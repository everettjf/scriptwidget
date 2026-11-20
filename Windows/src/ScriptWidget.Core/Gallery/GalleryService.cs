using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Core.Plugins;
using ScriptWidget.Core.Skills;

namespace ScriptWidget.Core.Gallery;

public sealed record GalleryResponse(int Status, byte[] Body, string FinalUrl);
public interface IGalleryTransport
{
    Task<GalleryResponse> DownloadAsync(string url, int maximumBytes, CancellationToken cancellation = default);
}

/// <summary>Credential-free HTTPS GETs, vetted DNS addresses, bounded reads, and no redirects.</summary>
public sealed class GalleryHttpTransport : IGalleryTransport, IDisposable
{
    private readonly HttpClient client = new(FetchModule.CreateHandler(FetchModule.SystemResolver)) { Timeout = Timeout.InfiniteTimeSpan };
    public async Task<GalleryResponse> DownloadAsync(string url, int maximumBytes, CancellationToken cancellation = default)
    {
        if (!GalleryCatalog.IsTrustedUrl(url)) throw new GalleryException("untrusted_url", "Gallery request is outside its trusted root.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", FetchModule.DefaultUserAgent);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        if (response.Content.Headers.ContentLength is { } length && length > maximumBytes) throw new GalleryException("invalid_download", "Gallery response exceeds its byte budget.");
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[16384];
        while (true)
        {
            var count = await stream.ReadAsync(chunk, timeout.Token).ConfigureAwait(false);
            if (count == 0) break;
            if (buffer.Length + count > maximumBytes) throw new GalleryException("invalid_download", "Gallery response exceeds its byte budget.");
            buffer.Write(chunk, 0, count);
        }
        return new GalleryResponse((int)response.StatusCode, buffer.ToArray(), response.RequestMessage?.RequestUri?.AbsoluteUri ?? url);
    }
    public void Dispose() => client.Dispose();
}

public sealed record LoadedGallery(GalleryIndex Index, bool IsOffline, string? Warning);
public sealed record GalleryInstallation(string ItemId, string Kind, string Version, string LocalName, string Fingerprint);
public sealed record GalleryInstallResult(GalleryInstallation Installation, bool Updated);

/// <summary>Verified downloads, validated offline index, transactional installs and explicit updates.</summary>
public sealed class GalleryService
{
    private static readonly SemaphoreSlim Installing = new(1, 1);
    private readonly Library library;
    private readonly SkillStore skills;
    private readonly IGalleryTransport transport;
    private readonly SafeJsonFile cache;
    private readonly SafeJsonFile records;
    private readonly object recordGate = new();
    private readonly string root;
    public GalleryService(DataPaths paths, Library library, SkillStore skills, IGalleryTransport transport)
    {
        this.library = library;
        this.skills = skills;
        this.transport = transport;
        root = paths.Gallery;
        cache = new SafeJsonFile(Path.Combine(paths.Gallery, "index.json"), GalleryCatalog.MaximumIndexBytes);
        records = new SafeJsonFile(Path.Combine(paths.Gallery, "installations.json"), 1024 * 1024);
    }

    public async Task<LoadedGallery> LoadAsync(CancellationToken cancellation = default)
    {
        try
        {
            var response = await transport.DownloadAsync(GalleryCatalog.IndexUrl, GalleryCatalog.MaximumIndexBytes, cancellation).ConfigureAwait(false);
            if (response.Status != 200 || !GalleryCatalog.IsTrustedUrl(response.FinalUrl)) throw new GalleryException("network", "Gallery index could not be downloaded from its trusted root.");
            var index = GalleryCatalog.Decode(response.Body);
            EnsureRoot();
            var saved = cache.Write(new UTF8Encoding(false, true).GetString(response.Body));
            return new LoadedGallery(index, false, saved ? null : "Gallery loaded, but its offline copy could not be saved.");
        }
        catch (Exception error) when (!cancellation.IsCancellationRequested && error is GalleryException or HttpRequestException or OperationCanceledException or IOException or UnauthorizedAccessException)
        {
            try
            {
                if (PluginFiles.RealDirectory(root) is not null && cache.Read() is { } saved) return new LoadedGallery(GalleryCatalog.Decode(Encoding.UTF8.GetBytes(saved)), true, "Showing the saved Gallery. The current index could not be verified or downloaded.");
            }
            catch (Exception cachedError) when (cachedError is PrivateFile.Unreadable or GalleryException) { }
            throw new GalleryException("network", "Gallery could not be loaded, and no verified offline copy is available.");
        }
    }

    private List<GalleryInstallation> ReadRecords()
    {
        try
        {
            if (PluginFiles.RealDirectory(root) is null) return [];
            var text = records.Read() ?? "[]";
            StrictJson.Parse(text);
            if (Json.TryParse(text) is not JsonArray array) return [];
            var result = new List<GalleryInstallation>();
            foreach (var value in array)
            {
                if (value is not JsonObject row || row.Count != 5 || new[] { "id", "kind", "version", "localName", "fingerprint" }.Any(key => !row[key].IsString())) return [];
                result.Add(new GalleryInstallation(row.OptString("id"), row.OptString("kind"), row.OptString("version"), row.OptString("localName"), row.OptString("fingerprint")));
            }
            return result.Select(record => record.ItemId).Distinct(StringComparer.OrdinalIgnoreCase).Count() == result.Count ? result : [];
        }
        catch (Exception error) when (error is PrivateFile.Unreadable or StrictJson.JsonException) { return []; }
    }

    private void EnsureRoot()
    {
        Directory.CreateDirectory(root);
        if (PluginFiles.RealDirectory(root) is null) throw new GalleryException("storage_unavailable", "Gallery storage is unavailable.");
    }

    public GalleryInstallation? Installation(GalleryItem item)
    {
        lock (recordGate)
        {
            var record = ReadRecords().FirstOrDefault(record => record.ItemId == item.Id && record.Kind == item.Kind);
            if (record is null) return null;
            return item.Kind == "skill" ? skills.Find(item.Id) is { IsBuiltIn: false } ? record : null :
                library.Find(record.LocalName)?.Manifest.OptString("id") == item.Id ? record : null;
        }
    }

    public static string Fingerprint(GalleryItem item) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
        string.Join("\n", item.Files.OrderBy(file => file.Path, StringComparer.Ordinal).Select(file => $"{file.Path}\n{file.Bytes}\n{file.Sha256}")))));

    public string State(GalleryItem item) => Installation(item) is not { } record ? "notInstalled" :
        record.Version == item.Version && record.Fingerprint == Fingerprint(item) ? "installed" : "updateAvailable";

    private void Save(GalleryInstallation installation)
    {
        lock (recordGate)
        {
            var values = ReadRecords().Where(record => record.ItemId != installation.ItemId).Append(installation).ToList();
            var array = new JsonArray();
            foreach (var record in values) array.Append(new JsonObject
            {
                ["id"] = record.ItemId, ["kind"] = record.Kind, ["version"] = record.Version, ["localName"] = record.LocalName, ["fingerprint"] = record.Fingerprint,
            });
            EnsureRoot();
            if (!records.Write(Json.Stringify(array))) throw new GalleryException("storage_unavailable", "Gallery installation record could not be saved.");
        }
    }

    public async Task<GalleryInstallResult> InstallAsync(GalleryItem item, Action<IPackageFiles> validateWidget, bool updateExisting = false, CancellationToken cancellation = default)
    {
        // Freeze caller-owned lists before awaiting network work.
        item = item with { Files = item.Files.ToArray(), Tags = item.Tags.ToArray() };
        GalleryCatalog.Validate(item);
        await Installing.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            var existing = Installation(item);
            if (existing is not null && !updateExisting) throw new GalleryException("already_installed", "This Gallery item is installed. Choose Update to replace it.");
            if (item.Kind == "skill" && existing is null && skills.Find(item.Id) is not null) throw new GalleryException("already_installed", "A Skill with this id already exists outside the Gallery.");
            var downloaded = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(TimeSpan.FromMinutes(2));
            foreach (var file in item.Files)
            {
                var response = await transport.DownloadAsync(file.Url, file.Bytes, timeout.Token).ConfigureAwait(false);
                if (response.Status != 200 || !GalleryCatalog.IsTrustedUrl(response.FinalUrl) || response.Body.Length != file.Bytes ||
                    Convert.ToHexStringLower(SHA256.HashData(response.Body)) != file.Sha256)
                    throw new GalleryException("invalid_download", "A Gallery file failed its origin, size or SHA-256 check. Nothing was installed.");
                downloaded[file.Path] = response.Body;
            }
            timeout.Token.ThrowIfCancellationRequested();
            string localName;
            if (item.Kind == "skill")
            {
                var skill = SkillValidator.Load(downloaded["skill.json"], downloaded["SKILL.md"]);
                if (skill.Id != item.Id || skill.Version != item.Version) throw new GalleryException("identity_mismatch", "Downloaded Skill identity or version does not match the index.");
                skills.Install(downloaded["skill.json"], downloaded["SKILL.md"], replaceExisting: existing is not null);
                localName = item.Id;
            }
            else
            {
                void Validate(IPackageFiles files)
                {
                    if (files.ReadText("widget.json") is not { } text) throw new GalleryException("invalid_manifest", "Downloaded widget has no readable manifest.");
                    var json = Json.ParseObject(text);
                    if (json.OptString("id") != item.Id || json.OptString("version") != item.Version || json.OptString("runtimeVersion") != "1.0")
                        throw new GalleryException("identity_mismatch", "Downloaded widget identity, version or runtime does not match the index.");
                    if (!files.Paths().Order(StringComparer.Ordinal).SequenceEqual(downloaded.Keys.Order(StringComparer.Ordinal))) throw new GalleryException("invalid_download", "The installed files would differ from the verified download.");
                    validateWidget(files);
                }
                using var archive = new MemoryStream();
                using (var zip = new ZipArchive(archive, ZipArchiveMode.Create, leaveOpen: true, Encoding.UTF8))
                    foreach (var (path, bytes) in downloaded)
                    {
                        var entry = zip.CreateEntry("package/" + path);
                        using var stream = entry.Open();
                        stream.Write(bytes);
                    }
                archive.Position = 0;
                localName = existing is not null
                    ? library.Store.ReplaceArchive(existing.LocalName, archive, item.Id, Library.InstallationFile, Validate).Name
                    : library.ImportArchive(archive, item.Name, Validate).Name;
            }
            var installation = new GalleryInstallation(item.Id, item.Kind, item.Version, localName, Fingerprint(item));
            try { Save(installation); }
            catch
            {
                // A first install without a record cannot be updated, so roll it back.
                if (existing is null) { if (item.Kind == "skill") skills.Delete(item.Id); else library.Delete(localName); }
                throw;
            }
            return new GalleryInstallResult(installation, existing is not null);
        }
        catch (HttpRequestException) { throw new GalleryException("network", "GitHub could not be reached. Nothing was installed."); }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new GalleryException("network", "Gallery download timed out. Nothing was installed."); }
        catch (RuntimeError error) { throw new GalleryException("invalid_package", error.Message); }
        finally { Installing.Release(); }
    }
}
