//
//  FileCreateView.swift
//  ScriptWidget
//
//  Created by gipyzarc on 2022/4/8.
//

import SwiftUI

struct FileCreateView: View {
    let scriptModel: ScriptModel
    @Environment(\.dismiss) private var dismiss

    @State private var inputFileName = "config.json";
    @State private var message = ""
    
    var body: some View {
        Form {
            Text("File Name:")
                .font(.body)
            TextField("e.g. config.json", text: $inputFileName)
                .font(.headline)
                .textInputAutocapitalization(.never)
            
            Text(message)
                .font(.body)
                .foregroundColor(.blue)
            
            HStack {
                Spacer()
                
                Button {
                    createFile()
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Create")
                            .bold()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle("Create File")
    }
    
    
    func createFile() {
        let fileName = inputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty {
            message = "File name can not be empty"
            return
        }
        
        if scriptModel.package.isFileExist(relativePath: fileName) {
            message = "File existed"
            return
        }
        
        let result = scriptModel.package.writeFile(relativePath: fileName, content: "")
        if result.0 {
            message = "succeed"
            dismiss()
        } else {
            message = ("failed create : \(result.1)")
        }
    }
}

struct FileCreateView_Previews: PreviewProvider {
    static var previews: some View {
        FileCreateView(scriptModel: globalScriptModel)
    }
}
