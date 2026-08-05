//
//  EditorWebSevice.swift
//  ScriptWidgetMac
//

import Foundation

func editorWebServiceURL() -> URL {
    URL(string: "\(kEditorURLScheme)://studio/index.html")!
}
