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
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(Text(title))
    }
}


class ScriptCodeEditorViewDataObject : ObservableObject {
    let editorID = UUID()
    
    @Published var scriptModel: ScriptModel
    @Published var filePath: URL
    private var renameObserver: NSObjectProtocol?
    
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        self.filePath = scriptModel.package.jsxPath
        
        renameObserver = NotificationCenter.default.addObserver(forName: ScriptWidgetHomeViewDataObject.scriptRenameNotification, object: nil, queue: OperationQueue.main) { [weak self] noti in
            
            guard let self, let newName = noti.userInfo?["newName"] as? String,
                  let oldName = noti.userInfo?["oldName"] as? String,
                  self.scriptModel.name == oldName else { return }
            let oldRoot = self.scriptModel.package.path.standardizedFileURL.path + "/"
            let oldFile = self.filePath.standardizedFileURL.path
            let relative = oldFile.hasPrefix(oldRoot) ? String(oldFile.dropFirst(oldRoot.count)) : "main.jsx"
            let package = sharedScriptManager.getScriptPackage(packageName: newName)
            self.scriptModel = ScriptModel(package: package)
            self.filePath = package.resolvedPackageURL(relativePath: relative) ?? package.jsxPath
        }
    }

    deinit {
        if let renameObserver {
            NotificationCenter.default.removeObserver(renameObserver)
        }
    }
}

struct ScriptCodeEditorView: View {
    @StateObject private var dataObject: ScriptCodeEditorViewDataObject
    let mode: ScriptCodeEditorViewMode
    let actionCreate: (() -> Void)?
    
    @State private var showRunnerView = false
    @State private var showResourceCodeView = false
    @State private var showCopilotView = false
    
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didSave = false
    @State private var isSaving = false

    // The detail column can be much narrower than a regular size class suggests,
    // especially when an unfolded display keeps the widget list visible.
    private let minimumInlinePanelWidth: CGFloat = 800

    
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
        ScriptPackageEditorView(model: dataObject.scriptModel, filePath: $dataObject.filePath, editorID: dataObject.editorID)
            .onDisappear {
                MirrorEditorService.save(target: StudioEditorTarget(editorID: dataObject.editorID, documentID: dataObject.filePath.standardizedFileURL.path)) { _ in }
            }
    }
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
    
    var body: some View {
        GeometryReader { proxy in
            let showsInlinePanel = proxy.size.width >= minimumInlinePanelWidth

            HStack(spacing: 0) {
                codeeditor
                    .frame(width: showsInlinePanel ? proxy.size.width * 0.58 : proxy.size.width)
                if showsInlinePanel {
                    Divider()
                    ScriptCodeStudioPanelView(
                        scriptModel: dataObject.scriptModel,
                        filePath: $dataObject.filePath,
                        editorID: dataObject.editorID
                    )
                }
            }
            .navigationTitle(self.dataObject.scriptModel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // No item at all when it would be empty: an empty toolbar item is drawn as a blank button.
                if self.mode != .creator {
                    ToolbarItem(placement: .navigationBarLeading) {
                        leadingButtons
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    trailingButtons(showsInlinePanel: showsInlinePanel)
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
                    ScriptCodeCopilotView(scriptModel: dataObject.scriptModel, editorID: dataObject.editorID, documentID: dataObject.filePath.standardizedFileURL.path)
                        .navigationTitle("AI Copilot")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showCopilotView = false }
                            }
                        }
                }
            }
        }
    }
    
    var leadingButtons: some View {
        HStack {
            if self.mode != .creator  {
                ScriptCodeEditorNavButtonView(title: "Project Resources", systemImage: "book.closed") {
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
    
    func trailingButtons(showsInlinePanel: Bool) -> some View {
        HStack {
            if mode == .editor, #available(iOS 16.2, *) {
                ScriptCodeEditorNavButtonView(title: "Start Live Activity", systemImage: "lock.rectangle") {
                    saveEditor {
                        let package = dataObject.scriptModel.package
                        isSaving = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            let expected=(try? ScriptWidgetLiveActivityBinding.capture(name:package.name,cacheOnly:false))?.0
                            let result = sharedScriptManager.buildScriptPackage(package: package, requireSharedContainer: true)
                            DispatchQueue.main.async {
                                isSaving = false
                                guard result.0 else { showAlert(result.1); return }
                                guard let expected,expected.ownerID==package.managedScope?.binding?.ownerID,
                                      (try? package.managedScope?.validate(name:package.name)) != nil else { showAlert("This widget installation changed. Reopen it and try again.");return }
                                if sharedLiveActivityManager.create(scriptName: package.name, scriptParameter: "",expectedBinding:expected) != nil {
                                    showAlert("Lock screen live activity created.")
                                } else {
                                    showAlert(sharedLiveActivityManager.message ?? "Live Activity could not be started. Check device support and Settings.")
                                }
                            }
                        }
                    }
                }
                .disabled(isSaving)
            }

            ScriptCodeEditorNavButtonView(title: "Run Preview", systemImage: "play.fill") {
                self.showRunnerView.toggle()
            }
            .keyboardShortcut("r", modifiers: .command)
            .sheet(isPresented: $showRunnerView, content: {
                previewView
            })

            if mode == .editor && !showsInlinePanel {
                ScriptCodeEditorNavButtonView(title: "AI Copilot", systemImage: "sparkles") {
                    showCopilotView = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            if mode == .editor {
                Button {
                    saveEditor {}
                } label: {
                    Label(didSave ? "Saved" : "Save", systemImage: didSave ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .disabled(isSaving)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityLabel(didSave ? "Widget saved" : "Save widget")
                .foregroundStyle(didSave ? Color.green : Color.accentColor)
            }
            
            if self.mode == .creator {
                ScriptCodeEditorNavButtonView(title: "Create Widget", systemImage: "plus.square.fill") {
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

    private func saveEditor(onSuccess: @escaping () -> Void) {
        guard !isSaving else { return }
        isSaving = true
        didSave = false
        MirrorEditorService.save(target: StudioEditorTarget(editorID: dataObject.editorID, documentID: dataObject.filePath.standardizedFileURL.path)) { succeeded in
            isSaving = false
            guard succeeded else {
                showAlert("Could not save the script. Your edits are still in the editor. Try saving again before leaving.")
                return
            }
            withAnimation(.easeOut(duration: 0.2)) { didSave = true }
            onSuccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didSave = false }
        }
    }

}

private struct ScriptCodeStudioPanelView: View {
    let scriptModel: ScriptModel
    @Binding var filePath: URL
    let editorID: UUID
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
                ScriptCodeCopilotView(scriptModel: scriptModel, editorID: editorID, documentID: filePath.standardizedFileURL.path)
            }
        }
        .background(StudioDesign.groupedBackground)
    }
}

/// The editor's Copilot panel: the AI conversation about this widget. It is
/// the same conversation the widget was made in, when it was made by the AI.
///
/// The AI works on a copy. Its versions change the small preview here and
/// nothing else, until "Apply to Editor" writes the version on screen into
/// the open document through the editor's own conflict check.
private struct ScriptCodeCopilotView: View {
    let scriptModel: ScriptModel
    let editorID: UUID
    let documentID: String?

    @State private var conversation: AIConversation?
    @State private var sessionKey = UUID()

    var body: some View {
        let package = scriptModel.package
        let manifest = package.readManifest()
        Group {
            if package.hasManifest && manifest == nil {
                // A widget.json that can not be read is never treated as absent.
                unavailable("This widget's widget.json can not be read, so the AI can not work on it. Fix it in the widget's configuration first.")
            } else {
                StudioCopilotConversationView(
                    scriptModel: scriptModel,
                    manifest: manifest,
                    editorID: editorID,
                    documentID: documentID,
                    conversation: conversation ?? Self.conversation(for: package, manifest: manifest),
                    onStartOver: {
                        conversation = Self.newConversation(for: package, manifest: manifest)
                        sessionKey = UUID()
                    }
                )
                .id(sessionKey)
            }
        }
        .id(package.path)
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
            Text("AI Copilot Unavailable").font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func conversation(for package: ScriptWidgetPackage, manifest: WidgetPackageManifest?) -> AIConversation {
        AIConversationStore.shared.latest(packageID: manifest?.id, packageName: package.name)
            ?? newConversation(for: package, manifest: manifest)
    }

    private static func newConversation(for package: ScriptWidgetPackage, manifest: WidgetPackageManifest?) -> AIConversation {
        var conversation = AIConversation()
        conversation.title = package.name
        conversation.savedPackageName = package.name
        conversation.savedPackageID = manifest?.id
        return conversation
    }
}

private struct StudioCopilotConversationView: View {
    let scriptModel: ScriptModel
    let manifest: WidgetPackageManifest?
    let editorID: UUID
    let documentID: String?
    let onStartOver: () -> Void

    @StateObject private var session: AIConversationSession
    @State private var draftText = ""
    @State private var statusMessage: String?
    /// What the editor held the last time this panel looked.
    @State private var knownEditorContent: String?
    @State private var isReading = false
    @State private var isApplying = false
    @State private var requestID = UUID()
    @State private var shownCode: ShownCode?
    @State private var confirmingNetwork = false
    @State private var isConfigured = true
    @State private var skills: [AIWidgetSkill] = AIWidgetSkills.builtIns

    private struct ShownCode: Identifiable {
        let id = UUID()
        let title: String
        let code: String
    }

    init(scriptModel: ScriptModel, manifest: WidgetPackageManifest?, editorID: UUID, documentID: String?,
         conversation: AIConversation, onStartOver: @escaping () -> Void) {
        self.scriptModel = scriptModel
        self.manifest = manifest
        self.editorID = editorID
        self.documentID = documentID
        self.onStartOver = onStartOver
        _session = StateObject(wrappedValue: AIConversationSession(
            conversation: conversation,
            sandbox: AgentSandboxSetup(seedDirectory: scriptModel.package.path, baseManifest: manifest)
        ))
    }

    private var package: ScriptWidgetPackage { scriptModel.package }
    private var conversation: AIConversation { session.conversation }

    /// The conversation changes the widget's entry file and no other.
    private var isEntryDocument: Bool {
        let entry = manifest?.entry ?? "main.jsx"
        return documentID != nil
            && documentID == package.resolvedPackageURL(relativePath: entry)?.standardizedFileURL.path
    }

    private var canWork: Bool { isConfigured && isEntryDocument && !package.readonly }

    /// The version on screen is not what the editor holds.
    private var hasUnappliedVersion: Bool {
        guard let known = knownEditorContent, !session.isRunning, !session.currentSource.isEmpty else { return false }
        return session.currentSource != known
    }

    /// Hosts the version declares that the widget may not contact yet.
    private var hostsToAllow: [String] {
        guard let manifest else { return [] }
        return session.currentDomains.filter { !manifest.networkDomains.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        notices
                        if conversation.currentVersion != nil { preview }
                        AIConversationTurnsView(session: session, canSend: canWork) { title, code in
                            shownCode = ShownCode(title: title, code: code)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: conversation.turns.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.activity) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if hasUnappliedVersion {
                Divider()
                applyBar
            }
            Divider()
            AIConversationUsageNotice(conversation: conversation) { _ in
                session.cancel()
                onStartOver()
            }
            composer
        }
        .onAppear {
            isConfigured = AISettingsStore.shared.load().isConfigured
            skills = AIWidgetSkillManager.shared.allSkills()
            lookAtEditor()
        }
        .onDisappear {
            requestID = UUID()
            session.cancel()
        }
        .onChange(of: documentID) { _ in lookAtEditor() }
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            isConfigured = AISettingsStore.shared.load().isConfigured
        }
        .onReceive(NotificationCenter.default.publisher(for: AIWidgetSkillManager.changedNotification)) { _ in
            skills = AIWidgetSkillManager.shared.allSkills()
        }
        .sheet(item: $shownCode) { shown in
            NavigationStack {
                ScrollView {
                    Text(shown.code)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(shown.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { shownCode = nil }
                    }
                }
            }
        }
        .confirmationDialog("Allow this widget to use the network?", isPresented: $confirmingNetwork, titleVisibility: .visible) {
            Button("Allow and Apply") { apply(allowingHosts: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This version contacts: \(hostsToAllow.joined(separator: ", ")). Applying it adds the network permission for these hosts to the widget. You can change this in the widget's configuration.")
        }
    }

    // MARK: - parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("AI Copilot", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Menu {
                Section("Skills for this conversation") {
                    ForEach(skills) { skill in
                        Toggle(isOn: skillBinding(skill.id)) { Label(skill.title, systemImage: skill.symbol) }
                    }
                }
                Button("Start a New Conversation", systemImage: "plus") {
                    session.cancel()
                    onStartOver()
                }
                .disabled(conversation.turns.isEmpty)
            } label: {
                Label("Copilot options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if conversation.turns.isEmpty {
            Text("Say what to change. The AI works on a copy: you see the result here first, and the widget changes only when you apply it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !isConfigured {
            Label("Set up an AI provider in Settings → AI first.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if package.readonly {
            Label("This widget is read-only.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !isEntryDocument {
            Label("The conversation changes the widget's main file. Select it in the file list to continue.", systemImage: "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// The version on screen, drawn small. It is the AI's copy, not the editor's document.
    private var preview: some View {
        let size = conversation.size.previewSize
        let scale = min(1, 150 / size.height, 300 / size.width)
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let element = session.previewElement, let previewPackage = session.previewPackage {
                    ScriptWidgetElementView(
                        element: element,
                        context: ScriptWidgetElementContext(
                            runtime: nil, debugMode: false, scriptName: scriptModel.name,
                            scriptParameter: "", package: previewPackage
                        )
                    )
                    .frame(width: size.width, height: size.height)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(18)
                    .scaleEffect(scale)
                    .allowsHitTesting(false)
                } else {
                    ProgressView()
                }
            }
            .frame(width: size.width * scale, height: size.height * scale)
            Text(hasUnappliedVersion
                 ? "Version \(conversation.currentVersion?.number ?? 0), not applied yet"
                 : "Version \(conversation.currentVersion?.number ?? 0)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !session.currentDomains.isEmpty {
                Label("May contact: \(session.currentDomains.joined(separator: ", "))", systemImage: "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var applyBar: some View {
        let change = AICopilotChangeSummary.compare(original: knownEditorContent ?? "", proposed: session.currentSource)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(conversation.currentVersion?.number ?? 0) is not in the editor yet")
                    .font(.callout.weight(.medium))
                Text("\(change.changedLines) changed lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show Code") {
                shownCode = ShownCode(title: "Version \(conversation.currentVersion?.number ?? 0)", code: session.currentSource)
            }
            .controlSize(.small)
            Button("Apply", systemImage: "checkmark") {
                if hostsToAllow.isEmpty { apply(allowingHosts: false) } else { confirmingNetwork = true }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Apply to Editor")
            .disabled(isApplying || !canWork)
        }
        .padding(10)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Say what to change…", text: $draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(StudioDesign.cardBackground, in: .rect(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(StudioDesign.separator, lineWidth: 0.5)
                    }
                    .accessibilityLabel("Message to the AI")
                if session.isRunning {
                    Button { session.cancel() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button { send(fixCurrentError: false) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            Button("Fix Runtime Error", systemImage: "wrench.and.screwdriver") { send(fixCurrentError: true) }
                .controlSize(.small)
                .disabled(!canWork || session.isRunning || isReading || isApplying)
        }
        .padding(10)
    }

    private var canSend: Bool {
        canWork && !session.isRunning && !isReading && !isApplying
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - actions

    /// Reads the open document. Code the conversation has never seen (the user
    /// edited it, or it is the first look) becomes a version; a pending AI
    /// version is left alone.
    private func lookAtEditor(then next: ((StudioDocumentSnapshot) -> Void)? = nil) {
        guard isEntryDocument, let documentID, !isReading else { return }
        let token = UUID()
        requestID = token
        isReading = true
        MirrorEditorService.requestSnapshot(target: StudioEditorTarget(editorID: editorID, documentID: documentID)) { snapshot in
            guard requestID == token else { return }
            isReading = false
            guard let snapshot else {
                if next != nil { statusMessage = "The editor is not ready yet." }
                return
            }
            knownEditorContent = snapshot.content
            if !conversation.versions.isEmpty || next != nil {
                session.adoptEditorSource(snapshot.content)
            }
            next?(snapshot)
        }
    }

    private func send(fixCurrentError: Bool) {
        let typed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = fixCurrentError && typed.isEmpty
            ? "Fix the current runtime error while keeping the widget's design."
            : typed
        guard canWork, !request.isEmpty, !session.isRunning, !isReading, !isApplying else { return }
        let diagnostic = fixCurrentError
            ? ScriptCodePreviewDiagnosticStore.shared.diagnostic(for: package.path)
            : nil
        statusMessage = fixCurrentError && diagnostic == nil
            ? "No runtime error was recorded; asking the AI to look at the code."
            : nil
        draftText = ""
        lookAtEditor { _ in
            session.send(request, runtimeDiagnostic: diagnostic)
        }
    }

    /// Writes the version on screen into the open document. The document must
    /// still be what this panel last saw; the editor checks again on its side.
    private func apply(allowingHosts: Bool) {
        guard canWork, !isApplying, let documentID else { return }
        let source = session.currentSource
        let expected = knownEditorContent
        let token = UUID()
        requestID = token
        isApplying = true
        statusMessage = "Applying and saving…"
        MirrorEditorService.requestSnapshot(target: StudioEditorTarget(editorID: editorID, documentID: documentID)) { snapshot in
            guard requestID == token else { return }
            guard let snapshot else {
                isApplying = false
                statusMessage = StudioDocumentApplyResult.unavailable.message
                return
            }
            guard snapshot.content == expected else {
                isApplying = false
                knownEditorContent = snapshot.content
                session.adoptEditorSource(snapshot.content)
                statusMessage = "The file changed in the editor, so nothing was applied. The conversation now continues from the editor's code."
                return
            }
            if allowingHosts, !hostsToAllow.isEmpty, var updated = package.readManifest() {
                if !updated.permissions.contains(.network) { updated.permissions.append(.network) }
                for host in hostsToAllow where !updated.networkDomains.contains(host) { updated.networkDomains.append(host) }
                let written = package.writeManifest(updated)
                guard written.0 else {
                    isApplying = false
                    statusMessage = "The network permission could not be added, so nothing was applied: \(written.1)"
                    return
                }
            }
            MirrorEditorService.replaceDocument(with: source, snapshot: snapshot) { result in
                guard requestID == token else { return }
                isApplying = false
                statusMessage = result.message
                if result == .saved { knownEditorContent = source }
            }
        }
    }

    private func skillBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { conversation.skillIDs.contains(id) },
            set: { enabled in
                var ids = Set(conversation.skillIDs)
                if enabled { ids.insert(id) } else { ids.remove(id) }
                session.setSkills(ids)
            }
        )
    }
}

#Preview("Widget Editor") {
    NavigationStack {
        ScriptCodeEditorView(mode: .editor, scriptModel: globalScriptModel)
    }
}
