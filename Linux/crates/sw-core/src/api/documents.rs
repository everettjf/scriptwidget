//! `$documents`: `list`, `readJSON` and `readCSV` over the JSON and CSV
//! files the user picked for a widget. The parsers and the script-visible
//! rules are the ones of `Android/core/.../system/DocumentsModule.kt`.
//!
//! How Linux differs from Android, which keeps a private copy of each file:
//! the record holds the path of each picked file, and the file is opened
//! again for every read, so a file that another program rewrites (an export,
//! a cron job) is always current. The path never leaves this module: a
//! script sees an opaque identifier, the file's name, its type and its size,
//! and gets the content only as parsed JSON or CSV. See
//! [`crate::api::support::read_picked_file`] for how the file is reopened.
//! A file that is gone, was replaced by something that is not a regular
//! file, or no longer parses, rejects the read; nothing else is read in its
//! place.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use crate::api::support::{CallContext, PickedFileError, PrivateFile, SYSTEM_FAILED, SystemReject, SystemServiceError, canonical, is_control_or_format, is_owner, picked_path, read_picked_file, run_system, system_gate, system_log};
use crate::executor::{Completion, ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, parse_object, quote, stringify};
use crate::plugins::strict_json;

/// Limits and parsers of `$documents`. Picked content is data: it is parsed here and never executed.
pub mod document_rules {
    use super::*;

    /// Files per installation.
    pub const MAXIMUM_FILES: usize = 8;
    /// Bytes per file.
    pub const MAXIMUM_BYTES: usize = 262_144;
    pub const MAXIMUM_NAME_BYTES: usize = 255;
    pub const MAXIMUM_DATA_ROWS: usize = 500;
    pub const MAXIMUM_COLUMNS: usize = 32;
    pub const MAXIMUM_CELL_BYTES: usize = 8192;
    pub const TYPES: [&str; 2] = ["json", "csv"];

    /// Bounded RFC 4180 style CSV, the Apple runtime's parser.
    ///
    /// - At most 256 KiB of valid UTF-8, an optional byte-order mark (`invalid_options` otherwise).
    /// - Fields are separated by commas; rows end with CR LF, LF or CR. A field may be quoted; inside
    ///   quotes a doubled quote is one quote and delimiters and newlines are data.
    /// - A quote inside an unquoted field, text after a closing quote and an unclosed quote are `invalid_options`.
    /// - More than 32 fields in a row, a cell above 8 KiB or more than 500 data rows are
    ///   `limit_exceeded`: nothing is silently truncated, so `truncated` is always false.
    /// - The first row is the header: nonempty, unique names. Every data row has exactly as many
    ///   fields (`invalid_options` otherwise).
    pub fn csv(bytes: &[u8]) -> Result<Value, SystemReject> {
        let invalid = || SystemServiceError::InvalidOptions.reject();
        let limit = || SystemServiceError::LimitExceeded.reject();
        if bytes.len() > MAXIMUM_BYTES {
            return Err(invalid());
        }
        let text = std::str::from_utf8(bytes).map_err(|_| invalid())?;
        let text = text.strip_prefix('\u{feff}').unwrap_or(text);
        let mut rows: Vec<Vec<String>> = Vec::new();
        let mut row: Vec<String> = Vec::new();
        let mut field = String::new();
        let (mut quoted, mut closed) = (false, false);
        fn finish_field(row: &mut Vec<String>, field: &mut String, closed: &mut bool) -> Result<(), SystemReject> {
            if row.len() >= MAXIMUM_COLUMNS {
                return Err(SystemServiceError::LimitExceeded.reject());
            }
            row.push(std::mem::take(field));
            *closed = false;
            Ok(())
        }
        let mut characters = text.chars().peekable();
        while let Some(character) = characters.next() {
            let append = |character: char, field: &mut String| {
                field.push(character);
                if field.len() > MAXIMUM_CELL_BYTES { Err(limit()) } else { Ok(()) }
            };
            if quoted {
                if character == '"' {
                    if characters.peek() == Some(&'"') {
                        characters.next();
                        append('"', &mut field)?;
                    } else {
                        quoted = false;
                        closed = true;
                    }
                } else {
                    append(character, &mut field)?;
                }
            } else if character == '"' {
                if !field.is_empty() || closed {
                    return Err(invalid());
                }
                quoted = true;
            } else if character == ',' {
                finish_field(&mut row, &mut field, &mut closed)?;
            } else if character == '\n' || character == '\r' {
                if character == '\r' && characters.peek() == Some(&'\n') {
                    characters.next();
                }
                finish_field(&mut row, &mut field, &mut closed)?;
                if rows.len() > MAXIMUM_DATA_ROWS {
                    return Err(limit());
                }
                rows.push(std::mem::take(&mut row));
            } else {
                if closed {
                    return Err(invalid());
                }
                append(character, &mut field)?;
            }
        }
        if quoted {
            return Err(invalid());
        }
        if !field.is_empty() || !row.is_empty() || closed {
            finish_field(&mut row, &mut field, &mut closed)?;
            if rows.len() > MAXIMUM_DATA_ROWS {
                return Err(limit());
            }
            rows.push(row);
        }
        let Some(headers) = rows.first() else { return Err(invalid()) };
        let distinct: std::collections::HashSet<&String> = headers.iter().collect();
        if headers.is_empty() || headers.iter().any(String::is_empty) || distinct.len() != headers.len() || rows[1..].iter().any(|row| row.len() != headers.len()) {
            return Err(invalid());
        }
        Ok(json!({ "headers": headers, "rows": rows[1..], "truncated": false }))
    }

    /// Strict JSON whose root is an object or an array, returned as JSON
    /// text for the script. Above 256 KiB is `limit_exceeded`; another root
    /// is `invalid_options`; text that is not well-formed UTF-8 JSON is the
    /// generic system failure, as on the Apple runtime.
    pub fn json(bytes: &[u8]) -> Result<String, SystemReject> {
        let failed = || SystemReject(SYSTEM_FAILED.to_owned());
        if bytes.len() > MAXIMUM_BYTES {
            return Err(SystemServiceError::LimitExceeded.reject());
        }
        let text = std::str::from_utf8(bytes).map_err(|_| failed())?;
        let value = strict_json::parse(text.strip_prefix('\u{feff}').unwrap_or(text), true).map_err(|_| failed())?;
        if !value.is_object() && !value.is_array() {
            return Err(SystemServiceError::InvalidOptions.reject());
        }
        Ok(stringify(&value))
    }

    /// `json` or `csv` from a file name, or `None` for anything else.
    pub fn kind(name: &str) -> Option<&'static str> {
        let lower = name.to_lowercase();
        if lower.ends_with(".json") {
            Some("json")
        } else if lower.ends_with(".csv") {
            Some("csv")
        } else {
            None
        }
    }

    /// A display name without path separators or control characters, at most 255 UTF-8 bytes; `Untitled` when nothing is left.
    pub fn name(raw: &str) -> String {
        let last = raw.rsplit(['/', '\\']).next().unwrap_or("");
        let mut name: String = last.chars().filter(|character| !is_control_or_format(*character)).collect::<String>().trim().to_owned();
        while name.len() > MAXIMUM_NAME_BYTES {
            name.pop();
        }
        if name.is_empty() { "Untitled".to_owned() } else { name }
    }

    /// Whether `content` parses under the rules a widget read applies.
    pub fn valid(kind: &str, content: &[u8]) -> bool {
        if kind == "json" { json(content).is_ok() } else { csv(content).is_ok() }
    }
}

/// One picked document. A script sees `id`, `name`, `kind` and the size; `path` stays in this program.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentEntry {
    pub id: String,
    pub name: String,
    /// `json` or `csv`.
    pub kind: String,
    /// Where the file is, as resolved when the user picked it.
    pub path: PathBuf,
}

/// Why a picked file was not added; shown to the user, never logged with a name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PickError {
    /// The widget is not an installed one.
    NotInstalled,
    UnsupportedType,
    TooLarge,
    Unreadable,
    InvalidContent,
    /// The widget already has as many as it may.
    Full,
    /// The same file is already in the list.
    Duplicate,
    /// The record could not be read or written.
    Storage,
}

impl PickError {
    pub fn code(self) -> &'static str {
        match self {
            Self::NotInstalled => "not_installed",
            Self::UnsupportedType => "unsupported_type",
            Self::TooLarge => "too_large",
            Self::Unreadable => "unreadable",
            Self::InvalidContent => "invalid_content",
            Self::Full => "full",
            Self::Duplicate => "duplicate",
            Self::Storage => "storage",
        }
    }
}

/// The documents the user picked for each installation. The index lives in a
/// directory named by a digest of the installation, so an identity is never
/// a path. A malformed index is `unavailable`, never an empty list.
pub struct DocumentStore {
    directory: PathBuf,
}

impl DocumentStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into() }
    }

    fn index(&self, installation: &str) -> PrivateFile {
        PrivateFile::new(self.directory.join(canonical::owner_file_name(installation, "")).join("index.json"), 64 * 1024)
    }

    fn locked<T>(&self, installation: &str, work: impl FnOnce(&PrivateFile) -> T) -> T {
        let file = self.index(installation);
        let lock = file.lock();
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        work(&file)
    }

    /// The installation's documents in the order they were picked.
    pub fn list(&self, installation: &str) -> Result<Vec<DocumentEntry>, SystemReject> {
        if !is_owner(installation) {
            return Ok(Vec::new());
        }
        self.locked(installation, load)
    }

    /// Records `chosen` for `installation` after reading it once under the
    /// rules a widget read applies, so a file that cannot be read is refused
    /// when it is picked.
    pub fn add(&self, installation: &str, chosen: &Path) -> Result<DocumentEntry, PickError> {
        if !is_owner(installation) {
            return Err(PickError::NotInstalled);
        }
        let path = picked_path(chosen).ok_or(PickError::Unreadable)?;
        let name = document_rules::name(&path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default());
        let kind = document_rules::kind(&name).ok_or(PickError::UnsupportedType)?;
        let content = read_picked_file(&path, document_rules::MAXIMUM_BYTES as u64).map_err(|error| match error {
            PickedFileError::TooLarge => PickError::TooLarge,
            PickedFileError::Unreadable => PickError::Unreadable,
        })?;
        if !document_rules::valid(kind, &content.bytes) {
            return Err(PickError::InvalidContent);
        }
        self.locked(installation, |file| {
            let mut entries = load(file).map_err(|_| PickError::Storage)?;
            if entries.iter().any(|entry| entry.path == path) {
                return Err(PickError::Duplicate);
            }
            if entries.len() >= document_rules::MAXIMUM_FILES {
                return Err(PickError::Full);
            }
            let entry = DocumentEntry { id: crate::packages::manifests::fresh_id().trim_start_matches("local.").to_owned(), name, kind: kind.to_owned(), path };
            entries.push(entry.clone());
            if save(file, &entries) { Ok(entry) } else { Err(PickError::Storage) }
        })
    }

    /// The bytes of one document as the file holds them now.
    /// `permission_denied` unless `id` names a document of this installation
    /// with this type; `unavailable` when its file cannot be read any more;
    /// `limit_exceeded` when it has grown beyond 256 KiB.
    pub fn read(&self, installation: &str, id: &str, kind: &str) -> Result<Vec<u8>, SystemReject> {
        let denied = || SystemServiceError::PermissionDenied.reject();
        if !is_owner(installation) || !is_owner(id) {
            return Err(denied());
        }
        let entry = self.locked(installation, load)?.into_iter().find(|entry| entry.id == id && entry.kind == kind).ok_or_else(denied)?;
        read_picked_file(&entry.path, document_rules::MAXIMUM_BYTES as u64).map(|file| file.bytes).map_err(|error| match error {
            PickedFileError::TooLarge => SystemServiceError::LimitExceeded.reject(),
            PickedFileError::Unreadable => SystemServiceError::Unavailable.reject(),
        })
    }

    /// The size of a document's file now, or `None` when it cannot be read.
    pub fn bytes(&self, entry: &DocumentEntry) -> Option<u64> {
        let metadata = std::fs::symlink_metadata(&entry.path).ok()?;
        metadata.is_file().then_some(metadata.len())
    }

    /// Removes one document from the list (the file itself is not touched) and returns its entry.
    pub fn remove(&self, installation: &str, id: &str) -> Option<DocumentEntry> {
        if !is_owner(installation) {
            return None;
        }
        self.locked(installation, |file| {
            let entries = load(file).ok()?;
            let entry = entries.iter().find(|entry| entry.id == id)?.clone();
            let remaining: Vec<_> = entries.into_iter().filter(|known| known.id != id).collect();
            save(file, &remaining).then_some(entry)
        })
    }

    /// Forgets everything recorded for `installation`, an unreadable index included.
    pub fn clear(&self, installation: &str) {
        if is_owner(installation) {
            self.locked(installation, |file| {
                file.delete();
                if let Some(home) = file.path().parent() {
                    let _ = std::fs::remove_dir(home);
                }
            });
        }
    }
}

fn load(file: &PrivateFile) -> Result<Vec<DocumentEntry>, SystemReject> {
    let unavailable = || SystemServiceError::Unavailable.reject();
    let Some(text) = file.read().map_err(|_| unavailable())? else { return Ok(Vec::new()) };
    let root = parse_object(&text).map_err(|_| unavailable())?;
    if root.len() != 2 || root.get("formatVersion").and_then(Value::as_i64) != Some(1) {
        return Err(unavailable());
    }
    let items = root.opt_array("documents").filter(|items| items.len() <= document_rules::MAXIMUM_FILES).ok_or_else(unavailable)?;
    let entries: Vec<DocumentEntry> = items
        .iter()
        .map(|item| {
            let item = item.as_object()?;
            let text = |name: &str| item.get(name).and_then(Value::as_str).map(str::to_owned);
            let entry = DocumentEntry { id: text("id")?, name: text("name")?, kind: text("type")?, path: PathBuf::from(text("path")?) };
            (is_owner(&entry.id) && !entry.name.is_empty() && entry.name.len() <= document_rules::MAXIMUM_NAME_BYTES && document_rules::TYPES.contains(&entry.kind.as_str()) && entry.path.is_absolute()).then_some(entry)
        })
        .collect::<Option<_>>()
        .ok_or_else(unavailable)?;
    let distinct: std::collections::HashSet<&str> = entries.iter().map(|entry| entry.id.as_str()).collect();
    if distinct.len() != entries.len() {
        return Err(unavailable());
    }
    Ok(entries)
}

fn save(file: &PrivateFile, entries: &[DocumentEntry]) -> bool {
    let documents: Vec<Value> = entries.iter().map(|entry| json!({ "id": entry.id, "name": entry.name, "type": entry.kind, "path": entry.path.to_string_lossy() })).collect();
    file.write(&stringify(&json!({ "formatVersion": 1, "documents": documents })))
}

/// `$documents`: `list`, `readJSON`, `readCSV` over the files the user
/// picked for this installation. Every call passes the system gate
/// (`documents` declared by an installed Runtime 1.6 package, not a future
/// timeline entry or Live Activity, the query budget). Picking a file for a
/// widget is the native grant: a widget without picked files gets an empty
/// list, and an identifier of another installation is `permission_denied`.
#[derive(Clone)]
pub struct DocumentsModule {
    store: Arc<DocumentStore>,
}

impl DocumentsModule {
    pub const PERMISSION: &'static str = "documents";

    pub fn new(store: Arc<DocumentStore>) -> Self {
        Self { store }
    }

    pub fn store(&self) -> &Arc<DocumentStore> {
        &self.store
    }

    /// `[{id, name, type, bytes}]` for this installation. `bytes` is the size of the file now, 0 when it cannot be read.
    pub fn list(&self, context: &CallContext) -> Result<Value, SystemReject> {
        system_gate::check(context, Self::PERMISSION, false)?;
        Ok(Value::Array(self.store.list(&context.installation)?.iter().map(|entry| json!({ "id": entry.id, "name": entry.name, "type": entry.kind, "bytes": self.store.bytes(entry).unwrap_or(0) })).collect()))
    }

    fn content(&self, context: &CallContext, id: Option<&Value>, kind: &str) -> Result<Vec<u8>, SystemReject> {
        system_gate::check(context, Self::PERMISSION, false)?;
        let id = id.and_then(Value::as_str).ok_or_else(|| SystemServiceError::PermissionDenied.reject())?;
        self.store.read(&context.installation, id, kind)
    }

    /// The JSON text of a picked `json` document; see [`document_rules::json`].
    pub fn read_json(&self, context: &CallContext, id: Option<&Value>) -> Result<String, SystemReject> {
        document_rules::json(&self.content(context, id, "json")?)
    }

    /// `{headers, rows, truncated}` of a picked `csv` document; see [`document_rules::csv`].
    pub fn read_csv(&self, context: &CallContext, id: Option<&Value>) -> Result<Value, SystemReject> {
        document_rules::csv(&self.content(context, id, "csv")?)
    }

    /// Forgets the documents of a deleted installation.
    pub fn retire(&self, installation: &str) {
        self.store.clear(installation);
        system_log::call("documents.retire", "ok");
    }
}

impl NativeModule for DocumentsModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("documents.")
    }

    fn apis(&self) -> &[&'static str] {
        &["$documents"]
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>, done: Completion) {
        let context = CallContext::from_request(request);
        let module = self.clone();
        let id = payload.and_then(|payload| payload.get("id")).cloned();
        match operation {
            "documents.list" => run_system(operation, done, move || module.list(&context).map(|value| stringify(&value))),
            "documents.readJSON" => run_system(operation, done, move || module.read_json(&context, id.as_ref())),
            "documents.readCSV" => run_system(operation, done, move || module.read_csv(&context, id.as_ref()).map(|value| stringify(&value))),
            _ => done.complete(false, Some(quote(&format!("Unsupported operation {operation}")))),
        }
    }
}
