//
//  SuperChargeAppIntent.swift
//  ScriptWidget
//
//  Created by zhufeng on 2023/10/7.
//

import Foundation
import AppIntents
import WidgetKit



struct ButtonActionAppIntent: AppIntent {
    
    let functionName: String
    let package: ScriptWidgetPackage?
    
    static var title: LocalizedStringResource = "Emoji Ranger SuperCharger"
    static var description = IntentDescription("All heroes get instant 100% health.")
    
    init() {
        self.functionName = ""
        self.package = nil
    }
    
    init(functionName: String, package: ScriptWidgetPackage) {
        self.functionName = functionName
        self.package = package
    }
    
    func perform() async throws -> some IntentResult {
        print("perform : \(ButtonActionAppIntent.self), functionName = \(functionName)")
        
        guard let package = package else {
            return .result()
        }
    
        let runtime = ScriptWidgetRuntime(package: package, environments: [
            "widget-size" : "function",
            "widget-param": "",
        ])
        
        let (JSX, _) = package.readMainFile()
        guard let JSX = JSX else {
            return .result()
        }
        _ = try? await runtime.executeJSXAsyncForFunction(JSX, functionName)
        
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        
        return .result()
    }
}
