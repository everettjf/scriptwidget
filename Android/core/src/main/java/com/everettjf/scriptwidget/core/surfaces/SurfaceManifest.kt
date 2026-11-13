package com.everettjf.scriptwidget.core.surfaces

import org.json.JSONArray
import org.json.JSONObject
import java.text.BreakIterator

/** One entry of a package's `actions`: a JavaScript function the system may run by its [id]. */
class DeclaredAction(val id: String, val title: String, val description: String?, val systemImage: String, val function: String)

/**
 * One entry of a package's `controls`. Exactly one of [actionID] (a declared
 * action) and [function] (the legacy direct `action` field) is set. A toggle
 * always has a [stateKey]; a button never has one.
 */
class DeclaredControl(
    val id: String,
    val type: String,
    val title: String,
    val subtitle: String?,
    val systemImage: String,
    val function: String?,
    val actionID: String?,
    val stateKey: String?,
) {
    val isToggle: Boolean get() = type == TYPE_TOGGLE

    companion object {
        const val TYPE_BUTTON = "button"
        const val TYPE_TOGGLE = "toggle"
    }
}

/** The validated `actions` and `controls` of one package manifest. */
class PackageSurfaces(val actions: List<DeclaredAction>, val controls: List<DeclaredControl>, val hasStoragePermission: Boolean) {
    /** The declared action with this identifier (compared without case, as on iOS), or null. */
    fun action(id: String?): DeclaredAction? = if (id.isNullOrEmpty()) null else actions.singleOrNull { it.id.equals(id, ignoreCase = true) }

    /** The declared control with this identifier, or null. */
    fun control(id: String?): DeclaredControl? = if (id.isNullOrEmpty()) null else controls.singleOrNull { it.id.equals(id, ignoreCase = true) }

    companion object {
        /** What a package without a manifest declares: nothing. */
        val EMPTY = PackageSurfaces(emptyList(), emptyList(), false)
    }
}

/** A manifest whose `actions` or `controls` break the Package 2.0 contract. [code] matches the shared validator's issue codes. */
class SurfaceManifestException(val code: String, message: String) : Exception(message)

/**
 * Reads `actions` and `controls` from a decoded `widget.json` with the same
 * limits as the shared manifest validator. Anything malformed throws: a
 * system surface never runs code from a manifest it does not fully accept.
 */
object SurfaceManifest {
    const val MAXIMUM_ACTIONS = 16
    const val MAXIMUM_CONTROLS = 8

    private val shortID = Regex("^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$")
    private val symbol = Regex("^[A-Za-z0-9][A-Za-z0-9.-]{0,79}$")
    private val function = Regex("^[A-Za-z_$][A-Za-z0-9_$]{0,63}$")
    private val stateKey = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
    private val actionKeys = setOf("id", "title", "description", "systemImage", "function")
    private val controlKeys = setOf("id", "type", "title", "subtitle", "systemImage", "action", "actionID", "stateKey")

    /** True when [key] may hold a toggle's state in package storage. */
    fun isValidStateKey(key: String?): Boolean = key != null && stateKey.matches(key)

    /**
     * Validates and returns the declared surfaces. A null [manifest] (a legacy
     * package) declares none.
     * @throws SurfaceManifestException when a declaration is malformed or over a limit.
     */
    fun parse(manifest: JSONObject?): PackageSurfaces {
        if (manifest == null) return PackageSurfaces.EMPTY
        val permissions = manifest.opt("permissions")
        val storage = permissions is JSONArray && (0 until permissions.length()).any { permissions.opt(it) == "storage" }
        val actions = actions(manifest)
        return PackageSurfaces(actions, controls(manifest, actions, storage), storage)
    }

    private fun actions(manifest: JSONObject): List<DeclaredAction> {
        val items = objects(manifest, "actions", actionKeys)
        if (items.size > MAXIMUM_ACTIONS) fail("too_many_actions", "A package may declare at most 16 actions.")
        val result = items.map { item ->
            val id = required(item, "id", "actions")
            if (!shortID.matches(id)) fail("invalid_action_id", "Invalid action identifier.")
            val title = required(item, "title", "actions")
            if (title.isBlank() || characters(title) > 40) fail("invalid_action_title", "Action titles must contain 1–40 characters.")
            val description = optional(item, "description", "actions")
            if (description != null && characters(description) > 160) fail("invalid_action_description", "Action descriptions may contain at most 160 characters.")
            val image = required(item, "systemImage", "actions")
            if (!symbol.matches(image)) fail("invalid_action_image", "Action systemImage must be an SF Symbols name.")
            val name = required(item, "function", "actions")
            if (!function.matches(name)) fail("invalid_action_function", "Action function must be a JavaScript function identifier.")
            DeclaredAction(id, title, description, image, name)
        }
        if (result.map { it.id.lowercase() }.toSet().size != result.size) fail("duplicate_actions", "Action identifiers must be unique.")
        return result
    }

    private fun controls(manifest: JSONObject, actions: List<DeclaredAction>, storage: Boolean): List<DeclaredControl> {
        val items = objects(manifest, "controls", controlKeys)
        if (items.size > MAXIMUM_CONTROLS) fail("too_many_controls", "A package may declare at most 8 controls.")
        val result = items.map { item ->
            val id = required(item, "id", "controls")
            if (!shortID.matches(id)) fail("invalid_control_id", "Invalid control identifier.")
            val type = required(item, "type", "controls")
            if (type != DeclaredControl.TYPE_BUTTON && type != DeclaredControl.TYPE_TOGGLE) fail("malformed_controls", "controls are malformed.")
            val title = required(item, "title", "controls")
            if (title.isBlank() || characters(title) > 40) fail("invalid_control_title", "Control titles must contain 1–40 characters.")
            val subtitle = optional(item, "subtitle", "controls")
            if (subtitle != null && characters(subtitle) > 80) fail("invalid_control_subtitle", "Control subtitles may contain at most 80 characters.")
            val image = required(item, "systemImage", "controls")
            if (!symbol.matches(image)) fail("invalid_control_image", "Control systemImage must be an SF Symbols name.")
            val legacy = optional(item, "action", "controls")
            val actionID = optional(item, "actionID", "controls")
            when {
                legacy != null && actionID != null -> fail("ambiguous_control_action", "Controls must declare either action or actionID, not both.")
                legacy != null -> if (!function.matches(legacy)) fail("invalid_control_action", "Control action must be a JavaScript function identifier.")
                actionID != null -> if (actions.none { it.id.equals(actionID, ignoreCase = true) }) fail("missing_control_action", "A control references an unknown action.")
                else -> fail("missing_control_action", "Controls must declare actionID or the legacy action field.")
            }
            val key = optional(item, "stateKey", "controls")
            if (type == DeclaredControl.TYPE_TOGGLE) {
                if (!isValidStateKey(key)) fail("invalid_control_state", "Toggle controls require a valid stateKey.")
                if (!storage) fail("control_storage", "Toggle controls require the storage permission.")
            } else if (key != null) fail("button_control_state", "Button controls must not declare stateKey.")
            DeclaredControl(id, type, title, subtitle, image, legacy, actionID, key)
        }
        if (result.map { it.id.lowercase() }.toSet().size != result.size) fail("duplicate_controls", "Control identifiers must be unique.")
        return result
    }

    /** The objects of an optional array field; unknown keys and other shapes are rejected. */
    private fun objects(manifest: JSONObject, field: String, allowed: Set<String>): List<JSONObject> {
        val value = manifest.opt(field)
        if (value == null || value == JSONObject.NULL) return emptyList()
        if (value !is JSONArray) fail("malformed_$field", "$field are malformed.")
        return List(value.length()) { index ->
            val item = value.opt(index) as? JSONObject ?: fail("malformed_$field", "$field are malformed.")
            if (item.keys().asSequence().any { it !in allowed }) fail("unknown_${field}_fields", "$field have unknown fields.")
            item
        }
    }

    private fun required(item: JSONObject, key: String, field: String): String =
        item.opt(key) as? String ?: fail("malformed_$field", "$field are malformed.")

    private fun optional(item: JSONObject, key: String, field: String): String? {
        val value = item.opt(key)
        if (value == null || value == JSONObject.NULL) return null
        return value as? String ?: fail("malformed_$field", "$field are malformed.")
    }

    /** User-perceived characters, the unit Swift's `String.count` uses. */
    internal fun characters(text: String): Int {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        var count = 0
        while (iterator.next() != BreakIterator.DONE) count += 1
        return count
    }

    private fun fail(code: String, message: String): Nothing = throw SurfaceManifestException(code, message)
}
