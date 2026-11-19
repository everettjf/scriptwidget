//
//  AIConversation.swift
//  ScriptWidget
//
//  The saved form of a multi-turn AI conversation about one widget: what the
//  user asked in each turn, what came of it, and every version of the source
//  a successful turn produced.
//
//  A conversation never holds a credential. It names its provider profile by
//  nothing at all: the profile that is active when a turn is sent is used.
//

import Foundation

enum AIConversationLimits {
    /// One generation and up to three repairs.
    static let maxAttemptsPerTurn = 4
    static let maxVersions = 30
    static let maxConversations = 50
    static let maxRequestCharacters = 4_000
    static let maxSourceBytes = 256 * 1024
    static let maxFileBytes = 12 * 1024 * 1024
    /// History sent to the model: the newest turns, shortened.
    static let historyTurns = 12
    static let historyRequestCharacters = 500
    static let historyNoteCharacters = 200
    /// The version before the current one is sent for reference when it is small.
    static let previousSourceCharacters = 8_000
    static let titleCharacters = 40
}

struct AIConversationVersion: Codable, Identifiable, Equatable {
    let id: UUID
    /// 1-based, in the order the versions were made; never reused.
    let number: Int
    let source: String
    let parentID: UUID?
    let createdAt: Date
    /// Hosts the widget declared it contacts; nil or empty for a widget that stays offline.
    var networkDomains: [String]?
}

/// What a generated widget says about its own network use. It is the model's
/// claim, so it is untrusted: it is checked like any manifest, shown to the
/// user before saving, and can only ever name the network permission.
struct AINetworkDeclaration: Equatable {
    static let maximumDomains = 8

    let domains: [String]

    enum ParseResult: Equatable {
        case none
        case declared(AINetworkDeclaration)
        case invalid(String)
    }

    /// Reads `{"permissions": ["network"], "networkDomains": [...]}`.
    static func parse(json: String?) -> ParseResult {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        guard json.utf8.count <= 4_096,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .invalid("it is not a JSON object")
        }
        guard Set(object.keys).isSubset(of: ["permissions", "networkDomains"]) else {
            return .invalid("only \"permissions\" and \"networkDomains\" may appear")
        }
        let permissions = object["permissions"] as? [String] ?? []
        let domains = object["networkDomains"] as? [String] ?? []
        if permissions.isEmpty && domains.isEmpty { return .none }
        guard permissions == ["network"] else {
            return .invalid("\"permissions\" must be exactly [\"network\"]; no other permission can be declared")
        }
        guard !domains.isEmpty, domains.count <= maximumDomains else {
            return .invalid("\"networkDomains\" must list 1 to \(maximumDomains) hosts")
        }
        let declaration = AINetworkDeclaration(domains: domains)
        let scratch = ScriptWidgetPackage(path: FileManager.default.temporaryDirectory, readonly: true)
        let report = WidgetPackageManifestValidator.validate(
            declaration.manifest(name: "AI Preview"), package: scratch, checkEntryExists: false
        )
        guard report.isValid else {
            return .invalid(report.errors.map(\.message).joined(separator: " "))
        }
        return .declared(declaration)
    }

    /// A new Package 2.0 manifest that allows exactly these hosts and nothing else.
    func manifest(name: String) -> WidgetPackageManifest {
        Self.manifest(name: name, domains: domains)
    }

    /// The manifest a widget saved from a conversation gets: no permission at
    /// all, or the network permission for the declared hosts.
    static func manifest(name: String, domains: [String]) -> WidgetPackageManifest {
        var manifest = WidgetPackageManifest.newProject(name: name)
        if !domains.isEmpty {
            manifest.permissions = [.network]
            manifest.networkDomains = domains
        }
        return manifest
    }

    var json: String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["permissions": ["network"], "networkDomains": domains], options: [.sortedKeys]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct AIConversationTurn: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        /// Waiting for the model or running the result. Never read back from disk as such.
        case running
        case succeeded
        /// Every attempt failed to run; the widget was left as it was.
        case unconverged
        /// The provider could not be reached or refused the request.
        case failed
        case cancelled
        /// The app closed while the turn was running.
        case interrupted
    }

    let id: UUID
    /// The user's own words.
    var request: String
    /// The version the turn started from; nil for the first turn of a new widget.
    var baseVersionID: UUID?
    var status: Status
    /// The model's one-sentence account of what it did.
    var note: String?
    /// Why the turn did not succeed; safe to show.
    var errorSummary: String?
    /// How many attempts failed to run before the turn ended.
    var repairs: Int
    /// The version a successful turn produced.
    var versionID: UUID?
    /// The last attempt of an unconverged turn, for the user to look at.
    var failedSource: String?
    var usage: AITokenUsage
    let createdAt: Date
    /// The user went back to an older version and continued from there.
    var isAbandoned: Bool
    /// Not a request: the user changed the code in the editor, and this records
    /// the version that came of it.
    var isManualEdit: Bool?
}

struct AIConversation: Codable, Identifiable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    let id: UUID
    var title: String
    var size: AIWidgetSize
    var skillIDs: [String]
    var turns: [AIConversationTurn]
    var versions: [AIConversationVersion]
    var currentVersionID: UUID?
    /// Counts versions ever made, so a number is not reused after pruning.
    var versionCounter: Int
    /// The widget the conversation was saved as; nil while it is a draft.
    var savedPackageName: String?
    /// That widget's manifest id, which survives a rename; nil for a legacy package.
    var savedPackageID: String?
    let createdAt: Date
    var updatedAt: Date

    init(size: AIWidgetSize = .medium, skillIDs: [String] = [], now: Date = Date()) {
        formatVersion = Self.currentFormatVersion
        id = UUID()
        title = ""
        self.size = size
        self.skillIDs = skillIDs
        turns = []
        versions = []
        currentVersionID = nil
        versionCounter = 0
        savedPackageName = nil
        createdAt = now
        updatedAt = now
    }

    var isDraft: Bool { savedPackageName == nil }
    var currentVersion: AIConversationVersion? { version(currentVersionID) }
    var latestVersion: AIConversationVersion? { versions.max { $0.number < $1.number } }
    var totalUsage: AITokenUsage { turns.reduce(.zero) { $0 + $1.usage } }

    func version(_ id: UUID?) -> AIConversationVersion? {
        guard let id else { return nil }
        return versions.first { $0.id == id }
    }

    /// The turn that produced a version.
    func turn(producing versionID: UUID) -> AIConversationTurn? {
        turns.first { $0.versionID == versionID }
    }

    /// Starts a turn from the current version. Turns made after that version
    /// are marked abandoned: the conversation continues from where the user is.
    mutating func beginTurn(request: String, now: Date = Date()) -> AIConversationTurn {
        abandonTurnsAfterCurrentVersion()
        let turn = AIConversationTurn(
            id: UUID(),
            request: String(request.prefix(AIConversationLimits.maxRequestCharacters)),
            baseVersionID: currentVersionID,
            status: .running,
            note: nil,
            errorSummary: nil,
            repairs: 0,
            versionID: nil,
            failedSource: nil,
            usage: .zero,
            createdAt: now,
            isAbandoned: false
        )
        turns.append(turn)
        if title.isEmpty { title = Self.title(from: request) }
        updatedAt = now
        return turn
    }

    /// Records a version made by a turn and makes it the current one.
    @discardableResult
    mutating func addVersion(source: String, networkDomains: [String] = [], now: Date = Date()) -> AIConversationVersion {
        versionCounter += 1
        let version = AIConversationVersion(
            id: UUID(), number: versionCounter, source: source, parentID: currentVersionID, createdAt: now,
            networkDomains: networkDomains.isEmpty ? nil : networkDomains
        )
        versions.append(version)
        currentVersionID = version.id
        pruneVersions()
        updatedAt = now
        return version
    }

    mutating func updateTurn(_ id: UUID, _ change: (inout AIConversationTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    /// The turns the model is told about: finished, not abandoned, oldest first.
    func historyForPrompt() -> [AIConversationTurn] {
        let finished = turns.filter { $0.status == .succeeded && !$0.isAbandoned && $0.isManualEdit != true }
        return Array(finished.suffix(AIConversationLimits.historyTurns))
    }

    /// Takes over code that did not come from the AI: what the editor holds when
    /// it differs from the current version. Returns whether a version was added.
    @discardableResult
    mutating func adoptExternalSource(_ source: String, networkDomains: [String] = [], now: Date = Date()) -> Bool {
        guard currentVersion?.source != source else { return false }
        abandonTurnsAfterCurrentVersion()
        let base = currentVersionID
        let version = addVersion(source: source, networkDomains: networkDomains, now: now)
        turns.append(AIConversationTurn(
            id: UUID(), request: "", baseVersionID: base, status: .succeeded, note: nil, errorSummary: nil,
            repairs: 0, versionID: version.id, failedSource: nil, usage: .zero, createdAt: now,
            isAbandoned: false, isManualEdit: true
        ))
        return true
    }

    /// A turn left running by a closed app can never finish.
    mutating func markRunningTurnsInterrupted() {
        for index in turns.indices where turns[index].status == .running {
            turns[index].status = .interrupted
        }
    }

    private mutating func abandonTurnsAfterCurrentVersion() {
        guard let currentVersionID, version(currentVersionID) != nil else { return }
        for index in turns.indices {
            // A turn whose version was pruned keeps the state it had.
            guard let produced = version(turns[index].versionID) else { continue }
            let onCurrentPath = produced.id == currentVersionID || isAncestor(produced.id, of: currentVersionID)
            turns[index].isAbandoned = !onCurrentPath
        }
    }

    private func isAncestor(_ candidate: UUID, of versionID: UUID) -> Bool {
        var cursor = version(versionID)?.parentID
        var steps = 0
        while let id = cursor, steps <= versions.count {
            if id == candidate { return true }
            cursor = version(id)?.parentID
            steps += 1
        }
        return false
    }

    /// Keeps the newest versions and always the current one.
    private mutating func pruneVersions() {
        guard versions.count > AIConversationLimits.maxVersions else { return }
        let removable = versions
            .filter { $0.id != currentVersionID }
            .sorted { $0.number < $1.number }
        let excess = versions.count - AIConversationLimits.maxVersions
        let removed = Set(removable.prefix(excess).map(\.id))
        versions.removeAll { removed.contains($0.id) }
    }

    static func title(from request: String) -> String {
        let line = request
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > AIConversationLimits.titleCharacters else { return line }
        return String(line.prefix(AIConversationLimits.titleCharacters)) + "…"
    }
}
