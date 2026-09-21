//
//  ScriptDynamicIslandDataObject.swift
//  ScriptWidgetWidget
//
//  Created by everettjf on 2022/9/25.
//

import Foundation
import SwiftUI
import WidgetKit

class ScriptDynamicIslandCreator {
    let scriptName: String
    let scriptParameter: String
    let scriptState: String
    let package: ScriptWidgetPackage
    
    var rootElement : ScriptWidgetDynamicIslandRuntimeElement
    var runtime: ScriptWidgetRuntime?
    
    init(scriptName: String, scriptParameter: String, scriptState: String) {
        self.scriptName = scriptName
        self.scriptParameter = scriptParameter
        self.scriptState = scriptState
        
        self.package = buildScriptManager.getScriptPackage(packageName: self.scriptName)
        
        self.rootElement = ScriptWidgetDynamicIslandRuntimeElement(text: ".")
    }
    
    func runScriptSync() {
        if self.scriptName.count == 0 {
            self.rootElement = ScriptWidgetDynamicIslandRuntimeElement(text: "No script selected")
            return
        }
        
        self.systemLog("[START]")
        
        let read = package.readMainFileResult()
        guard let JSX = read.content else {
            let message = read.icloud == .downloading
                ? "Downloading script. Open ScriptWidget to finish syncing, then start the activity again."
                : "Script unavailable. Open ScriptWidget and start the activity again."
            self.rootElement = ScriptWidgetDynamicIslandRuntimeElement(text: message)
            return
        }

        let runtime = ScriptWidgetRuntime(package: self.package, environments: [
            "widget-size" : "dynamic-island",
            "widget-param": scriptParameter,
            "live-activity-state": scriptState,
            "live-activity-surface": "dynamicIsland",
        ])
        
        let result = runtime.executeJSXSyncForDynamicIsland(JSX)
        
        if let element = result.0 {
            // succeed
            self.rootElement = element
            self.runtime = runtime
        } else {
            // error
            self.runtime = nil
            
            if let error = result.1 {
                let message = error.displayMessage
                self.systemLog(message)
                self.rootElement = ScriptWidgetDynamicIslandRuntimeElement(text: message)
            }
        }

        self.systemLog("[FINISH]")
    }

    func systemLog(_ str: String) {
        SWLog.info(str)
    }
}
