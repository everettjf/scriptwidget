//
//  AIReviewView.swift
//  ScriptWidget
//
//  Shows the generated widget, lets the user refine it, inspect the
//  code / logs, discard, or save into the real Scripts library.
//

import SwiftUI
import WidgetKit

struct AIReviewView: View {
    @ObservedObject var session: AIGenerateSession
    /// Called when the user successfully saves (so the parent sheet can close).
    var onSaved: () -> Void

    @Environment(\.presentationMode) private var presentationMode

    @State private var refineInstruction: String = ""
    @State private var showingCodeSheet = false
    @State private var showingLogsSheet = false
    @State private var showingSaveNamePrompt = false
    @State private var saveName: String = ""
    @State private var saveError: String?
    @State private var isDebugMode = false
    @State private var previewPackage: ScriptWidgetPackage?

    private var jsx: String { session.lastJSX ?? "" }
    private var isExhausted: Bool {
        if case .exhausted = session.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                banner
                previewSection
                actionsSection
                refineSection

                if session.isRunning {
                    AIGenerateProgressView(session: session)
                }
            }
            .padding()
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                menuToolbar
            }
        }
        .sheet(isPresented: $showingCodeSheet) { codeSheet }
        .sheet(isPresented: $showingLogsSheet) { logsSheet }
        .alert("Save Widget", isPresented: $showingSaveNamePrompt) {
            TextField("Widget name", text: $saveName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { }
            Button("Save") { performSave() }
        } message: {
            Text("Choose a name for your new widget.")
        }
        .alert("Save Failed", isPresented: saveErrorBinding) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear(perform: ensurePreviewPackage)
        .onChange(of: jsx) {
            refreshPreviewPackage()
        }
    }

    // MARK: - sub-sections

    @ViewBuilder private var banner: some View {
        if isExhausted {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Did not fully converge — showing the last attempt.")
                    .font(.footnote)
            }
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var previewSection: some View {
        let size = session.size.previewSize
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
            previewContent(size: size)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Swift.max(size.height + 40, 200))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func previewContent(size: CGSize) -> some View {
        if let element = session.resultElement, let pkg = previewPackage {
            let context = ScriptWidgetElementContext(
                runtime: nil,
                debugMode: isDebugMode,
                scriptName: "AI Preview",
                scriptParameter: "",
                package: pkg
            )
            ScriptWidgetElementView(element: element, context: context)
                .frame(width: size.width, height: size.height)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(session.size.previewIsCircular ? size.height / 2 : 10)
        } else {
            Text("No preview available")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                presentationMode.wrappedValue.dismiss()
            } label: {
                Label("Discard", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Toggle(isOn: $isDebugMode) {
                Text("Debug")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Button {
                saveName = "AI " + AIReviewView.defaultNameFormatter.string(from: Date())
                showingSaveNamePrompt = true
            } label: {
                Label("Save Widget", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(jsx.isEmpty)
        }
    }

    private var refineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Refine")
                .font(.headline)
            Text("Ask the AI to change something — it'll iterate again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("e.g. use a darker background and larger title", text: $refineInstruction)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let instruction = refineInstruction
                    refineInstruction = ""
                    session.refine(currentCode: jsx, refineInstruction: instruction)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                }
                .disabled(jsx.isEmpty || refineInstruction.trimmingCharacters(in: .whitespaces).isEmpty || session.isRunning)
            }
        }
    }

    @ViewBuilder private var menuToolbar: some View {
        Menu {
            Button { showingCodeSheet = true } label: {
                Label("View Code", systemImage: "curlybraces")
            }
            Button { showingLogsSheet = true } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder private var codeSheet: some View {
        NavigationView {
            ScrollView {
                Text(jsx)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Generated JSX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showingCodeSheet = false }
                }
            }
        }
    }

    @ViewBuilder private var logsSheet: some View {
        NavigationView {
            List {
                ForEach(session.iterationHistory) { record in
                    Section("Iteration \(record.iteration)") {
                        if let err = record.errorSummary {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            Label("Success", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        if !record.logs.isEmpty {
                            ForEach(Array(record.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Iteration Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showingLogsSheet = false }
                }
            }
        }
    }

    // MARK: - helpers

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func ensurePreviewPackage() {
        if previewPackage == nil {
            previewPackage = try? AgentRuntimeBridge.shared.makeSandboxPackage(prefix: "preview")
        }
        refreshPreviewPackage()
    }

    private func refreshPreviewPackage() {
        guard let pkg = previewPackage else { return }
        _ = pkg.writeMainFile(content: jsx)
    }

    private func performSave() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "Widget name can not be empty."
            return
        }
        let result = sharedScriptManager.createScript(
            content: jsx,
            recommendPackageName: trimmed,
            imageCopyPath: nil
        )
        if result.0 {
            NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptCreateNotification, object: nil)
            WidgetCenter.shared.reloadAllTimelines()
            onSaved()
        } else {
            saveError = result.1
        }
    }

    private static let defaultNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()
}
