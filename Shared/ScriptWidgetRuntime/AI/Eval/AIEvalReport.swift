//
//  AIEvalReport.swift
//  ScriptWidget
//
//  Markdown + JSON serialization for AIEvalReport. The JSON form is
//  the source of truth (re-importable for cross-run diffs); the
//  markdown is the human-readable summary.
//

import Foundation

enum AIEvalReportError: LocalizedError {
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .writeFailed(let s): return "Could not write eval report: \(s)"
        }
    }
}

enum AIEvalReportWriter {
    /// Default location: app-group container's AIEval/<runID>/.
    /// Falls back to NSTemporaryDirectory if the group container is
    /// unavailable on this run.
    static func defaultRunDirectory(runID: String) -> URL {
        let base: URL
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget"
        ) {
            base = group.appendingPathComponent("AIEval", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ScriptWidgetAIEval", isDirectory: true)
        }
        return base.appendingPathComponent(runID, isDirectory: true)
    }

    /// Write report.json + report.md + per-failure attempt files into
    /// the given directory. Returns the directory.
    @discardableResult
    static func write(_ report: AIEvalReport, to dir: URL? = nil) throws -> URL {
        let target = dir ?? defaultRunDirectory(runID: report.runID)
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )

        // JSON
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: target.appendingPathComponent("report.json"))
        } catch {
            throw AIEvalReportError.writeFailed(error.localizedDescription)
        }

        // Markdown
        let md = markdown(report)
        do {
            try md.write(
                to: target.appendingPathComponent("report.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw AIEvalReportError.writeFailed(error.localizedDescription)
        }

        // Per-failure dumps so it's easy to read what the model did
        // when it didn't pass.
        let failuresDir = target.appendingPathComponent("failures", isDirectory: true)
        let failingResults = report.results.filter { $0.passRate < 1.0 }
        if !failingResults.isEmpty {
            try? FileManager.default.createDirectory(
                at: failuresDir, withIntermediateDirectories: true
            )
            for result in failingResults {
                for attempt in result.attempts where !attempt.success {
                    let safeName = result.evalCase.name.replacingOccurrences(
                        of: "/", with: "_"
                    )
                    let url = failuresDir.appendingPathComponent(
                        "\(safeName)-attempt\(attempt.attempt).md"
                    )
                    let body = failureMarkdown(case: result.evalCase, attempt: attempt)
                    try? body.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }

        return target
    }

    // MARK: - markdown

    static func markdown(_ r: AIEvalReport) -> String {
        var s = ""
        s += "# AI Generation Benchmark — \(r.runID)\n\n"
        s += "## Run config\n\n"
        s += "| Field | Value |\n"
        s += "| ----- | ----- |\n"
        s += "| Started | \(iso(r.startedAt)) |\n"
        s += "| Finished | \(iso(r.finishedAt)) |\n"
        s += "| Duration | \(formatDuration(r.totalDuration)) |\n"
        s += "| Host | \(r.baseURLHost) |\n"
        s += "| Model | \(r.modelID) |\n"
        s += "| Temperature | \(String(format: "%.2f", r.temperature)) |\n"
        s += "| Max iterations | \(r.maxIterations) |\n"
        s += "| Prompt version | \(r.promptVersion) |\n"
        s += "| Attempts / case | \(r.attemptsPerCase) |\n"
        s += "| Parallelism | \(r.parallelism) |\n\n"

        s += "## Summary\n\n"
        s += "- **Pass rate**: \(percent(r.overallPassRate)) (\(r.totalPasses)/\(r.totalAttempts))\n"
        s += "- **Cases**: \(r.totalCases) total — "
        s += "\(r.perfectCases) perfect, "
        s += "\(r.partialCases) partial, "
        s += "\(r.failedCases) failed\n"
        s += "- **Total tokens**: \(formatInt(r.totalTokens))\n"
        let avgIter = avgIterations(across: r.results)
        s += "- **Avg iterations** (successful attempts): "
        s += avgIter.map { String(format: "%.2f", $0) } ?? "—"
        s += "\n\n"

        // By difficulty
        if let table = breakdown(by: { $0.evalCase.difficulty ?? "unspecified" }, results: r.results) {
            s += "## By difficulty\n\n"
            s += table
            s += "\n"
        }

        // By category
        if let table = breakdown(by: { $0.evalCase.category ?? "uncategorized" }, results: r.results) {
            s += "## By category\n\n"
            s += table
            s += "\n"
        }

        s += "## Per-case\n\n"
        s += "| Case | Source | Pass | Avg iter | Avg tokens | Notes |\n"
        s += "| ---- | ------ | ---- | -------- | ---------- | ----- |\n"
        for result in r.results {
            let case_ = result.evalCase
            let passCell = "\(result.passCount)/\(result.totalAttempts)"
            let iterCell = String(format: "%.2f", result.avgIterations)
            let tokenCell = formatInt(Int(result.avgTokens))
            let firstError = result.attempts.first(where: { !$0.success })?.error ?? ""
            let notes = result.passRate == 1.0
                ? ""
                : truncated(firstError, max: 60)
            s += "| \(case_.name) | \(case_.source.rawValue) | \(passCell) | \(iterCell) | \(tokenCell) | \(escapePipes(notes)) |\n"
        }
        s += "\n"

        s += "## Failures\n\n"
        let failing = r.results.filter { $0.passRate < 1.0 }
        if failing.isEmpty {
            s += "_No failures._\n"
        } else {
            for result in failing {
                s += "### \(result.evalCase.name) (\(result.passCount)/\(result.totalAttempts))\n\n"
                s += "_\(result.evalCase.prompt)_\n\n"
                for attempt in result.attempts where !attempt.success {
                    s += "- attempt \(attempt.attempt + 1): \(attempt.error ?? "unknown error") "
                    s += "(\(attempt.iterations) iter, \(attempt.totalTokens) tok, \(String(format: "%.1f", attempt.durationSec))s)\n"
                }
                s += "\n"
            }
        }
        return s
    }

    // MARK: - helpers

    private static func failureMarkdown(case c: AIEvalCase, attempt: AIEvalAttempt) -> String {
        var s = "# \(c.name) — attempt \(attempt.attempt + 1)\n\n"
        s += "**Source**: \(c.source.rawValue)\n\n"
        s += "**Size**: \(c.size.rawValue)\n\n"
        s += "**Prompt**:\n\n```\n\(c.prompt)\n```\n\n"
        s += "**Error**: \(attempt.error ?? "—")\n\n"
        s += "**Iterations used**: \(attempt.iterations)\n\n"
        s += "**Tokens**: \(attempt.totalTokens) (prompt \(attempt.promptTokens), completion \(attempt.completionTokens))\n\n"
        s += "**Duration**: \(String(format: "%.2f", attempt.durationSec))s\n\n"
        if let jsx = attempt.jsx, !jsx.isEmpty {
            s += "## Last produced JSX\n\n"
            s += "```jsx\n\(jsx)\n```\n"
        }
        return s
    }

    private static func breakdown(
        by key: (AIEvalCaseResult) -> String,
        results: [AIEvalCaseResult]
    ) -> String? {
        let grouped = Dictionary(grouping: results, by: key)
        guard grouped.count > 1 else { return nil }
        var s = "| Group | Cases | Pass rate |\n| ----- | ----- | --------- |\n"
        let sorted = grouped.sorted { $0.key < $1.key }
        for (k, group) in sorted {
            let totalAttempts = group.reduce(0) { $0 + $1.totalAttempts }
            let totalPasses = group.reduce(0) { $0 + $1.passCount }
            let rate = totalAttempts > 0
                ? Double(totalPasses) / Double(totalAttempts) : 0
            s += "| \(k) | \(group.count) | \(percent(rate)) |\n"
        }
        return s
    }

    private static func avgIterations(across results: [AIEvalCaseResult]) -> Double? {
        let successful = results.flatMap { $0.attempts }.filter { $0.success }
        guard !successful.isEmpty else { return nil }
        let sum = successful.reduce(0) { $0 + $1.iterations }
        return Double(sum) / Double(successful.count)
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func percent(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    private static func formatInt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return "\(m)m \(s)s"
    }

    private static func truncated(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    private static func escapePipes(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
