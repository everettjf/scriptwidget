using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using ScriptWidget.Core.Packages;

namespace ScriptWidget.Core.Tests.Packages;

/// <summary>One hand-written ZIP entry; every header field an attacker controls can be forged.</summary>
public sealed class RawEntry(
    string name,
    byte[]? data = null,
    long externalAttributes = 0x81A4L << 16,
    long? declaredSize = null,
    long? declaredCompressedSize = null,
    int flags = 0x0800,
    int method = 0,
    byte[]? nameBytes = null)
{
    public RawEntry(string name, string text) : this(name, Encoding.UTF8.GetBytes(text)) { }

    public string Name { get; } = name;
    public byte[] Data { get; } = data ?? [];
    public long ExternalAttributes { get; } = externalAttributes;
    public long? DeclaredSize { get; } = declaredSize;
    public long? DeclaredCompressedSize { get; } = declaredCompressedSize;
    public int Flags { get; } = flags;
    public int Method { get; } = method;
    public byte[]? NameBytes { get; } = nameBytes;
}

public static class ZipFixtures
{
    /// <summary>Stored-entry ZIP written byte by byte, like <c>makeStoredZIP</c> in the Swift tests.</summary>
    public static byte[] RawZip(params RawEntry[] entries)
    {
        using var locals = new MemoryStream();
        using var central = new MemoryStream();
        foreach (var entry in entries)
        {
            var name = entry.NameBytes ?? Encoding.UTF8.GetBytes(entry.Name);
            var crc = (uint)Crc32.Of(entry.Data);
            var size = (uint)(entry.DeclaredSize ?? entry.Data.Length);
            var compressed = (uint)(entry.DeclaredCompressedSize ?? entry.Data.Length);
            var offset = (uint)locals.Length;
            var local = new byte[30];
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(0), 0x04034B50);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(4), 20);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(6), (ushort)entry.Flags);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(8), (ushort)entry.Method);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(10), 0);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(12), 0x21);
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(14), crc);
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(18), compressed);
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(22), size);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(26), (ushort)name.Length);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(28), 0);
            locals.Write(local);
            locals.Write(name);
            locals.Write(entry.Data);
            var header = new byte[46];
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0), 0x02014B50);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(4), 0x031E);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(6), 20);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(8), (ushort)entry.Flags);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(10), (ushort)entry.Method);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(12), 0);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(14), 0x21);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(16), crc);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(20), compressed);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(24), size);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(28), (ushort)name.Length);
            // Extra length, comment length, disk number and internal attributes stay zero.
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(38), (uint)entry.ExternalAttributes);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(42), offset);
            central.Write(header);
            central.Write(name);
        }
        var end = new byte[22];
        BinaryPrimitives.WriteUInt32LittleEndian(end.AsSpan(0), 0x06054B50);
        BinaryPrimitives.WriteUInt16LittleEndian(end.AsSpan(8), (ushort)entries.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(end.AsSpan(10), (ushort)entries.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(end.AsSpan(12), (uint)central.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(end.AsSpan(16), (uint)locals.Length);
        return [.. locals.ToArray(), .. central.ToArray(), .. end];
    }

    /// <summary>Deflated ZIP produced by the platform writer.</summary>
    public static byte[] DeflatedZip(params (string Name, byte[] Data)[] files)
    {
        using var output = new MemoryStream();
        using (var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true, Encoding.UTF8))
        {
            foreach (var (name, data) in files)
            {
                using var stream = zip.CreateEntry(name, CompressionLevel.Optimal).Open();
                stream.Write(data);
            }
        }
        return output.ToArray();
    }

    /// <summary>Overwrites the uncompressed size the central directory declares for entry <paramref name="index"/>.</summary>
    public static byte[] ForgeDeclaredSize(byte[] archive, int index, int size)
    {
        var bytes = (byte[])archive.Clone();
        var cursor = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(bytes.Length - 22 + 16));
        for (var step = 0; step < index; step++)
        {
            cursor += 46 + BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(cursor + 28)) + BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(cursor + 30)) +
                BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(cursor + 32));
        }
        Assert.Equal(0x02014B50, BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(cursor)));
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(cursor + 24), size);
        return bytes;
    }

    public static byte[] PackageZip(string root = "Widget", string? name = null, IReadOnlyDictionary<string, string>? extra = null)
    {
        var entries = new List<RawEntry> { new($"{root}/widget.json", Manifest(name ?? root)), new($"{root}/main.jsx", "$render(<text>hi</text>);") };
        foreach (var (path, text) in extra ?? new Dictionary<string, string>()) entries.Add(new RawEntry($"{root}/{path}", text));
        return RawZip([.. entries]);
    }

    public static string Manifest(string name, string id = "com.example.widget") =>
        $$"""{"formatVersion":2,"id":"{{id}}","name":"{{name}}","version":"1.2.3","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[]}""";

    public static void AssertCode(string code, Action block)
    {
        var error = Assert.Throws<PackageException>(block);
        Assert.True(code == error.Code, $"Expected {code} but got {error.Code}: {error.Message}");
    }

    /// <summary>
    /// A deflated entry whose real content is longer than the size the central directory declares.
    /// The Kotlin reader inflates past the declared size and reports <c>archive_size_mismatch</c>;
    /// <c>ZipArchive</c> itself stops inflating at the declared size, so here the truncated content
    /// fails its CRC-32 instead and the import reports <c>archive_corrupt</c>. Either way nothing
    /// beyond the declared size is produced and nothing is installed.
    /// </summary>
    public static void AssertLyingSizeRejected(Action block)
    {
        var error = Assert.Throws<PackageException>(block);
        Assert.Contains(error.Code, new[] { PackageErrors.ArchiveSizeMismatch, PackageErrors.ArchiveCorrupt });
    }

    /// <summary>
    /// Relative paths of everything below <paramref name="root"/>, directories included, for
    /// "nothing left behind" checks. Links are listed and never followed.
    /// </summary>
    public static List<string> Tree(string root)
    {
        var result = new List<string>();
        // The \\?\ form lists names Win32 would otherwise rewrite, such as one with a trailing dot.
        Walk(@"\\?\" + Path.GetFullPath(root), "", result);
        result.Sort(StringComparer.Ordinal);
        return result;
    }

    private static void Walk(string directory, string prefix, List<string> result)
    {
        foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0 }))
        {
            var isDirectory = entry.Attributes.HasFlag(FileAttributes.Directory);
            result.Add(prefix + entry.Name + (isDirectory ? "/" : ""));
            if (isDirectory && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) Walk(entry.FullName, prefix + entry.Name + "/", result);
        }
    }

    public static string Repeat(this string text, int count) => string.Concat(Enumerable.Repeat(text, count));

    public static byte[] Utf8(this string text) => Encoding.UTF8.GetBytes(text);

    public static string Text(this byte[] bytes) => Encoding.UTF8.GetString(bytes);
}

/// <summary>
/// A unique directory under the system temporary directory that is removed when the test ends,
/// links and names Win32 would rewrite included. The counterpart of JUnit's <c>TemporaryFolder</c>.
/// </summary>
public sealed class TemporaryFolder : IDisposable
{
    public string Root { get; } = Path.Combine(Path.GetFullPath(Path.GetTempPath()), "scriptwidget-tests", "pkg-" + Guid.NewGuid().ToString("N"));

    public TemporaryFolder() => Directory.CreateDirectory(Root);

    public string NewFolder(params string[] parts)
    {
        var path = Path.Combine([Root, .. parts]);
        Directory.CreateDirectory(path);
        return path;
    }

    public string NewFile(string name, string text = "")
    {
        var path = Path.Combine(Root, name);
        File.WriteAllText(path, text);
        return path;
    }

    public void Dispose() => SafeFiles.DeleteTree(Root);
}

/// <summary>Links for tests. Windows needs a privilege for symbolic links, so a junction stands in when it is missing.</summary>
public static partial class Links
{
    /// <summary>
    /// Makes <paramref name="link"/> a link to <paramref name="target"/>: a symbolic link when the
    /// process may create one, otherwise a junction. A junction is a reparse point like a symbolic
    /// link and can be created without privilege, also for a file or missing target, so every
    /// link test runs on every machine.
    /// </summary>
    public static void Create(string link, string target)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        try
        {
            if (Directory.Exists(target)) Directory.CreateSymbolicLink(link, target); else File.CreateSymbolicLink(link, target);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Junction(link, target);
        }
        Assert.True(File.GetAttributes(link).HasFlag(FileAttributes.ReparsePoint), $"{link} is not a link");
    }

    /// <summary>Makes <paramref name="link"/> a directory junction to <paramref name="target"/>.</summary>
    public static void Junction(string link, string target)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        var start = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "/d", "/c", "mklink", "/J", link, target }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, $"mklink /J failed: {output}");
    }

    public static void HardLink(string link, string existing)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        Assert.True(CreateHardLink(link, existing, 0), $"CreateHardLink failed: {Marshal.GetLastPInvokeError()}");
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateHardLinkW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CreateHardLink(string fileName, string existingFileName, nint securityAttributes);
}
