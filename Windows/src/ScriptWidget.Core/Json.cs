using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ScriptWidget.Core;

/// <summary>
/// JSON helpers over <see cref="JsonNode"/> with the lenient accessors of
/// org.json, which the Android implementation this code is ported from uses.
/// Objects keep insertion order. Nothing here uses reflection, so it works
/// under native AOT.
/// </summary>
public static class Json
{
    private static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private static readonly JsonSerializerOptions Indented = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = true };
    private static readonly JsonDocumentOptions Strict = new() { AllowTrailingCommas = false, CommentHandling = JsonCommentHandling.Disallow, MaxDepth = 256 };

    /// <summary>Parses JSON text; throws <see cref="JsonException"/> when it is malformed.</summary>
    public static JsonNode? Parse(string text) => JsonNode.Parse(text, null, Strict);

    public static JsonObject ParseObject(string text) => Parse(text) as JsonObject ?? throw new JsonException("Expected a JSON object");

    public static JsonNode? TryParse(string? text)
    {
        if (text is null) return null;
        try { return Parse(text); } catch (JsonException) { return null; }
    }

    public static string Stringify(JsonNode? node, bool indented = false) => node is null ? "null" : node.ToJsonString(indented ? Indented : Compact);

    /// <summary>A JSON string literal, quotes included.</summary>
    public static string Quote(string? text) => text is null ? "null" : Stringify(JsonValue.Create(text));

    public static JsonArray Array(IEnumerable<string> items)
    {
        var array = new JsonArray();
        foreach (var item in items) array.Add((JsonNode)JsonValue.Create(item));
        return array;
    }

    public static JsonObject Object(IEnumerable<KeyValuePair<string, string>> items)
    {
        var result = new JsonObject();
        foreach (var (key, value) in items) result[key] = value;
        return result;
    }

    /// <summary>
    /// Adds a node to an array. Use this instead of <c>JsonArray.Add</c>, whose
    /// generic overload wins for JsonObject and JsonValue arguments and is not
    /// safe under native AOT.
    /// </summary>
    public static JsonArray Append(this JsonArray array, JsonNode? node) { array.Add(node); return array; }

    public static JsonArray Append(this JsonArray array, string? text) { array.Add((JsonNode?)(text is null ? null : JsonValue.Create(text))); return array; }

    // MARK: - Lenient accessors

    public static bool Has(this JsonObject json, string name) => json.ContainsKey(name);

    /// <summary>True when the member is missing or null.</summary>
    public static bool IsNull(this JsonObject json, string name) => !json.TryGetPropertyValue(name, out var value) || value is null;

    public static JsonObject? OptObject(this JsonObject? json, string name) => json is not null && json.TryGetPropertyValue(name, out var value) ? value as JsonObject : null;

    public static JsonArray? OptArray(this JsonObject? json, string name) => json is not null && json.TryGetPropertyValue(name, out var value) ? value as JsonArray : null;

    /// <summary>The member as text; numbers and booleans are converted, like org.json's optString.</summary>
    public static string OptString(this JsonObject? json, string name, string fallback = "")
    {
        if (json is null || !json.TryGetPropertyValue(name, out var value) || value is null) return fallback;
        return value.AsText() ?? fallback;
    }

    public static string? OptStringOrNull(this JsonObject? json, string name)
    {
        if (json is null || !json.TryGetPropertyValue(name, out var value) || value is null) return null;
        return value.AsText();
    }

    public static bool OptBoolean(this JsonObject? json, string name, bool fallback = false)
    {
        if (json is null || !json.TryGetPropertyValue(name, out var value) || value is not JsonValue item) return fallback;
        if (item.TryGetValue<bool>(out var flag)) return flag;
        if (item.TryGetValue<string>(out var text)) return text.Equals("true", StringComparison.OrdinalIgnoreCase) || (!text.Equals("false", StringComparison.OrdinalIgnoreCase) && fallback);
        return fallback;
    }

    public static double OptDouble(this JsonObject? json, string name, double fallback = double.NaN)
    {
        if (json is null || !json.TryGetPropertyValue(name, out var value) || value is null) return fallback;
        return value.AsDouble() ?? fallback;
    }

    public static int OptInt(this JsonObject? json, string name, int fallback = 0)
    {
        var number = json.OptDouble(name);
        return double.IsNaN(number) ? fallback : (int)Math.Clamp(number, int.MinValue, int.MaxValue);
    }

    public static long OptLong(this JsonObject? json, string name, long fallback = 0)
    {
        var number = json.OptDouble(name);
        return double.IsNaN(number) ? fallback : (long)Math.Clamp(number, long.MinValue, long.MaxValue);
    }

    /// <summary>Text of a scalar node; null for objects and arrays.</summary>
    public static string? AsText(this JsonNode node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<string>(out var text)) return text;
        if (value.TryGetValue<bool>(out var flag)) return flag ? "true" : "false";
        return value.ToJsonString();
    }

    public static double? AsDouble(this JsonNode node)
    {
        if (node is not JsonValue value) return null;
        // A value built in memory holds its CLR type (int, float, decimal…), a parsed one a JSON
        // element; the JSON text of a number is the one form every case shares.
        var text = value.GetValueKind() switch
        {
            JsonValueKind.Number => value.ToJsonString(),
            JsonValueKind.String => value.TryGetValue<string>(out var content) ? content : null,
            _ => null,
        };
        return text is not null && double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
    }

    public static bool IsString(this JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out _);

    public static bool IsNumber(this JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.Number;

    public static bool IsBoolean(this JsonNode? node) => node is JsonValue value && value.GetValueKind() is JsonValueKind.True or JsonValueKind.False;

    /// <summary>A detached copy that can be added to another object or array.</summary>
    public static JsonNode? Copy(this JsonNode? node) => node?.DeepClone();
}
