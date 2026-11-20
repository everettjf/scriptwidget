//! `$photos`: thumbnails of the pictures the user picked for a widget. The
//! script-visible rules are the ones of `Android/core/.../system/PhotosModule.kt`.
//!
//! How Linux differs from Android, which copies thumbnails of one selection
//! shared by every widget when the photos are picked:
//! - The selection is per widget: the user picks pictures for one widget in
//!   the management window (or with `scriptwidget photos add`).
//! - The record holds the path of each picture. The picture is opened again
//!   when its thumbnail is needed (see
//!   [`crate::api::support::read_picked_file`]), so a picture that was edited
//!   shows its new content. Thumbnails are kept in the cache folder, by the
//!   picture's path, size and modification time.
//! - A script never sees a path, a file name, a location or EXIF data: it
//!   gets an opaque identifier, the original pixel size, and a re-encoded
//!   JPEG of at most 768 pixels and 128 KiB.
//! - Pictures are ordered by the file's modification time, newest first,
//!   not by the capture time inside the file.
//!
//! Decoding and encoding pictures is the painter's work (`sw-render`); this
//! crate only knows the [`ThumbnailMaker`] it is given.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sw_quickjs::HostResult;

use crate::api::documents::PickError;
use crate::api::support::{CallContext, PickedFileError, PrivateFile, SystemReject, canonical, is_owner, iso_dates, picked_path, read_picked_file, run_system, system_log, system_options};
use crate::api::weather::Clock;
use crate::executor::{Completion, ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, parse_object, quote, stringify};

/// Bounds of the Photos API.
pub mod photo_limits {
    /// Pictures the user can pick for one widget.
    pub const MAXIMUM_SELECTED: usize = 24;
    /// Thumbnails in one result.
    pub const MAXIMUM_RETURNED: usize = 4;
    /// Candidates one query considers, newest first.
    pub const MAXIMUM_CANDIDATES: usize = 64;
    pub const MAXIMUM_SIDE: u32 = 768;
    pub const MAXIMUM_THUMBNAIL_BYTES: usize = 128 * 1024;
    pub const SNAPSHOT_LIFETIME_SECONDS: f64 = 86_400.0;
    /// A partially available result is retried after at most this long.
    pub const PARTIAL_RETRY_SECONDS: f64 = 60.0;
    /// A picture file larger than this is not opened.
    pub const MAXIMUM_SOURCE_BYTES: u64 = 16 * 1024 * 1024;
}

/// Script-visible Photos errors, with the Apple runtime's wording.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhotosError {
    Invalid,
    Denied,
    Unavailable,
    Changed,
    CacheMiss,
}

impl PhotosError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Invalid => "[invalid_options] Invalid photo options or selection",
            Self::Denied => "[permission_denied] Allow Photos access and choose photos or albums in ScriptWidget Settings",
            Self::Unavailable => "[unavailable] Photos could not be loaded",
            Self::Changed => "[scope_changed] Photo access changed. Reload and try again.",
            Self::CacheMiss => "[cache_miss] Open this widget in ScriptWidget to prepare its photo snapshot",
        }
    }

    pub fn reject(self) -> SystemReject {
        SystemReject(self.message().to_owned())
    }
}

/// `items(options)` input: `limit` integer 1–4, `offset` integer 0–63, `maxAgeSeconds` 0–86400. Unknown keys, Booleans and nonfinite numbers reject.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PhotoQuery {
    pub limit: usize,
    pub offset: usize,
    pub max_age_seconds: f64,
}

impl PhotoQuery {
    /// A snapshot is reused only for the same page.
    pub fn identity(&self) -> String {
        format!("{}:{}", self.limit, self.offset)
    }

    pub fn parse(options: Option<&Object>) -> Result<Self, SystemReject> {
        let empty = Object::new();
        let values = options.unwrap_or(&empty);
        let invalid = || PhotosError::Invalid.reject();
        if values.keys().any(|key| !["limit", "offset", "maxAgeSeconds"].contains(&key.as_str())) {
            return Err(invalid());
        }
        let number = |key: &str, fallback: f64, minimum: f64, maximum: f64, integer: bool| -> Result<f64, SystemReject> {
            if !values.has(key) {
                return Ok(fallback);
            }
            match system_options::json_number(values.get(key)) {
                Some(value) if value.is_finite() && (minimum..=maximum).contains(&value) && !(integer && value.fract() != 0.0) => Ok(value),
                _ => Err(invalid()),
            }
        };
        Ok(Self { limit: number("limit", 4.0, 1.0, 4.0, true)? as usize, offset: number("offset", 0.0, 0.0, 63.0, true)? as usize, max_age_seconds: number("maxAgeSeconds", 3600.0, 0.0, 86_400.0, false)? })
    }
}

/// A re-encoded picture: JPEG bytes, and the pixel size of the picture it was made from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Thumbnail {
    pub bytes: Vec<u8>,
    pub original_width: u32,
    pub original_height: u32,
}

/// Makes a JPEG of at most `maximum_side` pixels on the longer side and at
/// most `maximum_bytes` from the bytes of a picture file, turned as its
/// orientation says and without any of its metadata. `None` when the bytes
/// are not a picture that can be decoded within the painter's limits.
pub trait ThumbnailMaker: Send + Sync {
    fn make(&self, source: &[u8], maximum_side: u32, maximum_bytes: usize) -> Option<Thumbnail>;
}

/// The size of a thumbnail and what a JPEG is.
pub mod thumbnail_plan {
    use super::photo_limits;

    /// `width` × `height` scaled down (never up) so the longer side is at most `maximum_side`; each side stays at least 1.
    pub fn fit(width: u32, height: u32, maximum_side: u32) -> (u32, u32) {
        if width == 0 || height == 0 {
            return (0, 0);
        }
        let longest = width.max(height);
        if longest <= maximum_side {
            return (width, height);
        }
        let scale = f64::from(maximum_side) / f64::from(longest);
        (((f64::from(width) * scale).round() as u32).max(1), ((f64::from(height) * scale).round() as u32).max(1))
    }

    pub fn is_jpeg(bytes: &[u8]) -> bool {
        bytes.len() >= 4 && bytes[..3] == [0xff, 0xd8, 0xff]
    }

    /// The qualities tried, best first, before the picture is made smaller.
    pub const QUALITIES: [u32; 5] = [85, 75, 65, 55, 45];
    pub const MINIMUM_SIDE: u32 = 96;

    /// Tries decreasing quality, then smaller sizes, until the JPEG fits the
    /// byte limit. `encode` makes a JPEG of a size and a quality. `None`
    /// when even the smallest attempt is too large or the encoder fails.
    pub fn encode(width: u32, height: u32, maximum_side: u32, maximum_bytes: usize, mut encode: impl FnMut(u32, u32, u32) -> Option<Vec<u8>>) -> Option<Vec<u8>> {
        let (mut target_width, mut target_height) = fit(width, height, maximum_side.min(photo_limits::MAXIMUM_SIDE));
        if target_width == 0 || target_height == 0 {
            return None;
        }
        loop {
            for quality in QUALITIES {
                let bytes = encode(target_width, target_height, quality)?;
                if bytes.len() <= maximum_bytes && is_jpeg(&bytes) {
                    return Some(bytes);
                }
            }
            let longest = target_width.max(target_height);
            if longest <= MINIMUM_SIDE {
                return None;
            }
            (target_width, target_height) = fit(target_width, target_height, (longest * 3 / 4).max(MINIMUM_SIDE));
        }
    }
}

/// A picked picture. `id` is an opaque UUID; `width` and `height` are the original pixel size; `path` stays in this program.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhotoEntry {
    pub id: String,
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
    /// The file's modification time when it was picked, in epoch milliseconds; orders the selection.
    pub taken_at: i64,
    /// When it was picked, in epoch milliseconds.
    pub revision: i64,
}

impl PhotoEntry {
    fn reference(&self) -> String {
        format!("{}:{}", self.id, self.revision)
    }
}

/// The index of an installation's selection is not what this program writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Corrupt;

/// The pictures the user picked for each installation, and their thumbnails.
pub struct PhotoLibrary {
    directory: PathBuf,
    cache: PathBuf,
    maker: OnceLock<Arc<dyn ThumbnailMaker>>,
}

impl PhotoLibrary {
    /// `directory` holds the records; `cache` the thumbnails, which can be made again.
    pub fn new(directory: impl Into<PathBuf>, cache: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into(), cache: cache.into(), maker: OnceLock::new() }
    }

    /// Gives the library the painter's thumbnail maker. Without one no thumbnail can be made and `items()` is `unavailable`.
    pub fn set_maker(&self, maker: Arc<dyn ThumbnailMaker>) {
        let _ = self.maker.set(maker);
    }

    fn home(&self, installation: &str) -> PathBuf {
        self.directory.join(canonical::owner_file_name(installation, ""))
    }

    fn index(&self, installation: &str) -> PrivateFile {
        PrivateFile::new(self.home(installation).join("index.json"), 128 * 1024)
    }

    fn snapshot(&self, installation: &str) -> PrivateFile {
        PrivateFile::new(self.home(installation).join("snapshot.json"), 64 * 1024)
    }

    fn locked<T>(&self, installation: &str, work: impl FnOnce(&PrivateFile) -> T) -> T {
        let file = self.index(installation);
        let lock = file.lock();
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        work(&file)
    }

    /// The installation's pictures, newest first by modification time, ties by identifier.
    pub fn list(&self, installation: &str) -> Result<Vec<PhotoEntry>, Corrupt> {
        if !is_owner(installation) {
            return Ok(Vec::new());
        }
        let mut entries = self.locked(installation, load)?;
        entries.sort_by(|left, right| right.taken_at.cmp(&left.taken_at).then_with(|| left.id.cmp(&right.id)));
        Ok(entries)
    }

    /// Digest of the selection; a snapshot made under another selection is never reused.
    pub fn identity(entries: &[PhotoEntry]) -> String {
        let mut references: Vec<(&str, String)> = entries.iter().map(|entry| (entry.id.as_str(), entry.reference())).collect();
        references.sort_unstable();
        canonical::sha256(&references.into_iter().map(|(_, reference)| reference).collect::<Vec<_>>().join("\n"))
    }

    /// Records `chosen` for `installation`. Its thumbnail is made now, so a
    /// file that is not a picture is refused when it is picked.
    pub fn add(&self, installation: &str, chosen: &Path, now_milliseconds: i64) -> Result<PhotoEntry, PickError> {
        if !is_owner(installation) {
            return Err(PickError::NotInstalled);
        }
        let path = picked_path(chosen).ok_or(PickError::Unreadable)?;
        let (key, taken_at) = stamp(&path).ok_or(PickError::Unreadable)?;
        let thumbnail = self.make(&path)?;
        self.locked(installation, |file| {
            let mut entries = load(file).map_err(|_| PickError::Storage)?;
            if entries.iter().any(|entry| entry.path == path) {
                return Err(PickError::Duplicate);
            }
            if entries.len() >= photo_limits::MAXIMUM_SELECTED {
                return Err(PickError::Full);
            }
            let entry = PhotoEntry { id: crate::packages::manifests::fresh_id().trim_start_matches("local.").to_owned(), path, width: thumbnail.original_width, height: thumbnail.original_height, taken_at, revision: now_milliseconds };
            entries.push(entry.clone());
            if !save(file, &entries) {
                return Err(PickError::Storage);
            }
            // The cache is an optimization: the thumbnail is made again when it could not be kept.
            let _ = self.cached(installation, &key).write_bytes(&thumbnail.bytes);
            Ok(entry)
        })
    }

    /// Removes one picture from the selection; the file itself is not touched.
    pub fn remove(&self, installation: &str, id: &str) -> bool {
        is_owner(installation)
            && self.locked(installation, |file| {
                let Ok(entries) = load(file) else { return false };
                let remaining: Vec<_> = entries.iter().filter(|entry| entry.id != id).cloned().collect();
                remaining.len() != entries.len() && save(file, &remaining)
            })
    }

    /// Forgets the selection, the snapshot record and the thumbnails of `installation`; also the way out of a corrupt index.
    pub fn clear(&self, installation: &str) {
        if !is_owner(installation) {
            return;
        }
        self.locked(installation, |file| {
            file.delete();
            self.snapshot(installation).delete();
            let _ = std::fs::remove_dir(self.home(installation));
            let thumbnails = self.cache.join(canonical::owner_file_name(installation, ""));
            // Only a real directory of this program's own making is emptied.
            if std::fs::symlink_metadata(&thumbnails).is_ok_and(|metadata| metadata.is_dir()) {
                let _ = std::fs::remove_dir_all(thumbnails);
            }
        });
    }

    fn cached(&self, installation: &str, key: &str) -> CachedThumbnail {
        CachedThumbnail(self.cache.join(canonical::owner_file_name(installation, "")).join(format!("{key}.jpg")))
    }

    fn make(&self, path: &Path) -> Result<Thumbnail, PickError> {
        let source = read_picked_file(path, photo_limits::MAXIMUM_SOURCE_BYTES).map_err(|error| match error {
            PickedFileError::TooLarge => PickError::TooLarge,
            PickedFileError::Unreadable => PickError::Unreadable,
        })?;
        let maker = self.maker.get().ok_or(PickError::Storage)?;
        maker.make(&source.bytes, photo_limits::MAXIMUM_SIDE, photo_limits::MAXIMUM_THUMBNAIL_BYTES).filter(|thumbnail| thumbnail.bytes.len() <= photo_limits::MAXIMUM_THUMBNAIL_BYTES && thumbnail_plan::is_jpeg(&thumbnail.bytes) && thumbnail.original_width > 0 && thumbnail.original_height > 0).ok_or(PickError::InvalidContent)
    }

    /// The thumbnail of a picture as its file is now, or `None` when the
    /// file is gone, is not a regular file, is too large or is not a picture.
    pub fn read(&self, installation: &str, entry: &PhotoEntry) -> Option<Vec<u8>> {
        if !is_owner(installation) || !is_owner(&entry.id) {
            return None;
        }
        let (key, _) = stamp(&entry.path)?;
        let cached = self.cached(installation, &key);
        if let Some(bytes) = cached.read_bytes() {
            return Some(bytes);
        }
        let thumbnail = self.make(&entry.path).ok()?;
        let _ = cached.write_bytes(&thumbnail.bytes);
        Some(thumbnail.bytes)
    }
}

/// What identifies the present state of a picture file (path, size and
/// modification time, as a digest) and its modification time in milliseconds.
/// `None` unless it is a regular file; a link is not followed.
fn stamp(path: &Path) -> Option<(String, i64)> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > photo_limits::MAXIMUM_SOURCE_BYTES {
        return None;
    }
    let key = canonical::sha256(&format!("{}\n{}\n{}\n{}", path.display(), metadata.len(), metadata.mtime(), metadata.mtime_nsec()));
    Some((key[..40].to_owned(), metadata.mtime().saturating_mul(1000).saturating_add(metadata.mtime_nsec() / 1_000_000)))
}

/// One thumbnail in the cache folder.
struct CachedThumbnail(PathBuf);

impl CachedThumbnail {
    fn read_bytes(&self) -> Option<Vec<u8>> {
        let file = read_picked_file(&self.0, photo_limits::MAXIMUM_THUMBNAIL_BYTES as u64).ok()?;
        thumbnail_plan::is_jpeg(&file.bytes).then_some(file.bytes)
    }

    fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        let parent = self.0.parent().ok_or_else(|| std::io::Error::other("no folder"))?;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
        let mut temporary = self.0.clone().into_os_string();
        temporary.push(format!(".{}.tmp", std::process::id()));
        let temporary = PathBuf::from(temporary);
        let _ = std::fs::remove_file(&temporary);
        let written = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary).and_then(|mut file| file.write_all(bytes)).and_then(|()| std::fs::rename(&temporary, &self.0));
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written
    }
}

fn load(file: &PrivateFile) -> Result<Vec<PhotoEntry>, Corrupt> {
    let Some(text) = file.read().map_err(|_| Corrupt)? else { return Ok(Vec::new()) };
    let root = parse_object(&text).map_err(|_| Corrupt)?;
    let items = root.opt_array("photos").filter(|items| items.len() <= photo_limits::MAXIMUM_SELECTED && root.get("formatVersion").and_then(Value::as_i64) == Some(1)).ok_or(Corrupt)?;
    let entries: Vec<PhotoEntry> = items
        .iter()
        .map(|item| {
            let item = item.as_object()?;
            let text = |name: &str| item.get(name).and_then(Value::as_str).map(str::to_owned);
            let side = |name: &str| item.get(name).and_then(Value::as_u64).and_then(|value| u32::try_from(value).ok()).filter(|value| *value >= 1);
            let time = |name: &str| item.get(name).and_then(Value::as_i64);
            let entry = PhotoEntry { id: text("id")?, path: PathBuf::from(text("path")?), width: side("width")?, height: side("height")?, taken_at: time("takenAt")?, revision: time("revision")? };
            (is_owner(&entry.id) && entry.path.is_absolute()).then_some(entry)
        })
        .collect::<Option<_>>()
        .ok_or(Corrupt)?;
    let distinct: std::collections::HashSet<&str> = entries.iter().map(|entry| entry.id.as_str()).collect();
    if distinct.len() != entries.len() { Err(Corrupt) } else { Ok(entries) }
}

fn save(file: &PrivateFile, entries: &[PhotoEntry]) -> bool {
    let photos: Vec<Value> = entries.iter().map(|entry| json!({ "id": entry.id, "path": entry.path.to_string_lossy(), "width": entry.width, "height": entry.height, "takenAt": entry.taken_at, "revision": entry.revision })).collect();
    file.write(&stringify(&json!({ "formatVersion": 1, "photos": photos })))
}

/// The private snapshot record of one installation: which pictures one
/// query delivered and when. Image bytes always come from the current
/// selection, so a removed picture can never be served from a snapshot.
pub mod photo_snapshot {
    use super::*;

    pub fn encode(scope: &str, query: &PhotoQuery, references: &[PhotoEntry], available: usize, fetched_at_milliseconds: i64) -> String {
        stringify(&json!({ "formatVersion": 1, "scope": scope, "query": query.identity(), "available": available, "references": references.iter().map(PhotoEntry::reference).collect::<Vec<_>>(), "fetchedAt": fetched_at_milliseconds }))
    }

    /// The snapshot's fetch time and available count when it matches the
    /// current selection, page and picture revisions and is neither from
    /// the future nor older than 24 hours; `None` otherwise.
    pub fn matching(text: &str, scope: &str, query: &PhotoQuery, references: &[PhotoEntry], now_milliseconds: i64) -> Option<(i64, usize)> {
        let root = parse_object(text).ok()?;
        if root.get("formatVersion").and_then(Value::as_i64) != Some(1) || root.get("scope").and_then(Value::as_str) != Some(scope) || root.get("query").and_then(Value::as_str) != Some(query.identity().as_str()) {
            return None;
        }
        let stored: Vec<&str> = root.opt_array("references")?.iter().map(Value::as_str).collect::<Option<_>>()?;
        if stored != references.iter().map(PhotoEntry::reference).collect::<Vec<_>>() {
            return None;
        }
        let fetched_at = root.get("fetchedAt").and_then(Value::as_i64)?;
        let available = usize::try_from(root.get("available").and_then(Value::as_i64)?).ok()?;
        let age = (now_milliseconds - fetched_at) as f64 / 1000.0;
        ((0.0..=photo_limits::SNAPSHOT_LIFETIME_SECONDS).contains(&age) && available <= references.len()).then_some((fetched_at, available))
    }

    /// Whether a matching snapshot may answer a query. Future timeline
    /// entries and Live Activity presentations always use it; otherwise it
    /// must be within `maxAgeSeconds`, and within 60 seconds when some
    /// thumbnails were unavailable so they are retried.
    pub fn usable(fetched_at_milliseconds: i64, available: usize, references: usize, query: &PhotoQuery, read_only: bool, now_milliseconds: i64) -> bool {
        if read_only {
            return true;
        }
        let limit = if available < references { query.max_age_seconds.min(photo_limits::PARTIAL_RETRY_SECONDS) } else { query.max_age_seconds };
        (now_milliseconds - fetched_at_milliseconds) as f64 / 1000.0 <= limit
    }
}

/// `$photos`. No storage permission exists or is needed: the only pictures
/// reachable are the ones the user picked for this widget.
#[derive(Clone)]
pub struct PhotosModule {
    library: Arc<PhotoLibrary>,
    clock: Clock,
}

const QUERY_LIMIT: &str = "[query_limit] Too many system data queries";

impl PhotosModule {
    pub const PERMISSION: &'static str = "photos";

    pub fn new(library: Arc<PhotoLibrary>) -> Self {
        Self::with_clock(library, Arc::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)))
    }

    pub fn with_clock(library: Arc<PhotoLibrary>, clock: Clock) -> Self {
        Self { library, clock }
    }

    pub fn library(&self) -> &Arc<PhotoLibrary> {
        &self.library
    }

    /// An installed Package 2.0 widget that declares `photos`.
    pub fn permitted(context: &CallContext) -> bool {
        context.is_installed() && context.declares(Self::PERMISSION)
    }

    /// `undeclared` without the package permission, otherwise `limited`: the
    /// program can only ever reach the pictures the user handed over, which
    /// is Apple's limited access.
    pub fn authorization_status(context: &CallContext) -> &'static str {
        if Self::permitted(context) { "limited" } else { "undeclared" }
    }

    /// Nothing to prompt for on Linux; resolves true. Consumes a data query except in read-only presentations.
    pub fn request_authorization(&self, context: &CallContext) -> Result<bool, SystemReject> {
        if !Self::permitted(context) {
            return Err(PhotosError::Denied.reject());
        }
        if !(context.is_timeline_projection || context.is_live_activity) && !context.consume_data_query() {
            return Err(SystemReject(QUERY_LIMIT.to_owned()));
        }
        Ok(true)
    }

    /// `items(options)`, in the Apple runtime's order: package permission,
    /// options, query budget, a nonempty selection, then the snapshot rules.
    /// The selection is compared again before delivery.
    pub fn items(&self, context: &CallContext, options: Option<&Object>, invalid_options: bool) -> Result<Value, SystemReject> {
        if !Self::permitted(context) {
            return Err(PhotosError::Denied.reject());
        }
        if invalid_options {
            return Err(PhotosError::Invalid.reject());
        }
        let query = PhotoQuery::parse(options)?;
        if !context.consume_data_query() {
            return Err(SystemReject(QUERY_LIMIT.to_owned()));
        }
        let record = self.library.snapshot(&context.installation);
        let lock = record.lock();
        let result = self.answer(context, &query, &record, &lock);
        if result.is_err() {
            let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            record.delete();
        }
        result
    }

    fn answer(&self, context: &CallContext, query: &PhotoQuery, record: &PrivateFile, lock: &std::sync::Mutex<()>) -> Result<Value, SystemReject> {
        let installation = &context.installation;
        let entries = self.library.list(installation).map_err(|_| PhotosError::Unavailable.reject())?;
        if entries.is_empty() {
            return Err(PhotosError::Denied.reject());
        }
        let scope = PhotoLibrary::identity(&entries);
        let references: Vec<PhotoEntry> = entries.iter().take(photo_limits::MAXIMUM_CANDIDATES).skip(query.offset).take(query.limit.min(photo_limits::MAXIMUM_RETURNED)).cloned().collect();
        let now = (self.clock)();
        let read_only = context.is_timeline_projection || context.is_live_activity;
        let items: Vec<Value> = references
            .iter()
            .filter_map(|entry| {
                let bytes = self.library.read(installation, entry)?;
                Some(json!({ "id": entry.id, "image": format!("data:image/jpeg;base64,{}", crate::api::fetch::base64(&bytes)), "width": entry.width, "height": entry.height }))
            })
            .collect();
        let stored = {
            let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            record.read().ok().flatten()
        };
        let cached = stored
            .and_then(|text| photo_snapshot::matching(&text, &scope, query, &references, now))
            .filter(|(fetched_at, available)| photo_snapshot::usable(*fetched_at, *available, references.len(), query, read_only, now) && *available == items.len());
        let fetched_at = cached.map_or(now, |(fetched_at, _)| fetched_at);
        if cached.is_none() {
            if read_only {
                return Err(PhotosError::CacheMiss.reject());
            }
            let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            record.write(&photo_snapshot::encode(&scope, query, &references, items.len(), now));
        }
        let current = self.library.list(installation).map_err(|_| PhotosError::Changed.reject())?;
        if !Self::permitted(context) || PhotoLibrary::identity(&current) != scope {
            return Err(PhotosError::Changed.reject());
        }
        Ok(json!({
            "status": if items.is_empty() && !references.is_empty() { "unavailable" } else { "ready" },
            "unavailableCount": references.len() - items.len(),
            "items": items,
            "fetchedAt": iso_dates::format(fetched_at),
            "source": if cached.is_some() { "cache" } else { "system" },
            "stale": (now - fetched_at) as f64 / 1000.0 > query.max_age_seconds,
        }))
    }

    /// Forgets the selection of a deleted installation.
    pub fn retire(&self, installation: &str) {
        self.library.clear(installation);
        system_log::call("photos.retire", "ok");
    }
}

impl NativeModule for PhotosModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("photos.")
    }

    fn apis(&self) -> &[&'static str] {
        &["$photos"]
    }

    fn call(&self, request: &ExecutionRequest<'_>, operation: &str, _payload: Option<&str>) -> HostResult {
        let context = CallContext::from_request(request);
        let value = match operation {
            "photos.isAvailable" => if Self::permitted(&context) { "true" } else { "false" }.to_owned(),
            "photos.authorizationStatus" => quote(Self::authorization_status(&context)),
            _ => return Err(format!("Unsupported operation {operation}")),
        };
        system_log::call(operation, "ok");
        Ok(Some(value))
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>, done: Completion) {
        let context = CallContext::from_request(request);
        let module = self.clone();
        let payload = payload.cloned().unwrap_or_default();
        match operation {
            "photos.requestAuthorization" => run_system(operation, done, move || module.request_authorization(&context).map(|granted| granted.to_string())),
            "photos.items" => run_system(operation, done, move || module.items(&context, payload.opt_object("options"), payload.opt_bool("invalid", false)).map(|value| stringify(&value))),
            _ => done.complete(false, Some(quote(&format!("Unsupported operation {operation}")))),
        }
    }
}
