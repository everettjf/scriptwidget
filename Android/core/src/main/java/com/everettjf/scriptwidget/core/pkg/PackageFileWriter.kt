package com.everettjf.scriptwidget.core.pkg

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID

/** Atomic, path-validated file writes inside one package, ported from `ScriptWidgetPackageFiles.write`. */
internal object PackageFileWriter {
    /**
     * Writes [bytes] to [relativePath] below the package [root].
     *
     * The path must pass the package path rules (no traversal, absolute path, backslash, NUL,
     * dot-file or `__Build` component). Every existing directory on the way must be a real
     * directory, never a link, and no component may have a case alias, so a write cannot be
     * redirected outside the package. An existing target must be a singly linked regular file.
     * Content is limited to 25 MiB (256 KiB for `widget.json`, whose name must be spelled
     * exactly). The bytes go to a hidden temporary file in the target directory, are flushed, and
     * replace the target with one atomic rename: readers see the old or the new content, never a
     * partial file, and a failed write leaves the old content in place.
     */
    fun write(root: Path, relativePath: String, bytes: ByteArray) {
        val parts = PackagePathRules.visibleComponents(relativePath) ?: fail(PackageErrors.INVALID_PATH, "Invalid package path.")
        if (bytes.size > PackageLimits.MAX_FILE_BYTES) fail(PackageErrors.FILE_TOO_LARGE, "Package file exceeds 25 MiB.")
        if (parts.size == 1 && parts[0].lowercase(Locale.ROOT) == PackageManifests.FILE_NAME) {
            if (parts[0] != PackageManifests.FILE_NAME) fail(PackageErrors.INVALID_MANIFEST_CASE, "Use the exact file name widget.json.")
            if (bytes.size > PackageLimits.MAX_METADATA_BYTES) fail(PackageErrors.FILE_TOO_LARGE, "widget.json exceeds 256 KiB.")
        }
        var directory = SafeFiles.realDirectory(root) ?: fail(PackageErrors.PACKAGE_NOT_FOUND, "Package directory is unavailable.")
        for (name in parts.dropLast(1)) {
            requireUnambiguous(directory, name)
            val child = directory.resolve(name)
            val info = SafeFiles.attributes(child)
            if (info == null) {
                try {
                    Files.createDirectory(child)
                } catch (error: IOException) {
                    throw PackageException(PackageErrors.UNSAFE_FILE, "Package directory could not be created.", error)
                }
            } else if (info.isSymbolicLink || !info.isDirectory) {
                fail(PackageErrors.UNSAFE_FILE, "Package path crosses a link or a file.")
            }
            directory = child
        }
        val name = parts.last()
        requireUnambiguous(directory, name)
        val target = directory.resolve(name)
        val existing = SafeFiles.attributes(target)
        if (existing != null && (existing.isSymbolicLink || !existing.isRegularFile || !SafeFiles.singlyLinked(target))) {
            fail(PackageErrors.UNSAFE_FILE, "Only regular package files can be replaced.")
        }
        val temporary = directory.resolve(".write-${UUID.randomUUID()}")
        try {
            // Canonical boundary check on the directory that will receive the file.
            if (!directory.toRealPath().startsWith(root.toRealPath())) fail(PackageErrors.UNSAFE_FILE, "Package path leaves the package.")
            SafeFiles.writeNew(temporary, bytes)
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (error: IOException) {
            throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "Package file could not be saved.", error)
        } finally {
            try {
                Files.deleteIfExists(temporary)
            } catch (_: IOException) {
                // Hidden temporaries are never listed, read or exported.
            }
        }
    }

    private fun requireUnambiguous(directory: Path, name: String) {
        val siblings = SafeFiles.names(directory) ?: fail(PackageErrors.UNSAFE_FILE, "Package directory could not be verified.")
        if (!SafeFiles.unambiguous(siblings, name)) fail(PackageErrors.UNSAFE_FILE, "Case-colliding package paths are not allowed.")
    }

    private fun fail(code: String, message: String): Nothing = throw PackageException(code, message)
}
