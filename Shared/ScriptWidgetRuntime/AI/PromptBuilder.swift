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

/// What one conversation turn sends to the model.
struct AITurnContext {
    struct Exchange: Equatable {
        let request: String
        let note: String?
    }
    /// Earlier applied turns, oldest first.
    let history: [Exchange]
    /// The widget as it is now; nil when the turn starts a new widget.
    let currentCode: String?
    /// The version before the current one, if any.
    let previousCode: String?
    let request: String
    /// Formatted text of the selected Skills; nil for none.
    let skillsText: String?
    let size: AIWidgetSize
    /// Hosts the current widget declares it contacts.
    var currentDomains: [String] = []
    /// What the editor's preview last reported for this widget, if it failed.
    var runtimeDiagnostic: String? = nil
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
        6. Persistent data: `$storage.setString(key, value)` and
           `$storage.getString(key)` for strings; `$storage.setJSON(key, object)`
           and `$storage.getJSON(key)` for objects. Check write success.
           Do not invent `$storage.set` or `$storage.get`.
           `$storage` stays local. Opt-in `$icloud` requires permission `icloud`,
           minimumRuntimeVersion 1.5 and an explicit native app connection.
           readJSON(name) returns {value,revision,state,conflicts}; user actions
           can writeJSON(name,value,revision) or explicitly resolveJSON after
           reviewing every head. Never claim a local save is already uploaded,
           silently migrate existing records or choose a store ID in scripts.
           Browser previews use isolated mocks, not real iCloud.
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
            frame="max,leading" fills both directions and aligns the content
            (center, leading, trailing, top, bottom, topLeading, ...). There
            is no "auto" and no space after the comma: for a full-width row
            as tall as its content, put a <spacer/> inside the <hstack>.
            <text>, <date>, <image> and the other tags without children take
            no tags inside them: write <date ... /> next to a <text>, not in it.
            A linear $gradient needs both points, e.g. $gradient({type: "linear",
            colors: ["#0f172a", "#166534"], startPoint: "top", endPoint: "bottom"}).
        13. Charts use data={$json([{label: "Mon", value: 3}])}, not JSX
            child marks. Keep chart axes legible: avoid a fixed dark
            background with default light-appearance axes. Prefer the
            default background or select a matching background using
            $device.isdarkmode().
        14. Preserve the requested labels and values. Do not invent
            meeting locations, extra events, or live data. For fixed
            demo data do not call network, location, Health, Calendar or Reminders APIs.
        15. Calendar needs the calendar package permission and system approval
            in ScriptWidget Settings. Preview mocks do not grant access.
            Native Settings source selection also limits calendar metadata,
            events and cached snapshots. Obtain permitted IDs with calendars();
            scripts cannot enlarge this selection. Show setup for no sources.
            Photos requires photos permission and explicit photo/album selection in
            native Settings, empty by default. $photos.items({limit:4}) returns
            metadata-stripped JPEG data URLs in items[].image; render with <image url>.
            Support authorized and limited status. Up to four thumbnails per call,
            64 candidates, maxAgeSeconds up to 86400. Cloud-only photos must be
            downloaded in Photos first; show unavailableCount and setup states.
            Future entries and Live Activity presentations need a prepared snapshot.
            Do not use a Web sample as evidence of native access or seed fake photos.
            Connected account profiles use await $services.status("github") and
            await $services.profile("github"), services + network permissions and
            api.github.com. The installed widget owner must be allowed in native
            Service Accounts. Tokens never belong in scripts, parameters, mocks
            or AI context. Preserve null private counts; do not turn errors into
            zero data. Only GitHub connected-service profiles are supported. Service reads
            cannot run in future entries or Live Activity presentations.
            Music app playback uses $music.isAvailable(), authorizationStatus()
            and await $music.current(), with music permission and native Settings
            approval. This is a read-only iOS Music app snapshot, unavailable on
            macOS and unrelated to other audio players. State can remain playing
            while track details are withheld. Preserve nullable metadata/seconds,
            show permission/unavailable states and never infer subscription.
            No playback/queue changes, library scans or live future-entry reads.
            Runtime 1.4 supports backgroundMaterial="thin" (ultraThin/thin/regular/
            thick/ultraThick/none) using public SwiftUI material inside the widget,
            at most four material backgrounds per tree. Supply a readable background
            color for Reduce Transparency. Accented/vibrant modes omit local material.
            This is not Home Screen wallpaper blur or a switch for system Liquid Glass.
            rotation3d is static depth and falls back with Reduce Motion. Do not
            promise device-motion parallax, continuous widget animation or system
            wallpaper control. Web CSS material is an approximation.
            GIF input/canvas/frame/decoded-pixel limits apply. Mac and Reduce Motion
            use a bounded static first frame. Active previews use public SwiftUI timing;
            snapshots/inactive scenes stay static. Signed clockCustom intervals are
            half-turn durations; no private clock modifier is used. A mock is not proof of native
            continuous animation. Prefer small original assets; no decoder SDK is needed.
            Reminders needs the reminders package permission and system approval.
            Use lists() for permitted IDs; items() is read-only with listIDs,
            start/end (up to 31 days), limit (up to 50) and completed Boolean.
            Pending items use due dates (undated items excluded); completed items
            use completion dates. create/update/setCompleted require remindersWrite,
            a declared native user action and a saved stable requestID UUID.
            Always await writes. Reuse the same requestID after uncertain delivery;
            outcome_unknown requires user inspection, never a blind new create.
            Do not request remindersWrite for display-only widgets. Web Studio
            simulates actions and persists only preview items/receipts.
            Health read permissions are private: authorizationStatus returns
            notDisclosed, and completing consent review is not proof of access.
            Empty Health results may mean no records or data not shared.
            API 1.4 sleepSummary reads at most 7 elapsed days/256 segments;
            activitySummary reads one Gregorian local day with nullable goals
            and kcal or move-time minutes; workouts reads at most 31 days/50
            wholly contained items with nullable energy/distance. Sleep uses
            interval unions with awake/rem/deep/core/unspecified precedence,
            not Apple Health source ranking. Never persist Health readings or
            query/prompt from future entries or Live Activity presentations.
            Health Overview supports overview/sleep/activity/workouts parameters;
            Web Studio supplies editable simulated aggregates, not native access.
            Runtime 1.6 adds $notifications.status/pending/schedule/cancel,
            $alarms.status/pending/schedule/cancel/stop/pause/resume,
            $calendar.create/update, $health.dailyStatistics,
            $documents.list/readJSON/readCSV, $contacts.selected,
            $maps.search/geocode/reverseGeocode/snapshot,
            $weather.forecast and $home.items/setPower/runScene.
            These require Package 2.0 minimumRuntimeVersion 1.6. Declare the
            matching permission; Calendar writes also require calendarWrite.
            Weather requires weather, network and api.met.no; return and display
            provider attribution. New capabilities need native per-widget System
            Access except Health, which uses Health Settings review. Copies do
            not inherit grants. All calls share eight queries and reject in future
            entries/Live Activities; writes require explicit native user actions.
            Persist a canonical requestID UUID before calendar/alarm/scene writes;
            uncertain outcomes require inspection, never a blind new operation.
            Native replay receipts are bounded and completed ones expire after
            seven days. Documents use imported native UUIDs, never arbitrary paths.
            Contacts/Home expose native selections only. Home values are cached,
            and scene actions may require system authentication. AlarmKit needs
            iOS/iPadOS 26; native macOS must show unavailable. Mocks do not prove
            native authorization, system delivery or physical accessory state.
        16. Location needs the location package permission and approval in the
            main app. Widget access is separate: use isAuthorizedForWidgetUpdates
            when explaining widget setup, never infer permission from cached data.
            Catch current() failures and show a useful setup or unavailable state.
            Show age/isStale when displaying a cached position; do not invent a fix.
        17. Scheduled widgets use timeline-date/timeline-slot from $getenv, not
            a replaced Date global. Future entries are read-only: do not save
            records, prompt for access or fetch live data while projecting them.
            Buttons run separate current actions. Use saved display snapshots
            and label their age; do not imply future personal measurements exist.
        18. $file.exists(path) checks regular files inside the current package,
            including binary images. It cannot read outside the package or
            download iCloud content, and does not validate image bytes.
            Give a useful missing-resource state instead of inventing a photo.
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
            // A script may print anything, including what it read from the
            // device, so only short tails of the last lines are sent.
            logBlock = recentLogs.suffix(10).map { clip($0, 300) }.joined(separator: "\n")
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

    /// One turn of a conversation: what was said before, the widget as it is
    /// now, and the new request. The earlier turns travel as text inside this
    /// one message, so the system prompt stays the same from turn to turn.
    static func userPromptTurn(_ context: AITurnContext) -> String {
        var parts: [String] = []
        parts.append("""
        You are working with the user on one ScriptWidget widget over several turns.
        Widget size: \(context.size.rawValue)
        Size hint: \(context.size.designHint)
        """)

        if let skills = context.skillsText, !skills.isEmpty {
            parts.append("Apply these ScriptWidget skills in every turn:\n" + skills)
        }

        if !context.history.isEmpty {
            let lines = context.history.enumerated().map { index, exchange -> String in
                let request = clip(exchange.request, AIConversationLimits.historyRequestCharacters)
                let note = clip(exchange.note ?? "Done.", AIConversationLimits.historyNoteCharacters)
                return "\(index + 1). User: \(request)\n   You: \(note)"
            }
            parts.append("Earlier turns, oldest first (each one was applied):\n" + lines.joined(separator: "\n"))
        }

        if let previous = context.previousCode, !previous.isEmpty,
           previous.count <= AIConversationLimits.previousSourceCharacters {
            parts.append("""
            The version before your last change, for reference only (the user may ask to bring something back):

            ```jsx
            \(previous)
            ```
            """)
        }

        if let current = context.currentCode, !current.isEmpty {
            parts.append("""
            Current working widget code:

            ```jsx
            \(current)
            ```

            \(context.currentDomains.isEmpty ? "It declares no network use." : "Its network declaration: " + AINetworkDeclaration(domains: context.currentDomains).json)

            \(context.runtimeDiagnostic.map { "The latest local ScriptWidget runtime diagnostic is:\n" + clip($0, 2_000) } ?? "")

            The user now asks:
            \(context.request)

            Change only what the request needs and keep everything else as it is.
            """)
        } else {
            parts.append("The user asks for a new widget:\n\(context.request)")
        }

        let canEdit = !(context.currentCode ?? "").isEmpty
        parts.append("""
        Reply in exactly this form, which replaces the output rule above for this conversation:
        SUMMARY: one short sentence saying what you made or changed, in the language the user wrote in
        \(canEdit ? editReplyRule : "then the FULL widget code in one ```jsx fenced block.")
        If, and only if, the widget uses `fetch` or `$http`, end with one more fenced block
        that declares every host it contacts:
        ```json
        {"permissions": ["network"], "networkDomains": ["api.example.com"]}
        ```
        Hosts are exact lowercase names or `*.example.com`. A host that is not declared is
        blocked. No other permission can be declared. Nothing else.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// How a turn that changes existing code may answer: with all of the code,
    /// or with the places that change. See AISourceEdits.
    static let editReplyRule = """
    then EITHER the FULL widget code in one ```jsx fenced block,
    OR, when only a few places change, edit blocks instead of the full code:
    ```edit
    <<<<<<< SEARCH
    lines copied exactly from the current code, with their indentation
    =======
    the lines that replace them
    >>>>>>> REPLACE
    ```
    Write one SEARCH/REPLACE pair for each place, as many as the change needs. Each SEARCH
    text must be in the current code exactly once: copy enough neighbouring lines to make
    it so. An empty REPLACE part deletes the lines. Prefer edit blocks for a small change
    and the full code when most of the widget changes. Never use both forms in one reply.
    """

    /// Splits a turn reply into the model's note, the widget code and the
    /// network declaration, if any. A reply without the SUMMARY line or without
    /// a fence is still read as code.
    static func parseTurnReply(_ raw: String) -> (note: String?, code: String, declaration: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // The declaration is the last ```json block; take it out first so that
        // it can never be mistaken for the widget.
        var declaration: String?
        if let open = text.range(of: "```json", options: .backwards),
           let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
            declaration = String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeSubrange(open.lowerBound..<close.upperBound)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let fenceStart = text.range(of: "```")?.lowerBound ?? text.endIndex
        var note: String?
        var body = text
        let head = text[..<fenceStart]
        for line in head.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("summary:") else { continue }
            let value = trimmed.dropFirst("summary:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { note = clip(value, 300) }
            if fenceStart == text.endIndex, let range = text.range(of: String(line)) {
                body.removeSubrange(range)
            }
            break
        }
        // The code ends with a line break, like a file. The runtime puts its own
        // closing text right after the source, so a last line that is a `//`
        // comment would otherwise swallow it.
        return (note, stripCodeFences(body) + "\n", declaration)
    }

    /// Added to a repair request inside a conversation, where the declaration
    /// block is still allowed.
    static let turnRepairSuffix = """

    Keep the reply form of this conversation: the full code in one ```jsx block, then the
    ```json network declaration block only if the widget uses the network.
    """

    /// What the text written so far looks like as code, for showing it while it arrives.
    static func previewOfPartialReply(_ partial: String) -> String {
        guard let open = partial.range(of: "```") else { return partial }
        var code = partial[open.upperBound...]
        if let newline = code.firstIndex(of: "\n") { code = code[code.index(after: newline)...] } else { return "" }
        if let close = code.range(of: "```") { code = code[..<close.lowerBound] }
        return String(code)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
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
