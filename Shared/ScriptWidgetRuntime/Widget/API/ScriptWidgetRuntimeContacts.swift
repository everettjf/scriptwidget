import Foundation
import JavaScriptCore
import Contacts

struct ScriptWidgetContactChoice: Identifiable {
    let id: String
    let name: String
}
enum ScriptWidgetContactProvider {
    static var authorized: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        if #available(iOS 18.0, *), status == .limited { return true }
        #endif
        return status == .authorized
    }
    static let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
    static func choices() throws -> [ScriptWidgetContactChoice] {
        guard authorized else { throw ScriptWidgetSystemServiceError.permissionDenied }
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor])
        request.sortOrder = .userDefault
        var result: [ScriptWidgetContactChoice] = []
        try CNContactStore().enumerateContacts(with: request) { contact, stop in
            result.append(.init(id: contact.identifier, name: String((contact.givenName + " " + contact.familyName).prefix(256))))
            if result.count == 200 { stop.pointee = true }
        }
        return result
    }
    static func selected(_ ids: [String]) throws -> [[String: Any]] {
        guard authorized, ids.count <= 20 else { throw ScriptWidgetSystemServiceError.permissionDenied }
        if ids.isEmpty { return [] }
        let contacts = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: keys.map { $0 as CNKeyDescriptor })
        return contacts.prefix(20).filter { ids.contains($0.identifier) }.map { contact in
            ["id": contact.identifier, "name": String((contact.givenName + " " + contact.familyName).prefix(256)), "organization": String(contact.organizationName.prefix(256)),
             "phones": contact.phoneNumbers.prefix(3).map { String($0.value.stringValue.prefix(128)) }, "emails": contact.emailAddresses.prefix(3).map { String(($0.value as String).prefix(256)) }]
        }
    }
}
@objc protocol ScriptWidgetRuntimeContactsExports: JSExport {
    static func selected() -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeContacts: NSObject, ScriptWidgetRuntimeContactsExports {
    static func selected() -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.contacts) { context, finish in
            let ids = try context.access.load().contacts
            let result = try ScriptWidgetContactProvider.selected(ids)
            guard ScriptWidgetContactProvider.authorized else { throw ScriptWidgetSystemServiceError.permissionDenied }
            finish(.success(result))
        }
    }
}
