//! JSON, text and file helpers shared by the Gallery and Skills layers
//! (`GalleryFiles` in Kotlin, and the rules both validators have in common).

use std::collections::HashSet;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;

use serde_json::Value;

use crate::json::Object;
use crate::packages::safe_files;
use crate::plugins::strict_json;

/// Parses `text` as exactly one JSON object with the strict reader: anything
/// else, trailing content after the object, a repeated key or JSON that only
/// a lenient reader accepts yields `None`, so a manifest cannot smuggle a
/// second document or mean two things to two readers.
pub(crate) fn parse_object(text: &str) -> Option<Object> {
    match strict_json::parse(text, false) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

/// A JSON integer; fractions, strings and booleans are not coerced.
pub(crate) fn integer(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) if number.is_i64() || number.is_u64() => number.as_i64(),
        _ => None,
    }
}

/// `^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$`: the identifier of a Skill or a Gallery item.
pub(crate) fn is_identifier(text: &str) -> bool {
    let bytes = text.as_bytes();
    (3..=128).contains(&bytes.len()) && bytes[0].is_ascii_alphanumeric() && bytes.iter().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
}

/// `^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$`.
pub(crate) fn is_semantic_version(text: &str) -> bool {
    let (numbers, suffix) = match text.split_once('-') {
        Some((numbers, suffix)) => (numbers, Some(suffix)),
        None => (text, None),
    };
    let parts: Vec<&str> = numbers.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        && suffix.is_none_or(|suffix| !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-')))
}

/// Not blank and at most `maximum` characters.
pub(crate) fn bounded(text: &str, maximum: usize) -> bool {
    !text.trim().is_empty() && text.chars().count() <= maximum
}

/// True when no two values are equal ignoring case.
pub(crate) fn unique_ignoring_case<'a>(values: impl Iterator<Item = &'a str>) -> bool {
    let mut seen = HashSet::new();
    values.into_iter().all(|value| seen.insert(value.to_lowercase()))
}

/// The bytes of the regular, singly linked file `name` directly in
/// `directory`, or `None` when it is missing, a link, has an alias in another
/// case, or holds more than `maximum_bytes`.
pub(crate) fn read_private(directory: &Path, name: &str, maximum_bytes: usize) -> Option<Vec<u8>> {
    safe_files::read_bounded(safe_files::existing_file(directory, &[name])?, maximum_bytes as u64)
}

/// Replaces `target` with `bytes` through a flushed temporary file and one
/// atomic rename. The file is private to the user; its directory is created
/// when it does not exist and must not be a link.
pub(crate) fn write_atomically(target: &Path, bytes: &[u8]) -> io::Result<()> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "Not a file path");
    let directory = target.parent().ok_or_else(invalid)?;
    let name = target.file_name().and_then(|name| name.to_str()).ok_or_else(invalid)?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
    let opened = safe_files::open_directory(directory)?;
    let temporary = format!(".{name}.{}.tmp", safe_files::unique_token());
    let written = safe_files::write_new_at(&opened, &temporary, bytes).and_then(|()| std::fs::rename(safe_files::child(directory, &temporary), target));
    if written.is_err() {
        let _ = std::fs::remove_file(safe_files::child(directory, &temporary));
    }
    written
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_and_versions_follow_the_schema_patterns() {
        for id in ["abc", "com.example.weather", "a-b.c", "A1b", &"a".repeat(128)] {
            assert!(is_identifier(id), "{id}");
        }
        for id in ["", "ab", "-abc", ".abc", "com.example/x", "com example", &"a".repeat(129), "com.ex\u{e4}mple"] {
            assert!(!is_identifier(id), "{id}");
        }
        for version in ["1.0.0", "10.20.30", "1.0.0-beta.1", "1.0.0-rc-1"] {
            assert!(is_semantic_version(version), "{version}");
        }
        for version in ["latest", "1.0", "1", "v1.0.0", "1.0.0+build", "1.0.0-", "1.0.0 ", "", "1..0", "1.0.0.0"] {
            assert!(!is_semantic_version(version), "{version}");
        }
    }

    #[test]
    fn one_object_and_nothing_else() {
        assert!(parse_object("{\"a\":1}").is_some());
        for text in ["", "[]", "null", "{\"a\":1}{}", "{\"a\":1} x", "{a:1}", "{\"a\":1,\"a\":2}", "{'a':1}"] {
            assert!(parse_object(text).is_none(), "{text}");
        }
        assert_eq!(integer(&serde_json::json!(7)), Some(7));
        for value in [serde_json::json!(1.5), serde_json::json!("1"), serde_json::json!(true), serde_json::json!(null)] {
            assert_eq!(integer(&value), None, "{value}");
        }
    }
}
