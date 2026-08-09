//
//  ScriptWidgetGalleryView.swift
//  ScriptWidget
//

import SwiftUI

enum GalleryOpenRequest {
    static let notification = Notification.Name("ScriptWidgetGalleryOpenRequest")
}

@MainActor
final class GalleryViewModel: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isOffline = false
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var installingID: String?
    @Published var errorMessage: String?

    let client: GalleryClient
    let installer: GalleryInstaller

    init(client: GalleryClient = .init(), installer: GalleryInstaller = .init()) {
        self.client = client
        self.installer = installer
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await client.load(forceRefresh: forceRefresh)
            items = snapshot.index.items.sorted {
                if $0.featured != $1.featured { return $0.featured }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            isOffline = snapshot.isOffline
            fetchedAt = snapshot.fetchedAt
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func install(_ item: GalleryItem) async {
        guard installingID == nil else { return }
        installingID = item.id
        defer { installingID = nil }
        do {
            _ = try await installer.install(item)
            objectWillChange.send()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func state(for item: GalleryItem) -> GalleryInstallState { installer.state(for: item) }
}

struct ScriptWidgetGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GalleryViewModel
    @State private var selectedID: String?
    @State private var kind: GalleryItemKind?
    @State private var searchText = ""

    @MainActor
    init() {
        _model = StateObject(wrappedValue: GalleryViewModel())
    }

    @MainActor
    init(model: GalleryViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    private var filteredItems: [GalleryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.items.filter { item in
            (kind == nil || item.kind == kind)
                && (query.isEmpty || ([item.name, item.summary, item.author] + item.tags).joined(separator: " ").lowercased().contains(query))
        }
    }

    private var selectedItem: GalleryItem? {
        let visible = filteredItems
        return visible.first { $0.id == selectedID } ?? visible.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .galleryWindowSize()
        .searchable(text: $searchText, prompt: "Search Gallery")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load(forceRefresh: true) }
                }
                .disabled(model.isLoading)
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        .task { await model.load() }
        .alert("Gallery", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown Gallery error.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Content", selection: $kind) {
                Text("All").tag(GalleryItemKind?.none)
                ForEach(GalleryItemKind.allCases) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            if model.isLoading && model.items.isEmpty {
                Spacer()
                ProgressView("Loading GitHub Gallery…")
                Spacer()
            } else if filteredItems.isEmpty {
                GalleryUnavailableView(
                    title: model.items.isEmpty ? "Gallery Unavailable" : "No Results",
                    systemImage: model.items.isEmpty ? "wifi.exclamationmark" : "magnifyingglass",
                    message: model.items.isEmpty ? "Refresh when an internet connection is available." : "Try another search or content type."
                )
            } else {
                List(filteredItems, selection: $selectedID) { item in
                    GalleryItemRow(item: item, state: model.state(for: item))
                        .tag(item.id)
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: model.isOffline ? "wifi.slash" : "checkmark.shield")
                Text(model.isOffline ? "Offline cache" : "Verified GitHub index")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(model.isOffline ? Color.orange : Color.secondary)
            .padding(10)
            .accessibilityElement(children: .combine)
        }
        .navigationTitle("Gallery")
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            GalleryItemDetail(
                item: item,
                state: model.state(for: item),
                isInstalling: model.installingID == item.id
            ) {
                Task { await model.install(item) }
            }
            .id(item.id)
        } else {
            GalleryUnavailableView(title: "Select an Item", systemImage: "square.grid.2x2", message: "Choose a widget or Skill from the Gallery.")
        }
    }
}

private extension View {
    @ViewBuilder
    func galleryWindowSize() -> some View {
#if os(macOS)
        frame(minWidth: 760, idealWidth: 920, minHeight: 540, idealHeight: 640)
#else
        self
#endif
    }
}

private struct GalleryUnavailableView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct GalleryItemRow: View {
    let item: GalleryItem
    let state: GalleryInstallState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).lineLimit(1)
                    if item.featured { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Featured") }
                    Spacer(minLength: 0)
                    status
                }
                Text("v\(item.version) · \(item.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(item.kind == .widget ? .blue : .purple)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .notInstalled: EmptyView()
        case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
        case .updateAvailable: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange).accessibilityLabel("Update available")
        }
    }
}

private struct GalleryItemDetail: View {
    let item: GalleryItem
    let state: GalleryInstallState
    let isInstalling: Bool
    let install: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 42))
                        .foregroundStyle(item.kind == .widget ? .blue : .purple)
                        .frame(width: 64, height: 64)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(.rect(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.largeTitle.bold())
                        Text("\(item.kind == .widget ? "Widget" : "Skill") · v\(item.version) · \(item.license)")
                            .foregroundStyle(.secondary)
                        Text("by \(item.author)").font(.callout).foregroundStyle(.secondary)
                    }
                }

                Text(item.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.tags.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1), in: .capsule)
                        }
                    }
                }

                GroupBox("Trust & compatibility") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Runtime \(item.minimumRuntimeVersion)", systemImage: "checkmark.seal")
                        Label("\(item.files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(item.files.reduce(0) { $0 + $1.bytes }), countStyle: .file))", systemImage: "doc.on.doc")
                        Label("Every file is HTTPS host, byte-size, and SHA-256 verified before schema validation.", systemImage: "lock.shield")
                        Link(destination: item.sourceURL) { Label("Review source on GitHub", systemImage: "arrow.up.right.square") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                HStack {
                    Button(action: install) {
                        if isInstalling {
                            ProgressView().controlSize(.small)
                            Text("Verifying…")
                        } else {
                            Label(actionTitle, systemImage: actionSymbol)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isInstalling || state == .installed)
                    Spacer()
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(item.name)
    }

    private var actionTitle: String {
        switch state {
        case .notInstalled: "Install"
        case .installed: "Installed"
        case .updateAvailable(let current): "Update from v\(current)"
        }
    }

    private var actionSymbol: String {
        switch state {
        case .notInstalled: "square.and.arrow.down"
        case .installed: "checkmark"
        case .updateAvailable: "arrow.down.circle"
        }
    }
}
