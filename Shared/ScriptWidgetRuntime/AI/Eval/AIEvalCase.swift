//
//  AIEvalCase.swift
//  ScriptWidget
//
//  One row of the AI generation benchmark dataset.
//
//  The dataset is built primarily from the 44 bundled templates'
//  meta.json files: each template's `description` field becomes the
//  user prompt and the template name becomes the case id, so a single
//  build of the app already comes with a representative benchmark.
//  Adversarial cases (intended to expose current weaknesses) are
//  layered on top from a separate JSON file in the bundle when
//  present.
//

import Foundation

enum AIEvalCaseSource: String, Codable {
    case template
    case adversarial
}

struct AIEvalCase: Identifiable, Codable, Equatable {
    let id: String          // unique within a dataset version
    let name: String        // human-readable label
    let prompt: String      // user description fed to the agent
    let size: AIWidgetSize
    let source: AIEvalCaseSource
    let category: String?   // template category (weather / health / …) or nil
    let difficulty: String? // easy / medium / hard, when known
    let tags: [String]
}

enum AIEvalDataset {
    /// Build the standard dataset: every template that has a meta.json
    /// becomes one case at the medium widget size.
    static func loadStandard() -> [AIEvalCase] {
        let templateCases = loadTemplateCases()
        let adversarialCases = loadAdversarialCases()
        return templateCases + adversarialCases
    }

    static func loadTemplateCases() -> [AIEvalCase] {
        guard let bundleURL = scriptBundleURL() else { return [] }
        let templateRoot = bundleURL.appendingPathComponent("template", isDirectory: true)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: templateRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var cases: [AIEvalCase] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(TemplateMeta.self, from: data) else {
                continue
            }
            let name = dir.lastPathComponent
            let prompt = meta.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { continue }
            cases.append(AIEvalCase(
                id: "tpl/\(name)",
                name: name,
                prompt: prompt,
                size: .medium,
                source: .template,
                category: meta.category,
                difficulty: meta.difficulty,
                tags: meta.tags ?? []
            ))
        }
        return cases
    }

    /// Optional adversarial layer. Looked up at
    /// `Script.bundle/eval/adversarial.json`. Returns [] when missing.
    static func loadAdversarialCases() -> [AIEvalCase] {
        guard let bundleURL = scriptBundleURL() else { return [] }
        let url = bundleURL
            .appendingPathComponent("eval", isDirectory: true)
            .appendingPathComponent("adversarial.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([AdversarialEntry].self, from: data) else {
            return []
        }
        return entries.map { entry in
            AIEvalCase(
                id: "adv/\(entry.id)",
                name: entry.name,
                prompt: entry.prompt,
                size: AIWidgetSize(rawValue: entry.size ?? "medium") ?? .medium,
                source: .adversarial,
                category: entry.category,
                difficulty: entry.difficulty,
                tags: entry.tags ?? []
            )
        }
    }

    private static func scriptBundleURL() -> URL? {
        // Script.bundle is shipped as a resource of the AI module's
        // host bundle (the main app). Search the main bundle then any
        // bundle that has Script.bundle inside it.
        if let url = Bundle.main.url(forResource: "Script", withExtension: "bundle") {
            return url
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let url = bundle.url(forResource: "Script", withExtension: "bundle") {
                return url
            }
        }
        return nil
    }
}

private struct TemplateMeta: Decodable {
    let description: String
    let category: String?
    let tags: [String]?
    let difficulty: String?
}

private struct AdversarialEntry: Decodable {
    let id: String
    let name: String
    let prompt: String
    let size: String?
    let category: String?
    let difficulty: String?
    let tags: [String]?
}
