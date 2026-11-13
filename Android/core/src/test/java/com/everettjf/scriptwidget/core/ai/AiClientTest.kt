package com.everettjf.scriptwidget.core.ai

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Covers `AIClient.swift` behavior plus the Anthropic Messages API style. No test touches the network. */
class AiClientTest {
    private val key = "sk-test-SECRET-0123456789abcdef"
    private val anthropic = AiSettings(AiProfile.defaults(AiProviderKind.ANTHROPIC))
    private val openai = AiSettings(AiProfile.defaults(AiProviderKind.OPENAI), temperature = 0.4)
    private val messages = listOf(
        AiMessage(AiMessage.Role.SYSTEM, "rules"),
        AiMessage(AiMessage.Role.USER, "make a clock"),
        AiMessage(AiMessage.Role.ASSISTANT, "old code"),
        AiMessage(AiMessage.Role.USER, "fix it"),
    )

    /** Records requests and replays canned responses. */
    private class FakeTransport(private val responses: MutableList<Any>) : AiTransport {
        val requests = ArrayList<AiHttpRequest>()
        override fun execute(request: AiHttpRequest, cancellation: AiCancellation): AiHttpResponse {
            requests += request
            return when (val next = responses.removeAt(0)) {
                is AiHttpResponse -> next
                is Exception -> throw next
                else -> error("unexpected")
            }
        }
    }

    private fun response(status: Int, body: String) = AiHttpResponse(status, body.toByteArray())

    private fun failure(block: () -> Unit): AiClientException = try {
        block(); fail("expected AiClientException"); throw AssertionError()
    } catch (error: AiClientException) {
        error
    }

    private fun assertNoKey(error: Throwable) {
        assertFalse(error.message.orEmpty().contains(key))
        assertFalse(error.toString().contains(key))
        assertFalse(error.stackTraceToString().contains(key))
        assertNull(error.cause)
    }

    @Test
    fun anthropicRequestUsesTheMessagesApiShape() {
        val request = AiClient(FakeTransport(ArrayList())).buildChatRequest(messages, anthropic, "  $key\n")
        assertEquals("POST", request.method)
        assertEquals("https://api.anthropic.com/v1/messages", request.url)
        assertEquals(key, request.headers["x-api-key"])
        assertEquals("2023-06-01", request.headers["anthropic-version"])
        assertEquals("application/json", request.headers["Content-Type"])
        assertNull(request.headers["Authorization"])
        val body = JSONObject(String(request.body!!))
        assertEquals("claude-fable-5-2", body.getString("model"))
        assertEquals(AiClient.ANTHROPIC_MAX_TOKENS, body.getInt("max_tokens"))
        assertEquals("rules", body.getString("system"))
        val sent = body.getJSONArray("messages")
        assertEquals(3, sent.length())
        assertEquals(listOf("user", "assistant", "user"), List(3) { sent.getJSONObject(it).getString("role") })
        assertEquals("make a clock", sent.getJSONObject(0).getString("content"))
        // Current Claude models reject sampling parameters and non-default thinking configuration.
        assertFalse(body.has("temperature"))
        assertFalse(body.has("thinking"))
        assertFalse(String(request.body!!).contains(key))
    }

    @Test
    fun openAiRequestUsesChatCompletionsShape() {
        val request = AiClient(FakeTransport(ArrayList())).buildChatRequest(messages, openai, key)
        assertEquals("https://api.openai.com/v1/chat/completions", request.url)
        assertEquals("Bearer $key", request.headers["Authorization"])
        assertNull(request.headers["x-api-key"])
        val body = JSONObject(String(request.body!!))
        assertEquals("gpt-4o-mini", body.getString("model"))
        assertEquals(0.4, body.getDouble("temperature"), 0.0)
        assertFalse(body.has("max_tokens"))
        val sent = body.getJSONArray("messages")
        assertEquals(listOf("system", "user", "assistant", "user"), List(4) { sent.getJSONObject(it).getString("role") })
    }

    @Test
    fun customEndpointKeepsItsPathAndDropsATrailingVersion() {
        val settings = AiSettings(AiProfile(AiProviderKind.OPENAI_COMPATIBLE, "https://gateway.example.com/openai/v1/", "my-model"))
        val request = AiClient(FakeTransport(ArrayList())).buildChatRequest(messages, settings, key)
        assertEquals("https://gateway.example.com/openai/v1/chat/completions", request.url)
    }

    @Test
    fun requestAndResponseDescriptionsNeverContainSecretsOrBodies() {
        val request = AiClient(FakeTransport(ArrayList())).buildChatRequest(messages, anthropic, key)
        assertFalse(request.toString().contains(key))
        assertFalse(request.toString().contains("make a clock"))
        assertTrue(request.toString().contains("x-api-key"))
        assertFalse(response(200, "body with $key").toString().contains(key))
        assertFalse(anthropic.toString().contains(key))
    }

    @Test
    fun parsesAnthropicTextBlocksAndUsage() {
        val body = """{"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"${'$'}render("},{"type":"text","text":"<vstack/>)"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2}}"""
        val result = AiClient(FakeTransport(arrayListOf(response(200, body)))).chat(messages, anthropic, key)
        assertEquals("\$render(<vstack/>)", result.content)
        assertEquals(AiTokenUsage(12, 5, 17), result.usage)
        assertFalse(result.truncated)
    }

    @Test
    fun anthropicMaxTokensStopIsReportedAsTruncated() {
        val body = """{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"""
        assertTrue(AiClient().parseChatResponse(AiProviderKind.ANTHROPIC, response(200, body)).truncated)
    }

    @Test
    fun anthropicRefusalAndEmptyContentFail() {
        val refusal = failure { AiClient().parseChatResponse(AiProviderKind.ANTHROPIC, response(200, """{"stop_reason":"refusal","content":[]}""")) }
        assertEquals(AiErrorKind.REFUSED, refusal.kind)
        val empty = failure { AiClient().parseChatResponse(AiProviderKind.ANTHROPIC, response(200, """{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"x"}]}""")) }
        assertEquals(AiErrorKind.EMPTY_RESPONSE, empty.kind)
    }

    @Test
    fun parsesChatCompletionAndUsage() {
        val body = """{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"code"}}],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}"""
        val result = AiClient(FakeTransport(arrayListOf(response(200, body)))).chat(messages, openai, key)
        assertEquals("code", result.content)
        assertEquals(AiTokenUsage(7, 3, 10), result.usage)
        val cut = """{"choices":[{"finish_reason":"length","message":{"content":"co"}}]}"""
        assertTrue(AiClient().parseChatResponse(AiProviderKind.OPENAI, response(200, cut)).truncated)
    }

    @Test
    fun chatCompletionWithoutContentIsEmpty() {
        for (body in listOf("""{"choices":[{"message":{"content":""}}]}""", """{"choices":[{"message":{"content":null}}]}""", """{"choices":[{"message":{}}]}""")) {
            assertEquals(AiErrorKind.EMPTY_RESPONSE, failure { AiClient().parseChatResponse(AiProviderKind.OPENAI, response(200, body)) }.kind)
        }
    }

    @Test
    fun httpErrorsMapToFixedMessagesWithoutTheBody() {
        val secretBody = """{"type":"error","error":{"type":"authentication_error","message":"Incorrect API key provided: $key. Internal detail LEAK"}}"""
        val expectations = mapOf(
            401 to "rejected authentication", 403 to "rejected authentication", 404 to "was not found", 429 to "usage limit",
            500 to "HTTP 500", 400 to "HTTP 400",
        )
        for ((status, fragment) in expectations) for (kind in listOf(AiProviderKind.ANTHROPIC, AiProviderKind.OPENAI)) {
            val settings = if (kind == AiProviderKind.ANTHROPIC) anthropic else openai
            val error = failure { AiClient(FakeTransport(arrayListOf(response(status, secretBody)))).chat(messages, settings, key) }
            assertEquals(AiErrorKind.HTTP, error.kind)
            assertEquals(status, error.httpStatus)
            assertTrue(error.message, error.message!!.contains(fragment))
            assertFalse(error.message!!.contains("LEAK"))
            assertFalse(error.message!!.contains("Incorrect"))
            assertNoKey(error)
        }
        // A short machine code is the only thing taken from an error body.
        val coded = failure { AiClient(FakeTransport(arrayListOf(response(400, secretBody)))).chat(messages, anthropic, key) }
        assertTrue(coded.message!!.contains("(authentication_error)"))
    }

    @Test
    fun anErrorCodeThatEchoesTheKeyIsScrubbed() {
        val body = """{"error":{"type":"$key"}}"""
        val error = failure { AiClient(FakeTransport(arrayListOf(response(500, body)))).chat(messages, anthropic, key) }
        assertNoKey(error)
        val inBand = failure { AiClient(FakeTransport(arrayListOf(response(200, """{"type":"error","error":{"type":"$key"}}""")))).chat(messages, anthropic, key) }
        assertNoKey(inBand)
    }

    @Test
    fun malformedJsonFailsClosed() {
        for (body in listOf("", "<html>502</html>", "[1,2]", "{\"choices\":", "{}", """{"choices":[]}""", """{"choices":"x"}""")) {
            for (kind in listOf(AiProviderKind.OPENAI, AiProviderKind.ANTHROPIC)) {
                val error = failure { AiClient().parseChatResponse(kind, response(200, body)) }
                assertEquals("$kind $body", AiErrorKind.MALFORMED_RESPONSE, error.kind)
                assertFalse(error.message!!.contains("html"))
            }
        }
    }

    @Test
    fun errorObjectInASuccessfulResponseIsAnError() {
        val anthropicError = failure { AiClient().parseChatResponse(AiProviderKind.ANTHROPIC, response(200, """{"type":"error","error":{"type":"overloaded_error","message":"secret text"}}""")) }
        assertEquals(AiErrorKind.HTTP, anthropicError.kind)
        assertTrue(anthropicError.message!!.contains("overloaded_error"))
        assertFalse(anthropicError.message!!.contains("secret text"))
        val openAiError = failure { AiClient().parseChatResponse(AiProviderKind.OPENAI, response(200, """{"error":{"message":"secret text","code":"model_not_found"}}""")) }
        assertTrue(openAiError.message!!.contains("model_not_found"))
        assertFalse(openAiError.message!!.contains("secret text"))
    }

    @Test
    fun transportFailuresNeverCarryTheKeyOrACause() {
        val leaking = listOf(
            RuntimeException("boom while sending x-api-key: $key"),
            AiClientException(AiErrorKind.NETWORK, "proxy said $key"),
            java.io.IOException("Authorization: Bearer $key"),
        )
        for (thrown in leaking) {
            val error = failure { AiClient(FakeTransport(arrayListOf(thrown))).chat(messages, anthropic, key) }
            assertNoKey(error)
        }
    }

    @Test
    fun missingOrUnsafeKeyIsRejectedBeforeAnyRequest() {
        val transport = FakeTransport(ArrayList())
        for (bad in listOf("", "   ", "\n")) assertEquals(AiErrorKind.MISSING_API_KEY, failure { AiClient(transport).chat(messages, anthropic, bad) }.kind)
        val injected = "abc\r\nX-Evil: 1"
        val error = failure { AiClient(transport).chat(messages, anthropic, injected) }
        assertEquals(AiErrorKind.MISSING_API_KEY, error.kind)
        assertFalse(error.message!!.contains("X-Evil"))
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun invalidProfileIsRejectedBeforeAnyRequest() {
        val transport = FakeTransport(ArrayList())
        val insecure = AiSettings(AiProfile(AiProviderKind.OPENAI_COMPATIBLE, "http://example.com", "m"))
        assertEquals(AiErrorKind.INVALID_PROFILE, failure { AiClient(transport).chat(messages, insecure, key) }.kind)
        val noModel = AiSettings(AiProfile(AiProviderKind.OPENAI, "", "  "))
        assertEquals(AiErrorKind.INVALID_PROFILE, failure { AiClient(transport).chat(messages, noModel, key) }.kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun cancellationBeforeSendingMakesNoRequest() {
        val transport = FakeTransport(ArrayList())
        val cancellation = AiCancellation().also { it.cancel() }
        assertEquals(AiErrorKind.CANCELLED, failure { AiClient(transport).chat(messages, anthropic, key, cancellation) }.kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun cancellationRunsRegisteredActionsOnce() {
        val cancellation = AiCancellation()
        var count = 0
        val registration = cancellation.onCancel { count += 1 }
        cancellation.cancel(); cancellation.cancel()
        assertEquals(1, count)
        registration.close()
        var late = 0
        cancellation.onCancel { late += 1 }
        assertEquals(1, late)
    }

    @Test
    fun productionTransportRefusesPlainHttpWithoutConnecting() {
        val request = AiHttpRequest("GET", "http://127.0.0.1:9/v1/models", mapOf("x-api-key" to key), null, 100, 100, 1024)
        val error = failure { HttpsAiTransport().execute(request, AiCancellation()) }
        assertEquals(AiErrorKind.INVALID_PROFILE, error.kind)
        assertNoKey(error)
    }

    @Test
    fun listModelsUsesTheProviderAuthenticationAndSortsIds() {
        val body = """{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"name":"no id"},{"id":7}]}"""
        val transport = FakeTransport(arrayListOf(response(200, body), response(200, body)))
        assertEquals(listOf("a", "b"), AiClient(transport).listModels(anthropic.profile, key))
        assertEquals(listOf("a", "b"), AiClient(transport).listModels(openai.profile, key))
        assertEquals("GET", transport.requests[0].method)
        assertEquals("https://api.anthropic.com/v1/models?limit=1000", transport.requests[0].url)
        assertEquals(key, transport.requests[0].headers["x-api-key"])
        assertEquals("https://api.openai.com/v1/models", transport.requests[1].url)
        assertEquals("Bearer $key", transport.requests[1].headers["Authorization"])
        assertNull(transport.requests[0].body)
    }

    @Test
    fun listModelsFailuresAreMappedAndKeyFree() {
        val unauthorized = failure { AiClient(FakeTransport(arrayListOf(response(401, "nope $key")))).listModels(anthropic.profile, key) }
        assertTrue(unauthorized.message!!.contains("rejected authentication"))
        assertNoKey(unauthorized)
        assertEquals(AiErrorKind.MALFORMED_RESPONSE, failure { AiClient(FakeTransport(arrayListOf(response(200, "{}")))).listModels(anthropic.profile, key) }.kind)
    }
}
