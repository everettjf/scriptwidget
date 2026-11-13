package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import com.everettjf.scriptwidget.core.runtime.PreparedPackage
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.URI
import java.util.concurrent.Executor

class DataSourceModuleTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var store: PluginStore
    private val plugin = PluginFixtures.manifest()

    private class Call(val method: String, val uri: URI, val headers: Map<String, String>, val body: ByteArray?, val timeout: Int)

    /** Offline transport: records each call and answers with [respond]. */
    private class FakeTransport(var respond: (Call, (URI) -> Boolean) -> FetchModule.Response = { _, _ -> FetchModule.Response(200, "{\"ok\":true}".toByteArray(), emptyMap()) }) : DataSourceTransport {
        val calls = ArrayList<Call>()
        override fun perform(method: String, uri: URI, headers: Map<String, String>, body: ByteArray?, timeoutMilliseconds: Int, allowRedirect: (URI) -> Boolean): FetchModule.Response {
            val call = Call(method, uri, headers, body, timeoutMilliseconds)
            calls.add(call)
            return respond(call, allowRedirect)
        }
    }

    private class Outcome(val ok: Boolean, val json: String?) {
        /** The decoded rejection message or resolved value. */
        val value: Any? get() = json?.let { JSONTokener(it).nextValue() }
    }

    private val transport = FakeTransport()
    private val direct = Executor { it.run() }

    @Before
    fun setUp() {
        store = PluginStore(File(temporary.root, "Plugins"))
        store.install(PluginFixtures.json().inputStream())
    }

    private fun widgetManifest(
        plugins: List<String>? = listOf(PluginFixtures.ID),
        permissions: List<String> = listOf("network"),
        domains: List<String>? = listOf("api.example.com"),
    ): JSONObject {
        val manifest = JSONObject().put("formatVersion", 2).put("permissions", JSONArray(permissions))
        if (plugins != null) manifest.put("plugins", JSONArray(plugins))
        if (domains != null) manifest.put("networkDomains", JSONArray(domains))
        return manifest
    }

    private fun execution(manifest: JSONObject? = widgetManifest(), hasManifest: Boolean = true, environments: Map<String, String> = mapOf("widget-size" to "medium"),
                          timeline: Map<String, String> = emptyMap()): ExecutionRequest =
        ExecutionRequest(PreparedPackage("", emptyMap(), manifest, hasManifest, null, timeline), MemoryPackageFiles(emptyMap()), environments = environments)

    private fun payload(pluginID: String = PluginFixtures.ID, operationID: String = "status", parameters: JSONObject? = JSONObject()): JSONObject {
        val job = JSONObject().put("pluginID", pluginID).put("operationID", operationID)
        if (parameters != null) job.put("parameters", parameters)
        return job
    }

    private fun run(request: ExecutionRequest = execution(), payload: JSONObject? = payload(), module: DataSourceModule = DataSourceModule(store, transport, direct)): Outcome {
        val outcomes = ArrayList<Outcome>()
        module.start(request, DataSourceModule.OPERATION, payload) { ok, json -> outcomes.add(Outcome(ok, json)) }
        assertEquals("done must be called exactly once", 1, outcomes.size)
        return outcomes[0]
    }

    private fun assertRejected(expected: String, outcome: Outcome) {
        assertFalse(outcome.ok)
        assertEquals(expected, outcome.value)
        assertEquals("a rejected request must not reach the network", 0, transport.calls.size)
    }

    @Test
    fun exposesTheDataSourceGlobalAndOperation() {
        val module = DataSourceModule(store, transport, direct)
        assertEquals(setOf("\$dataSource"), module.apis)
        assertTrue(module.handles("datasource.request"))
        assertFalse(module.handles("http.request"))
    }

    @Test
    fun resolvesJsonAndTextResponses() {
        transport.respond = { _, _ -> FetchModule.Response(200, "plain text".toByteArray(), emptyMap()) }
        val text = run()
        assertTrue(text.ok)
        assertEquals("plain text", text.value)
        assertEquals("https://api.example.com/status", transport.calls[0].uri.toString())
        assertEquals("GET", transport.calls[0].method)
        assertEquals(DataSourceModule.TIMEOUT_MILLISECONDS, transport.calls[0].timeout)

        transport.respond = { _, _ -> FetchModule.Response(200, "{\"name\":\"Ada\",\"tags\":[1,2]}".toByteArray(), emptyMap()) }
        val parameters = JSONObject().put("user", "ada l").put("X-Token", "t").put("enabled", true).put("undeclared", "x")
        val json = run(payload = payload(operationID = "update", parameters = parameters))
        assertTrue(json.ok)
        assertEquals("Ada", (json.value as JSONObject).getString("name"))
        val call = transport.calls[1]
        assertEquals("https://api.example.com/users/ada%20l?page=1", call.uri.toString())
        assertEquals("POST", call.method)
        assertEquals("t", call.headers["X-Token"])
        assertEquals("{\"enabled\":true}", String(call.body!!))
    }

    @Test
    fun builtInPluginsWorkWhenDeclared() {
        val id = "app.scriptwidget.datasource.github"
        val outcome = run(execution(widgetManifest(plugins = listOf(id), domains = listOf("api.github.com"))), payload(id, "repository", null))
        assertTrue(outcome.ok)
        assertEquals("https://api.github.com/repos/everettjf/scriptwidget", transport.calls[0].uri.toString())
    }

    @Test
    fun undeclaredPluginIsRejected() {
        val message = "Plugin ${PluginFixtures.ID} is not declared in widget.json"
        assertRejected(message, run(execution(widgetManifest(plugins = listOf("dev.scriptwidget.other")))))
        assertRejected(message, run(execution(widgetManifest(plugins = null))))
        assertRejected(message, run(execution(widgetManifest(plugins = emptyList()))))
        // A legacy package has no manifest and therefore declares nothing, even if stale manifest data is present.
        assertRejected(message, run(execution(manifest = null, hasManifest = false)))
        assertRejected(message, run(execution(manifest = widgetManifest(), hasManifest = false)))
        // Installing a plugin grants nothing: the built-in is installed but not declared.
        assertRejected("Plugin app.scriptwidget.datasource.github is not declared in widget.json", run(payload = payload("app.scriptwidget.datasource.github", "repository")))
    }

    @Test
    fun missingNetworkPermissionIsRejected() {
        assertRejected("Plugin requests require the network permission", run(execution(widgetManifest(permissions = emptyList()))))
        assertRejected("Plugin requests require the network permission", run(execution(widgetManifest(permissions = listOf("location")))))
    }

    @Test
    fun hostMissingFromNetworkDomainsIsRejected() {
        val message = "Data source host is not declared in widget.json networkDomains."
        assertRejected(message, run(execution(widgetManifest(domains = listOf("other.example.com")))))
        assertRejected(message, run(execution(widgetManifest(domains = emptyList()))))
        assertRejected(message, run(execution(widgetManifest(domains = null))))
        assertRejected(message, run(execution(widgetManifest(domains = listOf("*.api.example.com")))))
        assertTrue(run(execution(widgetManifest(domains = listOf("*.example.com")))).ok)
    }

    @Test
    fun hostMissingFromPluginHostsIsRejected() {
        val request = execution(widgetManifest(domains = listOf("api.example.com", "evil.example.net")))
        assertEquals("Plugin request escaped its declared hosts.", DataSourcePolicy.destinationError(request, plugin, URI("https://evil.example.net/status")))
        assertNull(DataSourcePolicy.destinationError(request, plugin, URI("https://api.example.com/status")))
        // The package allows the host, the plugin does not declare it: a tampered manifest is still refused.
        assertEquals("Plugin request escaped its declared hosts.", PluginFixtures.failure {
            DataSourceRequestBuilder.prepare(plugin.copy(baseURL = "https://evil.example.net"), "status", emptyMap())
        }.message)
    }

    @Test
    fun httpAndPrivateDestinationsAreRejected() {
        val request = execution(widgetManifest(domains = listOf("api.example.com", "localhost", "10.0.0.1")))
        assertEquals("Data source requests require HTTPS", DataSourcePolicy.destinationError(request, plugin, URI("http://api.example.com/status")))
        assertEquals("Data source requests require HTTPS", DataSourcePolicy.destinationError(request, plugin, URI("ftp://api.example.com/status")))
        assertEquals("URL credentials are not allowed", DataSourcePolicy.destinationError(request, plugin, URI("https://user:pw@api.example.com/status")))
        val local = plugin.copy(hosts = listOf("api.example.com", "localhost", "10.0.0.1"))
        assertEquals("Local and private network hosts are not allowed", DataSourcePolicy.destinationError(request, local, URI("https://localhost/status")))
        assertEquals("Local and private network hosts are not allowed", DataSourcePolicy.destinationError(request, local, URI("https://10.0.0.1/status")))
        assertEquals("URL host is required", DataSourcePolicy.destinationError(request, plugin, URI("https:///status")))
    }

    @Test
    fun timelineProjectionsAndLiveActivitiesAreRejected() {
        val timeline = "[timeline_read_only] Future entries cannot make live service requests"
        assertRejected(timeline, run(execution(environments = mapOf("widget-size" to "medium", "timeline-is-projection" to "true"))))
        assertRejected(timeline, run(execution(timeline = mapOf("timeline-is-projection" to "true"))))
        val live = "[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app"
        assertRejected(live, run(execution(environments = mapOf("widget-size" to "live-activity"))))
        assertRejected(live, run(execution(environments = mapOf("widget-size" to "dynamic-island"))))
        assertTrue(run(execution(environments = mapOf("widget-size" to "medium", "timeline-is-projection" to "false"))).ok)
    }

    @Test
    fun finishedExecutionIsRejected() {
        val request = execution()
        request.session.finished = true
        assertRejected("Execution session is no longer active", run(request))
    }

    @Test
    fun requestBudgetIsSharedWithFetch() {
        val request = execution()
        repeat(FetchModule.MAXIMUM_REQUESTS) { assertTrue(run(request).ok) }
        val outcome = run(request)
        assertFalse(outcome.ok)
        assertEquals("Network request budget exceeded", outcome.value)
        assertEquals(FetchModule.MAXIMUM_REQUESTS, transport.calls.size)

        // Requests made by fetch count against the same budget.
        val shared = execution()
        shared.session.networkRequests.set(FetchModule.MAXIMUM_REQUESTS)
        assertEquals("Network request budget exceeded", run(shared).value)
        assertEquals(FetchModule.MAXIMUM_REQUESTS, transport.calls.size)
    }

    @Test
    fun rejectedRequestsDoNotConsumeTheBudget() {
        val request = execution()
        run(request, payload(operationID = "missing"))
        run(request, payload(operationID = "update"))
        run(request, payload(pluginID = "dev.scriptwidget.other"))
        assertEquals(0, request.session.networkRequests.get())
    }

    @Test
    fun redirectsAreRestrictedToDeclaredHttpsHosts() {
        val request = execution(widgetManifest(domains = listOf("*.example.com", "evil.example.net")))
        val decisions = LinkedHashMap<String, Boolean>()
        transport.respond = { _, allowRedirect ->
            for (target in listOf("https://api.example.com/moved", "https://evil.example.net/x", "https://cdn.example.com/x", "http://api.example.com/moved", "https://localhost/x", "https://user@api.example.com/x")) {
                decisions[target] = allowRedirect(URI(target))
            }
            if (!allowRedirect(URI("https://evil.example.net/x"))) throw FetchModule.FetchException("Redirect target is not allowed")
            FetchModule.Response(200, "{}".toByteArray(), emptyMap())
        }
        val outcome = run(request)
        assertFalse(outcome.ok)
        assertEquals("Redirect target is not allowed", outcome.value)
        assertEquals(mapOf(
            "https://api.example.com/moved" to true,
            "https://evil.example.net/x" to false,   // allowed by the package, not declared by the plugin
            "https://cdn.example.com/x" to false,    // allowed by the package wildcard, not declared by the plugin
            "http://api.example.com/moved" to false, // downgrade
            "https://localhost/x" to false,
            "https://user@api.example.com/x" to false,
        ), decisions)

        // A host the plugin declares but the package does not allow is refused as well.
        val wide = plugin.copy(hosts = listOf("api.example.com", "cdn.example.org"))
        val narrow = execution(widgetManifest(domains = listOf("api.example.com")))
        assertFalse(DataSourcePolicy.allowsRedirect(narrow, wide, URI("https://cdn.example.org/x")))
        assertTrue(DataSourcePolicy.allowsRedirect(narrow, wide, URI("https://api.example.com/x")))
        narrow.session.finished = true
        assertFalse(DataSourcePolicy.allowsRedirect(narrow, wide, URI("https://api.example.com/x")))
    }

    @Test
    fun uninstalledPluginAndBadRequestsAreRejected() {
        val other = "dev.scriptwidget.other"
        assertRejected("Plugin $other is not installed", run(execution(widgetManifest(plugins = listOf(other))), payload(other)))
        assertRejected("Operation missing was not found in ${PluginFixtures.ID}.", run(payload = payload(operationID = "missing")))
        assertRejected("Missing required parameter user.", run(payload = payload(operationID = "update")))
        assertRejected("Data source requests need a plugin id and an operation id", run(payload = JSONObject().put("pluginID", 7).put("operationID", "status")))
        assertRejected("Data source requests need a plugin id and an operation id", run(payload = null))
        val outcomes = ArrayList<String?>()
        DataSourceModule(store, transport, direct).start(execution(), "datasource.other", payload()) { _, json -> outcomes.add(json) }
        assertEquals(listOf<String?>("\"Unsupported operation datasource.other\""), outcomes)
    }

    @Test
    fun responseFailuresUseTheSwiftMessages() {
        transport.respond = { _, _ -> FetchModule.Response(500, "{\"secret\":\"body\"}".toByteArray(), emptyMap()) }
        assertEquals("Data source request failed", run().value)
        transport.respond = { _, _ -> FetchModule.Response(200, byteArrayOf(0xFF.toByte()), emptyMap()) }
        assertEquals("Data source returned non-UTF-8 text", run().value)
        transport.respond = { _, _ -> FetchModule.Response(200, "<html>".toByteArray(), emptyMap()) }
        assertEquals("Data source returned invalid JSON", run(payload = payload(operationID = "update", parameters = JSONObject().put("user", "u").put("X-Token", "t").put("enabled", 1))).value)
        transport.respond = { _, _ -> FetchModule.Response(200, ByteArray(FetchModule.MAXIMUM_RESPONSE_BYTES + 1), emptyMap()) }
        assertEquals("Data source response exceeds 2 MiB.", run().value)
        transport.respond = { _, _ -> throw FetchModule.FetchException("Local and private network hosts are not allowed") }
        assertEquals("Local and private network hosts are not allowed", run().value)
        // Unexpected exception text may quote the URL and its parameter values; it is not forwarded.
        transport.respond = { call, _ -> throw java.io.IOException("failed to connect to ${call.uri}?token=secret") }
        assertEquals("Data source request failed", run().value)
    }

    @Test
    fun resultsAreDroppedAfterTheExecutionEnds() {
        val request = execution()
        transport.respond = { _, _ -> request.session.finished = true; FetchModule.Response(200, "ok".toByteArray(), emptyMap()) }
        val outcomes = ArrayList<Boolean>()
        DataSourceModule(store, transport, direct).start(request, DataSourceModule.OPERATION, payload()) { ok, _ -> outcomes.add(ok) }
        assertEquals(emptyList<Boolean>(), outcomes)
    }
}
