//! Maps a plugin operation and script-supplied values to one request, and a
//! response to the value a widget receives. Ported from
//! `Windows/src/ScriptWidget.Core/Plugins/DataSourceRequests.cs`
//! (`DataSourceRequestBuilder.prepare` in Swift).

use serde_json::Value;

use crate::api::fetch::{self, Url};
use crate::api::policy;
use crate::json::{Object, stringify_object};
use crate::plugins::manifest::{PluginError, PluginErrorKind, PluginManifest, PluginOperation, PluginParameterLocation, PluginResponseType, PluginUrl, decode_utf8};
use crate::plugins::strict_json;

/// A fully resolved plugin request: nothing in it is taken from script input without validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedDataSourceRequest {
    pub plugin: PluginManifest,
    pub operation: PluginOperation,
    pub method: String,
    pub url: Url,
    pub headers: Vec<(String, String)>,
    /// JSON body built from `jsonBody` parameters, or `None` when there are none.
    pub body: Option<Vec<u8>>,
}

impl PreparedDataSourceRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(known, _)| known == name).map(|(_, value)| value.as_str())
    }
}

/// Sent with every plugin request, replacing any `User-Agent` header parameter.
pub const USER_AGENT: &str = "ScriptWidget-DataSource/1";

// CharacterSet.urlPathAllowed without "/?#{}": a path value can never add a segment, a query or a fragment.
const PATH_ALLOWED: &str = "-._~!$&'()*+,=:@";
// What URLComponents.queryItems leaves unescaped: "&" and "=" are always encoded, so a value cannot add a query item.
const QUERY_ALLOWED: &str = "-._~!$'()*+,;:@/?";

fn invalid_parameters(message: String) -> PluginError {
    PluginError::new(PluginErrorKind::InvalidParameters, message)
}

/// Builds the request for `operation_id` of `plugin`.
///
/// `values` come from package code and are untrusted. Strings, booleans and
/// numbers are accepted everywhere, objects and arrays for `jsonBody`
/// parameters only; null means "not supplied". Booleans are sent as `1`/`0`
/// in path, query and header positions, which is what the Swift runtime sends
/// for a JavaScript boolean.
///
/// Security rules:
/// - only declared parameters are used; anything else in `values` is ignored,
///   so a script cannot add headers, query items or body fields the plugin
///   did not declare;
/// - path values are percent-encoded including `/`, `?`, `#`, and `.`/`..`
///   values are refused, so a value cannot change the path structure;
/// - query names and values are percent-encoded including `&` and `=`;
/// - header values with control characters are refused (no header injection);
/// - the final URL must be HTTPS and its host must match the plugin's declared hosts.
///
/// Fails with `NotFound` for an unknown operation, `InvalidParameters` for a
/// missing or unusable value, `Permission` when the URL leaves the declared hosts.
pub fn prepare(plugin: &PluginManifest, operation_id: &str, values: &Object) -> Result<PreparedDataSourceRequest, PluginError> {
    let operation = plugin
        .operations
        .iter()
        .find(|item| item.id == operation_id)
        .ok_or_else(|| PluginError::new(PluginErrorKind::NotFound, format!("Operation {operation_id} was not found in {}.", plugin.id)))?;
    let mut path = operation.path.clone();
    let mut query: Vec<(String, String)> = Vec::new();
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut body = Object::new();
    for parameter in &operation.parameters {
        let could_not_encode = || invalid_parameters(format!("Could not encode {}.", parameter.id));
        // JSON null and a missing member both mean "not supplied".
        let raw: Option<Value> = values.get(&parameter.id).filter(|value| !value.is_null()).cloned().or_else(|| parameter.default_value.clone().map(Value::String));
        let structured = matches!(raw, Some(Value::Object(_) | Value::Array(_)));
        let text = match &raw {
            Some(value) if !structured => describe(value).ok_or_else(could_not_encode)?,
            _ => String::new(),
        };
        let Some(raw) = raw.filter(|_| structured || !text.is_empty()) else {
            if parameter.required {
                return Err(invalid_parameters(format!("Missing required parameter {}.", parameter.id)));
            }
            continue;
        };
        if structured && parameter.location != PluginParameterLocation::JsonBody {
            return Err(could_not_encode());
        }
        match parameter.location {
            PluginParameterLocation::Path => {
                if text == "." || text == ".." {
                    return Err(could_not_encode());
                }
                path = path.replace(&format!("{{{}}}", parameter.id), &percent_encode(&text, PATH_ALLOWED));
            }
            PluginParameterLocation::Query => query.push((parameter.id.clone(), text)),
            PluginParameterLocation::Header => {
                if text.chars().any(|character| character < ' ' || character == '\u{7f}') {
                    return Err(could_not_encode());
                }
                set_header(&mut headers, &parameter.id, text);
            }
            PluginParameterLocation::JsonBody => {
                body.insert(parameter.id.clone(), raw);
            }
        }
    }
    if path.contains(['{', '}']) {
        return Err(invalid_parameters("A path parameter is unresolved.".into()));
    }
    let invalid_base = || PluginError::invalid("Invalid plugin baseURL.");
    let escaped = || PluginError::new(PluginErrorKind::Permission, "Plugin request escaped its declared hosts.");
    let address = PluginUrl::parse(&plugin.base_url).ok_or_else(invalid_base)?;
    let (Some(scheme), Some(base_host)) = (address.scheme.as_deref(), address.host.as_deref().filter(|host| !host.is_empty())) else { return Err(invalid_base()) };
    let mut assembled = format!("{}://{base_host}", scheme.to_lowercase());
    if let Some(port) = address.port {
        assembled.push_str(&format!(":{port}"));
    }
    if address.raw_path != "/" {
        assembled.push_str(&address.raw_path);
    }
    assembled.push_str(&path);
    if !query.is_empty() {
        assembled.push('?');
        assembled.push_str(&query.iter().map(|(name, value)| format!("{}={}", percent_encode(name, QUERY_ALLOWED), percent_encode(value, QUERY_ALLOWED))).collect::<Vec<_>>().join("&"));
    }
    let parsed = PluginUrl::parse(&assembled).ok_or_else(invalid_base)?;
    let host = parsed.host.as_deref().map(str::to_lowercase);
    if parsed.scheme.as_deref() != Some("https") || !host.is_some_and(|host| policy::host_matches(&host, plugin.hosts.iter().map(String::as_str))) {
        return Err(escaped());
    }
    // The transport sends what its own URL parser understood, so the same rule is applied to that reading of the URL.
    let url = Url::parse(&assembled).map_err(|_| invalid_base())?;
    if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() || !policy::host_matches(url.host_str().unwrap_or(""), plugin.hosts.iter().map(String::as_str)) {
        return Err(escaped());
    }
    let has_body = !body.is_empty();
    headers.retain(|(name, _)| !name.eq_ignore_ascii_case("User-Agent") && !(has_body && name.eq_ignore_ascii_case("Content-Type")));
    headers.push(("User-Agent".into(), USER_AGENT.into()));
    if has_body {
        headers.push(("Content-Type".into(), "application/json".into()));
    }
    Ok(PreparedDataSourceRequest {
        plugin: plugin.clone(),
        operation: operation.clone(),
        method: operation.method.clone(),
        url,
        headers,
        body: has_body.then(|| stringify_object(&body).into_bytes()),
    })
}

fn set_header(headers: &mut Vec<(String, String)>, name: &str, value: String) {
    match headers.iter_mut().find(|(known, _)| known == name) {
        Some(entry) => entry.1 = value,
        None => headers.push((name.to_owned(), value)),
    }
}

/// Text form of a scalar value, or `None` when it has none.
fn describe(raw: &Value) -> Option<String> {
    match raw {
        Value::String(value) => Some(value.clone()),
        Value::Bool(value) => Some(if *value { "1" } else { "0" }.to_owned()),
        Value::Number(number) => match number.as_i64() {
            Some(whole) => Some(whole.to_string()),
            None => {
                let value = number.as_f64().filter(|value| value.is_finite())?;
                // A whole number is written without a fraction; anything else in the shortest
                // decimal form that reads back as the same number, without an exponent.
                Some(if value == value.round_ties_even() && value.abs() < 1e15 { (value as i64).to_string() } else { value.to_string() })
            }
        },
        _ => None,
    }
}

/// Percent-encodes every UTF-8 byte that is not an ASCII letter, digit or in `allowed`.
pub fn percent_encode(value: &str, allowed: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || allowed.as_bytes().contains(&byte) {
            output.push(byte as char);
        } else {
            output.push_str(&format!("%{byte:02X}"));
        }
    }
    output
}

/// `ScriptWidgetFetchManager.maximumResponseBytes`: plugin responses share the 2 MiB fetch limit.
pub const MAXIMUM_RESPONSE_BYTES: usize = fetch::MAXIMUM_RESPONSE_BYTES;

/// Turns an HTTP response into the JSON text delivered to the script: the
/// response document itself for a `json` operation, or a JSON string literal
/// for a `text` operation.
///
/// Fails closed with [`PluginErrorKind::Network`]: a non-2xx status, more
/// than 2 MiB, a `json` body that is not one well-formed UTF-8 JSON object or
/// array, or a `text` body that is not valid UTF-8. Response content is never
/// included in the error message.
pub fn map_response(operation: &PluginOperation, status: u16, body: &[u8]) -> Result<String, PluginError> {
    let network = |message: &str| PluginError::new(PluginErrorKind::Network, message);
    if !(200..=299).contains(&status) {
        return Err(network("Data source request failed"));
    }
    if body.len() > MAXIMUM_RESPONSE_BYTES {
        return Err(network("Data source response exceeds 2 MiB."));
    }
    let text = decode_utf8(body);
    if operation.response_type == PluginResponseType::Text {
        return text.map(strict_json::quote).ok_or_else(|| network("Data source returned non-UTF-8 text"));
    }
    let invalid = || network("Data source returned invalid JSON");
    let text = text.ok_or_else(invalid)?;
    // JSONSerialization without .fragmentsAllowed accepts only containers at the top level.
    match strict_json::validate(text) {
        Ok(strict_json::Kind::Object | strict_json::Kind::Array) => Ok(text.to_owned()),
        _ => Err(invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn scalars_have_one_text_form() {
        for (value, expected) in [(json!("x"), "x"), (json!(true), "1"), (json!(false), "0"), (json!(42), "42"), (json!(-7), "-7"), (json!(2.0), "2"), (json!(1.5), "1.5"), (json!(1e-6), "0.000001"), (json!(1e20), "100000000000000000000"), (json!(-0.25), "-0.25")] {
            assert_eq!(describe(&value).as_deref(), Some(expected), "{value}");
        }
        assert_eq!(describe(&json!([1])), None);
        assert_eq!(describe(&json!({})), None);
        assert_eq!(describe(&Value::Null), None);
    }

    #[test]
    fn percent_encoding_covers_every_byte_outside_the_allowed_set() {
        assert_eq!(percent_encode("a/b?c#d e%", PATH_ALLOWED), "a%2Fb%3Fc%23d%20e%25");
        assert_eq!(percent_encode("a&b=c", QUERY_ALLOWED), "a%26b%3Dc");
        assert_eq!(percent_encode("你", ""), "%E4%BD%A0");
    }
}
