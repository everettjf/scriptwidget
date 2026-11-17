using System.Text;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;
using static ScriptWidget.Core.Tests.Packages.ZipFixtures;

namespace ScriptWidget.Core.Tests.Packages;

/// <summary>
/// The rules the Windows port adds to the Kotlin package layer: names Win32 resolves to something
/// other than the file they spell, canonical boundary checks, and reparse points.
/// </summary>
public sealed class WindowsPackageSecurityTests : IDisposable
{
    private const string Source = "$render(<text>Hello</text>);";

    private static readonly string[] ReservedNames =
    [
        "CON", "PRN", "AUX", "NUL", "COM0", "COM1", "COM9", "LPT0", "LPT1", "LPT9", "CONIN$", "CONOUT$", "COM\u00B9", "COM\u00B2", "COM\u00B3",
        "LPT\u00B9", "LPT\u00B2", "LPT\u00B3", "con", "Nul", "aUx", "com1", "lpt9", "conin$", "NUL.txt", "con.js", "aux.tar.gz", "COM1.jsx", "lpt\u00B2.json",
        "NUL .txt", "prn.",
    ];

    private static readonly string[] SafeLookalikes =
    [
        "console.js", "CONSOLE", "nullable.js", "auxiliary.txt", "COM", "LPT", "COM10", "LPT10.txt", "COM1x.js", "com.js", "xCON", "CON_", "a.CON", "nul-1.js",
        "printer.prn", "COM\u00B9\u00B2",
    ];

    private static readonly string[] TrailingDotOrSpace = ["main.jsx.", "main.jsx ", "name.", "name ", "a..", "a. ", "a .", "..."];

    private static readonly string[] ReservedCharacters =
    [
        "a<b.js", "a>b.js", "a\"b.js", "a|b.js", "a?b.js", "a*b.js", "a:b.js", "main.jsx:stream", "main.jsx::$DATA", ":x", "x:", "a\u0001b", "a\u001Fb", "a\tb", "a\rb",
    ];

    private static readonly string[] DriveAndUncForms =
    [
        "C:\\x", "C:/x", "c:x", "C:", "\\\\server\\share", "\\\\server\\share\\x.js", "//server/share", "//server/share/x.js", "\\\\?\\C:\\x", "\\\\.\\C:\\x",
        "\\\\?\\UNC\\server\\share\\x", "//?/C:/x", "//./NUL", "\\x", "/x", "Z:/Widget/main.jsx",
    ];

    private readonly TemporaryFolder temporary = new();
    private readonly string library;
    private readonly string staging;
    private readonly PackageStore store;

    public WindowsPackageSecurityTests()
    {
        library = Path.Combine(temporary.Root, "library");
        staging = Path.Combine(temporary.Root, "staging");
        store = new PackageStore(library, staging);
    }

    public void Dispose() => temporary.Dispose();

    private string InLibrary(string path) => Path.Combine(library, path.Replace('/', Path.DirectorySeparatorChar));

    private List<string> StagingTree() => Directory.Exists(staging) ? Tree(staging) : [];

    /// <summary>The path with the <c>\\?\</c> prefix, which makes Win32 keep a trailing dot or space.</summary>
    private static string Verbatim(string path) => @"\\?\" + path;

    private static void AssertUnsafePath(string path)
    {
        Assert.True(PackagePathRules.Components(path) is null, path);
        Assert.True(PackagePathRules.VisibleComponents(path) is null, path);
    }

    /// <summary>The name alone, as a directory, and below a directory.</summary>
    private static IEnumerable<string> InEverySegment(string name) => [name, $"{name}/main.jsx", $"src/{name}", $"src/{name}/deep/x.js"];

    // Path rules

    [Fact]
    public void ReservedDeviceNamesAreRefusedInEverySegment()
    {
        foreach (var name in ReservedNames)
        {
            Assert.False(PackagePathRules.WindowsSafe(name), name);
            Assert.False(PackagePathRules.ValidComponent(name), name);
            foreach (var path in InEverySegment(name)) AssertUnsafePath(path);
        }
        foreach (var name in SafeLookalikes)
        {
            Assert.True(PackagePathRules.WindowsSafe(name), name);
            Assert.Equal(new[] { "src", name }, PackagePathRules.Components($"src/{name}"));
        }
    }

    [Fact]
    public void SegmentsEndingInADotOrSpaceAreRefused()
    {
        foreach (var name in TrailingDotOrSpace)
        {
            Assert.False(PackagePathRules.WindowsSafe(name), name);
            foreach (var path in InEverySegment(name)) AssertUnsafePath(path);
        }
        foreach (var name in new[] { " leading.js", "in ner.js", "a.b.c", "two  spaces.txt" })
        {
            Assert.Equal(new[] { name }, PackagePathRules.Components(name));
        }
    }

    [Fact]
    public void ColonsReservedCharactersAndControlCharactersAreRefused()
    {
        foreach (var name in ReservedCharacters)
        {
            Assert.False(PackagePathRules.WindowsSafe(name), name);
            foreach (var path in InEverySegment(name)) AssertUnsafePath(path);
        }
        for (var code = 0; code < 0x20; code++) Assert.False(PackagePathRules.WindowsSafe($"a{(char)code}b"), $"U+{code:X4}");
        foreach (var name in new[] { "a'b.js", "a&b.js", "a(b).js", "a+b=c.js", "50%.txt", "a,b;c.txt", "a~b.js", "a#b@c!.js", "[a]{b}.js", "a$b^c`d.js" })
        {
            Assert.Equal(new[] { name }, PackagePathRules.Components(name));
        }
    }

    [Fact]
    public void DriveLetterAndUncFormsAreRefused()
    {
        foreach (var path in DriveAndUncForms) AssertUnsafePath(path);
    }

    [Fact]
    public void OverlongSegmentsAndPathsAreRefused()
    {
        Assert.Equal(new[] { "x".Repeat(255) }, PackagePathRules.Components("x".Repeat(255)));
        AssertUnsafePath("x".Repeat(256));
        AssertUnsafePath("src/" + "x".Repeat(256) + "/a.js");
        // 86 three-byte characters are 86 UTF-16 units but 258 UTF-8 bytes; 128 pairs are 256 units.
        AssertUnsafePath("漢".Repeat(86));
        Assert.False(PackagePathRules.WindowsSafe("😀".Repeat(128)));
        var segment = "s".Repeat(200);
        var fits = string.Join('/', Enumerable.Repeat(segment, 5));
        Assert.Equal(1004, fits.Length);
        Assert.Equal(5, PackagePathRules.Components(fits)!.Count);
        AssertUnsafePath(fits + "/" + "t".Repeat(20));
        Assert.Null(ArchivePreflight.EntryParts(fits + "/" + "t".Repeat(20), PackageLimits.MaxPathDepth));
        Assert.Equal(PackageLimits.MaxRelativePathUnits, (fits + "/" + "t".Repeat(19)).Length);
        Assert.NotNull(PackagePathRules.Components(fits + "/" + "t".Repeat(19)));
    }

    // Package names

    [Fact]
    public void PackageNamesMustBeDirectoryNamesWindowsStoresVerbatim()
    {
        string[] invalid = [.. ReservedNames, .. TrailingDotOrSpace, .. ReservedCharacters, "Ratio 16:9", "What?", "Stars***", "a<b>c", "say \"hi\"", "pipe|line", "Widget.", "Widget "];
        foreach (var name in invalid)
        {
            Assert.False(PackageNames.IsValid(name), name);
            AssertCode(PackageErrors.InvalidName, () => store.Create(name, Source));
            AssertCode(PackageErrors.InvalidName, () => store.UniqueName(name));
        }
        store.Create("Widget", Source);
        foreach (var name in new[] { "NUL", "Widget.", "Ratio 16:9", "con.txt" }) AssertCode(PackageErrors.InvalidName, () => store.Rename("Widget", name));
        Assert.Equal(new[] { "Widget/", "Widget/main.jsx", "Widget/widget.json" }, Tree(library));
        Assert.Empty(StagingTree());
        foreach (var name in SafeLookalikes) Assert.True(PackageNames.IsValid(name), name);
    }

    [Fact]
    public void ImportRefusesManifestAndLegacyNamesWindowsCannotStore()
    {
        // Device names cannot be made safe by replacing characters.
        foreach (var name in new[] { "CON", "nul.txt", "COM\u00B9" })
        {
            var error = Assert.Throws<PackageException>(() => store.ImportArchive(new MemoryStream(PackageZip(root: "W", name: name)), null));
            Assert.True(error.Code == PackageErrors.InvalidName, $"{name}: {error.Code}");
            Assert.False(Directory.Exists(library) && Tree(library).Count > 0, name);
            Assert.Empty(StagingTree());
        }
        // A name another platform allows is stored under a directory name Windows accepts; the manifest keeps its name.
        foreach (var (name, directory) in new[] { ("Ratio 16:9", "Ratio 16-9"), ("Notes?", "Notes-"), ("a*b", "a-b"), ("Trailing.", "Trailing") })
        {
            var imported = store.ImportArchive(new MemoryStream(PackageZip(root: "W", name: name)), null);
            Assert.Equal(directory, imported.Name);
            Assert.Equal(name, imported.ManifestName);
            Assert.True(PackageNames.IsValid(imported.Name), imported.Name);
            store.Delete(imported.Name);
            Assert.Empty(StagingTree());
        }
        // A legacy package is named after its top-level directory, which is an archive path and fails earlier.
        AssertCode(PackageErrors.ArchiveUnsafePath, () => store.ImportArchive(new MemoryStream(RawZip(new RawEntry("AUX/main.jsx", Source))), null));
        // A suggested name is only a hint: an unusable one falls back to the default, as for "../bad".
        Assert.Equal("Imported Widget", store.ImportArchive(new MemoryStream(RawZip(new RawEntry("main.jsx", Source))), "NUL").Name);
        Assert.Equal(new[] { "Imported Widget" }, store.List().Select(package => package.Name));
    }

    // Archives

    [Fact]
    public void ArchivesWithNamesWindowsCannotStoreAreRefusedBeforeExtraction()
    {
        var names = new List<string>();
        foreach (var name in ReservedNames.Concat(TrailingDotOrSpace).Concat(ReservedCharacters))
        {
            names.Add($"Widget/{name}");
            names.Add($"Widget/{name}/inner.js");
        }
        names.AddRange(DriveAndUncForms);
        names.AddRange(["Widget/main.jsx::$DATA", "Widget/src/NUL", "Widget/src/sub/com1.txt", "NUL", "aux/main.jsx", "Widget/" + "x".Repeat(256)]);
        var destination = Path.Combine(library, "Target");
        Directory.CreateDirectory(library);
        foreach (var name in names)
        {
            var archive = RawZip(new RawEntry("Widget/main.jsx", Source), new RawEntry(name, "owned"));
            var preflight = Assert.Throws<PackageException>(() => PackageArchive.Preflight(archive));
            Assert.True(preflight.Code == PackageErrors.ArchiveUnsafePath, $"{name}: {preflight.Code}");
            AssertCode(PackageErrors.ArchiveUnsafePath, () => PackageArchive.ImportTo(new MemoryStream(archive), staging, destination));
            AssertCode(PackageErrors.ArchiveUnsafePath, () => store.ImportArchive(new MemoryStream(archive), null));
            Assert.Empty(Tree(library));
            Assert.Empty(StagingTree());
        }
    }

    [Fact]
    public void ArchivesWithHiddenUnsafeNamesAreRefusedEvenWhereEntriesAreSkipped()
    {
        // Entries below __MACOSX, __Build and dot-directories are never extracted, but the whole archive is still refused.
        foreach (var name in new[] { "__MACOSX/Widget/NUL", "Widget/__Build/con.js", "Widget/.git/aux", "Widget/.cache/a:b" })
        {
            AssertCode(PackageErrors.ArchiveUnsafePath, () => PackageArchive.Preflight(RawZip(new RawEntry("Widget/main.jsx", Source), new RawEntry(name, "x"))));
        }
    }

    // Reads and writes on disk

    [Fact]
    public void StoreRefusesWindowsUnsafePathsWithoutTouchingTheDisk()
    {
        store.Create("Widget", Source);
        Directory.CreateDirectory(InLibrary("Sibling"));
        var before = Tree(library);
        var paths = new List<string>(DriveAndUncForms);
        foreach (var name in ReservedNames.Concat(TrailingDotOrSpace).Concat(ReservedCharacters)) paths.AddRange(InEverySegment(name));
        paths.AddRange(["main.jsx:evil", "main.jsx::$DATA", "widget.json:Zone.Identifier", InLibrary("Sibling/x.js"), Verbatim(InLibrary("Sibling/x.js"))]);
        var files = store.Files("Widget");
        foreach (var path in paths)
        {
            AssertCode(PackageErrors.InvalidPath, () => store.WriteFile("Widget", path, "owned".Utf8()));
            AssertCode(PackageErrors.InvalidPath, () => store.ReadFile("Widget", path));
            Assert.False(files.Exists(path), path);
            Assert.Null(files.ReadBytes(path));
            Assert.Null(files.ReadText(path));
        }
        Assert.Equal(before, Tree(library));
        Assert.Equal(Source, File.ReadAllText(InLibrary("Widget/main.jsx")));
        // Win32 would open main.jsx for these spellings; the package layer must not.
        Assert.True(File.Exists(InLibrary("Widget/main.jsx.")));
        Assert.False(files.Exists("main.jsx."));
        Assert.False(files.Exists("main.jsx "));
    }

    [Fact]
    public void CreateRefusesManifestEntriesWindowsCannotStore()
    {
        foreach (var entry in new[] { "NUL.js", "con.jsx", "src/aux.js", "main.jsx:alt.js", "C:/main.jsx", "//server/share/main.js", "src /x.js", "a*.js", "COM1.js" })
        {
            AssertCode(PackageErrors.InvalidEntry, () => store.Create("Bad", Source, $"{{\"entry\":\"{entry}\"}}"));
        }
        Assert.Empty(store.List());
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void CanonicalBoundaryCheckUsesTheFullPathAndATrailingSeparator()
    {
        var root = temporary.NewFolder("root");
        temporary.NewFolder("root2");
        Assert.True(SafeFiles.Inside(root, Path.Combine(root, "a.js")));
        Assert.True(SafeFiles.Inside(root, Path.Combine(root, "src", "a.js")));
        Assert.True(SafeFiles.Inside(root + "\\", Path.Combine(root, "a.js")));
        Assert.True(SafeFiles.Inside(root.ToUpperInvariant(), Path.Combine(root, "a.js")));
        Assert.False(SafeFiles.Inside(root, root));
        Assert.False(SafeFiles.Inside(root, root + "\\"));
        Assert.False(SafeFiles.Inside(root, root + "2"));
        Assert.False(SafeFiles.Inside(root, Path.Combine(root + "2", "a.js")));
        Assert.False(SafeFiles.Inside(root, Path.Combine(temporary.Root, "a.js")));
        Assert.False(SafeFiles.Inside(root, root + "\\..\\root2\\a.js"));
        Assert.False(SafeFiles.Inside(root, root + "\\src\\..\\a.js"));
        Assert.False(SafeFiles.Inside(root, root + "\\.\\a.js"));
        Assert.False(SafeFiles.Inside(root, root + "/a.js"));
        Assert.False(SafeFiles.Inside(root, root + "\\a.js."));
        Assert.False(SafeFiles.Inside(root, root + "\\a.js "));
        Assert.False(SafeFiles.Inside(root, root + "\\dir.\\a.js"));
        Assert.False(SafeFiles.Inside(root, "a.js"));
        Assert.False(SafeFiles.Inside(root, Verbatim(Path.Combine(root, "a.js"))));
        Assert.False(SafeFiles.Inside(root, "\\\\server\\share\\a.js"));
        Assert.False(SafeFiles.Inside(root, Path.Combine(root, "a\0.js")));
        Assert.False(SafeFiles.Inside(root, Path.Combine(root, "x".Repeat(PackageLimits.MaxFullPathUnits))));
        // A rooted name must not replace the directory it is joined to.
        Assert.Equal(root + "\\C:\\x", SafeFiles.Child(root, "C:\\x"));
        Assert.False(SafeFiles.Inside(root, SafeFiles.Child(root, "\\\\server\\share")));
    }

    [Fact]
    public void JunctionsAreRefusedAtEveryComponentAndNeverFollowed()
    {
        store.Create("Widget", Source);
        var outside = temporary.NewFolder("outside");
        File.WriteAllText(Path.Combine(outside, "secret.js"), "secret()");
        Links.Junction(InLibrary("Widget/out"), outside);
        Links.Junction(InLibrary("Widget/src/deep/out"), outside);
        Links.Junction(InLibrary("Widget/self"), InLibrary("Widget"));
        Links.Junction(InLibrary("Aliased"), InLibrary("Widget"));
        Assert.True(File.Exists(InLibrary("Widget/out/secret.js")));

        var files = store.Files("Widget");
        Assert.Equal(new[] { "main.jsx", "widget.json" }, files.Paths());
        foreach (var path in new[] { "out/secret.js", "src/deep/out/secret.js", "self/main.jsx", "out", "self" })
        {
            Assert.False(files.Exists(path), path);
            Assert.Null(files.ReadBytes(path));
            AssertCode(PackageErrors.FileNotFound, () => store.ReadFile("Widget", path));
        }
        foreach (var path in new[] { "out/new.js", "out/sub/new.js", "src/deep/out/new.js", "self/main.jsx", "out" })
        {
            AssertCode(PackageErrors.UnsafeFile, () => store.WriteFile("Widget", path, "owned".Utf8()));
        }
        Assert.Equal(new[] { "secret.js" }, Tree(outside));
        Assert.Equal(Source, File.ReadAllText(InLibrary("Widget/main.jsx")));

        AssertCode(PackageErrors.UnsafeFile, () => PackageTree.Validate(InLibrary("Widget")));
        AssertCode(PackageErrors.UnsafeFile, () => PackageTree.Validate(InLibrary("Aliased")));
        AssertCode(PackageErrors.UnsafeFile, () => store.Duplicate("Widget"));
        Assert.Equal(new[] { "Widget" }, store.List().Select(package => package.Name));
        AssertCode(PackageErrors.PackageNotFound, () => store.Files("Aliased"));
        AssertCode(PackageErrors.PackageNotFound, () => store.WriteFile("Aliased", "main.jsx", "owned".Utf8()));

        // Export leaves the links out; delete removes them without touching their targets.
        using var output = new MemoryStream();
        store.ExportArchive("Widget", output);
        Assert.Equal(new[] { "Widget/main.jsx", "Widget/widget.json" }, PackageArchive.Preflight(output.ToArray()));
        store.Delete("Widget");
        Assert.False(Directory.Exists(InLibrary("Widget")));
        Assert.Equal(new[] { "secret.js" }, Tree(outside));
        Assert.Equal("secret()", File.ReadAllText(Path.Combine(outside, "secret.js")));
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void StagingRootMustNotBeAJunction()
    {
        var real = temporary.NewFolder("real-staging");
        var alias = Path.Combine(temporary.Root, "staging-alias");
        Links.Junction(alias, real);
        var linked = new PackageStore(library, alias);
        AssertCode(PackageErrors.StorageUnavailable, () => linked.Create("Widget", Source));
        AssertCode(PackageErrors.StorageUnavailable, () => linked.ImportArchive(new MemoryStream(PackageZip()), null));
        AssertCode(PackageErrors.StorageUnavailable, () => PackageArchive.Extract(new MemoryStream(PackageZip()), alias));
        Assert.Empty(Tree(real));
        Assert.Empty(linked.List());
    }

    [Fact]
    public void NamesWin32WouldRewriteAreNeverPartOfAPackage()
    {
        store.Create("Widget", Source);
        // Only the \\?\ form can create these; through Win32 they would alias "notes" and "main.jsx".
        File.WriteAllText(Verbatim(InLibrary("Widget/notes.")), "dot");
        File.WriteAllText(Verbatim(InLibrary("Widget/main.jsx ")), "space");
        Assert.Contains("notes.", Tree(InLibrary("Widget")));

        var files = store.Files("Widget");
        Assert.Equal(new[] { "main.jsx", "widget.json" }, files.Paths());
        foreach (var path in new[] { "notes.", "notes", "main.jsx " })
        {
            Assert.False(files.Exists(path), path);
            Assert.Null(files.ReadBytes(path));
        }
        Assert.Equal(Source, store.ReadFile("Widget", "main.jsx").Text());
        AssertCode(PackageErrors.InvalidPath, () => PackageTree.Validate(InLibrary("Widget")));
        AssertCode(PackageErrors.InvalidPath, () => store.Duplicate("Widget"));
        using var output = new MemoryStream();
        store.ExportArchive("Widget", output);
        Assert.Equal(new[] { "Widget/main.jsx", "Widget/widget.json" }, PackageArchive.Preflight(output.ToArray()));

        // A directory with such a name is not a package, and deleting a package removes such files too.
        Directory.CreateDirectory(Verbatim(InLibrary("Trailing.")));
        Assert.Equal(new[] { "Widget" }, store.List().Select(package => package.Name));
        store.Delete("Widget");
        Assert.Equal(new[] { "Trailing./" }, Tree(library));
        Assert.Empty(StagingTree());
    }

    [Fact]
    public void NormalizationAliasesOnDiskAreAmbiguous()
    {
        store.Create("Widget", Source);
        var composed = "café.js".Normalize(NormalizationForm.FormC);
        var decomposed = "café.js".Normalize(NormalizationForm.FormD);
        Assert.NotEqual(composed, decomposed);
        // NTFS keeps both spellings as two files; a normalizing filesystem would keep one.
        File.WriteAllText(InLibrary("Widget/" + composed), "composed");
        File.WriteAllText(InLibrary("Widget/" + decomposed), "decomposed");
        Assert.Equal(4, Tree(InLibrary("Widget")).Count);

        var files = store.Files("Widget");
        Assert.Equal(new[] { "main.jsx", "widget.json" }, files.Paths());
        foreach (var name in new[] { composed, decomposed })
        {
            Assert.False(files.Exists(name));
            AssertCode(PackageErrors.FileNotFound, () => store.ReadFile("Widget", name));
            AssertCode(PackageErrors.UnsafeFile, () => store.WriteFile("Widget", name, "owned".Utf8()));
        }
        AssertCode(PackageErrors.UnsafeFile, () => PackageTree.Validate(InLibrary("Widget")));
        Assert.Equal("composed", File.ReadAllText(InLibrary("Widget/" + composed)));
    }

    [Fact]
    public void CollisionDetectionIgnoresCaseAndNormalization()
    {
        Assert.False(SafeFiles.Unambiguous(["main.jsx", "MAIN.jsx"], "main.jsx"));
        Assert.False(SafeFiles.Unambiguous(["Main.JSX"], "main.jsx"));
        Assert.False(SafeFiles.Unambiguous(["CAFE\u0301.js", "café.js"], "café.js"));
        Assert.True(SafeFiles.Unambiguous(["main.jsx", "main.js", "main.jsx2"], "main.jsx"));
        // NTFS compares names in upper case, where the long s and the Kelvin sign meet their ASCII letters.
        Assert.Equal(PackageNames.Identity("s"), PackageNames.Identity("\u017F"));
        Assert.Equal(PackageNames.Identity("k"), PackageNames.Identity("\u212A"));
        Assert.Equal(PackageNames.Identity("STRASSE"), PackageNames.Identity("strasse"));
        // Text that is not valid Unicode is folded without being normalized, and never throws.
        Assert.Equal("a\uD800b", PackageNames.Identity("A\uD800B"));
        store.Create("Kelvin", Source);
        AssertCode(PackageErrors.PackageExists, () => store.Create("\u212Aelvin", Source));
        Assert.Equal("\u212Aelvin (1)", store.UniqueName("\u212Aelvin"));
    }

    // Supporting pieces

    [Fact]
    public void ChecksumMatchesTheZipCrc32()
    {
        Assert.Equal(0xCBF43926L, Crc32.Of("123456789".Utf8()));
        Assert.Equal(0L, Crc32.Of([]));
    }

    [Fact]
    public void GeneratedManifestsUseLineFeedsAndKeepUnicode()
    {
        var created = store.Create("阅读记录", Source);
        var bytes = File.ReadAllBytes(Path.Combine(created.Directory, "widget.json"));
        var text = Encoding.UTF8.GetString(bytes);
        Assert.DoesNotContain('\r', text);
        Assert.EndsWith("]\n}\n", text);
        Assert.Contains("\"name\": \"阅读记录\"", text);
        Assert.Equal(new[] { "formatVersion", "id", "name", "version", "runtimeVersion", "entry", "supportedFamilies", "permissions", "networkDomains", "plugins", "actions", "controls" },
            Json.ParseObject(text).Select(member => member.Key));
    }

    [Fact]
    public void SharedManifestValidatorPlugsIntoTheImportHook()
    {
        using var compiler = new PackageCompiler(new SharedScripts());
        void Validate(IPackageFiles files)
        {
            var result = compiler.ValidateManifest(files.ReadText("widget.json")!, files.Paths());
            if (!result.OptBoolean("ok")) throw new PackageException(PackageErrors.InvalidManifest, Json.Stringify(result));
        }

        Assert.Equal("Widget", store.ImportArchive(new MemoryStream(PackageZip()), null, Validate).Name);
        var unknownKey = Manifest("Extra").Replace("\"permissions\":[]", "\"permissions\":[],\"surprise\":true");
        var unsupported = Manifest("Future").Replace("\"formatVersion\":2", "\"formatVersion\":99");
        var missingEntry = Manifest("NoEntry").Replace("\"main.jsx\"", "\"missing.jsx\"");
        foreach (var manifest in new[] { unknownKey, unsupported, missingEntry })
        {
            var archive = RawZip(new RawEntry("W/widget.json", manifest), new RawEntry("W/main.jsx", Source));
            AssertCode(PackageErrors.InvalidManifest, () => store.ImportArchive(new MemoryStream(archive), null, Validate));
        }
        Assert.Equal(new[] { "Widget" }, store.List().Select(package => package.Name));
        Assert.Empty(StagingTree());
    }
}
