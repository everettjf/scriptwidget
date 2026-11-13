package com.everettjf.scriptwidget.core.pkg

import com.everettjf.scriptwidget.core.runtime.PackageCompiler
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import java.io.File
import java.nio.file.Path

/**
 * Read-only view of one package directory on disk.
 *
 * Every path is package-relative and must already be normalized. A path is refused (reported as
 * missing) when it is absolute, contains a backslash, NUL, `.`/`..` or empty component, names a
 * dot-file or the generated `__Build` cache, crosses a symbolic link at any component, has a
 * case or Unicode-normalization alias in its directory, is a hard-linked or special file, or
 * resolves canonically outside [root]. Reads are size-bounded while reading.
 */
class DiskPackageFiles(root: File) : PackageFiles {
    private val root: Path = root.toPath().toAbsolutePath().normalize()

    /**
     * Regular files of the package as sorted, normalized relative paths. Dot-files and
     * dot-directories, `__Build`, symbolic links, special files, hard-linked files, ambiguous
     * spellings and anything deeper than 16 components are left out.
     *
     * @throws PackageException `too_many_entries` when the package holds more than 500 files.
     */
    override fun paths(): List<String> {
        val result = ArrayList<String>()
        SafeFiles.realDirectory(root)?.let { collect(it, "", 1, result) }
        return result.sorted()
    }

    /** True only for a regular file inside the package that passes every rule in the class description. */
    override fun exists(path: String): Boolean = resolve(path) != null

    /**
     * UTF-8 text of a text-like file (per [PackageCompiler.isTextFile]), or null when the file is
     * missing, refused, binary, not valid UTF-8, or larger than 512 KiB for scripts and 2 MiB for
     * other text.
     */
    override fun readText(path: String): String? {
        if (!PackageCompiler.isTextFile(path)) return null
        val limit = if (scriptFile.containsMatchIn(path)) PackageLimits.MAX_SCRIPT_BYTES else PackageLimits.MAX_TEXT_BYTES
        return readBytes(path, limit.toLong())?.let(SafeFiles::decodeUtf8)
    }

    /** Bytes of a file, or null when it is missing, refused, or larger than 16 MiB. */
    override fun readBytes(path: String): ByteArray? = readBytes(path, PackageLimits.MAX_BINARY_READ_BYTES.toLong())

    /** [readBytes] with an explicit bound, for callers with their own limit (manifest, export). */
    internal fun readBytes(path: String, maximumBytes: Long): ByteArray? = resolve(path)?.let { SafeFiles.readBounded(it, maximumBytes) }

    private fun resolve(path: String): Path? {
        val parts = PackagePathRules.visibleComponents(path) ?: return null
        return SafeFiles.existingFile(root, parts)
    }

    private fun collect(directory: Path, prefix: String, depth: Int, result: MutableList<String>) {
        if (depth > PackageLimits.MAX_PATH_DEPTH) return
        val names = SafeFiles.names(directory) ?: return
        for (name in names) {
            if (PackagePathRules.isExcluded(name) || !PackagePathRules.validComponent(name) || !SafeFiles.unambiguous(names, name)) continue
            val child = directory.resolve(name)
            val info = SafeFiles.attributes(child) ?: continue
            if (info.isSymbolicLink) continue
            if (info.isDirectory) {
                collect(child, "$prefix$name/", depth + 1, result)
            } else if (info.isRegularFile && SafeFiles.singlyLinked(child)) {
                result.add(prefix + name)
                if (result.size > PackageLimits.MAX_FILE_COUNT) {
                    throw PackageException(PackageErrors.TOO_MANY_ENTRIES, "Package contains too many entries.")
                }
            }
        }
    }

    internal companion object {
        private val scriptFile = Regex("\\.(jsx?|mjs)$", RegexOption.IGNORE_CASE)
    }
}
