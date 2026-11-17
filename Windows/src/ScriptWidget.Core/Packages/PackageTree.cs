namespace ScriptWidget.Core.Packages;

/// <summary>Whole-tree verification, ported from <c>ScriptManager.validateExtractedTree</c> in Swift.</summary>
internal static class PackageTree
{
    /// <summary>
    /// Verifies a package directory before it is published or copied.
    ///
    /// The tree may hold only directories and singly linked regular files: a symbolic link,
    /// junction, hard link or special file could reach outside the package. Names must be valid
    /// components with no case or normalization collisions, nesting is limited to 16 components,
    /// and the entry count, per-file size and total size limits are those of the archive policy.
    /// Sizes are the ones the filesystem reports for files this layer wrote or is about to copy
    /// with a bound.
    /// </summary>
    public static void Validate(string root, ArchiveLimits? limits = null)
    {
        if (SafeFiles.RealDirectory(root) is null) throw Fail(PackageErrors.UnsafeFile, "Package directory could not be verified.");
        Visit(root, 1, new State(limits ?? new ArchiveLimits()));
    }

    private sealed class State(ArchiveLimits limits)
    {
        public ArchiveLimits Limits { get; } = limits;
        public int Count;
        public long Total;
    }

    private static void Visit(string directory, int depth, State state)
    {
        var names = SafeFiles.Names(directory) ?? throw Fail(PackageErrors.UnsafeFile, "Package file could not be verified.");
        foreach (var name in names)
        {
            if (depth > state.Limits.MaximumPathDepth || !PackagePathRules.ValidComponent(name)) throw Fail(PackageErrors.InvalidPath, "Invalid package path.");
            if (!SafeFiles.Unambiguous(names, name)) throw Fail(PackageErrors.UnsafeFile, "Case-colliding package paths are not allowed.");
            var child = SafeFiles.Child(directory, name);
            var info = SafeFiles.Attributes(child) ?? throw Fail(PackageErrors.UnsafeFile, "Package file could not be verified.");
            if (info.IsSymbolicLink) throw Fail(PackageErrors.UnsafeFile, "Symbolic links are not allowed.");
            if (!info.IsDirectory && !info.IsRegularFile) throw Fail(PackageErrors.UnsafeFile, "Only directories and regular files are allowed.");
            state.Count += 1;
            if (state.Count > state.Limits.MaximumFileCount) throw Fail(PackageErrors.TooManyEntries, "Package contains too many entries.");
            if (info.IsDirectory)
            {
                Visit(child, depth + 1, state);
                continue;
            }
            if (!SafeFiles.SinglyLinked(child)) throw Fail(PackageErrors.UnsafeFile, "Hard-linked files are not allowed.");
            var size = info.Size;
            if (size < 0 || size > state.Limits.MaximumFileBytes) throw Fail(PackageErrors.FileTooLarge, "Package file exceeds 25 MiB.");
            if (state.Total > state.Limits.MaximumExpandedBytes - size) throw Fail(PackageErrors.PackageTooLarge, "Expanded package exceeds 64 MiB.");
            state.Total += size;
        }
    }

    private static PackageException Fail(string code, string message) => new(code, message);
}
