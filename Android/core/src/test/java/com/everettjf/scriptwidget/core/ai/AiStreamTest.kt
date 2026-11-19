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
