//
//  ScriptCodeEditorView.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/24.
//

import SwiftUI

enum ScriptCodeEditorViewMode {
    case creator
    case editor
}

struct ScriptCodeEditorNavButtonView: View {
    let image: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.title3)
        }
    }
}


class ScriptCodeEditorViewDataObject : ObservableObject {
    
    @Published var scriptModel: ScriptModel
    @Published var filePath: URL
    private var renameObserver: NSObjectProtocol?
    
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        self.filePath = scriptModel.package.jsxPath
        
        renameObserver = NotificationCenter.default.addObserver(forName: ScriptWidgetHomeViewDataObject.scriptRenameNotification, object: nil, queue: OperationQueue.main) { [weak self] noti in
            
            guard let newName = noti.userInfo?["newName"] as? String else { return }
            
            self?.scriptModel = ScriptModel(package:sharedScriptManager.getScriptPackage(packageName: newName))
        }
    }

    deinit {
        if let renameObserver {
            NotificationCenter.default.removeObserver(renameObserver)
        }
    }
}

struct ScriptCodeEditorView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var dataObject: ScriptCodeEditorViewDataObject
    let mode: ScriptCodeEditorViewMode
    let actionCreate: (() -> Void)?
    
    @State private var showRunnerView = false
    @State private var showResourceCodeView = false
    @State private var showCopilotView = false
    
    @State private var showingAlert = false
    @State private var alertMessage = ""

    
    init(mode: ScriptCodeEditorViewMode, scriptModel: ScriptModel) {
        self.mode = mode
        _dataObject = StateObject(wrappedValue: ScriptCodeEditorViewDataObject(scriptModel: scriptModel))
        self.actionCreate = nil
    }
    
    init(mode: ScriptCodeEditorViewMode, scriptModel: ScriptModel, actionCreate: @escaping () -> Void) {
        self.mode = mode
        _dataObject = StateObject(wrappedValue: ScriptCodeEditorViewDataObject(scriptModel: scriptModel))
        self.actionCreate = actionCreate
    }
    
    var codeeditor: some View {
        ScriptPackageEditorView(model: dataObject.scriptModel, filePath: $dataObject.filePath)
            .onDisappear {
                NotificationCenter.default.post(name: MirrorEditorService.saveNotification, object: nil)
            }
    }
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
    
    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        codeeditor
                            .frame(width: max(420, proxy.size.width * 0.56))
                        Divider()
                        ScriptCodeStudioPanelView(
                            scriptModel: dataObject.scriptModel,
                            filePath: $dataObject.filePath
                        )
                    }
                }
            } else {
                codeeditor
            }
        }
                .navigationTitle(self.dataObject.scriptModel.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        leadingButtons
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        trailingButtons
                    }
                }
        .ignoresSafeArea(.all, edges: .bottom)
        .alert("Notification", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showCopilotView) {
            NavigationStack {
                ScriptCodeCopilotView(scriptModel: dataObject.scriptModel)
                    .navigationTitle("AI Copilot")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showCopilotView = false }
                        }
                    }
            }
        }
    }
    
    var leadingButtons: some View {
        HStack {
            if self.mode != .creator  {
                ScriptCodeEditorNavButtonView(image: "book") {
                    self.showResourceCodeView.toggle()
                }
                .sheet(isPresented: $showResourceCodeView, content: {
                    ResourceCodeView(model: dataObject.scriptModel)
                })
            }
        }
    }
    
    var previewView: some View {
        ScriptCodePreviewView(model: dataObject.scriptModel, filePath: $dataObject.filePath)
    }
    
    var trailingButtons: some View {
        HStack {
            if #available(iOS 16.1, *) {
                ScriptCodeEditorNavButtonView(image: "lock") {
                    
                    // build
                    let buildResult = sharedScriptManager.buildScriptPackage(package: self.dataObject.scriptModel.package)
                    print("build result = \(buildResult)")
                    
                    // show lock screen widget
                    sharedLiveActivityManager.create(scriptName: self.dataObject.scriptModel.name, scriptParameter: "")
                    showAlert("Lock screen live activity created :)")
                }
            }
            
            ScriptCodeEditorNavButtonView(image: "play") {
                self.showRunnerView.toggle()
            }
            .keyboardShortcut("r", modifiers: .command)
            .sheet(isPresented: $showRunnerView, content: {
                previewView
            })

            if horizontalSizeClass != .regular {
                ScriptCodeEditorNavButtonView(image: "sparkles") {
                    showCopilotView = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            Button {
                NotificationCenter.default.post(name: MirrorEditorService.saveNotification, object: nil)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityLabel("Save widget")
            
            if self.mode == .creator {
                ScriptCodeEditorNavButtonView(image: "plus.square") {
                    print("create tapped")
                    
                    DispatchQueue.main.async {
                        if let action = self.actionCreate {
                            action()
                        }
                    }
                }
            }
        }
    }
}

private struct ScriptCodeStudioPanelView: View {
    let scriptModel: ScriptModel
    @Binding var filePath: URL
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Studio panel", selection: $selectedTab) {
                Label("Preview", systemImage: "play.rectangle").tag(0)
                Label("Copilot", systemImage: "sparkles").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if selectedTab == 0 {
                ScriptCodePreviewView(model: scriptModel, filePath: $filePath, showsCloseButton: false)
            } else {
                ScriptCodeCopilotView(scriptModel: scriptModel)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct ScriptCodeCopilotView: View {
    let scriptModel: ScriptModel

    @StateObject private var session = AIGenerateSession()
    @State private var instruction = ""
    @State private var originalCode = ""
    @State private var proposedCode = ""
    @State private var statusMessage: String?
    @State private var selectedSkillIDs: Set<String> = []
    @State private var showingOriginal = false
    @State private var showingProposal = true

    private var changeSummary: AICopilotChangeSummary {
        .compare(original: originalCode, proposed: proposedCode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ask Studio for a focused change. The current code and latest runtime diagnostic are included, then the proposal is validated locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $instruction)
                    .frame(minHeight: 100)
                    .padding(4)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Copilot instruction")

                Text("Skills")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], alignment: .leading, spacing: 8) {
                    ForEach(AIWidgetSkills.all) { skill in
                        Toggle(isOn: skillBinding(skill.id)) {
                            Label(skill.title, systemImage: skill.symbol)
                                .font(.caption)
                        }
                        .toggleStyle(.button)
                        .accessibilityHint(skill.summary)
                    }
                }

                HStack {
                    Button("Propose Change", systemImage: "wand.and.stars") {
                        beginCopilotRequest(fixCurrentError: false)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Fix Error", systemImage: "wrench.and.screwdriver") {
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
                    proposalReview
                }
            }
            .padding()
        }
        .onReceive(session.$phase) { phase in
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
                Button("Apply", systemImage: "checkmark") {
                    MirrorEditorService.replaceDocument(with: proposedCode)
                    originalCode = proposedCode
                    proposedCode = ""
                    statusMessage = "Applied and saved. Use Undo to restore the previous version."
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 190)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 8))
    }

    private func beginCopilotRequest(fixCurrentError: Bool) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = ScriptCodePreviewDiagnosticStore.shared.diagnostic(for: scriptModel.package.path)
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

        MirrorEditorService.requestSnapshot { snapshot in
            DispatchQueue.main.async {
                guard let snapshot else {
                    statusMessage = "The editor is not ready yet."
                    return
                }
                originalCode = snapshot.content
                proposedCode = ""
                session.copilot(
                    currentCode: snapshot.content,
                    instruction: AIWidgetSkills.augment(requestText, selectedIDs: selectedSkillIDs),
                    runtimeDiagnostic: diagnostic
                )
            }
        }
    }

    private func consume(phase: AIGenerateSession.Phase) {
        switch phase {
        case .done(let jsx):
            proposedCode = jsx
            statusMessage = "Proposal passed the local ScriptWidget runtime."
        case .exhausted(let lastJSX, let error):
            proposedCode = lastJSX ?? ""
            statusMessage = "Iteration limit reached: \(error ?? "unknown runtime error")"
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

struct ScriptCodeEditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ScriptCodeEditorView(mode: .editor, scriptModel: globalScriptModel)
        }
    }
}
