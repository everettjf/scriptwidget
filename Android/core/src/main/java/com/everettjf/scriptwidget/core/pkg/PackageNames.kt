package com.everettjf.scriptwidget.core.pkg

import java.text.BreakIterator
import java.text.Normalizer
import java.util.Locale

/**
 * Package (library directory) names, ported from `validPackageName` in `manifest.js` and
 * `ScriptWidgetPackageName.isValid` in Swift.
 */
object PackageNames {
    private val drivePrefix = Regex("^[A-Za-z]:")
    private val controlOrFormat = Regex("[\\p{Cc}\\p{Cf}\\p{Cs}]")
    private val archiveUnsafe = Regex("[\\\\/:*?\"<>|\\x00]")

    /**
     * The identity two names share when a case-insensitive or normalizing filesystem would treat
     * them as one entry: NFC, then locale-independent lower case
     * (`ScriptWidgetPackageFiles.identity`).
     */
    fun identity(name: String): String = Normalizer.normalize(name, Normalizer.Form.NFC).lowercase(Locale.ROOT)

    /**
     * True when [name] may be used as a package name and directory name.
     *
     * Rejects blank names, a leading dot (hidden files, `.`/`..`), the reserved `__Build` cache
     * name in any case, path separators, Windows drive prefixes, and control/format characters
     * other than ZWNJ/ZWJ, so a display name can never become a traversal or a cache path.
     * Length is bounded to 80 grapheme clusters and 240 UTF-8 bytes.
     */
    fun isValid(name: String?): Boolean {
        if (name == null || name.isBlank() || name.startsWith(".")) return false
        if (identity(name) == "__build" || name.contains('/') || name.contains('\\') || drivePrefix.containsMatchIn(name)) return false
        if (hasControlCharacters(name)) return false
        return graphemeCount(name) <= PackageLimits.MAX_NAME_GRAPHEMES && utf8Length(name) <= PackageLimits.MAX_NAME_BYTES
    }

    /** Control, format (except ZWNJ/ZWJ, which joined emoji and some scripts need) or unpaired surrogate characters. */
    internal fun hasControlCharacters(text: String): Boolean =
        controlOrFormat.containsMatchIn(text.replace("‌", "").replace("‍", ""))

    internal fun utf8Length(text: String): Int = text.toByteArray(Charsets.UTF_8).size

    internal fun graphemeCount(text: String): Int = graphemeBoundaries(text).size - 1

    /**
     * [name] followed by [suffix], with the stem shortened by whole grapheme clusters until the
     * result fits the name limits. This is the truncation `getValidPackageName` and
     * `duplicateScript` apply in Swift.
     */
    internal fun withSuffix(name: String, suffix: String): String {
        val bounds = graphemeBoundaries(name)
        var keep = minOf(bounds.size - 1, maxOf(0, PackageLimits.MAX_NAME_GRAPHEMES - graphemeCount(suffix)))
        while (keep > 0 && utf8Length(name.substring(0, bounds[keep]) + suffix) > PackageLimits.MAX_NAME_BYTES) keep -= 1
        return name.substring(0, bounds[keep]) + suffix
    }

    /** `WidgetPackageManifest.legacy`: the identifier of a package that had no `widget.json`. */
    internal fun legacyId(name: String): String {
        val slug = name.lowercase(Locale.ROOT).replace(Regex("[^a-z0-9]+"), "-").trim('-')
        return "legacy." + slug.ifEmpty { "widget" }
    }

    /** `packageDirectoryName` in `archive.js`: a root directory name every platform's importer accepts. */
    internal fun archiveRootName(name: String): String =
        name.replace(archiveUnsafe, "-").replace(Regex("^\\.+"), "").trim().take(80).ifEmpty { "Widget" }

    private fun graphemeBoundaries(text: String): List<Int> {
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(text)
        val bounds = ArrayList<Int>()
        var index = iterator.first()
        while (index != BreakIterator.DONE) {
            bounds.add(index)
            index = iterator.next()
        }
        return bounds
    }
}
