using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Tests.Api;

/// <summary>The JavaScript runtime shared by the tests that run <c>fetch</c> from a script.</summary>
public sealed class ScriptRuntimeFixture : IDisposable
{
    public SharedScripts Scripts { get; }
    public PackageCompiler Compiler { get; }
    public ScriptExecutor Executor { get; }

    public ScriptRuntimeFixture()
    {
        Scripts = new SharedScripts();
        Compiler = new PackageCompiler(Scripts);
        Executor = new ScriptExecutor(Scripts);
    }

    public void Dispose() => Compiler.Dispose();
}

public sealed class FetchModuleTests(ScriptRuntimeFixture runtime) : IClassFixture<ScriptRuntimeFixture>
{
    private const string Blocked = "Local and private network hosts are not allowed";
    private static readonly IPAddress Public = IPAddress.Parse("93.184.216.34");
    private static readonly Func<Uri, bool> AnyRedirect = _ => true;
    private static readonly Dictionary<string, string> NoHeaders = [];

    private static IReadOnlyList<IPAddress> PublicResolver(string host) => [Public];

    private static FetchModule Offline(Func<HttpRequestMessage, HttpResponseMessage>? respond = null) =>
        new(PublicResolver, new FakeHandler(respond ?? (_ => FakeHandler.Text(200, "ok"))));

    // MARK: - From a script (NativeApiTest on Android)

    private static string Manifest(string permissions, string domains = "[]") =>
        $$"""{"entry":"main.jsx","formatVersion":2,"id":"com.example.test","name":"Test","networkDomains":{{domains}},"permissions":{{permissions}},"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"}""";

    /// <summary>Runs a script whose result is the text of the rendered &lt;text&gt;.</summary>
    private string Render(string source, string? manifest = null, FetchModule? fetch = null, Dictionary<string, string>? environments = null)
    {
        var text = new Dictionary<string, string> { ["main.jsx"] = source };
        if (manifest is not null) text["widget.json"] = manifest;
        var files = new MemoryPackageFiles(text);
        var prepared = runtime.Compiler.Prepare(files);
        var result = runtime.Executor.Execute(new ExecutionRequest
        {
            Prepared = prepared,
            Files = files,
            Environments = environments ?? new Dictionary<string, string> { ["widget-size"] = "small" },
            Modules = [fetch ?? Offline()],
            PackageID = "pkg-a",
        });
        Assert.True(result.Error is null, $"error: {result.Error?.Kind} {result.Error?.Message}");
        return Regex.Match(result.Tree!, "\"children\":\\[\"(.*)\"\\]\\}$").Groups[1].Value;
    }

    [Fact]
    public void FetchRequiresDeclaredHost()
    {
        const string script = """fetch("https://example.org/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))""";
        Assert.Equal("Network host is not declared in widget.json", Render(script, Manifest("[\"network\"]", "[\"example.com\"]")));
        Assert.Equal("Network host is not declared in widget.json", Render(script, Manifest("[]")));
    }

    [Fact]
    public void FetchRejectsPrivateHostsByNameAndByResolvedAddress()
    {
        const string byName = """fetch("http://192.168.1.1/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))""";
        Assert.Equal(Blocked, Render(byName));
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "ok"));
        var rebinding = new FetchModule(_ => [new IPAddress(new byte[] { 10, 0, 0, 5 })], handler);
        const string byAddress = """fetch("https://public.example.com/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))""";
        Assert.Equal(Blocked, Render(byAddress, fetch: rebinding));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public void FetchPolicyHoldsWhenBuiltInsAreTampered()
    {
        const string script = """
            RegExp.prototype.exec = function () { return ["https://example.com", "https", "example.com"]; };
            String.prototype.startsWith = function () { return false; };
            Array.prototype.includes = function () { return true; };
            fetch("http://127.0.0.1:8080/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))
            """;
        Assert.Equal(Blocked, Render(script, Manifest("[\"network\"]", "[\"example.com\"]")));
    }

    [Fact]
    public void FetchIsReadOnlyInFutureTimelineEntries()
    {
        const string script = """fetch("https://example.com/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e).slice(0, 20)}</text>))""";
        Assert.Equal("[timeline_read_only]", Render(script, environments: new() { ["widget-size"] = "small", ["timeline-is-projection"] = "true" }));
    }

    /// <summary>The Android test reads example.com; here the exchange is answered in the process.</summary>
    [Fact]
    public void FetchReturnsBodiesAndMetadata()
    {
        const string script = """
            $http.getResponse("https://example.com/").then(
              r => $render(<text>{[r.status, r.body.includes("Example Domain"), typeof r.headers["content-type"]].join("|")}</text>),
              e => $render(<text>{"error: " + String(e)}</text>))
            """;
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "<h1>Example Domain</h1>", "text/html"));
        Assert.Equal("200|true|string", Render(script, Manifest("[\"network\"]", "[\"example.com\"]"), new FetchModule(PublicResolver, handler)));
        Assert.Equal("https://example.com/", Assert.Single(handler.Requests).Uri.AbsoluteUri);
        const string plain = """fetch("https://example.com/a").then(v => $render(<text>{v}</text>), e => $render(<text>{"error: " + String(e)}</text>))""";
        Assert.Equal("ok", Render(plain, Manifest("[\"network\"]", "[\"example.com\"]")));
    }

    // MARK: - The module without a script

    private static ExecutionRequest Request(string[]? domains = null, Dictionary<string, string>? environments = null) => new()
    {
        Prepared = new PreparedPackage
        {
            Code = "",
            HasManifest = domains is not null,
            Manifest = domains is null ? null : new JsonObject { ["formatVersion"] = 2, ["permissions"] = Json.Array(["network"]), ["networkDomains"] = Json.Array(domains) },
        },
        Files = new MemoryPackageFiles(new Dictionary<string, string>()),
        Environments = environments ?? new Dictionary<string, string> { ["widget-size"] = "medium" },
    };

    private static (bool OK, JsonNode? Value) Start(FetchModule module, ExecutionRequest request, JsonObject job)
    {
        using var finished = new ManualResetEventSlim();
        var outcomes = new List<(bool, string?)>();
        module.Start(request, "http.request", job, (ok, json) => { lock (outcomes) outcomes.Add((ok, json)); finished.Set(); });
        Assert.True(finished.Wait(TimeSpan.FromSeconds(20)), "the request did not complete");
        var (succeeded, text) = Assert.Single(outcomes);
        return (succeeded, Json.Parse(text!));
    }

    private static string? Rejection(FetchModule module, ExecutionRequest request, JsonObject job)
    {
        var (ok, value) = Start(module, request, job);
        Assert.False(ok);
        return value?.AsText();
    }

    private static JsonObject Get(string url) => new() { ["method"] = "GET", ["url"] = url };

    private static FetchModule.FetchException Fails(Action block) => Assert.Throws<FetchModule.FetchException>(block);

    [Fact]
    public void HandlesOnlyTheHttpOperationAndReportsPresentationAndUrlErrors()
    {
        var module = Offline();
        Assert.True(module.Handles("http.request"));
        Assert.False(module.Handles("datasource.request"));
        Assert.Equal("[live_activity_unavailable] Live Activity presentations cannot request network data; update their state from the app",
            Rejection(module, Request(environments: new() { ["widget-size"] = "live-activity" }), Get("https://example.com/")));
        Assert.Equal("[timeline_read_only] Future entries cannot make live network requests; read a saved snapshot",
            Rejection(module, Request(environments: new() { ["widget-size"] = "medium", ["timeline-is-projection"] = "true" }), Get("https://example.com/")));
        Assert.Equal("Only HTTP and HTTPS URLs are allowed", Rejection(module, Request(), Get("ftp://example.com/x")));
        Assert.Equal("Only HTTP and HTTPS URLs are allowed", Rejection(module, Request(), Get("file:///c:/windows/win.ini")));
        Assert.Equal("Only HTTP and HTTPS URLs are allowed", Rejection(module, Request(), Get("example.com/x")));
        Assert.Equal("Only HTTP and HTTPS URLs are allowed", Rejection(module, Request(), new JsonObject()));
        Assert.Equal("https:///status is not url", Rejection(module, Request(), Get("https:///status")));
        Assert.Equal("URL credentials are not allowed", Rejection(module, Request(), Get("https://user:pw@example.com/")));
        Assert.Equal(Blocked, Rejection(module, Request(), Get("http://localhost:8080/")));
        Assert.Equal(Blocked, Rejection(module, Request(), Get("http://printer.local/")));
        // A package with a manifest needs the network permission and the host in networkDomains.
        Assert.Equal("Network host is not declared in widget.json", Rejection(module, Request(["example.com"]), Get("https://example.org/")));
        Assert.Equal("Network host is not declared in widget.json", Rejection(module, Request(["*.example.com"]), Get("https://example.com/")));
        Assert.True(Start(module, Request(["*.example.com"]), Get("https://api.example.com/")).OK);
        var request = Request(["example.com"]);
        request.Prepared.Manifest!["permissions"] = new JsonArray();
        Assert.Equal("Network host is not declared in widget.json", Rejection(module, request, Get("https://example.com/")));
    }

    [Fact]
    public void HostsResolvingToPrivateAddressesAreRefusedBeforeAnythingIsSent()
    {
        string[] refused =
        [
            "127.0.0.1", "127.8.9.10", "10.1.2.3", "169.254.169.254", "::1", "fc00::1", "fd12:3456:789a::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254",
            "192.168.0.10", "172.16.5.4", "172.31.255.255", "100.64.0.1", "0.0.0.0", "::", "fe80::1", "fec0::1", "ff02::1", "64:ff9b::7f00:1", "2002:7f00:1::1", "224.0.0.1", "255.255.255.255",
        ];
        foreach (var text in refused)
        {
            var handler = new FakeHandler(_ => FakeHandler.Text(200, "secret"));
            var module = new FetchModule(_ => [IPAddress.Parse(text)], handler);
            Assert.Equal(Blocked, Fails(() => module.Perform("GET", new Uri("https://public.example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
            // One private address among public ones is enough: the connection could go to it.
            var mixed = new FetchModule(_ => [Public, IPAddress.Parse(text)], handler);
            Assert.Equal(Blocked, Fails(() => mixed.Perform("GET", new Uri("https://public.example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
            Assert.Equal(Blocked, Rejection(module, Request(), Get("https://public.example.com/")));
            Assert.Empty(handler.Requests);
        }
        var none = new FakeHandler(_ => FakeHandler.Text(200, "secret"));
        Assert.Equal(Blocked, Fails(() => new FetchModule(_ => [], none).Perform("GET", new Uri("https://public.example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.Equal("Could not resolve public.example.com", Fails(() => new FetchModule(_ => throw new IOException("no such host"), none).Perform("GET", new Uri("https://public.example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.Empty(none.Requests);
        // Public addresses pass.
        foreach (var text in new[] { "93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946", "::ffff:93.184.216.34", "172.32.0.1", "100.128.0.1" })
        {
            var module = new FetchModule(_ => [IPAddress.Parse(text)], new FakeHandler(_ => FakeHandler.Text(200, "ok")));
            Assert.Equal(200, module.Perform("GET", new Uri("https://public.example.com/"), NoHeaders, null, 5000, AnyRedirect).Status);
        }
    }

    /// <summary>Address literals need no DNS: every spelling of a local address is refused by name or by value.</summary>
    [Fact]
    public void AddressLiteralsInBlockedRangesAreRefused()
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "secret"));
        var module = new FetchModule(FetchModule.SystemResolver, handler);
        foreach (var url in new[]
        {
            "http://127.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", "http://[fd00::1]/", "http://[fe80::1]/", "http://169.254.169.254/latest/meta-data/",
            "http://0.0.0.0/", "http://2130706433/", "http://0x7f.0.0.1/", "http://127.1/", "http://10.0.0.1:8080/", "https://192.168.1.1/", "http://100.64.0.1/", "http://[64:ff9b::a00:1]/",
        })
        {
            Assert.Equal(Blocked, Rejection(module, Request(), Get(url)));
        }
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task TheConnectStepRefusesBlockedNamesAndAddressesWithoutConnecting()
    {
        async Task<string> Refusal(string host, params string[] addresses)
        {
            var resolved = 0;
            IReadOnlyList<IPAddress> Resolver(string name) { resolved += 1; return addresses.Select(IPAddress.Parse).ToList(); }
            var error = await Assert.ThrowsAsync<FetchModule.FetchException>(async () => await FetchModule.ConnectAsync(Resolver, new DnsEndPoint(host, 443), CancellationToken.None));
            return $"{error.Message}|{resolved}";
        }
        foreach (var address in new[] { "127.0.0.1", "10.1.2.3", "169.254.169.254", "::1", "fc00::1", "fd00::1", "::ffff:127.0.0.1", "192.168.1.1", "172.16.0.1", "0.0.0.0" })
        {
            Assert.Equal($"{Blocked}|1", await Refusal("public.example.com", address));
            Assert.Equal($"{Blocked}|1", await Refusal("public.example.com", "93.184.216.34", address));
        }
        Assert.Equal($"{Blocked}|1", await Refusal("public.example.com"));
        // A blocked name is refused without asking the resolver.
        foreach (var host in new[] { "localhost", "LOCALHOST", "printer.local", "127.0.0.1", "10.0.0.1", "192.168.1.1", "172.16.0.1", "::1", "[::1]" })
        {
            Assert.Equal($"{Blocked}|0", await Refusal(host, "93.184.216.34"));
        }
        var unresolved = await Assert.ThrowsAsync<FetchModule.FetchException>(async () => await FetchModule.ConnectAsync(_ => throw new IOException("no such host"), new DnsEndPoint("public.example.com", 443), CancellationToken.None));
        Assert.Equal("Could not resolve public.example.com", unresolved.Message);
    }

    /// <summary>
    /// DNS rebinding: the name is public when the request is checked and local when the connection
    /// is opened. The production handler resolves again at connect and refuses, so nothing is sent.
    /// </summary>
    [Fact]
    public void ADnsAnswerThatChangesBeforeTheConnectIsRefused()
    {
        var answers = new List<string>();
        IReadOnlyList<IPAddress> Rebinding(string host)
        {
            lock (answers)
            {
                answers.Add(host);
                return [answers.Count == 1 ? Public : IPAddress.Loopback];
            }
        }
        var module = new FetchModule(Rebinding);
        Assert.Equal(Blocked, Fails(() => module.Perform("GET", new Uri("http://rebind.example.com:9/"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.Equal(["rebind.example.com", "rebind.example.com"], answers);
        Assert.Equal(Blocked, Rejection(new FetchModule(Rebinding), Request(["rebind.example.com"]), Get("https://rebind.example.com/")));
    }

    [Fact]
    public void TheProductionHandlerHasNoRedirectsCookiesCredentialsOrProxy()
    {
        using var handler = FetchModule.CreateHandler(PublicResolver);
        Assert.False(handler.AllowAutoRedirect);
        Assert.False(handler.UseCookies);
        Assert.False(handler.UseProxy);
        Assert.Null(handler.Proxy);
        Assert.Null(handler.Credentials);
        Assert.Null(handler.DefaultProxyCredentials);
        Assert.False(handler.PreAuthenticate);
        Assert.NotNull(handler.ConnectCallback);
    }

    [Fact]
    public void RedirectsToBlockedOrUndeclaredHostsAreRefused()
    {
        var location = "";
        var handler = new FakeHandler(message => message.RequestUri!.AbsolutePath == "/start" ? FakeHandler.Redirect(302, location) : FakeHandler.Text(200, "arrived"));
        var addresses = new Dictionary<string, IPAddress> { ["example.com"] = Public, ["cdn.example.com"] = IPAddress.Parse("10.0.0.1"), ["other.example.org"] = Public };
        var module = new FetchModule(host => [addresses[host]], handler);
        string[] Follow(string target, string[]? domains)
        {
            handler.Requests.Clear();
            location = target;
            var (ok, value) = Start(module, Request(domains), Get("https://example.com/start"));
            return [ok ? "ok" : "failed", value?.AsText() ?? "", handler.Requests.Count.ToString()];
        }
        string[] declared = ["example.com", "cdn.example.com"];
        Assert.Equal(["ok", "arrived", "2"], Follow("https://example.com/next", declared));
        Assert.Equal(["ok", "arrived", "2"], Follow("/next", declared));
        // Not in networkDomains.
        Assert.Equal(["failed", "Redirect target is not allowed", "1"], Follow("https://other.example.org/x", declared));
        // Local by name, by literal address, with credentials, or not HTTP at all.
        foreach (var target in new[] { "http://localhost/x", "http://127.0.0.1/x", "http://[::1]/x", "http://192.168.1.1/x", "https://user:pw@example.com/x", "ftp://example.com/x", "file:///c:/windows/win.ini", "javascript:alert(1)" })
        {
            Assert.Equal(["failed", "Redirect target is not allowed", "1"], Follow(target, declared));
            Assert.Equal(["failed", "Redirect target is not allowed", "1"], Follow(target, null));
        }
        // Declared, but the name resolves to a private address: refused when the hop is resolved.
        Assert.Equal(["failed", Blocked, "1"], Follow("https://cdn.example.com/x", declared));
    }

    [Fact]
    public void RedirectsFollowTheMethodRulesAndStopAtTheLimit()
    {
        var handler = new FakeHandler(message => message.RequestUri!.AbsolutePath switch
        {
            "/found" => FakeHandler.Redirect(302, "/after-found"),
            "/moved" => FakeHandler.Redirect(301, "/after-moved"),
            "/other" => FakeHandler.Redirect(303, "/after-other"),
            "/temporary" => FakeHandler.Redirect(307, "/after-temporary"),
            "/permanent" => FakeHandler.Redirect(308, "https://example.com/after-permanent"),
            "/loop" => FakeHandler.Redirect(302, "/loop"),
            "/nowhere" => FakeHandler.Redirect(302, null),
            "/unchanged" => FakeHandler.Redirect(304, "/never"),
            _ => FakeHandler.Text(200, "done"),
        });
        var module = new FetchModule(PublicResolver, handler);
        var headers = new Dictionary<string, string> { ["X-Trace"] = "1" };
        string Trace(string method, string path)
        {
            handler.Requests.Clear();
            var response = module.Perform(method, new Uri("https://example.com" + path), headers, Encoding.UTF8.GetBytes("payload"), 5000, AnyRedirect);
            return response.Status + " " + string.Join(" ", handler.Requests.Select(request => $"{request.Method}:{request.Uri.AbsolutePath}:{(request.Body is { Length: > 0 } body ? Encoding.UTF8.GetString(body) : "-")}"));
        }
        Assert.Equal("200 POST:/found:payload GET:/after-found:-", Trace("post", "/found"));
        Assert.Equal("200 POST:/moved:payload GET:/after-moved:-", Trace("POST", "/moved"));
        Assert.Equal("200 PUT:/found:payload PUT:/after-found:payload", Trace("PUT", "/found"));
        Assert.Equal("200 PUT:/other:payload GET:/after-other:-", Trace("PUT", "/other"));
        Assert.Equal("200 POST:/temporary:payload POST:/after-temporary:payload", Trace("POST", "/temporary"));
        Assert.Equal("200 DELETE:/permanent:payload DELETE:/after-permanent:payload", Trace("DELETE", "/permanent"));
        Assert.Equal("200 GET:/found:- GET:/after-found:-", Trace("GET", "/found"));
        Assert.Equal("304 GET:/unchanged:-", Trace("GET", "/unchanged"));
        Assert.All(handler.Requests, request => Assert.Equal("1", request.Headers["X-Trace"]));

        handler.Requests.Clear();
        Assert.Equal("Redirect target is not allowed", Fails(() => module.Perform("GET", new Uri("https://example.com/loop"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.Equal(FetchModule.MaximumRedirects + 1, handler.Requests.Count);
        Assert.Equal("Redirect without a location", Fails(() => module.Perform("GET", new Uri("https://example.com/nowhere"), NoHeaders, null, 5000, AnyRedirect)).Message);
        // The caller's rule is asked for every hop, with the resolved target.
        var asked = new List<string>();
        Assert.Equal("Redirect target is not allowed", Fails(() => module.Perform("GET", new Uri("https://example.com/found"), NoHeaders, null, 5000, target => { asked.Add(target.AbsoluteUri); return false; })).Message);
        Assert.Equal(["https://example.com/after-found"], asked);
        Assert.Equal("Unknown method 'BREW'", Fails(() => module.Perform("brew", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
    }

    [Fact]
    public void OverBudgetBodiesAreCutOff()
    {
        var limit = $"Response exceeds the {FetchModule.MaximumResponseBytes}-byte limit";
        Assert.Equal("Response exceeds the 2097152-byte limit", limit);

        // No length at all: the body is counted while it is read and reading stops at the limit.
        var endless = new ZeroStream();
        var module = new FetchModule(PublicResolver, new FakeHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(endless) }));
        Assert.Equal(limit, Fails(() => module.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.InRange(endless.BytesRead, FetchModule.MaximumResponseBytes, FetchModule.MaximumResponseBytes + 256 * 1024);

        // A length that understates the body is not trusted.
        var lying = new ZeroStream();
        var understated = new FetchModule(PublicResolver, new FakeHandler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(lying) };
            response.Content.Headers.ContentLength = 10;
            return response;
        }));
        Assert.Equal(limit, Fails(() => understated.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.InRange(lying.BytesRead, FetchModule.MaximumResponseBytes, FetchModule.MaximumResponseBytes + 256 * 1024);

        // A declared length above the limit is refused without reading.
        var unread = new ZeroStream();
        var declared = new FetchModule(PublicResolver, new FakeHandler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(unread) };
            response.Content.Headers.ContentLength = FetchModule.MaximumResponseBytes + 1;
            return response;
        }));
        Assert.Equal(limit, Fails(() => declared.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect)).Message);
        Assert.Equal(0, unread.BytesRead);

        // Exactly the limit is delivered; the script sees the same message for one byte more.
        var exact = new FetchModule(PublicResolver, new FakeHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new ZeroStream(FetchModule.MaximumResponseBytes)) }));
        Assert.Equal(FetchModule.MaximumResponseBytes, exact.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect).Body.Length);
        var over = new FetchModule(PublicResolver, new FakeHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new ZeroStream(FetchModule.MaximumResponseBytes + 1)) }));
        Assert.Equal(limit, Rejection(over, Request(), Get("https://example.com/")));
    }

    [Fact]
    public void TheRequestBudgetAndTheRequestBodyLimitAreEnforced()
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "ok"));
        var module = new FetchModule(PublicResolver, handler);
        var request = Request();
        for (var index = 0; index < FetchModule.MaximumRequests; index++) Assert.True(Start(module, request, Get("https://example.com/")).OK);
        Assert.Equal("Network request budget exceeded", Rejection(module, request, Get("https://example.com/")));
        Assert.Equal(FetchModule.MaximumRequests, handler.Requests.Count);
        // Requests that policy refuses before the budget do not count; refused ones after it do not reach the network.
        var other = Request();
        Rejection(module, other, Get("http://localhost/"));
        Assert.Equal(0, other.Session.NetworkRequests);

        handler.Requests.Clear();
        var large = new JsonObject { ["method"] = "POST", ["url"] = "https://example.com/", ["body"] = new string('x', FetchModule.MaximumRequestBodyBytes + 1) };
        Assert.Equal("Request body exceeds the 1048576-byte limit", Rejection(module, Request(), large));
        Assert.Empty(handler.Requests);
        var fits = new JsonObject { ["method"] = "POST", ["url"] = "https://example.com/", ["body"] = new string('x', FetchModule.MaximumRequestBodyBytes) };
        Assert.True(Start(module, Request(), fits).OK);
        Assert.Equal(FetchModule.MaximumRequestBodyBytes, Assert.Single(handler.Requests).Body!.Length);
    }

    [Fact]
    public void RequestsCarryTheScriptHeadersAndBodyButNotHostOrLength()
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "ok"));
        var module = new FetchModule(PublicResolver, handler);
        var job = new JsonObject
        {
            ["method"] = "POST", ["url"] = "https://example.com/items?x=1", ["body"] = "{\"a\":1}", ["jsonBody"] = true,
            ["headers"] = new JsonObject { ["X-Token"] = "t", ["Host"] = "evil.example.net", ["Content-Length"] = "999", ["Accept"] = "application/json" },
        };
        Assert.True(Start(module, Request(), job).OK);
        var sent = Assert.Single(handler.Requests);
        Assert.Equal("POST", sent.Method);
        Assert.Equal("https://example.com/items?x=1", sent.Uri.AbsoluteUri);
        Assert.Equal("{\"a\":1}", Encoding.UTF8.GetString(sent.Body!));
        Assert.Equal("t", sent.Headers["X-Token"]);
        Assert.Equal("application/json", sent.Headers["Accept"]);
        Assert.Equal("application/json", sent.Headers["Content-Type"]);
        Assert.Null(sent.Host);
        Assert.False(sent.Headers.TryGetValue("Content-Length", out var length) && length == "999");
        Assert.False(sent.Headers.ContainsKey("Cookie"));
        Assert.False(sent.Headers.ContainsKey("Authorization"));

        // The script's own content type wins over the JSON default; a GET sends no body.
        handler.Requests.Clear();
        job = new JsonObject { ["method"] = "PUT", ["url"] = "https://example.com/", ["body"] = "a=1", ["jsonBody"] = true, ["headers"] = new JsonObject { ["content-type"] = "application/x-www-form-urlencoded" } };
        Assert.True(Start(module, Request(), job).OK);
        Assert.Equal("application/x-www-form-urlencoded", handler.Requests[0].Headers["Content-Type"]);
        handler.Requests.Clear();
        Assert.True(Start(module, Request(), new JsonObject { ["method"] = "GET", ["url"] = "https://example.com/", ["body"] = "ignored" }).OK);
        Assert.True(handler.Requests[0].Body is null or { Length: 0 });

        // A header value cannot add a header line.
        handler.Requests.Clear();
        job = new JsonObject { ["method"] = "GET", ["url"] = "https://example.com/", ["headers"] = new JsonObject { ["X-Token"] = "a\r\nX-Evil: 1" } };
        Assert.Equal("Request header X-Token is not valid", Rejection(module, Request(), job));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public void ResponsesAreTextMetadataOrBase64()
    {
        var handler = new FakeHandler(message =>
        {
            if (message.RequestUri!.AbsolutePath == "/binary") return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([0xFF, 0x00, 0x10]) };
            var response = FakeHandler.Text(message.RequestUri.AbsolutePath == "/missing" ? 404 : 200, "body \u00e9", "application/json");
            response.Headers.TryAddWithoutValidation("Cache-Control", "max-age=60");
            response.Headers.TryAddWithoutValidation("Set-Cookie", "session=secret");
            response.Headers.TryAddWithoutValidation("X-Internal", "secret");
            response.Headers.TryAddWithoutValidation("Retry-After", new string('9', 2049));
            response.Content.Headers.TryAddWithoutValidation("Last-Modified", "Fri, 13 Nov 2026 07:00:00 GMT");
            return response;
        });
        var module = new FetchModule(PublicResolver, handler);
        Assert.Equal("body \u00e9", Start(module, Request(), Get("https://example.com/")).Value!.AsText());
        // An error status still delivers its body, as on the other platforms.
        Assert.Equal("body \u00e9", Start(module, Request(), Get("https://example.com/missing")).Value!.AsText());

        var metadata = (JsonObject)Start(module, Request(), new JsonObject { ["method"] = "GET", ["url"] = "https://example.com/missing", ["metadata"] = true }).Value!;
        Assert.Equal(404, metadata.OptInt("status"));
        Assert.Equal("body \u00e9", metadata.OptString("body"));
        var headers = metadata.OptObject("headers")!;
        Assert.Equal(["cache-control", "content-type", "last-modified"], headers.Select(member => member.Key).Order(StringComparer.Ordinal));
        Assert.Equal("application/json", headers.OptString("content-type"));
        Assert.Equal("Fri, 13 Nov 2026 07:00:00 GMT", headers.OptString("last-modified"));

        Assert.Equal("/wAQ", Start(module, Request(), new JsonObject { ["method"] = "GET", ["url"] = "https://example.com/binary", ["base64"] = true }).Value!.AsText());
        Assert.Equal("https://example.com/binary is empty", Rejection(module, Request(), Get("https://example.com/binary")));
        Assert.Equal("Response is not HTTP or has invalid UTF-8", Rejection(module, Request(), new JsonObject { ["method"] = "GET", ["url"] = "https://example.com/binary", ["metadata"] = true }));
    }

    [Fact]
    public void TimeoutsAndCancellationStopTheRequest()
    {
        var waiting = new FetchModule(PublicResolver, new FakeHandler(async (_, cancellation) =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            return FakeHandler.Text(200, "late");
        }));
        Assert.Equal("The request timed out.", Fails(() => waiting.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 150, AnyRedirect)).Message);

        // A body that stops arriving is given up on as well.
        var stalled = new FetchModule(PublicResolver, new FakeHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new ZeroStream(stall: true)) }));
        Assert.Equal("The request timed out.", Fails(() => stalled.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 150, AnyRedirect)).Message);

        // The end of the execution cancels the request.
        using var ended = new CancellationTokenSource(150);
        Assert.ThrowsAny<OperationCanceledException>(() => waiting.Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect, ended.Token));
        using var already = new CancellationTokenSource();
        already.Cancel();
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "ok"));
        Assert.ThrowsAny<OperationCanceledException>(() => new FetchModule(PublicResolver, handler).Perform("GET", new Uri("https://example.com/"), NoHeaders, null, 5000, AnyRedirect, already.Token));
        Assert.Empty(handler.Requests);

        // A result that arrives after the execution ended is dropped.
        var request = Request();
        var late = new FetchModule(PublicResolver, new FakeHandler(_ => { request.Session.Finished = true; return FakeHandler.Text(200, "late"); }));
        var outcomes = new List<bool>();
        late.Start(request, "http.request", Get("https://example.com/"), (ok, _) => { lock (outcomes) outcomes.Add(ok); });
        Thread.Sleep(500);
        lock (outcomes) Assert.Empty(outcomes);
    }

    [Fact]
    public void TimeoutsAreClampedToOneToTenSeconds()
    {
        Assert.Equal(5000, FetchModule.NormalizedTimeout(null));
        Assert.Equal(5000, FetchModule.NormalizedTimeout(double.NaN));
        Assert.Equal(5000, FetchModule.NormalizedTimeout(0));
        Assert.Equal(5000, FetchModule.NormalizedTimeout(-3));
        Assert.Equal(1000, FetchModule.NormalizedTimeout(0.2));
        Assert.Equal(2500, FetchModule.NormalizedTimeout(2.5));
        Assert.Equal(10000, FetchModule.NormalizedTimeout(60));
        Assert.Equal(10000, FetchModule.NormalizedTimeout(double.PositiveInfinity));
        Assert.Equal(2 * 1024 * 1024, FetchModule.MaximumResponseBytes);
        Assert.Equal(32, FetchModule.MaximumRequests);
        Assert.Equal(5, FetchModule.MaximumRedirects);
    }
}
