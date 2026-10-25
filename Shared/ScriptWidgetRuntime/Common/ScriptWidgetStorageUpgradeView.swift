import SwiftUI
import WidgetKit

enum ScriptWidgetApplicationTestHost {
    static var simulatesUnavailableStorage: Bool {
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-simulateUnavailableSharedStorage")
#else
        return false
#endif
    }
    static var isActive: Bool {
#if DEBUG
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
#else
        return false
#endif
    }
}

@MainActor
final class ScriptWidgetStorageUpgradeModel: ObservableObject {
    private let service: ScriptWidgetStorageUpgradeService?
    @Published private(set) var fields: [ScriptWidgetLegacyStorageField] = []
    @Published private(set) var preview: ScriptWidgetStorageReviewPreview?
    @Published var selectedOwners = Set<String>()
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    @Published private(set) var incompleteInventory = false

    init(service: ScriptWidgetStorageUpgradeService? = nil) {
        do { self.service = try service ?? .live() }
        catch { self.service = nil; message = error.localizedDescription; isError = true }
        if self.service != nil { reload() }
    }

    func reload() {
        guard let service else { return }
        do {
            fields = try service.fields()
            incompleteInventory = try !service.inventory().isComplete
            preview = nil; selectedOwners = []; message = nil; isError = false
        } catch { report(error) }
    }

    func show(_ field: ScriptWidgetLegacyStorageField) {
        guard let service else { return }
        preview = nil; selectedOwners = []
        do { preview = try service.preview(field: field.key); message = nil; isError = false }
        catch { report(error) }
    }

    func copySelection() {
        guard let service, let preview else { return }
        do {
            try service.copy(preview, to: selectedOwners)
            reload(); message = "Copies saved. The original record is still kept."
        } catch { report(error) }
    }

    func keep(_ field: ScriptWidgetLegacyStorageField) {
        guard let service else { return }
        do {
            try service.keepOriginal(field)
            reload(); message = "Original kept without copying."
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        preview = nil; selectedOwners = []
        message = error.localizedDescription; isError = true
    }
}

struct ScriptWidgetStorageUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ScriptWidgetStorageUpgradeModel
    @State private var confirmingCopy = false
    @State private var keeping: ScriptWidgetLegacyStorageField?

    init(model: ScriptWidgetStorageUpgradeModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ScriptWidgetStorageUpgradeModel())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which widgets receive a copy of older records. Your original values are kept.")
                    if model.incompleteInventory {
                        Text("Some library items may still be unavailable. Missing widgets are not treated as deleted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.message {
                        Text(message).foregroundStyle(model.isError ? Color.red : Color.secondary)
                            .accessibilityIdentifier("storageReview.message")
                    }
                }
                Section("Records to Review") {
                    if model.fields.isEmpty && !model.isError {
                        Label("No records need review", systemImage: "checkmark.circle")
                    }
                    ForEach(model.fields, id: \.key) { field in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { model.show(field) } label: {
                                Text(verbatim: field.key).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            Button("Keep Original Without Copying") { keeping = field }
                                .font(.caption).buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let preview = model.preview {
                    Section("Record Preview") {
                        Text("\(preview.legacy.valueType) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.legacy.valueBytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: preview.text).font(.system(.caption, design: .monospaced))
                            .lineLimit(8).textSelection(.enabled)
                    }
                    Section("Copy to Widgets") {
                        if preview.candidates.isEmpty {
                            Text("No original widget was found for this record. You can keep the original without copying.")
                        }
                        ForEach(preview.candidates) { candidate in
                            Toggle(isOn: selection(candidate.id)) {
                                VStack(alignment: .leading) {
                                    Text(verbatim: candidate.owner.name)
                                    Text(verbatim: candidate.key).font(.caption).foregroundStyle(.secondary)
                                    if !candidate.canCopy {
                                        Text("Unavailable or exceeds the record limits").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(!candidate.canCopy)
                            .accessibilityLabel("Copy to \(candidate.owner.name)")
                        }
                        Button("Review Copies") { confirmingCopy = true }
                            .disabled(model.selectedOwners.isEmpty)
                            .accessibilityIdentifier("storageReview.copy")
                    }
                }
            }
            .navigationTitle("Review Older Records")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Refresh") { model.reload() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Copy This Record?", isPresented: $confirmingCopy) {
                Button("Copy") { model.copySelection() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A copy will be saved to each selected widget. Changes made after this preview require another review. The original stays stored.")
            }
            .alert("Keep Original Without Copying?", isPresented: Binding(get: { keeping != nil }, set: { if !$0 { keeping = nil } }), presenting: keeping) { field in
                Button("Keep Original") { model.keep(field) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("No copy will be assigned to a widget. The original value stays stored and will not be deleted.")
            }
        }
    }

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedOwners.contains(id) }, set: { value in
            if value { model.selectedOwners.insert(id) } else { model.selectedOwners.remove(id) }
        })
    }
}

@MainActor
final class ScriptWidgetLibraryLaunchModel: ObservableObject {
    static let shared = ScriptWidgetLibraryLaunchModel()
    private let factory: @Sendable () throws -> ScriptWidgetApplicationLibraryService
    private let cacheOnOpen: Bool
    private var attempted = false
    private var isDiscoveringRestoredPackages = false
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var isOffline = false
    @Published private(set) var selectionID = "opening"
    @Published private(set) var selectedRootPath: String?
    @Published private(set) var choices: [ScriptWidgetLibraryChoice] = []
    @Published private(set) var message: String?

    init(cacheOnOpen: Bool = true, factory: @escaping @Sendable () throws -> ScriptWidgetApplicationLibraryService = { try .live() }) {
        self.factory = factory; self.cacheOnOpen = cacheOnOpen
    }

    func openIfNeeded() async {
        guard !attempted else { return }
        await open()
    }

    func open() async {
        guard !isBusy else { return }
        attempted = true; isBusy = true; message = nil
        let factory = self.factory
        defer { isBusy = false }
        do {
            let session = try await Task.detached(priority: .userInitiated) { try factory().open() }.value
            publish(session)
        } catch { report(error) }
    }

    /// Poll only while a native application scene is active. Failed or partial
    /// downloads and open editors are retried without replacing the current UI.
    func refreshRestoredPackages() async {
        guard !isBusy, !isDiscoveringRestoredPackages, isReady || isOffline else { return }
        isDiscoveringRestoredPackages = true
        defer { isDiscoveringRestoredPackages = false }
        let factory = self.factory
        do {
            let session = try await Task.detached(priority: .utility, operation: {
                let service = try factory()
                return try service.refreshRestoredPackages() ?? service.open()
            }).value
            if !isBusy, session.selection.activationID != selectionID || (session.sourceManager == nil) != isOffline {
                publish(session)
            }
        } catch {
            // Background discovery must not present transient download/lease
            // errors as a failed library switch. The next foreground scan retries.
        }
    }

    func loadChoices() async {
        let factory = self.factory
        do { choices = try await Task.detached { try factory().choices() }.value }
        catch { report(error) }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        let factory = self.factory
        do {
            let session = try await Task.detached(priority: .userInitiated) { try factory().refresh() }.value
            publish(session)
        } catch { report(error) }
    }

    func choose(_ choice: ScriptWidgetLibraryChoice) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; message = nil
        defer { isBusy = false }
        let factory = self.factory
        do {
            let session = try await Task.detached(priority: .userInitiated) { try factory().select(choice) }.value
            publish(session)
            return true
        } catch { report(error); return false }
    }

    private func publish(_ session: ScriptWidgetLibrarySession) {
        // A user-initiated switch may have completed while discovery awaited I/O.
        guard (try? session.validate()) != nil else { return }
        selectionID = session.selection.activationID
        selectedRootPath = session.selection.profile.path
        isOffline = session.sourceManager == nil
        isReady = !isOffline
        message = nil
        if cacheOnOpen, let manager = session.sourceManager {
            Task.detached(priority: .utility) {
                manager.precacheAllScripts()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func report(_ error: Error) {
        message = (error as? ScriptWidgetLibraryOpeningError)?.errorDescription
            ?? "The widget library could not be opened. Your original files and records are kept. Reconnect its storage and try again."
    }
}

struct ScriptWidgetLibrarySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ScriptWidgetLibraryLaunchModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Each library keeps its own widgets and records. Choosing a library does not move or delete files.")
                    Text("Close all widget editors and stop Web Studio before changing libraries.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Widget Libraries") {
                    ForEach(model.choices) { choice in
                        Button {
                            Task { if await model.choose(choice) { dismiss() } }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice.isUsingICloud ? "icloud" : "internaldrive")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.title)
                                    Text(choice.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                    if !choice.isAvailable { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                                }
                                if choice.root.path == model.selectedRootPath {
                                    Spacer()
                                    Image(systemName: "checkmark").accessibilityLabel("Selected library")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!choice.isAvailable || model.isBusy || choice.root.path == model.selectedRootPath)
                    }
                }
                Section {
                    Button("Refresh Selected Library") { Task { await model.refresh() } }
                        .disabled(model.isBusy || model.selectedRootPath == nil)
                    Text("After adding widgets in Files or iCloud Drive, refresh to make them available. Close editors and stop Web Studio first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.red) } }
                if model.isBusy { ProgressView("Opening library…") }
            }
            .navigationTitle("Widget Library")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await model.loadChoices() }
        }
    }
}

/// Shared startup surface. The application installs this before showing any
/// package/editor UI; tests can render it with a temporary, injected service.
struct ScriptWidgetLibraryLaunchView<Content: View>: View {
    @ObservedObject var model: ScriptWidgetLibraryLaunchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLibraries = false
    let content: () -> Content

    init(model: ScriptWidgetLibraryLaunchModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model; self.content = content
    }

    var body: some View {
        Group {
            if model.isReady {
                content().id(model.selectionID).disabled(model.isBusy)
            } else if model.isBusy || model.message == nil && !model.isOffline {
                VStack(spacing: 14) {
                    ProgressView("Opening Widget Library…")
                    Text("Older records are upgraded without removing the originals.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(32)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: model.isOffline ? "icloud.slash" : "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text(model.isOffline ? "Your Library Is Offline" : "Library Unavailable").font(.title2.bold())
                    Text(model.isOffline ? "Reconnect its storage to edit widgets. Cached widgets can continue running." : (model.message ?? "Try opening your library again."))
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.open() } }.buttonStyle(.borderedProminent)
                    Button("Choose Library") { showingLibraries = true }.buttonStyle(.bordered)
                }.padding(32).frame(maxWidth: 560)
            }
        }
        .task(id: scenePhase) {
            await model.openIfNeeded()
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshRestoredPackages()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
            }
        }
        .sheet(isPresented: $showingLibraries) { ScriptWidgetLibrarySelectionView(model: model) }
    }
}
