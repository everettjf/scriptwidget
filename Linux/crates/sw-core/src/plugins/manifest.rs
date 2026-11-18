//! Data Source Plugin 1.0 manifests (`plugin.json`): the model, the strict
//! decoder and the validator. Ported from
//! `Windows/src/ScriptWidget.Core/Plugins/PluginManifest.cs`, itself a port of
//! `DataSourcePluginValidator` in Swift.

use std::collections::HashSet;
use std::fmt;
use std::net::Ipv6Addr;

use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

use crate::api::policy;
use crate::json::Object;
use crate::plugins::strict_json;

/// Where a parameter value goes in the request (`DataSourceParameterLocation` in Swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginParameterLocation {
    Path,
    Query,
    Header,
    JsonBody,
}

impl PluginParameterLocation {
    /// The name in `plugin.json`.
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Path => "path",
            Self::Query => "query",
            Self::Header => "header",
            Self::JsonBody => "jsonBody",
        }
    }

    pub fn from_wire_name(name: &str) -> Option<Self> {
        match name {
            "path" => Some(Self::Path),
            "query" => Some(Self::Query),
            "header" => Some(Self::Header),
            "jsonBody" => Some(Self::JsonBody),
            _ => None,
        }
    }
}

/// How a response body is handed to the widget (`DataSourceResponseType` in Swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginResponseType {
    Json,
    Text,
}

impl PluginResponseType {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Text => "text",
        }
    }

    pub fn from_wire_name(name: &str) -> Option<Self> {
        match name {
            "json" => Some(Self::Json),
            "text" => Some(Self::Text),
            _ => None,
        }
    }
}

/// One declared operation parameter. A plugin can only place values where it declared them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginParameter {
    pub id: String,
    pub label: String,
    pub location: PluginParameterLocation,
    pub required: bool,
    pub default_value: Option<String>,
}

/// One declared HTTPS request template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginOperation {
    pub id: String,
    pub title: String,
    pub method: String,
    pub path: String,
    pub response_type: PluginResponseType,
    pub parameters: Vec<PluginParameter>,
}

/// A Data Source Plugin 1.0 manifest. It is data: a mapping from parameters
/// to HTTPS requests against the hosts it declares. It carries no code and no
/// permissions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginManifest {
    pub format_version: i32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub summary: String,
    pub symbol: String,
    pub author: String,
    pub license: String,
    pub minimum_runtime_version: String,
    pub base_url: String,
    pub hosts: Vec<String>,
    pub operations: Vec<PluginOperation>,
}

impl PluginManifest {
    /// The only supported `formatVersion`; any other value fails closed.
    pub const CURRENT_FORMAT_VERSION: i32 = 1;

    /// `plugin.json` text with sorted keys and two-space indentation, the
    /// form Swift writes (`.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`).
    /// An absent `defaultValue` is omitted.
    pub fn to_json(&self) -> String {
        let q = strict_json::quote;
        let mut output = String::from("{\n");
        output.push_str(&format!("  \"author\": {},\n", q(&self.author)));
        output.push_str(&format!("  \"baseURL\": {},\n", q(&self.base_url)));
        output.push_str(&format!("  \"formatVersion\": {},\n", self.format_version));
        output.push_str(&format!("  \"hosts\": [{}],\n", self.hosts.iter().map(|host| q(host)).collect::<Vec<_>>().join(", ")));
        output.push_str(&format!("  \"id\": {},\n", q(&self.id)));
        output.push_str(&format!("  \"license\": {},\n", q(&self.license)));
        output.push_str(&format!("  \"minimumRuntimeVersion\": {},\n", q(&self.minimum_runtime_version)));
        output.push_str(&format!("  \"name\": {},\n", q(&self.name)));
        output.push_str("  \"operations\": [");
        for (index, operation) in self.operations.iter().enumerate() {
            output.push_str(if index == 0 { "\n" } else { ",\n" });
            output.push_str("    {\n");
            output.push_str(&format!("      \"id\": {},\n", q(&operation.id)));
            output.push_str(&format!("      \"method\": {},\n", q(&operation.method)));
            output.push_str("      \"parameters\": [");
            for (parameter_index, parameter) in operation.parameters.iter().enumerate() {
                output.push_str(if parameter_index == 0 { "\n" } else { ",\n" });
                output.push_str("        {");
                if let Some(default_value) = &parameter.default_value {
                    output.push_str(&format!("\"defaultValue\": {}, ", q(default_value)));
                }
                output.push_str(&format!("\"id\": {}, \"label\": {}, ", q(&parameter.id), q(&parameter.label)));
                output.push_str(&format!("\"location\": {}, \"required\": {}}}", q(parameter.location.wire_name()), parameter.required));
            }
            output.push_str(if operation.parameters.is_empty() { "],\n" } else { "\n      ],\n" });
            output.push_str(&format!("      \"path\": {},\n", q(&operation.path)));
            output.push_str(&format!("      \"responseType\": {},\n", q(operation.response_type.wire_name())));
            output.push_str(&format!("      \"title\": {}\n", q(&operation.title)));
            output.push_str("    }");
        }
        output.push_str(if self.operations.is_empty() { "],\n" } else { "\n  ],\n" });
        output.push_str(&format!("  \"summary\": {},\n", q(&self.summary)));
        output.push_str(&format!("  \"symbol\": {},\n", q(&self.symbol)));
        output.push_str(&format!("  \"version\": {}\n", q(&self.version)));
        output.push_str("}\n");
        output
    }
}

/// What went wrong in the plugin layer (the cases of `DataSourcePluginError` in Swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginErrorKind {
    InvalidManifest,
    NotFound,
    Permission,
    InvalidParameters,
    Network,
    Storage,
}

/// The single failure type of the plugin layer. `message` is the text shown
/// to the user or passed to the script's rejection handler.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginError {
    pub kind: PluginErrorKind,
    pub message: String,
}

impl PluginError {
    pub fn new(kind: PluginErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into() }
    }

    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::InvalidManifest, message)
    }
}

impl fmt::Display for PluginError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for PluginError {}

/// One reason a manifest is refused. `id` is the stable Swift issue identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginValidationIssue {
    pub id: String,
    pub message: String,
}

/// `DataSourcePluginValidator.maximumManifestBytes`: bounds parsing work for an untrusted file.
pub const MAXIMUM_MANIFEST_BYTES: usize = 256 * 1024;
/// `DataSourcePluginValidator.maximumOperations`.
pub const MAXIMUM_OPERATIONS: usize = 50;
/// `DataSourcePluginValidator.maximumParameters` (per operation).
pub const MAXIMUM_PARAMETERS: usize = 30;
/// Most host declarations a plugin may carry.
pub const MAXIMUM_HOSTS: usize = 20;
/// Longest plugin name, in user-perceived characters.
pub const MAXIMUM_NAME_CHARACTERS: usize = 80;
/// `ScriptWidgetBuildContract.runtimeAPIVersion`: the only `minimumRuntimeVersion` accepted.
pub const RUNTIME_API_VERSION: &str = "1.0";

const ROOT_KEYS: [&str; 12] = ["formatVersion", "id", "name", "version", "summary", "symbol", "author", "license", "minimumRuntimeVersion", "baseURL", "hosts", "operations"];
const OPERATION_KEYS: [&str; 6] = ["id", "title", "method", "path", "responseType", "parameters"];
const PARAMETER_KEYS: [&str; 5] = ["id", "label", "location", "required", "defaultValue"];
const METHODS: [&str; 5] = ["GET", "POST", "PUT", "PATCH", "DELETE"];

fn identifier_character(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-'
}

/// `[A-Za-z0-9][A-Za-z0-9.-]{2,127}`.
fn is_identifier(text: &str) -> bool {
    let bytes = text.as_bytes();
    (3..=128).contains(&bytes.len()) && bytes[0].is_ascii_alphanumeric() && bytes.iter().all(|byte| identifier_character(*byte))
}

/// `[0-9]+.[0-9]+.[0-9]+(-[0-9A-Za-z.-]+)?`.
fn is_semantic_version(text: &str) -> bool {
    let (core, suffix) = match text.split_once('-') {
        Some((core, suffix)) => (core, Some(suffix)),
        None => (text, None),
    };
    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3 && parts.iter().all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())) && suffix.is_none_or(|suffix| !suffix.is_empty() && suffix.bytes().all(identifier_character))
}

/// A token of RFC 9110.
fn is_header_name(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"!#$%&'*+.^_`|~-".contains(&byte))
}

/// The names between braces in a path: `{([A-Za-z0-9.-]+)}`.
fn placeholders(path: &str) -> Vec<&str> {
    let mut found = Vec::new();
    let mut rest = path;
    while let Some(open) = rest.find('{') {
        let after = &rest[open + 1..];
        let length = after.bytes().take_while(|byte| identifier_character(*byte)).count();
        if length > 0 && after.as_bytes().get(length) == Some(&b'}') {
            found.push(&after[..length]);
            rest = &after[length + 1..];
        } else {
            rest = after;
        }
    }
    found
}

/// Decodes and validates `plugin.json` bytes.
///
/// Security rules, each failing closed with [`PluginErrorKind::InvalidManifest`]:
/// - at most 256 KiB, strict UTF-8, strict JSON with no duplicate keys;
/// - unknown keys at any level are rejected, so a future or misspelled
///   capability is never silently ignored;
/// - every field must be present with its exact JSON type (no coercion);
/// - then every rule of [`validate`].
pub fn decode(data: &[u8]) -> Result<PluginManifest, PluginError> {
    if data.len() > MAXIMUM_MANIFEST_BYTES {
        return Err(PluginError::invalid("plugin.json exceeds 256 KiB."));
    }
    let text = decode_utf8(data).ok_or_else(|| PluginError::invalid("plugin.json must be UTF-8 JSON."))?;
    let parsed = strict_json::parse(text, false).map_err(|_| PluginError::invalid("plugin.json is not valid JSON."))?;
    let Value::Object(root) = parsed else { return Err(PluginError::invalid("plugin.json must be an object.")) };
    let operations = objects(root.get("operations"));
    let Some(operations) = operations.filter(|_| root.keys().all(|key| ROOT_KEYS.contains(&key.as_str()))) else {
        return Err(PluginError::invalid("plugin.json contains unknown fields."));
    };
    for operation in &operations {
        let parameters = objects(operation.get("parameters"));
        let known = operation.keys().all(|key| OPERATION_KEYS.contains(&key.as_str()));
        if !known || !parameters.is_some_and(|parameters| parameters.iter().all(|parameter| parameter.keys().all(|key| PARAMETER_KEYS.contains(&key.as_str())))) {
            return Err(PluginError::invalid("Plugin operation contains unknown fields."));
        }
    }
    let hosts = || match root.get("hosts") {
        Some(Value::Array(hosts)) => hosts.iter().map(|host| host.as_str().map(str::to_owned).ok_or_else(|| malformed("hosts"))).collect::<Result<Vec<_>, _>>(),
        _ => Err(malformed("hosts")),
    };
    // Fields are read in this order, so the first one that is wrong is the one reported.
    let manifest = PluginManifest {
        format_version: integer(&root, "formatVersion")?,
        id: string(&root, "id")?,
        name: string(&root, "name")?,
        version: string(&root, "version")?,
        summary: string(&root, "summary")?,
        symbol: string(&root, "symbol")?,
        author: string(&root, "author")?,
        license: string(&root, "license")?,
        minimum_runtime_version: string(&root, "minimumRuntimeVersion")?,
        base_url: string(&root, "baseURL")?,
        hosts: hosts()?,
        operations: operations
            .iter()
            .map(|operation| {
                Ok(PluginOperation {
                    id: string(operation, "id")?,
                    title: string(operation, "title")?,
                    method: string(operation, "method")?,
                    path: string(operation, "path")?,
                    response_type: PluginResponseType::from_wire_name(&string(operation, "responseType")?).ok_or_else(|| malformed("responseType"))?,
                    parameters: objects(operation.get("parameters"))
                        .unwrap_or_default()
                        .iter()
                        .map(|parameter| {
                            Ok(PluginParameter {
                                id: string(parameter, "id")?,
                                label: string(parameter, "label")?,
                                location: PluginParameterLocation::from_wire_name(&string(parameter, "location")?).ok_or_else(|| malformed("location"))?,
                                required: parameter.get("required").and_then(Value::as_bool).ok_or_else(|| malformed("required"))?,
                                default_value: match parameter.get("defaultValue") {
                                    None | Some(Value::Null) => None,
                                    Some(Value::String(value)) => Some(value.clone()),
                                    Some(_) => return Err(malformed("defaultValue")),
                                },
                            })
                        })
                        .collect::<Result<Vec<_>, PluginError>>()?,
                })
            })
            .collect::<Result<Vec<_>, PluginError>>()?,
    };
    let issues = validate(&manifest);
    if !issues.is_empty() {
        return Err(PluginError::invalid(issues.iter().map(|issue| issue.message.as_str()).collect::<Vec<_>>().join("\n")));
    }
    Ok(manifest)
}

/// Semantic rules of Data Source Plugin 1.0. An empty list means the manifest is valid.
///
/// - `formatVersion` must be 1 and `minimumRuntimeVersion` the supported
///   runtime: unsupported versions fail closed instead of being run with
///   guessed semantics.
/// - `baseURL` must be HTTPS without credentials, query or fragment: plugins
///   never send cleartext requests and never embed secrets in the manifest.
/// - 1–20 unique, well-formed `hosts` that include the `baseURL` host and are
///   public Internet names: a plugin can only reach hosts the user can
///   review, never the device or local network.
/// - 1–50 operations with unique ids, an upper-case standard method, and an
///   absolute path with no `..`, query or fragment: an operation cannot leave
///   its declared path space.
/// - At most 30 parameters per operation, unique ids, every `{placeholder}`
///   declared as a `path` parameter and every `path` parameter present in the
///   path; header parameter ids must be valid header names.
pub fn validate(manifest: &PluginManifest) -> Vec<PluginValidationIssue> {
    let mut issues: Vec<PluginValidationIssue> = Vec::new();
    let mut reject = |id: &str, message: String| issues.push(PluginValidationIssue { id: id.to_owned(), message });
    if manifest.format_version != PluginManifest::CURRENT_FORMAT_VERSION {
        reject("format", format!("Unsupported Data Source Plugin format {}.", manifest.format_version));
    }
    if !is_identifier(&manifest.id) {
        reject("id", "Plugin id must be a stable 3–128 character identifier.".into());
    }
    if manifest.name.trim().is_empty() || manifest.name.graphemes(true).count() > MAXIMUM_NAME_CHARACTERS {
        reject("name", "Plugin name must contain 1–80 characters.".into());
    }
    if !is_semantic_version(&manifest.version) {
        reject("version", "Plugin version must use semantic versioning.".into());
    }
    if manifest.minimum_runtime_version != RUNTIME_API_VERSION {
        reject("runtime", format!("Plugin requires unsupported runtime {}.", manifest.minimum_runtime_version));
    }
    let address = PluginUrl::parse(&manifest.base_url);
    let base_host = address.as_ref().and_then(|address| address.host.as_deref()).map(str::to_lowercase).filter(|host| !host.is_empty());
    let usable = address.as_ref().is_some_and(|address| address.scheme.as_deref().map(str::to_lowercase).as_deref() == Some("https") && !address.has_user_info && !address.has_query && !address.has_fragment);
    let Some(base_host) = base_host.filter(|_| usable) else {
        reject("base_url", "baseURL must be an HTTPS URL without credentials, query, or fragment.".into());
        return issues;
    };
    if manifest.hosts.is_empty() || manifest.hosts.len() > MAXIMUM_HOSTS {
        reject("hosts", "A plugin must declare 1–20 HTTPS hosts.".into());
    }
    if manifest.hosts.iter().collect::<HashSet<_>>().len() != manifest.hosts.len() {
        reject("hosts", "Plugin hosts must be unique.".into());
    }
    for host in &manifest.hosts {
        if !is_valid_domain_declaration(host) {
            reject("host", format!("Invalid plugin host declaration: {host}."));
        } else {
            // "*.local" covers only private names; test it as a name it would match.
            let probe = match host.strip_prefix("*.") {
                Some(suffix) => format!("x.{suffix}"),
                None => host.clone(),
            };
            if policy::blocked_host_name(&probe) {
                reject("host", format!("Plugin host must be a public Internet host: {host}."));
            }
        }
    }
    if policy::blocked_host_name(PluginUrl::unbracket(&base_host)) {
        reject("base_host", "baseURL must use a public Internet host.".into());
    }
    if !policy::host_matches(&base_host, manifest.hosts.iter().map(String::as_str)) {
        reject("base_host", "baseURL host must be included in hosts.".into());
    }
    if manifest.operations.is_empty() || manifest.operations.len() > MAXIMUM_OPERATIONS {
        reject("operations", format!("A plugin must contain 1–{MAXIMUM_OPERATIONS} operations."));
    }
    if manifest.operations.iter().map(|operation| operation.id.to_lowercase()).collect::<HashSet<_>>().len() != manifest.operations.len() {
        reject("operation_ids", "Operation ids must be unique.".into());
    }
    for operation in &manifest.operations {
        let prefix = format!("operation.{}", operation.id);
        if !is_identifier(&operation.id) {
            reject(&prefix, format!("Operation id is invalid: {}.", operation.id));
        }
        if !METHODS.contains(&operation.method.as_str()) {
            reject(&prefix, format!("Operation {} has an unsupported HTTP method.", operation.id));
        }
        if operation.path.is_empty() || !operation.path.starts_with('/') || operation.path.contains("..") || operation.path.contains('?') || operation.path.contains('#') {
            reject(&prefix, "Operation path must be an absolute URL path without traversal, query, or fragment.".into());
        }
        if operation.parameters.len() > MAXIMUM_PARAMETERS {
            reject(&prefix, format!("Operation {} has too many parameters.", operation.id));
        }
        if operation.parameters.iter().map(|parameter| parameter.id.to_lowercase()).collect::<HashSet<_>>().len() != operation.parameters.len() {
            reject(&prefix, "Operation parameter ids must be unique.".into());
        }
        for parameter in &operation.parameters {
            let placeholder = format!("{{{}}}", parameter.id);
            let in_path = operation.path.contains(&placeholder);
            if !is_identifier(&parameter.id) {
                reject(&prefix, format!("Invalid parameter id: {}.", parameter.id));
            }
            if parameter.location == PluginParameterLocation::Path && !in_path {
                reject(&prefix, format!("Path parameter {} has no matching placeholder.", parameter.id));
            }
            if parameter.location != PluginParameterLocation::Path && in_path {
                reject(&prefix, format!("Placeholder {} must be a path parameter.", parameter.id));
            }
            if parameter.location == PluginParameterLocation::Header && !is_header_name(&parameter.id) {
                reject(&prefix, format!("Header parameter {} is invalid.", parameter.id));
            }
        }
        for placeholder in placeholders(&operation.path) {
            if !operation.parameters.iter().any(|parameter| parameter.id == placeholder) {
                reject(&prefix, format!("Path placeholder {placeholder} has no declared parameter."));
            }
        }
    }
    issues
}

/// `ScriptWidgetNetworkPolicy.isValidDomainDeclaration`: a lower-case host
/// name, optionally `*.`-prefixed, with no scheme, path or port, so a
/// declaration cannot smuggle a URL.
pub fn is_valid_domain_declaration(value: &str) -> bool {
    let normalized = value.to_lowercase();
    value == normalized
        && !normalized.contains("://")
        && !normalized.contains('/')
        && !normalized.contains(':')
        && !normalized.starts_with('.')
        && !normalized.ends_with('.')
        && !normalized.is_empty()
        && normalized.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'*' | b'.' | b'-'))
        && (!normalized.contains('*') || (normalized.starts_with("*.") && !normalized[1..].contains('*')))
}

fn objects(value: Option<&Value>) -> Option<Vec<&Object>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

fn string(map: &Object, key: &str) -> Result<String, PluginError> {
    map.get(key).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| malformed(key))
}

/// Whole JSON numbers only; `1.0` is accepted like Swift's `JSONDecoder`, `1.5` and `"1"` are not.
fn integer(map: &Object, key: &str) -> Result<i32, PluginError> {
    match map.get(key) {
        Some(Value::Number(number)) => {
            if let Some(whole) = number.as_i64() {
                return i32::try_from(whole).map_err(|_| malformed(key));
            }
            match number.as_f64() {
                Some(value) if number.is_f64() && value == value.round_ties_even() && value.abs() <= f64::from(i32::MAX) => Ok(value as i32),
                _ => Err(malformed(key)),
            }
        }
        _ => Err(malformed(key)),
    }
}

/// Strict UTF-8 text without a byte order mark, or `None` when the bytes are malformed.
pub fn decode_utf8(bytes: &[u8]) -> Option<&str> {
    std::str::from_utf8(bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes)).ok()
}

fn malformed(key: &str) -> PluginError {
    PluginError::invalid(format!("plugin.json field \"{key}\" is missing or has the wrong type."))
}

/// A URL split the way `java.net.URI` splits it, which is what the Android
/// validator and request builder rely on. It is deliberately stricter than a
/// browser's parser: no spaces, no backslashes, no characters outside the URI
/// grammar, and a host only when the authority is a plain server name, an
/// IPv4 address or a bracketed IPv6 address.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PluginUrl {
    pub scheme: Option<String>,
    /// The host as written (brackets included for IPv6), or `None` when there is none.
    pub host: Option<String>,
    pub port: Option<u32>,
    pub has_user_info: bool,
    pub raw_path: String,
    pub has_query: bool,
    pub has_fragment: bool,
}

impl PluginUrl {
    pub fn unbracket(host: &str) -> &str {
        host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host)
    }

    /// `None` when `text` is not a URI at all.
    pub fn parse(text: &str) -> Option<Self> {
        if text.is_empty() {
            return Some(Self::default());
        }
        let (mut rest, fragment) = match text.split_once('#') {
            Some((rest, fragment)) => (rest, Some(fragment)),
            None => (text, None),
        };
        let has_fragment = fragment.is_some();
        if fragment.is_some_and(|fragment| !legal(fragment, false) || fragment.contains('#')) {
            return None;
        }

        let mut scheme = None;
        if let Some(stop) = rest.find(['/', '?', ':']).filter(|stop| rest.as_bytes()[*stop] == b':') {
            let name = &rest[..stop];
            let valid = name.as_bytes().first().is_some_and(u8::is_ascii_alphabetic) && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'));
            if !valid {
                return None;
            }
            scheme = Some(name.to_owned());
            rest = &rest[stop + 1..];
            if rest.is_empty() {
                return None;
            }
            // An opaque URI such as "mailto:someone" has no host, path or query.
            if !rest.starts_with('/') {
                return legal(rest, false).then(|| Self { scheme, has_fragment, ..Self::default() });
            }
        }

        let mut authority = None;
        if let Some(after) = rest.strip_prefix("//") {
            let end = after.find(['/', '?']).unwrap_or(after.len());
            let found = &after[..end];
            rest = &after[end..];
            if !legal(found, true) {
                return None;
            }
            authority = Some(found);
        }
        let (path, query) = match rest.split_once('?') {
            Some((path, query)) => (path, Some(query)),
            None => (rest, None),
        };
        if !legal(path, false) || query.is_some_and(|query| !legal(query, false)) {
            return None;
        }

        let mut host = None;
        let mut port = None;
        let mut has_user_info = false;
        if let Some(authority) = authority.filter(|authority| !authority.is_empty()) {
            let (user, server) = match authority.split_once('@') {
                Some((_, server)) => (true, server),
                None => (false, authority),
            };
            let mut name = "";
            let mut port_text = "";
            if server.starts_with('[') {
                if let Some(close) = server.find(']') {
                    let after = &server[close + 1..];
                    if after.is_empty() || after.starts_with(':') {
                        name = &server[..close + 1];
                        port_text = after.strip_prefix(':').unwrap_or("");
                    }
                    if !name.is_empty() && name[1..name.len() - 1].parse::<Ipv6Addr>().is_err() {
                        name = "";
                    }
                }
            } else {
                let (candidate, after) = server.split_once(':').unwrap_or((server, ""));
                port_text = after;
                if server_name(candidate) {
                    name = candidate;
                }
            }
            // Anything else is a registry-based authority: it has no host, port or user information.
            let digits = port_text.bytes().all(|byte| byte.is_ascii_digit());
            let number = if port_text.is_empty() { None } else { port_text.parse::<u32>().ok().filter(|port| *port <= i32::MAX as u32) };
            if !name.is_empty() && digits && (port_text.is_empty() || number.is_some()) {
                host = Some(name.to_owned());
                has_user_info = user;
                port = number;
            }
        }
        Some(Self { scheme, host, port, has_user_info, raw_path: path.to_owned(), has_query: query.is_some(), has_fragment })
    }
}

/// An IPv4 address, or a host name of letter-digit-hyphen labels whose last label starts with a letter.
fn server_name(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let mut labels: Vec<&str> = name.split('.').collect();
    if labels.len() == 4 && labels.iter().all(|label| (1..=3).contains(&label.len()) && label.bytes().all(|byte| byte.is_ascii_digit()) && label.parse::<u32>().is_ok_and(|value| value <= 255)) {
        return true;
    }
    if labels.last().is_some_and(|label| label.is_empty()) {
        labels.pop();
    }
    if labels.is_empty() {
        return false;
    }
    let well_formed = labels.iter().all(|label| !label.is_empty() && label.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-') && !label.starts_with('-') && !label.ends_with('-'));
    well_formed && labels.last().is_some_and(|label| label.as_bytes()[0].is_ascii_alphabetic())
}

/// True when every character may appear in a URI and every `%` starts a two-digit escape.
fn legal(part: &str, brackets: bool) -> bool {
    let bytes = part.as_bytes();
    let mut characters = part.char_indices();
    while let Some((index, character)) = characters.next() {
        match character {
            '%' => {
                if index + 2 >= bytes.len() || !bytes[index + 1].is_ascii_hexdigit() || !bytes[index + 2].is_ascii_hexdigit() {
                    return false;
                }
                characters.next();
                characters.next();
            }
            '[' | ']' => {
                if !brackets {
                    return false;
                }
            }
            character if character.is_ascii() => {
                if !character.is_ascii_alphanumeric() && !"-_.!~*'();/?:@&=+$,".contains(character) {
                    return false;
                }
            }
            character => {
                if character.is_control() || character.is_whitespace() {
                    return false;
                }
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_are_split_like_java_net_uri() {
        let url = PluginUrl::parse("https://api.example.com:8443/v2?x=1#top").unwrap();
        assert_eq!((url.scheme.as_deref(), url.host.as_deref(), url.port, url.raw_path.as_str(), url.has_query, url.has_fragment), (Some("https"), Some("api.example.com"), Some(8443), "/v2", true, true));
        assert!(PluginUrl::parse("https://user:pw@api.example.com").unwrap().has_user_info);
        assert_eq!(PluginUrl::parse("https://[2606:4700::1111]:443/x").unwrap().host.as_deref(), Some("[2606:4700::1111]"));
        assert_eq!(PluginUrl::parse("https://10.0.0.1/").unwrap().host.as_deref(), Some("10.0.0.1"));
        assert_eq!(PluginUrl::parse("mailto:someone").unwrap().host, None);
        assert_eq!(PluginUrl::parse("api.example.com").unwrap().scheme, None);
        // No host: an underscore, a numeric last label, a bad port, an empty authority, a bad IPv6 literal.
        for text in ["https://api_internal.example.com", "https://example.123", "https://api.example.com:port", "https:///path", "https://[::g]/", "https://-a.example.com"] {
            assert_eq!(PluginUrl::parse(text).and_then(|url| url.host), None, "{text}");
        }
        // Not a URI at all.
        for text in ["https://api example.com", "https://api.example.com\\@evil.example.net", "https:\\\\api.example.com", "https://api.example.com/%zz", "https://api.example.com/a b", " https://api.example.com", "https://api.example.com\n", "1https://x", "https:", "https://a/#a#b"] {
            assert_eq!(PluginUrl::parse(text), None, "{text:?}");
        }
    }

    #[test]
    fn small_grammars_match_their_patterns() {
        assert!(is_identifier("abc") && is_identifier("a.b-c") && is_identifier(&"a".repeat(128)));
        for text in ["ab", "-abc", ".abc", "has space", "a/b/c", "abc\n", ""] {
            assert!(!is_identifier(text), "{text:?}");
        }
        assert!(!is_identifier(&"a".repeat(129)));
        assert!(is_semantic_version("1.0.0") && is_semantic_version("10.20.30-beta.1") && is_semantic_version("1.0.0-a-b"));
        for text in ["1.0", "v1.0.0", "1.0.0-", "1..0", "1.0.0.0", "1.0.0-beta+build", ""] {
            assert!(!is_semantic_version(text), "{text:?}");
        }
        assert_eq!(placeholders("/teams/{team}/users/{user}/{}/{a b}/{x.y-z}"), ["team", "user", "x.y-z"]);
        assert_eq!(placeholders("/{{a}}"), ["a"]);
        assert!(is_header_name("X-Token") && !is_header_name("X Token") && !is_header_name("") && !is_header_name("a:b"));
    }
}
