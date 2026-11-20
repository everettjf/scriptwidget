//
//  EditorPanelView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/4.
//

import SwiftUI

struct EditorPanelTabLabel: View {
    let imageName: String
    let label: LocalizedStringKey
    
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
    var editorID = UUID()
    var documentID: String? = nil
    
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

            StudioCopilotView(scriptModel: scriptModel, editorID: editorID, documentID: documentID)
                .tabItem({ EditorPanelTabLabel(imageName: "sparkles", label: "Copilot") })
        }
        .padding(.top, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// The editor's Copilot panel: the AI conversation about this widget. It is
/// the same conversation the widget was made in, when it was made by the AI.
///
/// The AI works on a copy. Its versions change the small preview here and
/// nothing else, until "Apply to Editor" writes the version on screen into
/// the open document through the editor's own conflict check.
private struct StudioCopilotView: View {
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
                unavailable(String(localized: "This widget's widget.json can not be read, so the AI can not work on it. Fix it in the Config tab first."))
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
        ContentUnavailableView("AI Copilot Unavailable", systemImage: "sparkles", description: Text(text))
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
                .onChange(of: conversation.turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.activity) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if hasUnappliedVersion {
                Divider()
                applyBar
            }
            Divider()
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
        .onChange(of: documentID) { _, _ in lookAtEditor() }
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            isConfigured = AISettingsStore.shared.load().isConfigured
        }
        .onReceive(NotificationCenter.default.publisher(for: AIWidgetSkillManager.changedNotification)) { _ in
            skills = AIWidgetSkillManager.shared.allSkills()
        }
        .sheet(item: $shownCode) { shown in
            VStack(alignment: .leading) {
                HStack {
                    Text(shown.title).font(.headline)
                    Spacer()
                    Button("Done") { shownCode = nil }.keyboardShortcut(.defaultAction)
                }
                ScrollView {
                    Text(shown.code)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(minWidth: 520, minHeight: 420)
        }
        .confirmationDialog("Allow this widget to use the network?", isPresented: $confirmingNetwork) {
            Button("Allow and Apply") { apply(allowingHosts: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This version contacts: \(hostsToAllow.joined(separator: ", ")). Applying it adds the network permission for these hosts to the widget. You can change this in the Config tab.")
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
                Button("Manage Skills…", systemImage: "slider.horizontal.3") {
                    NotificationCenter.default.post(name: SkillManagerOpenRequest.notification, object: nil)
                }
                Divider()
                Button("Start a New Conversation", systemImage: "plus") {
                    session.cancel()
                    onStartOver()
                }
                .disabled(conversation.turns.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Copilot options")
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
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(10)
                    .scaleEffect(scale)
                    .allowsHitTesting(false)
                } else {
                    ProgressView().controlSize(.small)
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
            // The panel is narrow: a longer title is cut off.
            Button("Apply", systemImage: "checkmark") {
                if hostsToAllow.isEmpty { apply(allowingHosts: false) } else { confirmingNetwork = true }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .help("Write this version into the editor")
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
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .onSubmit { send(fixCurrentError: false) }
                    .accessibilityLabel("Message to the AI")
                Button { send(fixCurrentError: false) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
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
        EditorService.requestSnapshot(target: StudioEditorTarget(editorID: editorID, documentID: documentID)) { snapshot in
            guard requestID == token else { return }
            isReading = false
            guard let snapshot else {
                if next != nil { statusMessage = String(localized: "The editor is not ready yet.") }
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
            ? PreviewDiagnosticStore.shared.diagnostic(for: package.path.standardizedFileURL.path)
            : nil
        statusMessage = fixCurrentError && diagnostic == nil
            ? String(localized: "No runtime error was recorded; asking the AI to look at the code.")
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
        statusMessage = String(localized: "Applying and saving…")
        EditorService.requestSnapshot(target: StudioEditorTarget(editorID: editorID, documentID: documentID)) { snapshot in
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
                statusMessage = String(localized: "The file changed in the editor, so nothing was applied. The conversation now continues from the editor's code.")
                return
            }
            if allowingHosts, !hostsToAllow.isEmpty, var updated = package.readManifest() {
                if !updated.permissions.contains(.network) { updated.permissions.append(.network) }
                for host in hostsToAllow where !updated.networkDomains.contains(host) { updated.networkDomains.append(host) }
                let written = package.writeManifest(updated)
                guard written.0 else {
                    isApplying = false
                    statusMessage = String(localized: "The network permission could not be added, so nothing was applied: \(written.1)")
                    return
                }
            }
            EditorService.replaceDocument(with: source, snapshot: snapshot) { result in
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

    @State private var manifest: WidgetPackageManifest
    @State private var networkDomains: String
    @State private var pluginIDs: String
    @State private var statusMessage: String?

    init(scriptModel: ScriptModel, configuration: StudioWidgetConfiguration) {
        self.scriptModel = scriptModel
        self.configuration = configuration
        let value = scriptModel.package.effectiveManifest()
        _manifest = State(initialValue: value)
        _networkDomains = State(initialValue: value.networkDomains.joined(separator: "\n"))
        _pluginIDs = State(initialValue: (value.plugins ?? []).joined(separator: "\n"))
    }

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
                Picker("Rendering Environment", selection: $configuration.renderingMode) {
                    ForEach(StudioPreviewRenderingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Runtime debug output", isOn: $configuration.debugMode)
                TextField("Widget parameter", text: $configuration.parameter)
            }

            Section("Project") {
                TextField("Name", text: $manifest.name)
                TextField("Identifier", text: $manifest.id)
                TextField("Version", text: $manifest.version)
                TextField("Entry point", text: $manifest.entry)
                LabeledContent("Runtime", value: manifest.runtimeVersion)
                LabeledContent("Minimum runtime", value: manifest.minimumRuntimeVersion ?? "1.0")
                LabeledContent("Location", value: scriptModel.package.path.path)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("Reveal in Finder", systemImage: "finder") {
                    MacKitUtil.revealInFinder(scriptModel.package.path.path)
                }
            }

            Section("Supported families") {
                ForEach(WidgetPackageFamily.allCases) { family in
                    Toggle(family.displayName, isOn: familyBinding(family))
                }
            }

            Section("Permissions") {
                ForEach(WidgetPackagePermission.allCases) { permission in
                    Toggle(permission.displayName, isOn: permissionBinding(permission))
                }
                Text("Package 2.0 permissions are enforced by the runtime. Data sources also require Network and an allowed host below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network allowlist") {
                TextEditor(text: $networkDomains)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                Text("One lowercase host per line, for example api.example.com or *.example.com. HTTPS URLs remain subject to the runtime network policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data Source Plugins") {
                TextEditor(text: $pluginIDs)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 64)
                Text("One installed plugin identifier per line. Open Data Source Lab (⇧⌘D) to inspect and test plugins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save widget.json", systemImage: "square.and.arrow.down") { saveManifest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scriptModel.package.readonly)
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func familyBinding(_ family: WidgetPackageFamily) -> Binding<Bool> {
        Binding(
            get: { manifest.supportedFamilies.contains(family) },
            set: { enabled in
                if enabled { manifest.supportedFamilies.append(family) }
                else { manifest.supportedFamilies.removeAll { $0 == family } }
            }
        )
    }

    private func permissionBinding(_ permission: WidgetPackagePermission) -> Binding<Bool> {
        Binding(
            get: { manifest.permissions.contains(permission) },
            set: { enabled in
                if enabled { manifest.permissions.append(permission) }
                else { manifest.permissions.removeAll { $0 == permission } }
            }
        )
    }

    private func saveManifest() {
        manifest.supportedFamilies = WidgetPackageFamily.allCases.filter(manifest.supportedFamilies.contains)
        manifest.permissions = WidgetPackagePermission.allCases.filter(manifest.permissions.contains)
        manifest.networkDomains = networkDomains
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        manifest.plugins = pluginIDs
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let result = scriptModel.package.writeManifest(manifest)
        statusMessage = result.0 ? "Saved Package 2.0 manifest." : result.1
    }
}
