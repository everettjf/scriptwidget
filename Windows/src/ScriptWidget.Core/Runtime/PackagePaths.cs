using System.Text;

namespace ScriptWidget.Core.Runtime;

/// <summary>Package-relative path handling, mirroring <c>normalizePackagePath</c> in the shared engine.</summary>
public static class PackagePaths
{
    /// <summary>Returns the normalized relative path, or null when it could leave the package.</summary>
    public static string? Normalize(string? relativePath)
    {
        if (string.IsNullOrEmpty(relativePath) || relativePath.StartsWith('/')) return null;
        if (relativePath.Contains('\\') || relativePath.Contains('\0')) return null;
        var parts = new List<string>();
        foreach (var part in relativePath.Split('/'))
        {
            switch (part)
            {
                case "" or ".": continue;
                case "..":
                    if (parts.Count == 0) return null;
                    parts.RemoveAt(parts.Count - 1);
                    break;
                default: parts.Add(part); break;
            }
        }
        return parts.Count == 0 ? null : string.Join('/', parts);
    }
}

/// <summary>Read-only view of one installed package. Paths are already normalized.</summary>
public interface IPackageFiles
{
    IReadOnlyList<string> Paths();
    bool Exists(string path);
    /// <summary>UTF-8 text of a script or data file, or null for missing and binary files.</summary>
    string? ReadText(string path);
    byte[]? ReadBytes(string path);
}

public sealed class MemoryPackageFiles(IReadOnlyDictionary<string, string> text, IReadOnlyDictionary<string, byte[]>? binary = null) : IPackageFiles
{
    private readonly IReadOnlyDictionary<string, byte[]> binary = binary ?? new Dictionary<string, byte[]>();

    public IReadOnlyList<string> Paths() => text.Keys.Concat(binary.Keys).Order(StringComparer.Ordinal).ToList();
    public bool Exists(string path) => text.ContainsKey(path) || binary.ContainsKey(path);
    public string? ReadText(string path) => text.GetValueOrDefault(path);
    public byte[]? ReadBytes(string path) => binary.TryGetValue(path, out var bytes) ? bytes : text.TryGetValue(path, out var value) ? Encoding.UTF8.GetBytes(value) : null;
}
