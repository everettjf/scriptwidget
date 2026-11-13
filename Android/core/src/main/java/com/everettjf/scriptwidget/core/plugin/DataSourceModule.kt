package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.api.RuntimePolicy
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Performs one HTTP exchange for a plugin request. Production uses [FetchModule.perform], which
 * resolves every hop and refuses private addresses; tests inject a fake so they stay offline.
 * [allowRedirect] must be consulted for every redirect target before it is followed.
 */
fun interface DataSourceTransport {
    fun perform(method: String, uri: URI, headers: Map<String, String>, body: ByteArray?, timeoutMilliseconds: Int, allowRedirect: (URI) -> Boolean): FetchModule.Response
}

/**
 * The rules of `$dataSource.request`, as pure functions of the execution and the plugin. Each
 * returns the rejection message (the Swift wording) or null when the rule is satisfied. They are
 * evaluated in Kotlin for every request; the JavaScript installer is not a security boundary.
 */
object DataSourcePolicy {
    const val SESSION_ENDED = "Execution session is no longer active"
    const val LIVE_ACTIVITY = "[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app"
    const val TIMELINE = "[timeline_read_only] Future entries cannot make live service requests"
    const val NETWORK_PERMISSION = "Plugin requests require the network permission"
    const val HTTPS_ONLY = "Data source requests require HTTPS"
    const val PLUGIN_HOST = "Plugin request escaped its declared hosts."
    const val PACKAGE_HOST = "Data source host is not declared in widget.json networkDomains."
    const val BUDGET = "Network request budget exceeded"

    /**
     * Presentation rules: a finished execution gets nothing; Live Activity presentations and
     * future timeline entries are rendered ahead of time and must not make live requests.
     */
    fun presentationError(request: ExecutionRequest): String? = when {
        request.session.finished -> SESSION_ENDED
        RuntimePolicy.isLiveActivity(request) -> LIVE_ACTIVITY
        RuntimePolicy.isTimelineProjection(request) -> TIMELINE
        else -> null
    }

    /**
     * Declaration rules: the package's validated `widget.json` must list [pluginID] in `plugins`
     * and hold the `network` permission. A package without a manifest declares nothing, so it is
     * refused: installing a plugin never grants a widget anything by itself.
     */
    fun declarationError(request: ExecutionRequest, pluginID: String): String? {
        val manifest = if (request.prepared.hasManifest) request.prepared.manifest else null
        val plugins = manifest?.optJSONArray("plugins")
        val declared = plugins != null && (0 until plugins.length()).any { plugins.opt(it) == pluginID }
        if (!declared) return "Plugin $pluginID is not declared in widget.json"
        return if (RuntimePolicy.hasPermission(request, "network")) null else NETWORK_PERMISSION
    }

    /**
     * Destination rules for the initial URL and for every redirect target: HTTPS only, a public
     * host name without credentials, a host the plugin declares, and a host the package allows
     * through `network` + `networkDomains`. A plugin therefore never enlarges what the package
     * may reach, and a package never reaches a host the plugin did not declare.
     */
    fun destinationError(request: ExecutionRequest, plugin: PluginManifest, uri: URI): String? {
        if (uri.scheme?.lowercase() != "https") return HTTPS_ONLY
        validationError(uri)?.let { return it }
        val host = uri.host.lowercase()
        if (!RuntimePolicy.hostMatches(host, plugin.hosts)) return PLUGIN_HOST
        if (!request.prepared.hasManifest || !RuntimePolicy.packageAllowsHost(request, host)) return PACKAGE_HOST
        return null
    }

    /** True when a redirect to [uri] may be followed; the execution must still be running. */
    fun allowsRedirect(request: ExecutionRequest, plugin: PluginManifest, uri: URI): Boolean =
        !request.session.finished && destinationError(request, plugin, uri) == null

    /** Same textual rule as `FetchModule.validationError`: HTTP(S), a host, no credentials, not local or private. */
    private fun validationError(uri: URI): String? {
        val host = uri.host?.lowercase()?.removePrefix("[")?.removeSuffix("]")
        if (host.isNullOrEmpty()) return "URL host is required"
        if (uri.userInfo != null) return "URL credentials are not allowed"
        return if (RuntimePolicy.blockedHostName(host)) "Local and private network hosts are not allowed" else null
    }
}

/**
 * `$dataSource.request(pluginID, operationID, parameters)`, ported from
 * `ScriptWidgetRuntimeDataSource`. Handles the asynchronous operation `datasource.request` with
 * payload `{pluginID, operationID, parameters}` and resolves with the mapped response.
 *
 * Every rule of [DataSourcePolicy] is checked here, in this order, with the Swift error strings:
 * execution still active, not a Live Activity, not a timeline projection, plugin declared in
 * `widget.json`, `network` permission, plugin installed and valid, request built only from
 * declared parameters, HTTPS destination inside both the plugin's hosts and the package's
 * `networkDomains`, and the per-execution network budget shared with `fetch`. Redirects are
 * re-validated against the same destination rules. Errors never contain response content,
 * header values or parameter values.
 */
class DataSourceModule(
    private val store: PluginStore,
    private val transport: DataSourceTransport = DataSourceTransport { method, uri, headers, body, timeout, allowRedirect ->
        sharedFetch.perform(method, uri, headers, body, timeout, allowRedirect)
    },
    private val executor: Executor = sharedPool,
) : NativeModule {
    override val apis: Set<String> = setOf("\$dataSource")

    override fun handles(operation: String): Boolean = operation == OPERATION

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val fail = { message: String -> done(false, JSONObject.quote(message)) }
        if (operation != OPERATION) return fail("Unsupported operation $operation")
        DataSourcePolicy.presentationError(request)?.let { return fail(it) }
        val job = payload ?: JSONObject()
        val pluginID = job.opt("pluginID") as? String
        val operationID = job.opt("operationID") as? String
        if (pluginID == null || operationID == null) return fail("Data source requests need a plugin id and an operation id")
        DataSourcePolicy.declarationError(request, pluginID)?.let { return fail(it) }
        val parameters = job.optJSONObject("parameters")
        val values = HashMap<String, Any?>()
        parameters?.keys()?.forEach { values[it] = parameters.opt(it) }

        executor.execute {
            try {
                val plugin = store.manifest(pluginID) ?: throw PluginException(PluginException.Kind.NOT_FOUND, "Plugin $pluginID is not installed")
                val prepared = DataSourceRequestBuilder.prepare(plugin, operationID, values)
                DataSourcePolicy.destinationError(request, plugin, prepared.uri)?.let { throw PluginException(PluginException.Kind.PERMISSION, it) }
                if (request.session.finished || request.session.networkRequests.incrementAndGet() > FetchModule.MAXIMUM_REQUESTS) {
                    throw PluginException(PluginException.Kind.NETWORK, DataSourcePolicy.BUDGET)
                }
                val response = transport.perform(prepared.method, prepared.uri, prepared.headers, prepared.body, TIMEOUT_MILLISECONDS) { redirected ->
                    DataSourcePolicy.allowsRedirect(request, plugin, redirected)
                }
                if (request.session.finished) return@execute
                done(true, DataSourceResponseMapper.map(prepared.operation, response.status, response.body))
            } catch (error: PluginException) {
                fail(error.message)
            } catch (error: FetchModule.FetchException) {
                fail(error.message ?: "Data source request failed")
            } catch (error: Exception) {
                // Exception text from the network stack can quote the URL, which may carry parameter values.
                fail("Data source request failed")
            }
        }
    }

    companion object {
        const val OPERATION = "datasource.request"
        /** The Swift fetch session's per-request timeout (5 s); the 10 s total is enforced by the transport. */
        const val TIMEOUT_MILLISECONDS = 5_000

        private val sharedFetch by lazy { FetchModule() }
        private val sharedPool by lazy {
            Executors.newFixedThreadPool(FetchModule.MAXIMUM_CONCURRENT) { runnable -> Thread(runnable, "scriptwidget-datasource").apply { isDaemon = true } }
        }
    }
}
