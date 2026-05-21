//
//  FileDetailView.swift
//  ScriptWidget
//
//  Created by gipyzarc on 2022/4/7.
//

import SwiftUI

struct FileDetailView: View {
    @Environment(\.presentationMode) var presentationMode

    let scriptModel: ScriptModel
    let fileModel: FileModel
    
    @State private var isShowingDeleteAlert = false
    @State private var isShowingRenameSheet = false
    
    @State private var onFileRenamed = false
    
    func isSupportEdit() -> Bool {
        if fileModel.name == "main.jsx" {
            return false
        }
        
        let ext = fileModel.path.pathExtension.lowercased()
        let supports = ["js", "json", "txt", "conf", "jsx", "ts", "tsx"]
        for item in supports {
            if ext == item {
                return true
            }
        }
        return false
    }
    
    var body: some View {
        VStack {
            if isSupportEdit() {
                MirrorEditorScriptView(model: scriptModel, filePath: fileModel.path)
            } else {
                Text("\(fileModel.relativePath)")
            }
        }
        
        // delete
        .alert("Delete ?", isPresented: $isShowingDeleteAlert, actions: {
            Button("Delete", role:.destructive ,action: {
                // real delete
                print("delete")
                if fileModel.name == "main.jsx" {
                    return
                }
                
                scriptModel.package.deleteFile(relativePath: fileModel.relativePath)
                
                presentationMode.dismiss()
            })
        })
        
        // rename
        .sheet(isPresented: $isShowingRenameSheet, content: {
            FileRenameView(scriptModel: scriptModel, fileModel: fileModel, onFileRenamed: $onFileRenamed)
        })
        
        // on file renamed
        .onChange(of: onFileRenamed) { _, value in
            print("on file renamed : \(value)")
            if value {
                presentationMode.dismiss()
            }
        }
        
        .navigationBarItems(
            trailing: HStack {
                if fileModel.name != "main.jsx" {
                    
                    Button(role: .destructive) {
                        isShowingDeleteAlert.toggle()
                    } label: {
                        Label("Delete", systemImage: "trash.fill")
                    }
                    
                    Button(role: .destructive) {
                        isShowingRenameSheet.toggle()
                    } label: {
                        Label("Edit", systemImage: "pencil.circle")
                    }
                    .tint(.systemIndigo)
                }
            }
        )
        .navigationTitle(fileModel.relativePath)
    }
}
