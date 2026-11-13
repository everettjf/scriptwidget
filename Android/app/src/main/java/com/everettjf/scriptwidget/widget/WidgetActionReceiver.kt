package com.everettjf.scriptwidget.widget

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import com.everettjf.scriptwidget.MainActivity
import org.json.JSONObject
import kotlin.concurrent.thread

/** Handles taps on widget buttons and toggles without opening the app. */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val appWidgetId = intent.getIntExtra(EXTRA_WIDGET, 0)
        val interaction = runCatching { JSONObject(intent.getStringExtra(EXTRA_INTERACTION).orEmpty()) }.getOrNull() ?: return
        if (appWidgetId == 0) return
        val type = interaction.optString("type")
        val action = when {
            type == "button" && interaction.optString("action").equals("reload", ignoreCase = true) -> null
            type == "button" -> WidgetAction("button", text(interaction, "actionID"), text(interaction, "handler"), null, null)
            type == "toggle" -> WidgetAction("toggle", text(interaction, "actionID"), text(interaction, "handler"), text(interaction, "stateKey"), !interaction.optBoolean("on"))
            else -> return
        }
        // The script has five seconds; a broadcast may run for ten.
        val pending = goAsync()
        thread(name = "scriptwidget-tap") {
            try {
                WidgetUpdater.update(context.applicationContext, appWidgetId, action)
            } catch (error: Throwable) {
                Log.w("ScriptWidget", "Widget action failed", error)
            } finally {
                pending.finish()
            }
        }
    }

    private fun text(json: JSONObject, name: String): String? = if (json.isNull(name)) null else json.optString(name).takeIf { it.isNotEmpty() }

    companion object {
        const val EXTRA_WIDGET = "widget"
        const val EXTRA_INTERACTION = "interaction"
    }
}

/**
 * Opens a link tapped in a widget. Only schemes that hand off to another
 * app or the browser are allowed; file, content and intent URLs from package
 * code are refused.
 */
class LinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        val uri = runCatching { Uri.parse(url) }.getOrNull()
        val scheme = uri?.scheme?.lowercase()
        if (uri != null && scheme != null && scheme !in BLOCKED_SCHEMES) {
            val target = if (scheme == "scriptwidget") Intent(this, MainActivity::class.java).setData(uri) else Intent(Intent.ACTION_VIEW, uri)
            try {
                startActivity(target.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: ActivityNotFoundException) {
                Log.i("ScriptWidget", "No app can open $scheme links")
            } catch (_: SecurityException) {
                Log.i("ScriptWidget", "Link target refused")
            }
        }
        finish()
    }

    companion object {
        const val EXTRA_URL = "url"
        val BLOCKED_SCHEMES = setOf("file", "content", "intent", "javascript", "data", "android-app", "android.resource", "blob", "about")
    }
}
