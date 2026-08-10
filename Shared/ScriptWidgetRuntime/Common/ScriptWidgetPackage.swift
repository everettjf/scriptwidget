//
//  ScriptWidgetPackage.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/10.
//

import Foundation
import CryptoKit
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
    static let editorInsert = "editor.insert"
    static let editorFormat = "editor.format"
    static let editorGetState = "editor.getState"

    static func envelope(type: String, documentID: String?, payload: [String: Any]) -> [String: Any] {
        [
            "protocolVersion": version,
            "type": type,
            "documentID": documentID as Any? ?? NSNull(),
            "payload": payload,
        ]
    }
}

struct StudioDocumentSnapshot: Equatable {
    let content: String
    let version: Int
    let selection: Range<Int>

    init?(state: Any?) {
        guard
            let state = state as? [String: Any],
            let content = state["content"] as? String
        else { return nil }
        let version = state["version"] as? Int ?? 0
        let selection = state["selection"] as? [String: Any]
        let from = selection?["from"] as? Int ?? 0
        let to = selection?["to"] as? Int ?? from
        self.init(content: content, version: version, selection: min(from, to)..<max(from, to))
    }

    init(content: String, version: Int, selection: Range<Int>) {
        self.content = content
        self.version = version
        self.selection = selection
    }
}

/// Owns document identity and the persisted-draft baseline for native Studio
/// hosts. Web views remain responsible only for transport and presentation.
final class StudioDocumentSession {
    private(set) var documentID: String?
    private(set) var savedContent = ""
    private let drafts: StudioDraftStore

    init(drafts: StudioDraftStore = .shared) {
        self.drafts = drafts
    }

    func open(documentID: String, content: String) -> String {
        self.documentID = documentID
        savedContent = content
        return drafts.recover(documentID: documentID, currentContent: content)?.content ?? content
    }

    func recordDraft(_ content: String) {
        guard let documentID else { return }
        drafts.save(documentID: documentID, baseContent: savedContent, content: content)
    }

    func markSaved(_ content: String) {
        savedContent = content
        if let documentID { drafts.remove(documentID: documentID) }
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
    static let compilerFingerprint = "scriptwidget-babel-v2"
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
        guard let directory = artifactDirectory(package: package),
              let manifestData = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(ScriptWidgetBuildManifest.self, from: manifestData),
              manifest.formatVersion == ScriptWidgetBuildManifest.formatVersion,
              manifest.runtimeAPIVersion == ScriptWidgetBuildContract.runtimeAPIVersion,
              manifest.compilerFingerprint == ScriptWidgetBuildContract.compilerFingerprint,
              let javaScript = try? String(contentsOf: directory.appendingPathComponent(javaScriptName), encoding: .utf8),
              manifest.compiledBytes == javaScript.utf8.count,
              manifest.compiledHash == compiledHash(javaScript) else {
            return nil
        }
        return ScriptWidgetCompiledArtifact(javaScript: javaScript, manifest: manifest)
    }

    @discardableResult
    static func save(package: ScriptWidgetPackage, source: String, javaScript: String) -> Bool {
        guard let directory = artifactDirectory(package: package) else { return false }
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.none
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try Data(javaScript.utf8).write(to: directory.appendingPathComponent(javaScriptName), options: .atomic)
            try encoder.encode(manifest).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
            return true
        } catch {
            print("compiled artifact write failed: \(error.localizedDescription)")
            return false
        }
    }

    static func remove(package: ScriptWidgetPackage) {
        guard let directory = artifactDirectory(package: package) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func artifactDirectory(package: ScriptWidgetPackage) -> URL? {
        ScriptManager.getSandboxBuildDirectoryURL()?
            .appendingPathComponent(package.name, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ScriptWidgetPackage {
    let path: URL
    let name: String
    let jsxPath: URL
    let imagePath: URL
    let metaPath: URL
    let manifestPath: URL
    let readonly: Bool

    init(path: URL, readonly: Bool) {
        self.readonly = readonly
        self.path = path
        self.jsxPath = self.path.appendingPathComponent("main.jsx")
        self.imagePath = self.path.appendingPathComponent("image")
        self.metaPath = self.path.appendingPathComponent("meta.json")
        self.manifestPath = self.path.appendingPathComponent("widget.json")
        self.name = self.path.lastPathComponent
    }

    func readMetadata() -> ScriptMetadata? {
        guard FileManager.default.fileExists(atPath: metaPath.path) else { return nil }
        guard let data = try? Data(contentsOf: metaPath) else { return nil }
        return try? JSONDecoder().decode(ScriptMetadata.self, from: data)
    }

    func readManifest() -> WidgetPackageManifest? {
        guard let data = try? Data(contentsOf: manifestPath) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let allowedKeys: Set<String> = [
            "formatVersion", "id", "name", "version", "runtimeVersion", "entry",
            "supportedFamilies", "permissions", "networkDomains", "plugins", "controls", "pushUpdates", "description",
            "category", "tags", "icon", "preview", "author", "license"
        ]
        guard Set(object.keys).isSubset(of: allowedKeys) else { return nil }
        if let author = object["author"] as? [String: Any],
           !Set(author.keys).isSubset(of: ["name", "url"]) {
            return nil
        }
        if let controls = object["controls"] as? [[String: Any]] {
            let allowedControlKeys: Set<String> = ["id", "type", "title", "subtitle", "systemImage", "action", "stateKey"]
            guard controls.allSatisfy({ Set($0.keys).isSubset(of: allowedControlKeys) }) else { return nil }
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
        guard !readonly else { return (false, "Package is readonly") }
        let report = WidgetPackageManifestValidator.validate(manifest, package: self)
        guard report.isValid else {
            return (false, report.errors.map(\.message).joined(separator: "\n"))
        }
        do {
            try makePackageDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: manifestPath, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: manifestPath.path
            )
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
        guard !readonly else { return (true, "") }
        return writeManifest(.legacy(name: name, metadata: readMetadata()))
    }

    func previewImageURL() -> URL? {
        let name = readManifest()?.preview ?? readMetadata()?.preview ?? "preview.png"
        let url = self.path.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: dirPath.path)
            for item in items {
                let path = self.path.appendingPathComponent(item)
                
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) {
                    continue
                }
                
                if isDir.boolValue {
                    updateDirectory(path)
                } else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: path)
                }
            }
        } catch {
            print("error : \(error)")
        }
    }
    
    func readMainFile() -> (String?, String) {
        return readFile(fullPath: self.jsxPath)
    }

    func readMainFileResult() -> ScriptFileReadResult {
        return readFileResult(fullPath: self.jsxPath)
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
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let root = path.standardizedFileURL.resolvingSymlinksInPath()
        let standardized = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard standardized.path.hasPrefix(rootPrefix) else { return nil }
        let candidate: URL
        if FileManager.default.fileExists(atPath: standardized.path) {
            candidate = standardized.resolvingSymlinksInPath()
        } else {
            candidate = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(standardized.lastPathComponent)
        }
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
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
        // 1) Primary path — when present this is authoritative and (re)caches.
        if let content = try? String(contentsOf: fullPath, encoding: .utf8) {
            syncBuildCache(fullPath: fullPath, content: content)
            let state: ICloudItemState = isUbiquitous(fullPath) ? .downloaded : .local
            return ScriptFileReadResult(content: content, source: .file, icloud: state, message: "succeed")
        }

        // 2) Primary unavailable — ask iCloud to bring it back and check status.
        let icloud = requestICloudDownloadState(for: fullPath)

        // 3) Local build-cache fallback so widgets keep rendering offline.
        if let buildCachePath = buildCachePath(for: fullPath),
           let content = try? String(contentsOf: buildCachePath, encoding: .utf8) {
            return ScriptFileReadResult(content: content,
                                        source: .buildCache,
                                        icloud: icloud,
                                        message: "read from build cache: \(buildCachePath.path)")
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

    private func buildCachePath(for fullPath: URL) -> URL? {
        guard let buildDirectory = ScriptManager.getSandboxBuildDirectoryURL() else {
            return nil
        }
        let packageRootPath = self.path.standardizedFileURL.resolvingSymlinksInPath().path
        let fullPathValue = fullPath.standardizedFileURL.resolvingSymlinksInPath().path
        let packageRootPrefix = packageRootPath.hasSuffix("/") ? packageRootPath : packageRootPath + "/"
        guard fullPathValue == packageRootPath || fullPathValue.hasPrefix(packageRootPrefix) else {
            return nil
        }
        var relativePath = String(fullPathValue.dropFirst(packageRootPath.count))
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        var cacheFilePath = buildDirectory.appendingPathComponent(self.name)
        if !relativePath.isEmpty {
            cacheFilePath = cacheFilePath.appendingPathComponent(relativePath)
        }
        return cacheFilePath
    }

    private func syncBuildCache(fullPath: URL, content: String) {
        guard let data = content.data(using: .utf8) else { return }
        syncBuildCache(fullPath: fullPath, data: data)
    }

    private func syncBuildCache(fullPath: URL, data: Data) {
        guard let cacheFilePath = buildCachePath(for: fullPath) else {
            return
        }
        let directory = cacheFilePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                FileAttributeKey.protectionKey: FileProtectionType.none
            ])
            try data.write(to: cacheFilePath, options: .atomic)
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: cacheFilePath.path)
        } catch {
            print("sync build cache failed: \(error)")
        }
    }

    /// Copies a package resource into the app-group cache used by widgets when
    /// iCloud has evicted the primary file. The caller is responsible for
    /// bounding which resource types and sizes are admitted.
    @discardableResult
    func cacheResource(fullPath: URL) -> Bool {
        guard let data = try? Data(contentsOf: fullPath) else { return false }
        syncBuildCache(fullPath: fullPath, data: data)
        return buildCachePath(for: fullPath).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }

    /// Returns the authoritative package file when present, otherwise its last
    /// locally cached copy. This keeps package images and animations available
    /// to WidgetKit while iCloud Drive is unavailable on cellular data.
    func locallyAvailableFileURL(fullPath: URL) -> URL? {
        if FileManager.default.fileExists(atPath: fullPath.path) {
            return fullPath
        }
        guard let cached = buildCachePath(for: fullPath),
              FileManager.default.fileExists(atPath: cached.path) else { return nil }
        return cached
    }
    
    func makePackageDirectory() throws {
        try FileManager.default.createDirectory(at: self.path, withIntermediateDirectories: true, attributes: [
            FileAttributeKey.protectionKey : FileProtectionType.none
        ])
    }
    
    func writeFile(fullPath: URL , content: String) -> (Bool, String) {
        if self.readonly { return (false, "Package is readonly") }
        
        guard let data = content.data(using: .utf8) else { return (false, "Failed to convert code to utf8 encoding") }
        do {
            if !FileManager.default.fileExists(atPath: fullPath.path) {
                try self.makePackageDirectory()
            }
            
            try data.write(to: fullPath, options: .atomic)
            
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: fullPath.path)
            syncBuildCache(fullPath: fullPath, content: content)
            
        } catch {
            return (false, "Failed write code to path :\(fullPath) error: \(error)")
        }
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
        guard !readonly else { return (false, "Package is readonly") }
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
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.none]
            )
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: destination.path
            )
            if ["jsx", "js", "json", "txt", "csv", "svg", "md"].contains(pathExtension.lowercased()) {
                syncBuildCache(fullPath: destination, data: data)
            }
            return (true, importedRelativePath)
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    func renameFile(relativePath: String, destRelativePath: String) -> (Bool, String) {
        guard let destFullPath = resolvedPackageURL(relativePath: destRelativePath),
              let fullPath = resolvedPackageURL(relativePath: relativePath) else {
            return (false, "Invalid package-relative path")
        }
        if FileManager.default.fileExists(atPath: destFullPath.path) {
            return (false, "new name existed")
        }
        do {
            try FileManager.default.moveItem(at: fullPath, to: destFullPath)
        } catch {
            return (false, "\(error)")
        }
        return (true, "")
    }
    
    func isFileExist(relativePath: String) -> Bool {
        guard let fullPath = resolvedPackageURL(relativePath: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: fullPath.path)
    }
    
    func deleteFile(relativePath: String) {
        guard let fullPath = resolvedPackageURL(relativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: fullPath)
        if let cached = buildCachePath(for: fullPath) {
            try? FileManager.default.removeItem(at: cached)
        }
    }
    
    func rename(destPath: URL) -> (Bool, String) {
        if self.readonly { return (false, "Bundle file not movable")}
        
        if FileManager.default.fileExists(atPath: destPath.path) {
            return (false, "New package name already exists")
        }
        
        do {
            try FileManager.default.moveItem(at: self.path, to: destPath)
        } catch {
            return (false, "\(error)")
        }
        return (true, "")
    }
    
    func delete() -> Bool {
        do {
            try FileManager.default.removeItem(at: self.path)
        } catch {
            return false
        }
        return true
    }
    
    func getImage(_ imageName: String) -> ImageModel? {
        let trimmedName = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
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
        if trimmedName.isEmpty {
            return nil
        }

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
                return itemURL
            }
        }

        return nil
    }

    func getImageList() -> [ImageModel] {
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: self.imagePath.path)
            var models = [ImageModel]()
            for item in items {
                let imagePath = self.imagePath.appendingPathComponent(item)
                let imageName = imagePath.deletingPathExtension().lastPathComponent
                models.append(ImageModel(name: imageName, path: imagePath))
            }
            models.sort { a, b in
                return a.name.compare(b.name) == .orderedAscending
            }
            return models
        } catch {
            print("get image list exception: \(error)")
        }
        return []
    }
    
#if os(macOS)
    func saveImage(imagePath: URL) -> Bool {
        try? FileManager.default.createDirectory(at: self.imagePath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        
        if imagePath.pathExtension != "png" {
            return false
        }
        let fileName = imagePath.lastPathComponent
        var newFileName = fileName
        var newFilePath = self.imagePath.appendingPathComponent(newFileName)
        if FileManager.default.fileExists(atPath: newFilePath.path) {
            // file name existed, get a new name
            let count = self.getImageList().count
            newFileName = "image\(count).png"
            newFilePath = self.imagePath.appendingPathComponent(newFileName)
        }
        
        do {
            try FileManager.default.copyItem(at: imagePath, to: newFilePath)
        } catch {
            print("error = \(error)")
            return false
        }
        
        return true
    }
    func saveImage(image: NSImage, imageName: String) -> Bool {
        try? FileManager.default.createDirectory(at: self.imagePath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        
        let imagePath = self.imagePath.appendingPathComponent(imageName).appendingPathExtension("png")
        do {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return false
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = image.size
            guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
                return false
            }
            try imageData.write(to: imagePath)
            
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: imagePath.path)
        } catch {
            print("save image \(error)")
            return false
        }
        return true
    }
#else
    func saveImage(image: UIImage, imageName: String) -> Bool {
        try? FileManager.default.createDirectory(at: self.imagePath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        
        let imagePath = self.imagePath.appendingPathComponent(imageName).appendingPathExtension("png")
        do {
            guard let imageData = image.pngData() else { return false }
            try imageData.write(to: imagePath)
            
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: imagePath.path)
        } catch {
            print("save image \(error)")
            return false
        }
        return true
    }
#endif
    func renameImage(name: String, newName: String) -> (Bool, String) {
        let newPath = self.imagePath.appendingPathComponent("\(newName).png")
        if FileManager.default.fileExists(atPath: newPath.path) {
            return (false, "new name existed")
        }
        let oldPath = self.imagePath.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.moveItem(at: oldPath, to: newPath)
            return (true, "succeed")
        } catch {
            return (false, "move failed : \(error)")
        }
    }
    
    
    func deleteImage(name: String) -> (Bool, String) {
        let path = self.imagePath.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.removeItem(at: path)
            return (true, "succeed")
        } catch {
            return (false, "delete failed : \(error)")
        }
    }
    
    func listFiles() -> [FileModel] {
        return self.listFilesInternal()
    }
    
    private func listFilesInternal(_ leadingPath: String = "") -> [FileModel] {
        var curDir = self.path
        if !leadingPath.isEmpty {
            curDir = self.path.appendingPathComponent(leadingPath)
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: curDir.path) else {
            return []
        }
        
        var items = [FileModel]()
        
        for file in files {
            let fullPath = curDir.appendingPathComponent(file)
            
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir) {
                continue
            }
            
            if isDir.boolValue {
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
        let curDir = self.path
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: curDir.path) else {
            return []
        }
        
        var items = [FileModel]()
        for file in files {
            let fullPath = curDir.appendingPathComponent(file)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir) {
                continue
            }
            if isDir.boolValue {
                continue
            }
            if file.suffix(4).lowercased() == ".jsx"
                || file.suffix(3).lowercased() == ".js"
                || file.suffix(5).lowercased() == ".json"
            {
                items.append(FileModel(name: file, relativePath: file, path: fullPath))
            }
        }
        
        return items.sorted { a, b in
            if a.name == "main.jsx" {
                return true
            }
            if b.name == "main.jsx" {
                return false
            }
            return a.name < b.name
        }
    }
}


let globalScriptWidgetPackage = ScriptWidgetPackage(bundle: "Script", relativePath: "template/Is Friday Today")
