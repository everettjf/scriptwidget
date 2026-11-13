package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.pkg.PackageException
import com.everettjf.scriptwidget.core.pkg.PackageInfo
import com.everettjf.scriptwidget.core.pkg.PackagePathRules
import com.everettjf.scriptwidget.core.pkg.PackageStore
import com.everettjf.scriptwidget.core.pkg.SafeFiles
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import com.everettjf.scriptwidget.core.skills.SkillException
import com.everettjf.scriptwidget.core.skills.SkillManifest
import com.everettjf.scriptwidget.core.skills.SkillStore
import com.everettjf.scriptwidget.core.skills.SkillValidator
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Downloads, verifies and installs Gallery items (`GalleryInstaller` in Swift).
 *
 * Remote files are data. An item is installed only after every one of these holds, and any
 * failure leaves no package, no Skill and no temporary file behind:
 *
 * 1. The item passes [GalleryIndexValidator.validateItem] again (trusted URLs, safe paths, sizes).
 * 2. Every listed file is downloaded into a unique temporary directory, and each response is
 *    HTTP 200 from a URL that still passes [GalleryIndexValidator.isRawGitHubUrl], with exactly
 *    the declared byte count and SHA-256.
 * 3. The downloaded manifest names the same id and version as the index entry.
 * 4. A widget is installed through [PackageStore.importArchive], which stages it, re-checks the
 *    tree (paths, links, limits) and publishes it with one atomic rename; a Skill is installed
 *    through [SkillStore.install], which enforces Skills 1.0.
 *
 * Hashes detect corrupted or substituted downloads; they do not make community code
 * trustworthy. Installed widgets run only within the runtime and their declared permissions.
 *
 * @param temporaryRoot private directory for downloads; a unique child is created per install.
 * @param runtimeApiVersion the runtime API version this app implements (for example `1.6`).
 *   When set, a widget whose `widget.json` requires a newer or incompatible API is refused.
 * @param widgetValidator additional Package 2.0 validation run on the staged widget before it
 *   is published; throwing refuses the install.
 * @param carriedFiles root-level bookkeeping files (single names) copied from the replaced
 *   package to its update, so an update keeps the identity of the installation.
 */
class GalleryInstaller(
    private val transport: GalleryTransport,
    private val registry: GalleryInstallationRegistry,
    private val packages: PackageStore,
    private val skills: SkillStore,
    temporaryRoot: File,
    private val runtimeApiVersion: String? = null,
    private val widgetValidator: ((PackageFiles) -> Unit)? = null,
    private val carriedFiles: List<String> = emptyList(),
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val temporaryRoot: Path = temporaryRoot.toPath().toAbsolutePath().normalize()
    private val lock = Any()

    /**
     * Install state of [item]. A registry record counts only while the thing it names is still
     * installed and still is that item: the widget package must exist under the recorded name
     * with the item's id in its manifest, and the Skill must exist with the item's id. A record
     * pointing at some other package therefore never marks it as installed or updatable.
     */
    fun state(item: GalleryItem): GalleryInstallState {
        val record = registry.record(item.id) ?: return GalleryInstallState.NotInstalled
        val present = when (record.kind) {
            GalleryItemKind.WIDGET -> installedWidget(item, record) != null
            GalleryItemKind.SKILL -> skills.isInstalled(item.id)
        }
        return if (present && record.kind == item.kind) registry.state(item) else GalleryInstallState.NotInstalled
    }

    /**
     * Installs or updates [item] and returns its record. Blocking: call off the main thread.
     *
     * An update replaces the package or Skill that the earlier install created and keeps its
     * local name; a first install of a widget gets a free package name derived from the
     * manifest's `name`.
     *
     * @throws GalleryException [GalleryException.Kind.INSTALL], [GalleryException.Kind.INVALID_DOWNLOAD]
     *   or [GalleryException.Kind.NETWORK]. A failed first install leaves nothing behind; a failed
     *   update leaves the previously installed version in place.
     */
    fun install(item: GalleryItem): GalleryInstalledRecord = synchronized(lock) {
        val issues = GalleryIndexValidator.validateItem(item)
        if (issues.isNotEmpty()) throw refuse(issues.joinToString("\n") { it.message })
        val prepared = download(item)
        try {
            val existing = registry.record(item.id)
            val localIdentifier: String
            val fresh: Boolean
            when (item.kind) {
                GalleryItemKind.WIDGET -> {
                    val target = existing?.let { installedWidget(item, it) }
                    fresh = target == null
                    localIdentifier = installWidget(item, prepared, target)
                }
                GalleryItemKind.SKILL -> {
                    fresh = !skills.isInstalled(item.id)
                    localIdentifier = installSkill(item, prepared)
                }
            }
            val record = GalleryInstalledRecord(item.id, item.kind, item.version, localIdentifier, item.contentFingerprint, now())
            try {
                registry.save(record)
            } catch (error: IOException) {
                // Without a record the item could not be updated later; undo a first install.
                if (fresh) runCatching { if (item.kind == GalleryItemKind.WIDGET) packages.delete(localIdentifier) else skills.delete(item.id) }
                throw GalleryException(GalleryException.Kind.INSTALL, "The Gallery installation could not be recorded.", error)
            }
            record
        } finally {
            SafeFiles.deleteTree(prepared)
        }
    }

    /**
     * Downloads one listed file of [item] and returns it only if it matches the index (status,
     * final host, byte count, SHA-256). Used to show a widget's manifest before installing.
     *
     * @throws GalleryException when [path] is not listed or the download fails verification.
     */
    fun downloadVerified(item: GalleryItem, path: String): ByteArray {
        val issues = GalleryIndexValidator.validateItem(item)
        if (issues.isNotEmpty()) throw refuse(issues.joinToString("\n") { it.message })
        val file = item.files.firstOrNull { it.path == path } ?: throw refuse("${item.id} does not list $path.")
        return fetchVerified(file)
    }

    private fun fetchVerified(file: GalleryFile): ByteArray {
        val response = try {
            transport.fetch(GalleryRequest(file.url, mapOf("User-Agent" to GalleryRepository.USER_AGENT), DOWNLOAD_TIMEOUT_MILLISECONDS))
        } catch (error: IOException) {
            throw GalleryException(GalleryException.Kind.NETWORK, "GitHub could not be reached.", error)
        }
        val verified = response.status == 200 &&
            GalleryIndexValidator.isRawGitHubUrl(response.finalUrl) &&
            response.body.size.toLong() == file.bytes &&
            sha256(response.body) == file.sha256
        if (!verified) {
            throw GalleryException(GalleryException.Kind.INVALID_DOWNLOAD, "Downloaded file failed status, host, size, or SHA-256 validation: ${file.path}")
        }
        return response.body
    }

    /** Downloads every file into a fresh directory; on any failure the directory is removed. */
    private fun download(item: GalleryItem): Path {
        val root = try {
            Files.createDirectories(temporaryRoot)
            Files.createDirectory(temporaryRoot.resolve("GalleryInstall-${UUID.randomUUID()}"))
        } catch (error: IOException) {
            throw GalleryException(GalleryException.Kind.INSTALL, "The download directory is unavailable.", error)
        }
        try {
            for (file in item.files) {
                val data = fetchVerified(file)
                val destination = root.resolve(file.path).normalize()
                // The validator already refused traversal; this keeps the write inside the directory regardless.
                if (!GalleryIndexValidator.isSafeRelativePath(file.path) || destination == root || !destination.startsWith(root)) {
                    throw GalleryException(GalleryException.Kind.INVALID_DOWNLOAD, "${item.id} contains unsafe path ${file.path}.")
                }
                Files.createDirectories(destination.parent)
                SafeFiles.writeNew(destination, data)
            }
            return root
        } catch (error: Throwable) {
            SafeFiles.deleteTree(root)
            throw if (error is IOException) GalleryException(GalleryException.Kind.INSTALL, "A downloaded file could not be stored.", error) else error
        }
    }

    /** The package an earlier install of [item] created, if it is still that item. */
    private fun installedWidget(item: GalleryItem, record: GalleryInstalledRecord): PackageInfo? {
        if (record.kind != GalleryItemKind.WIDGET) return null
        return try {
            packages.list().firstOrNull { it.name == record.localIdentifier && it.manifestId == item.id }
        } catch (_: PackageException) {
            null
        }
    }

    private fun installWidget(item: GalleryItem, source: Path, target: PackageInfo?): String {
        // PackageStore never installs dot-files or __Build; an item listing one cannot be installed completely.
        item.files.firstOrNull { PackagePathRules.visibleComponents(it.path) == null }?.let {
            throw refuse("Widget ${item.id} lists a path that cannot be installed: ${it.path}")
        }
        val expected = item.files.map { it.path }.toSet()
        val archive = ByteArrayOutputStream()
        try {
            ZipOutputStream(archive).use { zip ->
                for (file in item.files) {
                    zip.putNextEntry(ZipEntry("$ARCHIVE_ROOT/${file.path}"))
                    zip.write(Files.readAllBytes(source.resolve(file.path)))
                    zip.closeEntry()
                }
            }
        } catch (error: IOException) {
            throw GalleryException(GalleryException.Kind.INSTALL, "The downloaded widget could not be prepared.", error)
        }
        val imported = try {
            packages.importArchive(archive.toByteArray().inputStream(), null) { files ->
                val manifest = files.readText(WIDGET_MANIFEST)?.let(GalleryFiles::parseObject)
                if (manifest == null || manifest.opt("id") != item.id || manifest.opt("version") != item.version) {
                    throw refuse("Downloaded widget identity or version does not match the Gallery index.")
                }
                requireRuntime(item, manifest)
                if (files.paths().toSet() != expected) throw refuse("The downloaded widget could not be staged completely.")
                widgetValidator?.invoke(files)
            }
        } catch (error: PackageException) {
            throw GalleryException(GalleryException.Kind.INSTALL, error.message ?: "The widget package was rejected.", error)
        }
        if (target == null || target.name == imported.name) return imported.name

        // Update: the verified package is already installed under a temporary name. Swap it in.
        carry(target.directory.toPath(), imported.directory.toPath())
        try {
            packages.delete(target.name)
        } catch (error: PackageException) {
            runCatching { packages.delete(imported.name) }
            throw GalleryException(GalleryException.Kind.INSTALL, "The installed widget could not be replaced.", error)
        }
        return try {
            packages.rename(imported.name, target.name).name
        } catch (_: PackageException) {
            imported.name
        }
    }

    /**
     * Refuses a widget this app cannot run: its `runtimeVersion` must be the contract version of
     * the index entry, and its minimum API (`minimumRuntimeVersion`, else `runtimeVersion`) must
     * have the same major and a minor not above [runtimeApiVersion]
     * (`WidgetRuntimeRequirement.supports`). A cached index does not bypass this.
     */
    private fun requireRuntime(item: GalleryItem, manifest: JSONObject) {
        val contract = manifest.opt("runtimeVersion") as? String
        if (contract != item.minimumRuntimeVersion) throw refuse("${item.id} requires unsupported runtime ${contract ?: "(missing)"}.")
        val supported = runtimeApiVersion ?: return
        val requirement = if (manifest.has("minimumRuntimeVersion")) manifest.opt("minimumRuntimeVersion") as? String else contract
        if (requirement == null || !supports(requirement, supported)) {
            throw refuse("${item.name} requires Runtime API ${requirement ?: "(invalid)"}, but this app supports $supported. Update ScriptWidget to install it.")
        }
    }

    private fun installSkill(item: GalleryItem, source: Path): String {
        val manifest = SafeFiles.readBounded(source.resolve(SkillManifest.FILE_NAME), SkillValidator.MAX_MANIFEST_BYTES.toLong())
        val instruction = SafeFiles.readBounded(source.resolve(SkillManifest.INSTRUCTION_FILE_NAME), SkillValidator.MAX_INSTRUCTION_BYTES.toLong())
        if (manifest == null || instruction == null) throw refuse("Skill ${item.id} exceeds the Skills 1.0 size limits.")
        try {
            val skill = SkillValidator.load(manifest, instruction)
            if (skill.id != item.id || skill.version != item.version) {
                throw refuse("Downloaded skill identity or version does not match the Gallery index.")
            }
            skills.install(manifest, instruction, replaceExisting = true)
        } catch (error: SkillException) {
            throw GalleryException(GalleryException.Kind.INSTALL, error.message ?: "The skill was rejected.", error)
        }
        return item.id
    }

    /** Copies small regular bookkeeping files; links, directories and large files are skipped. */
    private fun carry(from: Path, to: Path) {
        for (name in carriedFiles) {
            if (name.isEmpty() || name.contains('/') || name.contains('\\') || name == "." || name == "..") continue
            val source = from.resolve(name)
            val attributes = SafeFiles.attributes(source) ?: continue
            if (!attributes.isRegularFile || attributes.isSymbolicLink) continue
            val bytes = SafeFiles.readBounded(source, MAX_CARRIED_BYTES) ?: continue
            try {
                SafeFiles.writeNew(to.resolve(name), bytes)
            } catch (_: IOException) {
                // The update is still valid without the bookkeeping file.
            }
        }
    }

    private fun refuse(message: String) = GalleryException(GalleryException.Kind.INSTALL, message)

    companion object {
        const val DOWNLOAD_TIMEOUT_MILLISECONDS = 30_000
        private const val ARCHIVE_ROOT = "package"
        private const val WIDGET_MANIFEST = "widget.json"
        private const val MAX_CARRIED_BYTES = 4096L
        private val apiVersion = Regex("^(0|[1-9][0-9]{0,2})\\.(0|[1-9][0-9]{0,2})$")

        /** Lowercase hexadecimal SHA-256 of [data]. */
        fun sha256(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

        /**
         * True when an app implementing API [current] can run a package requiring [minimum]:
         * both are `major.minor`, the majors are equal and the required minor is not newer.
         * Anything unparseable is unsupported.
         */
        fun supports(minimum: String, current: String): Boolean {
            val requested = apiVersion.matchEntire(minimum) ?: return false
            val supported = apiVersion.matchEntire(current) ?: return false
            return requested.groupValues[1].toInt() == supported.groupValues[1].toInt() &&
                requested.groupValues[2].toInt() <= supported.groupValues[2].toInt()
        }
    }
}
