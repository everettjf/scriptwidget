using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Runtime;
using static ScriptWidget.Core.Tests.Api.SystemFixtures;

namespace ScriptWidget.Core.Tests.Api;

public sealed class WeatherModuleTests : IDisposable
{
    private sealed class FakeTransport : IWeatherTransport
    {
        public int Status = 200;
        public byte[] Body = [];
        public List<string> Urls { get; } = [];
        public List<string?> Agents { get; } = [];
        public int Timeout;
        public bool Fail;
        public Uri? Redirect;
        public bool? RedirectAllowed;

        public WeatherResponse Get(string url, IReadOnlyDictionary<string, string> headers, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation)
        {
            Urls.Add(url);
            Agents.Add(headers.GetValueOrDefault("User-Agent"));
            Timeout = timeoutMilliseconds;
            if (Redirect is not null) RedirectAllowed = allowRedirect(Redirect);
            if (Fail) throw new IOException("offline");
            return new WeatherResponse(Status, Body);
        }
    }

    /// <summary>A recorded response for lat=59.91&amp;lon=10.75: 85 entries from 2026-11-13T07:00:00Z, hourly for 53 hours and without <c>next_1_hours</c> after that.</summary>
    private static readonly byte[] Recorded = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "fixtures", "met-norway-compact.json"));
    private static readonly string[] Declared = ["weather", "network"];
    private static readonly string[] Domains = ["api.met.no"];

    private long now = IsoDates.Parse("2026-11-13T07:30:00Z")!.Value;
    private readonly string directory = TemporaryDirectory("weather");
    private readonly FakeTransport transport = new() { Body = Recorded };
    private readonly WeatherModule module;

    public WeatherModuleTests()
    {
        module = new WeatherModule(transport, directory, WeatherModule.UserAgent("1.1.0"), () => now);
    }

    public void Dispose()
    {
        try { Directory.Delete(directory, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static CallContext Widget(string installation = Owner, int queries = 8, int network = 32) => Context(Declared, installation: installation, domains: Domains, queries: queries, network: network);

    private static JsonObject Oslo(int? hours = null)
    {
        var options = new JsonObject { ["latitude"] = 59.91, ["longitude"] = 10.75 };
        if (hours is { } count) options["hours"] = count;
        return options;
    }

    private static JsonObject With(JsonObject target, string name, JsonNode? value)
    {
        target[name] = value;
        return target;
    }

    private static JsonNode? Node(object? value) => value switch
    {
        null => null,
        JsonNode node => node,
        string text => JsonValue.Create(text),
        bool flag => JsonValue.Create(flag),
        int whole => JsonValue.Create(whole),
        _ => JsonValue.Create(Convert.ToDouble(value)),
    };

    private static byte[] Series(params JsonObject[] items)
    {
        var series = new JsonArray();
        foreach (var item in items) series.Append(item);
        return Encoding.UTF8.GetBytes(Json.Stringify(new JsonObject { ["properties"] = new JsonObject { ["timeseries"] = series } }));
    }

    private static JsonObject Entry(string time, JsonObject details, JsonObject? next = null)
    {
        var data = new JsonObject { ["instant"] = new JsonObject { ["details"] = details } };
        if (next is not null) data["next_1_hours"] = next;
        return new JsonObject { ["time"] = time, ["data"] = data };
    }

    /// <summary>Instant details; <c>null</c> leaves the member out.</summary>
    private static JsonObject Details(object? temperature = null, object? wind = null, bool noTemperature = false, bool noWind = false)
    {
        var details = new JsonObject();
        if (!noTemperature) details["air_temperature"] = Node(temperature ?? 1.5);
        if (!noWind) details["wind_speed"] = Node(wind ?? 2.0);
        return details;
    }

    private static JsonArray Hours(JsonObject result) => result.OptArray("hours")!;
    private static JsonObject Hour(JsonObject result, int index) => (JsonObject)Hours(result)[index]!;

    [Fact]
    public void OptionValidationAndRounding()
    {
        var options = WeatherOptions.Parse(new JsonObject { ["latitude"] = 37.3349, ["longitude"] = -122.00902 });
        Assert.Equal(37.33, options.Latitude);
        Assert.Equal(-122.01, options.Longitude);
        Assert.Equal(24, options.Hours);
        Assert.Equal("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=37.33&lon=-122.01", options.Url);
        // Halves round away from zero, and whole numbers keep one decimal in the URL.
        Assert.Equal(0.13, WeatherOptions.Round2(0.125));
        Assert.Equal(-0.13, WeatherOptions.Round2(-0.125));
        Assert.Equal("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=60.0&lon=-180.0", WeatherOptions.Parse(new JsonObject { ["latitude"] = 60, ["longitude"] = -180 }).Url);
        Assert.Equal(48, WeatherOptions.Parse(Oslo(48)).Hours);
        Assert.Equal(1, WeatherOptions.Parse(Oslo(1)).Hours);
        JsonObject[] bad =
        [
            new JsonObject(), new JsonObject { ["latitude"] = 59.91 }, new JsonObject { ["longitude"] = 10.75 },
            With(Oslo(), "latitude", 90.01), With(Oslo(), "latitude", -90.01), With(Oslo(), "longitude", 180.5), With(Oslo(), "longitude", -181),
            With(Oslo(), "latitude", "59.91"), With(Oslo(), "latitude", true), With(Oslo(), "latitude", null),
            Oslo(0), Oslo(49), With(Oslo(), "hours", 1.5), With(Oslo(), "hours", "24"), With(Oslo(), "hours", null),
            With(Oslo(), "units", "imperial"), new JsonObject { ["invalid"] = true },
        ];
        foreach (var item in bad) AssertRejects("invalid_options", () => WeatherOptions.Parse(item));
    }

    [Fact]
    public void NormalizesARecordedMetNorwayPayload()
    {
        var result = WeatherRules.Normalize(Recorded, WeatherOptions.Parse(Oslo()), now);
        Assert.Equal(["provider", "attribution", "latitude", "longitude", "fetchedAt", "isStale", "hours"], result.Select(member => member.Key));
        Assert.Equal("MET Norway", result.OptString("provider"));
        Assert.Equal("{\"text\":\"Weather data from MET Norway\",\"url\":\"https://www.met.no/en/free-meteorological-data/Download-services\"}", Json.Stringify(result.OptObject("attribution")));
        Assert.Equal(59.91, result.OptDouble("latitude"));
        Assert.Equal(10.75, result.OptDouble("longitude"));
        Assert.Equal("2026-11-13T07:30:00Z", result.OptString("fetchedAt"));
        Assert.False(result.OptBoolean("isStale", true));
        Assert.Equal(24, Hours(result).Count);
        var first = Hour(result, 0);
        Assert.Equal(["time", "temperatureC", "windMetersPerSecond", "precipitationMM", "condition"], first.Select(member => member.Key));
        Assert.Equal("2026-11-13T07:00:00Z", first.OptString("time"));
        Assert.Equal(1.7, first.OptDouble("temperatureC"));
        Assert.Equal(3.0, first.OptDouble("windMetersPerSecond"));
        Assert.Equal(0.0, first.OptDouble("precipitationMM"));
        Assert.Equal("fair_day", first.OptString("condition"));
        Assert.Equal("2026-11-14T06:00:00Z", Hour(result, 23).OptString("time"));

        // Entries more than an hour old are skipped; the rest keep their order.
        var later = WeatherRules.Normalize(Recorded, WeatherOptions.Parse(Oslo(48)), IsoDates.Parse("2026-11-13T17:30:00Z")!.Value);
        Assert.Equal(48, Hours(later).Count);
        Assert.Equal("2026-11-13T17:00:00Z", Hour(later, 0).OptString("time"));
        // After the hourly part the provider has no next-hour data: both fields stay null.
        Assert.False(Hour(later, 42).IsNull("condition"));
        Assert.Equal("2026-11-15T12:00:00Z", Hour(later, 43).OptString("time"));
        for (var index = 43; index <= 47; index++)
        {
            Assert.True(Hour(later, index).Has("precipitationMM") && Hour(later, index).IsNull("precipitationMM"));
            Assert.True(Hour(later, index).Has("condition") && Hour(later, index).IsNull("condition"));
        }
        Assert.Single(Hours(WeatherRules.Normalize(Recorded, WeatherOptions.Parse(Oslo(1)), now)));
        // A forecast that is entirely in the past has no usable row.
        AssertRejects("unavailable", () => WeatherRules.Normalize(Recorded, WeatherOptions.Parse(Oslo()), IsoDates.Parse("2026-12-24T00:00:00Z")!.Value));
    }

    [Fact]
    public void NormalizationBounds()
    {
        var options = WeatherOptions.Parse(Oslo());
        JsonObject Normalize(byte[] body) => WeatherRules.Normalize(body, options, now);
        foreach (var body in new[] { "not json", "[]", "{}", "{\"properties\":{}}", "{\"properties\":{\"timeseries\":{}}}", "{\"properties\":{\"timeseries\":[1]}}", "{\"properties\":{\"timeseries\":[]}}" })
        {
            AssertRejects("unavailable", () => Normalize(Encoding.UTF8.GetBytes(body)));
        }
        // A repeated member name makes the document ambiguous: it is refused, not half read.
        AssertRejects("unavailable", () => Normalize(Encoding.UTF8.GetBytes("{\"properties\":{\"timeseries\":[]},\"properties\":{\"timeseries\":[]}}")));
        AssertRejects("unavailable", () => Normalize(Enumerable.Repeat((byte)' ', WeatherRules.MaximumResponseBytes + 1).ToArray()));
        JsonObject[] Many(int count) => Enumerable.Range(0, count).Select(_ => Entry("2026-11-13T08:00:00Z", Details())).ToArray();
        AssertRejects("unavailable", () => Normalize(Series(Many(301))));
        Assert.Equal(24, Hours(Normalize(Series(Many(300)))).Count);
        // Entries without a usable time or instant details are skipped, not fatal.
        var skipped = Normalize(Series(
            new JsonObject { ["time"] = 5 }, new JsonObject { ["time"] = "2026-11-13T08:00" }, new JsonObject { ["time"] = "2026-11-13T08:00:00Z" },
            new JsonObject { ["time"] = "2026-11-13T08:00:00Z", ["data"] = new JsonObject { ["instant"] = new JsonObject() } },
            Entry("2026-11-13T06:29:59Z", Details()), Entry("2026-11-13T06:30:00Z", Details(temperature: -40, wind: 0))));
        Assert.Single(Hours(skipped));
        Assert.Equal(-40.0, Hour(skipped, 0).OptDouble("temperatureC"));
        // Values outside the physical bounds reject the payload.
        JsonObject[] outOfBounds =
        [
            Details(temperature: 100.1), Details(temperature: -150.5), Details(noTemperature: true), Details(temperature: "1"),
            Details(wind: -0.1), Details(wind: 200.5), Details(noWind: true),
        ];
        foreach (var bad in outOfBounds) AssertRejects("invalid_options", () => Normalize(Series(Entry("2026-11-13T08:00:00Z", bad))));
        JsonObject Next(object? amount, object? symbol, bool nullAmount = false)
        {
            var next = new JsonObject();
            if (amount is not null || nullAmount) next["details"] = new JsonObject { ["precipitation_amount"] = Node(amount) };
            if (symbol is not null) next["summary"] = new JsonObject { ["symbol_code"] = Node(symbol) };
            return next;
        }
        AssertRejects("invalid_options", () => Normalize(Series(Entry("2026-11-13T08:00:00Z", Details(), Next(1000.5, null)))));
        AssertRejects("invalid_options", () => Normalize(Series(Entry("2026-11-13T08:00:00Z", Details(), Next(-1, null)))));
        AssertRejects("invalid_options", () => Normalize(Series(Entry("2026-11-13T08:00:00Z", Details(), Next(null, null, nullAmount: true)))));
        var row = Hour(Normalize(Series(Entry("2026-11-13T08:00:00Z", Details(), Next(1000, new string('x', 70))))), 0);
        Assert.Equal(1000.0, row.OptDouble("precipitationMM"));
        Assert.Equal(new string('x', 64), row.OptString("condition"));
        var untyped = Hour(Normalize(Series(Entry("2026-11-13T08:00:00Z", Details(), Next(null, 7)))), 0);
        Assert.True(untyped.IsNull("precipitationMM"));
        Assert.True(untyped.IsNull("condition"));
        // A condition is cut by characters, never through the middle of one.
        var emoji = string.Concat(Enumerable.Repeat(char.ConvertFromUtf32(0x1F327), 70));
        Assert.Equal(string.Concat(Enumerable.Repeat(char.ConvertFromUtf32(0x1F327), 64)), Hour(Normalize(Series(Entry("2026-11-13T08:00:00Z", Details(), Next(null, emoji)))), 0).OptString("condition"));
    }

    [Fact]
    public void CacheFreshnessRules()
    {
        var options = WeatherOptions.Parse(Oslo());
        var fetched = Json.Stringify(WeatherRules.Normalize(Recorded, options, now));
        JsonObject? Cached(long ageMilliseconds, WeatherOptions? query = null) => WeatherRules.FromCache(fetched, query ?? options, now + ageMilliseconds);
        Assert.False(Cached(0)!.OptBoolean("isStale", true));
        Assert.False(Cached(3_599_999)!.OptBoolean("isStale", true));
        Assert.True(Cached(3_600_000)!.OptBoolean("isStale"));
        Assert.True(Cached(6 * 3_600_000L)!.OptBoolean("isStale"));
        Assert.Null(Cached(6 * 3_600_000L + 1));
        Assert.Null(Cached(-1)); // fetched in the future: the clock moved
        // Fewer hours are served from a longer cache; more are not.
        Assert.Equal(6, Hours(Cached(0, WeatherOptions.Parse(Oslo(6)))!).Count);
        Assert.Null(Cached(0, WeatherOptions.Parse(Oslo(25))));
        // Other coordinates never match, even when they are close.
        Assert.Null(Cached(0, WeatherOptions.Parse(With(Oslo(), "latitude", 59.92))));
        Assert.Null(Cached(0, WeatherOptions.Parse(With(Oslo(), "longitude", -10.75))));
        foreach (var text in new[] { null, "", "not json", "{}", "{\"latitude\":59.91,\"longitude\":10.75,\"fetchedAt\":\"yesterday\",\"hours\":[]}", new string('x', WeatherRules.MaximumCacheBytes + 1) })
        {
            Assert.Null(WeatherRules.FromCache(text, options, now));
        }
    }

    [Fact]
    public void PolicyOrder()
    {
        AssertRejects("permission_denied", () => module.Forecast(Context(["network"], domains: Domains), Oslo()));
        AssertRejects("permission_denied", () => module.Forecast(Context(Declared, domains: Domains, runtime: "1.5"), Oslo()));
        AssertRejects("permission_denied", () => module.Forecast(Context(Declared, domains: Domains, hasManifest: false), Oslo()));
        AssertRejects("permission_denied", () => module.Forecast(Context(Declared, domains: Domains, installation: "preview"), Oslo()));
        AssertRejects("read_only", () => module.Forecast(Context(Declared, domains: Domains, projection: true), Oslo()));
        AssertRejects("read_only", () => module.Forecast(Context(Declared, domains: Domains, liveActivity: true), Oslo()));
        AssertRejects("query_limit", () => module.Forecast(Widget(queries: 0), Oslo()));
        // Options are checked before the network declaration.
        AssertRejects("invalid_options", () => module.Forecast(Context(["weather"]), Oslo(99)));
        AssertRejects("invalid_options", () => module.Forecast(Widget(), null));
        AssertRejects("permission_denied", () => module.Forecast(Context(["weather"], domains: Domains), Oslo()));
        AssertRejects("permission_denied", () => module.Forecast(Context(Declared), Oslo()));
        AssertRejects("permission_denied", () => module.Forecast(Context(Declared, domains: ["met.no", "*.example.com"]), Oslo()));
        AssertRejects("query_limit", () => module.Forecast(Widget(network: 0), Oslo()));
        Assert.Empty(transport.Urls); // nothing reached the network
        Assert.Equal(24, Hours(module.Forecast(Context(Declared, domains: ["*.met.no"]), Oslo())).Count);
    }

    [Fact]
    public void RequestShapeAndFreshCache()
    {
        var first = module.Forecast(Widget(), new JsonObject { ["latitude"] = 59.9149, ["longitude"] = 10.7461, ["hours"] = 12 });
        Assert.Equal(["https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.91&lon=10.75"], transport.Urls);
        Assert.Equal("ScriptWidget-Windows/1.1.0 https://github.com/everettjf/scriptwidget", Assert.Single(transport.Agents));
        Assert.Equal(3000, transport.Timeout);
        Assert.Equal(12, Hours(first).Count);
        Assert.False(first.OptBoolean("isStale", true));

        // Within the hour the cache answers without a request and without the network budget.
        now += 3_599_000;
        var second = module.Forecast(Widget(network: 0), Oslo(6));
        Assert.Single(transport.Urls);
        Assert.Equal(6, Hours(second).Count);
        Assert.False(second.OptBoolean("isStale", true));
        Assert.Equal("2026-11-13T07:30:00Z", second.OptString("fetchedAt"));
        // More hours than were cached, other coordinates and another installation all go to the network.
        module.Forecast(Widget(), Oslo(24));
        Assert.Equal(2, transport.Urls.Count);
        module.Forecast(Widget(), With(Oslo(), "latitude", 60));
        Assert.Equal(3, transport.Urls.Count);
        module.Forecast(Widget(OtherOwner), With(Oslo(), "latitude", 60));
        Assert.Equal(4, transport.Urls.Count);
        Assert.Equal("ScriptWidget-Windows/0 https://github.com/everettjf/scriptwidget", WeatherModule.UserAgent(""));
    }

    [Fact]
    public void StaleCacheStandsInForAFailedRequest()
    {
        module.Forecast(Widget(), Oslo());
        now += 3_600_000;
        transport.Fail = true;
        var stale = module.Forecast(Widget(), Oslo(3));
        Assert.True(stale.OptBoolean("isStale"));
        Assert.Equal(3, Hours(stale).Count);
        Assert.Equal("2026-11-13T07:30:00Z", stale.OptString("fetchedAt"));
        Assert.Equal(2, transport.Urls.Count);
        transport.Fail = false;
        foreach (var status in new[] { 304, 403, 429, 500 })
        {
            transport.Status = status;
            Assert.True(module.Forecast(Widget(), Oslo()).OptBoolean("isStale"));
        }
        transport.Status = 200;
        transport.Body = Encoding.UTF8.GetBytes("{}");
        Assert.True(module.Forecast(Widget(), Oslo()).OptBoolean("isStale"));
        // A stale cache is not returned when the network budget is spent: the request was never attempted.
        AssertRejects("query_limit", () => module.Forecast(Widget(network: 0), Oslo()));
        now += 5 * 3_600_000L + 1;
        AssertRejects("unavailable", () => module.Forecast(Widget(), Oslo()));
        transport.Fail = true;
        AssertRejects("unavailable", () => module.Forecast(Widget(), Oslo()));
        // A good response replaces the cache and is fresh again.
        transport.Fail = false;
        transport.Body = Recorded;
        now = IsoDates.Parse("2026-11-13T15:00:00Z")!.Value;
        var fresh = module.Forecast(Widget(), Oslo());
        Assert.False(fresh.OptBoolean("isStale", true));
        Assert.Equal("2026-11-13T15:00:00Z", fresh.OptString("fetchedAt"));
    }

    [Fact]
    public void RedirectsStayInsideTheDeclaredHostsAndCachesAreRetired()
    {
        transport.Redirect = new Uri("https://example.com/forecast");
        module.Forecast(Widget(), Oslo());
        Assert.Equal(false, transport.RedirectAllowed);
        transport.Redirect = new Uri("https://api.met.no/weatherapi/other");
        now += 3_600_000;
        module.Forecast(Widget(), Oslo());
        Assert.Equal(true, transport.RedirectAllowed);
        now += 3_600_000;
        module.Forecast(Context(Declared, domains: Domains, active: () => false), Oslo());
        Assert.Equal(false, transport.RedirectAllowed); // a finished execution follows no redirect

        var files = Directory.EnumerateFiles(directory).Select(Path.GetFileName).ToList();
        Assert.Equal([Canonical.OwnerFileName(Owner, ".json")], files);
        Assert.DoesNotContain(Owner, files.Single()); // the installation identity is not a file name
        module.Retire(Owner);
        Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        // A cache file that is not a regular bounded file is ignored, never trusted.
        File.WriteAllText(Path.Combine(directory, Canonical.OwnerFileName(Owner, ".json")), new string('x', WeatherRules.MaximumCacheBytes + 1));
        transport.Fail = true;
        AssertRejects("unavailable", () => module.Forecast(Widget(), Oslo()));
    }

    /// <summary>Windows only: the ISO-8601 reader is written by hand, so its edges are pinned here.</summary>
    [Fact]
    public void IsoDatesAcceptOnlyFullInstants()
    {
        Assert.Equal(1_794_484_800_000L, IsoDates.Parse("2026-11-12T12:00:00Z"));
        Assert.Equal(1_794_484_800_000L, IsoDates.Parse("2026-11-12T13:00:00+01:00"));
        Assert.Equal(1_794_484_800_000L, IsoDates.Parse("2026-11-12T06:30:00-05:30"));
        Assert.Equal(1_794_484_800_123L, IsoDates.Parse("2026-11-12T12:00:00.123456789Z"));
        Assert.Equal(1_794_484_800_500L, IsoDates.Parse("2026-11-12T12:00:00.5Z"));
        Assert.Equal(-1000L, IsoDates.Parse("1969-12-31T23:59:59Z"));
        foreach (var text in new[]
        {
            "", "2026-11-12", "2026-11-12T12:00:00", "2026-11-12T12:00Z", "2026-11-12 12:00:00Z", "2026-13-12T12:00:00Z", "2026-02-30T12:00:00Z", "2026-11-12T24:00:00Z",
            "2026-11-12T12:60:00Z", "2026-11-12T12:00:60Z", "2026-11-12T12:00:00+19:00", "2026-11-12T12:00:00+0100", "2026-11-12T12:00:00.Z", "2026-11-12T12:00:00Z\n", " 2026-11-12T12:00:00Z",
        })
        {
            Assert.Null(IsoDates.Parse(text));
        }
        Assert.Equal("2026-11-12T12:00:00Z", IsoDates.Format(1_794_484_800_999L));
        Assert.Equal("1969-12-31T23:59:59Z", IsoDates.Format(-1));
    }

    /// <summary>Windows only: the operation as the script bridge calls it, and the transport over <c>fetch</c>.</summary>
    [Fact]
    public void TheOperationResolvesOnceAndTheFetchTransportStaysOnDeclaredPublicHosts()
    {
        ExecutionRequest Execution(string[] domains, string packageID = Owner) => new()
        {
            Prepared = new PreparedPackage
            {
                Code = "",
                HasManifest = true,
                Manifest = new JsonObject { ["minimumRuntimeVersion"] = "1.6", ["permissions"] = Json.Array(Declared), ["networkDomains"] = Json.Array(domains) },
            },
            Files = new MemoryPackageFiles(new Dictionary<string, string>()),
            PackageID = packageID,
        };
        (bool OK, JsonNode? Value) Start(WeatherModule target, ExecutionRequest request, string operation = "weather.forecast")
        {
            using var finished = new ManualResetEventSlim();
            var outcomes = new List<(bool, string?)>();
            target.Start(request, operation, new JsonObject { ["options"] = Oslo(2) }, (ok, json) => { lock (outcomes) outcomes.Add((ok, json)); finished.Set(); });
            Assert.True(finished.Wait(TimeSpan.FromSeconds(15)), "the operation did not complete");
            var (succeeded, text) = Assert.Single(outcomes);
            return (succeeded, Json.Parse(text!));
        }
        INativeModule native = module;
        Assert.Equal(["$weather"], native.Apis);
        Assert.True(native.Handles("weather.forecast"));
        Assert.False(native.Handles("http.request"));

        var lines = new List<string>();
        var sink = SystemLog.Sink;
        SystemLog.Sink = line => { lock (lines) lines.Add(line); };
        try
        {
            var resolved = Start(module, Execution(Domains));
            Assert.True(resolved.OK);
            Assert.Equal(2, Hours((JsonObject)resolved.Value!).Count);
            var denied = Start(module, Execution(["example.com"], OtherOwner));
            Assert.False(denied.OK);
            Assert.Equal("[permission_denied] System operation could not complete. Existing user data is preserved.", denied.Value!.AsText());
            Assert.Equal("Unsupported operation weather.other", Start(module, Execution(Domains), "weather.other").Value!.AsText());
            lock (lines)
            {
                Assert.Contains("weather.forecast -> ok", lines);
                Assert.Contains("weather.forecast -> permission_denied", lines);
                Assert.DoesNotContain(lines, line => line.Contains("59.9", StringComparison.Ordinal) || line.Contains(Owner, StringComparison.Ordinal));
            }
        }
        finally
        {
            SystemLog.Sink = sink;
        }

        // The real transport: the forecast host must resolve to a public address, and a redirect must stay declared.
        var location = "https://api.met.no/weatherapi/locationforecast/2.0/moved";
        var handler = new FakeHandler(message => message.RequestUri!.AbsolutePath.EndsWith("/compact", StringComparison.Ordinal)
            ? FakeHandler.Redirect(307, location)
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Recorded) });
        var address = IPAddress.Parse("157.249.81.141");
        var online = new WeatherModule(new FetchWeatherTransport(new FetchModule(_ => [address], handler)), Path.Combine(directory, "fetch"), WeatherModule.UserAgent("1.0"), () => now);
        Assert.Equal(24, Hours(online.Forecast(Widget(), Oslo())).Count);
        Assert.Equal(["https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.91&lon=10.75", location], handler.Requests.Select(request => request.Uri.AbsoluteUri));
        Assert.Equal("ScriptWidget-Windows/1.0 https://github.com/everettjf/scriptwidget", handler.Requests[0].Headers["User-Agent"]);
        location = "https://example.com/forecast";
        AssertRejects("unavailable", () => online.Forecast(Widget(OtherOwner), Oslo()));
        location = "http://127.0.0.1/forecast";
        AssertRejects("unavailable", () => online.Forecast(Widget(OtherOwner), Oslo()));
        address = IPAddress.Parse("10.0.0.9");
        handler.Requests.Clear();
        AssertRejects("unavailable", () => online.Forecast(Widget(OtherOwner), Oslo()));
        Assert.Empty(handler.Requests);
    }
}
