using ScriptWidget.Core.Packages;
using static ScriptWidget.Core.Tests.Packages.ZipFixtures;

namespace ScriptWidget.Core.Tests.Packages;

public sealed class DiskPackageFilesTests : IDisposable
{
    private readonly TemporaryFolder temporary = new();
    private readonly string root;
    private readonly string outside;
    private readonly DiskPackageFiles files;

    public DiskPackageFilesTests()
    {
        root = temporary.NewFolder("library", "Widget");
        outside = temporary.NewFolder("outside");
        File.WriteAllText(Path.Combine(outside, "secret.txt"), "secret");
        File.WriteAllText(Path.Combine(outside, "secret.js"), "secret()");
        Write("main.jsx", "$render(<text/>);");
        Write("widget.json", "{}");
        Write("src/util/helper.js", "export const a = 1;");
        Write("image/logo.png", "PNG");
        files = new DiskPackageFiles(root);
    }

    public void Dispose() => temporary.Dispose();

    private void Write(string path, string text) => Write(path, text.Utf8());

    private void Write(string path, byte[] bytes)
    {
        var file = Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllBytes(file, bytes);
    }

    private void Link(string path, string target) => Links.Create(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)), target);

    private static byte[] Filled(int count, char character)
    {
        var bytes = new byte[count];
        Array.Fill(bytes, (byte)character);
        return bytes;
    }

    private static string Nested(string name, int depth) => string.Join('/', Enumerable.Repeat(name, depth));

    [Fact]
    public void ListsRegularFilesAsSortedNormalizedPaths()
    {
        Assert.Equal(new[] { "image/logo.png", "main.jsx", "src/util/helper.js", "widget.json" }, files.Paths());
    }

    [Fact]
    public void ListingSkipsDotFilesBuildCacheAndLinks()
    {
        Write(".DS_Store", "x");
        Write(".git/config", "x");
        Write("src/.cache/tmp.js", "x");
        Write("__Build/main.js", "compiled");
        Write("src/__build/main.js", "compiled");
        Link("linked.js", Path.Combine(outside, "secret.js"));
        Link("linkedDir", outside);
        Link("dangling.js", Path.Combine(outside, "missing.js"));
        Assert.Equal(new[] { "image/logo.png", "main.jsx", "src/util/helper.js", "widget.json" }, files.Paths());
    }

    [Fact]
    public void ReadsExistingFiles()
    {
        Assert.True(files.Exists("main.jsx"));
        Assert.True(files.Exists("src/util/helper.js"));
        Assert.Equal("export const a = 1;", files.ReadText("src/util/helper.js"));
        Assert.Equal("PNG".Utf8(), files.ReadBytes("image/logo.png"));
        Assert.Equal("{}".Utf8(), files.ReadBytes("widget.json"));
    }

    [Fact]
    public void RejectsPathsThatAreNotNormalizedPackageRelativePaths()
    {
        File.WriteAllText(Path.Combine(Path.GetDirectoryName(root)!, "sibling.js"), "sibling");
        string[] unsafePaths =
        [
            "", "/", ".", "..", "../sibling.js", "../Widget/main.jsx", "src/../main.jsx", "src/../../sibling.js", "./main.jsx", "src//util/helper.js",
            "main.jsx/", "/main.jsx", Path.Combine(root, "main.jsx"), Path.Combine(outside, "secret.js"), "src\\util\\helper.js",
            "..\\sibling.js", "main.jsx\0", "main\0.jsx", "C:main.jsx", "src/util/helper.js\n",
            Nested("d", 17) + ".js", "x".Repeat(256) + ".js",
        ];
        foreach (var path in unsafePaths)
        {
            Assert.False(files.Exists(path), path);
            Assert.Null(files.ReadText(path));
            Assert.Null(files.ReadBytes(path));
        }
    }

    [Fact]
    public void ExistsIsTrueOnlyForRegularFiles()
    {
        Assert.False(files.Exists("src"));
        Assert.False(files.Exists("src/util"));
        Assert.False(files.Exists("missing.js"));
        Assert.False(files.Exists("main.jsx/child.js"));
        Assert.Null(files.ReadBytes("src"));
    }

    [Fact]
    public void RejectsSymbolicLinksAtEveryComponent()
    {
        Link("linked.js", Path.Combine(outside, "secret.js"));
        Link("linkedDir", outside);
        Link("src/deep/link", outside);
        Link("inside.js", Path.Combine(root, "main.jsx"));
        Link("dangling.js", Path.Combine(outside, "missing.js"));
        foreach (var path in new[] { "linked.js", "linkedDir/secret.js", "linkedDir/secret.txt", "src/deep/link/secret.js", "inside.js", "dangling.js", "linkedDir" })
        {
            Assert.False(files.Exists(path), path);
            Assert.Null(files.ReadText(path));
            Assert.Null(files.ReadBytes(path));
        }
    }

    [Fact]
    public void RejectsAPackageRootThatIsItselfALink()
    {
        var alias = Path.Combine(temporary.Root, "alias");
        Links.Create(alias, root);
        var linked = new DiskPackageFiles(alias);
        Assert.Empty(linked.Paths());
        Assert.False(linked.Exists("main.jsx"));
        Assert.Null(linked.ReadText("main.jsx"));
        Assert.Empty(new DiskPackageFiles(Path.Combine(temporary.Root, "missing")).Paths());
    }

    [Fact]
    public void RejectsHardLinkedFiles()
    {
        Links.HardLink(Path.Combine(root, "hard.js"), Path.Combine(outside, "secret.js"));
        Assert.False(files.Exists("hard.js"));
        Assert.Null(files.ReadText("hard.js"));
        Assert.DoesNotContain("hard.js", files.Paths());
    }

    [Fact]
    public void RejectsCaseAliasesAndHiddenOrCachePaths()
    {
        Write(".env", "TOKEN=1");
        Write("__Build/main.js", "compiled");
        foreach (var path in new[] { "MAIN.jsx", "Main.JSX", "SRC/util/helper.js", "Widget.json", ".env", "__Build/main.js", "__build/main.js" })
        {
            Assert.False(files.Exists(path), path);
            Assert.Null(files.ReadBytes(path));
        }
    }

    [Fact]
    public void ReadTextReturnsOnlyBoundedUtf8TextFiles()
    {
        Write("data.bin", "text in a binary file");
        Write("bad.txt", [0x66, 0xC3, 0x28]);
        Write("big.jsx", Filled(PackageLimits.MaxScriptBytes + 1, 'a'));
        Write("edge.jsx", Filled(PackageLimits.MaxScriptBytes, 'a'));
        Write("notes.txt", Filled(PackageLimits.MaxScriptBytes + 1, 'a'));
        Write("huge.txt", Filled(PackageLimits.MaxTextBytes + 1, 'a'));
        Write("unicode.md", "阅读 👩‍💻");
        Assert.Null(files.ReadText("image/logo.png"));
        Assert.Null(files.ReadText("data.bin"));
        Assert.Null(files.ReadText("bad.txt"));
        Assert.Null(files.ReadText("big.jsx"));
        Assert.Equal(PackageLimits.MaxScriptBytes, files.ReadText("edge.jsx")!.Length);
        Assert.Equal(PackageLimits.MaxScriptBytes + 1, files.ReadText("notes.txt")!.Length);
        Assert.Null(files.ReadText("huge.txt"));
        Assert.Equal("阅读 👩‍💻", files.ReadText("unicode.md"));
        Assert.Equal(PackageLimits.MaxTextBytes + 1, files.ReadBytes("huge.txt")!.Length);
    }

    [Fact]
    public void ReadBytesIsCappedAtSixteenMebibytes()
    {
        Write("edge.bin", new byte[PackageLimits.MaxBinaryReadBytes]);
        Write("big.bin", new byte[PackageLimits.MaxBinaryReadBytes + 1]);
        Assert.Equal(PackageLimits.MaxBinaryReadBytes, files.ReadBytes("edge.bin")!.Length);
        Assert.Null(files.ReadBytes("big.bin"));
        Assert.True(files.Exists("big.bin"));
    }

    [Fact]
    public void ListingFailsClosedBeyondTheEntryLimit()
    {
        for (var index = 0; index < PackageLimits.MaxFileCount; index++) Write($"many/f{index}.txt", "x");
        AssertCode(PackageErrors.TooManyEntries, () => files.Paths());
    }

    [Fact]
    public void ListingStopsAtTheDepthLimit()
    {
        Write(Nested("d", 15) + "/ok.js", "x");
        Write(Nested("e", 16) + "/deep.js", "x");
        var listed = files.Paths();
        Assert.Contains(listed, path => path.EndsWith("/ok.js", StringComparison.Ordinal));
        Assert.DoesNotContain(listed, path => path.EndsWith("/deep.js", StringComparison.Ordinal));
    }
}
