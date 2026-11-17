namespace ScriptWidget.Core.Packages;

/// <summary>Atomic, path-validated file writes inside one package, ported from <c>ScriptWidgetPackageFiles.write</c>.</summary>
internal static class PackageFileWriter
{
    /// <summary>
    /// Writes <paramref name="bytes"/> to <paramref name="relativePath"/> below the package
    /// <paramref name="root"/>.
    ///
    /// The path must pass the package path rules (no traversal, absolute path, backslash, NUL,
    /// dot-file or <c>__Build</c> component, and nothing Windows would resolve to a drive, UNC
    /// share, device or alternate data stream). Every existing directory on the way must be a real
    /// directory, never a link or junction, and no component may have a case alias, so a write
    /// cannot be redirected outside the package. An existing target must be a singly linked
    /// regular file. Content is limited to 25 MiB (256 KiB for <c>widget.json</c>, whose name must
    /// be spelled exactly). The bytes go to a hidden temporary file in the target directory, are
    /// flushed, and replace the target with one atomic rename: readers see the old or the new
    /// content, never a partial file, and a failed write leaves the old content in place.
    /// </summary>
    public static void Write(string root, string relativePath, byte[] bytes)
    {
        var parts = PackagePathRules.VisibleComponents(relativePath) ?? throw Fail(PackageErrors.InvalidPath, "Invalid package path.");
        if (bytes.Length > PackageLimits.MaxFileBytes) throw Fail(PackageErrors.FileTooLarge, "Package file exceeds 25 MiB.");
        if (parts.Count == 1 && parts[0].ToLowerInvariant() == PackageManifests.FileName)
        {
            if (parts[0] != PackageManifests.FileName) throw Fail(PackageErrors.InvalidManifestCase, "Use the exact file name widget.json.");
            if (bytes.Length > PackageLimits.MaxMetadataBytes) throw Fail(PackageErrors.FileTooLarge, "widget.json exceeds 256 KiB.");
        }
        var directory = SafeFiles.RealDirectory(root) ?? throw Fail(PackageErrors.PackageNotFound, "Package directory is unavailable.");
        foreach (var name in parts.Take(parts.Count - 1))
        {
            RequireUnambiguous(directory, name);
            var child = SafeFiles.Child(directory, name);
            var info = SafeFiles.Attributes(child);
            if (info is null)
            {
                try
                {
                    // The canonical boundary is checked before anything is created.
                    if (!SafeFiles.Inside(root, child)) throw Fail(PackageErrors.UnsafeFile, "Package path leaves the package.");
                    Directory.CreateDirectory(child);
                }
                catch (Exception error) when (SafeFiles.IsFileError(error))
                {
                    throw new PackageException(PackageErrors.UnsafeFile, "Package directory could not be created.", error);
                }
            }
            else if (info.Value.IsSymbolicLink || !info.Value.IsDirectory)
            {
                throw Fail(PackageErrors.UnsafeFile, "Package path crosses a link or a file.");
            }
            directory = child;
        }
        var fileName = parts[^1];
        RequireUnambiguous(directory, fileName);
        var target = SafeFiles.Child(directory, fileName);
        var existing = SafeFiles.Attributes(target);
        if (existing is { } found && (found.IsSymbolicLink || !found.IsRegularFile || !SafeFiles.SinglyLinked(target)))
        {
            throw Fail(PackageErrors.UnsafeFile, "Only regular package files can be replaced.");
        }
        var temporary = SafeFiles.Child(directory, $".write-{Guid.NewGuid()}");
        try
        {
            // Canonical boundary check on the file that will be written and the directory that receives it.
            if (!SafeFiles.Inside(root, target) || !SafeFiles.Inside(root, temporary)) throw Fail(PackageErrors.UnsafeFile, "Package path leaves the package.");
            SafeFiles.WriteNew(temporary, bytes);
            File.Move(temporary, target, overwrite: true);
        }
        catch (Exception error) when (SafeFiles.IsFileError(error))
        {
            throw new PackageException(PackageErrors.StorageUnavailable, "Package file could not be saved.", error);
        }
        finally
        {
            try
            {
                File.Delete(temporary);
            }
            catch (Exception error) when (SafeFiles.IsFileError(error))
            {
                // Hidden temporaries are never listed, read or exported.
            }
        }
    }

    private static void RequireUnambiguous(string directory, string name)
    {
        var siblings = SafeFiles.Names(directory) ?? throw Fail(PackageErrors.UnsafeFile, "Package directory could not be verified.");
        if (!SafeFiles.Unambiguous(siblings, name)) throw Fail(PackageErrors.UnsafeFile, "Case-colliding package paths are not allowed.");
    }

    private static PackageException Fail(string code, string message) => new(code, message);
}
