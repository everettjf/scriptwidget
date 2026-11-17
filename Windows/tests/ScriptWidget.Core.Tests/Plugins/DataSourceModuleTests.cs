using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Plugins;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Core.Tests.Api;
using static ScriptWidget.Core.Tests.Plugins.PluginFixtures;

namespace ScriptWidget.Core.Tests.Plugins;

public sealed class DataSourceModuleTests : IDisposable
{
    private readonly string temporary = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", "datasource-" + Guid.NewGuid().ToString("N"));
    private readonly PluginStore store;
    private readonly PluginManifest plugin = Manifest();

    private sealed record Call(string Method, Uri Uri, IReadOnlyDictionary<string, string> Headers, byte[]? Body, int Timeout);

    /// <summary>Offline transport: records each call and answers with <see cref="Respond"/>.</summary>
    private sealed class FakeTransport
    {
        public Func<Call, Func<Uri, bool>, FetchModule.Response> Respond = (_, _) => Response(200, "{\"ok\":true}");
        public List<Call> Calls { get; } = [];

        public FetchModule.Response Perform(string method, Uri uri, IReadOnlyDictionary<string, string> headers, byte[]? body, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation)
        {
            var call = new Call(method, uri, headers, body, timeoutMilliseconds);
            Calls.Add(call);
            return Respond(call, allowRedirect);
        }
    }

    private sealed record Outcome(bool OK, string? Json)
    {
        /// <summary>The decoded rejection message or resolved value.</summary>
        public JsonNode? Value => Json is null ? null : ScriptWidget.Core.Json.Parse(Json);
        public string? Text => Value?.AsText();
    }

    private readonly FakeTransport transport = new();
    private static readonly Action<Action> Direct = work => work();

    public DataSourceModuleTests()
    {
        store = new PluginStore(Path.Combine(temporary, "Plugins"));
        store.Install(new MemoryStream(Bytes()));
    }

    public void Dispose()
    {
        try { Directory.Delete(temporary, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static FetchModule.Response Response(int status, string body) => new(status, Encoding.UTF8.GetBytes(body), new Dictionary<string, string>());

    private static readonly string[] DefaultPlugins = [ID];
    private static readonly string[] DefaultPermissions = ["network"];
    private static readonly string[] DefaultDomains = ["api.example.com"];

    private static JsonObject WidgetManifest(string[]? plugins = null, string[]? permissions = null, string[]? domains = null, bool noPlugins = false, bool noDomains = false)
    {
        var manifest = new JsonObject { ["formatVersion"] = 2, ["permissions"] = Json.Array(permissions ?? DefaultPermissions) };
        if (!noPlugins) manifest["plugins"] = Json.Array(plugins ?? DefaultPlugins);
        if (!noDomains) manifest["networkDomains"] = Json.Array(domains ?? DefaultDomains);
        return manifest;
    }

    private static ExecutionRequest Execution(JsonObject? manifest, bool hasManifest = true, Dictionary<string, string>? environments = null, Dictionary<string, string>? timeline = null) => new()
    {
        Prepared = new PreparedPackage { Code = "", Manifest = manifest, HasManifest = hasManifest, TimelineEnvironment = timeline ?? [] },
        Files = new MemoryPackageFiles(new Dictionary<string, string>()),
        Environments = environments ?? new Dictionary<string, string> { ["widget-size"] = "medium" },
    };

    private static ExecutionRequest Execution() => Execution(WidgetManifest());

    private static JsonObject Payload(string pluginID = ID, string operationID = "status", JsonObject? parameters = null, bool noParameters = false)
    {
        var job = new JsonObject { ["pluginID"] = pluginID, ["operationID"] = operationID };
        if (!noParameters) job["parameters"] = parameters ?? new JsonObject();
        return job;
    }

    private Outcome Run(ExecutionRequest? request = null, JsonObject? payload = null, bool nullPayload = false, DataSourceModule? module = null)
    {
        var outcomes = new List<Outcome>();
        (module ?? new DataSourceModule(store, transport.Perform, Direct)).Start(request ?? Execution(), DataSourceModule.Operation, nullPayload ? null : payload ?? Payload(), (ok, json) => outcomes.Add(new Outcome(ok, json)));
        Assert.Single(outcomes); // done must be called exactly once
        return outcomes[0];
    }

    private void AssertRejected(string expected, Outcome outcome)
    {
        Assert.False(outcome.OK);
        Assert.Equal(expected, outcome.Text);
        Assert.Empty(transport.Calls); // a rejected request must not reach the network
    }

    [Fact]
    public void ExposesTheDataSourceGlobalAndOperation()
    {
        INativeModule module = new DataSourceModule(store, transport.Perform, Direct);
        Assert.Equal(["$dataSource"], module.Apis);
        Assert.True(module.Handles("datasource.request"));
        Assert.False(module.Handles("http.request"));
    }

    [Fact]
    public void ResolvesJsonAndTextResponses()
    {
        transport.Respond = (_, _) => Response(200, "plain text");
        var text = Run();
        Assert.True(text.OK);
        Assert.Equal("plain text", text.Text);
        Assert.Equal("https://api.example.com/status", transport.Calls[0].Uri.AbsoluteUri);
        Assert.Equal("GET", transport.Calls[0].Method);
        Assert.Equal(DataSourceModule.TimeoutMilliseconds, transport.Calls[0].Timeout);

        transport.Respond = (_, _) => Response(200, "{\"name\":\"Ada\",\"tags\":[1,2]}");
        var parameters = new JsonObject { ["user"] = "ada l", ["X-Token"] = "t", ["enabled"] = true, ["undeclared"] = "x" };
        var json = Run(payload: Payload(operationID: "update", parameters: parameters));
        Assert.True(json.OK);
        Assert.Equal("Ada", ((JsonObject)json.Value!).OptString("name"));
        var call = transport.Calls[1];
        Assert.Equal("https://api.example.com/users/ada%20l?page=1", call.Uri.AbsoluteUri);
        Assert.Equal("POST", call.Method);
        Assert.Equal("t", call.Headers["X-Token"]);
        Assert.Equal("{\"enabled\":true}", Encoding.UTF8.GetString(call.Body!));
    }

    [Fact]
    public void BuiltInPluginsWorkWhenDeclared()
    {
        const string id = "app.scriptwidget.datasource.github";
        var outcome = Run(Execution(WidgetManifest(plugins: [id], domains: ["api.github.com"])), Payload(id, "repository", noParameters: true));
        Assert.True(outcome.OK);
        Assert.Equal("https://api.github.com/repos/everettjf/scriptwidget", transport.Calls[0].Uri.AbsoluteUri);
    }

    [Fact]
    public void UndeclaredPluginIsRejected()
    {
        var message = $"Plugin {ID} is not declared in widget.json";
        AssertRejected(message, Run(Execution(WidgetManifest(plugins: ["dev.scriptwidget.other"]))));
        AssertRejected(message, Run(Execution(WidgetManifest(noPlugins: true))));
        AssertRejected(message, Run(Execution(WidgetManifest(plugins: []))));
        // A legacy package has no manifest and therefore declares nothing, even if stale manifest data is present.
        AssertRejected(message, Run(Execution(manifest: null, hasManifest: false)));
        AssertRejected(message, Run(Execution(manifest: WidgetManifest(), hasManifest: false)));
        // Installing a plugin grants nothing: the built-in is installed but not declared.
        AssertRejected("Plugin app.scriptwidget.datasource.github is not declared in widget.json", Run(payload: Payload("app.scriptwidget.datasource.github", "repository")));
    }

    [Fact]
    public void MissingNetworkPermissionIsRejected()
    {
        AssertRejected("Plugin requests require the network permission", Run(Execution(WidgetManifest(permissions: []))));
        AssertRejected("Plugin requests require the network permission", Run(Execution(WidgetManifest(permissions: ["location"]))));
    }

    [Fact]
    public void HostMissingFromNetworkDomainsIsRejected()
    {
        const string message = "Data source host is not declared in widget.json networkDomains.";
        AssertRejected(message, Run(Execution(WidgetManifest(domains: ["other.example.com"]))));
        AssertRejected(message, Run(Execution(WidgetManifest(domains: []))));
        AssertRejected(message, Run(Execution(WidgetManifest(noDomains: true))));
        AssertRejected(message, Run(Execution(WidgetManifest(domains: ["*.api.example.com"]))));
        Assert.True(Run(Execution(WidgetManifest(domains: ["*.example.com"]))).OK);
    }

    [Fact]
    public void HostMissingFromPluginHostsIsRejected()
    {
        var request = Execution(WidgetManifest(domains: ["api.example.com", "evil.example.net"]));
        Assert.Equal("Plugin request escaped its declared hosts.", DataSourcePolicy.DestinationError(request, plugin, new Uri("https://evil.example.net/status")));
        Assert.Null(DataSourcePolicy.DestinationError(request, plugin, new Uri("https://api.example.com/status")));
        // The package allows the host, the plugin does not declare it: a tampered manifest is still refused.
        Assert.Equal("Plugin request escaped its declared hosts.", Failure(() => DataSourceRequestBuilder.Prepare(plugin with { BaseURL = "https://evil.example.net" }, "status", Values())).Message);
    }

    [Fact]
    public void HttpAndPrivateDestinationsAreRejected()
    {
        var request = Execution(WidgetManifest(domains: ["api.example.com", "localhost", "10.0.0.1"]));
        Assert.Equal("Data source requests require HTTPS", DataSourcePolicy.DestinationError(request, plugin, new Uri("http://api.example.com/status")));
        Assert.Equal("Data source requests require HTTPS", DataSourcePolicy.DestinationError(request, plugin, new Uri("ftp://api.example.com/status")));
        Assert.Equal("Data source requests require HTTPS", DataSourcePolicy.DestinationError(request, plugin, new Uri("/status", UriKind.Relative)));
        Assert.Equal("URL credentials are not allowed", DataSourcePolicy.DestinationError(request, plugin, new Uri("https://user:pw@api.example.com/status")));
        var local = plugin with { Hosts = ["api.example.com", "localhost", "10.0.0.1"] };
        Assert.Equal("Local and private network hosts are not allowed", DataSourcePolicy.DestinationError(request, local, new Uri("https://localhost/status")));
        Assert.Equal("Local and private network hosts are not allowed", DataSourcePolicy.DestinationError(request, local, new Uri("https://10.0.0.1/status")));
        // "URL host is required" on Android: System.Uri cannot hold an HTTPS URL without a host at all.
        Assert.False(Uri.TryCreate("https:///status", UriKind.Absolute, out _));
    }

    [Fact]
    public void TimelineProjectionsAndLiveActivitiesAreRejected()
    {
        const string timeline = "[timeline_read_only] Future entries cannot make live service requests";
        AssertRejected(timeline, Run(Execution(WidgetManifest(), environments: new() { ["widget-size"] = "medium", ["timeline-is-projection"] = "true" })));
        AssertRejected(timeline, Run(Execution(WidgetManifest(), timeline: new() { ["timeline-is-projection"] = "true" })));
        const string live = "[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app";
        AssertRejected(live, Run(Execution(WidgetManifest(), environments: new() { ["widget-size"] = "live-activity" })));
        AssertRejected(live, Run(Execution(WidgetManifest(), environments: new() { ["widget-size"] = "dynamic-island" })));
        Assert.True(Run(Execution(WidgetManifest(), environments: new() { ["widget-size"] = "medium", ["timeline-is-projection"] = "false" })).OK);
    }

    [Fact]
    public void FinishedExecutionIsRejected()
    {
        var request = Execution();
        request.Session.Finished = true;
        AssertRejected("Execution session is no longer active", Run(request));
    }

    [Fact]
    public void RequestBudgetIsSharedWithFetch()
    {
        var request = Execution();
        for (var index = 0; index < FetchModule.MaximumRequests; index++) Assert.True(Run(request).OK);
        var outcome = Run(request);
        Assert.False(outcome.OK);
        Assert.Equal("Network request budget exceeded", outcome.Text);
        Assert.Equal(FetchModule.MaximumRequests, transport.Calls.Count);

        // Requests made by fetch count against the same budget.
        var shared = Execution();
        for (var index = 0; index < FetchModule.MaximumRequests; index++) shared.Session.AddNetworkRequest();
        Assert.Equal("Network request budget exceeded", Run(shared).Text);
        Assert.Equal(FetchModule.MaximumRequests, transport.Calls.Count);
    }

    [Fact]
    public void RejectedRequestsDoNotConsumeTheBudget()
    {
        var request = Execution();
        Run(request, Payload(operationID: "missing"));
        Run(request, Payload(operationID: "update"));
        Run(request, Payload(pluginID: "dev.scriptwidget.other"));
        Assert.Equal(0, request.Session.NetworkRequests);
    }

    [Fact]
    public void RedirectsAreRestrictedToDeclaredHttpsHosts()
    {
        var request = Execution(WidgetManifest(domains: ["*.example.com", "evil.example.net"]));
        var decisions = new Dictionary<string, bool>();
        transport.Respond = (_, allowRedirect) =>
        {
            foreach (var target in new[] { "https://api.example.com/moved", "https://evil.example.net/x", "https://cdn.example.com/x", "http://api.example.com/moved", "https://localhost/x", "https://user@api.example.com/x" })
            {
                decisions[target] = allowRedirect(new Uri(target));
            }
            if (!allowRedirect(new Uri("https://evil.example.net/x"))) throw new FetchModule.FetchException("Redirect target is not allowed");
            return Response(200, "{}");
        };
        var outcome = Run(request);
        Assert.False(outcome.OK);
        Assert.Equal("Redirect target is not allowed", outcome.Text);
        Assert.Equal(new Dictionary<string, bool>
        {
            ["https://api.example.com/moved"] = true,
            ["https://evil.example.net/x"] = false,   // allowed by the package, not declared by the plugin
            ["https://cdn.example.com/x"] = false,    // allowed by the package wildcard, not declared by the plugin
            ["http://api.example.com/moved"] = false, // downgrade
            ["https://localhost/x"] = false,
            ["https://user@api.example.com/x"] = false,
        }, decisions);

        // A host the plugin declares but the package does not allow is refused as well.
        var wide = plugin with { Hosts = ["api.example.com", "cdn.example.org"] };
        var narrow = Execution(WidgetManifest(domains: ["api.example.com"]));
        Assert.False(DataSourcePolicy.AllowsRedirect(narrow, wide, new Uri("https://cdn.example.org/x")));
        Assert.True(DataSourcePolicy.AllowsRedirect(narrow, wide, new Uri("https://api.example.com/x")));
        narrow.Session.Finished = true;
        Assert.False(DataSourcePolicy.AllowsRedirect(narrow, wide, new Uri("https://api.example.com/x")));
    }

    [Fact]
    public void UninstalledPluginAndBadRequestsAreRejected()
    {
        const string other = "dev.scriptwidget.other";
        AssertRejected($"Plugin {other} is not installed", Run(Execution(WidgetManifest(plugins: [other])), Payload(other)));
        AssertRejected($"Operation missing was not found in {ID}.", Run(payload: Payload(operationID: "missing")));
        AssertRejected("Missing required parameter user.", Run(payload: Payload(operationID: "update")));
        AssertRejected("Data source requests need a plugin id and an operation id", Run(payload: new JsonObject { ["pluginID"] = 7, ["operationID"] = "status" }));
        AssertRejected("Data source requests need a plugin id and an operation id", Run(nullPayload: true));
        var outcomes = new List<string?>();
        new DataSourceModule(store, transport.Perform, Direct).Start(Execution(), "datasource.other", Payload(), (_, json) => outcomes.Add(json));
        Assert.Equal(["\"Unsupported operation datasource.other\""], outcomes);
    }

    [Fact]
    public void ResponseFailuresUseTheSwiftMessages()
    {
        transport.Respond = (_, _) => Response(500, "{\"secret\":\"body\"}");
        Assert.Equal("Data source request failed", Run().Text);
        transport.Respond = (_, _) => new FetchModule.Response(200, [0xFF], new Dictionary<string, string>());
        Assert.Equal("Data source returned non-UTF-8 text", Run().Text);
        transport.Respond = (_, _) => Response(200, "<html>");
        Assert.Equal("Data source returned invalid JSON", Run(payload: Payload(operationID: "update", parameters: new JsonObject { ["user"] = "u", ["X-Token"] = "t", ["enabled"] = 1 })).Text);
        transport.Respond = (_, _) => new FetchModule.Response(200, new byte[FetchModule.MaximumResponseBytes + 1], new Dictionary<string, string>());
        Assert.Equal("Data source response exceeds 2 MiB.", Run().Text);
        transport.Respond = (_, _) => throw new FetchModule.FetchException("Local and private network hosts are not allowed");
        Assert.Equal("Local and private network hosts are not allowed", Run().Text);
        // Unexpected exception text may quote the URL and its parameter values; it is not forwarded.
        transport.Respond = (call, _) => throw new IOException($"failed to connect to {call.Uri}?token=secret");
        Assert.Equal("Data source request failed", Run().Text);
    }

    [Fact]
    public void ResultsAreDroppedAfterTheExecutionEnds()
    {
        var request = Execution();
        transport.Respond = (_, _) => { request.Session.Finished = true; return Response(200, "ok"); };
        var outcomes = new List<bool>();
        new DataSourceModule(store, transport.Perform, Direct).Start(request, DataSourceModule.Operation, Payload(), (ok, _) => outcomes.Add(ok));
        Assert.Empty(outcomes);
    }

    /// <summary>
    /// Windows only: the same rules over the real <c>fetch</c> transport, with the HTTP exchange and the
    /// resolver replaced. A plugin request never leaves HTTPS, its declared hosts or public addresses.
    /// </summary>
    [Fact]
    public void TheFetchTransportKeepsPluginRequestsOnDeclaredPublicHttpsHosts()
    {
        var location = "https://api.example.com/moved";
        var handler = new FakeHandler(message => message.RequestUri!.AbsolutePath == "/status" ? FakeHandler.Redirect(302, location) : FakeHandler.Text(200, "moved"));
        var addresses = new Dictionary<string, IPAddress> { ["api.example.com"] = IPAddress.Parse("93.184.216.34") };
        var fetch = new FetchModule(host => addresses.TryGetValue(host, out var address) ? [address] : throw new IOException("unknown host"), handler);
        DataSourceModule Module() => new(store, fetch.Perform, Direct);

        var followed = Run(module: Module());
        Assert.True(followed.OK);
        Assert.Equal("moved", followed.Text);
        Assert.Equal(["https://api.example.com/status", "https://api.example.com/moved"], handler.Requests.Select(item => item.Uri.AbsoluteUri));
        Assert.Equal("ScriptWidget-DataSource/1", handler.Requests[0].Headers["User-Agent"]);

        foreach (var target in new[] { "http://api.example.com/moved", "https://evil.example.net/x", "https://cdn.example.com/x", "https://127.0.0.1/x", "https://user:pw@api.example.com/x", "file:///c:/windows/win.ini" })
        {
            handler.Requests.Clear();
            location = target;
            var refused = Run(Execution(WidgetManifest(domains: ["*.example.com", "evil.example.net", "127.0.0.1"])), module: Module());
            Assert.False(refused.OK);
            Assert.Equal("Redirect target is not allowed", refused.Text);
            Assert.Single(handler.Requests);
        }

        // The declared host itself resolving to a private address is refused before anything is sent.
        handler.Requests.Clear();
        addresses["api.example.com"] = IPAddress.Parse("10.0.0.7");
        var rebound = Run(module: Module());
        Assert.Equal("Local and private network hosts are not allowed", rebound.Text);
        Assert.Empty(handler.Requests);
    }
}
