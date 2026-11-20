using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Plugins;

namespace ScriptWidget.Core.AI;

/// <summary>The only manifest change a model may request is public network hosts.</summary>
public sealed partial record AiNetworkDeclaration(IReadOnlyList<string> Domains)
{
    [GeneratedRegex(@"\A(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z", RegexOptions.CultureInvariant)]
    private static partial Regex Host();
    public static void ValidateHosts(IReadOnlyList<string> hosts, int maximum = 256)
    {
        if (hosts.Count > maximum || hosts.Any(host => host.Length > 253 || !Host().IsMatch(host) || RuntimePolicy.BlockedHostName(host.StartsWith("*.", StringComparison.Ordinal) ? host[2..] : host)))
            throw new AiException("invalid_declaration", $"Use at most {maximum} public lowercase host names, without a scheme, port or path.");
    }
    public static AiNetworkDeclaration Parse(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > 4096) throw new AiException("invalid_declaration", "The network declaration exceeds 4096 bytes.");
        try
        {
            StrictJson.Parse(text);
            var json = Json.ParseObject(text);
            if (json.Any(field => field.Key is not ("permissions" or "networkDomains"))) throw new AiException("invalid_declaration", "Only permissions and networkDomains may be declared.");
            List<string> Strings(string key)
            {
                if (!json.Has(key)) return [];
                if (json.OptArray(key) is not { } array || array.Any(value => !value.IsString())) throw new AiException("invalid_declaration", $"{key} must be an array of strings.");
                return array.Select(value => value!.AsText()!).ToList();
            }
            var permissions = Strings("permissions").Distinct(StringComparer.Ordinal).ToList();
            var domains = Strings("networkDomains").Select(host => host.ToLowerInvariant()).Distinct(StringComparer.Ordinal).ToList();
            if (permissions.Any(permission => permission != "network") || domains.Count > 0 && !permissions.Contains("network") || permissions.Contains("network") && domains.Count == 0)
                throw new AiException("invalid_declaration", "Only the network permission with 1 to 8 public hosts may be declared.");
            ValidateHosts(domains, 8);
            return new(domains);
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or StrictJson.JsonException) { throw new AiException("invalid_declaration", "The network declaration must be one strict JSON object."); }
    }
    public string ToJson() => Json.Stringify(new JsonObject { ["permissions"] = Json.Array(Domains.Count > 0 ? ["network"] : Array.Empty<string>()), ["networkDomains"] = Json.Array(Domains) });
}

public sealed record AiCandidate(string Source, string? DeclarationJson, string? Note);
public static partial class AiOutput
{
    [GeneratedRegex("```([^\\r\\n]*)\\r?\\n([\\s\\S]*?)```", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex Fence();
    public static AiCandidate Extract(string reply)
    {
        var matches = Fence().Matches(reply).Cast<Match>().ToList();
        var declaration = matches.LastOrDefault(match => match.Groups[1].Value.Trim().ToLowerInvariant() is "json" or "json5" or "jsonc" or "widget.json" or "" &&
            match.Groups[2].Value.TrimStart().StartsWith('{') && !match.Groups[2].Value.Contains("$render", StringComparison.Ordinal));
        var remaining = declaration is null ? reply : reply.Remove(declaration.Index, declaration.Length);
        var blocks = Fence().Matches(remaining).Cast<Match>().ToList();
        var code = blocks.FirstOrDefault(match => match.Groups[1].Value.Trim().ToLowerInvariant() is "jsx" or "javascript" or "js") ?? blocks.FirstOrDefault();
        var source = code is not null ? code.Groups[2].Value : remaining;
        var head = reply[..(reply.IndexOf("```", StringComparison.Ordinal) is var at && at >= 0 ? at : reply.Length)];
        var noteLine = head.Split('\n').FirstOrDefault(line => line.TrimStart().StartsWith("SUMMARY:", StringComparison.Ordinal));
        var note = noteLine is null ? null : AiConversation.Clip(noteLine.Trim()[8..].Trim(), 300);
        if (code is null && noteLine is not null) source = source.Replace(noteLine, "", StringComparison.Ordinal);
        source = source.Trim().Trim('`').Trim();
        return new AiCandidate(source.Length == 0 ? "" : source + "\n", declaration?.Groups[2].Value.Trim(), note);
    }
}
