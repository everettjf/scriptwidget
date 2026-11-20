using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Tests.Api;
using ScriptWidget.Core.Tests.Packages;

namespace ScriptWidget.Core.Tests.AI;

public sealed class AiCoreTests
{
    private static AiProfile Profile => AiProfile.Create(AiProvider.Compatible) with { BaseUrl = "https://api.example.com/v1/", Model = "test-model" };
    private static readonly AiApiKey Key = new("synthetic-test-key");
    private static readonly AiMessage[] Messages = [new("system", "Rules."), new("user", "A clock.")];
    private const string Plain = """{"choices":[{"message":{"content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}""";
    private static string Event(string content) => "data: " + Json.Stringify(new JsonObject { ["choices"] = new JsonArray(new JsonObject { ["delta"] = new JsonObject { ["content"] = content } }) }) + "\n\n";

    [Fact]
    public void ProfilesRoundTripWithoutKeysAndRejectUnknownData()
    {
        using var temporary = new TemporaryFolder();
        var file = Path.Combine(temporary.Root, "profiles.json");
        var store = new AiProfileStore(file);
        var profile = Profile;
        store.Save(new AiProfileSettings([profile], profile.Id));
        Assert.Equal("https://api.example.com", store.Load().Active!.NormalizedBaseUrl);
        Assert.Equal("test-model", store.Load().Active!.Model);
        Assert.DoesNotContain("synthetic-test-key", File.ReadAllText(file));
        Assert.DoesNotContain("key", Key.ToString().Replace("API key", "", StringComparison.Ordinal), StringComparison.OrdinalIgnoreCase);
        var json = Json.ParseObject(File.ReadAllText(file));
        json["extra"] = true;
        File.WriteAllText(file, Json.Stringify(json));
        Assert.Empty(store.Load().Profiles);
    }

    [Theory]
    [InlineData("http://api.example.com")]
    [InlineData("https://user:password@api.example.com")]
    [InlineData("https://api.example.com/?key=secret")]
    [InlineData("https://api.example.com/#secret")]
    [InlineData("https://api.example.com/../other")]
    [InlineData("https://api.example.com/%2e%2e/other")]
    [InlineData("https://api.example.com/v1/chat/completions")]
    [InlineData("https://api.example.com\\path")]
    public void ProfilesRejectUnsafeOrWrongEndpointForms(string url) => Assert.NotNull((Profile with { BaseUrl = url }).ValidationError());

    [Theory]
    [InlineData("")]
    [InlineData("key\r\nX-Injected: yes")]
    [InlineData("non-ascii-密钥")]
    public void KeysRejectHeaderInjectionAndInvalidValues(string value) => Assert.Throws<AiException>(() => new AiApiKey(value));

    [Fact]
    public void WindowsCredentialLockerRoundTripsATestCredential()
    {
        var profile = Profile;
        var credentials = new WindowsAiCredentials("ScriptWidget.Tests." + Guid.NewGuid().ToString("N"));
        try
        {
            Assert.Null(credentials.Get(profile.Id));
            credentials.Set(profile.Id, Key);
            Assert.Equal(Key.Secret, credentials.Get(profile.Id)!.Secret);
            credentials.Remove(profile.Id);
            Assert.Null(credentials.Get(profile.Id));
        }
        finally { credentials.Remove(profile.Id); }
    }

    [Fact]
    public void RequestFormatsKeepSystemMessagesAndAuthenticationSeparate()
    {
        using var openai = AiClient.BuildRequest(Profile, Key, Messages, true);
        Assert.Equal("https://api.example.com/v1/chat/completions", openai.RequestUri!.AbsoluteUri);
        Assert.Equal("Bearer synthetic-test-key", openai.Headers.GetValues("Authorization").Single());
        using var anthropic = AiClient.BuildRequest(Profile with { Provider = AiProvider.Anthropic }, Key, Messages, true);
        Assert.Equal("https://api.example.com/v1/messages", anthropic.RequestUri!.AbsoluteUri);
        Assert.False(anthropic.Headers.Contains("Authorization"));
        Assert.Equal(Key.Secret, anthropic.Headers.GetValues("x-api-key").Single());
    }

    [Fact]
    public async Task ParsesPlainRepliesAndScrubsAnEchoedCredential()
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, Plain.Replace("hello", Key.Secret, StringComparison.Ordinal), "application/json"));
        using var client = new AiClient(handler);
        var result = await client.ChatAsync(Profile, Key, Messages);
        Assert.Equal("[redacted]", result.Content);
        Assert.Equal(new AiUsage(10, 3, 13), result.Usage);
        Assert.DoesNotContain(Key.Secret, Encoding.UTF8.GetString(handler.Requests.Single().Body!));
    }

    [Fact]
    public async Task StreamsUnicodeUsageAndTerminalEvents()
    {
        var stream = Event("Hello ") + Event("世界 🌤️") + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4,\"total_tokens\":14}}\n\ndata: [DONE]\n\n";
        using var client = new AiClient(new FakeHandler(_ => FakeHandler.Text(200, stream, "text/event-stream")));
        var partials = new List<string>();
        var result = await client.ChatAsync(Profile, Key, Messages, partials.Add);
        Assert.Equal("Hello 世界 🌤️", result.Content);
        Assert.Equal(result.Content, partials[^1]);
        Assert.Equal(14, result.Usage.TotalTokens);
    }

    [Fact]
    public void StreamReaderHandlesByteBoundariesAndMultilineEvents()
    {
        var partials = new List<string>();
        var reader = new AiStreamReader(false, partials.Add);
        var source = "data: {\n" + "data: \"choices\":[{\"delta\":{\"content\":\"🌤️\"},\"finish_reason\":\"stop\"}]}\r\n\r\n";
        foreach (var value in Encoding.UTF8.GetBytes(source)) reader.Feed([value]);
        reader.Finish();
        Assert.Equal("🌤️", reader.Content);
        Assert.True(reader.Terminal);
    }

    [Fact]
    public void AnthropicStreamsIgnoreThinkingAndTrackCachedTokens()
    {
        var reader = new AiStreamReader(true, _ => { });
        var stream = """
            data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20}}}

            data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private reasoning"}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"widget"}}

            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":5}}

            """;
        reader.Feed(Encoding.UTF8.GetBytes(stream));
        reader.Finish();
        Assert.Equal("widget", reader.Content);
        Assert.Equal(new AiUsage(30, 5, 35), reader.Usage);
        Assert.True(reader.Truncated);
    }

    [Theory]
    [InlineData(301)]
    [InlineData(302)]
    [InlineData(307)]
    [InlineData(308)]
    public async Task CredentialsNeverFollowRedirectsOrTriggerFallback(int status)
    {
        var handler = new FakeHandler(_ => FakeHandler.Redirect(status, "https://another.example.com/steal"));
        using var client = new AiClient(handler);
        var error = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync(Profile, Key, Messages, _ => { }));
        Assert.Equal("redirect_refused", error.Code);
        Assert.Single(handler.Requests);
        Assert.DoesNotContain(Key.Secret, error.Message);
    }

    [Fact]
    public async Task OnlyAConnectionFailureBeforeTextFallsBackToPlainChat()
    {
        var attempts = 0;
        var handler = new FakeHandler((_, _) => ++attempts == 1 ? Task.FromException<HttpResponseMessage>(new IOException("connection lost")) : Task.FromResult(FakeHandler.Text(200, Plain, "application/json")));
        using var client = new AiClient(handler);
        var partials = new List<string>();
        var result = await client.ChatAsync(Profile, Key, Messages, partials.Add);
        Assert.Equal("hello", result.Content);
        Assert.Equal("hello", partials[^1]);
        Assert.Equal(2, attempts);
        Assert.True(Json.ParseObject(Encoding.UTF8.GetString(handler.Requests[0].Body!)).OptBoolean("stream"));
        Assert.False(Json.ParseObject(Encoding.UTF8.GetString(handler.Requests[1].Body!)).OptBoolean("stream"));
    }

    [Fact]
    public async Task IncompleteStreamsAreNotAcceptedOrRetried()
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, Event("partial"), "text/event-stream"));
        using var client = new AiClient(handler);
        var error = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync(Profile, Key, Messages, _ => { }));
        Assert.Equal("network", error.Code);
        Assert.Single(handler.Requests);
    }

    [Theory]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(429)]
    public async Task AuthenticationAndRateErrorsNeverDiscloseBodiesOrRetry(int status)
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(status, "{" + Key.Secret + " provider private data}"));
        using var client = new AiClient(handler);
        var error = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync(Profile, Key, Messages, _ => { }));
        Assert.Single(handler.Requests);
        Assert.DoesNotContain(Key.Secret, error.Message);
        Assert.DoesNotContain("provider private", error.Message);
    }

    [Fact]
    public async Task OversizedRepliesAndCancellationAreBounded()
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, new string('x', AiClient.MaximumResponseBytes + 1)));
        using var client = new AiClient(handler);
        Assert.Equal("response_too_large", (await Assert.ThrowsAsync<AiException>(() => client.ChatAsync(Profile, Key, Messages))).Code);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.ChatAsync(Profile, Key, Messages, cancellation: cancellation.Token));
    }

    [Fact]
    public void EditBlocksAreAtomicAndRequireUniqueExactSearches()
    {
        const string reply = "<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE";
        var edits = AiSourceEdits.Parse(reply)!;
        Assert.Equal("new\n", AiSourceEdits.Apply(edits, "old\r\n"));
        Assert.Throws<AiException>(() => AiSourceEdits.Apply(edits, "old old"));
        Assert.Throws<AiException>(() => AiSourceEdits.Apply(edits, "missing"));
        Assert.Throws<AiException>(() => AiSourceEdits.Parse("<<<<<<< SEARCH\nold\n=======\nnew"));
        Assert.Throws<AiException>(() => AiSourceEdits.Parse("<<<<<<< SEARCH\n \n=======\nnew\n>>>>>>> REPLACE"));
        Assert.Null(AiSourceEdits.Parse("plain source"));
    }

    [Theory]
    [InlineData("max", true)]
    [InlineData("max,leading", true)]
    [InlineData("48,max,leading", true)]
    [InlineData("max,40", true)]
    [InlineData("60,40,trailing", true)]
    [InlineData("max,auto", false)]
    [InlineData("48,leading", false)]
    [InlineData("60, 40", false)]
    [InlineData("Infinity,40", false)]
    public void FrameCheckMatchesTheSharedRuntime(string frame, bool valid) => Assert.Equal(valid, AiJsxCheck.FrameIsRead(frame));

    [Fact]
    public void JsxChecksIgnoreCommentsStringsAndUserComponents()
    {
        Assert.Empty(AiJsxCheck.Problems("// <fake/>\nconst s = '<fake/>'; const text = ` <fake/>`; $render(<Mine><text>OK</text></Mine>);"));
        Assert.NotEmpty(AiJsxCheck.Problems("$render(<vstack><notATag /></vstack>);"));
        Assert.Contains(AiJsxCheck.Problems("$render(<text frame='max,auto' imaginary='yes'>Hello</text>);"), problem => problem.Contains("frame", StringComparison.Ordinal));
        Assert.Contains(AiJsxCheck.Problems("$render(<text><date /></text>);"), problem => problem.Contains("takes no tags", StringComparison.Ordinal));
        Assert.Empty(AiJsxCheck.Problems("const b = a < c; $render(<text>{b}</text>);"));
    }

    [Fact]
    public void DiffComparesAdjacentSourcesAndHasBounds()
    {
        var lines = AiSourceDiff.Lines("one\ntwo\n", "one\nthree\n")!;
        Assert.Contains(lines, line => line.Kind == AiDiffKind.Removed && line.Text == "two");
        Assert.Contains(lines, line => line.Kind == AiDiffKind.Added && line.Text == "three");
        Assert.Null(AiSourceDiff.Lines(string.Join('\n', Enumerable.Repeat("old", 5000)), "new"));
    }
}
