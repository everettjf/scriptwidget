//! Package-scoped key-value storage behind `$storage`. Ported from
//! `Windows/src/ScriptWidget.Core/Api/StorageModule.cs`.
//!
//! Each package has its own file, named by a hash of the package identity; a
//! package can never name or reach another package's keys. Values are bounded
//! and writes are atomic. Compare-and-set runs under the same lock as plain
//! writes, so app and widget updates do not lose records. Files are readable
//! by the user only.

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sw_quickjs::HostResult;

use crate::api::policy;
use crate::executor::{ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, parse_object, stringify, stringify_object};

pub const MAXIMUM_VALUE_BYTES: usize = 256 * 1024;
pub const MAXIMUM_KEYS: usize = 1024;
pub const MAXIMUM_TOTAL_BYTES: usize = 8 * 1024 * 1024;
const MAXIMUM_KEY_BYTES: usize = 256;

pub struct StorageModule {
    directory: PathBuf,
}

/// One lock per storage file, shared by every module instance of the process.
fn lock_for(file: &Path) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
    let mut locks = LOCKS.get_or_init(Default::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    locks.entry(file.to_owned()).or_default().clone()
}

impl StorageModule {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into() }
    }

    /// Reads a string value for native features such as toggle state; empty when missing.
    pub fn get_string(&self, package_id: &str, key: &str) -> String {
        self.locked(package_id, |file| match read(file).opt_object(key) {
            Some(entry) if entry.opt_string("t") == "s" => entry.opt_string("v"),
            _ => String::new(),
        })
    }

    /// Writes a string value on behalf of a native feature. Returns false when a limit rejects it.
    pub fn set_string(&self, package_id: &str, key: &str, value: &str) -> bool {
        if !valid_key(key) || !valid_value("s", value) {
            return false;
        }
        self.locked(package_id, |file| {
            let mut store = read(file);
            if !store.has(key) && store.len() >= MAXIMUM_KEYS {
                return false;
            }
            store.insert(key.to_owned(), json!({ "t": "s", "v": value }));
            self.write(file, &store)
        })
    }

    /// All stored entries of a package, for the records screen and tests.
    pub fn snapshot(&self, package_id: &str) -> Object {
        self.locked(package_id, read)
    }

    pub fn clear(&self, package_id: &str) {
        self.locked(package_id, |file| {
            let _ = std::fs::remove_file(file);
        })
    }

    fn file_for(&self, package_id: &str) -> PathBuf {
        let name: String = Sha256::digest(package_id.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect();
        self.directory.join(format!("{name}.json"))
    }

    fn locked<T>(&self, package_id: &str, work: impl FnOnce(&Path) -> T) -> T {
        let file = self.file_for(package_id);
        let lock = lock_for(&file);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        work(&file)
    }

    fn write(&self, file: &Path, store: &Object) -> bool {
        let text = stringify_object(store);
        if text.len() > MAXIMUM_TOTAL_BYTES {
            return false;
        }
        let temporary = file.with_extension("json.tmp");
        let written = (|| -> std::io::Result<()> {
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&self.directory)?;
            // The temporary name is fixed and guarded by the file's lock; a stale one is replaced.
            let _ = std::fs::remove_file(&temporary);
            let mut output = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
            output.write_all(text.as_bytes())?;
            output.sync_all()?;
            std::fs::rename(&temporary, file)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written.is_ok()
    }
}

impl NativeModule for StorageModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("storage.")
    }

    fn call(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&str>) -> HostResult {
        let arguments = match payload {
            Some(payload) => parse_object(payload)?,
            None => Object::new(),
        };
        let key = arguments.opt_string("key");
        let writes = matches!(operation, "storage.set" | "storage.cas" | "storage.remove" | "storage.clear");
        if writes && policy::is_timeline_projection(request) {
            return Ok(Some("false".into()));
        }
        let flag = |value: bool| Ok(Some(if value { "true" } else { "false" }.to_owned()));
        self.locked(&request.package_id, |file| match operation {
            "storage.get" => Ok(Some(match read(file).opt_object(&key) {
                Some(entry) if valid_key(&key) => stringify_object(entry),
                _ => "null".into(),
            })),
            "storage.keys" => {
                let mut keys: Vec<String> = read(file).keys().cloned().collect();
                keys.sort_unstable();
                Ok(Some(stringify(&json!(keys))))
            }
            "storage.set" => {
                let value = arguments.opt_string("v");
                let kind = arguments.opt_string("t");
                if !valid_key(&key) || !valid_value(&kind, &value) {
                    return flag(false);
                }
                let mut store = read(file);
                if !store.has(&key) && store.len() >= MAXIMUM_KEYS {
                    return flag(false);
                }
                store.insert(key.clone(), json!({ "t": kind, "v": value }));
                flag(self.write(file, &store))
            }
            "storage.cas" => {
                let value = arguments.opt_string("v");
                let kind = arguments.opt_string("t");
                let expected = arguments.opt_string("expected");
                if !valid_key(&key) || !valid_value(&kind, &value) || expected.len() > MAXIMUM_VALUE_BYTES {
                    return flag(false);
                }
                let mut store = read(file);
                // A missing key matches an empty string or an empty object.
                let matches = match store.opt_object(&key) {
                    None => expected == if kind == "s" { "" } else { "{}" },
                    Some(current) => current.opt_string("t") == kind && current.opt_string("v") == expected,
                };
                if !matches || (!store.has(&key) && store.len() >= MAXIMUM_KEYS) {
                    return flag(false);
                }
                store.insert(key.clone(), json!({ "t": kind, "v": value }));
                flag(self.write(file, &store))
            }
            "storage.remove" => {
                if !valid_key(&key) {
                    return flag(false);
                }
                let mut store = read(file);
                store.shift_remove(&key);
                flag(self.write(file, &store))
            }
            "storage.clear" => flag(match std::fs::remove_file(file) {
                Ok(()) => true,
                Err(error) => error.kind() == std::io::ErrorKind::NotFound,
            }),
            _ => Err(format!("Unsupported operation {operation}")),
        })
    }
}

fn valid_key(key: &str) -> bool {
    !key.is_empty() && key.len() <= MAXIMUM_KEY_BYTES
}

fn valid_value(kind: &str, value: &str) -> bool {
    if value.len() > MAXIMUM_VALUE_BYTES {
        return false;
    }
    match kind {
        "s" => true,
        "j" => matches!(serde_json::from_str::<Value>(value), Ok(Value::Object(_))),
        _ => false,
    }
}

/// The stored entries; a missing, oversized or damaged file reads as empty.
fn read(file: &Path) -> Object {
    match std::fs::metadata(file) {
        Ok(metadata) if metadata.is_file() && metadata.len() <= MAXIMUM_TOTAL_BYTES as u64 => {}
        _ => return Object::new(),
    }
    std::fs::read_to_string(file).ok().and_then(|text| parse_object(&text).ok()).unwrap_or_default()
}
