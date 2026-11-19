//
//  AIGenerateView.swift
//  ScriptWidget
//
//  The AI widget conversation for iPhone and iPad. On an iPhone the preview
//  is on top, the conversation below it and the message field above the
//  keyboard; on an iPad the conversation and the preview are side by side.
//  Each turn that runs becomes a version the user can go back to, and the
//  conversation is kept as a draft until it is saved as a widget.
//
//  It uses the same session, store and turn views as the Mac window.
//

import SwiftUI
import WidgetKit

struct AIGenerateView: View {
    /// A new session is made whenever the user starts or opens a conversation.
    @State private var conversation: AIConversation
    @State private var sessionKey = UUID()

    /// Opens on a new conversation, or on one that was saved earlier.
    init(conversation: AIConversation = AIConversation()) {
        _conversation = State(initialValue: conversation)
    }

    var body: some View {
        AIConversationScreen(
            conversation: conversation,
            onOpen: { opened in
                conversation = opened
                sessionKey = UUID()
            }
        )
        .id(sessionKey)
    }
}

private struct AIConversationScreen: View {
    let onOpen: (AIConversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: AIConversationSession

    @State private var draftText = ""
    @State private var saveName = ""
    @State private var saveError: String?
    @State private var shownCode: ShownCode?
    @State private var showingLogs = false
    @State private var showingSaveName = false
    @State private var confirmingDelete = false
    @State private var isDebugMode = false
    @State private var profiles: [AIProfile] = []
    @State private var activeProfileID = ""
    @State private var isConfigured = true
    @State private var skills: [AIWidgetSkill] = AIWidgetSkills.builtIns
    @State private var drafts: [AIConversationSummary] = []
    @FocusState private var composerFocused: Bool

    private struct ShownCode: Identifiable {
        let id = UUID()
        let title: String
        let code: String
    }

    init(conversation: AIConversation, onOpen: @escaping (AIConversation) -> Void) {
        self.onOpen = onOpen
        _session = StateObject(wrappedValue: AIConversationSession(conversation: conversation))
    }

    private var conversation: AIConversation { session.conversation }
    /// Nothing to show yet needs little room; a widget gets more, less while typing.
    private var compactStageHeight: CGFloat {
        if conversation.currentVersion == nil && !session.isRunning { return 96 }
        return composerFocused ? 120 : 210
    }
    /// From this width on the conversation and the preview are side by side.
    private static let sideBySideWidth: CGFloat = 720
    private var sortedVersions: [AIConversationVersion] {
        conversation.versions.sorted { $0.number < $1.number }
    }

    var body: some View {
        // The layout follows the room there is, not the size class: an iPad
        // window can be narrow and still be "regular".
        GeometryReader { proxy in
            if proxy.size.width >= Self.sideBySideWidth {
                HStack(spacing: 0) {
                    chat
                        .frame(maxWidth: .infinity)
                    Divider()
                    ScrollView {
                        previewPanel(stageHeight: 380, showsThumbnails: true)
                            .padding(16)
                    }
                    .frame(width: min(400, proxy.size.width * 0.42))
                    .background(StudioDesign.groupedBackground)
                }
            } else {
                VStack(spacing: 0) {
                    // While typing, the widget stays in view but gives room to the conversation.
                    previewPanel(stageHeight: compactStageHeight, showsThumbnails: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(StudioDesign.groupedBackground)
                    Divider()
                    chat
                }
                .animation(.easeInOut(duration: 0.2), value: composerFocused)
            }
        }
        .navigationTitle(conversation.title.isEmpty ? "New AI Widget" : conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                optionsMenu
                Button("Save") { beginSave() }
                    .fontWeight(.semibold)
                    .disabled(session.currentSource.isEmpty || session.isRunning)
                    .accessibilityLabel("Save Widget")
            }
        }
        .onAppear {
            reloadSettings()
            skills = AIWidgetSkillManager.shared.allSkills()
            reloadDrafts()
        }
        .onDisappear { session.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            reloadSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: AIWidgetSkillManager.changedNotification)) { _ in
            skills = AIWidgetSkillManager.shared.allSkills()
        }
        .sheet(item: $shownCode) { codeSheet($0) }
        .sheet(isPresented: $showingLogs) { logsSheet }
        // One dialog asks for the name and, for a widget that uses the network,
        // names its hosts: a second dialog right after the first is dropped by iOS.
        .alert("Save Widget", isPresented: $showingSaveName) {
            TextField("Widget name", text: $saveName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { }
            if session.currentDomains.isEmpty {
                Button("Save") { performSave() }
            } else {
                Button("Save and Allow") { performSave() }
            }
        } message: {
            if session.currentDomains.isEmpty {
                Text("Choose a name for your new widget.")
            } else {
                Text("Choose a name for your new widget. The AI wrote a widget that contacts: \(session.currentDomains.joined(separator: ", ")). Saving gives it the network permission for these hosts only. You can change this later in the widget's configuration.")
            }
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                session.cancel()
                AIConversationStore.shared.delete(id: conversation.id)
                onOpen(AIConversation())
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its versions are removed. A widget you already saved stays in your library.")
        }
        .alert("Saving the Widget", isPresented: saveErrorBinding) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - toolbar

    private var optionsMenu: some View {
        Menu {
            Button {
                onOpen(AIConversation())
            } label: {
                Label("New Conversation", systemImage: "plus")
            }
            .disabled(conversation.turns.isEmpty)

            if !otherDrafts.isEmpty {
                Section("Drafts") {
                    ForEach(otherDrafts) { draft in
                        Button(draft.title.isEmpty ? "Untitled" : draft.title) { open(draft) }
                    }
                }
            }

            Section("Skills for this conversation") {
                ForEach(skills) { skill in
                    Toggle(isOn: skillBinding(skill.id)) {
                        Label(skill.title, systemImage: skill.symbol)
                    }
                }
            }

            if profiles.count > 1 {
                Picker("Provider", selection: activeProfileBinding) {
                    ForEach(profiles) { profile in
                        Text(profile.name.isEmpty ? "Unnamed" : profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(session.isRunning)
            }

            Section {
                Button {
                    shownCode = ShownCode(
                        title: "Version \(conversation.currentVersion?.number ?? 0)",
                        code: session.currentSource
                    )
                } label: {
                    Label("View Code", systemImage: "curlybraces")
                }
                .disabled(session.currentSource.isEmpty)
                Button {
                    showingLogs = true
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
                .disabled(session.attemptLogs.isEmpty)
                Toggle(isOn: $isDebugMode) {
                    Label("Debug Outlines", systemImage: "square.dashed")
                }
            }

            if !conversation.turns.isEmpty {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete This Conversation", systemImage: "trash")
                }
            }
        } label: {
            Label("Conversation options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
    }

    // MARK: - conversation

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !isConfigured {
                        notConfiguredNotice
                    } else if conversation.turns.isEmpty {
                        if conversation.currentVersion == nil {
                            emptyState
                        } else {
                            Text("This conversation continues from an earlier one. Say what to change.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    AIConversationTurnsView(session: session, canSend: isConfigured) { title, code in
                        shownCode = ShownCode(title: title, code: code)
                    }
                    if conversation.totalUsage.totalTokens > 0 {
                        Text("\(conversation.totalUsage.totalTokens) tokens in this conversation")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.turns.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.activity) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: composerFocused) { focused in
                if focused { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                AIConversationUsageNotice(conversation: conversation) { next in
                    session.cancel()
                    onOpen(next)
                }
                composer
            }
            .background(.bar)
        }
    }

    private var notConfiguredNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Set up an AI provider first", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("The selected provider has no server, model or key yet. Add them in Settings, under AI. Keys are kept in the Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .studioCard()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Describe a widget, then keep asking for changes.")
                    .font(.headline)
                Text("Every change that runs becomes a version you can go back to. Nothing is saved to your library until you tap Save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Try an example")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AIExamplePrompts.all) { example in
                            Button {
                                draftText = example.prompt
                                session.setSize(example.size)
                                composerFocused = true
                            } label: {
                                Label(example.title, systemImage: example.symbol)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.accentColor.opacity(0.12), in: .capsule)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !drafts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Continue a draft")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    ForEach(drafts.prefix(5)) { draft in
                        HStack(spacing: 10) {
                            Button { open(draft) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(draft.title.isEmpty ? "Untitled" : draft.title)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        Text("\(draft.versionCount) version\(draft.versionCount == 1 ? "" : "s") · \(draft.updatedAt.formatted(.relative(presentation: .named)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            Button {
                                AIConversationStore.shared.delete(id: draft.id)
                                reloadDrafts()
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete draft \(draft.title)")
                        }
                        if draft.id != drafts.prefix(5).last?.id { Divider() }
                    }
                }
                .studioCard(padding: 12)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                conversation.versions.isEmpty ? "Describe the widget you want…" : "Say what to change…",
                text: $draftText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(StudioDesign.cardBackground, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(StudioDesign.separator, lineWidth: 0.5)
            }
            .focused($composerFocused)
            .accessibilityLabel("Message to the AI")

            if session.isRunning {
                Button {
                    session.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                }
                .accessibilityLabel("Stop")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        isConfigured && !session.isRunning
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draftText
        draftText = ""
        session.send(text)
    }

    // MARK: - preview

    private func previewPanel(stageHeight: CGFloat, showsThumbnails: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                StudioDesign.cardBackground
                previewContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.isRunning, session.previewElement != nil {
                    Label("Showing version \(conversation.currentVersion?.number ?? 0) while the AI works", systemImage: "clock")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: .capsule)
                        .padding(6)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: stageHeight)
            .clipShape(.rect(cornerRadius: StudioDesign.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: StudioDesign.cardCornerRadius, style: .continuous)
                    .stroke(StudioDesign.separator, lineWidth: 0.5)
            }

            HStack(spacing: 4) {
                Menu {
                    Picker("Size", selection: sizeBinding) {
                        ForEach(AIWidgetSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                } label: {
                    Label(conversation.size.displayName, systemImage: "rectangle.3.group")
                        .font(.subheadline)
                }
                .accessibilityLabel("Size: \(conversation.size.displayName)")
                .accessibilityHint("Runs the widget again on this device. Nothing is sent to the AI.")
                Spacer(minLength: 8)
                versionStepper
            }

            if showsThumbnails, conversation.currentVersion != nil {
                thumbnails
            }

            if !session.currentDomains.isEmpty {
                Label("This version may contact: \(session.currentDomains.joined(separator: ", "))", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var versionStepper: some View {
        if let current = conversation.currentVersion {
            let index = sortedVersions.firstIndex { $0.id == current.id } ?? 0
            HStack(spacing: 2) {
                Button {
                    session.selectVersion(sortedVersions[index - 1].id)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 32)
                }
                .disabled(index == 0 || session.isRunning)
                .accessibilityLabel("Previous version")
                Text("Version \(current.number) of \(sortedVersions.last?.number ?? current.number)")
                    .font(.subheadline.monospacedDigit())
                Button {
                    session.selectVersion(sortedVersions[index + 1].id)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 32)
                }
                .disabled(index >= sortedVersions.count - 1 || session.isRunning)
                .accessibilityLabel("Next version")
            }
        } else {
            Text("No version yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 32)
        }
    }

    /// The widget at the three home-screen sizes; a tap shows that size above.
    private var thumbnails: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(AIConversationSession.thumbnailSizes) { size in
                let scale: CGFloat = 0.26
                let full = size.previewSize
                Button {
                    session.setSize(size)
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let element = session.previews[size], let package = session.previewPackage {
                                ScriptWidgetElementView(
                                    element: element,
                                    context: ScriptWidgetElementContext(
                                        runtime: nil, debugMode: false, scriptName: "AI Preview",
                                        scriptParameter: "", package: package
                                    )
                                )
                                .frame(width: full.width, height: full.height)
                                .background(Color(uiColor: .systemBackground))
                                .cornerRadius(18)
                                .scaleEffect(scale)
                                .allowsHitTesting(false)
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(width: full.width * scale, height: full.height * scale)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(size == conversation.size ? Color.accentColor : StudioDesign.separator,
                                        lineWidth: size == conversation.size ? 2 : 1)
                        }
                        Text(size.displayName)
                            .font(.caption2)
                            .foregroundStyle(size == conversation.size ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the \(size.displayName) size")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        let size = conversation.size.previewSize
        if let element = session.previewElement, let package = session.previewPackage {
            let context = ScriptWidgetElementContext(
                runtime: nil,
                debugMode: isDebugMode,
                scriptName: "AI Preview",
                scriptParameter: "",
                package: package
            )
            // A size larger than the space is drawn smaller, never cut off.
            GeometryReader { proxy in
                let scale = min(1, (proxy.size.width - 20) / size.width, (proxy.size.height - 20) / size.height)
                ScriptWidgetElementView(element: element, context: context)
                    .frame(width: size.width, height: size.height)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(conversation.size.previewIsCircular ? size.height / 2 : 22)
                    .scaleEffect(max(0.1, scale))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .accessibilityLabel("Widget preview, version \(conversation.currentVersion?.number ?? 0)")
        } else if session.isRunning {
            VStack(spacing: StudioDesign.compactSpacing) {
                ProgressView()
                Text("Building and checking your widget…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Your widget appears here as soon as it runs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - sheets

    private func codeSheet(_ shown: ShownCode) -> some View {
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

    private var logsSheet: some View {
        NavigationStack {
            List {
                ForEach(session.attemptLogs) { record in
                    Section("Attempt \(record.attempt)") {
                        if let error = record.errorSummary {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            Label("Ran", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        ForEach(Array(record.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Attempts of the Last Turn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showingLogs = false }
                }
            }
        }
    }

    // MARK: - helpers

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var sizeBinding: Binding<AIWidgetSize> {
        Binding(get: { conversation.size }, set: { session.setSize($0) })
    }

    private var activeProfileBinding: Binding<String> {
        Binding(get: { activeProfileID }, set: { newValue in
            activeProfileID = newValue
            AISettingsStore.shared.setActiveProfile(id: newValue)
        })
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

    private var otherDrafts: [AIConversationSummary] {
        Array(drafts.filter { $0.id != conversation.id }.prefix(8))
    }

    private func open(_ draft: AIConversationSummary) {
        guard let loaded = AIConversationStore.shared.load(id: draft.id) else {
            reloadDrafts()
            return
        }
        session.cancel()
        onOpen(loaded)
    }

    private func reloadDrafts() {
        drafts = AIConversationStore.shared.summaries(draftsOnly: true)
    }

    private func reloadSettings() {
        profiles = AISettingsStore.shared.loadProfiles()
        activeProfileID = AISettingsStore.shared.loadActiveProfileID()
        isConfigured = AISettingsStore.shared.load().isConfigured
    }

    private func beginSave() {
        composerFocused = false
        if saveName.trimmingCharacters(in: .whitespaces).isEmpty {
            saveName = "AI " + Self.defaultNameFormatter.string(from: Date())
        }
        showingSaveName = true
    }

    private static let defaultNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    private func performSave() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "Widget name can not be empty."
            return
        }
        // Resolve the name first so that the package just created can be found again.
        let packageName = sharedScriptManager.getValidPackageName(recommendPackageName: trimmed)
        guard !packageName.isEmpty else {
            saveError = "This name can not be used for a widget, or the widget library is not available."
            return
        }
        let result = sharedScriptManager.createScript(
            content: session.currentSource,
            recommendPackageName: packageName,
            imageCopyPath: nil
        )
        guard result.0 else {
            saveError = result.1
            return
        }
        var warning: String?
        let domains = session.currentDomains
        if !domains.isEmpty {
            // The declaration came from the model; writeManifest validates it again.
            let package = sharedScriptManager.getScriptPackage(packageName: packageName)
            if var manifest = package.readManifest() {
                manifest.permissions = [.network]
                manifest.networkDomains = domains
                let written = package.writeManifest(manifest)
                if !written.0 { warning = written.1 }
            } else {
                warning = "The widget's configuration could not be read."
            }
        }
        session.markSaved(
            packageName: packageName,
            packageID: sharedScriptManager.getScriptPackage(packageName: packageName).readManifest()?.id
        )
        NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptCreateNotification, object: nil)
        WidgetCenter.shared.reloadAllTimelines()
        if let warning {
            saveError = "The widget was saved, but its network permission could not be added: \(warning) Add it in the widget's configuration."
        } else {
            dismiss()
        }
    }
}
