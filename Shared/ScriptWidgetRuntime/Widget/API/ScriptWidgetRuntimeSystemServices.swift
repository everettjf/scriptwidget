import Foundation
import CoreFoundation
import JavaScriptCore
import CryptoKit

// Public native system capability adapters share one execution/identity gate.
// Grants are installation-local metadata, never authored package contents.
enum ScriptWidgetSystemServiceError: String, Error, LocalizedError {
    case invalidOptions = "invalid_options", permissionDenied = "permission_denied", unavailable, queryLimit = "query_limit", readOnly = "read_only", scopeChanged = "scope_changed", limitExceeded = "limit_exceeded", outcomeUnknown = "outcome_unknown", staleRequest = "request_conflict"
    var errorDescription: String? { "[\(rawValue)] System operation could not complete. Existing user data is preserved." }
}

struct ScriptWidgetSystemAccessGrant: Codable, Equatable {
    var version = 1
    var generation = UUID().uuidString.lowercased()
    var permissions: [String] = []
    var contacts: [String] = []
    var home: [String] = []
    var documents: [Document] = []
    struct Document: Codable, Equatable {
        let id: String
        let name: String
        let type: String
        let bytes: Int
    }
    static let capabilities: Set<String> = ["notifications", "calendarWrite", "alarms", "documents", "contacts", "home", "maps", "weather"]
    var isValid: Bool {
        version == 1 && UUID(uuidString: generation)?.uuidString.lowercased() == generation &&
        Set(permissions).count == permissions.count && Set(permissions).isSubset(of: Self.capabilities) &&
        contacts.count <= 20 && home.count <= 20 && [contacts, home].allSatisfy { ids in Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } } &&
        documents.count <= 8 && Set(documents.map(\.id)).count == documents.count && documents.allSatisfy {
            UUID(uuidString: $0.id)?.uuidString.lowercased() == $0.id && !$0.name.isEmpty && $0.name.utf8.count <= 255 && ["json", "csv"].contains($0.type) && (0...262144).contains($0.bytes)
        }
    }
}

struct ScriptWidgetSystemAccessStore {
    let container: URL
    let owner: String
    let validate: () throws -> Void
    var directory: String { "SystemAccess.v1/" + owner }
    var path: String { directory + "/grant.json" }
    func privateKey(_ kind: String) -> String { "ScriptWidget.SystemServices." + kind + ".v1." + owner }
    func load() throws -> ScriptWidgetSystemAccessGrant {
        try validate()
        guard UUID(uuidString: owner)?.uuidString.lowercased() == owner else { throw ScriptWidgetSystemServiceError.permissionDenied }
        guard let data = ScriptWidgetPackageFiles.read(root: container, relative: path, maximumBytes: 32768) else {
            if ScriptWidgetPackageFiles.safeURL(root: container, relative: path) != nil, ScriptWidgetPackageFiles.kind(root: container, relative: path) == nil { return .init() }
            throw ScriptWidgetSystemServiceError.unavailable
        }
        let value = try JSONDecoder().decode(ScriptWidgetSystemAccessGrant.self, from: data)
        guard value.isValid,
              try ScriptWidgetCloudJSONStore.hash(JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: .sortedKeys)) == ScriptWidgetCloudJSONStore.hash(JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(value)), options: .sortedKeys)) else { throw ScriptWidgetSystemServiceError.unavailable }
        return value
    }
    func save(_ grant: ScriptWidgetSystemAccessGrant, expected: ScriptWidgetSystemAccessGrant) throws {
        guard grant.isValid else { throw ScriptWidgetSystemServiceError.invalidOptions }
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: path, operation: { Result {
            try validate()
            let current = try load()
            // Missing grants have no durable generation yet.
            guard ScriptWidgetPackageFiles.kind(root: container, relative: path) == nil || current == expected else { throw ScriptWidgetSystemServiceError.scopeChanged }
            var value = grant; value.generation = UUID().uuidString.lowercased()
            guard ScriptWidgetPackageFiles.write(try JSONEncoder().encode(value), root: container, relative: path) else { throw ScriptWidgetSystemServiceError.unavailable }
        } }) else { throw ScriptWidgetSystemServiceError.unavailable }
        try result.get()
    }
    func readDocument(_ id: String, type: String) throws -> Data {
        let grant = try load()
        guard grant.permissions.contains("documents"), let item = grant.documents.first(where: { $0.id == id && $0.type == type }),
              let data = ScriptWidgetPackageFiles.read(root: container, relative: directory + "/documents/" + item.id, maximumBytes: 262144), data.count == item.bytes else { throw ScriptWidgetSystemServiceError.permissionDenied }
        return data
    }
}

struct ScriptWidgetSystemServiceContext {
    let state: ScriptWidgetRunningState
    let permission: WidgetPackagePermission
    let writing: Bool
    let grantRequired: Bool
    let initialGrant: ScriptWidgetSystemAccessGrant?
    var access: ScriptWidgetSystemAccessStore {
        let snapshot = state.executionSnapshot!
        return .init(container: snapshot.context.container, owner: snapshot.binding.ownerID, validate: { try snapshot.validateIdentity() })
    }
    func validate() throws {
        guard state.isCurrentExecution, state.previewStorage == nil, let snapshot = state.executionSnapshot,
              let manifest = state.package.readManifest(), manifest.permissions.contains(permission),
              WidgetPackageManifestValidator.validate(manifest, package: state.package, checkEntryExists: false).isValid,
              WidgetRuntimeRequirement.supports("1.6", current: manifest.minimumRuntimeVersion ?? "0.0") else { throw ScriptWidgetSystemServiceError.permissionDenied }
        try snapshot.validateIdentity()
        guard !state.isTimelineProjection, !state.isLiveActivityPresentation,
              !writing || state.isUserInitiatedAction else { throw ScriptWidgetSystemServiceError.readOnly }
        if grantRequired {
            let grant = try access.load()
            guard grant.permissions.contains(permission.rawValue), initialGrant == nil || grant == initialGrant else { throw ScriptWidgetSystemServiceError.permissionDenied }
        }
    }
    var owner: String { state.executionSnapshot!.binding.ownerID }
    func scopedID(_ key: String, group: String) throws -> String {
        guard ScriptWidgetSystemOptions.validKey(key) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        return "sw." + owner + "." + group + "." + key
    }
}

enum ScriptWidgetSystemServices {
    static let queue = DispatchQueue(label: "ScriptWidget.SystemServices", qos: .userInitiated)
    static func perform(_ permission: WidgetPackagePermission, writing: Bool = false, grant: Bool = true,
                        operation: @escaping (ScriptWidgetSystemServiceContext, @escaping (Result<Any, Error>) -> Void) throws -> Void) -> ScriptWidgetRuntimePromise {
        let state = JSContext.current()?.scriptWidgetRunningState
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state, state.executionSnapshot != nil else { reject.call(withArguments: [ScriptWidgetSystemServiceError.permissionDenied.localizedDescription]); return }
            var context = ScriptWidgetSystemServiceContext(state: state, permission: permission, writing: writing, grantRequired: grant, initialGrant: nil)
            do {
                try context.validate()
                context = .init(state: state, permission: permission, writing: writing, grantRequired: grant, initialGrant: grant ? try context.access.load() : nil)
                guard state.executionSession.registerDataQuery() else { throw ScriptWidgetSystemServiceError.queryLimit }
            } catch { reject.call(withArguments: [safeError(error)]); return }
            let captured = context
            let finish: (Result<Any, Error>) -> Void = { result in
                state.executionSession.callbackQueue.async {
                    guard state.isCurrentExecution else { return }
                    do { try captured.validate(); resolve.call(withArguments: [try result.get()]) }
                    catch { reject.call(withArguments: [safeError(error)]) }
                }
            }
            queue.async {
                do { try captured.validate(); try operation(captured, finish) }
                catch { finish(.failure(error)) }
            }
        }
    }
    static func safeError(_ error: Error) -> String {
        if let failure = error as? ScriptWidgetReminderMutationLedger.Failure {
            switch failure {
            case .uncertain: return ScriptWidgetSystemServiceError.outcomeUnknown.localizedDescription
            case .conflict: return ScriptWidgetSystemServiceError.staleRequest.localizedDescription
            case .full: return ScriptWidgetSystemServiceError.limitExceeded.localizedDescription
            case .busy, .corrupt: return ScriptWidgetSystemServiceError.unavailable.localizedDescription
            }
        }
        return (error as? ScriptWidgetSystemServiceError)?.localizedDescription ?? "[system_failed] System operation failed; review the result before retrying a write."
    }
}

/// Strict bounded inputs used by the native adapters and deterministic tests.
enum ScriptWidgetSystemOptions {
    static func validKey(_ key: String) -> Bool { key.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil }
    static func fields(_ options: [String: Any], _ allowed: Set<String>) throws {
        guard Set(options.keys).isSubset(of: allowed), JSONSerialization.isValidJSONObject(options),
              try JSONSerialization.data(withJSONObject: options).count <= 16384 else { throw ScriptWidgetSystemServiceError.invalidOptions }
    }
    static func text(_ value: Any?, maximum: Int = 256) throws -> String {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximum, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        return text
    }
    static func number(_ value: Any?, range: ClosedRange<Double>) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, range.contains(n.doubleValue) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        return n.doubleValue
    }
    static func date(_ value: Any?) throws -> Date {
        let text = try text(value, maximum: 64)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard text.contains("T"), let date = ISO8601DateFormatter().date(from: text) ?? formatter.date(from: text), date.timeIntervalSince1970.isFinite else { throw ScriptWidgetSystemServiceError.invalidOptions }
        return date
    }
    static func boolean(_ value: Any?) throws -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ScriptWidgetSystemServiceError.invalidOptions }; return n.boolValue
    }
}

protocol ScriptWidgetSystemMutationRequest {
    var requestID: String { get }
    var fingerprint: String { get }
    var listID: String { get }
}
extension ScriptWidgetReminderMutation: ScriptWidgetSystemMutationRequest { }

/// Worker-only bounded bridge for native asynchronous mutation acknowledgments.
/// A timeout leaves the durable prepared receipt in place; never auto-retry it.
final class ScriptWidgetSystemCompletionBox {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private let semaphore = DispatchSemaphore(value: 0)
    func finish(_ value: Result<String, Error>) { lock.lock(); if result == nil { result = value; semaphore.signal() }; lock.unlock() }
    func wait() throws -> String {
        guard semaphore.wait(timeout: .now() + 2.5) == .success else { throw ScriptWidgetSystemServiceError.outcomeUnknown }
        lock.lock(); defer { lock.unlock() }; return try result!.get()
    }
}

struct ScriptWidgetNativeMutation: ScriptWidgetSystemMutationRequest {
    let requestID: String
    let fingerprint: String
    let listID: String
    init(_ options: [String: Any], scope: String, operation: String) throws {
        requestID = try ScriptWidgetSystemOptions.text(options["requestID"], maximum: 36)
        guard UUID(uuidString: requestID)?.uuidString.lowercased() == requestID else { throw ScriptWidgetSystemServiceError.invalidOptions }
        listID = scope
        fingerprint = ScriptWidgetCloudJSONStore.hash(try JSONSerialization.data(withJSONObject: ["operation": operation, "options": options], options: [.sortedKeys, .withoutEscapingSlashes]))
    }
}
