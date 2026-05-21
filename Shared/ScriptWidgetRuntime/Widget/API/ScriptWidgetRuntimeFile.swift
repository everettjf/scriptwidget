//
//  ScriptWidgetRuntimeFile.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/4/1.
//

import Foundation
import JavaScriptCore


@objc protocol ScriptWidgetRuntimeFileExports: JSExport {
    static func read(_ relativePath: String) -> String
    static func readJSON(_ relativePath: String) -> [AnyHashable: Any]!
}

@objc public class ScriptWidgetRuntimeFile: NSObject, ScriptWidgetRuntimeFileExports {
    static func read(_ relativePath: String) -> String {
        guard let runningState = JSContext.current()?.scriptWidgetRunningState else {
            return ""
        }
        guard let content = runningState.package.readFile(relativePath: relativePath).0 else {
            return ""
        }
        return content
    }

    static func readJSON(_ relativePath: String) -> [AnyHashable: Any]! {
        guard let runningState = JSContext.current()?.scriptWidgetRunningState else {
            return [:]
        }
        guard let content = runningState.package.readFile(relativePath: relativePath).0 else {
            return [:]
        }
        
        guard let data = content.data(using: .utf8) else {
            return [:]
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [AnyHashable:Any]
            return json
        } catch {
            print("Something went wrong : \(error)")
        }
        return [:]
    }
    
}
