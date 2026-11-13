package com.everettjf.scriptwidget.core

import android.system.Os
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.IntlBridge
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import com.everettjf.scriptwidget.core.runtime.PackageCompiler
import com.everettjf.scriptwidget.core.runtime.RuntimeError
import com.everettjf.scriptwidget.core.runtime.ScriptExecutor
import com.everettjf.scriptwidget.core.runtime.SharedScripts
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Runs every bundled package that needs no live data through QuickJS and
 * compares the canonical element tree with the one JavaScriptCore produced
 * (Web/preview-engine/test/parity/native-trees.json).
 */
@RunWith(AndroidJUnit4::class)
class ParityTest {
    @Test fun bundledPackagesProduceTheSameTreesAsJavaScriptCore() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val corpus = JSONObject(instrumentation.context.assets.open("parity-corpus.json").use { it.readBytes().toString(Charsets.UTF_8) })
        val zone = corpus.getString("timeZone")
        Os.setenv("TZ", zone, true)
        java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone(zone))
        IntlBridge.timeZoneOverride = zone
        IntlBridge.localeOverride = corpus.optString("locale", "en-US")

        val scripts = SharedScripts(instrumentation.targetContext)
        val compiler = PackageCompiler(scripts)
        val executor = ScriptExecutor(scripts)
        val prelude = corpus.getString("prelude")
        val packages = corpus.getJSONArray("corpus")
        val failures = ArrayList<String>()
        var compileMilliseconds = 0L
        var executeMilliseconds = 0L
        var slowest = 0L

        for (index in 0 until packages.length()) {
            val item = packages.getJSONObject(index)
            val name = item.getString("name")
            val text = HashMap<String, String>()
            item.getJSONObject("files").let { files -> files.keys().forEach { text[it] = files.getString(it) } }
            val binaries = HashMap<String, ByteArray>()
            item.optJSONArray("binaries")?.let { array -> for (position in 0 until array.length()) binaries[array.getString(position)] = ByteArray(0) }
            val files = MemoryPackageFiles(text, binaries)
            val expected = item.optJSONObject("expected")
            val expectedTree = expected?.optString("tree")?.takeIf { expected.has("tree") }

            val compileStart = System.nanoTime()
            val prepared = try {
                compiler.prepare(files, prelude = prelude)
            } catch (error: RuntimeError) {
                failures += "$name: prepare failed [${error.kind}] ${error.message.take(300)}"
                continue
            }
            compileMilliseconds += (System.nanoTime() - compileStart) / 1_000_000
            val result = executor.execute(ExecutionRequest(prepared, files))
            executeMilliseconds += result.elapsedMilliseconds
            slowest = maxOf(slowest, result.elapsedMilliseconds)

            if (expectedTree == null) { failures += "$name: no native reference tree"; continue }
            if (result.tree != expectedTree) {
                val actual = result.tree
                failures += if (actual == null) "$name: error [${result.error?.kind}] ${result.error?.message?.take(400)}"
                else {
                    val at = actual.zip(expectedTree).indexOfFirst { (a, b) -> a != b }.let { if (it < 0) minOf(actual.length, expectedTree.length) else it }
                    "$name: tree differs at $at\n      native : ${expectedTree.substring(maxOf(0, at - 60), minOf(expectedTree.length, at + 100))}\n      android: ${actual.substring(maxOf(0, at - 60), minOf(actual.length, at + 100))}"
                }
            }
        }
        val total = packages.length()
        val summary = "parity ${total - failures.size}/$total; compile ${compileMilliseconds} ms total; execute ${executeMilliseconds} ms total, slowest ${slowest} ms"
        Log.i("ScriptWidgetParity", summary)
        failures.forEach { Log.w("ScriptWidgetParity", it) }
        assertTrue("corpus is empty", total > 0)
        assertEquals("$summary\n" + failures.joinToString("\n"), 0, failures.size)
    }
}
