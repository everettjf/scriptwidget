package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.pkg.ArchiveLimits
import com.everettjf.scriptwidget.core.pkg.ArchivePreflight
import com.everettjf.scriptwidget.core.pkg.PackageException
import com.everettjf.scriptwidget.core.pkg.SafeFiles
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.time.LocalDateTime
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** A plugin the store can serve. Built-in plugins ship with the app and have no directory. */
class InstalledPlugin(val manifest: PluginManifest, val builtIn: Boolean, val readme: String?)

/**
 * Installed Data Source Plugins, ported from `DataSourcePluginManager`.
 *
 * Each plugin is a directory below [root] holding `plugin.json` and an optional `README.md`,
 * nothing else. Imported files are untrusted: they are bounded, validated completely before
 * anything is written, staged in a private directory and published with one atomic rename, so
 * a failed import leaves nothing behind and readers never see a partial plugin.
 */
class PluginStore(root: File) {
    private val root: Path = root.toPath().toAbsolutePath().normalize()
    private val staging: Path = this.root.resolve(STAGING_DIRECTORY)
    private val lock = Any()

    /** Built-in plugins not replaced by an installed one, plus installed plugins, sorted by name. */
    fun list(): List<InstalledPlugin> {
        val custom = directories().mapNotNull { directory -> load(directory)?.let { InstalledPlugin(it, false, readText(directory, README_FILE, MAXIMUM_README_BYTES)) } }
            .distinctBy { it.manifest.id }
        val customIDs = custom.map { it.manifest.id }.toSet()
        val builtIn = BUILT_INS.filter { it.id !in customIDs }.map { InstalledPlugin(it, true, builtInReadme(it)) }
        return (builtIn + custom).sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.manifest.name })
    }

    /**
     * The validated manifest for [id], or null. A stored manifest is validated again on every
     * read, so a file altered on disk after import is never used unless it still passes.
     */
    fun manifest(id: String): PluginManifest? {
        for (directory in directories()) load(directory)?.let { if (it.id == id) return it }
        return BUILT_INS.firstOrNull { it.id == id }
    }

    /**
     * Installs a plugin from a `.swplugin` ZIP archive or a bare `plugin.json`.
     *
     * Security rules, each failing closed with [PluginException]:
     * - at most 512 KiB of input (`DataSourcePluginManager.maximumPackageBytes`);
     * - an archive passes the package archive preflight (no traversal, absolute paths,
     *   backslashes, symlinks, encrypted entries, case collisions or forged directories);
     * - the package root (archive root or its single directory) holds only `plugin.json` and an
     *   optional `README.md`, both regular files: a plugin cannot carry code or other payloads;
     * - entries are inflated with their real sizes counted, never trusting declared sizes, and
     *   their CRC-32 checked; `plugin.json` is at most 256 KiB and `README.md` 512 KiB of UTF-8;
     * - the manifest passes [PluginValidator.decode];
     * - an id that is already installed or built in is refused rather than replaced.
     */
    fun install(input: InputStream): PluginManifest {
        val bytes = readBounded(input)
        val (manifestBytes, readme) = if (isZip(bytes)) unpack(bytes) else bytes to null
        val manifest = PluginValidator.decode(manifestBytes)
        synchronized(lock) {
            if (manifest(manifest.id) != null) throw PluginException(PluginException.Kind.INVALID_MANIFEST, "Plugin ${manifest.id} is already installed.")
            val work = workDirectory("install")
            try {
                val prepared = Files.createDirectory(work.resolve("plugin"))
                SafeFiles.writeNew(prepared.resolve(MANIFEST_FILE), manifestBytes)
                if (readme != null) SafeFiles.writeNew(prepared.resolve(README_FILE), readme)
                SafeFiles.publish(prepared, uniqueDirectory(manifest.name))
            } catch (error: IOException) {
                throw storage("The plugin could not be installed.", error)
            } catch (error: PackageException) {
                throw storage(error.message ?: "The plugin could not be installed.", error)
            } finally {
                SafeFiles.deleteTree(work)
            }
        }
        return manifest
    }

    /**
     * Removes the installed plugin [id]. The directory is first renamed out of the store, so the
     * plugin disappears atomically. Built-in plugins cannot be deleted.
     */
    fun delete(id: String) {
        synchronized(lock) {
            val directory = directory(id)
                ?: throw PluginException(PluginException.Kind.NOT_FOUND, if (BUILT_INS.any { it.id == id }) "Built-in plugins cannot be deleted." else "Plugin not found.")
            val work = workDirectory("delete")
            try {
                Files.move(directory, work.resolve("plugin"), StandardCopyOption.ATOMIC_MOVE)
            } catch (error: IOException) {
                throw storage("The plugin could not be deleted.", error)
            } finally {
                SafeFiles.deleteTree(work)
            }
        }
    }

    /**
     * Writes plugin [id] to [output] as a `.swplugin` ZIP with `plugin.json` and, when present,
     * `README.md` at the archive root. Only those two files are ever exported, so nothing else
     * placed in the plugin directory can leak. Nothing is written unless the archive is complete.
     */
    fun export(id: String, output: OutputStream) {
        val files = LinkedHashMap<String, ByteArray>()
        val directory = directory(id)
        if (directory != null) {
            files[MANIFEST_FILE] = readBytes(directory, MANIFEST_FILE, PluginValidator.MAXIMUM_MANIFEST_BYTES) ?: throw PluginException(PluginException.Kind.NOT_FOUND, "Plugin not found.")
            readBytes(directory, README_FILE, MAXIMUM_README_BYTES)?.let { files[README_FILE] = it }
        } else {
            val builtIn = BUILT_INS.firstOrNull { it.id == id } ?: throw PluginException(PluginException.Kind.NOT_FOUND, "Plugin not found.")
            files[MANIFEST_FILE] = builtIn.toJson().toByteArray()
            files[README_FILE] = builtInReadme(builtIn).toByteArray()
        }
        val buffer = ByteArrayOutputStream()
        ZipOutputStream(buffer, Charsets.UTF_8).use { zip ->
            for ((name, bytes) in files) {
                val entry = ZipEntry(name)
                entry.setTimeLocal(FIXED_ENTRY_TIME)
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        try {
            buffer.writeTo(output)
        } catch (error: IOException) {
            throw storage("Could not create the .swplugin archive.", error)
        }
    }

    // MARK: - Import

    private fun readBounded(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        try {
            while (output.size() <= MAXIMUM_PACKAGE_BYTES) {
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
            }
        } catch (error: IOException) {
            throw storage("The plugin file could not be read.", error)
        }
        if (output.size() > MAXIMUM_PACKAGE_BYTES) invalid("A plugin package may not exceed 512 KiB.")
        if (output.size() == 0) invalid(NOT_A_PACKAGE)
        return output.toByteArray()
    }

    private fun isZip(bytes: ByteArray): Boolean = bytes.size >= 4 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()

    /** Returns the bytes of `plugin.json` and `README.md` (or null) from a validated archive. */
    private fun unpack(archive: ByteArray): Pair<ByteArray, ByteArray?> {
        val entries = try {
            ArchivePreflight.validate(archive, ArchiveLimits())
        } catch (error: PackageException) {
            invalid(error.message ?: NOT_A_PACKAGE)
        }
        // Hidden files and the macOS resource directory are ignored, as in the Swift importer.
        val visible = entries.filter { entry -> entry.parts[0] != "__MACOSX" && entry.parts.none { it.startsWith(".") } }
        val atRoot = visible.any { it.parts.size == 1 && !it.isDirectory && it.parts[0] == MANIFEST_FILE }
        val prefix = if (atRoot) 0 else {
            val roots = visible.filter { it.parts.size > 1 || it.isDirectory }.map { it.parts[0] }.toSet()
            if (roots.size != 1) invalid(NOT_A_PACKAGE)
            1
        }
        val members = visible.filter { it.parts.size > prefix }
        if (members.any { it.isDirectory || it.parts.size != prefix + 1 || it.parts[prefix] !in ALLOWED_FILES } || members.none { it.parts[prefix] == MANIFEST_FILE }) {
            invalid("A plugin package allows only plugin.json and optional README.md.")
        }
        val work = workDirectory("import")
        try {
            val file = work.resolve("archive.zip")
            Files.write(file, archive, StandardOpenOption.CREATE_NEW)
            ZipFile(file.toFile()).use { zip ->
                val manifest = inflate(zip, members.first { it.parts[prefix] == MANIFEST_FILE }, PluginValidator.MAXIMUM_MANIFEST_BYTES, "plugin.json exceeds 256 KiB.")
                val readme = members.firstOrNull { it.parts[prefix] == README_FILE }?.let { inflate(zip, it, MAXIMUM_README_BYTES, "README.md exceeds 512 KiB.") }
                if (readme != null && PluginValidator.decodeUtf8(readme) == null) invalid("README.md must be UTF-8 text.")
                return manifest to readme
            }
        } catch (error: IOException) {
            invalid("The plugin archive is corrupt.")
        } finally {
            SafeFiles.deleteTree(work)
        }
    }

    /** Inflates one entry in memory, counting real bytes so false size headers cannot expand. */
    private fun inflate(zip: ZipFile, entry: ArchivePreflight.Entry, maximumBytes: Int, tooLarge: String): ByteArray {
        if (entry.uncompressedSize > maximumBytes) invalid(tooLarge)
        val zipEntry = zip.getEntry(entry.name)
        if (zipEntry == null || zipEntry.isDirectory) invalid("The plugin archive is corrupt.")
        val output = ByteArrayOutputStream()
        val crc = CRC32()
        zip.getInputStream(zipEntry).use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (output.size() + count > entry.uncompressedSize || output.size() + count > maximumBytes) invalid("The plugin archive is corrupt.")
                crc.update(buffer, 0, count)
                output.write(buffer, 0, count)
            }
        }
        if (output.size().toLong() != entry.uncompressedSize || crc.value != entry.crc) invalid("The plugin archive is corrupt.")
        return output.toByteArray()
    }

    // MARK: - Storage

    /** Plugin directories: real directories (never links) whose names are not hidden. */
    private fun directories(): List<Path> {
        if (SafeFiles.realDirectory(root) == null) return emptyList()
        return (SafeFiles.names(root) ?: emptyList()).filter { !it.startsWith(".") }.sorted()
            .mapNotNull { SafeFiles.realDirectory(root.resolve(it)) }
    }

    private fun directory(id: String): Path? = directories().firstOrNull { load(it)?.id == id }

    private fun load(directory: Path): PluginManifest? {
        val bytes = readBytes(directory, MANIFEST_FILE, PluginValidator.MAXIMUM_MANIFEST_BYTES) ?: return null
        return try { PluginValidator.decode(bytes) } catch (_: PluginException) { null }
    }

    /** Reads a regular, singly linked file that is not a symlink and stays inside [directory]. */
    private fun readBytes(directory: Path, name: String, maximumBytes: Int): ByteArray? =
        SafeFiles.existingFile(directory, listOf(name))?.let { SafeFiles.readBounded(it, maximumBytes.toLong()) }

    private fun readText(directory: Path, name: String, maximumBytes: Int): String? =
        readBytes(directory, name, maximumBytes)?.let { PluginValidator.decodeUtf8(it) }

    private fun workDirectory(prefix: String): Path = try {
        Files.createDirectories(root)
        SafeFiles.newWorkDirectory(staging, prefix)
    } catch (error: IOException) {
        throw storage("The plugin directory is unavailable.", error)
    } catch (error: PackageException) {
        throw storage("The plugin directory is unavailable.", error)
    }

    /** Directory names are derived from the plugin name but reduced to `[a-z0-9-]`, so they cannot traverse. */
    private fun uniqueDirectory(name: String): Path {
        val slug = name.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')
        val base = slug.ifEmpty { "plugin" }
        var path = root.resolve(base)
        var index = 2
        while (SafeFiles.occupied(path)) { path = root.resolve("$base-$index"); index += 1 }
        return path
    }

    private fun builtInReadme(manifest: PluginManifest): String = "# ${manifest.name}\n\n${manifest.summary}\n"

    private fun invalid(message: String): Nothing = throw PluginException(PluginException.Kind.INVALID_MANIFEST, message)

    private fun storage(message: String, cause: Throwable): PluginException = PluginException(PluginException.Kind.STORAGE, message, cause)

    companion object {
        /** `DataSourcePluginManager.maximumPackageBytes`: the largest archive or manifest accepted for import. */
        const val MAXIMUM_PACKAGE_BYTES = 512 * 1024
        /** Largest `README.md` stored or shown (Android-specific; Swift bounds it only by the archive limits). */
        const val MAXIMUM_README_BYTES = 512 * 1024
        const val MANIFEST_FILE = "plugin.json"
        const val README_FILE = "README.md"
        private const val STAGING_DIRECTORY = ".staging"
        private const val NOT_A_PACKAGE = "Archive must contain one Data Source Plugin 1.0 package."
        private val ALLOWED_FILES = setOf(MANIFEST_FILE, README_FILE)
        private val FIXED_ENTRY_TIME: LocalDateTime = LocalDateTime.of(1980, 1, 1, 0, 0, 0)

        private fun parameter(id: String, label: String, location: PluginParameterLocation, required: Boolean, defaultValue: String) =
            PluginParameter(id, label, location, required, defaultValue)

        /** The plugins every ScriptWidget build ships, identical to `DataSourcePluginManager.builtIns`. */
        val BUILT_INS: List<PluginManifest> = listOf(
            PluginManifest(
                formatVersion = 1, id = "app.scriptwidget.datasource.open-meteo", name = "Open-Meteo", version = "1.0.0",
                summary = "Weather forecasts without an API key.", symbol = "cloud.sun", author = "Open-Meteo", license = "CC BY 4.0",
                minimumRuntimeVersion = "1.0", baseURL = "https://api.open-meteo.com", hosts = listOf("api.open-meteo.com"),
                operations = listOf(PluginOperation("forecast", "Forecast", "GET", "/v1/forecast", PluginResponseType.JSON, listOf(
                    parameter("latitude", "Latitude", PluginParameterLocation.QUERY, true, "37.7749"),
                    parameter("longitude", "Longitude", PluginParameterLocation.QUERY, true, "-122.4194"),
                    parameter("current", "Current fields", PluginParameterLocation.QUERY, false, "temperature_2m,weather_code"),
                    parameter("timezone", "Timezone", PluginParameterLocation.QUERY, false, "auto"),
                ))),
            ),
            PluginManifest(
                formatVersion = 1, id = "app.scriptwidget.datasource.github", name = "GitHub Public API", version = "1.0.0",
                summary = "Public repository metadata from GitHub.", symbol = "chevron.left.forwardslash.chevron.right", author = "GitHub", license = "API Terms",
                minimumRuntimeVersion = "1.0", baseURL = "https://api.github.com", hosts = listOf("api.github.com"),
                operations = listOf(PluginOperation("repository", "Repository", "GET", "/repos/{owner}/{repo}", PluginResponseType.JSON, listOf(
                    parameter("owner", "Owner", PluginParameterLocation.PATH, true, "everettjf"),
                    parameter("repo", "Repository", PluginParameterLocation.PATH, true, "scriptwidget"),
                ))),
            ),
        )
    }
}
