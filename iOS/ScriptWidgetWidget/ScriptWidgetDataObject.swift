//
//  ScriptWidgetDataObject.swift
//  ScriptWidgetWidget
//
//  Created by everettjf on 2022/9/17.
//

import Foundation
import SwiftUI
import Combine
import WidgetKit

class ScriptWidgetDataObject : ObservableObject {
    let scriptName: String
    let scriptParameter: String
    let widgetFamily: WidgetFamily
    let package: ScriptWidgetPackage
    
    @Published var rootElement : ScriptWidgetRuntimeElement
    var runtime: ScriptWidgetRuntime?
    
    var cancellables: [AnyCancellable] = []
    
    init(scriptName: String, scriptParameter: String, widgetFamily: WidgetFamily) {
        self.scriptName = scriptName
        self.scriptParameter = scriptParameter
        self.widgetFamily = widgetFamily
        
        self.package = sharedScriptManager.getScriptPackage(packageName: self.scriptName)
        
        self.rootElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["."])
    }
    
    deinit {
        for item in cancellables {
            item.cancel()
        }
    }
    
    func createTextElement(info: String) -> ScriptWidgetRuntimeElement {
        return ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: [info])
    }
    
    func runScriptSync() {
        if self.scriptName.count == 0 {
            self.rootElement = createTextElement(info: "No script selected")
            return
        }
        
        self.systemLog("[START]")
        
        let readResult = self.package.readMainFileResult()
        guard let JSX = readResult.content else {
            // Distinguish a transient iCloud download from a real failure so the
            // widget shows a reassuring message instead of a scary error (#6).
            let info: String
            switch readResult.icloud {
            case .downloading:
                info = "Downloading from iCloud…\nThis widget will update once the script is available."
            case .notInICloud:
                info = "Script not found.\nOpen the app once while online to sync it."
            default:
                info = "Failed to open script : \(readResult.message)"
            }
            self.rootElement = createTextElement(info: info)
            return
        }
        
        let widgetSizeString: String
        if #available(iOSApplicationExtension 27.0, *), self.widgetFamily == .systemExtraLargePortrait {
            widgetSizeString = "extraLargePortrait"
        } else {
            switch self.widgetFamily {
            case .systemLarge: widgetSizeString = "large"
            case .systemMedium: widgetSizeString = "medium"
            case .systemSmall: widgetSizeString = "small"
            case .systemExtraLarge: widgetSizeString = "extraLarge"
            case .accessoryInline: widgetSizeString = "accessoryInline"
            case .accessoryCircular: widgetSizeString = "accessoryCircular"
            case .accessoryRectangular: widgetSizeString = "accessoryRectangular"
            default: widgetSizeString = "small"
            }
        }
        let runtime = ScriptWidgetRuntime(package: self.package, environments: [
            "widget-size" : widgetSizeString,
            "widget-param": scriptParameter,
        ])
        
        let result = runtime.executeJSXSyncForWidget(JSX)
        
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
                self.rootElement = createTextElement(info: message)
            }
        }

        self.systemLog("[FINISH]")
    }

    func systemLog(_ str: String) {
        SWLog.info(str)
    }
}
