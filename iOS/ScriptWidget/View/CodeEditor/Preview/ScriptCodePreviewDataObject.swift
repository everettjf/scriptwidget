//
//  ScriptCodePreviewDataObject.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/9/24.
//

import SwiftUI
import Combine


class ScriptCodePreviewDataObject : ObservableObject {
    let model: ScriptModel
    var widgetSizeType: Int
    var scriptParameter: String
    var widgetRenderingMode: String
    
    @Published var rootElement : ScriptWidgetRuntimeElement
    @Published var previewStatus : String
    @Published var filePath: URL
    
    var runtime: ScriptWidgetRuntime?
    @Published private(set) var lastErrorMessage: String?

    let previewQueue: DispatchQueue
    
    var cancelledByDeinit = false
    private var previewGeneration = 0
    private var pendingLayoutWorkItem: DispatchWorkItem?
    
    init(model: ScriptModel, filePath: URL, widgetSizeType: Int, scriptParameter: String, widgetRenderingMode: String = "fullColor") {
        self.model = model
        self.filePath = filePath
        self.widgetSizeType = widgetSizeType
        self.scriptParameter = scriptParameter
        self.widgetRenderingMode = widgetRenderingMode
        
        self.previewQueue = DispatchQueue(label: "preview-queue", qos: .default)
        self.previewStatus = "Initializing"
        self.rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#Loading#"])
        
        self.layoutElements()
        print("PreviewView data object init :\(Unmanaged.passUnretained(self).toOpaque())")
    }
    
    deinit {
        cancelledByDeinit = true
        pendingLayoutWorkItem?.cancel()
        runtime?.cancel(.explicit)
        print("PreviewView data object deinit :\(Unmanaged.passUnretained(self).toOpaque())")
    }
    
    
    func changeWidgetSizeType(_ newWidgetSizeType : Int) {
        self.widgetSizeType = newWidgetSizeType
        
        self.layoutElements()
    }
    func changeWidgetParameter(_ parameter: String) {
        self.scriptParameter = parameter
        
        self.layoutElements()
    }
    func changeWidgetRenderingMode(_ mode: String) {
        self.widgetRenderingMode = mode

        self.layoutElements()
    }
    func changeFile(_ filePath: URL) {
        self.filePath = filePath
        
        // DO NOT Re-Layout
        // self.layoutElements()
    }
    
    
    func layoutElements() {
        if self.cancelledByDeinit {
            print("PreviewView data layout elements cancelled by deinit :\(Unmanaged.passUnretained(self).toOpaque())")
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        pendingLayoutWorkItem?.cancel()
        runtime?.cancel(.superseded)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                print("PreviewView data layout elements cancelled by deinit : weak nil")
                return
            }
            if self.cancelledByDeinit {
                print("PreviewView data layout elements cancelled by deinit :\(Unmanaged.passUnretained(self).toOpaque())")
                return
            }
            guard generation == self.previewGeneration else { return }
            self.internalLayoutElements(generation: generation)
        }
        pendingLayoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    func internalLayoutElements(generation: Int) {
        print("PreviewView data internal layout element :\(Unmanaged.passUnretained(self).toOpaque())")
        self.runScript(generation: generation) { [weak self] result in
            guard let self, generation == self.previewGeneration else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard generation == self.previewGeneration else { return }
                self.loadScriptConsoleLogs()
                self.systemLog("FINISH")
            }
            if result {
                print("succeed preview")
                
                self.setPreviewStatus("Finish :)")
            } else {
                print("failed preview")
                self.setPreviewStatus("Error 0_0")
                DispatchQueue.main.async {
                    guard generation == self.previewGeneration else { return }
                    let info = self.lastErrorMessage ?? "#Failed#"
                    self.rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: [info])
                }
            }
        }
    }
    
    func setPreviewStatus(_ status: String) {
        DispatchQueue.main.async {
            self.previewStatus = status
        }
    }
    
    func runScript(generation: Int, _ completion: @escaping (Bool) -> Void) {
        self.previewQueue.async {
            guard generation == self.previewGeneration, !self.cancelledByDeinit else { return }
            self.setPreviewStatus("Running...")
            print("start preview")

            self.systemLog("START")
            
            guard let JSX = self.model.package.readFile(fullPath: self.filePath).0 else {
                self.systemLog("Can not open file")
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            
            var widgetSizeString = ""
            switch self.widgetSizeType {
            case 0: widgetSizeString = "small"
            case 1: widgetSizeString = "medium"
            case 2: widgetSizeString = "large"
            case 3: widgetSizeString = "extraLarge"
            case 4: widgetSizeString = "accessoryInline"
            case 5: widgetSizeString = "accessoryCircular"
            case 6: widgetSizeString = "accessoryRectangular"
            case 8: widgetSizeString = "extraLargePortrait"
            default: widgetSizeString = "small"
            }
            
            let runtime = ScriptWidgetRuntime(package: self.model.package, environments: [
                "widget-size": widgetSizeString,
                "widget-param": self.scriptParameter,
                "widget-rendering-mode": self.widgetRenderingMode,
            ])
            
            let result = runtime.executeJSXSyncForWidget(JSX)

            // Keep the runtime alive in both success and failure paths
            // so loadScriptConsoleLogs() can still read this run's logs
            // off its JSContext.
            guard generation == self.previewGeneration else {
                runtime.cancel(.superseded)
                return
            }
            self.runtime = runtime

            if let element = result.0 {
                // succeed
                DispatchQueue.main.async {
                    self.lastErrorMessage = nil
                    ScriptCodePreviewDiagnosticStore.shared.record(nil, for: self.model.package.path)
                    self.rootElement = element

                    completion(true)
                }
            } else {
                // error
                if let error = result.1 {
                    let message = error.diagnosticMessage
                    self.systemLog(message)
                    DispatchQueue.main.async {
                        self.lastErrorMessage = message
                        ScriptCodePreviewDiagnosticStore.shared.record(message, for: self.model.package.path)
                    }
                }
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
        
    }
    
    func loadScriptConsoleLogs() {
        if let logs = self.runtime?.runningState?.logger.logs {
            for log in logs {
                self.scriptLog(log)
            }
        }
    }
    
    func scriptLog(_ str: String) {
        DispatchQueue.main.async {
            ScriptCodePreviewConsoleDataObject.addLog(str)
        }
    }
    
    func systemLog(_ str: String) {
        DispatchQueue.main.async {
            ScriptCodePreviewConsoleDataObject.addLog("$" + str)
        }
    }
}

final class ScriptCodePreviewDiagnosticStore: @unchecked Sendable {
    static let shared = ScriptCodePreviewDiagnosticStore()

    private let lock = NSLock()
    private var diagnostics: [String: String] = [:]

    func record(_ diagnostic: String?, for packageURL: URL) {
        lock.lock()
        diagnostics[packageURL.standardizedFileURL.path] = diagnostic
        lock.unlock()
    }

    func diagnostic(for packageURL: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics[packageURL.standardizedFileURL.path]
    }
}
