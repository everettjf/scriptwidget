package com.everettjf.scriptwidget.automation

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.actions.ActionRunner
import com.everettjf.scriptwidget.core.surfaces.ActionPlanner
import com.everettjf.scriptwidget.core.surfaces.Automation
import com.everettjf.scriptwidget.core.surfaces.AutomationFailure
import com.everettjf.scriptwidget.core.surfaces.AutomationLimiter
import com.everettjf.scriptwidget.core.surfaces.AutomationRejected
import com.everettjf.scriptwidget.core.surfaces.AutomationRequest
import com.everettjf.scriptwidget.widget.WidgetScheduler
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * What the user allowed other apps to do. Kept outside backups: the token is
 * a secret of this installation, and a restored phone starts with automation
 * off.
 */
class AutomationStore(context: Context) {
    private val file = File(context.noBackupFilesDir, "automation.json")

    private fun read(): JSONObject = file.takeIf { it.isFile && it.length() < 256 * 1024 }?.let { runCatching { JSONObject(it.readText()) }.getOrNull() } ?: JSONObject()

    private fun write(state: JSONObject) {
        val temporary = File(file.parentFile, file.name + ".tmp")
        temporary.writeText(state.toString())
        temporary.renameTo(file)
    }

    @get:Synchronized @set:Synchronized
    var enabled: Boolean
        get() = read().optBoolean("enabled", false)
        set(value) {
            val state = read().put("enabled", value)
            // The token is created when automation is first turned on.
            if (value && !Automation.isValidToken(state.optString("token"))) state.put("token", Automation.newToken())
            write(state)
        }

    /** The secret a sender must include; null until automation was turned on once. */
    @get:Synchronized
    val token: String? get() = read().optString("token").takeIf { Automation.isValidToken(it) }

    /** Replaces the token; every task that used the old one stops working. */
    @Synchronized
    fun renewToken(): String = Automation.newToken().also { write(read().put("token", it)) }

    /** Installations (stable package identities) other apps may run. */
    @Synchronized
    fun allowedPackages(): Set<String> = read().optJSONArray("packages")?.let { array -> (0 until array.length()).map { array.optString(it) }.toSet() } ?: emptySet()

    @Synchronized
    fun setAllowed(installation: String, allowed: Boolean) {
        val packages = allowedPackages().toMutableSet()
        if (allowed) packages += installation else packages -= installation
        write(read().put("packages", JSONArray(packages.sorted())))
    }
}

/**
 * The automation entry point: a broadcast from another app that runs a
 * declared action of a package, or redraws widgets.
 *
 * It is exported, so any app on the phone can send to it. It does nothing
 * unless the user turned automation on, the sender knows the token shown in
 * the app, and the package was allowed there. A request selects an action
 * the package manifest declares; it cannot carry code. The token is never
 * written to the log.
 */
class AutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val command = when (intent.action) {
            context.packageName + Automation.ACTION_RUN -> AutomationRequest.COMMAND_RUN
            context.packageName + Automation.ACTION_REFRESH -> AutomationRequest.COMMAND_REFRESH
            else -> return
        }
        val fields = HashMap<String, String?>()
        for (name in listOf(Automation.FIELD_PACKAGE, Automation.FIELD_ACTION, Automation.FIELD_VALUE, Automation.FIELD_TOKEN)) {
            // Automation apps send every extra as text; a real boolean is accepted for the value.
            val extra = runCatching { intent.extras?.get(name) }.getOrNull()
            fields[name] = when (extra) { is String -> extra; is Boolean -> extra.toString(); else -> null }
        }
        val application = context.applicationContext
        // The script has five seconds; a broadcast may run for ten.
        val ordered = isOrderedBroadcast
        val pending = goAsync()
        thread(name = "scriptwidget-automation") {
            val failure = try {
                handle(application, command, fields)
            } catch (rejected: AutomationRejected) {
                rejected.failure.message
            } catch (error: Throwable) {
                Log.w(TAG, "Automation request failed", error)
                "The request failed."
            }
            Log.i(TAG, "automation $command ${if (failure == null) "done" else "refused: $failure"}")
            if (ordered) {
                pending.resultCode = if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED
                pending.resultData = failure ?: "OK"
            }
            pending.finish()
        }
    }

    /** Returns null when the request was carried out, otherwise why not. */
    private fun handle(context: Context, command: String, fields: Map<String, String?>): String? {
        AppServices.attach(context)
        val store = AutomationStore(context)
        if (!store.enabled) throw AutomationRejected(AutomationFailure.DISABLED)
        if (!limiter.allow(System.currentTimeMillis())) throw AutomationRejected(AutomationFailure.TOO_MANY_REQUESTS)
        val request = Automation.parse(command, fields)
        if (!Automation.tokensMatch(store.token, request.token)) throw AutomationRejected(AutomationFailure.WRONG_TOKEN)
        val allowed = store.allowedPackages()
        if (request.command == AutomationRequest.COMMAND_REFRESH && request.packageName == null) {
            // Without a package: every widget of the packages the user allowed.
            AppServices.library.list().filter { it.installation in allowed }.forEach { WidgetScheduler.refreshPackage(context, it.installation) }
            return null
        }
        val installed = AppServices.library.find(request.packageName!!) ?: throw AutomationRejected(AutomationFailure.PACKAGE_NOT_FOUND)
        if (installed.installation !in allowed) throw AutomationRejected(AutomationFailure.PACKAGE_NOT_ALLOWED)
        if (request.command == AutomationRequest.COMMAND_REFRESH) {
            WidgetScheduler.refreshPackage(context, installed.installation)
            return null
        }
        val result = ActionRunner.run(context, installed.installation, request.action, ActionPlanner.SOURCE_AUTOMATION, request.value, null)
        return if (result.ok) null else result.message
    }

    private companion object {
        const val TAG = "ScriptWidget"
        val limiter = AutomationLimiter()
    }
}
