import Foundation
import JavaScriptCore
import EventKit

struct ScriptWidgetCalendarMutation: ScriptWidgetSystemMutationRequest {
    let requestID: String
    let listID: String
    let fingerprint: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let eventID: String?
    init(_ options: [String: Any], updating: Bool) throws {
        try ScriptWidgetSystemOptions.fields(options, updating ? ["requestID", "calendarID", "id", "title", "start", "end", "allDay"] : ["requestID", "calendarID", "title", "start", "end", "allDay"])
        requestID = try ScriptWidgetSystemOptions.text(options["requestID"], maximum: 36)
        guard UUID(uuidString: requestID)?.uuidString.lowercased() == requestID else { throw ScriptWidgetSystemServiceError.invalidOptions }
        listID = try ScriptWidgetSystemOptions.text(options["calendarID"], maximum: 256)
        title = try ScriptWidgetSystemOptions.text(options["title"], maximum: 512)
        start = try ScriptWidgetSystemOptions.date(options["start"]); end = try ScriptWidgetSystemOptions.date(options["end"])
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw ScriptWidgetSystemServiceError.invalidOptions }
        allDay = try options["allDay"].map(ScriptWidgetSystemOptions.boolean) ?? false
        eventID = updating ? try ScriptWidgetSystemOptions.text(options["id"], maximum: 2048) : nil
        fingerprint = ScriptWidgetCloudJSONStore.hash(try JSONSerialization.data(withJSONObject: ["operation": updating ? "update" : "create", "options": options], options: [.sortedKeys, .withoutEscapingSlashes]))
    }
}

enum ScriptWidgetRuntimeCalendarWrites {
    static func mutate(_ options: [String: Any], updating: Bool) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.calendarWrite, writing: true) { context, finish in
            let request = try ScriptWidgetCalendarMutation(options, updating: updating)
            guard context.state.package.readManifest()?.permissions.contains(.calendar) == true,
                  ScriptWidgetRuntimeCalendar.systemAuthorizationStatus() == "authorized" else { throw ScriptWidgetSystemServiceError.permissionDenied }
            let snapshot = context.state.executionSnapshot!
            let selected = try ScriptWidgetCalendarSelection.load(container: snapshot.context.container)
            guard selected.allows(request.listID) else { throw ScriptWidgetSystemServiceError.permissionDenied }
            let store = EKEventStore()
            guard let calendar = store.calendar(withIdentifier: request.listID), calendar.allowedEntityTypes.contains(.event), calendar.allowsContentModifications else { throw ScriptWidgetSystemServiceError.permissionDenied }
            let ownershipKey = context.access.privateKey("ownedEvents")
            guard let response = ScriptWidgetStorageLock.withExclusiveAccess(container: snapshot.context.container, namespace: ownershipKey, operation: { Result<Any, Error> {
            guard snapshot.context.defaults.synchronize() else { throw ScriptWidgetSystemServiceError.unavailable }
            var owned = try ScriptWidgetSystemAccessStore.readNativeValue([String: String].self, key: ownershipKey, backend: snapshot.context.defaults) ?? [:]
            guard owned.count <= 128, owned.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 2048 && $0.value.utf8.count <= 256 }) else { throw ScriptWidgetSystemServiceError.limitExceeded }
            let event: EKEvent
            if let id = request.eventID {
                guard owned[id] == request.listID, let existing = store.event(withIdentifier: id), existing.calendar.calendarIdentifier == request.listID,
                      !existing.hasRecurrenceRules else { throw ScriptWidgetSystemServiceError.permissionDenied }
                event = existing
            } else {
                guard owned.count < 128 else { throw ScriptWidgetSystemServiceError.limitExceeded }
                event = EKEvent(eventStore: store); event.calendar = calendar
            }
            event.title = request.title; event.startDate = request.start; event.endDate = request.end; event.isAllDay = request.allDay
            let result = try selected.withStableAccess(container: snapshot.context.container, kind: .calendar) {
                try ScriptWidgetReminderMutationLedger.perform(request, container: snapshot.context.container, backend: snapshot.context.defaults,
                    key: context.access.privateKey("calendarReceipts"), validate: {
                        try context.validate()
                        guard ScriptWidgetRuntimeCalendar.systemAuthorizationStatus() == "authorized" else { throw ScriptWidgetSystemServiceError.permissionDenied }
                    }) { beforeCommit in
                        try beforeCommit()
                        try store.save(event, span: .thisEvent, commit: true)
                        guard let id = event.eventIdentifier else { throw ScriptWidgetSystemServiceError.outcomeUnknown }
                        return id
                    }
            }
            guard let id = result["id"] as? String else { throw ScriptWidgetSystemServiceError.outcomeUnknown }
            owned[id] = request.listID
            try ScriptWidgetSystemAccessStore.writeNativeValue(owned, key: ownershipKey, backend: snapshot.context.defaults)
            guard snapshot.context.defaults.synchronize() else { throw ScriptWidgetSystemServiceError.outcomeUnknown }
            return ["id": id, "calendarID": request.listID, "status": "applied", "replayed": result["replayed"] ?? false]
            } }) else { throw ScriptWidgetSystemServiceError.unavailable }
            finish(.success(try response.get()))
        }
    }
}
