package com.everettjf.scriptwidget.widget

import android.content.Context
import org.json.JSONObject

/** Which package and parameter a placed widget shows. */
class WidgetBinding(val installation: String, val parameter: String)

class WidgetStore(context: Context) {
    private val preferences = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    fun get(appWidgetId: Int): WidgetBinding? = preferences.getString("w$appWidgetId", null)?.let { text ->
        runCatching { JSONObject(text) }.getOrNull()?.let { WidgetBinding(it.optString("installation"), it.optString("parameter")) }
    }

    fun set(appWidgetId: Int, binding: WidgetBinding) {
        preferences.edit().putString("w$appWidgetId", JSONObject().put("installation", binding.installation).put("parameter", binding.parameter).toString()).apply()
    }

    fun remove(appWidgetId: Int) { preferences.edit().remove("w$appWidgetId").remove("t$appWidgetId").apply() }

    /** Time of the last successful render, shown in diagnostics. */
    fun markUpdated(appWidgetId: Int, milliseconds: Long) { preferences.edit().putLong("t$appWidgetId", milliseconds).apply() }

    fun lastUpdated(appWidgetId: Int): Long = preferences.getLong("t$appWidgetId", 0)

    /** Remembers the package chosen in "Add to home screen" until the launcher reports the new widget. */
    fun rememberPendingPin(installation: String, parameter: String) {
        preferences.edit().putString("pendingPin", JSONObject().put("installation", installation).put("parameter", parameter).put("time", System.currentTimeMillis()).toString()).apply()
    }

    /** The package of a pin request made in the last two minutes, consumed once. */
    fun takePendingPin(): WidgetBinding? {
        val text = preferences.getString("pendingPin", null) ?: return null
        preferences.edit().remove("pendingPin").apply()
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (System.currentTimeMillis() - json.optLong("time") > 120_000) return null
        return WidgetBinding(json.optString("installation"), json.optString("parameter"))
    }

    fun boundIds(): List<Int> = preferences.all.keys.filter { it.startsWith("w") }.mapNotNull { it.substring(1).toIntOrNull() }
}
