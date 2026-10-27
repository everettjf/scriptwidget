import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// Native-owned identities. Package manifests and backup files cannot choose an
/// identity. The prefix deliberately sits outside the old `script.` domain.
enum ScriptWidgetStorageNamespaceError: Error, LocalizedError, Equatable {
    case unavailable, invalidRegistry, invalidName, inventoryRequired, unregistered, reviewRequired, conflict, limitExceeded
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Widget storage is busy or unavailable. Try again."
        case .invalidRegistry: return "The storage identity index is invalid. Existing records have not been changed."
        case .invalidName: return "The widget name is invalid."
        case .inventoryRequired: return "Open ScriptWidget to upgrade local records before using this widget."
        case .unregistered: return "Open ScriptWidget to register this widget's local records."
        case .reviewRequired: return "Open ScriptWidget to review overlapping older records. Original values are preserved."
        case .conflict: return "Records changed after the migration preview. Review them again."
        case .limitExceeded: return "These records exceed the migration limits. Preserve or review the older values before moving them."
        }
    }
}

struct ScriptWidgetStorageOwner: Codable, Equatable {
    var name: String
    let id: String
    var active: Bool
    let legacyName: String
    var galleryID: String? = nil
    var namespace: String { "ScriptWidgetStorage.v2:" + id + ":" }
}

struct ScriptWidgetLegacyStorageCandidate: Codable, Equatable {
    let ownerID: String
    let key: String
}

struct ScriptWidgetLegacyStorageField: Codable, Equatable {
    let key: String
    let candidates: [ScriptWidgetLegacyStorageCandidate]
    var needsReview: Bool
    var resolved: Bool
}

struct ScriptWidgetStorageNamespaceIndex: Codable, Equatable {
    var formatVersion = 1
    var phase: String
    var owners: [ScriptWidgetStorageOwner]
    var legacy: [ScriptWidgetLegacyStorageField]
}

struct ScriptWidgetLegacyStoragePreview {
    let field: ScriptWidgetLegacyStorageField
    let sourceFingerprint: Data
    let targetFingerprints: [String: Data]
    let valueBytes: Int
    let valueType: String
}

/// A native receipt identifies the already-prepared directory, not its contents
/// or an ID supplied by a package. Rename publication preserves this identity.
struct ScriptWidgetStoragePublicationReceipt: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func capture(directory: Int32, groupRoot: URL? = ScriptWidgetStorageVolume.nativeGroupRoot) throws -> Self {
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ScriptWidgetStorageNamespaceError.unavailable }
        let physicalDevice = UInt64(UInt32(bitPattern: info.st_dev))
        guard let identity = try ScriptWidgetStorageVolume.groupIdentity(root: groupRoot) else {
            return .init(device: physicalDevice, inode: info.st_ino)
        }
        let volume = try ScriptWidgetStorageVolume.identifier(directory)
        // Keep the original logical domain so owner IDs, existing journals and
        // location hashes survive a reboot. A mount number is not a volume ID.
        if volume == identity.volume { return .init(device: identity.device, inode: info.st_ino) }
        // Another filesystem cannot collide with this app's legacy domain.
        let digest = SHA256.hash(data: volume).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return .init(device: digest | (1 << 63), inode: info.st_ino)
    }

    func matches(parent: Int32, name: String) -> Bool {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return (try? Self.capture(directory: fd)) == self
    }
}

/// Volume UUIDs survive remounts; st_dev does not. The marker is native private
/// metadata and remains paired with the original directory inode and anchor.
enum ScriptWidgetStorageVolume {
    static let markerName = "volume"
    static let markerMagic = Data("SWVOL001".utf8)
    // The OS group URL is stable for this process. Cache the lookup, not the
    // volume/anchor proof, which is revalidated for every receipt.
    static let nativeGroupRoot: URL? = {
#if SCRIPTWIDGET_CLI
        return nil
#else
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")
#endif
    }()

    static func identifier(_ fd: Int32) throws -> Data {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var data = Data(count: 20)
        let status = data.withUnsafeMutableBytes { fgetattrlist(fd, &attrs, $0.baseAddress, $0.count, 0) }
        guard status == 0, data.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == 20,
              data.dropFirst(4).contains(where: { $0 != 0 }) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return Data(data.dropFirst(4))
    }

    static func anchorReceipt(_ bytes: Data) throws -> ScriptWidgetStoragePublicationReceipt {
        guard bytes.count == 24, [Data("SWANCH01".utf8), Data("SWANCH02".utf8)].contains(Data(bytes.prefix(8))) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return .init(device: bytes[8..<16].reduce(0) { ($0 << 8) | UInt64($1) },
                     inode: bytes[16..<24].reduce(0) { ($0 << 8) | UInt64($1) })
    }

    static func permitsLegacyRecovery(container: URL, groupRoot: URL?, volume: Data) -> Bool {
        guard let groupRoot else { return false }
        let group = groupRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = container.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.pathComponents.starts(with: group.pathComponents) else { return false }
        let fd = open(group.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return (try? identifier(fd)) == volume
    }

    static func groupIdentity(root: URL?) throws -> (volume: Data, device: UInt64)? {
        guard let root else { return nil }
        let parent = open(root.standardizedFileURL.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
        defer { close(parent) }
        let directory = openat(parent, "__WidgetStorage.v2", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            if errno == ENOENT { return nil }
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        defer { close(directory) }
        guard let marker = try readMarker(directory, markerName) else { return nil }
        guard let anchor = try readMarker(parent, ".ScriptWidgetStorage.v2.anchor") else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        let receipt = try anchorReceipt(anchor)
        var info = stat()
        let volume = try identifier(directory)
        guard fstat(directory, &info) == 0, info.st_ino == receipt.inode,
              marker == markerMagic + volume else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return (volume, receipt.device)
    }

    private static func readMarker(_ parent: Int32, _ name: String) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == 24 else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        var bytes = Data(count: 24)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == 24 else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return bytes
    }
}

enum ScriptWidgetStorageDirectoryRole: String, Codable, Sendable {
    case source, cache
}

struct ScriptWidgetStorageDirectoryBinding: Codable, Equatable, Sendable {
    let name: String
    let ownerID: String
    let role: ScriptWidgetStorageDirectoryRole
    let location: String
    let receipt: ScriptWidgetStoragePublicationReceipt
}

private struct ScriptWidgetStorageDirectoryIndex: Codable {
    let formatVersion: Int
    var entries: [ScriptWidgetStorageDirectoryBinding]
}

enum ScriptWidgetStoragePublicationState {
    case absent, matching, different
}

enum ScriptWidgetStorageInstallationRecovery: Equatable {
    case none, committed(ScriptWidgetStorageOwner), rolledBack
}

private struct ScriptWidgetStorageInstallation: Codable {
    let formatVersion: Int
    let location: String
    let owner: ScriptWidgetStorageOwner
    let previousOwnerID: String?
    let receipt: ScriptWidgetStoragePublicationReceipt
}

private struct ScriptWidgetStorageRelocation: Codable {
    let formatVersion: Int
    let binding: ScriptWidgetStorageDirectoryBinding
    let destination: String
    let deleting: Bool
}

enum ScriptWidgetStorageRelocationRecovery: Equatable {
    case none, committed(source: String, destination: String, deleting: Bool), rolledBack
}

struct ScriptWidgetStorageCleanup: Codable, Equatable {
    let location: String
    let name: String
    let receipt: ScriptWidgetStoragePublicationReceipt
}

private struct ScriptWidgetStorageReplacement: Codable {
    let formatVersion: Int
    let source: ScriptWidgetStorageDirectoryBinding
    let staging: String
    let receipt: ScriptWidgetStoragePublicationReceipt
    let galleryID: String
}

enum ScriptWidgetStorageReplacementRecovery: Equatable {
    case none, committed, rolledBack
}

/// A private startup journal plans the UUID before any registry mutation. The
/// native profile remains inaccessible until every planned binding is complete.
struct ScriptWidgetStorageAdoption: Codable, Equatable {
    let name: String
    let ownerID: String
    let previousOwnerID: String?
    let receipt: ScriptWidgetStoragePublicationReceipt
}

/// This coordinator intentionally has no dependency on package models or JS.
/// Bootstrap inventories and fresh-install/rename/retire calls are native-only.
/// Legacy originals remain untouched, including values that need user review.
enum ScriptWidgetStorageNamespaces {
    static let registryKey = "ScriptWidgetStorage.IdentityIndex.v2"
    static let registryLock = "ScriptWidgetStorage.IdentityIndex.v2.lock"
    static let installationKey = "ScriptWidgetStorage.Installation.v2"
    static let replacementKey = "ScriptWidgetStorage.Replacement.v2"
    static let cleanupKey = "ScriptWidgetStorage.Cleanup.v2"
    static let replacementPrefix = ".ScriptWidgetReplacement.v2."
    static let maximumCleanupEntries = 128
    static let relocationKey = "ScriptWidgetStorage.Relocation.v2"
    static let retiredDirectoryPrefix = ".ScriptWidgetRetired.v2."
    static let directoriesKey = "ScriptWidgetStorage.Directories.v2"
    static let maximumDirectoryBindings = maximumOwners * 2
    static let maximumRegistryBytes = 4 * 1024 * 1024
    static let maximumOwners = 4096
    static let maximumLegacyFields = 8192
    static let maximumNamespaceKeys = 1024
    static let maximumNamespaceBytes = 2 * 1024 * 1024
    static let maximumLegacyValueBytes = 16 * 1024 * 1024

    static func canonicalName(_ name: String) throws -> String {
        guard name.utf8.count <= 240 else { throw ScriptWidgetStorageNamespaceError.invalidName }
        let name = name.precomposedStringWithCanonicalMapping
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, name.utf8.count <= 240,
              !name.hasPrefix("."), name.lowercased() != "__build", !name.contains("/"), !name.contains("\\"),
              name.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0.value == 0x200C || $0.value == 0x200D }) else {
            throw ScriptWidgetStorageNamespaceError.invalidName
        }
        return name
    }

    private static func uuid() -> String { UUID().uuidString.lowercased() }
    private static func isUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func integer(_ value: Any?, equals: Int) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == Double(equals)
    }
    private static func bool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func decode(_ data: Data) throws -> ScriptWidgetStorageNamespaceIndex {
        guard data.count <= maximumRegistryBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "phase", "owners", "legacy"], integer(object["formatVersion"], equals: 1),
              let phase = object["phase"] as? String, ["prepared", "ready"].contains(phase),
              let owners = object["owners"] as? [[String: Any]], owners.count <= maximumOwners,
              let legacy = object["legacy"] as? [[String: Any]], legacy.count <= maximumLegacyFields else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        var ids = Set<String>(), activeNames = Set<String>(), legacyNamesByID: [String: String] = [:]
        for owner in owners {
            guard Set(owner.keys).subtracting(["galleryID"]) == ["name", "id", "active", "legacyName"],
                  owner["galleryID"] == nil || validGalleryID(owner["galleryID"]), let legacyName = owner["legacyName"] as? String,
                  legacyName.isEmpty || (try? canonicalName(legacyName)) == legacyName, let name = owner["name"] as? String,
                  (try? canonicalName(name)) == name, let id = owner["id"] as? String, isUUID(id), ids.insert(id).inserted,
                  bool(owner["active"]), let active = owner["active"] as? Bool else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            if active && !activeNames.insert(name).inserted { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            legacyNamesByID[id] = legacyName
        }
        let activeGalleryIDs = owners.filter { $0["active"] as? Bool == true }.compactMap { $0["galleryID"] as? String }
        guard Set(activeGalleryIDs.map { $0.lowercased() }).count == activeGalleryIDs.count else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        var fieldNames = Set<String>(), bindings = Set<String>()
        for field in legacy {
            guard Set(field.keys) == ["key", "candidates", "needsReview", "resolved"], let key = field["key"] as? String,
                  key.hasPrefix("script."), key.utf8.count <= 4096, fieldNames.insert(key).inserted,
                  bool(field["needsReview"]), bool(field["resolved"]), let candidates = field["candidates"] as? [[String: Any]], candidates.count <= 64 else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            var fieldOwners = Set<String>()
            for candidate in candidates {
                guard Set(candidate.keys) == ["ownerID", "key"], let id = candidate["ownerID"] as? String, ids.contains(id),
                      fieldOwners.insert(id).inserted, let suffix = candidate["key"] as? String, !suffix.isEmpty, suffix.utf8.count <= 4096,
                      let originalName = legacyNamesByID[id], !originalName.isEmpty,
                      key == "script." + originalName + "." + suffix,
                      bindings.insert(id + ":" + suffix).inserted else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            }
            if candidates.count != 1 && field["needsReview"] as? Bool != true { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            if phase == "prepared" && field["resolved"] as? Bool == true { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            if phase == "ready" && field["needsReview"] as? Bool == false && field["resolved"] as? Bool != true { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        }
        guard let index = try? JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: data) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return index
    }

    private static func load(_ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageNamespaceIndex? {
        guard let existing = try store.readValue(forKey: registryKey) else { return nil }
        guard let bytes = existing as? Data else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return try decode(bytes)
    }
    private static func save(_ index: ScriptWidgetStorageNamespaceIndex, _ store: any ScriptWidgetStorageBackend) throws {
        let bytes = try JSONEncoder().encode(index)
        _ = try decode(bytes)
        try store.writeValue(bytes, forKey: registryKey)
        guard store.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }
    private static func coordinated<T>(container: URL, defaults: any ScriptWidgetStorageBackend, operation: () throws -> T) throws -> T {
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: registryLock, operation: { () -> Result<T, Error> in
            guard defaults.synchronize() else { return .failure(ScriptWidgetStorageNamespaceError.unavailable) }
            return Result { try operation() }
        }) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return try result.get()
    }

    private static func decodeDirectories(_ data: Data) throws -> ScriptWidgetStorageDirectoryIndex {
        guard data.count <= maximumRegistryBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "entries"], integer(object["formatVersion"], equals: 1),
              let entries = object["entries"] as? [[String: Any]], entries.count <= maximumDirectoryBindings else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        var ownersAndRoles = Set<String>()
        for entry in entries {
            guard Set(entry.keys) == ["name", "ownerID", "role", "location", "receipt"],
                  let name = entry["name"] as? String, (try? canonicalName(name)) == name,
                  let ownerID = entry["ownerID"] as? String, isUUID(ownerID),
                  let role = entry["role"] as? String, ScriptWidgetStorageDirectoryRole(rawValue: role) != nil,
                  let location = entry["location"] as? String, validLocation(location),
                  let receipt = entry["receipt"] as? [String: Any], Set(receipt.keys) == ["device", "inode"],
                  receipt.values.allSatisfy({ value in
                      guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
                      return UInt64(value.stringValue) != nil
                  }), let inode = receipt["inode"] as? NSNumber, inode.uint64Value > 0,
                  ownersAndRoles.insert(ownerID + ":" + role).inserted else {
                throw ScriptWidgetStorageNamespaceError.invalidRegistry
            }
        }
        // Decode the same normalized object that was validated above.
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let result = try? JSONDecoder().decode(ScriptWidgetStorageDirectoryIndex.self, from: normalized) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        return result
    }

    private static func directories(_ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageDirectoryIndex {
        guard let value = try store.readValue(forKey: directoriesKey) else { return .init(formatVersion: 1, entries: []) }
        guard let data = value as? Data else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return try decodeDirectories(data)
    }

    private static func saveDirectories(_ value: ScriptWidgetStorageDirectoryIndex, _ store: any ScriptWidgetStorageBackend) throws {
        let data = try JSONEncoder().encode(value)
        _ = try decodeDirectories(data)
        try store.writeValue(data, forKey: directoriesKey)
        guard store.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }

    private static func setDirectory(_ binding: ScriptWidgetStorageDirectoryBinding, index: ScriptWidgetStorageNamespaceIndex, store: any ScriptWidgetStorageBackend) throws {
        guard index.owners.contains(where: { $0.id == binding.ownerID && $0.name == binding.name }) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        var value = try directories(store)
        // Retained identities keep their own receipts. Lookup additionally
        // requires the current active owner; an interrupted fresh install must
        // not erase the previous owner's working fallback-cache binding.
        value.entries.removeAll { $0.ownerID == binding.ownerID && $0.role == binding.role }
        value.entries.append(binding)
        try saveDirectories(value, store)
    }

    private static func removeUnexposedDirectories(ownerID: String, store: any ScriptWidgetStorageBackend) throws {
        var value = try directories(store)
        let count = value.entries.count
        value.entries.removeAll { $0.ownerID == ownerID }
        if value.entries.count != count { try saveDirectories(value, store) }
    }

    private static func availableOwner(name: String, index: ScriptWidgetStorageNamespaceIndex, store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageOwner {
        if let pending = try replacement(store), pending.source.name == name { throw ScriptWidgetStorageNamespaceError.unavailable }
        if let pending = try relocation(store), pending.binding.name == name || (!pending.deleting && pending.destination == name) {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        if let pending = try installation(store), pending.owner.name == name { throw ScriptWidgetStorageNamespaceError.unavailable }
        guard index.phase == "ready", let owner = index.owners.first(where: { $0.active && $0.name == name }) else {
            throw ScriptWidgetStorageNamespaceError.unregistered
        }
        guard !index.legacy.contains(where: { !$0.resolved && $0.candidates.contains(where: { $0.ownerID == owner.id }) }) else {
            throw ScriptWidgetStorageNamespaceError.reviewRequired
        }
        return owner
    }

    /// Initial native inventory may associate an existing source once. It
    /// cannot adopt new locations or directories from a manifest or backup.
    static func bindInventoriedSource(name: String, location: String, receipt: ScriptWidgetStoragePublicationReceipt,
                                     container: URL, defaults: any ScriptWidgetStorageBackend) throws {
        let name = try canonicalName(name)
        guard validLocation(location), receipt.inode > 0 else { throw ScriptWidgetStorageNamespaceError.invalidName }
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults), index.phase == "ready",
                  let owner = index.owners.first(where: { $0.active && $0.name == name }), owner.legacyName == name else {
                throw ScriptWidgetStorageNamespaceError.unregistered
            }
            let binding = ScriptWidgetStorageDirectoryBinding(name: name, ownerID: owner.id, role: .source, location: location, receipt: receipt)
            if let existing = try directories(defaults).entries.first(where: { $0.ownerID == owner.id && $0.role == .source }), existing != binding {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            try setDirectory(binding, index: index, store: defaults)
        }
    }

    /// Native startup only: adopt a verified, already-present directory. The
    /// outer profile journal freezes readers and persists this plan first.
    /// Retrying after either metadata write reuses exactly the planned UUID.
    static func adoptInventoriedSource(_ plan: ScriptWidgetStorageAdoption, location: String, container: URL,
                                      defaults: any ScriptWidgetStorageBackend, validate: () throws -> Void) throws {
        guard try canonicalName(plan.name) == plan.name, isUUID(plan.ownerID),
              plan.previousOwnerID.map(isUUID) ?? true, validLocation(location), plan.receipt.inode > 0 else {
            throw ScriptWidgetStorageNamespaceError.invalidName
        }
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            try validate()
            guard var index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            let binding = ScriptWidgetStorageDirectoryBinding(name: plan.name, ownerID: plan.ownerID, role: .source, location: location, receipt: plan.receipt)
            if let existing = index.owners.first(where: { $0.id == plan.ownerID }) {
                guard existing.active, existing.name == plan.name else { throw ScriptWidgetStorageNamespaceError.conflict }
            } else {
                let previous = index.owners.firstIndex { $0.active && $0.name == plan.name }
                guard previous.map({ index.owners[$0].id }) == plan.previousOwnerID,
                      index.owners.count < maximumOwners else { throw ScriptWidgetStorageNamespaceError.conflict }
                if let previous { index.owners[previous].active = false }
                index.owners.append(.init(name: plan.name, id: plan.ownerID, active: true, legacyName: ""))
                try save(index, defaults)
            }
            if let previous = try directories(defaults).entries.first(where: { $0.ownerID == plan.ownerID && $0.role == .source }), previous != binding {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            try setDirectory(binding, index: index, store: defaults)
        }
    }

    static func boundDirectory(name: String, role: ScriptWidgetStorageDirectoryRole, location: String,
                               receipt: ScriptWidgetStoragePublicationReceipt, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageDirectoryBinding {
        let name = try canonicalName(name)
        guard validLocation(location), receipt.inode > 0 else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            guard let index = try load(defaults) else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            let owner = try availableOwner(name: name, index: index, store: defaults)
            guard let binding = try directories(defaults).entries.first(where: {
                $0.name == name && $0.ownerID == owner.id && $0.role == role && $0.location == location && $0.receipt == receipt
            }) else { throw ScriptWidgetStorageNamespaceError.unregistered }
            return binding
        }
    }

    /// Copies/validation happen before this call. A cache publication may bind
    /// only to the exact authenticated source snapshot captured before copying.
    /// An unrecorded cache replacement remains unreadable and can be rebuilt.
    static func publishCache(source: ScriptWidgetStorageDirectoryBinding, location: String, receipt: ScriptWidgetStoragePublicationReceipt,
                             container: URL, defaults: any ScriptWidgetStorageBackend,
                             sourceStillMatches: () throws -> Bool,
                             inspect: () throws -> ScriptWidgetStoragePublicationState,
                             publish: () throws -> Void) throws -> ScriptWidgetStorageDirectoryBinding {
        guard source.role == .source, validLocation(location), receipt.inode > 0 else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults) else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            let owner = try availableOwner(name: source.name, index: index, store: defaults)
            guard owner.id == source.ownerID, try directories(defaults).entries.contains(source), try sourceStillMatches() else {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            var publicationError: Error?
            do { try publish() } catch { publicationError = error }
            guard try inspect() == .matching, try sourceStillMatches() else {
                throw publicationError ?? ScriptWidgetStorageNamespaceError.conflict
            }
            let binding = ScriptWidgetStorageDirectoryBinding(name: source.name, ownerID: owner.id, role: .cache, location: location, receipt: receipt)
            try setDirectory(binding, index: index, store: defaults)
            return binding
        }
    }

    private static func installation(_ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageInstallation? {
        guard let value = try store.readValue(forKey: installationKey) else { return nil }
        guard let data = value as? Data, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["formatVersion", "location", "owner", "previousOwnerID", "receipt"]),
              Set(object.keys).isSuperset(of: ["formatVersion", "location", "owner", "receipt"]),
              integer(object["formatVersion"], equals: 1),
              let location = object["location"] as? String, validLocation(location),
              let owner = object["owner"] as? [String: Any],
              Set(owner.keys).subtracting(["galleryID"]) == ["name", "id", "active", "legacyName"],
              owner["galleryID"] == nil || validGalleryID(owner["galleryID"]),
              let name = owner["name"] as? String, (try? canonicalName(name)) == name,
              let id = owner["id"] as? String, isUUID(id), bool(owner["active"]), owner["active"] as? Bool == false,
              owner["legacyName"] as? String == "",
              let receipt = object["receipt"] as? [String: Any], Set(receipt.keys) == ["device", "inode"],
              receipt.values.allSatisfy({ value in
                  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                  return UInt64(number.stringValue) != nil
              }),
              let result = try? JSONDecoder().decode(ScriptWidgetStorageInstallation.self, from: data), result.receipt.inode > 0,
              result.previousOwnerID == nil || (isUUID(result.previousOwnerID!) && result.previousOwnerID != id) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        // JSON null is not the same as an absent optional native field.
        if let previous = object["previousOwnerID"] {
            guard let previous = previous as? String, previous == result.previousOwnerID else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        }
        return result
    }

    private static func validGalleryID(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$", options: .regularExpression) != nil
    }

    static func gallerySource(itemID: String, location: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageDirectoryBinding? {
        guard validGalleryID(itemID), validLocation(location) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            guard let owner = index.owners.first(where: { $0.active && $0.galleryID?.lowercased() == itemID.lowercased() }) else { return nil }
            _ = try availableOwner(name: owner.name, index: index, store: defaults)
            guard let binding = try directories(defaults).entries.first(where: { $0.ownerID == owner.id && $0.role == .source && $0.location == location && $0.name == owner.name }) else {
                throw ScriptWidgetStorageNamespaceError.unregistered
            }
            return binding
        }
    }

    private static func validLocation(_ location: String) -> Bool {
        location.utf8.count == 64 && location.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func requireNoInstallation(_ store: any ScriptWidgetStorageBackend) throws {
        guard try installation(store) == nil, try relocation(store) == nil, try replacement(store) == nil else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }

    private static func saveInstallation(_ value: ScriptWidgetStorageInstallation?, _ store: any ScriptWidgetStorageBackend) throws {
        if let value {
            let data = try JSONEncoder().encode(value)
            guard data.count <= 4096 else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
            try store.writeValue(data, forKey: installationKey)
        } else { try store.removeValue(forKey: installationKey) }
        guard store.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }

    /// Checks an interrupted journal against the current native registry before
    /// any repair. Other identity mutations are excluded while a journal exists.
    private static func installationIndex(_ ticket: ScriptWidgetStorageInstallation, _ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageNamespaceIndex {
        guard var index = try load(store), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        if let existing = index.owners.first(where: { $0.id == ticket.owner.id }) {
            guard existing.name == ticket.owner.name, existing.legacyName.isEmpty, existing.galleryID == ticket.owner.galleryID else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        } else {
            guard index.owners.count < maximumOwners else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
            index.owners.append(ticket.owner)
        }
        if let previous = ticket.previousOwnerID {
            guard let owner = index.owners.first(where: { $0.id == previous }), owner.name == ticket.owner.name else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        }
        guard !index.owners.contains(where: { $0.active && $0.name == ticket.owner.name && $0.id != ticket.owner.id && $0.id != ticket.previousOwnerID }) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        return index
    }

    private static func finishInstallation(_ ticket: ScriptWidgetStorageInstallation, state: ScriptWidgetStoragePublicationState, _ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageInstallationRecovery {
        // A different directory or an inspection error is not evidence that
        // publication failed. Keep the journal and deny access pending repair.
        guard state != .different else { throw ScriptWidgetStorageNamespaceError.conflict }
        var index = try installationIndex(ticket, store)
        if let committed = index.owners.first(where: { $0.id == ticket.owner.id && $0.active }) {
            // Identity commit completed before a crash clearing the journal.
            // A later disappearance cannot restore the previous identity.
            try setDirectory(.init(name: committed.name, ownerID: committed.id, role: .source, location: ticket.location, receipt: ticket.receipt), index: index, store: store)
            try saveInstallation(nil, store)
            return .committed(committed)
        }
        let committed = state == .matching
        for position in index.owners.indices where index.owners[position].name == ticket.owner.name {
            index.owners[position].active = committed ? index.owners[position].id == ticket.owner.id : index.owners[position].id == ticket.previousOwnerID
        }
        if !committed {
            // This identity was never exposed. Remove the reservation, not any
            // preference values belonging to previously installed identities.
            index.owners.removeAll { $0.id == ticket.owner.id }
            try removeUnexposedDirectories(ownerID: ticket.owner.id, store: store)
        }
        if committed {
            try setDirectory(.init(name: ticket.owner.name, ownerID: ticket.owner.id, role: .source, location: ticket.location, receipt: ticket.receipt), index: index, store: store)
        }
        try save(index, store)
        try saveInstallation(nil, store)
        if committed {
            guard let owner = index.owners.first(where: { $0.id == ticket.owner.id }) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            return .committed(owner)
        }
        return .rolledBack
    }

    /// Native-only publication. Prepare/copy/validate files before this call;
    /// callbacks must only inspect or atomically publish the prepared directory.
    /// No JS, downloads, copying, or recursive traversal runs under this lock.
    @discardableResult
    static func publishFresh(name: String, location: String, receipt: ScriptWidgetStoragePublicationReceipt, galleryID: String? = nil,
                             container: URL, defaults: any ScriptWidgetStorageBackend,
                             inspect: (ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState,
                             publish: (ScriptWidgetStorageOwner) throws -> Void) throws -> ScriptWidgetStorageOwner {
        let name = try canonicalName(name)
        guard validLocation(location), receipt.inode > 0, galleryID == nil || validGalleryID(galleryID) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard var index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            guard galleryID == nil || !index.owners.contains(where: { $0.active && $0.galleryID?.lowercased() == galleryID?.lowercased() }) else { throw ScriptWidgetStorageNamespaceError.conflict }
            _ = try directories(defaults)
            guard index.owners.count < maximumOwners else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
            guard try inspect(receipt) == .absent else { throw ScriptWidgetStorageNamespaceError.conflict }
            let owner = ScriptWidgetStorageOwner(name: name, id: uuid(), active: false, legacyName: "", galleryID: galleryID)
            let previous = index.owners.first(where: { $0.active && $0.name == name })?.id
            let ticket = ScriptWidgetStorageInstallation(formatVersion: 1, location: location, owner: owner, previousOwnerID: previous, receipt: receipt)
            // Persist intent before changing the registry or filesystem. Lookup
            // checks this journal, including the window before reservation save.
            try saveInstallation(ticket, defaults)
            for position in index.owners.indices where index.owners[position].name == name { index.owners[position].active = false }
            index.owners.append(owner)
            try save(index, defaults)
            var publicationError: Error?
            do { try publish(owner) } catch { publicationError = error }
            let result = try finishInstallation(ticket, state: inspect(receipt), defaults)
            if case .committed(let owner) = result { return owner }
            throw publicationError ?? ScriptWidgetStorageNamespaceError.unavailable
        }
    }

    /// An absent destination rolls back an unexposed reservation; the matching
    /// prepared directory commits it. No callback is rerun during recovery.
    @discardableResult
    static func recoverInstallation(location: String, container: URL, defaults: any ScriptWidgetStorageBackend,
                                    inspect: (String, ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState) throws -> ScriptWidgetStorageInstallationRecovery {
        guard validLocation(location) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            guard let ticket = try installation(defaults) else { return .none }
            guard ticket.location == location else { throw ScriptWidgetStorageNamespaceError.unavailable }
            return try finishInstallation(ticket, state: inspect(ticket.owner.name, ticket.receipt), defaults)
        }
    }

    private static func relocation(_ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageRelocation? {
        guard let raw = try store.readValue(forKey: relocationKey) else { return nil }
        guard let data = raw as? Data, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "binding", "destination", "deleting"],
              integer(object["formatVersion"], equals: 1), bool(object["deleting"]),
              let rawBinding = object["binding"] as? [String: Any],
              let destination = object["destination"] as? String else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        let bindings = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "entries": [rawBinding]])
        let binding = try decodeDirectories(bindings).entries[0]
        let normalized = try JSONSerialization.data(withJSONObject: object)
        guard let ticket = try? JSONDecoder().decode(ScriptWidgetStorageRelocation.self, from: normalized), binding.role == .source,
              ticket.binding == binding, destination != binding.name,
              ticket.deleting ? destination == retiredDirectoryPrefix + binding.ownerID : (try? canonicalName(destination)) == destination else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        return ticket
    }

    private static func saveRelocation(_ ticket: ScriptWidgetStorageRelocation?, _ store: any ScriptWidgetStorageBackend) throws {
        if let ticket { try store.writeValue(try JSONEncoder().encode(ticket), forKey: relocationKey) }
        else { try store.removeValue(forKey: relocationKey) }
        guard store.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }

    private static func finishRelocation(_ ticket: ScriptWidgetStorageRelocation, source: ScriptWidgetStoragePublicationState,
                                         destination: ScriptWidgetStoragePublicationState, _ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageRelocationRecovery {
        guard var index = try load(store), index.phase == "ready",
              let position = index.owners.firstIndex(where: { $0.id == ticket.binding.ownerID }) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        let owner = index.owners[position]
        let committed = ticket.deleting ? !owner.active : owner.name == ticket.destination
        guard ticket.deleting || owner.active,
              owner.name == ticket.binding.name || (!ticket.deleting && owner.name == ticket.destination),
              !index.owners.contains(where: { $0.id != owner.id && $0.active && $0.name == ticket.destination }) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        if source == .matching && destination == .absent && !committed {
            guard owner.active, try directories(store).entries.contains(ticket.binding) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            try saveRelocation(nil, store)
            return .rolledBack
        }
        guard source == .absent && destination == .matching else { throw ScriptWidgetStorageNamespaceError.conflict }
        if ticket.deleting {
            index.owners[position].active = false
        } else {
            index.owners[position].name = ticket.destination
            let binding = ScriptWidgetStorageDirectoryBinding(name: ticket.destination, ownerID: owner.id, role: .source,
                location: ticket.binding.location, receipt: ticket.binding.receipt)
            try setDirectory(binding, index: index, store: store)
        }
        try save(index, store)
        try saveRelocation(nil, store)
        return .committed(source: ticket.binding.name, destination: ticket.destination, deleting: ticket.deleting)
    }

    /// A native same-root rename is the only filesystem mutation inside the lock.
    /// Recovery inspects actual receipts and never repeats the rename callback.
    @discardableResult
    static func relocate(source: ScriptWidgetStorageDirectoryBinding, destination: String, deleting: Bool,
                         container: URL, defaults: any ScriptWidgetStorageBackend,
                         inspect: (String, ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState,
                         move: () throws -> Void) throws -> ScriptWidgetStorageRelocationRecovery {
        guard source.role == .source,
              deleting ? destination == retiredDirectoryPrefix + source.ownerID : (try? canonicalName(destination)) == destination,
              destination != source.name else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults) else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            let owner = try availableOwner(name: source.name, index: index, store: defaults)
            guard owner.id == source.ownerID, try directories(defaults).entries.contains(source),
                  !index.owners.contains(where: { $0.active && $0.name == destination }),
                  try inspect(source.name, source.receipt) == .matching, try inspect(destination, source.receipt) == .absent else {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            let ticket = ScriptWidgetStorageRelocation(formatVersion: 1, binding: source, destination: destination, deleting: deleting)
            try saveRelocation(ticket, defaults)
            var moveError: Error?
            do { try move() } catch { moveError = error }
            let result = try finishRelocation(ticket, source: inspect(source.name, source.receipt), destination: inspect(destination, source.receipt), defaults)
            if result == .rolledBack { throw moveError ?? ScriptWidgetStorageNamespaceError.unavailable }
            return result
        }
    }

    @discardableResult
    static func recoverRelocation(location: String, container: URL, defaults: any ScriptWidgetStorageBackend,
                                  inspect: (String, ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState) throws -> ScriptWidgetStorageRelocationRecovery {
        return try coordinated(container: container, defaults: defaults) {
            guard let ticket = try relocation(defaults) else { return .none }
            guard ticket.binding.location == location, try installation(defaults) == nil else { throw ScriptWidgetStorageNamespaceError.unavailable }
            return try finishRelocation(ticket, source: inspect(ticket.binding.name, ticket.binding.receipt),
                destination: inspect(ticket.destination, ticket.binding.receipt), defaults)
        }
    }

    /// Retired receipts authorize cleanup only of their native hidden tombstones.
    /// Original records and ordinary source/cache paths are never removed here.
    static func retiredDirectories(location: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> [ScriptWidgetStorageDirectoryBinding] {
        guard validLocation(location) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            let retired = Set(index.owners.filter { !$0.active }.map(\.id))
            return try directories(defaults).entries.filter { $0.role == .source && $0.location == location && retired.contains($0.ownerID) }
        }
    }

    private static func validReplacementName(_ name: String) -> Bool {
        name.hasPrefix(replacementPrefix) && isUUID(String(name.dropFirst(replacementPrefix.count)))
    }

    private static func validatedReceipt(_ raw: Any?) throws -> ScriptWidgetStoragePublicationReceipt {
        guard let raw else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        let object: [String: Any] = ["formatVersion": 1, "entries": [["name": "Receipt", "ownerID": "00000000-0000-0000-0000-000000000001",
            "role": "source", "location": String(repeating: "a", count: 64), "receipt": raw]]]
        return try decodeDirectories(JSONSerialization.data(withJSONObject: object)).entries[0].receipt
    }

    private static func cleanup(_ store: any ScriptWidgetStorageBackend) throws -> [ScriptWidgetStorageCleanup] {
        guard let raw = try store.readValue(forKey: cleanupKey) else { return [] }
        guard let data = raw as? Data, data.count <= maximumRegistryBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "entries"], integer(object["formatVersion"], equals: 1),
              let entries = object["entries"] as? [[String: Any]], entries.count <= maximumCleanupEntries else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        var seen = Set<String>()
        for entry in entries {
            guard Set(entry.keys) == ["location", "name", "receipt"], let location = entry["location"] as? String, validLocation(location),
                  let name = entry["name"] as? String, validReplacementName(name), seen.insert(location + name).inserted else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            _ = try validatedReceipt(entry["receipt"])
        }
        let normalized = try JSONSerialization.data(withJSONObject: entries)
        guard let result = try? JSONDecoder().decode([ScriptWidgetStorageCleanup].self, from: normalized) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return result
    }

    private static func saveCleanup(_ entries: [ScriptWidgetStorageCleanup], _ store: any ScriptWidgetStorageBackend) throws {
        guard entries.count <= maximumCleanupEntries else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
        try store.writeValue(try JSONSerialization.data(withJSONObject: ["formatVersion": 1,
            "entries": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))]), forKey: cleanupKey)
        guard store.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }

    private static func enqueueCleanup(_ entry: ScriptWidgetStorageCleanup, _ store: any ScriptWidgetStorageBackend) throws {
        var entries = try cleanup(store)
        if let existing = entries.first(where: { $0.location == entry.location && $0.name == entry.name }) {
            guard existing == entry else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
            return
        }
        entries.append(entry)
        try saveCleanup(entries, store)
    }

    static func pendingCleanup(location: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> [ScriptWidgetStorageCleanup] {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            return try cleanup(defaults).filter { $0.location == location }
        }
    }

    static func acknowledgeCleanup(_ entry: ScriptWidgetStorageCleanup, container: URL, defaults: any ScriptWidgetStorageBackend) throws {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            try saveCleanup(cleanup(defaults).filter { $0 != entry }, defaults)
        }
    }

    private static func replacement(_ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageReplacement? {
        guard let raw = try store.readValue(forKey: replacementKey) else { return nil }
        guard let data = raw as? Data, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "source", "staging", "receipt", "galleryID"], integer(object["formatVersion"], equals: 1),
              let staging = object["staging"] as? String, validReplacementName(staging), validGalleryID(object["galleryID"]),
              let source = object["source"] as? [String: Any] else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        let binding = try decodeDirectories(JSONSerialization.data(withJSONObject: ["formatVersion": 1, "entries": [source]])).entries[0]
        let receipt = try validatedReceipt(object["receipt"])
        guard binding.role == .source, binding.receipt != receipt,
              let ticket = try? JSONDecoder().decode(ScriptWidgetStorageReplacement.self, from: JSONSerialization.data(withJSONObject: object)) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        return ticket
    }

    private static func saveReplacement(_ ticket: ScriptWidgetStorageReplacement?, _ store: any ScriptWidgetStorageBackend) throws {
        if let ticket { try store.writeValue(try JSONEncoder().encode(ticket), forKey: replacementKey) }
        else { try store.removeValue(forKey: replacementKey) }
        guard store.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
    }

    private static func finishReplacement(_ ticket: ScriptWidgetStorageReplacement,
                                          installed: ScriptWidgetStoragePublicationReceipt?, staging: ScriptWidgetStoragePublicationReceipt?,
                                          _ store: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageReplacementRecovery {
        guard let index = try load(store), index.phase == "ready",
              index.owners.contains(where: { $0.id == ticket.source.ownerID && $0.active && $0.name == ticket.source.name && $0.galleryID?.lowercased() == ticket.galleryID.lowercased() }) else {
            throw ScriptWidgetStorageNamespaceError.invalidRegistry
        }
        var ledger = try directories(store)
        let updated = ScriptWidgetStorageDirectoryBinding(name: ticket.source.name, ownerID: ticket.source.ownerID,
            role: .source, location: ticket.source.location, receipt: ticket.receipt)
        let committed = ledger.entries.contains(updated)
        guard committed || ledger.entries.contains(ticket.source) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        if installed == ticket.source.receipt && staging == ticket.receipt && !committed {
            try enqueueCleanup(.init(location: ticket.source.location, name: ticket.staging, receipt: ticket.receipt), store)
            try saveReplacement(nil, store)
            return .rolledBack
        }
        guard installed == ticket.receipt, staging == ticket.source.receipt || (committed && staging == nil) else { throw ScriptWidgetStorageNamespaceError.conflict }
        try enqueueCleanup(.init(location: ticket.source.location, name: ticket.staging, receipt: ticket.source.receipt), store)
        ledger.entries.removeAll { $0.ownerID == ticket.source.ownerID }
        ledger.entries.append(updated)
        try saveDirectories(ledger, store)
        try saveReplacement(nil, store)
        return .committed
    }

    @discardableResult
    static func replaceGallerySource(source: ScriptWidgetStorageDirectoryBinding, staging: String, receipt: ScriptWidgetStoragePublicationReceipt,
                                     galleryID: String, container: URL, defaults: any ScriptWidgetStorageBackend,
                                     inspect: (String) throws -> ScriptWidgetStoragePublicationReceipt?, swap: () throws -> Void) throws -> ScriptWidgetStorageReplacementRecovery {
        guard source.role == .source, validReplacementName(staging), receipt.inode > 0, receipt != source.receipt,
              validGalleryID(galleryID) else { throw ScriptWidgetStorageNamespaceError.invalidName }
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            let owner = try availableOwner(name: source.name, index: index, store: defaults)
            guard owner.id == source.ownerID, owner.galleryID?.lowercased() == galleryID.lowercased(), try directories(defaults).entries.contains(source),
                  try cleanup(defaults).count < maximumCleanupEntries,
                  try inspect(source.name) == source.receipt, try inspect(staging) == receipt else { throw ScriptWidgetStorageNamespaceError.conflict }
            let ticket = ScriptWidgetStorageReplacement(formatVersion: 1, source: source, staging: staging, receipt: receipt, galleryID: galleryID)
            try saveReplacement(ticket, defaults)
            var failure: Error?
            do { try swap() } catch { failure = error }
            let result = try finishReplacement(ticket, installed: inspect(source.name), staging: inspect(staging), defaults)
            if result == .rolledBack { throw failure ?? ScriptWidgetStorageNamespaceError.unavailable }
            return result
        }
    }

    @discardableResult
    static func recoverReplacement(location: String, container: URL, defaults: any ScriptWidgetStorageBackend,
                                   inspect: (String) throws -> ScriptWidgetStoragePublicationReceipt?) throws -> ScriptWidgetStorageReplacementRecovery {
        try coordinated(container: container, defaults: defaults) {
            guard let ticket = try replacement(defaults) else { return .none }
            guard ticket.source.location == location, try installation(defaults) == nil, try relocation(defaults) == nil else {
                throw ScriptWidgetStorageNamespaceError.unavailable
            }
            return try finishReplacement(ticket, installed: inspect(ticket.source.name), staging: inspect(ticket.staging), defaults)
        }
    }

    static func valueBytes(_ value: Any) throws -> Int {
        if let value = value as? String { return value.utf8.count }
        if let value = value as? Data { return value.count }
        let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
        return data.count
    }
    static func fingerprint(_ value: Any?) throws -> Data {
        var remaining = 10000
        func node(_ value: Any?, depth: Int) throws -> [Any] {
            remaining -= 1
            guard remaining >= 0, depth <= 16 else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
            guard let value else { return ["missing"] }
            if let value = value as? String { return ["string", value] }
            if let value = value as? Data { return ["data", value.base64EncodedString()] }
            if let value = value as? Date { return ["date", String(value.timeIntervalSince1970)] }
            if let value = value as? NSNumber { return [CFGetTypeID(value) == CFBooleanGetTypeID() ? "bool" : "number", value.stringValue] }
            if let values = value as? [String: Any] { return ["dictionary", try values.keys.sorted().map { [$0, try node(values[$0], depth: depth + 1)] as [Any] }] }
            if let values = value as? [Any] { return ["array", try values.map { try node($0, depth: depth + 1) }] }
            throw ScriptWidgetStorageNamespaceError.limitExceeded
        }
        if let value { guard try valueBytes(value) <= maximumLegacyValueBytes else { throw ScriptWidgetStorageNamespaceError.limitExceeded } }
        let data = try JSONSerialization.data(withJSONObject: node(value, depth: 0), options: [.withoutEscapingSlashes])
        guard data.count <= maximumLegacyValueBytes * 2 else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
        // Fingerprints are opaque equality tokens. Keep only the digest so a
        // review with many large targets does not retain each encoded value.
        return Data(SHA256.hash(data: data))
    }

    /// Called with a native inventory before scripts execute or new installs
    /// are published. A prepared journal resumes with the same opaque IDs.
    @discardableResult
    static func bootstrap(existingNames: [String], inventoryIsComplete: Bool, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageNamespaceIndex {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            var index: ScriptWidgetStorageNamespaceIndex
            if let existing = try load(defaults) { index = existing }
            else {
                let names = try Set(existingNames.map(canonicalName)).sorted()
                guard names.count <= maximumOwners else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                let owners = names.map { ScriptWidgetStorageOwner(name: $0, id: uuid(), active: true, legacyName: $0) }
                let byName = Dictionary(uniqueKeysWithValues: owners.map { ($0.name, $0.id) })
                let stored = try defaults.legacyValues()
                let keys = stored.keys.filter { $0.hasPrefix("script.") }.sorted()
                guard keys.count <= maximumLegacyFields else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                var fields: [ScriptWidgetLegacyStorageField] = [], total = 0
                for key in keys {
                    guard key.utf8.count <= 4096, let value = stored[key] else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                    total += try valueBytes(value)
                    guard total <= maximumLegacyValueBytes * 4 else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                    _ = try fingerprint(value)
                    let remainder = String(key.dropFirst("script.".count))
                    var candidates: [ScriptWidgetLegacyStorageCandidate] = []
                    for point in remainder.indices where remainder[point] == "." {
                        let name = String(remainder[..<point]).precomposedStringWithCanonicalMapping
                        let suffix = String(remainder[remainder.index(after: point)...])
                        if let id = byName[name], !suffix.isEmpty { candidates.append(.init(ownerID: id, key: suffix)) }
                    }
                    let tooLarge = try valueBytes(value) > ScriptWidgetAtomicPreferences.maximumValueBytes
                    // A partial iCloud/cache listing cannot prove the absence
                    // of another dotted owner. Keep those fields for review.
                    let uncertainInventory = !inventoryIsComplete && remainder.filter { $0 == "." }.count > 1
                    fields.append(.init(key: key, candidates: candidates, needsReview: candidates.count != 1 || uncertainInventory || tooLarge || candidates.contains { $0.key.utf8.count > 256 }, resolved: false))
                }
                // An overfull owner needs review as a unit; never silently
                // choose which of its old keys to omit.
                for owner in owners {
                    let fieldsForOwner = fields.filter { $0.candidates.contains { $0.ownerID == owner.id } }
                    let bytes = try fieldsForOwner.reduce(0) { try $0 + valueBytes(stored[$1.key]!) }
                    if fieldsForOwner.count > maximumNamespaceKeys || bytes > maximumNamespaceBytes {
                        for position in fields.indices where fields[position].candidates.contains(where: { $0.ownerID == owner.id }) { fields[position].needsReview = true }
                    }
                }
                index = .init(phase: "prepared", owners: owners, legacy: fields)
                try save(index, defaults)
            }
            guard index.phase == "prepared" else { return index }
            // Re-evaluate the frozen key inventory against one synchronized
            // source snapshot. Changes while an upgrade was interrupted must
            // become review items, never a partially visible migration.
            let source = try defaults.legacyValues()
            for position in index.legacy.indices {
                if let value = source[index.legacy[position].key] {
                    _ = try fingerprint(value)
                    if try valueBytes(value) > ScriptWidgetAtomicPreferences.maximumValueBytes { index.legacy[position].needsReview = true }
                }
            }
            for owner in index.owners {
                let fields = index.legacy.filter { $0.candidates.contains { $0.ownerID == owner.id } }
                let bytes = try fields.reduce(0) { sum, field in
                    guard let value = source[field.key] else { return sum }
                    return try sum + valueBytes(value)
                }
                if fields.count > maximumNamespaceKeys || bytes > maximumNamespaceBytes {
                    for position in index.legacy.indices where index.legacy[position].candidates.contains(where: { $0.ownerID == owner.id }) { index.legacy[position].needsReview = true }
                }
            }
            var copies: [(String, Any?)] = []
            for field in index.legacy {
                for candidate in field.candidates {
                    guard let owner = index.owners.first(where: { $0.id == candidate.ownerID }) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                    copies.append((owner.namespace + candidate.key, field.needsReview ? nil : source[field.key]))
                }
            }
            try save(index, defaults)
            // Prepared owners cannot be opened by a runtime. Clear any stale
            // staged copy for a field now requiring review before publishing.
            for (target, value) in copies {
                if let value { try defaults.writeValue(value, forKey: target) } else { try defaults.removeValue(forKey: target) }
            }
            for position in index.legacy.indices where !index.legacy[position].needsReview { index.legacy[position].resolved = true }
            index.phase = "ready"
            try save(index, defaults)
            return index
        }
    }

    /// Native identity consumers may inspect an owner; this never allocates or grants a namespace.
    static func owner(id: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageOwner? {
        guard isUUID(id) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        return try coordinated(container:container,defaults:defaults) {
            guard let index=try load(defaults),index.phase=="ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            return index.owners.first{$0.id==id}
        }
    }

    static func namespace(for name: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> String {
        let name = try canonicalName(name)
        return try coordinated(container: container, defaults: defaults) {
            if let pending = try replacement(defaults), pending.source.name == name { throw ScriptWidgetStorageNamespaceError.unavailable }
            if let pending = try relocation(defaults), pending.binding.name == name || (!pending.deleting && pending.destination == name) {
                throw ScriptWidgetStorageNamespaceError.unavailable
            }
            if let pending = try installation(defaults), pending.owner.name == name { throw ScriptWidgetStorageNamespaceError.unavailable }
            guard let index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            guard let owner = index.owners.first(where: { $0.name == name && $0.active }) else { throw ScriptWidgetStorageNamespaceError.unregistered }
            guard !index.legacy.contains(where: { !$0.resolved && $0.candidates.contains(where: { $0.ownerID == owner.id }) }) else { throw ScriptWidgetStorageNamespaceError.reviewRequired }
            return owner.namespace
        }
    }

    /// Fresh imports/remixes never inherit an old name's data or legacy grant.
    @discardableResult
    static func registerFresh(name: String, replacing: Bool = false, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> ScriptWidgetStorageOwner {
        let name = try canonicalName(name)
        return try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard var index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            if let position = index.owners.firstIndex(where: { $0.name == name && $0.active }) {
                guard replacing else { throw ScriptWidgetStorageNamespaceError.conflict }
                index.owners[position].active = false
            }
            guard index.owners.count < maximumOwners else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
            let owner = ScriptWidgetStorageOwner(name: name, id: uuid(), active: true, legacyName: "")
            index.owners.append(owner)
            try save(index, defaults)
            return owner
        }
    }

    static func rename(from source: String, to destination: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws {
        let source = try canonicalName(source), destination = try canonicalName(destination)
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard var index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            guard let position = index.owners.firstIndex(where: { $0.name == source && $0.active }) else { throw ScriptWidgetStorageNamespaceError.unregistered }
            if source == destination { return }
            guard !index.owners.contains(where: { $0.name == destination && $0.active }) else { throw ScriptWidgetStorageNamespaceError.conflict }
            index.owners[position].name = destination
            try save(index, defaults)
        }
    }

    static func retire(name: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws {
        let name = try canonicalName(name)
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard var index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            guard let position = index.owners.firstIndex(where: { $0.name == name && $0.active }) else { return }
            index.owners[position].active = false
            try save(index, defaults)
        }
    }

    static func pending(container: URL, defaults: any ScriptWidgetStorageBackend) throws -> [ScriptWidgetLegacyStorageField] {
        try coordinated(container: container, defaults: defaults) {
            guard let index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            return index.legacy.filter { !$0.resolved }
        }
    }

    static func preview(field key: String, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> ScriptWidgetLegacyStoragePreview {
        try coordinated(container: container, defaults: defaults) {
            guard let index = try load(defaults), index.phase == "ready",
                  let field = index.legacy.first(where: { $0.key == key && !$0.resolved }) else { throw ScriptWidgetStorageNamespaceError.conflict }
            let value = try defaults.readValue(forKey: key)
            var targets: [String: Data] = [:]
            for candidate in field.candidates {
                guard let owner = index.owners.first(where: { $0.id == candidate.ownerID }) else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                targets[owner.id] = try fingerprint(try defaults.readValue(forKey: owner.namespace + candidate.key))
            }
            let type = value == nil ? "missing" : value is String ? "string" : value is Data ? "data" : "property list"
            return .init(field: field, sourceFingerprint: try fingerprint(value), targetFingerprints: targets,
                         valueBytes: try value.map(valueBytes) ?? 0, valueType: type)
        }
    }

    static func reviewState(container: URL, defaults: any ScriptWidgetStorageBackend) throws -> (ScriptWidgetStorageNamespaceIndex, [ScriptWidgetStorageDirectoryBinding]) {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard let index = try load(defaults), index.phase == "ready" else { throw ScriptWidgetStorageNamespaceError.inventoryRequired }
            return (index, try directories(defaults).entries)
        }
    }

    static func previewText(_ preview: ScriptWidgetLegacyStoragePreview, container: URL, defaults: any ScriptWidgetStorageBackend) throws -> String {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            let value = try defaults.readValue(forKey: preview.field.key)
            guard try fingerprint(value) == preview.sourceFingerprint else { throw ScriptWidgetStorageNamespaceError.conflict }
            if let text = value as? String { return String(decoding: text.utf8.prefix(1024), as: UTF8.self) }
            if let data = value as? Data {
                let text = String(decoding: data.prefix(1024), as: UTF8.self)
                if text.first == "{" || text.first == "[" { return text }
                return "Binary data (\(data.count) bytes)"
            }
            if value == nil { return "No stored value" }
            if let number = value as? NSNumber { return number.stringValue }
            if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
            if let dictionary = value as? [String: Any] {
                func brief(_ value: Any) -> String {
                    if let text = value as? String { return String(decoding: text.utf8.prefix(80), as: UTF8.self) }
                    if let number = value as? NSNumber { return number.stringValue }
                    if let data = value as? Data { return "Binary data (\(data.count) bytes)" }
                    return "Nested value"
                }
                let text = dictionary.keys.sorted().prefix(8).map { key in
                    String(decoding: key.utf8.prefix(80), as: UTF8.self) + ": " + brief(dictionary[key]!)
                }.joined(separator: "\n")
                return String(decoding: text.utf8.prefix(1024), as: UTF8.self)
            }
            if let array = value as? [Any] { return "Array (\(array.count) items)" }
            return "No text preview available"
        }
    }

    /// No value is read/copied/deleted. This remains available even when an
    /// old field is too large or malformed to fingerprint for copying.
    static func archiveOriginal(_ field: ScriptWidgetLegacyStorageField, container: URL, defaults: any ScriptWidgetStorageBackend, validate: () throws -> Void = {}) throws {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard var index = try load(defaults), index.phase == "ready",
                  let position = index.legacy.firstIndex(where: { $0 == field && !$0.resolved }) else { throw ScriptWidgetStorageNamespaceError.conflict }
            try validate()
            index.legacy[position].resolved = true
            try save(index, defaults)
        }
    }

    /// Empty selection archives the key without erasing it. Choosing both
    /// creates independent copies, only after explicit native user review.
    static func resolve(_ preview: ScriptWidgetLegacyStoragePreview, to selectedOwners: Set<String>, container: URL, defaults: any ScriptWidgetStorageBackend,
                        expectedOwners: [ScriptWidgetStorageOwner]? = nil, expectedBindings: [ScriptWidgetStorageDirectoryBinding]? = nil,
                        validate: () throws -> Void = {}) throws {
        try coordinated(container: container, defaults: defaults) {
            try requireNoInstallation(defaults)
            guard var index = try load(defaults), index.phase == "ready",
                  let position = index.legacy.firstIndex(where: { $0.key == preview.field.key && !$0.resolved }), index.legacy[position] == preview.field,
                  selectedOwners.isSubset(of: Set(preview.field.candidates.map(\.ownerID))) else { throw ScriptWidgetStorageNamespaceError.conflict }
            if let expectedOwners {
                let ids = Set(preview.field.candidates.map(\.ownerID))
                guard index.owners.filter({ ids.contains($0.id) }).sorted(by: { $0.id < $1.id }) == expectedOwners.sorted(by: { $0.id < $1.id }) else {
                    throw ScriptWidgetStorageNamespaceError.conflict
                }
            }
            if let expectedBindings {
                let actual = try directories(defaults).entries
                guard expectedBindings.count == selectedOwners.count, Set(expectedBindings.map(\.ownerID)) == selectedOwners,
                      expectedBindings.allSatisfy({ $0.role == .source && actual.contains($0) }) else { throw ScriptWidgetStorageNamespaceError.conflict }
            }
            try validate()
            let value = try defaults.readValue(forKey: preview.field.key)
            guard try fingerprint(value) == preview.sourceFingerprint else { throw ScriptWidgetStorageNamespaceError.conflict }
            var updates: [(String, Any?)] = []
            for candidate in preview.field.candidates where selectedOwners.contains(candidate.ownerID) {
                guard let owner = index.owners.first(where: { $0.id == candidate.ownerID && $0.active }), candidate.key.utf8.count <= 256,
                      try fingerprint(try defaults.readValue(forKey: owner.namespace + candidate.key)) == preview.targetFingerprints[owner.id] else { throw ScriptWidgetStorageNamespaceError.conflict }
                if let value {
                    guard try valueBytes(value) <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                    guard try fitsBudget(namespace: owner.namespace, defaults: defaults, replacing: [candidate.key: value]) else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                }
                updates.append((owner.namespace + candidate.key, value))
            }
            // All sources/targets/budgets are checked before the first mutation.
            for (key, value) in updates {
                if let value { try defaults.writeValue(value, forKey: key) } else { try defaults.removeValue(forKey: key) }
            }
            index.legacy[position].resolved = true
            try save(index, defaults)
        }
    }

    static func fitsBudget(namespace: String, defaults: any ScriptWidgetStorageBackend, replacing: [String: Any], removing: Set<String> = []) throws -> Bool {
        var values: [Data: Any] = [:]
        for (key, value) in try defaults.values(in: namespace) { values[Data(key.utf8)] = value }
        let oldCount = values.count
        let oldBytes = try values.values.reduce(0) { try $0 + valueBytes($1) }
        for key in removing { values.removeValue(forKey: Data((namespace + key).utf8)) }
        for (key, value) in replacing { values[Data((namespace + key).utf8)] = value }
        let newBytes = try values.values.reduce(0) { try $0 + valueBytes($1) }
        return (values.count <= maximumNamespaceKeys && newBytes <= maximumNamespaceBytes) || (values.count <= oldCount && newBytes <= oldBytes)
    }
}
