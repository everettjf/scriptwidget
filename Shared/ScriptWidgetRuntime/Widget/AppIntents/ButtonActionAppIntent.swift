//
//  SuperChargeAppIntent.swift
//  ScriptWidget
//
//  Created by zhufeng on 2023/10/7.
//

import Foundation
import AppIntents
import WidgetKit



#if os(macOS)
private typealias ScriptWidgetActionIntentProtocol = AppIntent
#else
@available(iOS 17.0, *)
private typealias ScriptWidgetActionIntentProtocol = LiveActivityIntent
#endif

@available(iOS 17.0, *)
struct ButtonActionAppIntent: ScriptWidgetActionIntentProtocol {
    
    let functionName: String
    let package: ScriptWidgetPackage?
    
    static var title: LocalizedStringResource = "Run Widget Action"
    static var description = IntentDescription("Run an action declared by the selected ScriptWidget package.")
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .main }
    #endif
    
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
        _ = runtime.executeJSXSyncForFunction(JSX, functionName)
        
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        
        return .result()
    }
}
