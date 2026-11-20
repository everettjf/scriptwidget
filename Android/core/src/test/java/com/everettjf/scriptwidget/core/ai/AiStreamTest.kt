package com.everettjf.scriptwidget.core.ai

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Streamed replies of both API styles, the fallbacks, and what the loop reports. No network. */
class AiStreamTest {
    private val key = "sk-stream-secret-91ab"
    private val openai = AiSettings(AiProfile.defaults(AiProviderKind.OPENAI))
    private val anthropic = AiSettings(AiProfile.defaults(AiProviderKind.ANTHROPIC))
    private val messages = listOf(AiMessage(AiMessage.Role.USER, "make a clock"))

    /** Hands a body over in pieces of [step] bytes, as a network would. */
    private class StreamingTransport(private val responses: MutableList<AiHttpResponse>, private val step: Int = 7) : AiTransport {
        val requests = ArrayList<AiHttpRequest>()
        override fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse { requests += request; return responses.removeAt(0) }
        override fun executeStreaming(request: AiHttpRequest, cancellation: AiCancellation, onBody: (ByteArray) -> Unit): AiHttpResponse {
            requests += request
            val response = responses.removeAt(0)
            if (response.status in 200..299) response.body.toList().chunked(step).forEach { onBody(it.toByteArray()) }
            return response
        }
    }

    private fun sse(vararg events: String) = AiHttpResponse(200, events.joinToString("") { "data: $it\n\n" }.toByteArray())
    private fun delta(text: String) = JSONObject().put("choices", org.json.JSONArray().put(JSONObject().put("delta", JSONObject().put("content", text)))).toString()

    @Test
    fun anOpenAiStreamIsReadAsItArrivesAndEndsAsOneText() {
        val transport = StreamingTransport(arrayListOf(sse(
            delta("SUMMARY: 你好。\n"), delta("```jsx\n\$render("), delta("<vstack/>)\n```"),
            """{"choices":[{"delta":{},"finish_reason":"stop"}]}""",
            """{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}""", "[DONE]",
        )))
        val seen = ArrayList<String>()
        val result = AiClient(transport).chatStream(messages, openai, key, onText = { seen += it })
        val whole = "SUMMARY: 你好。\n```jsx\n\$render(<vstack/>)\n```"
        assertEquals(whole, result.content)
        assertEquals(AiTokenUsage(10, 5, 15), result.usage)
        assertFalse(result.truncated)
        assertEquals(whole, seen.last())
        assertTrue("every report is the text so far", seen.all { whole.startsWith(it) })
        val body = JSONObject(String(transport.requests.single().body!!))
        assertTrue(body.getBoolean("stream"))
        assertTrue(body.getJSONObject("stream_options").getBoolean("include_usage"))
        assertEquals("text/event-stream", transport.requests.single().headers["Accept"])
    }

    @Test
    fun anAnthropicStreamKeepsOnlyTheTextAndCountsTokens() {
        val transport = StreamingTransport(arrayListOf(sse(
            """{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":3}}}""",
            """{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}""",
            """{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}""",
            """{"type":"content_block_delta","delta":{"type":"text_delta","text":"there"}}""",
            """{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":7}}""",
            """{"type":"message_stop"}""",
        )), step = 3)
        val result = AiClient(transport).chatStream(messages, anthropic, key, onText = {})
        assertEquals("Hello there", result.content)
        assertEquals(AiTokenUsage(23, 7, 30), result.usage)
        assertTrue(result.truncated)
        assertTrue(JSONObject(String(transport.requests.single().body!!)).getBoolean("stream"))
    }

    /** The API refuses a message without text; one is left after an empty reply. */
    @Test
    fun anAnthropicRequestLeavesOutMessagesWithoutText() {
        val history = listOf(
            AiMessage(AiMessage.Role.SYSTEM, "rules"),
            AiMessage(AiMessage.Role.USER, "make a clock"),
            AiMessage(AiMessage.Role.ASSISTANT, ""),
            AiMessage(AiMessage.Role.USER, " \n\t"),
            AiMessage(AiMessage.Role.USER, "try again"),
        )
        val client = AiClient(StreamingTransport(arrayListOf()))
        for (stream in listOf(false, true)) {
            val sent = JSONObject(String(client.buildChatRequest(history, anthropic, key, stream).body!!)).getJSONArray("messages")
            assertEquals(listOf("user" to "make a clock", "user" to "try again"), List(sent.length()) { sent.getJSONObject(it).let { message -> message.getString("role") to message.getString("content") } })
        }
        // Chat completions accepts them, as Swift sends them.
        assertEquals(5, JSONObject(String(client.buildChatRequest(history, openai, key).body!!)).getJSONArray("messages").length())
    }

    /** An `error` event in the middle of the stream fails the request: the text before it is not a reply. */
    @Test
    fun anErrorEventInAnAnthropicStreamFailsTheRequest() {
        fun failure(transport: AiTransport, settings: AiSettings = anthropic): AiClientException = try {
            AiClient(transport).chatStream(messages, settings, key, onText = {})
            throw AssertionError("expected AiClientException")
        } catch (error: AiClientException) {
            error
        }
        val transport = StreamingTransport(arrayListOf(sse(
            """{"type":"content_block_delta","delta":{"type":"text_delta","text":"SUMMARY: half"}}""",
            """{"type":"error","error":{"type":"overloaded_error","message":"secret text"}}""",
        )), step = 5)
        val error = failure(transport)
        assertEquals(AiErrorKind.HTTP, error.kind)
        assertEquals("The AI server reported an error (overloaded_error).", error.message)
        assertEquals("nothing is sent again", 1, transport.requests.size)
        // Before any text too, and without a code that can be shown.
        val early = StreamingTransport(arrayListOf(sse("""{"type":"error","error":{"type":"not a code","message":"x"}}""")))
        assertEquals("The AI server reported an error.", failure(early).message)
        assertEquals(1, early.requests.size)
        // A code that echoes the key is not shown.
        assertFalse(failure(StreamingTransport(arrayListOf(sse("""{"type":"error","error":{"type":"$key"}}""")))).message.orEmpty().contains(key))
        // The same object in a chat-completions stream is not this event.
        val other = StreamingTransport(arrayListOf(sse(delta("whole"), """{"type":"error"}""")))
        assertEquals("whole", AiClient(other).chatStream(messages, openai, key, onText = {}).content)
    }

    @Test
    fun aServerThatWillNotStreamIsAskedInThePlainWay() {
        val plain = """{"choices":[{"message":{"content":"plain reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2}}"""
        // Refuses the streamed form with a 400, then answers the plain request.
        val refusing = StreamingTransport(arrayListOf(AiHttpResponse(400, "{}".toByteArray()), AiHttpResponse(200, plain.toByteArray())))
        val seen = ArrayList<String>()
        assertEquals("plain reply", AiClient(refusing).chatStream(messages, openai, key, onText = { seen += it }).content)
        assertEquals(2, refusing.requests.size)
        assertFalse(JSONObject(String(refusing.requests[1].body!!)).has("stream"))
        // Ignores "stream" and answers with one JSON body: read as it is, no second request.
        val ignoring = StreamingTransport(arrayListOf(AiHttpResponse(200, plain.toByteArray())))
        assertEquals("plain reply", AiClient(ignoring).chatStream(messages, openai, key, onText = { seen += it }).content)
        assertEquals(1, ignoring.requests.size)
        assertEquals("plain reply", seen.last())
    }

    /** Fails the streamed request with [failure] after handing over [before]; answers the plain one. */
    private class BreakingTransport(private val failure: Exception, private val before: String = "", private val plain: AiHttpResponse) : AiTransport {
        val requests = ArrayList<AiHttpRequest>()
        override fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse { requests += request; return plain }
        override fun executeStreaming(request: AiHttpRequest, cancellation: AiCancellation, onBody: (ByteArray) -> Unit): AiHttpResponse {
            requests += request
            if (before.isNotEmpty()) onBody(before.toByteArray())
            throw failure
        }
    }

    private val plainReply = AiHttpResponse(200, """{"choices":[{"message":{"content":"plain reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2}}""".toByteArray())

    @Test
    fun aStreamThatFailsInTransportBeforeAnyTextIsAskedOnceInThePlainWay() {
        val failures = listOf(
            AiClientException(AiErrorKind.NETWORK, "The AI server could not be reached. Check your connection and try again."),
            AiClientException(AiErrorKind.TIMEOUT, "The AI server did not answer in time. Try again."),
            java.io.IOException("connection reset"),
        )
        for (failure in failures) {
            val transport = BreakingTransport(failure, plain = plainReply)
            val seen = ArrayList<String>()
            assertEquals("plain reply", AiClient(transport).chatStream(messages, openai, key, onText = { seen += it }).content)
            assertEquals("one streamed request, one plain request", 2, transport.requests.size)
            assertTrue(JSONObject(String(transport.requests[0].body!!)).getBoolean("stream"))
            assertFalse(JSONObject(String(transport.requests[1].body!!)).has("stream"))
            assertEquals(listOf("plain reply"), seen)
        }
        // Events that carried no text (a role, a ping) are not text: the request is still tried again.
        val silent = BreakingTransport(java.io.IOException("reset"), before = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n", plain = plainReply)
        assertEquals("plain reply", AiClient(silent).chatStream(messages, openai, key, onText = {}).content)
        // The plain request fails too: that failure is reported, and nothing is sent a third time.
        val twice = object : AiTransport {
            var requests = 0
            override fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse { requests += 1; throw AiClientException(AiErrorKind.NETWORK, "second failure") }
            override fun executeStreaming(request: AiHttpRequest, cancellation: AiCancellation, onBody: (ByteArray) -> Unit): AiHttpResponse { requests += 1; throw AiClientException(AiErrorKind.NETWORK, "first failure") }
        }
        val error = try { AiClient(twice).chatStream(messages, openai, key, onText = {}); null } catch (failure: AiClientException) { failure }
        assertEquals("second failure", error!!.message)
        assertEquals(2, twice.requests)
    }

    @Test
    fun aStreamThatBreaksAfterTextArrivedIsNeverSentAgain() {
        val partial = "data: ${delta("SUMMARY: half")}\n\n"
        for (failure in listOf(AiClientException(AiErrorKind.NETWORK, "The AI server could not be reached. Check your connection and try again."), java.io.IOException("reset"))) {
            val transport = BreakingTransport(failure, before = partial, plain = plainReply)
            val seen = ArrayList<String>()
            val error = try { AiClient(transport).chatStream(messages, openai, key, onText = { seen += it }); null } catch (thrown: AiClientException) { thrown }
            assertEquals(AiErrorKind.NETWORK, error!!.kind)
            assertEquals("no second request", 1, transport.requests.size)
            assertFalse("the text shown is not replaced by another answer", seen.contains("plain reply"))
        }
    }

    @Test
    fun refusalsOfTheServerAndCancellationAreNeverTriedAgain() {
        // 401, 403 and 429 are answers of the server, not transport failures.
        for (status in listOf(401, 403, 429)) {
            val transport = StreamingTransport(arrayListOf(AiHttpResponse(status, "{}".toByteArray()), plainReply))
            val error = try { AiClient(transport).chatStream(messages, openai, key, onText = {}); null } catch (thrown: AiClientException) { thrown }
            assertEquals(status, error!!.httpStatus)
            assertEquals("HTTP $status is not asked again", 1, transport.requests.size)
        }
        // A redirect, a reply over the size limit and an invalid profile are not transport failures either.
        for (kind in listOf(AiErrorKind.HTTP, AiErrorKind.RESPONSE_TOO_LARGE, AiErrorKind.INVALID_PROFILE)) {
            val transport = BreakingTransport(AiClientException(kind, "as it is"), plain = plainReply)
            val error = try { AiClient(transport).chatStream(messages, openai, key, onText = {}); null } catch (thrown: AiClientException) { thrown }
            assertEquals(kind, error!!.kind)
            assertEquals(1, transport.requests.size)
        }
        // Cancelled while the stream was open: the failure that follows is the cancellation, and nothing is sent.
        val cancellation = AiCancellation()
        val cancelled = object : AiTransport {
            var requests = 0
            override fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse { requests += 1; return plainReply }
            override fun executeStreaming(request: AiHttpRequest, token: AiCancellation, onBody: (ByteArray) -> Unit): AiHttpResponse { requests += 1; token.cancel(); throw java.io.IOException("socket closed") }
        }
        val error = try { AiClient(cancelled).chatStream(messages, openai, key, cancellation, onText = {}); null } catch (thrown: AiClientException) { thrown }
        assertEquals(AiErrorKind.CANCELLED, error!!.kind)
        assertEquals(1, cancelled.requests)
    }

    @Test
    fun authenticationAndEmptyStreamsFailWithoutTheKey() {
        val rejected = try { AiClient(StreamingTransport(arrayListOf(AiHttpResponse(401, "{}".toByteArray())))).chatStream(messages, openai, key, onText = {}); null } catch (error: AiClientException) { error }
        assertEquals(AiErrorKind.HTTP, rejected!!.kind)
        assertFalse(rejected.message!!.contains(key))
        val empty = try { AiClient(StreamingTransport(arrayListOf(sse("""{"choices":[{"delta":{}}]}""", "[DONE]")))).chatStream(messages, openai, key, onText = {}); null } catch (error: AiClientException) { error }
        assertEquals(AiErrorKind.EMPTY_RESPONSE, empty!!.kind)
    }

    @Test
    fun aTransportThatCanNotStreamStillReturnsTheReply() {
        val transport = AiTransport { _, _ -> sse(delta("whole "), delta("reply"), "[DONE]") }
        val seen = ArrayList<String>()
        assertEquals("whole reply", AiClient(transport).chatStream(messages, openai, key, onText = { seen += it }).content)
        assertEquals("whole reply", seen.last())
    }

    @Test
    fun aTurnReportsTheReplyAsItIsWrittenAndOtherModesDoNot() {
        val chat = object : AiChat {
            override fun chat(messages: List<AiMessage>, cancellation: AiCancellation) = AiChatResult("\$render(<vstack/>)", AiTokenUsage(1, 1, 2))
            override fun chatStream(messages: List<AiMessage>, cancellation: AiCancellation, onText: (String) -> Unit): AiChatResult {
                onText("SUMMARY: A"); onText("SUMMARY: A\n```jsx\n\$render(")
                return AiChatResult("SUMMARY: A\n```jsx\n\$render(<vstack/>)\n```", AiTokenUsage(1, 1, 2))
            }
        }
        val partial = ArrayList<String>()
        val turn = AgentLoopRequest(AgentLoopRequest.Mode.Turn(AiTurnContext(emptyList(), null, null, "a clock", null, AiWidgetSize.MEDIUM)), AiWidgetSize.MEDIUM, "SYSTEM", 2)
        AgentLoop(chat).run(turn, { _, _ -> ValidationResult.success() }, onEvent = { if (it is AgentLoopEvent.Partial) partial += it.text })
        assertEquals(2, partial.size)
        assertEquals("", PromptBuilder.previewOfPartialReply(partial[0].replace("SUMMARY: A", "```jsx")))
        assertEquals("\$render(", PromptBuilder.previewOfPartialReply(partial[1]))
        assertEquals("SUMMARY: A", PromptBuilder.previewOfPartialReply(partial[0]))
        partial.clear()
        AgentLoop(chat).run(AgentLoopRequest(AgentLoopRequest.Mode.Fresh("a clock"), AiWidgetSize.MEDIUM, "SYSTEM", 2), { _, _ -> ValidationResult.success() }, onEvent = { if (it is AgentLoopEvent.Partial) partial += it.text })
        assertTrue(partial.isEmpty())
    }
}
