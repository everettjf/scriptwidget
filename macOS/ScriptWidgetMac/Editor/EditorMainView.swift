//
//  EditorView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/15.
//

import SwiftUI

struct EditorMainView: View {
    
    @SceneStorage("editorPanelLayoutMode") private var panelLayoutModeVertical = true
    
    let scriptModel: ScriptModel
    
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
    }
    
    var body: some View {
        content
            .navigationTitle(scriptModel.name)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        panelLayoutModeVertical.toggle()
                    }) {
                        Label(
                            panelLayoutModeVertical ? "Stack Vertically" : "Place Side by Side",
                            systemImage: panelLayoutModeVertical ? "rectangle.split.2x1" : "rectangle.split.1x2"
                        )
                    }
                    .help(panelLayoutModeVertical ? "Place preview below editor" : "Place preview beside editor")
                }
                
                ToolbarItem(placement: .automatic) {
                    ButtonOfficalSite()
                }
            }
    }
    
    var content: some View {
        VStack(spacing: 0) {
            EditorWorkspaceHeader(scriptModel: scriptModel)
            Divider()

            Group {
                if panelLayoutModeVertical {
                    HSplitView {
                        EditorWebView(scriptModel: scriptModel)
                            .frame(idealWidth: 640)

                        EditorPanelView(scriptModel: scriptModel)
                            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                    }
                } else {
                    VSplitView {
                        EditorWebView(scriptModel: scriptModel)
                            .frame(idealHeight: 620)

                        EditorPanelView(scriptModel: scriptModel)
                            .frame(minHeight: 280, idealHeight: 380)
                    }
                }
            }
        }
    }
}

private struct EditorWorkspaceHeader: View {
    let scriptModel: ScriptModel

    var body: some View {
        HStack(spacing: 10) {
            NameAutoImageView(
                name: scriptModel.name,
                colors: getGradientColorsWithString(string: scriptModel.name),
                size: 30
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(scriptModel.name)
                    .font(.headline)
                Label("Saved automatically", systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("⌘R Preview")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        EditorMainView(scriptModel: globalScriptModel)
    }
}
