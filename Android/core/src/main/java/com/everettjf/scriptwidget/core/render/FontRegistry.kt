package com.everettjf.scriptwidget.core.render

import android.content.Context
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import java.util.concurrent.ConcurrentHashMap

/**
 * Resolves the CSS font-family strings the shared renderer emits to Android
 * typefaces. The default face is the bundled Inter with bundled Noto Sans SC
 * as the fallback for Chinese text, so layout is the same on every device;
 * [useSystemFont] switches the default face to the device font.
 */
class FontRegistry(context: Context) {
    private val assets = context.applicationContext.assets
    private val cache = ConcurrentHashMap<String, Typeface>()

    /** When true, default-design text uses the device's own sans-serif face. */
    @Volatile var useSystemFont: Boolean = false

    /** Bundled display fonts selectable with `font="custom,<name>,<size>"`. */
    private val customFonts = mapOf(
        "apple ][" to "Apple ][.ttf", "apple" to "Apple ][.ttf",
        "larabiefont free" to "Larabiefont Free.ttf", "larabiefontfree" to "Larabiefont Free.ttf",
        "monofonto" to "Monofonto.ttf",
        "white rabbit" to "New.ttf", "whiterabbit" to "New.ttf", "new" to "New.ttf",
        "oneslot" to "OneSlot.ttf",
        "unispace" to "Unispace.ttf",
    )

    fun typeface(family: String, weight: Int): Typeface {
        val clamped = weight.coerceIn(100, 900)
        val key = "${useSystemFont}|$family|$clamped"
        return cache.getOrPut(key) { resolve(family, clamped) }
    }

    private fun resolve(family: String, weight: Int): Typeface {
        val first = family.substringBefore(',').trim().trim('"')
        val lower = first.lowercase()
        customFonts[lower]?.let { file ->
            return runCatching { Typeface.createFromAsset(assets, "fonts/$file") }.getOrElse { bundled(weight) }
        }
        return when {
            lower == "ui-monospace" || lower.contains("mono") || lower == "consolas" -> Typeface.create(Typeface.MONOSPACE, weight, false)
            lower == "new york" || lower == "ui-serif" -> Typeface.create(Typeface.SERIF, weight, false)
            useSystemFont -> Typeface.create(Typeface.DEFAULT, weight, false)
            else -> bundled(weight)
        }
    }

    private fun bundled(weight: Int): Typeface = runCatching {
        val inter = Font.Builder(assets, "fonts/Inter.ttf").setFontVariationSettings("'wght' $weight").setWeight(weight).build()
        val chinese = Font.Builder(assets, "fonts/NotoSansSC.ttf").setFontVariationSettings("'wght' $weight").setWeight(weight).build()
        Typeface.CustomFallbackBuilder(FontFamily.Builder(inter).build())
            .addCustomFallback(FontFamily.Builder(chinese).build())
            .setSystemFallback("sans-serif")
            .build()
    }.getOrElse { Typeface.create(Typeface.DEFAULT, weight, false) }
}
