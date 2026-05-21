//
//  AIReferenceSnapshot.swift
//  ScriptWidget
//
//  Builds a compact reference manual for the LLM's system prompt by
//  sampling real usage examples from Script.bundle (component / api).
//  Cached after first build.
//

import Foundation

struct AIReferenceSnapshot {
    let componentsBlock: String
    let apisBlock: String

    var combined: String {
        var out = ""
        if !componentsBlock.isEmpty {
            out += "=== COMPONENTS (JSX tags) ===\n"
            out += componentsBlock
            out += "\n"
        }
        if !apisBlock.isEmpty {
            out += "=== APIs (globals) ===\n"
            out += apisBlock
        }
        return out
    }
}

enum AIReferenceSnapshotLoader {
    // Cap per-file lines so the prompt stays bounded.
    private static let maxLinesPerFile = 40

    // If the full block is larger than this many chars, fall back to a
    // curated subset of APIs.
    private static let softCharBudget = 60_000

    private static let priorityAPIs: [String] = [
        "fetch", "http", "storage", "location", "health",
        "device", "file", "getenv", "system", "console",
    ]

    private static var cached: AIReferenceSnapshot?

    static func load() -> AIReferenceSnapshot {
        if let cached = cached {
            return cached
        }
        let snapshot = build()
        cached = snapshot
        return snapshot
    }

    private static func build() -> AIReferenceSnapshot {
        guard let bundleURL = Bundle.main.url(forResource: "Script", withExtension: "bundle") else {
            return AIReferenceSnapshot(componentsBlock: "", apisBlock: "")
        }

        let componentsBlock = readSection(
            rootURL: bundleURL.appendingPathComponent("component"),
            whitelist: nil
        )

        // First attempt: all APIs.
        var apisBlock = readSection(
            rootURL: bundleURL.appendingPathComponent("api"),
            whitelist: nil
        )

        let overBudget = (componentsBlock.count + apisBlock.count) > softCharBudget
        if overBudget {
            apisBlock = readSection(
                rootURL: bundleURL.appendingPathComponent("api"),
                whitelist: Set(priorityAPIs)
            )
        }

        return AIReferenceSnapshot(componentsBlock: componentsBlock, apisBlock: apisBlock)
    }

    private static func readSection(rootURL: URL, whitelist: Set<String>?) -> String {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: rootURL.path) else {
            return ""
        }
        var pieces: [String] = []
        for name in entries.sorted() {
            if let whitelist = whitelist, !whitelist.contains(name) {
                continue
            }
            let mainJsx = rootURL.appendingPathComponent(name).appendingPathComponent("main.jsx")
            guard let content = try? String(contentsOf: mainJsx, encoding: .utf8) else {
                continue
            }
            let trimmed = limit(content, lines: maxLinesPerFile)
            pieces.append("// === \(name) ===\n\(trimmed)")
        }
        return pieces.joined(separator: "\n\n")
    }

    private static func limit(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.count <= lines {
            return text
        }
        return all.prefix(lines).joined(separator: "\n") + "\n// ..."
    }
}
