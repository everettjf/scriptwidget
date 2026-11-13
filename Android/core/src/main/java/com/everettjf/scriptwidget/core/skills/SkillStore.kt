package com.everettjf.scriptwidget.core.skills

import com.everettjf.scriptwidget.core.gallery.GalleryFiles
import com.everettjf.scriptwidget.core.pkg.ArchiveLimits
import com.everettjf.scriptwidget.core.pkg.ArchivePreflight
import com.everettjf.scriptwidget.core.pkg.PackageException
import com.everettjf.scriptwidget.core.pkg.SafeFiles
import org.json.JSONArray
import org.json.JSONException
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.time.LocalDateTime
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * The user's Skills under `root/<slug>/` (`AIWidgetSkillManager` in Swift), plus the read-only
 * built-ins and the set of enabled Skills.
 *
 * Security model: a Skill is two text files that are only ever read as data. The store never
 * executes, evaluates or loads anything from a Skill, and a Skill cannot declare tools, hosts or
 * runtime permissions: `skill.json` is refused when it has a key outside the schema. Every
 * Skill is validated when it enters the store and again each time it is read, so a directory
 * that was altered on disk (extra file, link, oversized or malformed file) is not listed.
 *
 * Installs are prepared in a hidden staging directory and published with one atomic rename; a
 * failed install or import leaves no Skill and no staging files. Mutations are serialized per
 * instance; use one instance per root.
 */
class SkillStore(root: File) {
    private val root: Path = root.toPath().toAbsolutePath().normalize()
    private val lock = Any()

    private class Stored(val directory: Path, val skill: Skill, val manifest: ByteArray, val instruction: ByteArray)

    /**
     * Built-in Skills that no installed Skill replaces, followed by installed Skills sorted by
     * title. The order is deterministic, which keeps [enabledSkillsPromptText] stable.
     */
    fun list(): List<Skill> {
        val custom = stored().map { it.skill }.sortedWith(compareBy({ it.title.lowercase() }, { it.id }))
        val customIds = custom.map { it.id }.toSet()
        return BuiltInSkills.all.filter { it.id !in customIds } + custom
    }

    /** The Skill with [id], installed or built-in, or null. */
    fun find(id: String): Skill? = list().firstOrNull { it.id == id }

    /** True when an installed (not built-in) Skill has [id]. */
    fun isInstalled(id: String): Boolean = stored().any { it.skill.id == id }

    /**
     * Validates and installs a Skill from the exact bytes of its two files.
     *
     * Both files must pass [SkillValidator.load]. An installed Skill with the same id is
     * replaced in place when [replaceExisting] is set and refused otherwise, so an import can
     * never silently overwrite a Skill. The stored files are byte-for-byte the given ones.
     *
     * @throws SkillException with the validation code, `duplicate_skill` or `storage_unavailable`.
     */
    fun install(manifest: ByteArray, instruction: ByteArray, replaceExisting: Boolean = false): Skill = synchronized(lock) {
        val skill = SkillValidator.load(manifest, instruction)
        val existing = stored().firstOrNull { it.skill.id == skill.id }
        if (!replaceExisting && (existing != null || BuiltInSkills.all.any { it.id == skill.id })) {
            throw SkillException(SkillErrors.DUPLICATE, "A skill with id ${skill.id} is already installed.")
        }
        val staging = root.resolve(".staging-${UUID.randomUUID()}")
        val backup = root.resolve(".backup-${UUID.randomUUID()}")
        try {
            Files.createDirectories(root)
            if (SafeFiles.realDirectory(root) == null) throw IOException("Skills directory is a link")
            Files.createDirectory(staging)
            SafeFiles.writeNew(staging.resolve(SkillManifest.FILE_NAME), manifest)
            SafeFiles.writeNew(staging.resolve(SkillManifest.INSTRUCTION_FILE_NAME), instruction)
            val destination = existing?.directory ?: freeDirectory(skill.title)
            if (existing != null) Files.move(destination, backup, StandardCopyOption.ATOMIC_MOVE)
            try {
                Files.move(staging, destination, StandardCopyOption.ATOMIC_MOVE)
            } catch (error: IOException) {
                if (existing != null) Files.move(backup, destination, StandardCopyOption.ATOMIC_MOVE)
                throw error
            }
        } catch (error: IOException) {
            throw SkillException(SkillErrors.STORAGE_UNAVAILABLE, "The skill could not be saved.", cause = error)
        } finally {
            SafeFiles.deleteTree(staging)
            SafeFiles.deleteTree(backup)
        }
        skill
    }

    /**
     * Deletes an installed Skill and forgets its enabled state. Built-in Skills cannot be deleted.
     *
     * @throws SkillException `built_in_skill`, `skill_not_found` or `storage_unavailable`.
     */
    fun delete(id: String) = synchronized(lock) {
        val target = stored().firstOrNull { it.skill.id == id }
            ?: throw if (BuiltInSkills.all.any { it.id == id }) SkillException(SkillErrors.BUILT_IN, "Built-in skills cannot be deleted.")
            else SkillException(SkillErrors.NOT_FOUND, "Skill not found.")
        val trash = root.resolve(".deleted-${UUID.randomUUID()}")
        try {
            Files.move(target.directory, trash, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: IOException) {
            SafeFiles.deleteTree(target.directory)
        } finally {
            SafeFiles.deleteTree(trash)
        }
        if (SafeFiles.occupied(target.directory)) throw SkillException(SkillErrors.STORAGE_UNAVAILABLE, "The skill could not be deleted.")
        if (BuiltInSkills.all.none { it.id == id }) writeEnabled(readEnabled() - id)
    }

    /** Ids the user enabled. Nothing is enabled by default, and an unreadable state file enables nothing. */
    fun enabledIds(): Set<String> = synchronized(lock) { readEnabled() }

    fun isEnabled(id: String): Boolean = id in enabledIds()

    /**
     * Enables or disables a Skill for AI requests. Only an existing Skill can be enabled.
     *
     * @throws SkillException `skill_not_found` or `storage_unavailable`.
     */
    fun setEnabled(id: String, enabled: Boolean) = synchronized(lock) {
        if (enabled && find(id) == null) throw SkillException(SkillErrors.NOT_FOUND, "Skill not found.")
        val current = readEnabled()
        writeEnabled(if (enabled) current + id else current - id)
    }

    /** Enabled Skills that still exist and validate, in [list] order. */
    fun enabledSkills(): List<Skill> {
        val enabled = enabledIds()
        return list().filter { it.id in enabled }
    }

    /**
     * The text appended to an AI prompt for the enabled Skills, or an empty string when none is
     * enabled. Each Skill contributes its name, version and complete instructions, in [list]
     * order (`AIWidgetSkills.augment` in Swift).
     *
     * This is the only way a Skill influences the app: as untrusted advice inside a prompt. It
     * grants no tool, file, network or runtime permission.
     */
    fun enabledSkillsPromptText(): String {
        val selected = enabledSkills()
        if (selected.isEmpty()) return ""
        return "Apply these ScriptWidget skills:\n" + selected.joinToString("\n") { "- ${it.title} v${it.version}:\n  ${it.instruction.replace("\n", "\n  ")}" }
    }

    /** [prompt] followed by [enabledSkillsPromptText]; unchanged when no Skill is enabled. */
    fun augment(prompt: String): String = enabledSkillsPromptText().let { if (it.isEmpty()) prompt else "$prompt\n\n$it" }

    /**
     * Imports one Skill from a `.swskill`/ZIP archive without replacing anything.
     *
     * Hardening, each step failing closed: at most 256 KiB is read; the complete central
     * directory is preflighted like a widget archive (no traversal, absolute path, backslash,
     * colon, NUL, non-UTF-8 name, duplicate or case-colliding path, symbolic link or special
     * file, encryption, unknown compression, or ZIP64/size inconsistency) with Skill-sized
     * limits; apart from dot-files and `__MACOSX`, the archive must hold exactly `skill.json`
     * and `SKILL.md`, at its root or inside one top-level directory; each file is inflated with a
     * hard byte bound and must match its declared size and CRC-32 (zip bomb guard); the content
     * then passes [install]. No other archive entry is ever extracted.
     *
     * @throws SkillException `too_large`, `invalid_archive`, `invalid_package`, or any [install] code.
     */
    fun importArchive(input: InputStream): Skill {
        val archive = readBounded(input, SkillValidator.MAX_PACKAGE_BYTES)
            ?: throw SkillException(SkillErrors.TOO_LARGE, "A Skill package may not exceed 256 KiB.")
        val entries = try {
            ArchivePreflight.validate(archive, ARCHIVE_LIMITS)
        } catch (error: PackageException) {
            throw SkillException(SkillErrors.INVALID_ARCHIVE, "The Skill archive was rejected (${error.code}).", cause = error)
        }
        val visible = entries.filter { entry -> entry.parts.none { it.startsWith(".") } && entry.parts[0] != "__MACOSX" }
        val files = visible.filter { !it.isDirectory }
        val atRoot = files.any { it.parts.size == 1 }
        val depth = if (atRoot) 1 else 2
        val prefix = if (atRoot) emptyList() else files.firstOrNull()?.parts?.take(1).orEmpty()
        val wellFormed = files.all { it.parts.size == depth && it.parts.take(depth - 1) == prefix } &&
            visible.filter { it.isDirectory }.all { !atRoot && it.parts == prefix } &&
            files.map { it.parts.last() }.sorted() == PACKAGE_FILES
        if (!wellFormed) throw SkillException(SkillErrors.INVALID_PACKAGE, "Skills 1.0 allows only skill.json and SKILL.md.")

        val work = root.resolve(".import-${UUID.randomUUID()}")
        try {
            Files.createDirectories(work)
            val archiveFile = work.resolve("archive.zip")
            SafeFiles.writeNew(archiveFile, archive)
            val contents = ZipFile(archiveFile.toFile()).use { zip ->
                files.associate { entry ->
                    val name = entry.parts.last()
                    val limit = if (name == SkillManifest.FILE_NAME) SkillValidator.MAX_MANIFEST_BYTES else SkillValidator.MAX_INSTRUCTION_BYTES
                    if (entry.uncompressedSize > limit) throw SkillException(SkillErrors.TOO_LARGE, "$name exceeds its Skills 1.0 size limit.")
                    val zipEntry = zip.getEntry(entry.name)?.takeIf { !it.isDirectory } ?: corrupt()
                    val bytes = zip.getInputStream(zipEntry).use { readBounded(it, entry.uncompressedSize.toInt()) } ?: corrupt()
                    if (bytes.size.toLong() != entry.uncompressedSize || CRC32().apply { update(bytes) }.value != entry.crc) corrupt()
                    name to bytes
                }
            }
            return install(contents.getValue(SkillManifest.FILE_NAME), contents.getValue(SkillManifest.INSTRUCTION_FILE_NAME), replaceExisting = false)
        } catch (error: IOException) {
            throw SkillException(SkillErrors.INVALID_ARCHIVE, "The Skill archive could not be read.", cause = error)
        } catch (error: IllegalArgumentException) {
            throw SkillException(SkillErrors.INVALID_ARCHIVE, "The Skill archive could not be read.", cause = error)
        } finally {
            SafeFiles.deleteTree(work)
        }
    }

    /**
     * Writes a Skill as a ZIP holding exactly `skill.json` and `SKILL.md` at its root. An
     * installed Skill is exported byte-for-byte after re-validation; a built-in Skill gets a
     * generated manifest.
     *
     * @throws SkillException `skill_not_found`.
     */
    fun exportArchive(id: String, output: OutputStream) {
        val custom = stored().firstOrNull { it.skill.id == id }
        val manifest: ByteArray
        val instruction: ByteArray
        if (custom != null) {
            manifest = custom.manifest
            instruction = custom.instruction
        } else {
            val builtIn = BuiltInSkills.all.firstOrNull { it.id == id } ?: throw SkillException(SkillErrors.NOT_FOUND, "Skill not found.")
            manifest = SkillManifest(
                SkillManifest.CURRENT_FORMAT_VERSION, builtIn.id, builtIn.title, builtIn.version, builtIn.summary, builtIn.symbol,
                SkillManifest.INSTRUCTION_FILE_NAME, builtIn.tags, builtIn.author, builtIn.minimumRuntimeVersion,
            ).encode()
            instruction = builtIn.instruction.toByteArray(Charsets.UTF_8)
        }
        val zip = ZipOutputStream(output)
        for ((name, bytes) in listOf(SkillManifest.FILE_NAME to manifest, SkillManifest.INSTRUCTION_FILE_NAME to instruction)) {
            zip.putNextEntry(ZipEntry(name).apply { timeLocal = FIXED_ENTRY_TIME })
            zip.write(bytes)
            zip.closeEntry()
        }
        zip.finish()
    }

    /**
     * Installed Skills that are intact. A Skill directory must be a real directory (not a link)
     * whose visible entries are exactly the two regular, singly linked files, each within its
     * size limit and passing validation. When two directories claim one id, the first by
     * directory name wins.
     */
    private fun stored(): List<Stored> {
        val directory = SafeFiles.realDirectory(root) ?: return emptyList()
        val result = ArrayList<Stored>()
        val seen = HashSet<String>()
        for (name in SafeFiles.names(directory).orEmpty().filter { !it.startsWith(".") }.sorted()) {
            val stored = SafeFiles.realDirectory(directory.resolve(name))?.let(::read) ?: continue
            if (seen.add(stored.skill.id)) result.add(stored)
        }
        return result
    }

    private fun read(directory: Path): Stored? {
        val children = SafeFiles.names(directory)?.filter { !it.startsWith(".") } ?: return null
        if (children.sorted() != PACKAGE_FILES) return null
        val manifest = readFile(directory.resolve(SkillManifest.FILE_NAME), SkillValidator.MAX_MANIFEST_BYTES) ?: return null
        val instruction = readFile(directory.resolve(SkillManifest.INSTRUCTION_FILE_NAME), SkillValidator.MAX_INSTRUCTION_BYTES) ?: return null
        val skill = try {
            SkillValidator.load(manifest, instruction)
        } catch (_: SkillException) {
            return null
        }
        return Stored(directory, skill, manifest, instruction)
    }

    private fun readFile(file: Path, maximumBytes: Int): ByteArray? {
        val attributes = SafeFiles.attributes(file) ?: return null
        if (!attributes.isRegularFile || attributes.isSymbolicLink || !SafeFiles.singlyLinked(file)) return null
        return SafeFiles.readBounded(file, maximumBytes.toLong())
    }

    private fun freeDirectory(preferredName: String): Path {
        val base = SkillValidator.slug(preferredName)
        val taken = SafeFiles.names(root).orEmpty().map { it.lowercase() }.toSet()
        if (base !in taken) return root.resolve(base)
        for (index in 2..MAX_DIRECTORY_ATTEMPTS) if ("$base-$index" !in taken) return root.resolve("$base-$index")
        throw IOException("No free Skill directory name")
    }

    private fun readEnabled(): Set<String> {
        val text = SafeFiles.readBounded(root.resolve(ENABLED_FILE), MAX_ENABLED_BYTES)?.let(SafeFiles::decodeUtf8) ?: return emptySet()
        return try {
            val array = JSONArray(text)
            List(array.length()) { array.opt(it) as? String ?: return emptySet() }.toSet()
        } catch (_: JSONException) {
            emptySet()
        }
    }

    private fun writeEnabled(ids: Set<String>) {
        try {
            GalleryFiles.writeAtomically(root.resolve(ENABLED_FILE), JSONArray(ids.sorted()).toString().toByteArray(Charsets.UTF_8))
        } catch (error: IOException) {
            throw SkillException(SkillErrors.STORAGE_UNAVAILABLE, "The enabled skills could not be saved.", cause = error)
        }
    }

    /** Reads [input] completely, or returns null as soon as it holds more than [maximumBytes]. */
    private fun readBounded(input: InputStream, maximumBytes: Int): ByteArray? {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size() + count > maximumBytes) return null
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun corrupt(): Nothing = throw SkillException(SkillErrors.INVALID_ARCHIVE, "The Skill archive is corrupt or does not match its declared sizes.")

    private companion object {
        const val ENABLED_FILE = ".enabled.json"
        const val MAX_ENABLED_BYTES = 256L * 1024
        const val MAX_DIRECTORY_ATTEMPTS = 10_000
        val PACKAGE_FILES = listOf(SkillManifest.INSTRUCTION_FILE_NAME, SkillManifest.FILE_NAME).sorted()
        val FIXED_ENTRY_TIME: LocalDateTime = LocalDateTime.of(1980, 1, 1, 0, 0, 0)

        /** Skill-sized archive limits: 256 KiB in total, 64 KiB per file, a handful of shallow entries. */
        val ARCHIVE_LIMITS = ArchiveLimits(
            maximumArchiveBytes = SkillValidator.MAX_PACKAGE_BYTES,
            maximumExpandedBytes = SkillValidator.MAX_PACKAGE_BYTES.toLong(),
            maximumFileBytes = SkillValidator.MAX_INSTRUCTION_BYTES.toLong(),
            maximumFileCount = 16,
            maximumPathDepth = 3,
        )
    }
}
