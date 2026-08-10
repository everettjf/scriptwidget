//
//  WebView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/4/21.
//

import SwiftUI
import WebKit
import Combine


class MirrorEditorService {
    static let saveNotification = Notification.Name("MirrorEditorSaveNotification")
    fileprivate static let snapshotNotification = Notification.Name("MirrorEditorSnapshotNotification")
    fileprivate static let replaceDocumentNotification = Notification.Name("MirrorEditorReplaceDocumentNotification")

    static func requestSnapshot(completion: @escaping (MirrorEditorDocumentSnapshot?) -> Void) {
        NotificationCenter.default.post(
            name: snapshotNotification,
            object: MirrorEditorSnapshotRequest(completion: completion)
        )
    }

    static func replaceDocument(with content: String) {
        NotificationCenter.default.post(name: replaceDocumentNotification, object: content)
    }
}

typealias MirrorEditorDocumentSnapshot = StudioDocumentSnapshot

private struct MirrorEditorSnapshotRequest {
    let completion: (MirrorEditorDocumentSnapshot?) -> Void
}


struct MirrorEditorInternalActionProvider {
    typealias READER = () -> String
    typealias ISREADONLY = () -> Bool
    typealias WRITER = (String) -> Bool
    
    var documentID: String
    var onRead: READER?
    var onWrite: WRITER?
    var onIsReadOnly: ISREADONLY?
}

class MirrorEditorInternalView: WKWebView {
    public var accessoryView: UIView?
    
    var bridge: WKWebViewJavascriptBridge?
    var isEditorReady = false
    var pendingActions: [() -> Void] = []
    var cancellables = [Cancellable]()
    var isTearingDown = false
    
    private let documentSession = StudioDocumentSession()
    private var currentDocumentID: String?
    private var draftWorkItem: DispatchWorkItem?
    
    var action: MirrorEditorInternalActionProvider?
    

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
    }
    
    init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        super.init(frame: .zero, configuration: configuration)
        
        self.isOpaque = false
        self.backgroundColor = UIColor.clear
        self.scrollView.backgroundColor = UIColor.clear
        
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
            
            // save
            if let onWrite = self?.action?.onWrite {
                let writeSucceed = onWrite(value)
                if !writeSucceed {
                    print("save failed : write file ")
                    callback?(["result": "failed"])
                    return
                }
                self?.documentSession.markSaved(value)
            }

            callback?(["result": "ok"])
        })

        self.bridge?.register(handlerName: StudioProtocol.documentChanged, handler: { [weak self] _, callback in
            self?.scheduleDraftSnapshot()
            callback?(["result": "ok"])
        })
        
        guard let bundlePath = Bundle.main.url(forResource: "StudioEditor", withExtension: "bundle") else {
            fatalError("StudioEditor.bundle is missing")
        }
        guard let bundle = Bundle(url: bundlePath) else {
            fatalError("StudioEditor.bundle is invalid")
        }
        guard let indexURL = bundle.url(forResource: "index", withExtension: "html") else {
            fatalError("StudioEditor.bundle/index.html is missing")
        }
        self.loadFileURL(indexURL, allowingReadAccessTo: bundle.resourceURL!)
        
        let saveNoti = NotificationCenter.default.publisher(for: MirrorEditorService.saveNotification, object: nil).sink { [weak self] noti in
            self?.saveCurrentContent()
        }
        self.cancellables.append(saveNoti)

        let snapshotNotification = NotificationCenter.default.publisher(for: MirrorEditorService.snapshotNotification)
            .sink { [weak self] notification in
                guard let request = notification.object as? MirrorEditorSnapshotRequest else { return }
                self?.readSnapshot(completion: request.completion)
            }
        self.cancellables.append(snapshotNotification)

        let replaceNotification = NotificationCenter.default.publisher(for: MirrorEditorService.replaceDocumentNotification)
            .sink { [weak self] notification in
                guard let content = notification.object as? String else { return }
                self?.replaceDocument(with: content)
            }
        self.cancellables.append(replaceNotification)
    }
    
    deinit {
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
    
    func saveCurrentContent() {
        guard !isTearingDown else {
            return
        }
        editorGetValue { [weak self] (succeed, value) in
            guard let self = self else { return }
            guard !self.isTearingDown else { return }
            if !succeed {
                return
            }
            
            
            if !self.documentSession.needsSave(value) {
//                print("content same, already saved")
                return
            }
            
            if let onWrite = self.action?.onWrite {
                let saveSucceed = onWrite(value)
                if !saveSucceed {
                    return
                }
                self.documentSession.markSaved(value)
            }
            
            print("save succeed")
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
        callStudio(handlerName: StudioProtocol.documentSetReadOnly, payload: ["readOnly": readOnly])
    }
    
    func editorGetValue(callback: @escaping (Bool, String) -> Void) {
        guard !isTearingDown else {
            callback(false, "")
            return
        }
        callStudio(handlerName: StudioProtocol.editorGetState, callback: { responseData in
            guard let data = responseData as? [String: Any] else {
                callback(false, "")
                return
            }
            
            guard let value = data["content"] as? String else {
                callback(false, "")
                return
            }
            
            callback(true, value)
        })
    }

    private func readSnapshot(completion: @escaping (MirrorEditorDocumentSnapshot?) -> Void) {
        guard !isTearingDown else {
            completion(nil)
            return
        }
        callStudio(handlerName: StudioProtocol.editorGetState) { responseData in
            completion(MirrorEditorDocumentSnapshot(state: responseData))
        }
    }

    private func replaceDocument(with content: String) {
        guard !isTearingDown, action?.onIsReadOnly?() != true else { return }
        callStudio(
            handlerName: StudioProtocol.documentReplace,
            payload: ["content": content, "version": 0]
        ) { [weak self] response in
            guard let self else { return }
            let result = (response as? [String: Any])?["result"] as? String
            guard result == "ok" || result == nil else { return }
            if self.action?.onWrite?(content) == true {
                self.documentSession.markSaved(content)
            }
        }
    }

    private func scheduleDraftSnapshot() {
        draftWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let documentID = self.currentDocumentID else { return }
            self.editorGetValue { succeed, content in
                guard succeed else { return }
                guard self.currentDocumentID == documentID else { return }
                self.documentSession.recordDraft(content)
            }
        }
        draftWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }
    
    
    func updateDocument(action: MirrorEditorInternalActionProvider) {
        self.action = action
        guard currentDocumentID != action.documentID else {
            if isEditorReady {
                editorSetReadOnly(action.onIsReadOnly?() ?? false)
            }
            return
        }
        currentDocumentID = action.documentID
        self.runJSAction { [weak self] in
            self?.reloadCurrentScript()
        }
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
            let fileContent = onRead()
            guard let currentDocumentID else { return }
            let content = documentSession.open(documentID: currentDocumentID, content: fileContent)
            
            callStudio(
                handlerName: StudioProtocol.documentOpen,
                payload: [
                    "content": content,
                    "version": 0,
                    "readOnly": action?.onIsReadOnly?() ?? false,
                ]
            )
        }
    }
    
}


extension MirrorEditorInternalView {
    
    func createAccessoryView() -> UIView {
        let accessoryHeight:CGFloat = 44
        let doneButtonWidth: CGFloat = 50
        let screen = UIScreen.main.bounds.size
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: screen.width, height: accessoryHeight))
        containerView.backgroundColor = UIColor.systemBackground
        
        
        // format button view
        let formatButton = UIButton(frame: CGRect(x: screen.width - doneButtonWidth * 2, y: 0, width: doneButtonWidth, height: accessoryHeight))
        formatButton.setImage(UIImage(systemName: "paintbrush"), for: .normal)
        formatButton.addTarget(self, action: #selector(onButtonFormatTapped(sender:)), for: .touchUpInside)
        containerView.addSubview(formatButton)
        
        // done button view
        let doneButton = UIButton(frame: CGRect(x: screen.width - doneButtonWidth, y: 0, width: doneButtonWidth, height: accessoryHeight))
        doneButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        doneButton.addTarget(self, action: #selector(onButtonDoneTapped(sender:)), for: .touchUpInside)
        containerView.addSubview(doneButton)
        
        // scroll view
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: screen.width - doneButtonWidth*2, height: accessoryHeight))
        scrollView.showsHorizontalScrollIndicator = false
        containerView.addSubview(scrollView)
        
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
