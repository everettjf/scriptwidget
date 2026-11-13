package com.everettjf.scriptwidget.core

import com.everettjf.scriptwidget.core.runtime.PackageFiles
import org.json.JSONObject

/**
 * What this Android release does not implement. A package that needs one of
 * these still installs; the affected API reports that it is unavailable and
 * the app lists the gaps so nothing fails silently.
 */
object PlatformSupport {
    /** Android release line of this build: "1.0", "1.1" or "1.2". */
    const val RELEASE = "1.1"

    /** Manifest permissions with no Android implementation in this release, with the reason shown to the user. */
    val unsupportedPermissions: Map<String, String> = linkedMapOf(
        "reminders" to "Reminders (\$reminders) has no system equivalent on Android.",
        "remindersWrite" to "Reminders (\$reminders) has no system equivalent on Android.",
        "music" to "Now-playing data (\$music) is planned for a later Android release.",
        "icloud" to "iCloud JSON sync (\$icloud) is not available on Android.",
        "maps" to "Maps (\$maps) is planned for a later Android release.",
        "weather" to "Weather (\$weather) is planned for a later Android release.",
        "alarms" to "Alarms (\$alarms) is planned for a later Android release.",
        "documents" to "Documents (\$documents) is planned for a later Android release.",
        "contacts" to "Contacts (\$contacts) is planned for a later Android release.",
        "home" to "Home control (\$home) has no Android equivalent.",
    )

    /** Manifest features with no Android surface in this release. */
    private val unsupportedManifestKeys: Map<String, String> = linkedMapOf(
        "pushUpdates" to "Push-triggered refresh is planned for a later Android release.",
    )

    private val unsupportedFamilies = setOf("accessoryCircular", "accessoryRectangular", "accessoryInline")

    /** Source markers for capabilities that only exist on Apple platforms. */
    private val unsupportedSourceMarkers: Map<String, String> = linkedMapOf(
        "\$dynamic_island" to "Dynamic Island content is not shown on Android.",
        "backgroundMaterial" to "Frosted material backgrounds fall back to the plain background color.",
        "live-activity-state" to "Live Activities appear as Android Live Updates that show the title, detail and progress only; the package's own layout is not drawn.",
    )

    /** User-facing lines describing what a package uses that Android does not support. */
    fun unsupported(manifest: JSONObject?, files: PackageFiles?): List<String> {
        val lines = LinkedHashSet<String>()
        manifest?.optJSONArray("permissions")?.let { permissions ->
            for (index in 0 until permissions.length()) unsupportedPermissions[permissions.optString(index)]?.let { lines += it }
        }
        if (manifest != null) for ((key, reason) in unsupportedManifestKeys) {
            val value = manifest.opt(key)
            if (value != null && value != JSONObject.NULL && !(value is org.json.JSONArray && value.length() == 0)) lines += reason
        }
        manifest?.optJSONArray("supportedFamilies")?.let { families ->
            val all = List(families.length()) { families.optString(it) }
            if (all.isNotEmpty() && all.all { it in unsupportedFamilies }) lines += "This package only declares Lock Screen accessory sizes, which Android does not have."
        }
        val source = files?.let { package_ -> package_.paths().filter { it.endsWith(".jsx") || it.endsWith(".js") }.take(32).mapNotNull { package_.readText(it) }.joinToString("\n") }.orEmpty()
        for ((marker, reason) in unsupportedSourceMarkers) if (source.contains(marker)) lines += reason
        return lines.toList()
    }
}
