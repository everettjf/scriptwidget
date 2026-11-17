using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Api;

/// <summary>
/// <c>$weather.forecast(options)</c> input.
///
/// Rules: closed fields (<c>latitude</c>, <c>longitude</c>, <c>hours</c>); latitude −90…90 and longitude −180…180,
/// rounded to two decimals before anything leaves the device; <c>hours</c> an integer 1…48, 24 when absent.
/// </summary>
public sealed class WeatherOptions(double latitude, double longitude, int hours)
{
    public const string Host = "api.met.no";
    private static readonly IReadOnlySet<string> AllowedFields = new HashSet<string> { "latitude", "longitude", "hours" };

    public double Latitude { get; } = latitude;
    public double Longitude { get; } = longitude;
    public int Hours { get; } = hours;

    /// <summary>The MET Norway compact forecast for the rounded coordinates.</summary>
    public string Url => $"https://{Host}/weatherapi/locationforecast/2.0/compact?lat={Decimal(Latitude)}&lon={Decimal(Longitude)}";

    /// <summary>Throws <see cref="SystemReject"/> <c>invalid_options</c> for any violation of the rules above.</summary>
    public static WeatherOptions Parse(JsonObject options)
    {
        SystemOptions.Fields(options, AllowedFields);
        var latitude = Round2(SystemOptions.Number(options["latitude"], -90.0, 90.0));
        var longitude = Round2(SystemOptions.Number(options["longitude"], -180.0, 180.0));
        var hours = options.Has("hours") ? SystemOptions.Integer(options["hours"], 1, 48) : 24;
        return new WeatherOptions(latitude, longitude, hours);
    }

    /// <summary>Two decimals, halves away from zero, as <c>rounded()</c> does in the Apple runtime.</summary>
    public static double Round2(double value)
    {
        var scaled = value * 100;
        return (scaled < 0 ? -Math.Floor(-scaled + 0.5) : Math.Floor(scaled + 0.5)) / 100;
    }

    /// <summary>Shortest decimal text with at least one decimal place (<c>60.0</c>), the form every platform puts in the URL.</summary>
    private static string Decimal(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        return text.Contains('.') || text.Contains('E') ? text : text + ".0";
    }
}

/// <summary>Pure rules of <c>$weather</c>: provider normalisation and the private cache.</summary>
public static class WeatherRules
{
    public const int MaximumResponseBytes = 2 * 1024 * 1024;
    public const int MaximumSeries = 300;
    public const int MaximumCacheBytes = 128 * 1024;
    /// <summary>A matching cache younger than this is returned without a request.</summary>
    public const long FreshMilliseconds = 3_600_000L;
    /// <summary>A matching cache up to this age may stand in for a failed request, marked <c>isStale</c>.</summary>
    public const long UsableMilliseconds = 6 * 3_600_000L;
    public const string Provider = "MET Norway";
    public const string AttributionText = "Weather data from MET Norway";
    public const string AttributionUrl = "https://www.met.no/en/free-meteorological-data/Download-services";

    /// <summary>
    /// Turns a MET Norway compact forecast into the documented result.
    ///
    /// - The body is at most 2 MiB and <c>properties.timeseries</c> is an array of at most 300 objects, else <c>unavailable</c>.
    /// - Entries older than one hour before <paramref name="nowMilliseconds"/>, or without a time and instant details, are skipped.
    /// - <c>air_temperature</c> must be −150…100 and <c>wind_speed</c> 0…200; a present <c>precipitation_amount</c>
    ///   must be 0…1000. A violation rejects the whole payload (<c>invalid_options</c>, the Apple runtime's code).
    /// - Missing precipitation and condition stay null; a condition is cut to 64 characters.
    /// - At most <c>options.Hours</c> rows; no usable row is <c>unavailable</c>.
    /// </summary>
    public static JsonObject Normalize(byte[] body, WeatherOptions options, long nowMilliseconds)
    {
        if (body.Length > MaximumResponseBytes) throw SystemServiceError.Unavailable.Reject();
        try
        {
            JsonArray? series;
            try { series = (Json.Parse(Encoding.UTF8.GetString(body)) as JsonObject).OptObject("properties").OptArray("timeseries"); }
            catch (JsonException) { series = null; }
            if (series is null || series.Count > MaximumSeries || series.Any(item => item is not JsonObject)) throw SystemServiceError.Unavailable.Reject();
            var rows = new JsonArray();
            foreach (var item in series.OfType<JsonObject>())
            {
                if (Text(item["time"]) is not { } time) continue;
                var date = string.IsNullOrWhiteSpace(time) || SystemOptions.HasControlCharacters(time) ? null : IsoDates.Parse(time);
                if (date is not { } instant || instant < nowMilliseconds - 3_600_000L) continue;
                if (item.OptObject("data") is not { } values || values.OptObject("instant").OptObject("details") is not { } details) continue;
                var temperature = SystemOptions.Number(details["air_temperature"], -150.0, 100.0);
                var wind = SystemOptions.Number(details["wind_speed"], 0.0, 200.0);
                var next = values.OptObject("next_1_hours");
                var nextDetails = next.OptObject("details");
                double? precipitation = nextDetails is not null && nextDetails.Has("precipitation_amount") ? SystemOptions.Number(nextDetails["precipitation_amount"], 0.0, 1000.0) : null;
                var symbol = Text(next.OptObject("summary")?["symbol_code"]);
                rows.Append(new JsonObject
                {
                    ["time"] = time,
                    ["temperatureC"] = temperature,
                    ["windMetersPerSecond"] = wind,
                    ["precipitationMM"] = precipitation is { } amount ? JsonValue.Create(amount) : null,
                    ["condition"] = symbol is null ? null : JsonValue.Create(FirstCodePoints(symbol, 64)),
                });
                if (rows.Count == options.Hours) break;
            }
            if (rows.Count == 0) throw SystemServiceError.Unavailable.Reject();
            return new JsonObject
            {
                ["provider"] = Provider,
                ["attribution"] = new JsonObject { ["text"] = AttributionText, ["url"] = AttributionUrl },
                ["latitude"] = options.Latitude,
                ["longitude"] = options.Longitude,
                ["fetchedAt"] = IsoDates.Format(nowMilliseconds),
                ["isStale"] = false,
                ["hours"] = rows,
            };
        }
        catch (ArgumentException)
        {
            // A repeated member name: the document does not say one thing, so it says nothing.
            throw SystemServiceError.Unavailable.Reject();
        }
    }

    /// <summary>
    /// A cached forecast that may answer <paramref name="options"/>, or null.
    ///
    /// It matches only when the rounded coordinates are equal, <c>fetchedAt</c> is not in the future and at
    /// most six hours old, and it holds at least the requested number of hours. The result carries the
    /// first <c>options.Hours</c> rows and <c>isStale</c> (true from one hour of age).
    /// </summary>
    public static JsonObject? FromCache(string? text, WeatherOptions options, long nowMilliseconds)
    {
        if (text is null || Encoding.UTF8.GetByteCount(text) > MaximumCacheBytes) return null;
        try
        {
            if (Json.Parse(text) is not JsonObject cached) return null;
            if (Coordinate(cached["latitude"]) != options.Latitude || Coordinate(cached["longitude"]) != options.Longitude) return null;
            if (Text(cached["fetchedAt"]) is not { } stamp || IsoDates.Parse(stamp) is not { } fetched) return null;
            var age = nowMilliseconds - fetched;
            if (cached.OptArray("hours") is not { } hours) return null;
            if (age < 0 || age > UsableMilliseconds || hours.Count < options.Hours) return null;
            var rows = new JsonArray();
            for (var index = 0; index < options.Hours; index++) rows.Append(hours[index].Copy());
            cached["hours"] = rows;
            cached["isStale"] = age >= FreshMilliseconds;
            return cached;
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            return null;
        }
    }

    private static double? Coordinate(JsonNode? node) => SystemOptions.JsonNumber(node);

    private static string? Text(JsonNode? node) => node.IsString() ? node!.GetValue<string>() : null;

    private static string FirstCodePoints(string text, int count)
    {
        var index = 0;
        for (var taken = 0; taken < count && index < text.Length; taken++)
        {
            index += char.IsHighSurrogate(text[index]) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]) ? 2 : 1;
        }
        return text[..index];
    }
}

/// <summary>A provider response: the HTTP status and the bounded body.</summary>
public sealed class WeatherResponse(int status, byte[] body)
{
    public int Status { get; } = status;
    public byte[] Body { get; } = body;
}

/// <summary>The network side of <c>$weather</c>, replaceable in tests. Implementations throw on any transport failure.</summary>
public interface IWeatherTransport
{
    /// <summary>One GET. <paramref name="allowRedirect"/> decides for every redirect target; a refused redirect is a failure.</summary>
    WeatherResponse Get(string url, IReadOnlyDictionary<string, string> headers, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation);
}

/// <summary><see cref="IWeatherTransport"/> over the bounded <c>fetch</c> transport: public hosts only, resolved addresses checked, at most 2 MiB.</summary>
public sealed class FetchWeatherTransport(FetchModule? fetch = null) : IWeatherTransport
{
    private readonly FetchModule fetch = fetch ?? new FetchModule();

    public WeatherResponse Get(string url, IReadOnlyDictionary<string, string> headers, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation)
    {
        var uri = new Uri(url, UriKind.Absolute);
        if (fetch.ValidationError(uri) is not null) throw new FetchModule.FetchException("blocked");
        var response = fetch.Perform("GET", uri, headers, null, timeoutMilliseconds, target => fetch.ValidationError(target) is null && allowRedirect(target), cancellation);
        return new WeatherResponse(response.Status, response.Body);
    }
}

/// <summary>
/// <c>$weather.forecast</c>: MET Norway's compact forecast for coordinates the script supplies. The
/// device location is never read here. The order of checks is the Apple runtime's:
/// 1. the system gate (<c>weather</c> declared by an installed Runtime 1.6 package, not a future
///    timeline entry or Live Activity, the eight-query budget);
/// 2. <c>invalid_options</c> for the options;
/// 3. <c>permission_denied</c> unless the package declares <c>network</c> and <c>api.met.no</c>;
/// 4. a matching cache younger than one hour is returned without a request;
/// 5. <c>query_limit</c> when the 32-request network budget of the execution is spent;
/// 6. the request (3 s timeout, redirects only to declared hosts); a failure returns a matching
///    cache up to six hours old with <c>isStale: true</c>, else the failure.
///
/// There is no per-widget native grant for weather: nothing is read from the device.
/// </summary>
public sealed class WeatherModule(IWeatherTransport transport, string directory, string userAgent, Func<long>? clock = null) : INativeModule
{
    public const string Permission = "weather";
    public const int TimeoutMilliseconds = 3_000;
    private static readonly IReadOnlySet<string> SupportedApis = new HashSet<string> { "$weather" };

    private readonly Func<long> clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    /// <summary>MET Norway asks every client to identify itself; no user or device detail is included.</summary>
    public static string UserAgent(string versionName) => $"ScriptWidget-Windows/{(versionName.Length == 0 ? "0" : versionName)} https://github.com/everettjf/scriptwidget";

    public IReadOnlySet<string> Apis => SupportedApis;

    public bool Handles(string operation) => operation.StartsWith("weather.", StringComparison.Ordinal);

    public void Start(ExecutionRequest request, string operation, JsonObject? payload, NativeCompletion done)
    {
        var context = CallContext.From(request);
        if (operation == "weather.forecast") SystemExecutor.Run(operation, done, () => Json.Stringify(Forecast(context, payload.OptObject("options"))));
        else done(false, Json.Quote($"Unsupported operation {operation}"));
    }

    public JsonObject Forecast(CallContext context, JsonObject? options)
    {
        SystemGate.Check(context, Permission, writing: false);
        var query = WeatherOptions.Parse(options ?? new JsonObject());
        if (!context.AllowsHost(WeatherOptions.Host)) throw SystemServiceError.PermissionDenied.Reject();
        var cache = Cache(context.Installation);
        JsonObject? cached;
        lock (cache.Lock)
        {
            string? stored;
            try { stored = cache.Read(); } catch (PrivateFile.Unreadable) { stored = null; }
            cached = WeatherRules.FromCache(stored, query, clock());
        }
        if (cached is not null && !cached.OptBoolean("isStale")) return cached;
        if (!context.ConsumeNetworkRequest()) throw SystemServiceError.QueryLimit.Reject();
        try
        {
            WeatherResponse response;
            try
            {
                response = transport.Get(query.Url, new Dictionary<string, string> { ["User-Agent"] = userAgent }, TimeoutMilliseconds,
                    target => context.IsActive && context.AllowsHost(target.Host), context.Cancellation);
            }
            catch (Exception) { throw SystemServiceError.Unavailable.Reject(); }
            SystemGate.Validate(context, Permission, writing: false);
            if (!context.AllowsHost(WeatherOptions.Host) || response.Status != 200) throw SystemServiceError.Unavailable.Reject();
            var normalized = WeatherRules.Normalize(response.Body, query, clock());
            var encoded = Json.Stringify(normalized);
            if (Encoding.UTF8.GetByteCount(encoded) > WeatherRules.MaximumCacheBytes) throw SystemServiceError.LimitExceeded.Reject();
            bool written;
            lock (cache.Lock) written = cache.Write(encoded);
            if (!written) throw SystemServiceError.Unavailable.Reject();
            return normalized;
        }
        catch (SystemReject) when (cached is not null)
        {
            return cached;
        }
    }

    /// <summary>Removes the forecast cache of a deleted installation.</summary>
    public void Retire(string installation)
    {
        if (CallContext.IsOwner(installation)) Cache(installation).Delete();
        SystemLog.Call("weather.retire", "ok");
    }

    /// <summary>One forecast per installation, outside every script-reachable path.</summary>
    private PrivateFile Cache(string installation) => new(Path.Combine(directory, Canonical.OwnerFileName(installation, ".json")), WeatherRules.MaximumCacheBytes);
}
