import SwiftUI
import UniformTypeIdentifiers
import Contacts
import UserNotifications
#if os(iOS) && canImport(AlarmKit)
import AlarmKit
#endif

struct ScriptWidgetSystemAccessView: View {
    let package: ScriptWidgetPackage
    @Environment(\.dismiss) private var dismiss
    @State private var grant = ScriptWidgetSystemAccessGrant()
    @State private var original = ScriptWidgetSystemAccessGrant()
    @State private var message = ""
    @State private var contacts: [ScriptWidgetContactChoice] = []
    @State private var home: [ScriptWidgetHomeChoice] = []
    @State private var importing = false
    @State private var busy = false
    static func supports(_ package: ScriptWidgetPackage) -> Bool {
        package.readManifest()?.permissions.contains(where: { ScriptWidgetSystemAccessGrant.capabilities.contains($0.rawValue) }) == true
    }
    static func store(_ package: ScriptWidgetPackage) throws -> ScriptWidgetSystemAccessStore {
        guard let scope = package.managedScope, let binding = scope.binding else { throw ScriptWidgetSystemServiceError.permissionDenied }
        try scope.validate(name: package.name)
        return .init(container: scope.context.container, owner: binding.ownerID, validate: { try scope.validate(name: package.name) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Access for This Widget") {
                    Text(package.name).font(.headline)
                    Text("Only enable capabilities you want this installed widget to use. Copies require their own access. System writes require a button or declared action.")
                    ForEach((package.readManifest()?.permissions ?? []).filter { ScriptWidgetSystemAccessGrant.capabilities.contains($0.rawValue) }, id: \.rawValue) { permission in
                        Toggle(Self.label(permission.rawValue), isOn: Binding(get: { grant.permissions.contains(permission.rawValue) }, set: { on in
                            grant.permissions.removeAll { $0 == permission.rawValue }; if on { grant.permissions.append(permission.rawValue) }
                        }))
                    }
                    Button("Save Access and Selections") { run {
                        let store = try Self.store(package); try store.save(grant, expected: original); reload(); message = "Access saved. System authorization may also be required below."
                    } }
                    Text("Turning access off takes effect for subsequent system calls. It does not delete imported files or cancel previously scheduled notifications or alarms; cancel those before revoking access.").font(.footnote)
                }
                if declared("notifications") {
                    Section("Notifications") {
                        Button("Authorize Notifications") {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in DispatchQueue.main.async { message = granted ? "Notifications authorized." : "Notifications are not authorized." } }
                        }
                    }
                }
                if declared("alarms") {
                    Section("Alarms") {
                        #if os(iOS) && canImport(AlarmKit)
                        if #available(iOS 26.0, *) {
                            Button("Authorize Alarms") { Task { do { let status = try await AlarmManager.shared.requestAuthorization(); message = "Alarm authorization: \(String(describing: status))" } catch { message = "Alarm authorization could not complete." } } }
                        } else { Text("Alarms require iOS or iPadOS 26 or later.") }
                        #else
                        Text("AlarmKit is unavailable on this platform.")
                        #endif
                    }
                }
                if declared("documents") {
                    Section("Imported Data Files") {
                        Text("Import JSON or CSV as a private copy, up to 256 KiB per file and eight files per widget. The original file is never modified. Reimport to capture later edits.")
                        Button("Import JSON or CSV") { importing = true }
                            .disabled(!original.permissions.contains("documents"))
                        ForEach(grant.documents, id: \.id) { item in
                            VStack(alignment: .leading) { Text(item.name); Text("\(item.type) · \(item.bytes) bytes · \(item.id)").font(.caption).textSelection(.enabled) }
                        }
                        Text("File identifiers are available through $documents.list().")
                    }
                }
                if declared("contacts") {
                    Section("Selected Contacts") {
                        Text("The widget can read names, organization, up to three phone numbers and three email addresses for selected contacts only. The picker lists up to 200 contacts the system shares with this app; at most 20 can be selected.")
                        Button("Authorize and Load Contacts") {
                            CNContactStore().requestAccess(for: .contacts) { allowed, _ in
                                ScriptWidgetSystemServices.queue.async {
                                    let values = allowed ? (try? ScriptWidgetContactProvider.choices()) ?? [] : []
                                    DispatchQueue.main.async { contacts = values; message = allowed ? "Choose contacts and save access." : "Contacts are not authorized." }
                                }
                            }
                        }
                        ForEach(contacts) { item in Toggle(item.name, isOn: selection(\.contacts, id: item.id)) }
                    }
                }
                if declared("home") {
                    Section("Selected Home Accessories and Scenes") {
                        Text("Selected power controls can be switched by explicit actions. Selected scenes may also operate locks, doors or other accessories according to your Home configuration; choose only scenes you trust this widget to run. Sensor readings are cached HomeKit values, not guaranteed live readings.")
                        #if os(iOS)
                        Button("Authorize and Load Home") {
                            ScriptWidgetHomeProvider.shared.load { result in
                                switch result { case .success(let values): home = values; message = "Choose items and save access."; case .failure: message = "Home could not be loaded. Check system authorization, then retry." }
                            }
                        }
                        ForEach(home) { item in Toggle("\(item.name) (\(item.kind))", isOn: selection(\.home, id: item.id)) }
                        #else
                        Text("Native HomeKit access is currently supported on iPhone and iPad.")
                        #endif
                    }
                }
                if declared("calendarWrite") { Section("Calendar Writes") { Text("Authorize Calendar and select calendars in app Settings. This API creates single events and updates only events this installation created. Recurring-event edits and deletion are not exposed.") } }
                if declared("maps") || declared("weather") { Section("Network Services") { Text("Map requests send the supplied place or coordinate to Apple Maps. Weather sends rounded coordinates to MET Norway and also requires network permission for api.met.no. No current device location is read automatically.") } }
                if !message.isEmpty { Section { Text(message).accessibilityIdentifier("system-access-message") } }
            }
            .disabled(busy)
            .navigationTitle("System Access")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { reload() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .commaSeparatedText], allowsMultipleSelection: false) { result in
                run {
                    let url = try result.get().first!
                    let opened = url.startAccessingSecurityScopedResource(); defer { if opened { url.stopAccessingSecurityScopedResource() } }
                    let keys = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard keys.isRegularFile == true, keys.isSymbolicLink != true, let size = keys.fileSize, size <= 262144 else { throw ScriptWidgetSystemServiceError.invalidOptions }
                    let data = try ScriptWidgetDocumentData.importedFile(url)
                    guard data.count <= 262144 else { throw ScriptWidgetSystemServiceError.limitExceeded }
                    let type = url.pathExtension.lowercased()
                    if type == "json" { _ = try ScriptWidgetDocumentData.json(data) }
                    else if type == "csv" { _ = try ScriptWidgetDocumentData.csv(data) }
                    else { throw ScriptWidgetSystemServiceError.invalidOptions }
                    let store = try Self.store(package)
                    let before = try store.load(); var next = before
                    guard before.permissions.contains("documents"), before.documents.count < 8 else { throw ScriptWidgetSystemServiceError.permissionDenied }
                    let id = UUID().uuidString.lowercased()
                    next.documents.append(.init(id: id, name: String(url.lastPathComponent.prefix(80)), type: type, bytes: data.count))
                    try store.validate()
                    guard ScriptWidgetPackageFiles.write(data, root: store.container, relative: store.directory + "/documents/" + id) else { throw ScriptWidgetSystemServiceError.unavailable }
                    try store.save(next, expected: before)
                    reload(); message = "Imported a private data copy. The original file is unchanged."
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }
    private static func label(_ name: String) -> String {
        ["notifications":"Schedule local notifications", "calendarWrite":"Create and update this widget’s events", "maps":"Look up places and generate maps", "weather":"Fetch weather for supplied coordinates", "alarms":"Schedule alarms and timers", "documents":"Read imported JSON and CSV copies", "contacts":"Read selected contacts", "home":"Read and control selected Home items"][name] ?? name
    }
    private func declared(_ name: String) -> Bool { package.readManifest()?.permissions.contains(where: { $0.rawValue == name }) == true }
    private func selection(_ path: WritableKeyPath<ScriptWidgetSystemAccessGrant, [String]>, id: String) -> Binding<Bool> {
        Binding(get: { grant[keyPath: path].contains(id) }, set: { on in
            grant[keyPath: path].removeAll { $0 == id }
            if on && grant[keyPath: path].count < 20 { grant[keyPath: path].append(id) }
        })
    }
    private func reload() { do { let value = try Self.store(package).load(); grant = value; original = value } catch { message = ScriptWidgetSystemServices.safeError(error) } }
    private func run(_ work: () throws -> Void) { do { try work() } catch { message = ScriptWidgetSystemServices.safeError(error) } }
}
