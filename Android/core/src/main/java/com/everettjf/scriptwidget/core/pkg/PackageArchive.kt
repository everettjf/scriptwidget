package com.everettjf.scriptwidget.core.pkg

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.time.LocalDateTime
import java.util.TreeMap
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * A package extracted from an archive into a private staging directory. Nothing is visible in
 * the library until [moveTo] succeeds; [close] removes whatever is still in staging, so a
 * failed or abandoned import leaves nothing behind.
 */
class ExtractedPackage internal constructor(
    /** The extracted package root (inside the staging directory until moved). */
    val directory: File,
    /** Name of the single top-level archive directory, or null when files sat at the archive root. */
    val rootName: String?,
    private val workDirectory: Path,
) : Closeable {
    /**
     * Publishes the package with one atomic rename. [destination] must not exist and must be on
     * the same filesystem as the staging directory.
     */
    fun moveTo(destination: File) = SafeFiles.publish(directory.toPath(), destination.toPath())

    override fun close() = SafeFiles.deleteTree(workDirectory)
}

/**
 * `.swt` (ZIP) import and export with the hardening of the Swift implementation
 * (`ScriptPackageArchivePreflight`, `ScriptManager.importScriptPackage`).
 *
 * Archives are untrusted. The whole central directory is validated before anything is written;
 * extraction happens in a unique directory under a caller-supplied staging directory; and the
 * sizes an archive declares are never trusted, only the bytes actually inflated.
 */
object PackageArchive {
    private const val MACOS_RESOURCE_DIRECTORY = "__MACOSX"
    private val fixedEntryTime: LocalDateTime = LocalDateTime.of(1980, 1, 1, 0, 0, 0)

    /**
     * Validates [archive] without extracting it and returns its entry names.
     *
     * @throws PackageException with an `archive_*` code for every rule listed on the class.
     */
    fun preflight(archive: ByteArray, limits: ArchiveLimits = ArchiveLimits()): List<String> =
        ArchivePreflight.validate(archive, limits).map { it.name }

    /**
     * Reads, validates and extracts one package from [input].
     *
     * Steps, each failing closed: read at most the archive byte limit; preflight the complete
     * central directory; pick the package root (files at the archive root, or exactly one
     * top-level directory); extract only that root into a fresh directory under
     * [stagingDirectory]; verify the extracted tree. Dot-files, `__MACOSX` and `__Build` (generated
     * cache that must never be accepted from an archive) are not extracted. While inflating, bytes
     * are counted and extraction stops as soon as an entry exceeds its declared size or a limit,
     * so a zip bomb with false size headers cannot expand; the CRC-32 must match as well.
     *
     * The caller must [ExtractedPackage.close] the result. On failure the staging directory is
     * already clean.
     */
    fun extract(input: InputStream, stagingDirectory: File, limits: ArchiveLimits = ArchiveLimits()): ExtractedPackage {
        val bytes = readArchive(input, limits)
        val entries = ArchivePreflight.validate(bytes, limits)
        val selection = select(entries)
        val work = SafeFiles.newWorkDirectory(stagingDirectory.toPath().toAbsolutePath().normalize(), "import")
        try {
            val archiveFile = work.resolve("archive.zip")
            Files.write(archiveFile, bytes, StandardOpenOption.CREATE_NEW)
            val tree = Files.createDirectory(work.resolve("package"))
            var total = 0L
            ZipFile(archiveFile.toFile()).use { zip ->
                for ((parts, entry) in selection.files) {
                    val zipEntry = zip.getEntry(entry.name)
                    if (zipEntry == null || zipEntry.isDirectory) corrupt(entry.name, null)
                    val target = parts.fold(tree) { path, part -> path.resolve(part) }
                    Files.createDirectories(target.parent)
                    total += zip.getInputStream(zipEntry).use { copyEntry(it, target, entry, total, limits) }
                }
            }
            Files.delete(archiveFile)
            PackageTree.validate(tree, limits)
            return ExtractedPackage(tree.toFile(), selection.rootName, work)
        } catch (error: Throwable) {
            SafeFiles.deleteTree(work)
            throw when (error) {
                is PackageException -> error
                is IOException, is IllegalArgumentException -> PackageException(PackageErrors.ARCHIVE_CORRUPT, "The package could not be extracted.", error)
                else -> error
            }
        }
    }

    /**
     * [extract] followed by an atomic move to [destination]; the staging directory is cleaned
     * whether or not the import succeeds. Returns the archive's top-level directory name, if any.
     */
    fun importTo(input: InputStream, stagingDirectory: File, destination: File, limits: ArchiveLimits = ArchiveLimits()): String? =
        extract(input, stagingDirectory, limits).use { extracted ->
            extracted.moveTo(destination)
            extracted.rootName
        }

    /**
     * Writes the package in [packageDirectory] to [output] as a `.swt` archive whose entries live
     * under one `rootName/` directory.
     *
     * Dot-files, `__Build`, symbolic links, hard-linked and special files are skipped (they are
     * not part of the authored package and must not leak through an export). Entries are sorted
     * and carry a fixed timestamp, so the same package always yields the same bytes. The export
     * obeys the import limits, so every exported archive can be imported again. [extraFiles] adds
     * generated files (for example a migrated `widget.json`) that are absent on disk. Nothing is
     * written to [output] unless the whole archive was produced.
     */
    fun export(
        packageDirectory: File,
        rootName: String,
        output: OutputStream,
        extraFiles: Map<String, ByteArray> = emptyMap(),
        limits: ArchiveLimits = ArchiveLimits(),
    ) {
        val root = PackageNames.archiveRootName(rootName)
        val files = DiskPackageFiles(packageDirectory)
        val contents = TreeMap<String, ByteArray?>()
        for (path in files.paths()) contents[path] = null
        for ((path, bytes) in extraFiles) {
            if (PackagePathRules.visibleComponents(path) == null) throw PackageException(PackageErrors.INVALID_PATH, "Invalid package path.")
            contents.putIfAbsent(path, bytes)
        }
        if (contents.isEmpty()) throw PackageException(PackageErrors.ARCHIVE_NO_PACKAGE, "A package must contain 1–${limits.maximumFileCount} files.")
        if (contents.size > limits.maximumFileCount) throw PackageException(PackageErrors.TOO_MANY_ENTRIES, "A package must contain 1–${limits.maximumFileCount} files.")

        val buffer = BoundedOutput(limits.maximumArchiveBytes)
        var total = 0L
        ZipOutputStream(buffer, Charsets.UTF_8).use { zip ->
            for ((path, extra) in contents) {
                val name = "$root/$path"
                // The importer would refuse this name, so exporting it would produce a dead archive.
                if (ArchivePreflight.entryParts(name, limits.maximumPathDepth) == null) {
                    throw PackageException(PackageErrors.INVALID_PATH, "Package path $path cannot be exported.")
                }
                val bytes = extra ?: files.readBytes(path, limits.maximumFileBytes)
                    ?: throw PackageException(PackageErrors.FILE_TOO_LARGE, "Package file $path is unreadable or exceeds 25 MiB.")
                if (bytes.size > limits.maximumFileBytes) throw PackageException(PackageErrors.FILE_TOO_LARGE, "Package file $path exceeds 25 MiB.")
                total += bytes.size
                if (total > limits.maximumExpandedBytes) throw PackageException(PackageErrors.PACKAGE_TOO_LARGE, "Expanded package exceeds 64 MiB.")
                val entry = ZipEntry(name)
                entry.setTimeLocal(fixedEntryTime)
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        buffer.writeTo(output)
    }

    private class Selection(val files: List<Pair<List<String>, ArchivePreflight.Entry>>, val rootName: String?)

    /**
     * Chooses the package root like `ScriptManager.extractedPackageRoot`: the archive root when
     * `main.jsx` or `widget.json` sits there, otherwise the only top-level directory.
     */
    private fun select(entries: List<ArchivePreflight.Entry>): Selection {
        val files = entries.filter { entry ->
            !entry.isDirectory && entry.parts[0] != MACOS_RESOURCE_DIRECTORY && entry.parts.none(PackagePathRules::isExcluded)
        }
        if (files.any { it.parts.size == 1 && (it.parts[0] == "main.jsx" || it.parts[0] == "widget.json") }) {
            return Selection(files.map { it.parts to it }, null)
        }
        val roots = files.filter { it.parts.size > 1 }.map { it.parts[0] }.toSet()
        if (roots.size != 1) throw PackageException(PackageErrors.ARCHIVE_NO_PACKAGE, "The archive must contain one widget package.")
        val root = roots.first()
        return Selection(files.filter { it.parts.size > 1 && it.parts[0] == root }.map { it.parts.drop(1) to it }, root)
    }

    private fun readArchive(input: InputStream, limits: ArchiveLimits): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        try {
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                if (output.size() > limits.maximumArchiveBytes) break
            }
        } catch (error: IOException) {
            throw PackageException(PackageErrors.ARCHIVE_CORRUPT, "Archive could not be read.", error)
        }
        if (output.size() == 0 || output.size() > limits.maximumArchiveBytes) {
            throw PackageException(PackageErrors.ARCHIVE_SIZE, "Archive must be between 1 byte and 32 MiB.")
        }
        return output.toByteArray()
    }

    /** Inflates one entry into a new file, counting real bytes; returns the number written. */
    private fun copyEntry(input: InputStream, target: Path, entry: ArchivePreflight.Entry, totalBefore: Long, limits: ArchiveLimits): Long {
        val crc = CRC32()
        var count = 0L
        Files.newOutputStream(target, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = try {
                    input.read(buffer)
                } catch (error: IOException) {
                    corrupt(entry.name, error)
                }
                if (read < 0) break
                count += read
                if (count > entry.uncompressedSize || count > limits.maximumFileBytes) {
                    throw PackageException(PackageErrors.ARCHIVE_SIZE_MISMATCH, "Archive entry ${entry.name} does not match its declared size.")
                }
                if (totalBefore + count > limits.maximumExpandedBytes) {
                    throw PackageException(PackageErrors.ARCHIVE_EXPANDED_TOO_LARGE, "Expanded package exceeds 64 MiB.")
                }
                crc.update(buffer, 0, read)
                output.write(buffer, 0, read)
            }
        }
        if (count != entry.uncompressedSize) {
            throw PackageException(PackageErrors.ARCHIVE_SIZE_MISMATCH, "Archive entry ${entry.name} does not match its declared size.")
        }
        if (crc.value != entry.crc) corrupt(entry.name, null)
        return count
    }

    private fun corrupt(name: String, cause: Throwable?): Nothing =
        throw PackageException(PackageErrors.ARCHIVE_CORRUPT, "Archive entry $name is corrupt.", cause)

    /** In-memory sink that refuses to grow past the archive byte limit. */
    private class BoundedOutput(private val limit: Int) : ByteArrayOutputStream() {
        override fun write(b: Int) {
            ensure(1)
            super.write(b)
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            ensure(len)
            super.write(b, off, len)
        }

        private fun ensure(extra: Int) {
            if (count.toLong() + extra > limit) throw PackageException(PackageErrors.ARCHIVE_SIZE, "Archive exceeds 32 MiB.")
        }
    }
}
