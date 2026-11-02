//
//  WebView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/4/21.
//

import SwiftUI
import WebKit
import Combine

private final class ScriptWidgetEditorPasteTarget: NSObject, UIPasteConfigurationSupporting {
    var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(forAccepting: NSString.self)
    var receive: (([NSItemProvider]) -> Void)?
    func paste(itemProviders: [NSItemProvider]) { receive?(itemProviders) }
    func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        pasteConfiguration != nil && itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
    }
}

@MainActor final class MirrorEditorService {
    static let saveNotification = Notification.Name("MirrorEditorService_SaveNotification")
    fileprivate static let snapshotNotification = Notification.Name("MirrorEditorService_SnapshotNotification")
    fileprivate static let replaceDocumentNotification = Notification.Name("MirrorEditorService_ReplaceDocumentNotification")

    static func save(target: StudioEditorTarget, completion: @escaping (Bool) -> Void) {
        let request = StudioEditorSaveRequest(target: target, completion: completion)
        NotificationCenter.default.post(name: saveNotification, object: request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { request.finish(false) }
    }

    static func requestSnapshot(target: StudioEditorTarget, completion: @escaping (StudioDocumentSnapshot?) -> Void) {
        let request = StudioEditorSnapshotRequest(target: target, completion: completion)
        NotificationCenter.default.post(name: snapshotNotification, object: request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { request.finish(nil) }
    }

    static func replaceDocument(with content: String, snapshot: StudioDocumentSnapshot,
                                completion: @escaping (StudioDocumentApplyResult) -> Void) {
        let request = StudioEditorReplacementRequest(snapshot: snapshot, content: content, completion: completion)
        NotificationCenter.default.post(name: replaceDocumentNotification, object: request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { request.finish(.unavailable) }
    }
}

typealias MirrorEditorDocumentSnapshot = StudioDocumentSnapshot

struct MirrorEditorInternalActionProvider {
    typealias READER = () -> String
    typealias ISREADONLY = () -> Bool
    typealias WRITER = (String) -> Bool
    
    var documentID: String
    var onRead: READER?
    var onWrite: WRITER?
    var onIsReadOnly: ISREADONLY?
    var onResources: (() -> [String])? = nil
}

class MirrorEditorInternalView: WKWebView {
    private let textPasteTarget = ScriptWidgetEditorPasteTarget()
    var libraryEditorLease: UUID?
    public var accessoryView: UIView?
    
    var bridge: WKWebViewJavascriptBridge?
    var isEditorReady = false
    var pendingActions: [() -> Void] = []
    var cancellables = [Cancellable]()
    var isTearingDown = false
    
    private let documentSession = StudioDocumentSession()
    private var requestedDocumentID: String?
    private var currentDocumentID: String?
    private var documentGeneration = UUID()
    private var draftWorkItem: DispatchWorkItem?
    
    var action: MirrorEditorInternalActionProvider?
    

    let editorID: UUID

    required init?(coder: NSCoder) {
        editorID = UUID()
        super.init(coder: coder)
        
    }
    
    init(editorID: UUID = UUID()) {
        self.editorID = editorID
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(StudioEditorBundleSchemeHandler(), forURLScheme: StudioEditorBundleSchemeHandler.scheme)
        super.init(frame: .zero, configuration: configuration)
        
        self.isOpaque = false
        self.backgroundColor = UIColor.clear
        self.scrollView.backgroundColor = UIColor.clear
        textPasteTarget.receive = { [weak self] in self?.pasteTextProviders($0) }
        
        // accessoryView
        self.accessoryView = self.createAccessoryView()

        // bridge
        self.bridge = WKWebViewJavascriptBridge(webView: self)
        
        self.bridge?.register(handlerName: StudioProtocol.ready, handler: { [weak self] (_, callback) in
            guard self?.isEditorReady == false else {
                callback?(["result": "ok", "protocolVersion": StudioProtocol.version])
                return
            }
            self?.isEditorReady = true
            self?.eventOnEditorReady()
            callback?(["result": "ok", "protocolVersion": StudioProtocol.version])
        })
        
        self.bridge?.register(handlerName: StudioProtocol.documentSave, handler: { [weak self] (parameters, callback) in
            guard
                let payload = parameters?["payload"] as? [String: Any],
                let value = payload["content"] as? String
            else {
                print("save failed : param invalid")
                callback?(["result": "failed"])
                return
            }
            
            guard let self, !self.isTearingDown, self.action?.onIsReadOnly?() != true,
                  let documentID = parameters?["documentID"] as? String,
                  documentID == self.currentDocumentID,
                  parameters?["sessionID"] as? String == self.documentGeneration.uuidString,
                  let writer = self.action?.onWrite else {
                callback?(["result": "failed"])
                return
            }
            guard let version = payload["version"] as? Int,
                  self.documentSession.bufferSnapshot(value, version: version) else {
                callback?(["result": "failed"]); return
            }
            let saved = self.documentSession.save(value, documentID: documentID, writer: writer)
            callback?(["result": saved ? "ok" : "failed"])
        })

        self.bridge?.register(handlerName: StudioProtocol.documentChanged, handler: { [weak self] parameters, callback in
            guard let self, !self.isTearingDown,
                  parameters?["documentID"] as? String == self.currentDocumentID,
                  parameters?["sessionID"] as? String == self.documentGeneration.uuidString else {
                callback?(["result": "failed"]); return
            }
            guard let payload = parameters?["payload"] as? [String: Any],
                  self.documentSession.bufferChange(payload) else {
                callback?(["result": "failed"]); return
            }
            self.scheduleDraftSnapshot()
            callback?(["result": "ok"])
        })

        self.bridge?.register(handlerName: StudioProtocol.documentResources) { [weak self] parameters, callback in
            guard let self, !self.isTearingDown, let id = self.currentDocumentID,
                  parameters?["documentID"] as? String == id,
                  parameters?["sessionID"] as? String == self.documentGeneration.uuidString else {
                callback?(["result": "failed"]); return
            }
            callback?(["result": "ok", "documentID": id, "resources": self.action?.onResources?() ?? []])
        }
        
        self.load(URLRequest(url: StudioEditorBundleSchemeHandler.indexURL))
        
        let saveNoti = NotificationCenter.default.publisher(for: MirrorEditorService.saveNotification, object: nil).sink { [weak self] noti in
            guard let self, !self.isTearingDown,
                  let request = noti.object as? StudioEditorSaveRequest,
                  request.target.editorID == self.editorID else { return }
            guard request.target.documentID == self.currentDocumentID else { request.finish(false); return }
            self.saveCurrentContent(completion: request.finish)
        }
        self.cancellables.append(saveNoti)

        let snapshotNotification = NotificationCenter.default.publisher(for: MirrorEditorService.snapshotNotification)
            .sink { [weak self] notification in
                guard let self, !self.isTearingDown,
                      let request = notification.object as? StudioEditorSnapshotRequest,
                      request.target.editorID == self.editorID else { return }
                guard request.target.documentID == self.currentDocumentID else { request.finish(nil); return }
                self.readSnapshot(completion: request.finish)
            }
        self.cancellables.append(snapshotNotification)

        let replaceNotification = NotificationCenter.default.publisher(for: MirrorEditorService.replaceDocumentNotification)
            .sink { [weak self] notification in
                guard let self, !self.isTearingDown,
                      let request = notification.object as? StudioEditorReplacementRequest,
                      request.snapshot.editorID == self.editorID else { return }
                self.replaceDocument(request)
            }
        self.cancellables.append(replaceNotification)
        StudioEditorHostRegistry.register(editorID: editorID, host: self) { [weak self] in
            self?.invalidate()
        }
    }
    
    func invalidate() {
        guard !isTearingDown else { return }
        if let documentID = currentDocumentID, isEditorReady {
            let sessionID = documentGeneration.uuidString
            let handoff = StudioDocumentHandoff.begin(documentID)
            let closingAction = action
            let request = StudioEditorCloseRequest { [self] response in
                if let snapshot = StudioDocumentSnapshot(state: response),
                   snapshot.documentID == documentID, snapshot.sessionID == sessionID {
                    documentSession.bufferSnapshot(snapshot.content, version: snapshot.version)
                }
                if closingAction?.onIsReadOnly?() != true {
                    if let writer = closingAction?.onWrite,
                       closingAction?.onRead?() == documentSession.savedContent {
                        _ = documentSession.save(documentSession.bufferedContent, documentID: documentID, writer: writer)
                    } else {
                        documentSession.persistBufferedDraft()
                    }
                }
                StudioDocumentHandoff.finish(documentID, token: handoff)
            }
            // Retain the host through a bounded final snapshot even when
            // SwiftUI has already detached its representable.
            callStudio(handlerName: StudioProtocol.editorGetState, callback: request.finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { request.finish(nil) }
        }
        isTearingDown = true
        documentGeneration = UUID()
        pendingActions.removeAll()
        draftWorkItem?.cancel()
        for cancellable in cancellables { cancellable.cancel() }
        cancellables.removeAll()
    }

    deinit {
        ScriptWidgetEditorPresence.unregister(libraryEditorLease)
        print("de-init editor")
        isTearingDown = true
        pendingActions.removeAll()
        draftWorkItem?.cancel()
        self.stopLoading()
        
        for cancellable in self.cancellables {
            cancellable.cancel()
        }
        self.cancellables.removeAll()
        self.bridge?.reset()
        self.bridge = nil
    }
    
    public override var inputAccessoryView: UIView? {
        return accessoryView
    }
    
    func saveCurrentContent(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isTearingDown, let documentID = currentDocumentID else {
            completion(false)
            return
        }
        let generation = documentGeneration
        editorGetValue { [weak self] succeed, value in
            guard let self, !self.isTearingDown, self.currentDocumentID == documentID,
                  self.documentGeneration == generation, succeed else {
                completion(false)
                return
            }
            if self.action?.onIsReadOnly?() == true {
                completion(value == self.documentSession.savedContent)
                return
            }
            guard let writer = self.action?.onWrite else { completion(false); return }
            completion(self.documentSession.save(value, documentID: documentID, writer: writer))
        }
    }

    func editorInsert(value: String) {
        guard !isTearingDown else { return }
        callStudio(handlerName: StudioProtocol.editorInsert, payload: ["content": value])
    }

    func editorFormatCode() {
        guard !isTearingDown else { return }
        callStudio(handlerName: StudioProtocol.editorFormat)
    }

    func editorSetReadOnly(_ readOnly: Bool) {
        guard !isTearingDown else { return }
        textPasteTarget.pasteConfiguration = readOnly ? nil : UIPasteConfiguration(forAccepting: NSString.self)
        callStudio(handlerName: StudioProtocol.documentSetReadOnly, payload: ["readOnly": readOnly])
    }

    /// System Paste delivers text explicitly, independent of WebKit's page
    /// origin and context menu. Never retarget an asynchronous paste to another
    /// file/session, or a document that became read-only while loading.
    func pasteTextProviders(_ providers: [NSItemProvider]) {
        guard !isTearingDown, isEditorReady, action?.onIsReadOnly?() != true,
              let documentID = currentDocumentID,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        let generation = documentGeneration
        provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let text = value as? String else { return }
            DispatchQueue.main.async {
                guard let self, !self.isTearingDown, self.documentGeneration == generation,
                      self.currentDocumentID == documentID, self.action?.onIsReadOnly?() != true else { return }
                self.editorInsert(value: text)
            }
        }
    }
    
    func editorGetValue(callback: @escaping (Bool, String) -> Void) {
        guard !isTearingDown else {
            callback(false, "")
            return
        }
        let documentID = currentDocumentID, generation = documentGeneration
        callStudio(handlerName: StudioProtocol.editorGetState, callback: { responseData in
            guard let data = responseData as? [String: Any] else {
                callback(false, "")
                return
            }
            
            guard !self.isTearingDown, self.documentGeneration == generation,
                  self.currentDocumentID == documentID,
                  data["documentID"] as? String == documentID,
                  data["sessionID"] as? String == generation.uuidString,
                  let value = data["content"] as? String,
                  let version = data["version"] as? Int,
                  self.documentSession.bufferSnapshot(value, version: version) else {
                callback(false, "")
                return
            }
            
            callback(true, value)
        })
    }

    private func readSnapshot(completion: @escaping (StudioDocumentSnapshot?) -> Void) {
        guard isEditorReady, !isTearingDown, let documentID = currentDocumentID else { completion(nil); return }
        let generation = documentGeneration
        callStudio(handlerName: StudioProtocol.editorGetState) { [weak self] response in
            guard let self, !self.isTearingDown, self.currentDocumentID == documentID,
                  self.documentGeneration == generation,
                  let snapshot = StudioDocumentSnapshot(state: response, editorID: self.editorID),
                  snapshot.documentID == documentID, snapshot.sessionID == generation.uuidString,
                  self.documentSession.bufferSnapshot(snapshot.content, version: snapshot.version) else {
                completion(nil); return
            }
            completion(snapshot)
        }
    }

    private func replaceDocument(_ request: StudioEditorReplacementRequest) {
        guard request.isPending else { return }
        guard isEditorReady, !isTearingDown else { request.finish(.unavailable); return }
        let snapshot = request.snapshot
        guard snapshot.documentID == currentDocumentID,
              snapshot.sessionID == documentGeneration.uuidString,
              action?.onIsReadOnly?() != true else { request.finish(.conflict); return }
        let generation = documentGeneration
        callStudio(handlerName: StudioProtocol.documentReplace,
                   payload: ["content": request.content, "expectedContent": snapshot.content, "version": snapshot.version + 1]) { [weak self] response in
            guard let self, request.isPending else { return }
            guard !self.isTearingDown, self.documentGeneration == generation,
                  self.currentDocumentID == snapshot.documentID else { request.finish(.conflict); return }
            guard (response as? [String: Any])?["result"] as? String == "ok" else {
                request.finish(.conflict); return
            }
            // Read current text so newer manual edits survive a delayed reply.
            self.saveCurrentContent { saved in request.finish(saved ? .saved : .saveFailed) }
        }
    }

    private func scheduleDraftSnapshot() {
        draftWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isTearingDown else { return }
            self.documentSession.persistBufferedDraft()
        }
        draftWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    
    
    func updateDocument(action: MirrorEditorInternalActionProvider) {
        guard !isTearingDown else { return }
        requestedDocumentID = action.documentID
        guard currentDocumentID != action.documentID else {
            self.action = action
            if isEditorReady { editorSetReadOnly(action.onIsReadOnly?() ?? false) }
            return
        }
        let activateDocument = { [weak self] in
            StudioDocumentHandoff.afterClosing(action.documentID) { [weak self] in
                guard let self, !self.isTearingDown, self.requestedDocumentID == action.documentID else { return }
                self.action = action
                self.currentDocumentID = action.documentID
                self.documentGeneration = UUID()
                self.reloadCurrentScript()
            }
        }

        runJSAction { [weak self] in
            guard let self, !self.isTearingDown else { return }
            if self.currentDocumentID == nil {
                activateDocument()
            } else {
                // Read and save the outgoing document before replacing its
                // writer and identity, including edits before the debounce.
                self.saveCurrentContent { saved in
                    if saved { activateDocument() }
                }
            }
        }
    }

    private func studioEnvelope(type: String, payload: [String: Any]) -> [String: Any] {
        StudioProtocol.envelope(type: type, documentID: currentDocumentID, payload: payload, sessionID: documentGeneration.uuidString)
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
    
    
    func runJSAction(_ action:@escaping () -> Void) {
        guard !isTearingDown else { return }
        if self.isEditorReady {
            DispatchQueue.main.async {
                action()
            }
        } else {
            DispatchQueue.main.async {
                self.pendingActions.append(action)
            }
        }
    }
    
    func eventOnEditorReady() {
        DispatchQueue.main.async {
            let pendingActions = self.pendingActions
            self.pendingActions = []
            for action in pendingActions {
                action()
            }
            
            DispatchQueue.main.async {
                // init tasks
            }
        }
    }
    
    func reloadCurrentScript() {
        if let onRead = action?.onRead {
            textPasteTarget.pasteConfiguration = action?.onIsReadOnly?() == true ? nil : UIPasteConfiguration(forAccepting: NSString.self)
            let fileContent = onRead()
            guard let currentDocumentID else { return }
            documentGeneration = UUID()
            let content = documentSession.open(documentID: currentDocumentID, content: fileContent)
            
            callStudio(
                handlerName: StudioProtocol.documentOpen,
                payload: [
                    "content": content,
                    "dirty": content != fileContent,
                    "version": 0,
                    "readOnly": action?.onIsReadOnly?() ?? false,
                    "resources": action?.onResources?() ?? [],
                ]
            )
        }
    }
    
}


extension MirrorEditorInternalView {
    
    func createAccessoryView() -> UIView {
        let accessoryHeight:CGFloat = 44
        let actionButtonWidth: CGFloat = 50
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: accessoryHeight))
        containerView.autoresizingMask = .flexibleWidth
        containerView.backgroundColor = UIColor.systemBackground
        
        
        // format button view
        let formatButton = UIButton(type: .system)
        formatButton.setImage(UIImage(systemName: "paintbrush"), for: .normal)
        formatButton.addTarget(self, action: #selector(onButtonFormatTapped(sender:)), for: .touchUpInside)
        containerView.addSubview(formatButton)
        
        // done button view
        let doneButton = UIButton(type: .system)
        doneButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        doneButton.addTarget(self, action: #selector(onButtonDoneTapped(sender:)), for: .touchUpInside)
        containerView.addSubview(doneButton)
        
        // scroll view
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        containerView.addSubview(scrollView)

        let pasteConfiguration = UIPasteControl.Configuration()
        pasteConfiguration.displayMode = .iconAndLabel
        let pasteControl = UIPasteControl(configuration: pasteConfiguration)
        pasteControl.target = textPasteTarget
        pasteControl.accessibilityIdentifier = "editor.paste"
        containerView.addSubview(pasteControl)

        for view in [formatButton, doneButton, scrollView, pasteControl] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 4),
            pasteControl.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            pasteControl.widthAnchor.constraint(equalToConstant: 90),
            pasteControl.heightAnchor.constraint(equalToConstant: 36),
            scrollView.leadingAnchor.constraint(equalTo: pasteControl.trailingAnchor, constant: 4),
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: formatButton.leadingAnchor),
            formatButton.widthAnchor.constraint(equalToConstant: actionButtonWidth),
            formatButton.topAnchor.constraint(equalTo: containerView.topAnchor),
            formatButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            formatButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: actionButtonWidth),
            doneButton.topAnchor.constraint(equalTo: containerView.topAnchor),
            doneButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            doneButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        
        let buttonItemWidth = 40
        let buttonItemTitles = [
            "<",
            ">",
            "/",
            ".",
            "$",
            "\"",
            "'",
            "(",
            ")",
            "_",
            ";",
            "+",
            "-",
            "[",
            "]",
            "?",
            "`",
        ]
        for (index, title) in buttonItemTitles.enumerated() {
            self.addToolbarItemToView(parent: scrollView, title: title, index: index, width: buttonItemWidth)
        }
        scrollView.contentSize = CGSize(width: CGFloat(buttonItemTitles.count * buttonItemWidth), height: accessoryHeight)
        
        return containerView
    }
    
    func addToolbarItemToView(parent: UIView, title: String, index: Int, width: Int) {
        let button = UIButton(frame: CGRect(x: index * width, y: 0, width: width, height: 44))
        button.setTitle(title, for: .normal)
        button.setTitleColor(UIColor.label, for: .normal)
        button.addTarget(self, action: #selector(onToolbarItemTapped(sender:)), for: .touchUpInside)
        parent.addSubview(button)
    }
    
    func createBarButton(_ title: String) -> UIBarButtonItem {
        return UIBarButtonItem(title: title, style: .plain, target: self, action: #selector(onToolbarItemTapped(sender:)))
    }
    
    @objc func onToolbarItemTapped(sender: UIButton) {
        guard let text = sender.title(for: .normal) else {
            return
        }
        DispatchQueue.main.async {
            self.editorInsert(value: text)
        }
    }
    
    @objc func onButtonDoneTapped(sender: UIButton) {
        self.resignFirstResponder()
    }
    @objc func onButtonFormatTapped(sender: UIButton) {
        self.editorFormatCode()
    }
}
