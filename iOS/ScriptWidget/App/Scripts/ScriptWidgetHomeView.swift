//
//  ScriptWidgetListView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/10.
//

import SwiftUI
import UIKit
import SwiftUIX
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
    private var idiom : UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }

    @State private var tabBar: UITabBar? = nil
    
    @State private var isShowingSettings: Bool = false
    @State private var isShowingCreateGuide: Bool = false
    
    @Environment(\.presentationMode) var presentationMode
    
    @ObservedObject var dataObject = ScriptWidgetHomeViewDataObject()
    
    @State var selectedEditItem: ScriptModel?
    @State var selectedShareItem: ScriptModel?
    @State var selectedDeleteItem: ScriptModel?
    @State var isShowingDeleteAlert = false
    
    var body: some View {
        NavigationView {
            content
                .fullScreenCover(item: $selectedEditItem, content: { item in
                    EditAttributesView(scriptModel: item) {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                })
                .sheet(item: $selectedShareItem, content: { item in
                    // share
                    AppActivityView(activityItems: sharedScriptManager.exportScriptItemsInTempPath(model: item))
                })
                .alert("Confirm Delete : \(selectedDeleteItem?.name ?? "") ? ", isPresented: $isShowingDeleteAlert, presenting: selectedDeleteItem, actions: { item in
                    Button("Delete", role:.destructive ,action: {
                        // real delete
                        if sharedScriptManager.deleteScript(packageName: item.name) {
                            NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptDeleteNotification, object: nil)
                            // confirm
                            self.presentationMode.wrappedValue.dismiss()
                        }
                    })
                    
                })
                .navigationTitle("ScriptWidget")
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
                }
            
            HomeHelloView()
        }
        .background(TabBarAccessor { tabbar in   // << here !!
            if idiom != .pad {
                self.tabBar = tabbar
            }
        })
    }
    
    func showTabBar(_ visible: Bool) {
        guard let tabBar = tabBar else {
            return
        }

        if visible {
            tabBar.isHidden = false
        } else {
            tabBar.isHidden = true
        }
    }
    
    @ViewBuilder
    var content: some View {
        if dataObject.models.isEmpty {
            EmptyListBackgroundView()
        } else {
            List {
                ForEach(dataObject.models) { item in
                    NavigationLink(destination:
                                    ScriptCodeEditorView(mode: .editor, scriptModel: item)
                                    .onAppear { showTabBar(false) }     // !!
                                    .onDisappear { showTabBar(true) } // !!
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
                        .tint(.systemIndigo)

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
                .listRowBackground(Color.clear)
            }
            .refreshable {
                dataObject.reload()
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        }
    }
}

struct ScriptWidgetListView_Previews: PreviewProvider {
    static var previews: some View {
        ScriptWidgetHomeView()
    }
}
