using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ScriptWidget.Core.Packages;

/// <summary>What <see cref="SafeFiles.Attributes"/> reports about a path itself, never about a link target.</summary>
/// <param name="IsDirectory">A directory that is not a reparse point.</param>
/// <param name="IsSymbolicLink">Any reparse point: a symbolic link, junction or mount point.</param>
/// <param name="IsRegularFile">A plain file: not a directory, reparse point or device.</param>
/// <param name="Size">File size in bytes as the filesystem reports it.</param>
internal readonly record struct FileEntry(bool IsDirectory, bool IsSymbolicLink, bool IsRegularFile, long Size);

/// <summary>
/// Link-refusing filesystem primitives shared by the package layer. Every lookup reads the
/// attributes of the path itself, so a reparse point (symbolic link, junction, mount point) is
/// seen as a link and never as its target; files are opened with
/// <c>FILE_FLAG_OPEN_REPARSE_POINT</c> and checked again on the open handle.
///
/// Unlike the Swift implementation these cannot hold directory handles (<c>openat</c>), so a check
/// and the following open are separate system calls. Package directories live in app-private
/// storage. Paths are joined by plain concatenation (<see cref="Child"/>), never with
/// <c>Path.Combine</c>, which would let a rooted name replace the directory.
/// </summary>
internal static partial class SafeFiles
{
    private static readonly EnumerationOptions EverythingInDirectory = new()
    {
        AttributesToSkip = 0,
        IgnoreInaccessible = false,
        RecurseSubdirectories = false,
        ReturnSpecialDirectories = false,
        MatchType = MatchType.Simple,
    };

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>The absolute form of a caller-supplied root directory, without a trailing separator.</summary>
    public static string Root(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    /// <summary><paramref name="name"/> directly below <paramref name="directory"/>. The name must be a validated component.</summary>
    public static string Child(string directory, string name) =>
        directory.EndsWith(Path.DirectorySeparatorChar) ? directory + name : directory + Path.DirectorySeparatorChar + name;

    /// <summary>Attributes of <paramref name="path"/> itself (never of a link target), or null when it is absent or unreadable.</summary>
    public static FileEntry? Attributes(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            var link = attributes.HasFlag(FileAttributes.ReparsePoint);
            var directory = attributes.HasFlag(FileAttributes.Directory);
            var regular = !link && !directory && !attributes.HasFlag(FileAttributes.Device);
            return new FileEntry(directory && !link, link, regular, regular ? new FileInfo(path).Length : 0);
        }
        catch (Exception error) when (IsFileError(error))
        {
            return null;
        }
    }

    /// <summary>True when something, including a dangling link, occupies <paramref name="path"/>.</summary>
    public static bool Occupied(string path)
    {
        try
        {
            File.GetAttributes(path);
            return true;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return false;
        }
        catch (Exception error) when (IsFileError(error))
        {
            // Present but unreadable still occupies the name.
            return true;
        }
    }

    /// <summary><paramref name="path"/> when it is a real directory rather than a link to one, else null.</summary>
    public static string? RealDirectory(string path) => Attributes(path) is { IsDirectory: true, IsSymbolicLink: false } ? path : null;

    /// <summary>Entry names of <paramref name="directory"/>, or null when it cannot be listed or is implausibly large.</summary>
    public static List<string>? Names(string directory)
    {
        try
        {
            var result = new List<string>();
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory, "*", EverythingInDirectory))
            {
                result.Add(Path.GetFileName(entry));
                if (result.Count > PackageLimits.MaxDirectoryEntries) return null;
            }
            return result;
        }
        catch (Exception error) when (IsFileError(error))
        {
            return null;
        }
    }

    /// <summary>
    /// False when <paramref name="names"/> holds a different spelling of <paramref name="name"/>
    /// (another case or Unicode form). Such aliases resolve to one file on some filesystems and
    /// two on others, so they are refused.
    /// </summary>
    public static bool Unambiguous(IReadOnlyList<string> names, string name)
    {
        var identity = PackageNames.Identity(name);
        return !names.Any(other => other != name && PackageNames.Identity(other) == identity);
    }

    /// <summary>
    /// False for a regular file with more than one hard link: a second link could expose or alter
    /// a file outside the package. Also false when the link count cannot be read.
    /// </summary>
    public static bool SinglyLinked(string path)
    {
        using var handle = Open(path, access: 0);
        return handle is not null && GetFileInformationByHandle(handle, out var information) && information.NumberOfLinks <= 1;
    }

    /// <summary>
    /// Resolves <paramref name="parts"/> below <paramref name="root"/> to an existing regular file, or null.
    ///
    /// Each component must be spelled exactly as stored, must not be a link, and must not have a
    /// case alias; intermediate components must be directories. The canonical path of the result
    /// must still be inside the canonical root, which catches anything the walk could have missed.
    /// </summary>
    public static string? ExistingFile(string root, IReadOnlyList<string> parts)
    {
        var directory = RealDirectory(root);
        if (directory is null) return null;
        for (var index = 0; index < parts.Count; index++)
        {
            var name = parts[index];
            var siblings = Names(directory);
            if (siblings is null || !siblings.Contains(name) || !Unambiguous(siblings, name)) return null;
            var child = Child(directory, name);
            if (Attributes(child) is not { } info || info.IsSymbolicLink) return null;
            if (index < parts.Count - 1)
            {
                if (!info.IsDirectory) return null;
                directory = child;
            }
            else
            {
                if (!info.IsRegularFile || !SinglyLinked(child) || !Inside(root, child)) return null;
                return child;
            }
        }
        return null;
    }

    /// <summary>
    /// True when <paramref name="path"/> is in canonical form and strictly below the canonical
    /// form of <paramref name="root"/>. The canonical form is <c>Path.GetFullPath</c>; a path that
    /// Win32 would rewrite (a <c>..</c> component, a trailing dot or space, a device name) is not
    /// its own canonical form and is refused, as is one longer than 2048 UTF-16 units. The prefix
    /// test includes the separator, so <c>root2</c> is never inside <c>root</c>. Links are not
    /// resolved here: callers refuse every reparse point between root and path.
    /// </summary>
    public static bool Inside(string root, string path)
    {
        try
        {
            var canonicalRoot = Root(root);
            var canonical = Path.GetFullPath(path);
            if (canonical != path || canonical.Length > PackageLimits.MaxFullPathUnits) return false;
            var prefix = canonicalRoot.EndsWith(Path.DirectorySeparatorChar) ? canonicalRoot : canonicalRoot + Path.DirectorySeparatorChar;
            return canonical.Length > prefix.Length && canonical.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (IsFileError(error) || error is ArgumentException)
        {
            return false;
        }
    }

    /// <summary>
    /// Reads <paramref name="file"/> without following a link, or returns null when it holds more
    /// than <paramref name="maximumBytes"/> or is not a plain file.
    /// </summary>
    public static byte[]? ReadBounded(string file, long maximumBytes)
    {
        try
        {
            using var handle = Open(file, GenericRead);
            if (handle is null || !GetFileInformationByHandle(handle, out var information)) return null;
            if ((information.FileAttributes & (uint)(FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Device)) != 0) return null;
            using var input = new FileStream(handle, FileAccess.Read, bufferSize: 0, isAsync: false);
            using var output = new MemoryStream();
            var buffer = new byte[16 * 1024];
            var total = 0L;
            while (true)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count <= 0) break;
                total += count;
                // The size is counted while reading, never taken from metadata that may change.
                if (total > maximumBytes) return null;
                output.Write(buffer, 0, count);
            }
            return output.ToArray();
        }
        catch (Exception error) when (IsFileError(error))
        {
            return null;
        }
    }

    /// <summary>Strict UTF-8 decoding: malformed input yields null instead of replacement characters.</summary>
    public static string? DecodeUtf8(byte[] bytes) => DecodeUtf8(bytes, 0, bytes.Length);

    public static string? DecodeUtf8(byte[] bytes, int offset, int length)
    {
        try
        {
            return StrictUtf8.GetString(bytes, offset, length);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    /// <summary>Creates <paramref name="file"/> exclusively, writes <paramref name="bytes"/> and flushes them to storage.</summary>
    public static void WriteNew(string file, byte[] bytes)
    {
        using var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, bufferSize: 0);
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
            var work = Child(stagingRoot, $"{prefix}-{Guid.NewGuid()}");
            if (Occupied(work)) throw new IOException("Staging work directory already exists");
            Directory.CreateDirectory(work);
            return work;
        }
        catch (Exception error) when (IsFileError(error))
        {
            throw new PackageException(PackageErrors.StorageUnavailable, "The staging directory is unavailable.", error);
        }
    }

    /// <summary>
    /// Publishes a prepared directory with one atomic rename, so observers see either nothing or
    /// the complete package. <paramref name="destination"/> must be free; the rename itself also
    /// refuses an existing destination, and callers hold the store lock.
    /// </summary>
    public static void Publish(string prepared, string destination)
    {
        if (Occupied(destination)) throw new PackageException(PackageErrors.PackageExists, "A package with this name already exists.");
        if (destination.Length > PackageLimits.MaxFullPathUnits) throw new PackageException(PackageErrors.StorageUnavailable, "The package could not be published.");
        if (!string.Equals(Path.GetPathRoot(prepared), Path.GetPathRoot(destination), StringComparison.OrdinalIgnoreCase))
        {
            throw new PackageException(PackageErrors.StorageUnavailable, "Staging and library directories must share a filesystem.");
        }
        try
        {
            Directory.Move(prepared, destination);
        }
        catch (Exception error) when (IsFileError(error))
        {
            throw new PackageException(PackageErrors.StorageUnavailable, "The package could not be published.", error);
        }
    }

    /// <summary>
    /// Removes <paramref name="path"/> and everything below it. Links are removed, never followed.
    /// Best effort. Names are passed to Win32 verbatim, so entries it would otherwise rewrite
    /// (a trailing dot or space) are removed too.
    /// </summary>
    public static void DeleteTree(string path)
    {
        if (!Occupied(path)) return;
        try
        {
            Delete(Verbatim(Path.GetFullPath(path)));
        }
        catch (Exception error) when (IsFileError(error))
        {
            // Leftovers stay inside the private staging directory and are retried by later cleanups.
        }
    }

    private static void Delete(string path)
    {
        var attributes = File.GetAttributes(path);
        if (attributes.HasFlag(FileAttributes.ReadOnly)) File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
        if (!attributes.HasFlag(FileAttributes.Directory))
        {
            File.Delete(path);
            return;
        }
        if (!attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(path, "*", EverythingInDirectory))
            {
                try
                {
                    Delete(entry);
                }
                catch (Exception error) when (IsFileError(error))
                {
                    // Keep going; the directory removal below reports what is left.
                }
            }
        }
        // Non-recursive: removes an emptied directory, or a junction or directory link itself.
        Directory.Delete(path, recursive: false);
    }

    /// <summary>The I/O failures of the filesystem, which this layer turns into null or a <see cref="PackageException"/>.</summary>
    public static bool IsFileError(Exception error) =>
        error is IOException or UnauthorizedAccessException or NotSupportedException or System.Security.SecurityException;

    /// <summary>The <c>\\?\</c> form of an absolute path, which Win32 uses without rewriting or a length limit.</summary>
    private static string Verbatim(string fullPath)
    {
        if (fullPath.StartsWith(@"\\?\", StringComparison.Ordinal)) return fullPath;
        return fullPath.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + fullPath[2..] : @"\\?\" + fullPath;
    }

    /// <summary>
    /// Opens <paramref name="path"/> itself: a reparse point is opened rather than followed, so the
    /// caller can inspect and refuse it. Returns null when the path cannot be opened.
    /// </summary>
    private static SafeFileHandle? Open(string path, uint access)
    {
        string full;
        try
        {
            full = Path.GetFullPath(path);
        }
        catch (Exception error) when (IsFileError(error) || error is ArgumentException)
        {
            return null;
        }
        var handle = CreateFile(Verbatim(full), access, FileShare.ReadWrite | FileShare.Delete, 0, FileMode.Open, OpenReparsePoint | BackupSemantics, 0);
        if (!handle.IsInvalid) return handle;
        handle.Dispose();
        return null;
    }

    private const uint GenericRead = 0x80000000;
    private const uint OpenReparsePoint = 0x00200000;
    private const uint BackupSemantics = 0x02000000;

    /// <summary><c>BY_HANDLE_FILE_INFORMATION</c>.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow, CreationTimeHigh;
        public uint LastAccessTimeLow, LastAccessTimeHigh;
        public uint LastWriteTimeLow, LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh, FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh, FileIndexLow;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateFile(string fileName, uint desiredAccess, FileShare shareMode, nint securityAttributes, FileMode creationDisposition, uint flagsAndAttributes, nint templateFile);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
}
