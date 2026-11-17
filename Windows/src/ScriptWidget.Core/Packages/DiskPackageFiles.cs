using System.Text.RegularExpressions;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Packages;

/// <summary>
/// Read-only view of one package directory on disk.
///
/// Every path is package-relative and must already be normalized. A path is refused (reported as
/// missing) when it is absolute, contains a backslash, NUL, <c>.</c>/<c>..</c> or empty component,
/// names a dot-file or the generated <c>__Build</c> cache, is not safe on Windows (drive, UNC,
/// stream or device syntax, a trailing dot or space), crosses a symbolic link, junction or other
/// reparse point at any component, has a case or Unicode-normalization alias in its directory, is
/// a hard-linked or special file, or resolves canonically outside the root. Reads are
/// size-bounded while reading.
/// </summary>
public sealed partial class DiskPackageFiles(string root) : IPackageFiles
{
    private readonly string root = SafeFiles.Root(root);

    [GeneratedRegex(@"\.(jsx?|mjs)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ScriptFile();

    /// <summary>
    /// Regular files of the package as sorted, normalized relative paths. Dot-files and
    /// dot-directories, <c>__Build</c>, links, special files, hard-linked files, ambiguous
    /// spellings, names that are not safe on Windows and anything deeper than 16 components are
    /// left out.
    /// </summary>
    /// <exception cref="PackageException"><c>too_many_entries</c> when the package holds more than 500 files.</exception>
    public IReadOnlyList<string> Paths()
    {
        var result = new List<string>();
        if (SafeFiles.RealDirectory(root) is { } directory) Collect(directory, "", 1, result);
        result.Sort(StringComparer.Ordinal);
        return result;
    }

    /// <summary>True only for a regular file inside the package that passes every rule in the class description.</summary>
    public bool Exists(string path) => Resolve(path) is not null;

    /// <summary>
    /// UTF-8 text of a text-like file (per <see cref="PackageCompiler.IsTextFile"/>), or null when
    /// the file is missing, refused, binary, not valid UTF-8, or larger than 512 KiB for scripts
    /// and 2 MiB for other text.
    /// </summary>
    public string? ReadText(string path)
    {
        if (!PackageCompiler.IsTextFile(path)) return null;
        var limit = ScriptFile().IsMatch(path) ? PackageLimits.MaxScriptBytes : PackageLimits.MaxTextBytes;
        return ReadBytes(path, limit) is { } bytes ? SafeFiles.DecodeUtf8(bytes) : null;
    }

    /// <summary>Bytes of a file, or null when it is missing, refused, or larger than 16 MiB.</summary>
    public byte[]? ReadBytes(string path) => ReadBytes(path, PackageLimits.MaxBinaryReadBytes);

    /// <summary><see cref="ReadBytes(string)"/> with an explicit bound, for callers with their own limit (manifest, export).</summary>
    internal byte[]? ReadBytes(string path, long maximumBytes) => Resolve(path) is { } file ? SafeFiles.ReadBounded(file, maximumBytes) : null;

    private string? Resolve(string path) =>
        PackagePathRules.VisibleComponents(path) is { } parts ? SafeFiles.ExistingFile(root, parts) : null;

    private static void Collect(string directory, string prefix, int depth, List<string> result)
    {
        if (depth > PackageLimits.MaxPathDepth) return;
        var names = SafeFiles.Names(directory);
        if (names is null) return;
        foreach (var name in names)
        {
            if (PackagePathRules.IsExcluded(name) || !PackagePathRules.ValidComponent(name) || !SafeFiles.Unambiguous(names, name)) continue;
            var child = SafeFiles.Child(directory, name);
            if (SafeFiles.Attributes(child) is not { } info || info.IsSymbolicLink) continue;
            if (info.IsDirectory)
            {
                Collect(child, $"{prefix}{name}/", depth + 1, result);
            }
            else if (info.IsRegularFile && SafeFiles.SinglyLinked(child))
            {
                result.Add(prefix + name);
                if (result.Count > PackageLimits.MaxFileCount)
                {
                    throw new PackageException(PackageErrors.TooManyEntries, "Package contains too many entries.");
                }
            }
        }
    }
}
