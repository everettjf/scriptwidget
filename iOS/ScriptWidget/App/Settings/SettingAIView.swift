//
//  SettingAIView.swift
//  ScriptWidget
//
//  Lets the user manage one or more AI provider profiles plus the
//  global agent-loop knobs. Each profile has its own (host, model,
//  apiKey | OAuth credential).
//

import SwiftUI

struct SettingAIView: View {
    @State private var profiles: [AIProfile] = []
    @State private var activeID: String = ""
    @State private var maxIterations: Int = AISettings.defaultMaxIterations
    @State private var temperature: Double = AISettings.defaultTemperature

    @State private var showingNewProfile = false
    @State private var newProfileTarget: AIProfile?

    var body: some View {
        Form {
            Section {
                ForEach(profiles) { profile in
                    NavigationLink {
                        AIProfileEditorView(profileID: profile.id) {
                            reload()
                        }
                    } label: {
                        profileRow(profile)
                    }
                }
                .onDelete(perform: deleteProfiles)

                Button {
                    addProfile()
                } label: {
                    Label("Add Profile", systemImage: "plus.circle")
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Tap a profile to edit. The active profile is used by AI Generate.")
            }

            Section("Agent Loop") {
                Stepper(value: $maxIterations, in: 5...100, step: 5) {
                    HStack {
                        Text("Max Iterations")
                        Spacer()
                        Text("\(maxIterations)")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: maxIterations) { _ in saveAgentLoop() }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.2f", temperature))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $temperature, in: 0.0...1.5, step: 0.05)
                        .onChange(of: temperature) { _ in saveAgentLoop() }
                }
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            reload()
        }
    }

    private func profileRow(_ profile: AIProfile) -> some View {
        HStack {
            Image(systemName: profile.id == activeID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == activeID ? Color.accentColor : Color.secondary)
                .onTapGesture {
                    AISettingsStore.shared.setActiveProfile(id: profile.id)
                    activeID = profile.id
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "Unnamed" : profile.name)
                        .font(.body)
                    if profile.authMethod == .oauth {
                        Text("OAuth")
                            .font(.caption2)
                            .padding(.horizontal, 6)
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
        }
    }

    private func profileSubtitle(_ profile: AIProfile) -> String {
        let host = URL(string: profile.normalizedBaseURL)?.host ?? profile.normalizedBaseURL
        let model = profile.model.isEmpty ? "—" : profile.model
        return "\(host) · \(model)"
    }

    private func reload() {
        profiles = AISettingsStore.shared.loadProfiles()
        activeID = AISettingsStore.shared.loadActiveProfileID()
        maxIterations = AISettingsStore.shared.loadMaxIterations()
        temperature = AISettingsStore.shared.loadTemperature()
    }

    private func addProfile() {
        let new = AIProfile.makeDefault(named: "New Profile")
        AISettingsStore.shared.upsertProfile(new)
        AISettingsStore.shared.setActiveProfile(id: new.id)
        reload()
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for index in offsets {
            let id = profiles[index].id
            AISettingsStore.shared.deleteProfile(id: id)
        }
        reload()
    }

    private func saveAgentLoop() {
        AISettingsStore.shared.saveAgentLoop(maxIterations: maxIterations, temperature: temperature)
    }
}

// MARK: - Profile editor

struct AIProfileEditorView: View {
    let profileID: String
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

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

    @State private var showingDeleteConfirm = false
    @State private var notFound = false

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
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _ in persist() }
            }

            Section("Provider") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
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
                    }
                }
                TextField("https://api.openai.com", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: baseURL) { _ in persist() }
            }

            Section("Model") {
                TextField("gpt-4o-mini", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model) { _ in persist() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(modelSuggestions, id: \.self) { preset in
                            Button(preset) {
                                model = preset
                                persist()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                Picker("Method", selection: $authMethod) {
                    Text("API Key").tag(AIAuthMethod.apiKey)
                    Text("OpenAI OAuth").tag(AIAuthMethod.oauth)
                }
                .pickerStyle(.segmented)
                .onChange(of: authMethod) { _ in persist() }

                if authMethod == .apiKey {
                    HStack {
                        if apiKeyVisible {
                            TextField("sk-...", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("sk-...", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            apiKeyVisible.toggle()
                        } label: {
                            Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .onChange(of: apiKey) { _ in persist() }
                } else {
                    oauthSection
                }
            } header: {
                Text("Authentication")
            } footer: {
                if authMethod == .apiKey {
                    Text("API key is stored in the Keychain on this device.")
                        .foregroundColor(.secondary)
                } else {
                    Text("OAuth uses the Codex CLI client and only works with the OpenAI host (api.openai.com). The token is stored in the Keychain and refreshed automatically.")
                        .foregroundColor(.secondary)
                }
            }

            Section("Connection") {
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
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Profile", systemImage: "trash")
                }
            }
        }
        .navigationTitle(name.isEmpty ? "Profile" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .alert("Delete this profile?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteSelf() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Profile not found", isPresented: $notFound) {
            Button("OK") { dismiss() }
        }
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
        VStack(alignment: .leading, spacing: 8) {
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
        guard let profile = AISettingsStore.shared.loadProfiles().first(where: { $0.id == profileID }) else {
            notFound = true
            return
        }
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

    private func deleteSelf() {
        AISettingsStore.shared.deleteProfile(id: profileID)
        onChange()
        dismiss()
    }

    private func runTest() {
        // Persist first so the snapshot the AIClient picks up is current.
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
