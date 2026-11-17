using System.Text.RegularExpressions;
using ScriptWidget.Core.Packages;
using static ScriptWidget.Core.Tests.Packages.ZipFixtures;

namespace ScriptWidget.Core.Tests.Packages;

public sealed class PackageStoreTests : IDisposable
{
    private const string Source = "$render(<text>Hello</text>);";

    private readonly TemporaryFolder temporary = new();
    private readonly string library;
    private readonly string staging;
    private readonly PackageStore store;

    public PackageStoreTests()
    {
        library = Path.Combine(temporary.Root, "library");
        staging = Path.Combine(temporary.Root, "staging");
        store = new PackageStore(library, staging);
    }

    public void Dispose() => temporary.Dispose();

    private List<string> Names() => store.List().Select(package => package.Name).ToList();
    private List<string> StagingTree() => Directory.Exists(staging) ? Tree(staging) : [];
    private PackageInfo Import(byte[] archive, string? suggested = null) => store.ImportArchive(new MemoryStream(archive, writable: false), suggested);

    private byte[] Export(string name)
    {
        using var output = new MemoryStream();
        store.ExportArchive(name, output);
        return output.ToArray();
    }

    private string InLibrary(string path) => Path.Combine(library, path.Replace('/', Path.DirectorySeparatorChar));

    private void WriteInLibrary(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(InLibrary(path))!);
        File.WriteAllText(InLibrary(path), text);
    }

    // create / list

    [Fact]
    public void CreateWritesSourceAndDefaultManifestAtomically()
    {
        var created = store.Create("My Widget", Source);
        Assert.Equal("My Widget", created.Name);
        Assert.Equal(Path.Combine(library, "My Widget"), created.Directory);
        Assert.True(created.HasManifest);
        Assert.Equal("My Widget", created.ManifestName);
        Assert.Equal("1.0.0", created.ManifestVersion);
        Assert.Matches(new Regex(@"^local\.[0-9a-f-]{36}$"), created.ManifestId!);
        Assert.Equal(Source, File.ReadAllText(Path.Combine(created.Directory, "main.jsx")));
        var manifestText = File.ReadAllText(Path.Combine(created.Directory, "widget.json"));
        Assert.DoesNotContain("\r", manifestText);
        var manifest = Json.ParseObject(manifestText);
        Assert.Equal(2, manifest.OptInt("formatVersion"));
        Assert.Equal("1.0", manifest.OptString("runtimeVersion"));
        Assert.Equal("main.jsx", manifest.OptString("entry"));
        Assert.Empty(manifest.OptArray("permissions")!);
        Assert.Equal(new[] { "main.jsx", "widget.json" }, Tree(created.Directory));
        Assert.Equal(new[] { created }, store.List());
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void CreateHonorsASuppliedManifestAndItsEntry()
    {
        var manifest = Manifest("Custom").Replace("\"main.jsx\"", "\"src/app.jsx\"");
        var created = store.Create("Custom", Source, manifest);
        Assert.Equal("com.example.widget", created.ManifestId);
        Assert.Equal("1.2.3", created.ManifestVersion);
        Assert.Equal(manifest, File.ReadAllText(Path.Combine(created.Directory, "widget.json")));
        Assert.Equal(Source, File.ReadAllText(Path.Combine(created.Directory, "src", "app.jsx")));
    }

    [Fact]
    public void CreateFailsClosedAndLeavesNothingBehind()
    {
        store.Create("Widget", Source);
        AssertCode(PackageErrors.PackageExists, () => store.Create("Widget", "other"));
        AssertCode(PackageErrors.PackageExists, () => store.Create("WIDGET", "other"));
        foreach (var name in new[] { "", " ", "..", "../escape", "a/b", "a\\b", ".hidden", "__Build", "C:x", "a".Repeat(81) })
        {
            AssertCode(PackageErrors.InvalidName, () => store.Create(name, Source));
        }
        AssertCode(PackageErrors.InvalidManifest, () => store.Create("Bad", Source, "{not json"));
        AssertCode(PackageErrors.InvalidManifest, () => store.Create("Bad", Source, "[]"));
        AssertCode(PackageErrors.InvalidManifest, () => store.Create("Bad", Source, "{\"name\":\"Bad\"}"));
        foreach (var entry in new[] { "../main.jsx", "/main.jsx", "a\\\\b.jsx", "main.txt", "widget.json", ".hidden.js", "__Build/main.js" })
        {
            AssertCode(PackageErrors.InvalidEntry, () => store.Create("Bad", Source, $"{{\"entry\":\"{entry}\"}}"));
        }
        AssertCode(PackageErrors.FileTooLarge, () => store.Create("Big", "a".Repeat(PackageLimits.MaxScriptBytes + 1)));
        AssertCode(PackageErrors.FileTooLarge, () => store.Create("Big", Source, $"{{\"entry\":\"main.jsx\",\"description\":\"{"d".Repeat(PackageLimits.MaxMetadataBytes)}\"}}"));
        Assert.Contains("Hello", File.ReadAllText(InLibrary("Widget/main.jsx")));
        Assert.Equal(new[] { "Widget" }, Names());
        Assert.Equal(new[] { "Widget/", "Widget/main.jsx", "Widget/widget.json" }, Tree(library));
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void ListReportsOnlyRealPackageDirectories()
    {
        store.Create("Beta", Source);
        store.Create("Alpha", Source);
        WriteInLibrary("Legacy/main.jsx", Source);
        WriteInLibrary("Broken/widget.json", "{not json");
        WriteInLibrary("Typed/widget.json", "{\"id\":7,\"name\":[\"x\"],\"version\":\"2.0.0\"}");
        WriteInLibrary("WrongCase/Widget.JSON", Manifest("WrongCase"));
        Directory.CreateDirectory(InLibrary(".hidden"));
        Directory.CreateDirectory(InLibrary("__Build"));
        WriteInLibrary("stray.txt", "file");
        Links.Create(InLibrary("Linked"), InLibrary("Alpha"));

        var listed = store.List().ToDictionary(package => package.Name);
        Assert.Equal(new[] { "Alpha", "Beta", "Broken", "Legacy", "Typed", "WrongCase" }, Names());
        Assert.False(listed["Legacy"].HasManifest);
        Assert.Null(listed["Legacy"].ManifestName);
        Assert.True(listed["Broken"].HasManifest);
        Assert.Null(listed["Broken"].ManifestId);
        Assert.Null(listed["Typed"].ManifestId);
        Assert.Null(listed["Typed"].ManifestName);
        Assert.Equal("2.0.0", listed["Typed"].ManifestVersion);
        Assert.True(listed["WrongCase"].HasManifest);
        Assert.Null(listed["WrongCase"].ManifestName);
        AssertCode(PackageErrors.PackageNotFound, () => store.Files("Linked"));
        AssertCode(PackageErrors.PackageNotFound, () => store.ReadFile("Linked", "main.jsx"));
        AssertCode(PackageErrors.PackageNotFound, () => store.Delete("Linked"));
        AssertCode(PackageErrors.PackageNotFound, () => store.Files("ALPHA"));
    }

    [Fact]
    public void LibraryRootMustNotBeALink()
    {
        var real = temporary.NewFolder("real");
        var alias = Path.Combine(temporary.Root, "alias");
        Links.Create(alias, real);
        var linked = new PackageStore(alias, staging);
        AssertCode(PackageErrors.StorageUnavailable, () => linked.List());
        AssertCode(PackageErrors.StorageUnavailable, () => linked.Create("Widget", Source));
        Assert.Empty(Tree(real));
    }

    // import

    [Fact]
    public void ImportInstallsUnderTheManifestNameNotTheArchiveName()
    {
        var installed = Import(PackageZip(root: "ArchiveFolder", name: "Manifest Name", extra: new Dictionary<string, string> { ["src/a.js"] = "a" }), "FileName");
        Assert.Equal("Manifest Name", installed.Name);
        Assert.Equal("Manifest Name", installed.ManifestName);
        Assert.Equal("com.example.widget", installed.ManifestId);
        Assert.Equal("1.2.3", installed.ManifestVersion);
        Assert.Equal(new[] { "main.jsx", "src/a.js", "widget.json" }, store.Files("Manifest Name").Paths());
        Assert.Equal(new[] { "Manifest Name" }, Names());
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void ImportPicksAUniqueNameOnCollision()
    {
        Assert.Equal("Widget", Import(PackageZip()).Name);
        Assert.Equal("Widget (1)", Import(PackageZip()).Name);
        Assert.Equal("Widget (2)", Import(PackageZip()).Name);
        Assert.Equal("WIDGET (3)", Import(PackageZip(name: "WIDGET")).Name);
        Assert.Equal("Widget", Json.ParseObject(store.ReadFile("Widget (1)", "widget.json").Text()).OptString("name"));
        Assert.Equal(new[] { "WIDGET (3)", "Widget", "Widget (1)", "Widget (2)" }, Names());
    }

    [Fact]
    public void UniqueNameShortensTheStemAndSkipsCaseAndNormalizationAliases()
    {
        Assert.Equal("Fresh", store.UniqueName("Fresh"));
        var longName = "a".Repeat(80);
        store.Create(longName, Source);
        Assert.Equal("a".Repeat(76) + " (1)", store.UniqueName(longName));
        store.Create("Café", Source);
        Assert.Equal("Café (1)", store.UniqueName("Café"));
        Assert.Equal("CAFÉ (1)", store.UniqueName("CAFÉ"));
        Assert.Equal("Café (1)", store.UniqueName("Café"));
        store.Create("Café (1)", Source);
        Assert.Equal("Café (2)", store.UniqueName("Café"));
        AssertCode(PackageErrors.InvalidName, () => store.UniqueName("../x"));
    }

    [Fact]
    public void ImportMigratesLegacyPackages()
    {
        var meta = "{\"description\":\"Old\",\"category\":\"Tools\",\"tags\":[\"a\",\"b\"],\"featured\":true,\"icon\":5}";
        var nested = Import(RawZip(new RawEntry("Old Widget/main.jsx", Source), new RawEntry("Old Widget/meta.json", meta)), "ignored");
        Assert.Equal("Old Widget", nested.Name);
        Assert.True(nested.HasManifest);
        Assert.Equal("legacy.old-widget", nested.ManifestId);
        var manifest = Json.ParseObject(store.ReadFile("Old Widget", "widget.json").Text());
        Assert.Equal("Old", manifest.OptString("description"));
        Assert.Equal("Tools", manifest.OptString("category"));
        Assert.Equal(2, manifest.OptArray("tags")!.Count);
        Assert.False(manifest.Has("featured"));
        Assert.False(manifest.Has("icon"));
        Assert.Equal("main.jsx", manifest.OptString("entry"));

        Assert.Equal("Shared File", Import(RawZip(new RawEntry("main.jsx", Source), new RawEntry("meta.json", "{broken")), "Shared File").Name);
        Assert.Equal("Imported Widget", Import(RawZip(new RawEntry("main.jsx", Source)), "../bad").Name);
        Assert.Equal("Imported Widget (1)", Import(RawZip(new RawEntry("main.jsx", Source)), null).Name);
    }

    [Fact]
    public void RejectedImportsLeaveNothingInLibraryOrStaging()
    {
        store.Create("Existing", Source);
        var before = Tree(library);
        const long link = 0xA1FFL << 16;
        // The bomb is listed with both codes: see ZipFixtures.AssertLyingSizeRejected.
        var rejected = new (string Label, string[] Codes, byte[] Archive)[]
        {
            ("traversal", [PackageErrors.ArchiveUnsafePath], RawZip(new RawEntry("W/main.jsx", Source), new RawEntry("../Existing/main.jsx", "owned"))),
            ("absolute", [PackageErrors.ArchiveUnsafePath], RawZip(new RawEntry("/W/main.jsx", Source))),
            ("backslash", [PackageErrors.ArchiveUnsafePath], RawZip(new RawEntry("W\\main.jsx", Source))),
            ("symlink", [PackageErrors.ArchiveSymlink], RawZip(new RawEntry("W/main.jsx", Source), new RawEntry("W/link", "../Existing".Utf8(), link))),
            ("collision", [PackageErrors.ArchivePathCollision], RawZip(new RawEntry("W/main.jsx", Source), new RawEntry("W/MAIN.jsx", Source))),
            ("entries", [PackageErrors.ArchiveTooManyEntries], RawZip(Enumerable.Range(0, 501).Select(index => new RawEntry($"W/f{index}.js", "x")).ToArray())),
            ("file size", [PackageErrors.ArchiveFileTooLarge], RawZip(new RawEntry("W/main.jsx", Source.Utf8(), declaredSize: PackageLimits.MaxFileBytes + 1))),
            ("bomb", [PackageErrors.ArchiveSizeMismatch, PackageErrors.ArchiveCorrupt], ForgeDeclaredSize(DeflatedZip(("W/main.jsx", Source.Utf8()), ("W/bomb.bin", new byte[8 * 1024 * 1024])), 1, 8)),
            ("no package", [PackageErrors.ArchiveNoPackage], RawZip(new RawEntry("A/main.jsx", Source), new RawEntry("B/main.jsx", Source))),
            ("wrong-case manifest", [PackageErrors.InvalidManifestCase], RawZip(new RawEntry("W/Widget.json", Manifest("W")), new RawEntry("W/main.jsx", Source))),
            ("malformed manifest", [PackageErrors.InvalidManifest], RawZip(new RawEntry("W/widget.json", "{bad"), new RawEntry("W/main.jsx", Source))),
            ("non-object manifest", [PackageErrors.InvalidManifest], RawZip(new RawEntry("W/widget.json", "[1]"), new RawEntry("W/main.jsx", Source))),
            ("non-UTF-8 manifest", [PackageErrors.InvalidManifest], RawZip(new RawEntry("W/widget.json", new byte[] { 0x7B, 0xC3, 0x28, 0x7D }), new RawEntry("W/main.jsx", Source))),
            ("nameless manifest", [PackageErrors.InvalidManifest], RawZip(new RawEntry("W/widget.json", "{\"name\":5}"), new RawEntry("W/main.jsx", Source))),
            ("unsafe manifest name", [PackageErrors.InvalidName], PackageZip(name: "../Existing")),
            ("reserved manifest name", [PackageErrors.InvalidName], PackageZip(name: "__Build")),
            ("legacy without entry", [PackageErrors.MissingEntry], RawZip(new RawEntry("W/other.jsx", Source))),
            ("unsafe legacy name", [PackageErrors.InvalidName], RawZip(new RawEntry($"{"n".Repeat(81)}/main.jsx", Source))),
        };
        foreach (var (label, codes, archive) in rejected)
        {
            var error = Assert.Throws<PackageException>(() => Import(archive, "Suggested"));
            Assert.True(codes.Contains(error.Code), $"{label}: {error.Code} {error.Message}");
            Assert.Equal(before, Tree(library));
            Assert.Empty(StagingTree());
        }
    }

    [Fact]
    public void ValidationHookRunsBeforePublicationAndCanVeto()
    {
        IReadOnlyList<string>? seen = null;
        AssertCode("unsupported_runtime", () => store.ImportArchive(new MemoryStream(PackageZip()), null, files =>
        {
            seen = files.Paths();
            Assert.Contains("\"runtimeVersion\"", files.ReadText("widget.json")!);
            throw new PackageException("unsupported_runtime", "Runtime 9.0 is incompatible with 1.0.");
        }));
        Assert.Equal(new[] { "main.jsx", "widget.json" }, seen);
        Assert.Empty(Names());
        Assert.Empty(Tree(library));
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void ImportNeverInstallsBuildCachesOrHiddenFiles()
    {
        var archive = RawZip(
            new RawEntry("W/widget.json", Manifest("Clean")), new RawEntry("W/main.jsx", Source), new RawEntry("W/__Build/main.js", "planted"),
            new RawEntry("W/src/__Build/deep.js", "planted"), new RawEntry("W/src/ok.js", "ok"), new RawEntry("W/.env", "SECRET=1"), new RawEntry("__MACOSX/W/._main.jsx", "fork"));
        Assert.Equal("Clean", Import(archive).Name);
        Assert.Equal(new[] { "main.jsx", "src/", "src/ok.js", "widget.json" }, Tree(InLibrary("Clean")));
    }

    // export

    [Fact]
    public void ExportThenImportRoundTripsThePackage()
    {
        store.Create("Round Trip", Source);
        store.WriteFile("Round Trip", "src/lib/util.js", "export default 1;".Utf8());
        store.WriteFile("Round Trip", "image/logo.png", Enumerable.Range(0, 4096).Select(index => (byte)(index * 7)).ToArray());
        WriteInLibrary("Round Trip/__Build/main.js", "compiled");
        WriteInLibrary("Round Trip/.DS_Store", "junk");
        Links.Create(InLibrary("Round Trip/link.js"), InLibrary("Round Trip/main.jsx"));

        var archive = Export("Round Trip");
        Assert.Equal(archive, Export("Round Trip"));
        Assert.Equal(
            new[] { "Round Trip/image/logo.png", "Round Trip/main.jsx", "Round Trip/src/lib/util.js", "Round Trip/widget.json" },
            PackageArchive.Preflight(archive));
        var copy = Import(archive);
        Assert.Equal("Round Trip (1)", copy.Name);
        var original = store.Files("Round Trip");
        var imported = store.Files(copy.Name);
        Assert.Equal(original.Paths(), imported.Paths());
        foreach (var path in original.Paths()) Assert.Equal(original.ReadBytes(path), imported.ReadBytes(path));
        Assert.Equal(store.List().First(package => package.Name == "Round Trip").ManifestId, copy.ManifestId);
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void ExportMigratesLegacyPackagesWithoutTouchingTheLibrary()
    {
        WriteInLibrary("Legacy/main.jsx", Source);
        WriteInLibrary("Legacy/meta.json", "{\"description\":\"Old\"}");
        var archive = Export("Legacy");
        Assert.Equal(new[] { "Legacy/main.jsx", "Legacy/meta.json", "Legacy/widget.json" }, PackageArchive.Preflight(archive));
        Assert.False(File.Exists(InLibrary("Legacy/widget.json")));
        Directory.Delete(InLibrary("Legacy"), recursive: true);
        var imported = Import(archive);
        Assert.Equal("Legacy", imported.Name);
        Assert.Equal("legacy.legacy", imported.ManifestId);
        Assert.Equal("Old", Json.ParseObject(store.ReadFile("Legacy", "widget.json").Text()).OptString("description"));
    }

    [Fact]
    public void ExportRefusesInvalidPackages()
    {
        using var output = new MemoryStream();
        WriteInLibrary("Broken/widget.json", "{bad");
        WriteInLibrary("Broken/main.jsx", Source);
        WriteInLibrary("Cased/WIDGET.json", Manifest("Cased"));
        Directory.CreateDirectory(InLibrary("Empty"));
        AssertCode(PackageErrors.InvalidManifest, () => store.ExportArchive("Broken", output));
        AssertCode(PackageErrors.InvalidManifestCase, () => store.ExportArchive("Cased", output));
        AssertCode(PackageErrors.MissingEntry, () => store.ExportArchive("Empty", output));
        AssertCode(PackageErrors.PackageNotFound, () => store.ExportArchive("Missing", output));
        AssertCode(PackageErrors.InvalidName, () => store.ExportArchive("../Broken", output));
        Assert.Equal(0, output.Length);
    }

    // duplicate / rename / delete

    [Fact]
    public void DuplicateCopiesFilesAndRefreshesIdentity()
    {
        var original = store.Create("Widget", Source);
        store.WriteFile("Widget", "src/a.js", "a".Utf8());
        WriteInLibrary("Widget/__Build/main.js", "compiled");
        WriteInLibrary("Widget/.DS_Store", "junk");

        var copy = store.Duplicate("Widget");
        Assert.Equal("Widget Remix", copy.Name);
        Assert.Equal("Widget Remix", copy.ManifestName);
        Assert.NotEqual(original.ManifestId, copy.ManifestId);
        Assert.StartsWith("local.", copy.ManifestId);
        Assert.Equal(new[] { "main.jsx", "src/", "src/a.js", "widget.json" }, Tree(copy.Directory));
        Assert.Equal(Source, store.ReadFile("Widget Remix", "main.jsx").Text());
        Assert.Equal("Widget", store.List().First(package => package.Name == "Widget").ManifestName);
        Assert.Equal("Widget Remix (1)", store.Duplicate("Widget").Name);
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void DuplicateKeepsLegacyPackagesLegacyAndRejectsUnsafeSources()
    {
        WriteInLibrary("Legacy/main.jsx", Source);
        var copy = store.Duplicate("Legacy");
        Assert.Equal("Legacy Remix", copy.Name);
        Assert.False(copy.HasManifest);
        Assert.Equal(new[] { "main.jsx" }, Tree(copy.Directory));

        var secret = temporary.NewFile("secret.txt");
        Links.Create(InLibrary("Legacy/link.txt"), secret);
        AssertCode(PackageErrors.UnsafeFile, () => store.Duplicate("Legacy"));
        WriteInLibrary("Broken/widget.json", "{bad");
        AssertCode(PackageErrors.InvalidManifest, () => store.Duplicate("Broken"));
        AssertCode(PackageErrors.PackageNotFound, () => store.Duplicate("Missing"));
        Assert.Equal(new[] { "Broken", "Legacy", "Legacy Remix" }, Names());
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void RenameMovesTheDirectoryAndRefusesCollisions()
    {
        store.Create("Widget", Source);
        store.Create("Other", Source);
        var renamed = store.Rename("Widget", "阅读记录");
        Assert.Equal("阅读记录", renamed.Name);
        Assert.Equal("Widget", renamed.ManifestName);
        Assert.Equal(new[] { "Other", "阅读记录" }, Names());
        Assert.Equal("阅读记录", store.Rename("阅读记录", "阅读记录").Name);
        AssertCode(PackageErrors.PackageExists, () => store.Rename("阅读记录", "Other"));
        AssertCode(PackageErrors.PackageExists, () => store.Rename("阅读记录", "OTHER"));
        AssertCode(PackageErrors.PackageExists, () => store.Rename("Other", "other"));
        AssertCode(PackageErrors.InvalidName, () => store.Rename("Other", "../escape"));
        AssertCode(PackageErrors.InvalidName, () => store.Rename("Other", "__Build"));
        AssertCode(PackageErrors.PackageNotFound, () => store.Rename("Widget", "Again"));
        Assert.Equal(new[] { "Other", "阅读记录" }, Names());
    }

    [Fact]
    public void DeleteRemovesThePackageWithoutFollowingLinks()
    {
        store.Create("Widget", Source);
        var keep = temporary.NewFolder("keep");
        File.WriteAllText(Path.Combine(keep, "precious.txt"), "keep me");
        Links.Create(InLibrary("Widget/link"), keep);
        store.Delete("Widget");
        Assert.Empty(Names());
        Assert.False(Directory.Exists(InLibrary("Widget")));
        Assert.Equal("keep me", File.ReadAllText(Path.Combine(keep, "precious.txt")));
        Assert.Empty(StagingTree());
        AssertCode(PackageErrors.PackageNotFound, () => store.Delete("Widget"));
        AssertCode(PackageErrors.InvalidName, () => store.Delete(".."));
    }

    // writeFile / readFile

    [Fact]
    public void WriteFileReplacesContentAtomically()
    {
        store.Create("Widget", Source);
        store.WriteFile("Widget", "main.jsx", "new source".Utf8());
        store.WriteFile("Widget", "src/deep/util.js", "util".Utf8());
        store.WriteFile("Widget", "src/deep/util.js", "util 2".Utf8());
        Assert.Equal("new source", store.ReadFile("Widget", "main.jsx").Text());
        Assert.Equal("util 2", store.ReadFile("Widget", "src/deep/util.js").Text());
        Assert.Equal(new[] { "main.jsx", "src/", "src/deep/", "src/deep/util.js", "widget.json" }, Tree(InLibrary("Widget")));
        // No temporary file may remain.
        Assert.DoesNotContain(Tree(InLibrary("Widget")), path => path.Contains(".write-", StringComparison.Ordinal));
    }

    [Fact]
    public void WriteFileRejectsUnsafePathsAndKeepsOldContent()
    {
        store.Create("Widget", Source);
        Directory.CreateDirectory(InLibrary("Sibling"));
        var before = Tree(library);
        string[] unsafePaths =
        [
            "", "/", "..", "../Sibling/main.jsx", "src/../../Sibling/x.js", "src/../main.jsx", "./main.jsx", "/main.jsx",
            InLibrary("Sibling/x.js"), "src\\x.js", "..\\Sibling\\x.js", "main\0.jsx", "C:x.js", ".hidden", "src/.hidden/x.js",
            "__Build/main.js", "src/__BUILD/main.js", string.Join('/', Enumerable.Repeat("d", 17)), "x".Repeat(256),
        ];
        foreach (var path in unsafePaths) AssertCode(PackageErrors.InvalidPath, () => store.WriteFile("Widget", path, "owned".Utf8()));
        AssertCode(PackageErrors.InvalidManifestCase, () => store.WriteFile("Widget", "Widget.json", "{}".Utf8()));
        AssertCode(PackageErrors.UnsafeFile, () => store.WriteFile("Widget", "MAIN.jsx", "owned".Utf8()));
        AssertCode(PackageErrors.UnsafeFile, () => store.WriteFile("Widget", "main.jsx/child.js", "owned".Utf8()));
        AssertCode(PackageErrors.FileTooLarge, () => store.WriteFile("Widget", "big.bin", new byte[PackageLimits.MaxFileBytes + 1]));
        AssertCode(PackageErrors.FileTooLarge, () => store.WriteFile("Widget", "widget.json", new byte[PackageLimits.MaxMetadataBytes + 1]));
        AssertCode(PackageErrors.PackageNotFound, () => store.WriteFile("Missing", "main.jsx", "x".Utf8()));
        AssertCode(PackageErrors.InvalidName, () => store.WriteFile("../Sibling", "main.jsx", "x".Utf8()));
        Assert.Equal(before, Tree(library));
        Assert.Equal(Source, store.ReadFile("Widget", "main.jsx").Text());
    }

    [Fact]
    public void WriteFileNeverWritesThroughLinks()
    {
        store.Create("Widget", Source);
        var outside = temporary.NewFolder("outside");
        var victim = Path.Combine(outside, "victim.txt");
        File.WriteAllText(victim, "original");
        Links.Create(InLibrary("Widget/link.txt"), victim);
        Links.Create(InLibrary("Widget/linkdir"), outside);
        Links.Create(InLibrary("Widget/dangling.txt"), Path.Combine(outside, "created.txt"));
        Links.HardLink(InLibrary("Widget/hard.txt"), victim);

        foreach (var path in new[] { "link.txt", "linkdir/victim.txt", "linkdir/new.txt", "linkdir/sub/new.txt", "dangling.txt", "hard.txt" })
        {
            AssertCode(PackageErrors.UnsafeFile, () => store.WriteFile("Widget", path, "owned".Utf8()));
        }
        Assert.Equal("original", File.ReadAllText(victim));
        Assert.Equal(new[] { "victim.txt" }, Tree(outside));
        foreach (var path in new[] { "link.txt", "linkdir/victim.txt", "dangling.txt", "hard.txt" })
        {
            AssertCode(PackageErrors.FileNotFound, () => store.ReadFile("Widget", path));
        }
    }

    [Fact]
    public void WriteFileEnforcesTheEntryLimit()
    {
        store.Create("Widget", Source);
        for (var index = 0; index < PackageLimits.MaxFileCount - 2; index++) WriteInLibrary($"Widget/f{index}.txt", "x");
        AssertCode(PackageErrors.TooManyEntries, () => store.WriteFile("Widget", "one-more.txt", "x".Utf8()));
        store.WriteFile("Widget", "f0.txt", "replaced".Utf8());
        Assert.Equal("replaced", store.ReadFile("Widget", "f0.txt").Text());
    }

    [Fact]
    public void ReadFileReportsMissingAndUnsafePaths()
    {
        store.Create("Widget", Source);
        Assert.Equal(Source, store.ReadFile("Widget", "main.jsx").Text());
        AssertCode(PackageErrors.FileNotFound, () => store.ReadFile("Widget", "missing.js"));
        AssertCode(PackageErrors.FileNotFound, () => store.ReadFile("Widget", "MAIN.JSX"));
        AssertCode(PackageErrors.InvalidPath, () => store.ReadFile("Widget", "../Widget/main.jsx"));
        AssertCode(PackageErrors.InvalidPath, () => store.ReadFile("Widget", "/etc/hosts"));
        AssertCode(PackageErrors.InvalidPath, () => store.ReadFile("Widget", "a\\b"));
        AssertCode(PackageErrors.PackageNotFound, () => store.ReadFile("Missing", "main.jsx"));
    }
}
