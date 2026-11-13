package com.everettjf.scriptwidget.core.render

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import androidx.core.graphics.PathParser
import kotlin.math.min

/**
 * Paints the inline SVG the shared renderer emits: icons, rings, gauges,
 * charts and shape strokes. Presentation attributes inherit from ancestors
 * as in SVG; `currentColor` resolves to the element's CSS color.
 */
class SvgPainter(private val text: TextEngine) {
    private class Attributes(
        val fill: String = "black", val stroke: String = "none", val strokeWidth: Float = 1f,
        val lineCap: String = "butt", val lineJoin: String = "miter", val fillRule: String = "nonzero",
        val fontSize: Float = 16f, val fontFamily: String = "sans-serif", val fontWeight: Int = 400, val textAnchor: String = "start",
    ) {
        fun merged(node: DomNode): Attributes {
            val attributes = node.attributes
            if (attributes.isEmpty()) return this
            return Attributes(
                fill = attributes["fill"] ?: fill,
                stroke = attributes["stroke"] ?: stroke,
                strokeWidth = attributes["stroke-width"]?.toFloatOrNull() ?: strokeWidth,
                lineCap = attributes["stroke-linecap"] ?: lineCap,
                lineJoin = attributes["stroke-linejoin"] ?: lineJoin,
                fillRule = attributes["fill-rule"] ?: fillRule,
                fontSize = attributes["font-size"]?.removeSuffix("px")?.toFloatOrNull() ?: fontSize,
                fontFamily = attributes["font-family"] ?: fontFamily,
                fontWeight = attributes["font-weight"]?.toIntOrNull() ?: fontWeight,
                textAnchor = attributes["text-anchor"] ?: textAnchor,
            )
        }
    }

    private var currentColor = Color.BLACK
    private var masks: Map<String, DomNode> = emptyMap()

    /** Paints an `<svg>` element with its top-left corner at the canvas origin. */
    fun paint(canvas: Canvas, root: DomNode, cssColor: Int) {
        currentColor = cssColor
        masks = HashMap<String, DomNode>().also { collectMasks(root, it) }
        val width = root.attributes["width"]?.toFloatOrNull() ?: return
        val height = root.attributes["height"]?.toFloatOrNull() ?: return
        canvas.save()
        root.style["transform"]?.let { value ->
            Regex("rotate\\((-?[0-9.]+)deg\\)").find(value)?.let { canvas.rotate(it.groupValues[1].toFloat(), width / 2f, height / 2f) }
        }
        val viewBox = root.attributes["viewBox"]?.trim()?.split(Regex("[\\s,]+"))?.mapNotNull { it.toFloatOrNull() }
        if (viewBox != null && viewBox.size == 4 && viewBox[2] > 0f && viewBox[3] > 0f) {
            val scale = min(width / viewBox[2], height / viewBox[3])
            canvas.translate((width - viewBox[2] * scale) / 2f, (height - viewBox[3] * scale) / 2f)
            canvas.scale(scale, scale)
            canvas.translate(-viewBox[0], -viewBox[1])
        }
        val attributes = Attributes().merged(root)
        for (child in root.children) draw(canvas, child, attributes)
        canvas.restore()
    }

    private fun collectMasks(node: DomNode, into: MutableMap<String, DomNode>) {
        if (node.tag == "mask") node.attributes["id"]?.let { into[it] = node }
        node.children.forEach { collectMasks(it, into) }
    }

    private fun draw(canvas: Canvas, node: DomNode, inherited: Attributes) {
        if (node.tag == "defs" || node.tag == "mask" || node.tag.isEmpty()) return
        val attributes = inherited.merged(node)
        val mask = node.attributes["mask"]?.let { Regex("url\\(#(.+?)\\)").find(it)?.groupValues?.get(1) }?.let { masks[it] }
        val opacity = node.attributes["opacity"]?.toFloatOrNull()?.coerceIn(0f, 1f) ?: 1f

        canvas.save()
        node.attributes["transform"]?.let { canvas.concat(transform(it)) }
        val layered = mask != null || opacity < 1f
        if (layered) canvas.saveLayerAlpha(null, (opacity * 255f + 0.5f).toInt())

        if (node.tag == "g") for (child in node.children) draw(canvas, child, attributes)
        else if (node.tag == "text") drawText(canvas, node, attributes)
        else shape(node)?.let { path -> drawPath(canvas, node, path, attributes) }

        if (mask != null) {
            // An SVG mask keeps the drawing where the mask is light: composite
            // the mask's luminance into the layer's alpha.
            val luminance = ColorMatrix(floatArrayOf(
                0f, 0f, 0f, 0f, 0f,
                0f, 0f, 0f, 0f, 0f,
                0f, 0f, 0f, 0f, 0f,
                0.2126f, 0.7152f, 0.0722f, 0f, 0f,
            ))
            val maskPaint = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN); colorFilter = ColorMatrixColorFilter(luminance) }
            canvas.saveLayer(null, maskPaint)
            val maskAttributes = Attributes().merged(mask)
            for (child in mask.children) draw(canvas, child, maskAttributes)
            canvas.restore()
        }
        if (layered) canvas.restore()
        canvas.restore()
    }

    private fun number(node: DomNode, name: String, fallback: Float = 0f): Float = node.attributes[name]?.toFloatOrNull() ?: fallback

    private fun shape(node: DomNode): Path? = when (node.tag) {
        "path" -> node.attributes["d"]?.let { data -> runCatching { PathParser.createPathFromPathData(data) }.getOrNull() }
        "rect" -> {
            val x = number(node, "x"); val y = number(node, "y")
            val width = number(node, "width"); val height = number(node, "height")
            val rx = min(node.attributes["rx"]?.toFloatOrNull() ?: node.attributes["ry"]?.toFloatOrNull() ?: 0f, width / 2f)
            val ry = min(node.attributes["ry"]?.toFloatOrNull() ?: rx, height / 2f)
            if (width <= 0f || height <= 0f) null else roundedRect(x, y, width, height, rx, ry)
        }
        "circle" -> Path().apply { val r = number(node, "r"); addOval(RectF(number(node, "cx") - r, number(node, "cy") - r, number(node, "cx") + r, number(node, "cy") + r), Path.Direction.CW) }
        "ellipse" -> Path().apply {
            val rx = number(node, "rx"); val ry = number(node, "ry")
            addOval(RectF(number(node, "cx") - rx, number(node, "cy") - ry, number(node, "cx") + rx, number(node, "cy") + ry), Path.Direction.CW)
        }
        "line" -> Path().apply { moveTo(number(node, "x1"), number(node, "y1")); lineTo(number(node, "x2"), number(node, "y2")) }
        "polyline", "polygon" -> {
            val values = node.attributes["points"]?.trim()?.split(Regex("[\\s,]+"))?.mapNotNull { it.toFloatOrNull() } ?: emptyList()
            if (values.size < 4) null else Path().apply {
                moveTo(values[0], values[1])
                for (index in 2 until values.size - 1 step 2) lineTo(values[index], values[index + 1])
                if (node.tag == "polygon") close()
            }
        }
        else -> null
    }

    /** SVG rectangles start at (x + rx, y) and run clockwise; dash offsets depend on it. */
    private fun roundedRect(x: Float, y: Float, width: Float, height: Float, rx: Float, ry: Float): Path = Path().apply {
        if (rx <= 0f || ry <= 0f) {
            moveTo(x, y); lineTo(x + width, y); lineTo(x + width, y + height); lineTo(x, y + height); close()
            return@apply
        }
        moveTo(x + rx, y)
        lineTo(x + width - rx, y)
        arcTo(RectF(x + width - 2 * rx, y, x + width, y + 2 * ry), -90f, 90f)
        lineTo(x + width, y + height - ry)
        arcTo(RectF(x + width - 2 * rx, y + height - 2 * ry, x + width, y + height), 0f, 90f)
        lineTo(x + rx, y + height)
        arcTo(RectF(x, y + height - 2 * ry, x + 2 * rx, y + height), 90f, 90f)
        lineTo(x, y + ry)
        arcTo(RectF(x, y, x + 2 * rx, y + 2 * ry), 180f, 90f)
        close()
    }

    private fun resolveColor(value: String): Int? = if (value == "currentColor") currentColor else Css.color(value)

    private fun drawPath(canvas: Canvas, node: DomNode, path: Path, attributes: Attributes) {
        val fillOpacity = node.attributes["fill-opacity"]?.toFloatOrNull()?.coerceIn(0f, 1f) ?: 1f
        val strokeOpacity = node.attributes["stroke-opacity"]?.toFloatOrNull()?.coerceIn(0f, 1f) ?: 1f
        val closedShape = node.tag != "line" && node.tag != "polyline"
        resolveColor(attributes.fill)?.takeIf { closedShape || node.tag == "polyline" }?.let { fill ->
            if (Color.alpha(fill) == 0) return@let
            path.fillType = if (attributes.fillRule == "evenodd") Path.FillType.EVEN_ODD else Path.FillType.WINDING
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = withOpacity(fill, fillOpacity) }
            canvas.drawPath(path, paint)
        }
        resolveColor(attributes.stroke)?.let { stroke ->
            if (Color.alpha(stroke) == 0 || attributes.strokeWidth <= 0f) return@let
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                color = withOpacity(stroke, strokeOpacity)
                strokeWidth = attributes.strokeWidth
                strokeCap = when (attributes.lineCap) { "round" -> Paint.Cap.ROUND; "square" -> Paint.Cap.SQUARE; else -> Paint.Cap.BUTT }
                strokeJoin = when (attributes.lineJoin) { "round" -> Paint.Join.ROUND; "bevel" -> Paint.Join.BEVEL; else -> Paint.Join.MITER }
            }
            node.attributes["stroke-dasharray"]?.let { dashes ->
                val values = dashes.trim().split(Regex("[\\s,]+")).mapNotNull { it.toFloatOrNull() }
                if (values.isNotEmpty() && values.any { it > 0f }) {
                    // pathLength rescales dash lengths to the real outline length.
                    val unit = node.attributes["pathLength"]?.toFloatOrNull()?.takeIf { it > 0f }?.let { PathMeasure(path, false).length / it } ?: 1f
                    val even = if (values.size % 2 == 0) values else values + values
                    val intervals = FloatArray(even.size) { maxOf(even[it] * unit, if (it % 2 == 0) 0.0001f else 0f) }
                    val total = intervals.sum()
                    val offset = (node.attributes["stroke-dashoffset"]?.toFloatOrNull() ?: 0f) * unit
                    val phase = if (total > 0f) ((offset % total) + total) % total else 0f
                    // A zero-length dash with round caps would still draw a dot.
                    if (even[0] <= 0f) return@let
                    paint.pathEffect = DashPathEffect(intervals, phase)
                }
            }
            canvas.drawPath(path, paint)
        }
    }

    private fun withOpacity(color: Int, opacity: Float): Int =
        if (opacity >= 1f) color else Color.argb((Color.alpha(color) * opacity + 0.5f).toInt(), Color.red(color), Color.green(color), Color.blue(color))

    private fun drawText(canvas: Canvas, node: DomNode, attributes: Attributes) {
        val content = node.text ?: return
        val fill = resolveColor(attributes.fill) ?: return
        val paint = text.paint(TextStyle(attributes.fontFamily, attributes.fontSize, attributes.fontWeight, attributes.fontSize * 1.2f))
        paint.color = fill
        paint.textAlign = when (attributes.textAnchor) { "middle" -> Paint.Align.CENTER; "end" -> Paint.Align.RIGHT; else -> Paint.Align.LEFT }
        canvas.drawText(content, number(node, "x"), number(node, "y"), paint)
    }

    /** SVG transform list: translate, scale, rotate. */
    private fun transform(value: String): Matrix {
        val matrix = Matrix()
        for (match in Regex("([a-zA-Z]+)\\(([^)]*)\\)").findAll(value)) {
            val arguments = match.groupValues[2].trim().split(Regex("[\\s,]+")).mapNotNull { it.toFloatOrNull() }
            val step = Matrix()
            when (match.groupValues[1]) {
                "translate" -> step.setTranslate(arguments.getOrElse(0) { 0f }, arguments.getOrElse(1) { 0f })
                "scale" -> step.setScale(arguments.getOrElse(0) { 1f }, arguments.getOrElse(1) { arguments.getOrElse(0) { 1f } })
                "rotate" -> if (arguments.size >= 3) step.setRotate(arguments[0], arguments[1], arguments[2]) else step.setRotate(arguments.getOrElse(0) { 0f })
                else -> continue
            }
            matrix.preConcat(step)
        }
        return matrix
    }
}
