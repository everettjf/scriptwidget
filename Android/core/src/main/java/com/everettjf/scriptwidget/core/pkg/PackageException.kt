package com.everettjf.scriptwidget.core.pkg

/**
 * The single failure type of the package layer. [code] is a stable machine-readable identifier
 * (see [PackageErrors]); [message] is the human-readable explanation, reusing the Swift wording
 * where the Swift implementation has one.
 */
class PackageException(val code: String, message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Stable error codes. The manifest codes (`invalid_name`, `invalid_manifest_case`, `missing_entry`)
 * are the ones `WidgetPackageManifestValidator` and `manifest.js` emit. The Swift archive
 * preflight reports messages only, so the `archive_*` codes are defined here.
 */
object PackageErrors {
    /** Archive is empty or larger than the archive byte limit. */
    const val ARCHIVE_SIZE = "archive_size"
    /** Missing or garbled central directory, footer, entry header, or ZIP64 metadata. */
    const val ARCHIVE_MALFORMED = "archive_malformed"
    const val ARCHIVE_MULTI_DISK = "archive_multi_disk"
    const val ARCHIVE_TOO_MANY_ENTRIES = "archive_too_many_entries"
    const val ARCHIVE_ENCRYPTED = "archive_encrypted"
    const val ARCHIVE_UNSUPPORTED_COMPRESSION = "archive_unsupported_compression"
    /** Absolute, traversing, backslash, drive-style, NUL, non-UTF-8, or too deeply nested entry path. */
    const val ARCHIVE_UNSAFE_PATH = "archive_unsafe_path"
    /** Two entries that are equal after NFC normalization and case folding, or a file/directory clash. */
    const val ARCHIVE_PATH_COLLISION = "archive_path_collision"
    const val ARCHIVE_SYMLINK = "archive_symlink"
    const val ARCHIVE_FILE_TOO_LARGE = "archive_file_too_large"
    const val ARCHIVE_EXPANDED_TOO_LARGE = "archive_expanded_too_large"
    const val ARCHIVE_INVALID_RATIO = "archive_invalid_ratio"
    /** The inflated byte count differs from the size the central directory declared (zip bomb guard). */
    const val ARCHIVE_SIZE_MISMATCH = "archive_size_mismatch"
    /** The entry could not be inflated or its CRC-32 does not match. */
    const val ARCHIVE_CORRUPT = "archive_corrupt"
    /** The archive does not contain exactly one widget package. */
    const val ARCHIVE_NO_PACKAGE = "archive_no_package"

    const val INVALID_NAME = "invalid_name"
    const val INVALID_MANIFEST = "invalid_manifest"
    const val INVALID_MANIFEST_CASE = "invalid_manifest_case"
    const val MISSING_ENTRY = "missing_entry"
    const val INVALID_ENTRY = "invalid_entry"
    const val INVALID_PATH = "invalid_path"
    const val PACKAGE_EXISTS = "package_exists"
    const val PACKAGE_NOT_FOUND = "package_not_found"
    const val FILE_NOT_FOUND = "file_not_found"
    const val FILE_TOO_LARGE = "file_too_large"
    const val TOO_MANY_ENTRIES = "too_many_entries"
    const val PACKAGE_TOO_LARGE = "package_too_large"
    /** Symbolic link, hard link, special file, or case alias inside a package tree. */
    const val UNSAFE_FILE = "unsafe_file"
    /** The library or staging directory is unusable (missing, a link, or on another filesystem). */
    const val STORAGE_UNAVAILABLE = "storage_unavailable"
}
