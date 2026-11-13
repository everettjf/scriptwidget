package com.everettjf.scriptwidget.core.render

import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.SweepGradient
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** Parsers for the small CSS subset the shared renderer writes. */
object Css {
    private val named = mapOf(
        "white" to Color.WHITE, "black" to Color.BLACK, "transparent" to Color.TRANSPARENT, "none" to Color.TRANSPARENT,
        "red" to Color.RED, "green" to 0xFF008000.toInt(), "blue" to Color.BLUE, "gray" to Color.GRAY, "grey" to Color.GRAY,
    )

    /** Parses rgba()/rgb()/#hex/named colors. Returns null for `none`, empty or unknown values. */
    fun color(value: String?): Int? {
        val text = value?.trim()?.lowercase() ?: return null
        if (text.isEmpty() || text == "none") return null
        named[text]?.let { return it }
        if (text.startsWith("rgb")) {
            val parts = text.substringAfter('(').substringBefore(')').split(',', '/').map { it.trim() }
            if (parts.size < 3) return null
            val red = parts[0].toFloatOrNull() ?: return null
            val green = parts[1].toFloatOrNull() ?: return null
            val blue = parts[2].toFloatOrNull() ?: return null
            val alpha = parts.getOrNull(3)?.toFloatOrNull() ?: 1f
            return Color.argb((alpha.coerceIn(0f, 1f) * 255f + 0.5f).toInt(), red.toInt().coerceIn(0, 255), green.toInt().coerceIn(0, 255), blue.toInt().coerceIn(0, 255))
        }
        if (text.startsWith("#")) {
            val hex = text.substring(1)
            return when (hex.length) {
                3 -> Color.rgb(hex[0].digitToInt(16) * 17, hex[1].digitToInt(16) * 17, hex[2].digitToInt(16) * 17)
                6 -> (0xFF000000 or hex.toLong(16)).toInt()
                8 -> { val rgba = hex.toLong(16); (((rgba and 0xFF) shl 24) or (rgba shr 8)).toInt() }
                else -> null
            }
        }
        return null
    }

    /** `12px`, `12` or a bare number. Returns null for auto, percentages and keywords. */
    fun pixels(value: String?): Float? {
        val text = value?.trim() ?: return null
        if (text.isEmpty() || text.endsWith("%")) return null
        return text.removeSuffix("px").toFloatOrNull()
    }

    /** A length that may be a percentage of [basis]. */
    fun length(value: String?, basis: Float): Float? {
        val text = value?.trim() ?: return null
        if (text.endsWith("%")) return text.removeSuffix("%").toFloatOrNull()?.let { it / 100f * basis }
        return pixels(text)
    }

    /** Splits on commas that are not inside parentheses. */
    fun splitTopLevel(value: String, separator: Char = ','): List<String> {
        val parts = ArrayList<String>()
        var depth = 0
        var start = 0
        for ((index, character) in value.withIndex()) {
            when (character) {
                '(' -> depth += 1
                ')' -> depth -= 1
                separator -> if (depth == 0) { parts += value.substring(start, index).trim(); start = index + 1 }
            }
        }
        parts += value.substring(start).trim()
        return parts.filter { it.isNotEmpty() }
    }

    private class Stop(val color: Int, val position: Float)

    /** `<color> <position>` where position is in px or deg. */
    private fun stop(text: String): Stop? {
        val split = text.trim().lastIndexOf(' ')
        if (split <= 0) return null
        val color = color(text.substring(0, split)) ?: return null
        val position = text.substring(split + 1).removeSuffix("px").removeSuffix("deg").toFloatOrNull() ?: return null
        return Stop(color, position)
    }

    /**
     * Shader for a CSS gradient painted in a [width] x [height] box, or null
     * when [value] is not a gradient this renderer emits.
     */
    fun gradient(value: String?, width: Float, height: Float): Shader? {
        val text = value?.trim() ?: return null
        val open = text.indexOf('(')
        if (open < 0 || !text.endsWith(")")) return null
        val kind = text.substring(0, open)
        val arguments = splitTopLevel(text.substring(open + 1, text.length - 1))
        if (arguments.isEmpty()) return null
        when (kind) {
            "linear-gradient" -> {
                val angled = arguments[0].endsWith("deg")
                val degrees = if (angled) arguments[0].removeSuffix("deg").toFloatOrNull() ?: 180f else 180f
                val stopTexts = if (angled) arguments.drop(1) else arguments
                val parsed = stopTexts.map { stop(it) }
                val radians = Math.toRadians(degrees.toDouble())
                val directionX = sin(radians).toFloat()
                val directionY = -cos(radians).toFloat()
                val lineLength = abs(width * directionX) + abs(height * directionY)
                // Stops without positions (a solid two-stop fallback) span the gradient line.
                val stops = if (parsed.all { it != null }) parsed.filterNotNull()
                else stopTexts.mapIndexedNotNull { index, item -> color(item)?.let { Stop(it, lineLength * index / maxOf(1, stopTexts.size - 1)) } }
                if (stops.size < 2) return null
                val first = stops.first().position
                val last = stops.last().position
                if (last - first <= 0f) return null
                fun point(distance: Float) = floatArrayOf(width / 2f + (distance - lineLength / 2f) * directionX, height / 2f + (distance - lineLength / 2f) * directionY)
                val start = point(first)
                val end = point(last)
                return LinearGradient(start[0], start[1], end[0], end[1], stops.map { it.color }.toIntArray(),
                    monotonic(stops.map { (it.position - first) / (last - first) }), Shader.TileMode.CLAMP)
            }
            "radial-gradient" -> {
                val center = centerOf(arguments[0]) ?: return null
                val stops = arguments.drop(1).mapNotNull { stop(it) }
                if (stops.size < 2) return null
                val radius = stops.last().position
                if (radius <= 0f) return null
                return RadialGradient(center[0], center[1], radius, stops.map { it.color }.toIntArray(),
                    monotonic(stops.map { (it.position / radius).coerceIn(0f, 1f) }), Shader.TileMode.CLAMP)
            }
            "conic-gradient" -> {
                val center = centerOf(arguments[0]) ?: return null
                val from = Regex("from\\s+(-?[0-9.]+)deg").find(arguments[0])?.groupValues?.get(1)?.toFloatOrNull() ?: 0f
                val stops = arguments.drop(1).mapNotNull { stop(it) }
                if (stops.size < 2) return null
                val shader = SweepGradient(center[0], center[1], stops.map { it.color }.toIntArray(), monotonic(stops.map { (it.position / 360f).coerceIn(0f, 1f) }))
                // CSS measures conic angles clockwise from 12 o'clock; SweepGradient starts at 3 o'clock.
                shader.setLocalMatrix(Matrix().apply { setRotate(from - 90f, center[0], center[1]) })
                return shader
            }
        }
        return null
    }

    private fun centerOf(argument: String): FloatArray? {
        val match = Regex("at\\s+(-?[0-9.eE+-]+)px\\s+(-?[0-9.eE+-]+)px").find(argument) ?: return null
        return floatArrayOf(match.groupValues[1].toFloat(), match.groupValues[2].toFloat())
    }

    /** Android requires non-decreasing positions. */
    private fun monotonic(positions: List<Float>): FloatArray {
        val result = FloatArray(positions.size)
        var previous = 0f
        for ((index, value) in positions.withIndex()) {
            val current = if (value.isNaN()) previous else maxOf(previous, value)
            result[index] = current
            previous = current
        }
        return result
    }

    class Shadow(val dx: Float, val dy: Float, val blur: Float, val color: Int)

    /** `drop-shadow(Xpx Ypx Rpx color)` from a filter list. */
    fun dropShadow(filter: String?): Shadow? {
        val match = Regex("drop-shadow\\(\\s*(-?[0-9.]+)px\\s+(-?[0-9.]+)px\\s+(-?[0-9.]+)px\\s+(.+?\\))\\s*\\)").find(filter ?: return null) ?: return null
        val color = color(match.groupValues[4]) ?: return null
        return Shadow(match.groupValues[1].toFloat(), match.groupValues[2].toFloat(), match.groupValues[3].toFloat(), color)
    }

    class BoxShadow(val inset: Boolean, val dx: Float, val dy: Float, val blur: Float, val spread: Float, val color: Int)

    /** `[inset] X Y blur [spread] color`. */
    fun boxShadow(value: String?): BoxShadow? {
        var text = value?.trim() ?: return null
        val inset = text.startsWith("inset")
        if (inset) text = text.removePrefix("inset").trim()
        val colorStart = text.indexOfFirst { it.isLetter() && it != 'p' && it != 'x' }.takeIf { it >= 0 } ?: return null
        val numbers = text.substring(0, colorStart).trim().split(Regex("\\s+")).mapNotNull { pixels(it) }
        val color = color(text.substring(colorStart)) ?: return null
        if (numbers.size < 2) return null
        return BoxShadow(inset, numbers[0], numbers[1], numbers.getOrElse(2) { 0f }, numbers.getOrElse(3) { 0f }, color)
    }
}
