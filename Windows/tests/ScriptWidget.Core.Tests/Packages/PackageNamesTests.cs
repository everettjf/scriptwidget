using ScriptWidget.Core.Packages;

namespace ScriptWidget.Core.Tests.Packages;

/// <summary>Ports <c>testNamesPreserveUnicodeButRejectDirectoryAndCacheEscapes</c> and <c>packageNames.test.js</c>.</summary>
public class PackageNamesTests
{
    [Fact]
    public void RejectsNamesThatCouldBecomeTraversalOrReservedCachePaths()
    {
        string[] invalid =
        [
            "", " ", "\t\n", ".", "..", "../outside", "/outside", "folder/child", "folder\\child", "__Build", "__BUILD", "__build",
            ".hidden", "name\0bad", "name\nbad", "name\u202Ebad", "C:relative", "c:\\windows", "bad\uD800surrogate",
            "a".Repeat(81), "😀".Repeat(61), "漢".Repeat(80) + "x",
        ];
        foreach (var name in invalid) Assert.False(PackageNames.IsValid(name), name);
        Assert.False(PackageNames.IsValid(null));
    }

    [Fact]
    public void AcceptsUnicodeDisplayNames()
    {
        // The Kotlin list also holds "Ratio 16:9". A package name is a directory name, and Windows
        // reads a colon as stream syntax, so that name is refused here (see WindowsPathRulesTests).
        string[] valid =
        [
            "My Widget", "阅读记录", "👩‍💻 Focus", "e\u0301", "e\u0301".Repeat(80), "😀".Repeat(60), "Foo.Bar", "a".Repeat(80),
            "漢".Repeat(80), "Ratio 16-9", "Build", "__Builder", "नमस्ते\u200Dक",
        ];
        foreach (var name in valid) Assert.True(PackageNames.IsValid(name), name);
    }

    [Fact]
    public void ByteLimitAppliesIndependentlyOfGraphemeLimit()
    {
        // 61 four-byte scalars are 244 UTF-8 bytes; joined into fewer graphemes they still exceed 240 bytes.
        Assert.False(PackageNames.IsValid("😀".Repeat(61)));
        Assert.True(PackageNames.IsValid("漢".Repeat(80)));
        Assert.Equal(240, PackageNames.Utf8Length("漢".Repeat(80)));
    }

    [Fact]
    public void IdentityFoldsCaseAndUnicodeNormalization()
    {
        Assert.Equal(PackageNames.Identity("Café"), PackageNames.Identity("CAFE\u0301"));
        Assert.Equal("__build", PackageNames.Identity("__BUILD"));
        Assert.False(PackageNames.Identity("Widget") == PackageNames.Identity("Widget 2"));
    }

    [Fact]
    public void SuffixTruncatesTheStemByGraphemesToKeepLimits()
    {
        Assert.Equal("Widget (1)", PackageNames.WithSuffix("Widget", " (1)"));
        var longName = "a".Repeat(80);
        Assert.Equal("a".Repeat(76) + " (1)", PackageNames.WithSuffix(longName, " (1)"));
        Assert.Equal("a".Repeat(74) + " Remix", PackageNames.WithSuffix(longName, " Remix"));
        var wide = PackageNames.WithSuffix("漢".Repeat(80), " (10000)");
        Assert.True(PackageNames.IsValid(wide), wide);
        Assert.EndsWith(" (10000)", wide);
        Assert.Equal(72 + 8, PackageNames.GraphemeCount(wide));
        var accents = PackageNames.WithSuffix("e\u0301".Repeat(80), " (1)");
        Assert.Equal("e\u0301".Repeat(76) + " (1)", accents);
    }

    [Fact]
    public void LegacyIdentifiersAndArchiveRootsMatchTheSharedEngine()
    {
        Assert.Equal("legacy.my-widget", PackageNames.LegacyId("My Widget!"));
        Assert.Equal("legacy.widget", PackageNames.LegacyId("阅读记录"));
        Assert.Equal("Ratio 16-9", PackageNames.ArchiveRootName("Ratio 16:9"));
        Assert.Equal("Widget", PackageNames.ArchiveRootName("..."));
    }
}
