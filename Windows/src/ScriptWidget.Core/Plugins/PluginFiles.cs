using System.Globalization;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ScriptWidget.Core.Plugins;

/// <summary>
/// Link-refusing filesystem primitives of the plugin store: the part of the Android package
/// layer's <c>SafeFiles</c> that plugins use. Every lookup looks at the entry itself, so a symbolic
/// link or junction is seen as a link and never as its target.
///
/// A check and the following open are separate system calls; the opened handle is checked again
/// before anything is read. Plugin directories live in app-private storage.
/// </summary>
internal static class PluginFiles
{
    /// <summary>Most directory entries listed before a listing fails closed.</summary>
    private const int MaximumDirectoryEntries = 100_000;

    /// <summary>Raised when a directory cannot be staged or published; the message is safe to show.</summary>
    public sealed class StorageException(string message, Exception? cause = null) : Exception(message, cause);

    /// <summary>True when something, including a dangling link, occupies <paramref name="path"/>.</summary>
    public static bool Occupied(string path) => Attributes(path) is not null;

    /// <summary>Attributes of <paramref name="path"/> itself (never of a link target), or null when it is absent or unreadable.</summary>
    private static FileAttributes? Attributes(string path)
    {
        try { return File.GetAttributes(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary><paramref name="path"/> when it is a real directory rather than a link to one, else null.</summary>
    public static string? RealDirectory(string path) =>
        Attributes(path) is { } attributes && attributes.HasFlag(FileAttributes.Directory) && !attributes.HasFlag(FileAttributes.ReparsePoint) ? path : null;

    /// <summary>Entry names of <paramref name="directory"/>, or null when it cannot be listed or is implausibly large.</summary>
    public static List<string>? Names(string directory)
    {
        try
        {
            var result = new List<string>();
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
            {
                result.Add(Path.GetFileName(entry));
                if (result.Count > MaximumDirectoryEntries) return null;
            }
            return result;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// The identity two names share when a case-insensitive or normalizing filesystem would treat
    /// them as one entry: NFC, then locale-independent lower case.
    /// </summary>
    public static string Identity(string name)
    {
        try { return name.Normalize(NormalizationForm.FormC).ToLowerInvariant(); }
        catch (ArgumentException) { return name.ToLowerInvariant(); }
    }

    /// <summary>
    /// Resolves <paramref name="name"/> directly below <paramref name="directory"/> to an existing regular file, or null.
    /// The name must be spelled exactly as stored, must not be a link, must not have a case or
    /// Unicode-form alias, and must still be inside the directory.
    /// </summary>
    public static string? ExistingFile(string directory, string name)
    {
        if (RealDirectory(directory) is null || Names(directory) is not { } siblings) return null;
        var identity = Identity(name);
        if (!siblings.Contains(name, StringComparer.Ordinal) || siblings.Any(sibling => sibling != name && Identity(sibling) == identity)) return null;
        var child = Path.Combine(directory, name);
        if (Attributes(child) is not { } attributes || attributes.HasFlag(FileAttributes.Directory) || attributes.HasFlag(FileAttributes.ReparsePoint)) return null;
        var root = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return Path.GetFullPath(child).StartsWith(root, StringComparison.Ordinal) ? child : null;
    }

    /// <summary>
    /// Reads <paramref name="file"/>, or returns null when it holds more than <paramref name="maximumBytes"/>, is not a
    /// regular file, or has more than one hard link: a second link could expose or alter a file
    /// outside the plugin.
    /// </summary>
    public static byte[]? ReadBounded(string file, long maximumBytes)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information)) return null;
            if ((information.FileAttributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || information.NumberOfLinks > 1) return null;
            using var output = new MemoryStream();
            var buffer = new byte[16 * 1024];
            long total = 0;
            while (true)
            {
                var count = stream.Read(buffer, 0, buffer.Length);
                if (count <= 0) break;
                total += count;
                // The size is counted while reading, never taken from metadata that may change.
                if (total > maximumBytes) return null;
                output.Write(buffer, 0, count);
            }
            return output.ToArray();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Creates <paramref name="file"/> exclusively, writes <paramref name="bytes"/> and flushes them to storage.</summary>
    public static void WriteNew(string file, byte[] bytes)
    {
        using var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush(flushToDisk: true);
    }

    /// <summary>Creates a uniquely named private working directory below <paramref name="stagingRoot"/>.</summary>
    public static string NewWorkDirectory(string stagingRoot, string prefix)
    {
        try
        {
            Directory.CreateDirectory(stagingRoot);
            if (RealDirectory(stagingRoot) is null) throw new IOException("Staging directory is a link");
            var path = Path.Combine(stagingRoot, $"{prefix}-{Guid.NewGuid():D}");
            if (Occupied(path)) throw new IOException("Staging directory already exists");
            Directory.CreateDirectory(path);
            return path;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new StorageException("The staging directory is unavailable.", error);
        }
    }

    /// <summary>
    /// Publishes a prepared directory with one rename, so observers see either nothing or the
    /// complete plugin. <paramref name="destination"/> must be free; callers hold the store lock.
    /// </summary>
    public static void Publish(string prepared, string destination)
    {
        if (Occupied(destination)) throw new StorageException("A package with this name already exists.");
        try { Directory.Move(prepared, destination); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new StorageException("The package could not be published.", error); }
    }

    /// <summary>Removes <paramref name="path"/> and everything below it. Links are removed, never followed. Best effort.</summary>
    public static void DeleteTree(string path)
    {
        if (Attributes(path) is not { } attributes) return;
        try
        {
            if (!attributes.HasFlag(FileAttributes.Directory)) File.Delete(path);
            else if (attributes.HasFlag(FileAttributes.ReparsePoint)) Directory.Delete(path, recursive: false);
            else Directory.Delete(path, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Leftovers stay inside the private staging directory and are retried by later cleanups.
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation information);
}

/// <summary>
/// Central-directory validation and bounded inflation of an untrusted <c>.swplugin</c> archive: the
/// archive preflight of the package layer (<c>ScriptPackageArchivePreflight.validate</c> in Swift),
/// kept here so the plugin store does not depend on the package store. Validation inspects bytes
/// only and never inflates or writes anything.
/// </summary>
internal static class PluginArchive
{
    /// <summary>One central-directory entry that passed validation. <see cref="Parts"/> are the non-empty path components.</summary>
    public sealed record Entry(string Name, IReadOnlyList<string> Parts, bool IsDirectory, long UncompressedSize, long Crc);

    // ScriptPackageArchivePolicy.
    private const int MaximumArchiveBytes = 32 * 1024 * 1024;
    private const long MaximumExpandedBytes = 64L * 1024 * 1024;
    private const long MaximumFileBytes = 25L * 1024 * 1024;
    private const int MaximumFileCount = 500;
    private const int MaximumPathDepth = 16;
    private const int MaximumComponentBytes = 255;

    private const long EndSignature = 0x06054B50L;
    private const long CentralSignature = 0x02014B50L;
    private const long UInt32Max = 0xFFFFFFFFL;

    /// <summary>
    /// Validates the whole archive and returns its entries, or throws.
    ///
    /// Rejected: empty or oversized archives; a missing, multi-disk, trailing-garbage or
    /// out-of-bounds central directory; more entries than allowed; encrypted entries; compression
    /// other than stored/deflate; malformed ZIP64 sizes; entry names that are not UTF-8, are
    /// absolute, contain a backslash, colon, NUL, control character, <c>.</c> or <c>..</c> component, or
    /// nest too deeply; duplicate, case-colliding or file-versus-directory clashing paths; symbolic
    /// links and other special files; a declared file size or declared total above the limits;
    /// and a large file that claims zero compressed bytes.
    /// </summary>
    public static List<Entry> Validate(byte[] data)
    {
        if (data.Length == 0 || data.Length > MaximumArchiveBytes) throw Fail("Archive must be between 1 byte and 32 MiB.");
        var end = EndOfCentralDirectory(data);
        if (end < 0) throw Fail("Archive has no valid ZIP central directory.");
        if (U16(data, end + 4) != 0 || U16(data, end + 6) != 0 || U16(data, end + 8) != U16(data, end + 10)) throw Fail("Multi-disk ZIP archives are not supported.");
        if (end + 22 + U16(data, end + 20) != data.Length) throw Fail("Archive has a malformed ZIP footer.");
        var count = U16(data, end + 10);
        var centralSize = U32(data, end + 12);
        var centralOffset = U32(data, end + 16);
        if (count <= 0 || count > MaximumFileCount) throw Fail($"Archive must contain 1–{MaximumFileCount} entries.");
        if (centralOffset + centralSize > data.Length) throw Fail("Archive central directory is out of bounds.");

        var cursor = (int)centralOffset;
        long expanded = 0;
        var collisions = new Collisions();
        var entries = new List<Entry>(count);
        for (var index = 0; index < count; index++)
        {
            if (cursor + 46 > data.Length || U32(data, cursor) != CentralSignature) throw Fail("Archive central directory contains an invalid entry.");
            var flags = U16(data, cursor + 8);
            var method = U16(data, cursor + 10);
            var crc = U32(data, cursor + 16);
            var nameLength = U16(data, cursor + 28);
            var extraLength = U16(data, cursor + 30);
            var commentLength = U16(data, cursor + 32);
            var external = U32(data, cursor + 38);
            var entryEnd = cursor + 46 + nameLength + extraLength + commentLength;
            if (nameLength == 0 || entryEnd > data.Length) throw Fail("Archive contains a truncated filename.");
            var extraStart = cursor + 46 + nameLength;
            if (ResolvedSizes(U32(data, cursor + 20), U32(data, cursor + 24), data, extraStart, extraStart + extraLength) is not { } sizes)
            {
                throw Fail("Archive contains malformed ZIP64 size metadata.");
            }
            var (compressed, uncompressed) = sizes;
            if ((flags & 0x1) != 0) throw Fail("Encrypted package entries are not supported.");
            if (method != 0 && method != 8) throw Fail($"Unsupported ZIP compression method {method.ToString(CultureInfo.InvariantCulture)}.");
            var name = DecodeUtf8(data, cursor + 46, nameLength);
            var parts = name is null ? null : EntryParts(name, MaximumPathDepth);
            if (name is null || parts is null) throw Fail("Archive contains an unsafe or non-UTF-8 path.");
            var isDirectory = name.EndsWith('/');
            if (!collisions.Add(name, parts, isDirectory)) throw Fail("Archive contains duplicate or case-colliding paths.");
            // Unix mode in the high half: only regular files (0x8000), directories (0x4000) or
            // an absent type are accepted; 0xA000 is a symbolic link.
            var type = (int)((external >> 16) & 0xF000L);
            if (type == 0xA000) throw Fail("Symbolic links are not allowed in ScriptWidget packages.");
            if (type != 0 && type != 0x8000 && type != 0x4000) throw Fail("Only regular files and directories are allowed in ScriptWidget packages.");
            if (!isDirectory)
            {
                // Sizes are unsigned 64-bit; a negative value is far above any limit.
                if (uncompressed < 0 || uncompressed > MaximumFileBytes) throw Fail($"Package file {name} exceeds 25 MiB.");
                expanded += uncompressed;
                if (expanded > MaximumExpandedBytes) throw Fail("Expanded package exceeds 64 MiB.");
                if (uncompressed > 1024 * 1024 && compressed == 0L) throw Fail($"Archive entry {name} has an invalid compression ratio.");
            }
            entries.Add(new Entry(name, parts, isDirectory, uncompressed, crc));
            cursor = entryEnd;
        }
        if (cursor != centralOffset + centralSize) throw Fail("Archive entries do not match the declared central directory.");
        return entries;
    }

    /// <summary>
    /// Inflates one validated entry in memory, counting real bytes so false size headers cannot
    /// expand, and checks its CRC-32. Throws <see cref="InvalidDataException"/> when the entry is
    /// missing, does not match its declared size or checksum, or exceeds <paramref name="maximumBytes"/>.
    /// </summary>
    public static byte[] Inflate(ZipArchive zip, Entry entry, int maximumBytes)
    {
        var zipEntry = zip.GetEntry(entry.Name);
        if (zipEntry is null || zipEntry.FullName.EndsWith('/')) throw new InvalidDataException();
        using var output = new MemoryStream();
        var crc = 0xFFFFFFFFu;
        using (var input = zipEntry.Open())
        {
            var buffer = new byte[16 * 1024];
            while (true)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count <= 0) break;
                if (output.Length + count > entry.UncompressedSize || output.Length + count > maximumBytes) throw new InvalidDataException();
                for (var index = 0; index < count; index++) crc = CrcTable[(crc ^ buffer[index]) & 0xFF] ^ (crc >> 8);
                output.Write(buffer, 0, count);
            }
        }
        if (output.Length != entry.UncompressedSize || (crc ^ 0xFFFFFFFFu) != entry.Crc) throw new InvalidDataException();
        return output.ToArray();
    }

    /// <summary>
    /// Components of an archive entry name, or null when the name is unsafe: a leading slash,
    /// any backslash, colon (drive or stream syntax) or NUL, a <c>.</c>/<c>..</c> component, a component
    /// that is too long or holds control characters, no components, or more than <paramref name="maximumDepth"/>.
    /// </summary>
    public static IReadOnlyList<string>? EntryParts(string name, int maximumDepth)
    {
        if (name.StartsWith('/') || name.Contains('\\') || name.Contains(':') || name.Contains('\0')) return null;
        var parts = name.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || parts.Length > maximumDepth || !parts.All(ValidComponent)) return null;
        return parts;
    }

    private static bool ValidComponent(string part) =>
        part.Length > 0 && part != "." && part != ".." && !part.Contains('/') && !part.Contains('\\') &&
        Encoding.UTF8.GetByteCount(part) <= MaximumComponentBytes && !HasControlCharacters(part);

    /// <summary>Control, format (except ZWNJ/ZWJ, which joined emoji and some scripts need) or unpaired surrogate characters.</summary>
    private static bool HasControlCharacters(string text)
    {
        for (var index = 0; index < text.Length; index++)
        {
            if (!Rune.TryGetRuneAt(text, index, out var rune)) return true;
            if (rune.Value is 0x200C or 0x200D) continue;
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format) return true;
            index += rune.Utf16SequenceLength - 1;
        }
        return false;
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
            if (!fullPaths.Add(PluginFiles.Identity(name).Trim('/'))) return false;
            var prefix = new StringBuilder();
            for (var index = 0; index < parts.Count; index++)
            {
                if (index > 0) prefix.Append('/');
                prefix.Append(parts[index]);
                var path = prefix.ToString();
                var identity = PluginFiles.Identity(path);
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

    private static string? DecodeUtf8(byte[] data, int offset, int length)
    {
        try { return new UTF8Encoding(false, true).GetString(data, offset, length); }
        catch (DecoderFallbackException) { return null; }
    }

    private static int U16(byte[] data, int index) => index < 0 || index + 2 > data.Length ? 0 : data[index] | (data[index + 1] << 8);

    private static long U32(byte[] data, int index) => index < 0 || index + 4 > data.Length ? 0 : (long)U16(data, index) | ((long)U16(data, index + 2) << 16);

    private static long U64(byte[] data, int index) => index < 0 || index + 8 > data.Length ? 0 : U32(data, index) | (U32(data, index + 4) << 32);

    private static readonly uint[] CrcTable = BuildCrcTable();

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint index = 0; index < 256; index++)
        {
            var value = index;
            for (var bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xEDB88320u ^ (value >> 1) : value >> 1;
            table[index] = value;
        }
        return table;
    }

    private static PluginException Fail(string message) => new(PluginErrorKind.InvalidManifest, message);
}
