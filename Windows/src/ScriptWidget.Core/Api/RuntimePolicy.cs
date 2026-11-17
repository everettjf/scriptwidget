using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Api;

/// <summary>
/// Manifest and presentation rules that every native API checks before doing
/// work. JavaScript-side checks exist only for early, readable errors.
/// </summary>
public static class RuntimePolicy
{
    public static JsonObject? Manifest(ExecutionRequest request) => request.Prepared.Manifest;

    public static bool HasPermission(ExecutionRequest request, string permission) =>
        Manifest(request).OptArray("permissions")?.Any(item => item?.AsText() == permission) ?? false;

    /// <summary>Future timeline entries are rendered ahead of time and must not read live data or write.</summary>
    public static bool IsTimelineProjection(ExecutionRequest request) =>
        (request.Environments.TryGetValue("timeline-is-projection", out var value) ? value : request.Prepared.TimelineEnvironment.GetValueOrDefault("timeline-is-projection")) == "true";

    public static bool IsLiveActivity(ExecutionRequest request) => request.Environments.GetValueOrDefault("widget-size") is "live-activity" or "dynamic-island";

    /// <summary>True while a declared action runs; writes to system data require it.</summary>
    public static bool IsAction(ExecutionRequest request) => request.Prepared.ActionID is not null;

    /// <summary>Same textual rule as ScriptWidgetFetchPolicy.validationError.</summary>
    public static bool BlockedHostName(string host)
    {
        var value = host.ToLowerInvariant();
        var parts = value.Split('.');
        return value == "localhost" || value == "::1" || value.EndsWith(".local", StringComparison.Ordinal) ||
            value.StartsWith("127.", StringComparison.Ordinal) || value.StartsWith("10.", StringComparison.Ordinal) || value.StartsWith("192.168.", StringComparison.Ordinal) ||
            (parts.Length == 4 && parts[0] == "172" && int.TryParse(parts[1], out var second) && second is >= 16 and <= 31);
    }

    /// <summary>Rejects addresses that are not on the public Internet, whatever name resolved to them.</summary>
    public static bool BlockedAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any) || address.Equals(IPAddress.IPv6None)) return true;
        var bytes = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || address.IsIPv6Multicast) return true;
            if ((bytes[0] & 0xFE) == 0xFC) return true; // unique local fc00::/7
            // NAT64 and 6to4 embed an IPv4 address that the gateway would reach.
            if (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B) return BlockedAddress(new IPAddress(bytes.AsSpan(12, 4)));
            if (bytes[0] == 0x20 && bytes[1] == 0x02) return BlockedAddress(new IPAddress(bytes.AsSpan(2, 4)));
            return false;
        }
        if (bytes.Length != 4) return true;
        int first = bytes[0], second = bytes[1];
        if (first == 0 || first == 10 || first == 127) return true; // this-network, private, loopback
        if (first == 100 && second is >= 64 and <= 127) return true; // carrier-grade NAT
        if (first == 169 && second == 254) return true; // link-local
        if (first == 172 && second is >= 16 and <= 31) return true; // private
        if (first == 192 && second == 168) return true; // private
        if (first >= 224) return true; // multicast, reserved and broadcast
        return false;
    }

    public static bool HostMatches(string host, IEnumerable<string> declarations)
    {
        var value = host.ToLowerInvariant();
        return declarations.Any(declaration =>
        {
            var domain = declaration.ToLowerInvariant();
            if (!domain.StartsWith("*.", StringComparison.Ordinal)) return value == domain;
            var suffix = domain[2..];
            return value != suffix && value.EndsWith("." + suffix, StringComparison.Ordinal);
        });
    }

    /// <summary>Package 2.0: <c>network</c> permission and a matching <c>networkDomains</c> entry. Legacy packages without a manifest are allowed.</summary>
    public static bool PackageAllowsHost(ExecutionRequest request, string host)
    {
        if (!request.Prepared.HasManifest) return true;
        if (Manifest(request) is not { } manifest) return false;
        if (!HasPermission(request, "network")) return false;
        if (manifest.OptArray("networkDomains") is not { } domains) return false;
        return HostMatches(host, domains.Select(item => item?.AsText() ?? ""));
    }
}
