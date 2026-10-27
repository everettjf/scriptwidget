import SwiftUI
import WidgetKit

/// Explicit native grants are independent of scripts, manifests and exports.
struct ScriptWidgetCloudJSONView: View {
    let package: ScriptWidgetPackage
    @Environment(\.dismiss) private var dismiss
    @State private var stores: [String] = []
    @State private var connected = ""
    @State private var message = ""
    @State private var busy = false
    @State private var pendingStore: String?
    @State private var confirmConnection = false

    static func store(for package: ScriptWidgetPackage) throws -> ScriptWidgetCloudJSONStore {
        guard let scope = package.managedScope, let binding = scope.binding,
              package.readManifest()?.permissions.contains(.icloud) == true else { throw ScriptWidgetCloudJSONError.notConnected }
        try scope.validate(name: package.name)
        return try ScriptWidgetCloudJSONStore(container: scope.context.container, owner: binding.ownerID) { try scope.validate(name: package.name) }
    }

    private static let refreshLock = NSLock()
    private static var lastRefresh = Date.distantPast
    static func refreshConnectedPackages() {
        refreshLock.lock()
        guard Date().timeIntervalSince(lastRefresh) >= 15 else { refreshLock.unlock(); return }
        lastRefresh = Date(); refreshLock.unlock()
        ScriptWidgetCloudJSONStore.queue.async {
            guard !ScriptWidgetApplicationTestHost.isActive else { return }
            for model in sharedScriptManager.listScripts().prefix(64) {
                guard model.package.readManifest()?.permissions.contains(.icloud) == true,
                      let store = try? Self.store(for: model.package), (try? store.connection()) != nil else { continue }
                if let result = try? store.synchronize(), (result["downloadedRevisions"] as? Int ?? 0) > 0 { WidgetCenter.shared.reloadAllTimelines() }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud JSON Files") {
                    Text(package.name).font(.headline)
                    Text("Only this installed widget can use its connected data store. Existing local records are not moved. Copies require their own connection.")
                    if !connected.isEmpty {
                        Text("Connected folder: WidgetData/\(connected)").textSelection(.enabled)
                        Button("Disconnect", role: .destructive) { run { try $0.disconnect(); return "Disconnected. Cloud files and cached records are preserved." } }
                        Button("Sync Now") { run { _ = try $0.synchronize(); return "Local revisions exchanged. iCloud uploads asynchronously; this does not confirm upload or another device receiving them." } }
                    }
                    Button("Create a New Data Store") { pendingStore = nil; confirmConnection = true }
                }
                Section("Connect an Existing Data Store") {
                    Text("To share records with another device, select the same folder ID on both devices. Connecting grants this widget read and write access to that store. Imported widgets never connect automatically.")
                    ForEach(stores, id: \.self) { id in
                        Button(id) { pendingStore = id; confirmConnection = true }.font(.caption.monospaced())
                    }
                    Button("Refresh Stores") { refresh() }
                }
                Section("Files and Conflicts") {
                    Text("Find JSON revisions in Files → iCloud Drive → ScriptWidget → WidgetData. Each named document has immutable revision files containing value and parents. You may inspect or copy them; editing or deleting revision files directly is not supported. Conflicting versions remain available to readJSON and must be resolved explicitly.")
                    Text("The API never promises immediate sync. No iCloud account, offline files, quotas and system background limits may delay delivery. Keep a backup before changing records.")
                    if !message.isEmpty { Text(message).accessibilityIdentifier("icloud-json-message") }
                    if busy { ProgressView() }
                }
            }
            .disabled(busy)
            .navigationTitle("iCloud Data")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Allow this widget to access this iCloud data store?", isPresented: $confirmConnection, titleVisibility: .visible) {
                Button("Connect") {
                    let selected = pendingStore
                    run { try $0.connect(existingStore: selected); return "Connected. Existing local records have not been migrated." }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text(pendingStore ?? "A new empty store will be created. No existing local records will be moved or deleted.") }
            .task { refresh() }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
    private func refresh() { run { _ in "" } }
    private func run(_ operation: @escaping (ScriptWidgetCloudJSONStore) throws -> String) {
        guard !busy else { return }; busy = true
        ScriptWidgetCloudJSONStore.queue.async {
            var items: [String] = []; var connection = ""; var result = ""
            do {
                let store = try Self.store(for: package)
                result = try operation(store)
                items = try store.availableStores()
                connection = (try? store.connection()) ?? ""
            } catch { result = (error as? LocalizedError)?.errorDescription ?? "iCloud data is unavailable. Existing records are preserved." }
            DispatchQueue.main.async { stores = items; connected = connection; message = result; busy = false }
        }
    }
}
