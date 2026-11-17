using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;

namespace ScriptWidget.Core.Plugins;

/// <summary>A fully resolved plugin request: nothing in it is taken from script input without validation.</summary>
public sealed class PreparedDataSourceRequest(PluginManifest plugin, PluginOperation operation, string method, Uri uri, IReadOnlyDictionary<string, string> headers, byte[]? body)
{
    public PluginManifest Plugin { get; } = plugin;
    public PluginOperation Operation { get; } = operation;
    public string Method { get; } = method;
    public Uri Uri { get; } = uri;
    public IReadOnlyDictionary<string, string> Headers { get; } = headers;
    /// <summary>JSON body built from <c>jsonBody</c> parameters, or null when there are none.</summary>
    public byte[]? Body { get; } = body;
}

/// <summary>Maps an operation and script-supplied values to one request, ported from <c>DataSourceRequestBuilder.prepare</c>.</summary>
public static class DataSourceRequestBuilder
{
    /// <summary>Sent with every plugin request, replacing any <c>User-Agent</c> header parameter.</summary>
    public const string UserAgent = "ScriptWidget-DataSource/1";

    // CharacterSet.urlPathAllowed without "/?#{}": a path value can never add a segment, a query or a fragment.
    private const string PathAllowed = "-._~!$&'()*+,=:@";
    // What URLComponents.queryItems leaves unescaped: "&" and "=" are always encoded, so a value cannot add a query item.
    private const string QueryAllowed = "-._~!$'()*+,;:@/?";

    /// <summary>
    /// Builds the request for <paramref name="operationID"/> of <paramref name="plugin"/>.
    ///
    /// <paramref name="values"/> come from package code and are untrusted. Accepted value types are <c>string</c>,
    /// <c>bool</c>, the numeric types, a <see cref="JsonValue"/> holding one of those, and (for <c>jsonBody</c>
    /// parameters only) <see cref="JsonObject"/>/<see cref="JsonArray"/>; <c>null</c> means "not supplied".
    /// Booleans are sent as <c>1</c>/<c>0</c> in path, query and header positions, which is what the Swift
    /// runtime sends for a JavaScript boolean.
    ///
    /// Security rules:
    /// - only declared parameters are used; anything else in <paramref name="values"/> is ignored, so a script
    ///   cannot add headers, query items or body fields the plugin did not declare;
    /// - path values are percent-encoded including <c>/</c>, <c>?</c>, <c>#</c>, and <c>.</c>/<c>..</c> values are refused,
    ///   so a value cannot change the path structure;
    /// - query names and values are percent-encoded including <c>&amp;</c> and <c>=</c>;
    /// - header values with control characters are refused (no header injection);
    /// - the final URL must be HTTPS and its host must match the plugin's declared hosts.
    /// </summary>
    /// <exception cref="PluginException"><c>NotFound</c> for an unknown operation, <c>InvalidParameters</c> for a
    /// missing or unusable value, <c>Permission</c> when the URL leaves the declared hosts.</exception>
    public static PreparedDataSourceRequest Prepare(PluginManifest plugin, string operationID, IReadOnlyDictionary<string, object?> values)
    {
        var operation = plugin.Operations.FirstOrDefault(item => item.Id == operationID)
            ?? throw new PluginException(PluginErrorKind.NotFound, $"Operation {operationID} was not found in {plugin.Id}.");
        var path = operation.Path;
        var query = new List<(string Name, string Value)>();
        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var body = new JsonObject();
        foreach (var parameter in operation.Parameters)
        {
            var supplied = Unwrap(values.GetValueOrDefault(parameter.Id));
            var raw = supplied ?? parameter.DefaultValue;
            var structured = raw is JsonObject or JsonArray;
            var text = structured || raw is null ? "" : Describe(raw) ?? throw InvalidParameters($"Could not encode {parameter.Id}.");
            if (raw is null || (!structured && text.Length == 0))
            {
                if (parameter.Required) throw InvalidParameters($"Missing required parameter {parameter.Id}.");
                continue;
            }
            if (structured && parameter.Location != PluginParameterLocation.JsonBody) throw InvalidParameters($"Could not encode {parameter.Id}.");
            switch (parameter.Location)
            {
                case PluginParameterLocation.Path:
                    if (text is "." or "..") throw InvalidParameters($"Could not encode {parameter.Id}.");
                    path = path.Replace("{" + parameter.Id + "}", PercentEncode(text, PathAllowed), StringComparison.Ordinal);
                    break;
                case PluginParameterLocation.Query:
                    query.Add((parameter.Id, text));
                    break;
                case PluginParameterLocation.Header:
                    if (text.Any(character => character < ' ' || character == '\u007F')) throw InvalidParameters($"Could not encode {parameter.Id}.");
                    headers[parameter.Id] = text;
                    break;
                default:
                    body[parameter.Id] = raw switch
                    {
                        JsonNode node => node.DeepClone(),
                        string value => JsonValue.Create(value),
                        bool value => JsonValue.Create(value),
                        double value => JsonValue.Create(value),
                        float or decimal => JsonValue.Create(Convert.ToDouble(raw, CultureInfo.InvariantCulture)),
                        _ => JsonValue.Create(Convert.ToInt64(raw, CultureInfo.InvariantCulture)),
                    };
                    break;
            }
        }
        if (path.Contains('{') || path.Contains('}')) throw InvalidParameters("A path parameter is unresolved.");
        var address = PluginUrl.Parse(plugin.BaseURL);
        var baseHost = address?.Host;
        if (address?.Scheme is null || string.IsNullOrEmpty(baseHost)) throw new PluginException(PluginErrorKind.InvalidManifest, "Invalid plugin baseURL.");
        var basePath = address.RawPath;
        var assembled = new StringBuilder()
            .Append(address.Scheme.ToLowerInvariant()).Append("://").Append(baseHost)
            .Append(address.Port >= 0 ? ":" + address.Port.ToString(CultureInfo.InvariantCulture) : "")
            .Append(basePath == "/" ? "" : basePath).Append(path);
        if (query.Count > 0) assembled.Append('?').Append(string.Join("&", query.Select(item => PercentEncode(item.Name, QueryAllowed) + "=" + PercentEncode(item.Value, QueryAllowed))));
        var url = assembled.ToString();
        var parsed = PluginUrl.Parse(url) ?? throw new PluginException(PluginErrorKind.InvalidManifest, "Invalid plugin baseURL.");
        var host = parsed.Host?.ToLowerInvariant();
        if (parsed.Scheme != "https" || host is null || !RuntimePolicy.HostMatches(host, plugin.Hosts))
        {
            throw new PluginException(PluginErrorKind.Permission, "Plugin request escaped its declared hosts.");
        }
        // The transport sends what System.Uri understood, so the same rule is applied to its reading of the URL.
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) throw new PluginException(PluginErrorKind.InvalidManifest, "Invalid plugin baseURL.");
        if (uri.Scheme != "https" || uri.UserInfo.Length > 0 || !RuntimePolicy.HostMatches(uri.Host, plugin.Hosts))
        {
            throw new PluginException(PluginErrorKind.Permission, "Plugin request escaped its declared hosts.");
        }
        foreach (var name in headers.Keys.Where(name => name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase) || (name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase) && body.Count > 0)).ToList())
        {
            headers.Remove(name);
        }
        headers["User-Agent"] = UserAgent;
        var bodyBytes = body.Count > 0 ? Encoding.UTF8.GetBytes(Json.Stringify(body)) : null;
        if (bodyBytes is not null) headers["Content-Type"] = "application/json";
        return new PreparedDataSourceRequest(plugin, operation, operation.Method, uri, headers, bodyBytes);
    }

    /// <summary>A JSON scalar becomes its CLR value; JSON null and null both mean "not supplied".</summary>
    private static object? Unwrap(object? value)
    {
        if (value is not JsonValue scalar) return value;
        switch (scalar.GetValueKind())
        {
            case JsonValueKind.String: return scalar.GetValue<string>();
            case JsonValueKind.True: return true;
            case JsonValueKind.False: return false;
            case JsonValueKind.Null: return null;
            case JsonValueKind.Number:
                // The text of the number decides, so a node made from any numeric type reads the same.
                var literal = scalar.ToJsonString();
                if (long.TryParse(literal, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var whole)) return whole;
                return double.TryParse(literal, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : double.NaN;
            default: return scalar;
        }
    }

    /// <summary>Text form of a scalar value, or null when it has none (non-finite numbers, unsupported types).</summary>
    private static string? Describe(object raw)
    {
        switch (raw)
        {
            case string value: return value;
            case bool value: return value ? "1" : "0";
            case int or long or short or sbyte or byte or ushort or uint or ulong or System.Numerics.BigInteger:
                return Convert.ToString(raw, CultureInfo.InvariantCulture);
            case float or double or decimal:
            {
                var value = Convert.ToDouble(raw, CultureInfo.InvariantCulture);
                if (double.IsNaN(value) || double.IsInfinity(value)) return null;
                if (value == Math.Round(value, MidpointRounding.ToEven) && Math.Abs(value) < 1e15) return ((long)value).ToString(CultureInfo.InvariantCulture);
                return Plain(value);
            }
            default: return null;
        }
    }

    /// <summary>The shortest decimal text that reads back as <paramref name="value"/>, without an exponent.</summary>
    private static string Plain(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        var exponentAt = text.IndexOf('E');
        if (exponentAt < 0) return text;
        var exponent = int.Parse(text[(exponentAt + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var mantissa = text[..exponentAt];
        var negative = mantissa.StartsWith('-');
        if (negative) mantissa = mantissa[1..];
        var point = mantissa.IndexOf('.');
        var digits = mantissa.Replace(".", "", StringComparison.Ordinal);
        var position = (point < 0 ? mantissa.Length : point) + exponent;
        string plain;
        if (position <= 0) plain = "0." + new string('0', -position) + digits;
        else if (position >= digits.Length) plain = digits + new string('0', position - digits.Length);
        else plain = digits[..position] + "." + digits[position..];
        return (negative ? "-" : "") + plain;
    }

    /// <summary>Percent-encodes every UTF-8 byte that is not an ASCII letter, digit or in <paramref name="allowed"/>.</summary>
    internal static string PercentEncode(string value, string allowed)
    {
        var output = new StringBuilder();
        foreach (var item in Encoding.UTF8.GetBytes(value))
        {
            var character = (char)item;
            if (char.IsAsciiLetterOrDigit(character) || allowed.Contains(character)) output.Append(character);
            else output.Append('%').Append(item.ToString("X2", CultureInfo.InvariantCulture));
        }
        return output.ToString();
    }

    private static PluginException InvalidParameters(string message) => new(PluginErrorKind.InvalidParameters, message);
}

/// <summary>Turns an HTTP response into the value a widget receives, as the Swift runtime bridge does.</summary>
public static class DataSourceResponseMapper
{
    /// <summary><c>ScriptWidgetFetchManager.maximumResponseBytes</c>: plugin responses share the 2 MiB fetch limit.</summary>
    public const int MaximumResponseBytes = FetchModule.MaximumResponseBytes;

    /// <summary>
    /// Returns the JSON text delivered to the script: the response document itself for a <c>json</c>
    /// operation, or a JSON string literal for a <c>text</c> operation.
    ///
    /// Fails closed with <see cref="PluginErrorKind.Network"/>: a non-2xx status, more than 2 MiB, a
    /// <c>json</c> body that is not one well-formed UTF-8 JSON object or array, or a <c>text</c> body that
    /// is not valid UTF-8. Response content is never included in the error message.
    /// </summary>
    public static string Map(PluginOperation operation, int status, byte[] body)
    {
        if (status is < 200 or > 299) throw Network("Data source request failed");
        if (body.Length > MaximumResponseBytes) throw Network("Data source response exceeds 2 MiB.");
        var text = PluginValidator.DecodeUtf8(body);
        if (operation.ResponseType == PluginResponseType.Text) return StrictJson.Quote(text ?? throw Network("Data source returned non-UTF-8 text"));
        StrictJson.Kind kind;
        try { kind = StrictJson.Validate(text ?? throw Network("Data source returned invalid JSON")); }
        catch (StrictJson.JsonException) { throw Network("Data source returned invalid JSON"); }
        // JSONSerialization without .fragmentsAllowed accepts only containers at the top level.
        if (kind != StrictJson.Kind.Object && kind != StrictJson.Kind.Array) throw Network("Data source returned invalid JSON");
        return text;
    }

    private static PluginException Network(string message) => new(PluginErrorKind.Network, message);
}
