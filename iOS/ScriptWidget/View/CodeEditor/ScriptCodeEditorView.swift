//
//  ScriptCodeEditorView.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/24.
//

import SwiftUI

enum ScriptCodeEditorViewMode {
    case creator
    case editor
}

struct ScriptCodeEditorNavButtonView: View {
    let image: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.title3)
        }
    }
}


class ScriptCodeEditorViewDataObject : ObservableObject {
    
    @Published var scriptModel: ScriptModel
    @Published var filePath: URL
    private var renameObserver: NSObjectProtocol?
    
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        self.filePath = scriptModel.package.jsxPath
        
        renameObserver = NotificationCenter.default.addObserver(forName: ScriptWidgetHomeViewDataObject.scriptRenameNotification, object: nil, queue: OperationQueue.main) { [weak self] noti in
            
            guard let newName = noti.userInfo?["newName"] as? String else { return }
            
            self?.scriptModel = ScriptModel(package:sharedScriptManager.getScriptPackage(packageName: newName))
        }
    }

    deinit {
        if let renameObserver {
            NotificationCenter.default.removeObserver(renameObserver)
        }
    }
}

struct ScriptCodeEditorView: View {
    @StateObject private var dataObject: ScriptCodeEditorViewDataObject
    let mode: ScriptCodeEditorViewMode
    let actionCreate: (() -> Void)?
    
    @State private var showRunnerView = false
    @State private var showResourceCodeView = false
    
    @State private var showingAlert = false
    @State private var alertMessage = ""

    
    init(mode: ScriptCodeEditorViewMode, scriptModel: ScriptModel) {
        self.mode = mode
        _dataObject = StateObject(wrappedValue: ScriptCodeEditorViewDataObject(scriptModel: scriptModel))
        self.actionCreate = nil
    }
    
    init(mode: ScriptCodeEditorViewMode, scriptModel: ScriptModel, actionCreate: @escaping () -> Void) {
        self.mode = mode
        _dataObject = StateObject(wrappedValue: ScriptCodeEditorViewDataObject(scriptModel: scriptModel))
        self.actionCreate = actionCreate
    }
    
    var codeeditor: some View {
        ScriptPackageEditorView(model: dataObject.scriptModel, filePath: $dataObject.filePath)
            .onDisappear {
                NotificationCenter.default.post(name: MirrorEditorService.saveNotification, object: nil)
            }
    }
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
    
    var body: some View {
        VStack {
            codeeditor
                .navigationTitle(self.dataObject.scriptModel.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        leadingButtons
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        trailingButtons
                    }
                }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .alert("Notification", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    var leadingButtons: some View {
        HStack {
            if self.mode != .creator  {
                ScriptCodeEditorNavButtonView(image: "book") {
                    self.showResourceCodeView.toggle()
                }
                .sheet(isPresented: $showResourceCodeView, content: {
                    ResourceCodeView(model: dataObject.scriptModel)
                })
            }
        }
    }
    
    var previewView: some View {
        ScriptCodePreviewView(model: dataObject.scriptModel, filePath: $dataObject.filePath)
    }
    
    var trailingButtons: some View {
        HStack {
            if #available(iOS 16.1, *) {
                ScriptCodeEditorNavButtonView(image: "lock") {
                    
                    // build
                    let buildResult = sharedScriptManager.buildScriptPackage(package: self.dataObject.scriptModel.package)
                    print("build result = \(buildResult)")
                    
                    // show lock screen widget
                    sharedLiveActivityManager.create(scriptName: self.dataObject.scriptModel.name, scriptParameter: "")
                    showAlert("Lock screen live activity created :)")
                }
            }
            
            ScriptCodeEditorNavButtonView(image: "play") {
                self.showRunnerView.toggle()
            }
            .sheet(isPresented: $showRunnerView, content: {
                previewView
            })
            
            if self.mode == .creator {
                ScriptCodeEditorNavButtonView(image: "plus.square") {
                    print("create tapped")
                    
                    DispatchQueue.main.async {
                        if let action = self.actionCreate {
                            action()
                        }
                    }
                }
            }
        }
    }
}

struct ScriptCodeEditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ScriptCodeEditorView(mode: .editor, scriptModel: globalScriptModel)
        }
    }
}
