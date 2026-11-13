package com.everettjf.scriptwidget.core.ai

import java.net.URI

/** Wire protocol and preset of an AI provider. Android 1.0 supports API-key providers only. */
enum class AiProviderKind(val id: String, val displayName: String, val defaultBaseUrl: String, val defaultModel: String, val suggestedModels: List<String>) {
    /** Anthropic Messages API (`/v1/messages`, `x-api-key`). */
    ANTHROPIC(
        "anthropic", "Anthropic", "https://api.anthropic.com", "claude-fable-5-2",
        listOf("claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"),
    ),

    /** OpenAI chat completions; defaults mirror `AIProfile.defaultBaseURL` / `defaultModel` in Swift. */
    OPENAI("openai", "OpenAI", "https://api.openai.com", "gpt-4o-mini", listOf("gpt-4o-mini")),

    /** A user-defined endpoint that speaks OpenAI chat completions. */
    OPENAI_COMPATIBLE("custom", "OpenAI-compatible", "", "", emptyList());

    /** True when requests use the Anthropic Messages API rather than chat completions. */
    val usesAnthropicMessages: Boolean get() = this == ANTHROPIC

    companion object {
        /** The provider with this stored [id], or null: an unknown value is never guessed. */
        fun fromId(id: String?): AiProviderKind? = entries.firstOrNull { it.id == id }
    }
}

/**
 * One provider/model entry. It deliberately has no API key field: the key
 * lives in the platform credential store and is handed to [AiClient] per call,
 * so a profile can be persisted, logged or printed without leaking a secret.
 */
data class AiProfile(val kind: AiProviderKind, val baseUrl: String, val model: String) {
    /**
     * Base URL without trailing slashes or a trailing `/v1` (the client appends
     * the versioned path itself). Blank input falls back to the provider default.
     * Port of `AIProfile.normalizedBaseURL`.
     */
    val normalizedBaseUrl: String
        get() {
            var value = baseUrl.trim()
            if (value.isEmpty()) return kind.defaultBaseUrl
            while (value.endsWith("/")) value = value.dropLast(1)
            if (value.endsWith("/v1")) value = value.dropLast(3)
            while (value.endsWith("/")) value = value.dropLast(1)
            return value
        }

    /** Why this profile cannot be used, or null when it is valid. */
    fun validationError(): String? {
        baseUrlError(normalizedBaseUrl)?.let { return it }
        val name = model.trim()
        if (name.isEmpty()) return "Choose a model before generating a widget."
        if (name.length > MAXIMUM_MODEL_LENGTH || name.any { it.isISOControl() }) return "The model name is invalid."
        return null
    }

    /** True when the endpoint and model are usable; the API key is checked separately. */
    val isConfigured: Boolean get() = validationError() == null

    companion object {
        const val MAXIMUM_MODEL_LENGTH = 200
        const val MAXIMUM_BASE_URL_LENGTH = 2048

        /** The default profile of [kind]. */
        fun defaults(kind: AiProviderKind): AiProfile = AiProfile(kind, kind.defaultBaseUrl, kind.defaultModel)

        /**
         * Validates an already normalized base URL. Port of `AIProfile.endpointURL`, except that
         * Android requires HTTPS: the request carries the API key.
         */
        fun baseUrlError(normalized: String): String? {
            if (normalized.isEmpty()) return "Enter the API base URL."
            if (normalized.length > MAXIMUM_BASE_URL_LENGTH || normalized.any { it.isWhitespace() || it.isISOControl() || it == '\\' }) return "The API base URL is invalid."
            val uri = try { URI(normalized) } catch (_: Exception) { return "The API base URL is invalid." }
            if (!uri.scheme.orEmpty().equals("https", ignoreCase = true)) return "The API base URL must start with https://."
            if (uri.isOpaque || uri.host.isNullOrEmpty()) return "The API base URL needs a host name."
            if (uri.rawUserInfo != null || (uri.rawAuthority ?: "").contains('@')) return "The API base URL must not contain credentials."
            if (uri.rawQuery != null || uri.rawFragment != null) return "The API base URL must not contain a query or fragment."
            if (uri.port != -1 && uri.port !in 1..65535) return "The API base URL is invalid."
            val path = uri.rawPath.orEmpty()
            if (path.endsWith("/chat/completions") || path.endsWith("/messages")) return "Enter the base URL only, without the endpoint path."
            if (path.split('/').any { it == "." || it == ".." }) return "The API base URL is invalid."
            return null
        }
    }
}

/** Snapshot consumed by [AiClient] and [AgentLoop]: the active profile plus the loop globals. */
data class AiSettings(
    val profile: AiProfile,
    val maxIterations: Int = DEFAULT_MAX_ITERATIONS,
    val temperature: Double = DEFAULT_TEMPERATURE,
) {
    companion object {
        /** `AISettings.defaultMaxIterations`. */
        const val DEFAULT_MAX_ITERATIONS = 20
        /** Range of the Max Iterations control in docs/ai-generate.md. */
        const val MINIMUM_MAX_ITERATIONS = 5
        const val MAXIMUM_MAX_ITERATIONS = 100
        /** `AISettings.defaultTemperature`. */
        const val DEFAULT_TEMPERATURE = 0.7
    }
}
