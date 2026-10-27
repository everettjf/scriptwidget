import Foundation
import JavaScriptCore
import UserNotifications

struct ScriptWidgetNotificationOptions {
    let key: String
    let title: String
    let body: String
    let date: Date?
    let dailyHour: Int?
    let dailyMinute: Int?
    init(_ options: [String: Any], now: Date = Date()) throws {
        try ScriptWidgetSystemOptions.fields(options, ["key", "title", "body", "date", "daily"])
        key = try ScriptWidgetSystemOptions.text(options["key"], maximum: 64)
        guard ScriptWidgetSystemOptions.validKey(key) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        title = try ScriptWidgetSystemOptions.text(options["title"], maximum: 256)
        body = try ScriptWidgetSystemOptions.text(options["body"], maximum: 1024)
        guard (options["date"] == nil) != (options["daily"] == nil) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        date = try options["date"].map(ScriptWidgetSystemOptions.date)
        if let date { guard date > now, date.timeIntervalSince(now) <= 366 * 86400 else { throw ScriptWidgetSystemServiceError.invalidOptions } }
        if let raw = options["daily"] {
            guard let daily = raw as? [String: Any] else { throw ScriptWidgetSystemServiceError.invalidOptions }
            try ScriptWidgetSystemOptions.fields(daily, ["hour", "minute"])
            let hour = try ScriptWidgetSystemOptions.number(daily["hour"], range: 0...23), minute = try ScriptWidgetSystemOptions.number(daily["minute"], range: 0...59)
            guard hour.rounded() == hour, minute.rounded() == minute else { throw ScriptWidgetSystemServiceError.invalidOptions }
            dailyHour = Int(hour); dailyMinute = Int(minute)
        } else { dailyHour = nil; dailyMinute = nil }
    }
}
@objc protocol ScriptWidgetRuntimeNotificationsExports: JSExport {
    static func status() -> ScriptWidgetRuntimePromise
    static func pending() -> ScriptWidgetRuntimePromise
    static func schedule(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func cancel(_ key: String) -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeNotifications: NSObject, ScriptWidgetRuntimeNotificationsExports {
    static func status() -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.notifications) { _, finish in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status: String
                switch settings.authorizationStatus { case .authorized: status = "authorized"; case .provisional: status = "provisional"; case .ephemeral: status = "ephemeral"; case .denied: status = "denied"; case .notDetermined: status = "notDetermined"; @unknown default: status = "unavailable" }
                finish(.success(["authorization": status]))
            }
        }
    }
    static func pending() -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.notifications) { context, finish in
            let prefix = "sw." + context.owner + ".notification."
            UNUserNotificationCenter.current().getPendingNotificationRequests { items in
                let rows = items.filter { $0.identifier.hasPrefix(prefix) }.prefix(32).map { item -> [String: Any] in
                    let nextDate = (item.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() ?? (item.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                    return ["key": String(item.identifier.dropFirst(prefix.count)), "title": item.content.title, "body": item.content.body,
                     "repeats": item.trigger?.repeats ?? false, "date": nextDate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
                }
                finish(.success(rows))
            }
        }
    }
    static func schedule(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.notifications, writing: true) { context, finish in
            let value = try ScriptWidgetNotificationOptions(options ?? [:])
            let id = try context.scopedID(value.key, group: "notification")
            let center = UNUserNotificationCenter.current()
            // Coordinate capacity checks across both app/extension processes.
            guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: context.access.container, namespace: "ScriptWidget.Notifications.Queue.v1", operation: { () -> Result<String, Error> in
                let box = ScriptWidgetSystemCompletionBox()
                let deadline = Date().addingTimeInterval(2.4)
                center.getNotificationSettings { settings in
                    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { box.finish(.failure(ScriptWidgetSystemServiceError.permissionDenied)); return }
                    center.getPendingNotificationRequests { items in
                        do {
                            try context.validate()
                            guard Date() < deadline else { throw ScriptWidgetSystemServiceError.outcomeUnknown }
                            let replacing = items.contains(where: { $0.identifier == id })
                            guard replacing || items.count < 60,
                                  replacing || items.filter({ $0.identifier.hasPrefix("sw." + context.owner + ".notification.") }).count < 32 else { throw ScriptWidgetSystemServiceError.limitExceeded }
                            let content = UNMutableNotificationContent(); content.title = value.title; content.body = value.body
                            let trigger: UNNotificationTrigger
                            if let hour = value.dailyHour, let minute = value.dailyMinute {
                                trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
                            } else {
                                trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, value.date!.timeIntervalSinceNow), repeats: false)
                            }
                            try context.validate()
                            center.add(.init(identifier: id, content: content, trigger: trigger)) { error in
                                box.finish(error == nil ? .success(id) : .failure(ScriptWidgetSystemServiceError.outcomeUnknown))
                            }
                        } catch { box.finish(.failure(error)) }
                    }
                }
                return Result { try box.wait() }
            }) else { throw ScriptWidgetSystemServiceError.unavailable }
            _ = try result.get()
            finish(.success(["key": value.key, "status": "scheduled"]))
        }
    }
    static func cancel(_ key: String) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.notifications, writing: true) { context, finish in
            let id = try context.scopedID(key, group: "notification")
            try context.validate()
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
            finish(.success(["key": key, "status": "cancellationRequested"]))
        }
    }
}

extension ScriptWidgetSystemServices {
    private static let deletionObserver = NotificationCenter.default.addObserver(forName: ScriptManager.packageRemovedNotification, object: nil, queue: nil) { event in
        guard let owner = event.userInfo?["retiredOwner"] as? String,
              let context = event.userInfo?["storageContext"] as? ScriptWidgetPackageStorageContext else { return }
        retireSchedules(owner: owner, container: context.container, backend: context.defaults)
    }
    static func startLifecycle() { _ = deletionObserver }
    /// Called only after native package deletion has retired its installation.
    /// Calendar events, imported data and other user records are never deleted.
    static func retireSchedules(owner: String, container: URL, backend: any ScriptWidgetStorageBackend) {
        guard UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              ["com.everettjf.scriptwidget", "com.everettjf.scriptwidget.widget", "com.everettjf.scriptwidget.macwidget"].contains(Bundle.main.bundleIdentifier ?? ""),
              NSClassFromString("XCTestCase") == nil, NSClassFromString("XCTest.XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        queue.async {
            _ = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "ScriptWidget.Notifications.Queue.v1") {
                let box = ScriptWidgetSystemCompletionBox()
                let prefix = "sw." + owner + ".notification."
                UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                    let ids = requests.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
                    box.finish(.success(owner))
                }
                _ = try? box.wait()
            }
            ScriptWidgetRuntimeAlarms.retire(owner: owner, backend: backend)
        }
    }
}
