package com.everettjf.scriptwidget.ai

import android.content.Context
import android.content.res.AssetManager
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiProviderKind
import com.everettjf.scriptwidget.core.ai.AiReference
import com.everettjf.scriptwidget.core.ai.AiSettings

/**
 * Non-secret AI settings, the Android counterpart of `AISettingsStore`.
 *
 * There is one profile per provider kind. Base URL, model and the loop
 * globals live in SharedPreferences; the API key never does: it is kept by
 * [CredentialStore] under the provider's id.
 */
class AiSettingsStore(context: Context, private val credentials: CredentialStore) {
    private val preferences = context.applicationContext.getSharedPreferences("ai", Context.MODE_PRIVATE)

    /** The provider used for generation. An unknown stored value falls back to the default provider. */
    var activeKind: AiProviderKind
        get() = AiProviderKind.fromId(preferences.getString("provider", null)) ?: AiProviderKind.ANTHROPIC
        set(value) { preferences.edit().putString("provider", value.id).apply() }

    /** The saved profile of [kind], or its defaults. */
    fun profile(kind: AiProviderKind): AiProfile = AiProfile(
        kind,
        preferences.getString("baseUrl.${kind.id}", null) ?: kind.defaultBaseUrl,
        preferences.getString("model.${kind.id}", null) ?: kind.defaultModel,
    )

    /**
     * Saves [profile]. A credential belongs to an endpoint, not to a preset (`AIProfile.changingEndpoint`):
     * when the base URL changes, the stored key is removed unless [newKey] replaces it.
     * Blocking: call off the main thread.
     *
     * @return false when [newKey] could not be stored securely.
     */
    fun save(profile: AiProfile, newKey: String?): Boolean {
        val endpointChanged = profile(profile.kind).normalizedBaseUrl != profile.normalizedBaseUrl
        preferences.edit()
            .putString("baseUrl.${profile.kind.id}", profile.baseUrl.trim())
            .putString("model.${profile.kind.id}", profile.model.trim())
            .apply()
        return when {
            !newKey.isNullOrBlank() -> credentials.set(profile.kind.id, newKey)
            endpointChanged -> { credentials.remove(profile.kind.id); true }
            else -> true
        }
    }

    /** `AISettings.maxIterations`, clamped to the documented 5...100 range. */
    var maxIterations: Int
        get() = preferences.getInt("maxIterations", AiSettings.DEFAULT_MAX_ITERATIONS).coerceIn(AiSettings.MINIMUM_MAX_ITERATIONS, AiSettings.MAXIMUM_MAX_ITERATIONS)
        set(value) { preferences.edit().putInt("maxIterations", value.coerceIn(AiSettings.MINIMUM_MAX_ITERATIONS, AiSettings.MAXIMUM_MAX_ITERATIONS)).apply() }

    /** Snapshot for the client and the agent loop. */
    fun load(): AiSettings = AiSettings(profile(activeKind), maxIterations, AiSettings.DEFAULT_TEMPERATURE)
}

/** Process-wide AI services, created on first use. */
object AiServices {
    @Volatile private var instance: Holder? = null
    @Volatile private var cachedReference: AiReference? = null

    private class Holder(val credentials: CredentialStore, val settings: AiSettingsStore)

    private fun holder(context: Context): Holder = instance ?: synchronized(this) {
        instance ?: CredentialStore(context).let { Holder(it, AiSettingsStore(context, it)) }.also { instance = it }
    }

    fun credentials(context: Context): CredentialStore = holder(context).credentials

    fun settings(context: Context): AiSettingsStore = holder(context).settings

    /**
     * The component/API reference for the system prompt, read from the same `Script.bundle`
     * examples the Apple apps sample (`AIReferenceSnapshotLoader`). Blocking on first use.
     */
    fun reference(context: Context): AiReference = cachedReference ?: synchronized(this) {
        cachedReference ?: AiReference.build(readExamples(context.assets, "Script.bundle/component"), readExamples(context.assets, "Script.bundle/api")).also { cachedReference = it }
    }

    private fun readExamples(assets: AssetManager, root: String): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        for (name in assets.list(root)?.sorted() ?: emptyList()) {
            runCatching {
                assets.open("$root/$name/main.jsx").use { stream ->
                    val bytes = stream.readNBytes(MAXIMUM_EXAMPLE_BYTES + 1)
                    if (bytes.size <= MAXIMUM_EXAMPLE_BYTES) result[name] = String(bytes, Charsets.UTF_8)
                }
            }
        }
        return result
    }

    private const val MAXIMUM_EXAMPLE_BYTES = 256 * 1024
}
