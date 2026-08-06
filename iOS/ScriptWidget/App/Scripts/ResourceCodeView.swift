//
//  ResourceCodeView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/1/29.
//

import SwiftUI

struct ResourceCodeView: View {
    
    @Environment(\.dismiss) private var dismiss

    let model: ScriptModel
    
    
    init(model: ScriptModel) {
        self.model = model
        
        self.model.package.updateImages()
    }
    
    var body: some View {
        content
    }
    
    var content: some View {
        NavigationStack {
            List {
                Section("Package") {
                    NavigationLink(destination: ImageListView(model: model)) {
                        Label("Images", systemImage: "photo.on.rectangle")
                    }
                    NavigationLink(destination: FileListView(model: model)) {
                        Label("Files", systemImage: "doc.on.doc")
                    }
                }
                Section("Reference") {
                    NavigationLink(destination: SettingComponentsView()) {
                        Label("Components", systemImage: "cube")
                    }
                    NavigationLink(destination: SettingAPIsView()) {
                        Label("APIs", systemImage: "curlybraces")
                    }
                    NavigationLink(destination: SettingTemplatesView()) {
                        Label("Templates", systemImage: "rectangle.stack")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Resources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ResourceCodeView_Previews: PreviewProvider {
    static var previews: some View {
        ResourceCodeView(model: globalScriptModel)
            .preferredColorScheme(.dark)
            .previewDevice("iPhone 12 Pro")
        
    }
}
