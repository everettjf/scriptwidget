using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Api;

/// <summary>
/// Package-scoped key-value storage behind <c>$storage</c>. Each package has
/// its own file; a package can never name or reach another package's keys.
/// Values are bounded and writes are atomic. Compare-and-set runs under the
/// same lock as plain writes, so app and widget updates do not lose records.
/// </summary>
public sealed class StorageModule(string directory) : INativeModule
{
    public const int MaximumValueBytes = 256 * 1024;
    public const int MaximumKeys = 1024;
    public const int MaximumTotalBytes = 8 * 1024 * 1024;

    private static readonly ConcurrentDictionary<string, object> Locks = new(StringComparer.OrdinalIgnoreCase);
    private static object LockFor(string path) => Locks.GetOrAdd(path, _ => new object());

    public bool Handles(string operation) => operation.StartsWith("storage.", StringComparison.Ordinal);

    public string? Call(ExecutionRequest request, string operation, string? payload)
    {
        var arguments = payload is null ? new JsonObject() : Json.ParseObject(payload);
        var key = arguments.OptString("key");
        var writes = operation is "storage.set" or "storage.cas" or "storage.remove" or "storage.clear";
        if (writes && RuntimePolicy.IsTimelineProjection(request)) return "false";
        var file = FileFor(request.PackageID);
        lock (LockFor(file))
        {
            switch (operation)
            {
                case "storage.get":
                    return !ValidKey(key) ? "null" : Read(file).OptObject(key) is { } entry ? Json.Stringify(entry) : "null";
                case "storage.keys":
                    return Json.Stringify(Json.Array(Read(file).Select(item => item.Key).Order(StringComparer.Ordinal)));
                case "storage.set":
                {
                    var value = arguments.OptString("v");
                    var type = arguments.OptString("t");
                    if (!ValidKey(key) || !ValidValue(type, value)) return "false";
                    var store = Read(file);
                    if (!store.Has(key) && store.Count >= MaximumKeys) return "false";
                    store[key] = new JsonObject { ["t"] = type, ["v"] = value };
                    return Write(file, store) ? "true" : "false";
                }
                case "storage.cas":
                {
                    var value = arguments.OptString("v");
                    var type = arguments.OptString("t");
                    var expected = arguments.OptString("expected");
                    if (!ValidKey(key) || !ValidValue(type, value) || Encoding.UTF8.GetByteCount(expected) > MaximumValueBytes) return "false";
                    var store = Read(file);
                    var current = store.OptObject(key);
                    // A missing key matches an empty string or an empty object.
                    var matches = current is null ? expected == (type == "s" ? "" : "{}") : current.OptString("t") == type && current.OptString("v") == expected;
                    if (!matches) return "false";
                    if (current is null && store.Count >= MaximumKeys) return "false";
                    store[key] = new JsonObject { ["t"] = type, ["v"] = value };
                    return Write(file, store) ? "true" : "false";
                }
                case "storage.remove":
                {
                    if (!ValidKey(key)) return "false";
                    var store = Read(file);
                    store.Remove(key);
                    return Write(file, store) ? "true" : "false";
                }
                case "storage.clear":
                    try { File.Delete(file); } catch (IOException) { return "false"; } catch (UnauthorizedAccessException) { return "false"; }
                    return "true";
                default: throw new ArgumentException($"Unsupported operation {operation}");
            }
        }
    }

    /// <summary>Reads a string value for native features such as toggle state; empty when missing.</summary>
    public string GetString(string packageID, string key)
    {
        var file = FileFor(packageID);
        lock (LockFor(file)) return Read(file).OptObject(key) is { } entry && entry.OptString("t") == "s" ? entry.OptString("v") : "";
    }

    /// <summary>Writes a string value on behalf of a native feature. Returns false when a limit rejects it.</summary>
    public bool SetString(string packageID, string key, string value)
    {
        if (!ValidKey(key) || !ValidValue("s", value)) return false;
        var file = FileFor(packageID);
        lock (LockFor(file))
        {
            var store = Read(file);
            if (!store.Has(key) && store.Count >= MaximumKeys) return false;
            store[key] = new JsonObject { ["t"] = "s", ["v"] = value };
            return Write(file, store);
        }
    }

    /// <summary>All stored entries of a package, for the records screen and tests.</summary>
    public JsonObject Snapshot(string packageID)
    {
        var file = FileFor(packageID);
        lock (LockFor(file)) return Read(file);
    }

    public void Clear(string packageID)
    {
        var file = FileFor(packageID);
        lock (LockFor(file)) { try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    private static bool ValidKey(string key) => key.Length > 0 && Encoding.UTF8.GetByteCount(key) <= 256;

    private static bool ValidValue(string type, string value)
    {
        if (type != "s" && type != "j") return false;
        if (Encoding.UTF8.GetByteCount(value) > MaximumValueBytes) return false;
        if (type == "s") return true;
        try { return Json.Parse(value) is JsonObject; } catch (JsonException) { return false; }
    }

    private string FileFor(string packageID) =>
        Path.Combine(directory, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(packageID))) + ".json");

    private static JsonObject Read(string file)
    {
        if (!File.Exists(file)) return new JsonObject();
        try { return Json.Parse(File.ReadAllText(file, Encoding.UTF8)) as JsonObject ?? new JsonObject(); }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { return new JsonObject(); }
    }

    private bool Write(string file, JsonObject store)
    {
        var text = Json.Stringify(store);
        if (Encoding.UTF8.GetByteCount(text) > MaximumTotalBytes) return false;
        var temporary = file + ".tmp";
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(temporary, text, new UTF8Encoding(false));
            File.Move(temporary, file, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return false;
        }
    }
}
