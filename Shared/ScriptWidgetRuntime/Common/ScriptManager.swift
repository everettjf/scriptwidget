//
//  ScriptManager.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/11/10.
//

import Foundation
import Darwin
import SwiftUI
import ZipArchive
import CryptoKit


extension String {
    
    func trim() -> String {
        return self.trimmingCharacters(in: .whitespaces)
    }
    
    func checkIfValidFileName() -> Bool {
        ScriptWidgetPackageName.isValid(self)
    }
    
}

struct ScriptPackageImportResult: Equatable {
    let succeeded: Bool
    let packageName: String?
    let message: String
    let validation: WidgetPackageValidationReport?
}

enum ScriptPackageArchivePolicy {
    static let maximumArchiveBytes = 32 * 1024 * 1024
    static let maximumExpandedBytes = 64 * 1024 * 1024
    static let maximumFileBytes = 25 * 1024 * 1024
    static let maximumFileCount = 500
    static let maximumPathDepth = 16
}

enum ScriptPackageArchivePreflight {
    static func validate(_ archiveURL: URL) -> String? {
        guard let values = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]),
              let archiveBytes = values.fileSize,
              archiveBytes > 0,
              archiveBytes <= ScriptPackageArchivePolicy.maximumArchiveBytes else {
            return "Archive must be between 1 byte and 32 MiB."
        }
        guard let data = try? Data(contentsOf: archiveURL) else {
            return "Archive could not be read."
        }
        guard let end = endOfCentralDirectory(in: data) else {
            return "Archive has no valid ZIP central directory."
        }
        guard data.uint16LE(at: end + 4) == 0,
              data.uint16LE(at: end + 6) == 0,
              data.uint16LE(at: end + 8) == data.uint16LE(at: end + 10) else {
            return "Multi-disk ZIP archives are not supported."
        }
        let commentLength = Int(data.uint16LE(at: end + 20))
        guard end + 22 + commentLength == data.count else {
            return "Archive has a malformed ZIP footer."
        }
        let entries = Int(data.uint16LE(at: end + 10))
        let centralSize = Int(data.uint32LE(at: end + 12))
        let centralOffset = Int(data.uint32LE(at: end + 16))
        guard entries > 0, entries <= ScriptPackageArchivePolicy.maximumFileCount else {
            return "Archive must contain 1–\(ScriptPackageArchivePolicy.maximumFileCount) entries."
        }
        guard centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= data.count else {
            return "Archive central directory is out of bounds."
        }

        var cursor = centralOffset
        var expandedBytes: UInt64 = 0
        var normalizedPaths: Set<String> = []
        for _ in 0..<entries {
            guard cursor + 46 <= data.count,
                  data.uint32LE(at: cursor) == 0x02014B50 else {
                return "Archive central directory contains an invalid entry."
            }
            let flags = data.uint16LE(at: cursor + 8)
            let method = data.uint16LE(at: cursor + 10)
            let compressed32 = data.uint32LE(at: cursor + 20)
            let uncompressed32 = data.uint32LE(at: cursor + 24)
            let nameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let externalAttributes = data.uint32LE(at: cursor + 38)
            let entryEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, entryEnd <= data.count else {
                return "Archive contains a truncated filename."
            }
            guard let sizes = resolvedSizes(
                compressed32: compressed32,
                uncompressed32: uncompressed32,
                extra: data.subdata(in: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength))
            ) else { return "Archive contains malformed ZIP64 size metadata." }
            let compressed = sizes.compressed
            let uncompressed = sizes.uncompressed
            guard flags & 0x1 == 0 else { return "Encrypted package entries are not supported." }
            guard method == 0 || method == 8 else { return "Unsupported ZIP compression method \(method)." }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), validEntryPath(name) else {
                return "Archive contains an unsafe or non-UTF-8 path."
            }
            let normalizedPath = name.precomposedStringWithCanonicalMapping.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard normalizedPaths.insert(normalizedPath).inserted else {
                return "Archive contains duplicate or case-colliding paths."
            }
            let unixMode = UInt16((externalAttributes >> 16) & 0xFFFF)
            if unixMode & 0xF000 == 0xA000 {
                return "Symbolic links are not allowed in ScriptWidget packages."
            }
            if !name.hasSuffix("/") {
                guard uncompressed <= UInt64(ScriptPackageArchivePolicy.maximumFileBytes) else {
                    return "Package file \(name) exceeds 25 MiB."
                }
                expandedBytes += uncompressed
                guard expandedBytes <= UInt64(ScriptPackageArchivePolicy.maximumExpandedBytes) else {
                    return "Expanded package exceeds 64 MiB."
                }
                if uncompressed > 1024 * 1024, compressed == 0 {
                    return "Archive entry \(name) has an invalid compression ratio."
                }
            }
            cursor = entryEnd
        }
        guard cursor == centralOffset + centralSize else {
            return "Archive entries do not match the declared central directory."
        }
        return nil
    }

    private static func validEntryPath(_ name: String) -> Bool {
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
            return false
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.count <= ScriptPackageArchivePolicy.maximumPathDepth else { return false }
        return parts.allSatisfy { $0 != "." && $0 != ".." }
    }

    private static func resolvedSizes(compressed32: UInt32, uncompressed32: UInt32, extra: Data) -> (compressed: UInt64, uncompressed: UInt64)? {
        var compressed = UInt64(compressed32)
        var uncompressed = UInt64(uncompressed32)
        guard compressed32 == UInt32.max || uncompressed32 == UInt32.max else { return (compressed, uncompressed) }

        var cursor = 0
        while cursor + 4 <= extra.count {
            let identifier = extra.uint16LE(at: cursor)
            let length = Int(extra.uint16LE(at: cursor + 2))
            let end = cursor + 4 + length
            guard end <= extra.count else { return nil }
            if identifier == 0x0001 {
                var valueCursor = cursor + 4
                if uncompressed32 == UInt32.max {
                    guard valueCursor + 8 <= end else { return nil }
                    uncompressed = extra.uint64LE(at: valueCursor)
                    valueCursor += 8
                }
                if compressed32 == UInt32.max {
                    guard valueCursor + 8 <= end else { return nil }
                    compressed = extra.uint64LE(at: valueCursor)
                }
                return (compressed, uncompressed)
            }
            cursor = end
        }
        return nil
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 65_557)
        var index = data.count - 22
        while index >= lowerBound {
            if data.uint32LE(at: index) == 0x06054B50 { return index }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func uint16LE(at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }

    func uint32LE(at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        return UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }

    func uint64LE(at index: Int) -> UInt64 {
        guard index >= 0, index + 8 <= count else { return 0 }
        return (0..<8).reduce(UInt64(0)) { result, offset in
            result | (UInt64(self[index + offset]) << UInt64(offset * 8))
        }
    }
}



/// Native library adapter for the UUID coordinator. Activation is explicit:
/// callers must finish native inventory/migration and switch all consumers
/// before supplying this context. It never bootstraps from an imported package.
/// Immutable cross-thread capability. Foundation preferences are thread-safe;
/// file/index mutations use the native coordinators' locks. Activation readers
/// must be Sendable and cannot capture UI state or an execution session.
final class ScriptWidgetPackageStorageContext: @unchecked Sendable {
    let libraryRoot: URL
    let container: URL
    let defaults: any ScriptWidgetStorageBackend
    private let rootReceipt: ScriptWidgetStoragePublicationReceipt
    private let validateActivation: @Sendable () throws -> Void
    let locationIdentifier: String

    init(libraryRoot: URL, container: URL, defaults: any ScriptWidgetStorageBackend, validateActivation: @escaping @Sendable () throws -> Void = {},
         expectedLibraryReceipt: ScriptWidgetStoragePublicationReceipt? = nil) throws {
        guard !ScriptWidgetMetadataFile.isLink(libraryRoot), !ScriptWidgetMetadataFile.isLink(container) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: root.deletingLastPathComponent(), relative: root.lastPathComponent) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        guard expectedLibraryReceipt == nil || expectedLibraryReceipt == receipt else { throw ScriptWidgetStorageNamespaceError.conflict }
        self.libraryRoot = root
        self.container = container
        self.defaults = defaults
        self.validateActivation = validateActivation
        self.rootReceipt = receipt
        let identity = root.path + "\n" + String(receipt.device) + ":" + String(receipt.inode)
        self.locationIdentifier = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func requireSameRoot() throws {
        try validateActivation()
        guard try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot.deletingLastPathComponent(), relative: libraryRoot.lastPathComponent) == rootReceipt else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
    }

    func validateLibraryRoot() throws { try requireSameRoot() }

    func contextForCacheRoot(_ root: URL) throws -> ScriptWidgetPackageStorageContext {
        try validateActivation()
        try requireSeparateCacheRoot(root)
        return try ScriptWidgetPackageStorageContext(libraryRoot: root, container: container, defaults: defaults, validateActivation: validateActivation)
    }

    private func inspect(name: String, receipt: ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState {
        try requireSameRoot()
        guard let actual = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: name) else { return .absent }
        return actual == receipt ? .matching : .different
    }

    @discardableResult
    func recoverInstallation() throws -> ScriptWidgetStorageInstallationRecovery {
        try requireSameRoot()
        return try ScriptWidgetStorageNamespaces.recoverInstallation(location: locationIdentifier, container: container, defaults: defaults) { name, receipt in
            try self.inspect(name: name, receipt: receipt)
        }
    }

    @discardableResult
    func recoverRelocation() throws -> ScriptWidgetStorageRelocationRecovery {
        try requireSameRoot()
        let result = try ScriptWidgetStorageNamespaces.recoverRelocation(location: locationIdentifier, container: container, defaults: defaults) {
            try self.inspect(name: $0, receipt: $1)
        }
        try? cleanupRetiredDirectories()
        return result
    }

    func cleanupRetiredDirectories() throws {
        try requireSameRoot()
        let candidates = try ScriptWidgetStorageNamespaces.retiredDirectories(location: locationIdentifier, container: container, defaults: defaults)
        var attempts = 0
        for binding in candidates.reversed() {
            let name = ScriptWidgetStorageNamespaces.retiredDirectoryPrefix + binding.ownerID
            guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: name), receipt == binding.receipt else { continue }
            attempts += 1
            _ = ScriptWidgetPackageFiles.removeTree(root: libraryRoot, relative: name, expectedReceipt: receipt)
            if attempts == 8 { break }
        }
    }

    func relocate(name: String, destination: String? = nil) throws {
        try requireSameRoot()
        _ = try recoverInstallation()
        let recovered = try recoverRelocation()
        _ = try recoverReplacement()
        if case .committed(let original, let target, let deleting) = recovered,
           original == name, (deleting ? destination == nil : destination == target) { return }
        let source = try boundDirectory(name: name, role: .source)
        let deleting = destination == nil
        let target = destination ?? ScriptWidgetStorageNamespaces.retiredDirectoryPrefix + source.ownerID
        _ = try ScriptWidgetStorageNamespaces.relocate(source: source, destination: target, deleting: deleting,
            container: container, defaults: defaults, inspect: { try self.inspect(name: $0, receipt: $1) }, move: {
                try self.requireSameRoot()
                guard ScriptWidgetPackageFiles.move(root: self.libraryRoot, source: name, destination: target, expectedReceipt: source.receipt) else {
                    throw ScriptWidgetStorageNamespaceError.unavailable
                }
            })
        // Retired data is already inaccessible. Cleanup happens outside the
        // identity lock, and only the exact hidden directory may be removed.
        if deleting {
            _ = ScriptWidgetPackageFiles.removeTree(root: libraryRoot, relative: target, expectedReceipt: source.receipt)
        }
    }

    @discardableResult
    func recoverReplacement() throws -> ScriptWidgetStorageReplacementRecovery {
        try requireSameRoot()
        let result = try ScriptWidgetStorageNamespaces.recoverReplacement(location: locationIdentifier, container: container, defaults: defaults) {
            try self.requireSameRoot()
            return try ScriptWidgetPackageFiles.directoryReceipt(root: self.libraryRoot, relative: $0)
        }
        try? cleanupReplacementDirectories()
        return result
    }

    func cleanupReplacementDirectories() throws {
        try requireSameRoot()
        let entries = try ScriptWidgetStorageNamespaces.pendingCleanup(location: locationIdentifier, container: container, defaults: defaults)
        for entry in entries.prefix(8) {
            let actual = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: entry.name)
            if actual == nil || (actual == entry.receipt && ScriptWidgetPackageFiles.removeTree(root: libraryRoot, relative: entry.name, expectedReceipt: entry.receipt)) {
                try ScriptWidgetStorageNamespaces.acknowledgeCleanup(entry, container: container, defaults: defaults)
            }
        }
    }

    func gallerySource(itemID: String) throws -> ScriptWidgetStorageDirectoryBinding? {
        _ = try recoverInstallation()
        _ = try recoverRelocation()
        _ = try recoverReplacement()
        guard let binding = try ScriptWidgetStorageNamespaces.gallerySource(itemID: itemID, location: locationIdentifier, container: container, defaults: defaults) else { return nil }
        guard try boundDirectory(name: binding.name, role: .source) == binding else { throw ScriptWidgetStorageNamespaceError.conflict }
        return binding
    }

    /// Called only after native Gallery verification. The public manifest ID
    /// does not select an owner; native provenance does.
    func installGallerySource(_ source: URL, itemID: String, version: String, freshName: String) throws -> String {
        try requireSameRoot()
        let existing = try gallerySource(itemID: itemID)
        guard let entries = ScriptWidgetPackageFiles.list(root: libraryRoot),
              entries.filter({ $0.hasPrefix(ScriptWidgetStorageNamespaces.replacementPrefix) }).count < 32,
              let sourceReceipt = try ScriptWidgetPackageFiles.directoryReceipt(root: source.deletingLastPathComponent(), relative: source.lastPathComponent) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        let stagingName = ScriptWidgetStorageNamespaces.replacementPrefix + UUID().uuidString.lowercased()
        let staging = libraryRoot.appendingPathComponent(stagingName)
        guard ScriptWidgetPackageFiles.ensureDirectory(root: libraryRoot, relative: stagingName),
              let stagingReceipt = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: stagingName) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        do {
            try ScriptWidgetPackageFiles.copyExecutionPackage(root: source.deletingLastPathComponent(), relative: source.lastPathComponent,
                receipt: sourceReceipt, destination: staging, limits: .init())
            let package = ScriptWidgetPackage(path: staging, readonly: true)
            guard let manifest = package.readManifest(), manifest.id == itemID, manifest.version == version,
                  WidgetPackageManifestValidator.validate(manifest, package: package).isValid,
                  let entry = ScriptWidgetPackageFiles.read(root: staging, relative: manifest.entry, maximumBytes: ScriptWidgetExecutionSnapshot.maximumSourceBytes),
                  String(data: entry, encoding: .utf8) != nil else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
        } catch {
            if (try? requireSameRoot()) != nil {
                _ = ScriptWidgetPackageFiles.removeTree(root: libraryRoot, relative: stagingName, expectedReceipt: stagingReceipt)
            }
            throw error
        }
        if let existing {
            guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: stagingName) else { throw ScriptWidgetStorageNamespaceError.unavailable }
            // An uncertain swap preserves its stage/backup for journal recovery.
            _ = try ScriptWidgetStorageNamespaces.replaceGallerySource(source: existing, staging: stagingName, receipt: receipt,
                galleryID: itemID, container: container, defaults: defaults, inspect: {
                    try self.requireSameRoot()
                    return try ScriptWidgetPackageFiles.directoryReceipt(root: self.libraryRoot, relative: $0)
                }, swap: {
                    try self.requireSameRoot()
                    guard ScriptWidgetPackageFiles.replaceCacheDirectory(staging, root: self.libraryRoot, name: existing.name, expectedReceipt: receipt) else {
                        throw ScriptWidgetStorageNamespaceError.unavailable
                    }
                })
            try? cleanupReplacementDirectories()
            return existing.name
        }
        do { _ = try publish(staging, name: freshName, galleryID: itemID) }
        catch {
            // Failed fresh publication cannot place old user code in staging.
            // The installation journal still governs any uncertain destination.
            if (try? requireSameRoot()) != nil {
                _ = ScriptWidgetPackageFiles.removeTree(root: libraryRoot, relative: stagingName, expectedReceipt: stagingReceipt)
            }
            throw error
        }
        return freshName
    }

    func boundDirectory(name: String, role: ScriptWidgetStorageDirectoryRole) throws -> ScriptWidgetStorageDirectoryBinding {
        try requireSameRoot()
        guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: name) else {
            throw ScriptWidgetStorageNamespaceError.unregistered
        }
        return try ScriptWidgetStorageNamespaces.boundDirectory(name: name, role: role, location: locationIdentifier,
            receipt: receipt, container: container, defaults: defaults)
    }

    /// Used after a native legacy inventory, never for arbitrary imported IDs.
    func bindInventoriedSource(name: String) throws {
        try requireSameRoot()
        guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: libraryRoot, relative: name) else {
            throw ScriptWidgetStorageNamespaceError.unregistered
        }
        try ScriptWidgetStorageNamespaces.bindInventoriedSource(name: name, location: locationIdentifier, receipt: receipt,
            container: container, defaults: defaults)
    }

    func requireSeparateCacheRoot(_ cacheRoot: URL) throws {
        let sourceParts = libraryRoot.pathComponents
        let cacheParts = cacheRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard !sourceParts.starts(with: cacheParts), !cacheParts.starts(with: sourceParts) else {
            throw ScriptWidgetStorageNamespaceError.conflict
        }
    }

    @discardableResult
    func publishCache(_ prepared: URL, source: ScriptWidgetStorageDirectoryBinding, cacheRoot: URL) throws -> ScriptWidgetStorageDirectoryBinding {
        try requireSameRoot()
        let cache = try ScriptWidgetPackageStorageContext(libraryRoot: cacheRoot, container: container, defaults: defaults, validateActivation: validateActivation)
        // A cache must never replace authored library contents, even if a
        // native caller passes an incorrect cache-root override.
        try requireSeparateCacheRoot(cache.libraryRoot)
        guard source.role == .source, source.location == locationIdentifier else {
            throw ScriptWidgetStorageNamespaceError.conflict
        }
        guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: prepared.deletingLastPathComponent(), relative: prepared.lastPathComponent) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        return try ScriptWidgetStorageNamespaces.publishCache(source: source, location: cache.locationIdentifier, receipt: receipt,
            container: container, defaults: defaults, sourceStillMatches: {
                try self.requireSameRoot()
                return try ScriptWidgetPackageFiles.directoryReceipt(root: self.libraryRoot, relative: source.name) == source.receipt
            }, inspect: { try cache.inspect(name: source.name, receipt: receipt) }, publish: {
                try cache.requireSameRoot()
                guard ScriptWidgetPackageFiles.replaceCacheDirectory(prepared, root: cache.libraryRoot, name: source.name, expectedReceipt: receipt) else {
                    throw ScriptWidgetStorageNamespaceError.unavailable
                }
            })
    }

    @discardableResult
    func publish(_ prepared: URL, name: String, galleryID: String? = nil) throws -> ScriptWidgetStorageOwner {
        try requireSameRoot()
        _ = try recoverInstallation()
        _ = try recoverRelocation()
        _ = try recoverReplacement()
        guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: prepared.deletingLastPathComponent(), relative: prepared.lastPathComponent) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        return try ScriptWidgetStorageNamespaces.publishFresh(name: name, location: locationIdentifier, receipt: receipt, galleryID: galleryID,
            container: container, defaults: defaults, inspect: { try self.inspect(name: name, receipt: $0) }, publish: { _ in
                try self.requireSameRoot()
                guard ScriptWidgetPackageFiles.publishDirectory(prepared, root: self.libraryRoot, name: name, expectedReceipt: receipt) else {
                    throw ScriptWidgetStorageNamespaceError.unavailable
                }
            })
    }
}

/// One bounded execution image. Resource lifetime follows the package retained
/// by the renderer, while identity validation always checks the original binding.
final class ScriptWidgetExecutionSnapshot {
    static let maximumSourceBytes = 512 * 1024
    let package: ScriptWidgetPackage
    let source: String
    let hasUnsavedEntry: Bool
    let binding: ScriptWidgetStorageDirectoryBinding
    let context: ScriptWidgetPackageStorageContext
    var storageNamespace: String { "ScriptWidgetStorage.v2:" + binding.ownerID + ":" }

    init(name: String, role: ScriptWidgetStorageDirectoryRole, context: ScriptWidgetPackageStorageContext,
         entryOverride: String? = nil, limits: ScriptWidgetExecutionSnapshotLimits = .init()) throws {
        let binding = try context.boundDirectory(name: name, role: role)
        let files = try ScriptWidgetExecutionFiles()
        guard ScriptWidgetPackageFiles.ensureDirectory(root: files.directory, relative: binding.name) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        let path = files.directory.appendingPathComponent(binding.name)
        try ScriptWidgetPackageFiles.copyExecutionPackage(root: context.libraryRoot, relative: binding.name, receipt: binding.receipt,
            destination: path, limits: limits)
        guard try context.boundDirectory(name: binding.name, role: role) == binding else { throw ScriptWidgetStorageNamespaceError.conflict }
        let package = ScriptWidgetPackage(path: path, readonly: true, executionFiles: files,
            compiledScope: entryOverride == nil ? .init(context: context, role: role, binding: binding) : nil)
        let entry: String
        if package.hasManifest {
            guard let manifest = package.readManifest(), WidgetPackageManifestValidator.validate(manifest, package: package).isValid else {
                throw ScriptWidgetStorageNamespaceError.invalidRegistry
            }
            entry = manifest.entry
        } else { entry = "main.jsx" }
        guard let bytes = ScriptWidgetPackageFiles.read(root: path, relative: entry, maximumBytes: Self.maximumSourceBytes),
              let captured = String(data: bytes, encoding: .utf8) else { throw ScriptWidgetStorageNamespaceError.unavailable }
        let source = entryOverride ?? captured
        guard source.utf8.count <= Self.maximumSourceBytes else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
        self.package = package
        self.source = source
        self.hasUnsavedEntry = entryOverride != nil && source != captured
        self.binding = binding
        self.context = context
    }

    func validateIdentity() throws {
        guard try context.boundDirectory(name: binding.name, role: binding.role) == binding else {
            throw ScriptWidgetStorageNamespaceError.conflict
        }
    }
}

// Immutable native references; shared record/index mutations are coordinated
// by their process locks and package publication helpers.
final class ScriptManager: @unchecked Sendable {
    
    static let packageRemovedNotification = Notification.Name("ScriptWidgetPackageRemoved")

    let scriptDirectory: URL
    let isUsingiCloud: Bool
    let isBuild: Bool
    let storageContext: ScriptWidgetPackageStorageContext?
    let buildDirectoryOverride: URL?
    let unavailableReason: String?
    let storageRole: ScriptWidgetStorageDirectoryRole
    
    init(isBuild: Bool, scriptDirectoryOverride: URL? = nil, storageContext: ScriptWidgetPackageStorageContext? = nil, buildDirectoryOverride: URL? = nil,
         isUsingICloudOverride: Bool = false, unavailableReason: String? = nil,
         storageRole: ScriptWidgetStorageDirectoryRole = .source) {
        self.isBuild = isBuild
        self.storageContext = storageContext
        self.buildDirectoryOverride = buildDirectoryOverride
        self.unavailableReason = unavailableReason
        self.storageRole = storageRole
        if unavailableReason != nil {
            // /dev/null is a file. This non-materialized descriptor cannot
            // accidentally become a writable replacement library.
            self.scriptDirectory = URL(fileURLWithPath: "/dev/null/ScriptWidgetUnavailable")
            self.isUsingiCloud = false
            return
        }
        if let scriptDirectoryOverride {
            self.scriptDirectory = scriptDirectoryOverride
            self.isUsingiCloud = isUsingICloudOverride
            if storageContext == nil { self.makeSureRootExist() }
            return
        }
        if isBuild {
            if let buildDir = Self.getSandboxBuildDirectoryURL() {
                self.scriptDirectory = buildDir
            } else {
                print("app group container unavailable; falling back to local build directory")
                self.scriptDirectory = Self.localFallbackDirectoryURL("__Build")
            }
            self.isUsingiCloud = false
        } else {
            let dirInfo = Self.getICloudPriorityRootDirectory()
            self.scriptDirectory = dirInfo.0
            self.isUsingiCloud = dirInfo.1
            
            print("icloud dir : \(isUsingiCloud)")
            print("root = \(String(describing: scriptDirectory))")
            
        }
        self.makeSureRootExist()
    }
    
    static func getICloudPriorityRootDirectory() -> (URL, Bool) {
        var isUsingiCloud = false
        var root = URL(fileURLWithPath: "")
        if let url = ScriptManager.getICloudRootDirectoryURL() {
            root = url
            isUsingiCloud = true
        } else if let sandboxRoot = ScriptManager.getSandboxRootDirectoryURL() {
            root = sandboxRoot
            isUsingiCloud = false
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScriptWidgetTests-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent("Documents")
            isUsingiCloud = false
        } else {
            preconditionFailure("ScriptWidget requires its iCloud or App Group container. Check code signing and entitlements.")
        }
        
        let scriptRoot = root.appendingPathComponent("Scripts")
        return (scriptRoot, isUsingiCloud)
    }
    
    func makeSureRootExist() {
        guard unavailableReason == nil, storageContext == nil else { return }
        self.makeSureDirectoryExist(path: self.scriptDirectory)
    }
    func makeSureDirectoryExist(path: URL) {
        guard unavailableReason == nil else { return }
        _ = Self.ensureLocalDirectory(path)
    }

    static func ensureLocalDirectory(_ path: URL) -> Bool {
        guard !ScriptWidgetMetadataFile.isLink(path), !ScriptWidgetMetadataFile.isLink(path.deletingLastPathComponent()) else { return false }
        if ScriptWidgetMetadataFile.exists(path) { return ScriptWidgetPackageFiles.list(root: path) != nil }
        var ancestor = path.deletingLastPathComponent()
        var components = [path.lastPathComponent]
        while !ScriptWidgetMetadataFile.exists(ancestor), ancestor.pathComponents.count > 1 {
            components.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        return ScriptWidgetPackageFiles.ensureDirectory(root: ancestor, relative: components.joined(separator: "/"))
    }

    /// Deterministic unit tests must not read or populate the developer's real
    /// App Group cache. Signed container acceptance uses explicit scoped stores.
    static var usesIsolatedUnitTestBuildCache: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }

    static var hasUnsafeBuildCacheDirectory: Bool {
        if !usesIsolatedUnitTestBuildCache, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget") {
            let cache = root.appendingPathComponent("__Build")
            if ScriptWidgetMetadataFile.exists(cache),
               (ScriptWidgetPackageFiles.safeURL(root: root, relative: "__Build") == nil || (try? cache.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true) { return true }
        }
        let fallback = localFallbackDirectoryURL("__Build")
        return ScriptWidgetMetadataFile.isLink(fallback.deletingLastPathComponent()) ||
            (ScriptWidgetMetadataFile.exists(fallback) && (ScriptWidgetMetadataFile.isLink(fallback) || (try? fallback.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true))
    }

    static func getICloudRootDirectoryURL() -> URL? {
        if let url = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.ScriptWidget") {
            return url.appendingPathComponent("Documents")
        }
        return nil
    }
    
    static func getSandboxRootDirectoryURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget") {
            return url.appendingPathComponent("Documents")
        }
        return nil
    }
    
    static func getSandboxBuildDirectoryURL() -> URL? {
        guard !hasUnsafeBuildCacheDirectory else { return nil }
        if !usesIsolatedUnitTestBuildCache, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget"),
           ScriptWidgetPackageFiles.ensureDirectory(root: root, relative: "__Build") {
            return root.appendingPathComponent("__Build")
        }
        let fallback = localFallbackDirectoryURL("__Build")
        return ensureLocalDirectory(fallback) ? fallback : nil
    }

    /// Local storage used only for disposable build cache state and isolated
    /// tests. Authoritative user scripts must never fall back here because the
    /// app, widgets, and iCloud would then observe different libraries.
    static func localFallbackDirectoryURL(_ component: String) -> URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ScriptWidgetTests-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent(component)
        }
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScriptWidget").appendingPathComponent(component)
    }
    
    static func getSandboxFileCount() -> Int {
        if let url = ScriptManager.getSandboxRootDirectoryURL() {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return 0
            }
            
            return items.filter { item in
                return item != "__Build"
            }
            .count
        }
        return 0
    }
    
    static func moveSandboxFilesToICloud() -> Bool {
        guard let icloudUrl = ScriptManager.getICloudRootDirectoryURL() else { return false }
        guard let sandboxUrl = ScriptManager.getSandboxRootDirectoryURL() else { return false }
        
        do {
            let roots = try FileManager.default.contentsOfDirectory(at: sandboxUrl, includingPropertiesForKeys: [.isDirectoryKey])
            for root in roots where root.lastPathComponent != "__Build" {
                try migrateLocalItems(from: root, to: icloudUrl.appendingPathComponent(root.lastPathComponent))
            }
            return true
        } catch {
            return false
        }
    }

    /// A failed listing or move must never trigger deletion of unverified data.
    /// Successfully moved items are absent from the source; retry is safe.
    static func migrateLocalItems(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let items = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            var target = destination.appendingPathComponent(item.lastPathComponent)
            var suffix = 1
            while fileManager.fileExists(atPath: target.path) {
                let name = values.isDirectory == true || item.pathExtension.isEmpty
                    ? "\(item.lastPathComponent) (\(suffix))"
                    : "\(item.deletingPathExtension().lastPathComponent) (\(suffix)).\(item.pathExtension)"
                target = destination.appendingPathComponent(name)
                suffix += 1
            }
            try fileManager.moveItem(at: item, to: target)
        }
        // rmdir is deliberately nonrecursive: it fails if another process
        // added a file after enumeration, preserving that new file.
        source.withUnsafeFileSystemRepresentation { path in
            if let path { _ = rmdir(path) }
        }
    }

    func isICloudAvaliable() -> Bool {
        if let _ = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return true
        } else {
            return false
        }
    }
    
    func getPackagePathFromPackageName(packageName: String) -> URL? {
        guard unavailableReason == nil, ScriptWidgetPackageName.isValid(packageName),
              !ScriptWidgetMetadataFile.isLink(scriptDirectory.deletingLastPathComponent()) else { return nil }
        return ScriptWidgetPackageFiles.safeURL(root: scriptDirectory, relative: packageName)
    }

    func saveScript(packageName: String, content: String, imageCopyPath: URL?) -> (Bool,String) {
        guard let packagePath = self.getPackagePathFromPackageName(packageName: packageName) else { return (false, "Invalid or ambiguous package name") }
        if let storageContext {
            do {
                try storageContext.validateLibraryRoot()
                if ScriptWidgetMetadataFile.exists(packagePath) { _ = try storageContext.boundDirectory(name: packageName, role: .source) }
            } catch { return (false, "The widget library changed. Reopen it before saving.") }
        }
        if !ScriptWidgetMetadataFile.exists(packagePath) {
            return createBlankPackage(packageName: packageName, content: content, imageCopyPath: imageCopyPath)
        }
        let package = getScriptPackage(packageName: packageName)
        // Saving cannot repair a present invalid manifest by silently replacing
        // its permission declarations. Legacy edits retain their old format.
        if package.hasManifest && package.readManifest() == nil { return (false, "widget.json is invalid.") }
        let result = package.writeMainFile(content: content)

        if result.0, let imageCopyPath = imageCopyPath {
            // copy images to package
            let targetDir = package.imagePath
            try? FileManager.default.copyItem(at: imageCopyPath, to: targetDir)
        }

        if result.0, !self.isBuild {
            _ = buildScriptPackage(package: package)
        }
        
        return result
    }

    private func publishPreparedPackage(_ prepared: URL, name: String) throws {
        guard unavailableReason == nil else { throw ScriptWidgetStorageNamespaceError.unavailable }
        if let storageContext {
            guard storageContext.libraryRoot == scriptDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ScriptWidgetStorageNamespaceError.unavailable
            }
            _ = try storageContext.publish(prepared, name: name)
        } else {
            guard ScriptWidgetPackageFiles.publishDirectory(prepared, root: scriptDirectory, name: name) else {
                throw ScriptWidgetStorageNamespaceError.unavailable
            }
        }
    }

    /// A new blank project becomes visible only after source, optional images,
    /// and its manifest are prepared and validated. Existing edits stay in place.
    private func createBlankPackage(packageName: String, content: String, imageCopyPath: URL?) -> (Bool, String) {
        guard ScriptWidgetPackageName.isValid(packageName) else { return (false, "Invalid package name") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWidgetCreate-\(UUID().uuidString)")
        let prepared = temporary.appendingPathComponent("package")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
            guard ScriptWidgetPackageFiles.write(Data(content.utf8), root: prepared, relative: "main.jsx") else {
                return (false, "The new script could not be prepared.")
            }
            if let imageCopyPath {
                if let error = validateExtractedTree(imageCopyPath) { return (false, error) }
                try FileManager.default.copyItem(at: imageCopyPath, to: prepared.appendingPathComponent("image"))
            }
            let manifest = WidgetPackageManifest.newProject(name: packageName)
            let bytes = try JSONEncoder().encode(manifest)
            guard bytes.count <= ScriptWidgetMetadataFile.maximumBytes,
                  ScriptWidgetPackageFiles.write(bytes, root: prepared, relative: "widget.json") else {
                return (false, "The new package manifest could not be prepared.")
            }
            if let error = validateExtractedTree(prepared) { return (false, error) }
            let validation = WidgetPackageManifestValidator.validate(manifest, package: ScriptWidgetPackage(path: prepared, readonly: true))
            guard validation.isValid else { return (false, validation.errors.map(\.message).joined(separator: "\n")) }
            try publishPreparedPackage(prepared, name: packageName)
            if !isBuild {
                let package = getScriptPackage(packageName: packageName)
                ScriptWidgetPrecompileCoordinator.schedule(package: package, source: content)
                _ = buildScriptPackage(package: package)
            }
            return (true, "")
        } catch { return (false, error.localizedDescription) }
    }
    
    func renameScript(srcPackageName: String, destPackageName: String) -> (Bool, String) {
        guard let srcScriptPath = getPackagePathFromPackageName(packageName: srcPackageName),
              let destScriptPath = getPackagePathFromPackageName(packageName: destPackageName) else { return (false, "Invalid or ambiguous package name") }
        if srcPackageName == destPackageName {
            return (true, "No need rename")
        }

        let file = ScriptWidgetPackage(path: srcScriptPath)
        let renameResult: (Bool, String)
        if let storageContext {
            do {
                guard scriptDirectory.standardizedFileURL.resolvingSymlinksInPath() == storageContext.libraryRoot else {
                    throw ScriptWidgetStorageNamespaceError.conflict
                }
                try storageContext.relocate(name: srcPackageName, destination: destPackageName)
                renameResult = (true, "")
            } catch { renameResult = (false, error.localizedDescription) }
        } else { renameResult = file.rename(destPath: destScriptPath) }
        if renameResult.0, !self.isBuild {
            NotificationCenter.default.post(name: Self.packageRemovedNotification, object: srcPackageName)
            _ = removeBuildScriptPackage(package: file)
            let newPackage = self.getScriptPackage(packageName: destPackageName)
            _ = buildScriptPackage(package: newPackage)
        }
        return renameResult
    }
    
    func getValidPackageName(recommendPackageName: String) -> String {
        guard ScriptWidgetPackageName.isValid(recommendPackageName) else { return "" }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: scriptDirectory.path) else { return "" }
        let identities = Set(entries.map(ScriptWidgetPackageFiles.identity))
        func available(_ name: String) -> Bool {
            !identities.contains(ScriptWidgetPackageFiles.identity(name)) && getPackagePathFromPackageName(packageName: name) != nil
        }
        if available(recommendPackageName) { return recommendPackageName }
        for index in 1...10_000 {
            let suffix = " (\(index))"
            var stem = String(recommendPackageName.prefix(80 - suffix.count))
            while (stem + suffix).utf8.count > 240 { stem.removeLast() }
            let candidate = stem + suffix
            if available(candidate) { return candidate }
        }
        return ""
    }

    func createScript(content: String, recommendPackageName: String, imageCopyPath: URL?) -> (Bool,String) {
        // get valid id (name)
        let packageName = self.getValidPackageName(recommendPackageName: recommendPackageName)
        return createBlankPackage(packageName: packageName, content: content, imageCopyPath: imageCopyPath)
    }

    /// Install an entire template without mutating bundled source or publishing
    /// a partial library folder. RENAME_EXCL commits only to a fresh name.
    func createScript(fromTemplate source: ScriptWidgetPackage) -> (Bool, String) {
        installFreshPackage(source: source, preferredName: nil)
    }

    /// Shared preparation/publication boundary for new template and remix
    /// installs. Public package IDs are refreshed independently of the native
    /// storage identity. Existing legacy packages retain their legacy behavior.
    private func installFreshPackage(source: ScriptWidgetPackage, preferredName: String?) -> (Bool, String) {
        let template = ScriptWidgetPackage(path: source.path, readonly: true)
        if let error = validateExtractedTree(template.path) { return (false, error) }
        var manifest: WidgetPackageManifest
        if template.hasManifest {
            guard let existing = template.readManifest() else { return (false, "widget.json is invalid.") }
            manifest = existing
        } else { manifest = .legacy(name: template.name, metadata: template.readMetadata()) }
        let original = WidgetPackageManifestValidator.validate(manifest, package: template)
        guard original.isValid else { return (false, original.errors.map(\.message).joined(separator: "\n")) }
        let preferred = (preferredName ?? manifest.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ScriptWidgetPackageName.isValid(preferred) else { return (false, "Invalid package name.") }
        let name = getValidPackageName(recommendPackageName: preferred)
        guard getPackagePathFromPackageName(packageName: name) != nil else { return (false, "Invalid package destination.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWidgetTemplate-\(UUID().uuidString)")
        let staging = temporary.appendingPathComponent("package")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: template.path, to: staging)
            if let error = validateExtractedTree(staging) { return (false, error) }
            let cache = staging.appendingPathComponent("__Build")
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            manifest.id = "local.\(UUID().uuidString.lowercased())"
            manifest.name = name
            if template.hasManifest {
                let data = try JSONEncoder().encode(manifest)
                guard data.count <= ScriptWidgetMetadataFile.maximumBytes,
                      ScriptWidgetPackageFiles.write(data, root: staging, relative: "widget.json") else {
                    return (false, "The package manifest could not be prepared.")
                }
            }
            let package = ScriptWidgetPackage(path: staging, readonly: true)
            let validation = WidgetPackageManifestValidator.validate(manifest, package: package)
            guard validation.isValid else { return (false, validation.errors.map(\.message).joined(separator: "\n")) }
            try publishPreparedPackage(staging, name: name)
        } catch { return (false, error.localizedDescription) }
        if !isBuild { _ = buildScriptPackage(package: getScriptPackage(packageName: name)) }
        return (true, name)
    }

    /// Duplicate an existing script into a new package. Returns the new package name on success.
    func duplicateScript(sourcePackageName: String) -> (Bool, String) {
        guard let sourcePath = getPackagePathFromPackageName(packageName: sourcePackageName),
              FileManager.default.fileExists(atPath: sourcePath.path) else { return (false, "Source not found") }
        let suffix = " Remix"
        var stem = String(sourcePackageName.prefix(80 - suffix.count))
        while (stem + suffix).utf8.count > 240 { stem.removeLast() }
        return installFreshPackage(source: ScriptWidgetPackage(path: sourcePath), preferredName: stem + suffix)
    }

    func isExist(packageName: String) -> Bool {
        guard let dirPath = self.getPackagePathFromPackageName(packageName: packageName) else { return false }
        return FileManager.default.fileExists(atPath: dirPath.path)
    }
    
    func scriptCount() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: self.scriptDirectory.path) else { return 0 }
        var count = 0;
        for (_, packageName) in items.enumerated() {
            guard let packagePath = self.getPackagePathFromPackageName(packageName: packageName) else { continue }
            if packagePath.isDirectory {
                count += 1
            }
        }
        return count
    }
    
    func listScripts() -> [ScriptModel] {
        guard unavailableReason == nil else { return [] }
        if let storageContext, (try? storageContext.validateLibraryRoot()) == nil { return [] }
        let models = ScriptManager.listScriptsInDirectory(dirPath: self.scriptDirectory, readonly: false)
        guard storageContext != nil else { return models }
        return models.map { ScriptModel(package: getScriptPackage(packageName: $0.name)) }
    }
    
    func asyncListScripts() async -> [ScriptModel] {
        guard unavailableReason == nil else { return [] }
        let directory = scriptDirectory, context = storageContext
        let role = storageRole
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if let context, (try? context.validateLibraryRoot()) == nil { continuation.resume(returning: []); return }
                let models = ScriptManager.listScriptsInDirectory(dirPath: directory, readonly: false)
                guard let context else { continuation.resume(returning: models); return }
                continuation.resume(returning: models.map { model in
                    ScriptModel(package: ScriptWidgetPackage(path: model.package.path, readonly: false, managedScope: .init(context: context, role: role, binding: try? context.boundDirectory(name: model.name, role: role))))
                })
            }
        }
    }


    static func listBundleScripts(bundle: String, relativePath: String) -> [ScriptModel] {
        guard let bundleURL = Bundle.main.url(forResource: bundle, withExtension: "bundle") else { return [] }
        let dirPath = bundleURL.appendingPathComponent(relativePath)
        
        return ScriptManager.listScriptsInDirectory(dirPath: dirPath, readonly: true)
    }
    
    
    static func listScriptsInDirectory(dirPath: URL, readonly: Bool) -> [ScriptModel] {
        var models = [ScriptModel]()
        guard !ScriptWidgetMetadataFile.isLink(dirPath.deletingLastPathComponent()),
              let items = ScriptWidgetPackageFiles.list(root: dirPath) else { return [] }
        for (_, packageName) in items.enumerated() {
            guard ScriptWidgetPackageName.isValid(packageName),
                  let packagePath = ScriptWidgetPackageFiles.safeURL(root: dirPath, relative: packageName, allowMissing: false) else { continue }
            // we only care about directory, ignore file
            if !packagePath.isDirectory {
                continue
            }
            models.append(ScriptModel(package: ScriptWidgetPackage(path: packagePath, readonly: readonly)))
        }
        models.sort { (a, b) -> Bool in
            return a.name < b.name
        }
        return models
    }
    
    func getScriptPackage(packageName: String) -> ScriptWidgetPackage {
        guard let scriptDirPath = self.getPackagePathFromPackageName(packageName: packageName) else { return .unavailable() }
        return ScriptWidgetPackage(path: scriptDirPath, readonly: false,
            managedScope: storageContext.map { .init(context: $0, role: storageRole, binding: try? $0.boundDirectory(name: packageName, role: storageRole)) })
    }
    
    func deleteScript(packageName: String) -> Bool {
        guard let scriptDirPath = self.getPackagePathFromPackageName(packageName: packageName) else { return false }
        let package = ScriptWidgetPackage(path: scriptDirPath)
        let deleteResult: Bool
        var retiredOwner: String?
        if let storageContext {
            do {
                guard scriptDirectory.standardizedFileURL.resolvingSymlinksInPath() == storageContext.libraryRoot else {
                    throw ScriptWidgetStorageNamespaceError.conflict
                }
                retiredOwner = (try? storageContext.boundDirectory(name: packageName, role: .source))?.ownerID
                try storageContext.relocate(name: packageName)
                deleteResult = true
            } catch { return false }
        } else { deleteResult = package.delete() }
        if deleteResult {
            var info: [String: Any] = [:]
            if let retiredOwner, let storageContext { info = ["retiredOwner": retiredOwner, "storageContext": storageContext] }
            NotificationCenter.default.post(name: Self.packageRemovedNotification, object: packageName, userInfo: info)
        }
        
        let deleteBuildResult = removeBuildScriptPackage(package: package)
        
        return deleteResult && (storageContext != nil || deleteBuildResult.0)
    }
    
    static func readBundleFile(bundle: String, fileName: String) ->  String? {
        guard let bundleUrl = Bundle.main.url(forResource: bundle, withExtension: "bundle") else {
            return nil
        }
        let filePath = bundleUrl.appendingPathComponent(fileName);
        guard let content = try? String(contentsOf: filePath, encoding: .utf8) else {
            return nil
        }
        return content
    }
}

// icloud update
extension ScriptManager {
    
    func requestUpdateICloudScripts() {
        let models = self.listScripts()
        for model in models {
            model.package.updateFiles()
        }
    }
}

// export and import
extension ScriptManager {
    
    func exportScript(model: ScriptModel, toPath: URL) -> Bool {
        guard unavailableReason == nil else { return false }
        guard model.package.ensureManifest().0 else { return false }
        let validation = WidgetPackageManifestValidator.validate(model.package.effectiveManifest(), package: model.package)
        guard validation.isValid else { return false }
        let packageDir = model.package.path
        let result = SSZipArchive.createZipFile(atPath: toPath.path, withContentsOfDirectory: packageDir.path, keepParentDirectory: true)
        return result
    }
    
    func exportScriptItemsInTempPath(model: ScriptModel) -> [URL] {

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let tempFilePath = tempDir.appendingPathComponent(model.exportFileName)

        // remove if existed
        if FileManager.default.fileExists(atPath: tempFilePath.path) {
            try? FileManager.default.removeItem(at: tempFilePath)
        }

        // create new file
        let result = exportScript(model: model, toPath: tempFilePath)
        if !result {
            return []
        }
        
        return [tempFilePath]
    }
    
    func importScript(fromPath: URL) -> Bool {
        importScriptPackage(fromPath: fromPath).succeeded
    }

    func importScriptPackage(fromPath: URL) -> ScriptPackageImportResult {
        if let preflightError = ScriptPackageArchivePreflight.validate(fromPath) {
            return .init(succeeded: false, packageName: nil, message: preflightError, validation: nil)
        }
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptWidgetImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempPath) }
        do {
            try FileManager.default.createDirectory(at: tempPath, withIntermediateDirectories: true)
        } catch {
            return .init(succeeded: false, packageName: nil, message: error.localizedDescription, validation: nil)
        }
        guard SSZipArchive.unzipFile(atPath: fromPath.path, toDestination: tempPath.path) else {
            return .init(succeeded: false, packageName: nil, message: "The package could not be extracted.", validation: nil)
        }
        guard let extractedPackage = extractedPackageRoot(in: tempPath) else {
            return .init(succeeded: false, packageName: nil, message: "The archive must contain one widget package.", validation: nil)
        }
        if let extractedError = validateExtractedTree(extractedPackage) {
            return .init(succeeded: false, packageName: nil, message: extractedError, validation: nil)
        }

        let temporaryPackage = ScriptWidgetPackage(path: extractedPackage)
        // Only a package without widget.json is legacy. A present but malformed
        // manifest is authoritative and fails closed below.
        if !temporaryPackage.hasManifest {
            let migration = temporaryPackage.writeManifest(.legacy(
                name: extractedPackage.lastPathComponent,
                metadata: temporaryPackage.readMetadata()
            ))
            guard migration.0 else {
                return .init(succeeded: false, packageName: nil, message: migration.1, validation: nil)
            }
        }
        guard let manifest = temporaryPackage.readManifest() else {
            return .init(succeeded: false, packageName: nil, message: "widget.json is invalid.", validation: nil)
        }
        let report = WidgetPackageManifestValidator.validate(manifest, package: temporaryPackage)
        guard report.isValid else {
            return .init(
                succeeded: false,
                packageName: nil,
                message: report.errors.map(\.message).joined(separator: "\n"),
                validation: report
            )
        }

        let importedName = getValidPackageName(recommendPackageName: manifest.name)
        guard getPackagePathFromPackageName(packageName: importedName) != nil else {
            return .init(succeeded: false, packageName: nil, message: "Invalid or ambiguous package name", validation: report)
        }
        do { try publishPreparedPackage(extractedPackage, name: importedName) }
        catch { return .init(succeeded: false, packageName: nil, message: error.localizedDescription, validation: report) }
        if !isBuild {
            _ = buildScriptPackage(package: getScriptPackage(packageName: importedName))
        }
        return .init(succeeded: true, packageName: importedName, message: "", validation: report)
    }

    private func extractedPackageRoot(in directory: URL) -> URL? {
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
        if children.contains(where: { $0.lastPathComponent == "main.jsx" || $0.lastPathComponent == "widget.json" }) {
            return directory
        }
        let directories = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard directories.count == 1 else { return nil }
        return directories[0]
    }

    private func validateExtractedTree(_ root: URL) -> String? {
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            return "Package directory could not be verified."
        }
        var count = 0, total = 0
        var paths = Set<String>()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { return "Package file could not be verified." }
            if values.isSymbolicLink == true { return "Symbolic links are not allowed." }
            guard values.isDirectory == true || values.isRegularFile == true else { return "Only directories and regular files are allowed." }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard !relative.contains("\\"), relative.split(separator: "/").count <= ScriptPackageArchivePolicy.maximumPathDepth else { return "Invalid package path." }
            let identity = relative.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(identity).inserted else { return "Case-colliding package paths are not allowed." }
            count += 1
            if count > ScriptPackageArchivePolicy.maximumFileCount { return "Package contains too many entries." }
            guard values.isRegularFile == true else { continue }
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0, attributes.st_nlink == 1 else { return "Hard-linked files are not allowed." }
            guard let size = values.fileSize, size >= 0 else { return "Package file size could not be verified." }
            if size > ScriptPackageArchivePolicy.maximumFileBytes { return "Package file exceeds 25 MiB." }
            guard total <= ScriptPackageArchivePolicy.maximumExpandedBytes - size else { return "Expanded package exceeds 64 MiB." }
            total += size
        }
        return nil
    }
    
}


extension ScriptManager {
    /// Only the active native profile's cache can be shared with WidgetKit.
    /// A directory merely located somewhere inside the App Group is insufficient.
    func validateWidgetCache(_ directory: URL, sharedContainer: URL) throws {
        guard !ScriptWidgetMetadataFile.isLink(sharedContainer), !ScriptWidgetMetadataFile.isLink(directory) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        let shared = sharedContainer.standardizedFileURL.resolvingSymlinksInPath()
        let expected: URL
        if let storageContext {
            try storageContext.validateLibraryRoot()
            guard storageContext.container.standardizedFileURL.resolvingSymlinksInPath() == shared else {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            let profiles = try ScriptWidgetStorageProfiles(container: shared, legacy: .standard)
            let selected = try profiles.readySelection()
            guard URL(fileURLWithPath: selected.profile.path) == storageContext.libraryRoot else {
                throw ScriptWidgetStorageNamespaceError.conflict
            }
            expected = try profiles.widgetCacheRoot()
            try storageContext.validateLibraryRoot()
        } else {
            try ScriptWidgetStorageProfiles.withLegacyAccess(container: shared) {}
            expected = shared.appendingPathComponent("__Build")
        }
        guard directory.standardizedFileURL.resolvingSymlinksInPath() == expected else {
            throw ScriptWidgetStorageNamespaceError.conflict
        }
    }

    func buildScriptPackage(package: ScriptWidgetPackage, requireSharedContainer: Bool = false) -> (Bool, String) {
        guard unavailableReason == nil else { return (false, "The widget library is unavailable.") }
        if isBuild {
            return (false, "Not work when is build is true")
        }
        guard let buildDirectory = buildDirectoryOverride ?? Self.getSandboxBuildDirectoryURL() else {
            return (false, "Failed to get build directory")
        }
        
        if requireSharedContainer {
            guard let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget") else {
                return (false, "The shared widget container is unavailable. Restart ScriptWidget and try again.")
            }
            do { try validateWidgetCache(buildDirectory, sharedContainer: sharedRoot) }
            catch { return (false, "The selected widget cache is unavailable. Reopen the library in ScriptWidget and try again.") }
        }
        if let error = validateExtractedTree(package.path) { return (false, error) }
        do { try storageContext?.requireSeparateCacheRoot(buildDirectory) }
        catch { return (false, "The cache must be separate from the widget library.") }
        self.makeSureDirectoryExist(path: buildDirectory)
        guard (try? ScriptWidgetPackageFiles.directoryReceipt(root: buildDirectory.deletingLastPathComponent(), relative: buildDirectory.lastPathComponent)) != nil else {
            return (false, "The cache directory is unavailable.")
        }

        guard ScriptWidgetPackageName.isValid(package.name),
              let targetDirectory = ScriptWidgetPackageFiles.safeURL(root: buildDirectory, relative: package.name) else { return (false, "Invalid cache package path") }
        let staging = buildDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { _ = ScriptWidgetPackageFiles.removeTree(root: buildDirectory, relative: staging.lastPathComponent) }
        do {
            let sourceBinding: ScriptWidgetStorageDirectoryBinding?
            if let storageContext {
                guard storageContext.libraryRoot == scriptDirectory.standardizedFileURL.resolvingSymlinksInPath(),
                      package.path.standardizedFileURL.resolvingSymlinksInPath() == storageContext.libraryRoot.appendingPathComponent(package.name) else {
                    return (false, "The package does not belong to this widget library.")
                }
                sourceBinding = try storageContext.boundDirectory(name: package.name, role: .source)
            } else { sourceBinding = nil }
            try FileManager.default.copyItem(at: package.path, to: staging)
            if let error = validateExtractedTree(staging) { return (false, error) }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: staging.path)
            let staged = ScriptWidgetPackage(path: staging, readonly: true)
            if staged.hasManifest {
                guard let manifest = staged.readManifest(),
                      WidgetPackageManifestValidator.validate(manifest, package: staged).isValid else {
                    return (false, "Package manifest or files are unavailable. Sync the package before starting the activity.")
                }
            }
            guard (try? String(contentsOf: staged.jsxPath, encoding: .utf8)) != nil else {
                return (false, "Script is unavailable. Open the app online to finish syncing.")
            }
            // Do not publish unresolved iCloud placeholders as a working build.
            let files = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])
            while let url = files?.nextObject() as? URL {
                guard !url.lastPathComponent.hasSuffix(".icloud"),
                      (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    return (false, "Package contains unavailable files or symbolic links.")
                }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
            }
            if let storageContext, let sourceBinding {
                _ = try storageContext.publishCache(staging, source: sourceBinding, cacheRoot: buildDirectory)
            } else {
                guard let receipt = try ScriptWidgetPackageFiles.directoryReceipt(root: buildDirectory, relative: staging.lastPathComponent),
                      ScriptWidgetPackageFiles.replaceCacheDirectory(staging, root: buildDirectory, name: targetDirectory.lastPathComponent, expectedReceipt: receipt) else {
                    return (false, "The cache could not be published atomically.")
                }
            }
            return (true, "Succeed")
        } catch {
            return (false, "Failed to prepare script: \(error.localizedDescription)")
        }
    }

    func removeBuildScriptPackage(package: ScriptWidgetPackage) -> (Bool, String) {
        guard unavailableReason == nil else { return (false, "The widget library is unavailable.") }
        if let storageContext, (try? storageContext.validateLibraryRoot()) == nil { return (false, "The widget library changed.") }
        if isBuild {
            return (false, "Not work when is build is true")
        }
        guard let buildDirectory = buildDirectoryOverride ?? Self.getSandboxBuildDirectoryURL() else {
            return (false, "Failed to get build directory")
        }
        
        self.makeSureDirectoryExist(path: buildDirectory)
        
        // remove target
        guard ScriptWidgetPackageName.isValid(package.name),
              let targetDirectory = ScriptWidgetPackageFiles.safeURL(root: buildDirectory, relative: package.name) else { return (false, "Invalid cache package path") }
        
        if !FileManager.default.fileExists(atPath: targetDirectory.path) {
            return (true, "Already removed")
        }
        
        guard ScriptWidgetPackageFiles.removeTree(root: buildDirectory, relative: package.name) else { return (false, "Cache could not be removed") }
        
        return (true, "Succeed")
    }

    func buildAllScriptPackages() -> (Bool, String) {
        if isBuild {
            return (false, "Not work when is build is true")
        }
        
        let items = listScripts()
        for item in items {
            let result = buildScriptPackage(package: item.package)
            if !result.0 { return result }
        }
        return (true, "Succeed")
    }
    
    func removeAllBuildScriptPackages() -> (Bool, String) {

        if isBuild {
            return (false, "Not work when is build is true")
        }

        let items = listScripts()
        for item in items {
            _ = removeBuildScriptPackage(package: item.package)
        }

        return (true, "Succeed")
    }


}

// MARK: - Proactive local caching (issue #6)
//
// When iCloud Drive is unavailable (e.g. cellular with iCloud disabled, or the
// system evicting unused ubiquitous files), reading a script's files fails and
// the widget shows an error. `ScriptWidgetPackage.readFile` already falls back
// to a per-file build cache, but that cache is only populated when a file has
// been successfully read at least once on this device — so a script synced from
// another device that was never opened here had nothing to fall back to.
//
// These helpers proactively cache every script's runtime files and bounded
// image resources while iCloud is reachable, so later eviction still renders
// the complete widget from the cache.
extension ScriptManager {

    /// Text is required to execute the widget; common image formats are also
    /// retained so an offline fallback does not render an incomplete layout.
    private static let textCacheableExtensions: Set<String> = ["jsx", "js", "json", "txt", "csv", "svg", "md"]
    private static let binaryCacheableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    private static let maximumCachedResourceBytes = 25 * 1024 * 1024

    /// How long a single precache pass will wait for one evicted iCloud file to
    /// download before moving on. Bounded so a slow/absent network can't stall
    /// the whole pass; remaining files are simply picked up on the next pass.
    private static let precacheDownloadTimeout: TimeInterval = 8

    /// Read and locally cache one package's runtime files. A successful read writes
    /// the per-file build cache that `readFile` falls back to. For files that
    /// iCloud has evicted this requests the download and *waits* (bounded) for it
    /// to materialize before reading — so an evicted file is cached on this pass
    /// rather than only after a later app launch (issue #6). MUST be called off
    /// the main thread. Returns the number of files cached this pass.
    @discardableResult
    func precachePackageFiles(_ package: ScriptWidgetPackage, until passDeadline: Date? = nil) -> Int {
        guard !isBuild, unavailableReason == nil else { return 0 }
        if let context = storageContext {
            guard storageRole == .source,
                  package.path.standardizedFileURL == context.libraryRoot.appendingPathComponent(package.name),
                  let binding = try? context.boundDirectory(name: package.name, role: .source),
                  let urls = managedPrecacheURLs(root: package.path) else { return 0 }
            let deadline = min(passDeadline ?? .distantFuture, Date().addingTimeInterval(Self.precacheDownloadTimeout))
            for url in urls {
                guard Date() < deadline, (try? context.validateLibraryRoot()) != nil,
                      ensureDownloaded(url, until: deadline) else { return 0 }
            }
            guard (try? context.boundDirectory(name: package.name, role: .source)) == binding else { return 0 }
            // The native build transaction publishes the entire package and
            // owner binding together. Failed/partial downloads keep the old cache.
            return buildScriptPackage(package: package).0 ? urls.count : 0
        }
        var cached = 0
        for fileURL in cacheableFileURLs(in: package.path) {
            if let passDeadline, Date() >= passDeadline { break }
            guard ensureDownloaded(fileURL, until: passDeadline) else { continue }
            let pathExtension = fileURL.pathExtension.lowercased()
            if Self.textCacheableExtensions.contains(pathExtension),
               package.readFile(fullPath: fileURL).0 != nil {
                cached += 1
            } else if Self.binaryCacheableExtensions.contains(pathExtension),
                      resourceSize(fileURL) <= Self.maximumCachedResourceBytes,
                      package.cacheResource(fullPath: fileURL) {
                cached += 1
            }
        }
        return cached
    }

    private func managedPrecacheURLs(root: URL) -> [URL]? {
        var result: [URL] = [], count = 0
        func visit(_ relative: String, depth: Int) -> Bool {
            guard depth <= ScriptPackageArchivePolicy.maximumPathDepth,
                  let names = ScriptWidgetPackageFiles.list(root: root, relative: relative.isEmpty ? nil : relative) else { return false }
            var identities = Set<String>()
            for name in names {
                if depth == 0 && name == "__Build" { continue }
                count += 1
                guard count <= ScriptPackageArchivePolicy.maximumFileCount,
                      identities.insert(ScriptWidgetPackageFiles.identity(name)).inserted else { return false }
                let path = relative.isEmpty ? name : relative + "/" + name
                guard let kind = ScriptWidgetPackageFiles.kind(root: root, relative: path) else { return false }
                if kind == S_IFDIR {
                    guard visit(path, depth: depth + 1) else { return false }
                } else {
                    guard kind == S_IFREG else { return false }
                    result.append(Self.logicalURL(for: root.appendingPathComponent(path)))
                }
            }
            return true
        }
        return visit("", depth: 0) ? result : nil
    }

    /// Proactively cache every script so widgets keep rendering when iCloud is
    /// later unavailable. Call when the app becomes active / is online.
    func precacheAllScripts() {
        if isBuild { return }
        let deadline = Date().addingTimeInterval(30)
        for model in listScripts() {
            guard Date() < deadline else { return }
            precachePackageFiles(model.package, until: deadline)
        }
    }

    /// Logical URLs of cacheable runtime files under `root`, resolving iCloud
    /// placeholders (".main.jsx.icloud") back to their real names so evicted
    /// files are still discovered and downloaded.
    private func cacheableFileURLs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            let logical = Self.logicalURL(for: url)
            let pathExtension = logical.pathExtension.lowercased()
            if Self.textCacheableExtensions.contains(pathExtension)
                || Self.binaryCacheableExtensions.contains(pathExtension) {
                result.append(logical)
            }
        }
        return result
    }

    private func resourceSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
    }

    /// Map an iCloud placeholder URL (".main.jsx.icloud") back to its logical
    /// file URL ("main.jsx"); returns `url` unchanged for normal files.
    static func logicalURL(for url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return url }
        let logicalName = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(logicalName)
    }

    /// Ensure a (possibly iCloud-evicted) file is present locally. Returns
    /// immediately if it already exists; otherwise requests the download and
    /// polls up to `precacheDownloadTimeout`. Returns whether the file is present
    /// afterwards. MUST be called off the main thread.
    private func ensureDownloaded(_ url: URL, until sharedDeadline: Date? = nil) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = sharedDeadline ?? Date().addingTimeInterval(Self.precacheDownloadTimeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]),
               let error = values.ubiquitousItemDownloadingError {
                print("precache: iCloud download error for \(url.lastPathComponent): \(error)")
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}






/// Narrow read boundary used by package-list UI. The default implementation
/// deliberately delegates to `ScriptManager` so introducing this seam cannot
/// change package discovery, ordering, iCloud, or local fallback behavior.
protocol ScriptPackageListing {
    func listScripts() -> [ScriptModel]
}

struct DefaultScriptPackageRepository: ScriptPackageListing {
    private let manager: ScriptManager

    init(manager: ScriptManager = sharedScriptManager) {
        self.manager = manager
    }

    func listScripts() -> [ScriptModel] {
        manager.listScripts()
    }
}

private let legacySharedScriptManager = ScriptManager(isBuild: false)
private let legacyBuildScriptManager = ScriptManager(isBuild: true)

var sharedScriptManager: ScriptManager {
    ScriptWidgetLibraryManagers.resolve(isBuild: false) { legacySharedScriptManager }
}
var buildScriptManager: ScriptManager {
    ScriptWidgetLibraryManagers.resolve(isBuild: true) { legacyBuildScriptManager }
}



extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
