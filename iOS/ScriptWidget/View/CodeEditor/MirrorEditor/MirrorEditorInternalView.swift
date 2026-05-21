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
}


struct MirrorEditorInternalActionProvider {
    typealias READER = () -> String
    typealias ISREADONLY = () -> Bool
    typealias WRITER = (String) -> Bool
    
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
    
    var saveTimer: Timer? = nil
    var lastSaveContent = ""
    
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
        
        // event_editorReady
        self.bridge?.register(handlerName: "event_editorReady") { [weak self] (parameters, callback) in
            self?.isEditorReady = true
            print("event_editorReady : \(String(describing: parameters))")
            self?.eventOnEditorReady()
            callback?(["result":"ok"])
        }
        
        // event_printLog
        self.bridge?.register(handlerName: "event_printLog", handler: { [weak self] (parameters, callback) in
            guard let value = parameters?["value"] as? String else {
                print("editor print log : param invalid")
                callback?(["result": "failed"])
                return
            }
            
            print("editor print log : \(value)")
            callback?(["result": "ok"])
        })
        
        // event_editorSave
        self.bridge?.register(handlerName: "event_editorSave", handler: { [weak self] (parameters, callback) in
            
            guard let value = parameters?["value"] as? String else {
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
            }

            callback?(["result": "ok"])
        })
        
        // Load CodeMirror bundle
        guard let bundlePath = Bundle.main.url(forResource: "MirrorEditor", withExtension: "bundle") else {
            fatalError("MirrorEditor.bundle is missing")
        }
        guard let bundle = Bundle(url: bundlePath) else {
            fatalError("MirrorEditor.bundle is missing")
        }
        guard let indexPath = bundle.path(forResource: "build/index", ofType: "html") else {
            fatalError("MirrorEditor.bundle is missing")
        }
        let baseUrl = bundle.resourceURL!.appendingPathComponent("build")
        
        print("base url = \(baseUrl)")
        var html = try! String(contentsOfFile: indexPath, encoding: .utf8)
        if AppHelper.isdarkmode() {
            html = html.replacingOccurrences(of: "theme:light", with: "theme:dark")
        }
        self.loadHTMLString(html, baseURL: baseUrl)
        
        startAutoSave()
        
        let saveNoti = NotificationCenter.default.publisher(for: MirrorEditorService.saveNotification, object: nil).sink { [weak self] noti in
            self?.saveCurrentContent()
        }
        self.cancellables.append(saveNoti)
    }
    
    deinit {
        print("de-init editor")
        isTearingDown = true
        pendingActions.removeAll()
        self.saveTimer?.invalidate()
        self.saveTimer = nil
        self.stopLoading()
        
        for cancellable in self.cancellables {
            cancellable.cancel()
        }
        self.cancellables.removeAll()
        self.bridge = nil
    }
    
    public override var inputAccessoryView: UIView? {
        return accessoryView
    }
    
    func startAutoSave() {
        self.saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { [weak self] timer in
            self?.saveCurrentContent()
        })
    }
    
    func saveCurrentContent() {
        guard !isTearingDown else {
            return
        }
        editor_getValue { [weak self] (succeed, value) in
            guard let self = self else { return }
            guard !self.isTearingDown else { return }
            if !succeed {
                return
            }
            
            
            if self.lastSaveContent == value {
//                print("content same, already saved")
                return
            }
            
            if let onWrite = self.action?.onWrite {
                let saveSucceed = onWrite(value)
                if !saveSucceed {
                    return
                }
                self.lastSaveContent = value
            }
            
            print("save succeed")
        }
    }
    
    func editor_setValue(value: String) {
        guard !isTearingDown else { return }
        // tell editor
        let message = [
            "value": value
        ]
        self.bridge?.call(handlerName: "editor_setValue", data: message, callback: { responseData in
            print("editor_setValue response : \(String(describing: responseData))")
        })
    }
    
    func editor_insertValue(value: String) {
        guard !isTearingDown else { return }
        // tell editor
        let message = [
            "value": value
        ]
        self.bridge?.call(handlerName: "editor_insertValue", data: message, callback: { responseData in
            print("editor_insertValue response : \(String(describing: responseData))")
        })
    }
    func editor_formatCode() {
        guard !isTearingDown else { return }
        // tell editor
        let message = [
            "value": "format"
        ]
        self.bridge?.call(handlerName: "editor_formatCode", data: message, callback: { responseData in
            print("editor_formatCode response : \(String(describing: responseData))")
        })
    }
    func editor_setReadonly(readonly: Bool) {
        guard !isTearingDown else { return }
        // tell editor
        let message = [
            "readonly": readonly
        ]
        self.bridge?.call(handlerName: "editor_setReadonly", data: message, callback: { responseData in
            print("editor_setReadonly response : \(String(describing: responseData))")
        })
    }
    
    func editor_getValue(callback: @escaping (Bool, String)-> Void){
        guard !isTearingDown else {
            callback(false, "")
            return
        }
        self.bridge?.call(handlerName: "editor_getValue", data: [], callback: { responseData in
            guard let data = responseData as? [String: Any] else {
                callback(false, "")
                return
            }
            
            guard let value = data["value"] as? String else {
                callback(false, "")
                return
            }
            
            callback(true, value)
        })
    }
    
    
    func updateScript() {
        self.runJSAction { [weak self] in
            print("update script : \(String(describing: self))")
            self?.reloadCurrentScript()
        }
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
            let content = onRead()
            
            self.editor_setValue(value: content)
            if let onIsReadOnly = action?.onIsReadOnly {
                self.editor_setReadonly(readonly: onIsReadOnly())
            }else {
                self.editor_setReadonly(readonly: false)
            }
            
            lastSaveContent = content
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
            self.editor_insertValue(value: text)
        }
    }
    
    @objc func onButtonDoneTapped(sender: UIButton) {
        self.resignFirstResponder()
    }
    @objc func onButtonFormatTapped(sender: UIButton) {
        self.editor_formatCode()
    }
}
