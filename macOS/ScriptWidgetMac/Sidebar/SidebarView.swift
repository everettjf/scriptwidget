//
//  SidebarView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/15.
//

import SwiftUI




struct SidebarView: View {
    @ObservedObject var store: SharedAppStore
    // create
    @State private var createShowingSheet = false

    // AI generate
    @State private var aiGenerateShowingSheet = false
    @State private var aiConfigAlertShown = false

    // setup guide
    @State private var widgetGuideShowingSheet = false
    @State private var searchText = ""

    // rename
    @State private var renameCurrentName = ""
    @State private var renameInputName = ""
    @State private var renameShowingSheet = false

    // delete
    @State private var deleteCurrentName = ""
    @State private var deleteShowingSheet = false


    var body: some View {
        content
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            .sheet(isPresented: $renameShowingSheet) {
                RenameConfirmView(currentName: $renameCurrentName, inputName: $renameInputName)
            }
            .sheet(isPresented: $deleteShowingSheet) {
                DeleteConfirmView(currentName: $deleteCurrentName)
            }
            .sheet(isPresented: $createShowingSheet) {
                CreateGuideView()
            }
            .sheet(isPresented: $aiGenerateShowingSheet) {
                AIGenerateWindowView()
            }
            .sheet(isPresented: $widgetGuideShowingSheet) {
                MacWidgetSetupGuideView()
            }
            .onReceive(NotificationCenter.default.publisher(for: AIGenerateWindowView.openRequestNotification)) { _ in
                if AISettingsStore.shared.load().isConfigured {
                    aiGenerateShowingSheet = true
                } else {
                    aiConfigAlertShown = true
                }
            }
            .alert("Configure AI First", isPresented: $aiConfigAlertShown) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("AI generation uses Apple Private Cloud Compute by default. You can add another provider in Settings (⌘,) → AI.")
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button{
                        MacKitUtil.toggleSidebar()
                    } label: {
                        Label("Toggle Sidebar", systemImage: "sidebar.left")
                    }
                    .help("Toggle sidebar")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        self.createShowingSheet.toggle()
                    } label: {
                        Label("New Widget", systemImage: "plus")
                    }
                    .help("New widget from a template")
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            if AISettingsStore.shared.load().isConfigured {
                                aiGenerateShowingSheet = true
                            } else {
                                aiConfigAlertShown = true
                            }
                        } label: {
                            Label("Generate with AI", systemImage: "wand.and.stars")
                        }

                        Button {
                            NotificationCenter.default.post(name: GalleryOpenRequest.notification, object: nil)
                        } label: {
                            Label("Community Gallery", systemImage: "square.grid.2x2")
                        }

                        Divider()

                        Button {
                            widgetGuideShowingSheet = true
                        } label: {
                            Label("Add Widget to Desktop", systemImage: "rectangle.stack.badge.plus")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("More Studio actions")
                }
            }
            .searchable(text: $searchText, prompt: "Search widgets")
    }
    
    @ViewBuilder
    var content: some View {
        List {
            Section("Scripts") {
                if store.scriptModels.isEmpty {
                    EmptyListBackgroundView()
                } else if filteredScriptModels.isEmpty {
                    VStack(alignment: .leading, spacing: StudioDesign.compactSpacing) {
                        Label("No Matches", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                        Text("No widgets match ‘\(searchText)’.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Clear Search") { searchText = "" }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                    .padding(.vertical, StudioDesign.compactSpacing)
                } else {
                    ForEach(filteredScriptModels) { item in
                        NavigationLink(destination: EditorMainView(scriptModel: item)) {
                            WidgetRowView(model: item)
                                .padding(.vertical, 2)
                        }
                        .contextMenu(menuItems: {
                            Button("Reveal in Finder") {
                                MacKitUtil.revealInFinder(item.package.path.path)
                            }
                            Button("Update") {
                                item.package.updateFiles()
                            }
                            Button("Remix (Duplicate)") {
                                let result = sharedScriptManager.duplicateScript(sourcePackageName: item.name)
                                if result.0 {
                                    NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
                                } else {
                                    MacKitUtil.alertWarn(title: "Remix failed", message: result.1)
                                }
                            }
                            Button("Rename") {
                                self.renameCurrentName = item.name
                                self.renameInputName = item.name
                                self.renameShowingSheet.toggle()
                            }
                            Button("Delete") {
                                self.deleteCurrentName = item.name
                                self.deleteShowingSheet.toggle()
                            }
                            
                            Button("Import") {
                                MacKitUtil.selectFile(title: "Import script") { path in
                                    guard let path = path else {
                                        return
                                    }
                                    print("try import path : \(path)")
                                    let result = sharedScriptManager.importScript(fromPath: path)
                                    if result {
                                        MacKitUtil.alertInfo(title: "Import Succeeded", message: "The script was imported.")
                                    } else {
                                        MacKitUtil.alertWarn(title: "Import Failed", message: "Could not import the script. Please check the file and try again.")
                                    }
                                    
                                    NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
                                }
                            }
                            
                            Button("Export") {
                                MacKitUtil.selectDirectory(title: "Export to") { path in
                                    guard let path = path else {
                                        return
                                    }
                                    let exportFilePath = path.appendingPathComponent(item.exportFileName)
                                    let result = sharedScriptManager.exportScript(model: item, toPath: exportFilePath)
                                    if result {
                                        MacKitUtil.alertInfo(title: "Export Succeeded", message: "The script was exported.")
                                    } else {
                                        MacKitUtil.alertWarn(title: "Export Failed", message: "Could not export the script. Please choose another location and try again.")
                                    }
                                }
                            }
                        })
                    }
                }
            }
            Section("Resources") {
                NavigationLink(destination: ResourceCodeView(resourceType: "api")) {
                    Label("APIs", systemImage: "curlybraces")
                }
                NavigationLink(destination: ResourceCodeView(resourceType: "component")) {
                    Label("Components", systemImage: "cube")
                }
                NavigationLink(destination: ResourceCodeView(resourceType: "template")) {
                    Label("Templates", systemImage: "rectangle.stack")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var filteredScriptModels: [ScriptModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.scriptModels }
        return store.scriptModels.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}

#Preview("Sidebar") {
    SidebarView(store: SharedAppStore())
}
