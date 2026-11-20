using System.Text;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Skills;
using ScriptWidget.Core.Tests.Packages;
using static ScriptWidget.Core.Tests.Packages.ZipFixtures;

namespace ScriptWidget.Core.Tests.Skills;

public sealed class SkillStoreTests : IDisposable
{
    private readonly TemporaryFolder temporary = new();
    private string Root => Path.Combine(temporary.Root, "skills");
    private SkillStore Store => new(Root);
    private static WidgetSkill Example => new("com.example.layout", "Layout", "1.2.3", "Layout carefully.", "square", ["design"], "Use readable text.\nDo not add network permissions.");
    private static byte[] Manifest => SkillValidator.Manifest(Example);
    private static byte[] Instruction => Encoding.UTF8.GetBytes(Example.Instruction);
    public void Dispose() => temporary.Dispose();

    [Fact]
    public void BuiltInsAreReadOnlyAndNothingIsEnabledByDefault()
    {
        Assert.Equal(5, Store.List().Count);
        Assert.All(Store.List(), skill => Assert.True(skill.IsBuiltIn));
        Assert.Empty(Store.EnabledIds());
        Assert.Equal("", Store.PromptText());
        Assert.Equal("built_in_skill", Assert.Throws<SkillException>(() => Store.Delete("responsive-layout")).Code);
    }

    [Fact]
    public void InstallingEnablingReplacingAndDeletingArePersistent()
    {
        var store = Store;
        Assert.Equal(Example.Id, store.Install(Manifest, Instruction).Id);
        Assert.Equal(Example.Instruction, Store.Find(Example.Id)!.Instruction);
        Assert.False(Store.Find(Example.Id)!.IsBuiltIn);
        Assert.Equal("duplicate_skill", Assert.Throws<SkillException>(() => store.Install(Manifest, Instruction)).Code);
        store.SetEnabled(Example.Id, true);
        Assert.Contains(Example.Id, Store.EnabledIds());
        Assert.Contains("Use readable text.", Store.PromptText());
        Assert.Equal("", Store.PromptText([]));
        Assert.DoesNotContain("Responsive Layout", Store.PromptText([Example.Id]));
        store.Install(Manifest, Encoding.UTF8.GetBytes("New instructions."), replaceExisting: true);
        Assert.Contains("New instructions.", Store.PromptText());
        Assert.DoesNotContain("Use readable text.", Store.PromptText());
        store.Delete(Example.Id);
        Assert.Null(Store.Find(Example.Id));
        Assert.Empty(Store.EnabledIds());
        Assert.Empty(Directory.GetDirectories(Root));
    }

    [Fact]
    public void InvalidReplacementKeepsTheInstalledSkill()
    {
        Store.Install(Manifest, Instruction);
        Assert.Throws<SkillException>(() => Store.Install(Manifest, [], replaceExisting: true));
        Assert.Equal(Example.Instruction, Store.Find(Example.Id)!.Instruction);
        Assert.Single(Directory.GetDirectories(Root));
    }

    [Theory]
    [InlineData("tools", "[\"shell\"]")]
    [InlineData("permissions", "[\"network\"]")]
    [InlineData("executable", "true")]
    [InlineData("networkDomains", "[\"example.com\"]")]
    public void SkillsCannotDeclareCapabilities(string field, string value)
    {
        var json = Json.ParseObject(Encoding.UTF8.GetString(Manifest));
        json[field] = Json.Parse(value);
        var error = Assert.Throws<SkillException>(() => Store.Install(Encoding.UTF8.GetBytes(Json.Stringify(json)), Instruction));
        Assert.Equal("unknown_field", error.Code);
        Assert.Null(Store.Find(Example.Id));
    }

    [Theory]
    [InlineData("formatVersion", "2")]
    [InlineData("minimumRuntimeVersion", "\"2.0\"")]
    [InlineData("promptFile", "\"../outside.md\"")]
    [InlineData("tags", "[\"design\",\"DESIGN\"]")]
    [InlineData("tags", "[42]")]
    [InlineData("name", "\" \"")]
    [InlineData("version", "\"1.0\"")]
    [InlineData("id", "\"../outside\"")]
    public void ManifestRulesFailClosed(string field, string value)
    {
        var json = Json.ParseObject(Encoding.UTF8.GetString(Manifest));
        json[field] = Json.Parse(value);
        Assert.Throws<SkillException>(() => SkillValidator.Load(Encoding.UTF8.GetBytes(Json.Stringify(json)), Instruction));
    }

    [Fact]
    public void Utf8DuplicateKeysAndByteLimitsAreEnforced()
    {
        Assert.Equal("invalid_manifest", Assert.Throws<SkillException>(() => SkillValidator.Load([0xff], Instruction)).Code);
        Assert.Equal("invalid_instruction", Assert.Throws<SkillException>(() => SkillValidator.Load(Manifest, [0xff])).Code);
        var duplicate = Encoding.UTF8.GetString(Manifest).Replace("\"formatVersion\": 1", "\"formatVersion\": 1, \"formatVersion\": 2", StringComparison.Ordinal);
        Assert.Equal("invalid_manifest", Assert.Throws<SkillException>(() => SkillValidator.Load(Encoding.UTF8.GetBytes(duplicate), Instruction)).Code);
        Assert.Equal("too_large", Assert.Throws<SkillException>(() => SkillValidator.Load(new byte[32769], Instruction)).Code);
        Assert.Equal("too_large", Assert.Throws<SkillException>(() => SkillValidator.Load(Manifest, new byte[65537])).Code);
    }

    [Fact]
    public void DiskTamperingNeverContributesToPrompts()
    {
        Store.Install(Manifest, Instruction);
        Store.SetEnabled(Example.Id, true);
        var directory = Assert.Single(Directory.GetDirectories(Root));
        File.WriteAllText(Path.Combine(directory, "extra.js"), "throw new Error('never run');");
        Assert.Null(Store.Find(Example.Id));
        Assert.Equal("", Store.PromptText());
        File.Delete(Path.Combine(directory, "extra.js"));
        File.WriteAllBytes(Path.Combine(directory, "SKILL.md"), [0xff]);
        Assert.Null(Store.Find(Example.Id));
    }

    [Fact]
    public void LinkedFilesAndRootsAreRefused()
    {
        Store.Install(Manifest, Instruction);
        var directory = Assert.Single(Directory.GetDirectories(Root));
        File.Delete(Path.Combine(directory, "SKILL.md"));
        var outside = temporary.NewFile("outside.md", "Outside instructions.");
        Links.Create(Path.Combine(directory, "SKILL.md"), outside);
        Assert.Null(Store.Find(Example.Id));
        var linkedRoot = Path.Combine(temporary.Root, "linked-root");
        var target = temporary.NewFolder("elsewhere");
        Links.Create(linkedRoot, target);
        Assert.Throws<SkillException>(() => new SkillStore(linkedRoot).Install(Manifest, Instruction));
        Assert.Throws<SkillException>(() => new SkillStore(linkedRoot).SetEnabled("responsive-layout", true));
        Assert.Empty(Directory.GetFileSystemEntries(target));
    }

    [Fact]
    public void ExportAndImportRoundTripWithoutExecutingAnything()
    {
        var source = Example with { Instruction = "$(echo never-run)\n<script>never execute</script>" };
        Store.Install(SkillValidator.Manifest(source), Encoding.UTF8.GetBytes(source.Instruction));
        using var archive = new MemoryStream();
        Store.Export(source.Id, archive);
        using var other = new TemporaryFolder();
        var imported = new SkillStore(Path.Combine(other.Root, "skills"));
        archive.Position = 0;
        Assert.Equal(source.Instruction, imported.ImportArchive(archive).Instruction);
        Assert.Null(imported.Find(source.Id)!.Author);
        Assert.Empty(imported.EnabledIds());
        Assert.Equal(source.Instruction, imported.Find(source.Id)!.Instruction);
    }

    [Fact]
    public void WrappedArchivesWorkAndExtraEntriesAreRefused()
    {
        byte[] Archive(params RawEntry[] extra) => RawZip([new RawEntry("Layout/skill.json", Manifest), new RawEntry("Layout/SKILL.md", Instruction), .. extra]);
        Assert.Equal(Example.Id, Store.ImportArchive(new MemoryStream(Archive())).Id);
        Assert.Throws<SkillException>(() => Store.ImportArchive(new MemoryStream(Archive(new RawEntry("Layout/run.js", "never run")))));
        Assert.Throws<SkillException>(() => Store.ImportArchive(new MemoryStream(Archive(new RawEntry("Layout/.hidden", "never run")))));
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("/absolute")]
    [InlineData("C:/outside")]
    [InlineData("lib\\file")]
    [InlineData("CON")]
    public void UnsafeArchivePathsNeverReachTheFilesystem(string path)
    {
        var archive = RawZip(new RawEntry("skill.json", Manifest), new RawEntry("SKILL.md", Instruction), new RawEntry(path, "payload"));
        Assert.Throws<PackageException>(() => Store.ImportArchive(new MemoryStream(archive)));
        Assert.Null(Store.Find(Example.Id));
        Assert.False(Directory.Exists(Root));
    }
}
