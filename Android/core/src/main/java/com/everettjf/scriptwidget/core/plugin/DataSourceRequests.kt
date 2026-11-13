package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.api.RuntimePolicy
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.math.BigInteger
import java.net.URI

/** A fully resolved plugin request: nothing in it is taken from script input without validation. */
class PreparedDataSourceRequest(
    val plugin: PluginManifest,
    val operation: PluginOperation,
    val method: String,
    val uri: URI,
    val headers: Map<String, String>,
    /** JSON body built from `jsonBody` parameters, or null when there are none. */
    val body: ByteArray?,
)

/** Maps an operation and script-supplied values to one request, ported from `DataSourceRequestBuilder.prepare`. */
object DataSourceRequestBuilder {
    /** Sent with every plugin request, replacing any `User-Agent` header parameter. */
    const val USER_AGENT = "ScriptWidget-DataSource/1"

    // CharacterSet.urlPathAllowed without "/?#{}": a path value can never add a segment, a query or a fragment.
    private const val PATH_ALLOWED = "-._~!$&'()*+,=:@"
    // What URLComponents.queryItems leaves unescaped: "&" and "=" are always encoded, so a value cannot add a query item.
    private const val QUERY_ALLOWED = "-._~!$'()*+,;:@/?"

    /**
     * Builds the request for [operationID] of [plugin].
     *
     * [values] come from package code and are untrusted. Accepted value types are `String`,
     * `Boolean`, `Number`, and (for `jsonBody` parameters only) `JSONObject`/`JSONArray`; `null`
     * and `JSONObject.NULL` mean "not supplied". Booleans are sent as `1`/`0` in path, query and
     * header positions, which is what the Swift runtime sends for a JavaScript boolean.
     *
     * Security rules:
     * - only declared parameters are used; anything else in [values] is ignored, so a script
     *   cannot add headers, query items or body fields the plugin did not declare;
     * - path values are percent-encoded including `/`, `?`, `#`, and `.`/`..` values are refused,
     *   so a value cannot change the path structure;
     * - query names and values are percent-encoded including `&` and `=`;
     * - header values with control characters are refused (no header injection);
     * - the final URL must be HTTPS and its host must match the plugin's declared hosts.
     *
     * @throws PluginException `NOT_FOUND` for an unknown operation, `INVALID_PARAMETERS` for a
     *   missing or unusable value, `PERMISSION` when the URL leaves the declared hosts.
     */
    fun prepare(plugin: PluginManifest, operationID: String, values: Map<String, Any?>): PreparedDataSourceRequest {
        val operation = plugin.operations.firstOrNull { it.id == operationID }
            ?: throw PluginException(PluginException.Kind.NOT_FOUND, "Operation $operationID was not found in ${plugin.id}.")
        var path = operation.path
        val query = ArrayList<Pair<String, String>>()
        val headers = LinkedHashMap<String, String>()
        val body = JSONObject()
        for (parameter in operation.parameters) {
            val supplied = values[parameter.id]
            val raw: Any? = if (supplied != null && supplied != JSONObject.NULL) supplied else parameter.defaultValue
            val structured = raw is JSONObject || raw is JSONArray || raw is Map<*, *> || raw is Collection<*>
            val string = if (structured || raw == null) "" else describe(raw) ?: invalidParameters("Could not encode ${parameter.id}.")
            if (raw == null || (!structured && string.isEmpty())) {
                if (parameter.required) invalidParameters("Missing required parameter ${parameter.id}.")
                continue
            }
            if (structured && parameter.location != PluginParameterLocation.JSON_BODY) invalidParameters("Could not encode ${parameter.id}.")
            when (parameter.location) {
                PluginParameterLocation.PATH -> {
                    if (string == "." || string == "..") invalidParameters("Could not encode ${parameter.id}.")
                    path = path.replace("{${parameter.id}}", percentEncode(string, PATH_ALLOWED))
                }
                PluginParameterLocation.QUERY -> query.add(parameter.id to string)
                PluginParameterLocation.HEADER -> {
                    if (string.any { it < ' ' || it == '\u007F' }) invalidParameters("Could not encode ${parameter.id}.")
                    headers[parameter.id] = string
                }
                PluginParameterLocation.JSON_BODY -> body.put(parameter.id, when (raw) {
                    is Map<*, *> -> JSONObject(raw)
                    is Collection<*> -> JSONArray(raw)
                    else -> raw
                })
            }
        }
        if (path.contains("{") || path.contains("}")) invalidParameters("A path parameter is unresolved.")
        val base = runCatching { URI(plugin.baseURL) }.getOrNull()
        val baseHost = base?.host
        if (base == null || baseHost.isNullOrEmpty()) throw PluginException(PluginException.Kind.INVALID_MANIFEST, "Invalid plugin baseURL.")
        val basePath = base.rawPath.orEmpty()
        val text = StringBuilder()
            .append(base.scheme.lowercase()).append("://").append(baseHost)
            .append(if (base.port >= 0) ":${base.port}" else "")
            .append(if (basePath == "/") "" else basePath).append(path)
        if (query.isNotEmpty()) text.append('?').append(query.joinToString("&") { (name, value) -> percentEncode(name, QUERY_ALLOWED) + "=" + percentEncode(value, QUERY_ALLOWED) })
        val uri = runCatching { URI(text.toString()) }.getOrNull()
            ?: throw PluginException(PluginException.Kind.INVALID_MANIFEST, "Invalid plugin baseURL.")
        val host = uri.host?.lowercase()
        if (uri.scheme != "https" || host == null || !RuntimePolicy.hostMatches(host, plugin.hosts)) {
            throw PluginException(PluginException.Kind.PERMISSION, "Plugin request escaped its declared hosts.")
        }
        headers.keys.filter { it.equals("User-Agent", ignoreCase = true) || it.equals("Content-Type", ignoreCase = true) && body.length() > 0 }.forEach { headers.remove(it) }
        headers["User-Agent"] = USER_AGENT
        val bodyBytes = if (body.length() > 0) body.toString().toByteArray() else null
        if (bodyBytes != null) headers["Content-Type"] = "application/json"
        return PreparedDataSourceRequest(plugin, operation, operation.method, uri, headers, bodyBytes)
    }

    /** Text form of a scalar value, or null when it has none (non-finite numbers, unsupported types). */
    private fun describe(raw: Any): String? = when (raw) {
        is String -> raw
        is Boolean -> if (raw) "1" else "0"
        is Int, is Long, is Short, is Byte, is BigInteger -> raw.toString()
        is Number -> {
            val value = raw.toDouble()
            when {
                value.isNaN() || value.isInfinite() -> null
                value == Math.rint(value) && Math.abs(value) < 1e15 -> value.toLong().toString()
                else -> BigDecimal.valueOf(value).stripTrailingZeros().toPlainString()
            }
        }
        else -> null
    }

    /** Percent-encodes every UTF-8 byte that is not an ASCII letter, digit or in [allowed]. */
    internal fun percentEncode(value: String, allowed: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val char = (byte.toInt() and 0xFF).toChar()
            if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || allowed.indexOf(char) >= 0) out.append(char)
            else out.append('%').append("%02X".format(byte.toInt() and 0xFF))
        }
        return out.toString()
    }

    private fun invalidParameters(message: String): Nothing = throw PluginException(PluginException.Kind.INVALID_PARAMETERS, message)
}

/** Turns an HTTP response into the value a widget receives, as the Swift runtime bridge does. */
object DataSourceResponseMapper {
    /** `ScriptWidgetFetchManager.maximumResponseBytes`: plugin responses share the 2 MiB fetch limit. */
    const val MAXIMUM_RESPONSE_BYTES = FetchModule.MAXIMUM_RESPONSE_BYTES

    /**
     * Returns the JSON text delivered to the script: the response document itself for a `json`
     * operation, or a JSON string literal for a `text` operation.
     *
     * Fails closed with [PluginException.Kind.NETWORK]: a non-2xx status, more than 2 MiB, a
     * `json` body that is not one well-formed UTF-8 JSON object or array, or a `text` body that
     * is not valid UTF-8. Response content is never included in the error message.
     */
    fun map(operation: PluginOperation, status: Int, body: ByteArray): String {
        if (status !in 200..299) network("Data source request failed")
        if (body.size > MAXIMUM_RESPONSE_BYTES) network("Data source response exceeds 2 MiB.")
        val text = PluginValidator.decodeUtf8(body)
        if (operation.responseType == PluginResponseType.TEXT) return StrictJson.quote(text ?: network("Data source returned non-UTF-8 text"))
        val kind = try {
            StrictJson.validate(text ?: network("Data source returned invalid JSON"))
        } catch (error: StrictJson.JsonException) {
            network("Data source returned invalid JSON")
        }
        // JSONSerialization without .fragmentsAllowed accepts only containers at the top level.
        if (kind != StrictJson.Kind.OBJECT && kind != StrictJson.Kind.ARRAY) network("Data source returned invalid JSON")
        return text
    }

    private fun network(message: String): Nothing = throw PluginException(PluginException.Kind.NETWORK, message)
}
