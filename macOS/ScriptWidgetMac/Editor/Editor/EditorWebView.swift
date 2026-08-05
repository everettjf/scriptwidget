//
//  EditorWebView.swift
//  ScriptWidgetMac
//
//  Shared ScriptWidget Studio editor host.
//

import Combine
import SwiftUI
import WebKit

final class EditorService {
    static let saveNotification = Notification.Name("EditorService_SaveNotification")
}

final class EditorInternalWebView: WKWebView {
    private enum StudioMessage {
        static let ready = "studio.ready"
        static let documentOpen = "document.open"
        static let documentSave = "document.save"
        static let documentSetReadOnly = "document.setReadOnly"
        static let editorGetState = "editor.getState"
    }

    private static let protocolVersion = 1

    private var bridge: WKWebViewJavascriptBridge?
    private var scriptModel: ScriptModel?
    private var isEditorReady = false
    private var pendingActions: [() -> Void] = []
    private var cancellables = Set<AnyCancellable>()
    private var currentDocumentID: String?
    private var lastSavedContent = ""
    private var hasLoadedEditor = false

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: kEditorURLScheme)
        super.init(frame: .zero, configuration: configuration)

        setValue(false, forKey: "drawsBackground")
        bridge = WKWebViewJavascriptBridge(webView: self)
        registerBridgeHandlers()

        NotificationCenter.default.publisher(for: EditorService.saveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveCurrentContent() }
            .store(in: &cancellables)
    }

    deinit {
        stopLoading()
        pendingActions.removeAll()
        bridge?.reset()
        bridge = nil
    }

    func loadEditorIfNeeded() {
        guard !hasLoadedEditor else { return }
        hasLoadedEditor = true
        load(URLRequest(url: editorWebServiceURL()))
    }

    func updateScript(_ model: ScriptModel) {
        scriptModel = model
        let documentID = model.package.jsxPath.standardizedFileURL.path

        guard currentDocumentID != documentID else {
            if isEditorReady {
                setReadOnly(model.package.readonly)
            }
            return
        }

        currentDocumentID = documentID
        runWhenReady { [weak self] in self?.openCurrentDocument() }
    }

    private func registerBridgeHandlers() {
        bridge?.register(handlerName: StudioMessage.ready) { [weak self] _, callback in
            guard let self else { return }
            if !isEditorReady {
                isEditorReady = true
                flushPendingActions()
            }
            callback?(["result": "ok", "protocolVersion": Self.protocolVersion])
        }

        bridge?.register(handlerName: StudioMessage.documentSave) { [weak self] parameters, callback in
            guard
                let self,
                let payload = parameters?["payload"] as? [String: Any],
                let content = payload["content"] as? String
            else {
                callback?(["result": "failed", "message": "Invalid document payload"])
                return
            }

            callback?(save(content: content) ? ["result": "ok"] : ["result": "failed"])
        }
    }

    private func openCurrentDocument() {
        guard let model = scriptModel else { return }
        let result = model.package.readMainFile()
        guard let content = result.0 else { return }

        lastSavedContent = content
        callStudio(
            handlerName: StudioMessage.documentOpen,
            payload: [
                "content": content,
                "version": 0,
                "readOnly": model.package.readonly,
            ]
        )
    }

    private func setReadOnly(_ readOnly: Bool) {
        callStudio(handlerName: StudioMessage.documentSetReadOnly, payload: ["readOnly": readOnly])
    }

    private func saveCurrentContent() {
        guard isEditorReady else { return }
        callStudio(handlerName: StudioMessage.editorGetState) { [weak self] response in
            guard
                let self,
                let state = response as? [String: Any],
                let content = state["content"] as? String
            else { return }
            _ = save(content: content)
        }
    }

    @discardableResult
    private func save(content: String) -> Bool {
        guard content != lastSavedContent else { return true }
        guard let scriptModel else { return false }

        let result = scriptModel.package.writeMainFile(content: content)
        guard result.0 else {
            print("Studio save failed: \(result.1)")
            return false
        }

        lastSavedContent = content
        NotificationCenter.default.post(name: PreviewService.updateNotification, object: scriptModel.package)
        return true
    }

    private func runWhenReady(_ action: @escaping () -> Void) {
        if isEditorReady {
            DispatchQueue.main.async(execute: action)
        } else {
            pendingActions.append(action)
        }
    }

    private func flushPendingActions() {
        let actions = pendingActions
        pendingActions.removeAll()
        actions.forEach { $0() }
    }

    private func studioEnvelope(type: String, payload: [String: Any]) -> [String: Any] {
        [
            "protocolVersion": Self.protocolVersion,
            "type": type,
            "documentID": currentDocumentID as Any? ?? NSNull(),
            "payload": payload,
        ]
    }

    private func callStudio(
        handlerName: String,
        payload: [String: Any] = [:],
        callback: ((Any?) -> Void)? = nil
    ) {
        bridge?.call(
            handlerName: handlerName,
            data: studioEnvelope(type: handlerName, payload: payload),
            callback: callback
        )
    }
}

struct EditorWebView: NSViewRepresentable {
    let scriptModel: ScriptModel

    func makeNSView(context: Context) -> EditorInternalWebView {
        let webView = EditorInternalWebView()
        webView.loadEditorIfNeeded()
        webView.updateScript(scriptModel)
        return webView
    }

    func updateNSView(_ view: EditorInternalWebView, context: Context) {
        view.updateScript(scriptModel)
    }
}

struct EditorWebView_Previews: PreviewProvider {
    static var previews: some View {
        EditorWebView(scriptModel: globalScriptModel)
    }
}
