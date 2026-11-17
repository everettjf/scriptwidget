using System.IO.Compression;
using System.Text;
using ScriptWidget.Core.Packages;
using static ScriptWidget.Core.Tests.Packages.ZipFixtures;

namespace ScriptWidget.Core.Tests.Packages;

public sealed class PackageArchiveTests : IDisposable
{
    private const long SymlinkMode = 0xA1FFL << 16;

    private readonly TemporaryFolder temporary = new();
    private readonly string staging;
    private readonly string library;

    public PackageArchiveTests()
    {
        staging = temporary.NewFolder("staging");
        library = temporary.NewFolder("library");
    }

    public void Dispose() => temporary.Dispose();

    private static RawEntry Entry(string name, string text = "x") => new(name, text);

    private static MemoryStream Input(byte[] archive) => new(archive, writable: false);

    private static string Nested(string name, int depth) => string.Join('/', Enumerable.Repeat(name, depth));

    private void AssertRejected(string code, byte[] archive, ArchiveLimits? limits = null)
    {
        AssertCode(code, () => PackageArchive.Preflight(archive, limits));
        var destination = Path.Combine(library, "Target");
        AssertCode(code, () => PackageArchive.ImportTo(Input(archive), staging, destination, limits));
        Assert.False(Directory.Exists(destination));
        Assert.Empty(Tree(staging));
        Assert.Empty(Tree(library));
    }

    // Preflight: paths

    [Fact]
    public void RejectsTraversalPaths()
    {
        foreach (var name in new[] { "../escape.txt", "Widget/../../escape.txt", "Widget/../main.jsx", "..", "Widget/./main.jsx", "./main.jsx" })
        {
            AssertRejected(PackageErrors.ArchiveUnsafePath, RawZip(Entry("Widget/main.jsx"), Entry(name)));
        }
    }

    [Fact]
    public void RejectsAbsoluteBackslashDriveAndControlPaths()
    {
        string[] names =
        [
            "/etc/passwd", "/Widget/main.jsx", "\\Widget\\main.jsx", "Widget\\main.jsx", "Widget/..\\..\\escape.txt", "C:/Widget/main.jsx",
            "C:main.jsx", "Widget/main.jsx:stream", "Widget/ma\0in.jsx", "Widget/line\nbreak.js", "Widget/" + "n".Repeat(256),
        ];
        foreach (var name in names) AssertRejected(PackageErrors.ArchiveUnsafePath, RawZip(Entry("Widget/main.jsx"), Entry(name)));
    }

    [Fact]
    public void RejectsNonUtf8Names()
    {
        byte[] name = [(byte)'W', (byte)'/', 0xC3, 0x28];
        AssertRejected(PackageErrors.ArchiveUnsafePath, RawZip(new RawEntry("ignored", nameBytes: name)));
    }

    [Fact]
    public void RejectsExcessiveNesting()
    {
        var deep = Nested("d", 16);
        Assert.Equal(new[] { deep }, PackageArchive.Preflight(RawZip(Entry(deep))));
        AssertRejected(PackageErrors.ArchiveUnsafePath, RawZip(Entry($"{deep}/main.jsx")));
    }

    [Fact]
    public void RejectsDuplicateAndCaseCollidingPaths()
    {
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx", "one"), Entry("widget/MAIN.jsx", "two")));
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx", "one"), Entry("Widget/main.jsx", "two")));
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx"), Entry("Widget/a.js"), Entry("Widget/A.js")));
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx"), Entry("Widget/src/a.js"), Entry("Widget/SRC/b.js")));
    }

    [Fact]
    public void RejectsUnicodeNormalizationCollisions()
    {
        var composed = "Widget/café.js".Normalize(NormalizationForm.FormC);
        var decomposed = "Widget/café.js".Normalize(NormalizationForm.FormD);
        Assert.False(composed == decomposed);
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx"), Entry(composed), Entry(decomposed)));
    }

    [Fact]
    public void RejectsAPathUsedAsBothFileAndDirectory()
    {
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx"), Entry("Widget/data"), Entry("Widget/data/a.json")));
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx"), Entry("Widget/data/a.json"), Entry("Widget/data")));
    }

    // Preflight: entry kinds

    [Fact]
    public void RejectsSymbolicLinkEntries()
    {
        AssertRejected(PackageErrors.ArchiveSymlink, RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/link.js", "/etc/passwd".Utf8(), SymlinkMode)));
    }

    [Fact]
    public void RejectsSymbolicLinkDirectoryEntries()
    {
        // A link named like a directory, followed by a file that would be written through it.
        AssertRejected(
            PackageErrors.ArchiveSymlink,
            RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/out/", "/tmp".Utf8(), SymlinkMode), Entry("Widget/out/escape.txt")));
        AssertRejected(PackageErrors.ArchivePathCollision, RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/out", "/tmp".Utf8()), Entry("Widget/out/escape.txt")));
    }

    [Fact]
    public void RejectsSpecialFilesEncryptionAndUnknownCompression()
    {
        AssertRejected(PackageErrors.ArchiveSymlink, RawZip(new RawEntry("Widget/fifo", externalAttributes: 0x11A4L << 16)));
        AssertRejected(PackageErrors.ArchiveEncrypted, RawZip(new RawEntry("Widget/main.jsx", "x".Utf8(), flags: 0x0801)));
        AssertRejected(PackageErrors.ArchiveUnsupportedCompression, RawZip(new RawEntry("Widget/main.jsx", "x".Utf8(), method: 12)));
    }

    // Preflight: limits

    [Fact]
    public void RejectsTooManyEntries()
    {
        var entries = Enumerable.Range(0, PackageLimits.MaxFileCount + 1).Select(index => Entry($"Widget/f{index}.js")).ToArray();
        Assert.Equal(501, entries.Length);
        AssertRejected(PackageErrors.ArchiveTooManyEntries, RawZip(entries));
        Assert.Equal(500, PackageArchive.Preflight(RawZip(entries[..500])).Count);
    }

    [Fact]
    public void RejectsOversizedEntryByDeclaredSize()
    {
        var limit = PackageLimits.MaxFileBytes;
        AssertRejected(PackageErrors.ArchiveFileTooLarge, RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/big.bin", "x".Utf8(), declaredSize: limit + 1)));
        PackageArchive.Preflight(RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/big.bin", "x".Utf8(), declaredSize: limit)));
    }

    [Fact]
    public void RejectsOversizedTotalByDeclaredSize()
    {
        var each = 22L * 1024 * 1024;
        var entries = Enumerable.Range(1, 3).Select(index => new RawEntry($"Widget/part{index}.bin", "x".Utf8(), declaredSize: each));
        AssertRejected(PackageErrors.ArchiveExpandedTooLarge, RawZip([Entry("Widget/main.jsx"), .. entries]));
    }

    [Fact]
    public void RejectsOversizedEntryAndTotalWithRealData()
    {
        var limits = new ArchiveLimits { MaximumFileBytes = 1024, MaximumExpandedBytes = 2048 };
        AssertRejected(PackageErrors.ArchiveFileTooLarge, RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/big.bin", new byte[1025])), limits);
        var parts = Enumerable.Range(1, 3).Select(index => new RawEntry($"Widget/part{index}.bin", new byte[1000]));
        AssertRejected(PackageErrors.ArchiveExpandedTooLarge, RawZip([Entry("Widget/main.jsx"), .. parts]), limits);
    }

    [Fact]
    public void RejectsEmptyOversizedAndMalformedArchives()
    {
        AssertRejected(PackageErrors.ArchiveSize, []);
        AssertRejected(PackageErrors.ArchiveSize, PackageZip(), new ArchiveLimits { MaximumArchiveBytes = 64 });
        AssertRejected(PackageErrors.ArchiveMalformed, new byte[10]);
        AssertRejected(PackageErrors.ArchiveMalformed, "this is not a zip archive at all, just text".Utf8());
        AssertRejected(PackageErrors.ArchiveMalformed, [.. PackageZip(), 1, 2, 3]);
        var valid = PackageZip();
        var badOffset = (byte[])valid.Clone();
        badOffset[^(22 - 16)] = 0x7F;
        AssertRejected(PackageErrors.ArchiveMalformed, badOffset);
        var secondDisk = (byte[])valid.Clone();
        secondDisk[^(22 - 4)] = 1;
        AssertRejected(PackageErrors.ArchiveMultiDisk, secondDisk);
        AssertRejected(PackageErrors.ArchiveInvalidRatio, RawZip(new RawEntry("Widget/main.jsx", declaredSize: 2L * 1024 * 1024, declaredCompressedSize: 0)));
    }

    // Extraction

    [Fact]
    public void ZipBombWithLyingSizeHeadersStopsAtTheDeclaredSize()
    {
        var bomb = DeflatedZip(("Widget/main.jsx", "x".Utf8()), ("Widget/bomb.bin", new byte[48 * 1024 * 1024]));
        Assert.True(bomb.Length < 128 * 1024, "the bomb must be small on the wire");
        var forged = ForgeDeclaredSize(bomb, 1, 16);
        Assert.Equal(2, PackageArchive.Preflight(forged).Count);
        var destination = Path.Combine(library, "Bomb");
        AssertLyingSizeRejected(() => PackageArchive.ImportTo(Input(forged), staging, destination));
        Assert.False(Directory.Exists(destination));
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void InflationIsCountedAgainstTheLimitsEvenWhenHeadersAgree()
    {
        // Declared sizes pass a generous preflight, then the real stream is checked against tight limits.
        var archive = DeflatedZip(("Widget/main.jsx", "x".Utf8()), ("Widget/a.bin", new byte[4096]));
        var forged = ForgeDeclaredSize(archive, 1, 100);
        AssertLyingSizeRejected(() => PackageArchive.Extract(Input(forged), staging));
        var inflated = ForgeDeclaredSize(archive, 1, 8192);
        AssertCode(PackageErrors.ArchiveSizeMismatch, () => PackageArchive.Extract(Input(inflated), staging));
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void StoredEntryWithLyingSizeIsRejected()
    {
        var data = new byte[4096];
        Array.Fill(data, (byte)7);
        var archive = RawZip(Entry("Widget/main.jsx"), new RawEntry("Widget/data.bin", data, declaredSize: 16));
        AssertLyingSizeRejected(() => PackageArchive.Extract(Input(archive), staging).Dispose());
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void CorruptedContentFailsTheChecksum()
    {
        var archive = RawZip(Entry("Widget/main.jsx", "render()"));
        archive[30 + "Widget/main.jsx".Length] = (byte)'X';
        AssertCode(PackageErrors.ArchiveCorrupt, () => PackageArchive.Extract(Input(archive), staging));
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void ExtractsOnlyAuthoredFilesOfTheSinglePackageRoot()
    {
        var archive = RawZip(
            Entry("Widget/widget.json", "{}"), Entry("Widget/main.jsx", "main"), Entry("Widget/src/util.js", "util"), new RawEntry("Widget/empty/"),
            Entry("Widget/__Build/main.js", "planted"), Entry("Widget/src/__build/x.js", "planted"), Entry("Widget/src/deep/__BUILD/y.js", "planted"),
            Entry("Widget/.DS_Store", "junk"), Entry("Widget/.git/config", "junk"), Entry("__MACOSX/Widget/._main.jsx", "junk"), Entry("__MACOSX/other.txt", "junk"),
            Entry("README.txt", "stray top-level file"));
        using (var extracted = PackageArchive.Extract(Input(archive), staging))
        {
            Assert.Equal("Widget", extracted.RootName);
            Assert.Equal(new[] { "main.jsx", "src/", "src/util.js", "widget.json" }, Tree(extracted.Directory));
            Assert.Equal("util", File.ReadAllText(Path.Combine(extracted.Directory, "src", "util.js")));
            Assert.StartsWith(staging, extracted.Directory, StringComparison.Ordinal);
        }
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void AcceptsFilesAtTheArchiveRootAndRejectsAmbiguousRoots()
    {
        var flat = RawZip(Entry("main.jsx", "main"), Entry("image/a.png", "png"), Entry("__Build/main.js", "planted"));
        using (var extracted = PackageArchive.Extract(Input(flat), staging))
        {
            Assert.Null(extracted.RootName);
            Assert.Equal(new[] { "image/", "image/a.png", "main.jsx" }, Tree(extracted.Directory));
        }
        AssertRejectedOnExtract(PackageErrors.ArchiveNoPackage, RawZip(Entry("One/main.jsx"), Entry("Two/main.jsx")));
        AssertRejectedOnExtract(PackageErrors.ArchiveNoPackage, RawZip(Entry("readme.txt")));
        AssertRejectedOnExtract(PackageErrors.ArchiveNoPackage, RawZip(Entry("__Build/main.jsx"), Entry(".hidden/main.jsx")));
        AssertRejectedOnExtract(PackageErrors.ArchiveNoPackage, RawZip(new RawEntry("Widget/")));
    }

    private void AssertRejectedOnExtract(string code, byte[] archive)
    {
        AssertCode(code, () => PackageArchive.Extract(Input(archive), staging));
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void ImportMovesIntoPlaceAndNeverReplacesAnExistingDirectory()
    {
        var destination = Path.Combine(library, "Installed");
        Assert.Equal("Widget", PackageArchive.ImportTo(Input(PackageZip()), staging, destination));
        Assert.Equal(new[] { "main.jsx", "widget.json" }, Tree(destination));
        Assert.Empty(Tree(staging));
        File.WriteAllText(Path.Combine(destination, "main.jsx"), "mine");
        AssertCode(PackageErrors.PackageExists, () => PackageArchive.ImportTo(Input(PackageZip()), staging, destination));
        Assert.Equal("mine", File.ReadAllText(Path.Combine(destination, "main.jsx")));
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void ImportsDeflatedArchives()
    {
        var archive = DeflatedZip(("Widget/main.jsx", "a".Repeat(100_000).Utf8()), ("Widget/widget.json", "{}".Utf8()));
        using var extracted = PackageArchive.Extract(Input(archive), staging);
        Assert.Equal("a".Repeat(100_000), File.ReadAllText(Path.Combine(extracted.Directory, "main.jsx")));
    }

    // Export

    private string SamplePackage()
    {
        var root = temporary.NewFolder("source", "My Widget");
        File.WriteAllText(Path.Combine(root, "widget.json"), Manifest("My Widget"));
        File.WriteAllText(Path.Combine(root, "main.jsx"), "$render(<text>阅读</text>);");
        Directory.CreateDirectory(Path.Combine(root, "src"));
        File.WriteAllText(Path.Combine(root, "src", "b.js"), "b");
        File.WriteAllText(Path.Combine(root, "src", "a.js"), "a");
        Directory.CreateDirectory(Path.Combine(root, "image"));
        File.WriteAllBytes(Path.Combine(root, "image", "logo.png"), Enumerable.Range(0, 2048).Select(index => (byte)(index * 31)).ToArray());
        Directory.CreateDirectory(Path.Combine(root, "__Build"));
        File.WriteAllText(Path.Combine(root, "__Build", "main.js"), "compiled");
        Directory.CreateDirectory(Path.Combine(root, "src", "__Build"));
        File.WriteAllText(Path.Combine(root, "src", "__Build", "a.js"), "compiled");
        File.WriteAllText(Path.Combine(root, ".DS_Store"), "junk");
        Directory.CreateDirectory(Path.Combine(root, ".git"));
        File.WriteAllText(Path.Combine(root, ".git", "config"), "junk");
        var secret = temporary.NewFile("secret.txt", "secret");
        Links.Create(Path.Combine(root, "link.txt"), secret);
        Links.Create(Path.Combine(root, "linkdir"), Path.GetDirectoryName(secret)!);
        return root;
    }

    private static byte[] Export(string root, string? name = null)
    {
        using var output = new MemoryStream();
        PackageArchive.Export(root, name ?? Path.GetFileName(root), output);
        return output.ToArray();
    }

    private static List<string> EntryNames(byte[] archive)
    {
        using var zip = new ZipArchive(Input(archive), ZipArchiveMode.Read, leaveOpen: false, Encoding.UTF8);
        return zip.Entries.Select(entry => entry.FullName).ToList();
    }

    [Fact]
    public void ExportSkipsCachesDotFilesAndLinksAndSortsEntries()
    {
        var archive = Export(SamplePackage());
        string[] expected = ["My Widget/image/logo.png", "My Widget/main.jsx", "My Widget/src/a.js", "My Widget/src/b.js", "My Widget/widget.json"];
        Assert.Equal(expected, EntryNames(archive));
        Assert.Equal(expected, PackageArchive.Preflight(archive));
    }

    [Fact]
    public void ExportIsDeterministic()
    {
        var root = SamplePackage();
        var first = Export(root);
        File.SetLastWriteTimeUtc(Path.Combine(root, "main.jsx"), DateTimeOffset.FromUnixTimeMilliseconds(1_000_000_000_000L).UtcDateTime);
        Thread.Sleep(5);
        Assert.Equal(first, Export(root));
    }

    [Fact]
    public void ExportThenImportRoundTripsEveryFile()
    {
        var root = SamplePackage();
        var destination = Path.Combine(library, "Copy");
        Assert.Equal("My Widget", PackageArchive.ImportTo(Input(Export(root)), staging, destination));
        var original = new DiskPackageFiles(root);
        var copy = new DiskPackageFiles(destination);
        Assert.Equal(original.Paths(), copy.Paths());
        Assert.Equal(5, copy.Paths().Count);
        foreach (var path in original.Paths()) Assert.Equal(original.ReadBytes(path), copy.ReadBytes(path));
        Assert.Empty(Tree(staging));
    }

    [Fact]
    public void ExportAppliesLimitsAndSanitizesTheRootName()
    {
        var root = SamplePackage();
        Assert.Equal("Ratio 16-9/image/logo.png", EntryNames(Export(root, "Ratio 16:9"))[0]);
        using var output = new MemoryStream();
        AssertCode(PackageErrors.FileTooLarge, () => PackageArchive.Export(root, "W", output, limits: new ArchiveLimits { MaximumFileBytes = 1024 }));
        AssertCode(PackageErrors.PackageTooLarge, () => PackageArchive.Export(root, "W", output, limits: new ArchiveLimits { MaximumExpandedBytes = 2048 }));
        AssertCode(PackageErrors.TooManyEntries, () => PackageArchive.Export(root, "W", output, limits: new ArchiveLimits { MaximumFileCount = 4 }));
        AssertCode(PackageErrors.ArchiveSize, () => PackageArchive.Export(root, "W", output, limits: new ArchiveLimits { MaximumArchiveBytes = 512 }));
        AssertCode(PackageErrors.ArchiveNoPackage, () => PackageArchive.Export(temporary.NewFolder("empty"), "W", output));
        // The Kotlin test adds a file named "a:b.txt", which lists on disk but cannot be an archive
        // entry. Windows cannot store that name, so the file that lists but cannot be exported is
        // one nested 16 deep: under the archive's root directory it would be 17 components.
        var deep = Path.Combine([root, .. Enumerable.Repeat("d", 15)]);
        Directory.CreateDirectory(deep);
        File.WriteAllText(Path.Combine(deep, "deep.txt"), "deep");
        Assert.Contains(Nested("d", 15) + "/deep.txt", new DiskPackageFiles(root).Paths());
        AssertCode(PackageErrors.InvalidPath, () => PackageArchive.Export(root, "W", output));
        Assert.Equal(0, output.Length);
    }
}
