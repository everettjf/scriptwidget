//
//  PromptBuilder.swift
//  ScriptWidget
//
//  Constructs system / user messages for the widget-generation agent
//  and strips code fences from LLM output.
//

import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum AIWidgetSize: String, CaseIterable, Identifiable, Codable {
    case small
    case medium
    case large
    case extraLarge
    case extraLargePortrait
    case accessoryInline
    case accessoryCircular
    case accessoryRectangular

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        case .extraLargePortrait: return "Extra Large Portrait"
        case .accessoryInline: return "Accessory Inline"
        case .accessoryCircular: return "Accessory Circular"
        case .accessoryRectangular: return "Accessory Rectangular"
        }
    }

    var previewSize: CGSize {
        switch self {
        case .small:                  return CGSize(width: 170, height: 170)
        case .medium:                 return CGSize(width: 329, height: 170)
        case .large:                  return CGSize(width: 329, height: 345)
        case .extraLarge:             return CGSize(width: 639, height: 345)
        case .extraLargePortrait:     return CGSize(width: 345, height: 639)
        case .accessoryInline:        return CGSize(width: 250, height: 30)
        case .accessoryCircular:      return CGSize(width: 72,  height: 72)
        case .accessoryRectangular:   return CGSize(width: 170, height: 72)
        }
    }

    var previewIsCircular: Bool { self == .accessoryCircular }

    var designHint: String {
        switch self {
        case .small:
            return "Square, ~170x170 px. Keep it to one or two key pieces of information."
        case .medium:
            return "Wide rectangle, ~329x170 px. Room for a small grid or two columns."
        case .large:
            return "Square, ~329x345 px. Multiple sections / richer layout."
        case .extraLarge:
            return "Wide rectangle (iPad), ~639x345 px. Dashboard-style density is fine."
        case .extraLargePortrait:
            return "Tall rectangle, ~345x639 px. Use vertically stacked sections and flexible sizing."
        case .accessoryInline:
            return "Single line of text only. No colors, no layout containers beyond text."
        case .accessoryCircular:
            return "Very small round area (~72x72). Icon + a number at most."
        case .accessoryRectangular:
            return "Small rectangle (~170x72). A few short lines of text."
        }
    }
}

struct AIMessage {
    enum Role: String { case system, user, assistant }
    let role: Role
    let content: String
}

struct AICopilotChangeSummary: Equatable {
    let originalLines: Int
    let proposedLines: Int
    let changedLines: Int

    static func compare(original: String, proposed: String) -> AICopilotChangeSummary {
        let before = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let after = proposed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sharedCount = min(before.count, after.count)
        let replacements = (0..<sharedCount).reduce(into: 0) { count, index in
            if before[index] != after[index] { count += 1 }
        }
        return AICopilotChangeSummary(
            originalLines: before.count,
            proposedLines: after.count,
            changedLines: replacements + abs(before.count - after.count)
        )
    }
}

enum PromptBuilder {
    static func systemPrompt(reference: AIReferenceSnapshot) -> String {
        let rules = """
        You are a ScriptWidget code generator. ScriptWidget runs widgets
        written in a constrained JSX dialect inside JavaScriptCore.
        Output ONLY a single JSX snippet — no markdown fences, no prose,
        no explanations, no surrounding backticks.

        RULES:
        1. Call $render(<...>) exactly once. The root element MUST be a
           layout container (vstack / hstack / zstack) unless you are
           targeting an accessoryInline widget.
        2. Do NOT use `import`, `require`, `module`, any Node APIs, or
           any DOM / browser APIs.
        3. Networking is ONLY via the globally injected `fetch(url)`
           (returns a string) or the `$http.*` API.
        4. Top-level `await` is allowed — the runtime wraps your code in
           an async `$main` function.
        5. Date/time: the global `moment` library is available. Plain JS
           `Date` also works.
        6. Persistent data: `$storage.set(key, value)` and
           `$storage.get(key)`.
        7. Only use tags, props, and APIs that appear in the REFERENCE
           section below. Do not invent new ones.
        8. When calling `fetch`, always wrap it in try/catch so the
           widget still renders something useful on network failure.
        9. Prefer readable typography (`font="title"`, `"headline"`,
           `"caption"`, `"caption2"`) and sensible spacing. Match the
           visual density to the declared widget size.
        10. Keep the output self-contained — no external files, no
           image assets the user hasn't provided.
        11. Respect light and dark appearances. Prefer color="primary"
            and color="secondary" for text. On accessory widgets use
            primary/secondary monochrome content with no background;
            never hardcode white text on a transparent background.
        12. Use frame="width,height" for explicit sizes, e.g. frame="60,60"
            for a ring inside a 72x72 accessory widget. Leave room for
            stroke thickness and padding. Do not apply frame="max" to
            every row: it expands height too. Use frame="max,24" for a
            full-width row with a fixed height when appropriate.
        13. Charts use data={$json([{label: "Mon", value: 3}])}, not JSX
            child marks. Keep chart axes legible: avoid a fixed dark
            background with default light-appearance axes. Prefer the
            default background or select a matching background using
            $device.isdarkmode().
        14. Preserve the requested labels and values. Do not invent
            meeting locations, extra events, or live data. For fixed
            demo data do not call network, location or Health APIs.
        """
        let reference = reference.combined
        return rules + "\n\n" + reference
    }

    static func userPromptFirst(userDescription: String, size: AIWidgetSize) -> String {
        """
        Widget size: \(size.rawValue)
        Size hint: \(size.designHint)

        User description:
        \(userDescription)

        Return the complete JSX snippet. No markdown, no explanation.
        """
    }

    static func userPromptFix(
        previousCode: String,
        errorSummary: String,
        recentLogs: [String]
    ) -> String {
        let logBlock: String
        if recentLogs.isEmpty {
            logBlock = "(no console output)"
        } else {
            logBlock = recentLogs.suffix(10).joined(separator: "\n")
        }
        return """
        Your previous code failed to run:

        ```jsx
        \(previousCode)
        ```

        Runtime feedback:
        \(errorSummary)

        Last console output:
        \(logBlock)

        Fix the code and return the FULL corrected JSX only. No markdown, no explanation.
        """
    }

    static func userPromptRefine(currentCode: String, refineInstruction: String) -> String {
        """
        Current working widget code:

        ```jsx
        \(currentCode)
        ```

        Apply this change request from the user:
        \(refineInstruction)

        Return the FULL updated JSX only. No markdown, no explanation.
        """
    }

    static func userPromptCopilot(
        currentCode: String,
        instruction: String,
        runtimeDiagnostic: String?
    ) -> String {
        let diagnosticBlock: String
        if let runtimeDiagnostic, !runtimeDiagnostic.isEmpty {
            diagnosticBlock = """

            The latest local ScriptWidget runtime diagnostic is:
            \(runtimeDiagnostic)
            """
        } else {
            diagnosticBlock = ""
        }
        return """
        You are editing an existing ScriptWidget project in ScriptWidget Studio.

        Current code:
        ```jsx
        \(currentCode)
        ```
        \(diagnosticBlock)

        User request:
        \(instruction)

        Preserve working behavior that is unrelated to the request. Use only documented
        ScriptWidget APIs. Return the FULL updated JSX only, with no markdown or explanation.
        """
    }

    // Best-effort extraction: prefer content between matching ```jsx ...
    // ``` fences, then strip any leading/trailing prose.
    static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer fenced block if present.
        if let fenced = extractFencedBlock(text) {
            text = fenced
        }

        // Drop stray code-fence markers.
        text = text.replacingOccurrences(of: "```jsx", with: "")
        text = text.replacingOccurrences(of: "```javascript", with: "")
        text = text.replacingOccurrences(of: "```js", with: "")
        text = text.replacingOccurrences(of: "```", with: "")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractFencedBlock(_ raw: String) -> String? {
        guard let openRange = raw.range(of: "```") else { return nil }
        let afterOpen = raw[openRange.upperBound...]
        // Skip optional language tag on the same line.
        let afterNewline: Substring
        if let nl = afterOpen.firstIndex(of: "\n") {
            afterNewline = afterOpen[afterOpen.index(after: nl)...]
        } else {
            afterNewline = afterOpen
        }
        guard let closeRange = afterNewline.range(of: "```") else { return nil }
        return String(afterNewline[..<closeRange.lowerBound])
    }
}
