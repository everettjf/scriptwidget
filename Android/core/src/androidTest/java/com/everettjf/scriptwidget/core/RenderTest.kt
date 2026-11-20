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

    private fun listTree(rows: Int): String {
        val items = (1..rows).joinToString(",") {
            "{\"\$element\":\"toggle\",\"props\":{\"stateKey\":\"check.$it\",\"on\":false},\"children\":[{\"\$element\":\"text\",\"props\":{\"color\":\"material.primary\"},\"children\":[\"Row $it\"]}]}"
        }
        return "{\"\$element\":\"vstack\",\"props\":{\"frame\":\"max\",\"alignment\":\"leading\",\"background\":\"material.surface\"},\"children\":[" +
            "{\"\$element\":\"text\",\"props\":null,\"children\":[\"Header\"]},{\"\$element\":\"list\",\"props\":{\"spacing\":\"2\"},\"children\":[$items]}]}"
    }

    private val testColors = JSONObject("{\"light\":{\"primary\":[255,0,0,1],\"surface\":[0,0,255,1]},\"dark\":{\"primary\":[0,255,0,1],\"surface\":[10,20,30,1]}}")

    /** A scrolling list leaves its rows out of the widget bitmap and hands them over as pieces with their own tap targets. */
    @Test fun aListIsDrawnAsPiecesWithTapTargets() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val renderer = WidgetRenderer(context, SharedScripts(context))
        val output = renderer.render(RenderRequest(listTree(40), 338f, 300f, 2f, family = "large", liveLists = true, colors = testColors))
        assertEquals(1, output.listSlots.size)
        val slot = output.listSlots[0]
        assertTrue("the list fills the widget below the header: ${slot.bounds}", slot.bounds.width() > 300f && slot.bounds.height() > 200f && slot.bounds.bottom <= 300.5f)
        assertTrue("several rows share a piece: ${slot.pieces.size}", slot.pieces.size in 2..20)
        assertEquals(false, slot.truncated)
        // Every row keeps its tap target, inside the piece that shows it.
        val hits = slot.pieces.flatMap { piece -> piece.hitRegions.map { piece to it } }
        assertEquals(40, hits.size)
        assertEquals((1..40).map { "check.$it" }, hits.map { it.second.interaction.getString("stateKey") })
        for ((piece, hit) in hits) assertTrue("${hit.bounds} in ${piece.heightPoints}", hit.bounds.top >= -0.5f && hit.bounds.bottom <= piece.heightPoints + 0.5f)
        // The pieces together are as tall as the rows, far more than the visible part.
        assertTrue(slot.pieces.sumOf { it.heightPoints.toDouble() } > slot.bounds.height() * 2)
        // Each piece is a PNG at the list's width that shows the row text in the theme color.
        var red = 0
        for (piece in slot.pieces) {
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(piece.png, 0, piece.png.size)
            assertEquals(kotlin.math.ceil(slot.bounds.width() * output.scale).toInt(), bitmap.width)
            assertEquals(kotlin.math.ceil(piece.heightPoints * output.scale).toInt(), bitmap.height)
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            red += pixels.count { it == 0xFFFF0000.toInt() }
        }
        assertTrue("row text uses material.primary: $red", red > 1000)
        // The rows are not in the widget bitmap, and none of their taps are in the widget's own list.
        assertEquals(0, output.hitRegions.size)
        // The background is the theme surface color.
        assertEquals(0xFF0000FF.toInt(), output.bitmap.getPixel(4, output.bitmap.height - 4))
        // Drawing the same list again reuses the pieces byte for byte.
        val again = renderer.render(RenderRequest(listTree(40), 338f, 300f, 2f, family = "large", liveLists = true, colors = testColors))
        assertTrue(slot.pieces.indices.all { slot.pieces[it].png.contentEquals(again.listSlots[0].pieces[it].png) })
    }

    /** Without a host that scrolls, the list is drawn in place and only the visible rows can be tapped. */
    @Test fun aListDrawnInPlaceKeepsOnlyVisibleTapTargets() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val renderer = WidgetRenderer(context, SharedScripts(context))
        val output = renderer.render(RenderRequest(listTree(40), 338f, 300f, 2f, family = "large", colors = testColors))
        assertEquals(0, output.listSlots.size)
        assertTrue("visible rows only: ${output.hitRegions.size}", output.hitRegions.size in 3..15)
        for (hit in output.hitRegions) assertTrue("${hit.bounds}", hit.bounds.top >= 0f && hit.bounds.bottom <= 300.5f)
        // The rows are part of the bitmap now.
        val pixels = IntArray(output.bitmap.width * output.bitmap.height)
        output.bitmap.getPixels(pixels, 0, output.bitmap.width, 0, 0, output.bitmap.width, output.bitmap.height)
        assertTrue(pixels.count { it == 0xFFFF0000.toInt() } > 500)
    }

    /** The dark bitmap takes the dark palette, and without a palette the names are unknown, as on iPhone. */
    @Test fun themeColorsFollowTheAppearanceAndAreFixedWithoutAPalette() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val renderer = WidgetRenderer(context, SharedScripts(context))
        val dark = renderer.render(RenderRequest(listTree(3), 200f, 200f, 1f, darkMode = true, colors = testColors))
        assertEquals(0xFF0A141E.toInt(), dark.bitmap.getPixel(2, 198))
        val plain = renderer.render(RenderRequest(listTree(3), 200f, 200f, 1f))
        // Without a palette the names give the fixed Material 3 baseline: its light surface.
        assertEquals(0xFFFEF7FF.toInt(), plain.bitmap.getPixel(2, 198))
        // A malformed role does not fail the render; it takes the fixed color.
        val broken = renderer.render(RenderRequest(listTree(3), 200f, 200f, 1f, colors = JSONObject("{\"light\":{\"surface\":\"red\",\"primary\":[1,2]}}")))
        assertEquals(0xFFFEF7FF.toInt(), broken.bitmap.getPixel(2, 198))
        // The device's own palette has the roles scripts are told about.
        val palette = com.everettjf.scriptwidget.core.api.ThemeColors.palette(context)
        for (mode in listOf("light", "dark")) for (role in listOf("primary", "onPrimary", "primaryContainer", "surface", "onSurface", "surfaceContainer", "outline")) {
            val color = palette.getJSONObject(mode).getJSONArray(role)
            assertEquals("$mode.$role", 4, color.length())
            assertTrue((0..2).all { color.getDouble(it) in 0.0..255.0 } && color.getDouble(3) in 0.0..1.0)
        }
    }
}
