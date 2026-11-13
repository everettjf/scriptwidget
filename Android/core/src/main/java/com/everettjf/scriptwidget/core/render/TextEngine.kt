package com.everettjf.scriptwidget.core.render

import android.graphics.Paint
import android.graphics.text.LineBreaker
import android.graphics.text.MeasuredText
import android.text.TextPaint

/** Font description shared by measurement and drawing. Sizes are in points. */
data class TextStyle(val family: String, val size: Float, val weight: Int, val leading: Float)

class TextLine(val text: String, val width: Float)

/**
 * Text measurement and line breaking. The shared layout asks for sizes
 * through this class and the painter draws with it, so what was measured is
 * what gets drawn. All values are in points; the painter scales the canvas.
 */
class TextEngine(private val fonts: FontRegistry) {
    private val breaker = LineBreaker.Builder()
        .setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(LineBreaker.HYPHENATION_FREQUENCY_NONE)
        .build()

    fun paint(style: TextStyle): TextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG or Paint.LINEAR_TEXT_FLAG).apply {
        typeface = fonts.typeface(style.family, style.weight)
        textSize = style.size
        hinting = Paint.HINTING_OFF
    }

    /**
     * Lines of [text] in a box [width] points wide. Explicit newlines always
     * break. With a width, text wraps like CSS `white-space: pre-wrap` with
     * `overflow-wrap: break-word`; without one it does not wrap.
     */
    fun lines(text: String, style: TextStyle, width: Float?): List<TextLine> {
        val paint = paint(style)
        val result = ArrayList<TextLine>()
        for (paragraph in text.split('\n')) {
            if (paragraph.isEmpty()) { result += TextLine("", 0f); continue }
            if (width == null || paint.measureText(paragraph) <= width + 0.01f) {
                result += TextLine(paragraph, paint.measureText(paragraph))
                continue
            }
            val characters = paragraph.toCharArray()
            val measured = MeasuredText.Builder(characters).appendStyleRun(paint, characters.size, false).build()
            val constraints = LineBreaker.ParagraphConstraints().apply { setWidth(maxOf(width, 0.01f)) }
            val breaks = breaker.computeLineBreaks(measured, constraints, 0)
            var start = 0
            for (index in 0 until breaks.lineCount) {
                val end = breaks.getLineBreakOffset(index)
                val line = String(characters, start, end - start).trimEnd(' ')
                result += TextLine(line, paint.measureText(line))
                start = end
            }
        }
        return result
    }

    /** First baseline below the top of a line box of the style's leading (CSS half-leading). */
    fun baseline(style: TextStyle): Float {
        val metrics = paint(style).fontMetrics
        val ascent = -metrics.ascent
        val descent = metrics.descent
        return (style.leading - (ascent + descent)) / 2f + ascent
    }
}
