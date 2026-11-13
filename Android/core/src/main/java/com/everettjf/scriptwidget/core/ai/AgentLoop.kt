package com.everettjf.scriptwidget.core.ai

/** How a run of [AgentLoop] ended. Port of `AgentLoopOutcome`. */
sealed class AgentLoopOutcome {
    abstract val usage: AiTokenUsage

    /** The candidate compiled and rendered. [manifestJson] is its canonical package declaration, if any. */
    class Succeeded(val source: String, val manifestJson: String?, override val usage: AiTokenUsage) : AgentLoopOutcome()

    /** The iteration cap was reached; the last attempt is returned for manual repair. */
    class Exhausted(val lastSource: String?, val lastManifestJson: String?, val lastError: String?, override val usage: AiTokenUsage) : AgentLoopOutcome()

    class Cancelled(override val usage: AiTokenUsage) : AgentLoopOutcome()

    /** The provider call failed; [message] is safe to show (see [AiClientException]). */
    class Failed(val message: String, override val usage: AiTokenUsage) : AgentLoopOutcome()
}

/** Progress of the loop, delivered on the thread that runs it. Port of `AgentLoopEvent`. */
sealed class AgentLoopEvent {
    /** Waiting for the model. */
    class Thinking(val iteration: Int) : AgentLoopEvent()
    /** The model produced a candidate. */
    class Produced(val iteration: Int, val source: String, val manifestJson: String?) : AgentLoopEvent()
    /** The candidate is being compiled and executed. */
    class Running(val iteration: Int) : AgentLoopEvent()
    class RanFailed(val iteration: Int, val errorSummary: String, val logs: List<String>) : AgentLoopEvent()
    class RanSucceeded(val iteration: Int) : AgentLoopEvent()
    /** Cumulative token usage so far. */
    class TokensUsed(val usage: AiTokenUsage) : AgentLoopEvent()
}

/** What to generate. Port of `AgentLoopRequest`. */
class AgentLoopRequest(
    val mode: Mode,
    val size: AiWidgetSize,
    /** Built with [PromptBuilder.systemPrompt]. */
    val systemPrompt: String,
    val maxIterations: Int = AiSettings.DEFAULT_MAX_ITERATIONS,
    /** Formatted text of the enabled Skills, appended to the user's request; null for none. */
    val skillsText: String? = null,
) {
    sealed class Mode {
        /** A new widget from a description. */
        class Fresh(val userDescription: String) : Mode()
        /** Change an existing widget; [currentDeclaration] is its current network declaration JSON, if any. */
        class Refine(val currentCode: String, val instruction: String, val currentDeclaration: String? = null, val runtimeDiagnostic: String? = null) : Mode()
    }
}

/**
 * The generate → run → fix loop. Port of `AgentLoop.run`.
 *
 * It is synchronous and stateless: call [run] from a background thread. The
 * candidate is judged by the `validate` callback so this class has no
 * dependency on the JavaScript runtime and can be tested on the JVM.
 */
class AgentLoop(private val chat: AiChat) {

    /**
     * Runs until a candidate validates, the cap is reached, the provider fails or [cancellation] fires.
     *
     * @param validate compiles and executes `source` with the optional canonical declaration
     *   `manifestJson` and reports whether it rendered. It must not throw.
     * @param onEvent progress callback, invoked on the calling thread.
     */
    fun run(
        request: AgentLoopRequest,
        validate: (source: String, manifestJson: String?) -> ValidationResult,
        cancellation: AiCancellation = AiCancellation(),
        onEvent: (AgentLoopEvent) -> Unit = {},
    ): AgentLoopOutcome {
        var usage = AiTokenUsage.ZERO
        val system = AiMessage(AiMessage.Role.SYSTEM, request.systemPrompt)
        val firstUser: AiMessage
        var latest: AiCandidate?
        when (val mode = request.mode) {
            is AgentLoopRequest.Mode.Fresh -> {
                firstUser = AiMessage(AiMessage.Role.USER, PromptBuilder.userPromptFirst(PromptBuilder.augmentWithSkills(mode.userDescription, request.skillsText), request.size))
                latest = null
            }
            is AgentLoopRequest.Mode.Refine -> {
                firstUser = AiMessage(
                    AiMessage.Role.USER,
                    PromptBuilder.userPromptRefine(mode.currentCode, PromptBuilder.augmentWithSkills(mode.instruction, request.skillsText), mode.currentDeclaration, mode.runtimeDiagnostic),
                )
                latest = AiCandidate(mode.currentCode, mode.currentDeclaration)
            }
        }
        var lastError: String? = null
        var lastLogs: List<String> = emptyList()

        for (iteration in 1..iterationLimit(request.maxIterations)) {
            if (cancellation.isCancelled) return AgentLoopOutcome.Cancelled(usage)
            onEvent(AgentLoopEvent.Thinking(iteration))

            val previous = latest
            val error = lastError
            val messages = if (previous != null && iteration > 1 && error != null) {
                listOf(
                    system, firstUser,
                    AiMessage(AiMessage.Role.ASSISTANT, previous.asAssistantMessage()),
                    AiMessage(AiMessage.Role.USER, PromptBuilder.userPromptFix(previous.source, error, lastLogs)),
                )
            } else {
                listOf(system, firstUser)
            }

            val result = try {
                chat.chat(messages, cancellation)
            } catch (failure: AiClientException) {
                if (cancellation.isCancelled || failure.kind == AiErrorKind.CANCELLED) return AgentLoopOutcome.Cancelled(usage)
                return AgentLoopOutcome.Failed(failure.message ?: "The AI request failed.", usage)
            } catch (_: Exception) {
                // An unknown failure's text is not trusted to be free of request details.
                if (cancellation.isCancelled) return AgentLoopOutcome.Cancelled(usage)
                return AgentLoopOutcome.Failed("The AI request failed.", usage)
            }
            usage += result.usage
            onEvent(AgentLoopEvent.TokensUsed(usage))
            if (cancellation.isCancelled) return AgentLoopOutcome.Cancelled(usage)

            val extracted = AiOutput.extract(result.content)
            // Parse the declaration before anything runs: an invalid one is feedback for the model, never a guess.
            var declarationError: String? = null
            val declaration = extracted.manifestJson?.let { text ->
                try { AiManifestDeclaration.parse(text).toJson() } catch (invalid: IllegalArgumentException) { declarationError = invalid.message; null }
            }
            val candidate = AiCandidate(extracted.source, declaration)
            latest = candidate
            onEvent(AgentLoopEvent.Produced(iteration, candidate.source, candidate.manifestJson))

            onEvent(AgentLoopEvent.Running(iteration))
            val validation = when {
                candidate.source.isEmpty() -> ValidationResult.failure("The reply contained no JSX code.")
                result.truncated -> ValidationResult.failure("The reply was cut off at the output limit. Return a shorter, complete widget.")
                declarationError != null -> ValidationResult.failure("Invalid package declaration: $declarationError")
                else -> try {
                    validate(candidate.source, candidate.manifestJson)
                } catch (_: Exception) {
                    ValidationResult.failure("internalError: the widget could not be run.")
                }
            }
            if (cancellation.isCancelled) return AgentLoopOutcome.Cancelled(usage)

            if (validation.ok) {
                onEvent(AgentLoopEvent.RanSucceeded(iteration))
                return AgentLoopOutcome.Succeeded(candidate.source, candidate.manifestJson, usage)
            }
            val summary = validation.errorSummary ?: "Runtime returned no element."
            lastError = summary
            lastLogs = validation.logs
            onEvent(AgentLoopEvent.RanFailed(iteration, summary, validation.logs))
        }
        return AgentLoopOutcome.Exhausted(latest?.source, latest?.manifestJson, lastError, usage)
    }

    companion object {
        /**
         * Port of `AgentLoop.iterationLimit`: at least one attempt, at most the configured cap.
         * (The Swift per-provider limit only applies to Apple Private Cloud Compute.)
         */
        fun iterationLimit(maxIterations: Int): Int = maxIterations.coerceIn(1, AiSettings.MAXIMUM_MAX_ITERATIONS)
    }
}
