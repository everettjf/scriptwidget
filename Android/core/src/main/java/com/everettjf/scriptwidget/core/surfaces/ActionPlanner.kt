package com.everettjf.scriptwidget.core.surfaces

/** Why an action request was refused. The messages match the iOS action errors. */
enum class ActionFailure(val message: String) {
    INVALID_REQUEST("This widget action is invalid or exceeds its limits. Reload the widget and try again."),
    ACTION_NOT_FOUND("The ScriptWidget action is no longer available."),
    STORAGE_DENIED("This action did not declare the storage permission."),
    INVALID_STATE_KEY("The action uses an invalid storage key."),
    STORAGE_UNAVAILABLE("Widget storage is busy or unavailable. Please try again."),
}

/** Thrown by [ActionPlanner.plan]; nothing has run or been stored when it is thrown. */
class ActionRejected(val failure: ActionFailure) : Exception(failure.message)

/**
 * What to run for one accepted request. Exactly one of [actionID] (a declared
 * action) and [callFunction] (a control's legacy function) is set.
 */
class ActionPlan(
    val actionID: String?,
    val callFunction: String?,
    /** Values the script reads with `$getenv`. */
    val environments: Map<String, String>,
    /** Package storage key to write [stateValue] to before the action runs, or null. */
    val stateKey: String?,
    val stateValue: Boolean?,
)

/**
 * Decides what a system surface may run. Only actions and controls the
 * manifest declares are accepted; a serialized request can select one of them
 * but can never name an arbitrary function.
 */
object ActionPlanner {
    const val SOURCE_WIDGET = "widget"
    const val SOURCE_CONTROL = "control"
    const val SOURCE_SHORTCUT = "shortcut"
    private val sources = setOf(SOURCE_WIDGET, SOURCE_CONTROL, SOURCE_SHORTCUT)

    /**
     * @param actionID the declared action; for [SOURCE_CONTROL] it may be null and is then taken from the control.
     * @param value a toggle's new value, or null for a button.
     * @param controlID the declared control; required for, and only allowed with, [SOURCE_CONTROL].
     * @param stateKey storage key of a widget `<toggle>`; a control's own `stateKey` always wins.
     * @throws ActionRejected when the request does not match the manifest.
     */
    fun plan(surfaces: PackageSurfaces, actionID: String?, source: String, value: Boolean?, controlID: String?, stateKey: String? = null): ActionPlan {
        if (source !in sources) throw ActionRejected(ActionFailure.INVALID_REQUEST)
        val environments = LinkedHashMap<String, String>()
        environments["widget-size"] = "action"
        environments["widget-param"] = ""
        environments["action-source"] = source

        if (source == SOURCE_CONTROL) {
            val control = surfaces.control(controlID) ?: throw ActionRejected(ActionFailure.ACTION_NOT_FOUND)
            val declared = control.actionID?.let { surfaces.action(it) ?: throw ActionRejected(ActionFailure.ACTION_NOT_FOUND) }
            // A caller that names an action must name the one this control is declared with.
            if (!actionID.isNullOrEmpty() && !actionID.equals(declared?.id ?: control.id, ignoreCase = true)) throw ActionRejected(ActionFailure.ACTION_NOT_FOUND)
            if (control.isToggle != (value != null)) throw ActionRejected(ActionFailure.INVALID_REQUEST)
            var key: String? = null
            if (control.isToggle) {
                if (!surfaces.hasStoragePermission) throw ActionRejected(ActionFailure.STORAGE_DENIED)
                if (!SurfaceManifest.isValidStateKey(control.stateKey)) throw ActionRejected(ActionFailure.INVALID_STATE_KEY)
                key = control.stateKey
            }
            // A legacy control behaves like an action named after the control.
            environments["action-id"] = declared?.id ?: control.id
            environments["control-id"] = control.id
            value(environments, value)
            return ActionPlan(declared?.id, if (declared == null) control.function else null, environments, key, value)
        }

        if (controlID != null) throw ActionRejected(ActionFailure.INVALID_REQUEST)
        val declared = surfaces.action(actionID) ?: throw ActionRejected(ActionFailure.ACTION_NOT_FOUND)
        var key: String? = null
        if (stateKey != null) {
            if (value == null) throw ActionRejected(ActionFailure.INVALID_REQUEST)
            if (!surfaces.hasStoragePermission) throw ActionRejected(ActionFailure.STORAGE_DENIED)
            if (!SurfaceManifest.isValidStateKey(stateKey)) throw ActionRejected(ActionFailure.INVALID_STATE_KEY)
            key = stateKey
        }
        environments["action-id"] = declared.id
        value(environments, value)
        return ActionPlan(declared.id, null, environments, key, value)
    }

    /** A stored toggle state: `true` and `1` are on, everything else (including a missing value) is off. */
    fun isOn(stored: String?): Boolean = stored == "true" || stored == "1"

    private fun value(environments: MutableMap<String, String>, value: Boolean?) {
        if (value == null) return
        environments["action-value"] = if (value) "true" else "false"
        // Compatibility name from the first Control Widget release.
        environments["control-value"] = environments.getValue("action-value")
    }
}
