package com.everettjf.scriptwidget.actions

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.surfaces.ActionFailure
import com.everettjf.scriptwidget.core.surfaces.ActionPlanner
import com.everettjf.scriptwidget.core.surfaces.ActionRejected
import com.everettjf.scriptwidget.core.surfaces.DeclaredControl
import com.everettjf.scriptwidget.core.surfaces.PackageSurfaces
import com.everettjf.scriptwidget.core.surfaces.SurfaceManifest
import com.everettjf.scriptwidget.widget.WidgetScheduler
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Outcome of one action run. [message] is user-facing and set only on failure. */
class ActionResult private constructor(val ok: Boolean, val message: String?) {
    companion object {
        val OK = ActionResult(true, null)
        fun error(message: String) = ActionResult(false, message)
    }
}

/**
 * Runs a package's declared action for every system surface: widgets, Quick
 * Settings tiles and launcher shortcuts. A request only selects something the
 * package manifest declares; it can never name a function of its own.
 */
object ActionRunner {
    private const val TAG = "ScriptWidget"
    /** The script limit is five seconds; the wait adds room for compiling and storage. */
    private const val MAXIMUM_WAIT_SECONDS = 8L
    private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "scriptwidget-action") }
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Validates and runs an action, then redraws the package's widgets.
     *
     * The script always runs on a background thread within the runtime's
     * five-second limit. Call this from a background thread; from the main
     * thread it blocks until the action finishes, so prefer [runAsync] there.
     *
     * @param installation stable identity of the installed package.
     * @param actionID a declared `actions[].id`; may be null for [source] `control`, where the control decides.
     * @param source `widget`, `control` or `shortcut`; reported to the script as `action-source`.
     * @param value a toggle's new value, or null for a button.
     * @param controlID a declared `controls[].id`; required for, and only allowed with, `control`.
     * @param stateKey storage key of a widget `<toggle>`; a control always uses its declared `stateKey`.
     */
    fun run(context: Context, installation: String, actionID: String?, source: String, value: Boolean?, controlID: String?, stateKey: String? = null): ActionResult {
        val application = context.applicationContext
        if (Looper.myLooper() != Looper.getMainLooper()) return execute(application, installation, actionID, source, value, controlID, stateKey)
        return try {
            executor.submit<ActionResult> { execute(application, installation, actionID, source, value, controlID, stateKey) }.get(MAXIMUM_WAIT_SECONDS, TimeUnit.SECONDS)
        } catch (error: Exception) {
            ActionResult.error("The ScriptWidget action did not finish in time.")
        }
    }

    /** [run] on the action thread; [completion] is called on the main thread. */
    fun runAsync(
        context: Context, installation: String, actionID: String?, source: String, value: Boolean?, controlID: String?,
        stateKey: String? = null, completion: (ActionResult) -> Unit = {},
    ) {
        val application = context.applicationContext
        executor.execute {
            val result = execute(application, installation, actionID, source, value, controlID, stateKey)
            mainHandler.post { completion(result) }
        }
    }

    /**
     * The actions and controls [installed] declares, or null when its manifest
     * is present but unreadable or breaks the contract. A package without a
     * manifest declares nothing.
     */
    fun declared(installed: InstalledPackage): PackageSurfaces? {
        if (installed.manifest == null) return if (File(installed.directory, "widget.json").exists()) null else PackageSurfaces.EMPTY
        return try { SurfaceManifest.parse(installed.manifest) } catch (_: Exception) { null }
    }

    /** Whether a toggle control is on, read from the package's storage. False when it cannot be read. */
    fun toggleValue(installed: InstalledPackage, control: DeclaredControl): Boolean {
        val key = control.stateKey
        if (!control.isToggle || !SurfaceManifest.isValidStateKey(key) || !installed.permissions.contains("storage")) return false
        return ActionPlanner.isOn(runCatching { AppServices.runtime.storage.getString(installed.installation, key!!) }.getOrNull())
    }

    private fun execute(context: Context, installation: String, actionID: String?, source: String, value: Boolean?, controlID: String?, stateKey: String?): ActionResult {
        return try {
            AppServices.attach(context)
            val installed = AppServices.library.findByInstallation(installation) ?: return ActionResult.error(ActionFailure.ACTION_NOT_FOUND.message)
            // A malformed manifest fails closed: nothing is stored and nothing runs.
            val surfaces = declared(installed) ?: return ActionResult.error(ActionFailure.ACTION_NOT_FOUND.message)
            val plan = try {
                ActionPlanner.plan(surfaces, actionID, source, value, controlID, stateKey)
            } catch (rejected: ActionRejected) {
                return ActionResult.error(rejected.failure.message)
            }
            val runtime = AppServices.runtime
            try {
                // The toggle's new state is saved first, then offered to the action as action-value.
                if (plan.stateKey != null && plan.stateValue != null &&
                    !runtime.storage.setString(installed.installation, plan.stateKey!!, if (plan.stateValue == true) "true" else "false")) {
                    return ActionResult.error(ActionFailure.STORAGE_UNAVAILABLE.message)
                }
                val result = runtime.run(RunRequest(
                    installed.files, installed.installation, darkMode = runtime.isDarkMode(),
                    actionID = plan.actionID, callFunction = plan.callFunction,
                    extraEnvironments = plan.environments, buildDirectory = installed.buildDirectory,
                ))
                result.execution.error?.let { return ActionResult.error("The ScriptWidget action failed: ${it.message.take(300)}") }
                ActionResult.OK
            } finally {
                // Stored state or script side effects may already be visible, even after a failure.
                runCatching { WidgetScheduler.refreshPackage(context, installed.installation) }
            }
        } catch (error: Throwable) {
            Log.w(TAG, "Action failed", error)
            ActionResult.error("The ScriptWidget action failed.")
        }
    }
}
