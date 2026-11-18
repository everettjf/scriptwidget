//! The `actions` and `controls` a package manifest declares, read with the
//! limits of the shared manifest validator. Ported from
//! `Windows/src/ScriptWidget.Core/Surfaces/SurfaceManifest.cs`.
//!
//! A tap can select a declared action; it can never name an arbitrary
//! function. Anything malformed is an error: the service never runs code
//! from a manifest it does not fully accept.

use serde_json::{Map, Value};
use sw_core::packages::names::grapheme_count;

pub const MAXIMUM_ACTIONS: usize = 16;
pub const MAXIMUM_CONTROLS: usize = 8;

/// One entry of `actions`: a JavaScript function the system may run by its identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeclaredAction {
    pub id: String,
    pub function: String,
}

/// The validated `actions` of one manifest, and whether it may use storage.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PackageSurfaces {
    pub actions: Vec<DeclaredAction>,
    pub has_storage_permission: bool,
}

impl PackageSurfaces {
    /// The declared action with this identifier, compared without regard to case as on iOS.
    pub fn action(&self, id: &str) -> Option<&DeclaredAction> {
        let mut matches = self.actions.iter().filter(|action| action.id.eq_ignore_ascii_case(id));
        match (matches.next(), matches.next()) {
            (Some(action), None) if !id.is_empty() => Some(action),
            _ => None,
        }
    }
}

/// The code of the shared validator's issue for what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SurfaceError(pub String);

fn matches(text: &str, first: impl Fn(u8) -> bool, rest: impl Fn(u8) -> bool, maximum: usize) -> bool {
    let bytes = text.as_bytes();
    !bytes.is_empty() && bytes.len() <= maximum && first(bytes[0]) && bytes[1..].iter().all(|byte| rest(*byte))
}

/// `^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$`
fn is_short_id(text: &str) -> bool {
    matches(text, |byte| byte.is_ascii_alphanumeric(), |byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-', 64)
}

/// `^[A-Za-z0-9][A-Za-z0-9.-]{0,79}$`
fn is_symbol(text: &str) -> bool {
    matches(text, |byte| byte.is_ascii_alphanumeric(), |byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-', 80)
}

/// True when `name` is a JavaScript function identifier a manifest or a control may name: `^[A-Za-z_$][A-Za-z0-9_$]{0,63}$`.
pub fn is_valid_function(name: &str) -> bool {
    matches(name, |byte| byte.is_ascii_alphabetic() || byte == b'_' || byte == b'$', |byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$', 64)
}

/// True when `key` may hold a toggle's state in package storage: `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
pub fn is_valid_state_key(key: &str) -> bool {
    matches(key, |byte| byte.is_ascii_alphanumeric(), |byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'), 128)
}

fn fail<T>(code: &str) -> Result<T, SurfaceError> {
    Err(SurfaceError(code.to_owned()))
}

/// The objects of an optional array member; unknown keys and other shapes are refused.
fn objects<'a>(manifest: &'a Map<String, Value>, field: &str, allowed: &[&str]) -> Result<Vec<&'a Map<String, Value>>, SurfaceError> {
    match manifest.get(field) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| match item {
                Value::Object(object) if object.keys().all(|key| allowed.contains(&key.as_str())) => Ok(object),
                Value::Object(_) => fail(&format!("unknown_{field}_fields")),
                _ => fail(&format!("malformed_{field}")),
            })
            .collect(),
        Some(_) => fail(&format!("malformed_{field}")),
    }
}

fn required<'a>(item: &'a Map<String, Value>, key: &str, field: &str) -> Result<&'a str, SurfaceError> {
    item.get(key).and_then(Value::as_str).ok_or_else(|| SurfaceError(format!("malformed_{field}")))
}

fn optional<'a>(item: &'a Map<String, Value>, key: &str, field: &str) -> Result<Option<&'a str>, SurfaceError> {
    match item.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => fail(&format!("malformed_{field}")),
    }
}

fn unique(ids: &[&str]) -> bool {
    let mut lowered: Vec<String> = ids.iter().map(|id| id.to_ascii_lowercase()).collect();
    lowered.sort();
    lowered.windows(2).all(|pair| pair[0] != pair[1])
}

/// Validates and returns the declared surfaces. No manifest (a legacy package) declares none.
pub fn parse(manifest: Option<&Map<String, Value>>) -> Result<PackageSurfaces, SurfaceError> {
    let Some(manifest) = manifest else { return Ok(PackageSurfaces::default()) };
    let storage = manifest.get("permissions").and_then(Value::as_array).is_some_and(|items| items.iter().any(|item| item.as_str() == Some("storage")));

    let items = objects(manifest, "actions", &["id", "title", "description", "systemImage", "function"])?;
    if items.len() > MAXIMUM_ACTIONS {
        return fail("too_many_actions");
    }
    let mut actions = Vec::new();
    for item in items {
        let id = required(item, "id", "actions")?;
        if !is_short_id(id) {
            return fail("invalid_action_id");
        }
        let title = required(item, "title", "actions")?;
        if title.trim().is_empty() || grapheme_count(title) > 40 {
            return fail("invalid_action_title");
        }
        if optional(item, "description", "actions")?.is_some_and(|description| grapheme_count(description) > 160) {
            return fail("invalid_action_description");
        }
        if !is_symbol(required(item, "systemImage", "actions")?) {
            return fail("invalid_action_image");
        }
        let function = required(item, "function", "actions")?;
        if !is_valid_function(function) {
            return fail("invalid_action_function");
        }
        actions.push(DeclaredAction { id: id.to_owned(), function: function.to_owned() });
    }
    if !unique(&actions.iter().map(|action| action.id.as_str()).collect::<Vec<_>>()) {
        return fail("duplicate_actions");
    }

    // Linux shows no controls, but a manifest whose controls are malformed is not accepted in part.
    let items = objects(manifest, "controls", &["id", "type", "title", "subtitle", "systemImage", "action", "actionID", "stateKey"])?;
    if items.len() > MAXIMUM_CONTROLS {
        return fail("too_many_controls");
    }
    let mut control_ids = Vec::new();
    for item in items {
        let id = required(item, "id", "controls")?;
        if !is_short_id(id) {
            return fail("invalid_control_id");
        }
        let kind = required(item, "type", "controls")?;
        if kind != "button" && kind != "toggle" {
            return fail("malformed_controls");
        }
        let title = required(item, "title", "controls")?;
        if title.trim().is_empty() || grapheme_count(title) > 40 {
            return fail("invalid_control_title");
        }
        if optional(item, "subtitle", "controls")?.is_some_and(|subtitle| grapheme_count(subtitle) > 80) {
            return fail("invalid_control_subtitle");
        }
        if !is_symbol(required(item, "systemImage", "controls")?) {
            return fail("invalid_control_image");
        }
        match (optional(item, "action", "controls")?, optional(item, "actionID", "controls")?) {
            (Some(_), Some(_)) => return fail("ambiguous_control_action"),
            (Some(legacy), None) if !is_valid_function(legacy) => return fail("invalid_control_action"),
            (Some(_), None) => {}
            (None, Some(action)) if !actions.iter().any(|declared| declared.id.eq_ignore_ascii_case(action)) => return fail("missing_control_action"),
            (None, Some(_)) => {}
            (None, None) => return fail("missing_control_action"),
        }
        let key = optional(item, "stateKey", "controls")?;
        if kind == "toggle" {
            if !key.is_some_and(is_valid_state_key) {
                return fail("invalid_control_state");
            }
            if !storage {
                return fail("control_storage");
            }
        } else if key.is_some() {
            return fail("button_control_state");
        }
        control_ids.push(id);
    }
    if !unique(&control_ids) {
        return fail("duplicate_controls");
    }
    Ok(PackageSurfaces { actions, has_storage_permission: storage })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(text: &str) -> Map<String, Value> {
        serde_json::from_str(text).unwrap()
    }

    fn code(text: &str) -> String {
        parse(Some(&manifest(text))).expect_err(text).0
    }

    const ACTION: &str = r#"{"id":"count.up","title":"Count","systemImage":"plus.circle","function":"countUp"}"#;

    #[test]
    fn reads_declared_actions() {
        let surfaces = parse(Some(&manifest(&format!(r#"{{"permissions":["storage"],"actions":[{ACTION}]}}"#)))).unwrap();
        assert!(surfaces.has_storage_permission);
        assert_eq!(surfaces.action("COUNT.UP").map(|action| action.function.as_str()), Some("countUp"));
        assert_eq!(surfaces.action("other"), None);
        assert_eq!(surfaces.action(""), None);
        assert_eq!(parse(None).unwrap(), PackageSurfaces::default());
        assert_eq!(parse(Some(&manifest("{}"))).unwrap(), PackageSurfaces::default());
    }

    #[test]
    fn a_malformed_declaration_refuses_the_whole_manifest() {
        assert_eq!(code(r#"{"actions":{}}"#), "malformed_actions");
        assert_eq!(code(r#"{"actions":["x"]}"#), "malformed_actions");
        assert_eq!(code(r#"{"actions":[{"id":"a","title":"A","systemImage":"x","function":"f","extra":1}]}"#), "unknown_actions_fields");
        assert_eq!(code(r#"{"actions":[{"id":"-a","title":"A","systemImage":"x","function":"f"}]}"#), "invalid_action_id");
        assert_eq!(code(r#"{"actions":[{"id":"a","title":" ","systemImage":"x","function":"f"}]}"#), "invalid_action_title");
        assert_eq!(code(r#"{"actions":[{"id":"a","title":"A","systemImage":"x y","function":"f"}]}"#), "invalid_action_image");
        assert_eq!(code(r#"{"actions":[{"id":"a","title":"A","systemImage":"x","function":"f()"}]}"#), "invalid_action_function");
        assert_eq!(code(r#"{"actions":[{"id":"a","title":"A","systemImage":"x","function":"a.b"}]}"#), "invalid_action_function");
        assert_eq!(code(r#"{"actions":[{"id":"a","title":"A","systemImage":"x"}]}"#), "malformed_actions");
        assert_eq!(code(&format!(r#"{{"actions":[{ACTION},{}]}}"#, ACTION.replace("count.up", "Count.Up"))), "duplicate_actions");
        let many = vec![ACTION; 17].iter().enumerate().map(|(index, action)| action.replace("count.up", &format!("a{index}"))).collect::<Vec<_>>().join(",");
        assert_eq!(code(&format!(r#"{{"actions":[{many}]}}"#)), "too_many_actions");
        // Controls are not shown on Linux, but they are part of what is accepted.
        assert_eq!(code(&format!(r#"{{"actions":[{ACTION}],"controls":[{{"id":"c","type":"toggle","title":"T","systemImage":"x","actionID":"count.up","stateKey":"k"}}]}}"#)), "control_storage");
        assert_eq!(code(r#"{"controls":[{"id":"c","type":"button","title":"T","systemImage":"x","actionID":"nothing"}]}"#), "missing_control_action");
        assert_eq!(code(r#"{"controls":[{"id":"c","type":"slider","title":"T","systemImage":"x","action":"f"}]}"#), "malformed_controls");
        assert!(parse(Some(&manifest(&format!(r#"{{"permissions":["storage"],"actions":[{ACTION}],"controls":[{{"id":"c","type":"toggle","title":"T","systemImage":"x","actionID":"count.up","stateKey":"k"}}]}}"#)))).is_ok());
    }

    #[test]
    fn function_names_and_state_keys() {
        for name in ["f", "_private", "$x", "countUp2"] {
            assert!(is_valid_function(name), "{name}");
        }
        for name in ["", "2x", "a.b", "a b", "f()", "eval('x')", &"a".repeat(65)] {
            assert!(!is_valid_function(name), "{name}");
        }
        for key in ["k", "lights.on", "a_b-c"] {
            assert!(is_valid_state_key(key), "{key}");
        }
        for key in ["", ".k", "a/b", "a b", &"k".repeat(129)] {
            assert!(!is_valid_state_key(key), "{key}");
        }
    }
}
