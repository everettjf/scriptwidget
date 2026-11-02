import Foundation
import Darwin

/// A small, reviewable GitHub draft. Diagnostic events and user content never
/// enter a URL, browser history or a remote service through this helper.
enum ScriptWidgetDiagnosticIssueDraft {
    static func versions(environment: ScriptWidgetDiagnosticLog.Environment = .current) -> String {
        let version = environment.appVersion.map(String.init).joined(separator: ".")
        let build = environment.appBuild.map(String.init) ?? "unknown"
        let os = environment.osVersion.map(String.init).joined(separator: ".")
        let simulator = environment.simulator ? " (Simulator)" : ""
        return "ScriptWidget \(version.isEmpty ? "unknown" : version) (\(build)); \(environment.platform.rawValue) \(os)\(simulator)"
    }

    static func url(environment: ScriptWidgetDiagnosticLog.Environment = .current) -> URL? {
        var components = URLComponents(string: "https://github.com/everettjf/scriptwidget/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "versions", value: versions(environment: environment)),
            URLQueryItem(name: "diagnostics", value: "Attach the exported ScriptWidget-diagnostics.json file here. Review it before attaching: this issue and its attachments are public. Include screenshots if helpful, with personal information removed.")
        ]
        return components?.url
    }
}

/// Native diagnostic events deliberately accept no messages, paths, package
/// names or userInfo. Export is independent of the library and its record store.
final class ScriptWidgetDiagnosticLog: @unchecked Sendable {
    enum Stage: String, Codable {
        case applicationStart, libraryOpen, libraryChoices, libraryRefresh, librarySelect, restoredPackages
        case appGroupAccess, iCloudAccess, privateStoreOpen, profileIndexRead, profileStoreOpen
        case sourceReceipt, sourceIdentity, cacheOpen, sourceOpen, activation, preparing, inventory, planned, ready
        case exportLogs, logRead
        case deleteProject, deleteCleanup
    }
    enum Outcome: String, Codable { case started, success, failure, offline }
    enum Failure: String, Codable {
        case fileUnavailable, fileInvalidData, fileLimitExceeded
        case namespaceUnavailable, invalidRegistry, invalidName, inventoryRequired, unregistered, reviewRequired, conflict, limitExceeded
        case editorsOpen, storageUnavailable, changedChoice, identityMismatch
        case decoding, cocoa, posix, unknown
    }
    struct Facts: Codable, Hashable {
        var iCloud: Bool?
        var available: Bool?
        var expectedDevice: UInt64?
        var actualDevice: UInt64?
        var expectedInode: UInt64?
        var actualInode: UInt64?
    }
    struct Payload: Codable, Hashable {
        let stage: Stage
        let outcome: Outcome
        let failure: Failure?
        let systemCode: Int?
        let facts: Facts
    }
    struct Event: Codable {
        let id: UUID
        let session: UUID
        let time: Date
        let uptime: TimeInterval
        let environment: Environment
        let payload: Payload
    }
    struct Environment: Codable {
        enum Platform: String, Codable { case iOS, macOS }
        let platform: Platform
        let simulator: Bool
        let appVersion: [Int]
        let appBuild: Int?
        let osVersion: [Int]

        static let current: Environment = {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
#if os(iOS)
            let platform: Platform = .iOS
#else
            let platform: Platform = .macOS
#endif
#if targetEnvironment(simulator)
            let simulator = true
#else
            let simulator = false
#endif
            return Environment(platform: platform, simulator: simulator,
                appVersion: version.split(separator: ".").prefix(4).compactMap { Int($0) },
                appBuild: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init),
                osVersion: [os.majorVersion, os.minorVersion, os.patchVersion])
        }()
    }
    struct Report: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let appVersion: String
        let appBuild: String
        let operatingSystem: String
        let environment: Environment
        let scope: String
        let retentionBytes: Int
        let events: [Event]
    }

    static let shared: ScriptWidgetDiagnosticLog = {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
        let base = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWidgetDiagnosticTests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let log = ScriptWidgetDiagnosticLog(directory: base?.appendingPathComponent("ScriptWidget/Diagnostics", isDirectory: true))
        log.record(.applicationStart, outcome: .started)
        return log
    }()
    static let maximumFileBytes = 128 * 1_024
    private let directory: URL?
    private let maximumBytes: Int
    private let repeatInterval: TimeInterval
    private let session = UUID()
    private let lock = NSLock()
    private var recent: [Payload: Date] = [:]
    private var unsaved: [Event] = []

    init(directory: URL?, maximumBytes: Int = maximumFileBytes, repeatInterval: TimeInterval = 60) {
        self.directory = directory
        self.maximumBytes = max(1_024, min(maximumBytes, Self.maximumFileBytes))
        self.repeatInterval = repeatInterval
    }

    static func capture<T>(_ stage: Stage, facts: Facts = .init(), operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { shared.record(stage, outcome: .failure, error: error, facts: facts); throw error }
    }

    func record(_ stage: Stage, outcome: Outcome, error: Error? = nil, failure: Failure? = nil,
                facts: Facts = .init(), at date: Date = Date()) {
        let native = error as? any ScriptWidgetDiagnosticFailureProviding
        let system = error.map { $0 as NSError }
        let family: Failure? = error == nil ? nil : native?.diagnosticFailure
            ?? (error is DecodingError ? .decoding : system?.domain == NSCocoaErrorDomain ? .cocoa
                : system?.domain == NSPOSIXErrorDomain ? .posix : .unknown)
        let code = system.flatMap { [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains($0.domain) ? $0.code : nil }
        let payload = Payload(stage: stage, outcome: outcome, failure: failure ?? family, systemCode: code, facts: facts)
        lock.lock(); defer { lock.unlock() }
        if let last = recent[payload], date.timeIntervalSince(last) >= 0, date.timeIntervalSince(last) < repeatInterval { return }
        if recent.count >= 128 { recent.removeAll() }
        recent[payload] = date
        let event = Event(id: UUID(), session: session, time: date, uptime: ProcessInfo.processInfo.systemUptime,
            environment: .current, payload: payload)
        do {
            let line = try Self.encoder().encode(event) + Data([10])
            try withDirectory { root in
                let current = try read(root, name: "current.jsonl")
                if current.count + line.count > maximumBytes {
                    guard renameat(root, "current.jsonl", root, "previous.jsonl") == 0 else { throw CocoaError(.fileWriteUnknown) }
                }
                let fd = openat(root, "current.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { close(fd) }
                try validateFile(fd)
                try line.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                        offset += count
                    }
                }
            }
        } catch {
            // A diagnostic failure must never stop startup or record access.
            unsaved.append(event)
            if unsaved.count > 128 { unsaved.removeFirst(unsaved.count - 128) }
        }
    }

    func export(at date: Date = Date()) throws -> Data {
        record(.exportLogs, outcome: .started, at: date)
        lock.lock(); defer { lock.unlock() }
        var events: [Event] = []
        do {
            try withDirectory { root in
                for name in ["previous.jsonl", "current.jsonl"] {
                    for line in try read(root, name: name).split(separator: 10) {
                        // Re-encode only our typed schema. Never export raw bytes
                        // from a corrupt, replaced or incomplete log line.
                        if let event = try? Self.decoder().decode(Event.self, from: Data(line)) { events.append(event) }
                    }
                }
            }
        } catch {
            events.append(Event(id: UUID(), session: session, time: date, uptime: ProcessInfo.processInfo.systemUptime,
                environment: .current,
                payload: .init(stage: .logRead, outcome: .failure, failure: .fileUnavailable, systemCode: nil, facts: .init())))
        }
        events.append(contentsOf: unsaved)
        let report = Report(formatVersion: 1, exportedAt: date,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            environment: .current,
            scope: "Application library diagnostics on this device; no script contents, records, paths or credentials.",
            retentionBytes: maximumBytes * 2, events: events.sorted { $0.time < $1.time })
        return try Self.encoder(pretty: true).encode(report)
    }

    private func withDirectory<T>(_ operation: (Int32) throws -> T) throws -> T {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        // App-local Application Support; never depends on iCloud/App Group or
        // a selected library. Final components and every log file reject links.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(root) }
        let fd = openat(root, "writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        try validateFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation(root)
    }

    private func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw CocoaError(.fileReadNoPermission) }
    }

    private func read(_ root: Int32, name: String) throws -> Data {
        let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return Data() }
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        try validateFile(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        var data = Data(count: maximumBytes + 1)
        let count = try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        guard count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return Data(data.prefix(count))
    }

    private static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

protocol ScriptWidgetDiagnosticFailureProviding: Error {
    var diagnosticFailure: ScriptWidgetDiagnosticLog.Failure { get }
}
