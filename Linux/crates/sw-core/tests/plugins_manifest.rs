//! The strict decoder and validator of `plugin.json`. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Plugins/PluginValidatorTests.cs`.

mod plugins_common;

use plugins_common::*;
use serde_json::{Value, json};
use sw_core::plugins::manifest::{self, MAXIMUM_MANIFEST_BYTES, PluginManifest, PluginParameter, PluginParameterLocation, PluginResponseType, decode, is_valid_domain_declaration, validate};
use sw_core::plugins::store::built_ins;

fn message(data: &[u8]) -> String {
    decode(data).expect_err("the manifest must be refused").message
}

// Swift: testBuiltInPluginsValidate
#[test]
fn built_in_plugins_validate() {
    assert_eq!(built_ins().len(), 2);
    for plugin in built_ins() {
        assert_eq!(validate(plugin), []);
    }
}

#[test]
fn built_in_plugins_survive_encoding_and_decoding() {
    for plugin in built_ins() {
        assert_eq!(&decode(plugin.to_json().as_bytes()).unwrap(), plugin);
    }
    let manifest = base_manifest();
    assert_eq!(decode(manifest.to_json().as_bytes()).unwrap(), manifest);
    // The written form is the one Swift writes: sorted keys, two spaces, slashes as they are.
    let text = built_ins()[1].to_json();
    assert!(text.starts_with("{\n  \"author\": \"GitHub\",\n  \"baseURL\": \"https://api.github.com\",\n  \"formatVersion\": 1,\n  \"hosts\": [\"api.github.com\"],\n"), "{text}");
    assert!(text.contains("        {\"defaultValue\": \"everettjf\", \"id\": \"owner\", \"label\": \"Owner\", \"location\": \"path\", \"required\": true},\n"), "{text}");
    assert!(text.ends_with("  \"version\": \"1.0.0\"\n}\n"), "{text}");
    assert!(manifest.to_json().contains("{\"id\": \"user\", \"label\": \"User\", \"location\": \"path\", \"required\": true}"), "an absent default is left out");
    assert!(manifest.to_json().contains("      \"parameters\": [],\n"));
}

#[test]
fn decodes_every_field() {
    let manifest = base_manifest();
    assert_eq!(manifest.id, ID);
    assert_eq!(manifest.base_url, "https://api.example.com");
    assert_eq!(manifest.hosts, ["api.example.com"]);
    let update = &manifest.operations[0];
    assert_eq!(update.method, "POST");
    assert_eq!(update.response_type, PluginResponseType::Json);
    assert_eq!(update.parameters[1], PluginParameter { id: "page".into(), label: "Page".into(), location: PluginParameterLocation::Query, required: false, default_value: Some("1".into()) });
    assert_eq!(update.parameters[2].default_value, None);
    assert_eq!(manifest.operations[1].response_type, PluginResponseType::Text);
    // A byte order mark is not part of the document.
    assert_eq!(decode(&[&[0xEF, 0xBB, 0xBF][..], &bytes()].concat()).unwrap(), manifest);
}

// Swift: testManifestDecoderFailsClosedAndRejectsHTTP
#[test]
fn unknown_keys_fail_closed_at_every_level() {
    assert_rejected("plugin.json contains unknown fields.", |root| root["unexpected"] = json!(true));
    assert_rejected("plugin.json contains unknown fields.", |root| root["nativeLibrary"] = json!("libplugin.so"));
    assert_rejected("plugin.json contains unknown fields.", |root| root["permissions"] = json!(["network"]));
    assert_rejected("Plugin operation contains unknown fields.", |root| root["operations"][0]["script"] = json!("fetch()"));
    assert_rejected("Plugin operation contains unknown fields.", |root| root["operations"][0]["parameters"][0]["secret"] = json!("x"));
}

#[test]
fn http_base_url_is_rejected() {
    let unsafe_plugin = PluginManifest { base_url: "http://api.open-meteo.com".into(), ..built_ins()[0].clone() };
    assert!(!validate(&unsafe_plugin).is_empty());
    assert_rejected("baseURL must be an HTTPS URL without credentials, query, or fragment.", |root| root["baseURL"] = json!("http://api.example.com"));
}

#[test]
fn base_url_rules() {
    let message = "baseURL must be an HTTPS URL without credentials, query, or fragment.";
    for url in [
        "ftp://api.example.com", "https://user:pw@api.example.com", "https://user@api.example.com", "https://api.example.com?key=1", "https://api.example.com/#top", "api.example.com", "https:///path", "",
        "https://api example.com", "file:///etc/hosts",
    ] {
        assert_rejected(message, |root| root["baseURL"] = json!(url));
    }
    assert_rejected("baseURL host must be included in hosts.", |root| root["baseURL"] = json!("https://other.example.com"));
    // A port and a base path are allowed.
    assert_eq!(manifest_with(|root| root["baseURL"] = json!("https://api.example.com:8443/v2")).base_url, "https://api.example.com:8443/v2");
}

/// Spellings a lenient URL parser would accept or reinterpret are not a base URL.
#[test]
fn base_urls_that_only_a_lenient_parser_accepts_are_rejected() {
    let message = "baseURL must be an HTTPS URL without credentials, query, or fragment.";
    for url in [
        "https://api.example.com\\@evil.example.net", "https:\\\\api.example.com", "https:api.example.com", "https://api_internal.example.com", "https://api.example.com:port", "https://api.example.com/a b",
        "https://api.example.com/%zz", "https://api.example.com?", "https://api.example.com#", "https://@api.example.com", "https://\u{4f8b}\u{3048}.example.com", " https://api.example.com", "https://api.example.com\n",
        "https://api.example.com\t", "HTTPS://api.example.com/\u{0}", "https://2130706433",
    ] {
        assert_rejected(message, |root| root["baseURL"] = json!(url));
    }
}

#[test]
fn versions_fail_closed() {
    assert_rejected("Unsupported Data Source Plugin format 2.", |root| root["formatVersion"] = json!(2));
    assert_rejected("Unsupported Data Source Plugin format 0.", |root| root["formatVersion"] = json!(0));
    assert_rejected("\"formatVersion\" is missing or has the wrong type", |root| root["formatVersion"] = json!("1"));
    assert_rejected("\"formatVersion\" is missing or has the wrong type", |root| root["formatVersion"] = json!(1.5));
    assert_rejected("\"formatVersion\" is missing or has the wrong type", |root| root["formatVersion"] = json!(true));
    assert_rejected("\"formatVersion\" is missing or has the wrong type", |root| root["formatVersion"] = json!(5_000_000_000u64));
    assert_rejected("\"formatVersion\" is missing or has the wrong type", |root| remove(root, "formatVersion"));
    assert_rejected("Plugin requires unsupported runtime 2.0.", |root| root["minimumRuntimeVersion"] = json!("2.0"));
    assert_rejected("Plugin requires unsupported runtime 1.6.", |root| root["minimumRuntimeVersion"] = json!("1.6"));
    assert_rejected("Plugin version must use semantic versioning.", |root| root["version"] = json!("1.0"));
    assert_rejected("Plugin version must use semantic versioning.", |root| root["version"] = json!("v1.0.0"));
    assert_eq!(manifest_with(|root| root["version"] = json!("1.0.0-beta.1")).version, "1.0.0-beta.1");
    // 1.0 is the whole number 1, as for Swift's decoder.
    assert_eq!(decode(String::from_utf8(bytes()).unwrap().replace("\"formatVersion\":1", "\"formatVersion\":1.0").as_bytes()).unwrap(), base_manifest());
}

#[test]
fn identifier_and_name_rules() {
    let long = "a".repeat(129);
    for id in ["ab", "-abc", "has space", "a/b/c", long.as_str(), "abc\n"] {
        assert_rejected("Plugin id must be a stable 3–128 character identifier.", |root| root["id"] = json!(id));
    }
    assert_rejected("Plugin name must contain 1–80 characters.", |root| root["name"] = json!("  "));
    assert_rejected("Plugin name must contain 1–80 characters.", |root| root["name"] = json!("n".repeat(81)));
    assert_eq!(manifest_with(|root| root["name"] = json!("n".repeat(80))).name.len(), 80);
    // Characters as a person counts them: a family emoji is one, an accent does not add one.
    assert_eq!(manifest_with(|root| root["name"] = json!("👨\u{200d}👩\u{200d}👧".repeat(80))).name.chars().count(), 400);
    assert_rejected("Plugin name must contain 1–80 characters.", |root| root["name"] = json!("👨\u{200d}👩\u{200d}👧".repeat(81)));
    assert!(decode(&bytes_with(|root| root["name"] = json!("e\u{301}".repeat(80)))).is_ok());
}

#[test]
fn private_and_local_hosts_are_rejected() {
    for host in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "printer.local"] {
        assert_rejected(&format!("Plugin host must be a public Internet host: {host}."), |root| {
            root["baseURL"] = json!(format!("https://{host}"));
            root["hosts"] = json!([host]);
        });
    }
    assert_rejected("Plugin host must be a public Internet host: *.local.", |root| root["hosts"] = json!(["api.example.com", "*.local"]));
    assert_rejected("baseURL", |root| {
        root["baseURL"] = json!("https://[::1]");
        root["hosts"] = json!(["api.example.com"]);
    });
}

#[test]
fn host_declaration_rules() {
    assert_rejected("A plugin must declare 1–20 HTTPS hosts.", |root| root["hosts"] = json!([]));
    assert_rejected("A plugin must declare 1–20 HTTPS hosts.", |root| {
        root["hosts"] = Value::Array((0..21).map(|index| if index == 0 { json!("api.example.com") } else { json!(format!("h{index}.example.com")) }).collect());
    });
    assert_rejected("Plugin hosts must be unique.", |root| root["hosts"] = json!(["api.example.com", "api.example.com"]));
    for host in ["https://api.example.com", "api.example.com/path", "api.example.com:443", "API.example.com", ".example.com", "example.com.", "api.*.com", "*example.com", "*.*.example.com", "exa mple.com", ""] {
        assert_rejected(&format!("Invalid plugin host declaration: {host}."), |root| root["hosts"] = json!(["api.example.com", host]));
    }
    assert_rejected("\"hosts\" is missing or has the wrong type", |root| root["hosts"] = json!(["api.example.com", 7]));
    assert_rejected("\"hosts\" is missing or has the wrong type", |root| root["hosts"] = json!("api.example.com"));
    assert_eq!(manifest_with(|root| root["hosts"] = json!(["*.example.com"])).hosts, ["*.example.com"]);
}

#[test]
fn operation_rules() {
    assert_rejected("A plugin must contain 1–50 operations.", |root| root["operations"] = json!([]));
    assert_rejected("A plugin must contain 1–50 operations.", |root| {
        let status = root["operations"][1].clone();
        root["operations"] = Value::Array(
            (0..=50)
                .map(|index| {
                    let mut copy = status.clone();
                    copy["id"] = json!(format!("status-{index}"));
                    copy
                })
                .collect(),
        );
    });
    assert_rejected("Operation ids must be unique.", |root| root["operations"][1]["id"] = json!("UPDATE"));
    assert_rejected("Operation id is invalid: a b.", |root| root["operations"][1]["id"] = json!("a b"));
    for method in ["get", "HEAD", "OPTIONS", "CONNECT", "TRACE", ""] {
        assert_rejected("Operation status has an unsupported HTTP method.", |root| root["operations"][1]["method"] = json!(method));
    }
    let path_message = "Operation path must be an absolute URL path without traversal, query, or fragment.";
    for path in ["", "status", "/a/../b", "/status?x=1", "/status#top", "//evil.example.com/.."] {
        assert_rejected(path_message, |root| root["operations"][1]["path"] = json!(path));
    }
    assert_rejected("\"responseType\" is missing or has the wrong type", |root| root["operations"][1]["responseType"] = json!("xml"));
    assert_rejected("\"title\" is missing or has the wrong type", |root| remove(&mut root["operations"][1], "title"));
    assert_rejected("plugin.json contains unknown fields.", |root| root["operations"] = json!("none"));
    assert_rejected("plugin.json contains unknown fields.", |root| root["operations"] = json!([1]));
    assert_rejected("Plugin operation contains unknown fields.", |root| root["operations"][1]["parameters"] = json!("none"));
}

#[test]
fn parameter_declaration_rules() {
    assert_rejected("Operation status has too many parameters.", |root| {
        root["operations"][1]["parameters"] = Value::Array((0..=30).map(|index| json!({ "id": format!("param-{index}"), "label": "P", "location": "query", "required": false })).collect());
    });
    assert_rejected("Operation parameter ids must be unique.", |root| root["operations"][0]["parameters"][1]["id"] = json!("ENABLED"));
    assert_rejected("Invalid parameter id: p!.", |root| root["operations"][0]["parameters"][1]["id"] = json!("p!"));
    assert_rejected("Path parameter page has no matching placeholder.", |root| root["operations"][0]["parameters"][1]["location"] = json!("path"));
    assert_rejected("Placeholder user must be a path parameter.", |root| root["operations"][0]["parameters"][0]["location"] = json!("query"));
    assert_rejected("Path placeholder team has no declared parameter.", |root| root["operations"][0]["path"] = json!("/teams/{team}/users/{user}"));
    assert_rejected("\"location\" is missing or has the wrong type", |root| root["operations"][0]["parameters"][1]["location"] = json!("cookie"));
    assert_rejected("\"required\" is missing or has the wrong type", |root| root["operations"][0]["parameters"][1]["required"] = json!("yes"));
    assert_rejected("\"required\" is missing or has the wrong type", |root| remove(&mut root["operations"][0]["parameters"][1], "required"));
    assert_rejected("\"defaultValue\" is missing or has the wrong type", |root| root["operations"][0]["parameters"][1]["defaultValue"] = json!(1));
    assert_rejected("\"label\" is missing or has the wrong type", |root| root["operations"][0]["parameters"][1]["label"] = json!(5));
}

#[test]
fn every_issue_is_reported() {
    let data = bytes_with(|root| {
        root["id"] = json!("x");
        root["version"] = json!("1");
        root["formatVersion"] = json!(3);
    });
    assert_eq!(message(&data), "Unsupported Data Source Plugin format 3.\nPlugin id must be a stable 3–128 character identifier.\nPlugin version must use semantic versioning.");
}

#[test]
fn oversize_and_malformed_documents_are_rejected() {
    let padded = bytes_with(|root| root["summary"] = json!("s".repeat(MAXIMUM_MANIFEST_BYTES)));
    assert_eq!(message(&padded), "plugin.json exceeds 256 KiB.");
    assert_eq!(message(b"[]"), "plugin.json must be an object.");
    assert_eq!(message(b"\"plugin\""), "plugin.json must be an object.");
    assert_eq!(message(&[0x7B, 0xFF, 0x7D]), "plugin.json must be UTF-8 JSON.");
    let valid = String::from_utf8(bytes()).unwrap();
    let replace_first_brace = |replacement: &str| valid.replacen('{', replacement, 1);
    for text in [
        String::new(),
        "{".to_owned(),
        format!("{valid} trailing"),
        format!("{valid}{valid}"),
        valid.replace("\"formatVersion\"", "formatVersion"),
        valid.replace('"', "'"),
        replace_first_brace("{ // comment\n"),
        replace_first_brace("{\"id\":\"dev.scriptwidget.first\","),
        valid.replace("\"formatVersion\":1", "\"formatVersion\":1e999"),
    ] {
        assert_eq!(message(text.as_bytes()), "plugin.json is not valid JSON.", "{text}");
    }
}

#[test]
fn domain_declarations_match_swift() {
    assert!(is_valid_domain_declaration("api.example.com"));
    assert!(is_valid_domain_declaration("*.example.com"));
    assert!(!is_valid_domain_declaration("Api.example.com"));
    assert!(!is_valid_domain_declaration("api.example.com:8443"));
    assert!(!is_valid_domain_declaration("a*.example.com"));
    assert!(!is_valid_domain_declaration(""));
    assert_eq!(manifest::RUNTIME_API_VERSION, "1.0");
}
