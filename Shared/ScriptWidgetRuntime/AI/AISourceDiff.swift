//
//  AISourceDiff.swift
//  ScriptWidget
//
//  What changed between two versions of a widget's code, line by line, and
//  the view that shows it. Computed on the device; nothing is sent anywhere.
//  The Kotlin port is AiSourceDiff.
//

import SwiftUI

enum AISourceDiff {
    enum Kind: Equatable {
        case same
        case added
        case removed
        /// A run of unchanged lines that is left out; `text` is empty.
        case skipped(count: Int)
    }

    struct Line: Equatable, Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    struct Summary: Equatable {
        let added: Int
        let removed: Int
        var isEmpty: Bool { added == 0 && removed == 0 }
    }

    /// Unchanged lines kept around a change.
    static let contextLines = 3
    /// Above this many lines the comparison is not made; the caller shows the code instead.
    static let maxLines = 4_000

    static func split(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// How many lines were added and removed; nil when either side is too long to compare.
    static func summary(old: String, new: String) -> Summary? {
        guard let all = fullLines(old: old, new: new) else { return nil }
        return Summary(added: all.filter { $0.kind == .added }.count, removed: all.filter { $0.kind == .removed }.count)
    }

    /// The changed lines with a few unchanged ones around them; nil when either side is too long.
    static func lines(old: String, new: String, context: Int = contextLines) -> [Line]? {
        guard let all = fullLines(old: old, new: new) else { return nil }
        guard all.contains(where: { $0.kind != .same }) else { return [] }
        // Keep a line when a change is within `context` lines of it.
        var keep = [Bool](repeating: false, count: all.count)
        for (index, line) in all.enumerated() where line.kind != .same {
            for near in max(0, index - context)...min(all.count - 1, index + context) { keep[near] = true }
        }
        var result: [Line] = []
        var skipped = 0
        func flush() {
            if skipped > 0 { result.append(Line(id: result.count, kind: .skipped(count: skipped), text: "")) }
            skipped = 0
        }
        for (index, line) in all.enumerated() {
            if keep[index] {
                flush()
                result.append(Line(id: result.count, kind: line.kind, text: line.text))
            } else {
                skipped += 1
            }
        }
        flush()
        return result
    }

    private static func fullLines(old: String, new: String) -> [(kind: Kind, text: String)]? {
        let before = split(old), after = split(new)
        guard before.count <= maxLines, after.count <= maxLines else { return nil }
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(kind: Kind, text: String)] = []
        var oldIndex = 0, newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if oldIndex < before.count, removed.contains(oldIndex) {
                result.append((.removed, before[oldIndex]))
                oldIndex += 1
            } else if newIndex < after.count, inserted.contains(newIndex) {
                result.append((.added, after[newIndex]))
                newIndex += 1
            } else if oldIndex < before.count, newIndex < after.count {
                result.append((.same, after[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return result
    }
}

/// The changes of one version against the one it was made from.
struct AISourceDiffView: View {
    let old: String
    let new: String

    var body: some View {
        if let lines = AISourceDiff.lines(old: old, new: new) {
            if lines.isEmpty {
                Text("The code is the same.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line) }
                    }
                    .padding(.vertical, 8)
                }
            }
        } else {
            Text("These versions are too long to compare line by line.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    @ViewBuilder
    private func row(_ line: AISourceDiff.Line) -> some View {
        switch line.kind {
        case .skipped(let count):
            Text("⋯ \(count) unchanged line\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        case .same:
            code(" ", line.text, background: .clear, label: "Unchanged")
        case .added:
            code("+", line.text, background: Color.green.opacity(0.18), label: "Added")
        case .removed:
            code("−", line.text, background: Color.red.opacity(0.16), label: "Removed")
        }
    }

    /// The sign is drawn as well as the color, so that the color is not the only cue.
    private func code(_ sign: String, _ text: String, background: Color, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(text.isEmpty ? " " : text)
                .textSelection(.enabled)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(text)")
    }
}

/// "+3 −2" on a version's line; opens the changes of that version.
struct AIVersionChangesButton: View {
    let title: String
    let old: String
    let new: String

    @State private var isShown = false

    var body: some View {
        if let summary = AISourceDiff.summary(old: old, new: new), !summary.isEmpty {
            Button {
                isShown = true
            } label: {
                Text("+\(summary.added) −\(summary.removed)")
                    .font(.caption.monospacedDigit())
            }
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif
            .accessibilityLabel("\(summary.added) lines added, \(summary.removed) removed. Show the changes.")
            .sheet(isPresented: $isShown) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline)
                            Text("\(summary.added) line\(summary.added == 1 ? "" : "s") added, \(summary.removed) removed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Done") { isShown = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                    Divider()
                    AISourceDiffView(old: old, new: new)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 420)
                #endif
            }
        }
    }
}
