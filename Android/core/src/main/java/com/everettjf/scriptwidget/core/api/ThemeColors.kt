package com.everettjf.scriptwidget.core.api

import android.content.Context
import android.graphics.Color
import org.json.JSONArray
import org.json.JSONObject

/**
 * The system's Material colors, which Android derives from the wallpaper.
 * Widgets name them `material.<role>` in any color prop; the renderer picks
 * the light or the dark value for the bitmap it draws. Reading them needs no
 * permission.
 */
object ThemeColors {
    /** Role as scripts write it, and the platform color resource it comes from. */
    private val roles = listOf(
        "primary" to "primary", "onPrimary" to "on_primary",
        "primaryContainer" to "primary_container", "onPrimaryContainer" to "on_primary_container",
        "secondary" to "secondary", "onSecondary" to "on_secondary",
        "secondaryContainer" to "secondary_container", "onSecondaryContainer" to "on_secondary_container",
        "tertiary" to "tertiary", "onTertiary" to "on_tertiary",
        "tertiaryContainer" to "tertiary_container", "onTertiaryContainer" to "on_tertiary_container",
        "background" to "background", "onBackground" to "on_background",
        "surface" to "surface", "onSurface" to "on_surface",
        "surfaceVariant" to "surface_variant", "onSurfaceVariant" to "on_surface_variant",
        "surfaceContainerLowest" to "surface_container_lowest", "surfaceContainerLow" to "surface_container_low",
        "surfaceContainer" to "surface_container", "surfaceContainerHigh" to "surface_container_high",
        "surfaceContainerHighest" to "surface_container_highest",
        "outline" to "outline", "outlineVariant" to "outline_variant",
    )

    val roleNames: List<String> get() = roles.map { it.first }

    /** `{ light: { role: [r, g, b, a] }, dark: { ... } }`; a role the system does not define is left out. */
    fun palette(context: Context): JSONObject {
        val result = JSONObject()
        for (mode in listOf("light", "dark")) {
            val colors = JSONObject()
            for ((role, resource) in roles) {
                val id = context.resources.getIdentifier("system_${resource}_$mode", "color", "android")
                if (id == 0) continue
                val color = runCatching { context.getColor(id) }.getOrNull() ?: continue
                colors.put(role, JSONArray().put(Color.red(color)).put(Color.green(color)).put(Color.blue(color)).put(Color.alpha(color) / 255.0))
            }
            result.put(mode, colors)
        }
        return result
    }

    /** Changes when the user picks another wallpaper or color theme. */
    fun signature(context: Context): String = palette(context).toString().hashCode().toString(16)
}
