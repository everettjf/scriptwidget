package com.everettjf.scriptwidget.core.pkg

import java.nio.file.Path

/** Whole-tree verification, ported from `ScriptManager.validateExtractedTree` in Swift. */
internal object PackageTree {
    /**
     * Verifies a package directory before it is published or copied.
     *
     * The tree may hold only directories and singly linked regular files: a symbolic link, hard
     * link or special file could reach outside the package. Names must be valid components with
     * no case or normalization collisions, nesting is limited to 16 components, and the entry
     * count, per-file size and total size limits are those of the archive policy. Sizes are the
     * ones the filesystem reports for files this layer wrote or is about to copy with a bound.
     */
    fun validate(root: Path, limits: ArchiveLimits = ArchiveLimits()) {
        if (SafeFiles.realDirectory(root) == null) fail(PackageErrors.UNSAFE_FILE, "Package directory could not be verified.")
        val state = State(limits)
        visit(root, 1, state)
    }

    private class State(val limits: ArchiveLimits) {
        var count = 0
        var total = 0L
    }

    private fun visit(directory: Path, depth: Int, state: State) {
        val names = SafeFiles.names(directory) ?: fail(PackageErrors.UNSAFE_FILE, "Package file could not be verified.")
        for (name in names) {
            if (depth > state.limits.maximumPathDepth || !PackagePathRules.validComponent(name)) fail(PackageErrors.INVALID_PATH, "Invalid package path.")
            if (!SafeFiles.unambiguous(names, name)) fail(PackageErrors.UNSAFE_FILE, "Case-colliding package paths are not allowed.")
            val child = directory.resolve(name)
            val info = SafeFiles.attributes(child) ?: fail(PackageErrors.UNSAFE_FILE, "Package file could not be verified.")
            if (info.isSymbolicLink) fail(PackageErrors.UNSAFE_FILE, "Symbolic links are not allowed.")
            if (!info.isDirectory && !info.isRegularFile) fail(PackageErrors.UNSAFE_FILE, "Only directories and regular files are allowed.")
            state.count += 1
            if (state.count > state.limits.maximumFileCount) fail(PackageErrors.TOO_MANY_ENTRIES, "Package contains too many entries.")
            if (info.isDirectory) {
                visit(child, depth + 1, state)
                continue
            }
            if (!SafeFiles.singlyLinked(child)) fail(PackageErrors.UNSAFE_FILE, "Hard-linked files are not allowed.")
            val size = info.size()
            if (size < 0 || size > state.limits.maximumFileBytes) fail(PackageErrors.FILE_TOO_LARGE, "Package file exceeds 25 MiB.")
            if (state.total > state.limits.maximumExpandedBytes - size) fail(PackageErrors.PACKAGE_TOO_LARGE, "Expanded package exceeds 64 MiB.")
            state.total += size
        }
    }

    private fun fail(code: String, message: String): Nothing = throw PackageException(code, message)
}
