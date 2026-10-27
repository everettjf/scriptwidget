import Foundation
import CryptoKit
import Darwin

/// Immutable, content-addressed JSON revisions. Never overwrite a remote head:
/// disconnected writers produce two heads which require explicit resolution.
enum ScriptWidgetCloudJSONError: String, Error, LocalizedError {
    case unavailable, notConnected, accountChanged, invalidName, invalidData, limitExceeded, conflict, staleRevision, identityChanged
    var errorDescription: String? { "[icloud:\(rawValue)] iCloud JSON operation could not complete. Existing records are preserved." }
}

struct ScriptWidgetCloudJSONEnvironment {
    let account: String?
    let documents: URL?
    static func live() -> Self {
        // CLI and test hosts must never discover the user's real iCloud.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil,
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              NSClassFromString("XCTestCase") == nil, NSClassFromString("XCTest.XCTestCase") == nil,
              Bundle.main.bundleIdentifier == "com.everettjf.scriptwidget" || Bundle.main.bundleIdentifier == "com.everettjf.scriptwidget.widget" || Bundle.main.bundleIdentifier == "com.everettjf.scriptwidget.macwidget" else { return .init(account: nil, documents: nil) }
        guard let token = FileManager.default.ubiquityIdentityToken,
              let bytes = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else { return .init(account: nil, documents: nil) }
        return .init(account: ScriptWidgetCloudJSONStore.hash(bytes), documents: FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.ScriptWidget")?.appendingPathComponent("Documents"))
    }
}

struct ScriptWidgetCloudJSONGrant: Codable {
    let version: Int
    let store: String
    let account: String
}

/// Uses the same descriptor-relative, no-follow helpers as authored packages.
/// Authority is a native installation UUID + a local native grant, not a name,
/// manifest ID, script environment, exported package or cloud metadata file.
final class ScriptWidgetCloudJSONStore {
    static let maximumValueBytes = 64 * 1024
    static let maximumRevisions = 256
    static let maximumBytes = 2 * 1024 * 1024
    static let queue = DispatchQueue(label: "ScriptWidget.CloudJSON", qos: .utility)
    private let container: URL
    private let owner: String
    private let environment: () -> ScriptWidgetCloudJSONEnvironment
    private let validate: () throws -> Void
    private let rootReceipt: ScriptWidgetStoragePublicationReceipt

    init(container: URL, owner: String, environment: @escaping () -> ScriptWidgetCloudJSONEnvironment = ScriptWidgetCloudJSONEnvironment.live,
         validate: @escaping () throws -> Void) throws {
        guard UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: container.deletingLastPathComponent(), relative: container.lastPathComponent) else { throw ScriptWidgetCloudJSONError.unavailable }
        self.container = container; self.owner = owner; self.environment = environment; self.validate = validate; self.rootReceipt = receipt
    }

    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func canonical(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw ScriptWidgetCloudJSONError.invalidData }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func validName(_ name: String) -> Bool { name.range(of: #"^[a-z][a-z0-9_-]{0,58}\.json$"#, options: .regularExpression) != nil }
    private var grantPath: String { "CloudJSON.v1/grants/\(owner).json" }
    private func check() throws {
        try validate()
        guard try ScriptWidgetPackageFiles.directoryReceipt(root: container.deletingLastPathComponent(), relative: container.lastPathComponent) == rootReceipt else { throw ScriptWidgetCloudJSONError.identityChanged }
    }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try check()
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "CloudJSON.v1.\(owner)", operation: { Result { try check(); return try operation() } }) else { throw ScriptWidgetCloudJSONError.unavailable }
        return try result.get()
    }
    /// A native grant lock protects reconnects; the account/store lock also
    /// serializes two installed widgets explicitly connected to the same cache.
    /// Lock order is always owner, then store, across app and extension processes.
    private func connectedTransaction<T>(_ operation: (ScriptWidgetCloudJSONGrant) throws -> T) throws -> T {
        try transaction {
            let value = try grant()
            guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "CloudJSON.v1.store.\(value.account).\(value.store)", operation: { Result { try check(); return try operation(value) } }) else { throw ScriptWidgetCloudJSONError.unavailable }
            return try result.get()
        }
    }
    private func grant() throws -> ScriptWidgetCloudJSONGrant {
        guard ScriptWidgetPackageFiles.kind(root: container, relative: grantPath) != nil else { throw ScriptWidgetCloudJSONError.notConnected }
        guard let data = ScriptWidgetPackageFiles.read(root: container, relative: grantPath, maximumBytes: 2048),
              let value = try? JSONDecoder().decode(ScriptWidgetCloudJSONGrant.self, from: data), value.version == 1,
              UUID(uuidString: value.store)?.uuidString.lowercased() == value.store,
              value.account.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              try Self.canonical(JSONSerialization.jsonObject(with: data)) == Self.canonical(JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) else { throw ScriptWidgetCloudJSONError.invalidData }
        guard environment().account == value.account else { throw ScriptWidgetCloudJSONError.accountChanged }
        return value
    }
    private func local(_ grant: ScriptWidgetCloudJSONGrant) -> String { "CloudJSON.v1/cache/\(grant.account)/\(grant.store)" }
    private func cloud(_ grant: ScriptWidgetCloudJSONGrant) throws -> (URL, String) {
        let current = environment()
        guard current.account == grant.account else { throw ScriptWidgetCloudJSONError.accountChanged }
        guard let root = current.documents else { throw ScriptWidgetCloudJSONError.unavailable }
        return (root, "WidgetData/\(grant.store)")
    }

    /// App UI only. A package never supplies a store ID to a JavaScript API.
    func connect(existingStore: String? = nil) throws {
        try transaction {
            let env = environment()
            guard let account = env.account, account.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, let root = env.documents else { throw ScriptWidgetCloudJSONError.unavailable }
            let id = existingStore ?? UUID().uuidString.lowercased()
            guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw ScriptWidgetCloudJSONError.invalidName }
            let path = "WidgetData/\(id)"
            if existingStore != nil {
                guard ScriptWidgetPackageFiles.kind(root: root, relative: path) == S_IFDIR else { throw ScriptWidgetCloudJSONError.unavailable }
            } else {
                guard ScriptWidgetPackageFiles.ensureDirectory(root: root, relative: path) else { throw ScriptWidgetCloudJSONError.unavailable }
            }
            let value = ScriptWidgetCloudJSONGrant(version: 1, store: id, account: account)
            try check()
            guard environment().account == account,
                  ScriptWidgetPackageFiles.ensureDirectory(root: container, relative: local(value)),
                  ScriptWidgetPackageFiles.write(try JSONEncoder().encode(value), root: container, relative: grantPath) else { throw ScriptWidgetCloudJSONError.unavailable }
        }
    }
    /// Revoke only this installation's authority; preserve all record files.
    func disconnect() throws {
        try transaction {
            guard ScriptWidgetPackageFiles.removeTree(root: container, relative: grantPath) else { throw ScriptWidgetCloudJSONError.unavailable }
        }
    }
    func connection() throws -> String { try transaction { try grant().store } }
    func availableStores() throws -> [String] {
        try check()
        guard let root = environment().documents else { throw ScriptWidgetCloudJSONError.unavailable }
        if ScriptWidgetPackageFiles.kind(root: root, relative: "WidgetData") == nil { return [] }
        guard let names = ScriptWidgetPackageFiles.list(root: root, relative: "WidgetData", maximumCount: 128) else { throw ScriptWidgetCloudJSONError.limitExceeded }
        return names.filter { UUID(uuidString: $0)?.uuidString.lowercased() == $0 && ScriptWidgetPackageFiles.kind(root: root, relative: "WidgetData/\($0)") == S_IFDIR }.sorted()
    }

    private struct Revision {
        let id: String
        let name: String
        let parents: [String]
        let value: [String: Any]
        let bytes: Data
    }
    private func decode(_ bytes: Data, id: String, name: String) throws -> Revision {
        guard id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              bytes.count <= Self.maximumValueBytes + 64 * 1024, Self.hash(bytes) == id,
              let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(raw.keys) == ["formatVersion", "name", "parents", "value"],
              String(data: try Self.canonical(raw), encoding: .utf8) == String(data: bytes, encoding: .utf8),
              (raw["formatVersion"] as? Int) == 1, raw["name"] as? String == name,
              let parents = raw["parents"] as? [String], parents.count <= Self.maximumRevisions, parents == parents.sorted(), Set(parents).count == parents.count,
              parents.allSatisfy({ $0 != id && $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
              let value = raw["value"] as? [String: Any], try Self.canonical(value).count <= Self.maximumValueBytes else { throw ScriptWidgetCloudJSONError.invalidData }
        guard try Self.canonical(["formatVersion": 1, "name": name, "parents": parents, "value": value]) == bytes else { throw ScriptWidgetCloudJSONError.invalidData }
        return .init(id: id, name: name, parents: parents, value: value, bytes: bytes)
    }
    private func inventory(root: URL, path: String) throws -> [Revision] {
        if ScriptWidgetPackageFiles.kind(root: root, relative: path) == nil {
            // A dangling link/placeholder is not an absent empty store.
            guard ScriptWidgetPackageFiles.safeURL(root: root, relative: path) != nil else { throw ScriptWidgetCloudJSONError.invalidData }
            return []
        }
        guard let files = ScriptWidgetPackageFiles.list(root: root, relative: path, maximumCount: 128) else { throw ScriptWidgetCloudJSONError.limitExceeded }
        var result: [Revision] = []; var total = 0
        for name in files {
            if name == ".DS_Store", ScriptWidgetPackageFiles.kind(root: root, relative: path + "/" + name) == S_IFREG { continue }
            guard Self.validName(name), ScriptWidgetPackageFiles.kind(root: root, relative: path + "/" + name) == S_IFDIR,
                  let revisions = ScriptWidgetPackageFiles.list(root: root, relative: path + "/" + name, maximumCount: Self.maximumRevisions) else { throw ScriptWidgetCloudJSONError.invalidData }
            for file in revisions {
                if file == ".DS_Store", ScriptWidgetPackageFiles.kind(root: root, relative: path + "/" + name + "/" + file) == S_IFREG { continue }
                if file.hasPrefix(".revision-"), UUID(uuidString: String(file.dropFirst(10))) != nil { continue }
                if file.range(of: "^\\.[a-f0-9]{64}\\.json\\.icloud$", options: .regularExpression) != nil {
                    if let url = ScriptWidgetPackageFiles.safeURL(root: root, relative: path + "/" + name + "/" + String(file.dropFirst().dropLast(7))) {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    }
                    throw ScriptWidgetCloudJSONError.unavailable
                }
                guard result.count < Self.maximumRevisions, file.hasSuffix(".json"),
                      let data = ScriptWidgetPackageFiles.read(root: root, relative: path + "/" + name + "/" + file, maximumBytes: Self.maximumValueBytes + 64 * 1024) else { throw ScriptWidgetCloudJSONError.unavailable }
                total += data.count
                guard total <= Self.maximumBytes else { throw ScriptWidgetCloudJSONError.limitExceeded }
                result.append(try decode(data, id: String(file.dropLast(5)), name: name))
            }
        }
        return result
    }
    private func heads(_ revisions: [Revision], name: String) throws -> [Revision] {
        let selected = revisions.filter { $0.name == name }; let ids = Set(selected.map(\.id))
        guard selected.allSatisfy({ Set($0.parents).isSubset(of: ids) }) else { throw ScriptWidgetCloudJSONError.unavailable }
        // Every parent predates its descendant by construction; hostile graphs
        // cannot create a cycle without a SHA-256 fixed point.
        let parents = Set(selected.flatMap(\.parents))
        return selected.filter { !parents.contains($0.id) }.sorted { $0.id < $1.id }
    }
    private func token(_ heads: [Revision]) -> String { heads.isEmpty ? "" : Self.hash(Data(heads.map(\.id).joined(separator: "\n").utf8)) }
    private func publish(_ revision: Revision, root: URL, path: String, createStore: Bool = true) throws {
        let target = path + "/" + revision.name + "/" + revision.id + ".json"
        if let existing = ScriptWidgetPackageFiles.read(root: root, relative: target, maximumBytes: Self.maximumValueBytes + 64 * 1024) {
            guard existing == revision.bytes else { throw ScriptWidgetCloudJSONError.invalidData }; return
        }
        // Open the existing store before creating its document directory.
        // Remote stores are never recreated after deletion, including a race
        // between coordination and publication. No ancestor follows a link.
        let written = ScriptWidgetPackageFiles.withParent(root: root, relative: path + "/" + revision.name, create: createStore) { store, document -> Bool? in
            guard mkdirat(store, document, 0o700) == 0 || errno == EEXIST else { return false }
            let directory = openat(store, document, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { return false }
            defer { close(directory) }
            guard ScriptWidgetPackageFiles.preserveWidgetProtection(directory) else { return false }
            let name = revision.id + ".json"
            let temporary = ".revision-" + UUID().uuidString
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd); _ = unlinkat(directory, temporary, 0) }
            let saved = revision.bytes.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }; offset += count
                }
                return true
            }
            guard ScriptWidgetPackageFiles.preserveWidgetProtection(fd), saved, fsync(fd) == 0 else { return false }
            // Atomic, exclusive publication: never overwrite an existing revision.
            if renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 { return fsync(directory) == 0 }
            return errno == EEXIST && ScriptWidgetPackageFiles.read(root: root, relative: target, maximumBytes: Self.maximumValueBytes + 64 * 1024) == revision.bytes
        }
        guard written == true else { throw ScriptWidgetCloudJSONError.unavailable }
    }
    func status() throws -> [String: Any] {
        try transaction {
            let g = try grant()
            return ["state": environment().documents == nil ? "unavailable" : "connected", "store": g.store,
                    "uploaded": NSNull(), "uploadState": "unknown", "conflictPolicy": "preserveAllVersions"]
        }
    }
    private func response(_ items: [Revision], name: String, pending: Bool) throws -> [String: Any] {
        let values = try heads(items, name: name)
        return ["value": values.count == 1 ? values[0].value : NSNull(), "revision": token(values),
                "state": values.count > 1 ? "conflict" : pending ? "pending" : "cached",
                "conflicts": values.count > 1 ? values.map { ["id": $0.id, "value": $0.value] as [String: Any] } : []]
    }
    func read(_ name: String) throws -> [String: Any] {
        guard Self.validName(name) else { throw ScriptWidgetCloudJSONError.invalidName }
        return try connectedTransaction { g in
            let items = try inventory(root: container, path: local(g))
            // cached is deliberately NOT a claim of upload or convergence.
            return try response(items, name: name, pending: false)
        }
    }
    func write(_ name: String, value: [String: Any], expected: String, resolving: Bool = false) throws -> [String: Any] {
        guard Self.validName(name) else { throw ScriptWidgetCloudJSONError.invalidName }
        return try connectedTransaction { g in
            let path = local(g); let items = try inventory(root: container, path: path); let current = try heads(items, name: name)
            guard token(current) == expected else { throw ScriptWidgetCloudJSONError.staleRevision }
            guard resolving || current.count <= 1 else { throw ScriptWidgetCloudJSONError.conflict }
            guard try Self.canonical(value).count <= Self.maximumValueBytes, items.count < Self.maximumRevisions,
                  items.contains(where: { $0.name == name }) || Set(items.map(\.name)).count < 128,
                  items.reduce(0, { $0 + $1.bytes.count }) + Self.maximumValueBytes + 64 * 1024 <= Self.maximumBytes else { throw ScriptWidgetCloudJSONError.limitExceeded }
            let data = try Self.canonical(["formatVersion": 1, "name": name, "parents": current.map(\.id), "value": value])
            let revision = try decode(data, id: Self.hash(data), name: name)
            try check(); try publish(revision, root: container, path: path)
            return try response(items + [revision], name: name, pending: true)
        }
    }
    /// Explicit bounded synchronization. The file daemon uploads asynchronously;
    /// this result means the currently materialized files were exchanged only.
    func synchronize() throws -> [String: Any] {
        try connectedTransaction { g in
            let (root, remote) = try cloud(g); let path = local(g)
            guard ScriptWidgetPackageFiles.kind(root: root, relative: remote) == S_IFDIR else { throw ScriptWidgetCloudJSONError.unavailable }
            let cached = try inventory(root: container, path: path)
            let incoming = try inventory(root: root, path: remote)
            let merged = Dictionary((cached + incoming).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.id < $1.id }
            guard merged.count <= Self.maximumRevisions, Set(merged.map(\.name)).count <= 128, merged.reduce(0, { $0 + $1.bytes.count }) <= Self.maximumBytes else { throw ScriptWidgetCloudJSONError.limitExceeded }
            try check()
            guard environment().account == g.account else { throw ScriptWidgetCloudJSONError.accountChanged }
            // Copy remote revisions locally before publishing any outgoing data.
            // A malformed or oversized remote revision aborts without replacing it.
            for revision in merged { try publish(revision, root: container, path: path) }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?; var failure: Error?
            coordinator.coordinate(writingItemAt: root.appendingPathComponent(remote), options: [], error: &coordinationError) { _ in
                do {
                    try self.check()
                    guard self.environment().account == g.account else { throw ScriptWidgetCloudJSONError.accountChanged }
                    for revision in merged {
                        try self.check()
                        guard self.environment().account == g.account else { throw ScriptWidgetCloudJSONError.accountChanged }
                        try self.publish(revision, root: root, path: remote, createStore: false)
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }; if coordinationError != nil { throw ScriptWidgetCloudJSONError.unavailable }
            return ["state": "pending", "materializedRevisions": merged.count, "downloadedRevisions": incoming.filter { incoming in !cached.contains { $0.id == incoming.id } }.count, "uploaded": NSNull()]
        }
    }
}
