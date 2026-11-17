using System.Globalization;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Api;

namespace ScriptWidget.Core.Plugins;

/// <summary>Where a parameter value goes in the request (<c>DataSourceParameterLocation</c> in Swift).</summary>
public enum PluginParameterLocation { Path, Query, Header, JsonBody }

/// <summary>How a response body is handed to the widget (<c>DataSourceResponseType</c> in Swift).</summary>
public enum PluginResponseType { Json, Text }

/// <summary>The names the enumerations have in <c>plugin.json</c>.</summary>
public static class PluginWireNames
{
    public static string WireName(this PluginParameterLocation location) => location switch
    {
        PluginParameterLocation.Path => "path",
        PluginParameterLocation.Query => "query",
        PluginParameterLocation.Header => "header",
        _ => "jsonBody",
    };

    public static string WireName(this PluginResponseType type) => type == PluginResponseType.Json ? "json" : "text";

    public static PluginParameterLocation? ParameterLocation(string name) => name switch
    {
        "path" => PluginParameterLocation.Path,
        "query" => PluginParameterLocation.Query,
        "header" => PluginParameterLocation.Header,
        "jsonBody" => PluginParameterLocation.JsonBody,
        _ => null,
    };

    public static PluginResponseType? ResponseType(string name) => name switch
    {
        "json" => PluginResponseType.Json,
        "text" => PluginResponseType.Text,
        _ => null,
    };
}

/// <summary>One declared operation parameter. A plugin can only place values where it declared them.</summary>
public sealed record PluginParameter(string Id, string Label, PluginParameterLocation Location, bool Required, string? DefaultValue = null);

/// <summary>One declared HTTPS request template.</summary>
public sealed record PluginOperation(string Id, string Title, string Method, string Path, PluginResponseType ResponseType, IReadOnlyList<PluginParameter> Parameters)
{
    public bool Equals(PluginOperation? other) =>
        other is not null && Id == other.Id && Title == other.Title && Method == other.Method && Path == other.Path && ResponseType == other.ResponseType && Parameters.SequenceEqual(other.Parameters);

    public override int GetHashCode() => HashCode.Combine(Id, Title, Method, Path, ResponseType, Parameters.Count);
}

/// <summary>
/// A Data Source Plugin 1.0 manifest (<c>plugin.json</c>). It is data: a mapping from parameters to
/// HTTPS requests against the hosts it declares. It carries no code and no permissions.
/// </summary>
public sealed record PluginManifest(
    int FormatVersion,
    string Id,
    string Name,
    string Version,
    string Summary,
    string Symbol,
    string Author,
    string License,
    string MinimumRuntimeVersion,
    string BaseURL,
    IReadOnlyList<string> Hosts,
    IReadOnlyList<PluginOperation> Operations)
{
    /// <summary>The only supported <c>formatVersion</c>; any other value fails closed.</summary>
    public const int CurrentFormatVersion = 1;

    public bool Equals(PluginManifest? other) =>
        other is not null && FormatVersion == other.FormatVersion && Id == other.Id && Name == other.Name && Version == other.Version && Summary == other.Summary &&
        Symbol == other.Symbol && Author == other.Author && License == other.License && MinimumRuntimeVersion == other.MinimumRuntimeVersion && BaseURL == other.BaseURL &&
        Hosts.SequenceEqual(other.Hosts) && Operations.SequenceEqual(other.Operations);

    public override int GetHashCode() => HashCode.Combine(FormatVersion, Id, Name, Version, BaseURL, Hosts.Count, Operations.Count);

    /// <summary>
    /// <c>plugin.json</c> text with sorted keys and two-space indentation, the form Swift writes
    /// (<c>.prettyPrinted, .sortedKeys, .withoutEscapingSlashes</c>). An absent <c>defaultValue</c> is omitted.
    /// </summary>
    public string ToJson()
    {
        static string Q(string value) => StrictJson.Quote(value);
        var output = new StringBuilder("{\n");
        output.Append($"  \"author\": {Q(Author)},\n");
        output.Append($"  \"baseURL\": {Q(BaseURL)},\n");
        output.Append($"  \"formatVersion\": {FormatVersion.ToString(CultureInfo.InvariantCulture)},\n");
        output.Append($"  \"hosts\": [{string.Join(", ", Hosts.Select(Q))}],\n");
        output.Append($"  \"id\": {Q(Id)},\n");
        output.Append($"  \"license\": {Q(License)},\n");
        output.Append($"  \"minimumRuntimeVersion\": {Q(MinimumRuntimeVersion)},\n");
        output.Append($"  \"name\": {Q(Name)},\n");
        output.Append("  \"operations\": [");
        for (var index = 0; index < Operations.Count; index++)
        {
            var operation = Operations[index];
            output.Append(index == 0 ? "\n" : ",\n");
            output.Append("    {\n");
            output.Append($"      \"id\": {Q(operation.Id)},\n");
            output.Append($"      \"method\": {Q(operation.Method)},\n");
            output.Append("      \"parameters\": [");
            for (var parameterIndex = 0; parameterIndex < operation.Parameters.Count; parameterIndex++)
            {
                var parameter = operation.Parameters[parameterIndex];
                output.Append(parameterIndex == 0 ? "\n" : ",\n");
                output.Append("        {");
                if (parameter.DefaultValue is not null) output.Append($"\"defaultValue\": {Q(parameter.DefaultValue)}, ");
                output.Append($"\"id\": {Q(parameter.Id)}, \"label\": {Q(parameter.Label)}, ");
                output.Append($"\"location\": {Q(parameter.Location.WireName())}, \"required\": {(parameter.Required ? "true" : "false")}}}");
            }
            output.Append(operation.Parameters.Count == 0 ? "],\n" : "\n      ],\n");
            output.Append($"      \"path\": {Q(operation.Path)},\n");
            output.Append($"      \"responseType\": {Q(operation.ResponseType.WireName())},\n");
            output.Append($"      \"title\": {Q(operation.Title)}\n");
            output.Append("    }");
        }
        output.Append(Operations.Count == 0 ? "],\n" : "\n  ],\n");
        output.Append($"  \"summary\": {Q(Summary)},\n");
        output.Append($"  \"symbol\": {Q(Symbol)},\n");
        output.Append($"  \"version\": {Q(Version)}\n");
        output.Append("}\n");
        return output.ToString();
    }
}

/// <summary>What went wrong in the plugin layer (the cases of <c>DataSourcePluginError</c> in Swift).</summary>
public enum PluginErrorKind { InvalidManifest, NotFound, Permission, InvalidParameters, Network, Storage }

/// <summary>
/// The single failure type of the plugin layer, mirroring <c>DataSourcePluginError</c> in Swift.
/// <see cref="Exception.Message"/> is the text shown to the user or passed to the script's rejection handler.
/// </summary>
public sealed class PluginException(PluginErrorKind kind, string message, Exception? cause = null) : Exception(message, cause)
{
    public PluginErrorKind Kind { get; } = kind;
}

/// <summary>One reason a manifest is refused. <see cref="Id"/> is the stable Swift issue identifier.</summary>
public sealed record PluginValidationIssue(string Id, string Message);

/// <summary>
/// Strict decoder and validator for <c>plugin.json</c>, ported from <c>DataSourcePluginValidator</c>.
/// Plugin manifests are untrusted (imported ZIPs, shared files); everything not explicitly
/// allowed is refused.
/// </summary>
public static partial class PluginValidator
{
    /// <summary><c>DataSourcePluginValidator.maximumManifestBytes</c>: bounds parsing work for an untrusted file.</summary>
    public const int MaximumManifestBytes = 256 * 1024;
    /// <summary><c>DataSourcePluginValidator.maximumOperations</c>.</summary>
    public const int MaximumOperations = 50;
    /// <summary><c>DataSourcePluginValidator.maximumParameters</c> (per operation).</summary>
    public const int MaximumParameters = 30;
    /// <summary>Most host declarations a plugin may carry.</summary>
    public const int MaximumHosts = 20;
    /// <summary>Longest plugin name, in user-perceived characters.</summary>
    public const int MaximumNameCharacters = 80;
    /// <summary><c>ScriptWidgetBuildContract.runtimeAPIVersion</c>: the only <c>minimumRuntimeVersion</c> accepted.</summary>
    public const string RuntimeApiVersion = "1.0";

    private static readonly HashSet<string> RootKeys = ["formatVersion", "id", "name", "version", "summary", "symbol", "author", "license", "minimumRuntimeVersion", "baseURL", "hosts", "operations"];
    private static readonly HashSet<string> OperationKeys = ["id", "title", "method", "path", "responseType", "parameters"];
    private static readonly HashSet<string> ParameterKeys = ["id", "label", "location", "required", "defaultValue"];
    private static readonly HashSet<string> Methods = ["GET", "POST", "PUT", "PATCH", "DELETE"];

    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9.-]{2,127}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Identifier();
    [GeneratedRegex(@"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z", RegexOptions.CultureInvariant)]
    private static partial Regex SemanticVersion();
    [GeneratedRegex(@"\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z", RegexOptions.CultureInvariant)]
    private static partial Regex HeaderName();
    [GeneratedRegex(@"\A[a-z0-9*.-]+\z", RegexOptions.CultureInvariant)]
    private static partial Regex HostDeclaration();
    [GeneratedRegex(@"\{([A-Za-z0-9.-]+)\}", RegexOptions.CultureInvariant)]
    private static partial Regex Placeholder();

    /// <summary>
    /// Decodes and validates <c>plugin.json</c> bytes.
    ///
    /// Security rules, each failing closed with <see cref="PluginErrorKind.InvalidManifest"/>:
    /// - at most 256 KiB, strict UTF-8, strict JSON with no duplicate keys;
    /// - unknown keys at any level are rejected, so a future or misspelled capability is never
    ///   silently ignored;
    /// - every field must be present with its exact JSON type (no coercion);
    /// - then every rule of <see cref="Validate"/>.
    /// </summary>
    public static PluginManifest Decode(byte[] data)
    {
        if (data.Length > MaximumManifestBytes) throw Invalid("plugin.json exceeds 256 KiB.");
        var text = DecodeUtf8(data) ?? throw Invalid("plugin.json must be UTF-8 JSON.");
        object? parsed;
        try { parsed = StrictJson.Parse(text); }
        catch (StrictJson.JsonException) { throw Invalid("plugin.json is not valid JSON."); }
        catch (Exception error) when (error is FormatException or OverflowException) { throw Invalid("plugin.json is not valid JSON."); }
        if (parsed is not Dictionary<string, object?> root) throw Invalid("plugin.json must be an object.");
        var operations = Objects(root.GetValueOrDefault("operations"));
        if (!root.Keys.All(RootKeys.Contains) || operations is null) throw Invalid("plugin.json contains unknown fields.");
        foreach (var operation in operations)
        {
            var parameters = Objects(operation.GetValueOrDefault("parameters"));
            if (!operation.Keys.All(OperationKeys.Contains) || parameters is null || parameters.Any(parameter => !parameter.Keys.All(ParameterKeys.Contains)))
            {
                throw Invalid("Plugin operation contains unknown fields.");
            }
        }
        var manifest = new PluginManifest(
            FormatVersion: Integer(root, "formatVersion"),
            Id: Text(root, "id"),
            Name: Text(root, "name"),
            Version: Text(root, "version"),
            Summary: Text(root, "summary"),
            Symbol: Text(root, "symbol"),
            Author: Text(root, "author"),
            License: Text(root, "license"),
            MinimumRuntimeVersion: Text(root, "minimumRuntimeVersion"),
            BaseURL: Text(root, "baseURL"),
            Hosts: (root.GetValueOrDefault("hosts") as List<object?> ?? throw Malformed("hosts")).Select(host => host as string ?? throw Malformed("hosts")).ToList(),
            Operations: operations.Select(operation => new PluginOperation(
                Id: Text(operation, "id"),
                Title: Text(operation, "title"),
                Method: Text(operation, "method"),
                Path: Text(operation, "path"),
                ResponseType: PluginWireNames.ResponseType(Text(operation, "responseType")) ?? throw Malformed("responseType"),
                Parameters: Objects(operation.GetValueOrDefault("parameters"))!.Select(parameter => new PluginParameter(
                    Id: Text(parameter, "id"),
                    Label: Text(parameter, "label"),
                    Location: PluginWireNames.ParameterLocation(Text(parameter, "location")) ?? throw Malformed("location"),
                    Required: parameter.GetValueOrDefault("required") as bool? ?? throw Malformed("required"),
                    DefaultValue: parameter.GetValueOrDefault("defaultValue") switch
                    {
                        null => null,
                        string value => value,
                        _ => throw Malformed("defaultValue"),
                    })).ToList())).ToList());
        var issues = Validate(manifest);
        if (issues.Count > 0) throw Invalid(string.Join("\n", issues.Select(issue => issue.Message)));
        return manifest;
    }

    /// <summary>
    /// Semantic rules of Data Source Plugin 1.0. An empty list means the manifest is valid.
    ///
    /// - <c>formatVersion</c> must be 1 and <c>minimumRuntimeVersion</c> the supported runtime: unsupported
    ///   versions fail closed instead of being run with guessed semantics.
    /// - <c>baseURL</c> must be HTTPS without credentials, query or fragment: plugins never send
    ///   cleartext requests and never embed secrets in the manifest.
    /// - 1–20 unique, well-formed <c>hosts</c> that include the <c>baseURL</c> host and are public Internet
    ///   names: a plugin can only reach hosts the user can review, never the device or local network.
    ///   (The public-host rule is enforced by Swift when the request is made; here it is also
    ///   enforced at import.)
    /// - 1–50 operations with unique ids, an upper-case standard method, and an absolute path with
    ///   no <c>..</c>, query or fragment: an operation cannot leave its declared path space.
    /// - At most 30 parameters per operation, unique ids, every <c>{placeholder}</c> declared as a <c>path</c>
    ///   parameter and every <c>path</c> parameter present in the path; header parameter ids must be
    ///   valid header names.
    /// </summary>
    public static IReadOnlyList<PluginValidationIssue> Validate(PluginManifest manifest)
    {
        var issues = new List<PluginValidationIssue>();
        void Reject(string id, string message) => issues.Add(new PluginValidationIssue(id, message));
        if (manifest.FormatVersion != PluginManifest.CurrentFormatVersion) Reject("format", $"Unsupported Data Source Plugin format {manifest.FormatVersion.ToString(CultureInfo.InvariantCulture)}.");
        if (!Identifier().IsMatch(manifest.Id)) Reject("id", "Plugin id must be a stable 3–128 character identifier.");
        if (string.IsNullOrWhiteSpace(manifest.Name) || new StringInfo(manifest.Name).LengthInTextElements > MaximumNameCharacters) Reject("name", "Plugin name must contain 1–80 characters.");
        if (!SemanticVersion().IsMatch(manifest.Version)) Reject("version", "Plugin version must use semantic versioning.");
        if (manifest.MinimumRuntimeVersion != RuntimeApiVersion) Reject("runtime", $"Plugin requires unsupported runtime {manifest.MinimumRuntimeVersion}.");
        var address = PluginUrl.Parse(manifest.BaseURL);
        var baseHost = address?.Host?.ToLowerInvariant();
        if (address is null || address.Scheme?.ToLowerInvariant() != "https" || string.IsNullOrEmpty(baseHost) || address.HasUserInfo || address.HasQuery || address.HasFragment)
        {
            Reject("base_url", "baseURL must be an HTTPS URL without credentials, query, or fragment.");
            return issues;
        }
        if (manifest.Hosts.Count == 0 || manifest.Hosts.Count > MaximumHosts) Reject("hosts", "A plugin must declare 1–20 HTTPS hosts.");
        if (manifest.Hosts.Distinct(StringComparer.Ordinal).Count() != manifest.Hosts.Count) Reject("hosts", "Plugin hosts must be unique.");
        foreach (var host in manifest.Hosts)
        {
            if (!IsValidDomainDeclaration(host)) Reject("host", $"Invalid plugin host declaration: {host}.");
            // "*.local" covers only private names; test it as a name it would match.
            else if (RuntimePolicy.BlockedHostName(host.StartsWith("*.", StringComparison.Ordinal) ? "x" + host[1..] : host)) Reject("host", $"Plugin host must be a public Internet host: {host}.");
        }
        if (RuntimePolicy.BlockedHostName(PluginUrl.Unbracket(baseHost))) Reject("base_host", "baseURL must use a public Internet host.");
        if (!RuntimePolicy.HostMatches(baseHost, manifest.Hosts)) Reject("base_host", "baseURL host must be included in hosts.");
        if (manifest.Operations.Count == 0 || manifest.Operations.Count > MaximumOperations) Reject("operations", $"A plugin must contain 1–{MaximumOperations} operations.");
        if (manifest.Operations.Select(operation => operation.Id.ToLowerInvariant()).Distinct(StringComparer.Ordinal).Count() != manifest.Operations.Count) Reject("operation_ids", "Operation ids must be unique.");
        foreach (var operation in manifest.Operations)
        {
            var prefix = $"operation.{operation.Id}";
            if (!Identifier().IsMatch(operation.Id)) Reject(prefix, $"Operation id is invalid: {operation.Id}.");
            if (!Methods.Contains(operation.Method)) Reject(prefix, $"Operation {operation.Id} has an unsupported HTTP method.");
            if (operation.Path.Length == 0 || !operation.Path.StartsWith('/') || operation.Path.Contains("..", StringComparison.Ordinal) || operation.Path.Contains('?') || operation.Path.Contains('#'))
            {
                Reject(prefix, "Operation path must be an absolute URL path without traversal, query, or fragment.");
            }
            if (operation.Parameters.Count > MaximumParameters) Reject(prefix, $"Operation {operation.Id} has too many parameters.");
            if (operation.Parameters.Select(parameter => parameter.Id.ToLowerInvariant()).Distinct(StringComparer.Ordinal).Count() != operation.Parameters.Count) Reject(prefix, "Operation parameter ids must be unique.");
            var parameterIDs = operation.Parameters.Select(parameter => parameter.Id).ToHashSet(StringComparer.Ordinal);
            foreach (var parameter in operation.Parameters)
            {
                var placeholder = "{" + parameter.Id + "}";
                if (!Identifier().IsMatch(parameter.Id)) Reject(prefix, $"Invalid parameter id: {parameter.Id}.");
                if (parameter.Location == PluginParameterLocation.Path && !operation.Path.Contains(placeholder, StringComparison.Ordinal)) Reject(prefix, $"Path parameter {parameter.Id} has no matching placeholder.");
                if (parameter.Location != PluginParameterLocation.Path && operation.Path.Contains(placeholder, StringComparison.Ordinal)) Reject(prefix, $"Placeholder {parameter.Id} must be a path parameter.");
                if (parameter.Location == PluginParameterLocation.Header && !HeaderName().IsMatch(parameter.Id)) Reject(prefix, $"Header parameter {parameter.Id} is invalid.");
            }
            foreach (Match match in Placeholder().Matches(operation.Path))
            {
                var placeholder = match.Groups[1].Value;
                if (!parameterIDs.Contains(placeholder)) Reject(prefix, $"Path placeholder {placeholder} has no declared parameter.");
            }
        }
        return issues;
    }

    /// <summary>
    /// <c>ScriptWidgetNetworkPolicy.isValidDomainDeclaration</c>: a lower-case host name, optionally
    /// <c>*.</c>-prefixed, with no scheme, path or port, so a declaration cannot smuggle a URL.
    /// </summary>
    public static bool IsValidDomainDeclaration(string value)
    {
        var normalized = value.ToLowerInvariant();
        return value == normalized && !normalized.Contains("://", StringComparison.Ordinal) && !normalized.Contains('/') && !normalized.Contains(':') &&
            !normalized.StartsWith('.') && !normalized.EndsWith('.') && HostDeclaration().IsMatch(normalized) &&
            (!normalized.Contains('*') || (normalized.StartsWith("*.", StringComparison.Ordinal) && normalized.IndexOf('*', 1) < 0));
    }

    private static List<Dictionary<string, object?>>? Objects(object? value)
    {
        if (value is not List<object?> list) return null;
        var result = new List<Dictionary<string, object?>>(list.Count);
        foreach (var item in list)
        {
            if (item is not Dictionary<string, object?> map) return null;
            result.Add(map);
        }
        return result;
    }

    private static string Text(Dictionary<string, object?> map, string key) => map.GetValueOrDefault(key) as string ?? throw Malformed(key);

    /// <summary>Whole JSON numbers only; <c>1.0</c> is accepted like Swift's <c>JSONDecoder</c>, <c>1.5</c> and <c>"1"</c> are not.</summary>
    private static int Integer(Dictionary<string, object?> map, string key) => map.GetValueOrDefault(key) switch
    {
        long value when value is >= int.MinValue and <= int.MaxValue => (int)value,
        double value when value == Math.Round(value, MidpointRounding.ToEven) && Math.Abs(value) <= int.MaxValue => (int)value,
        _ => throw Malformed(key),
    };

    /// <summary>Strict UTF-8 text without a byte order mark, or null when the bytes are malformed.</summary>
    internal static string? DecodeUtf8(byte[] bytes)
    {
        try
        {
            var offset = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
            return new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private static PluginException Malformed(string key) => Invalid($"plugin.json field \"{key}\" is missing or has the wrong type.");

    private static PluginException Invalid(string message) => new(PluginErrorKind.InvalidManifest, message);
}

/// <summary>
/// A URL split the way <c>java.net.URI</c> splits it, which is what the Android validator and
/// request builder rely on. It is deliberately stricter than <see cref="Uri"/>: no spaces, no
/// backslashes, no characters outside the URI grammar, and a host only when the authority is a
/// plain server name, an IPv4 address or a bracketed IPv6 address.
/// </summary>
internal sealed class PluginUrl
{
    public string? Scheme { get; private init; }
    /// <summary>The host as written (brackets included for IPv6), or null when there is none.</summary>
    public string? Host { get; private init; }
    public int Port { get; private init; } = -1;
    public bool HasUserInfo { get; private init; }
    public string RawPath { get; private init; } = "";
    public bool HasQuery { get; private init; }
    public bool HasFragment { get; private init; }

    public static string Unbracket(string host) => host.StartsWith('[') && host.EndsWith(']') ? host[1..^1] : host;

    /// <summary>Null when <paramref name="text"/> is not a URI at all.</summary>
    public static PluginUrl? Parse(string text)
    {
        if (text.Length == 0) return new PluginUrl();
        var hash = text.IndexOf('#');
        var hasFragment = hash >= 0;
        var fragment = hasFragment ? text[(hash + 1)..] : "";
        var rest = hasFragment ? text[..hash] : text;
        if (!Legal(fragment, brackets: false) || fragment.Contains('#')) return null;

        string? scheme = null;
        var stop = rest.IndexOfAny(['/', '?', ':']);
        if (stop >= 0 && rest[stop] == ':')
        {
            scheme = rest[..stop];
            if (scheme.Length == 0 || !char.IsAsciiLetter(scheme[0]) || !scheme.All(character => char.IsAsciiLetterOrDigit(character) || character is '+' or '-' or '.')) return null;
            rest = rest[(stop + 1)..];
            if (rest.Length == 0) return null;
            // An opaque URI such as "mailto:someone" has no host, path or query.
            if (rest[0] != '/') return Legal(rest, brackets: false) ? new PluginUrl { Scheme = scheme, HasFragment = hasFragment } : null;
        }

        string? authority = null;
        if (rest.StartsWith("//", StringComparison.Ordinal))
        {
            var end = rest.IndexOfAny(['/', '?'], 2);
            authority = end < 0 ? rest[2..] : rest[2..end];
            rest = end < 0 ? "" : rest[end..];
            if (!Legal(authority, brackets: true)) return null;
        }
        var mark = rest.IndexOf('?');
        var hasQuery = mark >= 0;
        var path = hasQuery ? rest[..mark] : rest;
        if (!Legal(path, brackets: false) || (hasQuery && !Legal(rest[(mark + 1)..], brackets: false))) return null;

        string? host = null;
        var port = -1;
        var hasUserInfo = false;
        if (!string.IsNullOrEmpty(authority))
        {
            var server = authority;
            var at = server.IndexOf('@');
            if (at >= 0) server = server[(at + 1)..];
            string name;
            var portText = "";
            if (server.StartsWith('['))
            {
                var close = server.IndexOf(']');
                name = close < 0 ? "" : server[..(close + 1)];
                var after = close < 0 ? "" : server[(close + 1)..];
                if (after.Length > 0 && after[0] != ':') name = "";
                else if (after.Length > 0) portText = after[1..];
                if (name.Length > 0 && !(IPAddress.TryParse(name[1..^1], out var literal) && literal.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6)) name = "";
            }
            else
            {
                var colon = server.IndexOf(':');
                name = colon < 0 ? server : server[..colon];
                if (colon >= 0) portText = server[(colon + 1)..];
                if (!ServerName(name)) name = "";
            }
            // Anything else is a registry-based authority: it has no host, port or user information.
            if (name.Length > 0 && portText.All(char.IsAsciiDigit) && (portText.Length == 0 || int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out port)))
            {
                host = name;
                hasUserInfo = at >= 0;
                if (portText.Length == 0) port = -1;
            }
            else port = -1;
        }
        return new PluginUrl { Scheme = scheme, Host = host, Port = port, HasUserInfo = hasUserInfo, RawPath = path, HasQuery = hasQuery, HasFragment = hasFragment };
    }

    /// <summary>An IPv4 address, or a host name of letter-digit-hyphen labels whose last label starts with a letter.</summary>
    private static bool ServerName(string name)
    {
        if (name.Length == 0) return false;
        var labels = name.Split('.');
        if (labels.Length == 4 && labels.All(label => label.Length is >= 1 and <= 3 && label.All(char.IsAsciiDigit) && int.Parse(label, CultureInfo.InvariantCulture) <= 255)) return true;
        if (labels[^1].Length == 0) labels = labels[..^1];
        if (labels.Length == 0) return false;
        foreach (var label in labels)
        {
            if (label.Length == 0 || !label.All(character => char.IsAsciiLetterOrDigit(character) || character == '-') || label[0] == '-' || label[^1] == '-') return false;
        }
        return char.IsAsciiLetter(labels[^1][0]);
    }

    /// <summary>True when every character may appear in a URI and every <c>%</c> starts a two-digit escape.</summary>
    private static bool Legal(string part, bool brackets)
    {
        for (var index = 0; index < part.Length; index++)
        {
            var character = part[index];
            if (character == '%')
            {
                if (index + 2 >= part.Length) return false;
                if (!char.IsAsciiHexDigit(part[index + 1]) || !char.IsAsciiHexDigit(part[index + 2])) return false;
                index += 2;
            }
            else if (character is '[' or ']')
            {
                if (!brackets) return false;
            }
            else if (character < '\u0080')
            {
                if (!char.IsAsciiLetterOrDigit(character) && !"-_.!~*'();/?:@&=+$,".Contains(character)) return false;
            }
            else if (char.IsControl(character) || char.IsWhiteSpace(character) || char.IsSurrogate(character) && !Paired(part, index))
            {
                return false;
            }
        }
        return true;
    }

    private static bool Paired(string text, int index) =>
        char.IsHighSurrogate(text[index]) ? index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]) : index > 0 && char.IsHighSurrogate(text[index - 1]);
}
