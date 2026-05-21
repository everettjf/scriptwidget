//
//  SwiftWidgetRuntimeConsole.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/15.
//

import Foundation
import JavaScriptCore



@objc protocol ScriptWidgetRuntimeConsoleExports: JSExport {
    static func log(_ string: String) -> Void
    static func error(_ string: String) -> Void
}

@objc public class ScriptWidgetRuntimeConsole: NSObject, ScriptWidgetRuntimeConsoleExports {
    class func log(_ string: String) {
        JSContext.current()?.scriptWidgetRunningState?.logger.addLog(string)
        print("console log : \(string)")
    }

    class func error(_ string: String) {
        JSContext.current()?.scriptWidgetRunningState?.logger.addLog(string)
        print("console error : \(string)")
    }
}
