package com.everettjf.scriptwidget.core.ai

import com.everettjf.scriptwidget.core.api.RuntimePolicy
import com.everettjf.scriptwidget.core.pkg.PackageManifests
import org.json.JSONArray
import org.json.JSONObject

/**
 * The package declaration a model may attach to its code: the `network`
 * permission and the hosts the widget contacts. It is the only part of a
 * manifest the model can influence; everything else is written by the app.
 */
class AiManifestDeclaration(val permissions: List<String>, val networkDomains: List<String>) {
    /** Canonical JSON: `{"permissions":[...],"networkDomains":[...]}`. */
    fun toJson(): String = JSONObject().put("permissions", JSONArray(permissions)).put("networkDomains", JSONArray(networkDomains)).toString()

    /**
     * Returns a copy of [base] with this declaration applied. Permissions the model cannot
     * grant are kept exactly as [base] has them; `network` and `networkDomains` are replaced.
     */
    fun applyTo(base: JSONObject): JSONObject {
        val result = JSONObject(base.toString())
        val existing = base.optJSONArray("permissions")?.let { array -> List(array.length()) { array.optString(it) } } ?: emptyList()
        val merged = existing.filter { it !in GRANTABLE_PERMISSIONS } + permissions
        result.put("permissions", JSONArray(merged.distinct()))
        result.put("networkDomains", JSONArray(networkDomains))
        return result
    }

    companion object {
        /** Permissions generated code may request. Anything else needs a human editing the manifest. */
        val GRANTABLE_PERMISSIONS = setOf("network")
        const val MAXIMUM_DOMAINS = 16
        const val MAXIMUM_BYTES = 8 * 1024
        private val HOST = Regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$")

        /**
         * Parses a declaration, failing closed.
         * @throws IllegalArgumentException with a message that can be fed back to the model.
         */
        fun parse(json: String): AiManifestDeclaration {
            if (json.toByteArray(Charsets.UTF_8).size > MAXIMUM_BYTES) throw IllegalArgumentException("The package declaration is too large.")
            val root = try { JSONObject(json) } catch (_: Exception) { throw IllegalArgumentException("The package declaration is not a JSON object.") }
            for (key in root.keys()) if (key != "permissions" && key != "networkDomains") {
                throw IllegalArgumentException("The package declaration may only contain \"permissions\" and \"networkDomains\"; remove \"${key.take(40)}\".")
            }
            val permissions = strings(root, "permissions").distinct()
            for (permission in permissions) if (permission !in GRANTABLE_PERMISSIONS) {
                throw IllegalArgumentException("Permission \"${permission.take(40)}\" cannot be declared by generated widgets on Android; only \"network\" can.")
            }
            val domains = strings(root, "networkDomains").map { it.lowercase() }.distinct()
            if (domains.size > MAXIMUM_DOMAINS) throw IllegalArgumentException("Declare at most $MAXIMUM_DOMAINS network domains.")
            for (domain in domains) {
                if (domain.length > 253 || !HOST.matches(domain) || RuntimePolicy.blockedHostName(domain.removePrefix("*."))) {
                    throw IllegalArgumentException("\"${domain.take(80)}\" is not a public host name. Use a host such as api.example.com, without scheme or path.")
                }
            }
            if (domains.isNotEmpty() && "network" !in permissions) throw IllegalArgumentException("networkDomains requires the \"network\" permission.")
            if ("network" in permissions && domains.isEmpty()) throw IllegalArgumentException("The \"network\" permission requires at least one entry in networkDomains.")
            return AiManifestDeclaration(permissions, domains)
        }

        /** The declaration an existing manifest amounts to, or null when it declares no network access. */
        fun fromManifest(manifest: JSONObject?): AiManifestDeclaration? {
            val permissions = manifest?.optJSONArray("permissions")?.let { array -> List(array.length()) { array.optString(it) } }?.filter { it in GRANTABLE_PERMISSIONS } ?: return null
            if (permissions.isEmpty()) return null
            val domains = manifest.optJSONArray("networkDomains")?.let { array -> List(array.length()) { array.optString(it) } } ?: emptyList()
            return AiManifestDeclaration(permissions, domains)
        }

        private fun strings(root: JSONObject, key: String): List<String> {
            if (!root.has(key)) return emptyList()
            val array = root.opt(key) as? JSONArray ?: throw IllegalArgumentException("\"$key\" must be an array of strings.")
            return List(array.length()) { index -> array.opt(index) as? String ?: throw IllegalArgumentException("\"$key\" must be an array of strings.") }
        }
    }
}

/** Manifest text for generated candidates. The model only ever influences the network declaration. */
object AiManifests {
    /** Name of the manifest file inside a package. */
    const val FILE_NAME = PackageManifests.FILE_NAME
    /** Entry file of a package without a manifest, and of every newly generated widget. */
    const val DEFAULT_ENTRY = PackageManifests.LEGACY_ENTRY

    /** The entry path [manifest] declares, or `main.jsx` when there is no manifest or no string entry. */
    fun entry(manifest: JSONObject?): String = manifest?.let { PackageManifests.string(it, "entry") } ?: DEFAULT_ENTRY

    /** Parses manifest text as a JSON object, or null. */
    fun parse(text: String?): JSONObject? = PackageManifests.parse(text)

    /**
     * Manifest text for a candidate.
     *
     * With [base] null a fresh Package 2.0 manifest named [newName] is created. Otherwise [base]
     * (an installed package's manifest) is kept and only its network fields change. A null or
     * invalid [declarationJson] leaves the network fields as they are: nothing is granted by default.
     */
    fun text(base: JSONObject?, declarationJson: String?, newName: String): String {
        val declaration = declarationJson?.let { runCatching { AiManifestDeclaration.parse(it) }.getOrNull() }
        val manifest = base ?: PackageManifests.newManifest(newName)
        return String(PackageManifests.encode(declaration?.applyTo(manifest) ?: manifest), Charsets.UTF_8)
    }
}

/** Widget source and optional declaration text extracted from one model reply. */
class AiCandidate(val source: String, val manifestJson: String?) {
    /** The reply re-assembled in the format the prompt asks for; used as the assistant turn when asking for a fix. */
    fun asAssistantMessage(): String = if (manifestJson == null) source else "$source\n\n```json\n$manifestJson\n```"
}

/** Turns raw model output into a candidate. */
object AiOutput {
    private val FENCE = Regex("```([A-Za-z0-9_.+-]*)[^\\n]*\\n(.*?)```", RegexOption.DOT_MATCHES_ALL)
    private val DECLARATION_LANGUAGES = setOf("json", "json5", "jsonc", "widget.json")

    /**
     * Splits a reply into code and the optional package declaration.
     *
     * The declaration is the last fenced block tagged `json` (or untagged) whose body is a JSON
     * object; it is returned verbatim for [AiManifestDeclaration.parse] to judge. The code is
     * what [stripCodeFences] makes of the rest.
     */
    fun extract(raw: String): AiCandidate {
        var manifest: String? = null
        var remaining = raw
        val declaration = FENCE.findAll(raw).lastOrNull { match ->
            val language = match.groupValues[1].lowercase()
            val body = match.groupValues[2].trim()
            (language in DECLARATION_LANGUAGES || language.isEmpty()) && body.startsWith("{") && runCatching { JSONObject(body) }.isSuccess && !body.contains("\$render")
        }
        if (declaration != null) {
            manifest = declaration.groupValues[2].trim()
            remaining = raw.removeRange(declaration.range)
        }
        return AiCandidate(stripCodeFences(remaining), manifest)
    }

    /**
     * Port of `PromptBuilder.stripCodeFences`: prefer the content of the first fenced block,
     * then drop stray fence markers and surrounding whitespace.
     */
    fun stripCodeFences(raw: String): String {
        var text = raw.trim()
        extractFencedBlock(text)?.let { text = it }
        for (marker in listOf("```jsx", "```javascript", "```js", "```")) text = text.replace(marker, "")
        return text.trim()
    }

    private fun extractFencedBlock(raw: String): String? {
        val open = raw.indexOf("```")
        if (open < 0) return null
        val afterOpen = raw.substring(open + 3)
        // Skip the optional language tag on the same line.
        val newline = afterOpen.indexOf('\n')
        val afterNewline = if (newline >= 0) afterOpen.substring(newline + 1) else afterOpen
        val close = afterNewline.indexOf("```")
        if (close < 0) return null
        return afterNewline.substring(0, close)
    }
}

/** Outcome of compiling and running one candidate. [logs] are `"[level] message"` lines. */
class ValidationResult(val ok: Boolean, val errorSummary: String?, val logs: List<String> = emptyList()) {
    companion object {
        fun success(logs: List<String> = emptyList()) = ValidationResult(true, null, logs)
        fun failure(errorSummary: String, logs: List<String> = emptyList()) = ValidationResult(false, errorSummary, logs)

        /**
         * Judges a runtime execution the way `AgentRunResult.didSucceed` does: an error, a missing
         * tree, a fallback sentinel or an error-level log line all count as failure. The summary
         * follows `ScriptWidgetError.summaryForPrompt` (`kind: message`).
         */
        fun fromExecution(tree: String?, errorKind: String?, errorMessage: String?, logs: List<String>): ValidationResult {
            if (errorKind != null) return failure("$errorKind: ${errorMessage.orEmpty().take(MAXIMUM_ERROR_CHARACTERS)}", logs)
            if (tree.isNullOrEmpty()) return failure("Runtime returned no element.", logs)
            val root = runCatching { JSONObject(tree) }.getOrNull() ?: return failure("Runtime returned no element.", logs)
            if (root.optString("\$element").isEmpty()) return failure("Runtime returned no element.", logs)
            val children = root.optJSONArray("children")
            val sentinel = children != null && (0 until children.length()).any { index -> children.opt(index).let { it is String && it in SENTINELS } }
            if (sentinel) return failure("Runtime returned a fallback/placeholder element. The widget did not render real content.", logs)
            val failing = logs.firstOrNull { it.startsWith("[error]") || it.lowercase().contains("uncaught") }
            if (failing != null) return failure("The widget rendered but logged an error: ${failing.take(MAXIMUM_ERROR_CHARACTERS)}", logs)
            return success(logs)
        }

        private const val MAXIMUM_ERROR_CHARACTERS = 2000
        private val SENTINELS = setOf("#UI Not Found#", "#Failed#", "#Loading#")
    }
}
