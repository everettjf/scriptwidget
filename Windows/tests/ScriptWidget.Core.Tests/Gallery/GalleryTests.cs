using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Gallery;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Core.Skills;
using ScriptWidget.Core.Tests.Api;
using ScriptWidget.Core.Tests.Packages;

namespace ScriptWidget.Core.Tests.Gallery;

public sealed class GalleryTests(ScriptRuntimeFixture runtime) : IClassFixture<ScriptRuntimeFixture>, IDisposable
{
    private readonly TemporaryFolder temporary = new();
    private DataPaths Paths => new(Path.Combine(temporary.Root, "data"));
    private Library Library => new(Paths);
    private SkillStore Skills => new(Paths.Skills);
    private sealed class OfflineTransport : IGalleryTransport
    {
        public Dictionary<string, byte[]> Files { get; } = new(StringComparer.Ordinal);
        public bool Fail { get; set; }
        public string? FinalUrl { get; set; }
        public List<(string Url, int Limit)> Requests { get; } = [];
        public Task<GalleryResponse> DownloadAsync(string url, int maximumBytes, CancellationToken cancellation = default)
        {
            cancellation.ThrowIfCancellationRequested();
            Requests.Add((url, maximumBytes));
            if (Fail) throw new IOException("offline");
            return Task.FromResult(new GalleryResponse(Files.ContainsKey(url) ? 200 : 404, Files.GetValueOrDefault(url) ?? [], FinalUrl ?? url));
        }
    }
    private readonly OfflineTransport transport = new();
    private GalleryService Service => new(Paths, Library, Skills, transport);
    public void Dispose() => temporary.Dispose();

    private GalleryItem Widget(string version = "1.0.0", string source = "$render(<text>Gallery</text>);")
    {
        var manifest = PackageManifests.NewManifest("Gallery Widget");
        manifest["id"] = "com.example.gallery";
        manifest["version"] = version;
        return Item("widget", "com.example.gallery", version, new Dictionary<string, byte[]>
        {
            ["widget.json"] = PackageManifests.Encode(manifest), ["main.jsx"] = Encoding.UTF8.GetBytes(source),
        });
    }
    private GalleryItem Item(string kind, string id, string version, Dictionary<string, byte[]> files)
    {
        var members = new List<GalleryFile>();
        foreach (var (name, bytes) in files)
        {
            var url = GalleryCatalog.TrustedRoot + "widgets/example/" + name;
            transport.Files[url] = bytes;
            members.Add(new GalleryFile(name, url, Convert.ToHexStringLower(SHA256.HashData(bytes)), bytes.Length));
        }
        return new GalleryItem(id, kind, "Gallery Widget", version, "A verified example.", "square", "ScriptWidget", "MIT", ["test"], "https://github.com/everettjf/scriptwidget", false, members);
    }
    private void Validate(IPackageFiles files) => runtime.Compiler.Prepare(files);

    [Fact]
    public void TheShippedIndexPassesTheWindowsValidator()
    {
        var catalog = GalleryCatalog.Decode(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "fixtures", "gallery-index.json")));
        Assert.NotEmpty(catalog.Items);
        Assert.Contains(catalog.Items, item => item.Kind == "widget");
        Assert.Contains(catalog.Items, item => item.Kind == "skill");
    }

    [Theory]
    [InlineData("http://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json")]
    [InlineData("https://raw.githubusercontent.com.evil.test/everettjf/scriptwidget/main/Gallery/index.json")]
    [InlineData("https://raw.githubusercontent.com/another/repo/main/Gallery/index.json")]
    [InlineData("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/../outside")]
    [InlineData("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/%2e%2e/outside")]
    [InlineData("https://raw.githubusercontent.com:443/everettjf/scriptwidget/main/Gallery/index.json")]
    [InlineData("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json?token=x")]
    [InlineData("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json#fragment")]
    public void UrlsCannotEscapeTheConfiguredRoot(string url) => Assert.False(GalleryCatalog.IsTrustedUrl(url));

    [Fact]
    public async Task OfflineCacheIsRevalidatedAndInvalidUpdatesDoNotReplaceIt()
    {
        var bytes = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "fixtures", "gallery-index.json"));
        transport.Files[GalleryCatalog.IndexUrl] = bytes;
        var online = await Service.LoadAsync();
        Assert.False(online.IsOffline);
        transport.Files[GalleryCatalog.IndexUrl] = Encoding.UTF8.GetBytes("{}");
        var offline = await Service.LoadAsync();
        Assert.True(offline.IsOffline);
        Assert.Equal(online.Index.Items.Count, offline.Index.Items.Count);
        Assert.NotNull(offline.Warning);
        File.WriteAllText(Path.Combine(Paths.Gallery, "index.json"), "{}");
        await Assert.ThrowsAsync<GalleryException>(() => Service.LoadAsync());
    }

    [Fact]
    public async Task InstallsAndUpdatesWithoutChangingTheDesktopIdentity()
    {
        var library = Library;
        var service = new GalleryService(Paths, library, Skills, transport);
        var item = Widget();
        var installed = await service.InstallAsync(item, Validate);
        Assert.False(installed.Updated);
        var first = library.Find(installed.Installation.LocalName)!;
        var identity = first.Installation;
        Assert.Equal("installed", service.State(item));
        await Assert.ThrowsAsync<GalleryException>(() => service.InstallAsync(item, Validate));
        var update = Widget("1.1.0", "$render(<text>Updated</text>);");
        Assert.Equal("updateAvailable", service.State(update));
        var result = await service.InstallAsync(update, Validate, updateExisting: true);
        Assert.True(result.Updated);
        Assert.Equal(identity, library.Find(result.Installation.LocalName)!.Installation);
        Assert.Equal("1.1.0", library.Find(result.Installation.LocalName)!.Manifest.OptString("version"));
        Assert.Contains("Updated", library.Find(result.Installation.LocalName)!.Files.ReadText("main.jsx"));
        Assert.Single(library.List());
        Assert.Equal("installed", Service.State(update));
    }

    [Fact]
    public async Task ARejectedUpdateKeepsTheExistingPackageAndRegistry()
    {
        var item = Widget();
        var first = await Service.InstallAsync(item, Validate);
        var old = Library.Find(first.Installation.LocalName)!;
        var identity = old.Installation;
        var update = Widget("1.1.0", "$render(<text>bad</text>);");
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.InstallAsync(update, _ => throw new InvalidOperationException("reject"), updateExisting: true));
        Assert.Equal(identity, Library.Find(first.Installation.LocalName)!.Installation);
        Assert.Equal("1.0.0", Library.Find(first.Installation.LocalName)!.Manifest.OptString("version"));
        Assert.Equal("installed", Service.State(item));
        Assert.Single(Library.List());
    }

    [Theory]
    [InlineData("hash")]
    [InlineData("size")]
    [InlineData("origin")]
    public async Task VerificationFailureInstallsNothing(string failure)
    {
        var item = Widget();
        if (failure == "origin") transport.FinalUrl = "https://evil.test/payload";
        else
        {
            var member = item.Files[0];
            transport.Files[member.Url] = failure == "size" ? [0] : Enumerable.Repeat((byte)'x', member.Bytes).ToArray();
        }
        var error = await Assert.ThrowsAsync<GalleryException>(() => Service.InstallAsync(item, Validate));
        Assert.Equal("invalid_download", error.Code);
        Assert.Empty(Library.List());
        Assert.Equal("notInstalled", Service.State(item));
    }

    [Fact]
    public async Task ACorrectHashDoesNotOverrideManifestIdentityValidation()
    {
        var item = Widget() with { Id = "com.example.other" };
        var error = await Assert.ThrowsAsync<GalleryException>(() => Service.InstallAsync(item, Validate));
        Assert.Equal("identity_mismatch", error.Code);
        Assert.Empty(Library.List());
    }

    [Fact]
    public async Task ARegistryCannotRedirectAnUpdateToAnUnrelatedWidget()
    {
        var item = Widget();
        var first = await Service.InstallAsync(item, Validate);
        Library.WriteFile(first.Installation.LocalName, "widget.json", PackageManifests.Encode(PackageManifests.NewManifest("Mine")));
        Assert.Equal("notInstalled", Service.State(item));
        var second = await Service.InstallAsync(item, Validate, updateExisting: true);
        Assert.NotEqual(first.Installation.LocalName, second.Installation.LocalName);
        Assert.Equal(2, Library.List().Count);
        Assert.Equal("Mine", Library.Find(first.Installation.LocalName)!.Manifest.OptString("name"));
    }

    [Fact]
    public async Task SkillDownloadsUseTheSameValidatorAndRemainDisabled()
    {
        var skill = new WidgetSkill("com.example.skill", "A Skill", "1.0.0", "Prompt only.", "square", [], "Use readable text.");
        var item = Item("skill", skill.Id, skill.Version, new Dictionary<string, byte[]> { ["skill.json"] = SkillValidator.Manifest(skill), ["SKILL.md"] = Encoding.UTF8.GetBytes(skill.Instruction) });
        await Service.InstallAsync(item, Validate);
        Assert.Equal(skill.Instruction, Skills.Find(skill.Id)!.Instruction);
        Assert.Empty(Skills.EnabledIds());
        Assert.Equal("installed", Service.State(item));
    }

    [Fact]
    public async Task FailedRegistryWriteRollsBackAFreshInstallation()
    {
        var item = Widget();
        Directory.CreateDirectory(Path.Combine(Paths.Gallery, "installations.json"));
        await Assert.ThrowsAsync<GalleryException>(() => Service.InstallAsync(item, Validate));
        Assert.Empty(Library.List());
    }

    [Fact]
    public async Task CancellationDoesNotInstallOrFallBackToCache()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Service.LoadAsync(cancellation.Token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Service.InstallAsync(Widget(), Validate, cancellation: cancellation.Token));
        Assert.Empty(Library.List());
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("a\\b")]
    [InlineData("NUL.txt")]
    [InlineData("__Build/main.js")]
    [InlineData(".hidden")]
    [InlineData("main.jsx/child.js")]
    public async Task UnsafePathsAreRefusedBeforeAnyDownload(string path)
    {
        var item = Widget();
        item = item with { Files = [.. item.Files, item.Files[0] with { Path = path }] };
        await Assert.ThrowsAsync<GalleryException>(() => Service.InstallAsync(item, Validate));
        Assert.Empty(transport.Requests);
        Assert.Empty(Library.List());
    }

    [Fact]
    public void SchemaRejectsUnknownFieldsDuplicateKeysAndCaseCollisions()
    {
        var bytes = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "fixtures", "gallery-index.json"));
        var json = Json.ParseObject(Encoding.UTF8.GetString(bytes));
        json["futureCapability"] = true;
        Assert.Throws<GalleryException>(() => GalleryCatalog.Decode(Encoding.UTF8.GetBytes(Json.Stringify(json))));
        var source = Encoding.UTF8.GetString(bytes).Replace("\"schemaVersion\": 1", "\"schemaVersion\": 1, \"schemaVersion\": 1", StringComparison.Ordinal);
        Assert.Throws<GalleryException>(() => GalleryCatalog.Decode(Encoding.UTF8.GetBytes(source)));
        var item = Widget();
        Assert.Throws<GalleryException>(() => GalleryCatalog.Validate(item with { Files = [.. item.Files, item.Files[0] with { Path = "WIDGET.JSON" }] }));
    }
}
