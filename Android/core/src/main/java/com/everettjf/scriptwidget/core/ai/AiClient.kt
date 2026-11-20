package com.everettjf.scriptwidget.core.ai

import org.json.JSONArray
import org.json.JSONObject

/** One chat turn. Port of `AIMessage`. */
data class AiMessage(val role: Role, val content: String) {
    enum class Role(val wire: String) { SYSTEM("system"), USER("user"), ASSISTANT("assistant") }
}

/** Token counts reported by the provider. Port of `AITokenUsage`. */
data class AiTokenUsage(val promptTokens: Int = 0, val completionTokens: Int = 0, val totalTokens: Int = 0) {
    operator fun plus(other: AiTokenUsage) = AiTokenUsage(promptTokens + other.promptTokens, completionTokens + other.completionTokens, totalTokens + other.totalTokens)

    companion object { val ZERO = AiTokenUsage() }
}

/** A completed chat call. [truncated] is true when the provider stopped at its output limit. */
class AiChatResult(val content: String, val usage: AiTokenUsage, val truncated: Boolean = false)

/** The chat capability the agent loop needs; [AiClient] is the production implementation. */
fun interface AiChat {
    /** @throws AiClientException on every failure, including cancellation. */
    fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult

    /**
     * Like [chat], and reports the reply as it is written: [onText] gets all of the text so far,
     * on the calling thread. A model that can not stream reports nothing until it returns.
     */
    fun chatStream(messages: List<AiMessage>, cancellation: AiCancellation, onText: (String) -> Unit): AiChatResult = chat(messages, cancellation)
}

/**
 * Non-streaming chat against OpenAI-compatible chat completions or the
 * Anthropic Messages API. Port of `AIClient.chat` / `availableModels`.
 *
 * The API key is passed per call and only ever placed in a request header.
 * Every failure is an [AiClientException] whose message is fixed text plus,
 * at most, the HTTP status and a short provider error code: never the key
 * and never a response body.
 */
class AiClient(private val transport: AiTransport = HttpsAiTransport()) {

    /** Sends [messages] and returns the model's text. Blocks; call it off the main thread. */
    fun chat(messages: List<AiMessage>, settings: AiSettings, apiKey: String, cancellation: AiCancellation = AiCancellation()): AiChatResult {
        val request = buildChatRequest(messages, settings, apiKey)
        if (cancellation.isCancelled) throw AiClientException(AiErrorKind.CANCELLED, "Cancelled.")
        val response = perform(request, apiKey, cancellation)
        return scrub(apiKey) { parseChatResponse(settings.profile.kind, response) }
    }

    /** An [AiChat] bound to [settings] and [apiKey], for [AgentLoop]. */
    fun bind(settings: AiSettings, apiKey: String): AiChat = object : AiChat {
        override fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult = chat(messages, settings, apiKey, cancellation)
        override fun chatStream(messages: List<AiMessage>, cancellation: AiCancellation, onText: (String) -> Unit): AiChatResult =
            chatStream(messages, settings, apiKey, cancellation, onText)
    }

    /**
     * Sends [messages] asking for a streamed reply and reports the text so far through [onText].
     * Port of `AIClient.chatStream`. A server that refuses the streamed form, answers it in the
     * plain form, or sends nothing that can be read is asked once more in the plain way. So is
     * one whose streamed request failed in transport (no connection, a broken one, no answer in
     * time) before any text arrived. After text arrived nothing is sent again: what was shown
     * must not be replaced by a second, different answer. Authentication, the usage limit, a
     * redirect, a reply over the size limit and cancellation are reported as they are.
     */
    fun chatStream(messages: List<AiMessage>, settings: AiSettings, apiKey: String, cancellation: AiCancellation = AiCancellation(), onText: (String) -> Unit): AiChatResult {
        val request = buildChatRequest(messages, settings, apiKey, stream = true)
        if (cancellation.isCancelled) throw AiClientException(AiErrorKind.CANCELLED, "Cancelled.")
        val events = AiStreamReader(settings.profile.kind.usesAnthropicMessages, onText)
        val response = scrub(apiKey) {
            try {
                transport.executeStreaming(request, cancellation) { events.feed(it) }
            } catch (error: AiClientException) {
                if (cancellation.isCancelled) throw AiClientException(AiErrorKind.CANCELLED, "Cancelled.")
                if (error.kind !in TRANSPORT_FAILURES || events.text.isNotEmpty()) throw error
                null
            } catch (_: Exception) {
                if (cancellation.isCancelled) throw AiClientException(AiErrorKind.CANCELLED, "Cancelled.")
                if (events.text.isNotEmpty()) throw AiClientException(AiErrorKind.NETWORK, "The AI request could not be sent.")
                null
            }
        } ?: return chat(messages, settings, apiKey, cancellation).also { onText(it.content) }
        return scrub(apiKey) {
            if (response.status in listOf(401, 403, 429)) throw httpError(response)
            events.finish()
            when {
                // The server would not stream: ask in the plain way.
                response.status !in 200..299 -> chat(messages, settings, apiKey, cancellation)
                events.refused -> throw AiClientException(AiErrorKind.REFUSED, "The model declined this request. Rephrase the description and try again.")
                events.sawEvent && events.text.isNotBlank() -> {
                    onText(events.text)
                    AiChatResult(events.text, events.usage, events.truncated)
                }
                events.sawEvent -> throw AiClientException(AiErrorKind.EMPTY_RESPONSE, "The model returned an empty response.")
                // A plain JSON body means the server ignored "stream".
                else -> parseChatResponse(settings.profile.kind, response).also { onText(it.content) }
            }
        }
    }

    /** Model identifiers the endpoint lists (`GET /v1/models`), sorted. Used by "Test connection". */
    fun listModels(profile: AiProfile, apiKey: String, cancellation: AiCancellation = AiCancellation()): List<String> {
        val base = endpoint(profile)
        val key = requireKey(apiKey)
        val url = base + "/v1/models" + if (profile.kind.usesAnthropicMessages) "?limit=1000" else ""
        val request = AiHttpRequest("GET", url, authentication(profile.kind, key), null, CONNECT_TIMEOUT_MILLISECONDS, MODELS_TIMEOUT_MILLISECONDS, MAXIMUM_MODELS_BYTES)
        val response = perform(request, apiKey, cancellation)
        return scrub(apiKey) {
            if (response.status !in 200..299) throw httpError(response)
            val data = parseObject(response.body).optJSONArray("data") ?: throw malformed()
            (0 until data.length()).mapNotNull { index -> (data.optJSONObject(index)?.opt("id") as? String)?.takeIf { it.isNotEmpty() && it.length <= AiProfile.MAXIMUM_MODEL_LENGTH } }.distinct().sorted()
        }
    }

    /** Builds the chat request for the profile's API style. Visible so its JSON shape can be tested. */
    fun buildChatRequest(messages: List<AiMessage>, settings: AiSettings, apiKey: String, stream: Boolean = false): AiHttpRequest {
        val profile = settings.profile
        val base = endpoint(profile)
        val key = requireKey(apiKey)
        val model = profile.model.trim()
        val headers = LinkedHashMap<String, String>()
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        headers.putAll(authentication(profile.kind, key))
        val body = JSONObject().put("model", model)
        val path: String
        if (profile.kind.usesAnthropicMessages) {
            path = "/v1/messages"
            // The Messages API takes the system prompt as a top-level field and requires max_tokens.
            // Sampling parameters are not sent: current Claude models reject them.
            // A message without text is refused by the API, so it is left out.
            body.put("max_tokens", ANTHROPIC_MAX_TOKENS)
            val system = messages.filter { it.role == AiMessage.Role.SYSTEM }.joinToString("\n\n") { it.content }
            if (system.isNotEmpty()) body.put("system", system)
            body.put("messages", JSONArray(messages.filter { it.role != AiMessage.Role.SYSTEM && it.content.isNotBlank() }.map { JSONObject().put("role", it.role.wire).put("content", it.content) }))
        } else {
            path = "/v1/chat/completions"
            body.put("messages", JSONArray(messages.map { JSONObject().put("role", it.role.wire).put("content", it.content) }))
            body.put("temperature", settings.temperature)
            if (stream) body.put("stream_options", JSONObject().put("include_usage", true))
        }
        if (stream) {
            body.put("stream", true)
            headers["Accept"] = "text/event-stream"
        }
        return AiHttpRequest("POST", base + path, headers, body.toString().toByteArray(Charsets.UTF_8), CONNECT_TIMEOUT_MILLISECONDS, CHAT_TIMEOUT_MILLISECONDS, MAXIMUM_RESPONSE_BYTES)
    }

    /** Parses a chat response of either API style. Visible so error bodies and malformed JSON can be tested. */
    fun parseChatResponse(kind: AiProviderKind, response: AiHttpResponse): AiChatResult {
        if (response.status !in 200..299) throw httpError(response)
        if (response.body.size > MAXIMUM_RESPONSE_BYTES) throw AiClientException(AiErrorKind.RESPONSE_TOO_LARGE, "The AI response exceeded the size limit.")
        val json = parseObject(response.body)
        return if (kind.usesAnthropicMessages) parseAnthropic(json) else parseChatCompletion(json)
    }

    private fun parseAnthropic(json: JSONObject): AiChatResult {
        if (json.optString("type") == "error" || json.optJSONObject("error") != null) throw AiClientException(AiErrorKind.HTTP, "The AI server reported an error" + errorCode(json) + ".")
        val stop = json.opt("stop_reason") as? String
        if (stop == "refusal") throw AiClientException(AiErrorKind.REFUSED, "The model declined this request. Rephrase the description and try again.")
        val blocks = json.optJSONArray("content") ?: throw malformed()
        val text = StringBuilder()
        for (index in 0 until blocks.length()) {
            val block = blocks.optJSONObject(index) ?: continue
            // Thinking and tool blocks are not widget code.
            if (block.optString("type") == "text") (block.opt("text") as? String)?.let { text.append(it) }
        }
        if (text.isBlank()) throw AiClientException(AiErrorKind.EMPTY_RESPONSE, "The model returned an empty response.")
        val usage = json.optJSONObject("usage")
        val input = count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens") + count(usage, "cache_read_input_tokens")
        val output = count(usage, "output_tokens")
        return AiChatResult(text.toString(), AiTokenUsage(input, output, input + output), truncated = stop == "max_tokens")
    }

    private fun parseChatCompletion(json: JSONObject): AiChatResult {
        if (json.opt("error").let { it != null && it != JSONObject.NULL } && json.optJSONArray("choices") == null) throw AiClientException(AiErrorKind.HTTP, "The AI server reported an error" + errorCode(json) + ".")
        val choice = json.optJSONArray("choices")?.optJSONObject(0) ?: throw malformed()
        val content = choice.optJSONObject("message")?.opt("content") as? String
        if (content.isNullOrBlank()) throw AiClientException(AiErrorKind.EMPTY_RESPONSE, "The model returned an empty response.")
        val usage = json.optJSONObject("usage")
        val prompt = count(usage, "prompt_tokens")
        val completion = count(usage, "completion_tokens")
        val total = count(usage, "total_tokens").takeIf { it > 0 } ?: (prompt + completion)
        return AiChatResult(content, AiTokenUsage(prompt, completion, total), truncated = choice.opt("finish_reason") == "length")
    }

    private fun perform(request: AiHttpRequest, apiKey: String, cancellation: AiCancellation): AiHttpResponse = scrub(apiKey) {
        try {
            transport.execute(request, cancellation)
        } catch (error: AiClientException) {
            throw error
        } catch (_: Exception) {
            if (cancellation.isCancelled) throw AiClientException(AiErrorKind.CANCELLED, "Cancelled.")
            throw AiClientException(AiErrorKind.NETWORK, "The AI request could not be sent.")
        }
    }

    /** Last line of defence: an error that somehow mentions the key is replaced by one that does not. */
    private inline fun <T> scrub(apiKey: String, block: () -> T): T = try {
        block()
    } catch (error: AiClientException) {
        val key = apiKey.trim()
        if (key.isNotEmpty() && error.message.orEmpty().contains(key)) throw AiClientException(error.kind, "The AI request failed.", error.httpStatus)
        throw error
    }

    /** Port of the status mapping in `AIClient.chat`. */
    private fun httpError(response: AiHttpResponse): AiClientException {
        val message = when (response.status) {
            401, 403 -> "The AI server rejected authentication. Check this profile's API key."
            404 -> "The AI endpoint or model was not found. Check the API base URL and model name."
            429 -> "The AI server's usage limit was reached. Wait and try again."
            else -> "The AI server could not complete the request (HTTP ${response.status})" + errorCode(runCatching { parseObject(response.body) }.getOrNull()) + "."
        }
        return AiClientException(AiErrorKind.HTTP, message, response.status)
    }

    private fun parseObject(body: ByteArray): JSONObject = try {
        JSONObject(String(body, Charsets.UTF_8))
    } catch (_: Exception) {
        throw malformed()
    }

    private fun malformed() = AiClientException(AiErrorKind.MALFORMED_RESPONSE, "The AI server returned a response that could not be read. Check the API base URL.")

    private fun count(usage: JSONObject?, key: String): Int = (usage?.opt(key) as? Number)?.toInt()?.coerceAtLeast(0) ?: 0

    private fun endpoint(profile: AiProfile): String {
        profile.validationError()?.let { throw AiClientException(AiErrorKind.INVALID_PROFILE, it) }
        return profile.normalizedBaseUrl
    }

    private fun requireKey(apiKey: String): String {
        val key = apiKey.trim()
        if (key.isEmpty()) throw AiClientException(AiErrorKind.MISSING_API_KEY, "API key is not set. Open Settings → AI to configure it.")
        // A key with control characters could inject headers.
        if (key.length > MAXIMUM_KEY_LENGTH || key.any { it.isISOControl() || it.code > 0x7E }) throw AiClientException(AiErrorKind.MISSING_API_KEY, "The API key contains characters that are not allowed.")
        return key
    }

    private fun authentication(kind: AiProviderKind, key: String): Map<String, String> =
        if (kind.usesAnthropicMessages) linkedMapOf("x-api-key" to key, "anthropic-version" to ANTHROPIC_VERSION) else linkedMapOf("Authorization" to "Bearer $key")

    companion object {
        const val ANTHROPIC_VERSION = "2023-06-01"
        /** Room for a full widget plus the model's own reasoning, while staying a non-streaming request. */
        const val ANTHROPIC_MAX_TOKENS = 16_000
        /** Same 4 MiB cap as `AIClient.chat`. */
        const val MAXIMUM_RESPONSE_BYTES = 4 * 1024 * 1024
        /** Same 1 MiB cap as `AIClient.availableModels`. */
        const val MAXIMUM_MODELS_BYTES = 1024 * 1024
        const val MAXIMUM_KEY_LENGTH = 4096
        const val CONNECT_TIMEOUT_MILLISECONDS = 15_000
        /** Swift allows 120 s; models that reason before answering need longer for a non-streaming reply. */
        const val CHAT_TIMEOUT_MILLISECONDS = 300_000
        /** Same 15 s as `AIClient.availableModels`. */
        const val MODELS_TIMEOUT_MILLISECONDS = 15_000
        /** Failures of the connection, not answers of the server: the only ones a streamed request is tried again after. */
        private val TRANSPORT_FAILURES = setOf(AiErrorKind.NETWORK, AiErrorKind.TIMEOUT)
    }
}

private val ERROR_CODE = Regex("[A-Za-z0-9_.-]{1,64}")

/** A short machine error code such as `invalid_request_error`, never free text. */
private fun errorCode(json: JSONObject?): String {
    val error = json?.optJSONObject("error") ?: return ""
    val code = sequenceOf("type", "code").mapNotNull { error.opt(it) as? String }.firstOrNull { ERROR_CODE.matches(it) } ?: return ""
    return " ($code)"
}

/**
 * Reads a server-sent event stream of either API style as its bytes arrive and keeps the text
 * so far. Lines are split on the bytes, so a character that arrives in two pieces is not broken.
 */
internal class AiStreamReader(private val anthropic: Boolean, private val onText: (String) -> Unit) {
    private val pending = java.io.ByteArrayOutputStream()
    private val content = StringBuilder()
    private var lastSent = 0L
    private var input = 0
    private var output = 0
    private var total = 0

    var sawEvent = false
        private set
    var truncated = false
        private set
    var refused = false
        private set
    val text: String get() = content.toString()
    val usage: AiTokenUsage get() = AiTokenUsage(input, output, if (total > 0) total else input + output)

    fun feed(bytes: ByteArray) {
        for (byte in bytes) {
            if (byte == '\n'.code.toByte()) {
                line(String(pending.toByteArray(), Charsets.UTF_8).trimEnd('\r'))
                pending.reset()
            } else if (pending.size() < MAXIMUM_LINE_BYTES) {
                pending.write(byte.toInt())
            }
        }
    }

    /** Reads a last line that did not end with a line break. */
    fun finish() {
        if (pending.size() > 0) line(String(pending.toByteArray(), Charsets.UTF_8).trimEnd('\r'))
        pending.reset()
    }

    private fun line(line: String) {
        if (!line.startsWith("data:")) return
        val payload = line.substring(5).trim()
        if (payload == "[DONE]" || payload.isEmpty()) return
        val json = runCatching { JSONObject(payload) }.getOrNull() ?: return
        sawEvent = true
        val piece = if (anthropic) anthropicEvent(json) else chatCompletionEvent(json)
        if (piece.isNullOrEmpty()) return
        if (content.length + piece.length > AiClient.MAXIMUM_RESPONSE_BYTES) throw AiClientException(AiErrorKind.RESPONSE_TOO_LARGE, "The AI response exceeded the size limit.")
        content.append(piece)
        val now = System.nanoTime() / 1_000_000
        if (now - lastSent >= 80) {
            lastSent = now
            onText(content.toString())
        }
    }

    private fun chatCompletionEvent(json: JSONObject): String? {
        json.optJSONObject("usage")?.let { usage ->
            input = count(usage, "prompt_tokens"); output = count(usage, "completion_tokens"); total = count(usage, "total_tokens")
        }
        val choice = json.optJSONArray("choices")?.optJSONObject(0) ?: return null
        if (choice.opt("finish_reason") == "length") truncated = true
        return choice.optJSONObject("delta")?.opt("content") as? String
    }

    private fun anthropicEvent(json: JSONObject): String? {
        when (json.optString("type")) {
            "message_start" -> json.optJSONObject("message")?.optJSONObject("usage")?.let { usage ->
                input = count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens") + count(usage, "cache_read_input_tokens")
            }
            "message_delta" -> {
                json.optJSONObject("usage")?.let { output = count(it, "output_tokens") }
                when (json.optJSONObject("delta")?.opt("stop_reason")) {
                    "max_tokens" -> truncated = true
                    "refusal" -> refused = true
                }
            }
            "content_block_delta" -> {
                val delta = json.optJSONObject("delta") ?: return null
                // Thinking and tool input are not widget code.
                if (delta.optString("type") == "text_delta") return delta.opt("text") as? String
            }
            // The stream broke off; what was read so far is not a reply.
            "error" -> throw AiClientException(AiErrorKind.HTTP, "The AI server reported an error" + errorCode(json) + ".")
        }
        return null
    }

    private fun count(usage: JSONObject, key: String): Int = (usage.opt(key) as? Number)?.toInt()?.coerceAtLeast(0) ?: 0

    private companion object {
        const val MAXIMUM_LINE_BYTES = 1024 * 1024
    }
}
