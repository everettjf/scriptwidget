package com.everettjf.scriptwidget.core.runtime

import com.everettjf.scriptwidget.core.js.JsException
import com.everettjf.scriptwidget.core.js.JsHost
import com.everettjf.scriptwidget.core.js.QuickJs
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class RuntimeError(val kind: String, override val message: String) : Exception(message)

/** Output of preparing a package: transpiled entry, transpiled imports and the validated manifest. */
class PreparedPackage(
    val code: String,
    val imports: Map<String, String>,
    val manifest: JSONObject?,
    val hasManifest: Boolean,
    val actionID: String?,
    val timelineEnvironment: Map<String, String>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("code", code)
        .put("imports", JSONObject(imports))
        .put("manifest", manifest ?: JSONObject.NULL)
        .put("hasManifest", hasManifest)
        .put("actionID", actionID ?: JSONObject.NULL)
        .put("timelineEnvironment", JSONObject(timelineEnvironment))

    companion object {
        fun fromJson(json: JSONObject): PreparedPackage {
            val imports = HashMap<String, String>()
            json.optJSONObject("imports")?.let { map -> map.keys().forEach { imports[it] = map.getString(it) } }
            val environment = HashMap<String, String>()
            json.optJSONObject("timelineEnvironment")?.let { map -> map.keys().forEach { environment[it] = map.optString(it) } }
            return PreparedPackage(
                code = json.getString("code"),
                imports = imports,
                manifest = json.optJSONObject("manifest"),
                hasManifest = json.optBoolean("hasManifest"),
                actionID = if (json.isNull("actionID")) null else json.optString("actionID"),
                timelineEnvironment = environment,
            )
        }
    }
}

/**
 * Validates manifests and transpiles JSX with the same Babel bundle and
 * prepare code as the web preview engine. The Babel context is expensive, so
 * it lives on one dedicated thread and is released after a period of disuse.
 * Package code never executes in this context.
 */
class PackageCompiler(private val scripts: SharedScripts) {
    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(null, runnable, "scriptwidget-compiler", 16L * 1024 * 1024)
    }
    private var engine: QuickJs? = null
    private var release: ScheduledFuture<*>? = null

    private fun <T> onCompilerThread(block: (QuickJs) -> T): T = executor.submit(Callable {
        release?.cancel(false)
        val current = engine ?: createEngine().also { engine = it }
        try {
            block(current)
        } finally {
            current.setDeadline(0)
            release = executor.schedule({ engine?.close(); engine = null }, IDLE_SECONDS, TimeUnit.SECONDS)
        }
    }).let { future ->
        try { future.get() } catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
    }

    private fun createEngine(): QuickJs {
        val host = JsHost { operation, payload -> if (operation == "url.parse") parseURL(payload.orEmpty()) else IntlBridge.call(operation, payload) }
        val created = QuickJs(host, memoryLimitBytes = 384L * 1024 * 1024, stackBytes = 12L * 1024 * 1024)
        try {
            // The prelude captures the native entry point before the host file removes it.
            created.evaluate(COMPILER_PRELUDE, "compiler-prelude.js")
            created.evaluate(scripts.text("android-host.js"), "android-host.js")
            for (name in listOf("core.js", "prepare.js", "android-compiler.js")) created.evaluate(scripts.text(name), name)
        } catch (error: Throwable) {
            created.close()
            throw error
        }
        return created
    }

    /** Validates and transpiles a package. Throws [RuntimeError] with the engine's error kind. */
    fun prepare(files: PackageFiles, entry: String? = null, prelude: String = "", actionID: String? = null, callFunction: String? = null): PreparedPackage {
        val text = JSONObject()
        val binaries = JSONArray()
        for (path in files.paths()) {
            val content = if (isTextFile(path)) files.readText(path) else null
            if (content != null) text.put(path, content) else binaries.put(path)
        }
        val job = JSONObject().put("files", text).put("binaries", binaries).put("prelude", prelude)
        if (entry != null) job.put("entry", entry)
        if (actionID != null) job.put("actionID", actionID)
        if (callFunction != null) job.put("callFunction", callFunction)
        val output = try {
            onCompilerThread { it.setDeadline(COMPILE_TIMEOUT_MILLISECONDS); it.call("__swPrepare", job.toString()) }
        } catch (error: JsException) {
            throw RuntimeError(if (error.interrupted) "resourceLimit" else "internalError", error.message ?: "Compiler failed")
        }
        val prepared = JSONObject(output ?: throw RuntimeError("internalError", "Compiler returned nothing"))
        if (!prepared.optBoolean("ok")) {
            val error = prepared.optJSONObject("error")
            throw RuntimeError(error?.optString("kind") ?: "internalError", error?.optString("message") ?: "Package could not be prepared")
        }
        return PreparedPackage.fromJson(prepared)
    }

    /** Returns {ok, manifest?, error?, issues[]} from the shared manifest validator. */
    fun validateManifest(manifestText: String, paths: List<String>): JSONObject =
        JSONObject(onCompilerThread { it.call("__swValidateManifest", manifestText, JSONArray(paths).toString()) }!!)

    /** Timeline plan for a `timeline` manifest object: {entries:[{date, environments}], reloadDate}. */
    fun timelinePlan(schedule: JSONObject, nowMilliseconds: Long, systemTimeZone: String): JSONObject =
        JSONObject(onCompilerThread { it.call("__swTimeline", schedule.toString(), nowMilliseconds.toString(), systemTimeZone) }!!)

    /** WHATWG-style components for the absolute URLs the manifest validator inspects, or null. */
    private fun parseURL(text: String): String? = try {
        val uri = java.net.URI(text.trim())
        val scheme = uri.scheme?.lowercase()
        if (scheme == null || uri.isOpaque || uri.host.isNullOrEmpty()) null
        else {
            val userInfo = uri.rawUserInfo.orEmpty()
            JSONObject()
                .put("href", uri.toString())
                .put("protocol", "$scheme:")
                .put("hostname", uri.host.lowercase().removePrefix("[").removeSuffix("]"))
                .put("port", if (uri.port >= 0) uri.port.toString() else "")
                .put("pathname", uri.rawPath?.ifEmpty { "/" } ?: "/")
                .put("search", uri.rawQuery?.let { "?$it" } ?: "")
                .put("hash", uri.rawFragment?.let { "#$it" } ?: "")
                .put("username", userInfo.substringBefore(':'))
                .put("password", userInfo.substringAfter(':', ""))
                .toString()
        }
    } catch (_: Exception) { null }

    companion object {
        /**
         * Globals the trusted compiler code expects. JavaScriptCore contexts
         * have a console object, and the shared manifest validator measures
         * UTF-8 lengths with TextEncoder. Package code never runs here.
         */
        private const val COMPILER_PRELUDE = """
            globalThis.console = { log() {}, info() {}, warn() {}, error() {}, debug() {}, trace() {} };
            {
              const native = globalThis.__swNative;
              globalThis.URL = class URL {
                constructor(text) {
                  const parsed = native("url.parse", String(text));
                  if (parsed === null) throw new TypeError("Invalid URL");
                  Object.assign(this, JSON.parse(parsed));
                }
                toString() { return this.href; }
              };
            }
            globalThis.TextEncoder = class TextEncoder {
              encode(text) {
                const bytes = [];
                for (const character of String(text ?? "")) {
                  const code = character.codePointAt(0);
                  if (code < 0x80) bytes.push(code);
                  else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
                  else if (code < 0x10000) {
                    const safe = code >= 0xd800 && code <= 0xdfff ? 0xfffd : code;
                    bytes.push(0xe0 | (safe >> 12), 0x80 | ((safe >> 6) & 63), 0x80 | (safe & 63));
                  } else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
                }
                return new Uint8Array(bytes);
              }
            };
        """
        private const val IDLE_SECONDS = 45L
        private const val COMPILE_TIMEOUT_MILLISECONDS = 30_000L
        private val textFile = Regex("\\.(jsx?|mjs|json|txt|md|csv|svg|xml|html?|css|ya?ml)$", RegexOption.IGNORE_CASE)
        fun isTextFile(path: String): Boolean = textFile.containsMatchIn(path)
    }
}
