using System.Text.Json.Nodes;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Tests.Packages;

namespace ScriptWidget.Core.Tests.AI;

public sealed class AiPersistenceTests
{
    [Theory]
    [InlineData("formatVersion")]
    [InlineData("temperature")]
    [InlineData("provider")]
    public void ProfileFieldTypesFailClosed(string field)
    {
        using var temporary = new TemporaryFolder();
        var path = Path.Combine(temporary.Root, "profiles.json");
        var store = new AiProfileStore(path);
        var profile = AiProfile.Create(AiProvider.OpenAi);
        store.Save(new([profile], profile.Id));
        var json = Json.ParseObject(File.ReadAllText(path));
        var row = (JsonObject)json.OptArray("profiles")![0]!;
        row[field] = field == "provider" ? "0" : "1";
        File.WriteAllText(path, Json.Stringify(json));
        Assert.Empty(store.Load().Profiles);
    }

    [Fact]
    public void ConversationRejectsCyclesAndInvalidOptionalFieldTypes()
    {
        var conversation = new AiConversation();
        conversation.AddVersion("$render(<text>Hello</text>);");
        var turn = conversation.Begin("Change the title.");
        turn.Status = AiTurnStatus.Failed;
        foreach (var field in new[] { "note", "errorSummary", "failedSource", "isManualEdit", "repairs", "promptTokens" })
        {
            var json = conversation.ToJson();
            ((JsonObject)json.OptArray("turns")![0]!)[field] = field is "note" or "errorSummary" or "failedSource" ? JsonValue.Create(123) : JsonValue.Create("wrong type");
            Assert.Throws<AiException>(() => AiConversation.FromJson(Json.Stringify(json)));
        }
        var cycle = conversation.ToJson();
        ((JsonObject)cycle.OptArray("versions")![0]!)["parentId"] = conversation.CurrentVersionId;
        Assert.Throws<AiException>(() => AiConversation.FromJson(Json.Stringify(cycle)));
    }

    [Fact]
    public void PrivateWritesDoNotFollowAnExistingTemporaryLink()
    {
        using var temporary = new TemporaryFolder();
        var path = Path.Combine(temporary.Root, "settings.json");
        var victim = Path.Combine(temporary.Root, "unrelated.txt");
        File.WriteAllText(victim, "preserve");
        File.CreateSymbolicLink(path + ".tmp", victim);
        var file = new SafeJsonFile(path, 128);
        Assert.True(file.Write("{\"ok\":true}"));
        Assert.Equal("preserve", File.ReadAllText(victim));
        Assert.Equal("{\"ok\":true}", file.Read());
        Assert.False(file.Write(new string('x', 129)));
        Assert.Equal("{\"ok\":true}", file.Read());
        Assert.DoesNotContain(Directory.GetFiles(temporary.Root), name => Path.GetFileName(name).StartsWith(".write-", StringComparison.Ordinal));
    }

    [Fact]
    public void PrivateReadsAndWritesRefuseALinkedDirectory()
    {
        using var temporary = new TemporaryFolder();
        var real = Path.Combine(temporary.Root, "real");
        Directory.CreateDirectory(real);
        var link = Path.Combine(temporary.Root, "link");
        Directory.CreateSymbolicLink(link, real);
        var file = new SafeJsonFile(Path.Combine(link, "settings.json"), 128);
        Assert.False(file.Write("{}"));
        Assert.Throws<PrivateFile.Unreadable>(() => file.Read());
        Assert.Empty(Directory.GetFiles(real));
    }
}
