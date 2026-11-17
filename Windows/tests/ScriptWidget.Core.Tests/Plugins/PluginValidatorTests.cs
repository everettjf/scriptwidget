using System.Text.Json.Nodes;
using ScriptWidget.Core.Plugins;
using static ScriptWidget.Core.Tests.Plugins.PluginFixtures;

namespace ScriptWidget.Core.Tests.Plugins;

public class PluginValidatorTests
{
    // Swift: testBuiltInPluginsValidate
    [Fact]
    public void BuiltInPluginsValidate()
    {
        Assert.Equal(2, PluginStore.BuiltIns.Count);
        foreach (var plugin in PluginStore.BuiltIns) Assert.Empty(PluginValidator.Validate(plugin));
    }

    [Fact]
    public void BuiltInPluginsSurviveEncodingAndDecoding()
    {
        foreach (var plugin in PluginStore.BuiltIns) Assert.Equal(plugin, PluginValidator.Decode(Utf8(plugin.ToJson())));
        var manifest = Manifest();
        Assert.Equal(manifest, PluginValidator.Decode(Utf8(manifest.ToJson())));
    }

    [Fact]
    public void DecodesEveryField()
    {
        var manifest = Manifest();
        Assert.Equal(ID, manifest.Id);
        Assert.Equal("https://api.example.com", manifest.BaseURL);
        Assert.Equal(["api.example.com"], manifest.Hosts);
        var update = manifest.Operations[0];
        Assert.Equal("POST", update.Method);
        Assert.Equal(PluginResponseType.Json, update.ResponseType);
        Assert.Equal(new PluginParameter("page", "Page", PluginParameterLocation.Query, false, "1"), update.Parameters[1]);
        Assert.Null(update.Parameters[2].DefaultValue);
        Assert.Equal(PluginResponseType.Text, manifest.Operations[1].ResponseType);
    }

    // Swift: testManifestDecoderFailsClosedAndRejectsHTTP
    [Fact]
    public void UnknownKeysFailClosedAtEveryLevel()
    {
        AssertRejected("plugin.json contains unknown fields.", root => root["unexpected"] = true);
        AssertRejected("plugin.json contains unknown fields.", root => root["nativeLibrary"] = "libplugin.so");
        AssertRejected("Plugin operation contains unknown fields.", root => Operation(root)["script"] = "fetch()");
        AssertRejected("Plugin operation contains unknown fields.", root => Parameter(root, 0)["secret"] = "x");
    }

    [Fact]
    public void HttpBaseURLIsRejected()
    {
        var unsafePlugin = PluginStore.BuiltIns[0] with { BaseURL = "http://api.open-meteo.com" };
        Assert.NotEmpty(PluginValidator.Validate(unsafePlugin));
        AssertRejected("baseURL must be an HTTPS URL without credentials, query, or fragment.", root => root["baseURL"] = "http://api.example.com");
    }

    [Fact]
    public void BaseURLRules()
    {
        const string message = "baseURL must be an HTTPS URL without credentials, query, or fragment.";
        foreach (var url in new[]
        {
            "ftp://api.example.com", "https://user:pw@api.example.com", "https://user@api.example.com", "https://api.example.com?key=1",
            "https://api.example.com/#top", "api.example.com", "https:///path", "", "https://api example.com", "file:///etc/hosts",
        })
        {
            AssertRejected(message, root => root["baseURL"] = url);
        }
        AssertRejected("baseURL host must be included in hosts.", root => root["baseURL"] = "https://other.example.com");
        // A port and a base path are allowed.
        Assert.Equal("https://api.example.com:8443/v2", Manifest(root => root["baseURL"] = "https://api.example.com:8443/v2").BaseURL);
    }

    /// <summary>Windows only: spellings System.Uri would accept or reinterpret are not a base URL.</summary>
    [Fact]
    public void BaseURLsThatOnlyALenientParserAcceptsAreRejected()
    {
        const string message = "baseURL must be an HTTPS URL without credentials, query, or fragment.";
        foreach (var url in new[]
        {
            "https://api.example.com\\@evil.example.net", "https:\\\\api.example.com", "https:api.example.com", "https://api_internal.example.com",
            "https://api.example.com:port", "https://api.example.com/a b", "https://api.example.com/%zz", "https://api.example.com?", "https://api.example.com#",
            "https://@api.example.com", "https://\u4f8b\u3048.example.com", " https://api.example.com", "https://api.example.com\n",
        })
        {
            AssertRejected(message, root => root["baseURL"] = url);
        }
    }

    [Fact]
    public void VersionsFailClosed()
    {
        AssertRejected("Unsupported Data Source Plugin format 2.", root => root["formatVersion"] = 2);
        AssertRejected("Unsupported Data Source Plugin format 0.", root => root["formatVersion"] = 0);
        AssertRejected("\"formatVersion\" is missing or has the wrong type", root => root["formatVersion"] = "1");
        AssertRejected("\"formatVersion\" is missing or has the wrong type", root => root["formatVersion"] = 1.5);
        AssertRejected("\"formatVersion\" is missing or has the wrong type", root => root.Remove("formatVersion"));
        AssertRejected("Plugin requires unsupported runtime 2.0.", root => root["minimumRuntimeVersion"] = "2.0");
        AssertRejected("Plugin requires unsupported runtime 1.6.", root => root["minimumRuntimeVersion"] = "1.6");
        AssertRejected("Plugin version must use semantic versioning.", root => root["version"] = "1.0");
        AssertRejected("Plugin version must use semantic versioning.", root => root["version"] = "v1.0.0");
        Assert.Equal("1.0.0-beta.1", Manifest(root => root["version"] = "1.0.0-beta.1").Version);
    }

    [Fact]
    public void IdentifierAndNameRules()
    {
        foreach (var id in new[] { "ab", "-abc", "has space", "a/b/c", new string('a', 129), "abc\n" })
        {
            AssertRejected("Plugin id must be a stable 3–128 character identifier.", root => root["id"] = id);
        }
        AssertRejected("Plugin name must contain 1–80 characters.", root => root["name"] = "  ");
        AssertRejected("Plugin name must contain 1–80 characters.", root => root["name"] = new string('n', 81));
        Assert.Equal(80, Manifest(root => root["name"] = new string('n', 80)).Name.Length);
    }

    [Fact]
    public void PrivateAndLocalHostsAreRejected()
    {
        foreach (var host in new[] { "localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "printer.local" })
        {
            AssertRejected($"Plugin host must be a public Internet host: {host}.", root => { root["baseURL"] = $"https://{host}"; root["hosts"] = Array(host); });
        }
        AssertRejected("Plugin host must be a public Internet host: *.local.", root => root["hosts"] = Array("api.example.com", "*.local"));
        AssertRejected("baseURL", root => { root["baseURL"] = "https://[::1]"; root["hosts"] = Array("api.example.com"); });
    }

    [Fact]
    public void HostDeclarationRules()
    {
        AssertRejected("A plugin must declare 1–20 HTTPS hosts.", root => root["hosts"] = new JsonArray());
        AssertRejected("A plugin must declare 1–20 HTTPS hosts.", root => root["hosts"] = Array(Enumerable.Range(0, 21).Select(index => (object)(index == 0 ? "api.example.com" : $"h{index}.example.com")).ToArray()));
        AssertRejected("Plugin hosts must be unique.", root => root["hosts"] = Array("api.example.com", "api.example.com"));
        foreach (var host in new[] { "https://api.example.com", "api.example.com/path", "api.example.com:443", "API.example.com", ".example.com", "example.com.", "api.*.com", "*example.com", "*.*.example.com", "exa mple.com" })
        {
            AssertRejected($"Invalid plugin host declaration: {host}.", root => root["hosts"] = Array("api.example.com", host));
        }
        AssertRejected("\"hosts\" is missing or has the wrong type", root => root["hosts"] = Array("api.example.com", 7));
        Assert.Equal(["*.example.com"], Manifest(root => root["hosts"] = Array("*.example.com")).Hosts);
    }

    [Fact]
    public void OperationRules()
    {
        AssertRejected("A plugin must contain 1–50 operations.", root => root["operations"] = new JsonArray());
        AssertRejected("A plugin must contain 1–50 operations.", root =>
        {
            var operations = new JsonArray();
            for (var index = 0; index <= 50; index++)
            {
                var copy = (JsonObject)Operation(root, 1).DeepClone();
                copy["id"] = $"status-{index}";
                operations.Append(copy);
            }
            root["operations"] = operations;
        });
        AssertRejected("Operation ids must be unique.", root => Operation(root, 1)["id"] = "UPDATE");
        AssertRejected("Operation id is invalid: a b.", root => Operation(root, 1)["id"] = "a b");
        foreach (var method in new[] { "get", "HEAD", "OPTIONS", "CONNECT", "TRACE", "" })
        {
            AssertRejected("Operation status has an unsupported HTTP method.", root => Operation(root, 1)["method"] = method);
        }
        const string pathMessage = "Operation path must be an absolute URL path without traversal, query, or fragment.";
        foreach (var path in new[] { "", "status", "/a/../b", "/status?x=1", "/status#top", "//evil.example.com/.." })
        {
            AssertRejected(pathMessage, root => Operation(root, 1)["path"] = path);
        }
        AssertRejected("\"responseType\" is missing or has the wrong type", root => Operation(root, 1)["responseType"] = "xml");
        AssertRejected("\"title\" is missing or has the wrong type", root => Operation(root, 1).Remove("title"));
        AssertRejected("plugin.json contains unknown fields.", root => root["operations"] = "none");
        AssertRejected("Plugin operation contains unknown fields.", root => Operation(root, 1)["parameters"] = "none");
    }

    [Fact]
    public void ParameterDeclarationRules()
    {
        AssertRejected("Operation status has too many parameters.", root =>
        {
            var parameters = new JsonArray();
            for (var index = 0; index <= 30; index++) parameters.Append(new JsonObject { ["id"] = $"param-{index}", ["label"] = "P", ["location"] = "query", ["required"] = false });
            Operation(root, 1)["parameters"] = parameters;
        });
        AssertRejected("Operation parameter ids must be unique.", root => Parameter(root, 1)["id"] = "ENABLED");
        AssertRejected("Invalid parameter id: p!.", root => Parameter(root, 1)["id"] = "p!");
        AssertRejected("Path parameter page has no matching placeholder.", root => Parameter(root, 1)["location"] = "path");
        AssertRejected("Placeholder user must be a path parameter.", root => Parameter(root, 0)["location"] = "query");
        AssertRejected("Path placeholder team has no declared parameter.", root => Operation(root)["path"] = "/teams/{team}/users/{user}");
        AssertRejected("\"location\" is missing or has the wrong type", root => Parameter(root, 1)["location"] = "cookie");
        AssertRejected("\"required\" is missing or has the wrong type", root => Parameter(root, 1)["required"] = "yes");
        AssertRejected("\"required\" is missing or has the wrong type", root => Parameter(root, 1).Remove("required"));
        AssertRejected("\"defaultValue\" is missing or has the wrong type", root => Parameter(root, 1)["defaultValue"] = 1);
        AssertRejected("\"label\" is missing or has the wrong type", root => Parameter(root, 1)["label"] = 5);
    }

    [Fact]
    public void EveryIssueIsReported()
    {
        var error = Failure(() => PluginValidator.Decode(Bytes(root => { root["id"] = "x"; root["version"] = "1"; root["formatVersion"] = 3; })));
        Assert.Equal("Unsupported Data Source Plugin format 3.\nPlugin id must be a stable 3–128 character identifier.\nPlugin version must use semantic versioning.", error.Message);
    }

    [Fact]
    public void OversizeAndMalformedDocumentsAreRejected()
    {
        var padded = Bytes(root => root["summary"] = new string('s', PluginValidator.MaximumManifestBytes));
        Assert.Equal("plugin.json exceeds 256 KiB.", Failure(() => PluginValidator.Decode(padded)).Message);
        Assert.Equal("plugin.json must be an object.", Failure(() => PluginValidator.Decode(Utf8("[]"))).Message);
        Assert.Equal("plugin.json must be UTF-8 JSON.", Failure(() => PluginValidator.Decode([0x7B, 0xFF, 0x7D])).Message);
        var valid = System.Text.Encoding.UTF8.GetString(Bytes());
        var first = valid.IndexOf('{');
        string ReplaceFirstBrace(string replacement) => valid[..first] + replacement + valid[(first + 1)..];
        foreach (var text in new[]
        {
            "", "{", $"{valid} trailing", valid + valid, valid.Replace("\"formatVersion\"", "formatVersion"), valid.Replace('"', '\''),
            ReplaceFirstBrace("{ // comment\n"), ReplaceFirstBrace("{\"id\":\"dev.scriptwidget.first\","),
        })
        {
            Assert.Equal("plugin.json is not valid JSON.", Failure(() => PluginValidator.Decode(Utf8(text))).Message);
        }
    }

    [Fact]
    public void StrictJsonAcceptsOnlyTheStandardGrammar()
    {
        var escapedE = "\\" + "u00e9";
        var parsed = Assert.IsType<Dictionary<string, object?>>(StrictJson.Parse(" {\"a\": [1, 2.5, true, null, \"x\\n" + escapedE + "\"]} "));
        Assert.Equal(["a"], parsed.Keys);
        Assert.Equal(new List<object?> { 1L, 2.5, true, null, "x\n" + (char)0xE9 }, Assert.IsType<List<object?>>(parsed["a"]));
        foreach (var text in new[] { "01", "1.", ".5", "+1", "[1,]", "{\"a\":1,}", "\"a\tb\"", "nul", "NaN", "\"\\x41\"", new string('[', 600) + new string(']', 600) })
        {
            Assert.Throws<StrictJson.JsonException>(() => StrictJson.Parse(text));
        }
        Assert.Equal("\"a\\\"b\\\\c/d\\n\\" + "u0001\"", StrictJson.Quote("a\"b\\c/d\n" + (char)1));
        // Line and paragraph separators are escaped so the text is also a JavaScript literal.
        Assert.Equal("\"\\" + "u2028\\" + "u2029\"", StrictJson.Quote(new string([(char)0x2028, (char)0x2029])));
    }

    [Fact]
    public void DomainDeclarationsMatchSwift()
    {
        Assert.True(PluginValidator.IsValidDomainDeclaration("api.example.com"));
        Assert.True(PluginValidator.IsValidDomainDeclaration("*.example.com"));
        Assert.False(PluginValidator.IsValidDomainDeclaration("Api.example.com"));
        Assert.False(PluginValidator.IsValidDomainDeclaration("api.example.com:8443"));
        Assert.False(PluginValidator.IsValidDomainDeclaration("a*.example.com"));
    }
}
