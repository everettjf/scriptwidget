//
//  EditorPanelView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/4.
//

import SwiftUI

struct EditorPanelTabLabel: View {
    let imageName: String
    let label: String
    
    var body: some View {
        HStack {
            Image(systemName: imageName)
            Text(label)
        }
    }
}



struct EditorPanelView: View {
    let scriptModel: ScriptModel
    let configuration: StudioWidgetConfiguration
    
    var body: some View {
        TabView {
            VStack {
                PreviewView(scriptModel: scriptModel, configuration: configuration)
            }
            .tabItem({ EditorPanelTabLabel(imageName: "play.rectangle", label: "Preview") })
            
            VStack {
                ImageListView(scriptModel: scriptModel)
            }
            .tabItem({ EditorPanelTabLabel(imageName: "photo.on.rectangle", label: "Images") })
            
            WidgetConfigurationView(scriptModel: scriptModel, configuration: configuration)
                .tabItem({ EditorPanelTabLabel(imageName: "slider.horizontal.3", label: "Config") })

            StudioCopilotView(scriptModel: scriptModel)
                .tabItem({ EditorPanelTabLabel(imageName: "sparkles", label: "Copilot") })
        }
        .padding(.top, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct StudioCopilotView: View {
    let scriptModel: ScriptModel

    @StateObject private var session = AIGenerateSession()
    @State private var instruction = ""
    @State private var originalCode = ""
    @State private var proposedCode = ""
    @State private var statusMessage: String?
    @State private var showingOriginal = false
    @State private var showingProposal = true
    @State private var selectedSkillIDs: Set<String> = []

    private var changeSummary: AICopilotChangeSummary {
        .compare(original: originalCode, proposed: proposedCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("AI Copilot", systemImage: "sparkles")
                        .font(.headline)

                    Text("Ask Studio to improve the current widget. Changes are validated locally and shown for review before they are applied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $instruction)
                        .font(.body)
                        .frame(minHeight: 90)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(AIWidgetSkills.all) { skill in
                                Toggle(isOn: skillBinding(skill.id)) {
                                    Label(skill.title, systemImage: skill.symbol)
                                        .font(.caption)
                                }
                                .toggleStyle(.button)
                                .controlSize(.small)
                                .help(skill.summary)
                            }
                        }
                    }

                    HStack {
                        Button("Propose Change", systemImage: "wand.and.stars") {
                            beginCopilotRequest(fixCurrentError: false)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Fix Runtime Error", systemImage: "wrench.and.screwdriver") {
                            beginCopilotRequest(fixCurrentError: true)
                        }
                    }
                    .disabled(session.isRunning || scriptModel.package.readonly)

                    if session.isRunning {
                        AIGenerateProgressView(session: session)
                        Button("Cancel", role: .cancel) { session.cancel() }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !proposedCode.isEmpty {
                        Divider()
                        proposalReview
                    }
                }
                .padding(12)
            }
        }
        .onChange(of: session.phase) { _, phase in
            consume(phase: phase)
        }
    }

    private var proposalReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review Proposal").font(.headline)
                Spacer()
                Text("\(changeSummary.changedLines) changed lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Original · \(changeSummary.originalLines) lines", isExpanded: $showingOriginal) {
                codeBlock(originalCode)
            }
            DisclosureGroup("Proposed · \(changeSummary.proposedLines) lines", isExpanded: $showingProposal) {
                codeBlock(proposedCode)
            }

            HStack {
                Button("Reject", role: .destructive) {
                    proposedCode = ""
                    statusMessage = "Proposal rejected; the editor was not changed."
                }
                Spacer()
                Button("Apply to Editor", systemImage: "checkmark") {
                    EditorService.replaceDocument(with: proposedCode)
                    originalCode = proposedCode
                    proposedCode = ""
                    statusMessage = "Applied and saved. Use editor Undo to restore the previous version."
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 180)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
    }

    private func beginCopilotRequest(fixCurrentError: Bool) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = PreviewDiagnosticStore.shared.diagnostic(
            for: scriptModel.package.path.standardizedFileURL.path
        )
        let requestText: String
        if fixCurrentError {
            requestText = trimmed.isEmpty ? "Fix the current runtime error while preserving the widget design." : trimmed
        } else {
            guard !trimmed.isEmpty else {
                statusMessage = "Describe the change you want first."
                return
            }
            requestText = trimmed
        }

        EditorService.requestSnapshot { snapshot in
            guard let snapshot else {
                statusMessage = "The editor is not ready yet."
                return
            }
            originalCode = snapshot.content
            proposedCode = ""
            statusMessage = diagnostic == nil && fixCurrentError
                ? "No current runtime error was recorded; asking AI to inspect the code."
                : nil
            session.copilot(
                currentCode: snapshot.content,
                instruction: AIWidgetSkills.augment(requestText, selectedIDs: selectedSkillIDs),
                runtimeDiagnostic: diagnostic
            )
        }
    }

    private func consume(phase: AIGenerateSession.Phase) {
        switch phase {
        case .done(let jsx):
            proposedCode = jsx
            statusMessage = "Proposal passed the local ScriptWidget runtime."
        case .exhausted(let lastJSX, let error):
            proposedCode = lastJSX ?? ""
            statusMessage = "The AI reached its iteration limit: \(error ?? "unknown runtime error")"
        case .failed(let message):
            statusMessage = message
        case .cancelled:
            statusMessage = "Request cancelled."
        default:
            break
        }
    }

    private func skillBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedSkillIDs.contains(id) },
            set: { enabled in
                if enabled { selectedSkillIDs.insert(id) }
                else { selectedSkillIDs.remove(id) }
            }
        )
    }
}

struct EditorPanelView_Previews: PreviewProvider {
    static var previews: some View {
        EditorPanelView(
            scriptModel: globalScriptModel,
            configuration: StudioWidgetConfiguration()
        )
    }
}

private struct WidgetConfigurationView: View {
    let scriptModel: ScriptModel
    @Bindable var configuration: StudioWidgetConfiguration

    var body: some View {
        Form {
            Section("Preview") {
                Picker("Family", selection: $configuration.family) {
                    ForEach(StudioPreviewFamily.allCases) { family in
                        Text(family.title).tag(family)
                    }
                }
                Picker("Canvas", selection: $configuration.canvasMode) {
                    ForEach(StudioPreviewCanvasMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Runtime debug output", isOn: $configuration.debugMode)
                TextField("Widget parameter", text: $configuration.parameter)
            }

            Section("Project") {
                LabeledContent("Package", value: scriptModel.name)
                LabeledContent("Entry point", value: "main.jsx")
                LabeledContent("Location", value: scriptModel.package.path.path)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("Reveal in Finder", systemImage: "finder") {
                    MacKitUtil.revealInFinder(scriptModel.package.path.path)
                }
            }

            Section {
                Text("Package metadata, permissions, supported families, and network domains will be saved in widget.json during Package 2.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
