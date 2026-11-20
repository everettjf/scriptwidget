//! Strict decoder and validator of the Gallery 1.0 index. A port of
//! `GalleryIndexValidator.kt` (`GalleryIndexValidator` in Swift, tightened to
//! the bounds of `Gallery/gallery.schema.json`).
//!
//! The index is untrusted input. It is refused as a whole when any rule
//! fails; there is no partial acceptance and no best-effort repair.

use serde_json::Value;

use super::files;
use super::{GalleryError, GalleryErrorKind, GalleryFile, GalleryIndex, GalleryItem, GalleryItemKind, GalleryValidationIssue};
use crate::api::support::iso_dates;
use crate::json::Object;
use crate::packages::{limits, names};

/// `maximumIndexBytes`: a larger index is refused before it is parsed.
pub const MAX_INDEX_BYTES: usize = 1024 * 1024;
/// `maximumItems`.
pub const MAX_ITEMS: usize = 500;
/// `maximumWidgetBytes`: declared total of one widget item.
pub const MAX_WIDGET_BYTES: i64 = 32 * 1024 * 1024;
/// `maximumSkillBytes`: declared total of one Skill item.
pub const MAX_SKILL_BYTES: i64 = 256 * 1024;
/// `maximumFiles`: files of one item.
pub const MAX_FILES: usize = 500;
/// `ScriptPackageArchivePolicy.maximumFileBytes`: declared size of one file.
pub const MAX_FILE_BYTES: i64 = limits::MAX_FILE_BYTES as i64;
/// Longest file path, in characters.
pub const MAX_PATH_LENGTH: usize = 512;
/// Deepest file path.
pub const MAX_PATH_DEPTH: usize = 16;
pub const MAX_NAME_LENGTH: usize = 80;
pub const MAX_SUMMARY_LENGTH: usize = 240;
pub const MAX_TAGS: usize = 20;
/// Schema bounds that the Swift validator leaves to the JSON Schema.
pub const MAX_SYMBOL_LENGTH: usize = 80;
pub const MAX_AUTHOR_LENGTH: usize = 120;
pub const MAX_LICENSE_LENGTH: usize = 40;

/// The one host the index and every file come from.
pub const RAW_HOST: &str = "raw.githubusercontent.com";
const GITHUB_HOST: &str = "github.com";
const ROOT_KEYS: [&str; 4] = ["schemaVersion", "generatedAt", "repository", "items"];
const ITEM_KEYS: [&str; 13] = ["id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags", "minimumRuntimeVersion", "sourceURL", "featured", "files"];
const FILE_KEYS: [&str; 4] = ["path", "url", "sha256", "bytes"];

fn invalid(message: impl Into<String>) -> GalleryError {
    GalleryError::new(GalleryErrorKind::InvalidIndex, message)
}

fn only_known_keys(json: &Object, known: &[&str]) -> bool {
    json.keys().all(|key| known.contains(&key.as_str()))
}

/// Decodes and fully validates an index.
///
/// Refused: more than 1 MiB; bytes that are not strict UTF-8; anything but
/// one strict JSON object; an unknown key at any level (a future field must
/// not be silently ignored); a missing or wrongly typed field; an unknown
/// `kind`; an unparseable `generatedAt`; and every rule of [`validate`].
///
/// Fails with [`GalleryErrorKind::InvalidIndex`] and all reasons, one per line.
pub fn decode(data: &[u8]) -> Result<GalleryIndex, GalleryError> {
    if data.len() > MAX_INDEX_BYTES {
        return Err(invalid("Gallery index exceeds 1 MiB."));
    }
    let text = std::str::from_utf8(data).map_err(|_| invalid("Gallery index is not valid UTF-8."))?;
    let root = files::parse_object(text).ok_or_else(|| invalid("Gallery index must be a JSON object."))?;
    let items = root.get("items").and_then(Value::as_array).filter(|_| only_known_keys(&root, &ROOT_KEYS)).ok_or_else(|| invalid("Gallery index contains unknown fields or invalid items."))?;
    let schema_version = root.get("schemaVersion").and_then(files::integer).ok_or_else(|| invalid("Gallery index field schemaVersion is missing or invalid."))?;
    let generated_at = root.get("generatedAt").and_then(Value::as_str).and_then(iso_dates::parse).ok_or_else(|| invalid("Gallery index field generatedAt must be an ISO 8601 date-time."))?;
    let repository = root.get("repository").and_then(Value::as_str).ok_or_else(|| invalid("Gallery index field repository is missing or invalid."))?;
    let index = GalleryIndex { schema_version: i32::try_from(schema_version).unwrap_or(-1), generated_at, repository: repository.to_owned(), items: items.iter().map(item).collect::<Result<_, _>>()? };
    let issues = validate(&index);
    if !issues.is_empty() {
        return Err(invalid(issues.iter().map(|issue| issue.message.as_str()).collect::<Vec<_>>().join("\n")));
    }
    Ok(index)
}

/// Semantic rules of a decoded index. An empty result means the index is acceptable.
///
/// Index: schema version 1; 1–500 items; an HTTPS `github.com` repository
/// URL; item ids unique ignoring case. Every item additionally passes
/// [`validate_item`].
pub fn validate(index: &GalleryIndex) -> Vec<GalleryValidationIssue> {
    let mut issues = Vec::new();
    let mut reject = |id: &str, message: String| issues.push(GalleryValidationIssue { id: id.to_owned(), message });
    if index.schema_version != GalleryIndex::CURRENT_SCHEMA_VERSION {
        reject("schema", format!("Gallery schema {} is unsupported.", index.schema_version));
    }
    if index.items.is_empty() || index.items.len() > MAX_ITEMS {
        reject("items", format!("Gallery must contain 1–{MAX_ITEMS} items."));
    }
    if !is_github_url(&index.repository) {
        reject("repository", "Gallery repository must be an HTTPS github.com URL.".into());
    }
    if !files::unique_ignoring_case(index.items.iter().map(|item| item.id.as_str())) {
        reject("duplicate_item", "Gallery item identifiers must be unique.".into());
    }
    for item in &index.items {
        issues.extend(validate_item(item));
    }
    issues
}

/// Rules of one item; the installer re-runs them so an item is never
/// installed on the strength of an earlier check.
///
/// Refused: an id outside `[A-Za-z0-9][A-Za-z0-9.-]{2,127}`; a blank or
/// over-long name, summary, symbol, author or license; a version that is not
/// `major.minor.patch[-pre]`; a runtime contract other than `1.0`; more than
/// 20 tags or tags equal ignoring case; a source URL that is not HTTPS
/// `github.com`; fewer than 2 or more than 500 files; paths that are equal
/// after NFC normalization and case folding (they would overwrite each
/// other); a path that fails [`is_safe_relative_path`]; a file URL that fails
/// [`is_raw_github_url`]; a hash that is not 64 lowercase hex digits; a file
/// size outside 1 byte…25 MiB; a widget without `widget.json` and `main.jsx`
/// or above 32 MiB; a Skill that is not exactly `skill.json` and `SKILL.md`
/// or above 256 KiB.
pub fn validate_item(item: &GalleryItem) -> Vec<GalleryValidationIssue> {
    let mut issues = Vec::new();
    let prefix = if item.id.is_empty() { "item" } else { &item.id };
    let id = &item.id;
    let mut reject = |rule: &str, message: String| issues.push(GalleryValidationIssue { id: format!("{prefix}.{rule}"), message });

    if !files::is_identifier(id) {
        reject("id", format!("Gallery item id is invalid: {id}"));
    }
    if !files::bounded(&item.name, MAX_NAME_LENGTH) {
        reject("name", format!("{id} has an invalid name."));
    }
    if !files::is_semantic_version(&item.version) {
        reject("version", format!("{id} must use semantic versioning."));
    }
    if !files::bounded(&item.summary, MAX_SUMMARY_LENGTH) {
        reject("summary", format!("{id} has an invalid summary."));
    }
    if !files::bounded(&item.symbol, MAX_SYMBOL_LENGTH) {
        reject("symbol", format!("{id} has an invalid symbol."));
    }
    if !files::bounded(&item.author, MAX_AUTHOR_LENGTH) {
        reject("author", format!("{id} has an invalid author."));
    }
    if !files::bounded(&item.license, MAX_LICENSE_LENGTH) {
        reject("license", format!("{id} has an invalid license."));
    }
    if item.minimum_runtime_version != GalleryIndex::RUNTIME_CONTRACT_VERSION {
        reject("runtime", format!("{id} requires unsupported runtime {}.", item.minimum_runtime_version));
    }
    if item.tags.len() > MAX_TAGS || !files::unique_ignoring_case(item.tags.iter().map(String::as_str)) {
        reject("tags", format!("{id} has invalid tags."));
    }
    if !is_github_url(&item.source_url) {
        reject("source", format!("{id} sourceURL must use HTTPS github.com."));
    }
    if item.files.len() < 2 || item.files.len() > MAX_FILES {
        reject("files", format!("{id} has an invalid file count."));
    }

    let identities: std::collections::HashSet<String> = item.files.iter().map(|file| names::identity(&file.path)).collect();
    if identities.len() != item.files.len() {
        reject("paths", format!("{id} contains duplicate or case-colliding paths."));
    }
    let mut total = 0i64;
    for file in &item.files {
        if !is_safe_relative_path(&file.path) {
            reject("path", format!("{id} contains unsafe path {}.", file.path));
        }
        if !is_raw_github_url(&file.url) {
            reject("url", format!("{id} files must use raw.githubusercontent.com over HTTPS."));
        }
        if file.sha256.len() != 64 || !file.sha256.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) {
            reject("hash", format!("{id} contains an invalid SHA-256."));
        }
        if file.bytes <= 0 || file.bytes > MAX_FILE_BYTES {
            reject("bytes", format!("{id} contains an invalid file size."));
        }
        match total.checked_add(file.bytes.max(0)) {
            Some(sum) => total = sum,
            None => reject("total", format!("{id} size overflows.")),
        }
    }
    let has = |path: &str| item.files.iter().any(|file| file.path == path);
    match item.kind {
        GalleryItemKind::Widget => {
            if !has("widget.json") || !has("main.jsx") {
                reject("required", format!("Widget {id} must contain widget.json and main.jsx."));
            }
            if total > MAX_WIDGET_BYTES {
                reject("total", format!("Widget {id} exceeds 32 MiB."));
            }
        }
        GalleryItemKind::Skill => {
            if !(has("skill.json") && has("SKILL.md") && item.files.iter().all(|file| file.path == "skill.json" || file.path == "SKILL.md")) {
                reject("required", format!("Skill {id} must contain exactly skill.json and SKILL.md."));
            }
            if total > MAX_SKILL_BYTES {
                reject("total", format!("Skill {id} exceeds 256 KiB."));
            }
        }
    }
    issues
}

/// True when `path` can only name a location inside the item's own
/// directory: not empty, at most 512 characters, no leading slash, no
/// backslash, colon (drive or stream syntax), NUL or other control character,
/// and 1–16 components none of which is empty, `.` or `..`.
pub fn is_safe_relative_path(path: &str) -> bool {
    if path.is_empty() || path.chars().count() > MAX_PATH_LENGTH {
        return false;
    }
    if path.starts_with('/') || path.contains(['\\', ':']) || path.chars().any(char::is_control) {
        return false;
    }
    let components: Vec<&str> = path.split('/').collect();
    components.len() <= MAX_PATH_DEPTH && components.iter().all(|part| !part.is_empty() && *part != "." && *part != "..")
}

/// The Gallery trust rule for the index, every file and every redirect hop:
/// HTTPS, host exactly `raw.githubusercontent.com`, and no user info, port,
/// query or fragment. A URL that is not well formed, or whose authority is
/// anything but the bare host, is untrusted.
///
/// The text is checked as written and never normalized first: a URL library
/// would drop a default port, repair a missing slash or turn a backslash
/// into a slash, and what was then compared would not be what was written.
pub fn is_raw_github_url(url: &str) -> bool {
    https_authority_is(url, RAW_HOST) && !url.contains(['?', '#'])
}

/// Source and repository links: HTTPS, host exactly `github.com`, no user info and no port.
pub fn is_github_url(url: &str) -> bool {
    https_authority_is(url, GITHUB_HOST)
}

/// True when `url` is `https://<host>` followed by nothing, a path, a query
/// or a fragment, and every character may appear in a URI. The authority must
/// be the host and nothing else, which excludes user info, any port
/// (including an empty one), a trailing dot and another host that merely
/// starts or ends with this one.
fn https_authority_is(url: &str, host: &str) -> bool {
    const SCHEME: &str = "https://";
    let Some(scheme) = url.get(..SCHEME.len()) else { return false };
    if !scheme.eq_ignore_ascii_case(SCHEME) || !well_formed(url) {
        return false;
    }
    let rest = &url[SCHEME.len()..];
    let authority = &rest[..rest.find(['/', '?', '#']).unwrap_or(rest.len())];
    authority.eq_ignore_ascii_case(host)
}

/// No space, control character or character outside what RFC 3986 lets a
/// URI contain, and every `%` starts an escape of two hexadecimal digits.
/// Characters outside ASCII are let through, as `java.net.URI` does; they
/// can never be part of the host, which is compared exactly.
fn well_formed(url: &str) -> bool {
    let bytes = url.as_bytes();
    url.char_indices().all(|(index, character)| match character {
        '%' => bytes.get(index + 1..index + 3).is_some_and(|digits| digits.iter().all(u8::is_ascii_hexdigit)),
        character if character.is_ascii() => character.is_ascii_alphanumeric() || "-._~:/?#[]@!$&'()*+,;=".contains(character),
        character => !character.is_control() && !character.is_whitespace(),
    })
}

fn item(value: &Value) -> Result<GalleryItem, GalleryError> {
    let json = value.as_object().ok_or_else(|| invalid("Gallery index contains unknown fields or invalid items."))?;
    let listed = json.get("files").and_then(Value::as_array).filter(|_| only_known_keys(json, &ITEM_KEYS)).ok_or_else(|| invalid("Gallery item contains unknown fields."))?;
    let id = json.get("id").and_then(Value::as_str).ok_or_else(|| invalid("Gallery item field id is missing or invalid."))?;
    let text = |key: &str| json.get(key).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| invalid(format!("Gallery item {id} field {key} is missing or invalid.")));
    let bad_tags = || invalid(format!("Gallery item {id} field tags is missing or invalid."));
    let tags = json.get("tags").and_then(Value::as_array).ok_or_else(bad_tags)?.iter().map(|tag| tag.as_str().map(str::to_owned).ok_or_else(bad_tags)).collect::<Result<Vec<_>, _>>()?;
    Ok(GalleryItem {
        id: id.to_owned(),
        kind: json.get("kind").and_then(Value::as_str).and_then(GalleryItemKind::from_wire).ok_or_else(|| invalid(format!("Gallery item {id} has an unknown kind.")))?,
        name: text("name")?,
        version: text("version")?,
        summary: text("summary")?,
        symbol: text("symbol")?,
        author: text("author")?,
        license: text("license")?,
        tags,
        minimum_runtime_version: text("minimumRuntimeVersion")?,
        source_url: text("sourceURL")?,
        featured: json.get("featured").and_then(Value::as_bool).ok_or_else(|| invalid(format!("Gallery item {id} field featured is missing or invalid.")))?,
        files: listed.iter().map(|value| file(id, value)).collect::<Result<_, _>>()?,
    })
}

fn file(id: &str, value: &Value) -> Result<GalleryFile, GalleryError> {
    let json = value.as_object().filter(|json| only_known_keys(json, &FILE_KEYS)).ok_or_else(|| invalid("Gallery item contains unknown fields."))?;
    let missing = |key: &str| invalid(format!("Gallery item {id} has a file with a missing or invalid {key}."));
    let text = |key: &str| json.get(key).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| missing(key));
    Ok(GalleryFile { path: text("path")?, url: text("url")?, sha256: text("sha256")?, bytes: json.get("bytes").and_then(files::integer).ok_or_else(|| missing("bytes"))? })
}
