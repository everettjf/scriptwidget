//
//  WebView.swift
//  MineFolder
//
//  Created by everettjf on 2021/4/21.
//

import SwiftUI
import WebKit
import Combine


class EditorService {
    public static let saveNotification = Notification.Name("EditorService_SaveNotification")
}

class EditorInternalWebView: WKWebView {
    
    var bridge: WKWebViewJavascriptBridge?
    var scriptModel: ScriptModel?
    var isEditorReady = false
    var pendingActions: [() -> Void] = []
    var cancellables = [Cancellable]()

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: kEditorURLScheme)
        super.init(frame: .zero, configuration: config)

        self.setValue(false, forKey: "drawsBackground")
        
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
            guard let script = self?.scriptModel else {
                print("save failed : model invalid")
                callback?(["result": "failed"])
                return
            }
            
            let result = script.package.writeMainFile(content: value)
            if !result.0 {
                print("save failed : write file : \(result.1)")
                callback?(["result": "failed"])
                return
            }
            
            print("timer save succeed")
            print("----BEGIN SAVE CONTENT----")
            print(value)
            print("----END SAVE CONTENT----")
            
            callback?(["result": "ok"])
        })
        
        
        let cancellableSave = NotificationCenter.default.publisher(for: EditorService.saveNotification)
            .sink { [weak self] (notification) in
                // save
                DispatchQueue.main.async {
                    self?.saveCurrentContent()
                }
            }
        self.cancellables.append(cancellableSave)
        
    }
    
    deinit {
        for cancellable in self.cancellables {
            cancellable.cancel()
        }
    }
    
    func saveCurrentContent() {
        editor_getValue { (succeed, value) in
            if !succeed {
                return
            }
            
            // save
            guard let script = self.scriptModel else {
                print("save failed : model invalid")
                return
            }
            
            let result = script.package.writeMainFile(content: value)
            if !result.0 {
                print("save failed : write file : \(result.1)")
                return
            }
            print("cmd+s save succeed")
            print("----BEGIN SAVE CONTENT----")
            print(value)
            print("----END SAVE CONTENT----")
        }
    }
    
    func editor_setValue(value: String) {
        // tell editor
        let message = [
            "value": value
        ]
        self.bridge?.call(handlerName: "editor_setValue", data: message, callback: { responseData in
            print("editor_setValue response : \(String(describing: responseData))")
        })
    }
    func editor_setReadonly(readonly: Bool) {
        // tell editor
        let message = [
            "readonly": readonly
        ]
        self.bridge?.call(handlerName: "editor_setReadonly", data: message, callback: { responseData in
            print("editor_setReadonly response : \(String(describing: responseData))")
        })
    }
    
    func editor_getValue(callback: @escaping (Bool, String)-> Void){
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
    
    
    func updateScript(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        
        self.runJSAction {
            self.reloadCurrentScript()
        }
    }
    
    
    func runJSAction(_ action:@escaping () -> Void) {
        DispatchQueue.main.async {
            self.pendingActions.append(action)
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
        guard let model = self.scriptModel else { return }
        let (mainContent, error) = model.package.readMainFile()
        guard let content = mainContent else { return }
        self.editor_setValue(value: content)
        self.editor_setReadonly(readonly: model.package.readonly)
    }
    
}



struct EditorWebView: NSViewRepresentable {
    
    let scriptModel: ScriptModel

    func makeNSView(context: Context) -> EditorInternalWebView {
        let webView = EditorInternalWebView()
        
        return webView
    }

    func updateNSView(_ view: EditorInternalWebView, context: Context) {
        let url = editorWebServiceUrl()
        let request = URLRequest(url: URL(string: url)!)
        view.load(request)

        view.updateScript(scriptModel: scriptModel)
    }
}

struct EditorWebView_Previews: PreviewProvider {
    static var previews: some View {
        EditorWebView(scriptModel: globalScriptModel)
    }
}
