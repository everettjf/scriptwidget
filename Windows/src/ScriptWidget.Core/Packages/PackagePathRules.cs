using System.Text.RegularExpressions;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Packages;

/// <summary>
/// Package-relative path rules, ported from <c>ScriptWidgetPackageFiles.components</c> in Swift,
/// plus the names Windows cannot store safely (<see cref="WindowsSafe"/>).
/// </summary>
internal static partial class PackagePathRules
{
    [GeneratedRegex("^[A-Za-z]:", RegexOptions.CultureInvariant)]
    private static partial Regex DrivePrefix();

    private static readonly HashSet<string> ReservedDeviceNames = new(StringComparer.Ordinal) { "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };

    /// <summary>
    /// Splits a package-relative path into components, or returns null when it is unsafe.
    ///
    /// The path must already be in normal form: no leading slash, no empty, <c>.</c> or <c>..</c>
    /// component, no backslash and no NUL (so nothing can name a location outside the package), no
    /// Windows drive prefix, at most 16 components of at most 255 UTF-8 bytes each, and no control
    /// characters. On Windows every component must also pass <see cref="WindowsSafe"/> and the
    /// whole path is limited to 1024 UTF-16 units, so UNC, drive, device and stream syntax can
    /// never reach the filesystem.
    /// </summary>
    public static IReadOnlyList<string>? Components(string? relative)
    {
        var normalized = PackagePaths.Normalize(relative);
        if (normalized is null || normalized != relative || DrivePrefix().IsMatch(normalized)) return null;
        if (normalized.Length > PackageLimits.MaxRelativePathUnits) return null;
        var parts = normalized.Split('/');
        if (parts.Length > PackageLimits.MaxPathDepth || !parts.All(ValidComponent)) return null;
        return parts;
    }

    /// <summary>
    /// <see cref="Components"/>, additionally refusing dot-files and the generated <c>__Build</c>
    /// cache at any depth. Those are never part of the authored package, so they are neither
    /// listed, read nor written.
    /// </summary>
    public static IReadOnlyList<string>? VisibleComponents(string? relative) =>
        Components(relative) is { } parts && !parts.Any(IsExcluded) ? parts : null;

    public static bool ValidComponent(string part) =>
        part.Length > 0 && part != "." && part != ".." && !part.Contains('/') && !part.Contains('\\') &&
        PackageNames.Utf8Length(part) <= PackageLimits.MaxComponentBytes && !PackageNames.HasControlCharacters(part) && WindowsSafe(part);

    public static bool IsExcluded(string part) => part.StartsWith('.') || PackageNames.Identity(part) == "__build";

    /// <summary>
    /// True when Windows stores <paramref name="part"/> as a file or directory of exactly that
    /// name. Refused: more than 255 UTF-16 units; a trailing dot or space (Win32 strips them, so
    /// the name would alias another file); a colon (alternate data stream or drive syntax); the
    /// characters <c>&lt; &gt; " | ? *</c>, either separator and U+0000–U+001F; and the reserved
    /// device names CON, PRN, AUX, NUL, COM0–COM9, LPT0–LPT9 (also with a superscript digit),
    /// CONIN$ and CONOUT$ in any case, with or without an extension.
    /// </summary>
    public static bool WindowsSafe(string part)
    {
        if (part.Length == 0 || part.Length > PackageLimits.MaxComponentUnits) return false;
        if (part[^1] is '.' or ' ') return false;
        foreach (var character in part)
        {
            if (character < 0x20 || character is '<' or '>' or ':' or '"' or '|' or '?' or '*' or '/' or '\\') return false;
        }
        return !IsReservedDeviceName(part);
    }

    /// <summary>Win32 resolves these names to devices whatever directory or extension they carry.</summary>
    private static bool IsReservedDeviceName(string part)
    {
        var dot = part.IndexOf('.');
        var stem = (dot < 0 ? part : part[..dot]).TrimEnd(' ').ToUpperInvariant();
        if (ReservedDeviceNames.Contains(stem)) return true;
        if (stem.Length != 4 || (!stem.StartsWith("COM", StringComparison.Ordinal) && !stem.StartsWith("LPT", StringComparison.Ordinal))) return false;
        return stem[3] is (>= '0' and <= '9') or '¹' or '²' or '³';
    }
}
