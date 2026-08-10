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
    fileprivate static let snapshotRequestNotification = Notification.Name("EditorService_SnapshotRequestNotification")
    fileprivate static let replaceDocumentNotification = Notification.Name("EditorService_ReplaceDocumentNotification")

    static func requestSnapshot(_ completion: @escaping (EditorDocumentSnapshot?) -> Void) {
        NotificationCenter.default.post(
            name: snapshotRequestNotification,
            object: EditorSnapshotRequest(completion: completion)
        )
    }

    static func replaceDocument(with content: String) {
        NotificationCenter.default.post(name: replaceDocumentNotification, object: content)
    }
}

typealias EditorDocumentSnapshot = StudioDocumentSnapshot

private final class EditorSnapshotRequest {
    let completion: (EditorDocumentSnapshot?) -> Void

    init(completion: @escaping (EditorDocumentSnapshot?) -> Void) {
        self.completion = completion
    }
}

final class EditorInternalWebView: WKWebView {
    private var bridge: WKWebViewJavascriptBridge?
    private var scriptModel: ScriptModel?
    private var currentRelativePath = "main.jsx"
    private var isEditorReady = false
    private var pendingActions: [() -> Void] = []
    private var cancellables = Set<AnyCancellable>()
    private var currentDocumentID: String?
    private var requestedDocumentID: String?
    private let documentSession = StudioDocumentSession()
    private var hasLoadedEditor = false
    private var draftWorkItem: DispatchWorkItem?

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

        NotificationCenter.default.publisher(for: EditorService.snapshotRequestNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let request = notification.object as? EditorSnapshotRequest else { return }
                self?.readSnapshot(completion: request.completion)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: EditorService.replaceDocumentNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let content = notification.object as? String else { return }
                self?.replaceDocument(with: content)
            }
            .store(in: &cancellables)
    }

    deinit {
        stopLoading()
        draftWorkItem?.cancel()
        pendingActions.removeAll()
        bridge?.reset()
        bridge = nil
    }

    func loadEditorIfNeeded() {
        guard !hasLoadedEditor else { return }
        hasLoadedEditor = true
        load(URLRequest(url: editorWebServiceURL()))
    }

    func updateDocument(_ model: ScriptModel, relativePath: String) {
        let resolvedRelativePath = relativePath.isEmpty ? "main.jsx" : relativePath
        guard let documentURL = model.package.resolvedPackageURL(relativePath: resolvedRelativePath) else { return }
        let documentID = documentURL.standardizedFileURL.path
        requestedDocumentID = documentID

        guard currentDocumentID != documentID else {
            scriptModel = model
            if isEditorReady {
                setReadOnly(model.package.readonly)
            }
            return
        }

        let activateDocument = { [weak self] in
            guard let self else { return }
            guard self.requestedDocumentID == documentID else { return }
            self.scriptModel = model
            self.currentRelativePath = resolvedRelativePath
            self.currentDocumentID = documentID
            self.openCurrentDocument()
        }

        runWhenReady { [weak self] in
            guard let self else { return }
            if self.currentDocumentID == nil {
                activateDocument()
            } else {
                self.saveCurrentContent { saved in
                    if saved { activateDocument() }
                }
            }
        }
    }

    private func registerBridgeHandlers() {
        bridge?.register(handlerName: StudioProtocol.ready) { [weak self] _, callback in
            guard let self else { return }
            if !isEditorReady {
                isEditorReady = true
                flushPendingActions()
            }
            callback?(["result": "ok", "protocolVersion": StudioProtocol.version])
        }

        bridge?.register(handlerName: StudioProtocol.documentSave) { [weak self] parameters, callback in
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

        bridge?.register(handlerName: StudioProtocol.documentChanged) { [weak self] _, callback in
            self?.scheduleDraftSnapshot()
            callback?(["result": "ok"])
        }
    }

    private func openCurrentDocument() {
        guard let model = scriptModel else { return }
        let result = model.package.readFile(relativePath: currentRelativePath)
        guard let content = result.0 else { return }

        guard let currentDocumentID else { return }
        let recovered = documentSession.open(documentID: currentDocumentID, content: content)
        callStudio(
            handlerName: StudioProtocol.documentOpen,
            payload: [
                "content": recovered,
                "version": 0,
                "readOnly": model.package.readonly,
            ]
        )
    }

    private func scheduleDraftSnapshot() {
        draftWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let documentID = self.currentDocumentID else { return }
            self.readSnapshot { [weak self] snapshot in
                guard let self, let snapshot else { return }
                guard self.currentDocumentID == documentID else { return }
                self.documentSession.recordDraft(snapshot.content)
            }
        }
        draftWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func setReadOnly(_ readOnly: Bool) {
        callStudio(handlerName: StudioProtocol.documentSetReadOnly, payload: ["readOnly": readOnly])
    }

    private func saveCurrentContent(completion: ((Bool) -> Void)? = nil) {
        guard isEditorReady else {
            completion?(false)
            return
        }
        callStudio(handlerName: StudioProtocol.editorGetState) { [weak self] response in
            guard
                let self,
                let state = response as? [String: Any],
                let content = state["content"] as? String
            else {
                completion?(false)
                return
            }
            completion?(save(content: content))
        }
    }

    private func readSnapshot(completion: @escaping (EditorDocumentSnapshot?) -> Void) {
        guard isEditorReady else {
            completion(nil)
            return
        }
        callStudio(handlerName: StudioProtocol.editorGetState) { response in
            completion(EditorDocumentSnapshot(state: response))
        }
    }

    private func replaceDocument(with content: String) {
        guard isEditorReady, scriptModel?.package.readonly == false else { return }
        callStudio(
            handlerName: StudioProtocol.documentReplace,
            payload: ["content": content, "version": 0]
        ) { [weak self] response in
            guard let self else { return }
            let result = (response as? [String: Any])?["result"] as? String
            guard result == "ok" else { return }
            _ = save(content: content)
        }
    }

    @discardableResult
    private func save(content: String) -> Bool {
        guard documentSession.needsSave(content) else { return true }
        guard let scriptModel else { return false }

        let result = currentRelativePath == "main.jsx"
            ? scriptModel.package.writeMainFile(content: content)
            : scriptModel.package.writeFile(relativePath: currentRelativePath, content: content)
        guard result.0 else {
            print("Studio save failed: \(result.1)")
            return false
        }

        documentSession.markSaved(content)
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
        StudioProtocol.envelope(type: type, documentID: currentDocumentID, payload: payload)
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
    let relativePath: String

    func makeNSView(context: Context) -> EditorInternalWebView {
        let webView = EditorInternalWebView()
        webView.loadEditorIfNeeded()
        webView.updateDocument(scriptModel, relativePath: relativePath)
        return webView
    }

    func updateNSView(_ view: EditorInternalWebView, context: Context) {
        view.updateDocument(scriptModel, relativePath: relativePath)
    }
}

struct EditorWebView_Previews: PreviewProvider {
    static var previews: some View {
        EditorWebView(scriptModel: globalScriptModel, relativePath: "main.jsx")
    }
}
