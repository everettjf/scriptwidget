//
//  AIConversationSession.swift
//  ScriptWidget
//
//  Drives one multi-turn AI conversation for SwiftUI: sends a turn through
//  the agent loop, keeps every successful result as a version, keeps the last
//  good widget on screen when a turn fails, and saves after every change.
//
//  Generated code is untrusted. It only ever runs through AgentRuntimeBridge,
//  in a temporary package, under the same runtime limits as any widget.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor
final class AIConversationSession: ObservableObject {

    enum Activity: Equatable {
        case idle
        case thinking(attempt: Int)
        case running(attempt: Int)
        case repairing(attempt: Int, errorSummary: String)
    }

    @Published private(set) var conversation: AIConversation
    @Published private(set) var activity: Activity = .idle
    /// The current version, rendered at the conversation's size and at the
    /// thumbnail sizes. Rendering happens on this device and sends nothing.
    @Published private(set) var previews: [AIWidgetSize: ScriptWidgetRuntimeElement] = [:]
    /// The code of the reply being written, as far as it has arrived.
    @Published private(set) var liveText = ""
    /// The package the preview was rendered in; views need it to resolve files.
    @Published private(set) var previewPackage: ScriptWidgetPackage?
    /// Console output of each attempt of the newest turn, for the Logs view.
    @Published private(set) var attemptLogs: [AttemptLog] = []

    struct AttemptLog: Identifiable, Equatable {
        let id = UUID()
        let attempt: Int
        let errorSummary: String?
        let lines: [String]
    }

    /// The sizes always rendered next to the chosen one.
    static let thumbnailSizes: [AIWidgetSize] = [.small, .medium, .large]

    var isRunning: Bool { activity != .idle }
    /// How many attempts a turn gets with the provider in use; Apple Private
    /// Cloud Compute gets fewer than the others.
    var attemptLimit: Int {
        AgentLoop.iterationLimit(for: AgentLoopRequest(
            mode: .fresh(userDescription: ""), size: conversation.size, settings: loadSettings(),
            maxIterations: AIConversationLimits.maxAttemptsPerTurn
        ))
    }
    var previewElement: ScriptWidgetRuntimeElement? { previews[conversation.size] }
    /// Hosts the version on screen may contact.
    var currentDomains: [String] { conversation.currentVersion?.networkDomains ?? [] }
    var currentSource: String { conversation.currentVersion?.source ?? "" }

    private let store: AIConversationStore
    private let bridge: AgentRuntimeBridge
    private let makeLoop: () -> AgentLoop
    private let loadSettings: () -> AISettings
    private let skillsText: (Set<String>) -> String?
    /// Set when the conversation is about an existing widget.
    private let sandbox: AgentSandboxSetup?

    /// The temporary preview folder, removed when the session goes away.
    private let previewPackageURL: URL?

    private(set) var currentTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Changes whenever a turn starts or is cancelled; late results are dropped.
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var pendingAttemptCode = ""
    private var pendingDomains: [String] = []

    init(
        conversation: AIConversation = AIConversation(),
        store: AIConversationStore = .shared,
        bridge: AgentRuntimeBridge = .shared,
        makeLoop: @escaping () -> AgentLoop = { AgentLoop() },
        loadSettings: @escaping () -> AISettings = { AISettingsStore.shared.load() },
        skillsText: @escaping (Set<String>) -> String? = { AIWidgetSkills.instructions(selectedIDs: $0) },
        sandbox: AgentSandboxSetup? = nil
    ) {
        self.sandbox = sandbox
        self.conversation = conversation
        self.store = store
        self.bridge = bridge
        self.makeLoop = makeLoop
        self.loadSettings = loadSettings
        self.skillsText = skillsText
        let package = try? bridge.makeSandboxPackage(prefix: "chat-preview")
        if let package, let sandbox { bridge.seed(package, from: sandbox.seedDirectory) }
        previewPackage = package
        previewPackageURL = package?.path
        if conversation.currentVersion != nil { refreshPreview() }
    }

    deinit {
        if let previewPackageURL { try? FileManager.default.removeItem(at: previewPackageURL) }
    }

    // MARK: - turns

    /// Takes over what the editor holds when it is not the current version, so
    /// that the next turn starts from the user's own changes.
    ///
    /// Code that is already one of the conversation's versions is not taken
    /// over: the editor simply has not received a newer version yet, and that
    /// version stays the one being worked on.
    func adoptEditorSource(_ source: String) {
        guard !isRunning, !conversation.versions.contains(where: { $0.source == source }),
              conversation.adoptExternalSource(source, networkDomains: currentDomains) else { return }
        persist()
        refreshPreview()
    }

    /// Sends a new request, continuing from the current version.
    func send(_ text: String, runtimeDiagnostic: String? = nil) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }

        let base = conversation.currentVersion
        let turn = conversation.beginTurn(request: request)
        // Read after beginTurn: it drops the branch the user walked away from.
        let exchanges = conversation.historyForPrompt()
            .map { AITurnContext.Exchange(request: $0.request, note: $0.note) }
        let context = AITurnContext(
            history: exchanges,
            currentCode: base?.source,
            previousCode: conversation.version(base?.parentID)?.source,
            request: turn.request,
            skillsText: skillsText(Set(conversation.skillIDs)),
            size: conversation.size,
            currentDomains: base?.networkDomains ?? [],
            runtimeDiagnostic: runtimeDiagnostic
        )
        persist()
        run(turnID: turn.id, context: context)
    }

    /// Sends a turn that did not succeed once more, from the version it started from.
    func retry(turnID: UUID) {
        guard !isRunning, let turn = conversation.turns.first(where: { $0.id == turnID }),
              turn.status != .succeeded, turn.status != .running else { return }
        if let base = turn.baseVersionID, conversation.version(base) != nil {
            conversation.currentVersionID = base
            refreshPreview()
        }
        // The new turn takes the place of the one that did not succeed.
        conversation.turns.removeAll { $0.id == turnID }
        send(turn.request)
    }

    func cancel() {
        guard isRunning else { return }
        generation = UUID()
        currentTask?.cancel()
        finishRunningTurns(as: .cancelled, message: nil)
        activity = .idle
        liveText = ""
        persist()
    }

    // MARK: - versions, size, skills

    /// Shows another version. Nothing is sent to the provider.
    func selectVersion(_ id: UUID) {
        guard !isRunning, conversation.version(id) != nil, conversation.currentVersionID != id else { return }
        conversation.currentVersionID = id
        conversation.updatedAt = Date()
        persist()
        refreshPreview()
    }

    /// Renders the current version at another size, locally.
    func setSize(_ size: AIWidgetSize) {
        guard conversation.size != size else { return }
        conversation.size = size
        persist()
        // A thumbnail size is already rendered; any other size is rendered now.
        if previews[size] == nil { refreshPreview() }
    }

    func setSkills(_ ids: Set<String>) {
        conversation.skillIDs = ids.sorted()
        persist()
    }

    /// Records that the current version was saved as a widget.
    func markSaved(packageName: String, packageID: String? = nil) {
        conversation.savedPackageName = packageName
        conversation.savedPackageID = packageID
        conversation.updatedAt = Date()
        persist()
    }

    // MARK: - private

    private func run(turnID: UUID, context: AITurnContext) {
        let generation = UUID()
        self.generation = generation
        attemptLogs = []
        pendingAttemptCode = ""
        pendingDomains = []
        liveText = ""
        activity = .thinking(attempt: 1)

        let settings = loadSettings()
        let request = AgentLoopRequest(
            mode: .turn(context),
            size: conversation.size,
            settings: settings,
            maxIterations: AIConversationLimits.maxAttemptsPerTurn,
            sandbox: sandbox
        )
        let loop = makeLoop()
        currentTask = Task { [weak self] in
            let outcome = await loop.run(request) { [weak self] event in
                guard let self, self.generation == generation else { return }
                self.apply(event: event, turnID: turnID)
            }
            guard let self, self.generation == generation else { return }
            self.apply(outcome: outcome, turnID: turnID)
        }
    }

    private func apply(event: AgentLoopEvent, turnID: UUID) {
        switch event {
        case .thinking(let attempt):
            liveText = ""
            if case .repairing = activity { break }
            activity = .thinking(attempt: attempt)
        case .partial(let text):
            liveText = PromptBuilder.previewOfPartialReply(text)
        case .declared(let domains):
            pendingDomains = domains
        case .produced(_, let jsx):
            pendingAttemptCode = jsx
        case .running(let attempt):
            activity = .running(attempt: attempt)
        case .ranFailed(let attempt, let summary, let logs):
            attemptLogs.append(AttemptLog(attempt: attempt, errorSummary: summary, lines: logs))
            conversation.updateTurn(turnID) { $0.repairs += 1 }
            activity = .repairing(attempt: attempt + 1, errorSummary: summary)
        case .ranSucceeded(let attempt):
            attemptLogs.append(AttemptLog(attempt: attempt, errorSummary: nil, lines: []))
        case .tokensUsed(let usage):
            conversation.updateTurn(turnID) { $0.usage = usage }
        case .note(let note):
            // The newest note wins: it describes the attempt that is kept. A repair
            // that leaves the summary out keeps the one before it.
            conversation.updateTurn(turnID) { $0.note = note }
        }
    }

    private func apply(outcome: AgentLoopOutcome, turnID: UUID) {
        activity = .idle
        liveText = ""
        switch outcome {
        case .succeeded(let jsx, let element, let usage):
            guard jsx.utf8.count <= AIConversationLimits.maxSourceBytes else {
                conversation.updateTurn(turnID) {
                    $0.status = .unconverged
                    $0.errorSummary = "The generated widget is larger than a conversation can keep."
                    $0.usage = usage
                }
                break
            }
            let version = conversation.addVersion(source: jsx, networkDomains: pendingDomains)
            conversation.updateTurn(turnID) {
                $0.status = .succeeded
                $0.versionID = version.id
                $0.usage = usage
            }
            showPreview(element: element, source: jsx)
        case .exhausted(let lastJSX, let lastError, let usage):
            conversation.updateTurn(turnID) {
                $0.status = .unconverged
                $0.errorSummary = lastError.map(Self.clipError)
                $0.failedSource = lastJSX.map { String($0.prefix(AIConversationLimits.maxSourceBytes)) }
                $0.usage = usage
            }
        case .cancelled(let usage):
            conversation.updateTurn(turnID) {
                $0.status = .cancelled
                $0.usage = usage
            }
        case .failed(let message, let usage):
            conversation.updateTurn(turnID) {
                $0.status = .failed
                $0.errorSummary = Self.clipError(message)
                $0.usage = usage
            }
        }
        conversation.updatedAt = Date()
        persist()
    }

    private static func clipError(_ text: String) -> String {
        PromptBuilder.clip(text, AIConversationLimits.errorCharacters)
    }

    private func finishRunningTurns(as status: AIConversationTurn.Status, message: String?) {
        for turn in conversation.turns where turn.status == .running {
            conversation.updateTurn(turn.id) {
                $0.status = status
                $0.errorSummary = message
            }
        }
    }

    private func showPreview(element: ScriptWidgetRuntimeElement, source: String) {
        // The loop already rendered the chosen size; the others follow.
        previews = [conversation.size: element]
        refreshPreview(keeping: [conversation.size])
    }

    /// Runs the current version in the preview package: at the chosen size and
    /// at the thumbnail sizes, with the permissions the version declares.
    private func refreshPreview(keeping kept: Set<AIWidgetSize> = []) {
        let token = UUID()
        previewGeneration = token
        previewTask?.cancel()
        guard let previewPackage, let version = conversation.currentVersion else {
            previews = [:]
            return
        }
        previews = previews.filter { kept.contains($0.key) }
        var sizes = [conversation.size] + Self.thumbnailSizes.filter { $0 != conversation.size }
        sizes.removeAll { kept.contains($0) }
        let domains = version.networkDomains ?? []
        let manifest = sandbox.map { $0.manifest(declaring: domains) }
            ?? AINetworkDeclaration.manifest(name: "AI Preview", domains: domains)
        previewTask = Task { [weak self, bridge] in
            for size in sizes {
                let result = await bridge.run(jsx: version.source, in: previewPackage, size: size, manifest: manifest)
                guard let self, self.previewGeneration == token else { return }
                // A version only exists because it ran once; if it fails now (the
                // network is gone, say) the element it does return is still shown.
                self.previews[size] = result.element
            }
        }
    }

    private func persist() {
        // An empty conversation is not worth a file.
        guard !conversation.turns.isEmpty else { return }
        store.save(conversation)
    }

    /// Waits for the turn in flight and for the preview; for tests.
    func settle() async {
        await currentTask?.value
        await previewTask?.value
    }
}
