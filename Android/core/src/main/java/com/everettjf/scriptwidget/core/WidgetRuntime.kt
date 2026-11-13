package com.everettjf.scriptwidget.core

import android.content.Context
import android.content.res.Configuration
import com.everettjf.scriptwidget.core.api.DeviceInfo
import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.api.RuntimePolicy
import com.everettjf.scriptwidget.core.api.StorageModule
import com.everettjf.scriptwidget.core.render.RenderOutput
import com.everettjf.scriptwidget.core.render.RenderRequest
import com.everettjf.scriptwidget.core.render.WidgetRenderer
import com.everettjf.scriptwidget.core.runtime.ExecutionError
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.ExecutionResult
import com.everettjf.scriptwidget.core.runtime.NativeModule
import com.everettjf.scriptwidget.core.runtime.PackageCompiler
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import com.everettjf.scriptwidget.core.runtime.PreparedPackage
import com.everettjf.scriptwidget.core.runtime.RuntimeError
import com.everettjf.scriptwidget.core.runtime.ScriptExecutor
import com.everettjf.scriptwidget.core.runtime.SharedScripts
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.security.MessageDigest

/** Everything needed to run one package once. */
class RunRequest(
    val files: PackageFiles,
    /** Stable identity of the installed package; namespaces storage and caches. */
    val packageID: String,
    val family: String = "medium",
    val parameter: String = "",
    val darkMode: Boolean = false,
    /** Declared action to run (`actions[].id`), or null to render. */
    val actionID: String? = null,
    /** Legacy `onClick="name"` function to call after the entry. */
    val callFunction: String? = null,
    val extraEnvironments: Map<String, String> = emptyMap(),
    /** Directory for the compiled-artifact cache; null disables caching. */
    val buildDirectory: File? = null,
)

class RunResult(
    val execution: ExecutionResult,
    val prepared: PreparedPackage?,
    val request: ExecutionRequest?,
    /** When the package's daily schedule next changes slot; the host should run the package again then. */
    val nextTimelineTransition: Long? = null,
) {
    /** True when the script's output may depend on the light/dark theme it ran under. */
    val dependsOnAppearance: Boolean get() = request?.session?.readAppearance == true
}

/**
 * The Android runtime: compiles a package, executes it, and renders its
 * tree. One instance per process; all methods are safe to call from any
 * background thread.
 */
class WidgetRuntime(context: Context, extraModules: List<NativeModule> = emptyList()) {
    private val appContext = context.applicationContext
    val scripts = SharedScripts(appContext)
    val compiler = PackageCompiler(scripts)
    val executor = ScriptExecutor(scripts)
    val renderer = WidgetRenderer(appContext, scripts)
    val timeline = com.everettjf.scriptwidget.core.runtime.TimelinePlanner(scripts)
    val storage = StorageModule(File(appContext.filesDir, "Storage"))
    val fetch = FetchModule()
    private val modules: List<NativeModule> = listOf(storage, fetch) + extraModules
    private val imageCache = File(appContext.cacheDir, "remote-images")

    /** Compiles a package, reusing the cached artifact when no source changed. */
    fun prepare(request: RunRequest): PreparedPackage {
        val key = cacheKey(request)
        val cacheFile = request.buildDirectory?.let { File(it, "prepared-$key.json") }
        if (cacheFile != null && cacheFile.isFile) {
            runCatching { PreparedPackage.fromJson(JSONObject(cacheFile.readText())) }.getOrNull()?.let { return it }
        }
        val prepared = compiler.prepare(request.files, actionID = request.actionID, callFunction = request.callFunction)
        if (cacheFile != null) runCatching {
            cacheFile.parentFile?.mkdirs()
            // Keep the cache small: one artifact per (source, action) pair, older ones removed.
            cacheFile.parentFile?.listFiles { file -> file.name.startsWith("prepared-") }?.sortedByDescending { it.lastModified() }?.drop(MAXIMUM_CACHED_ARTIFACTS - 1)?.forEach { it.delete() }
            val temporary = File(cacheFile.parentFile, cacheFile.name + ".tmp")
            temporary.writeText(prepared.toJson().toString())
            temporary.renameTo(cacheFile)
        }
        return prepared
    }

    private fun cacheKey(request: RunRequest): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(scripts.contract.optString("compilerFingerprint").toByteArray())
        digest.update((request.actionID ?: "").toByteArray()); digest.update(0)
        digest.update((request.callFunction ?: "").toByteArray()); digest.update(0)
        for (path in request.files.paths()) {
            digest.update(path.toByteArray()); digest.update(0)
            if (PackageCompiler.isTextFile(path)) request.files.readText(path)?.let { digest.update(it.toByteArray()) }
            digest.update(0)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }.take(32)
    }

    /** Compiles and executes. Compile failures are returned as an execution error, never thrown. */
    fun run(request: RunRequest): RunResult {
        val prepared = try {
            prepare(request)
        } catch (error: RuntimeError) {
            return RunResult(ExecutionResult(null, ExecutionError(error.kind, error.message), emptyList(), JSONArray(), 0), null, null)
        }
        val environments = HashMap<String, String>()
        environments["widget-size"] = request.family
        environments["widget-param"] = request.parameter
        environments["widget-rendering-mode"] = "fullColor"
        // The cached artifact carries the slot of the moment it was compiled; use the slot of now.
        val schedule = timeline.state(prepared.manifest)
        if (schedule != null) environments.putAll(schedule.environments)
        environments.putAll(request.extraEnvironments)
        val execution = ExecutionRequest(
            prepared = prepared, files = request.files, environments = environments, darkMode = request.darkMode,
            device = DeviceInfo.device(appContext), system = DeviceInfo.system(appContext),
            modules = modules, packageID = request.packageID,
        )
        return RunResult(executor.execute(execution), prepared, execution, schedule?.nextTimelineTransitionOrNull())
    }

    /**
     * Renders the result of [run]. Errors become a visible card so a widget
     * is never blank. Remote images are fetched first, under the same network
     * policy as `fetch`.
     */
    fun render(
        request: RunRequest, result: RunResult, width: Float, height: Float, density: Float, maximumBitmapBytes: Long = Long.MAX_VALUE,
        liveDateStyles: Set<String> = emptySet(), darkMode: Boolean = request.darkMode, liveGifs: Boolean = false,
    ): RenderOutput {
        val tree = result.execution.tree ?: errorTree(result.execution.error)
        val remote = if (result.execution.tree != null && result.request != null) fetchRemoteImages(tree, result.request) else emptyMap()
        return try {
            renderer.render(RenderRequest(tree, width, height, density, request.family, darkMode, request.files, remote, maximumBitmapBytes = maximumBitmapBytes, liveDateStyles = liveDateStyles, liveGifs = liveGifs))
        } catch (error: Throwable) {
            renderer.render(RenderRequest(errorTree(ExecutionError("internalError", error.message ?: "Rendering failed")), width, height, density, request.family, darkMode, maximumBitmapBytes = maximumBitmapBytes))
        }
    }

    fun isDarkMode(): Boolean = (appContext.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    /** A canonical tree that explains [error] with its category and recovery hint. */
    fun errorTree(error: ExecutionError?): String {
        val kind = error?.kind ?: "internalError"
        val category = scripts.errorCategories.optJSONObject(kind) ?: scripts.errorCategories.optJSONObject("internalError")
        val title = category?.optString("category") ?: "Internal"
        val recovery = category?.optString("recovery").orEmpty()
        fun text(value: String, props: String) = "{\"\$element\":\"text\",\"props\":$props,\"children\":[${JSONObject.quote(value)}]}"
        val children = listOf(
            text("$title error", "{\"color\":\"#b91c1c\",\"font\":\"caption\",\"fontWeight\":\"bold\"}"),
            // Fixed colors: the card keeps its light background in dark mode.
            text((error?.message ?: "Unknown error").take(400), "{\"color\":\"#1f2937\",\"font\":\"caption\"}"),
            text(recovery, "{\"color\":\"#6b7280\",\"font\":\"caption2\"}"),
        ).joinToString(",")
        return "{\"\$element\":\"vstack\",\"props\":{\"alignment\":\"leading\",\"background\":\"#fef2f2\",\"frame\":\"max,topLeading\",\"padding\":\"12\",\"spacing\":4},\"children\":[$children]}"
    }

    /** Downloads http(s) `<image url>` sources referenced by the tree, bounded in count, size and time. */
    private fun fetchRemoteImages(tree: String, execution: ExecutionRequest): Map<String, File> {
        if (RuntimePolicy.isTimelineProjection(execution) || RuntimePolicy.isLiveActivity(execution)) return emptyMap()
        val urls = LinkedHashSet<String>()
        fun visit(node: Any?) {
            when (node) {
                is JSONObject -> {
                    if (node.optString("\$element") == "image") {
                        val props = node.optJSONObject("props")
                        val url = props?.optString("url").takeUnless { it.isNullOrEmpty() } ?: props?.optString("src")
                        if (!url.isNullOrEmpty() && (url.startsWith("http://") || url.startsWith("https://"))) urls += url
                    }
                    visit(node.optJSONArray("children"))
                }
                is JSONArray -> for (index in 0 until node.length()) visit(node.opt(index))
            }
        }
        runCatching { visit(JSONObject(tree)) }
        if (urls.isEmpty()) return emptyMap()
        imageCache.mkdirs()
        val result = HashMap<String, File>()
        val deadline = System.nanoTime() + IMAGE_BUDGET_MILLISECONDS * 1_000_000L
        for (url in urls.take(MAXIMUM_REMOTE_IMAGES)) {
            val uri = runCatching { URI(url) }.getOrNull() ?: continue
            if (fetch.validationError(uri) != null || !RuntimePolicy.packageAllowsHost(execution, uri.host)) continue
            val name = MessageDigest.getInstance("SHA-256").digest((execution.packageID + "\n" + url).toByteArray()).joinToString("") { "%02x".format(it) }
            val file = File(imageCache, name)
            val fresh = file.isFile && System.currentTimeMillis() - file.lastModified() < IMAGE_CACHE_MILLISECONDS
            if (!fresh && System.nanoTime() < deadline && execution.session.networkRequests.incrementAndGet() <= FetchModule.MAXIMUM_REQUESTS) {
                runCatching {
                    val response = fetch.perform("GET", uri, emptyMap(), null, 4000) { next -> fetch.validationError(next) == null && RuntimePolicy.packageAllowsHost(execution, next.host) }
                    if (response.status in 200..299 && response.body.isNotEmpty()) {
                        val temporary = File(imageCache, "$name.tmp")
                        temporary.writeBytes(response.body)
                        temporary.renameTo(file)
                    }
                }
            }
            // A stale copy is better than a placeholder when the network is unavailable.
            if (file.isFile) result[url] = file
        }
        return result
    }

    private companion object {
        const val MAXIMUM_CACHED_ARTIFACTS = 6
        const val MAXIMUM_REMOTE_IMAGES = 8
        const val IMAGE_BUDGET_MILLISECONDS = 6000L
        const val IMAGE_CACHE_MILLISECONDS = 15 * 60 * 1000L
    }
}
