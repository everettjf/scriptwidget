using System.IO.Compression;
using System.Text;

namespace ScriptWidget.Core.Packages;

/// <summary>
/// A package extracted from an archive into a private staging directory. Nothing is visible in
/// the library until <see cref="MoveTo"/> succeeds; <see cref="Dispose"/> removes whatever is
/// still in staging, so a failed or abandoned import leaves nothing behind.
/// </summary>
public sealed class ExtractedPackage : IDisposable
{
    private readonly string workDirectory;

    internal ExtractedPackage(string directory, string? rootName, string workDirectory)
    {
        Directory = directory;
        RootName = rootName;
        this.workDirectory = workDirectory;
    }

    /// <summary>The extracted package root (inside the staging directory until moved).</summary>
    public string Directory { get; }

    /// <summary>Name of the single top-level archive directory, or null when files sat at the archive root.</summary>
    public string? RootName { get; }

    /// <summary>
    /// Publishes the package with one atomic rename. <paramref name="destination"/> must not exist
    /// and must be on the same volume as the staging directory.
    /// </summary>
    public void MoveTo(string destination) => SafeFiles.Publish(Directory, SafeFiles.Root(destination));

    public void Dispose() => SafeFiles.DeleteTree(workDirectory);
}

/// <summary>
/// <c>.swt</c> (ZIP) import and export with the hardening of the Swift implementation
/// (<c>ScriptPackageArchivePreflight</c>, <c>ScriptManager.importScriptPackage</c>).
///
/// Archives are untrusted. The whole central directory is validated before anything is written;
/// extraction happens in a unique directory under a caller-supplied staging directory; and the
/// sizes an archive declares are never trusted, only the bytes actually inflated.
/// </summary>
public static class PackageArchive
{
    private const string MacosResourceDirectory = "__MACOSX";
    private static readonly DateTimeOffset FixedEntryTime = new(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// Validates <paramref name="archive"/> without extracting it and returns its entry names.
    /// </summary>
    /// <exception cref="PackageException">With an <c>archive_*</c> code for every rule listed on the class.</exception>
    public static IReadOnlyList<string> Preflight(byte[] archive, ArchiveLimits? limits = null) =>
        ArchivePreflight.Validate(archive, limits ?? new ArchiveLimits()).Select(entry => entry.Name).ToList();

    /// <summary>
    /// Reads, validates and extracts one package from <paramref name="input"/>.
    ///
    /// Steps, each failing closed: read at most the archive byte limit; preflight the complete
    /// central directory; pick the package root (files at the archive root, or exactly one
    /// top-level directory); extract only that root into a fresh directory under
    /// <paramref name="stagingDirectory"/>; verify the extracted tree. Dot-files, <c>__MACOSX</c>
    /// and <c>__Build</c> (generated cache that must never be accepted from an archive) are not
    /// extracted. While inflating, bytes are counted and extraction stops as soon as an entry
    /// exceeds its declared size or a limit, so a zip bomb with false size headers cannot expand;
    /// the CRC-32 must match as well. Every target is checked to be canonically inside the fresh
    /// directory before it is created.
    ///
    /// The caller must dispose the result. On failure the staging directory is already clean.
    /// </summary>
    public static ExtractedPackage Extract(Stream input, string stagingDirectory, ArchiveLimits? limits = null)
    {
        limits ??= new ArchiveLimits();
        var bytes = ReadArchive(input, limits);
        var entries = ArchivePreflight.Validate(bytes, limits);
        var selection = Select(entries);
        var work = SafeFiles.NewWorkDirectory(SafeFiles.Root(stagingDirectory), "import");
        try
        {
            var tree = SafeFiles.Child(work, "package");
            Directory.CreateDirectory(tree);
            var total = 0L;
            using (var zip = new ZipArchive(new MemoryStream(bytes, writable: false), ZipArchiveMode.Read, leaveOpen: false, Encoding.UTF8))
            {
                foreach (var (parts, entry) in selection.Files)
                {
                    var zipEntry = entry.Index < zip.Entries.Count ? zip.Entries[entry.Index] : null;
                    if (zipEntry is null || zipEntry.FullName != entry.Name) throw Corrupt(entry.Name, null);
                    // Preflight refused these already; the reader's own view must agree.
                    if (zipEntry.IsEncrypted) throw new PackageException(PackageErrors.ArchiveEncrypted, "Encrypted package entries are not supported.");
                    if (((zipEntry.ExternalAttributes >>> 16) & 0xF000) == 0xA000)
                    {
                        throw new PackageException(PackageErrors.ArchiveSymlink, "Symbolic links are not allowed in ScriptWidget packages.");
                    }
                    var target = parts.Aggregate(tree, SafeFiles.Child);
                    if (!SafeFiles.Inside(tree, target)) throw new PackageException(PackageErrors.ArchiveUnsafePath, "Archive contains an unsafe or non-UTF-8 path.");
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    using var stream = zipEntry.Open();
                    total += CopyEntry(stream, target, entry, total, limits);
                }
            }
            PackageTree.Validate(tree, limits);
            return new ExtractedPackage(tree, selection.RootName, work);
        }
        catch (Exception error)
        {
            SafeFiles.DeleteTree(work);
            if (error is not PackageException && (SafeFiles.IsFileError(error) || error is InvalidDataException or ArgumentException))
            {
                throw new PackageException(PackageErrors.ArchiveCorrupt, "The package could not be extracted.", error);
            }
            throw;
        }
    }

    /// <summary>
    /// <see cref="Extract"/> followed by an atomic move to <paramref name="destination"/>; the
    /// staging directory is cleaned whether or not the import succeeds. Returns the archive's
    /// top-level directory name, if any.
    /// </summary>
    public static string? ImportTo(Stream input, string stagingDirectory, string destination, ArchiveLimits? limits = null)
    {
        using var extracted = Extract(input, stagingDirectory, limits);
        extracted.MoveTo(destination);
        return extracted.RootName;
    }

    /// <summary>
    /// Writes the package in <paramref name="packageDirectory"/> to <paramref name="output"/> as a
    /// <c>.swt</c> archive whose entries live under one <c>rootName/</c> directory.
    ///
    /// Dot-files, <c>__Build</c>, links, hard-linked and special files are skipped (they are not
    /// part of the authored package and must not leak through an export). Entries are sorted and
    /// carry a fixed timestamp, so the same package always yields the same bytes. The export
    /// obeys the import limits, so every exported archive can be imported again.
    /// <paramref name="extraFiles"/> adds generated files (for example a migrated
    /// <c>widget.json</c>) that are absent on disk. Nothing is written to
    /// <paramref name="output"/> unless the whole archive was produced.
    /// </summary>
    public static void Export(
        string packageDirectory,
        string rootName,
        Stream output,
        IReadOnlyDictionary<string, byte[]>? extraFiles = null,
        ArchiveLimits? limits = null)
    {
        limits ??= new ArchiveLimits();
        var root = PackageNames.ArchiveRootName(rootName);
        var files = new DiskPackageFiles(packageDirectory);
        var contents = new SortedDictionary<string, byte[]?>(StringComparer.Ordinal);
        foreach (var path in files.Paths()) contents[path] = null;
        foreach (var (path, bytes) in extraFiles ?? new Dictionary<string, byte[]>())
        {
            if (PackagePathRules.VisibleComponents(path) is null) throw new PackageException(PackageErrors.InvalidPath, "Invalid package path.");
            // As in the Kotlin (putIfAbsent over a null value): an extra file takes the place of a disk file of the same path.
            if (!contents.TryGetValue(path, out var present) || present is null) contents[path] = bytes;
        }
        if (contents.Count == 0) throw new PackageException(PackageErrors.ArchiveNoPackage, $"A package must contain 1–{limits.MaximumFileCount} files.");
        if (contents.Count > limits.MaximumFileCount) throw new PackageException(PackageErrors.TooManyEntries, $"A package must contain 1–{limits.MaximumFileCount} files.");

        var buffer = new BoundedOutput(limits.MaximumArchiveBytes);
        var total = 0L;
        // Disposed only on success: closing a failed archive would write a central directory and could mask the failure.
        var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true, Encoding.UTF8);
        foreach (var (path, extra) in contents)
        {
            var name = $"{root}/{path}";
            // The importer would refuse this name, so exporting it would produce a dead archive.
            if (ArchivePreflight.EntryParts(name, limits.MaximumPathDepth) is null)
            {
                throw new PackageException(PackageErrors.InvalidPath, $"Package path {path} cannot be exported.");
            }
            var bytes = extra ?? files.ReadBytes(path, limits.MaximumFileBytes)
                ?? throw new PackageException(PackageErrors.FileTooLarge, $"Package file {path} is unreadable or exceeds 25 MiB.");
            if (bytes.Length > limits.MaximumFileBytes) throw new PackageException(PackageErrors.FileTooLarge, $"Package file {path} exceeds 25 MiB.");
            total += bytes.Length;
            if (total > limits.MaximumExpandedBytes) throw new PackageException(PackageErrors.PackageTooLarge, "Expanded package exceeds 64 MiB.");
            var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
            entry.LastWriteTime = FixedEntryTime;
            using var stream = entry.Open();
            stream.Write(bytes, 0, bytes.Length);
        }
        zip.Dispose();
        buffer.WriteTo(output);
    }

    private sealed record Selection(IReadOnlyList<(IReadOnlyList<string> Parts, ArchivePreflight.Entry Entry)> Files, string? RootName);

    /// <summary>
    /// Chooses the package root like <c>ScriptManager.extractedPackageRoot</c>: the archive root
    /// when <c>main.jsx</c> or <c>widget.json</c> sits there, otherwise the only top-level directory.
    /// </summary>
    private static Selection Select(List<ArchivePreflight.Entry> entries)
    {
        var files = entries.Where(entry => !entry.IsDirectory && entry.Parts[0] != MacosResourceDirectory && !entry.Parts.Any(PackagePathRules.IsExcluded)).ToList();
        if (files.Any(entry => entry.Parts.Count == 1 && entry.Parts[0] is "main.jsx" or "widget.json"))
        {
            return new Selection(files.Select(entry => (entry.Parts, entry)).ToList(), null);
        }
        var roots = files.Where(entry => entry.Parts.Count > 1).Select(entry => entry.Parts[0]).ToHashSet(StringComparer.Ordinal);
        if (roots.Count != 1) throw new PackageException(PackageErrors.ArchiveNoPackage, "The archive must contain one widget package.");
        var root = roots.First();
        return new Selection(
            files.Where(entry => entry.Parts.Count > 1 && entry.Parts[0] == root).Select(entry => ((IReadOnlyList<string>)entry.Parts.Skip(1).ToList(), entry)).ToList(),
            root);
    }

    private static byte[] ReadArchive(Stream input, ArchiveLimits limits)
    {
        using var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        try
        {
            while (true)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count <= 0) break;
                output.Write(buffer, 0, count);
                if (output.Length > limits.MaximumArchiveBytes) break;
            }
        }
        catch (Exception error) when (SafeFiles.IsFileError(error))
        {
            throw new PackageException(PackageErrors.ArchiveCorrupt, "Archive could not be read.", error);
        }
        if (output.Length == 0 || output.Length > limits.MaximumArchiveBytes)
        {
            throw new PackageException(PackageErrors.ArchiveSize, "Archive must be between 1 byte and 32 MiB.");
        }
        return output.ToArray();
    }

    /// <summary>
    /// Inflates one entry into a new file, counting real bytes; returns the number written. The
    /// length the reader reports is never used: only bytes that were actually produced count.
    /// </summary>
    private static long CopyEntry(Stream input, string target, ArchivePreflight.Entry entry, long totalBefore, ArchiveLimits limits)
    {
        var crc = new Crc32();
        var count = 0L;
        using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            var buffer = new byte[16 * 1024];
            while (true)
            {
                int read;
                try
                {
                    read = input.Read(buffer, 0, buffer.Length);
                }
                catch (Exception error) when (SafeFiles.IsFileError(error) || error is InvalidDataException)
                {
                    throw Corrupt(entry.Name, error);
                }
                if (read <= 0) break;
                count += read;
                if (count > entry.UncompressedSize || count > limits.MaximumFileBytes)
                {
                    throw new PackageException(PackageErrors.ArchiveSizeMismatch, $"Archive entry {entry.Name} does not match its declared size.");
                }
                if (totalBefore + count > limits.MaximumExpandedBytes)
                {
                    throw new PackageException(PackageErrors.ArchiveExpandedTooLarge, "Expanded package exceeds 64 MiB.");
                }
                crc.Update(buffer, 0, read);
                output.Write(buffer, 0, read);
            }
        }
        if (count != entry.UncompressedSize)
        {
            throw new PackageException(PackageErrors.ArchiveSizeMismatch, $"Archive entry {entry.Name} does not match its declared size.");
        }
        if (crc.Value != entry.Crc) throw Corrupt(entry.Name, null);
        return count;
    }

    private static PackageException Corrupt(string name, Exception? cause) =>
        new(PackageErrors.ArchiveCorrupt, $"Archive entry {name} is corrupt.", cause);

    /// <summary>In-memory sink that refuses to grow past the archive byte limit.</summary>
    private sealed class BoundedOutput(int limit) : MemoryStream
    {
        public override void WriteByte(byte value)
        {
            Ensure(1);
            base.WriteByte(value);
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            Ensure(count);
            base.Write(buffer, offset, count);
        }

        public override void Write(ReadOnlySpan<byte> buffer)
        {
            Ensure(buffer.Length);
            base.Write(buffer);
        }

        private void Ensure(int extra)
        {
            if (Position + extra > limit) throw new PackageException(PackageErrors.ArchiveSize, "Archive exceeds 32 MiB.");
        }
    }
}

/// <summary>CRC-32 (IEEE 802.3, as used by ZIP) over the bytes fed to <see cref="Update"/>.</summary>
internal sealed class Crc32
{
    private static readonly uint[] Table = BuildTable();
    private uint state = 0xFFFFFFFF;

    /// <summary>The checksum of everything fed so far, as an unsigned 32-bit value.</summary>
    public long Value => state ^ 0xFFFFFFFF;

    public void Update(byte[] buffer, int offset, int count)
    {
        var current = state;
        for (var index = offset; index < offset + count; index++) current = Table[(current ^ buffer[index]) & 0xFF] ^ (current >> 8);
        state = current;
    }

    public static long Of(byte[] bytes)
    {
        var crc = new Crc32();
        crc.Update(bytes, 0, bytes.Length);
        return crc.Value;
    }

    private static uint[] BuildTable()
    {
        var table = new uint[256];
        for (uint index = 0; index < 256; index++)
        {
            var value = index;
            for (var bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
            table[index] = value;
        }
        return table;
    }
}
