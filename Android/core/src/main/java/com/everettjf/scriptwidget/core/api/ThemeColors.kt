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

    /**
     * The Material 3 tone of each role, light and dark, in one of the five tonal palettes. Android 12
     * and 13 have the palettes (`system_accent1_600` …) but not the role colors, which arrived in
     * Android 14; the roles are then taken from these tones, as Material's dynamic color does.
     */
    private val tones: Map<String, Triple<String, Int, Int>> = mapOf(
        "primary" to Triple("accent1", 40, 80), "onPrimary" to Triple("accent1", 100, 20),
        "primaryContainer" to Triple("accent1", 90, 30), "onPrimaryContainer" to Triple("accent1", 10, 90),
        "secondary" to Triple("accent2", 40, 80), "onSecondary" to Triple("accent2", 100, 20),
        "secondaryContainer" to Triple("accent2", 90, 30), "onSecondaryContainer" to Triple("accent2", 10, 90),
        "tertiary" to Triple("accent3", 40, 80), "onTertiary" to Triple("accent3", 100, 20),
        "tertiaryContainer" to Triple("accent3", 90, 30), "onTertiaryContainer" to Triple("accent3", 10, 90),
        "background" to Triple("neutral1", 98, 6), "onBackground" to Triple("neutral1", 10, 90),
        "surface" to Triple("neutral1", 98, 6), "onSurface" to Triple("neutral1", 10, 90),
        "surfaceVariant" to Triple("neutral2", 90, 30), "onSurfaceVariant" to Triple("neutral2", 30, 80),
        "surfaceContainerLowest" to Triple("neutral1", 100, 4), "surfaceContainerLow" to Triple("neutral1", 96, 10),
        "surfaceContainer" to Triple("neutral1", 94, 12), "surfaceContainerHigh" to Triple("neutral1", 92, 17),
        "surfaceContainerHighest" to Triple("neutral1", 90, 22),
        "outline" to Triple("neutral2", 50, 60), "outlineVariant" to Triple("neutral2", 80, 30),
    )

    /** The tones Android publishes for each palette, by resource step: `system_accent1_600` is tone 40. */
    private val steps = listOf(0 to 100, 10 to 99, 50 to 95, 100 to 90, 200 to 80, 300 to 70, 400 to 60, 500 to 50, 600 to 40, 700 to 30, 800 to 20, 900 to 10, 1000 to 0)

    /**
     * The color of [tone] (0 to 100) from the published tones of one palette, given as tone to ARGB.
     * A tone between two published ones is blended from them; Material's tones are close enough in
     * lightness for this to stay within a few RGB steps of the exact color.
     */
    internal fun toneColor(published: Map<Int, Int>, tone: Int): Int? {
        published[tone]?.let { return it }
        val above = published.keys.filter { it > tone }.minOrNull() ?: return null
        val below = published.keys.filter { it < tone }.maxOrNull() ?: return null
        val t = (tone - below).toFloat() / (above - below)
        val low = published.getValue(below); val high = published.getValue(above)
        fun mix(shift: Int) = Math.round(((low shr shift) and 0xFF) * (1 - t) + ((high shr shift) and 0xFF) * t)
        return (0xFF shl 24) or (mix(16) shl 16) or (mix(8) shl 8) or mix(0)
    }

    private fun systemColor(context: Context, name: String): Int? {
        val id = context.resources.getIdentifier(name, "color", "android")
        if (id == 0) return null
        return runCatching { context.getColor(id) }.getOrNull()
    }

    /** `{ light: { role: [r, g, b, a] }, dark: { ... } }`; a role the system does not define is left out. */
    fun palette(context: Context): JSONObject {
        val result = JSONObject()
        val published = HashMap<String, Map<Int, Int>>()
        fun palette(name: String) = published.getOrPut(name) {
            steps.mapNotNull { (step, tone) -> systemColor(context, "system_${name}_$step")?.let { tone to it } }.toMap()
        }
        for (mode in listOf("light", "dark")) {
            val colors = JSONObject()
            for ((role, resource) in roles) {
                val color = systemColor(context, "system_${resource}_$mode")
                    ?: tones[role]?.let { (name, light, dark) -> toneColor(palette(name), if (mode == "light") light else dark) }
                    ?: continue
                colors.put(role, JSONArray().put(Color.red(color)).put(Color.green(color)).put(Color.blue(color)).put(Color.alpha(color) / 255.0))
            }
            result.put(mode, colors)
        }
        return result
    }

    /** Changes when the user picks another wallpaper or color theme. */
    fun signature(context: Context): String = palette(context).toString().hashCode().toString(16)
}
