//
//  ResourceCodeView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/29.
//

import SwiftUI
class ResourceCodeStore : ObservableObject {
    
    @Published var apiModels = [ScriptModel]()
    @Published var componentModels = [ScriptModel]()
    @Published var templateModels = [ScriptModel]()
    
    
    init() {
        reloadBundleScripts()
    }
    
    func reloadBundleScripts() {
        
        DispatchQueue.global().async { [self] in
            let items = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "api")
            DispatchQueue.main.async {
                self.apiModels = items
            }
        }
        DispatchQueue.global().async { [self] in
            let items = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "component")
            DispatchQueue.main.async {
                self.componentModels = items
            }
        }
        DispatchQueue.global().async { [self] in
            let items = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "template")
            DispatchQueue.main.async {
                self.templateModels = items
            }
        }
    }
}

struct ResourceCodeNavigationLink: View {
    
    let item: ScriptModel
    
    var body: some View {
        NavigationLink(destination: EditorMainView(scriptModel: item)) {
            WidgetRowView(model: item)
                .padding(.vertical, 2)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                MacKitUtil.revealInFinder(item.package.path.path)
            }
        }
    }

}


struct ResourceCodeListView : View {
    
    let resourceType: String
    @ObservedObject var store: ResourceCodeStore
    
    var body: some View {
        List {
            ForEach(models) { item in
                ResourceCodeNavigationLink(item: item)
            }
        }
        .navigationTitle(title)
        .listStyle(.inset)
    }

    private var models: [ScriptModel] {
        switch resourceType {
        case "api": return store.apiModels
        case "component": return store.componentModels
        case "template": return store.templateModels
        default: return []
        }
    }

    private var title: String {
        switch resourceType {
        case "api": return "APIs"
        case "component": return "Components"
        case "template": return "Templates"
        default: return "Resources"
        }
    }
}

struct ResourceCodeView: View {
    let resourceType: String
    @StateObject private var store = ResourceCodeStore()
    
    var body: some View {
        ResourceCodeListView(resourceType: resourceType, store: store)
    }
}

struct ResourceCodeView_Previews: PreviewProvider {
    static var previews: some View {
        ResourceCodeView(resourceType: "api")
    }
}
