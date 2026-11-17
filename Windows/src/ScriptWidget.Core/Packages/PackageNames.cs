using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace ScriptWidget.Core.Packages;

/// <summary>
/// Package (library directory) names, ported from <c>validPackageName</c> in <c>manifest.js</c> and
/// <c>ScriptWidgetPackageName.isValid</c> in Swift.
/// </summary>
public static partial class PackageNames
{
    [GeneratedRegex("^[A-Za-z]:", RegexOptions.CultureInvariant)]
    private static partial Regex DrivePrefix();

    [GeneratedRegex("[\\\\/:*?\"<>|\\x00]", RegexOptions.CultureInvariant)]
    private static partial Regex ArchiveUnsafe();

    [GeneratedRegex("[^a-z0-9]+", RegexOptions.CultureInvariant)]
    private static partial Regex NotSlug();

    /// <summary>
    /// The identity two names share when a case-insensitive or normalizing filesystem would treat
    /// them as one entry: NFC, then culture-independent case folding
    /// (<c>ScriptWidgetPackageFiles.identity</c>). The fold goes through upper case first, as NTFS
    /// compares names by upper-casing them, so no pair Windows treats as one entry gets two
    /// identities. Text that is not valid Unicode cannot be normalized and is only case-folded.
    /// </summary>
    public static string Identity(string name)
    {
        string normalized;
        try
        {
            normalized = name.Normalize(NormalizationForm.FormC);
        }
        catch (ArgumentException)
        {
            normalized = name;
        }
        return normalized.ToUpperInvariant().ToLowerInvariant();
    }

    /// <summary>
    /// True when <paramref name="name"/> may be used as a package name and directory name.
    ///
    /// Rejects blank names, a leading dot (hidden files, <c>.</c>/<c>..</c>), the reserved
    /// <c>__Build</c> cache name in any case, path separators, Windows drive prefixes, and
    /// control/format characters other than ZWNJ/ZWJ, so a display name can never become a
    /// traversal or a cache path. Length is bounded to 80 grapheme clusters and 240 UTF-8 bytes.
    /// Because the name is a directory name in the library, it must also be one Windows stores
    /// verbatim (<see cref="PackagePathRules.WindowsSafe"/>): no colon or other reserved
    /// character, no trailing dot or space, no device name.
    /// </summary>
    public static bool IsValid(string? name)
    {
        if (name is null || string.IsNullOrWhiteSpace(name) || name.StartsWith('.')) return false;
        if (Identity(name) == "__build" || name.Contains('/') || name.Contains('\\') || DrivePrefix().IsMatch(name)) return false;
        if (HasControlCharacters(name) || !PackagePathRules.WindowsSafe(name)) return false;
        return GraphemeCount(name) <= PackageLimits.MaxNameGraphemes && Utf8Length(name) <= PackageLimits.MaxNameBytes;
    }

    /// <summary>Control, format (except ZWNJ/ZWJ, which joined emoji and some scripts need) or unpaired surrogate characters.</summary>
    internal static bool HasControlCharacters(string text)
    {
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character is '‌' or '‍') continue;
            UnicodeCategory category;
            if (char.IsHighSurrogate(character) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]))
            {
                category = CharUnicodeInfo.GetUnicodeCategory(char.ConvertToUtf32(character, text[index + 1]));
                index += 1;
            }
            else
            {
                category = CharUnicodeInfo.GetUnicodeCategory(character);
            }
            if (category is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.Surrogate) return true;
        }
        return false;
    }

    internal static int Utf8Length(string text) => Encoding.UTF8.GetByteCount(text);

    internal static int GraphemeCount(string text) => GraphemeBoundaries(text).Length - 1;

    /// <summary>
    /// <paramref name="name"/> followed by <paramref name="suffix"/>, with the stem shortened by
    /// whole grapheme clusters until the result fits the name limits. This is the truncation
    /// <c>getValidPackageName</c> and <c>duplicateScript</c> apply in Swift.
    /// </summary>
    internal static string WithSuffix(string name, string suffix)
    {
        var bounds = GraphemeBoundaries(name);
        var keep = Math.Min(bounds.Length - 1, Math.Max(0, PackageLimits.MaxNameGraphemes - GraphemeCount(suffix)));
        while (keep > 0 && Utf8Length(name[..bounds[keep]] + suffix) > PackageLimits.MaxNameBytes) keep -= 1;
        return name[..bounds[keep]] + suffix;
    }

    /// <summary><c>WidgetPackageManifest.legacy</c>: the identifier of a package that had no <c>widget.json</c>.</summary>
    internal static string LegacyId(string name)
    {
        var slug = NotSlug().Replace(name.ToLowerInvariant(), "-").Trim('-');
        return "legacy." + (slug.Length == 0 ? "widget" : slug);
    }

    /// <summary><c>packageDirectoryName</c> in <c>archive.js</c>: a root directory name every platform's importer accepts.</summary>
    internal static string ArchiveRootName(string name)
    {
        var cleaned = ArchiveUnsafe().Replace(name, "-").TrimStart('.').Trim();
        if (cleaned.Length > 80) cleaned = cleaned[..80];
        return cleaned.Length == 0 ? "Widget" : cleaned;
    }

    /// <summary>Start index of every grapheme cluster, followed by the text length.</summary>
    private static int[] GraphemeBoundaries(string text) => [.. StringInfo.ParseCombiningCharacters(text), text.Length];
}
