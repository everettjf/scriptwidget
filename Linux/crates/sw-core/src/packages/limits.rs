//! Size and shape limits of the package layer, each taken from the Swift
//! implementation. Ported from `PackageLimits.cs`; the limits that exist only
//! because of NTFS and Win32 (UTF-16 lengths of a name and of a path) are not
//! here, as on Android.

/// `ScriptPackageArchivePolicy.maximumArchiveBytes`.
pub const MAX_ARCHIVE_BYTES: usize = 32 * 1024 * 1024;
/// `ScriptPackageArchivePolicy.maximumExpandedBytes`.
pub const MAX_EXPANDED_BYTES: u64 = 64 * 1024 * 1024;
/// `ScriptPackageArchivePolicy.maximumFileBytes`; also the bound of a package file read or write.
pub const MAX_FILE_BYTES: u64 = 25 * 1024 * 1024;
/// `ScriptPackageArchivePolicy.maximumFileCount` (files and directories).
pub const MAX_FILE_COUNT: usize = 500;
/// `ScriptPackageArchivePolicy.maximumPathDepth`.
pub const MAX_PATH_DEPTH: usize = 16;
/// Longest path component in UTF-8 bytes (`ScriptWidgetPackageFiles.components`); also the Linux file name limit.
pub const MAX_COMPONENT_BYTES: usize = 255;
/// `ScriptWidgetMetadataFile.maximumBytes`: bound for `widget.json` and `meta.json`.
pub const MAX_METADATA_BYTES: usize = 256 * 1024;
/// `ScriptWidgetRuntimeContract.maximumSourceBytes`: bound for one script source file.
pub const MAX_SCRIPT_BYTES: usize = 512 * 1024;
/// Bound for text reads of non-script files (as on Android).
pub const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
/// Bound for binary reads by the runtime (as on Android, below the 25 MiB file limit).
pub const MAX_BINARY_READ_BYTES: usize = 16 * 1024 * 1024;
/// Package names: at most 80 grapheme clusters and 240 UTF-8 bytes (`ScriptWidgetPackageName`).
pub const MAX_NAME_GRAPHEMES: usize = 80;
pub const MAX_NAME_BYTES: usize = 240;
/// Most directory entries listed before a listing fails closed (`ScriptWidgetPackageFiles.names`).
pub const MAX_DIRECTORY_ENTRIES: usize = 100_000;
/// `getValidPackageName` tries the suffixes " (1)" through " (10000)".
pub const MAX_NAME_ATTEMPTS: usize = 10_000;

/// Archive limits; the defaults are the Swift `ScriptPackageArchivePolicy`. Tests may shrink them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveLimits {
    pub maximum_archive_bytes: usize,
    pub maximum_expanded_bytes: u64,
    pub maximum_file_bytes: u64,
    pub maximum_file_count: usize,
    pub maximum_path_depth: usize,
}

impl Default for ArchiveLimits {
    fn default() -> Self {
        Self {
            maximum_archive_bytes: MAX_ARCHIVE_BYTES,
            maximum_expanded_bytes: MAX_EXPANDED_BYTES,
            maximum_file_bytes: MAX_FILE_BYTES,
            maximum_file_count: MAX_FILE_COUNT,
            maximum_path_depth: MAX_PATH_DEPTH,
        }
    }
}
