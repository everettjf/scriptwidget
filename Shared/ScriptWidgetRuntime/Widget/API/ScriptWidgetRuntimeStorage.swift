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
    static func remove(_ key: String) -> Bool
    static func keys() -> [String]
    static func clear() -> Bool
}

@objc public class ScriptWidgetRuntimeStorage: NSObject, ScriptWidgetRuntimeStorageExports {
    static let maximumKeyBytes = 256
    static let maximumValueBytes = 256 * 1_024
    private static func defaults() -> UserDefaults {
        return UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? UserDefaults.standard
    }

    private static func namespacedKey(_ key: String) -> String? {
        guard !key.isEmpty, key.utf8.count <= maximumKeyBytes,
              let namespace = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return nil }
        return namespace + key
    }

    static func getString(_ key: String) -> String {
        guard let key = namespacedKey(key) else { return "" }
        return defaults().string(forKey: key) ?? ""
    }

    static func setString(_ key: String, _ value: String) -> Bool {
        guard value.utf8.count <= maximumValueBytes, let key = namespacedKey(key) else { return false }
        defaults().set(value, forKey: key)
        return true
    }

    static func getJSON(_ key: String) -> [AnyHashable: Any]! {
        guard let key = namespacedKey(key), let data = defaults().data(forKey: key) else {
            return [:]
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [AnyHashable: Any]
            return json ?? [:]
        } catch {
            print("storage getJSON error: \(error)")
            return [:]
        }
    }

    static func setJSON(_ key: String, _ value: [AnyHashable: Any]) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [])
            guard data.count <= maximumValueBytes, let key = namespacedKey(key) else { return false }
            defaults().set(data, forKey: key)
            return true
        } catch {
            print("storage setJSON error: \(error)")
            return false
        }
    }

    static func remove(_ key: String) -> Bool {
        guard let key = namespacedKey(key) else { return false }
        defaults().removeObject(forKey: key)
        return true
    }

    static func keys() -> [String] {
        guard let prefix = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return [] }
        return defaults().dictionaryRepresentation().keys.compactMap { key in
            key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        }.sorted()
    }

    static func clear() -> Bool {
        guard let prefix = JSContext.current()?.scriptWidgetRunningState?.storageNamespace else { return false }
        let allKeys = defaults().dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for key in allKeys {
            defaults().removeObject(forKey: key)
        }
        return true
    }
}
