using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Hosting;

/// <summary>One installed package. <see cref="Installation"/> stays the same when the package is renamed.</summary>
public sealed class InstalledPackage(string name, string directory, string installation, JsonObject? manifest, bool manifestPresent)
{
    public string Name { get; } = name;
    public string Directory { get; } = directory;
    public string Installation { get; } = installation;
    public JsonObject? Manifest { get; } = manifest;
    /// <summary>True when widget.json exists, readable or not. A present manifest that cannot be read fails closed.</summary>
    public bool ManifestPresent { get; } = manifestPresent;

    public IPackageFiles Files => new DiskPackageFiles(Directory);
    public string BuildDirectory => Path.Combine(Directory, "__Build");
    public string DisplayName => Manifest.OptString("name") is { Length: > 0 } title ? title : Name;
    public string Description => Manifest.OptString("description");
    public IReadOnlyList<string> Permissions => Manifest.OptArray("permissions")?.Select(item => item?.AsText() ?? "").ToList() ?? [];
    /// <summary>Widget sizes the manifest lists that Windows can show; every size when it lists none.</summary>
    public IReadOnlyList<string> Families
    {
        get
        {
            // The manifest uses the WidgetKit names ("systemMedium"); $getenv("widget-size") uses the short ones.
            var declared = Manifest.OptArray("supportedFamilies")?.Select(item => WidgetFamilies.FromManifest(item?.AsText() ?? "")).OfType<string>().Distinct().ToList();
            return declared is { Count: > 0 } ? WidgetFamilies.All.Where(declared.Contains).ToList() : WidgetFamilies.All;
        }
    }
}

/// <summary>A template or example shipped with the application.</summary>
public sealed record BundledPackage(string Group, string Name, string Directory);

/// <summary>
/// The user's widget library under the data folder, plus the read-only
/// templates shipped with the application. All package I/O goes through the
/// hardened <see cref="PackageStore"/>.
/// </summary>
public sealed partial class Library
{
    public const string InstallationFile = ".scriptwidget-installation";

    private readonly string root;
    private readonly string templates;

    /// <param name="templatesDirectory">Folder with the bundled templates; defaults to <c>templates</c> next to the program.</param>
    public Library(DataPaths paths, string? templatesDirectory = null)
    {
        root = paths.Packages;
        templates = templatesDirectory ?? Path.Combine(AppContext.BaseDirectory, "templates");
        System.IO.Directory.CreateDirectory(root);
        Store = new PackageStore(root, Path.Combine(paths.Cache, "package-staging"));
    }

    public PackageStore Store { get; }
    public string Root => root;

    /// <summary>Raised after packages were added, removed, renamed or edited.</summary>
    public event Action? Changed;

    public IReadOnlyList<InstalledPackage> List() => Store.List().OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase).Select(Describe).ToList();

    public InstalledPackage? Find(string name) => Store.List().FirstOrDefault(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) is { } found ? Describe(found) : null;

    public InstalledPackage? FindByInstallation(string installation) => List().FirstOrDefault(item => item.Installation == installation);

    private InstalledPackage Describe(PackageInfo info)
    {
        JsonObject? manifest = null;
        var present = false;
        try
        {
            var file = new FileInfo(Path.Combine(info.Directory, PackageManifests.FileName));
            present = file.Exists;
            if (present && file.Length < PackageLimits.MaxMetadataBytes) manifest = PackageManifests.Parse(File.ReadAllText(file.FullName, Encoding.UTF8));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return new InstalledPackage(info.Name, info.Directory, Installation(info.Directory), manifest, present);
    }

    /// <summary>Stable identity kept in a dot-file, which package listings and exports skip.</summary>
    private static string Installation(string directory)
    {
        var marker = Path.Combine(directory, InstallationFile);
        try
        {
            if (File.Exists(marker) && new FileInfo(marker).Length <= 256)
            {
                var existing = File.ReadAllText(marker, Encoding.UTF8).Trim();
                if (existing.Length is >= 8 and <= 64 && existing.All(character => char.IsAsciiLetterOrDigit(character) || character == '-')) return existing;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        var created = Guid.NewGuid().ToString();
        try { File.WriteAllText(marker, created, new UTF8Encoding(false)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return created;
    }

    private static void ForgetInstallation(string directory)
    {
        try { File.Delete(Path.Combine(directory, InstallationFile)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Creates a package; a taken name gets a numbered suffix.</summary>
    public InstalledPackage Create(string name, string source, string? manifest = null)
    {
        var created = Describe(Store.Create(Store.UniqueName(name), source, manifest));
        Changed?.Invoke();
        return created;
    }

    /// <param name="validate">Checks the unpacked files before they are installed; throw to refuse the package.</param>
    public InstalledPackage ImportArchive(Stream input, string suggestedName, Action<IPackageFiles>? validate = null)
    {
        var info = Store.ImportArchive(input, suggestedName, validate);
        // An archive never carries another installation's identity.
        ForgetInstallation(info.Directory);
        var installed = Describe(info);
        Changed?.Invoke();
        return installed;
    }

    public void ExportArchive(string name, Stream output) => Store.ExportArchive(name, output);

    public void Delete(string name)
    {
        Store.Delete(name);
        Changed?.Invoke();
    }

    public InstalledPackage Rename(string name, string newName)
    {
        var renamed = Describe(Store.Rename(name, newName));
        Changed?.Invoke();
        return renamed;
    }

    public InstalledPackage Duplicate(string name)
    {
        var copy = Store.Duplicate(name);
        ForgetInstallation(copy.Directory);
        var installed = Describe(copy);
        Changed?.Invoke();
        return installed;
    }

    public void WriteFile(string name, string path, byte[] bytes)
    {
        Store.WriteFile(name, path, bytes);
        ClearBuild(name);
        Changed?.Invoke();
    }

    /// <summary>Removes the compiled-artifact cache of a package.</summary>
    public void ClearBuild(string name)
    {
        if (Find(name) is not { } installed) return;
        try { if (System.IO.Directory.Exists(installed.BuildDirectory)) System.IO.Directory.Delete(installed.BuildDirectory, true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    // MARK: - Bundled templates

    /// <summary>
    /// Script globals Windows does not implement in this release. A template
    /// that uses one would only show "not supported", so it is left out of
    /// the template list.
    /// </summary>
    [GeneratedRegex(@"\$(health|calendar|reminders|photos|contacts|home|icloud|alarms|maps|services|music|notifications|location|documents)\b")]
    private static partial Regex UnsupportedAPI();

    /// <summary>True for a script global without the dollar sign, such as <c>health</c>, that Windows does not implement in this release.</summary>
    public static bool IsUnsupportedApi(string name) => UnsupportedAPI().IsMatch("$" + name) && UnsupportedAPI().Match("$" + name).Length == name.Length + 1;

    /// <summary>The bundled templates that can run on Windows, grouped as the Apple apps group them.</summary>
    public IReadOnlyList<BundledPackage> Bundled()
    {
        var result = new List<BundledPackage>();
        foreach (var group in new[] { "template", "component", "api" })
        {
            var directory = Path.Combine(templates, group);
            if (!System.IO.Directory.Exists(directory)) continue;
            foreach (var package in System.IO.Directory.EnumerateDirectories(directory).OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase))
            {
                var main = Path.Combine(package, PackageManifests.LegacyEntry);
                if (!File.Exists(main)) continue;
                try { if (UnsupportedAPI().IsMatch(File.ReadAllText(main, Encoding.UTF8))) continue; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
                result.Add(new BundledPackage(group, Path.GetFileName(package), package));
            }
        }
        return result;
    }

    /// <summary>Files of a bundled package as (relative path, bytes).</summary>
    public IReadOnlyDictionary<string, byte[]> BundledFiles(BundledPackage bundled)
    {
        var result = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        void Visit(string directory, string relative)
        {
            foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos().OrderBy(item => item.Name, StringComparer.Ordinal))
            {
                if (entry.Name.StartsWith('.') || entry.Name == "__Build" || entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                var path = relative.Length == 0 ? entry.Name : relative + "/" + entry.Name;
                if (entry is DirectoryInfo) Visit(entry.FullName, path);
                else if (entry is FileInfo { Length: <= PackageLimits.MaxFileBytes }) result[path] = File.ReadAllBytes(entry.FullName);
            }
        }
        Visit(bundled.Directory, "");
        return result;
    }

    /// <summary>
    /// The manifest for a bundled template that has no <c>widget.json</c>. A copy in the library always
    /// has a manifest, and a manifest without <c>network</c> stops every request, so the hosts the
    /// template names in its own source are declared for it. This is done only for the templates
    /// shipped with the app, never for an imported package.
    /// </summary>
    public static JsonObject BundledManifest(string name, IReadOnlyDictionary<string, byte[]> files)
    {
        var metadata = files.TryGetValue(PackageManifests.LegacyMetadata, out var bytes) ? Encoding.UTF8.GetString(bytes) : null;
        var manifest = PackageManifests.LegacyManifest(name, metadata);
        manifest["id"] = PackageManifests.FreshId();
        var hosts = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var (path, content) in files)
        {
            if (!path.EndsWith(".js", StringComparison.Ordinal) && !path.EndsWith(".jsx", StringComparison.Ordinal)) continue;
            foreach (var line in Encoding.UTF8.GetString(content).Split('\n'))
            {
                if (line.TrimStart().StartsWith("//", StringComparison.Ordinal)) continue;
                foreach (Match match in SourceUrl().Matches(line))
                {
                    var host = match.Groups[1].Value.ToLowerInvariant();
                    if (DeclarableHost().IsMatch(host)) hosts.Add(host);
                }
            }
        }
        if (hosts.Count > 0)
        {
            manifest["permissions"] = Json.Array(["network"]);
            manifest["networkDomains"] = Json.Array(hosts);
        }
        return manifest;
    }

    [GeneratedRegex(@"https?://([A-Za-z0-9.-]+)")]
    private static partial Regex SourceUrl();

    [GeneratedRegex(@"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$")]
    private static partial Regex DeclarableHost();

    public InstalledPackage InstallBundled(BundledPackage bundled)
    {
        var files = BundledFiles(bundled);
        if (!files.TryGetValue(PackageManifests.LegacyEntry, out var main)) throw new PackageException(PackageErrors.MissingEntry, "Template has no main.jsx");
        var name = Store.UniqueName(bundled.Name);
        var manifest = files.TryGetValue(PackageManifests.FileName, out var manifestBytes)
            ? Encoding.UTF8.GetString(manifestBytes)
            : Encoding.UTF8.GetString(PackageManifests.Encode(BundledManifest(name, files)));
        var created = Store.Create(name, Encoding.UTF8.GetString(main), manifest);
        foreach (var (path, bytes) in files)
        {
            if (path != PackageManifests.LegacyEntry && path != PackageManifests.FileName) Store.WriteFile(created.Name, path, bytes);
        }
        var installed = Describe(created);
        Changed?.Invoke();
        return installed;
    }
}
