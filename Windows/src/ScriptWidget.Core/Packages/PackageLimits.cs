namespace ScriptWidget.Core.Packages;

/// <summary>Size and shape limits of the package layer, each taken from the Swift implementation.</summary>
public static class PackageLimits
{
    /// <summary><c>ScriptPackageArchivePolicy.maximumArchiveBytes</c>.</summary>
    public const int MaxArchiveBytes = 32 * 1024 * 1024;
    /// <summary><c>ScriptPackageArchivePolicy.maximumExpandedBytes</c>.</summary>
    public const long MaxExpandedBytes = 64L * 1024 * 1024;
    /// <summary><c>ScriptPackageArchivePolicy.maximumFileBytes</c>; also the <c>ScriptWidgetPackageFiles.read/write</c> bound.</summary>
    public const long MaxFileBytes = 25L * 1024 * 1024;
    /// <summary><c>ScriptPackageArchivePolicy.maximumFileCount</c> (files and directories).</summary>
    public const int MaxFileCount = 500;
    /// <summary><c>ScriptPackageArchivePolicy.maximumPathDepth</c>.</summary>
    public const int MaxPathDepth = 16;
    /// <summary>Longest path component in UTF-8 bytes (<c>ScriptWidgetPackageFiles.components</c>).</summary>
    public const int MaxComponentBytes = 255;
    /// <summary>Longest path component in UTF-16 units, the NTFS file name limit (Windows-specific).</summary>
    public const int MaxComponentUnits = 255;
    /// <summary>Longest package-relative path in UTF-16 units, separators included (Windows-specific).</summary>
    public const int MaxRelativePathUnits = 1024;
    /// <summary>
    /// Longest absolute path this layer reads, writes or publishes, in UTF-16 units
    /// (Windows-specific). A package path joined to its install or staging root must fit.
    /// </summary>
    public const int MaxFullPathUnits = 2048;
    /// <summary><c>ScriptWidgetMetadataFile.maximumBytes</c>: bound for <c>widget.json</c> and <c>meta.json</c>.</summary>
    public const int MaxMetadataBytes = 256 * 1024;
    /// <summary><c>ScriptWidgetRuntimeContract.maximumSourceBytes</c>: bound for one script source file.</summary>
    public const int MaxScriptBytes = 512 * 1024;
    /// <summary>Bound for text reads of non-script files through <see cref="DiskPackageFiles.ReadText"/> (as on Android).</summary>
    public const int MaxTextBytes = 2 * 1024 * 1024;
    /// <summary>Bound for <see cref="DiskPackageFiles.ReadBytes(string)"/> (as on Android, below the 25 MiB file limit).</summary>
    public const int MaxBinaryReadBytes = 16 * 1024 * 1024;
    /// <summary>Package names: at most 80 grapheme clusters and 240 UTF-8 bytes (<c>ScriptWidgetPackageName</c>).</summary>
    public const int MaxNameGraphemes = 80;
    public const int MaxNameBytes = 240;
    /// <summary>Most directory entries listed before a listing fails closed (<c>ScriptWidgetPackageFiles.names</c>).</summary>
    public const int MaxDirectoryEntries = 100_000;
    /// <summary><c>getValidPackageName</c> tries the suffixes " (1)" through " (10000)".</summary>
    public const int MaxNameAttempts = 10_000;
}

/// <summary>Archive limits; the defaults are the Swift <c>ScriptPackageArchivePolicy</c>. Tests may shrink them.</summary>
public sealed record ArchiveLimits
{
    public int MaximumArchiveBytes { get; init; } = PackageLimits.MaxArchiveBytes;
    public long MaximumExpandedBytes { get; init; } = PackageLimits.MaxExpandedBytes;
    public long MaximumFileBytes { get; init; } = PackageLimits.MaxFileBytes;
    public int MaximumFileCount { get; init; } = PackageLimits.MaxFileCount;
    public int MaximumPathDepth { get; init; } = PackageLimits.MaxPathDepth;
}
