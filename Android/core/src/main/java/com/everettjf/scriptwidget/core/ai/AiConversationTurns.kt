package com.everettjf.scriptwidget.core.ai

/**
 * How a conversation changes over one turn. Port of the turn handling of
 * `AIConversationSession`, without the threads: the caller starts a turn,
 * runs [AgentLoop] with the request from [loopRequest], feeds its events to
 * [applyEvent] and its outcome to [applyOutcome], all on the thread that owns
 * the conversation.
 *
 * A turn that does not succeed leaves the versions and the current version
 * exactly as they were.
 */
object AiConversationTurns {

    /**
     * Starts a turn for [request] and returns it with what to send. The request is blank-checked
     * by the caller. A conversation that is already running a turn is not started again.
     */
    fun begin(conversation: AiConversation, request: String, systemPrompt: String, skillsText: String?, runtimeDiagnostic: String? = null, now: Long = System.currentTimeMillis()): Started? {
        if (conversation.isRunning || request.isBlank()) return null
        // The history is read before the new turn is added, and after turns off the current path are marked.
        val turn = conversation.beginTurn(request.trim(), now)
        val current = conversation.currentVersion
        val context = AiTurnContext(
            history = conversation.historyForPrompt().map { AiTurnContext.Exchange(it.request, it.note) },
            currentCode = current?.source,
            previousCode = conversation.version(current?.parentId)?.source,
            request = turn.request,
            skillsText = skillsText,
            size = conversation.size,
            currentDeclaration = current?.declarationJson,
            runtimeDiagnostic = runtimeDiagnostic,
        )
        return Started(turn, AgentLoopRequest(AgentLoopRequest.Mode.Turn(context), conversation.size, systemPrompt, AiConversationLimits.MAX_ATTEMPTS_PER_TURN))
    }

    class Started(val turn: AiConversationTurn, val loopRequest: AgentLoopRequest)

    /** Sends a turn that did not succeed again: it is taken out and its request starts a new turn. */
    fun retry(conversation: AiConversation, turnId: String, systemPrompt: String, skillsText: String?, now: Long = System.currentTimeMillis()): Started? {
        val turn = conversation.turn(turnId) ?: return null
        if (conversation.isRunning || turn.isManualEdit || turn.status == AiConversationTurn.Status.SUCCEEDED || turn.status == AiConversationTurn.Status.RUNNING) return null
        conversation.turns.remove(turn)
        return begin(conversation, turn.request, systemPrompt, skillsText, now = now)
    }

    /** Records progress of the running turn [turnId]. */
    fun applyEvent(conversation: AiConversation, turnId: String, event: AgentLoopEvent) {
        val turn = conversation.turn(turnId)?.takeIf { it.status == AiConversationTurn.Status.RUNNING } ?: return
        when (event) {
            is AgentLoopEvent.RanFailed -> { turn.repairs += 1; turn.errorSummary = clipError(event.errorSummary) }
            is AgentLoopEvent.TokensUsed -> turn.usage = event.usage
            is AgentLoopEvent.Note -> turn.note = event.text
            else -> Unit
        }
    }

    /**
     * Ends the running turn [turnId]. A null [outcome] is a failure with no text to show.
     * Only a success adds a version and moves the current version.
     */
    fun applyOutcome(conversation: AiConversation, turnId: String, outcome: AgentLoopOutcome?, now: Long = System.currentTimeMillis()) {
        val turn = conversation.turn(turnId)?.takeIf { it.status == AiConversationTurn.Status.RUNNING } ?: return
        if (outcome != null) turn.usage = outcome.usage
        when (outcome) {
            is AgentLoopOutcome.Succeeded -> {
                val domains = outcome.manifestJson?.let { runCatching { AiManifestDeclaration.parse(it).networkDomains }.getOrNull() }.orEmpty()
                val version = conversation.addVersion(outcome.source, domains, now)
                turn.status = AiConversationTurn.Status.SUCCEEDED
                turn.versionId = version.id
                turn.note = outcome.note ?: turn.note ?: "Done."
                turn.errorSummary = null
            }
            is AgentLoopOutcome.Exhausted -> {
                turn.status = AiConversationTurn.Status.UNCONVERGED
                turn.errorSummary = clipError(outcome.lastError ?: "The widget did not run.")
                turn.failedSource = outcome.lastSource
            }
            is AgentLoopOutcome.Cancelled -> { turn.status = AiConversationTurn.Status.CANCELLED; turn.errorSummary = null }
            is AgentLoopOutcome.Failed -> { turn.status = AiConversationTurn.Status.FAILED; turn.errorSummary = clipError(outcome.message) }
            null -> { turn.status = AiConversationTurn.Status.FAILED; turn.errorSummary = "The request could not be completed." }
        }
        conversation.updatedAt = now
    }

    private fun clipError(text: String): String = PromptBuilder.clip(text, AiConversationLimits.ERROR_CHARACTERS)
}
