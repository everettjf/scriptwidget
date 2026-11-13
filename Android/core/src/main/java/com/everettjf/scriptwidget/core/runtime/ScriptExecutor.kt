package com.everettjf.scriptwidget.core.runtime

import com.everettjf.scriptwidget.core.js.JsException
import com.everettjf.scriptwidget.core.js.JsHost
import com.everettjf.scriptwidget.core.js.JsThread
import com.everettjf.scriptwidget.core.js.QuickJs
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Everything one execution may touch. */
class ExecutionRequest(
    val prepared: PreparedPackage,
    val files: PackageFiles,
    val environments: Map<String, String> = mapOf("widget-size" to "medium", "widget-param" to ""),
    val darkMode: Boolean = false,
    val device: JSONObject? = null,
    val system: JSONObject? = null,
    /** Preview simulations for the shared kernel; production executions leave this empty. */
    val fixtures: JSONObject = JSONObject(),
    val modules: List<NativeModule> = emptyList(),
    val timeoutMilliseconds: Long = 5000,
    /** Package identity for storage namespaces and diagnostics. */
    val packageID: String = "",
) {
    /** Budgets and cancellation shared by every native call of this execution. */
    val session = ExecutionSession()
}

class ExecutionSession {
    val networkRequests = java.util.concurrent.atomic.AtomicInteger(0)
    val dataQueries = java.util.concurrent.atomic.AtomicInteger(0)
    /** Set when the execution ended; in-flight native work should stop. */
    @Volatile var finished: Boolean = false
}

class ExecutionError(val kind: String, val message: String)

class LogEntry(val level: String, val message: String)

class ExecutionResult(
    /** Canonical tree JSON (see `encodeElement` in the shared kernel), or null on error. */
    val tree: String?,
    val error: ExecutionError?,
    val logs: List<LogEntry>,
    val diagnostics: JSONArray,
    val elapsedMilliseconds: Long,
)

/**
 * A group of native operations exposed to package code through the host
 * bridge. Policy (manifest permissions, budgets) is enforced here and in the
 * JavaScript installers, never by trusting package code.
 */
interface NativeModule {
    fun handles(operation: String): Boolean
    /** Script globals this module implements, such as `$location`; others report "not supported on Android". */
    val apis: Set<String> get() = emptySet()
    /** Synchronous operation. Returns JSON text or null. */
    fun call(request: ExecutionRequest, operation: String, payload: String?): String? =
        throw IllegalArgumentException("Unsupported operation $operation")
    /** Asynchronous operation. Call [done] exactly once from any thread. */
    fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        done(false, JSONObject.quote("Unsupported operation $operation"))
    }
}

/** Runs one prepared package in a fresh QuickJS context and returns its element tree. */
class ScriptExecutor(private val scripts: SharedScripts) {
    private class Completion(val id: Int, val ok: Boolean, val json: String?)

    fun execute(request: ExecutionRequest): ExecutionResult {
        val started = System.nanoTime()
        val result = JsThread.run { run(request) }
        return ExecutionResult(result.tree, result.error, result.logs, result.diagnostics, (System.nanoTime() - started) / 1_000_000)
    }

    private fun run(request: ExecutionRequest): ExecutionResult {
        val completions = LinkedBlockingQueue<Completion>()
        val nativeLogs = ArrayList<LogEntry>()
        var finished: String? = null
        var cancelled = false

        val host = JsHost { operation, payload ->
            when {
                operation == "finish" -> { finished = payload; null }
                operation == "package.import" -> compiledImport(request, payload)
                operation == "package.read" -> PackagePaths.normalize(payload)?.let { request.files.readText(it) }
                operation == "package.exists" -> if (PackagePaths.normalize(payload)?.let { request.files.exists(it) } == true) "1" else "0"
                operation == "support.script" -> scripts.supportScript(payload.orEmpty())
                operation == "xml.parse" -> XmlBridge.parse(payload.orEmpty())
                operation == "log.log" || operation == "log.error" -> {
                    if (nativeLogs.size < 500) nativeLogs += LogEntry(operation.removePrefix("log."), payload.orEmpty())
                    null
                }
                operation == "async.start" -> {
                    val job = JSONObject(payload!!)
                    val id = job.getInt("id")
                    val name = job.getString("operation")
                    val module = request.modules.firstOrNull { it.handles(name) }
                    if (module == null) completions += Completion(id, false, JSONObject.quote("Unsupported operation $name"))
                    else {
                        var delivered = false
                        module.start(request, name, job.optJSONObject("payload")) { ok, json ->
                            synchronized(completions) {
                                if (!delivered && !cancelled) { delivered = true; completions += Completion(id, ok, json) }
                            }
                        }
                    }
                    null
                }
                IntlBridge.handles(operation) -> IntlBridge.call(operation, payload)
                else -> (request.modules.firstOrNull { it.handles(operation) }
                    ?: throw IllegalArgumentException("Unsupported operation $operation")).call(request, operation, payload)
            }
        }

        val token = "__sw_" + ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val deadline = System.nanoTime() + request.timeoutMilliseconds * 1_000_000
        val engine = QuickJs(host)
        try {
            // The interrupt deadline is a backstop for synchronous loops; the
            // kernel's own timeout reports unresolved asynchronous work first.
            engine.setDeadline(request.timeoutMilliseconds + INTERRUPT_GRACE_MILLISECONDS)
            for (name in scripts.hostFiles) engine.evaluate(scripts.text(name), name)
            engine.evaluate(scripts.text("kernel.js"), "kernel.js")
            val job = JSONObject()
                .put("config", configuration(request).toString())
                .put("code", request.prepared.code)
                .put("timeoutMilliseconds", request.timeoutMilliseconds)
                .put("supportedAPIs", JSONArray(request.modules.flatMap { it.apis }.distinct()))
            engine.call("__swBoot", token, job.toString())

            while (finished == null) {
                engine.runJobs()
                if (finished != null) break
                if (engine.call(token, "pump") == "1") continue
                val remaining = deadline - System.nanoTime()
                val completion = if (remaining > 0) completions.poll(remaining, TimeUnit.NANOSECONDS) else null
                if (completion == null) {
                    engine.call(token, "timeout")
                    engine.runJobs()
                    if (finished == null) finished = failure("resourceLimit", "Script exceeded the 5-second execution limit")
                } else {
                    engine.call(token, "resolve", completion.id.toString(), if (completion.ok) "1" else "0", completion.json)
                }
            }
        } catch (error: JsException) {
            if (finished == null) {
                finished = if (error.interrupted) failure("resourceLimit", "Script exceeded the 5-second execution limit")
                else if (error.message.orEmpty().contains("out of memory", ignoreCase = true)) failure("resourceLimit", "Script exceeded the runtime memory budget")
                else failure("internalError", error.message ?: "Execution failed")
            }
        } finally {
            synchronized(completions) { cancelled = true }
            request.session.finished = true
            engine.close()
        }
        return decode(finished!!, nativeLogs)
    }

    private fun compiledImport(request: ExecutionRequest, relativePath: String?): String? {
        val path = PackagePaths.normalize(relativePath) ?: return null
        if (!request.files.exists(path) || request.files.readText(path) == null) return null
        return request.prepared.imports[path] ?: """{"ok":false,"kind":"transformError","message":"Not a script file"}"""
    }

    private fun configuration(request: ExecutionRequest): JSONObject {
        val prepared = request.prepared
        val environments = JSONObject()
        for ((key, value) in prepared.timelineEnvironment) environments.put(key, value)
        for ((key, value) in request.environments) environments.put(key, value)
        if (prepared.actionID != null) {
            if (!request.environments.containsKey("action-id")) environments.put("action-id", prepared.actionID)
            environments.put("widget-size", "action")
        }
        val config = JSONObject()
            .put("contract", scripts.contract)
            .put("environments", environments)
            .put("actionID", prepared.actionID ?: JSONObject.NULL)
            .put("liveActivityPresentation", request.environments["widget-size"] in setOf("live-activity", "dynamic-island"))
            .put("preview", JSONObject().put("appearance", if (request.darkMode) "dark" else "light"))
            .put("fixtures", request.fixtures)
            .put("manifest", prepared.manifest ?: JSONObject.NULL)
            .put("hasManifest", prepared.hasManifest)
            .put("packageID", request.packageID)
        request.device?.let { config.put("device", it) }
        request.system?.let { config.put("system", it) }
        return config
    }

    private fun failure(kind: String, message: String): String = JSONObject()
        .put("tree", JSONObject.NULL)
        .put("error", JSONObject().put("kind", kind).put("message", message))
        .put("logs", JSONArray()).put("diagnostics", JSONArray()).toString()

    private fun decode(resultText: String, nativeLogs: List<LogEntry>): ExecutionResult {
        val json = JSONObject(resultText)
        val error = json.optJSONObject("error")?.let { ExecutionError(it.optString("kind", "internalError"), it.optString("message")) }
        val logs = json.optJSONArray("logs")?.let { array ->
            List(array.length()) { index -> array.getJSONObject(index).let { LogEntry(it.optString("level"), it.optString("message")) } }
        }?.takeIf { it.isNotEmpty() } ?: nativeLogs
        return ExecutionResult(
            tree = if (json.isNull("tree")) null else json.getString("tree"),
            error = error,
            logs = logs,
            diagnostics = json.optJSONArray("diagnostics") ?: JSONArray(),
            elapsedMilliseconds = 0,
        )
    }

    companion object {
        private const val INTERRUPT_GRACE_MILLISECONDS = 400L
    }
}
