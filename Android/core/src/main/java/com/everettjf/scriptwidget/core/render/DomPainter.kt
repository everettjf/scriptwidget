package com.everettjf.scriptwidget.core.render

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Camera
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.RectF
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** One element recorded by the shared renderer (see render/entry.mjs `serialize`). */
class DomNode(json: JSONObject) {
    val tag: String = json.optString("t")
    val svg: Boolean = json.optInt("g") == 1
    val style: Map<String, String> = stringMap(json.optJSONObject("s"))
    val attributes: Map<String, String> = stringMap(json.optJSONObject("a"))
    val dataset: Map<String, String> = stringMap(json.optJSONObject("d"))
    val text: String? = if (json.has("x")) json.optString("x") else null
    val children: List<DomNode> = json.optJSONArray("c")?.let { array -> List(array.length()) { DomNode(array.getJSONObject(it)) } } ?: emptyList()

    private companion object {
        fun stringMap(json: JSONObject?): Map<String, String> {
            if (json == null) return emptyMap()
            val result = HashMap<String, String>()
            json.keys().forEach { result[it] = json.optString(it) }
            return result
        }
    }
}

/** A tappable area of the widget, in points from the widget's top-left corner. */
class HitRegion(val bounds: RectF, val interaction: JSONObject)

/** A `<date>` text the host may replace with a self-updating view. */
class DateSlot(val bounds: RectF, val description: JSONObject, val style: TextStyle?, val color: Int, val align: String)

/** A package GIF the host plays with its own views; it is left out of the bitmap. */
class GifSlot(val bounds: RectF, val source: String)

/**
 * A view with a clock or swing animation, drawn at rest into its own bitmap
 * so the host can move it. [anchor] is the rotation centre (clock) or the
 * resting centre (swing) in widget points; the bitmap is centred on it.
 */
class MotionSlot(val description: JSONObject, val anchor: android.graphics.PointF, val bitmap: Bitmap, val sizePoints: Float)

/** Supplies decoded images for `src` values: `res:<path>`, data URLs and fetched remote URLs. */
fun interface ImageSource {
    fun bitmap(source: String, maximumPixels: Int): Bitmap?
}

/**
 * Paints a recorded element tree on a Canvas. It implements exactly the
 * HTML/CSS and SVG subset that Web/preview-engine/src/render/renderer.js
 * writes: absolutely positioned boxes, text, images and inline SVG.
 */
class DomPainter(
    private val text: TextEngine,
    private val images: ImageSource,
    /** `<date>` styles the host draws itself with self-updating views; their text is left out of the bitmap. */
    private val liveDateStyles: Set<String> = emptySet(),
    /** When true, GIF images are recorded as [gifSlots] instead of being drawn as a still frame. */
    private val liveGifs: Boolean = false,
) {
    val gifSlots = ArrayList<GifSlot>()
    /** Filled when [liveMotion] is on. */
    val motionSlots = ArrayList<MotionSlot>()
    /** Draw animated views into [motionSlots] instead of the widget bitmap. */
    var liveMotion: Boolean = false
    private var pixelScale = 1f
    val hitRegions = ArrayList<HitRegion>()
    val dateSlots = ArrayList<DateSlot>()
    private var activeDate: JSONObject? = null
    private val svg = SvgPainter(text)

    private class TextContext(
        val family: String = "sans-serif", val size: Float = 17f, val weight: Int = 400, val lineHeight: Float? = null,
        val align: String = "left", val wrap: Boolean = true, val color: Int = Color.BLACK,
    ) {
        fun style(): TextStyle = TextStyle(family, size, weight, lineHeight ?: size * 1.2f)
    }

    /** Paints [root] (the widget element). [scale] converts points to pixels. */
    fun paint(canvas: Canvas, root: DomNode, scale: Float) {
        hitRegions.clear()
        dateSlots.clear()
        gifSlots.clear()
        motionSlots.clear()
        pixelScale = scale
        canvas.save()
        canvas.scale(scale, scale)
        val width = Css.pixels(root.style["width"]) ?: 0f
        val height = Css.pixels(root.style["height"]) ?: 0f
        element(canvas, root, width, height, TextContext(), Matrix())
        canvas.restore()
    }

    private fun element(canvas: Canvas, node: DomNode, parentWidth: Float, parentHeight: Float, inherited: TextContext, toWidget: Matrix) {
        if (node.tag == "style" || node.tag.isEmpty()) return
        val style = node.style
        if (node.svg) {
            val x = Css.pixels(style["left"]) ?: 0f
            val y = Css.pixels(style["top"]) ?: 0f
            canvas.save()
            canvas.translate(x, y)
            svg.paint(canvas, node, style["color"]?.let { Css.color(it) } ?: inherited.color)
            canvas.restore()
            return
        }

        if (liveMotion && motionSlots.size < MAXIMUM_MOTION_SLOTS) {
            val motion = node.dataset["swAnimation"]?.let { runCatching { JSONObject(it) }.getOrNull() }
            if (motion != null && isSupportedMotion(motion) && recordMotion(node, motion, parentWidth, parentHeight, inherited, toWidget)) return
        }
        val absolute = style["position"] == "absolute"
        val x = if (absolute) Css.length(style["left"], parentWidth) ?: 0f else 0f
        val y = (if (absolute) Css.length(style["top"], parentHeight) ?: 0f else 0f) + (Css.pixels(style["marginTop"]) ?: 0f)
        val width = Css.length(style["width"], parentWidth) ?: parentWidth
        val height = Css.length(style["height"], parentHeight) ?: parentHeight
        val bounds = RectF(0f, 0f, width, height)

        val local = Matrix(toWidget)
        local.preTranslate(x, y)
        canvas.save()
        canvas.translate(x, y)

        transform(style, width, height)?.let { matrix -> canvas.concat(matrix); local.preConcat(matrix) }

        val shadow = Css.dropShadow(style["filter"])
        val opacity = style["opacity"]?.toFloatOrNull()?.coerceIn(0f, 1f) ?: 1f
        if (shadow != null) {
            paintWithDropShadow(canvas, node, width, height, inherited, local, shadow, opacity)
            canvas.restore()
            return
        }
        val layered = opacity < 1f
        if (layered) canvas.saveLayerAlpha(null, (opacity * 255f + 0.5f).toInt())
        content(canvas, node, bounds, inherited, local)
        if (layered) canvas.restore()
        canvas.restore()
    }

    /** Draws the element into an offscreen bitmap so its silhouette can cast a blurred shadow. */
    private fun paintWithDropShadow(canvas: Canvas, node: DomNode, width: Float, height: Float, inherited: TextContext, local: Matrix, shadow: Css.Shadow, opacity: Float) {
        val values = FloatArray(9).also { canvas.matrix.getValues(it) }
        val deviceScale = max(1f, max(kotlin.math.hypot(values[Matrix.MSCALE_X], values[Matrix.MSKEW_Y]), kotlin.math.hypot(values[Matrix.MSKEW_X], values[Matrix.MSCALE_Y])))
        val margin = ceil(shadow.blur * 3f + max(kotlin.math.abs(shadow.dx), kotlin.math.abs(shadow.dy))) + 2f
        val pixelWidth = ceil((width + margin * 2f) * deviceScale).toInt().coerceIn(1, 4096)
        val pixelHeight = ceil((height + margin * 2f) * deviceScale).toInt().coerceIn(1, 4096)
        val layer = Bitmap.createBitmap(pixelWidth, pixelHeight, Bitmap.Config.ARGB_8888)
        val layerCanvas = Canvas(layer)
        layerCanvas.scale(deviceScale, deviceScale)
        layerCanvas.translate(margin, margin)
        // Hit regions inside are collected in widget coordinates through `local`.
        content(layerCanvas, node, RectF(0f, 0f, width, height), inherited, local)

        val offset = IntArray(2)
        val blurPaint = Paint().apply { if (shadow.blur > 0f) maskFilter = BlurMaskFilter(max(0.1f, shadow.blur * deviceScale), BlurMaskFilter.Blur.NORMAL) }
        val alpha = layer.extractAlpha(blurPaint, offset)
        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { color = shadow.color }
        val layerPaint = Paint(Paint.FILTER_BITMAP_FLAG)
        val layered = opacity < 1f
        if (layered) canvas.saveLayerAlpha(null, (opacity * 255f + 0.5f).toInt())
        canvas.save()
        canvas.translate(-margin, -margin)
        canvas.scale(1f / deviceScale, 1f / deviceScale)
        canvas.drawBitmap(alpha, offset[0] + shadow.dx * deviceScale, offset[1] + shadow.dy * deviceScale, shadowPaint)
        canvas.drawBitmap(layer, 0f, 0f, layerPaint)
        canvas.restore()
        if (layered) canvas.restore()
        alpha.recycle()
        layer.recycle()
    }

    /** Standard clock hands map to a system clock view; a custom interval is played as rotated frames. */
    private fun isSupportedMotion(motion: JSONObject): Boolean = when (motion.optString("kind")) {
        "swing" -> true
        "clock" -> motion.optString("type") in setOf("clockSecond", "clockMinute", "clockMiniute", "clockHour", "clock")
        else -> false
    }

    /** Draws [node] at rest (no animation transform) into a square bitmap centred on its anchor. */
    private fun recordMotion(node: DomNode, motion: JSONObject, parentWidth: Float, parentHeight: Float, inherited: TextContext, toWidget: Matrix): Boolean {
        val style = node.style
        val x = Css.length(style["left"], parentWidth) ?: 0f
        val y = Css.length(style["top"], parentHeight) ?: 0f
        val width = Css.length(style["width"], parentWidth) ?: parentWidth
        val height = Css.length(style["height"], parentHeight) ?: parentHeight
        if (width <= 0f || height <= 0f) return false
        val origin = style["transformOrigin"]?.split(' ')
        val clock = motion.optString("kind") == "clock"
        val anchorX = if (clock) Css.length(origin?.getOrNull(0), width) ?: (width / 2f) else width / 2f
        val anchorY = if (clock) Css.length(origin?.getOrNull(1), height) ?: (height / 2f) else height / 2f
        // A rotating view needs room for every angle; a swinging one only for itself.
        val corners = listOf(0f to 0f, width to 0f, 0f to height, width to height)
        val reach = if (clock) corners.maxOf { (cx, cy) -> kotlin.math.hypot(cx - anchorX, cy - anchorY) } else max(width, height) / 2f
        val side = reach * 2f + 4f
        val pixels = ceil(side * pixelScale).toInt()
        if (pixels <= 0 || pixels > 1024) return false
        val bitmap = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888)
        val layer = Canvas(bitmap)
        layer.scale(pixelScale, pixelScale)
        layer.translate(side / 2f - anchorX, side / 2f - anchorY)
        // Tap targets inside a moving view are not tracked; the view is drawn only.
        val saved = ArrayList(hitRegions)
        val opacity = style["opacity"]?.toFloatOrNull()?.coerceIn(0f, 1f) ?: 1f
        if (opacity < 1f) layer.saveLayerAlpha(null, (opacity * 255f + 0.5f).toInt())
        content(layer, node, RectF(0f, 0f, width, height), inherited, Matrix())
        hitRegions.clear(); hitRegions.addAll(saved)
        val point = floatArrayOf(x + anchorX, y + anchorY)
        toWidget.mapPoints(point)
        motionSlots += MotionSlot(motion, android.graphics.PointF(point[0], point[1]), bitmap, side)
        return true
    }

    private fun content(canvas: Canvas, node: DomNode, bounds: RectF, inherited: TextContext, toWidget: Matrix) {
        val style = node.style
        val width = bounds.width()
        val height = bounds.height()
        val radius = radius(style["borderRadius"], width, height)
        val outline = outline(style, bounds, radius)

        // An outer shadow lies under the box; an inset one is drawn over its background.
        val boxShadow = Css.boxShadow(style["boxShadow"])
        if (boxShadow != null && !boxShadow.inset) boxShadow(canvas, boxShadow, bounds, radius)
        background(canvas, style, bounds, outline)
        if (boxShadow != null && boxShadow.inset) boxShadow(canvas, boxShadow, bounds, radius)
        if (style["border"]?.contains("dashed") == true) {
            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.style = Paint.Style.STROKE; strokeWidth = 1f
                color = Css.color(style["border"]!!.substringAfter("dashed").trim()) ?: Color.GRAY
                pathEffect = DashPathEffect(floatArrayOf(3f, 3f), 0f)
            }
            canvas.drawRect(0.5f, 0.5f, width - 0.5f, height - 0.5f, stroke)
        }

        node.dataset["swInteraction"]?.let { text ->
            val mapped = RectF(bounds)
            toWidget.mapRect(mapped)
            runCatching { JSONObject(text) }.getOrNull()?.let { hitRegions += HitRegion(mapped, it) }
        }

        val clips = style["overflow"] == "hidden" || style["clipPath"] != null
        if (clips) { canvas.save(); canvas.clipPath(outline) }

        val context = textContext(style, inherited)
        val previousDate = activeDate
        node.dataset["swDate"]?.let { description ->
            val parsed = runCatching { JSONObject(description) }.getOrNull()
            val style = parsed?.optString("style")
            // A clock view shows the current time, so only a <date> of "now" may use it.
            if (parsed != null && style in liveDateStyles && (style != "time" || parsed.optBoolean("live"))) activeDate = parsed
        }
        val date = activeDate
        if (date != null && style.containsKey("fontSize")) {
            // The text element of a live <date>: the host places a clock or timer here.
            val mapped = RectF(bounds)
            toWidget.mapRect(mapped)
            val color = node.children.firstOrNull { it.text != null }?.style?.get("color")?.let { Css.color(it) } ?: context.color
            dateSlots += DateSlot(mapped, date, context.style(), color, context.align)
            activeDate = previousDate
            if (clips) canvas.restore()
            return
        }
        if (node.tag == "img") {
            val source = node.attributes["src"].orEmpty()
            if (liveGifs && source.startsWith("res:") && source.endsWith(".gif", ignoreCase = true) && node.style["objectFit"] == "contain") {
                val mapped = RectF(bounds)
                toWidget.mapRect(mapped)
                gifSlots += GifSlot(mapped, source)
            } else image(canvas, node, bounds)
        } else if (node.text != null && node.children.isEmpty()) drawText(canvas, node.text, style, bounds, context)
        for (child in node.children) element(canvas, child, width, height, context, toWidget)
        activeDate = previousDate
        if (clips) canvas.restore()
    }

    private fun textContext(style: Map<String, String>, inherited: TextContext): TextContext {
        if (!style.containsKey("fontFamily") && !style.containsKey("fontSize") && !style.containsKey("fontWeight") && !style.containsKey("lineHeight") &&
            !style.containsKey("textAlign") && !style.containsKey("whiteSpace") && !style.containsKey("color")) return inherited
        return TextContext(
            family = style["fontFamily"] ?: inherited.family,
            size = Css.pixels(style["fontSize"]) ?: inherited.size,
            weight = style["fontWeight"]?.toIntOrNull() ?: inherited.weight,
            lineHeight = Css.pixels(style["lineHeight"]) ?: inherited.lineHeight,
            align = style["textAlign"] ?: inherited.align,
            wrap = style["whiteSpace"]?.let { it != "pre" } ?: inherited.wrap,
            color = style["color"]?.let { if (it == "transparent") Color.TRANSPARENT else Css.color(it) } ?: inherited.color,
        )
    }

    private fun drawText(canvas: Canvas, content: String, style: Map<String, String>, bounds: RectF, context: TextContext) {
        if (content.isEmpty()) return
        val textStyle = context.style()
        val paint = text.paint(textStyle)
        val gradient = if (style["backgroundClip"] == "text" || style["webkitBackgroundClip"] == "text") Css.gradient(style["backgroundImage"], bounds.width(), bounds.height()) else null
        if (gradient != null) { paint.color = Color.BLACK; paint.shader = gradient } else paint.color = context.color
        if (gradient == null && Color.alpha(context.color) == 0) return
        val lines = text.lines(content, textStyle, if (context.wrap) bounds.width() else null)
        val baseline = text.baseline(textStyle)
        for ((index, line) in lines.withIndex()) {
            val x = when (context.align) {
                "center" -> (bounds.width() - line.width) / 2f
                "right" -> bounds.width() - line.width
                else -> 0f
            }
            canvas.drawText(line.text, x, baseline + index * textStyle.leading, paint)
        }
    }

    private fun image(canvas: Canvas, node: DomNode, bounds: RectF) {
        val source = node.attributes["src"] ?: return
        val scale = FloatArray(9).also { canvas.matrix.getValues(it) }[Matrix.MSCALE_X].let { if (it > 0f) it else 1f }
        val pixels = (bounds.width() * scale * bounds.height() * scale).toInt().coerceAtLeast(1)
        val bitmap = images.bitmap(source, pixels) ?: return
        val destination = RectF(bounds)
        val fit = node.style["objectFit"] ?: "fill"
        if (fit == "contain" || fit == "cover") {
            val ratio = bitmap.width.toFloat() / max(1, bitmap.height)
            val boxRatio = bounds.width() / max(0.0001f, bounds.height())
            val fitWidth = if ((fit == "contain") == (ratio > boxRatio)) bounds.width() else bounds.height() * ratio
            val fitHeight = fitWidth / ratio
            destination.set((bounds.width() - fitWidth) / 2f, (bounds.height() - fitHeight) / 2f, (bounds.width() + fitWidth) / 2f, (bounds.height() + fitHeight) / 2f)
        }
        canvas.save()
        canvas.clipRect(bounds)
        canvas.drawBitmap(bitmap, null, destination, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        canvas.restore()
    }

    private fun background(canvas: Canvas, style: Map<String, String>, bounds: RectF, outline: Path) {
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        val color = Css.color(style["backgroundColor"])
        if (color != null && Color.alpha(color) != 0) {
            fill.color = color
            canvas.drawPath(outline, fill)
        }
        val image = style["backgroundImage"]
        if (image != null && image != "none" && style["backgroundClip"] != "text" && style["webkitBackgroundClip"] != "text") {
            // Shapes paint a gradient sized for the whole view behind a smaller outline.
            val size = style["backgroundSize"]?.split(' ')?.mapNotNull { Css.pixels(it) }
            val position = style["backgroundPosition"]?.split(' ')?.mapNotNull { Css.pixels(it) }
            val width = size?.getOrNull(0) ?: bounds.width()
            val height = size?.getOrNull(1) ?: bounds.height()
            val shader = Css.gradient(image, width, height)
            if (shader != null) {
                if (position != null && position.size == 2) shader.setLocalMatrix(Matrix().apply { val existing = Matrix(); shader.getLocalMatrix(existing); set(existing); postTranslate(position[0], position[1]) })
                fill.color = Color.BLACK
                fill.shader = shader
                canvas.drawPath(outline, fill)
            } else Css.color(image)?.let { solid -> fill.shader = null; fill.color = solid; canvas.drawPath(outline, fill) }
        }
    }

    private fun boxShadow(canvas: Canvas, shadow: Css.BoxShadow, bounds: RectF, radius: Float) {
        if (shadow.inset) {
            // `inset 0 0 0 <spread> color` is the renderer's one-point inner border.
            val width = if (shadow.spread > 0f) shadow.spread else 1f
            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = width; color = shadow.color }
            val inset = width / 2f
            canvas.drawRoundRect(RectF(inset, inset, bounds.width() - inset, bounds.height() - inset), max(0f, radius - inset), max(0f, radius - inset), stroke)
            return
        }
        // Outer shadow under an opaque shape: draw the shape with a shadow layer first.
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = shadow.color; maskFilter = if (shadow.blur > 0f) BlurMaskFilter(shadow.blur / 2f + 0.1f, BlurMaskFilter.Blur.NORMAL) else null }
        canvas.save()
        canvas.translate(shadow.dx, shadow.dy)
        canvas.drawRoundRect(bounds, radius, radius, paint)
        canvas.restore()
    }

    private fun radius(value: String?, width: Float, height: Float): Float {
        val text = value?.trim() ?: return 0f
        if (text.endsWith("%")) return min(width, height) * (text.removeSuffix("%").toFloatOrNull() ?: 0f) / 100f
        return min(Css.pixels(text) ?: 0f, min(width, height) / 2f).coerceAtLeast(0f)
    }

    private fun outline(style: Map<String, String>, bounds: RectF, radius: Float): Path {
        val path = Path()
        val clip = style["clipPath"]
        when {
            clip != null && clip.startsWith("circle") -> path.addCircle(bounds.centerX(), bounds.centerY(), min(bounds.width(), bounds.height()) / 2f, Path.Direction.CW)
            clip != null && clip.startsWith("ellipse") -> path.addOval(bounds, Path.Direction.CW)
            clip != null && clip.startsWith("inset") -> { val round = min(bounds.width(), bounds.height()) / 2f; path.addRoundRect(bounds, round, round, Path.Direction.CW) }
            style["borderRadius"]?.trim()?.endsWith("%") == true -> path.addOval(bounds, Path.Direction.CW)
            radius > 0f -> path.addRoundRect(bounds, radius, radius, Path.Direction.CW)
            else -> path.addRect(bounds, Path.Direction.CW)
        }
        return path
    }

    /** CSS transform list with its transform-origin, as a matrix in element coordinates. */
    private fun transform(style: Map<String, String>, width: Float, height: Float): Matrix? {
        val value = style["transform"] ?: return null
        val origin = style["transformOrigin"]?.split(' ')
        val originX = Css.length(origin?.getOrNull(0), width) ?: (width / 2f)
        val originY = Css.length(origin?.getOrNull(1), height) ?: (height / 2f)
        val matrix = Matrix()
        var perspective = 0f
        for (match in Regex("([a-zA-Z0-9]+)\\(([^)]*)\\)").findAll(value)) {
            val arguments = match.groupValues[2].split(',').map { it.trim() }
            val step = Matrix()
            when (match.groupValues[1]) {
                "rotate" -> step.setRotate(arguments[0].removeSuffix("deg").toFloatOrNull() ?: 0f)
                "translateX" -> step.setTranslate(Css.pixels(arguments[0]) ?: 0f, 0f)
                "translateY" -> step.setTranslate(0f, Css.pixels(arguments[0]) ?: 0f)
                "translate" -> step.setTranslate(Css.pixels(arguments[0]) ?: 0f, Css.pixels(arguments.getOrNull(1)) ?: 0f)
                "scale" -> { val sx = arguments[0].toFloatOrNull() ?: 1f; step.setScale(sx, arguments.getOrNull(1)?.toFloatOrNull() ?: sx) }
                "perspective" -> { perspective = Css.pixels(arguments[0]) ?: 0f; continue }
                "rotate3d" -> {
                    if (arguments.size < 4) continue
                    val axisX = arguments[0].toFloatOrNull() ?: 0f
                    val axisY = arguments[1].toFloatOrNull() ?: 0f
                    val axisZ = arguments[2].toFloatOrNull() ?: 0f
                    val degrees = arguments[3].removeSuffix("deg").toFloatOrNull() ?: 0f
                    val length = kotlin.math.sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ)
                    if (length == 0f) continue
                    val camera = Camera()
                    // Camera uses a 72-per-inch unit for its distance; CSS perspective is in pixels.
                    if (perspective > 0f) camera.setLocation(0f, 0f, -perspective / 72f)
                    // Camera rotates about fixed axes; apply the dominant-axis decomposition.
                    camera.rotateX(-degrees * axisX / length)
                    camera.rotateY(degrees * axisY / length)
                    camera.rotateZ(-degrees * axisZ / length)
                    camera.getMatrix(step)
                }
                else -> continue
            }
            matrix.preConcat(step)
        }
        matrix.preTranslate(-originX, -originY)
        matrix.postTranslate(originX, originY)
        return matrix
    }

    private companion object { const val MAXIMUM_MOTION_SLOTS = 8 }

    @Suppress("unused") private val unusedFilter = PorterDuffColorFilter(Color.BLACK, PorterDuff.Mode.SRC_IN)
}
