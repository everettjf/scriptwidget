//! Building a plugin request from script values, and mapping the response.
//! Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Plugins/DataSourceRequestBuilderTests.cs`.

mod plugins_common;

use plugins_common::*;
use serde_json::{Value, json};
use sw_core::plugins::manifest::{PluginErrorKind, PluginManifest, PluginOperation};
use sw_core::plugins::requests::{self, PreparedDataSourceRequest, map_response, prepare};
use sw_core::plugins::store::built_ins;

fn github() -> &'static PluginManifest {
    built_ins().iter().find(|plugin| plugin.id == "app.scriptwidget.datasource.github").unwrap()
}

fn weather() -> &'static PluginManifest {
    built_ins().iter().find(|plugin| plugin.id == "app.scriptwidget.datasource.open-meteo").unwrap()
}

fn body(prepared: &PreparedDataSourceRequest) -> Value {
    serde_json::from_slice(prepared.body.as_deref().expect("a body")).expect("body JSON")
}

fn failure(plugin: &PluginManifest, operation: &str, given: Value) -> (PluginErrorKind, String) {
    let error = prepare(plugin, operation, &values(given)).expect_err("the request must be refused");
    (error.kind, error.message)
}

// Swift: testRequestBuilderMapsPathQueryHeaderAndJSONBody
#[test]
fn maps_path_query_header_and_json_body() {
    let prepared = prepare(&base_manifest(), "update", &values(json!({ "user": "hello world", "X-Token": "secret", "enabled": true }))).unwrap();
    assert_eq!(prepared.url.as_str(), "https://api.example.com/users/hello%20world?page=1");
    assert_eq!(prepared.method, "POST");
    assert_eq!(prepared.header("X-Token"), Some("secret"));
    assert_eq!(prepared.header("User-Agent"), Some("ScriptWidget-DataSource/1"));
    assert_eq!(prepared.header("Content-Type"), Some("application/json"));
    assert_eq!(body(&prepared)["enabled"], true);
}

#[test]
fn defaults_fill_missing_values_and_supplied_values_win() {
    assert_eq!(prepare(github(), "repository", &values(json!({}))).unwrap().url.as_str(), "https://api.github.com/repos/everettjf/scriptwidget");
    assert_eq!(prepare(github(), "repository", &values(json!({ "owner": "quickjs-ng", "repo": "quickjs" }))).unwrap().url.as_str(), "https://api.github.com/repos/quickjs-ng/quickjs");
    let forecast = prepare(weather(), "forecast", &values(json!({ "latitude": 48.85, "longitude": 2, "undeclared": "ignored" }))).unwrap();
    assert_eq!(forecast.url.as_str(), "https://api.open-meteo.com/v1/forecast?latitude=48.85&longitude=2&current=temperature_2m,weather_code&timezone=auto");
    assert_eq!(forecast.body, None);
    assert_eq!(forecast.headers, [("User-Agent".to_owned(), "ScriptWidget-DataSource/1".to_owned())]);
}

#[test]
fn path_values_cannot_change_the_path_structure() {
    let path = |owner: Value| prepare(github(), "repository", &values(json!({ "owner": owner, "repo": "r" }))).map(|prepared| prepared.url.path().to_owned()).map_err(|error| error.message);
    assert_eq!(path(json!("a/b")).unwrap(), "/repos/a%2Fb/r");
    assert_eq!(path(json!("a?x=1#f")).unwrap(), "/repos/a%3Fx=1%23f/r");
    assert_eq!(path(json!("{repo}")).unwrap(), "/repos/%7Brepo%7D/r");
    assert_eq!(path(json!("你好%")).unwrap(), "/repos/%E4%BD%A0%E5%A5%BD%25/r");
    assert_eq!(path(json!("a-b_c.d~e!$&'()*+,=:@")).unwrap(), "/repos/a-b_c.d~e!$&'()*+,=:@/r");
    assert_eq!(path(json!("a;b c\\d")).unwrap(), "/repos/a%3Bb%20c%5Cd/r");
    assert_eq!(path(json!(true)).unwrap(), "/repos/1/r");
    assert_eq!(path(json!(42)).unwrap(), "/repos/42/r");
    for value in ["..", "."] {
        assert_eq!(path(json!(value)).unwrap_err(), "Could not encode owner.");
    }
    assert_eq!(path(json!({ "a": 1 })).unwrap_err(), "Could not encode owner.");
    assert_eq!(path(json!([1])).unwrap_err(), "Could not encode owner.");
    // An encoded separator or dot segment stays one segment in the URL that is sent.
    assert_eq!(path(json!("../../admin")).unwrap(), "/repos/..%2F..%2Fadmin/r");
    assert_eq!(path(json!("%2E%2E")).unwrap(), "/repos/%252E%252E/r");
    assert_eq!(path(json!("...")).unwrap(), "/repos/.../r");
    assert_eq!(path(json!("a\r\nHost: evil")).unwrap(), "/repos/a%0D%0AHost:%20evil/r");
}

#[test]
fn query_values_cannot_add_query_items() {
    let query = |value: Value| {
        let prepared = prepare(weather(), "forecast", &values(json!({ "timezone": value }))).unwrap();
        let query = prepared.url.query().unwrap_or("").to_owned();
        query.split_once("timezone=").map(|(_, rest)| rest.to_owned())
    };
    assert_eq!(query(json!("a&b=c#d")).as_deref(), Some("a%26b%3Dc%23d"));
    assert_eq!(query(json!("Europe/Paris")).as_deref(), Some("Europe/Paris"));
    assert_eq!(query(json!("a b+c")).as_deref(), Some("a%20b+c"));
    assert_eq!(query(json!("€")).as_deref(), Some("%E2%82%AC"));
    assert_eq!(query(json!(false)).as_deref(), Some("0"));
    assert_eq!(query(json!(true)).as_deref(), Some("1"));
    assert_eq!(query(json!(1.5)).as_deref(), Some("1.5"));
    // Numbers as the script bridge delivers them: JSON text.
    let parsed = |text: &str| serde_json::from_str::<Value>(text).unwrap();
    assert_eq!(query(parsed("2.0")).as_deref(), Some("2"));
    assert_eq!(query(parsed("1e-6")).as_deref(), Some("0.000001"));
    assert_eq!(query(parsed("1e20")).as_deref(), Some("100000000000000000000"));
    assert_eq!(query(parsed("\"x\"")).as_deref(), Some("x"));
    // An empty optional value is omitted; null falls back to the default.
    assert_eq!(query(json!("")), None);
    assert_eq!(query(Value::Null).as_deref(), Some("auto"));
    assert_eq!(prepare(weather(), "forecast", &values(json!({}))).unwrap().url.query().unwrap().split_once("timezone=").unwrap().1, "auto");
}

#[test]
fn missing_required_parameters_are_reported() {
    let plugin = base_manifest();
    assert_eq!(failure(&plugin, "update", json!({ "X-Token": "t", "enabled": true })).1, "Missing required parameter user.");
    assert_eq!(failure(&plugin, "update", json!({ "user": "u", "enabled": true })).1, "Missing required parameter X-Token.");
    assert_eq!(failure(&plugin, "update", json!({ "user": "u", "X-Token": "t", "enabled": "" })), (PluginErrorKind::InvalidParameters, "Missing required parameter enabled.".to_owned()));
    // A supplied empty string does not fall back to the default (Swift behavior).
    assert_eq!(failure(weather(), "forecast", json!({ "latitude": "" })).1, "Missing required parameter latitude.");
}

#[test]
fn unknown_operation_is_not_found() {
    assert_eq!(failure(&base_manifest(), "missing", json!({})), (PluginErrorKind::NotFound, format!("Operation missing was not found in {ID}.")));
}

#[test]
fn header_values_cannot_inject_headers() {
    let plugin = base_manifest();
    for token in ["a\r\nX-Evil: 1", "a\nb", "a\0b", "a\u{7f}b"] {
        assert_eq!(failure(&plugin, "update", json!({ "user": "u", "enabled": true, "X-Token": token })).1, "Could not encode X-Token.");
    }
    assert_eq!(failure(&plugin, "update", json!({ "user": "u", "enabled": true, "X-Token": [] })).1, "Could not encode X-Token.");
}

#[test]
fn reserved_headers_are_set_by_the_runtime() {
    let custom = manifest_with(|root| {
        root["operations"][0]["parameters"][2]["id"] = json!("user-agent");
        root["operations"][0]["parameters"].as_array_mut().unwrap().push(json!({ "id": "content-type", "label": "Type", "location": "header", "required": false }));
    });
    let prepared = prepare(&custom, "update", &values(json!({ "user": "u", "user-agent": "Mozilla", "content-type": "text/plain", "enabled": 1 }))).unwrap();
    assert_eq!(prepared.headers, [("User-Agent".to_owned(), "ScriptWidget-DataSource/1".to_owned()), ("Content-Type".to_owned(), "application/json".to_owned())]);
}

#[test]
fn json_body_keeps_structured_values() {
    let plugin = base_manifest();
    let prepared = prepare(&plugin, "update", &values(json!({ "user": "u", "X-Token": "t", "enabled": { "tags": ["a", "b"] } }))).unwrap();
    assert_eq!(body(&prepared)["enabled"]["tags"][1], "b");
    let number = prepare(&plugin, "update", &values(json!({ "user": "u", "X-Token": "t", "enabled": 3 }))).unwrap();
    assert_eq!(number.body.as_deref(), Some(&b"{\"enabled\":3}"[..]));
    let text = prepare(&plugin, "update", &values(json!({ "user": "u", "X-Token": "t", "enabled": "yes" }))).unwrap();
    assert_eq!(text.body.as_deref(), Some(&b"{\"enabled\":\"yes\"}"[..]));
}

#[test]
fn base_path_and_port_are_preserved() {
    let versioned = manifest_with(|root| root["baseURL"] = json!("https://api.example.com:8443/v2"));
    assert_eq!(prepare(&versioned, "status", &values(json!({}))).unwrap().url.as_str(), "https://api.example.com:8443/v2/status");
    let slash = manifest_with(|root| root["baseURL"] = json!("https://api.example.com/"));
    assert_eq!(prepare(&slash, "status", &values(json!({}))).unwrap().url.as_str(), "https://api.example.com/status");
}

#[test]
fn requests_cannot_leave_the_declared_hosts() {
    let plugin = base_manifest();
    let with_base = |base: &str| PluginManifest { base_url: base.into(), ..plugin.clone() };
    // Not reachable through the validator; the builder still refuses a tampered manifest.
    assert_eq!(failure(&with_base("https://evil.example.net"), "status", json!({})), (PluginErrorKind::Permission, "Plugin request escaped its declared hosts.".to_owned()));
    assert_eq!(failure(&with_base("http://api.example.com"), "status", json!({})).1, "Plugin request escaped its declared hosts.");
    assert_eq!(failure(&with_base("https://api.example.com@evil.example.net"), "status", json!({})).1, "Plugin request escaped its declared hosts.");
    assert_eq!(failure(&with_base("not a url"), "status", json!({})).1, "Invalid plugin baseURL.");
    let with_path = |path: &str| PluginManifest { operations: vec![PluginOperation { path: path.into(), ..plugin.operations[1].clone() }], ..plugin.clone() };
    assert_eq!(failure(&with_path("/x/{gone}"), "status", json!({})).1, "A path parameter is unresolved.");
    // A backslash, which a browser's parser reads as a slash, never reaches it.
    assert_eq!(failure(&with_base("https://api.example.com\\@evil.example.net"), "status", json!({})).1, "Invalid plugin baseURL.");
    assert_eq!(failure(&with_path("/\\evil.example.net/x"), "status", json!({})).1, "Invalid plugin baseURL.");
    // A path that starts a new authority stays a path of the declared host.
    let double = prepare(&with_path("//evil.example.net/x"), "status", &values(json!({}))).unwrap();
    assert_eq!((double.url.host_str(), double.url.path()), (Some("api.example.com"), "//evil.example.net/x"));
}

// MARK: - Response mapping

#[test]
fn json_responses_pass_through_unchanged() {
    let plugin = base_manifest();
    let operation = &plugin.operations[0];
    let body = r#"{"temperature": 21.50, "tags": ["a", null], "big": 12345678901234567890}"#;
    assert_eq!(map_response(operation, 200, body.as_bytes()).unwrap(), body);
    assert_eq!(map_response(operation, 204, &[&[0xEF, 0xBB, 0xBF][..], b"[1,2]"].concat()).unwrap(), "[1,2]");
    assert_eq!(map_response(operation, 200, br#"{"a":1,"a":2}"#).unwrap(), r#"{"a":1,"a":2}"#);
}

#[test]
fn invalid_json_responses_are_rejected() {
    let plugin = base_manifest();
    let operation = &plugin.operations[0];
    for body in ["", "<html>", "{\"a\":}", "{} trailing", "\"text\"", "42", "null", "{'a':1}"] {
        let error = map_response(operation, 200, body.as_bytes()).unwrap_err();
        assert_eq!((error.kind, error.message.as_str()), (PluginErrorKind::Network, "Data source returned invalid JSON"), "{body}");
    }
    assert_eq!(map_response(operation, 200, &[0x7B, 0xC3, 0x28, 0x7D]).unwrap_err().message, "Data source returned invalid JSON");
}

#[test]
fn text_responses_become_json_strings() {
    let plugin = base_manifest();
    let operation = &plugin.operations[1];
    assert_eq!(map_response(operation, 200, "line 1\n\"quoted\" é".as_bytes()).unwrap(), "\"line 1\\n\\\"quoted\\\" é\"");
    assert_eq!(map_response(operation, 200, b"").unwrap(), "\"\"");
    assert_eq!(map_response(operation, 200, &[0xFF, 0xFE]).unwrap_err().message, "Data source returned non-UTF-8 text");
    // The text is a JavaScript literal as well: these two characters end a line there.
    assert_eq!(map_response(operation, 200, "a\u{2028}b".as_bytes()).unwrap(), "\"a\\u2028b\"");
}

#[test]
fn failed_and_oversize_responses_are_rejected() {
    let plugin = base_manifest();
    for status in [199, 301, 404, 500] {
        assert_eq!(map_response(&plugin.operations[0], status, b"{}").unwrap_err().message, "Data source request failed");
    }
    let oversize = vec![b'a'; requests::MAXIMUM_RESPONSE_BYTES + 1];
    assert_eq!(map_response(&plugin.operations[1], 200, &oversize).unwrap_err().message, "Data source response exceeds 2 MiB.");
    assert_eq!(requests::MAXIMUM_RESPONSE_BYTES, 2 * 1024 * 1024);
}
