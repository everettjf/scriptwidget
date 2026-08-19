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
    struct RenderOutput {
        let rootElement: ScriptWidgetRuntimeElement
        let runtime: ScriptWidgetRuntime
        let errorMessage: String?
        let logs: [String]
    }

    let package: ScriptWidgetPackage
    private var widgetSizeType: Int
    private var scriptParameter: String
    private var renderingMode: StudioPreviewRenderingMode
    private var cancellables = [Cancellable]()
    private let renderQueue = DispatchQueue(label: "com.everettjf.scriptwidget.studio-preview", qos: .userInitiated)
    private var pendingRender: DispatchWorkItem?
    private var renderGeneration = 0
    
    @Published var rootElement : ScriptWidgetRuntimeElement
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var logs: [String] = []
    var runtime: ScriptWidgetRuntime?


    init(
        file: ScriptWidgetPackage,
        widgetSizeType: Int,
        scriptParameter: String,
        renderingMode: StudioPreviewRenderingMode = .fullColor
    ) {
        self.widgetSizeType = widgetSizeType
        self.scriptParameter = scriptParameter
        self.renderingMode = renderingMode
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
        runtime?.cancel(.explicit)
    }
    
    func changeWidgetSizeType(_ newWidgetSizeType : Int) {
        self.widgetSizeType = newWidgetSizeType
        
        scheduleRender()
    }
    
    func changeWidgetParameter(_ parameter: String) {
        self.scriptParameter = parameter
        
        scheduleRender()
    }

    func changeRenderingMode(_ mode: StudioPreviewRenderingMode) {
        renderingMode = mode
        scheduleRender()
    }

    private func scheduleRender(immediate: Bool = false) {
        pendingRender?.cancel()
        runtime?.cancel(.superseded)
        renderGeneration += 1
        let generation = renderGeneration
        let size = widgetSizeType
        let parameter = scriptParameter
        let mode = renderingMode

        rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#Loading#"])
        ScriptCodePreviewConsoleDataObject.replaceLogs(["$START"])

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let output = Self.render(
                package: package,
                widgetSizeType: size,
                scriptParameter: parameter,
                renderingMode: mode
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == renderGeneration else {
                    output.runtime.cancel(.superseded)
                    return
                }
                runtime = output.runtime
                rootElement = output.rootElement
                lastErrorMessage = output.errorMessage
                logs = output.logs
                PreviewDiagnosticStore.shared.record(
                    output.errorMessage,
                    for: package.path.standardizedFileURL.path
                )
                ScriptCodePreviewConsoleDataObject.replaceLogs(["$START"] + output.logs + ["$FINISH"])
            }
        }
        pendingRender = work
        renderQueue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.3), execute: work)
    }

    static func render(
        package: ScriptWidgetPackage,
        widgetSizeType: Int,
        scriptParameter: String,
        renderingMode: StudioPreviewRenderingMode = .fullColor
    ) -> RenderOutput {
        let sourceResult = package.readMainFile()
        let source = sourceResult.0 ?? ""
        let widgetSize = StudioPreviewFamily(rawValue: widgetSizeType)?.runtimeValue ?? "small"
        let runtime = ScriptWidgetRuntime(package: package, environments: [
            "widget-size": widgetSize,
            "widget-param": scriptParameter,
            "widget-rendering-mode": renderingMode.runtimeValue,
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

        let message = result.1?.diagnosticMessage ?? "#Failed#"
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

final class PreviewDiagnosticStore: @unchecked Sendable {
    static let shared = PreviewDiagnosticStore()

    private let lock = NSLock()
    private var diagnostics: [String: String] = [:]

    func record(_ diagnostic: String?, for packagePath: String) {
        lock.lock()
        defer { lock.unlock() }
        diagnostics[packagePath] = diagnostic
    }

    func diagnostic(for packagePath: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics[packagePath]
    }
}

struct PreviewView: View {
    
    let scriptModel: ScriptModel
    @Bindable var configuration: StudioWidgetConfiguration
    @StateObject private var data: ScriptCodeRunnerDataObject
    
    @State private var outputTab = StudioOutputTab.problems
    @State private var scriptParameterApplied = ""
    
    init(scriptModel: ScriptModel, configuration: StudioWidgetConfiguration) {
        self.scriptModel = scriptModel
        self.configuration = configuration
        _data = StateObject(wrappedValue: ScriptCodeRunnerDataObject(
            file: scriptModel.package,
            widgetSizeType: configuration.family.rawValue,
            scriptParameter: "",
            renderingMode: configuration.renderingMode
        ))
    }
    
    var body: some View {
        content
    }
    
    private enum StudioOutputTab: String, CaseIterable, Identifiable {
        case problems
        case console

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var preview: some View {
        ScriptWidgetElementView(
            element: data.rootElement,
            context:
                ScriptWidgetElementContext(
                    runtime: data.runtime ,
                    debugMode: configuration.debugMode,
                    scriptName: scriptModel.name,
                    scriptParameter: scriptParameterApplied,
                    package: self.scriptModel.package
                )
        )
            .frame(
                width: configuration.family.size.width,
                height: configuration.family.size.height
            )
            .clipShape(.rect(cornerRadius: 12))
    }
    
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewToolbar
            Divider()
            previewCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            outputPanel
                .frame(minHeight: 120, idealHeight: 170, maxHeight: 240)
        }
    }

    private var previewToolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Canvas", selection: $configuration.canvasMode) {
                    ForEach(StudioPreviewCanvasMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if configuration.canvasMode == .single {
                    Picker("Family", selection: $configuration.family) {
                        ForEach(StudioPreviewFamily.allCases) { family in
                            Text(family.title).tag(family)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: configuration.family) { _, value in
                        data.changeWidgetSizeType(value.rawValue)
                    }
                }

                Toggle("Debug", isOn: $configuration.debugMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }


            Picker("Rendering Environment", selection: $configuration.renderingMode) {
                ForEach(StudioPreviewRenderingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: configuration.renderingMode) { _, value in
                data.changeRenderingMode(value)
            }

            HStack {
                TextField("Widget parameter", text: $configuration.parameter)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyParameter() }
                Button("Apply") { applyParameter() }
                Spacer()
                Button("Snapshot", systemImage: "photo") { saveSnapshot() }
                    .disabled(configuration.canvasMode == .all)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var previewCanvas: some View {
        ScrollView([.horizontal, .vertical]) {
            if configuration.canvasMode == .single {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                    preview
                }
                .frame(
                    minWidth: configuration.family.size.width + 36,
                    minHeight: configuration.family.size.height + 36
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 390), spacing: 20)], spacing: 20) {
                    ForEach(StudioPreviewFamily.allCases) { family in
                        StudioPreviewTile(
                            family: family,
                            scriptModel: scriptModel,
                            scriptParameter: scriptParameterApplied,
                            renderingMode: configuration.renderingMode,
                            isDebugMode: configuration.debugMode
                        )
                    }
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Output", selection: $outputTab) {
                ForEach(StudioOutputTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .padding(8)

            Divider()

            switch outputTab {
            case .problems:
                StudioProblemsView(errorMessage: data.lastErrorMessage)
            case .console:
                ScriptCodePreviewConsoleView()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func applyParameter() {
        scriptParameterApplied = configuration.parameter
        data.changeWidgetParameter(scriptParameterApplied)
        NotificationCenter.default.post(name: PreviewService.updateNotification, object: scriptModel.package)
    }

    private func saveSnapshot() {
        guard let image = preview.snapshot() else {
            MacKitUtil.alertWarn(title: "Snapshot Failed", message: "The preview could not be captured.")
            return
        }
        MacKitUtil.selectDirectory(title: "Save snapshot") { path in
            guard let path else { return }
            var targetPath = path.appendingPathComponent("snapshot.png")
            var index = 0
            while FileManager.default.fileExists(atPath: targetPath.path) {
                index += 1
                targetPath = path.appendingPathComponent("snapshot\(index).png")
            }
            MacKitUtil.saveImage(image, atUrl: targetPath)
        }
    }
}

private struct StudioProblemsView: View {
    let errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage, !errorMessage.isEmpty {
                ScrollView {
                    Label {
                        Text(errorMessage)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    .padding(10)
                }
            } else {
                ContentUnavailableView(
                    "No Problems",
                    systemImage: "checkmark.circle",
                    description: Text("The latest preview completed without a runtime error.")
                )
            }
        }
    }
}

private struct StudioPreviewTile: View {
    let family: StudioPreviewFamily
    let scriptModel: ScriptModel
    let scriptParameter: String
    let renderingMode: StudioPreviewRenderingMode
    let isDebugMode: Bool

    @StateObject private var data: ScriptCodeRunnerDataObject

    init(
        family: StudioPreviewFamily,
        scriptModel: ScriptModel,
        scriptParameter: String,
        renderingMode: StudioPreviewRenderingMode,
        isDebugMode: Bool
    ) {
        self.family = family
        self.scriptModel = scriptModel
        self.scriptParameter = scriptParameter
        self.renderingMode = renderingMode
        self.isDebugMode = isDebugMode
        _data = StateObject(wrappedValue: ScriptCodeRunnerDataObject(
            file: scriptModel.package,
            widgetSizeType: family.rawValue,
            scriptParameter: scriptParameter,
            renderingMode: renderingMode
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(family.title).font(.headline)
                Spacer()
                if data.lastErrorMessage != nil {
                    Label("Failed", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)

            ScriptWidgetElementView(
                element: data.rootElement,
                context: ScriptWidgetElementContext(
                    runtime: data.runtime,
                    debugMode: isDebugMode,
                    scriptName: scriptModel.name,
                    scriptParameter: scriptParameter,
                    package: scriptModel.package
                )
            )
            .frame(width: family.size.width, height: family.size.height)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 14))
        .onChange(of: scriptParameter) { _, value in
            data.changeWidgetParameter(value)
        }
        .onChange(of: renderingMode) { _, value in
            data.changeRenderingMode(value)
        }
    }
}

struct PreviewView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewView(scriptModel: globalScriptModel, configuration: StudioWidgetConfiguration())
            .frame(width: 300, height: 600, alignment: .topLeading)
    }
}
