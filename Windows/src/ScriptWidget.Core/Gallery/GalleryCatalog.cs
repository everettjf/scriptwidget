using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Plugins;

namespace ScriptWidget.Core.Gallery;

public sealed class GalleryException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public sealed record GalleryFile(string Path, string Url, string Sha256, int Bytes);
public sealed record GalleryItem(string Id, string Kind, string Name, string Version, string Summary, string Symbol,
    string Author, string License, IReadOnlyList<string> Tags, string SourceUrl, bool Featured, IReadOnlyList<GalleryFile> Files);
public sealed record GalleryIndex(string GeneratedAt, string Repository, IReadOnlyList<GalleryItem> Items);

/// <summary>Strict Gallery 1.0 decoding. No index field, path, host or capability is accepted on trust.</summary>
public static partial class GalleryCatalog
{
    public const string TrustedRoot = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/";
    public const string IndexUrl = TrustedRoot + "index.json";
    public const int MaximumIndexBytes = 1024 * 1024;
    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9.-]{2,127}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Identifier();
    [GeneratedRegex(@"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z", RegexOptions.CultureInvariant)]
    private static partial Regex Version();
    [GeneratedRegex(@"\A[a-f0-9]{64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Digest();

    internal static GalleryException Invalid(string message) => new("invalid_index", message);
    private static void Fields(JsonObject value, params string[] keys)
    {
        if (value.Any(pair => !keys.Contains(pair.Key, StringComparer.Ordinal)) || keys.Any(key => !value.Has(key))) throw Invalid("Gallery contains unknown or missing fields.");
    }
    private static string Text(JsonObject value, string key, int maximum = int.MaxValue)
    {
        if (!value[key].IsString() || value.OptString(key) is not { } text || string.IsNullOrWhiteSpace(text) || text.EnumerateRunes().Count() > maximum)
            throw Invalid($"Gallery field {key} is invalid.");
        return text;
    }
    private static JsonArray Array(JsonObject value, string key, int minimum, int maximum)
    {
        var array = value.OptArray(key);
        if (array is null || array.Count < minimum || array.Count > maximum) throw Invalid($"Gallery field {key} has an invalid number of entries.");
        return array;
    }

    public static bool IsTrustedUrl(string text)
    {
        if (!text.StartsWith(TrustedRoot, StringComparison.Ordinal) || text.Any(char.IsControl) || text.Contains('\\') || text.Contains('%') || text.Contains(' ')) return false;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "raw.githubusercontent.com" ||
            !uri.IsDefaultPort || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return false;
        // Reject normalization tricks as text before Uri removes dot segments or default ports.
        return uri.AbsoluteUri == text && text[TrustedRoot.Length..].Split('/').All(part => part.Length > 0 && part is not ("." or ".."));
    }

    private static bool GithubUrl(string value) => value.StartsWith("https://github.com/", StringComparison.Ordinal) &&
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Host == "github.com" && uri.UserInfo.Length == 0 && uri.IsDefaultPort && !value.Any(char.IsControl);

    public static GalleryIndex Decode(byte[] bytes)
    {
        if (bytes.Length > MaximumIndexBytes) throw Invalid("Gallery index exceeds 1 MiB.");
        try
        {
            var text = new UTF8Encoding(false, true).GetString(bytes);
            StrictJson.Parse(text);
            var json = Json.Parse(text) as JsonObject ?? throw Invalid("Gallery index must be an object.");
            Fields(json, "schemaVersion", "generatedAt", "repository", "items");
            if (json["schemaVersion"] is not JsonValue schema || !schema.TryGetValue<int>(out var version) || version != 1) throw Invalid("Only Gallery schema 1 is supported.");
            var generated = Text(json, "generatedAt", 80);
            if (!DateTimeOffset.TryParse(generated, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _) || !generated.Contains('T')) throw Invalid("Gallery generatedAt must be an ISO date-time.");
            var repository = Text(json, "repository", 2048);
            if (!GithubUrl(repository)) throw Invalid("Gallery repository must use HTTPS github.com.");
            var items = Array(json, "items", 1, 500).Select(value => DecodeItem(value as JsonObject ?? throw Invalid("Gallery item must be an object."))).ToList();
            if (items.Select(item => item.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != items.Count) throw Invalid("Gallery item ids must be unique.");
            return new GalleryIndex(generated, repository, items);
        }
        catch (Exception error) when (error is DecoderFallbackException or StrictJson.JsonException or System.Text.Json.JsonException)
        { throw Invalid("Gallery index must be strict UTF-8 JSON without duplicate keys."); }
    }

    private static GalleryItem DecodeItem(JsonObject json)
    {
        Fields(json, "id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags", "minimumRuntimeVersion", "sourceURL", "featured", "files");
        var tags = Array(json, "tags", 0, 20);
        if (tags.Any(tag => !tag.IsString()) || tags.Select(tag => tag!.AsText()).Distinct(StringComparer.OrdinalIgnoreCase).Count() != tags.Count) throw Invalid("Gallery tags must be unique text values.");
        if (json["featured"] is not JsonValue flag || !flag.TryGetValue<bool>(out var featured)) throw Invalid("Gallery featured must be a boolean.");
        if (Text(json, "minimumRuntimeVersion") != "1.0") throw Invalid("Gallery item requires an unsupported runtime contract.");
        var files = Array(json, "files", 2, 500).Select(value =>
        {
            var file = value as JsonObject ?? throw Invalid("Gallery file must be an object.");
            Fields(file, "path", "url", "sha256", "bytes");
            if (file["bytes"] is not JsonValue number || !number.TryGetValue<int>(out var count)) throw Invalid("Gallery file size must be an integer.");
            return new GalleryFile(Text(file, "path", 512), Text(file, "url", 2048), Text(file, "sha256", 64), count);
        }).ToList();
        var item = new GalleryItem(Text(json, "id", 128), Text(json, "kind", 8), Text(json, "name", 80), Text(json, "version", 128), Text(json, "summary", 240),
            Text(json, "symbol", 80), Text(json, "author", 120), Text(json, "license", 40), tags.Select(tag => tag!.AsText()!).ToList(), Text(json, "sourceURL", 2048), featured, files);
        Validate(item);
        return item;
    }

    /// <summary>Revalidated by the installer even for an item constructed directly or read from cache.</summary>
    public static void Validate(GalleryItem item)
    {
        if (!Identifier().IsMatch(item.Id) || !Version().IsMatch(item.Version) || item.Kind is not ("widget" or "skill") || !GithubUrl(item.SourceUrl)) throw Invalid("Gallery identity, kind, version or source is invalid.");
        foreach (var (value, maximum) in new[] { (item.Name, 80), (item.Summary, 240), (item.Symbol, 80), (item.Author, 120), (item.License, 40) })
            if (string.IsNullOrWhiteSpace(value) || value.EnumerateRunes().Count() > maximum) throw Invalid("Gallery metadata is invalid.");
        if (item.Tags.Count > 20 || item.Tags.Distinct(StringComparer.OrdinalIgnoreCase).Count() != item.Tags.Count) throw Invalid("Gallery tags must be unique.");
        if (item.Files.Count is < 2 or > 500) throw Invalid("Gallery file count is invalid.");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long total = 0;
        foreach (var file in item.Files)
        {
            if (file.Path.Length > 512 || PackagePathRules.VisibleComponents(file.Path) is null || !paths.Add(file.Path.Normalize(NormalizationForm.FormC)) ||
                !IsTrustedUrl(file.Url) || !Digest().IsMatch(file.Sha256) || file.Bytes is < 1 or > 25 * 1024 * 1024) throw Invalid("Gallery contains an unsafe path, untrusted URL, invalid hash or invalid size.");
            total += file.Bytes;
        }
        bool Has(string path) => item.Files.Any(file => file.Path == path);
        if (item.Kind == "widget" && (!Has("widget.json") || !Has("main.jsx") || total > 32L * 1024 * 1024) ||
            item.Kind == "skill" && (!Has("skill.json") || !Has("SKILL.md") || item.Files.Count != 2 || total > 256 * 1024)) throw Invalid("Gallery package is incomplete or exceeds its byte budget.");
        // A file must not also be an ancestor directory of another file.
        foreach (var file in item.Files)
        {
            var components = file.Path.Split('/');
            for (var index = 1; index < components.Length; index++)
                if (paths.Contains(string.Join('/', components.Take(index)).Normalize(NormalizationForm.FormC))) throw Invalid("Gallery has a file/directory collision.");
        }
    }
}
