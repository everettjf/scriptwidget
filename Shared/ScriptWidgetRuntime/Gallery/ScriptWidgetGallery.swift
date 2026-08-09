//
//  ScriptWidgetGallery.swift
//  ScriptWidget
//
//  GitHub-backed Gallery 1.0. Remote files are data, never executable plugins:
//  every byte is size/hash checked before Package 2.0 or Skills 1.0 validation.
//

import CryptoKit
import Foundation

enum GalleryItemKind: String, Codable, CaseIterable, Identifiable {
    case widget
    case skill

    var id: String { rawValue }
    var displayName: String { self == .widget ? "Widgets" : "Skills" }
}

struct GalleryFile: Codable, Equatable, Hashable {
    let path: String
    let url: URL
    let sha256: String
    let bytes: Int
}

struct GalleryItem: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let kind: GalleryItemKind
    let name: String
    let version: String
    let summary: String
    let symbol: String
    let author: String
    let license: String
    let tags: [String]
    let minimumRuntimeVersion: String
    let sourceURL: URL
    let featured: Bool
    let files: [GalleryFile]

    var contentFingerprint: String {
        files.sorted { $0.path < $1.path }.map { "\($0.path):\($0.sha256)" }.joined(separator: "|")
    }
}

struct GalleryIndex: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let repository: URL
    let items: [GalleryItem]
}

struct GalleryValidationIssue: Identifiable, Equatable {
    let id: String
    let message: String
}

struct GalleryValidationReport: Equatable {
    let issues: [GalleryValidationIssue]
    var isValid: Bool { issues.isEmpty }
}

enum GalleryIndexValidator {
    static let maximumIndexBytes = 1024 * 1024
    static let maximumItems = 500
    static let maximumWidgetBytes = 32 * 1024 * 1024
    static let maximumSkillBytes = 256 * 1024
    static let maximumFiles = 500

    static func decode(_ data: Data) -> Result<GalleryIndex, Error> {
        do {
            guard data.count <= maximumIndexBytes else { throw GalleryError.invalidIndex("Gallery index exceeds 1 MiB.") }
            try rejectUnknownFields(data)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(GalleryIndex.self, from: data)
            let report = validate(index)
            guard report.isValid else {
                throw GalleryError.invalidIndex(report.issues.map(\.message).joined(separator: "\n"))
            }
            return .success(index)
        } catch {
            return .failure(error)
        }
    }

    static func validate(_ index: GalleryIndex) -> GalleryValidationReport {
        var issues: [GalleryValidationIssue] = []
        func reject(_ id: String, _ message: String) { issues.append(.init(id: id, message: message)) }

        if index.schemaVersion != GalleryIndex.currentSchemaVersion { reject("schema", "Gallery schema \(index.schemaVersion) is unsupported.") }
        if index.items.isEmpty || index.items.count > maximumItems { reject("items", "Gallery must contain 1–\(maximumItems) items.") }
        if !isGitHubURL(index.repository) { reject("repository", "Gallery repository must be an HTTPS github.com URL.") }
        if Set(index.items.map { $0.id.lowercased() }).count != index.items.count { reject("duplicate_item", "Gallery item identifiers must be unique.") }

        for item in index.items {
            validate(item, reject: reject)
        }
        return .init(issues: issues)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.count <= 16 && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isRawGitHubURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "raw.githubusercontent.com"
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
    }

    static func isGitHubURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil && url.password == nil && url.port == nil
    }

    private static func validate(_ item: GalleryItem, reject: (String, String) -> Void) {
        let prefix = item.id.isEmpty ? "item" : item.id
        if item.id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$", options: .regularExpression) == nil {
            reject("\(prefix).id", "Gallery item id is invalid: \(item.id)")
        }
        if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.name.count > 80 { reject("\(prefix).name", "\(item.id) has an invalid name.") }
        if item.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$", options: .regularExpression) == nil { reject("\(prefix).version", "\(item.id) must use semantic versioning.") }
        if item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.summary.count > 240 { reject("\(prefix).summary", "\(item.id) has an invalid summary.") }
        if item.minimumRuntimeVersion != ScriptWidgetBuildContract.runtimeAPIVersion { reject("\(prefix).runtime", "\(item.id) requires unsupported runtime \(item.minimumRuntimeVersion).") }
        if item.tags.count > 20 || Set(item.tags.map { $0.lowercased() }).count != item.tags.count { reject("\(prefix).tags", "\(item.id) has invalid tags.") }
        if !isGitHubURL(item.sourceURL) { reject("\(prefix).source", "\(item.id) sourceURL must use HTTPS github.com.") }
        if item.files.count < 2 || item.files.count > maximumFiles { reject("\(prefix).files", "\(item.id) has an invalid file count.") }

        let normalizedPaths = item.files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }
        if Set(normalizedPaths).count != normalizedPaths.count { reject("\(prefix).paths", "\(item.id) contains duplicate or case-colliding paths.") }
        var total = 0
        for file in item.files {
            if !isSafeRelativePath(file.path) { reject("\(prefix).path", "\(item.id) contains unsafe path \(file.path).") }
            if !isRawGitHubURL(file.url) { reject("\(prefix).url", "\(item.id) files must use raw.githubusercontent.com over HTTPS.") }
            if file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil { reject("\(prefix).hash", "\(item.id) contains an invalid SHA-256.") }
            if file.bytes <= 0 || file.bytes > ScriptPackageArchivePolicy.maximumFileBytes { reject("\(prefix).bytes", "\(item.id) contains an invalid file size.") }
            if total <= Int.max - max(0, file.bytes) { total += max(0, file.bytes) } else { reject("\(prefix).total", "\(item.id) size overflows.") }
        }
        let paths = Set(item.files.map(\.path))
        switch item.kind {
        case .widget:
            if !paths.isSuperset(of: ["widget.json", "main.jsx"]) { reject("\(prefix).required", "Widget \(item.id) must contain widget.json and main.jsx.") }
            if total > maximumWidgetBytes { reject("\(prefix).total", "Widget \(item.id) exceeds 32 MiB.") }
        case .skill:
            if paths != ["skill.json", "SKILL.md"] { reject("\(prefix).required", "Skill \(item.id) must contain exactly skill.json and SKILL.md.") }
            if total > maximumSkillBytes { reject("\(prefix).total", "Skill \(item.id) exceeds 256 KiB.") }
        }
    }

    private static func rejectUnknownFields(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GalleryError.invalidIndex("Gallery index must be a JSON object.")
        }
        let rootKeys: Set<String> = ["schemaVersion", "generatedAt", "repository", "items"]
        guard Set(root.keys).isSubset(of: rootKeys), let items = root["items"] as? [[String: Any]] else {
            throw GalleryError.invalidIndex("Gallery index contains unknown fields or invalid items.")
        }
        let itemKeys: Set<String> = ["id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags", "minimumRuntimeVersion", "sourceURL", "featured", "files"]
        let fileKeys: Set<String> = ["path", "url", "sha256", "bytes"]
        for item in items {
            guard Set(item.keys).isSubset(of: itemKeys), let files = item["files"] as? [[String: Any]],
                  files.allSatisfy({ Set($0.keys).isSubset(of: fileKeys) }) else {
                throw GalleryError.invalidIndex("Gallery item contains unknown fields.")
            }
        }
    }
}

enum GalleryError: LocalizedError, Equatable {
    case invalidIndex(String)
    case network(String)
    case missingCache
    case invalidDownload(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .invalidIndex(let value), .network(let value), .invalidDownload(let value), .install(let value): value
        case .missingCache: "Gallery is unavailable and no offline cache exists."
        }
    }
}

protocol GalleryTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGalleryTransport: GalleryTransport {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GalleryError.network("GitHub returned an invalid response.") }
        return (data, response)
    }
}

struct GallerySnapshot: Equatable {
    let index: GalleryIndex
    let isOffline: Bool
    let fetchedAt: Date
}

struct GalleryCacheMetadata: Codable {
    let etag: String?
    let fetchedAt: Date
}

final class GalleryIndexCache {
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var metadataURL: URL { directory.appendingPathComponent("metadata.json") }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent("ScriptWidgetGallery", isDirectory: true)
    }

    func load() -> (Data, GalleryCacheMetadata)? {
        guard let data = try? Data(contentsOf: indexURL),
              let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(GalleryCacheMetadata.self, from: metadataData) else { return nil }
        return (data, metadata)
    }

    func save(data: Data, etag: String?, fetchedAt: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: .atomic)
        try JSONEncoder().encode(GalleryCacheMetadata(etag: etag, fetchedAt: fetchedAt)).write(to: metadataURL, options: .atomic)
    }
}

final class GalleryClient {
    static let defaultIndexURL = URL(string: "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json")!

    let indexURL: URL
    private let transport: GalleryTransport
    private let cache: GalleryIndexCache
    private let now: () -> Date

    init(indexURL: URL = defaultIndexURL, transport: GalleryTransport = URLSessionGalleryTransport(), cache: GalleryIndexCache = .init(), now: @escaping () -> Date = Date.init) {
        self.indexURL = indexURL
        self.transport = transport
        self.cache = cache
        self.now = now
    }

    func load(forceRefresh: Bool = false) async throws -> GallerySnapshot {
        guard GalleryIndexValidator.isRawGitHubURL(indexURL) else { throw GalleryError.invalidIndex("Gallery index must use raw.githubusercontent.com over HTTPS.") }
        let cached = cache.load()
        if !forceRefresh, let cached, now().timeIntervalSince(cached.1.fetchedAt) < 15 * 60,
           case .success(let index) = GalleryIndexValidator.decode(cached.0) {
            return .init(index: index, isOffline: false, fetchedAt: cached.1.fetchedAt)
        }

        var request = URLRequest(url: indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ScriptWidget-Gallery/1", forHTTPHeaderField: "User-Agent")
        if let etag = cached?.1.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await transport.data(for: request)
            if response.statusCode == 304, let cached,
               case .success(let index) = GalleryIndexValidator.decode(cached.0) {
                let date = now()
                try cache.save(data: cached.0, etag: cached.1.etag, fetchedAt: date)
                return .init(index: index, isOffline: false, fetchedAt: date)
            }
            guard response.statusCode == 200 else { throw GalleryError.network(httpMessage(response)) }
            guard GalleryIndexValidator.isRawGitHubURL(response.url ?? indexURL) else { throw GalleryError.network("Gallery redirected to an untrusted host.") }
            guard case .success(let index) = GalleryIndexValidator.decode(data) else {
                if case .failure(let error) = GalleryIndexValidator.decode(data) { throw error }
                throw GalleryError.invalidIndex("Gallery index is invalid.")
            }
            let date = now()
            try cache.save(data: data, etag: response.value(forHTTPHeaderField: "ETag"), fetchedAt: date)
            return .init(index: index, isOffline: false, fetchedAt: date)
        } catch {
            if let cached, case .success(let index) = GalleryIndexValidator.decode(cached.0) {
                return .init(index: index, isOffline: true, fetchedAt: cached.1.fetchedAt)
            }
            throw error
        }
    }

    private func httpMessage(_ response: HTTPURLResponse) -> String {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        if response.statusCode == 403 || response.statusCode == 429 {
            return remaining == "0" ? "GitHub rate limit reached. Try again after the reset time." : "GitHub temporarily limited Gallery requests. Try again later."
        }
        return "GitHub returned HTTP \(response.statusCode)."
    }
}

struct GalleryInstalledRecord: Codable, Equatable {
    let itemID: String
    let kind: GalleryItemKind
    let version: String
    let localIdentifier: String
    let contentFingerprint: String
    let installedAt: Date
}

enum GalleryInstallState: Equatable {
    case notInstalled
    case installed
    case updateAvailable(current: String)
}

final class GalleryInstallationRegistry {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScriptWidget", isDirectory: true)
        self.fileURL = fileURL ?? base.appendingPathComponent("gallery-installations.json")
    }

    func records() -> [String: GalleryInstalledRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: GalleryInstalledRecord].self, from: data) else { return [:] }
        return values
    }

    func record(for itemID: String) -> GalleryInstalledRecord? { records()[itemID] }

    func state(for item: GalleryItem) -> GalleryInstallState {
        guard let value = record(for: item.id) else { return .notInstalled }
        if value.version == item.version && value.contentFingerprint == item.contentFingerprint { return .installed }
        if GallerySemanticVersion.compare(value.version, item.version) == .orderedDescending { return .installed }
        return .updateAvailable(current: value.version)
    }

    func save(_ record: GalleryInstalledRecord) throws {
        var values = records()
        values[record.itemID] = record
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
    }
}

enum GallerySemanticVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ value: String) -> [Int] {
            value.split(separator: "-", maxSplits: 1)[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = components(lhs), right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return lhs == rhs ? .orderedSame : lhs.localizedStandardCompare(rhs)
    }
}

final class GalleryInstaller {
    static let changedNotification = Notification.Name("ScriptWidgetGalleryInstallationChanged")
    private let transport: GalleryTransport
    private let registry: GalleryInstallationRegistry
    private let scriptManager: ScriptManager
    private let skillManager: AIWidgetSkillManager
    private let fileManager: FileManager
    private let buildAfterInstall: Bool

    init(
        transport: GalleryTransport = URLSessionGalleryTransport(),
        registry: GalleryInstallationRegistry = .init(),
        scriptManager: ScriptManager = sharedScriptManager,
        skillManager: AIWidgetSkillManager = .shared,
        fileManager: FileManager = .default,
        buildAfterInstall: Bool = true
    ) {
        self.transport = transport
        self.registry = registry
        self.scriptManager = scriptManager
        self.skillManager = skillManager
        self.fileManager = fileManager
        self.buildAfterInstall = buildAfterInstall
    }

    func state(for item: GalleryItem) -> GalleryInstallState {
        guard let record = registry.record(for: item.id) else { return .notInstalled }
        switch record.kind {
        case .widget:
            guard scriptManager.isExist(packageName: record.localIdentifier) else { return .notInstalled }
        case .skill:
            guard skillManager.package(for: item.id) != nil else { return .notInstalled }
        }
        return registry.state(for: item)
    }

    func install(_ item: GalleryItem) async throws -> GalleryInstalledRecord {
        let report = GalleryIndexValidator.validate(.init(schemaVersion: 1, generatedAt: Date(), repository: URL(string: "https://github.com/everettjf/scriptwidget")!, items: [item]))
        guard report.isValid else { throw GalleryError.install(report.issues.map(\.message).joined(separator: "\n")) }
        let prepared = try await download(item)
        defer { try? fileManager.removeItem(at: prepared) }

        let localIdentifier: String
        switch item.kind {
        case .widget: localIdentifier = try installWidget(item, from: prepared)
        case .skill: localIdentifier = try installSkill(item, from: prepared)
        }
        let record = GalleryInstalledRecord(
            itemID: item.id,
            kind: item.kind,
            version: item.version,
            localIdentifier: localIdentifier,
            contentFingerprint: item.contentFingerprint,
            installedAt: Date()
        )
        try registry.save(record)
        NotificationCenter.default.post(name: Self.changedNotification, object: item)
        return record
    }

    private func download(_ item: GalleryItem) async throws -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent("GalleryInstall-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for file in item.files {
                var request = URLRequest(url: file.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("ScriptWidget-Gallery/1", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await transport.data(for: request)
                guard response.statusCode == 200,
                      GalleryIndexValidator.isRawGitHubURL(response.url ?? file.url),
                      data.count == file.bytes,
                      Self.sha256(data) == file.sha256 else {
                    throw GalleryError.invalidDownload("Downloaded file failed status, host, size, or SHA-256 validation: \(file.path)")
                }
                let destination = root.appendingPathComponent(file.path)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            return root
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func installWidget(_ item: GalleryItem, from source: URL) throws -> String {
        let package = ScriptWidgetPackage(path: source)
        guard let manifest = package.readManifest(), manifest.id == item.id, manifest.version == item.version else {
            throw GalleryError.install("Downloaded widget identity or version does not match the Gallery index.")
        }
        let validation = WidgetPackageManifestValidator.validate(manifest, package: package)
        guard validation.isValid else { throw GalleryError.install(validation.errors.map(\.message).joined(separator: "\n")) }

        let existing = registry.record(for: item.id)
        let localName = existing?.kind == .widget && scriptManager.isExist(packageName: existing!.localIdentifier)
            ? existing!.localIdentifier
            : scriptManager.getValidPackageName(recommendPackageName: manifest.name)
        let destination = scriptManager.getPackagePathFromPackageName(packageName: localName)
        try replaceDirectory(at: destination, with: source) {
            if buildAfterInstall {
                let build = scriptManager.buildScriptPackage(package: scriptManager.getScriptPackage(packageName: localName))
                guard build.0 else { throw GalleryError.install(build.1) }
            }
        }
        return localName
    }

    private func installSkill(_ item: GalleryItem, from source: URL) throws -> String {
        let package = AIWidgetSkillPackage(directory: source)
        guard let (manifest, instruction) = package.load(), manifest.id == item.id, manifest.version == item.version else {
            throw GalleryError.install("Downloaded skill identity or version does not match the Gallery index.")
        }
        let validation = AIWidgetSkillValidator.validate(manifest: manifest, instruction: instruction)
        guard validation.isValid else { throw GalleryError.install(validation.issues.map(\.message).joined(separator: "\n")) }

        let existing = registry.record(for: item.id)
        let destination: URL
        if existing?.kind == .skill, let installed = skillManager.package(for: item.id) {
            destination = installed.directory
        } else {
            destination = uniqueDirectory(in: skillManager.directory, preferredName: manifest.name)
        }
        try replaceDirectory(at: destination, with: source)
        NotificationCenter.default.post(name: AIWidgetSkillManager.changedNotification, object: skillManager)
        return item.id
    }

    private func replaceDirectory(at destination: URL, with source: URL, afterReplace: () throws -> Void = {}) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".gallery-staging-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".gallery-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: source, to: staging)
        let hadExisting = fileManager.fileExists(atPath: destination.path)
        do {
            if hadExisting { try fileManager.moveItem(at: destination, to: backup) }
            try fileManager.moveItem(at: staging, to: destination)
            try afterReplace()
            if hadExisting { try? fileManager.removeItem(at: backup) }
        } catch {
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
            if hadExisting, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func uniqueDirectory(in parent: URL, preferredName: String) -> URL {
        let base = AIWidgetSkillValidator.slug(preferredName)
        var result = parent.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: result.path) {
            result = parent.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
