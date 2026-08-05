//
//  EditorSchemeHandler.swift
//  ScriptWidgetMac
//
//  Serves the bundled Monaco editor static files (Editor.bundle/static)
//  directly to WKWebView via a custom URL scheme. Replaces the old
//  Vapor-based localhost HTTP service.
//

import Foundation
import WebKit
import UniformTypeIdentifiers

let kEditorURLScheme = "scriptwidget-editor"

final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {

    private let staticRoot: URL?

    override init() {
        if let bundleURL = Bundle.main.url(forResource: "Editor", withExtension: "bundle") {
            self.staticRoot = bundleURL.appendingPathComponent("static", isDirectory: true)
        } else {
            self.staticRoot = nil
        }
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let root = staticRoot else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }

        var relative = url.path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "editor-dark.html" }

        let rootPath = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        // Prevent path traversal — candidate must stay inside staticRoot.
        guard candidate.path.hasPrefix(rootPath) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        guard let data = try? Data(contentsOf: candidate) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mime = Self.mimeType(forPathExtension: candidate.pathExtension)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
            ]
        ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil) as URLResponse

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to cancel — responses are synchronous.
    }

    private static func mimeType(forPathExtension ext: String) -> String {
        let lower = ext.lowercased()
        switch lower {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "application/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "map":         return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "ttf":         return "font/ttf"
        case "otf":         return "font/otf"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "wasm":        return "application/wasm"
        default:
            if let type = UTType(filenameExtension: lower), let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }
}
