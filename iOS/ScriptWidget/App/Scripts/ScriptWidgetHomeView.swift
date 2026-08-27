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

    private let packages: any ScriptPackageListing
    private var observers: [NSObjectProtocol] = []
    private var reloadGeneration = 0
    
    init(packages: any ScriptPackageListing = DefaultScriptPackageRepository()) {
        self.packages = packages
        reload()
        
        let names = [
            Self.scriptCreateNotification,
            Self.scriptRenameNotification,
            Self.scriptDeleteNotification,
            GalleryInstaller.changedNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        DispatchQueue.global().async { [self] in
            let items = packages.listScripts()
            DispatchQueue.main.async {
                guard generation == self.reloadGeneration else { return }
                self.models = items
            }
        }
    }
}

struct ScriptWidgetHomeView: View {
    @State private var isShowingSettings: Bool = false
    @State private var isShowingCreateGuide: Bool = false
    @State private var isShowingWidgetGuide = false
    @State private var isShowingWebStudio = false
    @State private var searchText = ""

    @StateObject private var dataObject = ScriptWidgetHomeViewDataObject()

    @State private var selectedEditItem: ScriptModel?
    @State private var selectedShareItem: ScriptModel?
    @State private var selectedDeleteItem: ScriptModel?
    @State private var isShowingDeleteAlert = false
    
    var body: some View {
        NavigationSplitView {
            content
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                .fullScreenCover(item: $selectedEditItem, content: { item in
                    EditAttributesView(scriptModel: item) {
                        selectedEditItem = nil
                    }
                })
                .sheet(item: $selectedShareItem, content: { item in
                    // share
                    ActivityViewController(activityItems: sharedScriptManager.exportScriptItemsInTempPath(model: item))
                })
                .alert("Delete Widget?", isPresented: $isShowingDeleteAlert, presenting: selectedDeleteItem) { item in
                    Button("Delete", role: .destructive) {
                        if sharedScriptManager.deleteScript(packageName: item.name) {
                            NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptDeleteNotification, object: nil)
                            selectedDeleteItem = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: { item in
                    Text("“\(item.name)” and its project files will be removed. This can’t be undone.")
                }
                .navigationTitle("Widgets")
                .searchable(text: $searchText, prompt: "Search widgets")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            isShowingSettings = true
                        }) {
                            Label("Settings", systemImage: "gearshape")
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
                            Label("Create", systemImage: "plus")
                                .labelStyle(.iconOnly)
                        }
                        .sheet(isPresented: $isShowingCreateGuide) {
                            CreateGuideView()
                        }
                    }

                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            isShowingWebStudio = true
                        } label: {
                            Label("Web Studio", systemImage: "laptopcomputer.and.iphone")
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
                .fullScreenCover(isPresented: $isShowingWebStudio, onDismiss: {
                    WebStudioServer.shared.stop()
                }) {
                    WebStudioServerView()
                        .overlay(alignment: .topTrailing) {
                            Button("Close", systemImage: "xmark") {
                                isShowingWebStudio = false
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .padding()
                            .accessibilityLabel("Close Web Studio")
                        }
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
            VStack(spacing: StudioDesign.standardSpacing) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: StudioDesign.cardCornerRadius))
                    .accessibilityHidden(true)
                Text("No Results for “\(searchText)”")
                    .font(.headline)
                Text("Try a different widget name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Clear Search") {
                    searchText = ""
                }
                .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioDesign.groupedBackground)
        } else {
            List {
                Section {
                    ForEach(filteredModels) { item in
                        NavigationLink(destination:
                                        ScriptCodeEditorView(mode: .editor, scriptModel: item)
                                        .toolbar(.hidden, for: .tabBar)
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
                    HStack {
                        Text("My Widgets")
                        Spacer()
                        Text("\(filteredModels.count)")
                            .monospacedDigit()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(StudioDesign.groupedBackground)
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

#Preview("Studio") {
    ScriptWidgetHomeView()
}
