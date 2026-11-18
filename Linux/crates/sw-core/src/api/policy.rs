//! Manifest and presentation rules that every native API checks before doing
//! work. JavaScript-side checks exist only for early, readable errors.
//! Ported from `Windows/src/ScriptWidget.Core/Api/RuntimePolicy.cs`.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::executor::ExecutionRequest;
use crate::json::{ObjectExt, as_text};

pub fn has_permission(request: &ExecutionRequest<'_>, permission: &str) -> bool {
    request
        .prepared
        .manifest
        .as_ref()
        .and_then(|manifest| manifest.opt_array("permissions"))
        .is_some_and(|permissions| permissions.iter().any(|item| as_text(item).as_deref() == Some(permission)))
}

/// Future timeline entries are rendered ahead of time and must not read live data or write.
pub fn is_timeline_projection(request: &ExecutionRequest<'_>) -> bool {
    const NAME: &str = "timeline-is-projection";
    let value = request.environment(NAME).or_else(|| request.prepared.timeline_environment.iter().rev().find(|(name, _)| name == NAME).map(|(_, value)| value.as_str()));
    value == Some("true")
}

pub fn is_live_activity(request: &ExecutionRequest<'_>) -> bool {
    matches!(request.environment("widget-size"), Some("live-activity" | "dynamic-island"))
}

/// True while a declared action runs; writes to system data require it.
pub fn is_action(request: &ExecutionRequest<'_>) -> bool {
    request.prepared.action_id.is_some()
}

/// Same textual rule as ScriptWidgetFetchPolicy.validationError.
pub fn blocked_host_name(host: &str) -> bool {
    let value = host.to_lowercase();
    let parts: Vec<&str> = value.split('.').collect();
    value == "localhost"
        || value == "::1"
        || value.ends_with(".local")
        || value.starts_with("127.")
        || value.starts_with("10.")
        || value.starts_with("192.168.")
        || (parts.len() == 4 && parts[0] == "172" && parts[1].parse::<u32>().is_ok_and(|second| (16..=31).contains(&second)))
}

/// Rejects addresses that are not on the public Internet, whatever name resolved to them.
pub fn blocked_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => blocked_v4(address),
        IpAddr::V6(address) => match address.to_ipv4_mapped() {
            Some(mapped) => blocked_v4(mapped),
            None => blocked_v6(address),
        },
    }
}

fn blocked_v4(address: Ipv4Addr) -> bool {
    let [first, second, ..] = address.octets();
    first == 0 // this network
        || first == 10 // private
        || first == 127 // loopback
        || (first == 100 && (64..=127).contains(&second)) // carrier-grade NAT
        || (first == 169 && second == 254) // link-local
        || (first == 172 && (16..=31).contains(&second)) // private
        || (first == 192 && second == 168) // private
        || first >= 224 // multicast, reserved and broadcast
}

fn blocked_v6(address: Ipv6Addr) -> bool {
    let bytes = address.octets();
    let segments = address.segments();
    if address.is_loopback() || address.is_unspecified() || address.is_multicast() {
        return true;
    }
    if segments[0] & 0xffc0 == 0xfe80 || segments[0] & 0xffc0 == 0xfec0 {
        return true; // link-local fe80::/10 and the retired site-local fec0::/10
    }
    if bytes[0] & 0xfe == 0xfc {
        return true; // unique local fc00::/7
    }
    // NAT64 and 6to4 embed an IPv4 address that the gateway would reach.
    if bytes[..4] == [0x00, 0x64, 0xff, 0x9b] {
        return blocked_v4(Ipv4Addr::new(bytes[12], bytes[13], bytes[14], bytes[15]));
    }
    if bytes[..2] == [0x20, 0x02] {
        return blocked_v4(Ipv4Addr::new(bytes[2], bytes[3], bytes[4], bytes[5]));
    }
    false
}

pub fn host_matches<'a>(host: &str, declarations: impl IntoIterator<Item = &'a str>) -> bool {
    let value = host.to_lowercase();
    declarations.into_iter().any(|declaration| {
        let domain = declaration.to_lowercase();
        match domain.strip_prefix("*.") {
            None => value == domain,
            Some(suffix) => value != suffix && value.ends_with(&format!(".{suffix}")),
        }
    })
}

/// Package 2.0: `network` permission and a matching `networkDomains` entry.
/// Legacy packages without a manifest are allowed.
pub fn package_allows_host(request: &ExecutionRequest<'_>, host: &str) -> bool {
    if !request.prepared.has_manifest {
        return true;
    }
    let Some(manifest) = &request.prepared.manifest else { return false };
    if !has_permission(request, "network") {
        return false;
    }
    let Some(domains) = manifest.opt_array("networkDomains") else { return false };
    let domains: Vec<String> = domains.iter().map(|item| as_text(item).unwrap_or_default()).collect();
    host_matches(host, domains.iter().map(String::as_str))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_and_local_addresses_are_blocked() {
        for text in [
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
            "::1", "::", "fe80::1", "fec0::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:192.168.0.1", "64:ff9b::a00:1", "2002:c0a8:101::1",
        ] {
            assert!(blocked_address(text.parse().unwrap()), "{text}");
        }
        for text in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8", "64:ff9b::808:808", "2002:808:808::1"] {
            assert!(!blocked_address(text.parse().unwrap()), "{text}");
        }
    }

    #[test]
    fn host_names_are_matched_textually() {
        for host in ["localhost", "LOCALHOST", "printer.local", "127.0.0.1", "10.0.0.8", "192.168.0.1", "172.20.1.1", "::1"] {
            assert!(blocked_host_name(host), "{host}");
        }
        for host in ["example.com", "172.32.1.1", "local.example.com"] {
            assert!(!blocked_host_name(host), "{host}");
        }
        assert!(host_matches("API.example.com", ["api.example.com"]));
        assert!(host_matches("a.b.example.com", ["*.example.com"]));
        assert!(!host_matches("example.com", ["*.example.com"]));
        assert!(!host_matches("badexample.com", ["*.example.com", "example.org"]));
    }
}
