namespace ScriptWidget.Core.Packages;

/// <summary>
/// Central-directory validation of an untrusted <c>.swt</c> archive, ported from
/// <c>ScriptPackageArchivePreflight.validate</c> in Swift (and <c>preflightArchive</c> in
/// <c>archive.js</c>). It inspects bytes only and never inflates or writes anything.
/// </summary>
internal static class ArchivePreflight
{
    /// <summary>
    /// One central-directory entry that passed validation. <see cref="Parts"/> are the non-empty
    /// path components; <see cref="Index"/> is the position in the central directory.
    /// </summary>
    public sealed class Entry(int index, string name, IReadOnlyList<string> parts, bool isDirectory, long uncompressedSize, long crc)
    {
        public int Index { get; } = index;
        public string Name { get; } = name;
        public IReadOnlyList<string> Parts { get; } = parts;
        public bool IsDirectory { get; } = isDirectory;
        public long UncompressedSize { get; } = uncompressedSize;
        public long Crc { get; } = crc;
    }

    private const long EndSignature = 0x06054B50L;
    private const long CentralSignature = 0x02014B50L;
    private const long UInt32Max = 0xFFFFFFFFL;

    /// <summary>
    /// Validates the whole archive and returns its entries, or throws.
    ///
    /// Rejected: empty or oversized archives; a missing, multi-disk, trailing-garbage or
    /// out-of-bounds central directory; more entries than allowed; encrypted entries; compression
    /// other than stored/deflate; malformed ZIP64 sizes; entry names that are not UTF-8, are
    /// absolute, contain a backslash, colon, NUL, control character, <c>.</c> or <c>..</c>
    /// component, nest too deeply, or hold a component Windows cannot store safely (see
    /// <see cref="PackagePathRules.WindowsSafe"/>); duplicate, case-colliding or
    /// file-versus-directory clashing paths; symbolic links and other special files; a declared
    /// file size or declared total above the limits; and a large file that claims zero compressed
    /// bytes.
    /// </summary>
    public static List<Entry> Validate(byte[] data, ArchiveLimits limits)
    {
        if (data.Length == 0 || data.Length > limits.MaximumArchiveBytes) throw Fail(PackageErrors.ArchiveSize, "Archive must be between 1 byte and 32 MiB.");
        var end = EndOfCentralDirectory(data);
        if (end < 0) throw Fail(PackageErrors.ArchiveMalformed, "Archive has no valid ZIP central directory.");
        if (U16(data, end + 4) != 0 || U16(data, end + 6) != 0 || U16(data, end + 8) != U16(data, end + 10))
        {
            throw Fail(PackageErrors.ArchiveMultiDisk, "Multi-disk ZIP archives are not supported.");
        }
        if (end + 22 + U16(data, end + 20) != data.Length) throw Fail(PackageErrors.ArchiveMalformed, "Archive has a malformed ZIP footer.");
        var count = U16(data, end + 10);
        var centralSize = U32(data, end + 12);
        var centralOffset = U32(data, end + 16);
        if (count <= 0 || count > limits.MaximumFileCount)
        {
            throw Fail(PackageErrors.ArchiveTooManyEntries, $"Archive must contain 1–{limits.MaximumFileCount} entries.");
        }
        if (centralOffset + centralSize > data.Length) throw Fail(PackageErrors.ArchiveMalformed, "Archive central directory is out of bounds.");

        var cursor = (int)centralOffset;
        var expanded = 0L;
        var collisions = new Collisions();
        var entries = new List<Entry>(count);
        for (var index = 0; index < count; index++)
        {
            if (cursor + 46 > data.Length || U32(data, cursor) != CentralSignature)
            {
                throw Fail(PackageErrors.ArchiveMalformed, "Archive central directory contains an invalid entry.");
            }
            var flags = U16(data, cursor + 8);
            var method = U16(data, cursor + 10);
            var crc = U32(data, cursor + 16);
            var nameLength = U16(data, cursor + 28);
            var extraLength = U16(data, cursor + 30);
            var commentLength = U16(data, cursor + 32);
            var external = U32(data, cursor + 38);
            var entryEnd = cursor + 46 + nameLength + extraLength + commentLength;
            if (nameLength == 0 || entryEnd > data.Length) throw Fail(PackageErrors.ArchiveMalformed, "Archive contains a truncated filename.");
            var extraStart = cursor + 46 + nameLength;
            if (ResolvedSizes(U32(data, cursor + 20), U32(data, cursor + 24), data, extraStart, extraStart + extraLength) is not var (compressed, uncompressed))
            {
                throw Fail(PackageErrors.ArchiveMalformed, "Archive contains malformed ZIP64 size metadata.");
            }
            if ((flags & 0x1) != 0) throw Fail(PackageErrors.ArchiveEncrypted, "Encrypted package entries are not supported.");
            if (method != 0 && method != 8) throw Fail(PackageErrors.ArchiveUnsupportedCompression, $"Unsupported ZIP compression method {method}.");
            var name = SafeFiles.DecodeUtf8(data, cursor + 46, nameLength);
            var parts = name is null ? null : EntryParts(name, limits.MaximumPathDepth);
            if (name is null || parts is null) throw Fail(PackageErrors.ArchiveUnsafePath, "Archive contains an unsafe or non-UTF-8 path.");
            var isDirectory = name.EndsWith('/');
            if (!collisions.Add(name, parts, isDirectory))
            {
                throw Fail(PackageErrors.ArchivePathCollision, "Archive contains duplicate or case-colliding paths.");
            }
            // Unix mode in the high half: only regular files (0x8000), directories (0x4000) or
            // an absent type are accepted; 0xA000 is a symbolic link.
            var type = (int)((external >>> 16) & 0xF000L);
            if (type == 0xA000) throw Fail(PackageErrors.ArchiveSymlink, "Symbolic links are not allowed in ScriptWidget packages.");
            if (type != 0 && type != 0x8000 && type != 0x4000)
            {
                throw Fail(PackageErrors.ArchiveSymlink, "Only regular files and directories are allowed in ScriptWidget packages.");
            }
            if (!isDirectory)
            {
                // Sizes are unsigned 64-bit; a negative long is far above any limit.
                if (uncompressed < 0 || uncompressed > limits.MaximumFileBytes)
                {
                    throw Fail(PackageErrors.ArchiveFileTooLarge, $"Package file {name} exceeds 25 MiB.");
                }
                expanded += uncompressed;
                if (expanded > limits.MaximumExpandedBytes) throw Fail(PackageErrors.ArchiveExpandedTooLarge, "Expanded package exceeds 64 MiB.");
                if (uncompressed > 1024 * 1024 && compressed == 0L)
                {
                    throw Fail(PackageErrors.ArchiveInvalidRatio, $"Archive entry {name} has an invalid compression ratio.");
                }
            }
            entries.Add(new Entry(index, name, parts, isDirectory, uncompressed, crc));
            cursor = entryEnd;
        }
        if (cursor != centralOffset + centralSize)
        {
            throw Fail(PackageErrors.ArchiveMalformed, "Archive entries do not match the declared central directory.");
        }
        return entries;
    }

    /// <summary>
    /// Components of an archive entry name, or null when the name is unsafe: a leading slash,
    /// any backslash, colon (drive or stream syntax) or NUL, a <c>.</c>/<c>..</c> component, a
    /// component that is too long, holds control characters or is not safe on Windows, no
    /// components, more than <paramref name="maximumDepth"/>, or more than 1024 UTF-16 units in all.
    /// </summary>
    public static IReadOnlyList<string>? EntryParts(string name, int maximumDepth)
    {
        if (name.StartsWith('/') || name.Contains('\\') || name.Contains(':') || name.Contains('\0')) return null;
        if (name.Length > PackageLimits.MaxRelativePathUnits) return null;
        var parts = name.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || parts.Length > maximumDepth || !parts.All(PackagePathRules.ValidComponent)) return null;
        return parts;
    }

    /// <summary>
    /// Tracks every file and directory prefix seen so far. Two spellings of one identity
    /// (case or Unicode form), a repeated path, and a path used as both file and directory would
    /// overwrite or shadow each other on extraction, so each is a collision.
    /// </summary>
    private sealed class Collisions
    {
        private readonly HashSet<string> fullPaths = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> spellings = new(StringComparer.Ordinal);
        private readonly Dictionary<string, bool> directories = new(StringComparer.Ordinal);

        public bool Add(string name, IReadOnlyList<string> parts, bool isDirectory)
        {
            if (!fullPaths.Add(PackageNames.Identity(name).Trim('/'))) return false;
            var prefix = new System.Text.StringBuilder();
            for (var index = 0; index < parts.Count; index++)
            {
                if (index > 0) prefix.Append('/');
                prefix.Append(parts[index]);
                var path = prefix.ToString();
                var identity = PackageNames.Identity(path);
                if (!spellings.TryGetValue(identity, out var spelling)) spellings[identity] = spelling = path;
                if (spelling != path) return false;
                var directory = index < parts.Count - 1 || isDirectory;
                if (!directories.TryGetValue(path, out var known)) directories[path] = known = directory;
                if (known != directory) return false;
            }
            return true;
        }
    }

    private static (long Compressed, long Uncompressed)? ResolvedSizes(long compressed32, long uncompressed32, byte[] data, int extraStart, int extraEnd)
    {
        if (compressed32 != UInt32Max && uncompressed32 != UInt32Max) return (compressed32, uncompressed32);
        var compressed = compressed32;
        var uncompressed = uncompressed32;
        var cursor = extraStart;
        while (cursor + 4 <= extraEnd)
        {
            var identifier = U16(data, cursor);
            var end = cursor + 4 + U16(data, cursor + 2);
            if (end > extraEnd) return null;
            if (identifier == 0x0001)
            {
                var value = cursor + 4;
                if (uncompressed32 == UInt32Max)
                {
                    if (value + 8 > end) return null;
                    uncompressed = U64(data, value);
                    value += 8;
                }
                if (compressed32 == UInt32Max)
                {
                    if (value + 8 > end) return null;
                    compressed = U64(data, value);
                }
                return (compressed, uncompressed);
            }
            cursor = end;
        }
        return null;
    }

    /// <summary>Offset of the last end-of-central-directory record, or -1.</summary>
    private static int EndOfCentralDirectory(byte[] data)
    {
        if (data.Length < 22) return -1;
        var lowerBound = Math.Max(0, data.Length - 65_557);
        for (var index = data.Length - 22; index >= lowerBound; index--)
        {
            if (U32(data, index) == EndSignature) return index;
        }
        return -1;
    }

    private static int U16(byte[] data, int index) =>
        index < 0 || index + 2 > data.Length ? 0 : data[index] | (data[index + 1] << 8);

    private static long U32(byte[] data, int index) =>
        index < 0 || index + 4 > data.Length ? 0 : (long)U16(data, index) | ((long)U16(data, index + 2) << 16);

    private static long U64(byte[] data, int index) =>
        index < 0 || index + 8 > data.Length ? 0 : U32(data, index) | (U32(data, index + 4) << 32);

    private static PackageException Fail(string code, string message) => new(code, message);
}
