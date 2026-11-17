using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ScriptWidget.Core.Packages;

/// <summary>
/// Minimal <c>widget.json</c> handling for the library: creating default manifests and reading the
/// display fields. Semantic validation (unknown keys, permissions, entry, versions) is the shared
/// manifest validator's job (<see cref="ScriptWidget.Core.Runtime.PackageCompiler.ValidateManifest"/>)
/// and is not repeated here.
/// </summary>
internal static class PackageManifests
{
    public const string FileName = "widget.json";
    public const string LegacyEntry = "main.jsx";
    public const string LegacyMetadata = "meta.json";

    private static readonly string[] DiscoveryKeys = ["description", "category", "icon", "preview"];

    /// <summary>Display fields of a manifest; each is null when absent or not a string.</summary>
    public sealed record Summary(string? Id, string? Name, string? Version);

    /// <summary>Parses manifest text as a JSON object, or null. A present manifest that fails here is invalid, never legacy.</summary>
    public static JsonObject? Parse(string? text)
    {
        if (text is null) return null;
        try
        {
            if (Json.Parse(text) is not JsonObject manifest) return null;
            // Members are materialized lazily; a duplicate key surfaces here rather than later.
            _ = manifest.Count;
            return manifest;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    public static Summary Summarize(JsonObject manifest) => new(StringValue(manifest, "id"), StringValue(manifest, "name"), StringValue(manifest, "version"));

    public static string? StringValue(JsonObject manifest, string key) =>
        manifest.TryGetPropertyValue(key, out var node) && node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    /// <summary>A fresh local identifier, as <c>WidgetPackageManifest.newProject</c> generates.</summary>
    public static string FreshId() => "local." + Guid.NewGuid().ToString("D").ToLowerInvariant();

    /// <summary><c>WidgetPackageManifest.newProject</c> / <c>newManifest</c> in <c>manifest.js</c>.</summary>
    public static JsonObject NewManifest(string name) => new()
    {
        ["formatVersion"] = 2,
        ["id"] = FreshId(),
        ["name"] = name,
        ["version"] = "1.0.0",
        ["runtimeVersion"] = "1.0",
        ["entry"] = LegacyEntry,
        ["supportedFamilies"] = Json.Array(["systemSmall", "systemMedium", "systemLarge"]),
        ["permissions"] = new JsonArray(),
        ["networkDomains"] = new JsonArray(),
        ["plugins"] = new JsonArray(),
        ["actions"] = new JsonArray(),
        ["controls"] = new JsonArray(),
    };

    /// <summary>
    /// <c>WidgetPackageManifest.legacy</c>: the manifest given to a package that has <c>main.jsx</c>
    /// and no <c>widget.json</c>. Discovery fields are carried over from <c>meta.json</c> when it is
    /// well formed; a malformed <c>meta.json</c> is ignored, as in Swift.
    /// </summary>
    public static JsonObject LegacyManifest(string name, string? metadataText)
    {
        var manifest = NewManifest(name);
        manifest["id"] = PackageNames.LegacyId(name);
        if (Parse(metadataText) is not { } metadata) return manifest;
        foreach (var key in DiscoveryKeys)
        {
            if (StringValue(metadata, key) is { } text) manifest[key] = text;
        }
        if (metadata.OptArray("tags") is { } tags && tags.All(tag => tag.IsString())) manifest["tags"] = tags.DeepClone();
        return manifest;
    }

    /// <summary>The manifest as indented UTF-8 JSON with LF line ends and a final newline.</summary>
    public static byte[] Encode(JsonObject manifest) =>
        Encoding.UTF8.GetBytes(Json.Stringify(manifest, indented: true).Replace("\r\n", "\n", StringComparison.Ordinal) + "\n");
}
