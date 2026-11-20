using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Skills;
using ScriptWidget.Core.Tests.Api;
using ScriptWidget.Core.Tests.Packages;

namespace ScriptWidget.Core.Tests.AI;

public sealed class AiLocalTests
{
    private static readonly AiMessage[] Messages = [new("user", "A local widget.")];
    private static AiProfile Local => AiProfile.Create(AiProvider.Ollama) with { Model = "test-local-model" };

    [Theory]
    [InlineData(AiProvider.Ollama, "http://localhost:11434")]
    [InlineData(AiProvider.LmStudio, "http://localhost:1234")]
    public void LocalPresetsPersistBeforeChoosingAModel(AiProvider provider, string address)
    {
        using var folder = new TemporaryFolder();
        var profile = AiProfile.Create(provider);
        Assert.Equal(address, profile.BaseUrl);
        Assert.Null(profile.ValidationError(requireModel: false));
        Assert.NotNull(profile.ValidationError());
        var store = new AiProfileStore(Path.Combine(folder.Root, "profiles.json"));
        store.Save(new([profile], profile.Id));
        Assert.Equal(profile, store.Load().Active);
    }

    [Theory]
    [InlineData("http://localhost:1234/v1/")]
    [InlineData("http://127.0.0.1:11434")]
    [InlineData("http://[::1]:1234")]
    [InlineData("https://localhost:1234")]
    public void LoopbackAllowsOptionalAuthentication(string address)
    {
        var profile = Local with { BaseUrl = address };
        Assert.Null(profile.ValidationError());
        using var request = AiClient.BuildRequest(profile, null, Messages, true);
        Assert.False(request.Headers.Contains("Authorization"));
        Assert.EndsWith("/v1/chat/completions", request.RequestUri!.AbsoluteUri);
    }

    [Theory]
    [InlineData("http://192.168.1.5:1234")]
    [InlineData("http://0.0.0.0:1234")]
    [InlineData("http://api.example.com")]
    [InlineData("http://localhost.example.com:1234")]
    [InlineData("http://localhost.:1234")]
    [InlineData("http://[::ffff:192.168.1.2]:1234")]
    [InlineData("http://localhost:1234?api-key=secret")]
    [InlineData("http://localhost:1234/#fragment")]
    [InlineData("http://user:secret@localhost:1234")]
    [InlineData("http://local%68ost:1234")]
    public void PlainHttpDoesNotExtendToOtherHostsOrUnsafeUrls(string address)
    {
        var profile = Local with { BaseUrl = address, Provider = AiProvider.Compatible };
        Assert.NotNull(profile.ValidationError());
        Assert.Throws<AiException>(() => AiClient.BuildRequest(profile, null, Messages, false));
    }

    [Fact]
    public void RemoteEndpointsStillNeedAKeyAndLocalPresetsCannotBecomeRemote()
    {
        var remote = Local with { Provider = AiProvider.Compatible, BaseUrl = "https://api.example.com" };
        Assert.Equal("missing_api_key", Assert.Throws<AiException>(() => AiClient.BuildRequest(remote, null, Messages, false)).Code);
        Assert.NotNull((remote with { Provider = AiProvider.Ollama }).ValidationError());
        using var request = AiClient.BuildRequest(Local, new AiApiKey("synthetic-local-token"), Messages, false);
        Assert.Equal("Bearer synthetic-local-token", request.Headers.Authorization!.ToString());
    }

    [Theory]
    [InlineData("localhost", false)]
    [InlineData("127.0.0.1", true)]
    [InlineData("[::1]", false)]
    public async Task ActualLoopbackSocketsListModelsWithoutAKeyOrModel(string host, bool withToken)
    {
        using var server = new LocalServer(host == "[::1]" ? IPAddress.IPv6Loopback : IPAddress.Loopback);
        var served = server.ReplyAsync("application/json", """{"data":[{"id":"local-chat"},{"id":"local-chat"}]}""");
        using var client = new AiClient();
        var profile = Local with { BaseUrl = $"http://{host}:{server.Port}/v1", Model = "" };
        var models = await client.ListModelsAsync(profile, withToken ? new AiApiKey("local-test-token") : null);
        var request = await served;
        Assert.Equal("local-chat", Assert.Single(models));
        Assert.StartsWith("GET /v1/models HTTP/1.1", request.Headers);
        Assert.Equal(withToken, request.Headers.Contains("Authorization: Bearer local-test-token", StringComparison.OrdinalIgnoreCase));
        if (!withToken) Assert.DoesNotContain("Authorization:", request.Headers, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task LocalStreamingFeedsTheRealRunnerAndNativeValidation()
    {
        using var server = new LocalServer(IPAddress.Loopback);
        var reply = "SUMMARY: Local card.\n```jsx\n$render(<vstack><text>Local only</text></vstack>);\n```";
        var payload = new JsonObject { ["choices"] = new JsonArray(new JsonObject { ["delta"] = new JsonObject { ["content"] = reply }, ["finish_reason"] = "stop" }) };
        var served = server.ReplyAsync("text/event-stream", "data: " + Json.Stringify(payload) + "\n\ndata: [DONE]\n\n");
        using var client = new AiClient();
        using var folder = new TemporaryFolder();
        var paths = new DataPaths(folder.Root);
        var store = new AiConversationStore(paths.AiConversations);
        var conversation = new AiConversation();
        var progress = new List<AiProgress>();
        var profile = Local with { BaseUrl = $"http://localhost:{server.Port}" };
        var turn = await new AiRunner(paths, new Library(paths), new SkillStore(paths.Skills), store)
            .RunAsync(conversation, "A local card.", client.Bind(profile, null), progress.Add);
        Assert.Equal(AiTurnStatus.Succeeded, turn.Status);
        Assert.Contains("Local only", store.Load(conversation.Id)!.CurrentVersion!.Source);
        Assert.Contains(progress, item => item.State == "partial");
        var request = await served;
        Assert.StartsWith("POST /v1/chat/completions HTTP/1.1", request.Headers);
        Assert.DoesNotContain("Authorization:", request.Headers, StringComparison.OrdinalIgnoreCase);
        Assert.True(Json.ParseObject(request.Body).OptBoolean("stream"));
    }

    [Fact]
    public async Task CancellingAnActualLocalRequestStopsTheWait()
    {
        using var server = new LocalServer(IPAddress.Loopback);
        using var cancellation = new CancellationTokenSource();
        var accepted = server.AcceptAsync();
        using var client = new AiClient();
        var pending = client.ChatAsync(Local with { BaseUrl = $"http://127.0.0.1:{server.Port}" }, null, Messages, cancellation: cancellation.Token);
        using var connection = await accepted;
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Theory]
    [InlineData(302, "redirect_refused")]
    [InlineData(401, "http")]
    public async Task LocalRedirectsAndAuthErrorsNeverFallBackOrLeaveLoopback(int status, string code)
    {
        var handler = new FakeHandler(_ => status == 302 ? FakeHandler.Redirect(302, "https://external.example.com") : FakeHandler.Text(401, "private server error"));
        using var client = new AiClient(handler);
        var error = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync(Local, null, Messages, _ => { }));
        Assert.Equal(code, error.Code);
        Assert.Single(handler.Requests);
        Assert.DoesNotContain("private server error", error.Message);
    }

    private sealed class LocalServer : IDisposable
    {
        private readonly TcpListener listener;
        private readonly CancellationTokenSource lifetime = new(TimeSpan.FromSeconds(20));
        public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
        public LocalServer(IPAddress address) { listener = new(address, 0); listener.Start(); }
        public ValueTask<TcpClient> AcceptAsync() => listener.AcceptTcpClientAsync(lifetime.Token);
        public async Task<(string Headers, string Body)> ReplyAsync(string contentType, string body)
        {
            using var connection = await AcceptAsync();
            await using var stream = connection.GetStream();
            var header = new List<byte>();
            var one = new byte[1];
            while (header.Count < 65536)
            {
                await stream.ReadExactlyAsync(one, lifetime.Token);
                header.Add(one[0]);
                if (header.Count >= 4 && header.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
            }
            var headers = Encoding.ASCII.GetString(header.ToArray());
            var size = headers.Split("\r\n").FirstOrDefault(line => line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))?.Split(':')[1].Trim();
            var requestBody = new byte[size is null ? 0 : int.Parse(size, System.Globalization.CultureInfo.InvariantCulture)];
            await stream.ReadExactlyAsync(requestBody, lifetime.Token);
            var payload = Encoding.UTF8.GetBytes(body);
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: {contentType}\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n"), lifetime.Token);
            await stream.WriteAsync(payload, lifetime.Token);
            return (headers, Encoding.UTF8.GetString(requestBody));
        }
        public void Dispose() { lifetime.Cancel(); listener.Stop(); lifetime.Dispose(); }
    }
}
