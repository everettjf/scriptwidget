using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Plugins;

namespace ScriptWidget.Core.Tests.Plugins;

internal static class PluginFixtures
{
    public const string ID = "dev.scriptwidget.test-source";

    /// <summary>The plugin of <c>testRequestBuilderMapsPathQueryHeaderAndJSONBody</c> in the Swift tests.</summary>
    public const string Base = """
        {
          "formatVersion": 1, "id": "dev.scriptwidget.test-source", "name": "Test Source", "version": "1.0.0",
          "summary": "Test", "symbol": "network", "author": "Tests", "license": "MIT", "minimumRuntimeVersion": "1.0",
          "baseURL": "https://api.example.com", "hosts": ["api.example.com"],
          "operations": [
            {"id": "update", "title": "Update", "method": "POST", "path": "/users/{user}", "responseType": "json", "parameters": [
              {"id": "user", "label": "User", "location": "path", "required": true},
              {"id": "page", "label": "Page", "location": "query", "required": false, "defaultValue": "1"},
              {"id": "X-Token", "label": "Token", "location": "header", "required": true, "defaultValue": null},
              {"id": "enabled", "label": "Enabled", "location": "jsonBody", "required": true}
            ]},
            {"id": "status", "title": "Status", "method": "GET", "path": "/status", "responseType": "text", "parameters": []}
          ]
        }
        """;

    public static byte[] Bytes(Action<JsonObject>? mutate = null)
    {
        var root = Json.ParseObject(Base);
        mutate?.Invoke(root);
        return Encoding.UTF8.GetBytes(Json.Stringify(root));
    }

    public static PluginManifest Manifest(Action<JsonObject>? mutate = null) => PluginValidator.Decode(Bytes(mutate));

    public static JsonObject Operation(JsonObject root, int index = 0) => (JsonObject)root["operations"]![index]!;

    public static JsonObject Parameter(JsonObject root, int index) => (JsonObject)Operation(root)["parameters"]![index]!;

    /// <summary>A JSON array of strings and numbers.</summary>
    public static JsonArray Array(params object[] values)
    {
        var array = new JsonArray();
        foreach (var value in values) array.Append(value is string text ? JsonValue.Create(text) : JsonValue.Create(Convert.ToInt64(value)));
        return array;
    }

    public static Dictionary<string, object?> Values(params (string Name, object? Value)[] items) => items.ToDictionary(item => item.Name, item => item.Value);

    public static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    /// <summary>Runs <paramref name="block"/> and returns the <see cref="PluginException"/> it must throw.</summary>
    public static PluginException Failure(Action block) => Assert.Throws<PluginException>(block);

    public static void AssertRejected(string expected, Action<JsonObject> mutate)
    {
        var error = Failure(() => PluginValidator.Decode(Bytes(mutate)));
        Assert.Equal(PluginErrorKind.InvalidManifest, error.Kind);
        Assert.True(error.Message.Contains(expected, StringComparison.Ordinal), $"Expected \"{expected}\" in \"{error.Message}\"");
    }
}

/// <summary>One hand-written ZIP entry; every header field an attacker controls can be forged.</summary>
internal sealed class RawEntry(string name, byte[]? data = null, long externalAttributes = 0x81A4L << 16, int flags = 0x0800, int method = 0)
{
    public RawEntry(string name, string text) : this(name, Encoding.UTF8.GetBytes(text)) { }

    public string Name { get; } = name;
    public byte[] Data { get; } = data ?? [];
    public long ExternalAttributes { get; } = externalAttributes;
    public int Flags { get; } = flags;
    public int Method { get; } = method;
}

internal static class ZipFixtures
{
    /// <summary>Stored-entry ZIP written byte by byte, like <c>makeStoredZIP</c> in the Swift tests.</summary>
    public static byte[] RawZip(params RawEntry[] entries)
    {
        using var locals = new MemoryStream();
        using var central = new MemoryStream();
        foreach (var entry in entries)
        {
            var name = Encoding.UTF8.GetBytes(entry.Name);
            var crc = Crc32(entry.Data);
            var offset = (uint)locals.Length;
            using (var local = new BinaryWriter(locals, Encoding.UTF8, leaveOpen: true))
            {
                local.Write(0x04034B50u); local.Write((ushort)20); local.Write((ushort)entry.Flags); local.Write((ushort)entry.Method);
                local.Write((ushort)0); local.Write((ushort)0x21); local.Write(crc); local.Write((uint)entry.Data.Length); local.Write((uint)entry.Data.Length);
                local.Write((ushort)name.Length); local.Write((ushort)0);
                local.Write(name);
                local.Write(entry.Data);
            }
            using var header = new BinaryWriter(central, Encoding.UTF8, leaveOpen: true);
            header.Write(0x02014B50u); header.Write((ushort)0x031E); header.Write((ushort)20); header.Write((ushort)entry.Flags); header.Write((ushort)entry.Method);
            header.Write((ushort)0); header.Write((ushort)0x21); header.Write(crc); header.Write((uint)entry.Data.Length); header.Write((uint)entry.Data.Length);
            header.Write((ushort)name.Length); header.Write((ushort)0); header.Write((ushort)0); header.Write((ushort)0); header.Write((ushort)0);
            header.Write((uint)entry.ExternalAttributes); header.Write(offset);
            header.Write(name);
        }
        using var output = new MemoryStream();
        output.Write(locals.ToArray());
        output.Write(central.ToArray());
        using (var end = new BinaryWriter(output, Encoding.UTF8, leaveOpen: true))
        {
            end.Write(0x06054B50u); end.Write((ushort)0); end.Write((ushort)0); end.Write((ushort)entries.Length); end.Write((ushort)entries.Length);
            end.Write((uint)central.Length); end.Write((uint)locals.Length); end.Write((ushort)0);
        }
        return output.ToArray();
    }

    /// <summary>Deflated ZIP produced by the platform writer.</summary>
    public static byte[] DeflatedZip(params (string Name, byte[] Data)[] files)
    {
        using var output = new MemoryStream();
        using (var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, data) in files)
            {
                var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
                if (name.EndsWith('/')) continue;
                using var stream = entry.Open();
                stream.Write(data);
            }
        }
        return output.ToArray();
    }

    /// <summary>Overwrites the uncompressed size the central directory declares for entry <paramref name="index"/>.</summary>
    public static byte[] ForgeDeclaredSize(byte[] archive, int index, int size)
    {
        var bytes = (byte[])archive.Clone();
        var cursor = BitConverter.ToInt32(bytes, bytes.Length - 22 + 16);
        for (var skipped = 0; skipped < index; skipped++) cursor += 46 + BitConverter.ToUInt16(bytes, cursor + 28) + BitConverter.ToUInt16(bytes, cursor + 30) + BitConverter.ToUInt16(bytes, cursor + 32);
        Assert.Equal(0x02014B50, BitConverter.ToInt32(bytes, cursor));
        BitConverter.GetBytes(size).CopyTo(bytes, cursor + 24);
        return bytes;
    }

    /// <summary>Entry names and contents of an archive, in order.</summary>
    public static List<(string Name, byte[] Data)> Read(byte[] archive)
    {
        using var zip = new ZipArchive(new MemoryStream(archive), ZipArchiveMode.Read);
        var result = new List<(string, byte[])>();
        foreach (var entry in zip.Entries)
        {
            using var stream = entry.Open();
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            result.Add((entry.FullName, buffer.ToArray()));
        }
        return result;
    }

    private static uint Crc32(byte[] data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var item in data)
        {
            crc ^= item;
            for (var bit = 0; bit < 8; bit++) crc = (crc & 1) != 0 ? 0xEDB88320u ^ (crc >> 1) : crc >> 1;
        }
        return crc ^ 0xFFFFFFFFu;
    }
}
