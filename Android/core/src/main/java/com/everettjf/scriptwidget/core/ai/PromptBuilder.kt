package com.everettjf.scriptwidget.core.ai

import com.everettjf.scriptwidget.core.PlatformSupport
import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.api.StorageModule
import com.everettjf.scriptwidget.core.js.QuickJs
import com.everettjf.scriptwidget.core.pkg.PackageLimits

/** Home-screen sizes the Android release can place. Port of the system cases of `AIWidgetSize`. */
enum class AiWidgetSize(val family: String, val displayName: String, val designHint: String) {
    SMALL("small", "Small", "Square, ~160x160 dp. Keep it to one or two key pieces of information."),
    MEDIUM("medium", "Medium", "Wide rectangle, ~330x160 dp. Room for a small grid or two columns."),
    LARGE("large", "Large", "Square, ~330x330 dp. Multiple sections / richer layout.");

    companion object {
        /** The size for a preview family name; unknown names fall back to [MEDIUM]. */
        fun fromFamily(family: String?): AiWidgetSize = entries.firstOrNull { it.family == family } ?: MEDIUM
    }
}

/**
 * Compact reference manual for the system prompt, built from the usage
 * examples in `Script.bundle` (`component/<name>/main.jsx`, `api/<name>/main.jsx`):
 * the same files `AIReferenceSnapshotLoader` samples on Apple platforms.
 */
class AiReference(val componentsBlock: String, val apisBlock: String) {
    /** Port of `AIReferenceSnapshot.combined`. */
    val combined: String
        get() {
            val out = StringBuilder()
            if (componentsBlock.isNotEmpty()) out.append("=== COMPONENTS (JSX tags) ===\n").append(componentsBlock).append("\n")
            if (apisBlock.isNotEmpty()) out.append("=== APIs (globals) ===\n").append(apisBlock)
            return out.toString()
        }

    companion object {
        /** Cap per file so the prompt stays bounded. */
        const val MAXIMUM_LINES_PER_FILE = 40
        /** Above this many characters only [PRIORITY_APIS] are kept. */
        const val SOFT_CHARACTER_BUDGET = 60_000
        /** `AIReferenceSnapshotLoader.priorityAPIs`. */
        val PRIORITY_APIS = listOf("fetch", "http", "storage", "location", "health", "calendar", "device", "file", "getenv", "system", "console")
        /**
         * Bundled API examples for globals Android does not implement; showing them would invite
         * their use. Derived from [PlatformSupport.unsupportedGlobals]: an example directory is
         * named after its global without the `$`.
         */
        val ANDROID_EXCLUDED_APIS: Set<String> = PlatformSupport.unsupportedGlobals.keys.map { it.removePrefix("\$") }.toSet()
        /** Bundled component examples with no Android surface. */
        val ANDROID_EXCLUDED_COMPONENTS = setOf("live-activity")

        val EMPTY = AiReference("", "")

        /**
         * Builds the reference from example sources keyed by directory name.
         * Port of `AIReferenceSnapshotLoader.build`, minus the examples Android cannot run.
         */
        fun build(components: Map<String, String>, apis: Map<String, String>): AiReference {
            val componentsBlock = section(components.filterKeys { it !in ANDROID_EXCLUDED_COMPONENTS }, null)
            val usable = apis.filterKeys { it !in ANDROID_EXCLUDED_APIS }
            var apisBlock = section(usable, null)
            if (componentsBlock.length + apisBlock.length > SOFT_CHARACTER_BUDGET) apisBlock = section(usable, PRIORITY_APIS.toSet())
            return AiReference(componentsBlock, apisBlock)
        }

        private fun section(sources: Map<String, String>, whitelist: Set<String>?): String =
            sources.keys.sorted().filter { whitelist == null || it in whitelist }.joinToString("\n\n") { name -> "// === $name ===\n${limit(sources.getValue(name))}" }

        private fun limit(text: String): String {
            val lines = text.split("\n")
            return if (lines.size <= MAXIMUM_LINES_PER_FILE) text else lines.take(MAXIMUM_LINES_PER_FILE).joinToString("\n") + "\n// ..."
        }
    }
}

/** What Android cannot do and does differently, phrased for the model. */
object AndroidPromptNotes {
    /**
     * One line per capability Android lacks. Everything here comes from [PlatformSupport], which
     * is also what the app tells the user and what a candidate is checked against after it ran;
     * a global that a native module implements must never be named here.
     */
    fun unsupportedLines(): List<String> {
        val lines = LinkedHashSet<String>()
        lines += PlatformSupport.unsupportedGlobals.values
        // The marker is what a candidate is searched for, so the model is given it by name.
        for ((marker, reason) in PlatformSupport.unsupportedSourceMarkers) lines += if (reason.contains(marker)) reason else "$marker: $reason"
        lines += "Lock Screen accessory sizes (${PlatformSupport.unsupportedFamilies.joinToString(", ")}) do not exist; only small, medium and large."
        return lines.toList()
    }

    /**
     * The system data APIs, which all work on Android, with what differs from iPhone where a
     * model needs to know it. Kept to one line each: the table is under "System data" in
     * `docs/android/README.md`. The reference has an example for `$health`, `$calendar` and `$location`.
     */
    fun systemDataLines(): List<String> = listOf(
        "Each needs its permission in widget.json, which you cannot declare (rule 3), and the user's approval in the app. " +
            "In this preview they report unavailable or reject: check isAvailable() and authorizationStatus() where they exist, " +
            "wrap calls in try/catch and render a short setup message. The user adds the permission after saving.",
        // The examples of these two are longer than the reference shows, so the calls are named here.
        "await \$health.stepCountToday(), activeEnergyToday() and heartRateLatest() give {value} from Health Connect; ring goals and stand time are null.",
        "await \$location.current({timeout: 10}) gives {latitude, longitude, accuracy, age, isStale} and may be a saved position: show its age. There is no background location.",
        "\$calendar sees only the calendars the user selected in the app.",
        "\$photos.items({limit: 4}) returns only photos the user picked in the app, as items[].image for <image url>; there are no albums.",
        "\$services.status(\"github\") and profile(\"github\") use a GitHub token the user enters in the app (no sign-in), " +
            "with the services and network permissions and api.github.com. Never put a token in code.",
        "\$notifications and \$alarms (status, pending, schedule, cancel) are inexact: up to about ten minutes late, no snooze.",
        "\$music.current() is the active media session of any app; its provider is \"androidMediaSession\".",
        "\$maps.search, geocode and reverseGeocode work; search finds named places and addresses, not business categories.",
        "\$icloud keeps its data in a sync folder the user chooses in the app, not in iCloud.",
        "\$weather.forecast, \$documents.list/readJSON/readCSV, \$contacts.selected and \$dataSource.request work as on iPhone.",
    )

    /**
     * What only Android has: the scrolling `<list>` and the `material.<role>` colors. The
     * reference is built from the examples the Apple apps ship, which show neither. Kept short:
     * the full description is under "Only on Android" in `docs/android/README.md`.
     */
    fun androidOnlyLines(): List<String> = listOf(
        "`<list spacing=\"4\">{rows}</list>` is a vertical stack that scrolls inside the widget; each child is a row. " +
            "Use it when the rows may not all fit: one list per widget, at most 100 rows, in a vstack under any title. " +
            "It takes `spacing` and the general props; <link>, <button> and <toggle> work in a row.",
        "Wallpaper colors: every color prop takes \"material.<role>\" (also \"material.primary,0.5\", and in a \$gradient); " +
            "the system supplies the light and the dark value. Roles: primary, onPrimary, primaryContainer, onPrimaryContainer, " +
            "the same four for secondary and tertiary, background, onBackground, surface, onSurface, surfaceVariant, onSurfaceVariant, " +
            "surfaceContainer (also with Lowest, Low, High or Highest appended), outline, outlineVariant. " +
            "Text takes the \"on\" role of its background, e.g. background=\"material.surfaceContainer\" with color=\"material.onSurface\". " +
            "Use them when the user asks to follow the wallpaper or the system colors.",
    )

    /** The budgets the Android runtime enforces on every run. */
    fun runtimeLimitLines(): List<String> = listOf(
        "A run must finish within 5 seconds, including all awaited network calls.",
        "JavaScript memory is limited to ${QuickJs.DEFAULT_MEMORY_LIMIT / (1024 * 1024)} MiB.",
        "main.jsx may be at most ${PackageLimits.MAX_SCRIPT_BYTES / 1024} KiB.",
        "Network: at most ${FetchModule.MAXIMUM_REQUESTS} requests per run (${FetchModule.MAXIMUM_CONCURRENT} concurrent), each response at most ${FetchModule.MAXIMUM_RESPONSE_BYTES / (1024 * 1024)} MiB, " +
            "each request body at most ${FetchModule.MAXIMUM_REQUEST_BODY_BYTES / (1024 * 1024)} MiB, ${FetchModule.MAXIMUM_TOTAL_MILLISECONDS / 1000} seconds per request. Only public http(s) hosts; no localhost or private addresses.",
        "\$storage: at most ${StorageModule.MAXIMUM_KEYS} keys, ${StorageModule.MAXIMUM_VALUE_BYTES / 1024} KiB per value, ${StorageModule.MAXIMUM_TOTAL_BYTES / (1024 * 1024)} MiB in total.",
    )
}

/**
 * Builds the system and user messages of the widget-generation agent.
 * Port of `PromptBuilder` in `Shared/ScriptWidgetRuntime/AI/PromptBuilder.swift`.
 */
object PromptBuilder {
    /** Skills text beyond this many characters is cut; Skills 1.0 instructions are at most 64 KiB each. */
    const val MAXIMUM_SKILLS_CHARACTERS = 64 * 1024

    /**
     * The system prompt: generation rules, the Android limits, the unsupported
     * list, what only Android has, then the component/API reference.
     *
     * The rules follow the Swift prompt. Its long rules about the system data
     * APIs are replaced by the short SYSTEM DATA section, what Android lacks is
     * in the unsupported list, and the output contract gains an optional
     * package declaration because an Android package always has a manifest
     * that must declare network access.
     */
    fun systemPrompt(
        reference: AiReference,
        unsupported: List<String> = AndroidPromptNotes.unsupportedLines(),
        runtimeLimits: List<String> = AndroidPromptNotes.runtimeLimitLines(),
    ): String {
        val rules = """
            You are a ScriptWidget code generator. ScriptWidget runs widgets
            written in a constrained JSX dialect inside a sandboxed JavaScript
            engine. This widget will run on ScriptWidget for Android.
            Output ONLY a single JSX snippet: no prose, no explanations.
            The one exception is the package declaration described in rule 3.

            RULES:
            1. Call ${'$'}render(<...>) exactly once. The root element MUST be a
               layout container (vstack / hstack / zstack).
            2. Do NOT use `import`, `require`, `module`, any Node APIs, or
               any DOM / browser APIs.
            3. Networking is ONLY via the globally injected `fetch(url)`
               (returns a string) or the `${'$'}http.*` API. A widget that uses the
               network MUST end its answer, after the JSX, with exactly one fenced
               block that declares the permission and every host it contacts:
               ```json
               {"permissions": ["network"], "networkDomains": ["api.example.com"]}
               ```
               Hosts are exact names or `*.example.com`. Undeclared hosts are
               blocked. A widget that does not use the network must not add
               this block. No other permission can be declared.
            4. Top-level `await` is allowed: the runtime wraps your code in
               an async `${'$'}main` function.
            5. Date/time: the global `moment` library is available. Plain JS
               `Date` also works.
            6. Persistent data: `${'$'}storage.setString(key, value)` and
               `${'$'}storage.getString(key)` for strings; `${'$'}storage.setJSON(key, object)`
               and `${'$'}storage.getJSON(key)` for objects. Check write success.
               Do not invent `${'$'}storage.set` or `${'$'}storage.get`.
               `${'$'}storage` stays on this device.
            7. Only use tags, props, and APIs that appear in the REFERENCE
               section or under SYSTEM DATA below. Do not invent new ones.
            8. When calling `fetch`, always wrap it in try/catch so the
               widget still renders something useful on network failure.
            9. Prefer readable typography (`font="title"`, `"headline"`,
               `"caption"`, `"caption2"`) and sensible spacing. Match the
               visual density to the declared widget size.
            10. Keep the output self-contained: no external files, no
                image assets the user hasn't provided.
            11. Respect light and dark appearances. Prefer color="primary"
                and color="secondary" for text; never hardcode white text
                on a transparent background.
            12. Use frame="width,height" for explicit sizes, e.g. frame="60,60".
                Leave room for stroke thickness and padding. Do not apply
                frame="max" to every row: it expands height too. Use
                frame="max,24" for a full-width row with a fixed height
                when appropriate.
                frame="max,leading" fills both directions and aligns the content
                (center, leading, trailing, top, bottom, topLeading, ...). There
                is no "auto" and no space after the comma: for a full-width row
                as tall as its content, put a <spacer/> inside the <hstack>.
                <text>, <date>, <image> and the other tags without children take
                no tags inside them: write <date ... /> next to a <text>, not in it.
                A linear ${'$'}gradient needs both points, e.g. ${'$'}gradient({type: "linear",
                colors: ["#0f172a", "#166534"], startPoint: "top", endPoint: "bottom"}).
            13. Charts use data={${'$'}json([{label: "Mon", value: 3}])}, not JSX
                child marks. Keep chart axes legible: avoid a fixed dark
                background with default light-appearance axes. Prefer the
                default background or select a matching background using
                ${'$'}device.isdarkmode().
            14. Preserve the requested labels and values. Do not invent
                meeting locations, extra events, or live data. For fixed
                demo data do not call the network or system data APIs.
            15. Scheduled widgets use timeline-date/timeline-slot from ${'$'}getenv, not
                a replaced Date global. Future entries are read-only: do not save
                records or fetch live data while projecting them.
            16. ${'$'}file.exists(path) checks regular files inside the current package.
                Give a useful missing-resource state instead of inventing a photo.
        """.trimIndent()
        val out = StringBuilder(rules)
        out.append("\n\nRUNTIME LIMITS (enforced; a widget that exceeds them fails):\n")
        for (line in runtimeLimits) out.append("- ").append(line).append('\n')
        out.append("\nNOT SUPPORTED ON ANDROID (never use these; if the request needs one, render a short explanation instead):\n")
        for (line in unsupported) out.append("- ").append(line).append('\n')
        out.append("\nSYSTEM DATA ON ANDROID (these work; use one only when the request needs it):\n")
        for (line in AndroidPromptNotes.systemDataLines()) out.append("- ").append(line).append('\n')
        out.append("\nONLY ON ANDROID (use these although the REFERENCE does not show them):\n")
        for (line in AndroidPromptNotes.androidOnlyLines()) out.append("- ").append(line).append('\n')
        out.append('\n').append(reference.combined)
        return out.toString()
    }

    /**
     * Appends enabled Skills to the user's request, as `AIWidgetSkills.augment` does.
     * [skillsText] is already formatted prompt text; blank or null leaves [prompt] unchanged.
     * Skills only add instructions: they cannot change rules, permissions or tools.
     */
    fun augmentWithSkills(prompt: String, skillsText: String?): String {
        val skills = skillsText?.trim().orEmpty().take(MAXIMUM_SKILLS_CHARACTERS)
        if (skills.isEmpty()) return prompt
        return "$prompt\n\nApply these ScriptWidget skills:\n$skills"
    }

    /** Port of `userPromptFirst`. */
    fun userPromptFirst(userDescription: String, size: AiWidgetSize): String = """
Widget size: ${size.family}
Size hint: ${size.designHint}

User description:
$userDescription

Return the complete JSX snippet (plus the network declaration block only if it uses the network). No explanation.
""".trim()

    /** How much of one console line a repair request carries. */
    const val MAXIMUM_LOG_LINE_CHARACTERS = 300
    /** How many console lines a repair request carries: the last ones. */
    const val MAXIMUM_LOG_LINES = 10

    /**
     * Port of `userPromptFix`: the failed code, the runtime feedback and the last ten log lines.
     * A script may print anything, including what it read from the device, so only the start of
     * each of those lines is sent.
     */
    fun userPromptFix(previousCode: String, errorSummary: String, recentLogs: List<String>): String {
        val logBlock = if (recentLogs.isEmpty()) "(no console output)"
        else recentLogs.takeLast(MAXIMUM_LOG_LINES).joinToString("\n") { clip(it, MAXIMUM_LOG_LINE_CHARACTERS) }
        return """
Your previous code failed to run:

```jsx
$previousCode
```

Runtime feedback:
$errorSummary

Last console output:
$logBlock

Fix the code and return the FULL corrected JSX only (plus the network declaration block only if it uses the network). No explanation.
""".trim()
    }

    /**
     * What a turn is told about a version that failed when the preview ran it: the error, then the
     * last console lines under the limits of a repair. [userPromptTurn] cuts the whole to 2,000 characters.
     */
    fun runtimeDiagnostic(errorSummary: String, logs: List<String>): String {
        if (logs.isEmpty()) return errorSummary
        return errorSummary + "\nLast console output:\n" + logs.takeLast(MAXIMUM_LOG_LINES).joinToString("\n") { clip(it, MAXIMUM_LOG_LINE_CHARACTERS) }
    }

    /**
     * Port of `userPromptRefine` / `userPromptCopilot`: improve an installed widget.
     * [currentDeclaration] is the package's current network declaration, if any, so the
     * model knows which hosts are already allowed.
     */
    fun userPromptRefine(currentCode: String, refineInstruction: String, currentDeclaration: String? = null, runtimeDiagnostic: String? = null): String {
        val declaration = if (currentDeclaration.isNullOrBlank()) "" else "\n\nIts current package declaration is:\n```json\n$currentDeclaration\n```"
        val diagnostic = if (runtimeDiagnostic.isNullOrBlank()) "" else "\n\nThe latest local ScriptWidget runtime diagnostic is:\n$runtimeDiagnostic"
        return """
Current widget code:

```jsx
$currentCode
```$declaration$diagnostic

Apply this change request from the user:
$refineInstruction

Preserve working behavior that is unrelated to the request. Use only documented ScriptWidget APIs.
Return the FULL updated JSX only (plus the network declaration block only if it uses the network). No explanation.
""".trim()
    }

    /**
     * Port of `userPromptTurn`: one turn of a conversation about a widget. The reply form it
     * asks for (a SUMMARY line, the code, the declaration) replaces the system prompt's
     * "only JSX" rule, so a turn can say what it changed.
     */
    fun userPromptTurn(context: AiTurnContext): String {
        val parts = ArrayList<String>()
        parts += "You are working with the user on one ScriptWidget widget over several turns.\nWidget size: ${context.size.family}\nSize hint: ${context.size.designHint}"
        val skills = context.skillsText?.trim().orEmpty().take(MAXIMUM_SKILLS_CHARACTERS)
        if (skills.isNotEmpty()) parts += "Apply these ScriptWidget skills in every turn:\n$skills"
        if (context.history.isNotEmpty()) {
            val lines = context.history.mapIndexed { index, exchange ->
                "${index + 1}. User: ${clip(exchange.request, AiConversationLimits.HISTORY_REQUEST_CHARACTERS)}\n   You: ${clip(exchange.note ?: "Done.", AiConversationLimits.HISTORY_NOTE_CHARACTERS)}"
            }
            parts += "Earlier turns, oldest first (each one was applied):\n" + lines.joinToString("\n")
        }
        val previous = context.previousCode
        if (!previous.isNullOrEmpty() && previous.length <= AiConversationLimits.PREVIOUS_SOURCE_CHARACTERS) {
            parts += "The version before your last change, for reference only (the user may ask to bring something back):\n\n```jsx\n$previous\n```"
        }
        val current = context.currentCode
        if (!current.isNullOrEmpty()) {
            val declaration = if (context.currentDeclaration.isNullOrBlank()) "It declares no network use." else "Its network declaration: ${context.currentDeclaration}"
            val diagnostic = if (context.runtimeDiagnostic.isNullOrBlank()) "" else "\n\nThe latest local ScriptWidget runtime diagnostic is:\n${clip(context.runtimeDiagnostic, 2_000)}"
            parts += "Current working widget code:\n\n```jsx\n$current\n```\n\n$declaration$diagnostic\n\nThe user now asks:\n${context.request}\n\n" +
                "Change only what the request needs and keep everything else as it is."
        } else {
            parts += "The user asks for a new widget:\n${context.request}"
        }
        val codeRule = if (current.isNullOrEmpty()) "then the FULL widget code in one ```jsx fenced block." else EDIT_REPLY_RULE
        parts += """
Reply in exactly this form, which replaces the output rule above for this conversation:
SUMMARY: one short sentence saying what you made or changed, written in the language of the request below (a request in English gets an English sentence)
$codeRule
If, and only if, the widget uses `fetch` or `${'$'}http`, end with one more fenced block
that declares every host it contacts:
```json
{"permissions": ["network"], "networkDomains": ["api.example.com"]}
```
Hosts are exact lowercase names or `*.example.com`. A host that is not declared is
blocked. No other permission can be declared. Nothing else.
""".trim()
        return parts.joinToString("\n\n")
    }

    /**
     * How a turn that changes existing code may answer: with all of the code, or with the
     * places that change. The same words as `PromptBuilder.editReplyRule`; see [AiSourceEdits].
     */
    val EDIT_REPLY_RULE = """
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
""".trim()

    /** Added to a repair request inside a conversation, where the reply form still holds. */
    const val TURN_REPAIR_SUFFIX = "\n\nKeep the reply form of this conversation: the full code in one ```jsx block, then the " +
        "```json network declaration block only if the widget uses the network."

    /**
     * Port of `parseTurnReply`: the model's note, the widget code and the declaration, if any.
     * A reply without the SUMMARY line or without a fence is still read as code. The code ends
     * with a line break, like a file.
     */
    fun parseTurnReply(raw: String): AiTurnReply {
        val candidate = AiOutput.extract(raw)
        var note: String? = null
        val fence = raw.indexOf("```")
        val head = if (fence >= 0) raw.substring(0, fence) else raw
        var source = candidate.source
        for (line in head.lines()) {
            val trimmed = line.trim()
            if (!trimmed.lowercase().startsWith("summary:")) continue
            val value = trimmed.substring("summary:".length).trim()
            if (value.isNotEmpty()) note = clip(value, AiConversationLimits.NOTE_CHARACTERS)
            // Without a fence the SUMMARY line is part of what was read as code.
            if (fence < 0) source = source.replaceFirst(line, "").trim()
            break
        }
        return AiTurnReply(note, AiCandidate(if (source.isEmpty()) "" else source + "\n", candidate.manifestJson))
    }

    /** Port of `previewOfPartialReply`: what the text written so far looks like as code. */
    fun previewOfPartialReply(partial: String): String {
        val open = partial.indexOf("```")
        if (open < 0) return partial
        val newline = partial.indexOf('\n', open + 3)
        if (newline < 0) return ""
        val code = partial.substring(newline + 1)
        val close = code.indexOf("```")
        return if (close >= 0) code.substring(0, close) else code
    }

    fun clip(text: String, limit: Int): String = if (text.length > limit) text.take(limit) + "…" else text
}

/** What one turn of a conversation tells the model. Port of `AITurnContext`. */
class AiTurnContext(
    /** Earlier applied turns, oldest first. */
    val history: List<Exchange>,
    /** The widget as it is now; null when the turn starts a new widget. */
    val currentCode: String?,
    /** The version before the current one, if any. */
    val previousCode: String?,
    val request: String,
    /** Formatted text of the enabled Skills; null for none. */
    val skillsText: String?,
    val size: AiWidgetSize,
    /** Canonical network declaration of the current widget, if any. */
    val currentDeclaration: String? = null,
    val runtimeDiagnostic: String? = null,
) {
    class Exchange(val request: String, val note: String?)
}

/** A turn reply, split. */
class AiTurnReply(val note: String?, val candidate: AiCandidate)

/** A starter prompt shown on the generate screen. Port of `AIExamplePrompt`. */
class AiExamplePrompt(val title: String, val size: AiWidgetSize, val prompt: String)

/**
 * Port of `AIExamplePrompts.all`. The Weather prompt uses fixed coordinates, so that the
 * preview shows a temperature: a conversation cannot declare the `location` permission. The
 * Steps prompt shows its setup state in the preview for the same reason, as on iPhone.
 */
object AiExamplePrompts {
    val all: List<AiExamplePrompt> = listOf(
        AiExamplePrompt(
            "Weather", AiWidgetSize.MEDIUM,
            "Show the current weather for Shanghai (latitude 31.23, longitude 121.47) using the Open-Meteo API " +
                "(https://api.open-meteo.com/v1/forecast). Dark navy background. " +
                "Big temperature in Celsius, feels-like temperature below in a smaller caption, " +
                "and the weather code. Handle a failed request gracefully with a message.",
        ),
        AiExamplePrompt(
            "Clock", AiWidgetSize.SMALL,
            "A minimalist clock widget. Show the current time as a large HH:mm, " +
                "today's weekday and date below in a muted caption. " +
                "Dark gradient background from near-black to deep purple.",
        ),
        AiExamplePrompt(
            "Countdown", AiWidgetSize.MEDIUM,
            "A countdown widget to 2026-12-31. Show days remaining as a big number, " +
                "with the label 'days until New Year' underneath. " +
                "Warm orange-to-red gradient background, light text.",
        ),
        AiExamplePrompt(
            "Crypto Price", AiWidgetSize.MEDIUM,
            "Fetch the current Bitcoin price in USD from " +
                "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true " +
                "and display it. Large USD price, a second line with the 24h change " +
                "(green with ▲ if positive, red with ▼ if negative). Black background.",
        ),
        AiExamplePrompt(
            "Battery Ring", AiWidgetSize.SMALL,
            "Show the device battery percentage via \$device as a number in the center " +
                "of a circular gauge ring. Use green above 50%, yellow 20-50%, red below 20%. " +
                "Dark background.",
        ),
        AiExamplePrompt(
            "Quote", AiWidgetSize.LARGE,
            "A daily quote widget. Hardcode 7 short inspirational quotes (one per weekday) " +
                "and display the one matching today's weekday. " +
                "Quote in a readable body font centered, author on a second line in caption. " +
                "Soft pastel gradient background.",
        ),
        AiExamplePrompt(
            "Steps", AiWidgetSize.SMALL,
            "Show today's step count from \$health. Large number centered, " +
                "'steps' label below in caption. Progress bar at the bottom " +
                "showing progress toward a 10000-step goal. Dark teal background.",
        ),
        AiExamplePrompt(
            "Habit Grid", AiWidgetSize.LARGE,
            "A GitHub-style 7x5 habit tracker grid (35 cells). Hardcode a boolean " +
                "array of 35 values representing the last 35 days of a 'read 20 mins' habit. " +
                "Green filled cells for completed, gray for missed. " +
                "Header: 'Reading streak' with current streak count in the top-right.",
        ),
    )
}
