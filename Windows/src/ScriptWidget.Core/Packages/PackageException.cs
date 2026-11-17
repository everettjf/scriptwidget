namespace ScriptWidget.Core.Packages;

/// <summary>
/// The single failure type of the package layer. <see cref="Code"/> is a stable machine-readable
/// identifier (see <see cref="PackageErrors"/>); the message is the human-readable explanation,
/// reusing the Swift wording where the Swift implementation has one.
/// </summary>
public sealed class PackageException(string code, string message, Exception? cause = null) : Exception(message, cause)
{
    public string Code { get; } = code;
}

/// <summary>
/// Stable error codes. The manifest codes (<c>invalid_name</c>, <c>invalid_manifest_case</c>,
/// <c>missing_entry</c>) are the ones <c>WidgetPackageManifestValidator</c> and <c>manifest.js</c>
/// emit. The Swift archive preflight reports messages only, so the <c>archive_*</c> codes are
/// defined here.
/// </summary>
public static class PackageErrors
{
    /// <summary>Archive is empty or larger than the archive byte limit.</summary>
    public const string ArchiveSize = "archive_size";
    /// <summary>Missing or garbled central directory, footer, entry header, or ZIP64 metadata.</summary>
    public const string ArchiveMalformed = "archive_malformed";
    public const string ArchiveMultiDisk = "archive_multi_disk";
    public const string ArchiveTooManyEntries = "archive_too_many_entries";
    public const string ArchiveEncrypted = "archive_encrypted";
    public const string ArchiveUnsupportedCompression = "archive_unsupported_compression";
    /// <summary>
    /// Absolute, traversing, backslash, drive-style, NUL, non-UTF-8, or too deeply nested entry
    /// path, or one that Windows cannot store safely (see <see cref="PackagePathRules.WindowsSafe"/>).
    /// </summary>
    public const string ArchiveUnsafePath = "archive_unsafe_path";
    /// <summary>Two entries that are equal after NFC normalization and case folding, or a file/directory clash.</summary>
    public const string ArchivePathCollision = "archive_path_collision";
    public const string ArchiveSymlink = "archive_symlink";
    public const string ArchiveFileTooLarge = "archive_file_too_large";
    public const string ArchiveExpandedTooLarge = "archive_expanded_too_large";
    public const string ArchiveInvalidRatio = "archive_invalid_ratio";
    /// <summary>The inflated byte count differs from the size the central directory declared (zip bomb guard).</summary>
    public const string ArchiveSizeMismatch = "archive_size_mismatch";
    /// <summary>The entry could not be inflated or its CRC-32 does not match.</summary>
    public const string ArchiveCorrupt = "archive_corrupt";
    /// <summary>The archive does not contain exactly one widget package.</summary>
    public const string ArchiveNoPackage = "archive_no_package";

    public const string InvalidName = "invalid_name";
    public const string InvalidManifest = "invalid_manifest";
    public const string InvalidManifestCase = "invalid_manifest_case";
    public const string MissingEntry = "missing_entry";
    public const string InvalidEntry = "invalid_entry";
    public const string InvalidPath = "invalid_path";
    public const string PackageExists = "package_exists";
    public const string PackageNotFound = "package_not_found";
    public const string FileNotFound = "file_not_found";
    public const string FileTooLarge = "file_too_large";
    public const string TooManyEntries = "too_many_entries";
    public const string PackageTooLarge = "package_too_large";
    /// <summary>Symbolic link, junction or other reparse point, hard link, special file, or case alias inside a package tree.</summary>
    public const string UnsafeFile = "unsafe_file";
    /// <summary>The library or staging directory is unusable (missing, a link, or on another volume).</summary>
    public const string StorageUnavailable = "storage_unavailable";
}
