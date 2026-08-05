//
//  MirrorEditorView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/3/12.
//

import SwiftUI


struct MirrorEditorScriptView: UIViewRepresentable {
    @Environment(\.presentationMode) var presentationMode
    
    let model: ScriptModel
    let filePath: URL
    
    init(model: ScriptModel, filePath: URL) {
        self.model = model
        self.filePath = filePath
        withUnsafePointer(to: &self) { addr in
            print("MirrorEditorScriptView \(addr) init : \(filePath.lastPathComponent)")
        }
    }
    
    func createActionProvider() -> MirrorEditorInternalActionProvider {
        let provider = MirrorEditorInternalActionProvider(documentID: filePath.standardizedFileURL.path) {
            print("on read : \(self.filePath.lastPathComponent)")
            guard let content = model.package.readFile(fullPath: self.filePath).0 else {
                return ""
            }
            return content
        } onWrite: { content in
            print("on write : \(self.filePath.lastPathComponent)")
            let result = model.package.writeFile(fullPath: self.filePath, content: content)
            if !result.0 {
                print("save failed : write file : \(result.1)")
                return false
            }
            return true
        } onIsReadOnly: {
            
            return model.package.readonly
        }
        return provider
    }
    
    func makeUIView(context: Context) -> MirrorEditorInternalView {
        print("MirrorEditorScriptView make ui view : \(filePath.lastPathComponent)")
        let uiView = MirrorEditorInternalView()
        uiView.updateDocument(action: createActionProvider())
        
        return uiView;
    }
    
    func updateUIView(_ uiView: MirrorEditorInternalView, context: Context) {
        print("MirrorEditorScriptView update ui view: \(filePath.lastPathComponent)")
        uiView.updateDocument(action: createActionProvider())
    }
    
}
