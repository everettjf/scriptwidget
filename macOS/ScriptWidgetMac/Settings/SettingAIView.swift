//
//  SettingAIView.swift
//  ScriptWidgetMac
//
//  Profile-aware AI settings panel. Sidebar lists profiles; the
//  detail pane edits the selected profile. Agent-loop knobs are
//  global and live in their own section.
//

import SwiftUI

struct SettingAIView: View {
    @State private var profiles: [AIProfile] = []
    @State private var activeID: String = ""
    @State private var selectedID: String = ""

    @State private var maxIterations: Int = AISettings.defaultMaxIterations
    @State private var temperature: Double = AISettings.defaultTemperature

    @StateObject private var benchmarkState = AIBenchmarkUIState()

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 220)
                detail
                    .frame(minWidth: 360)
            }
            Divider()
            agentLoopBar
            Divider()
            benchmarkBar
        }
        .padding(0)
        .frame(minWidth: 720, minHeight: 600)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            reload()
        }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button {
                    addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New profile")
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            List(selection: $selectedID) {
                ForEach(profiles) { profile in
                    profileRow(profile).tag(profile.id)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Button {
                    duplicateSelected()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID.isEmpty)
                .help("Duplicate profile")

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID.isEmpty || profiles.count <= 1)
                .help("Delete profile")

                Spacer()
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    private func profileRow(_ profile: AIProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                AISettingsStore.shared.setActiveProfile(id: profile.id)
                activeID = profile.id
            } label: {
                Image(systemName: profile.id == activeID ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(profile.id == activeID ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(profile.id == activeID ? "Active" : "Set active")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(profile.name.isEmpty ? "Unnamed" : profile.name)
                        .font(.body)
                    if profile.authMethod == .oauth {
                        Text("OAuth")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(profileSubtitle(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func profileSubtitle(_ profile: AIProfile) -> String {
        let host = URL(string: profile.normalizedBaseURL)?.host ?? profile.normalizedBaseURL
        let model = profile.model.isEmpty ? "—" : profile.model
        return "\(host) · \(model)"
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        if let profile = profiles.first(where: { $0.id == selectedID }) {
            AIProfileEditorPane(
                profileID: profile.id,
                onChange: reload
            )
            .id(profile.id)
        } else {
            VStack {
                Spacer()
                Text("Select a profile or create a new one.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - benchmark bar

    private var benchmarkBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Benchmark").font(.headline)
                Spacer()
                if benchmarkState.isRunning {
                    Button("Stop") { benchmarkState.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await benchmarkState.run() }
                    } label: {
                        Label("Run Benchmark", systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .disabled(!AISettingsStore.shared.loadActiveProfile().isConfigured)
                }
            }

            switch benchmarkState.phase {
            case .idle:
                Text("Run the agent loop against the bundled template prompts (~3 attempts each, parallel) and write a markdown report. Use a baseline before you change prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .running(let completed, let total, let currentCase):
                let fraction = total > 0 ? Double(completed) / Double(total) : 0
                ProgressView(value: fraction).controlSize(.small)
                Text("\(completed) / \(total) — \(currentCase ?? "…")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            case .finished(let summary, let dir):
                HStack(spacing: 12) {
                    Text(summary).font(.caption)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    } label: {
                        Label("Reveal Report", systemImage: "folder")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    // MARK: - agent loop bar

    private var agentLoopBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Loop (global)").font(.headline)
            HStack(spacing: 24) {
                HStack {
                    Text("Max Iterations")
                    Spacer()
                    Stepper(value: $maxIterations, in: 5...100, step: 5) {
                        Text("\(maxIterations)").monospacedDigit()
                    }
                    .onChange(of: maxIterations) { saveAgentLoop() }
                }

                HStack {
                    Text("Temperature")
                    Slider(value: $temperature, in: 0.0...1.5, step: 0.05)
                        .frame(maxWidth: 200)
                        .onChange(of: temperature) { saveAgentLoop() }
                    Text(String(format: "%.2f", temperature))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding(12)
    }

    // MARK: - actions

    private func reload() {
        profiles = AISettingsStore.shared.loadProfiles()
        activeID = AISettingsStore.shared.loadActiveProfileID()
        if selectedID.isEmpty || !profiles.contains(where: { $0.id == selectedID }) {
            selectedID = activeID.isEmpty ? (profiles.first?.id ?? "") : activeID
        }
        maxIterations = AISettingsStore.shared.loadMaxIterations()
        temperature = AISettingsStore.shared.loadTemperature()
    }

    private func addProfile() {
        let new = AIProfile.makeDefault(named: "New Profile")
        AISettingsStore.shared.upsertProfile(new)
        AISettingsStore.shared.setActiveProfile(id: new.id)
        selectedID = new.id
        reload()
    }

    private func duplicateSelected() {
        guard let original = profiles.first(where: { $0.id == selectedID }) else { return }
        var copy = original
        copy.id = UUID().uuidString
        copy.name = original.name + " Copy"
        AISettingsStore.shared.upsertProfile(copy)
        selectedID = copy.id
        reload()
    }

    private func deleteSelected() {
        guard !selectedID.isEmpty, profiles.count > 1 else { return }
        AISettingsStore.shared.deleteProfile(id: selectedID)
        selectedID = ""
        reload()
    }

    private func saveAgentLoop() {
        AISettingsStore.shared.saveAgentLoop(maxIterations: maxIterations, temperature: temperature)
    }
}

// MARK: - Editor pane (macOS)

private struct AIProfileEditorPane: View {
    let profileID: String
    let onChange: () -> Void

    @State private var name: String = ""
    @State private var baseURL: String = AIProfile.defaultBaseURL
    @State private var model: String = AIProfile.defaultModel
    @State private var apiKey: String = ""
    @State private var authMethod: AIAuthMethod = .apiKey
    @State private var apiKeyVisible: Bool = false

    @State private var oauthAccountID: String = ""
    @State private var oauthExpiresAt: Date?
    @State private var oauthState: OAuthState = .idle
    @State private var oauthError: String?

    @State private var testPhase: TestPhase = .idle
    @State private var testMessage: String = ""

    enum TestPhase { case idle, running, success, failure }
    enum OAuthState { case idle, signingIn, signedIn }

    private static let providerPresets: [(label: String, host: String, models: [String])] = [
        ("OpenAI",   "https://api.openai.com", ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini"]),
        ("DeepSeek", "https://api.deepseek.com", ["deepseek-chat", "deepseek-reasoner"]),
        ("xAI",      "https://api.x.ai", ["grok-2-latest", "grok-2-mini"]),
        ("Local",    "http://localhost:11434", ["llama3.2", "qwen2.5-coder"]),
    ]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { persist() }
            }

            Section("Provider") {
                HStack(spacing: 6) {
                    ForEach(Self.providerPresets, id: \.label) { preset in
                        Button(preset.label) {
                            baseURL = preset.host
                            if let first = preset.models.first {
                                model = first
                            }
                            persist()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                TextField("https://api.openai.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURL) { persist() }
            }

            Section("Model") {
                TextField("gpt-4o-mini", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { persist() }
                HStack(spacing: 6) {
                    ForEach(modelSuggestions, id: \.self) { preset in
                        Button(preset) {
                            model = preset
                            persist()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $authMethod) {
                    Text("API Key").tag(AIAuthMethod.apiKey)
                    Text("OpenAI OAuth").tag(AIAuthMethod.oauth)
                }
                .pickerStyle(.segmented)
                .onChange(of: authMethod) { persist() }

                if authMethod == .apiKey {
                    HStack {
                        Group {
                            if apiKeyVisible {
                                TextField("sk-...", text: $apiKey)
                            } else {
                                SecureField("sk-...", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            apiKeyVisible.toggle()
                        } label: {
                            Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .onChange(of: apiKey) { persist() }
                    Text("API key is stored in the Keychain on this device.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    oauthSection
                    Text("OAuth uses the Codex CLI client and the OpenAI host (api.openai.com). Token lives in the Keychain and refreshes automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Connection") {
                HStack {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            if testPhase == .running { ProgressView().controlSize(.small) }
                            Text("Test Connection")
                        }
                    }
                    .disabled(testPhase == .running || !configured)
                    if !testMessage.isEmpty {
                        Text(testMessage)
                            .font(.footnote)
                            .foregroundStyle(testPhase == .failure ? Color.red : Color.green)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear(perform: load)
    }

    private var modelSuggestions: [String] {
        let host = URL(string: AIProfile(
            id: "", name: "", baseURL: baseURL, model: "", apiKey: "", authMethod: .apiKey
        ).normalizedBaseURL)?.host ?? ""
        if host.contains("deepseek") {
            return ["deepseek-chat", "deepseek-reasoner"]
        } else if host.contains("x.ai") {
            return ["grok-2-latest", "grok-2-mini"]
        } else if host.contains("localhost") || host.contains("127.0.0.1") {
            return ["llama3.2", "qwen2.5-coder", "mistral"]
        } else {
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini"]
        }
    }

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status")
                Spacer()
                switch oauthState {
                case .idle:      Text("Not signed in").foregroundStyle(.secondary)
                case .signingIn: Text("Signing in…").foregroundStyle(.secondary)
                case .signedIn:  Text("Signed in").foregroundColor(.green)
                }
            }
            if oauthState == .signedIn {
                if !oauthAccountID.isEmpty {
                    HStack {
                        Text("Account").foregroundStyle(.secondary)
                        Spacer()
                        Text(oauthAccountID)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let expires = oauthExpiresAt {
                    HStack {
                        Text("Expires").foregroundStyle(.secondary)
                        Spacer()
                        Text(expires, style: .relative)
                            .font(.footnote)
                    }
                }
            }
            if let oauthError {
                Text(oauthError)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
            HStack {
                Button {
                    Task { await runOAuth() }
                } label: {
                    HStack {
                        if oauthState == .signingIn { ProgressView().controlSize(.small) }
                        Image(systemName: "person.badge.key")
                        Text(oauthState == .signedIn ? "Re-Sign In" : "Sign in with OpenAI")
                    }
                }
                .disabled(oauthState == .signingIn)

                if oauthState == .signedIn {
                    Button(role: .destructive) {
                        signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
    }

    private var configured: Bool {
        if authMethod == .apiKey {
            return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            return oauthState == .signedIn
        }
    }

    private func load() {
        guard let profile = AISettingsStore.shared.loadProfiles().first(where: { $0.id == profileID }) else { return }
        name = profile.name
        baseURL = profile.baseURL
        model = profile.model
        apiKey = profile.apiKey
        authMethod = profile.authMethod
        if profile.authMethod == .oauth, !profile.apiKey.isEmpty {
            if let accountID = AIOpenAIOAuthService.accountID(fromAccessToken: profile.apiKey),
               let stored = AIOpenAIOAuthVault.credential(for: accountID) {
                oauthState = .signedIn
                oauthAccountID = accountID
                oauthExpiresAt = stored.expiresAt
            } else {
                oauthState = .idle
            }
        } else {
            oauthState = .idle
        }
    }

    private func currentSnapshot() -> AIProfile {
        AIProfile(
            id: profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod
        )
    }

    private func persist() {
        AISettingsStore.shared.upsertProfile(currentSnapshot())
        onChange()
    }

    private func runTest() {
        persist()
        let combined = AISettings(
            profile: currentSnapshot(),
            maxIterations: AISettingsStore.shared.loadMaxIterations(),
            temperature: AISettingsStore.shared.loadTemperature()
        )
        testPhase = .running
        testMessage = ""
        Task {
            do {
                let messages = [
                    AIMessage(role: .system, content: "You reply with exactly: pong"),
                    AIMessage(role: .user, content: "ping"),
                ]
                let result = try await AIClient.shared.chat(messages: messages, settings: combined)
                await MainActor.run {
                    testPhase = .success
                    testMessage = "OK — \(result.content.prefix(60)) (\(result.usage.totalTokens) tokens)"
                }
            } catch {
                await MainActor.run {
                    testPhase = .failure
                    testMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func runOAuth() async {
        oauthState = .signingIn
        oauthError = nil
        do {
            let credential = try await AIOpenAIOAuthService.signIn(originator: "scriptwidget")
            AIOpenAIOAuthVault.save(credential)
            apiKey = credential.accessToken
            oauthAccountID = credential.accountID
            oauthExpiresAt = credential.expiresAt
            oauthState = .signedIn
            persist()
        } catch {
            oauthError = error.localizedDescription
            oauthState = .idle
        }
    }

    private func signOut() {
        if !oauthAccountID.isEmpty {
            AIOpenAIOAuthVault.remove(accountID: oauthAccountID)
        }
        apiKey = ""
        oauthAccountID = ""
        oauthExpiresAt = nil
        oauthState = .idle
        persist()
    }
}

// MARK: - Benchmark state

@MainActor
final class AIBenchmarkUIState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(completed: Int, total: Int, currentCase: String?)
        case finished(summary: String, reportDir: URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func run() async {
        cancel()
        let cases = AIEvalDataset.loadStandard()
        guard !cases.isEmpty else {
            phase = .failed("No benchmark cases found in Script.bundle.")
            return
        }
        let settings = AISettingsStore.shared.load()
        guard settings.profile.isConfigured else {
            phase = .failed("Active profile is not configured.")
            return
        }
        let totalJobs = cases.count * 3
        phase = .running(completed: 0, total: totalJobs, currentCase: nil)

        task = Task {
            let report = await AIEvalRunner.shared.run(
                cases: cases,
                settings: settings,
                attemptsPerCase: 3,
                parallelism: 3,
                onProgress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .running = self.phase {
                            self.phase = .running(
                                completed: progress.completed,
                                total: progress.total,
                                currentCase: progress.currentCase
                            )
                        }
                    }
                }
            )
            await self.finish(with: report)
        }
        await task?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func finish(with report: AIEvalReport) async {
        do {
            let dir = try AIEvalReportWriter.write(report)
            let summary = String(
                format: "%.1f%% pass · %d perfect / %d total · %@ · tokens %@",
                report.overallPassRate * 100,
                report.perfectCases,
                report.totalCases,
                AIBenchmarkUIState.formatDuration(report.totalDuration),
                AIBenchmarkUIState.formatInt(report.totalTokens)
            )
            phase = .finished(summary: summary, reportDir: dir)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return "\(m)m\(s)s"
    }

    private static func formatInt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
