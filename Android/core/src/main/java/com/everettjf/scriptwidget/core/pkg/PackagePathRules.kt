package com.everettjf.scriptwidget.core.pkg

import com.everettjf.scriptwidget.core.runtime.PackagePaths

/** Package-relative path rules, ported from `ScriptWidgetPackageFiles.components` in Swift. */
internal object PackagePathRules {
    private val drivePrefix = Regex("^[A-Za-z]:")

    /**
     * Splits a package-relative path into components, or returns null when it is unsafe.
     *
     * The path must already be in normal form: no leading slash, no empty, `.` or `..` component,
     * no backslash and no NUL (so nothing can name a location outside the package), no Windows
     * drive prefix, at most 16 components of at most 255 UTF-8 bytes each, and no control
     * characters.
     */
    fun components(relative: String?): List<String>? {
        val normalized = PackagePaths.normalize(relative) ?: return null
        if (normalized != relative || drivePrefix.containsMatchIn(normalized)) return null
        val parts = normalized.split('/')
        if (parts.size > PackageLimits.MAX_PATH_DEPTH || !parts.all(::validComponent)) return null
        return parts
    }

    /**
     * [components], additionally refusing dot-files and the generated `__Build` cache at any depth.
     * Those are never part of the authored package, so they are neither listed, read nor written.
     */
    fun visibleComponents(relative: String?): List<String>? = components(relative)?.takeIf { parts -> parts.none(::isExcluded) }

    fun validComponent(part: String): Boolean =
        part.isNotEmpty() && part != "." && part != ".." && !part.contains('/') && !part.contains('\\') &&
            PackageNames.utf8Length(part) <= PackageLimits.MAX_COMPONENT_BYTES && !PackageNames.hasControlCharacters(part)

    fun isExcluded(part: String): Boolean = part.startsWith(".") || PackageNames.identity(part) == "__build"
}
