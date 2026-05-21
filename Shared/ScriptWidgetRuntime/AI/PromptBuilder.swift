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
        case .extraLarge:             return CGSize(width: 345, height: 329)
        case .accessoryInline:        return CGSize(width: 250, height: 30)
        case .accessoryCircular:      return CGSize(width: 72,  height: 72)
        case .accessoryRectangular:   return CGSize(width: 170, height: 72)
        }
    }

    var previewIsCircular: Bool { self == .accessoryCircular }

    var designHint: String {
        switch self {
        case .small:
            return "Square, ~155x155 px. Keep it to one or two key pieces of information."
        case .medium:
            return "Wide rectangle, ~329x155 px. Room for a small grid or two columns."
        case .large:
            return "Square, ~329x345 px. Multiple sections / richer layout."
        case .extraLarge:
            return "Wide rectangle (iPad), ~639x345 px. Dashboard-style density is fine."
        case .accessoryInline:
            return "Single line of text only. No colors, no layout containers beyond text."
        case .accessoryCircular:
            return "Very small round area (~72x72). Icon + a number at most."
        case .accessoryRectangular:
            return "Small rectangle (~160x72). A few short lines of text."
        }
    }
}

struct AIMessage {
    enum Role: String { case system, user, assistant }
    let role: Role
    let content: String
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
