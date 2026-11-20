//! What was installed from the Gallery, and whether the catalog holds
//! something newer. A port of `GalleryInstallations.kt`.

use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use serde_json::{Map, Value};

use super::files;
use super::{GalleryItem, GalleryItemKind};
use crate::json::Object;
use crate::packages::safe_files;

/// What was installed for one Gallery item (`GalleryInstalledRecord` in
/// Swift). `local_identifier` is the package name for a widget and the Skill
/// id for a Skill.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryInstalledRecord {
    pub item_id: String,
    pub kind: GalleryItemKind,
    pub version: String,
    pub local_identifier: String,
    pub content_fingerprint: String,
    /// Milliseconds since the epoch.
    pub installed_at: i64,
}

/// Install state of an item as shown in the Gallery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GalleryInstallState {
    NotInstalled,
    Installed,
    /// The catalog holds a newer version, or different content at the same version.
    UpdateAvailable { current: String },
}

const MAX_REGISTRY_BYTES: usize = 4 * 1024 * 1024;

/// Persistent map from Gallery item id to its [`GalleryInstalledRecord`]
/// (`GalleryInstallationRegistry` in Swift). The registry is bookkeeping, not
/// authority: an unreadable or malformed file reads as "nothing installed",
/// and the installer confirms every record against the package or Skill that
/// is really on disk.
#[derive(Debug)]
pub struct GalleryInstallationRegistry {
    file: PathBuf,
    gate: Mutex<()>,
}

impl GalleryInstallationRegistry {
    pub fn new(file: impl AsRef<Path>) -> Self {
        Self { file: safe_files::root(file.as_ref()), gate: Mutex::new(()) }
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        self.gate.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// All readable records. Malformed entries are dropped.
    pub fn records(&self) -> BTreeMap<String, GalleryInstalledRecord> {
        let _guard = self.lock();
        self.read()
    }

    fn read(&self) -> BTreeMap<String, GalleryInstalledRecord> {
        let root = self
            .file
            .parent()
            .zip(self.file.file_name().and_then(|name| name.to_str()))
            .and_then(|(directory, name)| files::read_private(directory, name, MAX_REGISTRY_BYTES))
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .and_then(|text| files::parse_object(&text));
        let mut result = BTreeMap::new();
        for (key, value) in root.unwrap_or_default() {
            if let Some(record) = value.as_object().and_then(decode).filter(|record| record.item_id == key) {
                result.insert(key, record);
            }
        }
        result
    }

    pub fn record(&self, item_id: &str) -> Option<GalleryInstalledRecord> {
        self.records().remove(item_id)
    }

    /// Compares the record with the catalog entry: same version and
    /// fingerprint is installed; a locally newer version is installed (never
    /// offered as a downgrade); anything else, including changed content at
    /// the same version, is an update.
    pub fn state(&self, item: &GalleryItem) -> GalleryInstallState {
        let Some(value) = self.record(&item.id) else { return GalleryInstallState::NotInstalled };
        if value.version == item.version && value.content_fingerprint == item.content_fingerprint() {
            return GalleryInstallState::Installed;
        }
        if semantic_version::compare(&value.version, &item.version) == Ordering::Greater {
            return GalleryInstallState::Installed;
        }
        GalleryInstallState::UpdateAvailable { current: value.version }
    }

    /// Adds or replaces one record; the file is replaced atomically.
    pub fn save(&self, record: &GalleryInstalledRecord) -> std::io::Result<()> {
        let _guard = self.lock();
        let mut records = self.read();
        records.insert(record.item_id.clone(), record.clone());
        self.write(&records)
    }

    /// Forgets one record; the installed package or Skill is not touched.
    pub fn remove(&self, item_id: &str) -> std::io::Result<()> {
        let _guard = self.lock();
        let mut records = self.read();
        records.remove(item_id);
        self.write(&records)
    }

    fn write(&self, records: &BTreeMap<String, GalleryInstalledRecord>) -> std::io::Result<()> {
        let mut root = Map::new();
        for (key, value) in records {
            let mut json = Map::new();
            json.insert("itemID".into(), Value::String(value.item_id.clone()));
            json.insert("kind".into(), Value::String(value.kind.wire().into()));
            json.insert("version".into(), Value::String(value.version.clone()));
            json.insert("localIdentifier".into(), Value::String(value.local_identifier.clone()));
            json.insert("contentFingerprint".into(), Value::String(value.content_fingerprint.clone()));
            json.insert("installedAt".into(), Value::from(value.installed_at));
            root.insert(key.clone(), Value::Object(json));
        }
        let mut bytes = serde_json::to_vec_pretty(&Value::Object(root)).unwrap_or_default();
        bytes.push(b'\n');
        files::write_atomically(&self.file, &bytes)
    }
}

fn decode(json: &Object) -> Option<GalleryInstalledRecord> {
    let text = |key: &str| json.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(GalleryInstalledRecord {
        item_id: text("itemID")?,
        kind: GalleryItemKind::from_wire(json.get("kind")?.as_str()?)?,
        version: text("version")?,
        local_identifier: text("localIdentifier")?,
        content_fingerprint: text("contentFingerprint")?,
        installed_at: json.get("installedAt").and_then(files::integer)?,
    })
}

/// Version ordering used for update detection (`GallerySemanticVersion` in Swift).
pub mod semantic_version {
    use std::cmp::Ordering;

    /// How `lhs` compares with `rhs`: older, equal or newer.
    ///
    /// The numeric components before any `-` suffix are compared first;
    /// missing components count as 0 and non-numeric ones as 0. Versions with
    /// equal numbers but different text (a pre-release suffix) are ordered by
    /// a case-insensitive, digit-aware text comparison, which stands in for
    /// Swift's `localizedStandardCompare` and, like it, is not SemVer precedence.
    pub fn compare(lhs: &str, rhs: &str) -> Ordering {
        let (left, right) = (components(lhs), components(rhs));
        for index in 0..left.len().max(right.len()) {
            let order = left.get(index).copied().unwrap_or(0).cmp(&right.get(index).copied().unwrap_or(0));
            if order != Ordering::Equal {
                return order;
            }
        }
        if lhs == rhs { Ordering::Equal } else { natural(lhs, rhs) }
    }

    fn components(value: &str) -> Vec<u64> {
        value.split('-').next().unwrap_or_default().split('.').filter(|part| !part.is_empty()).map(|part| part.parse().unwrap_or(0)).collect()
    }

    /// Runs of digits and runs of everything else, in order.
    fn chunks(text: &str) -> Vec<&str> {
        let mut result = Vec::new();
        let mut start = 0;
        let mut digits: Option<bool> = None;
        for (index, character) in text.char_indices() {
            let digit = character.is_ascii_digit();
            if digits.is_some_and(|previous| previous != digit) {
                result.push(&text[start..index]);
                start = index;
            }
            digits = Some(digit);
        }
        if start < text.len() {
            result.push(&text[start..]);
        }
        result
    }

    fn natural(lhs: &str, rhs: &str) -> Ordering {
        let (left, right) = (chunks(lhs), chunks(rhs));
        for (a, b) in left.iter().zip(&right) {
            let numeric = a.starts_with(|character: char| character.is_ascii_digit()) && b.starts_with(|character: char| character.is_ascii_digit());
            let order = if numeric {
                let (x, y) = (a.trim_start_matches('0'), b.trim_start_matches('0'));
                x.len().cmp(&y.len()).then_with(|| x.cmp(y))
            } else {
                a.to_lowercase().cmp(&b.to_lowercase())
            };
            if order != Ordering::Equal {
                return order;
            }
        }
        left.len().cmp(&right.len()).then_with(|| lhs.cmp(rhs))
    }
}
