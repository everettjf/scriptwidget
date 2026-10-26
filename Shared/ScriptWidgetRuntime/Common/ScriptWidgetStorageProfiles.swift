import Foundation

struct ScriptWidgetStorageLibraryProfile: Codable, Equatable, Sendable {
    let id: String
    let path: String
    let receipt: ScriptWidgetStoragePublicationReceipt
    let storageReceipt: ScriptWidgetStoragePublicationReceipt
    let isUsingICloud: Bool
    let includesLegacy: Bool
}

struct ScriptWidgetStorageLibrarySelection: Equatable, Sendable {
    let profile: ScriptWidgetStorageLibraryProfile
    let activationID: String
}

private struct ScriptWidgetStorageProfileIndex: Codable {
    let formatVersion: Int
    var phase: String
    var activeID: String
    var activationID: String
    var profiles: [ScriptWidgetStorageLibraryProfile]
}

private struct ScriptWidgetStorageProfileInventoryEntry: Codable, Equatable {
    let name: String
    let receipt: ScriptWidgetStoragePublicationReceipt
}

private struct ScriptWidgetStorageProfileJournal: Codable {
    let formatVersion: Int
    let original: [ScriptWidgetStorageProfileInventoryEntry]
    let inventoryIsComplete: Bool
    var plans: [ScriptWidgetStorageAdoption]
}

/// Native startup/cutover authority. Library profiles isolate identical names
/// in different libraries. Readers only open ready profiles; activation freezes
/// the previous context before copying records or reconciling directory owners.
/// No imported package, backup or Gallery registry may select a profile UUID.
// This service has only immutable references. All state publication/read
// operations use the process-shared state/worker locks; preferences themselves
// remain Foundation's synchronized implementation.
final class ScriptWidgetStorageProfiles: @unchecked Sendable {
    static var liveLegacyPreferences: UserDefaults {
        UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard
    }
    static let indexKey = "ScriptWidgetStorage.LibraryProfiles.v1"
    private static let journalKey = "ScriptWidgetStorage.LibraryInventory.v1"
    static let maximumProfiles = 16
    private static let stateLock = "ScriptWidgetStorage.LibraryProfiles.v1.state"
    let container: URL
    private let legacy: UserDefaults
    private let files: ScriptWidgetStorageFiles

    init(container: URL, legacy: UserDefaults) throws {
        self.container = container
        self.legacy = legacy
        files = try ScriptWidgetStorageFiles(container: container)
    }

    private static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }

    /// Round-trip comparison rejects unknown fields and unexpected nulls as
    /// well as the decoder's type errors. Present malformed state never means
    /// a fresh install or permission to fall back to legacy names.
    private static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= ScriptWidgetStorageNamespaces.maximumRegistryBytes else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
        let value = try JSONDecoder().decode(type, from: data)
        let original = try JSONSerialization.jsonObject(with: data)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: original, options: options) == JSONSerialization.data(withJSONObject: encoded, options: options) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        return value
    }

    private func load() throws -> ScriptWidgetStorageProfileIndex? {
        guard let bytes = try files.readMetadata(key: Self.indexKey) else { return nil }
        let state = try Self.decode(ScriptWidgetStorageProfileIndex.self, from: bytes)
        guard state.formatVersion == 1, ["preparing", "ready"].contains(state.phase), Self.uuid(state.activeID), Self.uuid(state.activationID),
              (1...Self.maximumProfiles).contains(state.profiles.count),
              Set(state.profiles.map(\.id)).count == state.profiles.count,
              state.profiles.contains(where: { $0.id == state.activeID }),
              state.profiles.filter(\.includesLegacy).count == 1, state.profiles.first?.includesLegacy == true else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        var roots = Set<String>(), stores = Set<String>()
        for profile in state.profiles {
            guard Self.uuid(profile.id), profile.path.hasPrefix("/"), !profile.path.contains("\0"), profile.path.utf8.count <= 4096,
                  URL(fileURLWithPath: profile.path).standardizedFileURL.path == profile.path,
                  profile.receipt.inode > 0, profile.storageReceipt.inode > 0,
                  roots.insert(profile.path + ":" + String(profile.receipt.device) + ":" + String(profile.receipt.inode)).inserted,
                  stores.insert(String(profile.storageReceipt.device) + ":" + String(profile.storageReceipt.inode)).inserted else {
                throw ScriptWidgetStorageNamespaceError.invalidRegistry
            }
        }
        return state
    }

    private func coordinated<T>(_ body: () throws -> T) throws -> T {
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: Self.stateLock, operation: {
            Result { try body() }
        }) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return try result.get()
    }

    private func save(_ state: ScriptWidgetStorageProfileIndex) throws {
        let bytes = try JSONEncoder().encode(state)
        try files.writeMetadata(key: Self.indexKey, data: bytes)
        // All mutations originate from validated native values. Loading again
        // checks the exact same schema and file identity used by other readers.
        _ = try load()
    }

    func profiles() throws -> [ScriptWidgetStorageLibraryProfile] { try coordinated { try load()?.profiles ?? [] } }

    func selectedProfile() throws -> ScriptWidgetStorageLibraryProfile? {
        try coordinated {
            guard let state = try load() else { return nil }
            return state.profiles.first { $0.id == state.activeID }
        }
    }

    func readySelection() throws -> ScriptWidgetStorageLibrarySelection {
        try coordinated {
            guard let state = try load(), state.phase == "ready", let profile = state.profiles.first(where: { $0.id == state.activeID }) else {
                throw ScriptWidgetStorageNamespaceError.inventoryRequired
            }
            return .init(profile: profile, activationID: state.activationID)
        }
    }

    func widgetCacheRoot() throws -> URL {
        let selection = try readySelection()
        let root = try backend(selection.profile).files.widgetCacheDirectory()
        guard try readySelection() == selection else { throw ScriptWidgetStorageNamespaceError.conflict }
        return root
    }

    /// Before any native profile exists, non-storage legacy scripts retain
    /// their old availability even on unsigned hosts without an App Group.
    /// Record access itself always uses the stricter fence below. A present,
    /// malformed or half-present private store is never treated as absence.
    static func validateLegacyExecution(container: URL?) throws {
        guard let container, try ScriptWidgetStorageFiles.hasPrivateStore(container: container, allowMissingContainer: true) else { return }
        try withLegacyAccess(container: container) {}
    }

    /// The same state lock protects publication of `preparing` and the entire
    /// legacy operation, including preference synchronization. Caller order is
    /// owner lock -> profile state lock; activation releases state before using
    /// any identity/record coordinator. The reader's preference instance is unused:
    /// this boundary never bootstraps or queries the migration source.
    static func withLegacyAccess<T>(container: URL?, operation: () throws -> T) throws -> T {
        guard let container else { return try operation() }
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: stateLock, operation: {
            Result {
                if try ScriptWidgetStorageFiles.hasPrivateStore(container: container) {
                    let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: .standard)
                    guard try profiles.load() == nil else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
                }
                return try operation()
            }
        }) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return try result.get()
    }

    func legacyAccessAllowed() -> Bool { (try? coordinated { try load() == nil }) == true }

    private func requireActivation(profileID: String, activationID: String, ready: Bool) throws {
        try coordinated {
            guard let state = try load(), state.activeID == profileID, state.activationID == activationID,
                  state.phase == (ready ? "ready" : "preparing") else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
        }
    }

    private func backend(_ profile: ScriptWidgetStorageLibraryProfile) throws -> ScriptWidgetFileStorageBackend {
        let scoped = try files.profileFiles(id: profile.id, expectedStoreReceipt: profile.storageReceipt)
        return ScriptWidgetFileStorageBackend(files: scoped, legacy: legacy, includesLegacy: profile.includesLegacy)
    }

    private static func source(_ root: URL) throws -> (String, ScriptWidgetStoragePublicationReceipt) {
        guard !ScriptWidgetMetadataFile.isLink(root) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path.utf8.count <= 4096,
              let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: canonical.deletingLastPathComponent(), relative: canonical.lastPathComponent) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        return (canonical.path, receipt)
    }

    /// Extension hosts can open a ready profile but cannot initialize one.
    /// Captured activation IDs stop an old execution even after switching away
    /// from a library and then switching back to the same profile.
    func currentContext(cacheRoot: URL? = nil) throws -> ScriptWidgetPackageStorageContext {
        let (profile, activation): (ScriptWidgetStorageLibraryProfile, String) = try coordinated {
            guard let state = try load(), state.phase == "ready", let profile = state.profiles.first(where: { $0.id == state.activeID }) else {
                throw ScriptWidgetStorageNamespaceError.inventoryRequired
            }
            return (profile, state.activationID)
        }
        let root = URL(fileURLWithPath: profile.path)
        if let cacheRoot {
            let cache = cacheRoot.standardizedFileURL.resolvingSymlinksInPath()
            let source = root.pathComponents, target = cache.pathComponents
            guard !source.starts(with: target), !target.starts(with: source) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        } else {
            guard try Self.source(root).1 == profile.receipt else { throw ScriptWidgetStorageNamespaceError.unavailable }
        }
        let context = try ScriptWidgetPackageStorageContext(libraryRoot: cacheRoot ?? root, container: container, defaults: backend(profile), validateActivation: {
            try self.requireActivation(profileID: profile.id, activationID: activation, ready: true)
        }, expectedLibraryReceipt: cacheRoot == nil ? profile.receipt : nil)
        try context.validateLibraryRoot()
        return context
    }

    /// Serialize first open/recovery with every activation. A second opener
    /// observes ready state without rotating its activation identity.
    func prepareApplicationOpen(initialRoot: URL?, isUsingICloud: Bool) throws {
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "ScriptWidgetStorage.LibraryProfiles.v1.worker", operation: {
            Result {
                if (try? self.readySelection()) != nil { return }
                let previous = try self.selectedProfile()
                guard let root = previous.map({ URL(fileURLWithPath: $0.path) }) ?? initialRoot else {
                    throw ScriptWidgetLibraryOpeningError.storageUnavailable
                }
                if previous == nil, !ScriptManager.ensureLocalDirectory(root) { throw ScriptWidgetLibraryOpeningError.storageUnavailable }
                _ = try self.performActivation(root: root, isUsingICloud: previous?.isUsingICloud ?? isUsingICloud, allowSwitch: false, checkpoint: { _ in })
            }
        }) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        try result.get()
    }

    /// Call only from the native application's startup or an explicit library
    /// switch. The worker lock serializes activations, not ordinary records.
    /// State locks are never held while copying legacy values or using registry
    /// locks, which keeps the context-validation lock order acyclic.
    @discardableResult
    func activate(root: URL, isUsingICloud: Bool, allowSwitch: Bool = false,
                  automaticCandidates: [String: ScriptWidgetStoragePublicationReceipt]? = nil,
                  checkpoint: (String) throws -> Void = { _ in }) throws -> ScriptWidgetPackageStorageContext {
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "ScriptWidgetStorage.LibraryProfiles.v1.worker", operation: {
            Result { try self.performActivation(root: root, isUsingICloud: isUsingICloud, allowSwitch: allowSwitch, automaticCandidates: automaticCandidates, checkpoint: checkpoint) }
        }) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return try result.get()
    }

    private func performActivation(root: URL, isUsingICloud: Bool, allowSwitch: Bool,
                                   automaticCandidates: [String: ScriptWidgetStoragePublicationReceipt]? = nil,
                                   checkpoint: (String) throws -> Void) throws -> ScriptWidgetPackageStorageContext {
        let descriptor = try Self.source(root)
        let (profile, activation): (ScriptWidgetStorageLibraryProfile, String) = try coordinated {
            var state = try load()
            let match = state?.profiles.first { $0.path == descriptor.0 && $0.receipt == descriptor.1 }
            if let state, state.activeID != match?.id && !allowSwitch { throw ScriptWidgetStorageNamespaceError.conflict }
            let profile: ScriptWidgetStorageLibraryProfile
            if let match {
                guard match.isUsingICloud == isUsingICloud else { throw ScriptWidgetStorageNamespaceError.conflict }
                profile = match
            } else {
                guard (state?.profiles.count ?? 0) < Self.maximumProfiles else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                let id = UUID().uuidString.lowercased(), scoped = try files.profileFiles(id: id)
                profile = .init(id: id, path: descriptor.0, receipt: descriptor.1, storageReceipt: scoped.storageReceipt,
                    isUsingICloud: isUsingICloud, includesLegacy: state == nil)
            }
            let activation = state?.phase == "preparing" && state?.activeID == profile.id ? state!.activationID : UUID().uuidString.lowercased()
            if state == nil { state = .init(formatVersion: 1, phase: "preparing", activeID: profile.id, activationID: activation, profiles: [profile]) }
            else {
                if match == nil { state!.profiles.append(profile) }
                state!.phase = "preparing"; state!.activeID = profile.id; state!.activationID = activation
            }
            try save(state!)
            return (profile, activation)
        }
        try checkpoint("preparing")
        let store = try backend(profile)
        let context = try ScriptWidgetPackageStorageContext(libraryRoot: URL(fileURLWithPath: profile.path), container: container, defaults: store, expectedLibraryReceipt: profile.receipt)
        // These recoveries inspect receipts; they never repeat publication or
        // filesystem callbacks from an interrupted application operation.
        _ = try context.recoverInstallation(); _ = try context.recoverRelocation(); _ = try context.recoverReplacement()
        let inventory = try ScriptWidgetLibraryInventory.capture(context: context, isUsingICloud: isUsingICloud)
        var journal: ScriptWidgetStorageProfileJournal
        if let bytes = try store.files.readMetadata(key: Self.journalKey) {
            journal = try Self.decode(ScriptWidgetStorageProfileJournal.self, from: bytes)
            try validate(journal)
        } else {
            journal = .init(formatVersion: 1, original: inventory.entries.keys.sorted().map { .init(name: $0, receipt: inventory.entries[$0]!) },
                inventoryIsComplete: inventory.isComplete, plans: [])
            try store.files.writeMetadata(key: Self.journalKey, data: JSONEncoder().encode(journal))
        }
        try checkpoint("inventory")
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: journal.original.map(\.name), inventoryIsComplete: journal.inventoryIsComplete,
            container: container, defaults: store)
        let (index, bindings) = try ScriptWidgetStorageNamespaces.reviewState(container: container, defaults: store)
        let original = Dictionary(uniqueKeysWithValues: journal.original.map { ($0.name, $0.receipt) })
        let previousPlans = Dictionary(uniqueKeysWithValues: journal.plans.map { ($0.name, $0) })
        if let automaticCandidates {
            guard automaticCandidates.allSatisfy({ inventory.entries[$0.key] == $0.value }) else {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
        }
        // Automatic recovery only adopts readable candidates from this scan.
        // Incomplete downloads stay unbound so later checks can retry them.
        journal.plans = inventory.entries.keys.filter { automaticCandidates == nil || automaticCandidates?[$0] != nil }.sorted().map { name in
            let receipt = inventory.entries[name]!
            let owner = index.owners.first { $0.active && $0.name == name }
            let binding = bindings.first { $0.role == .source && $0.ownerID == owner?.id }
            let previous = previousPlans[name]
            let reuseUnbound = binding == nil && (owner?.legacyName == name && original[name] == receipt || previous?.ownerID == owner?.id && previous?.receipt == receipt)
            let id: String
            if let owner, (binding?.receipt == receipt && binding?.location == context.locationIdentifier && binding?.name == name) || reuseUnbound { id = owner.id }
            else if let previous, previous.receipt == receipt, previous.previousOwnerID == owner?.id, !index.owners.contains(where: { $0.id == previous.ownerID }) { id = previous.ownerID }
            else { id = UUID().uuidString.lowercased() }
            return .init(name: name, ownerID: id, previousOwnerID: owner?.id, receipt: receipt)
        }
        try validate(journal)
        try store.files.writeMetadata(key: Self.journalKey, data: JSONEncoder().encode(journal))
        try checkpoint("planned")
        for plan in journal.plans {
            try ScriptWidgetStorageNamespaces.adoptInventoriedSource(plan, location: context.locationIdentifier, container: container, defaults: store) {
                try self.requireActivation(profileID: profile.id, activationID: activation, ready: false)
                try context.validateLibraryRoot()
                guard try ScriptWidgetPackageFiles.directoryReceipt(root: context.libraryRoot, relative: plan.name) == plan.receipt else { throw ScriptWidgetStorageNamespaceError.conflict }
            }
            try checkpoint("bound")
        }
        let final = try ScriptWidgetLibraryInventory.capture(context: context, isUsingICloud: isUsingICloud)
        guard final.entries == inventory.entries, final.rejectedNames == inventory.rejectedNames else { throw ScriptWidgetStorageNamespaceError.conflict }
        try coordinated {
            guard var state = try load(), state.phase == "preparing", state.activeID == profile.id, state.activationID == activation else {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            state.phase = "ready"; try save(state)
        }
        try checkpoint("ready")
        return try currentContext()
    }

    private func validate(_ journal: ScriptWidgetStorageProfileJournal) throws {
        guard journal.formatVersion == 1, journal.original.count <= ScriptWidgetStorageNamespaces.maximumOwners,
              journal.plans.count <= ScriptWidgetStorageNamespaces.maximumOwners,
              Set(journal.original.map(\.name)).count == journal.original.count,
              Set(journal.plans.map(\.name)).count == journal.plans.count,
              Set(journal.plans.map(\.ownerID)).count == journal.plans.count else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        for entry in journal.original {
            guard try ScriptWidgetStorageNamespaces.canonicalName(entry.name) == entry.name, entry.receipt.inode > 0 else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        }
        for plan in journal.plans {
            guard try ScriptWidgetStorageNamespaces.canonicalName(plan.name) == plan.name, Self.uuid(plan.ownerID),
                  plan.previousOwnerID.map(Self.uuid) ?? true, plan.receipt.inode > 0 else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        }
    }
}

/// Adapts old native consumers without weakening the startup cutover. A legacy
/// transaction's callback receives the underlying backend while the state lock
/// is held, so nested reads neither relock nor escape the publication fence.
final class ScriptWidgetLegacyStorageBackend: ScriptWidgetStorageBackend {
    private let underlying: any ScriptWidgetStorageBackend
    private let container: URL?
    init(_ underlying: any ScriptWidgetStorageBackend, container: URL?) {
        self.underlying = underlying; self.container = container
    }
    private func access<T>(_ operation: () throws -> T) throws -> T {
        try ScriptWidgetStorageProfiles.withLegacyAccess(container: container) {
            guard self.underlying.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
            return try operation()
        }
    }
    func readValue(forKey key: String) throws -> Any? { try access { try underlying.readValue(forKey: key) } }
    func writeValue(_ value: Any, forKey key: String) throws {
        try access {
            try underlying.writeValue(value, forKey: key)
            guard underlying.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
        }
    }
    func removeValue(forKey key: String) throws {
        try access {
            try underlying.removeValue(forKey: key)
            guard underlying.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
        }
    }
    func legacyValues() throws -> [String: Any] { try access { try underlying.legacyValues() } }
    func values(in namespace: String) throws -> [(String, Any)] { try access { try underlying.values(in: namespace) } }
    func synchronize() -> Bool { underlying.synchronize() }
    func mutateValues(in namespace: String, operation: (any ScriptWidgetStorageBackend) throws -> Bool) throws -> Bool {
        try access {
            let saved = try underlying.mutateValues(in: namespace, operation: operation)
            guard !saved || underlying.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
            return saved
        }
    }
}

#if os(macOS) && DEBUG
/// Hosted regression executable entry point. It runs before the app UI and
/// accepts only an existing, uniquely named fixture under this app's temp root.
/// Release builds do not contain this entry point.
enum ScriptWidgetCutoverProcessProbe {
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-storage-cutover-probe") else { return }
        guard arguments.count == 6, arguments[1] == "-storage-cutover-probe", arguments[2] == "write" else { exit(2) }
        let root = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "StorageGateProcess-", id = String(root.lastPathComponent.dropFirst(prefix.count))
        guard root.lastPathComponent.hasPrefix(prefix), UUID(uuidString: id) != nil,
              root.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              !ScriptWidgetMetadataFile.isLink(URL(fileURLWithPath: arguments[3])),
              arguments[4] == "app.scriptwidget.cutover-process." + id,
              ["writer.json", "stopped.json"].contains(arguments[5]) else { exit(2) }
        do {
            guard let defaults = UserDefaults(suiteName: arguments[4]) else { exit(2) }
            let container = root.appendingPathComponent("container")
            let store = ScriptWidgetLegacyStorageBackend(defaults, container: container)
            let namespace = "script.Read."
            var completed = 0, blocked = false
            for _ in 0..<1_000 {
                let saved = ScriptWidgetAtomicPreferences.mutate(container: container, defaults: store, namespace: namespace) { values in
                    let count = try values.readValue(forKey: namespace + "count") as? String ?? "0"
                    guard let number = Int(count) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                    let next = String(number + 1)
                    try values.writeValue(next, forKey: namespace + "count")
                    try values.writeValue(next, forKey: namespace + "mirror")
                    return true
                }
                guard saved else { blocked = true; break }
                completed += 1
                if completed == 1 { try Data().write(to: root.appendingPathComponent("writer-started"), options: .atomic) }
                Thread.sleep(forTimeInterval: 0.001)
            }
            let report: [String: Any] = ["completedWrites": completed, "blocked": blocked]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: root.appendingPathComponent(arguments[5]), options: .atomic)
            exit(blocked ? 0 : 1)
        } catch { exit(1) }
    }
}
#endif

/// An absolute path saved by the app does not grant an extension access to its
/// iCloud container. Each process must ask Foundation to extend its own sandbox
/// before inspecting the selected source. Do not use the returned URL to select
/// another library or change any installation identity.
enum ScriptWidgetICloudContainerAccess {
    static func prepare() {
        // Deterministic tests use temporary libraries, never the host's iCloud.
        guard !ScriptManager.usesIsolatedUnitTestBuildCache else { return }
        establish {
            _ = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.ScriptWidget")
        }
    }

    static func establish(_ operation: @escaping @Sendable () -> Void) {
        guard Thread.isMainThread else { operation(); return }
        // Foundation requires this potentially blocking call off the main
        // thread. Synchronous rendering must wait until access is established.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            operation()
            finished.signal()
        }
        finished.wait()
    }
}

/// Ready-library factory shared by app, widget and action hosts. It never
/// bootstraps from an extension or silently picks another library when the
/// selected source disappears. Cached executions use an entire bound package.
struct ScriptWidgetLibrarySession: Sendable {
    let selection: ScriptWidgetStorageLibrarySelection
    let sourceManager: ScriptManager?
    let cacheManager: ScriptManager
    let cacheRoot: URL
    private let profiles: ScriptWidgetStorageProfiles

    static func activate(profiles: ScriptWidgetStorageProfiles, root: URL, isUsingICloud: Bool,
                         allowSwitch: Bool = false) throws -> Self {
        _ = try profiles.activate(root: root, isUsingICloud: isUsingICloud, allowSwitch: allowSwitch)
        return try Self(profiles: profiles)
    }

    init(profiles: ScriptWidgetStorageProfiles,
         prepareICloudAccess: () -> Void = ScriptWidgetICloudContainerAccess.prepare) throws {
        let selected = try profiles.readySelection()
        if selected.profile.isUsingICloud { prepareICloudAccess() }
        let cache = try profiles.widgetCacheRoot()
        let cached = try profiles.currentContext(cacheRoot: cache)
        let source: ScriptWidgetPackageStorageContext?
        do { source = try profiles.currentContext() }
        catch {
            let directory = URL(fileURLWithPath: selected.profile.path)
            guard !ScriptWidgetMetadataFile.exists(directory), !ScriptWidgetMetadataFile.isLink(directory) else { throw error }
            source = nil
        }
        guard try profiles.readySelection() == selected else { throw ScriptWidgetStorageNamespaceError.conflict }
        selection = selected; cacheRoot = cache; self.profiles = profiles
        cacheManager = ScriptManager(isBuild: true, scriptDirectoryOverride: cache, storageContext: cached, storageRole: .cache)
        sourceManager = source.map { ScriptManager(isBuild: false, scriptDirectoryOverride: $0.libraryRoot,
            storageContext: $0, buildDirectoryOverride: cache, isUsingICloudOverride: selected.profile.isUsingICloud) }
    }

    func validate() throws {
        guard try profiles.readySelection() == selection else { throw ScriptWidgetStorageNamespaceError.conflict }
    }

    /// A healthy source is authoritative, including malformed manifests and
    /// present unreadable entries. Only an absent source/entry or explicit
    /// iCloud placeholder may select a previously authorized complete cache.
    func capture(name: String, cacheOnly: Bool = false) throws -> ScriptWidgetExecutionSnapshot {
        try validate()
        guard ScriptWidgetPackageName.isValid(name) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        var sourceManifest: WidgetPackageManifest?
        var sourceHasManifest: Bool?
        if let manager = sourceManager, let context = manager.storageContext {
            let directory = context.libraryRoot.appendingPathComponent(name)
            if ScriptWidgetMetadataFile.exists(directory) {
                guard !ScriptWidgetMetadataFile.isLink(directory) else { throw ScriptWidgetStorageNamespaceError.unavailable }
                // Check the source's binding before considering cache fallback;
                // an externally replaced directory cannot select an older owner.
                _ = try context.boundDirectory(name: name, role: .source)
                let package = manager.getScriptPackage(packageName: name)
                let placeholders = try Self.hasPlaceholder(root: directory)
                if ScriptWidgetMetadataFile.exists(package.manifestPath) {
                    guard let manifest = package.readManifest(), WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false).isValid else {
                        throw ScriptWidgetStorageNamespaceError.invalidRegistry
                    }
                    sourceManifest = manifest; sourceHasManifest = true
                } else if !ScriptWidgetMetadataFile.exists(directory.appendingPathComponent(".widget.json.icloud")) { sourceHasManifest = false }
                if !placeholders {
                    if package.hasManifest && package.readManifest() == nil { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                    if ScriptWidgetMetadataFile.exists(package.jsxPath) {
                        let captured = try ScriptWidgetExecutionSnapshot(name: name, role: .source, context: context)
                        if !cacheOnly { return captured }
                    }
                } else if ScriptWidgetMetadataFile.exists(package.manifestPath), package.readManifest() == nil {
                    throw ScriptWidgetStorageNamespaceError.invalidRegistry
                }
            }
        }
        guard let context = cacheManager.storageContext else { throw ScriptWidgetStorageNamespaceError.unavailable }
        let snapshot = try ScriptWidgetExecutionSnapshot(name: name, role: .cache, context: context)
        if let sourceHasManifest {
            guard snapshot.package.hasManifest == sourceHasManifest else { throw ScriptWidgetStorageNamespaceError.conflict }
            if let sourceManifest {
                guard let cached = snapshot.package.readManifest() else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(sourceManifest) == encoder.encode(cached) else { throw ScriptWidgetStorageNamespaceError.conflict }
            }
        }
        return snapshot
    }

    static func hasPlaceholder(root: URL) throws -> Bool {
        var count = 0, found = false
        func visit(_ relative: String, depth: Int) throws {
            guard depth <= 16, let names = ScriptWidgetPackageFiles.list(root: root, relative: relative.isEmpty ? nil : relative) else { throw ScriptWidgetStorageNamespaceError.unavailable }
            var identities = Set<String>()
            for name in names {
                if depth == 0 && name == "__Build" { continue }
                guard identities.insert(ScriptWidgetPackageFiles.identity(name)).inserted else { throw ScriptWidgetStorageNamespaceError.invalidName }
                count += 1
                guard count <= 500 else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                let path = relative.isEmpty ? name : relative + "/" + name
                guard let kind = ScriptWidgetPackageFiles.kind(root: root, relative: path) else { throw ScriptWidgetStorageNamespaceError.unavailable }
                if kind == S_IFDIR { try visit(path, depth: depth + 1) }
                else {
                    guard kind == S_IFREG else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                    if name.hasSuffix(".icloud") { found = true }
                    else if let values = try? root.appendingPathComponent(path).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                            let status = values.ubiquitousItemDownloadingStatus, status != .current { found = true }
                }
            }
        }
        try visit("", depth: 0)
        return found
    }
}

/// One entry/resource/permission capture for a native rendering host. Extensions
/// can consume an activation, but never migrate a library or pick its owners.
struct ScriptWidgetHostExecution {
    let package: ScriptWidgetPackage
    let source: String
    let snapshot: ScriptWidgetExecutionSnapshot?

    static func names(in session: ScriptWidgetLibrarySession) throws -> [String] {
        var names = Set<String>()
        for manager in [session.sourceManager, session.cacheManager].compactMap({ $0 }) {
            guard let context = manager.storageContext else { continue }
            let role: ScriptWidgetStorageDirectoryRole = manager.isBuild ? .cache : .source
            for model in manager.listScripts() {
                if (try? context.boundDirectory(name: model.name, role: role)) != nil { names.insert(model.name) }
            }
        }
        try session.validate()
        return names.sorted()
    }

    static func availableNames() throws -> [String] {
        try availableNames(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")) {
            sharedScriptManager.listScripts().map(\.name)
        }
    }

    static func availableNames(container: URL?, legacyNames: () -> [String]) throws -> [String] {
        if let session = try activeSession(container: container) {
            return try names(in: session)
        }
        try ScriptWidgetStorageProfiles.validateLegacyExecution(container: container)
        let names = legacyNames().filter { ScriptWidgetPackageName.isValid($0) }
        try ScriptWidgetStorageProfiles.validateLegacyExecution(container: container)
        return Array(Set(names)).sorted()
    }

    static func activeSession(container: URL?) throws -> ScriptWidgetLibrarySession? {
        guard let container, try ScriptWidgetStorageFiles.hasPrivateStore(container: container, allowMissingContainer: true) else { return nil }
        let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: ScriptWidgetStorageProfiles.liveLegacyPreferences)
        guard !(try profiles.profiles()).isEmpty else { return nil }
        return try ScriptWidgetLibrarySession(profiles: profiles)
    }

    static func load(name: String, cacheOnly: Bool = false) throws -> Self {
        try load(name: name, cacheOnly: cacheOnly,
                 container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")) {
            (cacheOnly ? buildScriptManager : sharedScriptManager).getScriptPackage(packageName: name)
        }
    }

    static func load(name: String, cacheOnly: Bool = false, container: URL?,
                     legacyPackage: () -> ScriptWidgetPackage) throws -> Self {
        guard ScriptWidgetPackageName.isValid(name) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        if let session = try activeSession(container: container) {
            let captured = try session.capture(name: name, cacheOnly: cacheOnly)
            return Self(package: captured.package, source: captured.source, snapshot: captured)
        }
        try ScriptWidgetStorageProfiles.validateLegacyExecution(container: container)
        let package = legacyPackage()
        let read = package.readMainFileResult()
        guard let source = read.content else {
            let message = read.icloud == .downloading
                ? "Downloading from iCloud… Open ScriptWidget to finish syncing."
                : "Script unavailable. Open ScriptWidget to check the selected library."
            throw ScriptWidgetHostReadError(message: message)
        }
        try ScriptWidgetStorageProfiles.validateLegacyExecution(container: container)
        return Self(package: package, source: source, snapshot: nil)
    }
}

struct ScriptWidgetHostReadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// All application consumers resolve an already selected library. Only the
/// application launch/switch coordinator may activate one; resolution is read-only.
enum ScriptWidgetLibraryManagers {
    static func resolve(isBuild: Bool,
                        container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget"),
                        legacy: () -> ScriptManager) -> ScriptManager {
        do {
            guard let session = try ScriptWidgetHostExecution.activeSession(container: container) else { return legacy() }
            if isBuild { return session.cacheManager }
            guard let manager = session.sourceManager else {
                return ScriptManager(isBuild: false, unavailableReason: "The selected library is offline. Reconnect it to edit widgets.")
            }
            return manager
        } catch {
            return ScriptManager(isBuild: isBuild, unavailableReason: "The selected library could not be opened. Finish opening it in ScriptWidget.")
        }
    }
}

/// Switching never closes editors on the user's behalf. Native editor hosts
/// hold a lease until dismantled; a switch cannot run while any lease exists.
enum ScriptWidgetEditorPresence {
    private static let lock = NSRecursiveLock()
    private static var leases = Set<UUID>()
    static func register() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); leases.insert(id); return id
    }
    static func unregister(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        if let id { leases.remove(id) }
    }
    static func withoutEditors<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard leases.isEmpty else { throw ScriptWidgetLibraryOpeningError.editorsOpen }
        return try body()
    }
}

enum ScriptWidgetLibraryOpeningError: LocalizedError {
    case editorsOpen, storageUnavailable, changedChoice
    var errorDescription: String? {
        switch self {
        case .editorsOpen: return "Close all widget editors and stop Web Studio before changing libraries. Your open documents have not been changed."
        case .storageUnavailable: return "The selected library is unavailable. Reconnect its storage and try again."
        case .changedChoice: return "The library changed while you were choosing it. Open the library list again."
        }
    }
}

struct ScriptWidgetLibraryChoice: Identifiable, Equatable, Sendable {
    let id: String
    let root: URL
    let isUsingICloud: Bool
    let title: String
    let isAvailable: Bool
}

/// Application-only entry point. Extensions use ready sessions and cannot call
/// this through JavaScript or an imported manifest. Existing selections always
/// win over a newly available iCloud/default root.
struct ScriptWidgetApplicationLibraryService: Sendable {
    let profiles: ScriptWidgetStorageProfiles
    let initialRoot: URL?
    let initialIsUsingICloud: Bool
    let alternatives: [ScriptWidgetLibraryChoice]

    static func live() throws -> Self {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget") else {
            throw ScriptWidgetLibraryOpeningError.storageUnavailable
        }
        let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: ScriptWidgetStorageProfiles.liveLegacyPreferences)
        var alternatives: [ScriptWidgetLibraryChoice] = []
        if let root = ScriptManager.getICloudRootDirectoryURL() {
            alternatives.append(.init(id: "icloud", root: root.appendingPathComponent("Scripts"), isUsingICloud: true, title: "iCloud Drive", isAvailable: true))
        }
        if let root = ScriptManager.getSandboxRootDirectoryURL() {
            alternatives.append(.init(id: "local", root: root.appendingPathComponent("Scripts"), isUsingICloud: false, title: "On This Device", isAvailable: true))
        }
        return Self(profiles: profiles, initialRoot: alternatives.first?.root,
                    initialIsUsingICloud: alternatives.first?.isUsingICloud ?? false, alternatives: alternatives)
    }

    func open() throws -> ScriptWidgetLibrarySession {
        if (try? profiles.readySelection()) != nil { return try ScriptWidgetLibrarySession(profiles: profiles) }
        return try ScriptWidgetEditorPresence.withoutEditors {
            try profiles.prepareApplicationOpen(initialRoot: initialRoot, isUsingICloud: initialIsUsingICloud)
            return try ScriptWidgetLibrarySession(profiles: profiles)
        }
    }

    /// Application-only recovery of directories delivered after initial opening.
    /// Existing bindings and records remain authoritative. A replaced directory
    /// receives a fresh owner through the same journaled adoption as a rescan.
    func refreshRestoredPackages() throws -> ScriptWidgetLibrarySession? {
        try ScriptWidgetEditorPresence.withoutEditors {
            let previous = try? profiles.readySelection()
            let session = try open()
            guard let context = session.sourceManager?.storageContext else { return nil }
            let inventory = try ScriptWidgetLibraryInventory.capture(context: context, isUsingICloud: session.selection.profile.isUsingICloud)
            let (index, bindings) = try ScriptWidgetStorageNamespaces.reviewState(container: context.container, defaults: context.defaults)
            let activeOwners = Set(index.owners.filter(\.active).map(\.id))
            let registered = Dictionary(uniqueKeysWithValues: bindings.filter {
                $0.role == .source && $0.location == context.locationIdentifier && activeOwners.contains($0.ownerID)
            }.map { ($0.name, $0.receipt) })
            var candidates: [String: ScriptWidgetStoragePublicationReceipt] = [:]
            for (name, receipt) in inventory.entries {
                if registered[name] == receipt { continue }
                let package = ScriptWidgetPackage(path: context.libraryRoot.appendingPathComponent(name), readonly: true)
                guard let hasPlaceholder = try? ScriptWidgetLibrarySession.hasPlaceholder(root: package.path) else { continue }
                if hasPlaceholder {
                    if session.selection.profile.isUsingICloud {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: package.path)
                    }
                    continue
                }
                guard package.readMainFileResult().content != nil else { continue }
                candidates[name] = receipt
            }
            guard !candidates.isEmpty else { return previous == session.selection ? nil : session }
            _ = try profiles.activate(root: context.libraryRoot, isUsingICloud: session.selection.profile.isUsingICloud,
                                      automaticCandidates: candidates)
            return try ScriptWidgetLibrarySession(profiles: profiles)
        }
    }

    func choices() throws -> [ScriptWidgetLibraryChoice] {
        var result: [ScriptWidgetLibraryChoice] = [], paths = Set<String>()
        for profile in try profiles.profiles() {
            let root = URL(fileURLWithPath: profile.path)
            let actual = try? ScriptWidgetPackageFiles.directoryReceipt(root: root.deletingLastPathComponent(), relative: root.lastPathComponent)
            result.append(.init(id: profile.id, root: root, isUsingICloud: profile.isUsingICloud,
                title: profile.isUsingICloud ? "iCloud Drive" : "On This Device", isAvailable: actual == profile.receipt))
            paths.insert(root.path)
        }
        result.append(contentsOf: alternatives.filter { !paths.contains($0.root.path) })
        return result
    }

    /// Native Files/iCloud rescan. It rotates the execution activation but
    /// preserves owners whose bound directories have not changed.
    func refresh() throws -> ScriptWidgetLibrarySession {
        try ScriptWidgetEditorPresence.withoutEditors {
            let selected = try profiles.readySelection()
            return try ScriptWidgetLibrarySession.activate(profiles: profiles,
                root: URL(fileURLWithPath: selected.profile.path), isUsingICloud: selected.profile.isUsingICloud)
        }
    }

    func select(_ choice: ScriptWidgetLibraryChoice) throws -> ScriptWidgetLibrarySession {
        try ScriptWidgetEditorPresence.withoutEditors {
            guard let current = try choices().first(where: { $0.id == choice.id }), current == choice, current.isAvailable else {
                throw ScriptWidgetLibraryOpeningError.changedChoice
            }
            if try profiles.selectedProfile()?.path == choice.root.path,
               (try? profiles.readySelection()) != nil { return try ScriptWidgetLibrarySession(profiles: profiles) }
            // Only a native, explicitly chosen first-time location may be made.
            if alternatives.contains(choice), !ScriptWidgetMetadataFile.exists(choice.root) {
                guard ScriptManager.ensureLocalDirectory(choice.root) else { throw ScriptWidgetLibraryOpeningError.storageUnavailable }
            }
            return try ScriptWidgetLibrarySession.activate(profiles: profiles, root: choice.root, isUsingICloud: choice.isUsingICloud, allowSwitch: true)
        }
    }
}


/// Browser drafts retain the installation selected at connection time, even
/// after a device-side deletion, replacement or library change.
final class ScriptWidgetEditingLibrary: @unchecked Sendable {
    private struct Entry {
        let package: ScriptWidgetPackage
        let receipt: ScriptWidgetStoragePublicationReceipt
    }
    private let manager: ScriptManager
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(manager: ScriptManager) throws {
        guard manager.unavailableReason == nil else { throw ScriptWidgetLibraryOpeningError.storageUnavailable }
        try manager.storageContext?.validateLibraryRoot()
        self.manager = manager
        _ = packages
    }

    var packages: [ScriptWidgetPackage] {
        lock.lock(); defer { lock.unlock() }
        // New names may appear during a session. Once a name has been seen,
        // retain its original installation instead of adopting a replacement.
        for model in manager.listScripts() where entries[model.name] == nil {
            let package = model.package
            guard entries.count < ScriptWidgetStorageNamespaces.maximumOwners, !package.readonly,
                  let receipt = try? ScriptWidgetPackageFiles.directoryReceipt(root: package.path.deletingLastPathComponent(), relative: package.name) else { continue }
            if let scope = package.managedScope, (try? scope.validate(name: package.name)) == nil { continue }
            entries[model.name] = Entry(package: package, receipt: receipt)
        }
        return entries.keys.sorted().compactMap { name in
            guard let entry = entries[name], valid(entry) else { return nil }
            return entry.package
        }
    }
    func package(named name: String) -> ScriptWidgetPackage? { packages.first { $0.name == name } }
    private func valid(_ entry: Entry) -> Bool {
        if let scope = entry.package.managedScope, (try? scope.validate(name: entry.package.name)) == nil { return false }
        return (try? ScriptWidgetPackageFiles.directoryReceipt(root: entry.package.path.deletingLastPathComponent(), relative: entry.package.name)) == entry.receipt
    }
}

/// ActivityKit attributes carry native installation identity, never just an editable script name.
struct ScriptWidgetLiveActivityBinding: Codable, Equatable, Sendable {
    let formatVersion: Int
    let profileID: String
    let ownerID: String

    init(profileID: String, ownerID: String) {
        formatVersion=1;self.profileID=profileID;self.ownerID=ownerID
    }
    var isValid: Bool {
        formatVersion==1 && [profileID,ownerID].allSatisfy { UUID(uuidString:$0)?.uuidString.lowercased()==$0 }
    }

    static func capture(name: String, cacheOnly: Bool = true, container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.everettjf.scriptwidget")) throws -> (Self,ScriptWidgetHostExecution) {
        guard let session=try ScriptWidgetHostExecution.activeSession(container:container) else { throw ScriptWidgetLiveActivityBindingError.libraryUnavailable }
        let captured=try session.capture(name:name,cacheOnly:cacheOnly)
        let binding=Self(profileID:session.selection.profile.id,ownerID:captured.binding.ownerID)
        try session.validate();try captured.validateIdentity()
        return (binding,.init(package:captured.package,source:captured.source,snapshot:captured))
    }

    private func owner(in container: URL?) throws -> (ScriptWidgetLibrarySession,String) {
        guard isValid else { throw ScriptWidgetLiveActivityBindingError.invalidBinding }
        guard let session=try ScriptWidgetHostExecution.activeSession(container:container),let context=session.cacheManager.storageContext else { throw ScriptWidgetLiveActivityBindingError.libraryUnavailable }
        guard session.selection.profile.id==profileID else { throw ScriptWidgetLiveActivityBindingError.differentLibrary }
        guard let owner=try ScriptWidgetStorageNamespaces.owner(id:ownerID,container:context.container,defaults:context.defaults),owner.active else { throw ScriptWidgetLiveActivityBindingError.installationRetired }
        try session.validate()
        return (session,owner.name)
    }

    func currentName(container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.everettjf.scriptwidget")) throws -> String {
        try owner(in:container).1
    }

    func load(cacheOnly: Bool = true, container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.everettjf.scriptwidget")) throws -> ScriptWidgetHostExecution {
        let (session,name)=try owner(in:container)
        let captured=try session.capture(name:name,cacheOnly:cacheOnly)
        guard captured.binding.ownerID==ownerID else { throw ScriptWidgetLiveActivityBindingError.installationUnavailable }
        try captured.validateIdentity();try session.validate()
        return .init(package:captured.package,source:captured.source,snapshot:captured)
    }

}

enum ScriptWidgetLiveActivityBindingError: LocalizedError, Equatable {
    case invalidBinding, libraryUnavailable, differentLibrary, installationUnavailable, installationRetired
    var errorDescription: String? {
        switch self {
        case .invalidBinding:return "Open ScriptWidget to restart this older or invalid Live Activity."
        case .libraryUnavailable:return "The widget library is unavailable. Open ScriptWidget and try again."
        case .differentLibrary:return "This Live Activity belongs to another widget library. End it or switch back to that library."
        case .installationRetired:return "This widget installation was removed. End this Live Activity and start a new one from the installed widget."
        case .installationUnavailable:return "This widget installation is unavailable. Restore its files or end and restart the Live Activity."
        }
    }
}
