//
//  SkillManagerView.swift
//  ScriptWidgetMac
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let scriptWidgetSkill = UTType(exportedAs: "com.everettjf.scriptwidget.skill", conformingTo: .zip)
}

private struct SkillArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.scriptWidgetSkill] }
    var data = Data()

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SkillManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var skills: [AIWidgetSkill] = AIWidgetSkills.builtIns
    @State private var selectedID: String?
    @State private var draftManifest = AIWidgetSkillManifest.newSkill(name: "Skill")
    @State private var draftInstruction = ""
    @State private var statusMessage: String?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument = SkillArchiveDocument()
    @State private var exportFilename = "skill.swskill"
    @State private var confirmingDelete = false

    private var selectedSkill: AIWidgetSkill? { skills.first { $0.id == selectedID } }
    private var isEditable: Bool { selectedSkill?.isBuiltIn == false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                skillList.frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                detail.frame(minWidth: 480, idealWidth: 620)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 580, idealHeight: 700)
        .onAppear(perform: reload)
        .onChange(of: selectedID) { _, _ in loadSelection() }
        .onReceive(NotificationCenter.default.publisher(for: AIWidgetSkillManager.changedNotification)) { _ in reload() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.scriptWidgetSkill, .zip]) { result in
            importSkill(result)
        }
        .fileDialogMessage("Choose a ScriptWidget .swskill package")
        .fileDialogConfirmationLabel("Import Skill")
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .scriptWidgetSkill,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { statusMessage = error.localizedDescription }
        }
        .confirmationDialog("Delete this custom skill?", isPresented: $confirmingDelete) {
            Button("Delete Skill", role: .destructive, action: deleteSelection)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The skill package will be removed from synced storage.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ScriptWidget Skills").font(.title3.weight(.semibold))
                Text("Write reusable AI guidance, then import or share it as a safe text-only package.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Built-in") {
                    ForEach(skills.filter(\.isBuiltIn)) { skill in skillRow(skill) }
                }
                Section("My Skills") {
                    ForEach(skills.filter { !$0.isBuiltIn }) { skill in skillRow(skill) }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button("New", systemImage: "plus", action: createSkill)
                Button("Import", systemImage: "square.and.arrow.down") { showingImporter = true }
                Spacer()
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Duplicate", systemImage: "plus.square.on.square", action: duplicateSelection)
                        .disabled(selectedSkill == nil)
                    Button("Export…", systemImage: "square.and.arrow.up", action: prepareExport)
                        .disabled(selectedSkill == nil)
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(!isEditable)
                }
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
    }

    private func skillRow(_ skill: AIWidgetSkill) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.title)
                Text("v\(skill.version) · \(skill.summary)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: skill.symbol)
        }
        .tag(skill.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        if let skill = selectedSkill {
            Form {
                Section("Identity") {
                    TextField("Name", text: $draftManifest.name).disabled(!isEditable)
                    LabeledContent("Identifier", value: draftManifest.id).textSelection(.enabled)
                    TextField("Version", text: $draftManifest.version).disabled(!isEditable)
                    TextField("SF Symbol", text: $draftManifest.symbol).disabled(!isEditable)
                    TextField("Author", text: optionalBinding(\AIWidgetSkillManifest.author)).disabled(!isEditable)
                }
                Section("Discovery") {
                    TextField("Summary", text: $draftManifest.summary, axis: .vertical).disabled(!isEditable)
                    TextField("Tags (comma separated)", text: tagsBinding).disabled(!isEditable)
                }
                Section("SKILL.md") {
                    TextEditor(text: $draftInstruction)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 250)
                        .disabled(!isEditable)
                    Text("The complete Markdown text is appended to AI requests. Skills cannot execute code, access secrets, or grant permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if skill.isBuiltIn {
                    Section {
                        Button("Duplicate to Edit", systemImage: "plus.square.on.square", action: duplicateSelection)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "Select a Skill",
                systemImage: "wand.and.stars",
                description: Text("Choose a built-in skill to inspect it, or create your own.")
            )
        }
    }

    private var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Skills sync beside your widget projects.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal Skills Folder", systemImage: "folder") {
                MacKitUtil.revealInFinder(AIWidgetSkillManager.shared.directory.path)
            }
            Button("Save", systemImage: "square.and.arrow.down", action: saveSelection)
                .buttonStyle(.borderedProminent)
                .disabled(!isEditable)
        }
        .padding(10)
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { draftManifest.tags.joined(separator: ", ") },
            set: { value in
                draftManifest.tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        )
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<AIWidgetSkillManifest, String?>) -> Binding<String> {
        Binding(get: { draftManifest[keyPath: keyPath] ?? "" }, set: { draftManifest[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func reload() {
        let previous = selectedID
        skills = AIWidgetSkillManager.shared.allSkills()
        selectedID = skills.contains(where: { $0.id == previous }) ? previous : skills.first?.id
        loadSelection()
    }

    private func loadSelection() {
        guard let skill = selectedSkill else { return }
        if let package = AIWidgetSkillManager.shared.package(for: skill.id), let (manifest, instruction) = package.load() {
            draftManifest = manifest; draftInstruction = instruction
        } else {
            var manifest = AIWidgetSkillManifest.newSkill(name: skill.title)
            manifest.id = skill.id; manifest.version = skill.version; manifest.summary = skill.summary
            manifest.symbol = skill.symbol; manifest.tags = skill.tags; manifest.author = skill.author
            draftManifest = manifest; draftInstruction = skill.instruction
        }
        statusMessage = nil
    }

    private func createSkill() {
        let result = AIWidgetSkillManager.shared.create(name: "Untitled Skill")
        statusMessage = result.0 ? "Created a new editable skill." : result.1
        if result.0 { selectedID = result.1 }
    }

    private func saveSelection() {
        guard let selectedID else { return }
        let result = AIWidgetSkillManager.shared.save(skillID: selectedID, manifest: draftManifest, instruction: draftInstruction)
        statusMessage = result.0 ? "Saved \(draftManifest.name)." : result.1
    }

    private func duplicateSelection() {
        guard let skill = selectedSkill else { return }
        let result = AIWidgetSkillManager.shared.duplicate(skill)
        statusMessage = result.0 ? "Created an editable copy." : result.1
        if result.0 { selectedID = result.1 }
    }

    private func deleteSelection() {
        guard let selectedID else { return }
        let result = AIWidgetSkillManager.shared.delete(skillID: selectedID)
        statusMessage = result.0 ? "Skill deleted." : result.1
    }

    private func prepareExport() {
        guard let skill = selectedSkill else { return }
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(AIWidgetSkillValidator.slug(skill.title)).swskill")
        let result = AIWidgetSkillManager.shared.export(skillID: skill.id, to: temporaryURL)
        guard result.0, let data = try? Data(contentsOf: temporaryURL) else { statusMessage = result.1; return }
        try? FileManager.default.removeItem(at: temporaryURL)
        exportDocument = SkillArchiveDocument(data: data)
        exportFilename = "\(AIWidgetSkillValidator.slug(skill.title)).swskill"
        showingExporter = true
    }

    private func importSkill(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { statusMessage = error.localizedDescription }
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let imported = AIWidgetSkillManager.shared.importSkill(from: url)
        statusMessage = imported.succeeded ? "Skill imported." : imported.message
        if imported.succeeded { selectedID = imported.skillID }
    }
}
