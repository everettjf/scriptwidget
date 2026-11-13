package com.everettjf.scriptwidget

import android.content.Context
import android.content.res.AssetManager
import com.everettjf.scriptwidget.core.pkg.DiskPackageFiles
import com.everettjf.scriptwidget.core.pkg.PackageStore
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/** One installed package. [installation] stays the same when the package is renamed. */
class InstalledPackage(val name: String, val directory: File, val installation: String, val manifest: JSONObject?) {
    val files: PackageFiles get() = DiskPackageFiles(directory)
    val buildDirectory: File get() = File(directory, "__Build")
    val displayName: String get() = manifest?.optString("name")?.takeIf { it.isNotEmpty() } ?: name
    val description: String get() = manifest?.optString("description").orEmpty()
    val permissions: List<String> get() = manifest?.optJSONArray("permissions")?.let { array -> List(array.length()) { array.optString(it) } } ?: emptyList()
}

/** A template or example shipped inside the app. */
class BundledPackage(val group: String, val name: String, val assetPath: String)

/**
 * The user's widget library under the app's private files directory, plus
 * the read-only templates bundled with the app. All package I/O goes through
 * the hardened [PackageStore].
 */
class Library(private val context: Context) {
    val root = File(context.filesDir, "Scripts")
    private val staging = File(context.cacheDir, "package-staging")
    val store = PackageStore(root, staging)

    init { root.mkdirs() }

    fun list(): List<InstalledPackage> = (root.listFiles { file -> file.isDirectory && !file.name.startsWith(".") } ?: emptyArray())
        .sortedBy { it.name.lowercase() }
        .map { describe(it) }

    fun find(name: String): InstalledPackage? = File(root, name).takeIf { it.isDirectory && it.parentFile == root }?.let { describe(it) }

    fun findByInstallation(installation: String): InstalledPackage? = list().firstOrNull { it.installation == installation }

    private fun describe(directory: File): InstalledPackage {
        val manifest = File(directory, "widget.json").takeIf { it.isFile && it.length() < 256 * 1024 }?.let { runCatching { JSONObject(it.readText()) }.getOrNull() }
        return InstalledPackage(directory.name, directory, installation(directory), manifest)
    }

    /** Stable identity kept in a dot-file, which package listings and exports skip. */
    private fun installation(directory: File): String {
        val marker = File(directory, INSTALLATION_FILE)
        marker.takeIf { it.isFile }?.readText()?.trim()?.takeIf { it.length in 8..64 }?.let { return it }
        val created = UUID.randomUUID().toString()
        runCatching { marker.writeText(created) }
        return created
    }

    /** Creates a package; a taken name gets a numbered suffix. */
    fun create(name: String, source: String, manifest: String? = null): InstalledPackage = describe(store.create(store.uniqueName(name), source, manifest).directory)

    fun importArchive(input: InputStream, suggestedName: String): InstalledPackage {
        val directory = store.importArchive(input, suggestedName, validate = { files -> AppServices.validatePackage(files) }).directory
        // An archive never carries another installation's identity.
        File(directory, INSTALLATION_FILE).delete()
        return describe(directory)
    }

    fun exportArchive(name: String, output: OutputStream) = store.exportArchive(name, output)

    fun delete(name: String) = store.delete(name)

    fun rename(name: String, newName: String): InstalledPackage = describe(store.rename(name, newName).directory)

    fun duplicate(name: String): InstalledPackage {
        val copy = store.duplicate(name).directory
        File(copy, INSTALLATION_FILE).delete()
        return describe(copy)
    }

    fun writeFile(name: String, path: String, bytes: ByteArray) {
        store.writeFile(name, path, bytes)
        File(File(root, name), "__Build").deleteRecursively()
    }

    // MARK: - Bundled templates

    fun bundled(): List<BundledPackage> {
        val result = ArrayList<BundledPackage>()
        for (group in listOf("template", "component", "api")) {
            for (name in context.assets.list("Script.bundle/$group")?.sorted() ?: emptyList()) {
                val path = "Script.bundle/$group/$name"
                if (context.assets.list(path)?.contains("main.jsx") == true) result += BundledPackage(group, name, path)
            }
        }
        return result
    }

    /** Files of a bundled package as (relative path, bytes). */
    fun bundledFiles(bundled: BundledPackage): Map<String, ByteArray> {
        val result = LinkedHashMap<String, ByteArray>()
        fun visit(assetPath: String, relative: String) {
            val children = context.assets.list(assetPath) ?: return
            if (children.isEmpty()) {
                runCatching { context.assets.open(assetPath, AssetManager.ACCESS_BUFFER).use { result[relative] = it.readBytes() } }
                return
            }
            for (child in children) if (!child.startsWith(".") && child != "__Build") visit("$assetPath/$child", if (relative.isEmpty()) child else "$relative/$child")
        }
        visit(bundled.assetPath, "")
        return result
    }

    fun installBundled(bundled: BundledPackage): InstalledPackage {
        val files = bundledFiles(bundled)
        val source = files["main.jsx"]?.toString(Charsets.UTF_8) ?: error("Template has no main.jsx")
        val manifest = files["widget.json"]?.toString(Charsets.UTF_8)
        val created = store.create(store.uniqueName(bundled.name), source, manifest)
        for ((path, bytes) in files) if (path != "main.jsx" && path != "widget.json") store.writeFile(created.name, path, bytes)
        return describe(created.directory)
    }

    companion object { const val INSTALLATION_FILE = ".scriptwidget-installation" }
}
