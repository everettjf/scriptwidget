//
//  ScriptWidgetPackage.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/10.
//

import Foundation
import CryptoKit
import ImageIO
import Darwin
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ImageModel : Identifiable {
    let name: String
    let path: URL

    var id: String { path.standardizedFileURL.path }
}

struct FileModel: Identifiable, Hashable {
    let name: String
    let relativePath: String
    let path: URL

    var id: String { relativePath }
}

/// Stable protocol shared by every Studio host. Keeping message names here
/// prevents the iOS and macOS bridges from drifting independently.
enum StudioProtocol {
    static let version = 1
    static let ready = "studio.ready"
    static let documentOpen = "document.open"
    static let documentChanged = "document.changed"
    static let documentSave = "document.save"
    static let documentReplace = "document.replace"
    static let documentSetReadOnly = "document.setReadOnly"
    static let documentResources = "document.resources"
    static let editorInsert = "editor.insert"
    static let editorFormat = "editor.format"
    static let editorGetState = "editor.getState"

    static func envelope(type: String, documentID: String?, payload: [String: Any], sessionID: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "protocolVersion": version,
            "type": type,
            "documentID": documentID as Any? ?? NSNull(),
            "payload": payload,
        ]
        if let sessionID { value["sessionID"] = sessionID }
        return value
    }
}

struct StudioEditorTarget: Equatable {
    let editorID: UUID
    let documentID: String
}

struct StudioDocumentSnapshot: Equatable {
    let content: String
    let version: Int
    let selection: Range<Int>
    let documentID: String?
    let sessionID: String?
    let editorID: UUID?
    var target: StudioEditorTarget? {
        guard let editorID, let documentID else { return nil }
        return StudioEditorTarget(editorID: editorID, documentID: documentID)
    }

    init?(state: Any?, editorID: UUID? = nil) {
        guard
            let state = state as? [String: Any],
            let content = state["content"] as? String
        else { return nil }
        let version = state["version"] as? Int ?? 0
        let selection = state["selection"] as? [String: Any]
        let from = selection?["from"] as? Int ?? 0
        let to = selection?["to"] as? Int ?? from
        self.init(content: content, version: version, selection: min(from, to)..<max(from, to),
                  documentID: state["documentID"] as? String, sessionID: state["sessionID"] as? String, editorID: editorID)
    }

    init(content: String, version: Int, selection: Range<Int>, documentID: String? = nil, sessionID: String? = nil, editorID: UUID? = nil) {
        self.content = content
        self.version = version
        self.selection = selection
        self.documentID = documentID
        self.sessionID = sessionID
        self.editorID = editorID
    }
}

enum StudioDocumentApplyResult: Equatable {
    case saved, conflict, unavailable, saveFailed
    var message: String {
        switch self {
        case .saved: return "Applied and saved. Use Undo to restore the previous version."
        case .conflict: return "The file changed. Review the current code before applying this proposal."
        case .unavailable: return "The editor is not ready. Reopen the file and try again."
        case .saveFailed: return "Saving could not be confirmed. Keep the editor open and try saving again."
        }
    }
}

@MainActor final class StudioEditorSaveRequest {
    let target: StudioEditorTarget
    private var completion: ((Bool) -> Void)?
    init(target: StudioEditorTarget, completion: @escaping (Bool) -> Void) {
        self.target = target
        self.completion = completion
    }
    func finish(_ saved: Bool) {
        let callback = completion
        completion = nil
        callback?(saved)
    }
}

@MainActor final class StudioEditorSnapshotRequest {
    let target: StudioEditorTarget
    private var completion: ((StudioDocumentSnapshot?) -> Void)?
    init(target: StudioEditorTarget, completion: @escaping (StudioDocumentSnapshot?) -> Void) {
        self.target = target
        self.completion = completion
    }
    func finish(_ snapshot: StudioDocumentSnapshot?) {
        let callback = completion
        completion = nil
        callback?(snapshot)
    }
}

@MainActor final class StudioEditorReplacementRequest {
    let snapshot: StudioDocumentSnapshot
    let content: String
    private var completion: ((StudioDocumentApplyResult) -> Void)?
    var isPending: Bool { completion != nil }
    init(snapshot: StudioDocumentSnapshot, content: String, completion: @escaping (StudioDocumentApplyResult) -> Void) {
        self.snapshot = snapshot
        self.content = content
        self.completion = completion
    }
    func finish(_ result: StudioDocumentApplyResult) {
        let callback = completion
        completion = nil
        callback?(result)
    }
}

// SwiftUI may create a replacement before dismantling the previous host.
// Retire the old instance as soon as the same logical editor is recreated,
// so its document handoff starts before the new host can read from disk.
@MainActor enum StudioEditorHostRegistry {
    private final class Entry {
        weak var host: AnyObject?
        let retire: () -> Void

        init(host: AnyObject, retire: @escaping () -> Void) {
            self.host = host
            self.retire = retire
        }
    }

    private static var entries: [UUID: Entry] = [:]

    static func register(editorID: UUID, host: AnyObject, retire: @escaping () -> Void) {
        entries = entries.filter { $0.value.host != nil }
        if let previous = entries[editorID], previous.host !== host {
            previous.retire()
        }
        entries[editorID] = Entry(host: host, retire: retire)
    }
}

// Keep a reopening behind a closing editor's final JS snapshot. A new view
// must not read the old file before the outgoing recovery draft is committed.
@MainActor enum StudioDocumentHandoff {
    private static var closing: [String: Set<UUID>] = [:]
    private static var waiting: [String: [() -> Void]] = [:]

    static func begin(_ documentID: String) -> UUID {
        let token = UUID()
        closing[documentID, default: []].insert(token)
        return token
    }

    static func finish(_ documentID: String, token: UUID) {
        guard closing[documentID]?.remove(token) != nil else { return }
        guard closing[documentID]?.isEmpty == true else { return }
        closing.removeValue(forKey: documentID)
        let actions = waiting.removeValue(forKey: documentID) ?? []
        actions.forEach { $0() }
    }

    static func afterClosing(_ documentID: String, action: @escaping () -> Void) {
        if closing[documentID] == nil { action() }
        else { waiting[documentID, default: []].append(action) }
    }
}

@MainActor final class StudioEditorCloseRequest {
    private var completion: ((Any?) -> Void)?
    init(completion: @escaping (Any?) -> Void) { self.completion = completion }
    func finish(_ response: Any?) {
        let callback = completion
        completion = nil
        callback?(response)
    }
}

/// Owns document identity and the persisted-draft baseline for native Studio
/// hosts. Web views remain responsible only for transport and presentation.
final class StudioDocumentSession {
    private(set) var documentID: String?
    private(set) var savedContent = ""
    private(set) var bufferedContent = ""
    private(set) var bufferedVersion = 0
    private let drafts: StudioDraftStore

    init(drafts: StudioDraftStore = .shared) {
        self.drafts = drafts
    }

    func open(documentID: String, content: String) -> String {
        self.documentID = documentID
        savedContent = content
        bufferedContent = drafts.recover(documentID: documentID, currentContent: content)?.content ?? content
        bufferedVersion = 0
        return bufferedContent
    }

    // CodeMirror offsets are UTF-16 and refer to the same original document.
    // Apply validated changes right-to-left, retaining an in-memory recovery
    // snapshot without sending/writing the whole source on every keystroke.
    func bufferChange(_ payload: [String: Any]) -> Bool {
        guard documentID != nil, let version = payload["version"] as? Int, version >= 0 else { return false }
        if let content = payload["content"] as? String {
            return bufferSnapshot(content, version: version)
        }
        guard bufferedVersion < Int.max, version == bufferedVersion + 1,
              let changes = payload["changes"] as? [[String: Any]] else { return false }
        var content = bufferedContent
        var boundary = content.utf16.count
        for change in changes.reversed() {
            guard let from = change["from"] as? Int, let to = change["to"] as? Int,
                  let inserted = change["insert"] as? String,
                  from >= 0, to >= from, to <= boundary else { return false }
            let units = content.utf16
            guard let lower = String.Index(units.index(units.startIndex, offsetBy: from), within: content.unicodeScalars),
                  let upper = String.Index(units.index(units.startIndex, offsetBy: to), within: content.unicodeScalars) else { return false }
            content.replaceSubrange(lower..<upper, with: inserted)
            boundary = from
        }
        bufferedContent = content
        bufferedVersion = version
        return true
    }

    @discardableResult
    func bufferSnapshot(_ content: String, version: Int) -> Bool {
        guard documentID != nil, version >= bufferedVersion else { return false }
        bufferedContent = content
        bufferedVersion = version
        return true
    }

    func persistBufferedDraft() {
        recordDraft(bufferedContent)
    }

    func recordDraft(_ content: String) {
        guard let documentID else { return }
        drafts.save(documentID: documentID, baseContent: savedContent, content: content)
    }

    func markSaved(_ content: String) {
        savedContent = content
        if let documentID { drafts.remove(documentID: documentID) }
    }

    func save(_ content: String, documentID: String, writer: (String) -> Bool) -> Bool {
        guard self.documentID == documentID else { return false }
        guard needsSave(content) else { return true }
        recordDraft(content)
        guard writer(content) else { return false }
        markSaved(content)
        return true
    }

    func needsSave(_ content: String) -> Bool {
        content != savedContent
    }
}

/// Crash-safe editor drafts. A draft is restored only while its base file hash
/// still matches, so an iCloud or external edit always wins over stale local work.
struct StudioDraftRecord: Codable, Equatable {
    let documentID: String
    let baseHash: String
    let content: String
    let updatedAt: Date
}

final class StudioDraftStore {
    static let shared = StudioDraftStore()

    private let directory: URL
    private let queue = DispatchQueue(label: "scriptwidget.studio-drafts")

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent("ScriptWidgetStudioDrafts", isDirectory: true)
    }

    func save(documentID: String, baseContent: String, content: String, date: Date = Date()) {
        guard content != baseContent else {
            remove(documentID: documentID)
            return
        }
        let record = StudioDraftRecord(
            documentID: documentID,
            baseHash: Self.hash(baseContent),
            content: content,
            updatedAt: date
        )
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: recordURL(documentID), options: .atomic)
            } catch {
                NSLog("ScriptWidget Studio draft persistence failed: %@", error.localizedDescription)
            }
        }
    }

    func recover(documentID: String, currentContent: String) -> StudioDraftRecord? {
        queue.sync {
            guard
                let data = try? Data(contentsOf: recordURL(documentID)),
                let record = try? JSONDecoder().decode(StudioDraftRecord.self, from: data),
                record.documentID == documentID,
                record.baseHash == Self.hash(currentContent),
                record.content != currentContent
            else { return nil }
            return record
        }
    }

    func remove(documentID: String) {
        queue.sync {
            try? FileManager.default.removeItem(at: recordURL(documentID))
        }
    }

    private func recordURL(_ documentID: String) -> URL {
        directory.appendingPathComponent(Self.hash(documentID) + ".json")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// iCloud availability of a single ubiquitous (or local) file. Surfaced so the
/// UI can tell "downloading from iCloud" apart from a real failure (issue #6).
enum ICloudItemState: Equatable {
    case local          // a non-ubiquitous file that is present on disk
    case downloaded     // ubiquitous item present locally (current)
    case downloading    // not present locally; an iCloud download is in flight
    case notInICloud    // not present and no iCloud placeholder to download from
    case error(String)  // iCloud reported a download error
}

/// Pure iCloud metadata classifier. Keeping this separate from FileManager
/// makes every user-visible state deterministic and testable without requiring
/// a signed-in iCloud account on CI or Simulator.
enum ICloudItemStateResolver {
    static func resolve(
        downloadError: Error?,
        isDownloading: Bool?,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        hasPlaceholder: Bool
    ) -> ICloudItemState {
        if let downloadError { return .error(downloadError.localizedDescription) }
        if isDownloading == true { return .downloading }
        if let downloadingStatus {
            switch downloadingStatus {
            case .current, .downloaded: return .downloaded
            default: return .downloading
            }
        }
        return hasPlaceholder ? .downloading : .notInICloud
    }
}

/// Where a file's content came from when read.
enum ScriptFileSource: Equatable {
    case file        // the primary (iCloud / local) path
    case buildCache  // the local fallback cache, primary was unavailable
}

/// Outcome of reading a script file, richer than the legacy `(String?, String)`
/// tuple so callers can show a meaningful state instead of a generic error.
struct ScriptFileReadResult {
    let content: String?
    let source: ScriptFileSource?
    let icloud: ICloudItemState
    let message: String

    var succeeded: Bool { content != nil }
}

struct ScriptWidgetBuildManifest: Codable, Equatable {
    static let formatVersion = 2

    let formatVersion: Int
    let runtimeAPIVersion: String
    let compilerFingerprint: String
    let sourceHash: String
    let compiledHash: String
    let sourceBytes: Int
    let compiledBytes: Int
    let libraries: [String]
    let createdAt: Date
}

enum ScriptWidgetBuildContract {
    static let runtimeAPIVersion = "1.0"
    static let nativeRuntimeAPIVersion = "1.6"
    static let compilerFingerprint = "scriptwidget-babel-v3"
}

/// Common-layer indirection keeps Share Extension independent of JavaScriptCore
/// compiler sources. Runtime-capable hosts install the handler on first use;
/// all hosts can still save/import packages and the first render remains a
/// safe compilation fallback.
enum ScriptWidgetPrecompileCoordinator {
    private static let lock = NSLock()
    private static var handler: ((ScriptWidgetPackage, String) -> Void)?

    static func install(_ value: @escaping (ScriptWidgetPackage, String) -> Void) {
        lock.lock()
        handler = value
        lock.unlock()
    }

    static func schedule(package: ScriptWidgetPackage, source: String) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(package, source)
    }
}

struct ScriptWidgetCompiledArtifact {
    let javaScript: String
    let manifest: ScriptWidgetBuildManifest
}

/// Versioned, atomic last-known-good compiled output. The source remains the
/// authority; a compiled artifact is accepted only when every hash and runtime
/// contract field matches.
enum ScriptWidgetCompiledArtifactStore {
    static let directoryName = "__Compiled"
    static let manifestName = "build-manifest.json"
    static let javaScriptName = "main.js"

    // Fixed slots bound total cache size; collisions only evict compiled output.
    private struct NativeEnvelope: Codable {
        let version: Int
        let owner: String
        let policyHash: String
        let manifest: ScriptWidgetBuildManifest
        let javaScript: String
    }

    private static func nativeLocation(_ package: ScriptWidgetPackage) throws -> (ScriptWidgetStorageFiles, String, ScriptWidgetManagedPackageScope, String)? {
        guard let scope = package.compiledScope, let binding = scope.binding else { return nil }
        try scope.validate(name: package.name)
        guard let backend = scope.context.defaults as? ScriptWidgetFileStorageBackend else { return nil }
        let policy: Data
        if package.hasManifest {
            guard let manifest = package.readManifest() else { return nil }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            policy = try encoder.encode(manifest)
        } else { policy = Data("legacy".utf8) }
        let slot = Int(SHA256.hash(data: Data(binding.ownerID.utf8)).first(where: { _ in true })!) % 32
        return (backend.files, "CompiledArtifact.v1.slot.\(slot)", scope, hash(policy))
    }

    private static func loadNative(_ package: ScriptWidgetPackage) -> ScriptWidgetCompiledArtifact? {
        guard let location = try? nativeLocation(package),
              let bytes = try? location.0.readMetadata(key: location.1),
              let envelope = try? JSONDecoder().decode(NativeEnvelope.self, from: bytes),
              envelope.version == 1, envelope.owner == location.2.binding?.ownerID,
              envelope.policyHash == location.3,
              envelope.javaScript.utf8.count <= 2 * 1_024 * 1_024,
              envelope.manifest.formatVersion == ScriptWidgetBuildManifest.formatVersion,
              envelope.manifest.runtimeAPIVersion == ScriptWidgetBuildContract.runtimeAPIVersion,
              envelope.manifest.compilerFingerprint == ScriptWidgetBuildContract.compilerFingerprint,
              envelope.manifest.compiledBytes == envelope.javaScript.utf8.count,
              envelope.manifest.compiledHash == compiledHash(envelope.javaScript),
              (try? location.2.validate(name: package.name)) != nil else { return nil }
        return .init(javaScript: envelope.javaScript, manifest: envelope.manifest)
    }

    static func sourceHash(_ source: String) -> String { hash(Data(source.utf8)) }
    static func compiledHash(_ source: String) -> String { hash(Data(source.utf8)) }

    static func inferredLibraries(source: String) -> [String] {
        // Compatibility dependency discovery is intentionally conservative:
        // comments may produce a harmless false positive, while member access
        // and calls cover existing Moment templates without changing API 1.0.
        let patterns = ["moment(", "moment."]
        return patterns.contains(where: source.contains) ? ["moment"] : []
    }

    static func load(package: ScriptWidgetPackage, source: String) -> ScriptWidgetCompiledArtifact? {
        guard let artifact = loadLastKnownGood(package: package),
              artifact.manifest.sourceHash == sourceHash(source),
              artifact.manifest.sourceBytes == source.utf8.count else { return nil }
        return artifact
    }

    /// Returns only a fully self-consistent prior artifact. Callers may use it
    /// after a new source revision fails to compile, preserving a working widget
    /// without ever executing partially-written or hash-mismatched bytes.
    static func loadLastKnownGood(package: ScriptWidgetPackage) -> ScriptWidgetCompiledArtifact? {
        if package.compiledScope != nil { return loadNative(package) }
        guard artifactDirectory(package: package) != nil, let root = ScriptManager.getSandboxBuildDirectoryURL(),
              let manifestData = ScriptWidgetPackageFiles.read(root: root, relative: package.name + "/" + directoryName + "/" + manifestName, maximumBytes: 256 * 1_024),
              let manifest = try? JSONDecoder().decode(ScriptWidgetBuildManifest.self, from: manifestData),
              manifest.formatVersion == ScriptWidgetBuildManifest.formatVersion,
              manifest.runtimeAPIVersion == ScriptWidgetBuildContract.runtimeAPIVersion,
              manifest.compilerFingerprint == ScriptWidgetBuildContract.compilerFingerprint,
              let bytes = ScriptWidgetPackageFiles.read(root: root, relative: package.name + "/" + directoryName + "/" + javaScriptName, maximumBytes: 2 * 1_024 * 1_024),
              let javaScript = String(data: bytes, encoding: .utf8),
              manifest.compiledBytes == javaScript.utf8.count,
              manifest.compiledHash == compiledHash(javaScript) else {
            return nil
        }
        return ScriptWidgetCompiledArtifact(javaScript: javaScript, manifest: manifest)
    }

    @discardableResult
    static func save(package: ScriptWidgetPackage, source: String, javaScript: String) -> Bool {
        guard javaScript.utf8.count <= 2 * 1_024 * 1_024 else { return false }
        let manifest = ScriptWidgetBuildManifest(
            formatVersion: ScriptWidgetBuildManifest.formatVersion,
            runtimeAPIVersion: ScriptWidgetBuildContract.runtimeAPIVersion,
            compilerFingerprint: ScriptWidgetBuildContract.compilerFingerprint,
            sourceHash: sourceHash(source),
            compiledHash: compiledHash(javaScript),
            sourceBytes: source.utf8.count,
            compiledBytes: javaScript.utf8.count,
            libraries: inferredLibraries(source: source),
            createdAt: Date()
        )
        if package.compiledScope != nil {
            do {
                guard let location = try nativeLocation(package), let owner = location.2.binding?.ownerID else { return false }
                let envelope = NativeEnvelope(version: 1, owner: owner, policyHash: location.3, manifest: manifest, javaScript: javaScript)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try location.0.writeMetadata(key: location.1, data: encoder.encode(envelope))
                try location.2.validate(name: package.name)
                return true
            } catch { return false }
        }
        guard artifactDirectory(package: package) != nil, let root = ScriptManager.getSandboxBuildDirectoryURL() else { return false }
        do {
            guard ScriptWidgetPackageFiles.ensureDirectory(root: root, relative: package.name + "/" + directoryName) else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard ScriptWidgetPackageFiles.write(Data(javaScript.utf8), root: root, relative: package.name + "/" + directoryName + "/" + javaScriptName),
                  ScriptWidgetPackageFiles.write(try encoder.encode(manifest), root: root, relative: package.name + "/" + directoryName + "/" + manifestName) else { return false }
            return true
        } catch {
            print("compiled artifact write failed: \(error.localizedDescription)")
            return false
        }
    }

    static func remove(package: ScriptWidgetPackage) {
        guard artifactDirectory(package: package) != nil, let root = ScriptManager.getSandboxBuildDirectoryURL() else { return }
        _ = ScriptWidgetPackageFiles.removeTree(root: root, relative: package.name + "/" + directoryName)
    }

    static func artifactDirectory(package: ScriptWidgetPackage) -> URL? {
        guard !package.readonly, package.managedScope == nil, package.executionFiles == nil, ScriptWidgetPackageName.isValid(package.name), let root = ScriptManager.getSandboxBuildDirectoryURL() else { return nil }
        return ScriptWidgetPackageFiles.safeURL(root: root, relative: package.name + "/" + directoryName)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads package metadata without following user-controlled links. The OS-owned
/// ancestor may have canonical aliases (e.g. /var), but package entries may not.
enum ScriptWidgetMetadataFile {
    static let maximumBytes = 256 * 1_024

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        // lstat also sees dangling links. Errors other than absence fail closed.
        return lstat(url.path, &info) == 0 || (errno != ENOENT && errno != ENOTDIR)
    }

    static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func read(root: URL, components: [String]) -> Data? {
        guard !components.isEmpty, components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0")
        }) else { return nil }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return data }
            guard data.count <= maximumBytes - count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

/// Package-relative operations use directory descriptors so swapping a child
/// for a symlink cannot redirect a read or atomic write outside the package.
enum ScriptWidgetPackageFiles {
    #if os(iOS) && !targetEnvironment(simulator)
    private static let unprotectedClass: Int32? = {
        // Obtain Foundation's public .noFileProtection policy through a private
        // reference file, then apply it to our open descriptor. No path-based
        // attribute change can be redirected through an untrusted child link.
        let reference = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWidgetProtection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reference) }
        do { try Data().write(to: reference, options: [.withoutOverwriting, .noFileProtection]) } catch { return nil }
        let fd = open(reference.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let value = fcntl(fd, F_GETPROTECTIONCLASS)
        return value >= 0 ? value : nil
    }()
    #endif

    static func preserveWidgetProtection(_ fd: Int32) -> Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let value = unprotectedClass else { return false }
        return fcntl(fd, F_SETPROTECTIONCLASS, value) == 0
        #else
        return true // Simulator/macOS do not validate iOS Data Protection.
        #endif
    }

    static func components(_ relative: String) -> [String]? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard relative.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              (1...16).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") &&
            $0.utf8.count <= 255 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || $0.value == 0x200C || $0.value == 0x200D }
        }) else { return nil }
        return parts
    }

    static func identity(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    static func names(_ directory: Int32, maximumCount: Int = 100_000) -> [String]? {
        let copy = dup(directory)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if name != "." && name != ".." { result.append(name) }
            // Archive/package limits bound authored trees, but a library can
            // legitimately hold more than 500 packages.
            if result.count > maximumCount { return nil }
            errno = 0
        }
        return errno == 0 ? result : nil
    }

    private static func unambiguous(_ name: String, in directory: Int32) -> Bool {
        guard let entries = names(directory) else { return false }
        return !entries.contains { identity($0) == identity(name) && $0 != name }
    }

    static func safeURL(root: URL, relative: String, allowMissing: Bool = true) -> URL? {
        guard let parts = components(relative) else { return nil }
        let root = root.standardizedFileURL
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            guard allowMissing, errno == ENOENT, !ScriptWidgetMetadataFile.exists(root),
                  components(root.lastPathComponent)?.count == 1 else { return nil }
            let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { return nil }
            defer { close(parent) }
            guard unambiguous(root.lastPathComponent, in: parent) else { return nil }
            return root.appendingPathComponent(relative)
        }
        defer { close(directory) }
        for (index, name) in parts.enumerated() {
            guard unambiguous(name, in: directory) else { return nil }
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                return allowMissing && errno == ENOENT ? root.appendingPathComponent(relative) : nil
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG, kind != S_IFREG || info.st_nlink == 1 else { return nil }
            if index < parts.count - 1 {
                let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { return nil }
                close(directory); directory = next
            }
        }
        return root.appendingPathComponent(relative)
    }

    static func withParent<T>(root: URL, relative: String, create: Bool = false, operation: (Int32, String) -> T?) -> T? {
        guard let parts = components(relative) else { return nil }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for name in parts.dropLast() {
            guard unambiguous(name, in: directory) else { return nil }
            if create && mkdirat(directory, name, 0o700) != 0 && errno != EEXIST { return nil }
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(directory); directory = next
            if create && !preserveWidgetProtection(directory) { return nil }
        }
        guard let last = parts.last, unambiguous(last, in: directory) else { return nil }
        return operation(directory, last)
    }

    static func list(root: URL, relative: String? = nil, maximumCount: Int = 100_000) -> [String]? {
        if let relative {
            return withParent(root: root, relative: relative) { directory, name in
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return nil }
                defer { close(child) }
                return names(child, maximumCount: maximumCount)
            }
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return names(fd, maximumCount: maximumCount)
    }

    static func kind(root: URL, relative: String) -> mode_t? {
        withParent(root: root, relative: relative) { directory, name in
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            let kind = info.st_mode & S_IFMT
            return kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1) ? kind : nil
        }
    }

    static func ensureDirectory(root: URL, relative: String) -> Bool {
        withParent(root: root, relative: relative, create: true) { directory, name in
            guard mkdirat(directory, name, 0o700) == 0 || errno == EEXIST else { return false }
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return false }
            defer { close(child) }
            return preserveWidgetProtection(child)
        } ?? false
    }

    static func read(root: URL, relative: String, maximumBytes: Int = 25 * 1_024 * 1_024) -> Data? {
        withParent(root: root, relative: relative) { directory, name in
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            // A concurrent atomic replacement may unlink the old inode after
            // openat. Its descriptor still holds a complete private snapshot;
            // zero links is valid here, while multiple links remain rejected.
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink <= 1,
                  info.st_size >= 0, info.st_size <= maximumBytes else { return nil }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0 { if errno == EINTR { continue }; return nil }
                if count == 0 { return data }
                guard data.count <= maximumBytes - count else { return nil }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
    }

    static func write(_ data: Data, root: URL, relative: String) -> Bool {
        guard data.count <= 25 * 1_024 * 1_024 else { return false }
        return withParent(root: root, relative: relative, create: true) { directory, name in
            var existing = stat()
            if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { return false }
            } else if errno != ENOENT { return false }
            let temporary = ".write-\(UUID().uuidString)"
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd); _ = unlinkat(directory, temporary, 0) }
            let saved = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 { if errno == EINTR { continue }; return false }
                    if count == 0 { return false }
                    offset += count
                }
                return true
            }
            return saved && preserveWidgetProtection(fd) && fsync(fd) == 0 && renameat(directory, temporary, directory, name) == 0
        } ?? false
    }

    static func move(root: URL, source: String, destination: String, expectedReceipt: ScriptWidgetStoragePublicationReceipt? = nil) -> Bool {
        withParent(root: root, relative: source) { sourceDirectory, sourceName in
            var info = stat()
            guard fstatat(sourceDirectory, sourceName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { return false }
            if let expectedReceipt {
                guard info.st_mode & S_IFMT == S_IFDIR, expectedReceipt.matches(parent: sourceDirectory, name: sourceName) else { return false }
            }
            return withParent(root: root, relative: destination) { destinationDirectory, destinationName in
                renameatx_np(sourceDirectory, sourceName, destinationDirectory, destinationName, UInt32(RENAME_EXCL)) == 0
            } ?? false
        } ?? false
    }

    static func publishDirectory(_ source: URL, root: URL, name: String) -> Bool {
        publishDirectory(source, root: root, name: name, expectedReceipt: nil)
    }

    /// Directory identities come from descriptors, never package metadata.
    /// Nil means a verified absent child; unsafe/inaccessible paths throw.
    static func directoryReceipt(root: URL, relative: String) throws -> ScriptWidgetStoragePublicationReceipt? {
        let result: Result<ScriptWidgetStoragePublicationReceipt?, Error>? = withParent(root: root, relative: relative) { parent, name in
            var entry = stat()
            if fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
                return errno == ENOENT ? .success(nil) : .failure(ScriptWidgetStorageNamespaceError.unavailable)
            }
            guard entry.st_mode & S_IFMT == S_IFDIR else { return .failure(ScriptWidgetStorageNamespaceError.conflict) }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return .failure(ScriptWidgetStorageNamespaceError.unavailable) }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino else {
                return .failure(ScriptWidgetStorageNamespaceError.conflict)
            }
            do { return .success(try ScriptWidgetStoragePublicationReceipt.capture(directory: child)) }
            catch { return .failure(error) }
        }
        guard let result else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return try result.get()
    }

    static func publishDirectory(_ source: URL, root: URL, name: String, expectedReceipt: ScriptWidgetStoragePublicationReceipt?) -> Bool {
        guard ScriptWidgetPackageName.isValid(name), !ScriptWidgetMetadataFile.isLink(root.deletingLastPathComponent()) else { return false }
        return withParent(root: source.deletingLastPathComponent(), relative: source.lastPathComponent) { sourceParent, sourceName in
            var info = stat()
            guard fstatat(sourceParent, sourceName, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
            if let expectedReceipt {
                guard expectedReceipt.matches(parent: sourceParent, name: sourceName) else { return false }
            }
            return withParent(root: root, relative: name) { parent, finalName in
                renameatx_np(sourceParent, sourceName, parent, finalName, UInt32(RENAME_EXCL)) == 0
            } ?? false
        } ?? false
    }

    /// Disposable cache replacement: atomically exchange two directories.
    /// After a swap the old cache is at source, for bounded caller cleanup.
    static func replaceCacheDirectory(_ source: URL, root: URL, name: String, expectedReceipt: ScriptWidgetStoragePublicationReceipt) -> Bool {
        guard ScriptWidgetPackageName.isValid(name), !ScriptWidgetMetadataFile.isLink(root.deletingLastPathComponent()) else { return false }
        return withParent(root: source.deletingLastPathComponent(), relative: source.lastPathComponent) { sourceParent, sourceName in
            var prepared = stat()
            guard fstatat(sourceParent, sourceName, &prepared, AT_SYMLINK_NOFOLLOW) == 0,
                  prepared.st_mode & S_IFMT == S_IFDIR, expectedReceipt.matches(parent: sourceParent, name: sourceName) else { return false }
            return withParent(root: root, relative: name) { parent, finalName in
                var existing = stat()
                if fstatat(parent, finalName, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { return false }
                    return renameatx_np(sourceParent, sourceName, parent, finalName, UInt32(RENAME_EXCL)) == 0
                }
                guard existing.st_mode & S_IFMT == S_IFDIR,
                      existing.st_dev != prepared.st_dev || existing.st_ino != prepared.st_ino else { return false }
                return renameatx_np(sourceParent, sourceName, parent, finalName, UInt32(RENAME_SWAP)) == 0
            } ?? false
        } ?? false
    }

    static func removeTree(root: URL, relative: String, maximumDepth: Int = 16, expectedReceipt: ScriptWidgetStoragePublicationReceipt? = nil) -> Bool {
        guard (0...32).contains(maximumDepth) else { return false }
        var remaining = 10_000
        func remove(_ parent: Int32, _ name: String, _ depth: Int) -> Bool {
            guard remaining > 0, depth <= maximumDepth else { return false }
            remaining -= 1
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            if depth == 0, let expectedReceipt {
                guard info.st_mode & S_IFMT == S_IFDIR, expectedReceipt.matches(parent: parent, name: name) else { return false }
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
                      let children = names(child) else { return false }
                for entry in children { if !remove(child, entry, depth + 1) { return false } }
                var final = stat()
                guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
                      final.st_dev == opened.st_dev, final.st_ino == opened.st_ino else { return false }
                return unlinkat(parent, name, AT_REMOVEDIR) == 0
            }
            // Uninstall can remove an unsafe child entry without following it.
            guard depth > 0 || info.st_mode & S_IFMT == S_IFREG else { return false }
            return unlinkat(parent, name, 0) == 0
        }
        return withParent(root: root, relative: relative) { remove($0, $1, 0) } ?? false
    }

    static func removeFile(root: URL, relative: String) -> Bool {
        withParent(root: root, relative: relative) { directory, name in
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
            return unlinkat(directory, name, 0) == 0
        } ?? false
    }

    /// Streaming, bounded copy from a pinned source directory into a new private
    /// execution package. Neither path traversal nor per-file fallback is used.
    static func copyExecutionPackage(root: URL, relative: String, receipt: ScriptWidgetStoragePublicationReceipt,
                                     destination: URL, limits: ScriptWidgetExecutionSnapshotLimits) throws {
        guard limits.isValid else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
        let result: Result<Void, Error>? = withParent(root: root, relative: relative) { parent, name in
            Result {
                let source = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard source >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
                defer { close(source) }
                var info = stat()
                guard fstat(source, &info) == 0, try ScriptWidgetStoragePublicationReceipt.capture(directory: source) == receipt else {
                    throw ScriptWidgetStorageNamespaceError.conflict
                }
                let target = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard target >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
                defer { close(target) }
                var count = 0, total = 0
                func unchanged(_ a: stat, _ b: stat) -> Bool {
                    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
                    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
                    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
                }
                func copy(_ source: Int32, _ target: Int32, depth: Int) throws {
                    guard let children = names(source, maximumCount: limits.maximumEntries + 1) else {
                        throw ScriptWidgetStorageNamespaceError.limitExceeded
                    }
                    var identities = Set<String>()
                    for name in children.sorted() {
                        if depth == 0 && name == "__Build" { continue }
                        guard components(name)?.count == 1, identities.insert(identity(name)).inserted else {
                            throw ScriptWidgetStorageNamespaceError.invalidName
                        }
                        count += 1
                        guard count <= limits.maximumEntries, depth < limits.maximumDepth else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                        var listed = stat()
                        guard fstatat(source, name, &listed, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScriptWidgetStorageNamespaceError.conflict }
                        if listed.st_mode & S_IFMT == S_IFDIR {
                            let input = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            guard input >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            defer { close(input) }
                            var opened = stat()
                            guard fstat(input, &opened) == 0, opened.st_dev == listed.st_dev, opened.st_ino == listed.st_ino,
                                  mkdirat(target, name, 0o700) == 0 else { throw ScriptWidgetStorageNamespaceError.conflict }
                            let output = openat(target, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            guard output >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            defer { close(output) }
                            guard preserveWidgetProtection(output) else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            try copy(input, output, depth: depth + 1)
                        } else {
                            guard listed.st_mode & S_IFMT == S_IFREG, listed.st_nlink == 1, listed.st_size >= 0,
                                  listed.st_size <= limits.maximumFileBytes else { throw ScriptWidgetStorageNamespaceError.limitExceeded }
                            let input = openat(source, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                            guard input >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            defer { close(input) }
                            var opened = stat()
                            guard fstat(input, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1, unchanged(opened, listed) else {
                                throw ScriptWidgetStorageNamespaceError.conflict
                            }
                            let output = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                            guard output >= 0 else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            defer { close(output) }
                            guard preserveWidgetProtection(output) else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            var bytes = [UInt8](repeating: 0, count: 16_384), size = 0
                            while true {
                                let n = Darwin.read(input, &bytes, bytes.count)
                                if n < 0 { if errno == EINTR { continue }; throw ScriptWidgetStorageNamespaceError.unavailable }
                                if n == 0 { break }
                                guard size <= limits.maximumFileBytes - n, total <= limits.maximumTotalBytes - n else {
                                    throw ScriptWidgetStorageNamespaceError.limitExceeded
                                }
                                size += n; total += n
                                let written = bytes.withUnsafeBytes { buffer -> Bool in
                                    var offset = 0
                                    while offset < n {
                                        let m = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), n - offset)
                                        if m < 0 { if errno == EINTR { continue }; return false }
                                        if m == 0 { return false }
                                        offset += m
                                    }
                                    return true
                                }
                                guard written else { throw ScriptWidgetStorageNamespaceError.unavailable }
                            }
                            var final = stat(), current = stat()
                            guard size == opened.st_size, fstat(input, &final) == 0, unchanged(opened, final),
                                  fstatat(source, name, &current, AT_SYMLINK_NOFOLLOW) == 0, unchanged(opened, current) else {
                                throw ScriptWidgetStorageNamespaceError.conflict
                            }
                        }
                    }
                }
                try copy(source, target, depth: 0)
            }
        }
        guard let result else { throw ScriptWidgetStorageNamespaceError.unavailable }
        return try result.get()
    }
}

struct ScriptWidgetExecutionSnapshotLimits {
    var maximumEntries = 500
    var maximumFileBytes = 25 * 1024 * 1024
    var maximumTotalBytes = 64 * 1024 * 1024
    var maximumDepth = 16
    var isValid: Bool {
        (1...500).contains(maximumEntries) && (1...(25 * 1024 * 1024)).contains(maximumFileBytes) &&
        (1...(64 * 1024 * 1024)).contains(maximumTotalBytes) && (1...16).contains(maximumDepth)
    }
}

enum ScriptWidgetPackageName {
    static func isValid(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 && name.utf8.count <= 240 &&
        !name.hasPrefix(".") && ScriptWidgetPackageFiles.identity(name) != "__build" &&
        ScriptWidgetPackageFiles.components(name)?.count == 1
    }
}

/// Keeps private execution resources alive with their rendered package. A
/// process exit releases the kernel lease; a later acquisition removes stale
/// unleased folders. Imported files can never choose these directory names.
final class ScriptWidgetExecutionFiles: Sendable {
    static let maximumActiveSnapshots = 32
    let directory: URL
    private let parent: URL
    private let lease: Int32

    init(temporaryRoot: URL? = nil) throws {
        let temporary = (temporaryRoot ?? FileManager.default.temporaryDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let rootName = "__ScriptWidgetExecutions.v1"
        guard ScriptWidgetPackageFiles.ensureDirectory(root: temporary, relative: rootName) else {
            throw ScriptWidgetStorageNamespaceError.unavailable
        }
        let parent = temporary.appendingPathComponent(rootName)
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: parent, namespace: "execution-folder-allocation", operation: { () -> (URL, Int32)? in
            guard let entries = ScriptWidgetPackageFiles.list(root: parent) else { return nil }
            var retained = 0
            for name in entries where UUID(uuidString: name) != nil {
                let fd = ScriptWidgetPackageFiles.withParent(root: parent, relative: name + "/lease.lock") {
                    openat($0, $1, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                } ?? -1
                if fd >= 0 {
                    var info = stat()
                    if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 {
                        if !ScriptWidgetPackageFiles.removeTree(root: parent, relative: name, maximumDepth: 18) { retained += 1 }
                        _ = flock(fd, LOCK_UN)
                    } else { retained += 1 }
                    close(fd)
                } else {
                    // An allocation interrupted before its lease was created.
                    if !ScriptWidgetPackageFiles.removeTree(root: parent, relative: name, maximumDepth: 18) { retained += 1 }
                }
            }
            guard retained < Self.maximumActiveSnapshots else { return nil }
            let name = UUID().uuidString.lowercased()
            guard ScriptWidgetPackageFiles.ensureDirectory(root: parent, relative: name) else { return nil }
            let directory = parent.appendingPathComponent(name)
            let fd = open(directory.appendingPathComponent("lease.lock").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { _ = ScriptWidgetPackageFiles.removeTree(root: parent, relative: name); return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd); _ = ScriptWidgetPackageFiles.removeTree(root: parent, relative: name); return nil
            }
            return (directory, fd)
        }), let result else { throw ScriptWidgetStorageNamespaceError.unavailable }
        self.parent = parent
        self.directory = result.0
        self.lease = result.1
    }

    deinit {
        _ = ScriptWidgetPackageFiles.removeTree(root: parent, relative: directory.lastPathComponent, maximumDepth: 18)
        _ = flock(lease, LOCK_UN)
        close(lease)
    }
}

struct ScriptWidgetManagedPackageScope: Sendable {
    let context: ScriptWidgetPackageStorageContext
    let role: ScriptWidgetStorageDirectoryRole
    let binding: ScriptWidgetStorageDirectoryBinding?

    init(context: ScriptWidgetPackageStorageContext, role: ScriptWidgetStorageDirectoryRole, binding: ScriptWidgetStorageDirectoryBinding? = nil) {
        self.context = context; self.role = role; self.binding = binding
    }

    func validate(name: String) throws {
        guard let binding, binding.name == name, binding.role == role,
              try context.boundDirectory(name: name, role: role) == binding else {
            throw ScriptWidgetStorageNamespaceError.conflict
        }
    }
}

struct ScriptWidgetPackage: Sendable {
    let path: URL
    let name: String
    var jsxPath: URL {
        if let entry = readManifest()?.entry, let url = resolvedPackageURL(relativePath: entry) {
            return url
        }
        return path.appendingPathComponent("main.jsx")
    }
    let imagePath: URL
    let metaPath: URL
    let manifestPath: URL
    let readonly: Bool
    let accessError: String?
    let executionFiles: ScriptWidgetExecutionFiles?
    let managedScope: ScriptWidgetManagedPackageScope?
    let compiledScope: ScriptWidgetManagedPackageScope?

    init(path: URL, readonly: Bool, accessError: String? = nil, executionFiles: ScriptWidgetExecutionFiles? = nil,
         managedScope: ScriptWidgetManagedPackageScope? = nil, compiledScope: ScriptWidgetManagedPackageScope? = nil) {
        self.accessError = accessError
        self.readonly = readonly
        self.executionFiles = executionFiles
        self.managedScope = managedScope
        self.compiledScope = compiledScope
        self.path = path
        self.imagePath = self.path.appendingPathComponent("image")
        self.metaPath = self.path.appendingPathComponent("meta.json")
        self.manifestPath = self.path.appendingPathComponent("widget.json")
        self.name = self.path.lastPathComponent
    }

    private var canMutate: Bool {
        guard !readonly else { return false }
        guard let managedScope else { return true }
        guard managedScope.role == .source else { return false }
        return (try? managedScope.validate(name: name)) != nil
    }

    private var canRead: Bool {
        accessError == nil && (managedScope == nil || (try? managedScope?.validate(name: name)) != nil)
    }

    static func unavailable() -> ScriptWidgetPackage {
        // A non-materialized, read-only descriptor keeps legacy callers able to
        // display an error without crashing or resolving a user-controlled name.
        ScriptWidgetPackage(path: FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWidgetUnavailable-\(UUID().uuidString)"), readonly: true, accessError: "Invalid or ambiguous package name")
    }

    func readMetadata() -> ScriptMetadata? {
        guard canRead, let data = ScriptWidgetPackageFiles.read(root: path, relative: "meta.json", maximumBytes: ScriptWidgetMetadataFile.maximumBytes) else { return nil }
        return try? JSONDecoder().decode(ScriptMetadata.self, from: data)
    }

    private func withLegacyCache<T>(_ operation: (URL) throws -> T) -> T? {
        guard !readonly, managedScope == nil, ScriptWidgetPackageName.isValid(name),
              let root = ScriptManager.getSandboxBuildDirectoryURL() else { return nil }
        return try? ScriptWidgetStorageProfiles.withLegacyAccess(container: root.deletingLastPathComponent()) { try operation(root) }
    }

    private func legacyCachedFile(_ relative: String, maximumBytes: Int? = nil) -> (Data, URL)? {
        withLegacyCache { root in
            let bytes: Data?
            if let maximumBytes { bytes = ScriptWidgetPackageFiles.read(root: root, relative: name + "/" + relative, maximumBytes: maximumBytes) }
            else { bytes = ScriptWidgetPackageFiles.read(root: root, relative: name + "/" + relative) }
            guard let data = bytes else { throw ScriptWidgetStorageNamespaceError.unavailable }
            return (data, root.appendingPathComponent(name).appendingPathComponent(relative))
        }
    }

    var hasManifest: Bool {
        if accessError != nil || (!readonly && managedScope == nil && ScriptManager.hasUnsafeBuildCacheDirectory) { return true } // Invalid descriptors cannot become legacy packages.
        if ScriptWidgetMetadataFile.isLink(path) ||
            ScriptWidgetPackageFiles.list(root: path)?.contains(where: { $0.lowercased() == "widget.json" }) == true || ScriptWidgetMetadataFile.exists(manifestPath) ||
            ScriptWidgetMetadataFile.exists(path.appendingPathComponent(".widget.json.icloud")) { return true }
        return withLegacyCache { root in
            let cachedPackage = root.appendingPathComponent(name)
            return ScriptWidgetMetadataFile.isLink(cachedPackage) ||
                ScriptWidgetPackageFiles.list(root: root, relative: name)?.contains(where: { $0.lowercased() == "widget.json" }) == true ||
                ScriptWidgetMetadataFile.exists(cachedPackage.appendingPathComponent("widget.json"))
        } ?? false
    }

    func readManifest() -> WidgetPackageManifest? {
        guard canRead,
              ScriptWidgetPackageFiles.list(root: path)?.contains(where: { $0.lowercased() == "widget.json" && $0 != "widget.json" }) != true else { return nil }
        // A present malformed, linked or nonregular manifest is authoritative.
        // Only an absent primary may use the per-package iCloud fallback.
        guard !ScriptWidgetMetadataFile.isLink(path) else { return nil }
        let data: Data
        if ScriptWidgetMetadataFile.exists(manifestPath) {
            guard let primary = ScriptWidgetPackageFiles.read(root: path, relative: "widget.json", maximumBytes: ScriptWidgetMetadataFile.maximumBytes) else { return nil }
            data = primary
        } else if ScriptWidgetMetadataFile.isLink(path.appendingPathComponent(".widget.json.icloud")) {
            return nil
        } else if let fallback = legacyCachedFile("widget.json", maximumBytes: ScriptWidgetMetadataFile.maximumBytes) {
            data = fallback.0
        } else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let allowedKeys: Set<String> = [
            "formatVersion", "id", "name", "version", "runtimeVersion", "minimumRuntimeVersion", "timeline", "entry",
            "supportedFamilies", "permissions", "networkDomains", "plugins", "actions", "controls", "pushUpdates", "description",
            "category", "tags", "icon", "preview", "author", "license"
        ]
        guard Set(object.keys).isSubset(of: allowedKeys) else { return nil }
        if let timeline = object["timeline"] as? [String: Any],
           !Set(timeline.keys).isSubset(of: ["dailyTimes", "timeZone"]) { return nil }
        if let author = object["author"] as? [String: Any],
           !Set(author.keys).isSubset(of: ["name", "url"]) {
            return nil
        }
        if let controls = object["controls"] as? [[String: Any]] {
            let allowedControlKeys: Set<String> = ["id", "type", "title", "subtitle", "systemImage", "action", "actionID", "stateKey"]
            guard controls.allSatisfy({ Set($0.keys).isSubset(of: allowedControlKeys) }) else { return nil }
        }
        if let actions = object["actions"] as? [[String: Any]] {
            let allowedActionKeys: Set<String> = ["id", "title", "description", "systemImage", "function"]
            guard actions.allSatisfy({ Set($0.keys).isSubset(of: allowedActionKeys) }) else { return nil }
        }
        if let pushUpdates = object["pushUpdates"] as? [String: Any],
           !Set(pushUpdates.keys).isSubset(of: ["registrationURL", "channel"]) {
            return nil
        }
        return try? JSONDecoder().decode(WidgetPackageManifest.self, from: data)
    }

    func effectiveManifest() -> WidgetPackageManifest {
        readManifest() ?? .legacy(name: name, metadata: readMetadata())
    }

    @discardableResult
    func writeManifest(_ manifest: WidgetPackageManifest) -> (Bool, String) {
        guard canMutate else { return (false, "Package is readonly") }
        let report = WidgetPackageManifestValidator.validate(manifest, package: self)
        guard report.isValid else {
            return (false, report.errors.map(\.message).joined(separator: "\n"))
        }
        do {
            try makePackageDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(manifest)
            guard ScriptWidgetPackageFiles.write(data, root: path, relative: "widget.json") else { return (false, "Manifest could not be saved") }
            syncBuildCache(fullPath: manifestPath, data: data)
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Migrates a writable legacy package in place. Bundled read-only examples
    /// expose an effective manifest without mutating application resources.
    @discardableResult
    func ensureManifest() -> (Bool, String) {
        if let manifest = readManifest() {
            let report = WidgetPackageManifestValidator.validate(manifest, package: self)
            return report.isValid
                ? (true, "")
                : (false, report.errors.map(\.message).joined(separator: "\n"))
        }
        guard !hasManifest else { return (false, "Invalid or unavailable widget.json") }
        guard !readonly else { return (true, "") }
        guard canMutate else { return (false, "The widget library changed. Reopen it before saving.") }
        return writeManifest(.legacy(name: name, metadata: readMetadata()))
    }

    func previewImageURL() -> URL? {
        let name = readManifest()?.preview ?? readMetadata()?.preview ?? "preview.png"
        guard let url = resolvedPackageURL(relativePath: name) else { return nil }
        return locallyAvailableFileURL(fullPath: url)
    }

    // readwrite
    init(path: URL) {
        self.init(path: path, readonly: false)
    }
    
    // readonly
    init(bundle: String, relativePath: String) {
        let bundleURL = Bundle.main.url(forResource: bundle, withExtension: "bundle")
        let dirPath = bundleURL!.appendingPathComponent(relativePath)
        self.init(path: dirPath, readonly: true)
    }
    
    func fileNameWithoutExtension() -> String {
        return self.name
    }
    
    func updateFiles() {
        updateDirectory(self.path)
    }
    
    func updateImages() {
        updateDirectory(self.imagePath)
    }
    
    func updateDirectory(_ dirPath: URL) {
        for url in downloadableFileURLs(in: dirPath) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Enumerates nested and evicted files without following symlinks.
    func downloadableFileURLs(in directory: URL) -> [URL] {
        let root = path.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate == root || candidate.hasPrefix(root + "/"),
              let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory != true { urls.append(ScriptManager.logicalURL(for: url)) }
        }
        return urls
    }

    func readMainFile() -> (String?, String) {
        let result = readMainFileResult()
        return (result.content, result.message)
    }

    func readMainFileResult() -> ScriptFileReadResult {
        if hasManifest {
            guard let manifest = readManifest(),
                  WidgetPackageManifestValidator.validate(manifest, package: self, checkEntryExists: false).isValid else {
                return ScriptFileReadResult(content: nil, source: nil, icloud: .error("Invalid or unavailable widget.json"),
                                            message: "Invalid or unavailable widget.json")
            }
        }
        return readFileResult(fullPath: jsxPath)
    }

    func readFile(relativePath: String) -> (String?, String) {
        guard let filePath = resolvedPackageURL(relativePath: relativePath) else {
            return (nil, "Invalid package-relative path")
        }
        return readFile(fullPath: filePath)
    }

    /// Resolves an untrusted script path while keeping it inside this package.
    /// Standardising both URLs also rejects `..`, absolute paths and symlink escapes.
    func resolvedPackageURL(relativePath: String) -> URL? {
        guard canRead else { return nil }
        return ScriptWidgetPackageFiles.safeURL(root: path, relative: relativePath)
    }

    private func relativePath(for fullPath: URL) -> String? {
        guard accessError == nil, !fullPath.pathComponents.contains(".."), !fullPath.pathComponents.contains(".") else { return nil }
        let root = path.standardizedFileURL.path
        let target = fullPath.standardizedFileURL.path
        var relative: String?
        if target.hasPrefix(root + "/") {
            relative = String(target.dropFirst(root.count + 1))
        } else if !ScriptWidgetMetadataFile.exists(path) {
            let canonicalRoot = Self.canonicalPath(path)
            let canonicalTarget = Self.canonicalPath(fullPath)
            if canonicalTarget.hasPrefix(canonicalRoot + "/") { relative = String(canonicalTarget.dropFirst(canonicalRoot.count + 1)) }
        } else {
            var rootInfo = stat()
            let rootFD = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { return nil }
            defer { close(rootFD) }
            guard fstat(rootFD, &rootInfo) == 0 else { return nil }
            var ancestor = fullPath.deletingLastPathComponent()
            var parts = [fullPath.lastPathComponent]
            for _ in 0..<16 {
                let fd = open(ancestor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    var info = stat()
                    let matches = fstat(fd, &info) == 0 && info.st_dev == rootInfo.st_dev && info.st_ino == rootInfo.st_ino
                    close(fd)
                    if matches { relative = parts.joined(separator: "/"); break }
                }
                parts.insert(ancestor.lastPathComponent, at: 0)
                ancestor.deleteLastPathComponent()
            }
        }
        guard let relative, ScriptWidgetPackageFiles.safeURL(root: path, relative: relative) != nil else { return nil }
        return relative
    }

    /// Legacy tuple API kept for existing callers. The second element preserves
    /// the historical status strings ("succeed" / "read from build cache: …" /
    /// error text) so behavior and tests are unchanged.
    func readFile(fullPath: URL) -> (String?, String) {
        let result = readFileResult(fullPath: fullPath)
        return (result.content, result.message)
    }

    /// Read a file, reporting where the content came from and — when it can't be
    /// read — whether iCloud is still downloading it (vs a genuine miss). Reading
    /// the primary copy succeeds first and refreshes the local build cache; if the
    /// primary is unavailable (e.g. iCloud-evicted) the build cache is the
    /// fallback. Requesting the iCloud download is deferred until the primary read
    /// fails, so a normal read stays cheap.
    func readFileResult(fullPath: URL) -> ScriptFileReadResult {
        guard canRead else {
            return ScriptFileReadResult(content: nil, source: nil, icloud: .error("The widget installation changed"), message: "The widget installation changed. Reopen it before editing.")
        }
        guard let relative = relativePath(for: fullPath) else {
            return ScriptFileReadResult(content: nil, source: nil, icloud: .error("Invalid package-relative path"), message: "Invalid package-relative path")
        }
        // 1) Primary path — when present this is authoritative and (re)caches.
        if let data = ScriptWidgetPackageFiles.read(root: path, relative: relative), let content = String(data: data, encoding: .utf8) {
            syncBuildCache(fullPath: fullPath, content: content)
            let state: ICloudItemState = isUbiquitous(fullPath) ? .downloaded : .local
            return ScriptFileReadResult(content: content, source: .file, icloud: state, message: "succeed")
        }

        if ScriptWidgetMetadataFile.exists(fullPath) {
            return ScriptFileReadResult(content: nil, source: nil, icloud: .error("Package file is not readable"), message: "Package file is not readable")
        }
        // 2) Primary unavailable — ask iCloud to bring it back and check status.
        let icloud = requestICloudDownloadState(for: fullPath)

        // 3) Local build-cache fallback so widgets keep rendering offline.
        if let cached = legacyCachedFile(relative), let content = String(data: cached.0, encoding: .utf8) {
            return ScriptFileReadResult(content: content,
                                        source: .buildCache,
                                        icloud: icloud,
                                        message: "read from build cache: \(cached.1.path)")
        }

        // 4) Nothing to serve — describe why for the UI.
        let message: String
        switch icloud {
        case .downloading: message = "Downloading from iCloud"
        case .error(let e): message = e
        case .notInICloud, .local, .downloaded: message = "File not found: \(fullPath.path)"
        }
        return ScriptFileReadResult(content: nil, source: nil, icloud: icloud, message: message)
    }

    /// Whether the item at `url` is managed by iCloud (downloaded or evicted).
    func isUbiquitous(_ url: URL) -> Bool {
        return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    /// iCloud state of a file that is *not* currently present locally, kicking off
    /// a download so a later read (or the next precache pass) can serve it.
    private func requestICloudDownloadState(for fullPath: URL) -> ICloudItemState {
        try? FileManager.default.startDownloadingUbiquitousItem(at: fullPath)

        if let values = try? fullPath.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey,
        ]) {
            let placeholder = fullPath.deletingLastPathComponent()
                .appendingPathComponent("." + fullPath.lastPathComponent + ".icloud")
            return ICloudItemStateResolver.resolve(
                downloadError: values.ubiquitousItemDownloadingError,
                isDownloading: values.ubiquitousItemIsDownloading,
                downloadingStatus: values.ubiquitousItemDownloadingStatus,
                hasPlaceholder: FileManager.default.fileExists(atPath: placeholder.path)
            )
        }

        // No ubiquitous metadata: it's a real miss unless an evicted-item
        // placeholder (".name.icloud") is sitting next to it.
        let placeholder = fullPath.deletingLastPathComponent()
            .appendingPathComponent("." + fullPath.lastPathComponent + ".icloud")
        return ICloudItemStateResolver.resolve(
            downloadError: nil,
            isDownloading: nil,
            downloadingStatus: nil,
            hasPlaceholder: FileManager.default.fileExists(atPath: placeholder.path)
        )
    }

    /// Current iCloud state of the package's main script file, for status UI.
    /// Does not block; reports `.downloading` once a fetch has been requested.
    func mainFileICloudState() -> ICloudItemState {
        if FileManager.default.fileExists(atPath: self.jsxPath.path) {
            return isUbiquitous(self.jsxPath) ? .downloaded : .local
        }
        return requestICloudDownloadState(for: self.jsxPath)
    }

    /// The path of `url` with symlinks resolved through its deepest existing
    /// ancestor. `resolvingSymlinksInPath()` leaves a missing file's path
    /// unresolved, so on devices an iCloud-evicted file under `/private/var/...`
    /// would no longer share a prefix with its package root, which resolves to
    /// `/var/...`, and the build-cache fallback would find nothing (issue #6).
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved.path
    }

    private func buildCachePath(for fullPath: URL) -> URL? {
        guard canMutate, managedScope == nil, ScriptWidgetPackageName.isValid(name),
              let relative = relativePath(for: fullPath),
              let root = ScriptManager.getSandboxBuildDirectoryURL() else { return nil }
        return try? ScriptWidgetStorageProfiles.withLegacyAccess(container: root.deletingLastPathComponent()) {
            ScriptWidgetPackageFiles.safeURL(root: root, relative: name + "/" + relative)
        }
    }

    private func syncBuildCache(fullPath: URL, content: String) {
        guard let data = content.data(using: .utf8) else { return }
        syncBuildCache(fullPath: fullPath, data: data)
    }

    private func syncBuildCache(fullPath: URL, data: Data) {
        guard let cacheFilePath = buildCachePath(for: fullPath) else {
            return
        }
        // Reading a build package must not rewrite the file being rendered.
        guard cacheFilePath.standardizedFileURL.resolvingSymlinksInPath() != fullPath.standardizedFileURL.resolvingSymlinksInPath() else { return }
        guard let buildRoot = ScriptManager.getSandboxBuildDirectoryURL() else { return }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: buildRoot.appendingPathComponent(name), options: .forMerging,
                                       error: &coordinationError) { _ in
            _ = withLegacyCache { root in
                guard let relative = relativePath(for: fullPath) else { return false }
                return ScriptWidgetPackageFiles.write(data, root: root, relative: name + "/" + relative)
            }
        }
    }

    /// Copies a package resource into the app-group cache used by widgets when
    /// iCloud has evicted the primary file. The caller is responsible for
    /// bounding which resource types and sizes are admitted.
    @discardableResult
    func cacheResource(fullPath: URL) -> Bool {
        guard canMutate, let relative = relativePath(for: fullPath),
              let data = ScriptWidgetPackageFiles.read(root: path, relative: relative) else { return false }
        syncBuildCache(fullPath: fullPath, data: data)
        return buildCachePath(for: fullPath).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }

    /// Returns the authoritative package file when present, otherwise its last
    /// locally cached copy. This keeps package images and animations available
    /// to WidgetKit while iCloud Drive is unavailable on cellular data.
    func locallyAvailableFileURL(fullPath: URL) -> URL? {
        guard relativePath(for: fullPath) != nil else { return nil }
        if ScriptWidgetMetadataFile.exists(fullPath) {
            return (try? fullPath.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? fullPath : nil
        }
        guard let cached = buildCachePath(for: fullPath),
              (try? cached.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return cached
    }

    func makePackageDirectory() throws {
        try managedScope?.context.validateLibraryRoot()
        guard canMutate, accessError == nil,
              ScriptWidgetPackageFiles.ensureDirectory(root: path.deletingLastPathComponent().resolvingSymlinksInPath(), relative: path.lastPathComponent) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func writeFile(fullPath: URL, content: String) -> (Bool, String) {
        guard canMutate, let relative = relativePath(for: fullPath) else { return (false, "Invalid or readonly package path") }
        do { try makePackageDirectory() } catch { return (false, "Package directory could not be opened") }
        let data = Data(content.utf8)
        guard ScriptWidgetPackageFiles.write(data, root: path, relative: relative) else { return (false, "Package file could not be saved") }
        syncBuildCache(fullPath: fullPath, data: data)
        return (true, "")
    }

    func writeMainFile(content: String) -> (Bool,String) {
        let result = self.writeFile(fullPath: self.jsxPath, content: content)
        guard result.0 else { return result }
        ScriptWidgetPrecompileCoordinator.schedule(package: self, source: content)
        return result
    }
    
    func writeFile(relativePath: String, content: String) -> (Bool,String) {
        guard let fullPath = resolvedPackageURL(relativePath: relativePath) else {
            return (false, "Invalid package-relative path")
        }
        return self.writeFile(fullPath: fullPath, content: content)
    }

    /// Imports a user-selected project file into the package root. Names are
    /// de-duplicated instead of overwriting existing work, and the destination
    /// is resolved through the same package-boundary guard as script writes.
    func importProjectFile(from sourceURL: URL, maximumBytes: Int = 25 * 1024 * 1024) -> (Bool, String) {
        guard canMutate else { return (false, "Package is readonly") }
        guard let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= maximumBytes else {
            return (false, "The selected file exceeds the 25 MiB project limit")
        }
        guard let data = try? Data(contentsOf: sourceURL) else {
            return (false, "The selected file could not be read")
        }

        let originalName = sourceURL.lastPathComponent
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        let isImageResource = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(pathExtension.lowercased())
        let relativeDirectory = isImageResource ? "image" : ""
        var candidateName = originalName
        var suffix = 2
        func relativePath(for name: String) -> String {
            relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
        }
        while isFileExist(relativePath: relativePath(for: candidateName)) {
            candidateName = pathExtension.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(pathExtension)"
            suffix += 1
        }
        let importedRelativePath = relativePath(for: candidateName)
        guard let destination = resolvedPackageURL(relativePath: importedRelativePath) else {
            return (false, "Invalid project filename")
        }
        do {
            try makePackageDirectory()
            guard ScriptWidgetPackageFiles.write(data, root: path, relative: importedRelativePath) else { return (false, "The selected file could not be saved") }
            if ["jsx", "js", "json", "txt", "csv", "svg", "md"].contains(pathExtension.lowercased()) {
                syncBuildCache(fullPath: destination, data: data)
            }
            return (true, importedRelativePath)
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    func renameFile(relativePath: String, destRelativePath: String) -> (Bool, String) {
        guard canMutate, accessError == nil,
              resolvedPackageURL(relativePath: relativePath) != nil,
              resolvedPackageURL(relativePath: destRelativePath) != nil,
              ScriptWidgetPackageFiles.move(root: path, source: relativePath, destination: destRelativePath) else { return (false, "File could not be renamed") }
        if let cache = ScriptManager.getSandboxBuildDirectoryURL() {
            _ = ScriptWidgetPackageFiles.removeFile(root: cache, relative: name + "/" + relativePath)
        }
        return (true, "")
    }

    func isFileExist(relativePath: String) -> Bool {
        guard let fullPath = resolvedPackageURL(relativePath: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: fullPath.path)
    }
    
    func deleteFile(relativePath: String) {
        guard canMutate, let fullPath = resolvedPackageURL(relativePath: relativePath),
              ScriptWidgetPackageFiles.removeFile(root: path, relative: relativePath) else { return }
        if buildCachePath(for: fullPath) != nil {
            if let root = ScriptManager.getSandboxBuildDirectoryURL(), let relative = self.relativePath(for: fullPath) {
                _ = ScriptWidgetPackageFiles.removeFile(root: root, relative: name + "/" + relative)
            }
        }
    }
    
    func rename(destPath: URL) -> (Bool, String) {
        guard canMutate, accessError == nil, ScriptWidgetPackageName.isValid(destPath.lastPathComponent),
              path.deletingLastPathComponent().standardizedFileURL == destPath.deletingLastPathComponent().standardizedFileURL,
              ScriptWidgetPackageFiles.safeURL(root: path.deletingLastPathComponent(), relative: path.lastPathComponent, allowMissing: false) != nil,
              ScriptWidgetPackageFiles.move(root: path.deletingLastPathComponent(), source: path.lastPathComponent, destination: destPath.lastPathComponent) else { return (false, "Package could not be renamed") }
        return (true, "")
    }

    func delete() -> Bool {
        guard canMutate, accessError == nil,
              ScriptWidgetPackageFiles.safeURL(root: path.deletingLastPathComponent(), relative: path.lastPathComponent, allowMissing: false) != nil else { return false }
        return ScriptWidgetPackageFiles.removeTree(root: path.deletingLastPathComponent().resolvingSymlinksInPath(), relative: path.lastPathComponent)
    }

    func getImage(_ imageName: String) -> ImageModel? {
        guard canRead else { return nil }
        let trimmedName = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ScriptWidgetPackageFiles.components(trimmedName)?.count == 1 else { return nil }
        let requested = imagePath.appendingPathComponent(trimmedName)
        let candidates: [URL]
        if requested.pathExtension.isEmpty {
            candidates = ["png", "jpg", "jpeg", "webp", "heic"].map {
                requested.appendingPathExtension($0)
            }
        } else {
            candidates = [requested]
        }
        guard let availablePath = candidates.lazy.compactMap({ locallyAvailableFileURL(fullPath: $0) }).first else {
            return nil
        }
        return ImageModel(name: availablePath.deletingPathExtension().lastPathComponent, path: availablePath)
    }
    
    
    func getGifFile(_ fileName: String) -> URL? {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ScriptWidgetPackageFiles.components(trimmedName)?.count == 1,
              resolvedPackageURL(relativePath: "image/" + trimmedName) != nil else { return nil }

        // 1) Accept direct file name (with extension), e.g. "cat.gif" / "cat.GIF".
        let directPath = self.imagePath.appendingPathComponent(trimmedName)
        if directPath.pathExtension.lowercased() == "gif",
           let availablePath = locallyAvailableFileURL(fullPath: directPath) {
            return availablePath
        }

        // 2) Accept bare name, e.g. "cat" -> "cat.gif".
        if directPath.pathExtension.isEmpty {
            let appendedGifPath = directPath.appendingPathExtension("gif")
            if let availablePath = locallyAvailableFileURL(fullPath: appendedGifPath) {
                return availablePath
            }
        }

        // 3) Fallback: scan directory and match case-insensitively.
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: self.imagePath.path) else {
            return nil
        }

        let targetNameNoExt = URL(fileURLWithPath: trimmedName).deletingPathExtension().lastPathComponent.lowercased()
        for item in items {
            let itemURL = self.imagePath.appendingPathComponent(item)
            if itemURL.pathExtension.lowercased() != "gif" {
                continue
            }

            let itemFullName = itemURL.lastPathComponent.lowercased()
            let itemNameNoExt = itemURL.deletingPathExtension().lastPathComponent.lowercased()
            if itemFullName == trimmedName.lowercased() || itemNameNoExt == targetNameNoExt {
                return locallyAvailableFileURL(fullPath: itemURL)
            }
        }

        return nil
    }

    func getImageList() -> [ImageModel] {
        guard canRead else { return [] }
        guard let items = ScriptWidgetPackageFiles.list(root: path, relative: "image") else { return [] }
        return items.compactMap { item in
            let imageURL = imagePath.appendingPathComponent(item)
            guard locallyAvailableFileURL(fullPath: imageURL) != nil else { return nil }
            return ImageModel(name: imageURL.deletingPathExtension().lastPathComponent, path: imageURL)
        }.sorted { $0.name.compare($1.name) == .orderedAscending }
    }

    /// Names only for Studio. No image decoding, library queries or remote downloads.
    func editorImageResources() -> [String] {
        guard canRead, accessError == nil,
              let names = ScriptWidgetPackageFiles.list(root: path, relative: "image", maximumCount: 4096) else { return [] }
        var resources: [String] = []
        for name in names.sorted() {
            let relative = "image/" + name
            guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.contains(".."),
                  relative.utf8.count <= 1024, ScriptWidgetPackageFiles.components(relative)?.count == 2,
                  ["png", "jpg", "jpeg", "webp"].contains((name as NSString).pathExtension.lowercased()),
                  let safe = ScriptWidgetPackageFiles.safeURL(root: path, relative: relative, allowMissing: false),
                  ScriptWidgetPackageFiles.kind(root: path, relative: relative) == S_IFREG,
                  locallyAvailableFileURL(fullPath: safe) != nil else { continue }
            resources.append(relative)
            if resources.count == 256 { break }
        }
        return resources
    }
    
#if os(macOS)
    func saveImage(imagePath source: URL) -> Bool {
        guard canMutate, source.pathExtension.lowercased() == "png",
              let data = try? Data(contentsOf: source), data.count <= 25 * 1_024 * 1_024 else { return false }
        var filename = source.lastPathComponent
        var index = 1
        while isFileExist(relativePath: "image/" + filename) { filename = "image\(index).png"; index += 1 }
        return saveImageData(data, name: filename)
    }

    func saveImage(image: NSImage, imageName: String) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
        return saveImageData(data, name: imageName + ".png")
    }
#else
    func saveImage(image: UIImage, imageName: String) -> Bool {
        guard let data = image.pngData() else { return false }
        return saveImageData(data, name: imageName + ".png")
    }
#endif

    /// Native photo configuration publishes immutable, normalized PNG assets.
    /// No original EXIF, GPS, filename or album identifier is retained.
    func savePhotoImage(_ image: CGImage) -> String? {
        guard canMutate, image.width > 0, image.height > 0, image.width <= 768, image.height <= 768,
              getImageList().filter({ $0.name.hasPrefix("photo-") }).count < 12 else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), bytes.length <= 3 * 1_024 * 1_024 else { return nil }
        let name = "photo-" + UUID().uuidString.lowercased()
        return saveImageData(bytes as Data, name: name + ".png") ? name : nil
    }

    static func isWallpaperImageName(_ name:String)->Bool {
        name.range(of:"^background-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",options:.regularExpression) != nil
    }
    /// Saves only the normalized crop, never the user's whole source screenshot or metadata.
    func saveWallpaperImage(_ image:CGImage)->String? {
        guard canMutate,image.width>0,image.height>0,image.width<=1024,image.height<=1024,
              getImageList().filter({Self.isWallpaperImageName($0.name) && $0.path.pathExtension=="png"}).count<12 else { return nil }
        let data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination),data.length<=5*1_024*1_024 else { return nil }
        let name="background-"+UUID().uuidString.lowercased()
        return saveImageData(data as Data,name:name+".png") ? name : nil
    }

    private func saveImageData(_ data: Data, name: String) -> Bool {
        guard canMutate, ScriptWidgetPackageFiles.components(name)?.count == 1 else { return false }
        do { try makePackageDirectory() } catch { return false }
        guard ScriptWidgetPackageFiles.write(data, root: path, relative: "image/" + name) else { return false }
        syncBuildCache(fullPath: imagePath.appendingPathComponent(name), data: data)
        return true
    }

    func renameImage(name: String, newName: String) -> (Bool, String) {
        guard ScriptWidgetPackageFiles.components(name)?.count == 1, ScriptWidgetPackageFiles.components(newName)?.count == 1 else { return (false, "Invalid image name") }
        return renameFile(relativePath: "image/\(name).png", destRelativePath: "image/\(newName).png")
    }

    func deleteImage(name: String) -> (Bool, String) {
        guard canMutate, ScriptWidgetPackageFiles.components(name)?.count == 1,
              ScriptWidgetPackageFiles.removeFile(root: path, relative: "image/\(name).png") else { return (false, "Image could not be removed") }
        if let cached = buildCachePath(for: imagePath.appendingPathComponent(name + ".png")) {
            _ = ScriptWidgetPackageFiles.removeFile(root: cached.deletingLastPathComponent(), relative: cached.lastPathComponent)
        }
        return (true, "")
    }

    func listFiles() -> [FileModel] {
        return self.listFilesInternal()
    }
    
    private func listFilesInternal(_ leadingPath: String = "") -> [FileModel] {
        var curDir = self.path
        if !leadingPath.isEmpty {
            curDir = self.path.appendingPathComponent(leadingPath)
        }
        
        guard accessError == nil, let files = ScriptWidgetPackageFiles.list(root: path, relative: leadingPath.isEmpty ? nil : leadingPath) else { return [] }
        
        var items = [FileModel]()
        
        for file in files {
            let fullPath = curDir.appendingPathComponent(file)
            
            let relative = leadingPath.isEmpty ? file : leadingPath + "/" + file
            guard let kind = ScriptWidgetPackageFiles.kind(root: path, relative: relative) else { continue }
            if kind == S_IFDIR {
                var nextLeadingPath = ""
                if leadingPath.isEmpty {
                    nextLeadingPath = file
                } else {
                    nextLeadingPath = leadingPath + "/" + file
                }
                let innerFiles = self.listFilesInternal(nextLeadingPath)
                items.append(contentsOf: innerFiles)
            } else {
                if leadingPath.isEmpty {
                    items.append(FileModel(name: file, relativePath: file, path: fullPath))
                } else {
                    items.append(FileModel(name: file, relativePath: leadingPath + "/" + file, path: fullPath))
                }
            }
        }
        
        return items
    }
    
    func listRootFiles() -> [FileModel] {
        guard accessError == nil, let names = ScriptWidgetPackageFiles.list(root: path) else { return [] }
        return names.compactMap { name in
            guard ScriptWidgetPackageFiles.kind(root: path, relative: name) == S_IFREG else { return nil }
            return FileModel(name: name, relativePath: name, path: path.appendingPathComponent(name))
        }
    }
}


// Widget and Live Activity hosts replace this descriptor with the selected
// execution package before evaluating JavaScript. Extensions do not embed the
// app's template bundle, so their initial state must not depend on that resource.
let globalScriptWidgetPackage = ScriptWidgetPackage.unavailable()
