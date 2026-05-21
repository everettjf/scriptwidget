//
//  EditorWebSevice.swift
//  ScriptWidgetMac
//
//  Resolves the URL that the Monaco editor WKWebView loads. The assets
//  themselves are served from the app bundle via EditorSchemeHandler —
//  no localhost HTTP server is required.
//

import Foundation

func editorWebServiceUrl() -> String {
    let editorName = MacKitUtil.isSystemThemeDark() ? "editor-dark.html" : "editor-light.html"
    return "\(kEditorURLScheme)://editor/\(editorName)"
}
