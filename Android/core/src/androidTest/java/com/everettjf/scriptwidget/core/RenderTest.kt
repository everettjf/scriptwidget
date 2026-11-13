package com.everettjf.scriptwidget.core

import android.graphics.Bitmap
import android.system.Os
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.render.RenderRequest
import com.everettjf.scriptwidget.core.render.WidgetRenderer
import com.everettjf.scriptwidget.core.runtime.IntlBridge
import com.everettjf.scriptwidget.core.runtime.SharedScripts
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Renders every corpus tree to a bitmap. Fails on layout or paint errors and
 * on blank output; the PNGs are saved for visual review.
 */
@RunWith(AndroidJUnit4::class)
class RenderTest {
    @Test fun corpusTreesRenderToBitmaps() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val corpus = JSONObject(instrumentation.context.assets.open("parity-corpus.json").use { it.readBytes().toString(Charsets.UTF_8) })
        Os.setenv("TZ", corpus.getString("timeZone"), true)
        IntlBridge.timeZoneOverride = corpus.getString("timeZone")
        IntlBridge.localeOverride = "en-US"
        val renderer = WidgetRenderer(context, SharedScripts(context))
        val directory = File(context.getExternalFilesDir(null), "render").apply { deleteRecursively(); mkdirs() }
        val packages = corpus.getJSONArray("corpus")
        val failures = ArrayList<String>()
        var layout = 0L
        var paint = 0L
        var slowest = 0L
        for (index in 0 until packages.length()) {
            val item = packages.getJSONObject(index)
            val name = item.getString("name")
            val tree = item.getJSONObject("expected").getString("tree")
            try {
                val output = renderer.render(RenderRequest(tree, 338f, 158f, 2.625f, family = "medium", nowMilliseconds = 1767268800000))
                layout += output.layoutMilliseconds
                paint += output.paintMilliseconds
                slowest = maxOf(slowest, output.layoutMilliseconds + output.paintMilliseconds)
                val pixels = IntArray(output.bitmap.width * output.bitmap.height)
                output.bitmap.getPixels(pixels, 0, output.bitmap.width, 0, 0, output.bitmap.width, output.bitmap.height)
                if (pixels.all { it == pixels[0] } && !tree.contains("\"children\":[]}") ) failures += "$name: bitmap is a single flat color"
                File(directory, name.replace('/', '_').replace(' ', '_') + ".png").outputStream().use { output.bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                output.bitmap.recycle()
            } catch (error: Throwable) {
                failures += "$name: ${error.message?.take(500)}"
            }
        }
        val summary = "rendered ${packages.length() - failures.size}/${packages.length()}; layout $layout ms, paint $paint ms, slowest $slowest ms; ${directory.absolutePath}"
        Log.i("ScriptWidgetRender", summary)
        assertTrue(packages.length() > 0)
        assertEquals("$summary\n" + failures.joinToString("\n"), 0, failures.size)
    }
}
