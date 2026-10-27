import Foundation
import CoreFoundation
import JavaScriptCore
import CryptoKit
import Darwin
#if canImport(EventKit)
import EventKit
#endif

@objc protocol ScriptWidgetRuntimeCalendarExports: JSExport {
    static func isAvailable() -> Bool
    static func authorizationStatus() -> String
    static func requestAuthorization() -> ScriptWidgetRuntimePromise
    static func calendars() -> ScriptWidgetRuntimePromise
    static func create(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func update(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func events(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
}

/// Strict, deterministic input validation before any private data is queried.
struct ScriptWidgetCalendarQuery {
    static let maximumItems = 50
    static let maximumRangeSeconds: TimeInterval = 31 * 86_400
    let start: Date
    let end: Date
    let limit: Int
    let calendarIDs: [String]
    let maxAgeSeconds: TimeInterval

    init(_ options: [String: Any]?, now: Date = Date(), calendar: Calendar = .current) throws {
        let options = options ?? [:]
        guard Set(options.keys).isSubset(of: ["start", "end", "limit", "calendarIDs", "maxAgeSeconds"]) else {
            throw QueryError.invalid("Unknown calendar query option")
        }
        func date(_ key: String, fallback: Date) throws -> Date {
            guard let raw = options[key] else { return fallback }
            guard let text = raw as? String, text.utf8.count <= 64,
                  text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { throw QueryError.invalid("\(key) must be an ISO-8601 string") }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let value = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            guard let value, value.timeIntervalSince1970.isFinite else { throw QueryError.invalid("Invalid \(key) date") }
            return value
        }
        let today = calendar.startOfDay(for: now)
        start = try date("start", fallback: today)
        end = try date("end", fallback: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        guard end > start, end.timeIntervalSince(start) <= Self.maximumRangeSeconds else {
            throw QueryError.invalid("Calendar range must be positive and at most 31 days")
        }
        func number(_ key: String, fallback: Double, maximum: Double, minimum: Double) throws -> Double {
            guard let raw = options[key] else { return fallback }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= minimum, value.doubleValue <= maximum else { throw QueryError.invalid("Invalid \(key)") }
            return value.doubleValue
        }
        let count = try number("limit", fallback: 10, maximum: Double(Self.maximumItems), minimum: 1)
        guard count.rounded() == count else { throw QueryError.invalid("limit must be an integer") }
        limit = Int(count)
        maxAgeSeconds = try number("maxAgeSeconds", fallback: 60, maximum: 86_400, minimum: 0)
        if let raw = options["calendarIDs"] {
            guard let ids = raw as? [String], ids.count <= 16, !ids.isEmpty,
                  Set(ids.map { Data($0.utf8) }).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw QueryError.invalid("calendarIDs must contain 1–16 unique identifiers")
            }
            calendarIDs = ids.sorted(by: ScriptWidgetCalendarSelection.orderedID)
        } else { calendarIDs = [] }
    }

    var cacheIdentity: String {
        let data = try! JSONSerialization.data(withJSONObject: ["start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970, "limit": limit, "calendarIDs": calendarIDs], options: .sortedKeys)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum QueryError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return "[invalid_options] \(message)" }; return nil }
    }
}

enum ScriptWidgetEventSourceKind: String, Sendable {
    case calendar, reminders
    var fileName: String { self == .calendar ? "calendar-access.v1.json" : "reminders-access.v1.json" }
    var label: String { self == .calendar ? "Calendar sources" : "Reminder lists" }
    var plural: String { self == .calendar ? "calendars" : "reminder lists" }
    var lockName: String { self == .calendar ? "ScriptWidget.CalendarAccess.Selection.v1" : "ScriptWidget.RemindersAccess.Selection.v1" }
}

/// App-owned scope, separate from a script's requested calendar IDs. Missing
/// settings preserve existing access; malformed present settings fail closed.
struct ScriptWidgetCalendarSelection: Equatable, Sendable {
    static let fileName = "calendar-access.v1.json"
    static let maximumIDs = 64
    static let maximumBytes = 128 * 1024
    let calendarIDs: [String]?
    static let all = Self(calendarIDs: nil)

    init(calendarIDs: [String]?) { self.calendarIDs = calendarIDs?.sorted(by: Self.orderedID) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.encoded == rhs.encoded }
    static func sameID(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func orderedID(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    static func contains(_ ids: [String], _ id: String) -> Bool { ids.contains { sameID($0, id) } }

    var encoded: Data {
        try! JSONSerialization.data(withJSONObject: ["formatVersion": 1, "mode": calendarIDs == nil ? "all" : "selected", "calendarIDs": calendarIDs ?? []], options: [.sortedKeys])
    }
    var identity: String { SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined() }
    func allows(_ id: String) -> Bool { calendarIDs.map { Self.contains($0, id) } ?? true }

    static func validIDs(_ ids: [String]) -> Bool {
        ids.count <= maximumIDs && Set(ids.map { Data($0.utf8) }).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }

    static func load(container: URL?, kind: ScriptWidgetEventSourceKind = .calendar) throws -> Self {
        guard let container else { throw AccessError.unavailable }
        var root = stat()
        guard lstat(container.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { throw AccessError.unavailable }
        var info = stat()
        let path = container.appendingPathComponent(kind.fileName)
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw AccessError.unavailable }
            return .all
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              let data = ScriptWidgetPackageFiles.read(root: container, relative: kind.fileName, maximumBytes: maximumBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "mode", "calendarIDs"],
              let version = object["formatVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let mode = object["mode"] as? String, ["all", "selected"].contains(mode),
              let ids = object["calendarIDs"] as? [String], validIDs(ids), mode != "all" || ids.isEmpty else { throw AccessError.unavailable }
        return .init(calendarIDs: mode == "all" ? nil : ids)
    }

    func save(container: URL?, replacing expected: Self? = nil, repairingUnreadable: Bool = false, kind: ScriptWidgetEventSourceKind = .calendar) throws {
        guard let container, Self.validIDs(calendarIDs ?? []), encoded.count <= Self.maximumBytes else { throw AccessError.unavailable }
        var root = stat()
        guard lstat(container.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { throw AccessError.unavailable }
        let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: kind.lockName) {
            Result<Void, Error> {
                if let expected, try Self.load(container: container, kind: kind) != expected { throw AccessError.changed }
                if repairingUnreadable, (try? Self.load(container: container, kind: kind)) != nil { throw AccessError.changed }
                guard ScriptWidgetPackageFiles.write(encoded, root: container, relative: kind.fileName) else { throw AccessError.unavailable }
            }
        }
        guard let result else { throw AccessError.unavailable }
        try result.get()
    }

    /// Keep an explicit native selection unchanged through a system mutation.
    func withStableAccess<T>(container: URL, kind: ScriptWidgetEventSourceKind, operation: () throws -> T) throws -> T {
        let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: kind.lockName) {
            Result<T, Error> {
                guard try Self.load(container: container, kind: kind) == self else { throw AccessError.changed }
                return try operation()
            }
        }
        guard let result else { throw AccessError.unavailable }
        return try result.get()
    }

    func permittedIDs(available: [String], requested: [String]) throws -> [String] {
        if let calendarIDs, calendarIDs.isEmpty { throw AccessError.noneSelected }
        let byID = Dictionary(available.map { (Data($0.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        guard requested.allSatisfy({ byID[Data($0.utf8)] != nil && allows($0) }) else { throw AccessError.outsideSelection }
        let permitted = (requested.isEmpty ? Array(byID.values).filter(allows) : requested).sorted(by: Self.orderedID)
        if calendarIDs != nil, permitted.isEmpty { throw AccessError.outsideSelection }
        return permitted
    }

    enum AccessError: LocalizedError {
        case unavailable, noneSelected, outsideSelection, changed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "[permission_denied] Calendar source settings are unavailable. Open ScriptWidget to review access."
            case .noneSelected: return "[permission_denied] No Calendar sources are selected in ScriptWidget Settings."
            case .outsideSelection: return "[invalid_options] A requested Calendar source is unavailable or outside your selection."
            case .changed: return "[permission_denied] Calendar source selection changed. Run the widget again."
            }
        }
    }
}

/// Cache records are untrusted app-group data. Only bounded, matching records
/// survive decoding; authorization is checked separately before and after use.
enum ScriptWidgetCalendarCache {
    static let maximumBytes = 64 * 1_024

    static func decode(_ data: Data, query: ScriptWidgetCalendarQuery, now: Date = Date(), selection: ScriptWidgetCalendarSelection = .all) -> [String: Any]? {
        guard query.maxAgeSeconds > 0, selection.calendarIDs?.isEmpty != true, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (Set(object.keys) == ["query", "timestamp", "value", "selection"] || (selection == .all && Set(object.keys) == ["query", "timestamp", "value"])),
              object["selection"] == nil || object["selection"] as? String == selection.identity,
              object["query"] as? String == query.cacheIdentity,
              let timestamp = object["timestamp"] as? NSNumber, CFGetTypeID(timestamp) != CFBooleanGetTypeID(), timestamp.doubleValue.isFinite,
              timestamp.doubleValue <= now.timeIntervalSince1970,
              now.timeIntervalSince1970 - timestamp.doubleValue <= query.maxAgeSeconds,
              var value = object["value"] as? [String: Any],
              Set(value.keys) == ["status", "items", "fetchedAt", "source", "stale", "truncated"],
              let items = value["items"] as? [[String: Any]], items.count <= query.limit,
              value["status"] as? String == (items.isEmpty ? "empty" : "ready"),
              let fetchedAt = value["fetchedAt"] as? String, ISO8601DateFormatter().date(from: fetchedAt) != nil,
              value["source"] as? String == "system",
              let stale = value["stale"] as? NSNumber, CFGetTypeID(stale) == CFBooleanGetTypeID(),
              let truncated = value["truncated"] as? NSNumber, CFGetTypeID(truncated) == CFBooleanGetTypeID() else { return nil }
        for item in items {
            guard Set(item.keys) == ["id", "calendarID", "title", "start", "end", "allDay"],
                  let id = item["id"] as? String, id.utf8.count <= 2_048,
                  let calendarID = item["calendarID"] as? String, !calendarID.isEmpty, calendarID.utf8.count <= 256,
                  selection.allows(calendarID),
                  query.calendarIDs.isEmpty || ScriptWidgetCalendarSelection.contains(query.calendarIDs, calendarID),
                  let title = item["title"] as? String, title.utf8.count <= 1_024,
                  let start = item["start"] as? String, let startDate = ISO8601DateFormatter().date(from: start),
                  let end = item["end"] as? String, let endDate = ISO8601DateFormatter().date(from: end),
                  endDate >= startDate, endDate >= query.start, startDate < query.end,
                  let allDay = item["allDay"] as? NSNumber, CFGetTypeID(allDay) == CFBooleanGetTypeID() else { return nil }
        }
        value["source"] = "cache"
        value["stale"] = now.timeIntervalSince1970 - timestamp.doubleValue > 60
        return value
    }
}

struct ScriptWidgetCalendarSource: Identifiable, Sendable {
    let id: String
    var identity: Data { Data(id.utf8) }
    let title: String
}

struct ScriptWidgetCalendarEvent: Sendable {
    let id: String
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    var dictionary: [String: Any] {
        ["id": String(id.prefix(512)), "calendarID": calendarID, "title": String(title.prefix(256)),
         "start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: end), "allDay": allDay]
    }
}

struct ScriptWidgetCalendarProvider {
    var authorizationStatus: () -> String
    var sources: () -> [ScriptWidgetCalendarSource]
    var events: (ScriptWidgetCalendarQuery, [String], ScriptWidgetExecutionSession) throws -> (items: [ScriptWidgetCalendarEvent], truncated: Bool)

    static func system() -> Self {
        #if canImport(EventKit)
        let store = EKEventStore()
        return .init(authorizationStatus: { ScriptWidgetRuntimeCalendar.systemAuthorizationStatus() }, sources: {
            store.calendars(for: .event).compactMap { calendar in
                guard ScriptWidgetCalendarSelection.validIDs([calendar.calendarIdentifier]) else { return nil }
                return .init(id: calendar.calendarIdentifier, title: String(calendar.title.prefix(256)))
            }
        }, events: { query, ids, session in
            let calendars = store.calendars(for: .event).filter { ScriptWidgetCalendarSelection.contains(ids, $0.calendarIdentifier) }
            guard calendars.count == ids.count else { throw ScriptWidgetCalendarSelection.AccessError.outsideSelection }
            var items: [ScriptWidgetCalendarEvent] = [], truncated = false
            if !calendars.isEmpty {
                let predicate = store.predicateForEvents(withStart: query.start, end: query.end, calendars: calendars)
                store.enumerateEvents(matching: predicate) { event, stop in
                    if !session.isActive || items.count >= query.limit {
                        truncated = items.count >= query.limit; stop.pointee = true; return
                    }
                    items.append(.init(id: event.eventIdentifier ?? "", calendarID: event.calendar.calendarIdentifier,
                        title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay))
                }
            }
            return (items, truncated)
        })
        #else
        return .init(authorizationStatus: { "unavailable" }, sources: { [] }, events: { _, _, _ in ([], false) })
        #endif
    }
}

@objc public class ScriptWidgetRuntimeCalendar: NSObject, ScriptWidgetRuntimeCalendarExports {
    private static let queue = DispatchQueue(label: "app.scriptwidget.calendar", qos: .userInitiated)

    static func isAvailable() -> Bool {
        guard JSContext.current()?.scriptWidgetRunningState?.previewStorage == nil else { return false }
        #if canImport(EventKit)
        return true
        #else
        return false
        #endif
    }

    static func authorizationStatus() -> String {
        if JSContext.current()?.scriptWidgetRunningState?.previewStorage != nil { return "unavailable" }
        guard let state = permittedState() else { return "undeclared" }
        return authorizationStatus(for: state)
    }

    static func permittedState() -> ScriptWidgetRunningState? {
        guard let state = JSContext.current()?.scriptWidgetRunningState, state.isCurrentExecution else { return nil }
        guard state.previewStorage == nil else { return nil }
        guard packageAllowsCalendar(state.package) else {
            try? defaults(for: state).removeValue(forKey: cacheKey(state))
            return nil
        }
        return state
    }

    private static func packageAllowsCalendar(_ package: ScriptWidgetPackage) -> Bool {
        guard let manifest = package.readManifest(), manifest.permissions.contains(.calendar) else { return false }
        return WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false).isValid
    }

    static func systemAuthorizationStatus() -> String {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) {
            if status == .fullAccess { return "authorized" }
            if status == .writeOnly { return "writeOnly" }
        }
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        default: return "unavailable"
        }
        #else
        return "unavailable"
        #endif
    }

    private static func cacheKey(_ state: ScriptWidgetRunningState) -> String {
        let identity = Data(state.storageNamespace.utf8)
        return "ScriptWidget.CalendarCache.v1." + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    private static func defaults(for state: ScriptWidgetRunningState) -> any ScriptWidgetStorageBackend {
        #if DEBUG
        if let defaults = state.storageDefaultsForTesting { return defaults }
        #endif
        return state.executionSnapshot?.context.defaults ?? (UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard)
    }

    private static func selection(for state: ScriptWidgetRunningState) throws -> ScriptWidgetCalendarSelection {
        var container = state.executionSnapshot?.context.container ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")
        #if DEBUG
        container = state.storageContainerForTesting ?? container
        #endif
        return try ScriptWidgetCalendarSelection.load(container: container)
    }

    private static func authorizationStatus(for state: ScriptWidgetRunningState) -> String {
        #if DEBUG
        if let provider = state.calendarProviderForTesting { return provider.authorizationStatus() }
        #endif
        return systemAuthorizationStatus()
    }

    private static func provider(for state: ScriptWidgetRunningState) -> ScriptWidgetCalendarProvider {
        #if DEBUG
        if let provider = state.calendarProviderForTesting { return provider }
        #endif
        return .system()
    }

    static func requestAuthorization() -> ScriptWidgetRuntimePromise {
        let state = permittedState()
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state else { reject.call(withArguments: ["[permission_denied] Install this widget and declare calendar in widget.json"]); return }
            guard state.isCurrentExecution else { return }
            if state.isTimelineProjection {
                resolve.call(withArguments: [systemAuthorizationStatus() == "authorized"])
                return
            }
            if systemAuthorizationStatus() != "authorized" { try? defaults(for: state).removeValue(forKey: cacheKey(state)) }
            requestSystemAuthorization { granted, error in
                state.executionSession.callbackQueue.async {
                    guard state.isCurrentExecution else { return }
                    guard packageAllowsCalendar(state.package) else {
                        try? defaults(for: state).removeValue(forKey: cacheKey(state))
                        reject.call(withArguments: ["[permission_denied] Calendar permission was removed from widget.json"]); return
                    }
                    if let error { reject.call(withArguments: [error]) }
                    else { resolve.call(withArguments: [granted]) }
                }
            }
        }
    }

    /// Native settings use this explicit user action outside a script's deadline.
    /// JS callers must pass the package gate above before reaching it.
    static func requestSystemAuthorization(completion: @escaping (Bool, String?) -> Void) {
        #if canImport(EventKit) && !IsWidgetTarget
        DispatchQueue.main.async {
            if systemAuthorizationStatus() == "authorized" { completion(true, nil); return }
            let key: String
            if #available(iOS 17.0, macOS 14.0, *) { key = "NSCalendarsFullAccessUsageDescription" }
            else { key = "NSCalendarsUsageDescription" }
            guard Bundle.main.object(forInfoDictionaryKey: key) as? String != nil else {
                completion(false, "[unavailable] Calendar usage description is missing"); return
            }
            let store = EKEventStore()
            let callback: (Bool, Error?) -> Void = { granted, error in
                store.reset()
                DispatchQueue.main.async { completion(granted, error == nil ? nil : "[authorization_failed] Calendar access could not be requested") }
            }
            if #available(iOS 17.0, macOS 14.0, *) { store.requestFullAccessToEvents(completion: callback) }
            else { store.requestAccess(to: .event, completion: callback) }
        }
        #else
        completion(systemAuthorizationStatus() == "authorized", nil)
        #endif
    }

    static func calendars() -> ScriptWidgetRuntimePromise { read(query: nil, error: nil) }

    static func create(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { ScriptWidgetRuntimeCalendarWrites.mutate(options ?? [:], updating: false) }
    static func update(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { ScriptWidgetRuntimeCalendarWrites.mutate(options ?? [:], updating: true) }
    static func events(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        do { return read(query: try ScriptWidgetCalendarQuery(options), error: nil) }
        catch { return read(query: nil, error: error.localizedDescription) }
    }

    private static func read(query: ScriptWidgetCalendarQuery?, error: String?) -> ScriptWidgetRuntimePromise {
        let state = permittedState()
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state else { reject.call(withArguments: ["[permission_denied] Install this widget and declare calendar in widget.json"]); return }
            if let error { reject.call(withArguments: [error]); return }
            guard state.executionSession.registerDataQuery() else { reject.call(withArguments: ["[query_limit] Too many system data queries"]); return }
            guard isAvailable() else { reject.call(withArguments: ["[unavailable] Calendar is unavailable"]); return }
            guard authorizationStatus(for: state) == "authorized" else {
                try? defaults(for: state).removeValue(forKey: cacheKey(state))
                reject.call(withArguments: ["[permission_denied] Allow calendar access in ScriptWidget"]); return
            }
            let scope: ScriptWidgetCalendarSelection
            do {
                scope = try selection(for: state)
                if query != nil, scope.calendarIDs?.isEmpty == true { throw ScriptWidgetCalendarSelection.AccessError.noneSelected }
            } catch {
                try? defaults(for: state).removeValue(forKey: cacheKey(state))
                reject.call(withArguments: [error.localizedDescription]); return
            }
            if state.isTimelineProjection {
                guard let query, let payload = cachedPayload(query: query, state: state, selection: scope),
                      authorizationStatus(for: state) == "authorized", (try? selection(for: state)) == scope else {
                    reject.call(withArguments: ["[timeline_read_only] No matching Calendar snapshot is available"]); return
                }
                resolve.call(withArguments: [payload]); return
            }
            queue.async {
                guard state.isCurrentExecution else { return }
                do {
                    let provider = provider(for: state)
                    let payload: Any
                    if let query {
                        if let cached = cachedPayload(query: query, state: state, selection: scope) { payload = cached }
                        else {
                            let sources = provider.sources().filter { ScriptWidgetCalendarSelection.validIDs([$0.id]) }
                            let ids = try scope.permittedIDs(available: sources.map(\.id), requested: query.calendarIDs)
                            let result = try provider.events(query, ids, state.executionSession)
                            let selected = Set(ids.map { Data($0.utf8) })
                            let matching = result.items.filter { selected.contains(Data($0.calendarID.utf8)) && $0.end >= $0.start && $0.end >= query.start && $0.start < query.end }
                                .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                            let items = matching.prefix(query.limit).map(\.dictionary)
                            let value: [String: Any] = ["status": items.isEmpty ? "empty" : "ready", "items": items,
                                "fetchedAt": isoString(Date()), "source": "system", "stale": false,
                                "truncated": result.truncated || matching.count > query.limit]
                            payload = value
                            if state.isCurrentExecution, authorizationStatus(for: state) == "authorized", (try? selection(for: state)) == scope,
                               let data = try? JSONSerialization.data(withJSONObject: ["query": query.cacheIdentity, "selection": scope.identity,
                                   "timestamp": Date().timeIntervalSince1970, "value": value]), data.count <= ScriptWidgetCalendarCache.maximumBytes {
                                try? defaults(for: state).writeValue(data, forKey: cacheKey(state))
                            }
                        }
                    } else {
                        var seen = Set<Data>()
                        payload = Array(provider.sources().filter { scope.allows($0.id) && ScriptWidgetCalendarSelection.validIDs([$0.id]) && seen.insert(Data($0.id.utf8)).inserted }
                            .prefix(64)).map { ["id": $0.id, "title": String($0.title.prefix(256))] }
                    }
                    state.executionSession.callbackQueue.async {
                        guard state.isCurrentExecution else { return }
                        guard packageAllowsCalendar(state.package), authorizationStatus(for: state) == "authorized" else {
                            try? defaults(for: state).removeValue(forKey: cacheKey(state))
                            reject.call(withArguments: ["[permission_denied] Calendar access was revoked"]); return
                        }
                        guard (try? selection(for: state)) == scope else {
                            try? defaults(for: state).removeValue(forKey: cacheKey(state))
                            reject.call(withArguments: [ScriptWidgetCalendarSelection.AccessError.changed.localizedDescription]); return
                        }
                        resolve.call(withArguments: [payload])
                    }
                } catch {
                    let message = (error as? ScriptWidgetCalendarSelection.AccessError)?.localizedDescription ?? "[query_failed] Calendar data could not be loaded"
                    state.executionSession.callbackQueue.async { if state.isCurrentExecution { reject.call(withArguments: [message]) } }
                }
            }
        }
    }

    private static func cachedPayload(query: ScriptWidgetCalendarQuery, state: ScriptWidgetRunningState, selection: ScriptWidgetCalendarSelection) -> [String: Any]? {
        guard let data = (try? defaults(for: state).readValue(forKey: cacheKey(state))) as? Data else { return nil }
        let payload = ScriptWidgetCalendarCache.decode(data, query: query, selection: selection)
        if payload == nil {
            let record = data.count <= ScriptWidgetCalendarCache.maximumBytes ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
            let legacyAll = selection == .all && record.map { Set($0.keys) == ["query", "timestamp", "value"] } == true
            // A different query window must not erase the current entry's
            // snapshot. A revoked/native scope mismatch is discarded instead.
            if !legacyAll && record?["selection"] as? String != selection.identity {
                try? defaults(for: state).removeValue(forKey: cacheKey(state))
            }
        }
        return payload
    }

    private static func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}


#if !IsWidgetTarget
import SwiftUI
import WidgetKit
#if os(iOS)
import UIKit
#endif

@MainActor
final class ScriptWidgetCalendarSourcesModel: ObservableObject {
    @Published private(set) var sources: [ScriptWidgetCalendarSource] = []
    @Published private(set) var loading = false
    @Published var useAll = true
    @Published var selectedIDs: [String] = []
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    private var original: ScriptWidgetCalendarSelection?
    let kind: ScriptWidgetEventSourceKind
    private let container: URL?
    private let authorization: () -> String
    private let loadSources: @Sendable () -> [ScriptWidgetCalendarSource]
    private let onSaved: () -> Void

    init(kind: ScriptWidgetEventSourceKind = .calendar, container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget"),
         authorization: (() -> String)? = nil,
         loadSources: (@Sendable () -> [ScriptWidgetCalendarSource])? = nil,
         onSaved: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.kind = kind; self.container = container; self.onSaved = onSaved
        self.authorization = authorization ?? { kind == .calendar ? ScriptWidgetRuntimeCalendar.systemAuthorizationStatus() : ScriptWidgetRuntimeReminders.systemAuthorizationStatus() }
        self.loadSources = loadSources ?? { kind == .calendar ? ScriptWidgetCalendarProvider.system().sources() : ScriptWidgetRemindersSystemProvider().sources() }
    }
    var draft: ScriptWidgetCalendarSelection { .init(calendarIDs: useAll ? nil : Array(selectedIDs)) }
    var hasChanges: Bool { original != draft }
    var missingSelectionCount: Int { selectedIDs.filter { !ScriptWidgetCalendarSelection.contains(sources.map(\.id), $0) }.count }
    func isSelected(_ id: String) -> Bool { ScriptWidgetCalendarSelection.contains(selectedIDs, id) }
    func removeUnavailableSelections() { selectedIDs = selectedIDs.filter { ScriptWidgetCalendarSelection.contains(sources.map(\.id), $0) } }

    func reload(discardDraft: Bool = false) async {
        guard !loading else { return }
        guard authorization() == "authorized" else { sources = []; return }
        let keepDraft = original != nil && hasChanges && !discardDraft
        loading = true; defer { loading = false }
        message = nil; isError = false
        if !keepDraft {
            do {
                original = try ScriptWidgetCalendarSelection.load(container: container, kind: kind)
                useAll = original?.calendarIDs == nil; selectedIDs = original?.calendarIDs ?? []
            } catch {
                original = nil; useAll = false; selectedIDs = []
                message = "\(kind.label) settings are unavailable. Choose sources and save to replace these settings."; isError = true
            }
        }
        let loader = loadSources
        let loaded = await Task.detached { loader() }.value
        guard authorization() == "authorized" else { sources = []; return }
        var seen = Set<Data>()
        sources = loaded.filter { ScriptWidgetCalendarSelection.validIDs([$0.id]) && seen.insert(Data($0.id.utf8)).inserted }
            .sorted { ($0.title.localizedStandardCompare($1.title) == .orderedSame) ? ScriptWidgetCalendarSelection.orderedID($0.id, $1.id) : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func select(_ id: String, enabled: Bool) {
        guard !loading, sources.contains(where: { ScriptWidgetCalendarSelection.sameID($0.id, id) }), enabled == false || selectedIDs.count < ScriptWidgetCalendarSelection.maximumIDs else { return }
        if enabled { if !isSelected(id) { selectedIDs.append(id) } } else { selectedIDs.removeAll { ScriptWidgetCalendarSelection.sameID($0, id) } }
    }

    func save() {
        guard !loading, authorization() == "authorized" else { message = "Allow access before saving sources."; isError = true; return }
        do {
            try draft.save(container: container, replacing: original, repairingUnreadable: original == nil, kind: kind)
            original = draft; isError = false
            message = "\(kind.label) saved. Widget updates are scheduled by the system."
            onSaved()
        } catch {
            isError = true
            if case ScriptWidgetCalendarSelection.AccessError.changed = error { message = "\(kind.label) changed elsewhere. Reload before saving." }
            else { message = "\(kind.label) could not be saved. Reload and try again." }
        }
    }
}

@MainActor
struct CalendarSourcesSettingsView: View {
    @ObservedObject var model: ScriptWidgetCalendarSourcesModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.kind == .calendar ? "Sources available to widgets" : "Reminder lists available to widgets").font(.subheadline.bold())
            Toggle("All \(model.kind.plural), including newly added ones", isOn: $model.useAll)
                .disabled(model.loading)
            if !model.useAll {
                if model.sources.isEmpty { Text(model.loading ? "Loading sources…" : "No sources are available.").font(.footnote).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.sources, id: \.identity) { source in
                            Toggle(source.title.isEmpty ? "Untitled source" : source.title, isOn: Binding(
                                get: { model.isSelected(source.id) }, set: { model.select(source.id, enabled: $0) }))
                                .lineLimit(3)
                                .disabled(model.loading || (!model.isSelected(source.id) && model.selectedIDs.count >= ScriptWidgetCalendarSelection.maximumIDs))
                        }
                    }
                }
                .frame(height: min(240, max(48, CGFloat(model.sources.count) * 48)))
                Text(model.selectedIDs.isEmpty ? "No sources selected. Event queries will be blocked." : "\(model.selectedIDs.count) selected (up to 64). Individual widgets may request a smaller selection.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.missingSelectionCount > 0 {
                    Text("\(model.missingSelectionCount) saved sources are currently unavailable.").font(.footnote).foregroundStyle(.secondary)
                    Button("Remove Unavailable Selections") { model.removeUnavailableSelections() }
                        .disabled(model.loading)
                }
            }
            HStack {
                Button("Reload Sources") { Task { await model.reload(discardDraft: true) } }.disabled(model.loading)
                Button(model.kind == .calendar ? "Save Calendar Sources" : "Save Reminder Lists") { model.save() }.disabled(model.loading || !model.hasChanges)
            }
            if let message = model.message { Text(message).font(.footnote).foregroundStyle(model.isError ? .red : .secondary) }
        }
    }
}

@MainActor
struct CalendarAccessSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: String
    @State private var requesting = false
    @State private var errorMessage: String?
    @StateObject private var sourcesModel: ScriptWidgetCalendarSourcesModel

    init(initialStatus: String? = nil, sourcesModel: ScriptWidgetCalendarSourcesModel? = nil) {
        _status = State(initialValue: initialStatus ?? ScriptWidgetRuntimeCalendar.systemAuthorizationStatus())
        _sourcesModel = StateObject(wrappedValue: sourcesModel ?? ScriptWidgetCalendarSourcesModel())
    }

    private var connected: Bool { status == "authorized" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(connected ? "Calendar Connected" : "Connect Calendar", systemImage: connected ? "checkmark.circle" : "calendar.badge.clock")
                .font(.headline)
            Text(connected
                 ? "Calendar widgets can read events. Each package must also declare Calendar access. ScriptWidget does not expose event editing."
                 : "Allow access to display real events. Apple requires full Calendar permission to read events; ScriptWidget uses it only for reading.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !connected {
                Button(requesting ? "Requesting Access…" : "Allow Calendar Access") {
                    requesting = true
                    errorMessage = nil
                    ScriptWidgetRuntimeCalendar.requestSystemAuthorization { _, error in
                        requesting = false
                        status = ScriptWidgetRuntimeCalendar.systemAuthorizationStatus()
                        errorMessage = error
                        if connected { WidgetCenter.shared.reloadAllTimelines(); Task { await sourcesModel.reload() } }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(requesting || status == "unavailable" || status == "restricted")
            } else {
                CalendarSourcesSettingsView(model: sourcesModel)
                Button("Refresh Calendar Widgets") { WidgetCenter.shared.reloadAllTimelines() }
                    .buttonStyle(.bordered)
            }
            if status == "denied" || status == "writeOnly" || status == "restricted" {
                Text("Review Calendar access in system privacy settings, then return here.")
                    .font(.footnote).foregroundStyle(.secondary)
                #if os(iOS)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                #endif
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
        .task(id: scenePhase) {
            if scenePhase == .active {
                status = ScriptWidgetRuntimeCalendar.systemAuthorizationStatus()
                if connected { await sourcesModel.reload() }
            }
        }
    }
}

struct CalendarAccessPresentationModifier: ViewModifier {
    @State private var showingAccess = false
    @State private var showingReminders = false
    @State private var showingPhotos = false

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                if url.scheme == "scriptwidget", url.host == "calendar-access" { showingAccess = true }
                if url.scheme == "scriptwidget", url.host == "reminders-access" { showingReminders = true }
                if url.scheme == "scriptwidget", url.host == "photos-access" { showingPhotos = true }
            }
            .sheet(isPresented: $showingAccess) {
                CalendarAccessSheet()
            }
            .sheet(isPresented: $showingReminders) { RemindersAccessSheet() }
            .sheet(isPresented: $showingPhotos) { PhotosAccessSheet() }
    }
}

private struct CalendarAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { Section("Calendar") { CalendarAccessSettingsView() } }
                .navigationTitle("Data Access")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 300)
        #endif
    }
}

#endif
