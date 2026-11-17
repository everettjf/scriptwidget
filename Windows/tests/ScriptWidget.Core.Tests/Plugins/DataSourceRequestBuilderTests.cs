using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Plugins;
using static ScriptWidget.Core.Tests.Plugins.PluginFixtures;

namespace ScriptWidget.Core.Tests.Plugins;

public class DataSourceRequestBuilderTests
{
    private readonly PluginManifest plugin = Manifest();
    private readonly PluginManifest github = PluginStore.BuiltIns.First(item => item.Id == "app.scriptwidget.datasource.github");
    private readonly PluginManifest weather = PluginStore.BuiltIns.First(item => item.Id == "app.scriptwidget.datasource.open-meteo");

    private static JsonObject Body(PreparedDataSourceRequest prepared) => Json.ParseObject(Encoding.UTF8.GetString(prepared.Body!));

    // Swift: testRequestBuilderMapsPathQueryHeaderAndJSONBody
    [Fact]
    public void MapsPathQueryHeaderAndJSONBody()
    {
        var prepared = DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "hello world"), ("X-Token", "secret"), ("enabled", true)));
        Assert.Equal("https://api.example.com/users/hello%20world?page=1", prepared.Uri.AbsoluteUri);
        Assert.Equal("POST", prepared.Method);
        Assert.Equal("secret", prepared.Headers["X-Token"]);
        Assert.Equal("ScriptWidget-DataSource/1", prepared.Headers["User-Agent"]);
        Assert.Equal("application/json", prepared.Headers["Content-Type"]);
        Assert.True(Body(prepared)["enabled"]!.GetValue<bool>());
    }

    [Fact]
    public void DefaultsFillMissingValuesAndSuppliedValuesWin()
    {
        Assert.Equal("https://api.github.com/repos/everettjf/scriptwidget", DataSourceRequestBuilder.Prepare(github, "repository", Values()).Uri.AbsoluteUri);
        Assert.Equal("https://api.github.com/repos/quickjs-ng/quickjs", DataSourceRequestBuilder.Prepare(github, "repository", Values(("owner", "quickjs-ng"), ("repo", "quickjs"))).Uri.AbsoluteUri);
        var forecast = DataSourceRequestBuilder.Prepare(weather, "forecast", Values(("latitude", 48.85), ("longitude", 2), ("undeclared", "ignored")));
        Assert.Equal("https://api.open-meteo.com/v1/forecast?latitude=48.85&longitude=2&current=temperature_2m,weather_code&timezone=auto", forecast.Uri.AbsoluteUri);
        Assert.Null(forecast.Body);
        Assert.Equal(["User-Agent"], forecast.Headers.Keys);
    }

    [Fact]
    public void PathValuesCannotChangeThePathStructure()
    {
        string Path(object? owner) => DataSourceRequestBuilder.Prepare(github, "repository", Values(("owner", owner), ("repo", "r"))).Uri.AbsolutePath;
        Assert.Equal("/repos/a%2Fb/r", Path("a/b"));
        Assert.Equal("/repos/a%3Fx=1%23f/r", Path("a?x=1#f"));
        Assert.Equal("/repos/%7Brepo%7D/r", Path("{repo}"));
        Assert.Equal("/repos/%E4%BD%A0%E5%A5%BD%25/r", Path("你好%"));
        Assert.Equal("/repos/a-b_c.d~e!$&'()*+,=:@/r", Path("a-b_c.d~e!$&'()*+,=:@"));
        Assert.Equal("/repos/a%3Bb%20c%5Cd/r", Path("a;b c\\d"));
        Assert.Equal("/repos/1/r", Path(true));
        Assert.Equal("/repos/42/r", Path(42));
        foreach (var value in new[] { "..", "." }) Assert.Equal("Could not encode owner.", Failure(() => Path(value)).Message);
        Assert.Equal("Could not encode owner.", Failure(() => Path(new JsonObject { ["a"] = 1 })).Message);
        Assert.Equal("Could not encode owner.", Failure(() => Path(double.NaN)).Message);
        // Windows only: an encoded separator or dot segment stays one segment in the URL that is sent.
        Assert.Equal("/repos/..%2F..%2Fadmin/r", Path("../../admin"));
        Assert.Equal("/repos/%252E%252E/r", Path("%2E%2E"));
        Assert.Equal("/repos/.../r", Path("..."));
    }

    [Fact]
    public void QueryValuesCannotAddQueryItems()
    {
        string Query(object? value)
        {
            var query = DataSourceRequestBuilder.Prepare(weather, "forecast", Values(("timezone", value))).Uri.Query;
            return query[(query.IndexOf("timezone=", StringComparison.Ordinal) + "timezone=".Length)..];
        }
        Assert.Equal("a%26b%3Dc%23d", Query("a&b=c#d"));
        Assert.Equal("Europe/Paris", Query("Europe/Paris"));
        Assert.Equal("a%20b+c", Query("a b+c"));
        Assert.Equal("%E2%82%AC", Query("€"));
        Assert.Equal("0", Query(false));
        Assert.Equal("1.5", Query(1.5));
        // The values the script bridge delivers are JSON nodes.
        Assert.Equal("1", Query(JsonValue.Create(true)));
        Assert.Equal("2", Query(Json.Parse("2.0")));
        Assert.Equal("0.000001", Query(Json.Parse("1e-6")));
        Assert.Equal("100000000000000000000", Query(Json.Parse("1e20")));
        Assert.Equal("x", Query(Json.Parse("\"x\"")));
        // An empty optional value is omitted; null falls back to the default.
        Assert.DoesNotContain("timezone", DataSourceRequestBuilder.Prepare(weather, "forecast", Values(("timezone", ""))).Uri.Query);
        Assert.Equal("auto", Query(Json.Parse("null")));
        Assert.Equal("auto", Query(null));
    }

    [Fact]
    public void MissingRequiredParametersAreReported()
    {
        Assert.Equal("Missing required parameter user.", Failure(() => DataSourceRequestBuilder.Prepare(plugin, "update", Values(("X-Token", "t"), ("enabled", true)))).Message);
        Assert.Equal("Missing required parameter X-Token.", Failure(() => DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "u"), ("enabled", true)))).Message);
        var error = Failure(() => DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "u"), ("X-Token", "t"), ("enabled", ""))));
        Assert.Equal("Missing required parameter enabled.", error.Message);
        Assert.Equal(PluginErrorKind.InvalidParameters, error.Kind);
        // A supplied empty string does not fall back to the default (Swift behavior).
        Assert.Equal("Missing required parameter latitude.", Failure(() => DataSourceRequestBuilder.Prepare(weather, "forecast", Values(("latitude", "")))).Message);
    }

    [Fact]
    public void UnknownOperationIsNotFound()
    {
        var error = Failure(() => DataSourceRequestBuilder.Prepare(plugin, "missing", Values()));
        Assert.Equal(PluginErrorKind.NotFound, error.Kind);
        Assert.Equal($"Operation missing was not found in {ID}.", error.Message);
    }

    [Fact]
    public void HeaderValuesCannotInjectHeaders()
    {
        foreach (var token in new[] { "a\r\nX-Evil: 1", "a\nb", "a\0b" })
        {
            Assert.Equal("Could not encode X-Token.", Failure(() => DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "u"), ("enabled", true), ("X-Token", token)))).Message);
        }
        Assert.Equal("Could not encode X-Token.", Failure(() => DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "u"), ("enabled", true), ("X-Token", new JsonArray())))).Message);
    }

    [Fact]
    public void ReservedHeadersAreSetByTheRuntime()
    {
        var custom = Manifest(root =>
        {
            Parameter(root, 2)["id"] = "user-agent";
            ((JsonArray)Operation(root)["parameters"]!).Append(new JsonObject { ["id"] = "content-type", ["label"] = "Type", ["location"] = "header", ["required"] = false });
        });
        var prepared = DataSourceRequestBuilder.Prepare(custom, "update", Values(("user", "u"), ("user-agent", "Mozilla"), ("content-type", "text/plain"), ("enabled", 1)));
        Assert.Equal(new Dictionary<string, string> { ["User-Agent"] = "ScriptWidget-DataSource/1", ["Content-Type"] = "application/json" }, prepared.Headers);
    }

    [Fact]
    public void JsonBodyKeepsStructuredValues()
    {
        var nested = new JsonObject { ["tags"] = Array("a", "b") };
        var prepared = DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "u"), ("X-Token", "t"), ("enabled", nested)));
        Assert.Equal("b", Body(prepared)["enabled"]!["tags"]![1]!.GetValue<string>());
        var number = DataSourceRequestBuilder.Prepare(plugin, "update", Values(("user", "u"), ("X-Token", "t"), ("enabled", 3)));
        Assert.Equal(3, Body(number).OptInt("enabled"));
        Assert.Equal("{\"enabled\":3}", Encoding.UTF8.GetString(number.Body!));
    }

    [Fact]
    public void BasePathAndPortArePreserved()
    {
        var versioned = Manifest(root => root["baseURL"] = "https://api.example.com:8443/v2");
        Assert.Equal("https://api.example.com:8443/v2/status", DataSourceRequestBuilder.Prepare(versioned, "status", Values()).Uri.AbsoluteUri);
        var slash = Manifest(root => root["baseURL"] = "https://api.example.com/");
        Assert.Equal("https://api.example.com/status", DataSourceRequestBuilder.Prepare(slash, "status", Values()).Uri.AbsoluteUri);
    }

    [Fact]
    public void RequestsCannotLeaveTheDeclaredHosts()
    {
        // Not reachable through the validator; the builder still refuses a tampered manifest.
        var escaped = plugin with { BaseURL = "https://evil.example.net" };
        var error = Failure(() => DataSourceRequestBuilder.Prepare(escaped, "status", Values()));
        Assert.Equal(PluginErrorKind.Permission, error.Kind);
        Assert.Equal("Plugin request escaped its declared hosts.", error.Message);
        Assert.Equal("Plugin request escaped its declared hosts.", Failure(() => DataSourceRequestBuilder.Prepare(plugin with { BaseURL = "http://api.example.com" }, "status", Values())).Message);
        Assert.Equal("Invalid plugin baseURL.", Failure(() => DataSourceRequestBuilder.Prepare(plugin with { BaseURL = "not a url" }, "status", Values())).Message);
        var unresolved = plugin with { Operations = [plugin.Operations[1] with { Path = "/x/{gone}" }] };
        Assert.Equal("A path parameter is unresolved.", Failure(() => DataSourceRequestBuilder.Prepare(unresolved, "status", Values())).Message);
        // Windows only: a backslash, which System.Uri reads as a slash, never reaches it.
        Assert.Equal("Invalid plugin baseURL.", Failure(() => DataSourceRequestBuilder.Prepare(plugin with { BaseURL = "https://api.example.com\\@evil.example.net" }, "status", Values())).Message);
        var backslash = plugin with { Operations = [plugin.Operations[1] with { Path = "/\\evil.example.net/x" }] };
        Assert.Equal("Invalid plugin baseURL.", Failure(() => DataSourceRequestBuilder.Prepare(backslash, "status", Values())).Message);
    }

    // MARK: - Response mapping

    private PluginOperation JsonOperation => plugin.Operations[0];
    private PluginOperation TextOperation => plugin.Operations[1];

    [Fact]
    public void JsonResponsesPassThroughUnchanged()
    {
        const string body = """{"temperature": 21.50, "tags": ["a", null], "big": 12345678901234567890}""";
        Assert.Equal(body, DataSourceResponseMapper.Map(JsonOperation, 200, Utf8(body)));
        Assert.Equal("[1,2]", DataSourceResponseMapper.Map(JsonOperation, 204, [0xEF, 0xBB, 0xBF, .. Utf8("[1,2]")]));
        Assert.Equal("""{"a":1,"a":2}""", DataSourceResponseMapper.Map(JsonOperation, 200, Utf8("""{"a":1,"a":2}""")));
    }

    [Fact]
    public void InvalidJsonResponsesAreRejected()
    {
        foreach (var body in new[] { "", "<html>", "{\"a\":}", "{} trailing", "\"text\"", "42", "null", "{'a':1}" })
        {
            var error = Failure(() => DataSourceResponseMapper.Map(JsonOperation, 200, Utf8(body)));
            Assert.Equal("Data source returned invalid JSON", error.Message);
            Assert.Equal(PluginErrorKind.Network, error.Kind);
        }
        Assert.Equal("Data source returned invalid JSON", Failure(() => DataSourceResponseMapper.Map(JsonOperation, 200, [0x7B, 0xC3, 0x28, 0x7D])).Message);
    }

    [Fact]
    public void TextResponsesBecomeJsonStrings()
    {
        Assert.Equal("\"line 1\\n\\\"quoted\\\" é\"", DataSourceResponseMapper.Map(TextOperation, 200, Utf8("line 1\n\"quoted\" é")));
        Assert.Equal("\"\"", DataSourceResponseMapper.Map(TextOperation, 200, []));
        Assert.Equal("Data source returned non-UTF-8 text", Failure(() => DataSourceResponseMapper.Map(TextOperation, 200, [0xFF, 0xFE])).Message);
    }

    [Fact]
    public void FailedAndOversizeResponsesAreRejected()
    {
        foreach (var status in new[] { 199, 301, 404, 500 }) Assert.Equal("Data source request failed", Failure(() => DataSourceResponseMapper.Map(JsonOperation, status, Utf8("{}"))).Message);
        var oversize = new byte[DataSourceResponseMapper.MaximumResponseBytes + 1];
        System.Array.Fill(oversize, (byte)'a');
        Assert.Equal("Data source response exceeds 2 MiB.", Failure(() => DataSourceResponseMapper.Map(TextOperation, 200, oversize)).Message);
        Assert.Equal(2 * 1024 * 1024, DataSourceResponseMapper.MaximumResponseBytes);
    }
}
