//
//  FileListView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/19.
//

import SwiftUI


class FileListDataObject: ObservableObject {
    @Published var files: [FileModel] = []
    
    let scriptModel: ScriptModel
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        
        self.reload()
        self.addObserver()
    }
    
    func reload() {
        scriptModel.package.updateFiles()
        self.files = scriptModel.package.listFiles()
    }
    
    
    func addObserver() {
        NotificationCenter.default.addObserver(forName: ImageDataObject.refreshNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
    }
}

struct FileListView: View {
    @StateObject private var data: FileListDataObject
    
    init(scriptModel: ScriptModel) {
        _data = StateObject(wrappedValue: FileListDataObject(scriptModel: scriptModel))
    }
    
    var body: some View {
        List {
            if data.files.isEmpty {
                Label("No additional files", systemImage: "doc")
                    .foregroundStyle(.secondary)
            }
            ForEach(data.files) { file in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).fontWeight(.medium)
                        Text(file.relativePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.tint)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
        .refreshable {
            self.data.reload()
        }
    }
}

struct FileListView_Previews: PreviewProvider {
    static var previews: some View {
        FileListView(scriptModel: globalScriptModel)
    }
}
