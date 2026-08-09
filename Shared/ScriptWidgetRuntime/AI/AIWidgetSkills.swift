//
//  AIWidgetSkills.swift
//  ScriptWidget
//
//  Versioned, plain-text Skills 1.0 packages. Skills only contribute prompt
//  instructions; they never execute code or grant runtime permissions.
//

import Foundation
import ZipArchive

struct AIWidgetSkill: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var version: String
    var symbol: String
    var summary: String
    var instruction: String
    var tags: [String]
    var author: String?
    var minimumRuntimeVersion: String
    var isBuiltIn: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, version, symbol, summary, instruction, tags, author, minimumRuntimeVersion
    }

    init(
        id: String,
        title: String,
        version: String = "1.0.0",
        symbol: String,
        summary: String,
        instruction: String,
        tags: [String] = [],
        author: String? = nil,
        minimumRuntimeVersion: String = "1.0",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.symbol = symbol
        self.summary = summary
        self.instruction = instruction
        self.tags = tags
        self.author = author
        self.minimumRuntimeVersion = minimumRuntimeVersion
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        version = try values.decode(String.self, forKey: .version)
        symbol = try values.decode(String.self, forKey: .symbol)
        summary = try values.decode(String.self, forKey: .summary)
        instruction = try values.decode(String.self, forKey: .instruction)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        author = try values.decodeIfPresent(String.self, forKey: .author)
        minimumRuntimeVersion = try values.decode(String.self, forKey: .minimumRuntimeVersion)
        isBuiltIn = false
    }
}

struct AIWidgetSkillManifest: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var id: String
    var name: String
    var version: String
    var summary: String
    var symbol: String
    var promptFile: String
    var tags: [String]
    var author: String?
    var minimumRuntimeVersion: String

    static func newSkill(name: String) -> AIWidgetSkillManifest {
        let slug = AIWidgetSkillValidator.slug(name)
        return AIWidgetSkillManifest(
            formatVersion: currentFormatVersion,
            id: "local.\(slug).\(UUID().uuidString.lowercased())",
            name: name,
            version: "1.0.0",
            summary: "Reusable instructions for ScriptWidget AI.",
            symbol: "wand.and.stars",
            promptFile: "SKILL.md",
            tags: [],
            author: nil,
            minimumRuntimeVersion: ScriptWidgetBuildContract.runtimeAPIVersion
        )
    }
}

struct AIWidgetSkillValidationIssue: Identifiable, Equatable {
    let id: String
    let message: String
}

struct AIWidgetSkillValidationReport: Equatable {
    var issues: [AIWidgetSkillValidationIssue]
    var isValid: Bool { issues.isEmpty }
}

enum AIWidgetSkillValidator {
    static let maximumInstructionBytes = 64 * 1024
    static let maximumManifestBytes = 32 * 1024
    static let maximumPackageBytes = 256 * 1024

    static func validate(manifest: AIWidgetSkillManifest, instruction: String) -> AIWidgetSkillValidationReport {
        var issues: [AIWidgetSkillValidationIssue] = []
        func reject(_ id: String, _ message: String) { issues.append(.init(id: id, message: message)) }

        if manifest.formatVersion != AIWidgetSkillManifest.currentFormatVersion {
            reject("unsupported_format", "Skill format \(manifest.formatVersion) is not supported.")
        }
        if manifest.id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$", options: .regularExpression) == nil {
            reject("invalid_id", "Skill id must use 3–128 letters, numbers, dots, or hyphens.")
        }
        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 80 { reject("invalid_name", "Skill name must contain 1–80 characters.") }
        if manifest.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$", options: .regularExpression) == nil {
            reject("invalid_version", "Skill version must be semantic, for example 1.0.0.")
        }
        if manifest.minimumRuntimeVersion != ScriptWidgetBuildContract.runtimeAPIVersion {
            reject("unsupported_runtime", "Skill requires runtime \(manifest.minimumRuntimeVersion), but this app supports \(ScriptWidgetBuildContract.runtimeAPIVersion).")
        }
        if manifest.promptFile != "SKILL.md" { reject("invalid_prompt_file", "Skills 1.0 requires promptFile to be SKILL.md.") }
        if manifest.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manifest.summary.count > 240 {
            reject("invalid_summary", "Skill summary must contain 1–240 characters.")
        }
        if manifest.symbol.isEmpty || manifest.symbol.count > 80 { reject("invalid_symbol", "Skill symbol is invalid.") }
        if manifest.tags.count > 20 || Set(manifest.tags.map { $0.lowercased() }).count != manifest.tags.count {
            reject("invalid_tags", "Use at most 20 unique tags.")
        }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInstruction.isEmpty { reject("empty_instruction", "SKILL.md must contain instructions.") }
        if instruction.utf8.count > maximumInstructionBytes { reject("instruction_too_large", "SKILL.md exceeds 64 KiB.") }
        return .init(issues: issues)
    }

    static func slug(_ value: String) -> String {
        let result = value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "skill" : result
    }
}

struct AIWidgetSkillPackage {
    let directory: URL
    var manifestURL: URL { directory.appendingPathComponent("skill.json") }
    var instructionURL: URL { directory.appendingPathComponent("SKILL.md") }

    func load() -> (AIWidgetSkillManifest, String)? {
        guard let manifestData = try? Data(contentsOf: manifestURL),
              manifestData.count <= AIWidgetSkillValidator.maximumManifestBytes,
              let object = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else { return nil }
        let allowed: Set<String> = [
            "formatVersion", "id", "name", "version", "summary", "symbol",
            "promptFile", "tags", "author", "minimumRuntimeVersion"
        ]
        guard Set(object.keys).isSubset(of: allowed),
              let manifest = try? JSONDecoder().decode(AIWidgetSkillManifest.self, from: manifestData),
              let instructionData = try? Data(contentsOf: instructionURL),
              instructionData.count <= AIWidgetSkillValidator.maximumInstructionBytes,
              let instruction = String(data: instructionData, encoding: .utf8) else { return nil }
        return (manifest, instruction)
    }

    @discardableResult
    func save(manifest: AIWidgetSkillManifest, instruction: String) -> (Bool, String) {
        let report = AIWidgetSkillValidator.validate(manifest: manifest, instruction: instruction)
        guard report.isValid else { return (false, report.issues.map(\.message).joined(separator: "\n")) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try Data(instruction.utf8).write(to: instructionURL, options: .atomic)
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func skill(isBuiltIn: Bool = false) -> AIWidgetSkill? {
        guard let (manifest, instruction) = load(),
              AIWidgetSkillValidator.validate(manifest: manifest, instruction: instruction).isValid else { return nil }
        return AIWidgetSkill(
            id: manifest.id,
            title: manifest.name,
            version: manifest.version,
            symbol: manifest.symbol,
            summary: manifest.summary,
            instruction: instruction,
            tags: manifest.tags,
            author: manifest.author,
            minimumRuntimeVersion: manifest.minimumRuntimeVersion,
            isBuiltIn: isBuiltIn
        )
    }
}

struct AIWidgetSkillImportResult: Equatable {
    let succeeded: Bool
    let skillID: String?
    let message: String
}

final class AIWidgetSkillManager {
    static let changedNotification = Notification.Name("AIWidgetSkillManagerChanged")
    static let shared = AIWidgetSkillManager()

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let scripts = ScriptManager.getICloudPriorityRootDirectory().0
            self.directory = scripts.deletingLastPathComponent().appendingPathComponent("Skills", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func allSkills() -> [AIWidgetSkill] {
        let custom = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { AIWidgetSkillPackage(directory: $0).skill() }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let customIDs = Set(custom.map(\.id))
        return AIWidgetSkills.builtIns.filter { !customIDs.contains($0.id) } + custom
    }

    func package(for skillID: String) -> AIWidgetSkillPackage? {
        guard let url = packageDirectories().first(where: { AIWidgetSkillPackage(directory: $0).load()?.0.id == skillID }) else { return nil }
        return AIWidgetSkillPackage(directory: url)
    }

    @discardableResult
    func create(name: String) -> (Bool, String) {
        let manifest = AIWidgetSkillManifest.newSkill(name: name)
        let package = AIWidgetSkillPackage(directory: uniquePackageDirectory(preferredName: name))
        let result = package.save(
            manifest: manifest,
            instruction: "# \(name)\n\nDescribe the expert guidance this skill should add to an AI request.\n"
        )
        if result.0 { notifyChanged() }
        return result.0 ? (true, manifest.id) : result
    }

    @discardableResult
    func save(skillID: String, manifest: AIWidgetSkillManifest, instruction: String) -> (Bool, String) {
        guard manifest.id == skillID, let package = package(for: skillID) else { return (false, "Skill identity cannot be changed.") }
        let result = package.save(manifest: manifest, instruction: instruction)
        if result.0 { notifyChanged() }
        return result
    }

    @discardableResult
    func duplicate(_ skill: AIWidgetSkill) -> (Bool, String) {
        var manifest = AIWidgetSkillManifest.newSkill(name: "\(skill.title) Copy")
        manifest.summary = skill.summary
        manifest.symbol = skill.symbol
        manifest.tags = skill.tags
        manifest.author = skill.author
        let package = AIWidgetSkillPackage(directory: uniquePackageDirectory(preferredName: manifest.name))
        let result = package.save(manifest: manifest, instruction: skill.instruction)
        if result.0 { notifyChanged() }
        return result.0 ? (true, manifest.id) : result
    }

    @discardableResult
    func delete(skillID: String) -> (Bool, String) {
        guard let package = package(for: skillID) else { return (false, "Built-in skills cannot be deleted.") }
        do {
            try FileManager.default.removeItem(at: package.directory)
            notifyChanged()
            return (true, "")
        } catch { return (false, error.localizedDescription) }
    }

    func export(skillID: String, to archiveURL: URL) -> (Bool, String) {
        let package: AIWidgetSkillPackage
        var temporaryDirectory: URL?
        if let custom = self.package(for: skillID) {
            package = custom
        } else if let builtIn = AIWidgetSkills.builtIns.first(where: { $0.id == skillID }) {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("SkillExport-\(UUID().uuidString)", isDirectory: true)
            temporaryDirectory = temp
            var manifest = AIWidgetSkillManifest.newSkill(name: builtIn.title)
            manifest.id = builtIn.id; manifest.version = builtIn.version; manifest.summary = builtIn.summary
            manifest.symbol = builtIn.symbol; manifest.tags = builtIn.tags; manifest.author = builtIn.author
            package = AIWidgetSkillPackage(directory: temp)
            guard package.save(manifest: manifest, instruction: builtIn.instruction).0 else { return (false, "Could not prepare the built-in skill.") }
        } else {
            return (false, "Skill not found.")
        }
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        try? FileManager.default.removeItem(at: archiveURL)
        let succeeded = SSZipArchive.createZipFile(
            atPath: archiveURL.path,
            withContentsOfDirectory: package.directory.path,
            keepParentDirectory: false
        )
        return succeeded ? (true, "") : (false, "Could not create the .swskill archive.")
    }

    func importSkill(from archiveURL: URL) -> AIWidgetSkillImportResult {
        guard (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= AIWidgetSkillValidator.maximumPackageBytes else {
            return .init(succeeded: false, skillID: nil, message: "A Skill package may not exceed 256 KiB.")
        }
        if let message = ScriptPackageArchivePreflight.validate(archiveURL) {
            return .init(succeeded: false, skillID: nil, message: message)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("SkillImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        guard SSZipArchive.unzipFile(atPath: archiveURL.path, toDestination: temp.path),
              let root = importedPackageRoot(in: temp) else {
            return .init(succeeded: false, skillID: nil, message: "The archive must contain one Skills 1.0 package.")
        }
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard Set(children) == ["skill.json", "SKILL.md"],
              let (manifest, instruction) = AIWidgetSkillPackage(directory: root).load() else {
            return .init(succeeded: false, skillID: nil, message: "Skills 1.0 allows only skill.json and SKILL.md.")
        }
        let report = AIWidgetSkillValidator.validate(manifest: manifest, instruction: instruction)
        guard report.isValid else {
            return .init(succeeded: false, skillID: nil, message: report.issues.map(\.message).joined(separator: "\n"))
        }
        guard !allSkills().contains(where: { $0.id == manifest.id }) else {
            return .init(succeeded: false, skillID: nil, message: "A skill with id \(manifest.id) is already installed.")
        }
        let destination = uniquePackageDirectory(preferredName: manifest.name)
        do {
            try FileManager.default.copyItem(at: root, to: destination)
            notifyChanged()
            return .init(succeeded: true, skillID: manifest.id, message: "")
        } catch {
            return .init(succeeded: false, skillID: nil, message: error.localizedDescription)
        }
    }

    private func packageDirectories() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
    }

    private func uniquePackageDirectory(preferredName: String) -> URL {
        let base = AIWidgetSkillValidator.slug(preferredName)
        var candidate = directory.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private func importedPackageRoot(in root: URL) -> URL? {
        let children = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        if children.contains(where: { $0.lastPathComponent == "skill.json" }) { return root }
        let directories = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        return directories.count == 1 ? directories[0] : nil
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}

enum AIWidgetSkills {
    static let builtIns: [AIWidgetSkill] = [
        .init(id: "responsive-layout", title: "Responsive Layout", symbol: "rectangle.3.group", summary: "Adapt one script to every widget family.", instruction: "Use $getenv(\"widget-size\") to create intentional small, medium, and large layouts. Keep the information hierarchy readable in every family.", tags: ["layout"], isBuiltIn: true),
        .init(id: "accessible-design", title: "Accessible Design", symbol: "accessibility", summary: "Improve contrast, hierarchy, and legibility.", instruction: "Use strong text/background contrast, avoid color as the only signal, keep important text legible, and prefer concise labels.", tags: ["accessibility"], isBuiltIn: true),
        .init(id: "resilient-data", title: "Resilient Data", symbol: "network.badge.shield.half.filled", summary: "Handle network and missing-data failures.", instruction: "When data is remote or optional, validate it and render a useful fallback state. Never expose secrets or invent unsupported runtime APIs.", tags: ["network", "safety"], isBuiltIn: true),
        .init(id: "visual-polish", title: "Visual Polish", symbol: "paintbrush.pointed", summary: "Apply a coherent native visual system.", instruction: "Create a restrained native-looking visual system with consistent spacing, typography, color, and alignment. Avoid decorative clutter.", tags: ["design"], isBuiltIn: true),
        .init(id: "runtime-debugger", title: "Runtime Debugger", symbol: "ladybug", summary: "Repair errors with the smallest safe change.", instruction: "Prioritize the supplied runtime diagnostic. Make the smallest correction that fixes it, preserve unrelated behavior, and use only documented ScriptWidget APIs.", tags: ["debugging"], isBuiltIn: true),
    ]

    static var all: [AIWidgetSkill] { AIWidgetSkillManager.shared.allSkills() }

    static func augment(_ prompt: String, selectedIDs: Set<String>) -> String {
        let selected = all.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return prompt }
        let instructions = selected.map { "- \($0.title) v\($0.version):\n  \($0.instruction.replacingOccurrences(of: "\n", with: "\n  "))" }.joined(separator: "\n")
        return """
        \(prompt)

        Apply these ScriptWidget skills:
        \(instructions)
        """
    }
}
