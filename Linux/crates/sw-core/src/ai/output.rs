//! What a model's reply becomes: the code, the optional package declaration,
//! and the judgement of a trial run. Port of `AiOutput.kt`.

use serde_json::{Value, json};

use super::take;
use crate::api::policy;
use crate::json::{Object, ObjectExt, stringify};
use crate::packages::manifests;

/// The package declaration a model may attach to its code: the `network`
/// permission and the hosts the widget contacts. It is the only part of a
/// manifest the model can influence; everything else is written by the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiManifestDeclaration {
    pub permissions: Vec<String>,
    pub network_domains: Vec<String>,
}

impl AiManifestDeclaration {
    /// Permissions generated code may request. Anything else needs a human editing the manifest.
    pub const GRANTABLE_PERMISSIONS: [&'static str; 1] = ["network"];
    /// `AINetworkDeclaration.maximumDomains` and the 4,096 bytes its `parse` reads at most.
    pub const MAXIMUM_DOMAINS: usize = 8;
    pub const MAXIMUM_BYTES: usize = 4_096;

    pub fn new(permissions: Vec<String>, network_domains: Vec<String>) -> Self {
        Self { permissions, network_domains }
    }

    /// Canonical JSON: `{"permissions":[...],"networkDomains":[...]}`.
    pub fn to_json(&self) -> String {
        stringify(&json!({ "permissions": self.permissions, "networkDomains": self.network_domains }))
    }

    /// Returns a copy of `base` with this declaration applied. Permissions the model cannot
    /// grant are kept exactly as `base` has them; `network` and `networkDomains` are replaced.
    pub fn apply_to(&self, base: &Object) -> Object {
        let mut result = base.clone();
        let existing: Vec<String> = base.opt_array("permissions").map(|items| items.iter().map(|item| crate::json::as_text(item).unwrap_or_default()).collect()).unwrap_or_default();
        let mut merged: Vec<String> = Vec::new();
        for permission in existing.into_iter().filter(|permission| !Self::GRANTABLE_PERMISSIONS.contains(&permission.as_str())).chain(self.permissions.iter().cloned()) {
            if !merged.contains(&permission) {
                merged.push(permission);
            }
        }
        result.insert("permissions".into(), json!(merged));
        result.insert("networkDomains".into(), json!(self.network_domains));
        result
    }

    /// What the model is told when a declaration is refused; the same sentence as `AgentLoop.swift`
    /// and `AiOutput.kt`.
    pub fn failure_text(reason: &str) -> String {
        format!("The network declaration block is not valid: {reason}.")
    }

    /// Parses a declaration, failing closed. The error is the reason, worded as
    /// `AINetworkDeclaration.parse` words it, for [`Self::failure_text`] to complete.
    ///
    /// The text is read strictly (no comments, no key twice), where Android's
    /// `org.json` is lenient: what is not plain JSON is not a declaration.
    pub fn parse(json: &str) -> Result<Self, String> {
        const NOT_AN_OBJECT: &str = "it is not a JSON object";
        const ONLY_NETWORK: &str = "\"permissions\" must be exactly [\"network\"]; no other permission can be declared";
        // `AINetworkDeclaration.parse` reads nothing larger.
        if json.len() > Self::MAXIMUM_BYTES {
            return Err(NOT_AN_OBJECT.into());
        }
        let root = manifests::parse(Some(json)).ok_or(NOT_AN_OBJECT)?;
        if root.keys().any(|key| key != "permissions" && key != "networkDomains") {
            return Err("only \"permissions\" and \"networkDomains\" may appear".into());
        }
        let permissions = distinct(strings(&root, "permissions")?);
        if permissions.iter().any(|permission| !Self::GRANTABLE_PERMISSIONS.contains(&permission.as_str())) {
            return Err(ONLY_NETWORK.into());
        }
        let domains = distinct(strings(&root, "networkDomains")?.into_iter().map(|domain| domain.to_lowercase()).collect());
        let network = permissions.iter().any(|permission| permission == "network");
        if !domains.is_empty() && !network {
            return Err(ONLY_NETWORK.into());
        }
        if domains.len() > Self::MAXIMUM_DOMAINS || (network && domains.is_empty()) {
            return Err(format!("\"networkDomains\" must list 1 to {} hosts", Self::MAXIMUM_DOMAINS));
        }
        for domain in &domains {
            if domain.len() > 253 || !is_host(domain) || policy::blocked_host_name(domain.strip_prefix("*.").unwrap_or(domain)) {
                return Err(format!("\"{}\" is not a public host name; use a host such as api.example.com, without scheme or path", take(domain, 80)));
            }
        }
        Ok(Self { permissions, network_domains: domains })
    }

    /// The declaration an existing manifest amounts to, or `None` when it declares no network access.
    pub fn from_manifest(manifest: Option<&Object>) -> Option<Self> {
        let manifest = manifest?;
        let texts = |key: &str| manifest.opt_array(key).map(|items| items.iter().map(|item| crate::json::as_text(item).unwrap_or_default()).collect::<Vec<String>>());
        let permissions: Vec<String> = texts("permissions")?.into_iter().filter(|permission| Self::GRANTABLE_PERMISSIONS.contains(&permission.as_str())).collect();
        if permissions.is_empty() {
            return None;
        }
        Some(Self { permissions, network_domains: texts("networkDomains").unwrap_or_default() })
    }
}

fn distinct(items: Vec<String>) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    for item in items {
        if !result.contains(&item) {
            result.push(item);
        }
    }
    result
}

fn strings(root: &Object, key: &str) -> Result<Vec<String>, String> {
    let wrong = || format!("\"{key}\" must be an array of strings");
    match root.get(key) {
        None => Ok(Vec::new()),
        Some(Value::Array(items)) => items.iter().map(|item| item.as_str().map(str::to_owned).ok_or_else(wrong)).collect(),
        Some(_) => Err(wrong()),
    }
}

/// `^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$` of the Kotlin original.
fn is_host(domain: &str) -> bool {
    let name = domain.strip_prefix("*.").unwrap_or(domain);
    let labels: Vec<&str> = name.split('.').collect();
    let label = |text: &str| {
        let bytes = text.as_bytes();
        let edge = |byte: &u8| byte.is_ascii_lowercase() || byte.is_ascii_digit();
        (1..=63).contains(&bytes.len()) && bytes.first().is_some_and(edge) && bytes.last().is_some_and(edge) && bytes.iter().all(|byte| edge(byte) || *byte == b'-')
    };
    labels.len() >= 2 && labels.iter().all(|text| label(text)) && labels.last().is_some_and(|last| last.as_bytes()[0].is_ascii_lowercase())
}

/// Manifest text for generated candidates. The model only ever influences the network declaration.
pub struct AiManifests;

impl AiManifests {
    /// Name of the manifest file inside a package.
    pub const FILE_NAME: &'static str = manifests::FILE_NAME;
    /// Entry file of a package without a manifest, and of every newly generated widget.
    pub const DEFAULT_ENTRY: &'static str = manifests::LEGACY_ENTRY;

    /// The entry path `manifest` declares, or `main.jsx` when there is no manifest or no string entry.
    pub fn entry(manifest: Option<&Object>) -> String {
        manifest.and_then(|manifest| manifests::string_value(manifest, "entry")).unwrap_or_else(|| Self::DEFAULT_ENTRY.to_owned())
    }

    /// Parses manifest text as a JSON object, or `None`.
    pub fn parse(text: Option<&str>) -> Option<Object> {
        manifests::parse(text)
    }

    /// Manifest text for a candidate.
    ///
    /// With `base` `None` a fresh Package 2.0 manifest named `new_name` is created. Otherwise `base`
    /// (an installed package's manifest) is kept and only its network fields change. A missing or
    /// invalid `declaration_json` leaves the network fields as they are: nothing is granted by default.
    pub fn text(base: Option<&Object>, declaration_json: Option<&str>, new_name: &str) -> String {
        let declaration = declaration_json.and_then(|text| AiManifestDeclaration::parse(text).ok());
        let manifest = base.cloned().unwrap_or_else(|| manifests::new_manifest(new_name));
        let manifest = declaration.map_or_else(|| manifest.clone(), |declaration| declaration.apply_to(&manifest));
        String::from_utf8(manifests::encode(&manifest)).unwrap_or_default()
    }
}

/// Widget source and optional declaration text extracted from one model reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiCandidate {
    pub source: String,
    pub manifest_json: Option<String>,
}

impl AiCandidate {
    pub fn new(source: impl Into<String>, manifest_json: Option<String>) -> Self {
        Self { source: source.into(), manifest_json }
    }

    /// The reply re-assembled in the format the prompt asks for; used as the assistant turn when asking for a fix.
    pub fn as_assistant_message(&self) -> String {
        match &self.manifest_json {
            None => self.source.clone(),
            Some(manifest) => format!("{}\n\n```json\n{manifest}\n```", self.source),
        }
    }
}

/// One fenced block of a reply: where it is, its language tag and what is inside.
struct Fence<'a> {
    start: usize,
    end: usize,
    language: &'a str,
    body: &'a str,
}

/// The matches of the Kotlin pattern "```([A-Za-z0-9_.+-]*)[^\n]*\n(.*?)```", in order, not overlapping.
fn fences(raw: &str) -> Vec<Fence<'_>> {
    let mut result = Vec::new();
    let mut from = 0;
    while let Some(found) = raw[from..].find("```") {
        let start = from + found;
        let after = &raw[start + 3..];
        let tag = after.find(|character: char| !(character.is_ascii_alphanumeric() || matches!(character, '_' | '.' | '+' | '-'))).unwrap_or(after.len());
        let block = after.find('\n').and_then(|newline| {
            let body_start = start + 3 + newline + 1;
            raw[body_start..].find("```").map(|close| (body_start, body_start + close))
        });
        match block {
            Some((body_start, body_end)) => {
                result.push(Fence { start, end: body_end + 3, language: &after[..tag], body: &raw[body_start..body_end] });
                from = body_end + 3;
            }
            // No block starts here; the pattern would try the next character.
            None => from = start + 1,
        }
    }
    result
}

/// Turns raw model output into a candidate.
pub struct AiOutput;

impl AiOutput {
    const DECLARATION_LANGUAGES: [&'static str; 4] = ["json", "json5", "jsonc", "widget.json"];

    /// Splits a reply into code and the optional package declaration.
    ///
    /// The declaration is the last fenced block tagged `json` (or untagged) whose body is a JSON
    /// object; it is returned verbatim for [`AiManifestDeclaration::parse`] to judge. The code is
    /// what [`AiOutput::strip_code_fences`] makes of the rest.
    pub fn extract(raw: &str) -> AiCandidate {
        let declaration = fences(raw).into_iter().rfind(|fence| {
            let language = fence.language.to_lowercase();
            let body = super::trim(fence.body);
            (Self::DECLARATION_LANGUAGES.contains(&language.as_str()) || language.is_empty()) && body.starts_with('{') && crate::json::parse_object(body).is_ok() && !body.contains("$render")
        });
        match declaration {
            Some(fence) => {
                let remaining = format!("{}{}", &raw[..fence.start], &raw[fence.end..]);
                AiCandidate { source: Self::strip_code_fences(&remaining), manifest_json: Some(super::trim(fence.body).to_owned()) }
            }
            None => AiCandidate { source: Self::strip_code_fences(raw), manifest_json: None },
        }
    }

    /// Port of `PromptBuilder.stripCodeFences`: prefer the content of the first fenced block,
    /// then drop stray fence markers and surrounding whitespace.
    pub fn strip_code_fences(raw: &str) -> String {
        let trimmed = super::trim(raw);
        let mut text = extract_fenced_block(trimmed).unwrap_or(trimmed).to_owned();
        for marker in ["```jsx", "```javascript", "```js", "```"] {
            text = text.replace(marker, "");
        }
        super::trim(&text).to_owned()
    }
}

fn extract_fenced_block(raw: &str) -> Option<&str> {
    let open = raw.find("```")?;
    let after_open = &raw[open + 3..];
    // Skip the optional language tag on the same line.
    let after_newline = match after_open.find('\n') {
        Some(newline) => &after_open[newline + 1..],
        None => after_open,
    };
    let close = after_newline.find("```")?;
    Some(&after_newline[..close])
}

/// Outcome of compiling and running one candidate. `logs` are `"[level] message"` lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationResult {
    pub ok: bool,
    pub error_summary: Option<String>,
    pub logs: Vec<String>,
}

impl ValidationResult {
    const MAXIMUM_ERROR_CHARACTERS: usize = 2000;
    const SENTINELS: [&'static str; 3] = ["#UI Not Found#", "#Failed#", "#Loading#"];

    pub fn success(logs: Vec<String>) -> Self {
        Self { ok: true, error_summary: None, logs }
    }

    pub fn failure(error_summary: impl Into<String>, logs: Vec<String>) -> Self {
        Self { ok: false, error_summary: Some(error_summary.into()), logs }
    }

    /// Judges a runtime execution the way `AgentRunResult.didSucceed` does: an error, a missing
    /// tree, a fallback sentinel or an error-level log line all count as failure. The summary
    /// follows `ScriptWidgetError.summaryForPrompt` (`kind: message`).
    pub fn from_execution(tree: Option<&str>, error_kind: Option<&str>, error_message: Option<&str>, logs: Vec<String>) -> Self {
        const NO_ELEMENT: &str = "Runtime returned no element.";
        if let Some(kind) = error_kind {
            return Self::failure(format!("{kind}: {}", take(error_message.unwrap_or(""), Self::MAXIMUM_ERROR_CHARACTERS)), logs);
        }
        let Some(tree) = tree.filter(|tree| !tree.is_empty()) else { return Self::failure(NO_ELEMENT, logs) };
        match serde_json::from_str::<Value>(tree) {
            Ok(Value::Object(root)) => {
                if root.opt_string("$element").is_empty() {
                    return Self::failure(NO_ELEMENT, logs);
                }
                let sentinel = root.opt_array("children").is_some_and(|children| children.iter().any(|child| child.as_str().is_some_and(|text| Self::SENTINELS.contains(&text))));
                if sentinel {
                    return Self::failure("Runtime returned a fallback/placeholder element. The widget did not render real content.", logs);
                }
            }
            // A tree nested deeper than serde_json reads by default is still a tree the runtime
            // made: its depth is bounded by the runtime contract, and a sentinel is never nested.
            Err(error) if error.to_string().contains("recursion limit") && tree.starts_with("{\"$element\":\"") => {}
            _ => return Self::failure(NO_ELEMENT, logs),
        }
        if let Some(failing) = logs.iter().find(|line| line.starts_with("[error]") || line.to_lowercase().contains("uncaught")) {
            let summary = format!("The widget rendered but logged an error: {}", take(failing, Self::MAXIMUM_ERROR_CHARACTERS));
            return Self::failure(summary, logs);
        }
        Self::success(logs)
    }
}
