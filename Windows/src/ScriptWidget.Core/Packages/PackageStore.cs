using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Packages;

/// <summary>
/// One installed package as shown in the library. The manifest fields are display values read
/// leniently from <c>widget.json</c>; they are null when the manifest is absent, unreadable or the
/// field is not a string. They are not validated.
/// </summary>
/// <param name="Name">The package (directory) name.</param>
/// <param name="Directory">Absolute path of the package directory.</param>
/// <param name="HasManifest">True when any spelling of <c>widget.json</c> is present; such a package is never treated as legacy.</param>
public sealed record PackageInfo(string Name, string Directory, bool HasManifest, string? ManifestId, string? ManifestName, string? ManifestVersion);

/// <summary>
/// The library of installed packages, one directory per package under
/// <c>libraryRoot/&lt;PackageName&gt;/</c>. Ported from <c>ScriptManager</c> in Swift.
///
/// Everything that enters the library is prepared in a unique directory under the staging root
/// and published with one atomic rename, so a failed create, import or duplicate leaves no
/// partial package. The staging root must be on the same volume as the library root and must not
/// be inside it. Package names follow <see cref="PackageNames.IsValid"/>, and a name is usable
/// only when no other library entry has the same identity after case folding and NFC
/// normalization.
///
/// Mutations are serialized per store instance; use one instance per library.
/// </summary>
public sealed partial class PackageStore(string libraryRoot, string stagingRoot, ArchiveLimits? limits = null)
{
    private readonly string library = SafeFiles.Root(libraryRoot);
    private readonly string staging = SafeFiles.Root(stagingRoot);
    private readonly ArchiveLimits limits = limits ?? new ArchiveLimits();
    private readonly Lock gate = new();

    [GeneratedRegex(@"\.(js|jsx)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex EntryFile();

    /// <summary>Installed packages sorted by name. Entries that are links, files, invalid or ambiguous names are not packages.</summary>
    public IReadOnlyList<PackageInfo> List()
    {
        var names = LibraryNames();
        var result = new List<PackageInfo>();
        foreach (var name in names.Order(StringComparer.Ordinal))
        {
            if (!PackageNames.IsValid(name) || !SafeFiles.Unambiguous(names, name)) continue;
            if (SafeFiles.RealDirectory(SafeFiles.Child(library, name)) is { } directory) result.Add(Info(name, directory));
        }
        return result;
    }

    /// <summary>Read-only, boundary-checked view of an installed package.</summary>
    public DiskPackageFiles Files(string name) => new(Existing(name));

    /// <summary>
    /// <paramref name="recommended"/> if it is free, otherwise the first free <c>"&lt;stem&gt; (n)"</c>
    /// for n in 1…10000, with the stem shortened to keep the name limits
    /// (<c>ScriptManager.getValidPackageName</c>).
    /// </summary>
    /// <exception cref="PackageException"><c>invalid_name</c> when <paramref name="recommended"/> is invalid or no name is free.</exception>
    public string UniqueName(string recommended)
    {
        lock (gate)
        {
            RequireValid(recommended);
            var identities = LibraryNames().Select(PackageNames.Identity).ToHashSet(StringComparer.Ordinal);
            bool Available(string name) => PackageNames.IsValid(name) && !identities.Contains(PackageNames.Identity(name));
            if (Available(recommended)) return recommended;
            for (var index = 1; index <= PackageLimits.MaxNameAttempts; index++)
            {
                var candidate = PackageNames.WithSuffix(recommended, $" ({index})");
                if (Available(candidate)) return candidate;
            }
            throw new PackageException(PackageErrors.InvalidName, "No free package name is available.");
        }
    }

    /// <summary>
    /// Creates a package named exactly <paramref name="name"/> from <paramref name="mainSource"/>
    /// and a manifest. Without <paramref name="manifestJson"/> a default Package 2.0 manifest is
    /// generated. The source is written to the manifest's <c>entry</c> (default <c>main.jsx</c>).
    /// The package becomes visible only after source and manifest are fully written.
    ///
    /// <paramref name="manifestJson"/> must be a JSON object of at most 256 KiB with a safe
    /// <c>.js</c>/<c>.jsx</c> entry path; its semantic validation is the caller's responsibility.
    /// </summary>
    /// <exception cref="PackageException"><c>invalid_name</c>, <c>package_exists</c>, <c>invalid_manifest</c>, <c>invalid_entry</c>, <c>file_too_large</c>.</exception>
    public PackageInfo Create(string name, string mainSource, string? manifestJson = null)
    {
        RequireValid(name);
        var source = Encoding.UTF8.GetBytes(mainSource);
        if (source.Length > PackageLimits.MaxScriptBytes) throw new PackageException(PackageErrors.FileTooLarge, "Script source exceeds 512 KiB.");
        byte[] manifestBytes;
        var entry = PackageManifests.LegacyEntry;
        if (manifestJson is null)
        {
            manifestBytes = PackageManifests.Encode(PackageManifests.NewManifest(name));
        }
        else
        {
            manifestBytes = Encoding.UTF8.GetBytes(manifestJson);
            if (manifestBytes.Length > PackageLimits.MaxMetadataBytes) throw new PackageException(PackageErrors.FileTooLarge, "widget.json exceeds 256 KiB.");
            var manifest = PackageManifests.Parse(manifestJson) ?? throw new PackageException(PackageErrors.InvalidManifest, "widget.json is invalid.");
            entry = PackageManifests.StringValue(manifest, "entry") ?? throw new PackageException(PackageErrors.InvalidManifest, "widget.json is invalid.");
            if (PackagePathRules.VisibleComponents(entry) is null || entry == PackageManifests.FileName || !EntryFile().IsMatch(entry))
            {
                throw new PackageException(PackageErrors.InvalidEntry, "entry must be a package-relative .js or .jsx file.");
            }
        }
        return Staged("create", prepared =>
        {
            PackageFileWriter.Write(prepared, entry, source);
            PackageFileWriter.Write(prepared, PackageManifests.FileName, manifestBytes);
            PackageTree.Validate(prepared, limits);
            lock (gate)
            {
                if (!Free(name)) throw new PackageException(PackageErrors.PackageExists, "A package with this name already exists.");
                SafeFiles.Publish(prepared, SafeFiles.Child(library, name));
            }
            return Info(name, SafeFiles.Child(library, name));
        });
    }

    /// <summary>
    /// Imports a <c>.swt</c> archive and returns the installed package.
    ///
    /// The archive is preflighted and extracted by <see cref="PackageArchive.Extract"/>. The
    /// installed directory name comes from the manifest's <c>name</c>, never from the archive file
    /// name; on a collision it gets the next free <c>" (n)"</c> suffix (<see cref="UniqueName"/>).
    /// A package without <c>widget.json</c> is legacy: it must contain <c>main.jsx</c> and receives
    /// a generated manifest named after the archive's top-level directory, or
    /// <paramref name="suggestedName"/> when the files sit at the archive root. A present manifest
    /// is authoritative: a wrongly cased, non-UTF-8, non-object or nameless <c>widget.json</c>
    /// fails the import instead of being reinterpreted as legacy.
    ///
    /// <paramref name="validate"/> runs on the staged package before publication (plug the shared
    /// manifest validator, <see cref="PackageCompiler.ValidateManifest"/>, in here); if it throws,
    /// nothing is installed. A rejected import leaves nothing in the library or the staging
    /// directory.
    /// </summary>
    public PackageInfo ImportArchive(Stream input, string? suggestedName, Action<IPackageFiles>? validate = null)
    {
        using var extracted = PackageArchive.Extract(input, staging, limits);
        var prepared = extracted.Directory;
        var files = new DiskPackageFiles(prepared);
        string name;
        if (ManifestPresent(prepared))
        {
            name = PackageManifests.StringValue(ReadManifest(files), "name") ?? throw new PackageException(PackageErrors.InvalidManifest, "widget.json is invalid.");
            // A package made on another platform may be named with characters Windows reserves.
            name = PackageNames.DirectoryName(name);
        }
        else
        {
            if (!files.Exists(PackageManifests.LegacyEntry)) throw new PackageException(PackageErrors.MissingEntry, "Entry file main.jsx does not exist.");
            name = extracted.RootName ?? (PackageNames.IsValid(suggestedName) ? suggestedName! : "Imported Widget");
            RequireValid(name);
            PackageFileWriter.Write(prepared, PackageManifests.FileName, PackageManifests.Encode(LegacyManifest(name, files)));
        }
        RequireValid(name);
        validate?.Invoke(files);
        lock (gate)
        {
            var installed = UniqueName(name);
            extracted.MoveTo(SafeFiles.Child(library, installed));
            return Info(installed, SafeFiles.Child(library, installed));
        }
    }

    /// <summary>
    /// Replaces a verified Gallery package while keeping its directory and a bounded private
    /// installation marker. Validation finishes before the old package moves; a failed publish
    /// restores it. Identity is rechecked under the mutation lock so an unrelated widget is never replaced.
    /// </summary>
    public PackageInfo ReplaceArchive(string name, Stream input, string expectedId, string installationMarker, Action<IPackageFiles> validate)
    {
        if (installationMarker.Length == 0 || installationMarker.Contains('/') || installationMarker.Contains('\\') || installationMarker is "." or ".." || !PackagePathRules.ValidComponent(installationMarker))
            throw new ArgumentException("Invalid installation marker.", nameof(installationMarker));
        using var extracted = PackageArchive.Extract(input, staging, limits);
        var files = new DiskPackageFiles(extracted.Directory);
        if (!ManifestPresent(extracted.Directory) || PackageManifests.StringValue(ReadManifest(files), "id") != expectedId)
            throw new PackageException(PackageErrors.InvalidManifest, "Replacement package identity does not match.");
        validate(files);
        lock (gate)
        {
            var target = Existing(name);
            if (PackageManifests.StringValue(ReadManifest(new DiskPackageFiles(target)), "id") != expectedId)
                throw new PackageException(PackageErrors.InvalidManifest, "Installed package identity changed.");
            // The marker is never accepted from a download. It is copied only from this installation.
            if (Plugins.PluginFiles.ExistingFile(target, installationMarker) is { } marker && Plugins.PluginFiles.ReadBounded(marker, 4096) is { } bytes)
                Plugins.PluginFiles.WriteNew(Path.Combine(extracted.Directory, installationMarker), bytes);
            var backup = SafeFiles.NewWorkDirectory(staging, "replace-backup");
            var old = SafeFiles.Child(backup, "package");
            var cleanBackup = false;
            try
            {
                Directory.Move(target, old);
                try { extracted.MoveTo(target); }
                catch { Directory.Move(old, target); cleanBackup = true; throw; }
                cleanBackup = true;
                return Info(name, target);
            }
            finally { if (cleanBackup || !Directory.Exists(old)) SafeFiles.DeleteTree(backup); }
        }
    }

    /// <summary>
    /// Exports an installed package as a <c>.swt</c> archive under one top-level directory named
    /// after the package. <c>__Build</c>, dot-files and links are not exported. A legacy package is
    /// exported with a generated <c>widget.json</c> (the installed package is not modified); a
    /// package whose present manifest is unreadable is not exported.
    /// </summary>
    public void ExportArchive(string name, Stream output)
    {
        var directory = Existing(name);
        var files = new DiskPackageFiles(directory);
        var extras = new Dictionary<string, byte[]>();
        if (ManifestPresent(directory))
        {
            ReadManifest(files);
        }
        else
        {
            if (!files.Exists(PackageManifests.LegacyEntry)) throw new PackageException(PackageErrors.MissingEntry, "Entry file main.jsx does not exist.");
            extras[PackageManifests.FileName] = PackageManifests.Encode(LegacyManifest(name, files));
        }
        PackageArchive.Export(directory, name, output, extras, limits);
    }

    /// <summary>
    /// Copies a package to a new <c>"&lt;name&gt; Remix"</c> package (made unique like
    /// <see cref="UniqueName"/>) and returns it. The source tree must be free of links and special
    /// files. <c>__Build</c> and dot-files are not copied. A Package 2.0 copy gets a fresh
    /// <c>id</c> and its new name; a legacy package stays legacy
    /// (<c>ScriptManager.duplicateScript</c>).
    /// </summary>
    public PackageInfo Duplicate(string name)
    {
        var source = Existing(name);
        PackageTree.Validate(source, limits);
        var files = new DiskPackageFiles(source);
        var manifest = ManifestPresent(source) ? ReadManifest(files) : null;
        return Staged("duplicate", prepared =>
        {
            foreach (var path in files.Paths())
            {
                var bytes = files.ReadBytes(path, limits.MaximumFileBytes) ?? throw new PackageException(PackageErrors.UnsafeFile, "Package file could not be verified.");
                PackageFileWriter.Write(prepared, path, bytes);
            }
            lock (gate)
            {
                var copy = UniqueName(PackageNames.WithSuffix(name, " Remix"));
                if (manifest is not null)
                {
                    manifest["id"] = PackageManifests.FreshId();
                    manifest["name"] = copy;
                    PackageFileWriter.Write(prepared, PackageManifests.FileName, PackageManifests.Encode(manifest));
                }
                PackageTree.Validate(prepared, limits);
                SafeFiles.Publish(prepared, SafeFiles.Child(library, copy));
                return Info(copy, SafeFiles.Child(library, copy));
            }
        });
    }

    /// <summary>
    /// Renames a package directory atomically. The manifest is left unchanged, as in Swift.
    /// <paramref name="newName"/> must be valid and free; a change of case only is refused as ambiguous.
    /// </summary>
    public PackageInfo Rename(string name, string newName)
    {
        lock (gate)
        {
            var source = Existing(name);
            RequireValid(newName);
            if (name != newName)
            {
                if (!Free(newName)) throw new PackageException(PackageErrors.PackageExists, "A package with this name already exists.");
                SafeFiles.Publish(source, SafeFiles.Child(library, newName));
            }
            return Info(newName, SafeFiles.Child(library, newName));
        }
    }

    /// <summary>
    /// Deletes a package. The directory first leaves the library with one atomic rename into
    /// staging, so it disappears at once; its contents are then removed without following links.
    /// </summary>
    public void Delete(string name)
    {
        lock (gate)
        {
            var directory = Existing(name);
            try
            {
                var work = SafeFiles.NewWorkDirectory(staging, "delete");
                try
                {
                    Directory.Move(directory, SafeFiles.Child(work, "package"));
                }
                finally
                {
                    SafeFiles.DeleteTree(work);
                }
            }
            catch (Exception error) when (SafeFiles.IsFileError(error) || error is PackageException)
            {
                SafeFiles.DeleteTree(directory);
            }
            if (SafeFiles.Occupied(directory)) throw new PackageException(PackageErrors.StorageUnavailable, "The widget could not be deleted.");
        }
    }

    /// <summary>
    /// Atomically writes one file of an installed package. See <see cref="PackageFileWriter.Write"/>
    /// for the path, link and size rules. A new file is refused once the package holds 500 files.
    /// </summary>
    public void WriteFile(string name, string relativePath, byte[] bytes)
    {
        lock (gate)
        {
            var directory = Existing(name);
            var files = new DiskPackageFiles(directory);
            if (!files.Exists(relativePath) && files.Paths().Count >= limits.MaximumFileCount)
            {
                throw new PackageException(PackageErrors.TooManyEntries, "Package contains too many entries.");
            }
            PackageFileWriter.Write(directory, relativePath, bytes);
        }
    }

    /// <summary>
    /// Bytes of one file of an installed package, at most 25 MiB, under the rules of <see cref="DiskPackageFiles"/>.
    /// </summary>
    /// <exception cref="PackageException"><c>invalid_path</c> for an unsafe path, <c>file_not_found</c> when the file is missing, refused or too large.</exception>
    public byte[] ReadFile(string name, string relativePath)
    {
        var directory = Existing(name);
        if (PackagePathRules.VisibleComponents(relativePath) is null) throw new PackageException(PackageErrors.InvalidPath, "Invalid package path.");
        return new DiskPackageFiles(directory).ReadBytes(relativePath, PackageLimits.MaxFileBytes)
            ?? throw new PackageException(PackageErrors.FileNotFound, $"File not found: {relativePath}");
    }

    /// <summary>Runs <paramref name="build"/> on a fresh staging directory that is removed afterwards unless it was published.</summary>
    private T Staged<T>(string prefix, Func<string, T> build)
    {
        var work = SafeFiles.NewWorkDirectory(staging, prefix);
        try
        {
            var prepared = SafeFiles.Child(work, "package");
            Directory.CreateDirectory(prepared);
            return build(prepared);
        }
        catch (Exception error) when (SafeFiles.IsFileError(error))
        {
            throw new PackageException(PackageErrors.StorageUnavailable, "The package could not be prepared.", error);
        }
        finally
        {
            SafeFiles.DeleteTree(work);
        }
    }

    private List<string> LibraryNames()
    {
        List<string>? names = null;
        try
        {
            Directory.CreateDirectory(library);
            if (SafeFiles.RealDirectory(library) is { } directory) names = SafeFiles.Names(directory);
        }
        catch (Exception error) when (SafeFiles.IsFileError(error))
        {
            names = null;
        }
        return names ?? throw new PackageException(PackageErrors.StorageUnavailable, "The widget library is unavailable.");
    }

    private static void RequireValid(string name)
    {
        if (!PackageNames.IsValid(name)) throw new PackageException(PackageErrors.InvalidName, "Invalid package name.");
    }

    /// <summary>True when no library entry shares the identity of <paramref name="name"/>.</summary>
    private bool Free(string name)
    {
        var identity = PackageNames.Identity(name);
        return !LibraryNames().Any(other => PackageNames.Identity(other) == identity);
    }

    /// <summary>Directory of an installed package: a valid, exactly spelled, unambiguous name that is a real directory.</summary>
    private string Existing(string name)
    {
        RequireValid(name);
        var names = LibraryNames();
        var directory = names.Contains(name) && SafeFiles.Unambiguous(names, name) ? SafeFiles.RealDirectory(SafeFiles.Child(library, name)) : null;
        return directory ?? throw new PackageException(PackageErrors.PackageNotFound, "Package not found.");
    }

    /// <summary>
    /// True when the package has a manifest. Any other spelling of <c>widget.json</c> is an error:
    /// on a case-insensitive platform it would be the manifest, so it must not be skipped as legacy.
    /// </summary>
    private static bool ManifestPresent(string directory)
    {
        var names = SafeFiles.Names(directory) ?? throw new PackageException(PackageErrors.UnsafeFile, "Package directory could not be verified.");
        var spellings = names.Where(name => name.ToLowerInvariant() == PackageManifests.FileName).ToList();
        if (spellings.Any(name => name != PackageManifests.FileName)) throw new PackageException(PackageErrors.InvalidManifestCase, "Use the exact file name widget.json.");
        return spellings.Count > 0;
    }

    private static JsonObject ReadManifest(DiskPackageFiles files)
    {
        var text = files.ReadBytes(PackageManifests.FileName, PackageLimits.MaxMetadataBytes) is { } bytes ? SafeFiles.DecodeUtf8(bytes) : null;
        return PackageManifests.Parse(text) ?? throw new PackageException(PackageErrors.InvalidManifest, "widget.json is invalid.");
    }

    private static JsonObject LegacyManifest(string name, DiskPackageFiles files)
    {
        var metadata = files.ReadBytes(PackageManifests.LegacyMetadata, PackageLimits.MaxMetadataBytes) is { } bytes ? SafeFiles.DecodeUtf8(bytes) : null;
        return PackageManifests.LegacyManifest(name, metadata);
    }

    private static PackageInfo Info(string name, string directory)
    {
        var names = SafeFiles.Names(directory) ?? [];
        var hasManifest = names.Any(entry => entry.ToLowerInvariant() == PackageManifests.FileName);
        PackageManifests.Summary? summary = null;
        if (names.Contains(PackageManifests.FileName))
        {
            var text = new DiskPackageFiles(directory).ReadBytes(PackageManifests.FileName, PackageLimits.MaxMetadataBytes) is { } bytes ? SafeFiles.DecodeUtf8(bytes) : null;
            if (PackageManifests.Parse(text) is { } manifest) summary = PackageManifests.Summarize(manifest);
        }
        return new PackageInfo(name, directory, hasManifest, summary?.Id, summary?.Name, summary?.Version);
    }
}
