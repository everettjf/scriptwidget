//
//  AIGenerateWindowView.swift
//  ScriptWidgetMac
//
//  The AI widget conversation for macOS, hosted in a sheet: the conversation
//  on the left, the live preview on the right. Each turn that runs becomes a
//  version the user can go back to, and the conversation is kept as a draft
//  until it is saved as a widget.
//

import SwiftUI
import WidgetKit

struct AIGenerateWindowView: View {
    static let openRequestNotification = Notification.Name("AIGenerateWindowViewOpenRequest")

    /// A new session is made whenever the user starts or opens a conversation.
    @State private var conversation: AIConversation
    @State private var sessionKey = UUID()

    /// Opens on a new conversation, or on one that was saved earlier.
    init(conversation: AIConversation = AIConversation()) {
        _conversation = State(initialValue: conversation)
    }

    var body: some View {
        AIConversationWindowContent(
            conversation: conversation,
            onOpen: { opened in
                conversation = opened
                sessionKey = UUID()
            }
        )
        .id(sessionKey)
    }
}

private struct AIConversationWindowContent: View {
    let onOpen: (AIConversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: AIConversationSession

    @State private var draftText = ""
    @State private var saveName = ""
    @State private var saveError: String?
    @State private var shownCode: ShownCode?
    @State private var showingLogs = false
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
    private var sortedVersions: [AIConversationVersion] {
        conversation.versions.sorted { $0.number < $1.number }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                chatSide
                    .frame(minWidth: 320, idealWidth: 400)
                previewSide
                    .frame(minWidth: 300, idealWidth: 420)
            }
            Divider()
            footer
        }
        .frame(idealWidth: 900, minHeight: 540, idealHeight: 640)
        .frame(minWidth: 760)
        .onAppear {
            reloadSettings()
            skills = AIWidgetSkillManager.shared.allSkills()
            reloadDrafts()
            if conversation.currentVersion != nil { prefillSaveNameIfNeeded() }
            composerFocused = true
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
        .alert("Save Failed", isPresented: saveErrorBinding) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conversation.title.isEmpty ? "New AI Widget" : conversation.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if !conversation.turns.isEmpty {
                        Text(conversation.isDraft ? "Draft" : "Saved")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text("Describe a widget, then keep asking for changes. Every change that runs becomes a version.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if profiles.count > 1 {
                Picker("Provider", selection: $activeProfileID) {
                    ForEach(profiles) { profile in
                        Text(profile.name.isEmpty ? "Unnamed" : profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .disabled(session.isRunning)
                .onChange(of: activeProfileID) { _, newValue in
                    AISettingsStore.shared.setActiveProfile(id: newValue)
                }
            }
            Menu {
                Button("New Conversation", systemImage: "plus") { onOpen(AIConversation()) }
                    .disabled(conversation.turns.isEmpty)
                if !otherDrafts.isEmpty {
                    Section("Drafts") {
                        ForEach(otherDrafts) { draft in
                            Button(draftLabel(draft)) { open(draft) }
                        }
                    }
                }
                if !conversation.turns.isEmpty {
                    Divider()
                    Button("Delete This Conversation", systemImage: "trash", role: .destructive) {
                        session.cancel()
                        AIConversationStore.shared.delete(id: conversation.id)
                        onOpen(AIConversation())
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Conversation options")
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: - conversation

    private var chatSide: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !isConfigured {
                            notConfiguredNotice
                        } else if conversation.turns.isEmpty {
                            emptyState
                        }
                        ForEach(conversation.turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: conversation.turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.activity) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            composer
        }
    }

    private var notConfiguredNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Set up an AI provider first", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("The selected provider has no server, model or key yet. Keys are kept in the Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SettingsLink {
                Text("Open AI Settings")
            }
        }
        .studioCard()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try an example")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowButtons(items: AIExamplePrompts.all) { example in
                    Button {
                        draftText = example.prompt
                        session.setSize(example.size)
                        composerFocused = true
                    } label: {
                        Label(example.title, systemImage: example.symbol)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if !drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue a draft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(drafts.prefix(5)) { draft in
                        HStack {
                            Button { open(draft) } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                    Text(draft.title.isEmpty ? "Untitled" : draft.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(draft.updatedAt, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            Button {
                                AIConversationStore.shared.delete(id: draft.id)
                                reloadDrafts()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete draft \(draft.title)")
                        }
                    }
                }
                .studioCard(padding: 10)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: AIConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.request)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: StudioDesign.cardCornerRadius))
            }
            VStack(alignment: .leading, spacing: 6) {
                turnOutcome(turn)
                if turn.usage.totalTokens > 0 {
                    Text("\(turn.usage.totalTokens) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(turn.isAbandoned ? 0.5 : 1)
    }

    @ViewBuilder
    private func turnOutcome(_ turn: AIConversationTurn) -> some View {
        switch turn.status {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(activityText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", systemImage: "stop.circle") { session.cancel() }
                    .controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
            }
        case .succeeded:
            Text(turn.note ?? "Done.")
                .textSelection(.enabled)
            if turn.repairs > 0 {
                Label("Fixed automatically \(turn.repairs) time\(turn.repairs == 1 ? "" : "s")", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            versionLine(turn)
        case .unconverged:
            Label("This change did not run, so the widget was left as it was.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let error = turn.errorSummary {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack {
                retryButton(turn, title: "Try Again")
                if let code = turn.failedSource, !code.isEmpty {
                    Button("Show Its Code") { shownCode = ShownCode(title: "Code That Did Not Run", code: code) }
                        .controlSize(.small)
                }
            }
        case .failed:
            Label(turn.errorSummary ?? "The AI provider could not complete the request.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            retryButton(turn, title: "Retry")
        case .cancelled:
            Label("Stopped.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
            retryButton(turn, title: "Send Again")
        case .interrupted:
            Label("Interrupted when the app closed.", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
            retryButton(turn, title: "Send Again")
        }
    }

    @ViewBuilder
    private func versionLine(_ turn: AIConversationTurn) -> some View {
        if let version = conversation.version(turn.versionID) {
            let isCurrent = version.id == conversation.currentVersionID
            HStack(spacing: 8) {
                Label("Version \(version.number)", systemImage: isCurrent ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if isCurrent {
                    Text("shown now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Go to This Version") { session.selectVersion(version.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(session.isRunning)
                }
                if turn.isAbandoned {
                    Text("left behind")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func retryButton(_ turn: AIConversationTurn, title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.clockwise") { session.retry(turnID: turn.id) }
            .controlSize(.small)
            .disabled(session.isRunning || !isConfigured)
    }

    private var activityText: String {
        switch session.activity {
        case .idle: return ""
        case .thinking: return "Writing the widget…"
        case .running: return "Running it…"
        case .repairing(let attempt, _): return "It did not run. Fixing, attempt \(attempt) of \(AIConversationLimits.maxAttemptsPerTurn)…"
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Section("Skills for this conversation") {
                    ForEach(skills) { skill in
                        Toggle(isOn: skillBinding(skill.id)) {
                            Label(skill.title, systemImage: skill.symbol)
                        }
                    }
                }
                Button("Manage Skills…", systemImage: "slider.horizontal.3") {
                    NotificationCenter.default.post(name: SkillManagerOpenRequest.notification, object: nil)
                }
                Section("Examples") {
                    ForEach(AIExamplePrompts.all) { example in
                        Button(example.title, systemImage: example.symbol) {
                            draftText = example.prompt
                            if conversation.versions.isEmpty { session.setSize(example.size) }
                        }
                    }
                }
            } label: {
                Image(systemName: conversation.skillIDs.isEmpty ? "plus.circle" : "plus.circle.fill")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Skills and examples")
            .help(conversation.skillIDs.isEmpty ? "Skills and examples" : "\(conversation.skillIDs.count) skills on")

            TextField(
                conversation.versions.isEmpty ? "Describe the widget you want…" : "Say what to change…",
                text: $draftText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: StudioDesign.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: StudioDesign.controlCornerRadius, style: .continuous)
                    .stroke(StudioDesign.separator, lineWidth: 1)
            }
            .focused($composerFocused)
            .onSubmit(sendDraft)
            .accessibilityLabel("Message to the AI")

            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(10)
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

    private var previewSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview").font(.headline)
                Picker("Size", selection: sizeBinding) {
                    ForEach(AIWidgetSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .help("Changing the size runs the widget again on this Mac. Nothing is sent to the AI.")
                Spacer()
                Toggle("Debug", isOn: $isDebugMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            ZStack(alignment: .topTrailing) {
                StudioDesign.cardBackground
                previewContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.isRunning, session.previewElement != nil {
                    Label("Showing version \(conversation.currentVersion?.number ?? 0) while the AI works", systemImage: "clock")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: .capsule)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 360)
            .clipShape(.rect(cornerRadius: StudioDesign.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: StudioDesign.cardCornerRadius, style: .continuous)
                    .stroke(StudioDesign.separator, lineWidth: 1)
            }

            HStack {
                Button("Code", systemImage: "curlybraces") {
                    shownCode = ShownCode(
                        title: "Version \(conversation.currentVersion?.number ?? 0)",
                        code: session.currentSource
                    )
                }
                .disabled(session.currentSource.isEmpty)
                Button("Logs", systemImage: "text.alignleft") { showingLogs = true }
                    .disabled(session.attemptLogs.isEmpty)
                Spacer()
                usageText
            }
        }
        .padding(12)
    }

    private var usageText: some View {
        let total = conversation.totalUsage.totalTokens
        let last = conversation.turns.last?.usage.totalTokens ?? 0
        return Text("Last turn \(last) · Total \(total) tokens")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Tokens: last turn \(last), total \(total)")
            .opacity(total == 0 ? 0 : 1)
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
            ScrollView([.horizontal, .vertical]) {
                ScriptWidgetElementView(element: element, context: context)
                    .frame(width: size.width, height: size.height)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(conversation.size.previewIsCircular ? size.height / 2 : 10)
                    .padding(16)
            }
            .defaultScrollAnchor(.center)
        } else if session.isRunning {
            VStack(spacing: StudioDesign.standardSpacing) {
                ProgressView()
                Text("Building and checking your widget…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "Nothing to Show Yet",
                systemImage: "sparkles.rectangle.stack",
                description: Text("Describe a widget on the left. It appears here as soon as it runs.")
            )
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            if let current = conversation.currentVersion {
                let index = sortedVersions.firstIndex { $0.id == current.id } ?? 0
                Button("Previous version", systemImage: "chevron.left") {
                    session.selectVersion(sortedVersions[index - 1].id)
                }
                .labelStyle(.iconOnly)
                .disabled(index == 0 || session.isRunning)
                Text("Version \(current.number) of \(sortedVersions.last?.number ?? current.number)")
                    .font(.callout.monospacedDigit())
                Button("Next version", systemImage: "chevron.right") {
                    session.selectVersion(sortedVersions[index + 1].id)
                }
                .labelStyle(.iconOnly)
                .disabled(index >= sortedVersions.count - 1 || session.isRunning)
            } else {
                Text("No version yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Widget name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200, maxWidth: 260)
            Button("Save Widget", systemImage: "square.and.arrow.down", action: performSave)
                .buttonStyle(.borderedProminent)
                .disabled(session.currentSource.isEmpty || session.isRunning
                          || saveName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .onChange(of: conversation.currentVersionID) { _, _ in prefillSaveNameIfNeeded() }
    }

    // MARK: - sheets

    private func codeSheet(_ shown: ShownCode) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(shown.title).font(.headline)
                Spacer()
                Button("Done") { shownCode = nil }
                    .keyboardShortcut(.defaultAction)
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

    private var logsSheet: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Attempts of the Last Turn").font(.headline)
                Spacer()
                Button("Done") { showingLogs = false }
                    .keyboardShortcut(.defaultAction)
            }
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
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - helpers

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var sizeBinding: Binding<AIWidgetSize> {
        Binding(get: { conversation.size }, set: { session.setSize($0) })
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

    private func draftLabel(_ draft: AIConversationSummary) -> String {
        draft.title.isEmpty ? "Untitled" : draft.title
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

    private func prefillSaveNameIfNeeded() {
        guard saveName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saveName = "AI " + Self.defaultNameFormatter.string(from: Date())
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
        let result = sharedScriptManager.createScript(
            content: session.currentSource,
            recommendPackageName: trimmed,
            imageCopyPath: nil
        )
        if result.0 {
            session.markSaved(packageName: trimmed)
            NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
            WidgetCenter.shared.reloadAllTimelines()
            dismiss()
        } else {
            saveError = result.1
        }
    }
}

/// Buttons that wrap onto as many lines as they need.
private struct FlowButtons<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items) { content($0) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}
