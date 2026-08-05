//
//  PreviewView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/15.
//

import SwiftUI
import Combine



struct ScriptCodePreviewConsoleOutput : Identifiable {
    let id = UUID()
    let data: String
}

class ScriptCodePreviewConsoleDataObject : ObservableObject {
    public static let addLogNotification = Notification.Name("ScriptCodePreviewConsoleDataObject_addLog")
    public static let clearLogNotification = Notification.Name("ScriptCodePreviewConsoleDataObject_clearLog")
    public static let replaceLogsNotification = Notification.Name("ScriptCodePreviewConsoleDataObject_replaceLogs")
    
    @Published var consoleOutputs : [ScriptCodePreviewConsoleOutput] = []
    var cancellables = [Cancellable]()
    
    init() {
        let cancellableAddLog = NotificationCenter.default.publisher(for: Self.addLogNotification)
            .sink { (notification) in
                guard let log = notification.object as? String else {
                    return
                }
                
                self.consoleOutputs.append(ScriptCodePreviewConsoleOutput(data: log))
            }
        self.cancellables.append(cancellableAddLog)
        
        
        let cancellableClearLog = NotificationCenter.default.publisher(for: Self.clearLogNotification)
            .sink { (notification) in
                self.consoleOutputs.removeAll()
            }
        self.cancellables.append(cancellableClearLog)

        let cancellableReplaceLogs = NotificationCenter.default.publisher(for: Self.replaceLogsNotification)
            .sink { [weak self] notification in
                let logs = notification.object as? [String] ?? []
                self?.consoleOutputs = logs.suffix(500).map { ScriptCodePreviewConsoleOutput(data: $0) }
            }
        self.cancellables.append(cancellableReplaceLogs)
    }
    
    deinit {
        for cancellable in self.cancellables {
            cancellable.cancel()
        }
    }
    
    static func addLog(_ log: String) {
        NotificationCenter.default.post(name: Self.addLogNotification, object: log)
    }

    static func clearLog() {
        NotificationCenter.default.post(name: Self.clearLogNotification, object: nil)
    }

    static func replaceLogs(_ logs: [String]) {
        NotificationCenter.default.post(name: Self.replaceLogsNotification, object: logs)
    }
}

struct ScriptCodePreviewConsoleView : View {
    @StateObject private var data = ScriptCodePreviewConsoleDataObject()
    
    var body: some View {
        List {
            ForEach(data.consoleOutputs) { item in
                Text(item.data)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .font(.footnote)
                    .onTapGesture(count: 2) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.declareTypes([.string], owner: nil)
                        pasteboard.setString(item.data, forType: .string)
                        
                        MacKitUtil.alertInfo(title: "Tip", message: "Copied")
                    }
            }
        }
    }
}



final class ScriptCodeRunnerDataObject: ObservableObject {
    private struct RenderOutput {
        let rootElement: ScriptWidgetRuntimeElement
        let runtime: ScriptWidgetRuntime
        let errorMessage: String?
        let logs: [String]
    }

    let package: ScriptWidgetPackage
    private var widgetSizeType: Int
    private var scriptParameter: String
    private var cancellables = [Cancellable]()
    private let renderQueue = DispatchQueue(label: "com.everettjf.scriptwidget.studio-preview", qos: .userInitiated)
    private var pendingRender: DispatchWorkItem?
    private var renderGeneration = 0
    
    @Published var rootElement : ScriptWidgetRuntimeElement
    var runtime: ScriptWidgetRuntime?
    var lastErrorMessage: String?


    init(file: ScriptWidgetPackage, widgetSizeType: Int, scriptParameter: String) {
        self.widgetSizeType = widgetSizeType
        self.scriptParameter = scriptParameter
        self.package = file
        self.rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#Loading#"])
        scheduleRender(immediate: true)
        
        let cancellableSave = NotificationCenter.default.publisher(for: PreviewService.updateNotification)
            .sink { [weak self](notification) in
                // re-execute
                DispatchQueue.main.async {
                    self?.scheduleRender()
                }
            }
        self.cancellables.append(cancellableSave)
    }
    
    deinit {
        for cancellable in self.cancellables {
            cancellable.cancel()
        }
        pendingRender?.cancel()
    }
    
    func changeWidgetSizeType(_ newWidgetSizeType : Int) {
        self.widgetSizeType = newWidgetSizeType
        
        scheduleRender()
    }
    
    func changeWidgetParameter(_ parameter: String) {
        self.scriptParameter = parameter
        
        scheduleRender()
    }

    private func scheduleRender(immediate: Bool = false) {
        pendingRender?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let size = widgetSizeType
        let parameter = scriptParameter

        rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#Loading#"])
        ScriptCodePreviewConsoleDataObject.replaceLogs(["$START"])

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let output = Self.render(package: package, widgetSizeType: size, scriptParameter: parameter)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == renderGeneration else { return }
                runtime = output.runtime
                rootElement = output.rootElement
                lastErrorMessage = output.errorMessage
                ScriptCodePreviewConsoleDataObject.replaceLogs(["$START"] + output.logs + ["$FINISH"])
            }
        }
        pendingRender = work
        renderQueue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.3), execute: work)
    }

    private static func render(
        package: ScriptWidgetPackage,
        widgetSizeType: Int,
        scriptParameter: String
    ) -> RenderOutput {
        let sourceResult = package.readMainFile()
        let source = sourceResult.0 ?? ""
        let widgetSize = ["small", "medium", "large"].indices.contains(widgetSizeType)
            ? ["small", "medium", "large"][widgetSizeType]
            : "small"
        let runtime = ScriptWidgetRuntime(package: package, environments: [
            "widget-size": widgetSize,
            "widget-param": scriptParameter,
        ])

        guard sourceResult.0 != nil else {
            let message = "Can not open file: \(sourceResult.1)"
            return RenderOutput(
                rootElement: ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: [message]),
                runtime: runtime,
                errorMessage: message,
                logs: [message]
            )
        }

        let result = runtime.executeJSXSyncForWidget(source)
        let runtimeLogs = runtime.runningState?.logger.logs ?? []
        if let element = result.0 {
            return RenderOutput(rootElement: element, runtime: runtime, errorMessage: nil, logs: runtimeLogs)
        }

        let message = result.1?.displayMessage ?? "#Failed#"
        return RenderOutput(
            rootElement: ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: [message]),
            runtime: runtime,
            errorMessage: message,
            logs: runtimeLogs + [message]
        )
    }
}


class PreviewService {
    public static let updateNotification = Notification.Name("PreviewService_UpdateNotification")
}

struct PreviewView: View {
    
    let scriptModel: ScriptModel
    @StateObject private var data: ScriptCodeRunnerDataObject
    
    @State private var widgetSizeType = 0
    @State private var isDebugMode = false
    
    @State private var scriptParameter = ""
    @State private var scriptParameterApplied = ""
    
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        _data = StateObject(wrappedValue: ScriptCodeRunnerDataObject(
            file: scriptModel.package,
            widgetSizeType: 0,
            scriptParameter: ""
        ))
    }
    
    var body: some View {
        content
    }
    
    var preview: some View {
        ScriptWidgetElementView(
            element: data.rootElement,
            context:
                ScriptWidgetElementContext(
                    runtime: data.runtime ,
                    debugMode: isDebugMode,
                    scriptName: scriptModel.name,
                    scriptParameter: scriptParameterApplied,
                    package: self.scriptModel.package
                )
        )
            .frame(
                width: PreviewWidgetSize.size(self.widgetSizeType).width,
                height: PreviewWidgetSize.size(self.widgetSizeType).height
            )
            .clipShape(.rect(cornerRadius: 12))
    }
    
    var content: some View {
        
        VStack(alignment: .leading) {
            
            ZStack {
                Rectangle()
                    .fill(Color.secondary)
                    .opacity(0.2)
                
                preview
            }
            .frame(height: PreviewWidgetSize.size(self.widgetSizeType).height + 5)
            
            
            Section {
                HStack {
                    Picker(selection: $widgetSizeType) {
                        Text("Small").tag(0)
                        Text("Medium").tag(1)
                        Text("Large").tag(2)
                    } label: {
                        Text("Preview Size")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: widgetSizeType) { _, value in
                        print("preview size changed : \(value)")

                        self.data.changeWidgetSizeType(value)
                    }
                }
                .padding(.top, 5)
                
                HStack {
                    Toggle(isOn: $isDebugMode) {
                        Text("Debug Border")
                    }.toggleStyle(SwitchToggleStyle())

                    Spacer()

                    Button {
                        guard let image = preview.snapshot() else {
                            print("Failed snapshot")
                            MacKitUtil.alertWarn(title: "Tip", message: "Failed snapshot")
                            return
                        }
                        print("Succeed snapshot")
                        
                        MacKitUtil.selectDirectory(title: "Save snapshot to ?") { path in
                            guard let path = path else {
                                // cancelled
                                return
                            }
                            var targetPath = path.appendingPathComponent("snapshot.png")
                            var index = 0
                            while true {
                                if !FileManager.default.fileExists(atPath: targetPath.path) {
                                    break
                                }
                                
                                // file existed
                                index += 1
                                targetPath = path.appendingPathComponent("snapshot\(index).png")
                            }
                            print("target path : \(targetPath)")
                            
                            MacKitUtil.saveImage(image, atUrl: targetPath)
                            
                            MacKitUtil.alertInfo(title: "Tip", message: "Succeed save snapshot to : \(targetPath.path)")
                        }
                        
                    } label: {
                        Text("Snapshot")
                        Image(systemName: "photo")
                    }

                }
                
                
                HStack {
                    TextField("Parameter", text: $scriptParameter)
                    Button("Apply") {
                        self.scriptParameterApplied = self.scriptParameter
                        self.data.changeWidgetParameter(self.scriptParameterApplied)
                    }
                }
            }
            .padding(.leading)
            .padding(.trailing)
            
            ScriptCodePreviewConsoleView()
        }
    }
}

struct PreviewView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewView(scriptModel: globalScriptModel)
            .frame(width: 300, height: 600, alignment: .topLeading)
    }
}
