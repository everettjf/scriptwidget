package com.everettjf.scriptwidget.core.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ports the behavior of `AgentLoop.run` with a fake model and a fake runtime. */
class AgentLoopTest {
    private val usagePerCall = AiTokenUsage(10, 5, 15)

    /** Replies in order; a reply may be an exception to throw. Records every conversation. */
    private class FakeChat(private val replies: List<Any>, private val onCall: (Int) -> Unit = {}) : AiChat {
        val conversations = ArrayList<List<AiMessage>>()
        override fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult {
            conversations += messages
            onCall(conversations.size)
            return when (val reply = replies[minOf(conversations.size, replies.size) - 1]) {
                is AiChatResult -> reply
                is Exception -> throw reply
                else -> AiChatResult(reply as String, AiTokenUsage(10, 5, 15))
            }
        }
    }

    private fun request(mode: AgentLoopRequest.Mode = AgentLoopRequest.Mode.Fresh("a clock"), maxIterations: Int = 20, skills: String? = null) =
        AgentLoopRequest(mode, AiWidgetSize.MEDIUM, "SYSTEM", maxIterations, skills)

    private fun describe(event: AgentLoopEvent): String = when (event) {
        is AgentLoopEvent.Thinking -> "thinking${event.iteration}"
        is AgentLoopEvent.Produced -> "produced${event.iteration}"
        is AgentLoopEvent.Running -> "running${event.iteration}"
        is AgentLoopEvent.RanFailed -> "failed${event.iteration}"
        is AgentLoopEvent.RanSucceeded -> "succeeded${event.iteration}"
        is AgentLoopEvent.TokensUsed -> "tokens${event.usage.totalTokens}"
    }

    @Test
    fun succeedsOnTheFirstTry() {
        val chat = FakeChat(listOf("```jsx\n\$render(<vstack/>)\n```"))
        val events = ArrayList<String>()
        val validated = ArrayList<Pair<String, String?>>()
        val outcome = AgentLoop(chat).run(request(), { source, manifest -> validated += source to manifest; ValidationResult.success() }, onEvent = { events += describe(it) })
        outcome as AgentLoopOutcome.Succeeded
        assertEquals("\$render(<vstack/>)", outcome.source)
        assertNull(outcome.manifestJson)
        assertEquals(usagePerCall, outcome.usage)
        assertEquals(listOf("\$render(<vstack/>)" to null), validated)
        assertEquals(listOf("thinking1", "tokens15", "produced1", "running1", "succeeded1"), events)
        val conversation = chat.conversations.single()
        assertEquals(listOf(AiMessage.Role.SYSTEM, AiMessage.Role.USER), conversation.map { it.role })
        assertEquals("SYSTEM", conversation[0].content)
        assertTrue(conversation[1].content.contains("Widget size: medium"))
        assertTrue(conversation[1].content.contains("a clock"))
    }

    @Test
    fun fixesAfterOneErrorByFeedingTheFailureBack() {
        val chat = FakeChat(listOf("\$render(<broken>)", "\$render(<vstack/>)"))
        val events = ArrayList<String>()
        val outcome = AgentLoop(chat).run(request(), { source, _ ->
            if (source.contains("broken")) ValidationResult.failure("scriptError: broken is not defined", listOf("[log] start", "[error] boom")) else ValidationResult.success()
        }, onEvent = { events += describe(it) })
        outcome as AgentLoopOutcome.Succeeded
        assertEquals("\$render(<vstack/>)", outcome.source)
        assertEquals(AiTokenUsage(20, 10, 30), outcome.usage)
        assertEquals(listOf("thinking1", "tokens15", "produced1", "running1", "failed1", "thinking2", "tokens30", "produced2", "running2", "succeeded2"), events)
        val second = chat.conversations[1]
        assertEquals(listOf(AiMessage.Role.SYSTEM, AiMessage.Role.USER, AiMessage.Role.ASSISTANT, AiMessage.Role.USER), second.map { it.role })
        assertEquals(chat.conversations[0][1], second[1])
        assertEquals("\$render(<broken>)", second[2].content)
        assertTrue(second[3].content.contains("scriptError: broken is not defined"))
        assertTrue(second[3].content.contains("[error] boom"))
        assertTrue(second[3].content.contains("\$render(<broken>)"))
    }

    @Test
    fun givesUpAtTheCapAndReturnsTheLastAttempt() {
        val chat = FakeChat(listOf("attempt"))
        var runs = 0
        val outcome = AgentLoop(chat).run(request(maxIterations = 3), { _, _ -> runs += 1; ValidationResult.failure("scriptError: still broken $runs") })
        outcome as AgentLoopOutcome.Exhausted
        assertEquals(3, chat.conversations.size)
        assertEquals(3, runs)
        assertEquals("attempt", outcome.lastSource)
        assertEquals("scriptError: still broken 3", outcome.lastError)
        assertEquals(45, outcome.usage.totalTokens)
    }

    @Test
    fun iterationLimitIsClampedLikeSwift() {
        assertEquals(1, AgentLoop.iterationLimit(0))
        assertEquals(1, AgentLoop.iterationLimit(-5))
        assertEquals(20, AgentLoop.iterationLimit(20))
        assertEquals(100, AgentLoop.iterationLimit(5000))
        val chat = FakeChat(listOf("attempt"))
        AgentLoop(chat).run(request(maxIterations = 0), { _, _ -> ValidationResult.failure("e") })
        assertEquals(1, chat.conversations.size)
    }

    @Test
    fun cancellationBeforeStartMakesNoCall() {
        val chat = FakeChat(listOf("x"))
        val cancellation = AiCancellation().also { it.cancel() }
        val outcome = AgentLoop(chat).run(request(), { _, _ -> ValidationResult.success() }, cancellation)
        assertTrue(outcome is AgentLoopOutcome.Cancelled)
        assertTrue(chat.conversations.isEmpty())
    }

    @Test
    fun cancellationDuringTheModelCallStopsBeforeValidation() {
        val cancellation = AiCancellation()
        val chat = FakeChat(listOf("code")) { cancellation.cancel() }
        var validated = false
        val outcome = AgentLoop(chat).run(request(), { _, _ -> validated = true; ValidationResult.success() }, cancellation)
        outcome as AgentLoopOutcome.Cancelled
        assertFalse(validated)
        assertEquals(15, outcome.usage.totalTokens)
    }

    @Test
    fun cancellationSurfacedAsAClientErrorIsNotAFailure() {
        val cancellation = AiCancellation()
        val chat = FakeChat(listOf(AiClientException(AiErrorKind.CANCELLED, "Cancelled.")))
        assertTrue(AgentLoop(chat).run(request(), { _, _ -> ValidationResult.success() }, cancellation) is AgentLoopOutcome.Cancelled)
    }

    @Test
    fun cancellationDuringValidationWins() {
        val cancellation = AiCancellation()
        val events = ArrayList<String>()
        val outcome = AgentLoop(FakeChat(listOf("code"))).run(request(), { _, _ -> cancellation.cancel(); ValidationResult.success() }, cancellation) { events += describe(it) }
        assertTrue(outcome is AgentLoopOutcome.Cancelled)
        assertFalse(events.contains("succeeded1"))
    }

    @Test
    fun providerFailureEndsTheLoopWithItsSafeMessage() {
        val outcome = AgentLoop(FakeChat(listOf(AiClientException(AiErrorKind.HTTP, "The AI server rejected authentication.", 401)))).run(request(), { _, _ -> ValidationResult.success() })
        outcome as AgentLoopOutcome.Failed
        assertEquals("The AI server rejected authentication.", outcome.message)
        // An unexpected exception's text is never shown.
        val unknown = AgentLoop(FakeChat(listOf(IllegalStateException("header x-api-key: sk-secret")))).run(request(), { _, _ -> ValidationResult.success() })
        unknown as AgentLoopOutcome.Failed
        assertFalse(unknown.message.contains("sk-secret"))
    }

    @Test
    fun networkDeclarationIsCanonicalizedAndPassedToValidation() {
        val reply = "\$render(<vstack/>)\n\n```json\n{\"networkDomains\": [\"API.example.com\"], \"permissions\": [\"network\"]}\n```"
        var seen: String? = null
        val outcome = AgentLoop(FakeChat(listOf(reply))).run(request(), { _, manifest -> seen = manifest; ValidationResult.success() })
        outcome as AgentLoopOutcome.Succeeded
        assertEquals("""{"permissions":["network"],"networkDomains":["api.example.com"]}""", seen)
        assertEquals(seen, outcome.manifestJson)
        assertEquals("\$render(<vstack/>)", outcome.source)
    }

    @Test
    fun invalidDeclarationIsFedBackWithoutRunningTheWidget() {
        val bad = "\$render(<vstack/>)\n```json\n{\"permissions\": [\"location\"]}\n```"
        val chat = FakeChat(listOf(bad, "\$render(<vstack/>)"))
        var runs = 0
        val outcome = AgentLoop(chat).run(request(), { _, _ -> runs += 1; ValidationResult.success() })
        assertTrue(outcome is AgentLoopOutcome.Succeeded)
        assertEquals(1, runs)
        assertTrue(chat.conversations[1][3].content.contains("Invalid package declaration"))
        assertTrue(chat.conversations[1][3].content.contains("location"))
    }

    @Test
    fun emptyAndTruncatedRepliesAreRetried() {
        val chat = FakeChat(listOf("```\n```", AiChatResult("\$render(<vsta", AiTokenUsage.ZERO, truncated = true), "\$render(<vstack/>)"))
        var runs = 0
        val outcome = AgentLoop(chat).run(request(), { _, _ -> runs += 1; ValidationResult.success() })
        assertTrue(outcome is AgentLoopOutcome.Succeeded)
        assertEquals(1, runs)
        assertTrue(chat.conversations[1][3].content.contains("no JSX code"))
        assertTrue(chat.conversations[2][3].content.contains("cut off"))
    }

    @Test
    fun aThrowingValidatorCountsAsAFailedRun() {
        val chat = FakeChat(listOf("code"))
        val outcome = AgentLoop(chat).run(request(maxIterations = 2), { _, _ -> throw IllegalStateException("native crash") })
        outcome as AgentLoopOutcome.Exhausted
        assertTrue(outcome.lastError!!.startsWith("internalError"))
    }

    @Test
    fun refineSendsTheCurrentCodeAndKeepsItWhenTheFirstCallFails() {
        val mode = AgentLoopRequest.Mode.Refine("OLD CODE", "make it blue", """{"permissions":["network"],"networkDomains":["a.example.com"]}""")
        val chat = FakeChat(listOf("NEW CODE"))
        val outcome = AgentLoop(chat).run(request(mode), { _, _ -> ValidationResult.success() })
        outcome as AgentLoopOutcome.Succeeded
        assertEquals("NEW CODE", outcome.source)
        // No declaration in the reply: the caller keeps the package's existing manifest.
        assertNull(outcome.manifestJson)
        val first = chat.conversations[0]
        assertEquals(2, first.size)
        assertTrue(first[1].content.contains("OLD CODE"))
        assertTrue(first[1].content.contains("make it blue"))
        assertTrue(first[1].content.contains("a.example.com"))
    }

    @Test
    fun skillsTextIsAppendedToTheUserRequestOnly() {
        val chat = FakeChat(listOf("code"))
        AgentLoop(chat).run(request(skills = "- Tidy v1:\n  be tidy"), { _, _ -> ValidationResult.success() })
        val conversation = chat.conversations.single()
        assertEquals("SYSTEM", conversation[0].content)
        assertTrue(conversation[1].content.contains("a clock\n\nApply these ScriptWidget skills:\n- Tidy v1:\n  be tidy"))
    }
}
