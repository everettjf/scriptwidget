//
//  FileRenameView.swift
//  ScriptWidget
//
//  Created by gipyzarc on 2022/4/8.
//

import SwiftUI

struct FileRenameView: View {
    let scriptModel: ScriptModel
    let fileModel: FileModel
    @Environment(\.dismiss) private var dismiss

    @State private var inputFileName = "";
    @State private var message = ""
    
    @Binding var onFileRenamed: Bool
    
    init(scriptModel: ScriptModel, fileModel: FileModel, onFileRenamed: Binding<Bool>) {
        _onFileRenamed = onFileRenamed
        self.scriptModel = scriptModel
        self.fileModel = fileModel
    }
    
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text("Rename").font(.title3)
                Spacer()
            }
            if fileModel.name == "main.jsx" {
                Text("main.jsx do not support rename")
            } else {
                Form {
                    Text("Current File Name:")
                        .font(.body)
                    Text(fileModel.relativePath)
                        .font(.body)
                        .bold()
                    
                    Text("New File Name:")
                        .font(.body)
                    TextField("e.g. new-name.json", text: $inputFileName)
                        .font(.headline)
                        .textInputAutocapitalization(.never)
                    
                    Text(message)
                        .font(.body)
                        .foregroundColor(.blue)
                    
                    HStack {
                        Spacer()
                        
                        Button {
                            rename()
                        } label: {
                            HStack {
                                Image(systemName: "plus")
                                Text("Rename")
                                    .bold()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Rename File")
    }
    
    
    func rename() {
        let fileName = inputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty {
            message = "File name can not be empty"
            return
        }
        
        if scriptModel.package.isFileExist(relativePath: fileName) {
            message = "File existed"
            return
        }
        
        let result = scriptModel.package.renameFile(relativePath: fileModel.relativePath, destRelativePath: fileName)
        if result.0 {
            message = "succeed"
            dismiss()
            onFileRenamed.toggle()
        } else {
            message = ("failed rename : \(result.1)")
        }
    }
}

struct FileRenameView_Previews: PreviewProvider {
    static var previews: some View {
        FileRenameView(scriptModel: globalScriptModel, fileModel: globalFileModel, onFileRenamed: .constant(false))
    }
}
