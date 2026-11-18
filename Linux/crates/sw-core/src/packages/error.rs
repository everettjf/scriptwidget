//! The single failure type of the package layer. Ported from
//! `Windows/src/ScriptWidget.Core/Packages/PackageException.cs`.

use std::fmt;

/// A failure of the package layer. `code` is a stable machine-readable
/// identifier (see [`codes`]); `message` is the explanation for a person,
/// with the wording of the Swift implementation where it has one.
#[derive(Debug)]
pub struct PackageError {
    pub code: String,
    pub message: String,
    /// The filesystem error behind the failure, when there was one.
    pub cause: Option<std::io::Error>,
}

impl PackageError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_owned(), message: message.into(), cause: None }
    }

    pub(crate) fn caused(code: &str, message: impl Into<String>, cause: impl Into<std::io::Error>) -> Self {
        Self { code: code.to_owned(), message: message.into(), cause: Some(cause.into()) }
    }
}

impl fmt::Display for PackageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for PackageError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.cause.as_ref().map(|cause| cause as _)
    }
}

/// Stable error codes, the same strings as on Windows and Android. The
/// manifest codes (`invalid_name`, `invalid_manifest_case`, `missing_entry`)
/// are the ones `WidgetPackageManifestValidator` and `manifest.js` emit. The
/// Swift archive preflight reports messages only, so the `archive_*` codes
/// were defined by the Android port.
pub mod codes {
    /// Archive is empty or larger than the archive byte limit.
    pub const ARCHIVE_SIZE: &str = "archive_size";
    /// Missing or garbled central directory, footer, entry header, or ZIP64 metadata.
    pub const ARCHIVE_MALFORMED: &str = "archive_malformed";
    pub const ARCHIVE_MULTI_DISK: &str = "archive_multi_disk";
    pub const ARCHIVE_TOO_MANY_ENTRIES: &str = "archive_too_many_entries";
    pub const ARCHIVE_ENCRYPTED: &str = "archive_encrypted";
    pub const ARCHIVE_UNSUPPORTED_COMPRESSION: &str = "archive_unsupported_compression";
    /// Absolute, traversing, backslash, colon, NUL, non-UTF-8, or too deeply nested entry path.
    pub const ARCHIVE_UNSAFE_PATH: &str = "archive_unsafe_path";
    /// Two entries that are equal after NFC normalization and case folding, or a file/directory clash.
    pub const ARCHIVE_PATH_COLLISION: &str = "archive_path_collision";
    pub const ARCHIVE_SYMLINK: &str = "archive_symlink";
    pub const ARCHIVE_FILE_TOO_LARGE: &str = "archive_file_too_large";
    pub const ARCHIVE_EXPANDED_TOO_LARGE: &str = "archive_expanded_too_large";
    pub const ARCHIVE_INVALID_RATIO: &str = "archive_invalid_ratio";
    /// The inflated byte count differs from the size the central directory declared (zip bomb guard).
    pub const ARCHIVE_SIZE_MISMATCH: &str = "archive_size_mismatch";
    /// The entry could not be inflated or its CRC-32 does not match.
    pub const ARCHIVE_CORRUPT: &str = "archive_corrupt";
    /// The archive does not contain exactly one widget package.
    pub const ARCHIVE_NO_PACKAGE: &str = "archive_no_package";

    pub const INVALID_NAME: &str = "invalid_name";
    pub const INVALID_MANIFEST: &str = "invalid_manifest";
    pub const INVALID_MANIFEST_CASE: &str = "invalid_manifest_case";
    pub const MISSING_ENTRY: &str = "missing_entry";
    pub const INVALID_ENTRY: &str = "invalid_entry";
    pub const INVALID_PATH: &str = "invalid_path";
    pub const PACKAGE_EXISTS: &str = "package_exists";
    pub const PACKAGE_NOT_FOUND: &str = "package_not_found";
    pub const FILE_NOT_FOUND: &str = "file_not_found";
    pub const FILE_TOO_LARGE: &str = "file_too_large";
    pub const TOO_MANY_ENTRIES: &str = "too_many_entries";
    pub const PACKAGE_TOO_LARGE: &str = "package_too_large";
    /// Symbolic link, hard link, special file, or case alias inside a package tree.
    pub const UNSAFE_FILE: &str = "unsafe_file";
    /// The library or staging directory is unusable (missing, a link, or on another filesystem).
    pub const STORAGE_UNAVAILABLE: &str = "storage_unavailable";
}
