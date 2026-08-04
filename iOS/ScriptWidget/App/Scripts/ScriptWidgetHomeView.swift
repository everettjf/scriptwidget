//
//  ScriptWidgetListView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/10.
//

import SwiftUI
import UIKit
import WidgetKit

class ScriptWidgetHomeViewDataObject : ObservableObject {
    public static let scriptCreateNotification = Notification.Name("ScriptWidgetHomeViewDataObjectNewScript")
    public static let scriptRenameNotification = Notification.Name("ScriptWidgetHomeViewDataObjectRenameScript")
    public static let scriptDeleteNotification = Notification.Name("ScriptWidgetHomeViewDataObjectDeleteScript")
    
    @Published var models = [ScriptModel]()
    
    init() {
        reload()
        
        NotificationCenter.default.addObserver(forName: ScriptWidgetHomeViewDataObject.scriptCreateNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
        
        NotificationCenter.default.addObserver(forName: ScriptWidgetHomeViewDataObject.scriptRenameNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
        
        NotificationCenter.default.addObserver(forName: ScriptWidgetHomeViewDataObject.scriptDeleteNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
        
    }
    
    func reload() {
        DispatchQueue.global().async { [self] in
            let items = sharedScriptManager.listScripts()
            DispatchQueue.main.async {
                self.models = items
            }
        }
    }
}

struct ScriptWidgetHomeView: View {
    @State private var isShowingSettings: Bool = false
    @State private var isShowingCreateGuide: Bool = false
    @State private var isShowingWidgetGuide = false
    @State private var searchText = ""

    @StateObject private var dataObject = ScriptWidgetHomeViewDataObject()

    @State private var selectedEditItem: ScriptModel?
    @State private var selectedShareItem: ScriptModel?
    @State private var selectedDeleteItem: ScriptModel?
    @State private var isShowingDeleteAlert = false
    
    var body: some View {
        NavigationSplitView {
            content
                .fullScreenCover(item: $selectedEditItem, content: { item in
                    EditAttributesView(scriptModel: item) {
                        selectedEditItem = nil
                    }
                })
                .sheet(item: $selectedShareItem, content: { item in
                    // share
                    ActivityViewController(activityItems: sharedScriptManager.exportScriptItemsInTempPath(model: item))
                })
                .alert("Confirm Delete : \(selectedDeleteItem?.name ?? "") ? ", isPresented: $isShowingDeleteAlert, presenting: selectedDeleteItem, actions: { item in
                    Button("Delete", role:.destructive ,action: {
                        // real delete
                        if sharedScriptManager.deleteScript(packageName: item.name) {
                            NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptDeleteNotification, object: nil)
                            selectedDeleteItem = nil
                        }
                    })
                    
                })
                .navigationTitle("ScriptWidget")
                .searchable(text: $searchText, prompt: "Search widgets")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            isShowingSettings = true
                        }) {
                            Label("Settings", systemImage: "slider.horizontal.3")
                                .labelStyle(.iconOnly)
                        }
                        .sheet(isPresented: $isShowingSettings) {
                            SettingsView()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            isShowingCreateGuide = true
                        }) {
                            Label("Create", systemImage: "plus.square")
                                .labelStyle(.iconOnly)
                        }
                        .sheet(isPresented: $isShowingCreateGuide) {
                            CreateGuideView()
                        }
                    }

                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            isShowingWidgetGuide = true
                        } label: {
                            Label("Add Widget to Home Screen", systemImage: "rectangle.stack.badge.plus")
                        }
                    }

                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            dataObject.reload()
                            WidgetCenter.shared.reloadAllTimelines()
                        } label: {
                            Label("Refresh Widgets", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .sheet(isPresented: $isShowingWidgetGuide) {
                    WidgetSetupGuideView()
                }
        } detail: {
            HomeHelloView()
        }
    }
    
    @ViewBuilder
    var content: some View {
        if dataObject.models.isEmpty && searchText.isEmpty {
            EmptyListBackgroundView()
        } else if filteredModels.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                Section {
                    ForEach(filteredModels) { item in
                        NavigationLink(destination:
                                        ScriptCodeEditorView(mode: .editor, scriptModel: item)
                                        .toolbarVisibility(.hidden, for: .tabBar)
                        ) {
                            WidgetRowView(model: item)
                        }.swipeActions(allowsFullSwipe: false) {
                            Button {
                                self.selectedShareItem = item
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)

                            Button {
                                self.selectedEditItem = item
                            } label: {
                                Label("Edit", systemImage: "pencil.circle")
                            }
                            .tint(Color(uiColor: .systemIndigo))

                            Button {
                                let result = sharedScriptManager.duplicateScript(sourcePackageName: item.name)
                                if result.0 {
                                    NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptCreateNotification, object: nil)
                                }
                            } label: {
                                Label("Remix", systemImage: "square.on.square")
                            }
                            .tint(.purple)

                            Button(role: .destructive) {
                                self.selectedDeleteItem = item
                                self.isShowingDeleteAlert.toggle()
                            } label: {
                                Label("Delete", systemImage: "trash.fill")
                            }
                        }
                    }
                } header: {
                    Text("\(filteredModels.count) widget\(filteredModels.count == 1 ? "" : "s")")
                }
                .listRowBackground(Color.clear)
            }
            .refreshable {
                dataObject.reload()
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        }
    }

    private var filteredModels: [ScriptModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return dataObject.models }
        return dataObject.models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}

struct ScriptWidgetListView_Previews: PreviewProvider {
    static var previews: some View {
        ScriptWidgetHomeView()
    }
}
