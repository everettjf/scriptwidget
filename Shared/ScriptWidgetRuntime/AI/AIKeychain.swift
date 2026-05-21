//
//  AIKeychain.swift
//  ScriptWidget
//
//  Tiny generic-password keychain wrapper used to persist OAuth
//  credentials (refresh + access tokens). UserDefaults is intentionally
//  not used for these — they are bearer secrets.
//

import Foundation
import Security

struct AIKeychain {
    static let live = AIKeychain()

    private let service = "com.everettjf.scriptwidget.ai"

    func value(for account: String) -> String? {
        var query = lookupQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query = lookupQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        var addQuery = lookupQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func removeValue(for account: String) {
        SecItemDelete(lookupQuery(account: account) as CFDictionary)
    }

    private func lookupQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
