package com.everettjf.scriptwidget.core.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Edit replies: read, applied, refused, and what the loop does with them. Mirrors the Swift tests. */
class AiSourceEditsTest {
    private val good = "\$render(<vstack><text>Hello</text></vstack>)\n"
    private val better = "\$render(<vstack><text>Hello</text><text>World</text></vstack>)\n"

    private class FakeChat(private val replies: List<String>) : AiChat {
        val conversations = ArrayList<List<AiMessage>>()
        override fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult {
            conversations += messages
            return AiChatResult(replies[minOf(conversations.size, replies.size) - 1], AiTokenUsage(10, 5, 15))
        }
    }

    private fun edit(summary: String, vararg pairs: Pair<String, String>): String =
        "SUMMARY: $summary\n```edit\n" + pairs.joinToString("\n") { "<<<<<<< SEARCH\n${it.first}\n=======\n${it.second}\n>>>>>>> REPLACE" } + "\n```"

    private fun turn(current: String?) = AgentLoopRequest(
        AgentLoopRequest.Mode.Turn(AiTurnContext(emptyList(), current, null, "Say Hi instead", null, AiWidgetSize.MEDIUM)),
        AiWidgetSize.MEDIUM, "SYSTEM", AiConversationLimits.MAX_ATTEMPTS_PER_TURN,
    )

    private fun reason(body: () -> Unit): String = try { body(); "none" } catch (failure: AiSourceEdits.Failure) { failure.reason }

    @Test
    fun editBlocksAreReadAndAppliedInOrder() {
        val reply = "SUMMARY: Two changes.\n```edit\n<<<<<<< SEARCH\n  <text>Hello</text>\n=======\n  <text>Hi</text>\n  <text>there</text>\n>>>>>>> REPLACE\n" +
            "<<<<<<< SEARCH\nconst a = 1;\n=======\n>>>>>>> REPLACE\n```"
        val edits = AiSourceEdits.parse(reply)!!
        assertEquals(listOf(AiSourceEdit("  <text>Hello</text>", "  <text>Hi</text>\n  <text>there</text>"), AiSourceEdit("const a = 1;", "")), edits)
        val source = "const a = 1;\r\n\$render(\n  <text>Hello</text>\n)"
        assertEquals("\n\$render(\n  <text>Hi</text>\n  <text>there</text>\n)\n", AiSourceEdits.apply(edits, source))
        assertNull("a full reply has no edits", AiSourceEdits.parse("SUMMARY: x\n```jsx\n\$render(<text>a</text>)\n```"))
    }

    @Test
    fun anEditThatIsMissingAmbiguousOrMalformedIsRefused() {
        val source = "<text>a</text>\n<text>a</text>\n<text>b</text>\n"
        assertTrue(reason { AiSourceEdits.apply(listOf(AiSourceEdit("<text>c</text>", "x")), source) }.contains("is not in the current code"))
        assertTrue(reason { AiSourceEdits.apply(listOf(AiSourceEdit("<text>a</text>", "x")), source) }.contains("2 times"))
        assertTrue(reason { AiSourceEdits.apply(listOf(AiSourceEdit("<text>b</text>", "x"), AiSourceEdit("nowhere", "y")), source) }.contains("edit 2"))
        assertTrue(reason { AiSourceEdits.parse("<<<<<<< SEARCH\na\n=======\nb") }.contains("no >>>>>>> REPLACE"))
        assertTrue(reason { AiSourceEdits.parse("<<<<<<< SEARCH\n\n=======\nb\n>>>>>>> REPLACE") }.contains("nothing in its SEARCH"))
        assertTrue(reason { AiSourceEdits.parse("<<<<<<< SEARCH\na\n>>>>>>> REPLACE") }.contains("ends without"))
        val many = List(AiSourceEdits.MAX_EDITS + 1) { "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE" }.joinToString("\n")
        assertTrue(reason { AiSourceEdits.parse(many) }.contains("more than"))
    }

    @Test
    fun theTurnPromptOffersEditBlocksOnlyWhenThereIsCodeToChange() {
        fun prompt(current: String?) = PromptBuilder.userPromptTurn(AiTurnContext(emptyList(), current, null, "x", null, AiWidgetSize.MEDIUM))
        assertTrue(prompt("CODE").contains(AiSourceEdits.SEARCH_MARKER))
        assertFalse(prompt(null).contains(AiSourceEdits.SEARCH_MARKER))
    }

    @Test
    fun aTurnAnsweredWithEditBlocksChangesOnlyThatPlace() {
        val chat = FakeChat(listOf(edit("Says Hi now.", "<text>Hello</text>" to "<text>Hi</text>")))
        val validated = ArrayList<String>()
        val outcome = AgentLoop(chat).run(turn(good), { source, _ -> validated += source; ValidationResult.success() })
        outcome as AgentLoopOutcome.Succeeded
        assertEquals("\$render(<vstack><text>Hi</text></vstack>)\n", outcome.source)
        assertEquals("Says Hi now.", outcome.note)
        assertEquals(listOf(outcome.source), validated)
        assertEquals(1, chat.conversations.size)
    }

    @Test
    fun anEditThatDoesNotApplyIsSentBackAndTheFullCodeIsAccepted() {
        val chat = FakeChat(listOf(edit("Says Hi now.", "<text>Goodbye</text>" to "<text>Hi</text>"), "SUMMARY: Says Hi now.\n```jsx\n$better```"))
        val validated = ArrayList<String>()
        val outcome = AgentLoop(chat).run(turn(good), { source, _ -> validated += source; ValidationResult.success() })
        outcome as AgentLoopOutcome.Succeeded
        assertEquals(better, outcome.source)
        assertEquals("nothing runs from a refused edit", listOf(better), validated)
        val repair = chat.conversations[1].last().content
        assertTrue(repair.contains("could not be applied"))
        assertTrue(repair.contains("is not in the current code"))
        assertTrue("the code it was shown is sent again", repair.contains("<text>Hello</text>"))
    }

    @Test
    fun editsThatNeverApplyEndTheTurnWithoutACandidate() {
        val chat = FakeChat(listOf(edit("Tried.", "nowhere" to "x")))
        var runs = 0
        val outcome = AgentLoop(chat).run(turn(good), { _, _ -> runs += 1; ValidationResult.success() })
        assertTrue(outcome is AgentLoopOutcome.Exhausted)
        assertEquals(0, runs)
        assertEquals(AiConversationLimits.MAX_ATTEMPTS_PER_TURN, chat.conversations.size)
    }

    @Test
    fun editBlocksForANewWidgetAreRefused() {
        val chat = FakeChat(listOf(edit("Tried.", "a" to "b"), "SUMMARY: Made it.\n```jsx\n$good```"))
        val outcome = AgentLoop(chat).run(turn(null), { _, _ -> ValidationResult.success() })
        assertEquals(good, (outcome as AgentLoopOutcome.Succeeded).source)
    }

    @Test
    fun aRepairWrittenAsEditsChangesTheFailedAttempt() {
        val broken = "\$render(<vstack><text>Hi</text></vstac>)\n"
        val chat = FakeChat(listOf("SUMMARY: Says Hi now.\n```jsx\n$broken```", edit("Fixed the tag.", "</vstac>" to "</vstack>")))
        val outcome = AgentLoop(chat).run(turn(good), { source, _ -> if (source.contains("</vstac>")) ValidationResult.failure("transformError") else ValidationResult.success() })
        assertEquals("\$render(<vstack><text>Hi</text></vstack>)\n", (outcome as AgentLoopOutcome.Succeeded).source)
    }
}

/** What changed between versions, and the notice for a conversation that has grown. Mirrors the Swift tests. */
class AiSourceDiffTest {
    @Test
    fun theDiffShowsChangedLinesWithContextAndLeavesTheRestOut() {
        val old = (1..20).joinToString("\n") { "line $it" } + "\n"
        val new = old.replace("line 10\n", "line ten\nline ten and a half\n")
        assertEquals(AiSourceDiff.Summary(2, 1), AiSourceDiff.summary(old, new))
        val lines = AiSourceDiff.lines(old, new)!!
        val k = AiSourceDiff.Kind.entries
        assertEquals(
            listOf(k[3], k[0], k[0], k[0], k[2], k[1], k[1], k[0], k[0], k[0], k[3]),
            lines.map { it.kind },
        )
        assertEquals(listOf(6, 7), lines.filter { it.kind == AiSourceDiff.Kind.SKIPPED }.map { it.skipped })
        assertEquals(listOf("line ten", "line ten and a half"), lines.filter { it.kind == AiSourceDiff.Kind.ADDED }.map { it.text })
        assertEquals("line 10", lines.first { it.kind == AiSourceDiff.Kind.REMOVED }.text)
        assertEquals(emptyList<AiSourceDiff.Line>(), AiSourceDiff.lines(old, old))
        assertEquals("line endings are not a change", AiSourceDiff.Summary(0, 0), AiSourceDiff.summary("a\r\nb\n", "a\nb"))
        assertNull(AiSourceDiff.summary("x\n".repeat(AiSourceDiff.MAX_LINES + 1), "x"))
    }

    @Test
    fun usageAdviceAppearsOnlyWhenAConversationHasGrown() {
        val conversation = AiConversation(size = AiWidgetSize.LARGE, packageId = "installation-1")
        assertNull(conversation.usageAdvice)
        assertNull("nothing to continue from", conversation.continuedFromCurrentVersion())
        fun turn(prompt: Int, repairs: Int = 0) {
            val turn = conversation.beginTurn("Change it")
            val version = conversation.addVersion("\$render(<text>${conversation.versionCounter}</text>)\n", listOf("example.com"))
            turn.status = AiConversationTurn.Status.SUCCEEDED
            turn.versionId = version.id
            turn.repairs = repairs
            turn.usage = AiTokenUsage(prompt, 100, prompt + 100)
        }
        turn(5_000)
        assertNull(conversation.usageAdvice)
        turn(70_000, repairs = 1)
        assertEquals(35_000, conversation.lastRequestTokens)
        assertEquals(AiConversationUsageAdvice(AiConversationUsageAdvice.Reason.HEAVY_REQUESTS, 35_000), conversation.usageAdvice)
        turn(5_000)
        assertNull("it follows the newest turn", conversation.usageAdvice)
        repeat(AiConversationLimits.HISTORY_TURNS) { turn(5_000) }
        assertEquals(AiConversationUsageAdvice.Reason.HISTORY_FULL, conversation.usageAdvice?.reason)
        repeat(20) { turn(5_000) }
        assertEquals(AiConversationUsageAdvice.Reason.VERSIONS_FULL, conversation.usageAdvice?.reason)
        turn(200_000)
        assertEquals(AiConversationUsageAdvice.Reason.HEAVY_REQUESTS, conversation.usageAdvice?.reason)
        assertTrue(conversation.usageAdvice!!.message.contains("200,000"))

        val next = conversation.continuedFromCurrentVersion()!!
        assertFalse(next.id == conversation.id)
        assertEquals(listOf(conversation.currentVersion!!.source), next.versions.map { it.source })
        assertEquals(listOf("example.com"), next.currentVersion!!.networkDomains)
        assertEquals(AiWidgetSize.LARGE, next.size)
        assertEquals("installation-1", next.packageId)
        assertTrue(next.turns.isEmpty())
        assertNull(next.usageAdvice)
        assertTrue("no earlier turn is sent", next.historyForPrompt().isEmpty())
    }
}
