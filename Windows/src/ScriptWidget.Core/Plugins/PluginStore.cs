using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace ScriptWidget.Core.Plugins;

/// <summary>A plugin the store can serve. Built-in plugins ship with the app and have no directory.</summary>
public sealed class InstalledPlugin(PluginManifest manifest, bool builtIn, string? readme)
{
    public PluginManifest Manifest { get; } = manifest;
    public bool BuiltIn { get; } = builtIn;
    public string? Readme { get; } = readme;
}

/// <summary>
/// Installed Data Source Plugins, ported from <c>DataSourcePluginManager</c>.
///
/// Each plugin is a directory below the root holding <c>plugin.json</c> and an optional <c>README.md</c>,
/// nothing else. Imported files are untrusted: they are bounded, validated completely before
/// anything is written, staged in a private directory and published with one rename, so
/// a failed import leaves nothing behind and readers never see a partial plugin.
/// </summary>
public sealed partial class PluginStore
{
    /// <summary><c>DataSourcePluginManager.maximumPackageBytes</c>: the largest archive or manifest accepted for import.</summary>
    public const int MaximumPackageBytes = 512 * 1024;
    /// <summary>Largest <c>README.md</c> stored or shown (Swift bounds it only by the archive limits).</summary>
    public const int MaximumReadmeBytes = 512 * 1024;
    public const string ManifestFile = "plugin.json";
    public const string ReadmeFile = "README.md";
    private const string StagingDirectory = ".staging";
    private const string NotAPackage = "Archive must contain one Data Source Plugin 1.0 package.";
    private static readonly HashSet<string> AllowedFiles = new(StringComparer.Ordinal) { ManifestFile, ReadmeFile };
    private static readonly DateTimeOffset FixedEntryTime = new(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static PluginParameter Parameter(string id, string label, PluginParameterLocation location, bool required, string defaultValue) =>
        new(id, label, location, required, defaultValue);

    /// <summary>The plugins every ScriptWidget build ships, identical to <c>DataSourcePluginManager.builtIns</c>.</summary>
    public static readonly IReadOnlyList<PluginManifest> BuiltIns =
    [
        new PluginManifest(
            FormatVersion: 1, Id: "app.scriptwidget.datasource.open-meteo", Name: "Open-Meteo", Version: "1.0.0",
            Summary: "Weather forecasts without an API key.", Symbol: "cloud.sun", Author: "Open-Meteo", License: "CC BY 4.0",
            MinimumRuntimeVersion: "1.0", BaseURL: "https://api.open-meteo.com", Hosts: ["api.open-meteo.com"],
            Operations: [new PluginOperation("forecast", "Forecast", "GET", "/v1/forecast", PluginResponseType.Json,
            [
                Parameter("latitude", "Latitude", PluginParameterLocation.Query, true, "37.7749"),
                Parameter("longitude", "Longitude", PluginParameterLocation.Query, true, "-122.4194"),
                Parameter("current", "Current fields", PluginParameterLocation.Query, false, "temperature_2m,weather_code"),
                Parameter("timezone", "Timezone", PluginParameterLocation.Query, false, "auto"),
            ])]),
        new PluginManifest(
            FormatVersion: 1, Id: "app.scriptwidget.datasource.github", Name: "GitHub Public API", Version: "1.0.0",
            Summary: "Public repository metadata from GitHub.", Symbol: "chevron.left.forwardslash.chevron.right", Author: "GitHub", License: "API Terms",
            MinimumRuntimeVersion: "1.0", BaseURL: "https://api.github.com", Hosts: ["api.github.com"],
            Operations: [new PluginOperation("repository", "Repository", "GET", "/repos/{owner}/{repo}", PluginResponseType.Json,
            [
                Parameter("owner", "Owner", PluginParameterLocation.Path, true, "everettjf"),
                Parameter("repo", "Repository", PluginParameterLocation.Path, true, "scriptwidget"),
            ])]),
    ];

    private readonly string root;
    private readonly string staging;
    private readonly object gate = new();

    public PluginStore(string root)
    {
        this.root = Path.GetFullPath(root);
        staging = Path.Combine(this.root, StagingDirectory);
    }

    [GeneratedRegex("[^a-z0-9]+", RegexOptions.CultureInvariant)]
    private static partial Regex NotSlug();
    [GeneratedRegex(@"\A(?:con|prn|aux|nul|com[0-9]|lpt[0-9])\z", RegexOptions.CultureInvariant)]
    private static partial Regex DeviceName();

    /// <summary>Built-in plugins not replaced by an installed one, plus installed plugins, sorted by name.</summary>
    public IReadOnlyList<InstalledPlugin> List()
    {
        var custom = new List<InstalledPlugin>();
        var customIDs = new HashSet<string>(StringComparer.Ordinal);
        foreach (var directory in Directories())
        {
            if (Load(directory) is { } manifest && customIDs.Add(manifest.Id)) custom.Add(new InstalledPlugin(manifest, false, ReadText(directory, ReadmeFile, MaximumReadmeBytes)));
        }
        var builtIn = BuiltIns.Where(manifest => !customIDs.Contains(manifest.Id)).Select(manifest => new InstalledPlugin(manifest, true, BuiltInReadme(manifest)));
        return builtIn.Concat(custom).OrderBy(plugin => plugin.Manifest.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    /// The validated manifest for <paramref name="id"/>, or null. A stored manifest is validated again on every
    /// read, so a file altered on disk after import is never used unless it still passes.
    /// </summary>
    public PluginManifest? Manifest(string id)
    {
        foreach (var directory in Directories())
        {
            if (Load(directory) is { } manifest && manifest.Id == id) return manifest;
        }
        return BuiltIns.FirstOrDefault(manifest => manifest.Id == id);
    }

    /// <summary>
    /// Installs a plugin from a <c>.swplugin</c> ZIP archive or a bare <c>plugin.json</c>.
    ///
    /// Security rules, each failing closed with <see cref="PluginException"/>:
    /// - at most 512 KiB of input (<c>DataSourcePluginManager.maximumPackageBytes</c>);
    /// - an archive passes the package archive preflight (no traversal, absolute paths,
    ///   backslashes, symlinks, encrypted entries, case collisions or forged directories);
    /// - the package root (archive root or its single directory) holds only <c>plugin.json</c> and an
    ///   optional <c>README.md</c>, both regular files: a plugin cannot carry code or other payloads;
    /// - entries are inflated with their real sizes counted, never trusting declared sizes, and
    ///   their CRC-32 checked; <c>plugin.json</c> is at most 256 KiB and <c>README.md</c> 512 KiB of UTF-8;
    /// - the manifest passes <see cref="PluginValidator.Decode"/>;
    /// - an id that is already installed or built in is refused rather than replaced.
    /// </summary>
    public PluginManifest Install(Stream input)
    {
        var bytes = ReadBounded(input);
        var (manifestBytes, readme) = IsZip(bytes) ? Unpack(bytes) : (bytes, null);
        var manifest = PluginValidator.Decode(manifestBytes);
        lock (gate)
        {
            if (Manifest(manifest.Id) is not null) throw new PluginException(PluginErrorKind.InvalidManifest, $"Plugin {manifest.Id} is already installed.");
            var work = WorkDirectory("install");
            try
            {
                var prepared = Path.Combine(work, "plugin");
                Directory.CreateDirectory(prepared);
                PluginFiles.WriteNew(Path.Combine(prepared, ManifestFile), manifestBytes);
                if (readme is not null) PluginFiles.WriteNew(Path.Combine(prepared, ReadmeFile), readme);
                PluginFiles.Publish(prepared, UniqueDirectory(manifest.Name));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw Storage("The plugin could not be installed.", error);
            }
            catch (PluginFiles.StorageException error)
            {
                throw Storage(error.Message, error);
            }
            finally
            {
                PluginFiles.DeleteTree(work);
            }
        }
        return manifest;
    }

    /// <summary>
    /// Removes the installed plugin <paramref name="id"/>. The directory is first renamed out of the store, so the
    /// plugin disappears atomically. Built-in plugins cannot be deleted.
    /// </summary>
    public void Delete(string id)
    {
        lock (gate)
        {
            var directory = DirectoryOf(id)
                ?? throw new PluginException(PluginErrorKind.NotFound, BuiltIns.Any(manifest => manifest.Id == id) ? "Built-in plugins cannot be deleted." : "Plugin not found.");
            var work = WorkDirectory("delete");
            try
            {
                Directory.Move(directory, Path.Combine(work, "plugin"));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw Storage("The plugin could not be deleted.", error);
            }
            finally
            {
                PluginFiles.DeleteTree(work);
            }
        }
    }

    /// <summary>
    /// Writes plugin <paramref name="id"/> to <paramref name="output"/> as a <c>.swplugin</c> ZIP with <c>plugin.json</c> and, when present,
    /// <c>README.md</c> at the archive root. Only those two files are ever exported, so nothing else
    /// placed in the plugin directory can leak. Nothing is written unless the archive is complete.
    /// </summary>
    public void Export(string id, Stream output)
    {
        var files = new List<(string Name, byte[] Bytes)>();
        var directory = DirectoryOf(id);
        if (directory is not null)
        {
            files.Add((ManifestFile, ReadBytes(directory, ManifestFile, PluginValidator.MaximumManifestBytes) ?? throw new PluginException(PluginErrorKind.NotFound, "Plugin not found.")));
            if (ReadBytes(directory, ReadmeFile, MaximumReadmeBytes) is { } readme) files.Add((ReadmeFile, readme));
        }
        else
        {
            var builtIn = BuiltIns.FirstOrDefault(manifest => manifest.Id == id) ?? throw new PluginException(PluginErrorKind.NotFound, "Plugin not found.");
            files.Add((ManifestFile, Encoding.UTF8.GetBytes(builtIn.ToJson())));
            files.Add((ReadmeFile, Encoding.UTF8.GetBytes(BuiltInReadme(builtIn))));
        }
        using var buffer = new MemoryStream();
        using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true, entryNameEncoding: Encoding.UTF8))
        {
            foreach (var (name, bytes) in files)
            {
                var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
                entry.LastWriteTime = FixedEntryTime;
                using var stream = entry.Open();
                stream.Write(bytes, 0, bytes.Length);
            }
        }
        try
        {
            buffer.Position = 0;
            buffer.CopyTo(output);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw Storage("Could not create the .swplugin archive.", error);
        }
    }

    // MARK: - Import

    private static byte[] ReadBounded(Stream input)
    {
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        try
        {
            while (output.Length <= MaximumPackageBytes)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count <= 0) break;
                output.Write(buffer, 0, count);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw Storage("The plugin file could not be read.", error);
        }
        if (output.Length > MaximumPackageBytes) throw Invalid("A plugin package may not exceed 512 KiB.");
        if (output.Length == 0) throw Invalid(NotAPackage);
        return output.ToArray();
    }

    private static bool IsZip(byte[] bytes) => bytes.Length >= 4 && bytes[0] == (byte)'P' && bytes[1] == (byte)'K';

    /// <summary>Returns the bytes of <c>plugin.json</c> and <c>README.md</c> (or null) from a validated archive.</summary>
    private static (byte[] Manifest, byte[]? Readme) Unpack(byte[] archive)
    {
        var entries = PluginArchive.Validate(archive);
        // Hidden files and the macOS resource directory are ignored, as in the Swift importer.
        var visible = entries.Where(entry => entry.Parts[0] != "__MACOSX" && !entry.Parts.Any(part => part.StartsWith('.'))).ToList();
        var atRoot = visible.Any(entry => entry.Parts.Count == 1 && !entry.IsDirectory && entry.Parts[0] == ManifestFile);
        var prefix = 0;
        if (!atRoot)
        {
            var roots = visible.Where(entry => entry.Parts.Count > 1 || entry.IsDirectory).Select(entry => entry.Parts[0]).ToHashSet(StringComparer.Ordinal);
            if (roots.Count != 1) throw Invalid(NotAPackage);
            prefix = 1;
        }
        var members = visible.Where(entry => entry.Parts.Count > prefix).ToList();
        if (members.Any(entry => entry.IsDirectory || entry.Parts.Count != prefix + 1 || !AllowedFiles.Contains(entry.Parts[prefix])) || !members.Any(entry => entry.Parts[prefix] == ManifestFile))
        {
            throw Invalid("A plugin package allows only plugin.json and optional README.md.");
        }
        try
        {
            using var zip = new ZipArchive(new MemoryStream(archive, writable: false), ZipArchiveMode.Read, leaveOpen: false, entryNameEncoding: Encoding.UTF8);
            var manifest = Inflate(zip, members.First(entry => entry.Parts[prefix] == ManifestFile), PluginValidator.MaximumManifestBytes, "plugin.json exceeds 256 KiB.");
            var readmeEntry = members.FirstOrDefault(entry => entry.Parts[prefix] == ReadmeFile);
            var readme = readmeEntry is null ? null : Inflate(zip, readmeEntry, MaximumReadmeBytes, "README.md exceeds 512 KiB.");
            if (readme is not null && PluginValidator.DecodeUtf8(readme) is null) throw Invalid("README.md must be UTF-8 text.");
            return (manifest, readme);
        }
        catch (Exception error) when (error is IOException or InvalidDataException or NotSupportedException or ArgumentException)
        {
            throw Invalid("The plugin archive is corrupt.");
        }
    }

    /// <summary>Inflates one entry in memory, counting real bytes so false size headers cannot expand.</summary>
    private static byte[] Inflate(ZipArchive zip, PluginArchive.Entry entry, int maximumBytes, string tooLarge)
    {
        if (entry.UncompressedSize > maximumBytes) throw Invalid(tooLarge);
        return PluginArchive.Inflate(zip, entry, maximumBytes);
    }

    // MARK: - Storage

    /// <summary>Plugin directories: real directories (never links) whose names are not hidden.</summary>
    private List<string> Directories()
    {
        if (PluginFiles.RealDirectory(root) is null) return [];
        return (PluginFiles.Names(root) ?? []).Where(name => !name.StartsWith('.')).Order(StringComparer.Ordinal)
            .Select(name => PluginFiles.RealDirectory(Path.Combine(root, name))).OfType<string>().ToList();
    }

    private string? DirectoryOf(string id) => Directories().FirstOrDefault(directory => Load(directory)?.Id == id);

    private static PluginManifest? Load(string directory)
    {
        if (ReadBytes(directory, ManifestFile, PluginValidator.MaximumManifestBytes) is not { } bytes) return null;
        try { return PluginValidator.Decode(bytes); }
        catch (PluginException) { return null; }
    }

    /// <summary>Reads a regular, singly linked file that is not a symlink and stays inside <paramref name="directory"/>.</summary>
    private static byte[]? ReadBytes(string directory, string name, int maximumBytes) =>
        PluginFiles.ExistingFile(directory, name) is { } file ? PluginFiles.ReadBounded(file, maximumBytes) : null;

    private static string? ReadText(string directory, string name, int maximumBytes) =>
        ReadBytes(directory, name, maximumBytes) is { } bytes ? PluginValidator.DecodeUtf8(bytes) : null;

    private string WorkDirectory(string prefix)
    {
        try
        {
            Directory.CreateDirectory(root);
            return PluginFiles.NewWorkDirectory(staging, prefix);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PluginFiles.StorageException)
        {
            throw Storage("The plugin directory is unavailable.", error);
        }
    }

    /// <summary>Directory names are derived from the plugin name but reduced to <c>[a-z0-9-]</c>, so they cannot traverse.</summary>
    private string UniqueDirectory(string name)
    {
        var slug = NotSlug().Replace(name.ToLowerInvariant(), "-").Trim('-');
        // Windows only: a device name such as "con" or "com1" is not usable as a directory name.
        var baseName = slug.Length == 0 ? "plugin" : DeviceName().IsMatch(slug) ? "plugin-" + slug : slug;
        var path = Path.Combine(root, baseName);
        var index = 2;
        while (PluginFiles.Occupied(path)) { path = Path.Combine(root, $"{baseName}-{index}"); index += 1; }
        return path;
    }

    private static string BuiltInReadme(PluginManifest manifest) => $"# {manifest.Name}\n\n{manifest.Summary}\n";

    private static PluginException Invalid(string message) => new(PluginErrorKind.InvalidManifest, message);

    private static PluginException Storage(string message, Exception cause) => new(PluginErrorKind.Storage, message, cause);
}
