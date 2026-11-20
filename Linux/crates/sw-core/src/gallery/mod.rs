//! Gallery 1.0: the verified catalog of community widgets and Skills. A port
//! of `Android/core/src/main/java/com/everettjf/scriptwidget/core/gallery`
//! (itself a port of `Shared/ScriptWidgetRuntime/Gallery`); each module names
//! the Kotlin file it ports.
//!
//! What is trusted and what is not:
//! - The trust root is one fixed address, the curated index on
//!   `raw.githubusercontent.com` ([`GalleryRepository::DEFAULT_INDEX_URL`]).
//!   The index, every file and every redirect hop must be an HTTPS URL of
//!   exactly that host ([`validator::is_raw_github_url`]).
//! - The index is untrusted input all the same: it is decoded strictly and
//!   refused as a whole when any rule fails ([`validator::decode`]). An
//!   unknown key or an unsupported schema version fails closed.
//! - A download is accepted only when its status, final address, byte count
//!   and SHA-256 are exactly what the index states ([`GalleryInstaller`]).
//! - Verified files are still community content. A widget is installed
//!   through the hardened package store and runs only inside the engine with
//!   the permissions and hosts its manifest declares; a Skill is installed
//!   through the Skills store and is never more than prompt text.

pub(crate) mod files;
mod installations;
mod installer;
mod repository;
pub mod validator;

use std::fmt;

pub use installations::{GalleryInstallState, GalleryInstallationRegistry, GalleryInstalledRecord, semantic_version};
pub use installer::{GalleryInstaller, sha256, supports};
pub use repository::{FetchGalleryTransport, GalleryIndexCache, GalleryRepository, GalleryRequest, GalleryResponse, GallerySnapshot, GalleryTransport};

/// What a Gallery item installs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GalleryItemKind {
    Widget,
    Skill,
}

impl GalleryItemKind {
    pub const ALL: [GalleryItemKind; 2] = [GalleryItemKind::Widget, GalleryItemKind::Skill];

    /// The value of `kind` in the index.
    pub fn wire(self) -> &'static str {
        match self {
            Self::Widget => "widget",
            Self::Skill => "skill",
        }
    }

    /// The kind for an index value, or `None` for anything else (unknown kinds fail closed).
    pub fn from_wire(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.wire() == value)
    }
}

/// One downloadable file of a Gallery item. The index, not the server, is the
/// authority for `path`, `bytes` and `sha256`: a download is accepted only
/// when all three match exactly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryFile {
    pub path: String,
    pub url: String,
    pub sha256: String,
    pub bytes: i64,
}

/// One catalog entry of Gallery 1.0.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryItem {
    pub id: String,
    pub kind: GalleryItemKind,
    pub name: String,
    pub version: String,
    pub summary: String,
    pub symbol: String,
    pub author: String,
    pub license: String,
    pub tags: Vec<String>,
    /// Runtime contract version (`1.0`), not the package's minimum API version.
    pub minimum_runtime_version: String,
    pub source_url: String,
    pub featured: bool,
    pub files: Vec<GalleryFile>,
}

impl GalleryItem {
    /// Identity of the item's content: every path with its hash, sorted by
    /// path. A changed fingerprint at an unchanged version is still offered
    /// as an update, so a corrected artifact is never hidden.
    pub fn content_fingerprint(&self) -> String {
        let mut files: Vec<&GalleryFile> = self.files.iter().collect();
        files.sort_by(|left, right| left.path.cmp(&right.path));
        files.iter().map(|file| format!("{}:{}", file.path, file.sha256)).collect::<Vec<_>>().join("|")
    }

    /// Declared download size. Only meaningful for an item that passed validation.
    pub fn total_bytes(&self) -> i64 {
        self.files.iter().fold(0i64, |total, file| total.saturating_add(file.bytes.max(0)))
    }
}

/// A decoded Gallery 1.0 index. `generated_at` is milliseconds since the epoch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryIndex {
    pub schema_version: i32,
    pub generated_at: i64,
    pub repository: String,
    pub items: Vec<GalleryItem>,
}

impl GalleryIndex {
    /// `GalleryIndex.currentSchemaVersion`; any other schema is refused.
    pub const CURRENT_SCHEMA_VERSION: i32 = 1;
    /// `ScriptWidgetBuildContract.runtimeAPIVersion`: the only runtime contract Gallery 1.0 items may declare.
    pub const RUNTIME_CONTRACT_VERSION: &'static str = "1.0";
}

/// One reason an index or item was refused. `id` is stable (`<item>.<rule>`), `message` is for people.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryValidationIssue {
    pub id: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GalleryErrorKind {
    /// The index is oversized, malformed, has unknown fields, or breaks a validation rule.
    InvalidIndex,
    /// The request failed, was redirected off the trusted host, or returned an error status.
    Network,
    /// The network is unavailable and no previously validated index is cached.
    MissingCache,
    /// A downloaded file did not match its declared status, host, byte count or SHA-256.
    InvalidDownload,
    /// The verified files were refused by the widget or Skill installer.
    Install,
}

/// The single failure type of the Gallery layer (`GalleryError` in Swift).
/// Every failure is a refusal: nothing unverified is cached, shown as
/// verified, or installed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryError {
    pub kind: GalleryErrorKind,
    pub message: String,
}

impl GalleryError {
    pub fn new(kind: GalleryErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into() }
    }

    pub fn network(message: impl Into<String>) -> Self {
        Self::new(GalleryErrorKind::Network, message)
    }

    pub(crate) fn install(message: impl Into<String>) -> Self {
        Self::new(GalleryErrorKind::Install, message)
    }
}

impl fmt::Display for GalleryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for GalleryError {}
