import SwiftUI
import UniformTypeIdentifiers

private struct ScriptWidgetDiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Shared by Settings and the unavailable-library surface. No library manager,
/// container authorization or record migration is required to export this file.
struct ScriptWidgetDiagnosticExportButton: View {
    @State private var preparing = false
    @State private var exporting = false
    @State private var failed = false
    @State private var document = ScriptWidgetDiagnosticDocument()

    var body: some View {
        Button {
            preparing = true
            Task {
                do {
                    let data = try await Task.detached(priority: .utility) { try ScriptWidgetDiagnosticLog.shared.export() }.value
                    document = ScriptWidgetDiagnosticDocument(data: data)
                    exporting = true
                } catch { failed = true }
                preparing = false
            }
        } label: {
            Label(preparing ? "Preparing Logs…" : "Export Diagnostic Logs", systemImage: "square.and.arrow.up")
        }
        .disabled(preparing)
        .accessibilityIdentifier("diagnostics.export")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
            defaultFilename: "ScriptWidget-diagnostics") { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { failed = true }
            }
        .alert("Could Not Export Logs", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try exporting again and choose another save location.")
        }
    }
}

struct ScriptWidgetDiagnosticSettingsSection: View {
    var body: some View {
        Section {
            ScriptWidgetDiagnosticExportButton()
            ScriptWidgetDiagnosticFeedbackButton()
        } header: {
            Text("Diagnostics")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export recent library activity and error codes for support.")
                Text("Excludes script contents, personal records, paths and credentials.")
                Text("Logs stay on this device until you export them.")
            }
            .font(.caption)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScriptWidgetDiagnosticFeedbackButton: View {
    @State private var showingFeedback = false

    var body: some View {
        Button { showingFeedback = true } label: {
            Label("Report an Issue on GitHub", systemImage: "bubble.left.and.bubble.right")
        }
        .accessibilityIdentifier("diagnostics.feedback")
        .sheet(isPresented: $showingFeedback) { ScriptWidgetDiagnosticFeedbackView() }
    }
}

struct ScriptWidgetDiagnosticFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var openingFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                feedbackContent
                .frame(maxWidth: 520, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Feedback")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
#if os(macOS)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 560)
#endif
        .alert("Could Not Open GitHub", isPresented: $openingFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again, or visit github.com/everettjf/scriptwidget/issues in your browser.")
        }
    }

    // Kept separate from the native scroll/navigation containers for rendered
    // component captures in the cross-platform runtime test target.
    var feedbackContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Report a Problem").font(.title2.bold())
            Text("GitHub issues and attachments are public. Review your logs and screenshots before attaching them, and remove personal information from your description.")
            Text("1. Save your diagnostic logs").font(.headline)
            Text("Logs contain recent library activity and error codes on this device. They exclude script contents, personal records, paths and credentials.")
                .font(.callout).foregroundStyle(.secondary)
            ScriptWidgetDiagnosticExportButton().buttonStyle(.bordered)
            Text("2. Open the GitHub issue form").font(.headline)
            Text("Sign in to GitHub, describe what happened and attach the saved JSON file. Review the form, then choose Create. Logs are not attached automatically.")
                .font(.callout).foregroundStyle(.secondary)
            Text("The form will include these version details:").font(.callout)
            Text(ScriptWidgetDiagnosticIssueDraft.versions()).font(.caption).textSelection(.enabled)
            Button {
                guard let url = ScriptWidgetDiagnosticIssueDraft.url() else { openingFailed = true; return }
                openURL(url) { accepted in openingFailed = !accepted }
            } label: {
                Label("Open GitHub Issue Form", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("diagnostics.openIssue")
        }
    }
}
