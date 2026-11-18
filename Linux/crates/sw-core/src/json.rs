//! Lenient accessors over `serde_json`, with the behavior of org.json that
//! the Android original and the Windows port rely on. Objects keep insertion
//! order (`preserve_order`).

use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

/// Parses a JSON object; anything else is an error.
pub fn parse_object(text: &str) -> Result<Object, String> {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(object)) => Ok(object),
        Ok(_) => Err("Expected a JSON object".into()),
        Err(error) => Err(format!("Invalid JSON: {error}")),
    }
}

pub fn stringify(value: &Value) -> String {
    // Serializing a `Value` cannot fail: its keys are strings and its numbers are finite.
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

pub fn stringify_object(object: &Object) -> String {
    serde_json::to_string(object).unwrap_or_else(|_| "{}".into())
}

/// A JSON string literal, quotes included.
pub fn quote(text: &str) -> String {
    stringify(&Value::String(text.to_owned()))
}

/// Text of a scalar; `None` for null, objects and arrays. Numbers and booleans are converted.
pub fn as_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Bool(flag) => Some(if *flag { "true" } else { "false" }.into()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

pub fn as_f64(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

/// The lenient accessors, on an object.
pub trait ObjectExt {
    fn has(&self, name: &str) -> bool;
    /// True when the member is missing or null.
    fn is_null(&self, name: &str) -> bool;
    fn opt_object(&self, name: &str) -> Option<&Object>;
    fn opt_array(&self, name: &str) -> Option<&Vec<Value>>;
    /// The member as text, or "" when it is missing, null, an object or an array.
    fn opt_string(&self, name: &str) -> String;
    fn opt_string_or_none(&self, name: &str) -> Option<String>;
    fn opt_bool(&self, name: &str, fallback: bool) -> bool;
    /// The member as a number, or NaN.
    fn opt_f64(&self, name: &str) -> f64;
    fn opt_i32(&self, name: &str, fallback: i32) -> i32;
}

impl ObjectExt for Object {
    fn has(&self, name: &str) -> bool {
        self.contains_key(name)
    }

    fn is_null(&self, name: &str) -> bool {
        matches!(self.get(name), None | Some(Value::Null))
    }

    fn opt_object(&self, name: &str) -> Option<&Object> {
        self.get(name).and_then(Value::as_object)
    }

    fn opt_array(&self, name: &str) -> Option<&Vec<Value>> {
        self.get(name).and_then(Value::as_array)
    }

    fn opt_string(&self, name: &str) -> String {
        self.opt_string_or_none(name).unwrap_or_default()
    }

    fn opt_string_or_none(&self, name: &str) -> Option<String> {
        self.get(name).and_then(as_text)
    }

    fn opt_bool(&self, name: &str, fallback: bool) -> bool {
        match self.get(name) {
            Some(Value::Bool(flag)) => *flag,
            Some(Value::String(text)) if text.eq_ignore_ascii_case("true") => true,
            Some(Value::String(text)) if text.eq_ignore_ascii_case("false") => false,
            _ => fallback,
        }
    }

    fn opt_f64(&self, name: &str) -> f64 {
        self.get(name).and_then(as_f64).unwrap_or(f64::NAN)
    }

    fn opt_i32(&self, name: &str, fallback: i32) -> i32 {
        let number = self.opt_f64(name);
        // A float-to-integer cast saturates at the bounds.
        if number.is_nan() { fallback } else { number as i32 }
    }
}
