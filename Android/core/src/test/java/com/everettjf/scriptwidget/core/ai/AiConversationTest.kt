package com.everettjf.scriptwidget.core.ai

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** The conversation model, its files and its turns, with a fake model and a fake runtime. */
class AiConversationTest {
    @get:Rule val folder = TemporaryFolder()

    private class FakeChat(private val replies: List<Any>) : AiChat {
        val conversations = ArrayList<List<AiMessage>>()
        override fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult {
            conversations += messages
            return when (val reply = replies[minOf(conversations.size, replies.size) - 1]) {
                is Exception -> throw reply
                else -> AiChatResult(reply as String, AiTokenUsage(10, 5, 15))
            }
        }
    }

    private fun reply(note: String, code: String, declaration: String? = null) =
        "SUMMARY: $note\n```jsx\n$code\n```" + (declaration?.let { "\n```json\n$it\n```" } ?: "")

    /** Runs one whole turn the way the app does, on this thread. */
    private fun turn(conversation: AiConversation, request: String, chat: AiChat, validate: (String, String?) -> ValidationResult = { _, _ -> ValidationResult.success() }): AiConversationTurn {
        val started = AiConversationTurns.begin(conversation, request, "SYSTEM", null)!!
        val outcome = AgentLoop(chat).run(started.loopRequest, validate, onEvent = { AiConversationTurns.applyEvent(conversation, started.turn.id, it) })
        AiConversationTurns.applyOutcome(conversation, started.turn.id, outcome)
        return started.turn
    }

    @Test
    fun aTurnThatRunsBecomesAVersionWithItsNote() {
        val conversation = AiConversation()
        val chat = FakeChat(listOf(reply("Made a clock.", "\$render(<vstack/>)")))
        val turn = turn(conversation, "a clock\nwith seconds", chat)
        assertEquals(AiConversationTurn.Status.SUCCEEDED, turn.status)
        assertEquals("Made a clock.", turn.note)
        assertEquals(0, turn.repairs)
        assertEquals(15, turn.usage.totalTokens)
        assertEquals("a clock", conversation.title)
        val version = conversation.currentVersion!!
        assertEquals(1, version.number)
        assertEquals("\$render(<vstack/>)\n", version.source)
        assertEquals(turn.versionId, version.id)
        assertNull(version.declarationJson)
        val user = chat.conversations.single().last().content
        assertTrue(user.contains("The user asks for a new widget:\na clock\nwith seconds"))
        assertTrue(user.contains("SUMMARY:"))
    }

    @Test
    fun theSecondTurnSendsTheCurrentCodeAndTheHistory() {
        val conversation = AiConversation()
        turn(conversation, "a clock", FakeChat(listOf(reply("Made a clock.", "ONE"))))
        turn(conversation, "bigger", FakeChat(listOf(reply("Bigger.", "TWO"))))
        val chat = FakeChat(listOf(reply("Red.", "THREE")))
        turn(conversation, "make it red", chat)
        val user = chat.conversations.single().last().content
        assertTrue(user.contains("1. User: a clock\n   You: Made a clock."))
        assertTrue(user.contains("2. User: bigger\n   You: Bigger."))
        assertTrue(user.contains("Current working widget code:\n\n```jsx\nTWO\n"))
        assertTrue("the version before is sent for reference", user.contains("```jsx\nONE\n"))
        assertTrue(user.contains("It declares no network use."))
        assertTrue(user.contains("The user now asks:\nmake it red"))
        assertEquals(listOf(1, 2, 3), conversation.versions.map { it.number })
        assertEquals(conversation.versions[1].id, conversation.versions[2].parentId)
    }

    @Test
    fun aRepairedTurnCountsItsRepairsAndKeepsTheFirstNote() {
        val conversation = AiConversation()
        val chat = FakeChat(listOf(reply("Made a list.", "BROKEN"), "```jsx\nFIXED\n```"))
        val turn = turn(conversation, "a list", chat) { source, _ -> if (source.contains("BROKEN")) ValidationResult.failure("scriptError: boom") else ValidationResult.success() }
        assertEquals(AiConversationTurn.Status.SUCCEEDED, turn.status)
        assertEquals(1, turn.repairs)
        assertEquals("Made a list.", turn.note)
        assertNull(turn.errorSummary)
        assertEquals("FIXED\n", conversation.currentVersion!!.source)
        assertEquals(1, conversation.versions.size)
        assertTrue(chat.conversations[1].last().content.contains("Keep the reply form of this conversation"))
    }

    @Test
    fun aTurnThatNeverRunsLeavesTheWidgetAsItWas() {
        val conversation = AiConversation()
        turn(conversation, "a clock", FakeChat(listOf(reply("Made a clock.", "GOOD"))))
        val before = conversation.currentVersionId
        val chat = FakeChat(listOf(reply("Tried.", "BAD")))
        val turn = turn(conversation, "add a chart", chat) { _, _ -> ValidationResult.failure("scriptError: no chart") }
        assertEquals(AiConversationTurn.Status.UNCONVERGED, turn.status)
        assertEquals(AiConversationLimits.MAX_ATTEMPTS_PER_TURN, chat.conversations.size)
        assertEquals(AiConversationLimits.MAX_ATTEMPTS_PER_TURN, turn.repairs)
        assertEquals("scriptError: no chart", turn.errorSummary)
        assertEquals("BAD\n", turn.failedSource)
        assertNull(turn.versionId)
        assertEquals(before, conversation.currentVersionId)
        assertEquals(1, conversation.versions.size)
        assertFalse("a failed turn is not history", conversation.historyForPrompt().any { it.id == turn.id })
    }

    @Test
    fun aProviderFailureIsShownAndCanBeRetried() {
        val conversation = AiConversation()
        val failed = turn(conversation, "a clock", FakeChat(listOf(AiClientException(AiErrorKind.HTTP, "The provider refused the request (401)."))))
        assertEquals(AiConversationTurn.Status.FAILED, failed.status)
        assertEquals("The provider refused the request (401).", failed.errorSummary)
        assertTrue(conversation.versions.isEmpty())

        val started = AiConversationTurns.retry(conversation, failed.id, "SYSTEM", null)!!
        assertEquals("a clock", started.turn.request)
        assertEquals(listOf(started.turn.id), conversation.turns.map { it.id })
        val outcome = AgentLoop(FakeChat(listOf(reply("Made a clock.", "OK")))).run(started.loopRequest, { _, _ -> ValidationResult.success() })
        AiConversationTurns.applyOutcome(conversation, started.turn.id, outcome)
        assertEquals(AiConversationTurn.Status.SUCCEEDED, started.turn.status)
        assertNull("a turn that ran can not be sent again", AiConversationTurns.retry(conversation, started.turn.id, "SYSTEM", null))
    }

    @Test
    fun anUnknownFailureShowsNoExceptionText() {
        val conversation = AiConversation()
        val failed = turn(conversation, "a clock", FakeChat(listOf(IllegalStateException("Authorization: Bearer sk-secret"))))
        assertEquals(AiConversationTurn.Status.FAILED, failed.status)
        assertFalse(conversation.toJson().toString().contains("sk-secret"))
    }

    @Test
    fun aCancelledTurnChangesNothing() {
        val conversation = AiConversation()
        val started = AiConversationTurns.begin(conversation, "a clock", "SYSTEM", null)!!
        assertNull("one turn at a time", AiConversationTurns.begin(conversation, "another", "SYSTEM", null))
        val cancellation = AiCancellation().also { it.cancel() }
        val outcome = AgentLoop(FakeChat(listOf("unused"))).run(started.loopRequest, { _, _ -> ValidationResult.success() }, cancellation)
        AiConversationTurns.applyOutcome(conversation, started.turn.id, outcome)
        assertEquals(AiConversationTurn.Status.CANCELLED, started.turn.status)
        assertTrue(conversation.versions.isEmpty())
        assertFalse(conversation.isRunning)
    }

    @Test
    fun theDeclarationOfATurnIsKeptWithItsVersionAndSentBack() {
        val conversation = AiConversation()
        val validated = ArrayList<String?>()
        turn(conversation, "bitcoin price", FakeChat(listOf(reply("Shows the price.", "FETCH", """{"permissions":["network"],"networkDomains":["API.Example.com"]}""")))) { _, manifest -> validated += manifest; ValidationResult.success() }
        assertEquals(listOf("api.example.com"), conversation.currentVersion!!.networkDomains)
        assertEquals("""{"permissions":["network"],"networkDomains":["api.example.com"]}""", validated.single())
        val chat = FakeChat(listOf(reply("Offline now.", "STATIC")))
        turn(conversation, "use fixed data", chat)
        assertTrue(chat.conversations.single().last().content.contains("""Its network declaration: {"permissions":["network"],"networkDomains":["api.example.com"]}"""))
        assertTrue("a version without a declaration has no network", conversation.currentVersion!!.networkDomains.isEmpty())
    }

    @Test
    fun anInvalidDeclarationIsNotRunAndIsRepaired() {
        val conversation = AiConversation()
        val ran = ArrayList<String>()
        val chat = FakeChat(listOf(
            reply("Reads the calendar.", "CAL", """{"permissions":["calendar"],"networkDomains":[]}"""),
            reply("Plain.", "PLAIN"),
        ))
        val turn = turn(conversation, "my calendar", chat) { source, _ -> ran += source; ValidationResult.success() }
        assertEquals(listOf("PLAIN\n"), ran)
        assertEquals(1, turn.repairs)
        assertTrue(chat.conversations[1].last().content.contains("Invalid package declaration"))
    }

    @Test
    fun goingBackAndAskingAgainLeavesTheLaterTurnsBehind() {
        val conversation = AiConversation()
        val first = turn(conversation, "a clock", FakeChat(listOf(reply("Clock.", "ONE"))))
        val second = turn(conversation, "blue", FakeChat(listOf(reply("Blue.", "TWO"))))
        assertTrue(conversation.selectVersion(first.versionId!!))
        val chat = FakeChat(listOf(reply("Green.", "THREE")))
        val third = turn(conversation, "green", chat)
        assertTrue(second.isAbandoned)
        assertFalse(first.isAbandoned)
        assertFalse(third.isAbandoned)
        val user = chat.conversations.single().last().content
        assertFalse("a turn left behind is not sent", user.contains("blue"))
        assertTrue(user.contains("```jsx\nONE\n"))
        assertEquals(first.versionId, conversation.currentVersion!!.parentId)
        assertEquals(3, conversation.currentVersion!!.number)
        assertFalse(conversation.selectVersion("missing"))
    }

    @Test
    fun codeChangedOutsideTheConversationBecomesAVersionThatIsNotHistory() {
        val conversation = AiConversation()
        turn(conversation, "a clock", FakeChat(listOf(reply("Clock.", "ONE"))))
        assertFalse("the same code adds nothing", conversation.adoptExternalSource("ONE\n"))
        assertTrue(conversation.adoptExternalSource("EDITED", listOf("a.example.com")))
        val manual = conversation.turns.last()
        assertTrue(manual.isManualEdit)
        assertEquals(2, conversation.currentVersion!!.number)
        assertEquals(listOf("a.example.com"), conversation.currentVersion!!.networkDomains)
        val chat = FakeChat(listOf(reply("Red.", "THREE")))
        turn(conversation, "red", chat)
        val user = chat.conversations.single().last().content
        assertTrue(user.contains("```jsx\nEDITED\n"))
        assertTrue(user.contains("1. User: a clock"))
        assertFalse(user.contains("2. User:"))
        assertNull(AiConversationTurns.retry(conversation, manual.id, "SYSTEM", null))
    }

    @Test
    fun onlyTheNewestVersionsAreKeptAndNumbersAreNotReused() {
        val conversation = AiConversation()
        repeat(AiConversationLimits.MAX_VERSIONS + 5) { conversation.addVersion("v$it") }
        assertEquals(AiConversationLimits.MAX_VERSIONS, conversation.versions.size)
        assertEquals(AiConversationLimits.MAX_VERSIONS + 5, conversation.currentVersion!!.number)
        assertEquals(6, conversation.versions.minOf { it.number })
        conversation.selectVersion(conversation.versions.first().id)
        conversation.addVersion("another")
        assertEquals(AiConversationLimits.MAX_VERSIONS + 6, conversation.currentVersion!!.number)
    }

    @Test
    fun aConversationSurvivesItsFile() {
        val conversation = AiConversation(size = AiWidgetSize.LARGE)
        turn(conversation, "bitcoin", FakeChat(listOf(reply("Price.", "FETCH", """{"permissions":["network"],"networkDomains":["api.example.com"]}"""))))
        turn(conversation, "chart", FakeChat(listOf(reply("Tried.", "BAD")))) { _, _ -> ValidationResult.failure("scriptError: x") }
        conversation.packageId = "Bitcoin"
        val read = AiConversation.fromJson(JSONObject(conversation.toJson().toString()))!!
        assertEquals(conversation.toJson().toString(), read.toJson().toString())
        assertEquals(AiWidgetSize.LARGE, read.size)
        assertEquals("Bitcoin", read.packageId)
        assertEquals(listOf("api.example.com"), read.currentVersion!!.networkDomains)
        assertEquals(AiConversationTurn.Status.UNCONVERGED, read.turns[1].status)
        assertEquals("BAD\n", read.turns[1].failedSource)
    }

    @Test
    fun aRunningTurnIsReadBackAsInterrupted() {
        val conversation = AiConversation()
        AiConversationTurns.begin(conversation, "a clock", "SYSTEM", null)!!
        val read = AiConversation.fromJson(JSONObject(conversation.toJson().toString()))!!
        assertEquals(AiConversationTurn.Status.INTERRUPTED, read.turns.single().status)
        assertFalse(read.isRunning)
        assertNotNull(AiConversationTurns.retry(read, read.turns.single().id, "SYSTEM", null))
    }

    @Test
    fun malformedConversationsFailClosed() {
        val good = AiConversation().also { it.addVersion("x") }.toJson()
        assertNull(AiConversation.fromJson(JSONObject(good.toString()).put("formatVersion", 2)))
        assertNull(AiConversation.fromJson(JSONObject(good.toString()).put("id", "../../escape")))
        assertNull(AiConversation.fromJson(JSONObject(good.toString()).put("versions", "none")))
        assertNull(AiConversation.fromJson(JSONObject("{}")))
        assertNotNull(AiConversation.fromJson(good))
    }

    @Test
    fun theStoreKeepsConversationsAndIgnoresWhatIsNotOne() {
        val directory = File(folder.root, "ai-conversations")
        val store = AiConversationStore(directory)
        assertTrue(store.summaries().isEmpty())
        val draft = AiConversation(updatedAt = 10).also { turn(it, "a clock", FakeChat(listOf(reply("Clock.", "ONE")))); it.updatedAt = 10 }
        val bound = AiConversation().also { turn(it, "weather", FakeChat(listOf(reply("Weather.", "W")))); it.packageId = "Weather"; it.updatedAt = 20 }
        assertTrue(store.save(draft))
        assertTrue(store.save(bound))
        File(directory, "notes.json").writeText("{\"hello\": 1}")
        File(directory, "broken.json").writeText("{")
        File(directory, "copied-under-another-name.json").writeText(draft.toJson().toString())

        assertEquals(listOf(bound.id, draft.id), store.summaries().map { it.id })
        assertEquals(listOf(draft.id), store.summaries(draftsOnly = true).map { it.id })
        assertEquals("a clock", store.load(draft.id)!!.title)
        assertEquals(bound.id, store.latest("Weather")!!.id)
        assertNull(store.latest("Missing"))
        assertNull(store.load("../notes"))
        assertTrue("foreign files are left alone", File(directory, "notes.json").isFile && File(directory, "broken.json").isFile)

        store.delete(draft.id)
        assertNull(store.load(draft.id))
        store.deleteForPackage("Weather")
        assertNull(store.latest("Weather"))
        assertFalse(directory.list()!!.any { it.endsWith(".tmp") })
    }

    @Test
    fun theStoreKeepsOnlyTheNewestConversations() {
        val store = AiConversationStore(File(folder.root, "many"))
        val ids = (1..AiConversationLimits.MAX_CONVERSATIONS + 3).map { index ->
            AiConversation().also { it.beginTurn("request $index"); it.markRunningTurnsInterrupted(); it.updatedAt = index.toLong(); store.save(it) }.id
        }
        val kept = store.summaries().map { it.id }
        assertEquals(AiConversationLimits.MAX_CONVERSATIONS, kept.size)
        assertFalse(ids.take(3).any { it in kept })
        assertEquals(ids.last(), kept.first())
    }

    @Test
    fun aConversationFileHoldsNoCredentialOrProvider() {
        val conversation = AiConversation()
        turn(conversation, "a clock", FakeChat(listOf(reply("Clock.", "ONE"))))
        val keys = HashSet<String>()
        fun collect(value: Any?) {
            when (value) {
                is JSONObject -> for (key in value.keys()) { keys += key; collect(value.opt(key)) }
                is org.json.JSONArray -> for (index in 0 until value.length()) collect(value.opt(index))
            }
        }
        collect(conversation.toJson())
        assertTrue(keys.none { key -> listOf("key", "token", "secret", "authorization", "baseurl", "model", "provider").any { key.lowercase().contains(it) && key !in setOf("promptTokens", "completionTokens", "totalTokens") } })
    }

    @Test
    fun turnRepliesAreReadLeniently() {
        val full = PromptBuilder.parseTurnReply("SUMMARY: Made it blue.\n```jsx\n\$render(<vstack/>) // end\n```\n```json\n{\"permissions\":[\"network\"],\"networkDomains\":[\"a.example.com\"]}\n```")
        assertEquals("Made it blue.", full.note)
        assertEquals("\$render(<vstack/>) // end\n", full.candidate.source)
        assertTrue(full.candidate.manifestJson!!.contains("a.example.com"))

        val bare = PromptBuilder.parseTurnReply("\$render(<vstack/>)")
        assertNull(bare.note)
        assertEquals("\$render(<vstack/>)\n", bare.candidate.source)

        val unfenced = PromptBuilder.parseTurnReply("Summary: plain\n\$render(<vstack/>)")
        assertEquals("plain", unfenced.note)
        assertEquals("\$render(<vstack/>)\n", unfenced.candidate.source)

        assertEquals("", PromptBuilder.parseTurnReply("SUMMARY: nothing").candidate.source)
        assertEquals(AiConversationLimits.NOTE_CHARACTERS + 1, PromptBuilder.parseTurnReply("SUMMARY: " + "x".repeat(900) + "\n```jsx\nA\n```").note!!.length)
    }

    @Test
    fun skillsAndDiagnosticsArePartOfATurn() {
        val conversation = AiConversation()
        conversation.addVersion("ONE")
        val started = AiConversationTurns.begin(conversation, "fix it", "SYSTEM", "Skill: use rounded corners", "scriptError: line 3")!!
        val mode = started.loopRequest.mode as AgentLoopRequest.Mode.Turn
        val text = PromptBuilder.userPromptTurn(mode.context)
        assertTrue(text.contains("Apply these ScriptWidget skills in every turn:\nSkill: use rounded corners"))
        assertTrue(text.contains("The latest local ScriptWidget runtime diagnostic is:\nscriptError: line 3"))
        assertEquals(AiConversationLimits.MAX_ATTEMPTS_PER_TURN, started.loopRequest.maxIterations)
        assertNull(AiConversationTurns.begin(AiConversation(), "   ", "SYSTEM", null))
    }
}
