//
//  FileListView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/2/12.
//

import SwiftUI


class FileListDataObject: ObservableObject {
    @Published var files: [FileModel] = []
    
    let model: ScriptModel
    init(model: ScriptModel) {
        self.model = model
        
        self.reload()
    }
    
    func reload() {
        model.package.updateFiles()
        self.files = model.package.listFiles()
    }
}


struct FileListRowView: View {
    
    let scriptModel: ScriptModel
    let fileModel: FileModel
    
    var body: some View {
        NavigationLink(destination: FileDetailView(scriptModel: scriptModel, fileModel: fileModel)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileModel.name)
                        .fontWeight(.medium)
                    Text(fileModel.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "doc.text")
                    .foregroundStyle(.tint)
            }
        }
    }
}

struct FileListView: View {
    @StateObject private var data: FileListDataObject
    
    
    init(model: ScriptModel) {
        _data = StateObject(wrappedValue: FileListDataObject(model: model))
    }
    
    var body: some View {
        List {
            Section("Package Files") {
                if data.files.isEmpty {
                    Label("No additional files", systemImage: "doc")
                        .foregroundStyle(.secondary)
                }
                ForEach(data.files) { file in
                    FileListRowView(
                        scriptModel: data.model,
                        fileModel: file
                    )
                }
            }
        }
        .onAppear(perform: {
            self.data.reload()
        })
        .listStyle(.insetGrouped)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: FileCreateView(scriptModel: data.model)) {
                    Label("New File", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

struct FileListView_Previews: PreviewProvider {
    static var previews: some View {
        FileListView(model: globalScriptModel)
    }
}
