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
            .frame(minWidth:200, maxWidth: 300, idealHeight: 250)
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
                Text("Open Settings (⌘,) → AI to add your OpenAI API key, then come back to generate with AI.")
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button{
                        MacKitUtil.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        if AISettingsStore.shared.load().isConfigured {
                            self.aiGenerateShowingSheet = true
                        } else {
                            self.aiConfigAlertShown = true
                        }
                    } label: {
                        Label("Generate with AI", systemImage: "wand.and.stars")
                    }
                    .help("Generate with AI (⌘⇧N)")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        self.createShowingSheet.toggle()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .help("New widget")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        widgetGuideShowingSheet = true
                    } label: {
                        Label("Add Widget", systemImage: "rectangle.stack.badge.plus")
                    }
                    .help("How to add ScriptWidget to the desktop")
                }
            }
            .searchable(text: $searchText, prompt: "Search widgets")
    }
    
    @ViewBuilder
    var content: some View {
        List {
            Section("Quick Start") {
                Button {
                    createShowingSheet = true
                } label: {
                    Label("New from Template", systemImage: "plus")
                }

                Button {
                    if AISettingsStore.shared.load().isConfigured {
                        aiGenerateShowingSheet = true
                    } else {
                        aiConfigAlertShown = true
                    }
                } label: {
                    Label("Generate with AI", systemImage: "sparkles")
                }

                Button {
                    widgetGuideShowingSheet = true
                } label: {
                    Label("Add Widget to Desktop", systemImage: "rectangle.stack.badge.plus")
                }
            }

            Section("Scripts") {
                if store.scriptModels.isEmpty {
                    EmptyListBackgroundView()
                } else if filteredScriptModels.isEmpty {
                    Text("No widgets match ‘\(searchText)’")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Label("APIs", systemImage: "scribble.variable")
                }
                NavigationLink(destination: ResourceCodeView(resourceType: "component")) {
                    Label("Components", systemImage: "scribble.variable")
                }
                NavigationLink(destination: ResourceCodeView(resourceType: "template")) {
                    Label("Templates", systemImage: "scribble.variable")
                }
            }
        }
    }

    private var filteredScriptModels: [ScriptModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.scriptModels }
        return store.scriptModels.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}

struct SidebarView_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView(store: SharedAppStore())
    }
}
