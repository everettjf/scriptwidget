import Foundation
import CoreFoundation
import JavaScriptCore
import CryptoKit
import EventKit

@objc protocol ScriptWidgetRuntimeRemindersExports: JSExport {
    static func isAvailable() -> Bool
    static func authorizationStatus() -> String
    static func requestAuthorization() -> ScriptWidgetRuntimePromise
    static func lists() -> ScriptWidgetRuntimePromise
    static func items(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func create(_ options: [String: Any]) -> ScriptWidgetRuntimePromise
    static func update(_ options: [String: Any]) -> ScriptWidgetRuntimePromise
    static func setCompleted(_ options: [String: Any]) -> ScriptWidgetRuntimePromise
}

struct ScriptWidgetRemindersQuery {
    let window: ScriptWidgetCalendarQuery
    let completed: Bool
    let timeZone: TimeZone
    init(_ options: [String: Any]?, now: Date = Date(), calendar: Calendar = .current) throws {
        timeZone = calendar.timeZone
        var options = options ?? [:]
        guard Set(options.keys).isSubset(of: ["start", "end", "limit", "listIDs", "maxAgeSeconds", "completed"]) else { throw ScriptWidgetRemindersError.invalid("Unknown reminder query option") }
        if let value = options.removeValue(forKey: "completed") {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ScriptWidgetRemindersError.invalid("completed must be a Boolean") }
            completed = number.boolValue
        } else { completed = false }
        if let ids = options.removeValue(forKey: "listIDs") { options["calendarIDs"] = ids }
        do { window = try ScriptWidgetCalendarQuery(options, now: now, calendar: calendar) }
        catch { throw ScriptWidgetRemindersError.invalid(error.localizedDescription.replacingOccurrences(of: "calendarIDs", with: "listIDs").replacingOccurrences(of: "Calendar", with: "Reminder")) }
    }
    var identity: String { SHA256.hash(data: Data((window.cacheIdentity + (completed ? ":completed:" : ":pending:") + timeZone.identifier).utf8)).map { String(format: "%02x", $0) }.joined() }
}

enum ScriptWidgetRemindersError: LocalizedError {
    case invalid(String), denied, noneSelected, unavailable, queryFailed, scopeChanged
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message.hasPrefix("[invalid_options]") ? message : "[invalid_options] " + message
        case .denied: return "[permission_denied] Allow Reminders access and select lists in ScriptWidget Settings"
        case .noneSelected: return "[permission_denied] No Reminder lists are selected in ScriptWidget Settings"
        case .unavailable: return "[unavailable] Reminder lists are unavailable"
        case .queryFailed: return "[query_failed] Reminders could not be loaded"
        case .scopeChanged: return "[permission_denied] Reminder list selection changed. Run the widget again."
        }
    }
}

struct ScriptWidgetReminderItem: Sendable {
    let id: String
    let listID: String
    let title: String
    let due: String?
    let hasTime: Bool
    let completed: Bool
    let completedAt: String?
    let priority: Int
    var dictionary: [String: Any] {
        ["id": id, "listID": listID, "title": title, "due": due as Any? ?? NSNull(), "hasTime": hasTime,
         "completed": completed, "completedAt": completedAt as Any? ?? NSNull(), "priority": priority]
    }
    static func isoDate(_ text: String) -> Date? {
        guard text.utf8.count <= 64, text.contains("T") else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: text) ?? fractional.date(from: text)
    }
    static func day(_ text: String, timeZone: TimeZone = .current) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard parts.count == 3, let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: value) == parts[0], calendar.component(.month, from: value) == parts[1], calendar.component(.day, from: value) == parts[2] else { return nil }
        return value
    }
    static func dueValue(_ components: DateComponents?) -> (text: String?, hasTime: Bool) {
        guard var components, let year = components.year, let month = components.month, let day = components.day,
              (1...9999).contains(year) else { return (nil, false) }
        let text = String(format: "%04d-%02d-%02d", year, month, day)
        guard Self.day(text) != nil else { return (nil, false) }
        let hasTime = components.hour != nil || components.minute != nil || components.second != nil
        if !hasTime { return (text, false) }
        guard (0...23).contains(components.hour ?? 0), (0...59).contains(components.minute ?? 0), (0...59).contains(components.second ?? 0) else { return (nil, true) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = components.timeZone ?? .current
        components.calendar = calendar
        guard let value = calendar.date(from: components), calendar.component(.hour, from: value) == (components.hour ?? 0),
              calendar.component(.minute, from: value) == (components.minute ?? 0) else { return (nil, true) }
        return (ISO8601DateFormatter().string(from: value), true)
    }
    func matches(_ query: ScriptWidgetRemindersQuery, selection: ScriptWidgetCalendarSelection) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 2048, title.utf8.count <= 1024, ScriptWidgetCalendarSelection.validIDs([listID]),
              selection.allows(listID), query.window.calendarIDs.isEmpty || ScriptWidgetCalendarSelection.contains(query.window.calendarIDs, listID),
              completed == query.completed, (0...9).contains(priority) else { return false }
        if let due {
            guard hasTime ? Self.isoDate(due) != nil : Self.day(due) != nil else { return false }
        } else if hasTime { return false }
        if completed {
            guard let completedAt, let date = Self.isoDate(completedAt) else { return false }
            return date >= query.window.start && date < query.window.end
        }
        guard completedAt == nil, let due else { return false }
        if hasTime, let date = Self.isoDate(due) { return date >= query.window.start && date < query.window.end }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = query.timeZone
        guard let date = Self.day(due, timeZone: query.timeZone), let end = calendar.date(byAdding: .day, value: 1, to: date) else { return false }
        return date < query.window.end && end > query.window.start
    }
}

protocol ScriptWidgetRemindersProviding: AnyObject {
    func mutate(_ request: ScriptWidgetReminderMutation, beforeCommit: () throws -> Void) throws -> String
    func authorizationStatus() -> String
    func sources() -> [ScriptWidgetCalendarSource]
    func fetch(_ query: ScriptWidgetRemindersQuery, ids: [String], session: ScriptWidgetExecutionSession,
               completion: @escaping (Result<(items: [ScriptWidgetReminderItem], truncated: Bool), Error>) -> Void)
}

extension ScriptWidgetRemindersProviding {
    func mutate(_ request: ScriptWidgetReminderMutation, beforeCommit: () throws -> Void) throws -> String {
        throw ScriptWidgetRemindersError.unavailable
    }
}

final class ScriptWidgetRemindersSystemProvider: ScriptWidgetRemindersProviding {
    private let store = EKEventStore()
    func authorizationStatus() -> String { ScriptWidgetRuntimeReminders.systemAuthorizationStatus() }
    func sources() -> [ScriptWidgetCalendarSource] {
        store.calendars(for: .reminder).compactMap {
            ScriptWidgetCalendarSelection.validIDs([$0.calendarIdentifier]) ? .init(id: $0.calendarIdentifier, title: String($0.title.prefix(256))) : nil
        }
    }
    func mutate(_ request: ScriptWidgetReminderMutation, beforeCommit: () throws -> Void) throws -> String {
        guard authorizationStatus() == "authorized",
              let list = store.calendar(withIdentifier: request.listID), list.allowedEntityTypes.contains(.reminder),
              list.allowsContentModifications else { throw ScriptWidgetRemindersError.denied }
        let reminder: EKReminder
        if request.kind == .create { reminder = EKReminder(eventStore: store); reminder.calendar = list }
        else {
            guard let id = request.id, let existing = store.calendarItem(withIdentifier: id) as? EKReminder,
                  ScriptWidgetCalendarSelection.sameID(existing.calendar.calendarIdentifier, request.listID) else {
                throw ScriptWidgetRemindersError.invalid("The reminder is unavailable in the selected list")
            }
            reminder = existing
        }
        if let title = request.title { reminder.title = title }
        if let priority = request.priority { reminder.priority = priority }
        if request.changesDue {
            if let due = request.due {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
                if let day = ScriptWidgetReminderItem.day(due) {
                    reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: day)
                } else if let date = ScriptWidgetReminderItem.isoDate(due) {
                    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    components.timeZone = calendar.timeZone; reminder.dueDateComponents = components
                }
            } else { reminder.dueDateComponents = nil }
        }
        if let completed = request.completed { reminder.isCompleted = completed }
        // No EventKit mutation is persisted before the durable replay marker and
        // the final cancellation, ownership, permission and scope checks.
        try beforeCommit()
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
    func fetch(_ query: ScriptWidgetRemindersQuery, ids: [String], session: ScriptWidgetExecutionSession,
               completion: @escaping (Result<(items: [ScriptWidgetReminderItem], truncated: Bool), Error>) -> Void) {
        let allowed = Set(ids.map { Data($0.utf8) })
        let lists = store.calendars(for: .reminder).filter { allowed.contains(Data($0.calendarIdentifier.utf8)) }
        guard lists.count == ids.count else { completion(.failure(ScriptWidgetRemindersError.invalid("A selected list is unavailable"))); return }
        guard !lists.isEmpty else { completion(.success(([], false))); return }
        let predicate = query.completed
            ? store.predicateForCompletedReminders(withCompletionDateStarting: query.window.start, ending: query.window.end, calendars: lists)
            : store.predicateForIncompleteReminders(withDueDateStarting: query.window.start, ending: query.window.end, calendars: lists)
        let cancellation = ScriptWidgetQueryCancellation(session: session)
        let token = store.fetchReminders(matching: predicate) { [self] reminders in
            cancellation.complete()
            guard session.isActive else { return }
            guard let reminders else { completion(.failure(ScriptWidgetRemindersError.queryFailed)); return }
            var items: [ScriptWidgetReminderItem] = [], scanned = 0
            for reminder in reminders {
                guard session.isActive else { return }
                if scanned >= 1000 { break }
                scanned += 1
                guard reminder.priority <= 9, !reminder.calendarItemIdentifier.isEmpty, reminder.calendarItemIdentifier.utf8.count <= 2048 else { continue }
                let due = ScriptWidgetReminderItem.dueValue(reminder.dueDateComponents)
                let item = ScriptWidgetReminderItem(id: reminder.calendarItemIdentifier, listID: reminder.calendar.calendarIdentifier,
                    title: String((reminder.title ?? "").prefix(256)), due: due.text, hasTime: due.hasTime, completed: reminder.isCompleted,
                    completedAt: reminder.completionDate.map { ISO8601DateFormatter().string(from: $0) }, priority: Int(reminder.priority))
                guard allowed.contains(Data(item.listID.utf8)), item.matches(query, selection: .all) else { continue }
                items.append(item)
            }
            withExtendedLifetime(store) { completion(.success((items, scanned < reminders.count))) }
        }
        guard cancellation.install({ [store] in store.cancelFetchRequest(token) }) else {
            store.cancelFetchRequest(token); return
        }
        if !session.isActive { store.cancelFetchRequest(token); cancellation.complete() }
    }
}

enum ScriptWidgetRemindersCache {
    static let maximumBytes = 64 * 1024
    static func decode(_ data: Data, query: ScriptWidgetRemindersQuery, selection: ScriptWidgetCalendarSelection, now: Date = Date()) -> [String: Any]? {
        guard query.window.maxAgeSeconds > 0, selection.calendarIDs?.isEmpty != true, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["query", "selection", "timestamp", "value"], object["query"] as? String == query.identity,
              object["selection"] as? String == selection.identity,
              let time = object["timestamp"] as? NSNumber, CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue.isFinite,
              time.doubleValue <= now.timeIntervalSince1970, now.timeIntervalSince1970 - time.doubleValue <= query.window.maxAgeSeconds,
              var value = object["value"] as? [String: Any], Set(value.keys) == ["status", "items", "fetchedAt", "source", "stale", "truncated"],
              let items = value["items"] as? [[String: Any]], items.count <= query.window.limit,
              value["status"] as? String == (items.isEmpty ? "empty" : "ready"), value["source"] as? String == "system",
              let fetched = value["fetchedAt"] as? String, ScriptWidgetReminderItem.isoDate(fetched) != nil,
              boolean(value["stale"]) != nil, boolean(value["truncated"]) != nil else { return nil }
        for row in items {
            guard Set(row.keys) == ["id", "listID", "title", "due", "hasTime", "completed", "completedAt", "priority"],
                  let id = row["id"] as? String, let listID = row["listID"] as? String, let title = row["title"] as? String,
                  let hasTime = boolean(row["hasTime"]), let completed = boolean(row["completed"]),
                  let priority = row["priority"] as? NSNumber, CFGetTypeID(priority) != CFBooleanGetTypeID(), priority.doubleValue.isFinite,
                  priority.doubleValue >= 0, priority.doubleValue <= 9, priority.doubleValue.rounded() == priority.doubleValue,
                  row["due"] is NSNull || row["due"] is String, row["completedAt"] is NSNull || row["completedAt"] is String else { return nil }
            let item = ScriptWidgetReminderItem(id: id, listID: listID, title: title, due: row["due"] as? String, hasTime: hasTime,
                completed: completed, completedAt: row["completedAt"] as? String, priority: priority.intValue)
            guard item.matches(query, selection: selection) else { return nil }
        }
        value["source"] = "cache"; value["stale"] = now.timeIntervalSince1970 - time.doubleValue > 60
        return value
    }
    private static func boolean(_ raw: Any?) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
    }
}

@objc public class ScriptWidgetRuntimeReminders: NSObject, ScriptWidgetRuntimeRemindersExports {
    private static let queue = DispatchQueue(label: "app.scriptwidget.reminders", qos: .userInitiated)
    static func isAvailable() -> Bool { JSContext.current()?.scriptWidgetRunningState?.previewStorage == nil }
    static func systemAuthorizationStatus() -> String {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, macOS 14.0, *), status == .fullAccess { return "authorized" }
        switch status { case .authorized: return "authorized"; case .denied: return "denied"; case .restricted: return "restricted"; case .notDetermined: return "notDetermined"; default: return "unavailable" }
    }
    private static func permitted(_ state: ScriptWidgetRunningState) -> Bool {
        guard state.previewStorage == nil, let manifest = state.package.readManifest(), manifest.permissions.contains(.reminders) else { return false }
        return WidgetPackageManifestValidator.validate(manifest, package: state.package, checkEntryExists: false).isValid
    }
    private static func defaults(_ state: ScriptWidgetRunningState) -> any ScriptWidgetStorageBackend {
        #if DEBUG
        if let defaults = state.storageDefaultsForTesting { return defaults }
        #endif
        return state.executionSnapshot?.context.defaults ?? (UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard)
    }
    private static func key(_ state: ScriptWidgetRunningState) -> String {
        "ScriptWidget.RemindersCache.v1." + SHA256.hash(data: Data(state.storageNamespace.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func scope(_ state: ScriptWidgetRunningState) throws -> ScriptWidgetCalendarSelection {
        var container = state.executionSnapshot?.context.container ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")
        #if DEBUG
        container = state.storageContainerForTesting ?? container
        #endif
        return try ScriptWidgetCalendarSelection.load(container: container, kind: .reminders)
    }
    private static func status(_ state: ScriptWidgetRunningState) -> String {
        #if DEBUG
        if let provider = state.remindersProviderForTesting { return provider.authorizationStatus() }
        #endif
        return systemAuthorizationStatus()
    }
    private static func provider(_ state: ScriptWidgetRunningState) -> any ScriptWidgetRemindersProviding {
        #if DEBUG
        if let provider = state.remindersProviderForTesting { return provider }
        #endif
        return ScriptWidgetRemindersSystemProvider()
    }
    static func authorizationStatus() -> String {
        guard let state = JSContext.current()?.scriptWidgetRunningState, state.isCurrentExecution, permitted(state) else { return "undeclared" }
        return status(state)
    }
    static func requestAuthorization() -> ScriptWidgetRuntimePromise {
        let state = JSContext.current()?.scriptWidgetRunningState
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state, state.isCurrentExecution, permitted(state) else { reject.call(withArguments: [ScriptWidgetRemindersError.denied.localizedDescription]); return }
            if state.isTimelineProjection || state.isLiveActivityPresentation { resolve.call(withArguments: [status(state) == "authorized"]); return }
            requestSystemAuthorization { granted, error in
                state.executionSession.callbackQueue.async {
                    guard state.isCurrentExecution else { return }
                    guard permitted(state) else { reject.call(withArguments: [ScriptWidgetRemindersError.denied.localizedDescription]); return }
                    if !granted { try? defaults(state).removeValue(forKey: key(state)) }
                    if let error { reject.call(withArguments: [error]) } else { resolve.call(withArguments: [granted]) }
                }
            }
        }
    }
    static func requestSystemAuthorization(completion: @escaping (Bool, String?) -> Void) {
        #if !IsWidgetTarget
        DispatchQueue.main.async {
            if systemAuthorizationStatus() == "authorized" { completion(true, nil); return }
            let key: String
            if #available(iOS 17.0, macOS 14.0, *) { key = "NSRemindersFullAccessUsageDescription" } else { key = "NSRemindersUsageDescription" }
            guard Bundle.main.object(forInfoDictionaryKey: key) as? String != nil else { completion(false, "Reminders usage description is missing"); return }
            let store = EKEventStore()
            let callback: (Bool, Error?) -> Void = { granted, error in
                store.reset(); DispatchQueue.main.async { completion(granted, error == nil ? nil : "Reminders access could not be requested") }
            }
            if #available(iOS 17.0, macOS 14.0, *) { store.requestFullAccessToReminders(completion: callback) }
            else { store.requestAccess(to: .reminder, completion: callback) }
        }
        #else
        completion(systemAuthorizationStatus() == "authorized", nil)
        #endif
    }
    static func lists() -> ScriptWidgetRuntimePromise { read(nil, error: nil) }
    static func items(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        do { return read(try ScriptWidgetRemindersQuery(options), error: nil) } catch { return read(nil, error: error.localizedDescription) }
    }
    static func create(_ options: [String: Any]) -> ScriptWidgetRuntimePromise { mutate(.create, options) }
    static func update(_ options: [String: Any]) -> ScriptWidgetRuntimePromise { mutate(.update, options) }
    static func setCompleted(_ options: [String: Any]) -> ScriptWidgetRuntimePromise { mutate(.setCompleted, options) }
    private static func mutate(_ kind: ScriptWidgetReminderMutation.Kind, _ options: [String: Any]) -> ScriptWidgetRuntimePromise {
        let state = JSContext.current()?.scriptWidgetRunningState
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state, let snapshot = state.executionSnapshot,
                  ScriptWidgetReminderMutation.permitsAction(state), permitted(state),
                  state.package.readManifest()?.permissions.contains(.remindersWrite) == true else {
                reject.call(withArguments: ["[permission_denied] Declare reminders and remindersWrite and invoke a declared native action"]); return
            }
            let request: ScriptWidgetReminderMutation
            do { request = try ScriptWidgetReminderMutation(kind: kind, options: options) }
            catch { reject.call(withArguments: [error.localizedDescription]); return }
            guard state.executionSession.registerDataQuery() else { reject.call(withArguments: ["[query_limit] Too many system data operations"]); return }
            queue.async {
                do {
                    func validate() throws {
                        guard ScriptWidgetReminderMutation.permitsAction(state), permitted(state),
                              state.package.readManifest()?.permissions.contains(.remindersWrite) == true,
                              status(state) == "authorized" else { throw ScriptWidgetRemindersError.denied }
                    }
                    try validate()
                    let selection = try scope(state)
                    guard selection.allows(request.listID) else { throw ScriptWidgetRemindersError.noneSelected }
                    let container = snapshot.context.container
                    let result = try selection.withStableAccess(container: container, kind: .reminders) {
                        let source = provider(state)
                        guard source.sources().contains(where: { ScriptWidgetCalendarSelection.sameID($0.id, request.listID) }) else {
                            throw ScriptWidgetRemindersError.invalid("The selected reminder list is unavailable")
                        }
                        let ledgerKey = "ScriptWidget.RemindersWrites.v1." + SHA256.hash(data: Data(state.storageNamespace.utf8)).map { String(format: "%02x", $0) }.joined()
                        let value = try ScriptWidgetReminderMutationLedger.perform(request, container: container,
                            backend: snapshot.context.defaults, key: ledgerKey, validate: validate) { beforeCommit in
                            try source.mutate(request, beforeCommit: beforeCommit)
                        }
                        try? snapshot.context.defaults.removeValue(forKey: key(state))
                        return value
                    }
                    state.executionSession.callbackQueue.async {
                        guard state.isCurrentExecution else { return }
                        do {
                            try validate()
                            guard try scope(state) == selection else { throw ScriptWidgetRemindersError.scopeChanged }
                            resolve.call(withArguments: [result])
                        } catch { reject.call(withArguments: [error.localizedDescription]) }
                    }
                } catch {
                    let message: String
                    if let known = error as? ScriptWidgetReminderMutationLedger.Failure { message = known.localizedDescription }
                    else if let known = error as? ScriptWidgetRemindersError { message = known.localizedDescription }
                    else { message = "[write_failed] The reminder write could not be confirmed. Inspect Reminders before retrying." }
                    state.executionSession.callbackQueue.async { if state.isCurrentExecution { reject.call(withArguments: [message]) } }
                }
            }
        }
    }
    private static func cached(_ query: ScriptWidgetRemindersQuery, _ state: ScriptWidgetRunningState, _ selection: ScriptWidgetCalendarSelection) -> [String: Any]? {
        guard let data = (try? defaults(state).readValue(forKey: key(state))) as? Data else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["selection"] as? String != selection.identity {
            try? defaults(state).removeValue(forKey: key(state)); return nil
        }
        return ScriptWidgetRemindersCache.decode(data, query: query, selection: selection)
    }
    private static func read(_ query: ScriptWidgetRemindersQuery?, error: String?) -> ScriptWidgetRuntimePromise {
        let state = JSContext.current()?.scriptWidgetRunningState
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state, state.isCurrentExecution, permitted(state) else { reject.call(withArguments: [ScriptWidgetRemindersError.denied.localizedDescription]); return }
            if let error { reject.call(withArguments: [error]); return }
            guard state.executionSession.registerDataQuery() else { reject.call(withArguments: ["[query_limit] Too many system data queries"]); return }
            guard status(state) == "authorized" else { try? defaults(state).removeValue(forKey: key(state)); reject.call(withArguments: [ScriptWidgetRemindersError.denied.localizedDescription]); return }
            let selection: ScriptWidgetCalendarSelection
            do {
                selection = try scope(state)
                if query != nil, selection.calendarIDs?.isEmpty == true { throw ScriptWidgetRemindersError.noneSelected }
            } catch { try? defaults(state).removeValue(forKey: key(state)); reject.call(withArguments: [(error as? ScriptWidgetRemindersError)?.localizedDescription ?? ScriptWidgetRemindersError.denied.localizedDescription]); return }
            func deliver(_ payload: Any) {
                state.executionSession.callbackQueue.async {
                    guard state.isCurrentExecution else { return }
                    guard permitted(state), status(state) == "authorized", (try? scope(state)) == selection else {
                        try? defaults(state).removeValue(forKey: key(state)); reject.call(withArguments: [ScriptWidgetRemindersError.scopeChanged.localizedDescription]); return
                    }
                    resolve.call(withArguments: [payload])
                }
            }
            if state.isTimelineProjection || state.isLiveActivityPresentation {
                guard let query, let value = cached(query, state, selection) else { reject.call(withArguments: ["[snapshot_required] Open ScriptWidget to refresh this reminder snapshot"]); return }
                deliver(value); return
            }
            queue.async {
                guard state.isCurrentExecution else { return }
                let source = provider(state)
                if query == nil {
                    var seen = Set<Data>()
                    deliver(Array(source.sources().filter { selection.allows($0.id) && ScriptWidgetCalendarSelection.validIDs([$0.id]) && seen.insert($0.identity).inserted }.prefix(64)).map { ["id": $0.id, "title": String($0.title.prefix(256))] }); return
                }
                let query = query!
                if let value = cached(query, state, selection) { deliver(value); return }
                let ids: [String]
                do { ids = try selection.permittedIDs(available: source.sources().map(\.id), requested: query.window.calendarIDs) }
                catch { state.executionSession.callbackQueue.async { if state.isCurrentExecution { reject.call(withArguments: ["[invalid_options] A requested reminder list is unavailable or outside your selection"]) } }; return }
                source.fetch(query, ids: ids, session: state.executionSession) { result in
                    guard state.isCurrentExecution else { return }
                    switch result {
                    case .failure:
                        state.executionSession.callbackQueue.async { if state.isCurrentExecution { reject.call(withArguments: [ScriptWidgetRemindersError.queryFailed.localizedDescription]) } }
                    case .success(let result):
                        let allowed = Set(ids.map { Data($0.utf8) })
                        let items = result.items.filter { allowed.contains(Data($0.listID.utf8)) && $0.matches(query, selection: selection) }
                            .sorted { ($0.completedAt ?? $0.due ?? "", $0.id) < ($1.completedAt ?? $1.due ?? "", $1.id) }
                        let value: [String: Any] = ["status": items.isEmpty ? "empty" : "ready", "items": Array(items.prefix(query.window.limit)).map(\.dictionary),
                            "fetchedAt": ISO8601DateFormatter().string(from: Date()), "source": "system", "stale": false, "truncated": result.truncated || items.count > query.window.limit]
                        if state.isCurrentExecution, permitted(state), status(state) == "authorized", (try? scope(state)) == selection,
                           let data = try? JSONSerialization.data(withJSONObject: ["query": query.identity, "selection": selection.identity, "timestamp": Date().timeIntervalSince1970, "value": value]), data.count <= ScriptWidgetRemindersCache.maximumBytes {
                            try? defaults(state).writeValue(data, forKey: key(state))
                        }
                        deliver(value)
                    }
                }
            }
        }
    }
}

#if !IsWidgetTarget
import SwiftUI
import WidgetKit

@MainActor
struct RemindersAccessSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = ScriptWidgetRuntimeReminders.systemAuthorizationStatus()
    @State private var requesting = false
    @State private var message: String?
    @StateObject private var model = ScriptWidgetCalendarSourcesModel(kind: .reminders)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status == "authorized" ? "Reminders Connected" : "Connect Reminders", systemImage: "checklist").font(.headline)
            Text("Apple requires full Reminders access. Widgets read only the lists you choose. Explicit actions with remindersWrite can create, update or complete reminders in those lists.").font(.footnote).foregroundStyle(.secondary)
            if status == "authorized" { CalendarSourcesSettingsView(model: model) }
            else {
                Button(requesting ? "Requesting Access…" : "Allow Reminders Access") {
                    requesting = true
                    ScriptWidgetRuntimeReminders.requestSystemAuthorization { _, error in
                        requesting = false; status = ScriptWidgetRuntimeReminders.systemAuthorizationStatus(); message = error
                        if status == "authorized" { Task { await model.reload() } }
                    }
                }.disabled(requesting || status == "restricted" || status == "unavailable")
            }
            if status == "denied" || status == "restricted" { Text("Review Reminders access in system privacy settings, then return here.").font(.footnote).foregroundStyle(.secondary) }
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
        }.task(id: scenePhase) {
            if scenePhase == .active { status = ScriptWidgetRuntimeReminders.systemAuthorizationStatus(); if status == "authorized" { await model.reload() } }
        }
    }
}

struct RemindersAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { Section("Reminders") { RemindersAccessSettingsView() } }.navigationTitle("Data Access")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 300)
        #endif
    }
}
#endif


/// Validated native mutation input. Rendering environments cannot confer action
/// authority. A request ID is reserved for durable duplicate-execution handling.
struct ScriptWidgetReminderMutation {
    enum Kind: String { case create, update, setCompleted }
    let kind: Kind
    let requestID: String
    let listID: String
    let id: String?
    let title: String?
    let changesDue: Bool
    let due: String?
    let priority: Int?
    let completed: Bool?
    let fingerprint: String

    init(kind: Kind, options: [String: Any]) throws {
        let fields: Set<String>
        switch kind {
        case .create: fields = ["requestID", "listID", "title", "due", "priority"]
        case .update: fields = ["requestID", "listID", "id", "title", "due", "priority"]
        case .setCompleted: fields = ["requestID", "listID", "id", "completed"]
        }
        guard Set(options.keys).isSubset(of: fields),
              let requestID = options["requestID"] as? String,
              UUID(uuidString: requestID)?.uuidString.lowercased() == requestID,
              let listID = options["listID"] as? String, ScriptWidgetCalendarSelection.validIDs([listID]) else {
            throw ScriptWidgetRemindersError.invalid("A mutation requires a canonical request UUID and one listID")
        }
        self.kind = kind; self.requestID = requestID; self.listID = listID
        if kind == .create { id = nil }
        else {
            guard let value = options["id"] as? String, !value.isEmpty, value.utf8.count <= 2048,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ScriptWidgetRemindersError.invalid("A mutation requires a reminder ID")
            }
            id = value
        }
        if let value = options["title"] {
            guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 1024, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ScriptWidgetRemindersError.invalid("A title must contain 1–1024 UTF-8 bytes without control characters")
            }
            title = text
        } else {
            guard kind != .create else { throw ScriptWidgetRemindersError.invalid("Creating a reminder requires a title") }
            title = nil
        }
        changesDue = options.keys.contains("due")
        if let value = options["due"], !(value is NSNull) {
            guard let text = value as? String,
                  Self.validDue(text) else {
                throw ScriptWidgetRemindersError.invalid("due must be a valid calendar day, ISO date-time, or null")
            }
            due = text
        } else { due = nil }
        if let value = options["priority"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...9).contains(number.doubleValue), number.doubleValue.rounded() == number.doubleValue else {
                throw ScriptWidgetRemindersError.invalid("priority must be an integer from 0 to 9")
            }
            priority = number.intValue
        } else { priority = kind == .create ? 0 : nil }
        if kind == .setCompleted {
            guard let number = options["completed"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ScriptWidgetRemindersError.invalid("completed must be a Boolean")
            }
            completed = number.boolValue
        } else { completed = nil }
        guard kind != .update || title != nil || changesDue || priority != nil else {
            throw ScriptWidgetRemindersError.invalid("An update requires at least one changed field")
        }
        var identity: [String: Any] = ["kind": kind.rawValue, "listID": listID]
        if let id { identity["id"] = id }
        if let title { identity["title"] = title }
        if changesDue { identity["due"] = due as Any? ?? NSNull() }
        if let priority { identity["priority"] = priority }
        if let completed { identity["completed"] = completed }
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validDue(_ text: String) -> Bool {
        if ScriptWidgetReminderItem.day(text) != nil { return true }
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              ScriptWidgetReminderItem.day(String(text.prefix(10))) != nil else { return false }
        return ScriptWidgetReminderItem.isoDate(text) != nil
    }

    static func permitsAction(_ state: ScriptWidgetRunningState) -> Bool {
        state.isUserInitiatedAction && !state.isTimelineProjection && !state.isLiveActivityPresentation
            && state.previewStorage == nil && state.isCurrentExecution
    }
}

/// Private per-owner write receipts. A prepared receipt is never blindly retried:
/// the process may have stopped after EventKit committed but before we recorded
/// the identifier. Only completed receipts older than seven days are discarded.
enum ScriptWidgetReminderMutationLedger {
    static let maximumEntries = 128
    static let maximumBytes = 64 * 1024
    static let retention: TimeInterval = 7 * 86_400
    enum Failure: LocalizedError {
        case corrupt, busy, conflict, uncertain, full
        var errorDescription: String? {
            switch self {
            case .corrupt: return "[write_history_invalid] Reminder write history could not be validated"
            case .busy: return "[write_busy] Another reminder write is running. Retry with the same requestID."
            case .conflict: return "[request_conflict] This requestID was used with a different operation"
            case .uncertain: return "[outcome_unknown] This operation may already have been applied. Inspect Reminders before creating another request."
            case .full: return "[write_history_full] Reminder write history has reached its bound"
            }
        }
    }
    private struct Entry: Codable {
        let requestID: String
        let fingerprint: String
        let listID: String
        let createdAt: Double
        var state: String
        var id: String?
    }
    private struct Ledger: Codable {
        let formatVersion: Int
        var entries: [Entry]
    }
    static func perform<Request: ScriptWidgetSystemMutationRequest>(_ request: Request, container: URL,
                        backend: any ScriptWidgetStorageBackend, key: String, now: Date = Date(),
                        validate: @escaping () throws -> Void,
                        write: (_ beforeCommit: () throws -> Void) throws -> String) throws -> [String: Any] {
        let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: key) {
            Result<[String: Any], Error> {
                try validate()
                var ledger = Ledger(formatVersion: 1, entries: [])
                if let present = try backend.readValue(forKey: key) {
                    guard let bytes = present as? Data, bytes.count <= maximumBytes,
                          let decoded = try? JSONDecoder().decode(Ledger.self, from: bytes),
                          let original = try? JSONSerialization.jsonObject(with: bytes),
                          let normalized = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)),
                          try JSONSerialization.data(withJSONObject: original, options: .sortedKeys) == JSONSerialization.data(withJSONObject: normalized, options: .sortedKeys),
                          decoded.formatVersion == 1, decoded.entries.count <= maximumEntries,
                          Set(decoded.entries.map(\.requestID)).count == decoded.entries.count else { throw Failure.corrupt }
                    for entry in decoded.entries {
                        guard UUID(uuidString: entry.requestID)?.uuidString.lowercased() == entry.requestID,
                              entry.fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                              ScriptWidgetCalendarSelection.validIDs([entry.listID]), entry.createdAt.isFinite, entry.createdAt >= 0,
                              ["prepared", "completed"].contains(entry.state),
                              entry.state == "prepared" ? entry.id == nil : validID(entry.id) else { throw Failure.corrupt }
                    }
                    ledger = decoded
                }
                ledger.entries.removeAll { $0.state == "completed" && now.timeIntervalSince1970 - $0.createdAt > retention }
                if let prior = ledger.entries.first(where: { $0.requestID == request.requestID }) {
                    guard prior.fingerprint == request.fingerprint,
                          ScriptWidgetCalendarSelection.sameID(prior.listID, request.listID) else { throw Failure.conflict }
                    guard prior.state == "completed", let id = prior.id else { throw Failure.uncertain }
                    return ["id": id, "listID": prior.listID, "status": "applied", "replayed": true]
                }
                guard ledger.entries.count < maximumEntries else { throw Failure.full }
                func save() throws {
                    let bytes = try JSONEncoder().encode(ledger)
                    guard bytes.count <= maximumBytes else { throw Failure.full }
                    try backend.writeValue(bytes, forKey: key)
                    guard backend.synchronize() else { throw Failure.uncertain }
                }
                var beganCommit = false
                let id: String
                do {
                    id = try write {
                        guard !beganCommit else { throw Failure.uncertain }
                        try validate()
                        ledger.entries.append(.init(requestID: request.requestID, fingerprint: request.fingerprint,
                                                    listID: request.listID, createdAt: now.timeIntervalSince1970, state: "prepared"))
                        // Reserve the largest supported system identifier before
                        // committing so a successful write can fit its receipt.
                        var completed = ledger
                        completed.entries[completed.entries.count - 1].state = "completed"
                        completed.entries[completed.entries.count - 1].id = String(repeating: "x", count: 2048)
                        guard try JSONEncoder().encode(completed).count <= maximumBytes else { throw Failure.full }
                        try save()
                        beganCommit = true
                    }
                } catch {
                    if beganCommit { throw Failure.uncertain }
                    throw error
                }
                guard beganCommit, validID(id), let last = ledger.entries.indices.last else { throw Failure.uncertain }
                ledger.entries[last].state = "completed"; ledger.entries[last].id = id
                do { try save() } catch { throw Failure.uncertain }
                return ["id": id, "listID": request.listID, "status": "applied", "replayed": false]
            }
        }
        guard let result else { throw Failure.busy }
        return try result.get()
    }
    private static func validID(_ id: String?) -> Bool {
        guard let id else { return false }
        return !id.isEmpty && id.utf8.count <= 2048 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
