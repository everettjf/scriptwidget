import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DataSourceLabView: View {
    @State private var plugins = DataSourcePluginManager.shared.allManifests()
    @State private var selectedPluginID: String?
    @State private var selectedOperationID: String?
    @State private var parameterValues: [String: String] = [:]
    @State private var response = "Choose an operation, review its parameters, then run it."
    @State private var requestSummary = ""
    @State private var isRunning = false
    @State private var isImporting = false
    @State private var statusMessage: String?

    private var selectedPlugin: DataSourcePluginManifest? {
        plugins.first { $0.id == selectedPluginID }
    }

    private var selectedOperation: DataSourcePluginOperation? {
        selectedPlugin?.operations.first { $0.id == selectedOperationID }
    }

    var body: some View {
        NavigationSplitView {
            List(plugins, selection: $selectedPluginID) { plugin in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name)
                        Text(plugin.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } icon: {
                    Image(systemName: plugin.symbol)
                }
                .tag(plugin.id)
            }
            .navigationTitle("Data Sources")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Import", systemImage: "square.and.arrow.down") { isImporting = true }
                    Button("Export", systemImage: "square.and.arrow.up") { exportSelected() }
                        .disabled(selectedPluginID == nil)
                    Button("Uninstall", systemImage: "trash", role: .destructive) { uninstallSelected() }
                        .disabled(selectedPluginID == nil || selectedPluginID.map { DataSourcePluginManager.shared.package(id: $0) == nil } == true)
                    Spacer()
                    Button("Reveal", systemImage: "finder") {
                        MacKitUtil.revealInFinder(DataSourcePluginManager.shared.directory.path)
                    }
                }
                .labelStyle(.iconOnly)
                .padding(8)
                .background(.bar)
            }
        } content: {
            if let plugin = selectedPlugin {
                List(plugin.operations, selection: $selectedOperationID) { operation in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(operation.title)
                        Text("\(operation.method) \(operation.path)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .tag(operation.id)
                }
                .navigationTitle(plugin.name)
            } else {
                ContentUnavailableView("Choose a data source", systemImage: "externaldrive.connected.to.line.below")
            }
        } detail: {
            if let plugin = selectedPlugin, let operation = selectedOperation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("Request") {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                                ForEach(operation.parameters) { parameter in
                                    GridRow {
                                        Text(parameter.label)
                                        TextField(parameter.required ? "Required" : "Optional", text: parameterBinding(parameter))
                                            .textFieldStyle(.roundedBorder)
                                        Text(parameter.location.rawValue)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }

                        HStack {
                            Button("Run request", systemImage: "play.fill") { run(plugin: plugin, operation: operation) }
                                .buttonStyle(.borderedProminent)
                                .disabled(isRunning)
                            if isRunning { ProgressView().controlSize(.small) }
                            Spacer()
                            Text("HTTPS only · 2 MiB response limit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !requestSummary.isEmpty {
                            Text(requestSummary)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }

                        GroupBox("Response") {
                            TextEditor(text: .constant(response))
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 220)
                        }

                        GroupBox("Widget code") {
                            Text(sampleCode(plugin: plugin, operation: operation))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                }
                .navigationTitle(operation.title)
            } else {
                ContentUnavailableView("Choose an operation", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: selectedPluginID) { _, _ in selectFirstOperation() }
        .onChange(of: selectedOperationID) { _, _ in loadDefaults() }
        .onReceive(NotificationCenter.default.publisher(for: DataSourcePluginManager.changedNotification)) { _ in reload() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.zip, .data]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let imported = DataSourcePluginManager.shared.importPlugin(from: url)
            statusMessage = imported.succeeded ? "Installed \(imported.pluginID ?? "plugin")." : imported.message
            reload()
        }
        .alert("Data Source Plugin", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { statusMessage = nil }
        } message: { Text(statusMessage ?? "") }
    }

    private func parameterBinding(_ parameter: DataSourcePluginParameter) -> Binding<String> {
        Binding(get: { parameterValues[parameter.id, default: ""] }, set: { parameterValues[parameter.id] = $0 })
    }

    private func selectFirstIfNeeded() {
        if selectedPluginID == nil { selectedPluginID = plugins.first?.id }
        selectFirstOperation()
    }

    private func selectFirstOperation() {
        selectedOperationID = selectedPlugin?.operations.first?.id
        loadDefaults()
    }

    private func loadDefaults() {
        parameterValues = Dictionary(uniqueKeysWithValues: (selectedOperation?.parameters ?? []).map { ($0.id, $0.defaultValue ?? "") })
        response = "Ready."
        requestSummary = ""
    }

    private func reload() {
        plugins = DataSourcePluginManager.shared.allManifests()
        selectFirstIfNeeded()
    }

    private func exportSelected() {
        guard let plugin = selectedPlugin else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(plugin.name.replacingOccurrences(of: "/", with: "-")) \(plugin.version).swplugin"
        panel.allowedContentTypes = [.zip, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = DataSourcePluginManager.shared.export(id: plugin.id, to: url)
        statusMessage = result.0 ? "Exported \(plugin.name)." : result.1
    }

    private func uninstallSelected() {
        guard let id = selectedPluginID else { return }
        let result = DataSourcePluginManager.shared.delete(id: id)
        statusMessage = result.0 ? "Plugin uninstalled." : result.1
        if result.0 { selectedPluginID = nil }
        reload()
    }

    private func run(plugin: DataSourcePluginManifest, operation: DataSourcePluginOperation) {
        isRunning = true
        response = "Running…"
        Task {
            do {
                let prepared = try DataSourceRequestBuilder.prepare(plugin: plugin, operationID: operation.id, values: parameterValues)
                let result = try await DataSourcePluginExecutor.execute(prepared)
                let object = try? JSONSerialization.jsonObject(with: result.data)
                let formatted = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
                response = String(data: formatted ?? result.data, encoding: .utf8) ?? "<non-UTF-8 response>"
                requestSummary = "HTTP \(result.statusCode) · \(result.data.count) bytes · \(String(format: "%.0f", result.duration * 1_000)) ms\n\(result.request.httpMethod ?? "GET") \(result.request.url?.absoluteString ?? "")"
            } catch {
                response = "Error: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    private func sampleCode(plugin: DataSourcePluginManifest, operation: DataSourcePluginOperation) -> String {
        let parameters = operation.parameters.map { "  \($0.id): \(String(reflecting: parameterValues[$0.id, default: ""]))" }.joined(separator: ",\n")
        return "const value = await $dataSource.request(\n  \(String(reflecting: plugin.id)),\n  \(String(reflecting: operation.id)),\n{\n\(parameters)\n});"
    }
}

struct DataSourceLabCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Data Source Lab...") { openWindow(id: "data-source-lab") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
