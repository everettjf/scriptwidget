package com.everettjf.scriptwidget.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.api.DeviceInfo
import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.api.StorageModule
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.ExecutionResult
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import com.everettjf.scriptwidget.core.runtime.PackageCompiler
import com.everettjf.scriptwidget.core.runtime.ScriptExecutor
import com.everettjf.scriptwidget.core.runtime.SharedScripts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress

@RunWith(AndroidJUnit4::class)
class NativeApiTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val scripts = SharedScripts(context)
    private val compiler = PackageCompiler(scripts)
    private val executor = ScriptExecutor(scripts)
    private val storage = StorageModule(File(context.cacheDir, "storage-test"))

    @Before fun reset() { File(context.cacheDir, "storage-test").deleteRecursively() }

    private fun manifest(permissions: String, domains: String = "[]") = """{"entry":"main.jsx","formatVersion":2,"id":"com.example.test","name":"Test","networkDomains":$domains,"permissions":$permissions,"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"}"""

    /** Runs a script whose result is the text of the rendered <text>. */
    private fun run(source: String, manifest: String? = null, packageID: String = "pkg-a", fetch: FetchModule = FetchModule(), environments: Map<String, String> = mapOf("widget-size" to "small")): ExecutionResult {
        val files = MemoryPackageFiles(buildMap { put("main.jsx", source); if (manifest != null) put("widget.json", manifest) })
        val prepared = compiler.prepare(files)
        return executor.execute(ExecutionRequest(prepared, files, environments = environments, modules = listOf(storage, fetch), packageID = packageID,
            device = DeviceInfo.device(context), system = DeviceInfo.system(context)))
    }

    private fun text(result: ExecutionResult): String {
        assertNull("error: ${result.error?.kind} ${result.error?.message}", result.error)
        return Regex("\"children\":\\[\"(.*)\"\\]\\}$").find(result.tree!!)!!.groupValues[1]
    }

    @Test fun storagePersistsAcrossExecutionsAndIsPackageScoped() {
        assertEquals("true|", text(run("""const before = ${'$'}storage.getString("k"); const ok = ${'$'}storage.setString("k", "值 😀"); ${'$'}render(<text>{String(ok) + "|" + before}</text>)""")))
        assertEquals("值 😀", text(run("""${'$'}render(<text>{${'$'}storage.getString("k")}</text>)""")))
        assertEquals("", text(run("""${'$'}render(<text>{${'$'}storage.getString("k")}</text>)""", packageID = "pkg-b")))
    }

    @Test fun storageJsonAndCompareAndSet() {
        val script = """
            const a = ${'$'}storage.setJSON("j", {n: 1, list: [1, 2]});
            const cas1 = ${'$'}storage.compareAndSetJSON("j", {list: [1, 2], n: 1}, {n: 2});
            const cas2 = ${'$'}storage.compareAndSetJSON("j", {n: 1}, {n: 3});
            const cas3 = ${'$'}storage.compareAndSetString("s", "", "first");
            const cas4 = ${'$'}storage.compareAndSetString("s", "", "second");
            ${'$'}render(<text>{[a, cas1, cas2, cas3, cas4, ${'$'}storage.getJSON("j").n, ${'$'}storage.getString("s"), ${'$'}storage.keys().join(",")].join("|")}</text>)
        """
        assertEquals("true|true|false|true|false|2|first|j,s", text(run(script)))
    }

    @Test fun storageRejectsOversizedValuesAndEmptyKeys() {
        val script = """
            const big = "x".repeat(256 * 1024 + 1);
            ${'$'}render(<text>{[${'$'}storage.setString("k", big), ${'$'}storage.setString("", "v"), ${'$'}storage.setString("k", "x".repeat(1000))].join("|")}</text>)
        """
        assertEquals("false|false|true", text(run(script)))
    }

    @Test fun deviceAndSystemReportAndroid() {
        val value = text(run("""${'$'}render(<text>{[${'$'}system.platform(), typeof ${'$'}device.screen().width, ${'$'}device.model().length > 0].join("|")}</text>)"""))
        assertEquals("android|number|true", value)
    }

    @Test fun fetchRequiresDeclaredHost() {
        val script = """fetch("https://example.org/").then(v => ${'$'}render(<text>ok</text>), e => ${'$'}render(<text>{String(e)}</text>))"""
        assertEquals("Network host is not declared in widget.json", text(run(script, manifest("[\"network\"]", "[\"example.com\"]"))))
        assertEquals("Network host is not declared in widget.json", text(run(script, manifest("[]"))))
    }

    @Test fun fetchRejectsPrivateHostsByNameAndByResolvedAddress() {
        val byName = """fetch("http://192.168.1.1/").then(v => ${'$'}render(<text>ok</text>), e => ${'$'}render(<text>{String(e)}</text>))"""
        assertEquals("Local and private network hosts are not allowed", text(run(byName)))
        val rebinding = FetchModule(resolver = { listOf(InetAddress.getByAddress(byteArrayOf(10, 0, 0, 5))) })
        val byAddress = """fetch("https://public.example.com/").then(v => ${'$'}render(<text>ok</text>), e => ${'$'}render(<text>{String(e)}</text>))"""
        assertEquals("Local and private network hosts are not allowed", text(run(byAddress, fetch = rebinding)))
    }

    @Test fun fetchPolicyHoldsWhenBuiltInsAreTampered() {
        val script = """
            RegExp.prototype.exec = function () { return ["https://example.com", "https", "example.com"]; };
            String.prototype.startsWith = function () { return false; };
            Array.prototype.includes = function () { return true; };
            fetch("http://127.0.0.1:8080/").then(v => ${'$'}render(<text>ok</text>), e => ${'$'}render(<text>{String(e)}</text>))
        """
        assertEquals("Local and private network hosts are not allowed", text(run(script, manifest("[\"network\"]", "[\"example.com\"]"))))
    }

    @Test fun fetchIsReadOnlyInFutureTimelineEntries() {
        val script = """fetch("https://example.com/").then(v => ${'$'}render(<text>ok</text>), e => ${'$'}render(<text>{String(e).slice(0, 20)}</text>))"""
        assertEquals("[timeline_read_only]", text(run(script, environments = mapOf("widget-size" to "small", "timeline-is-projection" to "true"))))
    }

    @Test fun fetchReturnsBodiesAndMetadataFromThePublicInternet() {
        val script = """
            ${'$'}http.getResponse("https://example.com/").then(
              r => ${'$'}render(<text>{[r.status, r.body.includes("Example Domain"), typeof r.headers["content-type"]].join("|")}</text>),
              e => ${'$'}render(<text>{"error: " + String(e)}</text>))
        """
        val value = text(run(script, manifest("[\"network\"]", "[\"example.com\"]")))
        assertTrue(value, value == "200|true|string" || value.startsWith("error: "))
        assertEquals("needs network on the device: $value", "200|true|string", value)
    }

    @Test fun unresolvedPromisesEndAtTheExecutionLimit() {
        val files = MemoryPackageFiles(mapOf("main.jsx" to "const p = { then() {} }; await p; \$render(<text>never</text>)"))
        val prepared = compiler.prepare(files)
        val started = System.nanoTime()
        val result = executor.execute(ExecutionRequest(prepared, files, timeoutMilliseconds = 700))
        assertEquals("resourceLimit", result.error?.kind)
        assertTrue((System.nanoTime() - started) / 1_000_000 < 3000)
    }
}
