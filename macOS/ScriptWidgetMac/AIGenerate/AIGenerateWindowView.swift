//
//  AIGenerateWindowView.swift
//  ScriptWidgetMac
//
//  The AI Generate experience for macOS, hosted inside a sheet. Shows
//  prompt input, progress, and — once a widget is produced — an inline
//  preview with refine / discard / save actions.
//

import SwiftUI
import WidgetKit

struct AIGenerateWindowView: View {
    static let openRequestNotification = Notification.Name("AIGenerateWindowViewOpenRequest")

    @Environment(\.dismiss) private var dismiss

    @StateObject private var session = AIGenerateSession()

    @State private var prompt: String = ""
    @State private var refineInstruction: String = ""
    @State private var saveName: String = ""
    @State private var saveError: String?
    @State private var showingCode: Bool = false
    @State private var showingLogs: Bool = false
    @State private var isDebugMode: Bool = false
    @State private var previewPackage: ScriptWidgetPackage?
    @State private var profiles: [AIProfile] = []
    @State private var activeProfileID: String = ""

    private var jsx: String { session.lastJSX ?? "" }
    private var hasResult: Bool {
        switch session.phase {
        case .done, .exhausted: return true
        default: return false
        }
    }
    private var isExhausted: Bool {
        if case .exhausted = session.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                inputSide
                    .frame(minWidth: 300, idealWidth: 380)
                previewSide
                    .frame(minWidth: 300, idealWidth: 420)
            }
            Divider()
            footer
        }
        .frame(idealWidth: 860, minHeight: 520, idealHeight: 620)
        .frame(minWidth: 720)
        .onAppear {
            ensurePreviewPackage()
            prefillSaveNameIfNeeded()
            loadProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            loadProfiles()
        }
        .onChange(of: jsx) {
            refreshPreviewPackage()
            prefillSaveNameIfNeeded()
        }
        .sheet(isPresented: $showingCode) { codeSheet }
        .sheet(isPresented: $showingLogs) { logsSheet }
        .alert("Save Failed", isPresented: saveErrorBinding) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - layout

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Widget Generator").font(.title3.weight(.semibold))
                Text("Describe what you want; the AI will iterate until the widget runs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var inputSide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Prompt").font(.headline)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 140)
                    .border(Color.secondary.opacity(0.3))

                examplesSection

                if profiles.count > 1 {
                    HStack {
                        Text("Profile")
                        Picker("", selection: $activeProfileID) {
                            ForEach(profiles) { profile in
                                Text(profile.name.isEmpty ? "Unnamed" : profile.name).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: activeProfileID) { _, newValue in
                            AISettingsStore.shared.setActiveProfile(id: newValue)
                        }
                    }
                }

                HStack {
                    Text("Size")
                    Picker("", selection: $session.size) {
                        ForEach(AIWidgetSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .labelsHidden()
                }

                Button {
                    session.start(userDescription: prompt)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text(session.isRunning ? "Generating..." : "Generate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if session.isRunning || hasResult {
                    AIGenerateProgressView(session: session)
                }

                if hasResult {
                    Divider().padding(.vertical, 4)
                    Text("Refine").font(.headline)
                    Text("Ask the AI to change something — it will iterate again on top of the current code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("e.g. use a darker background", text: $refineInstruction)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let instruction = refineInstruction
                            refineInstruction = ""
                            session.refine(currentCode: jsx, refineInstruction: instruction)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .disabled(jsx.isEmpty || refineInstruction.trimmingCharacters(in: .whitespaces).isEmpty || session.isRunning)
                    }
                }
            }
            .padding(12)
        }
    }

    private var previewSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Toggle("Debug", isOn: $isDebugMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if isExhausted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Did not fully converge — showing the last attempt.")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            }

            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                previewContent
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .cornerRadius(12)

            HStack {
                Button { showingCode = true } label: {
                    Label("Code", systemImage: "curlybraces")
                }
                Button { showingLogs = true } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
                Spacer()
            }
            .disabled(jsx.isEmpty)
        }
        .padding(12)
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Try an example")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AIExamplePrompts.all) { example in
                        Button {
                            prompt = example.prompt
                            session.size = example.size
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: example.symbol)
                                Text(example.title)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        let size = session.size.previewSize
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
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(session.size.previewIsCircular ? size.height / 2 : 10)
        } else {
            Text(session.isRunning ? "Generating..." : "No preview yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("Tokens used: \(session.usage.totalTokens)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                dismiss()
            } label: {
                Label("Discard", systemImage: "trash")
            }

            TextField("Widget name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)

            Button {
                performSave()
            } label: {
                Label("Save Widget", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(jsx.isEmpty || saveName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private var codeSheet: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Generated JSX").font(.headline)
                Spacer()
                Button("Done") { showingCode = false }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(jsx)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private var logsSheet: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Iteration Logs").font(.headline)
                Spacer()
                Button("Done") { showingLogs = false }
                    .keyboardShortcut(.defaultAction)
            }
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
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - helpers

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func loadProfiles() {
        profiles = AISettingsStore.shared.loadProfiles()
        activeProfileID = AISettingsStore.shared.loadActiveProfileID()
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

    private func prefillSaveNameIfNeeded() {
        guard saveName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saveName = "AI " + AIGenerateWindowView.defaultNameFormatter.string(from: Date())
    }

    private static let defaultNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

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
            NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
            WidgetCenter.shared.reloadAllTimelines()
            dismiss()
        } else {
            saveError = result.1
        }
    }
}
