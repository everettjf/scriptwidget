package com.everettjf.scriptwidget.core.api

import android.util.Base64
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.net.URL
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors

/**
 * `fetch` and `$http`. Mirrors ScriptWidgetRuntimeFetch: public HTTP(S)
 * only, the package's declared hosts only, bounded request and response
 * sizes, a per-execution request budget, and every redirect re-validated.
 * Beyond the Swift host-name rule, the resolved addresses are checked so a
 * public name cannot point at a private or loopback address.
 */
class FetchModule(private val resolver: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() }) : NativeModule {
    private val pool = Executors.newFixedThreadPool(MAXIMUM_CONCURRENT) { runnable -> Thread(runnable, "scriptwidget-fetch").apply { isDaemon = true } }

    class Response(val status: Int, val body: ByteArray, val headers: Map<String, String>)

    class FetchException(message: String) : Exception(message)

    override fun handles(operation: String): Boolean = operation == "http.request"

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val job = payload ?: JSONObject()
        val fail = { message: String -> done(false, JSONObject.quote(message)) }
        if (RuntimePolicy.isLiveActivity(request)) return fail("[live_activity_unavailable] Live Activity presentations cannot request network data; update their state from the app")
        if (RuntimePolicy.isTimelineProjection(request)) return fail("[timeline_read_only] Future entries cannot make live network requests; read a saved snapshot")
        val url = job.optString("url")
        val uri = runCatching { URI(url) }.getOrNull() ?: return fail("$url is not url")
        validationError(uri)?.let { return fail(it) }
        if (!RuntimePolicy.packageAllowsHost(request, uri.host)) return fail("Network host is not declared in widget.json")
        if (request.session.networkRequests.incrementAndGet() > MAXIMUM_REQUESTS) return fail("Network request budget exceeded")

        pool.execute {
            try {
                val headers = HashMap<String, String>()
                job.optJSONObject("headers")?.let { map -> map.keys().forEach { headers[it] = map.optString(it) } }
                val body = if (job.has("body")) job.optString("body").toByteArray() else null
                if (body != null && job.optBoolean("jsonBody") && headers.keys.none { it.equals("Content-Type", ignoreCase = true) }) headers["Content-Type"] = "application/json"
                if (body != null && body.size > MAXIMUM_REQUEST_BODY_BYTES) throw FetchException("Request body exceeds the $MAXIMUM_REQUEST_BODY_BYTES-byte limit")
                val timeout = normalizedTimeout(if (job.has("timeout")) job.optDouble("timeout") else null)
                val response = perform(job.optString("method", "GET"), uri, headers, body, timeout) { redirected ->
                    !request.session.finished && validationError(redirected) == null && RuntimePolicy.packageAllowsHost(request, redirected.host)
                }
                if (request.session.finished) return@execute
                val base64 = job.optBoolean("base64")
                val text = if (base64) Base64.encodeToString(response.body, Base64.NO_WRAP) else decodeUtf8(response.body)
                if (job.optBoolean("metadata")) {
                    if (text == null) throw FetchException("Response is not HTTP or has invalid UTF-8")
                    val allowed = JSONObject()
                    for (name in EXPOSED_HEADERS) response.headers[name]?.takeIf { it.toByteArray().size <= 2048 }?.let { allowed.put(name, it) }
                    done(true, JSONObject().put("status", response.status).put("body", text).put("headers", allowed).toString())
                } else if (text == null) throw FetchException("$url is empty")
                else done(true, JSONObject.quote(text))
            } catch (error: FetchException) {
                fail(error.message ?: "Network request failed")
            } catch (error: Exception) {
                fail(error.message ?: error.javaClass.simpleName)
            }
        }
    }

    fun validationError(uri: URI): String? {
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return "Only HTTP and HTTPS URLs are allowed"
        val host = uri.host?.lowercase()?.removePrefix("[")?.removeSuffix("]")
        if (host.isNullOrEmpty()) return "URL host is required"
        if (uri.userInfo != null) return "URL credentials are not allowed"
        return if (RuntimePolicy.blockedHostName(host)) "Local and private network hosts are not allowed" else null
    }

    /** Performs one request, following up to five redirects that [allowRedirect] accepts. */
    fun perform(method: String, start: URI, headers: Map<String, String>, body: ByteArray?, timeoutMilliseconds: Int, allowRedirect: (URI) -> Boolean): Response {
        var current = start
        var currentMethod = method.uppercase()
        var currentBody = body
        val deadline = System.nanoTime() + MAXIMUM_TOTAL_MILLISECONDS * 1_000_000L
        for (hop in 0..MAXIMUM_REDIRECTS) {
            val host = current.host.removePrefix("[").removeSuffix("]")
            val addresses = try { resolver(host) } catch (error: Exception) { throw FetchException("Could not resolve ${current.host}") }
            if (addresses.isEmpty() || addresses.any { RuntimePolicy.blockedAddress(it) }) throw FetchException("Local and private network hosts are not allowed")
            val remaining = ((deadline - System.nanoTime()) / 1_000_000L).toInt()
            if (remaining <= 0) throw FetchException("The request timed out.")
            val connection = URL(current.toString()).openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.requestMethod = currentMethod
                connection.connectTimeout = minOf(timeoutMilliseconds, remaining)
                connection.readTimeout = minOf(timeoutMilliseconds, remaining)
                connection.useCaches = false
                for ((name, value) in headers) if (!name.equals("Host", ignoreCase = true) && !name.equals("Content-Length", ignoreCase = true)) connection.setRequestProperty(name, value)
                if (currentBody != null && currentMethod != "GET") {
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(currentBody.size)
                    connection.outputStream.use { it.write(currentBody) }
                }
                val status = connection.responseCode
                if (status in 300..399 && status != 304) {
                    val location = connection.getHeaderField("Location") ?: throw FetchException("Redirect without a location")
                    val next = current.resolve(location)
                    if (hop == MAXIMUM_REDIRECTS || !allowRedirect(next)) throw FetchException("Redirect target is not allowed")
                    if (status == 303 || ((status == 301 || status == 302) && currentMethod == "POST")) { currentMethod = "GET"; currentBody = null }
                    current = next
                    continue
                }
                val declared = connection.contentLengthLong
                if (declared > MAXIMUM_RESPONSE_BYTES) throw FetchException("Response exceeds the $MAXIMUM_RESPONSE_BYTES-byte limit")
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                val buffer = ByteArrayOutputStream()
                stream?.use { input ->
                    val chunk = ByteArray(16 * 1024)
                    while (true) {
                        val read = input.read(chunk)
                        if (read < 0) break
                        if (buffer.size() + read > MAXIMUM_RESPONSE_BYTES) throw FetchException("Response exceeds the $MAXIMUM_RESPONSE_BYTES-byte limit")
                        buffer.write(chunk, 0, read)
                    }
                }
                val responseHeaders = HashMap<String, String>()
                for ((name, values) in connection.headerFields) if (name != null && values.isNotEmpty()) responseHeaders[name.lowercase()] = values.last()
                return Response(status, buffer.toByteArray(), responseHeaders)
            } finally {
                connection.disconnect()
            }
        }
        throw FetchException("Too many redirects")
    }

    private fun decodeUtf8(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: CharacterCodingException) { null }

    companion object {
        const val MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
        const val MAXIMUM_REQUEST_BODY_BYTES = 1024 * 1024
        const val MAXIMUM_REQUESTS = 32
        const val MAXIMUM_CONCURRENT = 8
        const val MAXIMUM_REDIRECTS = 5
        const val MAXIMUM_TOTAL_MILLISECONDS = 10_000L
        val EXPOSED_HEADERS = listOf("content-type", "cache-control", "expires", "last-modified", "date", "retry-after")

        /** Seconds from the script, clamped to 1...10; 5 by default. */
        fun normalizedTimeout(seconds: Double?): Int {
            val value = if (seconds == null || seconds.isNaN() || seconds <= 0) 5.0 else seconds.coerceIn(1.0, 10.0)
            return (value * 1000).toInt()
        }
    }
}
