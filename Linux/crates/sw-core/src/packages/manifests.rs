//! Minimal `widget.json` handling for the library: creating default manifests
//! and reading the display fields. Ported from `PackageManifests.cs`.
//!
//! Semantic validation (unknown keys, permissions, entry, versions) is the
//! shared manifest validator's job ([`crate::PackageCompiler::validate_manifest`])
//! and is not repeated here.

use std::fmt;

use serde::de::{Deserialize, Deserializer, Error as _, MapAccess, SeqAccess, Visitor};
use serde_json::{Number, Value, json};

use super::names;
use super::safe_files::unique_token;
use crate::json::Object;

pub const FILE_NAME: &str = "widget.json";
pub const LEGACY_ENTRY: &str = "main.jsx";
pub const LEGACY_METADATA: &str = "meta.json";

const DISCOVERY_KEYS: [&str; 4] = ["description", "category", "icon", "preview"];

/// Display fields of a manifest; each is `None` when absent or not a string.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Summary {
    pub id: Option<String>,
    pub name: Option<String>,
    pub version: Option<String>,
}

/// Parses manifest text as a JSON object, or returns `None`. A present
/// manifest that fails here is invalid, never legacy.
///
/// The reading is strict: no comments, no trailing commas, nothing after the
/// value, and an object that names a key twice is refused instead of letting
/// the later value silently win.
pub fn parse(text: Option<&str>) -> Option<Object> {
    match serde_json::from_str::<Strict>(text?) {
        Ok(Strict(Value::Object(manifest))) => Some(manifest),
        _ => None,
    }
}

pub fn summarize(manifest: &Object) -> Summary {
    Summary { id: string_value(manifest, "id"), name: string_value(manifest, "name"), version: string_value(manifest, "version") }
}

/// The member when it is a string; numbers and booleans are not converted.
pub fn string_value(manifest: &Object, key: &str) -> Option<String> {
    manifest.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// A fresh local identifier, as `WidgetPackageManifest.newProject` generates.
pub fn fresh_id() -> String {
    format!("local.{}", unique_token())
}

/// `WidgetPackageManifest.newProject` / `newManifest` in `manifest.js`.
pub fn new_manifest(name: &str) -> Object {
    let manifest = json!({
        "formatVersion": 2,
        "id": fresh_id(),
        "name": name,
        "version": "1.0.0",
        "runtimeVersion": "1.0",
        "entry": LEGACY_ENTRY,
        "supportedFamilies": ["systemSmall", "systemMedium", "systemLarge"],
        "permissions": [],
        "networkDomains": [],
        "plugins": [],
        "actions": [],
        "controls": [],
    });
    match manifest {
        Value::Object(manifest) => manifest,
        _ => Object::new(),
    }
}

/// `WidgetPackageManifest.legacy`: the manifest given to a package that has
/// `main.jsx` and no `widget.json`. Discovery fields are carried over from
/// `meta.json` when it is well formed; a malformed `meta.json` is ignored, as
/// in Swift.
pub fn legacy_manifest(name: &str, metadata_text: Option<&str>) -> Object {
    let mut manifest = new_manifest(name);
    manifest.insert("id".into(), Value::String(names::legacy_id(name)));
    let Some(metadata) = parse(metadata_text) else { return manifest };
    for key in DISCOVERY_KEYS {
        if let Some(text) = string_value(&metadata, key) {
            manifest.insert(key.into(), Value::String(text));
        }
    }
    if let Some(Value::Array(tags)) = metadata.get("tags")
        && tags.iter().all(Value::is_string)
    {
        manifest.insert("tags".into(), Value::Array(tags.clone()));
    }
    manifest
}

/// The manifest as indented UTF-8 JSON with LF line ends and a final newline.
pub fn encode(manifest: &Object) -> Vec<u8> {
    let mut text = serde_json::to_string_pretty(manifest).unwrap_or_else(|_| "{}".into());
    text.push('\n');
    text.into_bytes()
}

/// A JSON value read with duplicate object keys treated as an error.
struct Strict(Value);

impl<'de> Deserialize<'de> for Strict {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(StrictVisitor)
    }
}

struct StrictVisitor;

impl<'de> Visitor<'de> for StrictVisitor {
    type Value = Strict;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Strict, E> {
        Ok(Strict(Value::Bool(value)))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Strict, E> {
        Ok(Strict(Value::Number(value.into())))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Strict, E> {
        Ok(Strict(Value::Number(value.into())))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Strict, E> {
        Ok(Strict(Number::from_f64(value).map_or(Value::Null, Value::Number)))
    }

    fn visit_str<E>(self, value: &str) -> Result<Strict, E> {
        Ok(Strict(Value::String(value.to_owned())))
    }

    fn visit_string<E>(self, value: String) -> Result<Strict, E> {
        Ok(Strict(Value::String(value)))
    }

    fn visit_unit<E>(self) -> Result<Strict, E> {
        Ok(Strict(Value::Null))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Strict, A::Error> {
        let mut items = Vec::new();
        while let Some(Strict(item)) = sequence.next_element()? {
            items.push(item);
        }
        Ok(Strict(Value::Array(items)))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Strict, A::Error> {
        let mut object = Object::new();
        while let Some(key) = map.next_key::<String>()? {
            let Strict(value) = map.next_value()?;
            if object.insert(key.clone(), value).is_some() {
                return Err(A::Error::custom(format!("duplicate key {key:?}")));
            }
        }
        Ok(Strict(Value::Object(object)))
    }
}
