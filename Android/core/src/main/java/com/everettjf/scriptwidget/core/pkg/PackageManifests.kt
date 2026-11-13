package com.everettjf.scriptwidget.core.pkg

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

/**
 * Minimal `widget.json` handling for the library: creating default manifests and reading the
 * display fields. Semantic validation (unknown keys, permissions, entry, versions) is the shared
 * manifest validator's job and is not repeated here.
 */
internal object PackageManifests {
    const val FILE_NAME = "widget.json"
    const val LEGACY_ENTRY = "main.jsx"
    const val LEGACY_METADATA = "meta.json"

    /** Display fields of a manifest; each is null when absent or not a string. */
    class Summary(val id: String?, val name: String?, val version: String?)

    /** Parses manifest text as a JSON object, or null. A present manifest that fails here is invalid, never legacy. */
    fun parse(text: String?): JSONObject? = try {
        text?.let { JSONObject(it) }
    } catch (_: JSONException) {
        null
    }

    fun summary(manifest: JSONObject): Summary = Summary(string(manifest, "id"), string(manifest, "name"), string(manifest, "version"))

    fun string(manifest: JSONObject, key: String): String? = manifest.opt(key) as? String

    /** A fresh local identifier, as `WidgetPackageManifest.newProject` generates. */
    fun freshId(): String = "local." + UUID.randomUUID().toString().lowercase(Locale.ROOT)

    /** `WidgetPackageManifest.newProject` / `newManifest` in `manifest.js`. */
    fun newManifest(name: String): JSONObject = JSONObject()
        .put("formatVersion", 2)
        .put("id", freshId())
        .put("name", name)
        .put("version", "1.0.0")
        .put("runtimeVersion", "1.0")
        .put("entry", LEGACY_ENTRY)
        .put("supportedFamilies", JSONArray(listOf("systemSmall", "systemMedium", "systemLarge")))
        .put("permissions", JSONArray())
        .put("networkDomains", JSONArray())
        .put("plugins", JSONArray())
        .put("actions", JSONArray())
        .put("controls", JSONArray())

    /**
     * `WidgetPackageManifest.legacy`: the manifest given to a package that has `main.jsx` and no
     * `widget.json`. Discovery fields are carried over from `meta.json` when it is well formed;
     * a malformed `meta.json` is ignored, as in Swift.
     */
    fun legacyManifest(name: String, metadataText: String?): JSONObject {
        val manifest = newManifest(name).put("id", PackageNames.legacyId(name))
        val metadata = parse(metadataText) ?: return manifest
        for (key in listOf("description", "category", "icon", "preview")) string(metadata, key)?.let { manifest.put(key, it) }
        val tags = metadata.optJSONArray("tags")
        if (tags != null && (0 until tags.length()).all { tags.opt(it) is String }) manifest.put("tags", tags)
        return manifest
    }

    fun encode(manifest: JSONObject): ByteArray = (manifest.toString(2) + "\n").toByteArray(Charsets.UTF_8)
}
