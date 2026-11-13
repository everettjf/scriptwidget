package com.everettjf.scriptwidget.core.render

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.util.Base64
import com.everettjf.scriptwidget.core.js.JsHost
import com.everettjf.scriptwidget.core.js.QuickJs
import com.everettjf.scriptwidget.core.runtime.IntlBridge
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import com.everettjf.scriptwidget.core.runtime.SharedScripts
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.sqrt

/** What to draw and at what size. Lengths are in points (dp). */
class RenderRequest(
    val tree: String,
    val width: Float,
    val height: Float,
    /** Pixels per point. */
    val density: Float,
    val family: String = "medium",
    val darkMode: Boolean = false,
    val files: PackageFiles? = null,
    /** Remote image URLs that were fetched under the package's network policy, with their files. */
    val remoteImages: Map<String, File> = emptyMap(),
    /** Fixed clock for deterministic output; null uses the real clock. */
    val nowMilliseconds: Long? = null,
    /** Bitmap budget in bytes for this render; the output is scaled down to fit. */
    val maximumBitmapBytes: Long = Long.MAX_VALUE,
    /** `<date>` styles left out of the bitmap because the host shows them with self-updating views. */
    val liveDateStyles: Set<String> = emptySet(),
    /** Leave `<gif>` out of the bitmap; the host plays it (see [RenderOutput.gifSlots]). */
    val liveGifs: Boolean = false,
)

class RenderOutput(
    val bitmap: Bitmap,
    /** Pixels per point actually used (lower than requested when the budget forced a smaller bitmap). */
    val scale: Float,
    val hitRegions: List<HitRegion>,
    val dateSlots: List<DateSlot>,
    val gifSlots: List<GifSlot>,
    val diagnostics: JSONArray,
    val layoutMilliseconds: Long,
    val paintMilliseconds: Long,
)

/** Decodes package, inline and fetched images for one render. */
class PackageImageSource(private val files: PackageFiles?, private val remote: Map<String, File>) : ImageSource {
    private val cache = HashMap<String, Bitmap?>()

    private fun bytes(source: String): ByteArray? = when {
        source.startsWith("res:") -> files?.readBytes(source.removePrefix("res:"))
        source.startsWith("data:") -> runCatching { Base64.decode(source.substringAfter("base64,"), Base64.DEFAULT) }.getOrNull()
        else -> remote[source]?.takeIf { it.isFile && it.length() <= MAXIMUM_IMAGE_BYTES }?.readBytes()
    }

    /** Natural size in pixels, or null when the source cannot be decoded. */
    fun size(source: String): IntArray? {
        val data = bytes(source) ?: return null
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, options)
        return if (options.outWidth > 0 && options.outHeight > 0) intArrayOf(options.outWidth, options.outHeight) else null
    }

    override fun bitmap(source: String, maximumPixels: Int): Bitmap? = cache.getOrPut("$source@$maximumPixels") {
        val data = bytes(source) ?: return@getOrPut null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@getOrPut null
        var sample = 1
        // Decode no more than about four times the pixels that will be shown.
        while ((bounds.outWidth / (sample * 2)).toLong() * (bounds.outHeight / (sample * 2)) >= maximumPixels.toLong()) sample *= 2
        runCatching { BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) }.getOrNull()
    }

    private companion object { const val MAXIMUM_IMAGE_BYTES = 16L * 1024 * 1024 }
}

/**
 * Turns a canonical element tree into a bitmap. Layout runs in the shared
 * web renderer inside a long-lived QuickJS context (trusted code only); the
 * recorded elements are painted with [DomPainter].
 */
class WidgetRenderer(context: Context, private val scripts: SharedScripts, val fonts: FontRegistry = FontRegistry(context)) {
    private val text = TextEngine(fonts)
    private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(null, runnable, "scriptwidget-render", 8L * 1024 * 1024) }
    private var engine: QuickJs? = null
    private var images: PackageImageSource? = null

    private val host = JsHost { operation, payload ->
        when (operation) {
            "text.measure" -> measure(JSONObject(payload!!))
            "text.baseline" -> text.baseline(style(JSONObject(payload!!))).toString()
            "image.size" -> images?.size(payload.orEmpty())?.let { "[${it[0]},${it[1]}]" } ?: "null"
            else -> IntlBridge.call(operation, payload)
        }
    }

    private fun style(json: JSONObject) = TextStyle(json.optString("family"), json.optDouble("size", 17.0).toFloat(), json.optInt("weight", 400), json.optDouble("leading", 20.0).toFloat())

    private fun measure(json: JSONObject): String {
        val width = if (json.isNull("width")) null else json.optDouble("width").toFloat()
        val lines = text.lines(json.optString("text"), style(json), width)
        return "{\"width\":${lines.maxOfOrNull { it.width } ?: 0f},\"lines\":${max(1, lines.size)}}"
    }

    private fun engine(): QuickJs = engine ?: QuickJs(host, memoryLimitBytes = 96L * 1024 * 1024, stackBytes = 6L * 1024 * 1024).also { created ->
        try {
            // Keep the native entry point for the trusted render bundle before the host file removes it.
            created.evaluate("globalThis.__swRenderNative = globalThis.__swNative;", "render-prelude.js")
            created.evaluate(scripts.text("android-host.js"), "android-host.js")
            created.evaluate(scripts.text("render.js"), "render.js")
            created.evaluate(
                "globalThis.__swRenderStart = function (request) { globalThis.__swRenderResult = null; globalThis.__swRenderError = null;" +
                    " __swRenderBundle.render(globalThis.__swRenderNative, request).then(function (value) { globalThis.__swRenderResult = value; }," +
                    " function (error) { globalThis.__swRenderError = String(error && error.stack ? error.stack : error); }); };" +
                    " globalThis.__swRenderTake = function (name) { var value = globalThis[name]; globalThis[name] = null; return value; };",
                "render-driver.js",
            )
            engine = created
        } catch (error: Throwable) {
            created.close()
            throw error
        }
    }

    fun render(request: RenderRequest): RenderOutput = executor.submit(Callable { renderOnThread(request) }).let { future ->
        try { future.get() } catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
    }

    private fun renderOnThread(request: RenderRequest): RenderOutput {
        val layoutStart = System.nanoTime()
        val source = PackageImageSource(request.files, request.remoteImages)
        images = source
        val resources = JSONObject()
        request.files?.paths()?.forEach { path -> if (imageFile.containsMatchIn(path)) resources.put(path, "res:$path") }
        val job = JSONObject()
            .put("tree", request.tree).put("width", request.width.toDouble()).put("height", request.height.toDouble())
            .put("family", request.family).put("dark", request.darkMode).put("resources", resources)
            .put("images", JSONArray(request.remoteImages.keys.toList()))
        request.nowMilliseconds?.let { job.put("now", it) }

        val js = engine()
        val rendered: JSONObject
        try {
            js.setDeadline(LAYOUT_TIMEOUT_MILLISECONDS)
            js.call("__swRenderStart", job.toString())
            js.runJobs()
            val failure = js.call("__swRenderTake", "__swRenderError")
            if (failure != null) throw IllegalStateException("Layout failed: $failure")
            rendered = JSONObject(js.call("__swRenderTake", "__swRenderResult") ?: throw IllegalStateException("Layout did not finish"))
        } catch (error: Throwable) {
            // A failed or interrupted context may hold partial state; start fresh next time.
            engine?.close()
            engine = null
            throw error
        } finally {
            engine?.setDeadline(0)
        }
        val layoutMilliseconds = (System.nanoTime() - layoutStart) / 1_000_000

        val paintStart = System.nanoTime()
        var scale = request.density
        val bytesAtRequestedScale = ceil(request.width * scale).toLong() * ceil(request.height * scale).toLong() * 4L
        if (bytesAtRequestedScale > request.maximumBitmapBytes) scale *= sqrt(request.maximumBitmapBytes.toDouble() / bytesAtRequestedScale).toFloat()
        val bitmap = Bitmap.createBitmap(max(1, ceil(request.width * scale).toInt()), max(1, ceil(request.height * scale).toInt()), Bitmap.Config.ARGB_8888)
        val painter = DomPainter(text, source, request.liveDateStyles, request.liveGifs)
        painter.paint(Canvas(bitmap), DomNode(rendered.getJSONObject("root")), scale)
        images = null
        return RenderOutput(bitmap, scale, painter.hitRegions.toList(), painter.dateSlots.toList(), painter.gifSlots.toList(), rendered.optJSONArray("diagnostics") ?: JSONArray(),
            layoutMilliseconds, (System.nanoTime() - paintStart) / 1_000_000)
    }

    /** Frees the layout context; the next render recreates it. */
    fun release() { executor.submit { engine?.close(); engine = null } }

    private companion object {
        const val LAYOUT_TIMEOUT_MILLISECONDS = 8000L
        val imageFile = Regex("\\.(png|jpe?g|webp|gif|heic|bmp)$", RegexOption.IGNORE_CASE)
    }
}
