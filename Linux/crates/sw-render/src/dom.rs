//! The element tree the shared renderer records (see `serialize` in
//! `Android/core/src/main/js/render/entry.mjs`).

use std::collections::HashMap;

use serde_json::Value;
use sw_core::json::{Object, as_text};

/// One recorded element.
#[derive(Debug, Default)]
pub struct DomNode {
    pub tag: String,
    pub svg: bool,
    pub style: HashMap<String, String>,
    pub attributes: HashMap<String, String>,
    pub dataset: HashMap<String, String>,
    pub text: Option<String>,
    pub children: Vec<DomNode>,
}

impl DomNode {
    pub fn from_json(json: &Object) -> Result<Self, String> {
        Self::read(json, 0)
    }

    fn read(json: &Object, depth: usize) -> Result<Self, String> {
        // The layout nests a few dozen levels at most; a deeper tree is not one it wrote.
        if depth > MAXIMUM_DEPTH {
            return Err("The recorded element tree is nested too deeply".into());
        }
        let mut children = Vec::new();
        if let Some(Value::Array(items)) = json.get("c") {
            children.reserve(items.len());
            for item in items {
                let Value::Object(child) = item else { return Err("A recorded element is not an object".into()) };
                children.push(Self::read(child, depth + 1)?);
            }
        }
        Ok(Self {
            tag: json.get("t").and_then(as_text).unwrap_or_default(),
            svg: json.get("g").and_then(Value::as_i64) == Some(1),
            style: string_map(json.get("s")),
            attributes: string_map(json.get("a")),
            dataset: string_map(json.get("d")),
            text: json.get("x").map(|value| as_text(value).unwrap_or_default()),
            children,
        })
    }

    pub fn style(&self, name: &str) -> Option<&str> {
        self.style.get(name).map(String::as_str)
    }

    pub fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes.get(name).map(String::as_str)
    }

    pub fn data(&self, name: &str) -> Option<&str> {
        self.dataset.get(name).map(String::as_str)
    }
}

fn string_map(value: Option<&Value>) -> HashMap<String, String> {
    match value {
        Some(Value::Object(object)) => object.iter().map(|(key, value)| (key.clone(), as_text(value).unwrap_or_default())).collect(),
        _ => HashMap::new(),
    }
}

const MAXIMUM_DEPTH: usize = 512;
