package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.api.RuntimePolicy
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.text.BreakIterator

/** Where a parameter value goes in the request (`DataSourceParameterLocation` in Swift). */
enum class PluginParameterLocation(val wireName: String) {
    PATH("path"), QUERY("query"), HEADER("header"), JSON_BODY("jsonBody");

    companion object {
        fun of(name: String): PluginParameterLocation? = entries.firstOrNull { it.wireName == name }
    }
}

/** How a response body is handed to the widget (`DataSourceResponseType` in Swift). */
enum class PluginResponseType(val wireName: String) {
    JSON("json"), TEXT("text");

    companion object {
        fun of(name: String): PluginResponseType? = entries.firstOrNull { it.wireName == name }
    }
}

/** One declared operation parameter. A plugin can only place values where it declared them. */
data class PluginParameter(
    val id: String,
    val label: String,
    val location: PluginParameterLocation,
    val required: Boolean,
    val defaultValue: String? = null,
)

/** One declared HTTPS request template. */
data class PluginOperation(
    val id: String,
    val title: String,
    val method: String,
    val path: String,
    val responseType: PluginResponseType,
    val parameters: List<PluginParameter>,
)

/**
 * A Data Source Plugin 1.0 manifest (`plugin.json`). It is data: a mapping from parameters to
 * HTTPS requests against the hosts it declares. It carries no code and no permissions.
 */
data class PluginManifest(
    val formatVersion: Int,
    val id: String,
    val name: String,
    val version: String,
    val summary: String,
    val symbol: String,
    val author: String,
    val license: String,
    val minimumRuntimeVersion: String,
    val baseURL: String,
    val hosts: List<String>,
    val operations: List<PluginOperation>,
) {
    /**
     * `plugin.json` text with sorted keys and two-space indentation, the form Swift writes
     * (`.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`). An absent `defaultValue` is omitted.
     */
    fun toJson(): String {
        val q = StrictJson::quote
        val out = StringBuilder("{\n")
        out.append("  \"author\": ${q(author)},\n")
        out.append("  \"baseURL\": ${q(baseURL)},\n")
        out.append("  \"formatVersion\": $formatVersion,\n")
        out.append("  \"hosts\": [${hosts.joinToString(", ") { q(it) }}],\n")
        out.append("  \"id\": ${q(id)},\n")
        out.append("  \"license\": ${q(license)},\n")
        out.append("  \"minimumRuntimeVersion\": ${q(minimumRuntimeVersion)},\n")
        out.append("  \"name\": ${q(name)},\n")
        out.append("  \"operations\": [")
        operations.forEachIndexed { index, operation ->
            out.append(if (index == 0) "\n" else ",\n")
            out.append("    {\n")
            out.append("      \"id\": ${q(operation.id)},\n")
            out.append("      \"method\": ${q(operation.method)},\n")
            out.append("      \"parameters\": [")
            operation.parameters.forEachIndexed { parameterIndex, parameter ->
                out.append(if (parameterIndex == 0) "\n" else ",\n")
                out.append("        {")
                if (parameter.defaultValue != null) out.append("\"defaultValue\": ${q(parameter.defaultValue)}, ")
                out.append("\"id\": ${q(parameter.id)}, \"label\": ${q(parameter.label)}, ")
                out.append("\"location\": ${q(parameter.location.wireName)}, \"required\": ${parameter.required}}")
            }
            out.append(if (operation.parameters.isEmpty()) "],\n" else "\n      ],\n")
            out.append("      \"path\": ${q(operation.path)},\n")
            out.append("      \"responseType\": ${q(operation.responseType.wireName)},\n")
            out.append("      \"title\": ${q(operation.title)}\n")
            out.append("    }")
        }
        out.append(if (operations.isEmpty()) "],\n" else "\n  ],\n")
        out.append("  \"summary\": ${q(summary)},\n")
        out.append("  \"symbol\": ${q(symbol)},\n")
        out.append("  \"version\": ${q(version)}\n")
        out.append("}\n")
        return out.toString()
    }

    companion object {
        /** The only supported `formatVersion`; any other value fails closed. */
        const val CURRENT_FORMAT_VERSION = 1
    }
}

/**
 * The single failure type of the plugin layer, mirroring `DataSourcePluginError` in Swift.
 * [message] is the text shown to the user or passed to the script's rejection handler.
 */
class PluginException(val kind: Kind, message: String, cause: Throwable? = null) : Exception(message, cause) {
    enum class Kind { INVALID_MANIFEST, NOT_FOUND, PERMISSION, INVALID_PARAMETERS, NETWORK, STORAGE }

    override val message: String get() = super.message.orEmpty()
}

/** One reason a manifest is refused. [id] is the stable Swift issue identifier. */
data class PluginValidationIssue(val id: String, val message: String)

/**
 * Strict decoder and validator for `plugin.json`, ported from `DataSourcePluginValidator`.
 * Plugin manifests are untrusted (imported ZIPs, shared files); everything not explicitly
 * allowed is refused.
 */
object PluginValidator {
    /** `DataSourcePluginValidator.maximumManifestBytes`: bounds parsing work for an untrusted file. */
    const val MAXIMUM_MANIFEST_BYTES = 256 * 1024
    /** `DataSourcePluginValidator.maximumOperations`. */
    const val MAXIMUM_OPERATIONS = 50
    /** `DataSourcePluginValidator.maximumParameters` (per operation). */
    const val MAXIMUM_PARAMETERS = 30
    /** Most host declarations a plugin may carry. */
    const val MAXIMUM_HOSTS = 20
    /** Longest plugin name, in user-perceived characters. */
    const val MAXIMUM_NAME_CHARACTERS = 80
    /** `ScriptWidgetBuildContract.runtimeAPIVersion`: the only `minimumRuntimeVersion` accepted. */
    const val RUNTIME_API_VERSION = "1.0"

    private val ROOT_KEYS = setOf("formatVersion", "id", "name", "version", "summary", "symbol", "author", "license", "minimumRuntimeVersion", "baseURL", "hosts", "operations")
    private val OPERATION_KEYS = setOf("id", "title", "method", "path", "responseType", "parameters")
    private val PARAMETER_KEYS = setOf("id", "label", "location", "required", "defaultValue")
    private val METHODS = setOf("GET", "POST", "PUT", "PATCH", "DELETE")
    private val IDENTIFIER = Regex("[A-Za-z0-9][A-Za-z0-9.-]{2,127}")
    private val SEMANTIC_VERSION = Regex("[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?")
    private val HEADER_NAME = Regex("[A-Za-z0-9!#$%&'*+.^_`|~-]+")
    private val HOST_DECLARATION = Regex("[a-z0-9*.-]+")
    private val PLACEHOLDER = Regex("\\{([A-Za-z0-9.-]+)\\}")

    /**
     * Decodes and validates `plugin.json` bytes.
     *
     * Security rules, each failing closed with [PluginException.Kind.INVALID_MANIFEST]:
     * - at most 256 KiB, strict UTF-8, strict JSON with no duplicate keys;
     * - unknown keys at any level are rejected, so a future or misspelled capability is never
     *   silently ignored;
     * - every field must be present with its exact JSON type (no coercion);
     * - then every rule of [validate].
     */
    fun decode(data: ByteArray): PluginManifest {
        if (data.size > MAXIMUM_MANIFEST_BYTES) invalid("plugin.json exceeds 256 KiB.")
        val text = decodeUtf8(data) ?: invalid("plugin.json must be UTF-8 JSON.")
        val root = try {
            StrictJson.parse(text)
        } catch (error: StrictJson.JsonException) {
            invalid("plugin.json is not valid JSON.")
        } catch (error: NumberFormatException) {
            invalid("plugin.json is not valid JSON.")
        }
        if (root !is Map<*, *>) invalid("plugin.json must be an object.")
        val operations = objects(root["operations"])
        if (!ROOT_KEYS.containsAll(root.keys) || operations == null) invalid("plugin.json contains unknown fields.")
        for (operation in operations) {
            val parameters = objects(operation["parameters"])
            if (!OPERATION_KEYS.containsAll(operation.keys) || parameters == null || parameters.any { !PARAMETER_KEYS.containsAll(it.keys) }) {
                invalid("Plugin operation contains unknown fields.")
            }
        }
        val manifest = PluginManifest(
            formatVersion = integer(root, "formatVersion"),
            id = string(root, "id"),
            name = string(root, "name"),
            version = string(root, "version"),
            summary = string(root, "summary"),
            symbol = string(root, "symbol"),
            author = string(root, "author"),
            license = string(root, "license"),
            minimumRuntimeVersion = string(root, "minimumRuntimeVersion"),
            baseURL = string(root, "baseURL"),
            hosts = (root["hosts"] as? List<*>)?.map { it as? String ?: malformed("hosts") } ?: malformed("hosts"),
            operations = operations.map { operation ->
                PluginOperation(
                    id = string(operation, "id"),
                    title = string(operation, "title"),
                    method = string(operation, "method"),
                    path = string(operation, "path"),
                    responseType = PluginResponseType.of(string(operation, "responseType")) ?: malformed("responseType"),
                    parameters = objects(operation["parameters"])!!.map { parameter ->
                        PluginParameter(
                            id = string(parameter, "id"),
                            label = string(parameter, "label"),
                            location = PluginParameterLocation.of(string(parameter, "location")) ?: malformed("location"),
                            required = parameter["required"] as? Boolean ?: malformed("required"),
                            defaultValue = when (val value = parameter["defaultValue"]) {
                                null -> null
                                is String -> value
                                else -> malformed("defaultValue")
                            },
                        )
                    },
                )
            },
        )
        val issues = validate(manifest)
        if (issues.isNotEmpty()) invalid(issues.joinToString("\n") { it.message })
        return manifest
    }

    /**
     * Semantic rules of Data Source Plugin 1.0. An empty list means the manifest is valid.
     *
     * - `formatVersion` must be 1 and `minimumRuntimeVersion` the supported runtime: unsupported
     *   versions fail closed instead of being run with guessed semantics.
     * - `baseURL` must be HTTPS without credentials, query or fragment: plugins never send
     *   cleartext requests and never embed secrets in the manifest.
     * - 1–20 unique, well-formed `hosts` that include the `baseURL` host and are public Internet
     *   names: a plugin can only reach hosts the user can review, never the device or local network.
     *   (The public-host rule is enforced by Swift when the request is made; here it is also
     *   enforced at import.)
     * - 1–50 operations with unique ids, an upper-case standard method, and an absolute path with
     *   no `..`, query or fragment: an operation cannot leave its declared path space.
     * - At most 30 parameters per operation, unique ids, every `{placeholder}` declared as a `path`
     *   parameter and every `path` parameter present in the path; header parameter ids must be
     *   valid header names.
     */
    fun validate(manifest: PluginManifest): List<PluginValidationIssue> {
        val issues = ArrayList<PluginValidationIssue>()
        fun reject(id: String, message: String) { issues.add(PluginValidationIssue(id, message)) }
        if (manifest.formatVersion != PluginManifest.CURRENT_FORMAT_VERSION) reject("format", "Unsupported Data Source Plugin format ${manifest.formatVersion}.")
        if (!IDENTIFIER.matches(manifest.id)) reject("id", "Plugin id must be a stable 3–128 character identifier.")
        if (manifest.name.isBlank() || characterCount(manifest.name) > MAXIMUM_NAME_CHARACTERS) reject("name", "Plugin name must contain 1–80 characters.")
        if (!SEMANTIC_VERSION.matches(manifest.version)) reject("version", "Plugin version must use semantic versioning.")
        if (manifest.minimumRuntimeVersion != RUNTIME_API_VERSION) reject("runtime", "Plugin requires unsupported runtime ${manifest.minimumRuntimeVersion}.")
        val base = runCatching { URI(manifest.baseURL) }.getOrNull()
        val baseHost = base?.host?.lowercase()
        if (base == null || base.scheme?.lowercase() != "https" || baseHost.isNullOrEmpty() || base.rawUserInfo != null || base.rawQuery != null || base.rawFragment != null) {
            reject("base_url", "baseURL must be an HTTPS URL without credentials, query, or fragment.")
            return issues
        }
        if (manifest.hosts.isEmpty() || manifest.hosts.size > MAXIMUM_HOSTS) reject("hosts", "A plugin must declare 1–20 HTTPS hosts.")
        if (manifest.hosts.toSet().size != manifest.hosts.size) reject("hosts", "Plugin hosts must be unique.")
        for (host in manifest.hosts) {
            if (!isValidDomainDeclaration(host)) reject("host", "Invalid plugin host declaration: $host.")
            // "*.local" covers only private names; test it as a name it would match.
            else if (RuntimePolicy.blockedHostName(if (host.startsWith("*.")) "x" + host.substring(1) else host)) reject("host", "Plugin host must be a public Internet host: $host.")
        }
        if (RuntimePolicy.blockedHostName(baseHost.removePrefix("[").removeSuffix("]"))) reject("base_host", "baseURL must use a public Internet host.")
        if (!RuntimePolicy.hostMatches(baseHost, manifest.hosts)) reject("base_host", "baseURL host must be included in hosts.")
        if (manifest.operations.isEmpty() || manifest.operations.size > MAXIMUM_OPERATIONS) reject("operations", "A plugin must contain 1–$MAXIMUM_OPERATIONS operations.")
        if (manifest.operations.map { it.id.lowercase() }.toSet().size != manifest.operations.size) reject("operation_ids", "Operation ids must be unique.")
        for (operation in manifest.operations) {
            val prefix = "operation.${operation.id}"
            if (!IDENTIFIER.matches(operation.id)) reject(prefix, "Operation id is invalid: ${operation.id}.")
            if (operation.method !in METHODS) reject(prefix, "Operation ${operation.id} has an unsupported HTTP method.")
            if (operation.path.isEmpty() || !operation.path.startsWith("/") || operation.path.contains("..") || operation.path.contains("?") || operation.path.contains("#")) {
                reject(prefix, "Operation path must be an absolute URL path without traversal, query, or fragment.")
            }
            if (operation.parameters.size > MAXIMUM_PARAMETERS) reject(prefix, "Operation ${operation.id} has too many parameters.")
            if (operation.parameters.map { it.id.lowercase() }.toSet().size != operation.parameters.size) reject(prefix, "Operation parameter ids must be unique.")
            val parameterIDs = operation.parameters.map { it.id }.toSet()
            for (parameter in operation.parameters) {
                val placeholder = "{${parameter.id}}"
                if (!IDENTIFIER.matches(parameter.id)) reject(prefix, "Invalid parameter id: ${parameter.id}.")
                if (parameter.location == PluginParameterLocation.PATH && !operation.path.contains(placeholder)) reject(prefix, "Path parameter ${parameter.id} has no matching placeholder.")
                if (parameter.location != PluginParameterLocation.PATH && operation.path.contains(placeholder)) reject(prefix, "Placeholder ${parameter.id} must be a path parameter.")
                if (parameter.location == PluginParameterLocation.HEADER && !HEADER_NAME.matches(parameter.id)) reject(prefix, "Header parameter ${parameter.id} is invalid.")
            }
            for (match in PLACEHOLDER.findAll(operation.path)) {
                val placeholder = match.groupValues[1]
                if (placeholder !in parameterIDs) reject(prefix, "Path placeholder $placeholder has no declared parameter.")
            }
        }
        return issues
    }

    /**
     * `ScriptWidgetNetworkPolicy.isValidDomainDeclaration`: a lower-case host name, optionally
     * `*.`-prefixed, with no scheme, path or port, so a declaration cannot smuggle a URL.
     */
    fun isValidDomainDeclaration(value: String): Boolean {
        val normalized = value.lowercase()
        return value == normalized && !normalized.contains("://") && !normalized.contains("/") && !normalized.contains(":") &&
            !normalized.startsWith(".") && !normalized.endsWith(".") && HOST_DECLARATION.matches(normalized) &&
            (!normalized.contains("*") || (normalized.startsWith("*.") && normalized.indexOf('*', 1) < 0))
    }

    private fun objects(value: Any?): List<Map<*, *>>? {
        val list = value as? List<*> ?: return null
        return list.map { it as? Map<*, *> ?: return null }
    }

    private fun string(map: Map<*, *>, key: String): String = map[key] as? String ?: malformed(key)

    /** Whole JSON numbers only; `1.0` is accepted like Swift's `JSONDecoder`, `1.5` and `"1"` are not. */
    private fun integer(map: Map<*, *>, key: String): Int = when (val value = map[key]) {
        is Long -> if (value in Int.MIN_VALUE..Int.MAX_VALUE) value.toInt() else malformed(key)
        is Double -> if (value == Math.rint(value) && Math.abs(value) <= Int.MAX_VALUE) value.toInt() else malformed(key)
        else -> malformed(key)
    }

    private fun characterCount(text: String): Int {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        var count = 0
        while (iterator.next() != BreakIterator.DONE) count += 1
        return count
    }

    internal fun decodeUtf8(bytes: ByteArray): String? = try {
        val offset = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) 3 else 0
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes, offset, bytes.size - offset)).toString()
    } catch (_: CharacterCodingException) {
        null
    }

    private fun malformed(key: String): Nothing = invalid("plugin.json field \"$key\" is missing or has the wrong type.")

    private fun invalid(message: String): Nothing = throw PluginException(PluginException.Kind.INVALID_MANIFEST, message)
}
