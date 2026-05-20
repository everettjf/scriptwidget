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
    
    @Published var rootElement : ScriptWidgetRuntimeElement
    @Published var previewStatus : String
    @Published var filePath: URL
    
    var runtime: ScriptWidgetRuntime?
    var lastErrorMessage: String?

    let previewQueue: DispatchQueue
    
    var cancelledByDeinit = false
    
    init(model: ScriptModel, filePath: URL, widgetSizeType: Int, scriptParameter: String) {
        self.model = model
        self.filePath = filePath
        self.widgetSizeType = widgetSizeType
        self.scriptParameter = scriptParameter
        
        self.previewQueue = DispatchQueue(label: "preview-queue", qos: .default)
        self.previewStatus = "Initializing"
        self.rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#Loading#"])
        
        self.layoutElements()
        print("PreviewView data object init :\(Unmanaged.passUnretained(self).toOpaque())")
    }
    
    deinit {
        cancelledByDeinit = true
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else {
                print("PreviewView data layout elements cancelled by deinit : weak nil")
                return
            }
            if self.cancelledByDeinit {
                print("PreviewView data layout elements cancelled by deinit :\(Unmanaged.passUnretained(self).toOpaque())")
                return
            }
            self.internalLayoutElements()
        }
    }
    
    func internalLayoutElements() {
        print("PreviewView data internal layout element :\(Unmanaged.passUnretained(self).toOpaque())")
        self.runScript { [weak self] result in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.loadScriptConsoleLogs()
                self?.systemLog("FINISH")
            }
            if result {
                print("succeed preview")
                
                self?.setPreviewStatus("Finish :)")
            } else {
                print("failed preview")
                self?.setPreviewStatus("Error 0_0")
                DispatchQueue.main.async {
                    let info = self?.lastErrorMessage ?? "#Failed#"
                    self?.rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: [info])
                }
            }
        }
    }
    
    func setPreviewStatus(_ status: String) {
        DispatchQueue.main.async {
            self.previewStatus = status
        }
    }
    
    func runScript(_ completion: @escaping (Bool) -> Void) {
        self.previewQueue.async {
            self.setPreviewStatus("Running...")
            print("start preview")
            // new running state
            sharedRunningState = ScriptWidgetRunningState(package: self.model.package)
            
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
            default: widgetSizeString = "small"
            }
            
            let runtime = ScriptWidgetRuntime(package: self.model.package, environments: [
                "widget-size": widgetSizeString,
                "widget-param": self.scriptParameter,
            ])
            
            let result = runtime.executeJSXSyncForWidget(JSX)
            
            if let element = result.0 {
                // succeed
                self.lastErrorMessage = nil
                DispatchQueue.main.async {
                    self.rootElement = element
                    self.runtime = runtime

                    completion(true)
                }
            } else {
                // error
                self.runtime = nil

                if let error = result.1 {
                    let message = error.displayMessage
                    self.lastErrorMessage = message
                    self.systemLog(message)
                }
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
        
    }
    
    func loadScriptConsoleLogs() {
        if let runningState = sharedRunningState {
            let logs = runningState.logger.logs
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
