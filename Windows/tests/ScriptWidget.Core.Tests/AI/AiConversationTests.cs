using System.Text;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Core.Skills;
using ScriptWidget.Core.Tests.Api;
using ScriptWidget.Core.Tests.Packages;

namespace ScriptWidget.Core.Tests.AI;

public sealed class AiConversationTests(ScriptRuntimeFixture runtime) : IClassFixture<ScriptRuntimeFixture>, IDisposable
{
    private readonly TemporaryFolder temporary = new();
    private DataPaths Paths => new(Path.Combine(temporary.Root, "data"));
    private Library Library => new(Paths);
    private AiConversationStore Store => new(Paths.AiConversations);
    private AiRunner Runner => new(Paths, Library, new SkillStore(Paths.Skills), Store);
    private const string Source = "$render(<vstack><text>Before</text></vstack>);\n";
    private sealed class Scripted(params string[] replies) : IAiChat
    {
        public List<IReadOnlyList<AiMessage>> Calls { get; } = [];
        public Task<AiChatResult> ChatAsync(IReadOnlyList<AiMessage> messages, Action<string>? onText, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            Calls.Add(messages);
            var reply = replies[Math.Min(Calls.Count - 1, replies.Length - 1)];
            onText?.Invoke(reply);
            return Task.FromResult(new AiChatResult(reply, new AiUsage(10, 2, 12)));
        }
    }
    private sealed class Cancelling(CancellationTokenSource cancellation) : IAiChat
    {
        public Task<AiChatResult> ChatAsync(IReadOnlyList<AiMessage> messages, Action<string>? onText, CancellationToken token)
        { cancellation.Cancel(); return Task.FromCanceled<AiChatResult>(token); }
    }
    public void Dispose() => temporary.Dispose();
    private static string Reply(string source, string note = "Made a widget.") => "SUMMARY: " + note + "\n```jsx\n" + source + "\n```";

    [Fact]
    public async Task ARealExecutionIsRequiredAndTheRepairUsesItsDiagnostic()
    {
        var chat = new Scripted(Reply("throw new Error('repair me');"), Reply(Source));
        var conversation = new AiConversation();
        var turn = await Runner.RunAsync(conversation, "A small card.", chat);
        Assert.Equal(AiTurnStatus.Succeeded, turn.Status);
        Assert.Equal(1, turn.Repairs);
        Assert.Equal(2, chat.Calls.Count);
        Assert.Contains("repair me", chat.Calls[1].Last().Content);
        Assert.Equal(24, turn.Usage.TotalTokens);
        Assert.Equal(Source.Trim(), conversation.CurrentVersion!.Source.Trim());
        Assert.Single(Store.List());
        Assert.Equal(AiTurnStatus.Succeeded, Store.Load(conversation.Id)!.Turns.Single().Status);
        Assert.Empty(Directory.GetDirectories(Path.Combine(Paths.Cache, "ai-trials")));
    }

    [Fact]
    public async Task FourFailedAttemptsLeaveTheCurrentVersionUntouched()
    {
        var conversation = new AiConversation();
        var original = conversation.AddVersion(Source);
        var chat = new Scripted(Reply("throw new Error('never succeeds');"));
        var turn = await Runner.RunAsync(conversation, "Change the title.", chat);
        Assert.Equal(AiTurnStatus.Unconverged, turn.Status);
        Assert.Equal(4, chat.Calls.Count);
        Assert.Equal(original.Id, conversation.CurrentVersionId);
        Assert.Single(conversation.Versions);
        Assert.Contains("never succeeds", turn.FailedSource);
        Assert.Equal(4, turn.Repairs);
    }

    [Fact]
    public async Task AnEditChangesOnlyItsUniqueSearchAndCanBeSavedAgain()
    {
        var conversation = new AiConversation();
        conversation.AddVersion(Source);
        var chat = new Scripted("SUMMARY: Changed the title.\n```edit\n<<<<<<< SEARCH\nBefore\n=======\nAfter\n>>>>>>> REPLACE\n```");
        var turn = await Runner.RunAsync(conversation, "Change Before to After.", chat);
        Assert.Equal(AiTurnStatus.Succeeded, turn.Status);
        Assert.Equal(Source.Replace("Before", "After", StringComparison.Ordinal), conversation.CurrentVersion!.Source);
        Assert.Equal("Changed the title.", turn.Note);
        Assert.Equal(2, Store.Load(conversation.Id)!.Versions.Count);
    }

    [Fact]
    public async Task CancellationKeepsThePriorVersion()
    {
        using var cancellation = new CancellationTokenSource();
        var conversation = new AiConversation();
        var original = conversation.AddVersion(Source);
        var turn = await Runner.RunAsync(conversation, "Change it.", new Cancelling(cancellation), cancellation: cancellation.Token);
        Assert.Equal(AiTurnStatus.Cancelled, turn.Status);
        Assert.Equal(original.Id, conversation.CurrentVersionId);
        Assert.Null(turn.ErrorSummary);
    }

    [Fact]
    public void SavedRunningTurnsBecomeInterruptedWithoutInventingAVersion()
    {
        var conversation = new AiConversation();
        var original = conversation.AddVersion(Source);
        conversation.Begin("Still running.");
        Store.Save(conversation);
        var restored = Store.Load(conversation.Id)!;
        Assert.Equal(AiTurnStatus.Interrupted, restored.Turns.Single().Status);
        Assert.Equal(original.Id, restored.CurrentVersionId);
        Assert.False(restored.IsRunning);
    }

    [Fact]
    public void VersionSelectionForkAndRetryKeepTheirOriginalBase()
    {
        var conversation = new AiConversation();
        var first = conversation.AddVersion(Source);
        var failed = conversation.Begin("Failed change.");
        failed.Status = AiTurnStatus.Failed;
        var later = conversation.AddVersion("later");
        Assert.True(conversation.SelectVersion(later.Id));
        Assert.Equal("Failed change.", conversation.RetryRequest(failed.Id));
        Assert.Equal(first.Id, conversation.CurrentVersionId);
        var fork = conversation.Fork();
        Assert.NotEqual(conversation.Id, fork.Id);
        Assert.Equal(Source, fork.CurrentVersion!.Source);
        Assert.Empty(fork.Turns);
        Assert.Single(fork.Versions);
    }

    [Fact]
    public void OldBranchesAreExcludedAndVersionCountIsBounded()
    {
        var conversation = new AiConversation();
        var first = conversation.AddVersion("first");
        var a = conversation.Begin("branch A");
        a.VersionId = conversation.AddVersion("A").Id;
        a.Status = AiTurnStatus.Succeeded;
        Assert.True(conversation.SelectVersion(first.Id));
        var b = conversation.Begin("branch B");
        Assert.True(a.IsAbandoned);
        Assert.Empty(conversation.History);
        b.Status = AiTurnStatus.Failed;
        for (var i = 0; i < 35; i++) conversation.AddVersion(i.ToString(System.Globalization.CultureInfo.InvariantCulture));
        Assert.Equal(30, conversation.Versions.Count);
        Assert.Equal(37, conversation.VersionCounter);
        Assert.NotNull(conversation.CurrentVersion);
    }

    [Fact]
    public void ConversationFilesRefuseTraversalLinksUnknownFieldsAndInvalidUtf8()
    {
        var conversation = new AiConversation();
        conversation.AddVersion(Source);
        Store.Save(conversation);
        Assert.Null(Store.Load("../outside"));
        var file = Path.Combine(Paths.AiConversations, conversation.Id + ".json");
        var json = conversation.ToJson();
        json["apiKey"] = "must never be accepted";
        File.WriteAllText(file, Json.Stringify(json));
        Assert.Null(Store.Load(conversation.Id));
        File.WriteAllBytes(file, [0xff]);
        Assert.Null(Store.Load(conversation.Id));
        File.Delete(file);
        var outside = temporary.NewFile("outside.json", Json.Stringify(conversation.ToJson()));
        Links.Create(file, outside);
        Assert.Null(Store.Load(conversation.Id));
        Store.Save(conversation); // Replaces the link, never its target.
        Assert.Equal(Json.Stringify(conversation.ToJson()), File.ReadAllText(outside));
        Assert.NotNull(Store.Load(conversation.Id));
    }

    [Fact]
    public async Task PresentMalformedManifestsFailBeforeAnAiCall()
    {
        var package = Library.Create("Broken", Source);
        Library.WriteFile(package.Name, "widget.json", Encoding.UTF8.GetBytes("{broken"));
        var conversation = new AiConversation { PackageId = package.Installation };
        conversation.AddVersion(Source);
        var chat = new Scripted(Reply(Source));
        await Assert.ThrowsAsync<AiException>(() => Runner.RunAsync(conversation, "Fix it.", chat));
        Assert.Empty(chat.Calls);
        Assert.Equal("{broken", Library.Find(package.Name)!.Files.ReadText("widget.json"));
    }

    [Fact]
    public void ApplyingPreservesNestedFilesPermissionsAndInstallationIdentity()
    {
        var library = Library;
        var package = library.Create("Existing", Source);
        library.WriteFile(package.Name, "lib/helper.js", Encoding.UTF8.GetBytes("const helper = 1;"));
        library.WriteFile(package.Name, "image/pixel.png", [1, 2, 3]);
        var manifest = Json.ParseObject(package.Files.ReadText("widget.json")!);
        manifest["permissions"] = Json.Array(["storage"]);
        library.WriteFile(package.Name, "widget.json", PackageManifests.Encode(manifest));
        package = library.Find(package.Name)!;
        var conversation = new AiConversation();
        var version = conversation.AddVersion(Source.Replace("Before", "After", StringComparison.Ordinal), ["api.example.com"]);
        Assert.Throws<AiException>(() => AiCandidates.Apply(library, package, version, files => runtime.Compiler.Prepare(files), false));
        Assert.Equal(Source, package.Files.ReadText("main.jsx"));
        var updated = AiCandidates.Apply(library, package, version, files => runtime.Compiler.Prepare(files), true);
        Assert.Equal(package.Installation, updated.Installation);
        Assert.Equal(["storage", "network"], updated.Manifest.OptArray("permissions")!.Select(value => value!.AsText()));
        Assert.Equal(["api.example.com"], updated.Manifest.OptArray("networkDomains")!.Select(value => value!.AsText()));
        Assert.Equal("const helper = 1;", updated.Files.ReadText("lib/helper.js"));
        Assert.Equal(new byte[] { 1, 2, 3 }, updated.Files.ReadBytes("image/pixel.png"));
        Assert.Contains("After", updated.Files.ReadText("main.jsx"));
    }

    [Fact]
    public void ReopenedConversationsKeepDraftsAndDetectManualChanges()
    {
        var conversation = new AiConversation { PackageId = Guid.NewGuid().ToString("D") };
        conversation.AddVersion(Source);
        conversation.RecordAppliedSource(Source);
        var draft = conversation.AddVersion(Source.Replace("Before", "Draft", StringComparison.Ordinal));
        Store.Save(conversation);
        var reopened = Store.Load(conversation.Id)!;
        Assert.False(reopened.ReconcileInstalledSource(Source));
        Assert.Equal(draft.Id, reopened.CurrentVersionId);
        Assert.True(reopened.CanApplyToSource(Source));
        var manual = Source.Replace("Before", "Manual", StringComparison.Ordinal);
        Assert.False(reopened.CanApplyToSource(manual));
        Assert.True(reopened.ReconcileInstalledSource(manual));
        Assert.Equal(manual, reopened.CurrentVersion!.Source);
        Assert.True(reopened.Turns.Single().IsManualEdit);
        Assert.NotNull(reopened.Version(draft.Id));
        Store.Save(reopened);
        var again = Store.Load(conversation.Id)!;
        Assert.False(again.ReconcileInstalledSource(manual));
        Assert.Single(again.Turns);
        Assert.Equal(again.AppliedSourceHash, again.Fork().AppliedSourceHash);
    }

    [Fact]
    public void LegacyConversationsRecognizeAnInstalledVersionWithoutLosingTheDraft()
    {
        var conversation = new AiConversation();
        conversation.AddVersion(Source);
        var draft = conversation.AddVersion("unapplied draft");
        Assert.False(conversation.ToJson().Has("appliedSourceHash"));
        var old = AiConversation.FromJson(Json.Stringify(conversation.ToJson()));
        Assert.False(old.ReconcileInstalledSource(Source));
        Assert.Equal(draft.Id, old.CurrentVersionId);
        Assert.NotNull(old.AppliedSourceHash);
        Assert.Empty(old.Turns);
    }

    [Fact]
    public void AppliedFingerprintSurvivesVersionPruning()
    {
        var conversation = new AiConversation();
        conversation.AddVersion(Source);
        conversation.RecordAppliedSource(Source);
        for (var i = 0; i < 35; i++) conversation.AddVersion("draft " + i);
        Assert.DoesNotContain(conversation.Versions, version => version.Source == Source);
        var selected = conversation.CurrentVersionId;
        Assert.False(conversation.ReconcileInstalledSource(Source));
        Assert.Equal(selected, conversation.CurrentVersionId);
        Assert.Equal(30, conversation.Versions.Count);
    }

    [Fact]
    public async Task RunnerUsesExternalEditsAfterReopeningAndKeepsTheUnappliedDraft()
    {
        var library = Library;
        var package = library.Create("Manual edits", Source);
        var conversation = new AiConversation { PackageId = package.Installation };
        conversation.AddVersion(Source);
        conversation.RecordAppliedSource(Source);
        var draft = conversation.AddVersion(Source.Replace("Before", "Draft", StringComparison.Ordinal));
        Store.Save(conversation);
        var manual = Source.Replace("Before", "Manual", StringComparison.Ordinal);
        library.WriteFile(package.Name, "main.jsx", Encoding.UTF8.GetBytes(manual));
        var reopened = Store.Load(conversation.Id)!;
        var chat = new Scripted(Reply(Source.Replace("Before", "Final", StringComparison.Ordinal)));
        var turn = await Runner.RunAsync(reopened, "Keep the manual title but change its color.", chat);
        Assert.Equal(AiTurnStatus.Succeeded, turn.Status);
        Assert.Contains(manual, chat.Calls.Single()[1].Content);
        Assert.NotNull(reopened.Version(draft.Id));
        Assert.True(reopened.Turns.First().IsManualEdit);
        Assert.Equal(manual, package.Files.ReadText("main.jsx"));
        Assert.True(Store.Load(reopened.Id)!.CanApplyToSource(manual));
    }

    [Theory]
    [InlineData("short")]
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    public void SavedFingerprintsAreStrictLowercaseSha256(string hash)
    {
        var json = new AiConversation().ToJson();
        json["appliedSourceHash"] = hash;
        Assert.Throws<AiException>(() => AiConversation.FromJson(Json.Stringify(json)));
    }

    [Fact]
    public void OutputAndDeclarationsCannotGrantAnythingExceptPublicNetworking()
    {
        var candidate = AiOutput.Extract(Reply(Source) + "\n```json\n{\"permissions\":[\"network\"],\"networkDomains\":[\"api.example.com\"]}\n```");
        Assert.Equal(Source.Trim(), candidate.Source.Trim());
        Assert.Equal(["api.example.com"], AiNetworkDeclaration.Parse(candidate.DeclarationJson!).Domains);
        Assert.Throws<AiException>(() => AiNetworkDeclaration.Parse("{\"permissions\":[\"storage\"]}"));
        Assert.Throws<AiException>(() => AiNetworkDeclaration.Parse("{\"permissions\":[\"network\"],\"networkDomains\":[\"localhost\"]}"));
        Assert.Throws<AiException>(() => AiNetworkDeclaration.Parse("{\"permissions\":[\"network\"],\"networkDomains\":[\"192.168.1.1\"]}"));
        Assert.Throws<AiException>(() => AiNetworkDeclaration.Parse("{\"permissions\":[],\"networkDomains\":[],\"tools\":[\"shell\"]}"));
        var domains = Enumerable.Range(0, 9).Select(index => $"api{index}.example.com");
        Assert.Throws<AiException>(() => AiNetworkDeclaration.Parse(Json.Stringify(new System.Text.Json.Nodes.JsonObject { ["permissions"] = Json.Array(["network"]), ["networkDomains"] = Json.Array(domains) })));
    }
}
