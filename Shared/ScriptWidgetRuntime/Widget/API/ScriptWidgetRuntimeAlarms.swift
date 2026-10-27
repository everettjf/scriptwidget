import Foundation
import JavaScriptCore
#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

struct ScriptWidgetAlarmOptions {
    let key: String
    let title: String
    let date: Date?
    let seconds: Double?
    init(_ options: [String: Any], now: Date = Date()) throws {
        try ScriptWidgetSystemOptions.fields(options, ["requestID", "key", "title", "date", "seconds"])
        key = try ScriptWidgetSystemOptions.text(options["key"], maximum: 64)
        guard ScriptWidgetSystemOptions.validKey(key), (options["date"] == nil) != (options["seconds"] == nil) else { throw ScriptWidgetSystemServiceError.invalidOptions }
        title = try ScriptWidgetSystemOptions.text(options["title"], maximum: 128)
        date = try options["date"].map(ScriptWidgetSystemOptions.date)
        seconds = try options["seconds"].map { try ScriptWidgetSystemOptions.number($0, range: 60...86400) }
        if let date { guard date > now, date.timeIntervalSince(now) <= 366 * 86400 else { throw ScriptWidgetSystemServiceError.invalidOptions } }
    }
    static func id(owner: String, key: String) throws -> UUID {
        guard ScriptWidgetSystemOptions.validKey(key), UUID(uuidString: owner) != nil else { throw ScriptWidgetSystemServiceError.invalidOptions }
        let hex = Array(ScriptWidgetCloudJSONStore.hash(Data((owner + ":alarm:" + key).utf8)).prefix(32))
        return UUID(uuidString: String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32]))!
    }
}
@objc protocol ScriptWidgetRuntimeAlarmsExports: JSExport {
    static func status() -> ScriptWidgetRuntimePromise
    static func pending() -> ScriptWidgetRuntimePromise
    static func schedule(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func cancel(_ key: String) -> ScriptWidgetRuntimePromise
    static func stop(_ key: String) -> ScriptWidgetRuntimePromise
    static func pause(_ key: String) -> ScriptWidgetRuntimePromise
    static func resume(_ key: String) -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeAlarms: NSObject, ScriptWidgetRuntimeAlarmsExports {
    static func status() -> ScriptWidgetRuntimePromise { run("status") }
    static func pending() -> ScriptWidgetRuntimePromise { run("pending") }
    static func schedule(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { run("schedule", options ?? [:]) }
    static func cancel(_ key: String) -> ScriptWidgetRuntimePromise { run("cancel", ["key": key]) }
    static func stop(_ key: String) -> ScriptWidgetRuntimePromise { run("stop", ["key": key]) }
    static func pause(_ key: String) -> ScriptWidgetRuntimePromise { run("pause", ["key": key]) }
    static func resume(_ key: String) -> ScriptWidgetRuntimePromise { run("resume", ["key": key]) }
    static func retire(owner: String, backend: any ScriptWidgetStorageBackend) {
        #if os(iOS) && canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard let keys = try? backend.readValue(forKey: "ScriptWidget.SystemServices.alarmKeys.v1." + owner) as? [String], keys.count <= 32 else { return }
            for key in keys where ScriptWidgetSystemOptions.validKey(key) {
                if let id = try? ScriptWidgetAlarmOptions.id(owner: owner, key: key) { try? AlarmManager.shared.cancel(id: id) }
            }
        }
        #endif
    }
    private static func run(_ method: String, _ options: [String: Any] = [:]) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.alarms, writing: !["status", "pending"].contains(method)) { context, finish in
            #if os(iOS) && canImport(AlarmKit)
            guard #available(iOS 26.0, *) else { throw ScriptWidgetSystemServiceError.unavailable }
            let manager = AlarmManager.shared
            if method == "status" { finish(.success(["authorization": String(describing: manager.authorizationState)])); return }
            guard manager.authorizationState == .authorized else { throw ScriptWidgetSystemServiceError.permissionDenied }
            let backend = context.state.executionSnapshot!.context.defaults
            let indexKey = context.access.privateKey("alarmKeys")
            guard let operationResult = ScriptWidgetStorageLock.withExclusiveAccess(container: context.access.container, namespace: indexKey, operation: { Result<Any, Error> {
            guard backend.synchronize() else { throw ScriptWidgetSystemServiceError.unavailable }
            let raw = try backend.readValue(forKey: indexKey)
            guard raw == nil || raw is [String], let keys = (raw as? [String] ?? []) as [String]?, keys.count <= 32, keys.allSatisfy(ScriptWidgetSystemOptions.validKey), Set(keys).count == keys.count else { throw ScriptWidgetSystemServiceError.unavailable }
            if method == "pending" {
                let alarms = try manager.alarms
                let rows = try keys.compactMap { key -> [String: Any]? in
                    let id = try ScriptWidgetAlarmOptions.id(owner: context.owner, key: key)
                    guard let alarm = alarms.first(where: { $0.id == id }) else { return nil }
                    return ["key": key, "state": String(describing: alarm.state)]
                }
                return rows
            }
            let key = try ScriptWidgetSystemOptions.text(options["key"], maximum: 64)
            let id = try ScriptWidgetAlarmOptions.id(owner: context.owner, key: key)
            if method != "schedule" {
                try context.validate()
                switch method { case "cancel": try manager.cancel(id: id); case "stop": try manager.stop(id: id); case "pause": try manager.pause(id: id); default: try manager.resume(id: id) }
                return ["key": key, "status": "requested"]
            }
            let value = try ScriptWidgetAlarmOptions(options)
            let request = try ScriptWidgetNativeMutation(options, scope: "alarms", operation: "schedule")
            let ledgerKey = context.access.privateKey("alarmReceipts")
            let result = try ScriptWidgetReminderMutationLedger.perform(request, container: context.access.container, backend: backend, key: ledgerKey, validate: context.validate) { beforeCommit in
                guard keys.contains(key) || keys.count < 32 else { throw ScriptWidgetSystemServiceError.limitExceeded }
                // Never silently replace a running alarm. Cancel explicitly first.
                guard try !manager.alarms.contains(where: { $0.id == id }) else { throw ScriptWidgetSystemServiceError.staleRequest }
                try backend.writeValue(Array(Set(keys + [key])).sorted(), forKey: indexKey)
                guard backend.synchronize() else { throw ScriptWidgetSystemServiceError.unavailable }
                try beforeCommit()
                let box = ScriptWidgetSystemCompletionBox()
                Task {
                    do {
                        try context.validate()
                        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: value.title), stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
                        let presentation = AlarmPresentation(alert: alert, countdown: value.seconds.map { _ in .init(title: LocalizedStringResource(stringLiteral: value.title)) })
                        let attributes = AlarmAttributes(presentation: presentation, metadata: ScriptWidgetAlarmMetadata(), tintColor: .teal)
                        let configuration: AlarmManager.AlarmConfiguration<ScriptWidgetAlarmMetadata> = value.seconds.map { .timer(duration: $0, attributes: attributes) } ?? .alarm(schedule: value.date.map { .fixed($0) }, attributes: attributes)
                        _ = try await manager.schedule(id: id, configuration: configuration)
                        box.finish(.success(id.uuidString.lowercased()))
                    } catch { box.finish(.failure(ScriptWidgetSystemServiceError.outcomeUnknown)) }
                }
                return try box.wait()
            }
            return ["key": key, "status": "scheduled", "replayed": result["replayed"] ?? false]
            } }) else { throw ScriptWidgetSystemServiceError.unavailable }
            finish(.success(try operationResult.get()))
            #else
            _ = context; throw ScriptWidgetSystemServiceError.unavailable
            #endif
        }
    }
}
#if os(iOS) && canImport(AlarmKit)
@available(iOS 26.0, *)
struct ScriptWidgetAlarmMetadata: AlarmMetadata { }
#endif
