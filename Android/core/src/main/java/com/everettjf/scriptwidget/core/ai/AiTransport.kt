package com.everettjf.scriptwidget.core.ai

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.SocketTimeoutException
import java.net.URI
import java.net.UnknownHostException
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException

/** Cooperative cancellation shared by the agent loop and the transport. Safe to use from any thread. */
class AiCancellation {
    @Volatile var isCancelled: Boolean = false
        private set
    private val actions = CopyOnWriteArrayList<() -> Unit>()

    /** Cancels once; registered actions (such as closing a connection) run on the calling thread. */
    fun cancel() {
        if (isCancelled) return
        isCancelled = true
        for (action in actions) runCatching { action() }
    }

    /** Runs [action] when cancelled (immediately if already cancelled). Close the result to unregister. */
    fun onCancel(action: () -> Unit): AutoCloseable {
        actions += action
        if (isCancelled) runCatching { action() }
        return AutoCloseable { actions -= action }
    }
}

/** Failure categories of the AI client; messages never contain the API key or a response body. */
enum class AiErrorKind { MISSING_API_KEY, INVALID_PROFILE, NETWORK, TIMEOUT, HTTP, RESPONSE_TOO_LARGE, MALFORMED_RESPONSE, EMPTY_RESPONSE, REFUSED, CANCELLED }

/** The only exception type the AI client throws. Port of `AIClientError`. */
class AiClientException(val kind: AiErrorKind, message: String, val httpStatus: Int? = null) : Exception(message)

/**
 * One HTTPS request. [headers] may hold the API key, so [toString] prints
 * header names only and never the body.
 */
class AiHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray?,
    val connectTimeoutMilliseconds: Int,
    val readTimeoutMilliseconds: Int,
    val maximumResponseBytes: Int,
) {
    override fun toString(): String = "AiHttpRequest($method ${URI(url).let { "${it.scheme}://${it.host}${it.rawPath.orEmpty()}" }}, headers=${headers.keys.sorted()}, bodyBytes=${body?.size ?: 0})"
}

/** Status and bounded body of a response. [toString] never prints the body. */
class AiHttpResponse(val status: Int, val body: ByteArray) {
    override fun toString(): String = "AiHttpResponse(status=$status, bodyBytes=${body.size})"
}

/** Performs one request. Injected into [AiClient] so tests never touch the network. */
fun interface AiTransport {
    /** @throws AiClientException for every failure, including cancellation. */
    fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse
}

/**
 * The production transport: `HttpURLConnection`, HTTPS only, explicit timeouts,
 * a bounded response and no redirects at all (a redirect could forward the API
 * key to another host). It is separate from the widget `fetch` module, whose
 * budgets and package host policy are meant for untrusted scripts.
 */
class HttpsAiTransport : AiTransport {
    override fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse {
        val uri = try { URI(request.url) } catch (_: Exception) { throw AiClientException(AiErrorKind.INVALID_PROFILE, "The API base URL is invalid.") }
        if (!uri.scheme.orEmpty().equals("https", ignoreCase = true) || uri.host.isNullOrEmpty()) throw AiClientException(AiErrorKind.INVALID_PROFILE, "The API base URL must start with https://.")
        if (cancellation.isCancelled) throw cancelled()
        var connection: HttpsURLConnection? = null
        var registration: AutoCloseable? = null
        try {
            connection = uri.toURL().openConnection() as? HttpsURLConnection ?: throw AiClientException(AiErrorKind.INVALID_PROFILE, "The API base URL must start with https://.")
            val open = connection
            registration = cancellation.onCancel { open.disconnect() }
            open.requestMethod = request.method
            open.instanceFollowRedirects = false
            open.useCaches = false
            open.connectTimeout = request.connectTimeoutMilliseconds
            open.readTimeout = request.readTimeoutMilliseconds
            for ((name, value) in request.headers) open.setRequestProperty(name, value)
            if (request.body != null) {
                open.doOutput = true
                open.setFixedLengthStreamingMode(request.body.size)
                open.outputStream.use { it.write(request.body) }
            }
            val status = open.responseCode
            if (cancellation.isCancelled) throw cancelled()
            if (status in 300..399) throw AiClientException(AiErrorKind.HTTP, "The AI server answered with a redirect, which is not followed. Check the API base URL.", status)
            val success = status in 200..299
            // Error bodies are only inspected for a short error code, so they get a much smaller budget.
            val limit = if (success) request.maximumResponseBytes else minOf(request.maximumResponseBytes, MAXIMUM_ERROR_BODY_BYTES)
            val stream: InputStream? = if (success) open.inputStream else open.errorStream
            val body = stream?.use { read(it, limit, failWhenLarger = success) } ?: ByteArray(0)
            if (cancellation.isCancelled) throw cancelled()
            return AiHttpResponse(status, body)
        } catch (error: AiClientException) {
            throw if (cancellation.isCancelled) cancelled() else error
        } catch (error: Exception) {
            // Exception text is not forwarded: it can echo request details.
            throw when {
                cancellation.isCancelled -> cancelled()
                error is SocketTimeoutException -> AiClientException(AiErrorKind.TIMEOUT, "The AI server did not answer in time. Try again.")
                error is UnknownHostException -> AiClientException(AiErrorKind.NETWORK, "The AI server could not be found. Check the API base URL and your connection.")
                error is SSLException -> AiClientException(AiErrorKind.NETWORK, "A secure connection to the AI server could not be established.")
                error is IOException -> AiClientException(AiErrorKind.NETWORK, "The AI server could not be reached. Check your connection and try again.")
                else -> AiClientException(AiErrorKind.NETWORK, "The AI request could not be sent.")
            }
        } finally {
            runCatching { registration?.close() }
            runCatching { connection?.disconnect() }
        }
    }

    private fun read(stream: InputStream, limit: Int, failWhenLarger: Boolean): ByteArray {
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(16 * 1024)
        while (true) {
            val count = stream.read(chunk)
            if (count < 0) break
            if (buffer.size() + count > limit) {
                if (failWhenLarger) throw AiClientException(AiErrorKind.RESPONSE_TOO_LARGE, "The AI response exceeded the size limit.")
                buffer.write(chunk, 0, limit - buffer.size())
                break
            }
            buffer.write(chunk, 0, count)
        }
        return buffer.toByteArray()
    }

    private fun cancelled() = AiClientException(AiErrorKind.CANCELLED, "Cancelled.")

    private companion object {
        const val MAXIMUM_ERROR_BODY_BYTES = 64 * 1024
    }
}
