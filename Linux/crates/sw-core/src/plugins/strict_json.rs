//! RFC 8259 JSON reader and writer for untrusted plugin manifests and data
//! source responses. Ported from
//! `Windows/src/ScriptWidget.Core/Plugins/StrictJson.cs`.
//!
//! Lenient readers accept unquoted strings, single quotes, comments and
//! trailing text, and platforms disagree on number types and duplicate keys.
//! A manifest that one platform reads and another refuses is not a contract,
//! so manifests are parsed here: exactly one JSON value, nothing after it, no
//! raw control characters, bounded nesting.

use std::collections::HashSet;
use std::fmt;

use serde_json::{Map, Number, Value};

/// Deepest container nesting accepted; `JSONSerialization` on Apple platforms stops at 512 as well.
pub const MAXIMUM_DEPTH: usize = 512;

/// What a document's top-level value is, for callers that only validate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Object,
    Array,
    String,
    Number,
    Boolean,
    Null,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonError(pub String);

impl fmt::Display for JsonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for JsonError {}

/// Parses `text`. Whole numbers that fit 64 bits stay integers; every other
/// number is a double.
///
/// A repeated object key is rejected unless `allow_duplicate_keys`: two
/// values for one key let a validator and a later reader disagree about what
/// the document says.
pub fn parse(text: &str, allow_duplicate_keys: bool) -> Result<Value, JsonError> {
    let mut reader = Reader { text: text.as_bytes(), index: 0, build: true, allow_duplicate_keys };
    reader.document().map(|(_, value)| value)
}

/// Checks that `text` is one well-formed JSON value without building it, and returns its kind.
pub fn validate(text: &str) -> Result<Kind, JsonError> {
    let mut reader = Reader { text: text.as_bytes(), index: 0, build: false, allow_duplicate_keys: true };
    reader.document().map(|(kind, _)| kind)
}

/// JSON string literal for `value`. Slashes are not escaped, like `.withoutEscapingSlashes` in Swift.
pub fn quote(value: &str) -> String {
    let mut output = String::with_capacity(value.len() + 2);
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            '\u{8}' => output.push_str("\\b"),
            '\u{c}' => output.push_str("\\f"),
            // Line and paragraph separators are escaped so the text is also a JavaScript literal.
            character if character < ' ' || character == '\u{2028}' || character == '\u{2029}' => output.push_str(&format!("\\u{:04x}", character as u32)),
            character => output.push(character),
        }
    }
    output.push('"');
    output
}

struct Reader<'a> {
    text: &'a [u8],
    index: usize,
    build: bool,
    allow_duplicate_keys: bool,
}

impl Reader<'_> {
    fn document(&mut self) -> Result<(Kind, Value), JsonError> {
        self.skip_whitespace();
        let kind = match self.peek() {
            b'{' => Kind::Object,
            b'[' => Kind::Array,
            b'"' => Kind::String,
            b't' | b'f' => Kind::Boolean,
            b'n' => Kind::Null,
            _ => Kind::Number,
        };
        let result = self.value(0)?;
        self.skip_whitespace();
        if self.index != self.text.len() {
            return Err(self.fail("Unexpected text after the JSON value"));
        }
        Ok((kind, result))
    }

    fn value(&mut self, depth: usize) -> Result<Value, JsonError> {
        if depth > MAXIMUM_DEPTH {
            return Err(self.fail("JSON is nested too deeply"));
        }
        match self.peek() {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => self.string().map(Value::String),
            b't' => self.literal("true", Value::Bool(true)),
            b'f' => self.literal("false", Value::Bool(false)),
            b'n' => self.literal("null", Value::Null),
            _ => self.number(),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, JsonError> {
        self.index += 1;
        let mut result = Map::new();
        let mut seen: Option<HashSet<String>> = if self.allow_duplicate_keys { None } else { Some(HashSet::new()) };
        self.skip_whitespace();
        if self.peek() == b'}' {
            self.index += 1;
            return Ok(Value::Object(result));
        }
        loop {
            self.skip_whitespace();
            if self.peek() != b'"' {
                return Err(self.fail("Expected an object key"));
            }
            let key = self.string()?;
            if let Some(seen) = seen.as_mut()
                && !seen.insert(key.clone())
            {
                return Err(self.fail("Duplicate object key"));
            }
            self.skip_whitespace();
            if self.peek() != b':' {
                return Err(self.fail("Expected ':' after an object key"));
            }
            self.index += 1;
            self.skip_whitespace();
            let member = self.value(depth + 1)?;
            if self.build {
                result.insert(key, member);
            }
            self.skip_whitespace();
            match self.peek() {
                b',' => self.index += 1,
                b'}' => {
                    self.index += 1;
                    return Ok(Value::Object(result));
                }
                _ => return Err(self.fail("Expected ',' or '}' in an object")),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value, JsonError> {
        self.index += 1;
        let mut result = Vec::new();
        self.skip_whitespace();
        if self.peek() == b']' {
            self.index += 1;
            return Ok(Value::Array(result));
        }
        loop {
            self.skip_whitespace();
            let member = self.value(depth + 1)?;
            if self.build {
                result.push(member);
            }
            self.skip_whitespace();
            match self.peek() {
                b',' => self.index += 1,
                b']' => {
                    self.index += 1;
                    return Ok(Value::Array(result));
                }
                _ => return Err(self.fail("Expected ',' or ']' in an array")),
            }
        }
    }

    fn string(&mut self) -> Result<String, JsonError> {
        self.index += 1;
        let mut output: Vec<u8> = Vec::new();
        // A high surrogate escape waiting for its low half.
        let mut pending: Option<u32> = None;
        let flush = |pending: &mut Option<u32>, output: &mut Vec<u8>| {
            if pending.take().is_some() {
                // A lone surrogate cannot be text; the Windows port keeps the UTF-16 unit, which no reader can use either.
                output.extend_from_slice("\u{fffd}".as_bytes());
            }
        };
        loop {
            let Some(&byte) = self.text.get(self.index) else { return Err(self.fail("Unterminated string")) };
            self.index += 1;
            if byte == b'"' {
                flush(&mut pending, &mut output);
                // The input is a `str` and every escape appends whole characters, so this is UTF-8.
                return String::from_utf8(output).map_err(|_| self.fail("Invalid text"));
            }
            if byte < b' ' {
                return Err(self.fail("Control character in a string"));
            }
            if byte != b'\\' {
                flush(&mut pending, &mut output);
                output.push(byte);
                continue;
            }
            let Some(&escape) = self.text.get(self.index) else { return Err(self.fail("Unterminated escape")) };
            self.index += 1;
            if escape != b'u' {
                flush(&mut pending, &mut output);
            }
            match escape {
                b'"' | b'\\' | b'/' => output.push(escape),
                b'b' => output.push(8),
                b'f' => output.push(12),
                b'n' => output.push(b'\n'),
                b'r' => output.push(b'\r'),
                b't' => output.push(b'\t'),
                b'u' => {
                    let mut code = 0u32;
                    for _ in 0..4 {
                        let digit = self.hex_digit()?;
                        code = code * 16 + digit;
                    }
                    match (pending.take(), code) {
                        (Some(high), 0xDC00..=0xDFFF) => {
                            let scalar = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00);
                            push_character(&mut output, char::from_u32(scalar).unwrap_or('\u{fffd}'));
                        }
                        (previous, _) => {
                            if previous.is_some() {
                                output.extend_from_slice("\u{fffd}".as_bytes());
                            }
                            match code {
                                0xD800..=0xDBFF => pending = Some(code),
                                _ => push_character(&mut output, char::from_u32(code).unwrap_or('\u{fffd}')),
                            }
                        }
                    }
                }
                _ => return Err(self.fail("Invalid escape")),
            }
        }
    }

    /// One digit of a `\u` escape. Besides ASCII this accepts the full-width
    /// digits and the full-width Latin letters A to F, which
    /// `Character.digit(c, 16)` of the Android implementation accepts too.
    fn hex_digit(&mut self) -> Result<u32, JsonError> {
        let rest = self.text.get(self.index..).unwrap_or(&[]);
        let character = std::str::from_utf8(&rest[..rest.len().min(4)]).or_else(|error| std::str::from_utf8(&rest[..error.valid_up_to()])).ok().and_then(|text| text.chars().next());
        let Some(character) = character else { return Err(self.fail("Truncated unicode escape")) };
        let digit = match character {
            '0'..='9' | 'a'..='f' | 'A'..='F' => character.to_digit(16),
            '\u{ff10}'..='\u{ff19}' => Some(character as u32 - 0xFF10),
            '\u{ff21}'..='\u{ff26}' => Some(character as u32 - 0xFF21 + 10),
            '\u{ff41}'..='\u{ff46}' => Some(character as u32 - 0xFF41 + 10),
            _ => None,
        };
        let digit = digit.ok_or_else(|| self.fail("Invalid unicode escape"))?;
        self.index += character.len_utf8();
        Ok(digit)
    }

    fn number(&mut self) -> Result<Value, JsonError> {
        let start = self.index;
        if self.peek() == b'-' {
            self.index += 1;
        }
        match self.peek() {
            b'0' => self.index += 1,
            b'1'..=b'9' => self.digits()?,
            _ => return Err(self.fail("Unexpected character")),
        }
        let mut integral = true;
        if self.peek() == b'.' {
            integral = false;
            self.index += 1;
            self.digits()?;
        }
        if matches!(self.peek(), b'e' | b'E') {
            integral = false;
            self.index += 1;
            if matches!(self.peek(), b'+' | b'-') {
                self.index += 1;
            }
            self.digits()?;
        }
        if !self.build {
            return Ok(Value::Null);
        }
        let literal = std::str::from_utf8(&self.text[start..self.index]).map_err(|_| self.fail("Unexpected character"))?;
        if integral && let Ok(whole) = literal.parse::<i64>() {
            return Ok(Value::Number(Number::from(whole)));
        }
        // A number too large for a double has no value a manifest could mean.
        literal.parse::<f64>().ok().and_then(Number::from_f64).map(Value::Number).ok_or_else(|| self.fail("Number is out of range"))
    }

    fn digits(&mut self) -> Result<(), JsonError> {
        let start = self.index;
        while self.peek().is_ascii_digit() {
            self.index += 1;
        }
        if self.index == start { Err(self.fail("Expected a digit")) } else { Ok(()) }
    }

    fn literal(&mut self, word: &str, value: Value) -> Result<Value, JsonError> {
        if !self.text[self.index..].starts_with(word.as_bytes()) {
            return Err(self.fail("Unexpected character"));
        }
        self.index += word.len();
        Ok(value)
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.text.get(self.index), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.index += 1;
        }
    }

    /// The current byte, or NUL at the end (NUL is never valid outside a string).
    fn peek(&self) -> u8 {
        self.text.get(self.index).copied().unwrap_or(0)
    }

    fn fail(&self, message: &str) -> JsonError {
        JsonError(format!("{message} at offset {}", self.index))
    }
}

fn push_character(output: &mut Vec<u8>, character: char) {
    output.extend_from_slice(character.encode_utf8(&mut [0; 4]).as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn accepts_only_the_standard_grammar() {
        let parsed = parse(" {\"a\": [1, 2.5, true, null, \"x\\n\\u00e9\"]} ", false).unwrap();
        assert_eq!(parsed, json!({ "a": [1, 2.5, true, null, "x\né"] }));
        assert!(parsed["a"][0].is_i64() && parsed["a"][1].is_f64());
        let deep = format!("{}{}", "[".repeat(600), "]".repeat(600));
        for text in ["01", "1.", ".5", "+1", "[1,]", "{\"a\":1,}", "\"a\tb\"", "nul", "NaN", "\"\\x41\"", deep.as_str(), "", "{", "1 2", "{'a':1}", "{a:1}", "[1 // c\n]", "\"\\u12\"", "\"\\u12G4\"", "1e999"] {
            assert!(parse(text, false).is_err(), "{text}");
        }
        assert!(parse(&format!("{}{}", "[".repeat(512), "]".repeat(512)), false).is_ok());
        assert_eq!(quote("a\"b\\c/d\n\u{1}"), "\"a\\\"b\\\\c/d\\n\\u0001\"");
        assert_eq!(quote("\u{2028}\u{2029}"), "\"\\u2028\\u2029\"");
    }

    #[test]
    fn duplicate_keys_are_an_error_unless_allowed() {
        assert!(parse("{\"a\":1,\"a\":2}", false).is_err());
        assert_eq!(parse("{\"a\":1,\"a\":2}", true).unwrap(), json!({ "a": 2 }));
        assert!(parse("{\"a\":{\"b\":1},\"c\":{\"b\":2}}", false).is_ok());
        assert_eq!(validate("{\"a\":1,\"a\":2}"), Ok(Kind::Object));
    }

    #[test]
    fn numbers_keep_their_kind_and_escapes_become_text() {
        assert_eq!(parse("9223372036854775807", false).unwrap(), json!(9223372036854775807i64));
        assert!(parse("9223372036854775808", false).unwrap().is_f64());
        assert!(parse("1.0", false).unwrap().is_f64());
        assert_eq!(parse("-0", false).unwrap(), json!(0));
        assert_eq!(parse("\"\\ud83c\\udf27 \\uFF14\\uff11\"", false).unwrap(), json!("🌧 \u{ff14}\u{ff11}"));
        // Full-width digits are digits of an escape, as on Android and Windows.
        assert_eq!(parse("\"\\u００４１\"", false).unwrap(), json!("A"));
        assert_eq!(parse("\"\\ud83c x \\udf27\"", false).unwrap(), json!("\u{fffd} x \u{fffd}"));
    }

    #[test]
    fn validation_reports_the_kind_without_building() {
        for (text, kind) in [("{}", Kind::Object), (" [1] ", Kind::Array), ("\"x\"", Kind::String), ("-1.5e3", Kind::Number), ("true", Kind::Boolean), ("false", Kind::Boolean), ("null", Kind::Null), ("1e999", Kind::Number)] {
            assert_eq!(validate(text), Ok(kind), "{text}");
        }
        for text in ["", "{} x", "<html>", "{\"a\":}", "tru"] {
            assert!(validate(text).is_err(), "{text}");
        }
    }
}
