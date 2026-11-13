package com.everettjf.scriptwidget.core.pkg

/** Size and shape limits of the package layer, each taken from the Swift implementation. */
object PackageLimits {
    /** `ScriptPackageArchivePolicy.maximumArchiveBytes`. */
    const val MAX_ARCHIVE_BYTES: Int = 32 * 1024 * 1024
    /** `ScriptPackageArchivePolicy.maximumExpandedBytes`. */
    const val MAX_EXPANDED_BYTES: Long = 64L * 1024 * 1024
    /** `ScriptPackageArchivePolicy.maximumFileBytes`; also the `ScriptWidgetPackageFiles.read/write` bound. */
    const val MAX_FILE_BYTES: Long = 25L * 1024 * 1024
    /** `ScriptPackageArchivePolicy.maximumFileCount` (files and directories). */
    const val MAX_FILE_COUNT: Int = 500
    /** `ScriptPackageArchivePolicy.maximumPathDepth`. */
    const val MAX_PATH_DEPTH: Int = 16
    /** Longest path component in UTF-8 bytes (`ScriptWidgetPackageFiles.components`). */
    const val MAX_COMPONENT_BYTES: Int = 255
    /** `ScriptWidgetMetadataFile.maximumBytes`: bound for `widget.json` and `meta.json`. */
    const val MAX_METADATA_BYTES: Int = 256 * 1024
    /** `ScriptWidgetRuntimeContract.maximumSourceBytes`: bound for one script source file. */
    const val MAX_SCRIPT_BYTES: Int = 512 * 1024
    /** Bound for text reads of non-script files through [DiskPackageFiles.readText] (Android-specific). */
    const val MAX_TEXT_BYTES: Int = 2 * 1024 * 1024
    /** Bound for [DiskPackageFiles.readBytes] (Android-specific, below the 25 MiB file limit). */
    const val MAX_BINARY_READ_BYTES: Int = 16 * 1024 * 1024
    /** Package names: at most 80 grapheme clusters and 240 UTF-8 bytes (`ScriptWidgetPackageName`). */
    const val MAX_NAME_GRAPHEMES: Int = 80
    const val MAX_NAME_BYTES: Int = 240
    /** Most directory entries listed before a listing fails closed (`ScriptWidgetPackageFiles.names`). */
    const val MAX_DIRECTORY_ENTRIES: Int = 100_000
    /** `getValidPackageName` tries the suffixes " (1)" through " (10000)". */
    const val MAX_NAME_ATTEMPTS: Int = 10_000
}

/** Archive limits; the defaults are the Swift `ScriptPackageArchivePolicy`. Tests may shrink them. */
data class ArchiveLimits(
    val maximumArchiveBytes: Int = PackageLimits.MAX_ARCHIVE_BYTES,
    val maximumExpandedBytes: Long = PackageLimits.MAX_EXPANDED_BYTES,
    val maximumFileBytes: Long = PackageLimits.MAX_FILE_BYTES,
    val maximumFileCount: Int = PackageLimits.MAX_FILE_COUNT,
    val maximumPathDepth: Int = PackageLimits.MAX_PATH_DEPTH,
)
