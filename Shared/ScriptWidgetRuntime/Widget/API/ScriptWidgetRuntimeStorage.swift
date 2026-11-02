//
//  ScriptWidgetRuntimeStorage.swift
//  ScriptWidget
//
//  Created by ScriptWidget contributors.
//

import Foundation
import JavaScriptCore

@objc protocol ScriptWidgetRuntimeStorageExports: JSExport {
    static func getString(_ key: String) -> String
    static func setString(_ key: String, _ value: String) -> Bool
    static func getJSON(_ key: String) -> [AnyHashable: Any]!
    static func setJSON(_ key: String, _ value: [AnyHashable: Any]) -> Bool
    static func compareAndSetString(_ key: String, _ expected: String, _ value: String) -> Bool
    static func compareAndSetJSON(_ key: String, _ expected: [AnyHashable: Any], _ value: [AnyHashable: Any]) -> Bool
    static func remove(_ key: String) -> Bool
    static func keys() -> [String]
    static func clear() -> Bool
}

@objc public class ScriptWidgetRuntimeStorage: NSObject, ScriptWidgetRuntimeStorageExports {
    static let maximumKeyBytes = ScriptWidgetAtomicPreferences.maximumKeyBytes
    static let maximumValueBytes = ScriptWidgetAtomicPreferences.maximumValueBytes
    private static func defaults() -> any ScriptWidgetStorageBackend {
        if let snapshot = JSContext.current()?.scriptWidgetRunningState?.executionSnapshot { return snapshot.context.defaults }
        if let preview = JSContext.current()?.scriptWidgetRunningState?.previewStorage { return preview }
        #if DEBUG
        if let fixture = JSContext.current()?.scriptWidgetRunningState?.storageDefaultsForTesting { return ScriptWidgetLegacyStorageBackend(fixture, container: container) }
        #endif
        return ScriptWidgetLegacyStorageBackend(UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? UserDefaults.standard, container: container)
    }

    private static func reportStorageError(_ error: Error) {
        let message = (error as? ScriptWidgetStorageNamespaceError) == .inventoryRequired
            ? "[storage:migration_required] Open ScriptWidget to reload this widget's record identity."
            : "[storage:unavailable] Records could not be read. Existing data has been preserved."
        JSContext.current()?.exception = JSValue(newErrorFromMessage: message, in: JSContext.current())
    }

    private static func namespacedKey(_ key: String) -> String? {
        guard !key.isEmpty, key.utf8.count <= maximumKeyBytes, canAccess(),
              let namespace = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return nil }
        return namespace + key
    }

    private static var container: URL? {
        if let snapshot = JSContext.current()?.scriptWidgetRunningState?.executionSnapshot { return snapshot.context.container }
        if JSContext.current()?.scriptWidgetRunningState?.previewStorage != nil { return nil }
        #if DEBUG
        if let fixture = JSContext.current()?.scriptWidgetRunningState?.storageContainerForTesting { return fixture }
        #endif
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")
    }

    private static func canAccess() -> Bool {
        guard let state = JSContext.current()?.scriptWidgetRunningState else { return false }
        guard state.executionSnapshot != nil || state.previewStorage != nil else { return true }
        guard state.executionSession.isActive else { return false }
        // Local, bounded, owner-scoped records predate Package 2.0. Copying an
        // old script into a new package must not revoke this existing API.
        // Personal-data and cross-package permissions remain separate.
        if state.package.hasManifest && state.package.readManifest() == nil {
            JSContext.current()?.exception = JSValue(newErrorFromMessage: "[invalid_manifest] widget.json could not be read", in: JSContext.current())
            return false
        }
        do { try state.validateExecutionSnapshot(); return true }
        catch {
            JSContext.current()?.exception = JSValue(newErrorFromMessage: "[storage:identity_changed] Reload the widget before accessing its records.", in: JSContext.current())
            return false
        }
    }

    private static func canStore(_ key: String, value: Any, store: any ScriptWidgetStorageBackend) -> Bool {
        guard let state = JSContext.current()?.scriptWidgetRunningState, state.executionSnapshot != nil else { return true }
        guard canAccess() else { return false }
        return (try? ScriptWidgetStorageNamespaces.fitsBudget(namespace: state.storageNamespace, defaults: store, replacing: [key: value])) == true
    }

    /// Native actions use the same coordinator, including toggle state writes.
    static func mutate(namespace: String, defaults store: any ScriptWidgetStorageBackend, operation: (any ScriptWidgetStorageBackend) throws -> Bool) -> Bool {
        guard JSContext.current()?.scriptWidgetRunningState?.isTimelineProjection != true else { return false }
        return mutate(namespace: namespace, defaults: store, container: container) { value in
            if JSContext.current()?.scriptWidgetRunningState?.executionSnapshot != nil && !canAccess() { return false }
            return try operation(value)
        }
    }

    static func mutate(namespace: String, defaults store: any ScriptWidgetStorageBackend, container: URL?, operation: (any ScriptWidgetStorageBackend) throws -> Bool) -> Bool {
        guard let container else {
            // Preserve ordinary legacy storage when no shared container exists.
            if store is ScriptWidgetPreviewStorageBackend { return (try? store.mutateValues(in: namespace, operation: operation)) == true }
            return (try? operation(store)) == true
        }
        return ScriptWidgetAtomicPreferences.mutate(container: container, defaults: store, namespace: namespace, operation: operation)
    }

    static func getString(_ key: String) -> String {
        guard let key = namespacedKey(key) else { return "" }
        let store = defaults()
        _ = store.synchronize()
        do { return try store.readValue(forKey: key) as? String ?? "" }
        catch { reportStorageError(error); return "" }
    }

    static func setString(_ key: String, _ value: String) -> Bool {
        guard value.utf8.count <= maximumValueBytes, let name = namespacedKey(key),
              let namespace = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return false }
        return mutate(namespace: namespace, defaults: defaults()) { store in
            guard canStore(key, value: value, store: store) else { return false }
            try store.writeValue(value, forKey: name); return true
        }
    }

    static func getJSON(_ key: String) -> [AnyHashable: Any]! {
        guard let key = namespacedKey(key) else { return [:] }
        let store = defaults()
        _ = store.synchronize()
        do {
            guard let data = try store.readValue(forKey: key) as? Data, data.count <= maximumValueBytes,
                  let json = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [AnyHashable: Any] else { return [:] }
            return json
        } catch { reportStorageError(error); return [:] }
    }

    static func setJSON(_ key: String, _ value: [AnyHashable: Any]) -> Bool {
        guard let data = ScriptWidgetAtomicPreferences.encodeJSON(value), let name = namespacedKey(key),
              let namespace = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return false }
        return mutate(namespace: namespace, defaults: defaults()) { store in
            guard canStore(key, value: data, store: store) else { return false }
            try store.writeValue(data, forKey: name); return true
        }
    }

    static func compareAndSetString(_ key: String, _ expected: String, _ value: String) -> Bool {
        guard namespacedKey(key) != nil,
              let state = JSContext.current()?.scriptWidgetRunningState, state.executionSession.isActive, !state.isTimelineProjection else { return false }
        return ScriptWidgetAtomicPreferences.compareAndSetString(container: container, defaults: defaults(), namespace: state.storageNamespace, key: key, expected: expected, value: value, isActive: { state.executionSession.isActive }, canStore: { canStore(key, value: $1, store: $0) })
    }

    static func compareAndSetJSON(_ key: String, _ expected: [AnyHashable: Any], _ value: [AnyHashable: Any]) -> Bool {
        guard namespacedKey(key) != nil,
              let state = JSContext.current()?.scriptWidgetRunningState, state.executionSession.isActive, !state.isTimelineProjection else { return false }
        return ScriptWidgetAtomicPreferences.compareAndSetJSON(container: container, defaults: defaults(), namespace: state.storageNamespace, key: key, expected: expected, value: value, isActive: { state.executionSession.isActive }, canStore: { canStore(key, value: $1, store: $0) })
    }

    static func remove(_ key: String) -> Bool {
        guard let name = namespacedKey(key), let namespace = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return false }
        return mutate(namespace: namespace, defaults: defaults()) { store in try store.removeValue(forKey: name); return true }
    }

    static func keys() -> [String] {
        guard canAccess(), let prefix = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return [] }
        let store = defaults()
        _ = store.synchronize()
        do { return try store.values(in: prefix).map { String(decoding: $0.0.utf8.dropFirst(prefix.utf8.count), as: UTF8.self) }.sorted() }
        catch { reportStorageError(error); return [] }
    }

    static func clear() -> Bool {
        guard canAccess(), let prefix = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return false }
        return mutate(namespace: prefix, defaults: defaults()) { store in
            for (key, _) in try store.values(in: prefix) { try store.removeValue(forKey: key) }
            return true
        }
    }
}
