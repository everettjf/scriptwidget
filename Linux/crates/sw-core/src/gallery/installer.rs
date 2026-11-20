//! Downloads, verifies and installs Gallery items. A port of
//! `GalleryInstaller.kt` (`GalleryInstaller` in Swift).

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use sha2::{Digest, Sha256};

use super::files;
use super::repository::{GalleryRepository, GalleryRequest, GalleryTransport, system_clock};
use super::validator;
use super::{GalleryError, GalleryErrorKind, GalleryFile, GalleryInstallState, GalleryInstallationRegistry, GalleryInstalledRecord, GalleryItem, GalleryItemKind};
use crate::json::Object;
use crate::package_files::PackageFiles;
use crate::packages::{PackageError, PackageInfo, PackageStore, codes, manifests, path_rules, safe_files};
use crate::plugins::files::write_archive;
use crate::skills::{SkillManifest, SkillStore, validator as skill_validator};

/// An additional check of a staged widget before it is published; an error refuses the install with its sentence.
pub type WidgetValidator<'a> = &'a dyn Fn(&dyn PackageFiles) -> Result<(), String>;

const DOWNLOAD_TIMEOUT_MILLISECONDS: u64 = 30_000;
const ARCHIVE_ROOT: &str = "package";
const MAX_CARRIED_BYTES: u64 = 4096;

/// One install at a time in this process, whichever installer value runs it.
static INSTALLING: Mutex<()> = Mutex::new(());

/// Downloads, verifies and installs Gallery items.
///
/// Remote files are data. An item is installed only after every one of these
/// holds, and any failure leaves no package, no Skill and no temporary file
/// behind:
///
/// 1. The item passes [`validator::validate_item`] again (trusted URLs, safe
///    paths, sizes).
/// 2. Every listed file is downloaded into a unique temporary directory, and
///    each response is HTTP 200 from a URL that still passes
///    [`validator::is_raw_github_url`], with exactly the declared byte count
///    and SHA-256.
/// 3. The downloaded manifest names the same id and version as the index entry.
/// 4. A widget is installed through [`PackageStore::import_archive`], which
///    stages it, re-checks the tree (paths, links, limits) and publishes it
///    with one atomic rename; a Skill is installed through
///    [`SkillStore::install`], which enforces Skills 1.0.
///
/// Hashes detect corrupted or substituted downloads; they do not make
/// community code trustworthy. Installed widgets run only within the runtime
/// and their declared permissions.
pub struct GalleryInstaller<'a> {
    transport: &'a dyn GalleryTransport,
    registry: &'a GalleryInstallationRegistry,
    packages: &'a PackageStore,
    skills: &'a SkillStore,
    temporary_root: PathBuf,
    runtime_api_version: Option<String>,
    widget_validator: Option<WidgetValidator<'a>>,
    carried_files: Vec<String>,
    now: fn() -> i64,
}

impl<'a> GalleryInstaller<'a> {
    /// `temporary_root` is a private directory for downloads; a unique child is created per install.
    pub fn new(transport: &'a dyn GalleryTransport, registry: &'a GalleryInstallationRegistry, packages: &'a PackageStore, skills: &'a SkillStore, temporary_root: impl AsRef<Path>) -> Self {
        Self { transport, registry, packages, skills, temporary_root: safe_files::root(temporary_root.as_ref()), runtime_api_version: None, widget_validator: None, carried_files: Vec::new(), now: system_clock }
    }

    /// The runtime API version this program implements (for example `1.6`).
    /// When set, a widget whose `widget.json` requires a newer or incompatible API is refused.
    pub fn runtime_api_version(mut self, version: Option<&str>) -> Self {
        self.runtime_api_version = version.map(str::to_owned);
        self
    }

    /// Additional Package 2.0 validation run on the staged widget before it is published.
    pub fn widget_validator(mut self, validator: WidgetValidator<'a>) -> Self {
        self.widget_validator = Some(validator);
        self
    }

    /// Root-level bookkeeping files (single names) copied from the replaced
    /// package to its update, so an update keeps the identity of the installation.
    pub fn carried_files(mut self, names: &[&str]) -> Self {
        self.carried_files = names.iter().map(|name| (*name).to_owned()).collect();
        self
    }

    /// Install state of `item`. A registry record counts only while the thing
    /// it names is still installed and still is that item: the widget package
    /// must exist under the recorded name with the item's id in its manifest,
    /// and the Skill must exist with the item's id. A record pointing at some
    /// other package therefore never marks it as installed or updatable.
    pub fn state(&self, item: &GalleryItem) -> GalleryInstallState {
        let Some(record) = self.registry.record(&item.id) else { return GalleryInstallState::NotInstalled };
        let present = match record.kind {
            GalleryItemKind::Widget => self.installed_widget(item, &record).is_some(),
            GalleryItemKind::Skill => self.skills.is_installed(&item.id),
        };
        if present && record.kind == item.kind { self.registry.state(item) } else { GalleryInstallState::NotInstalled }
    }

    /// Installs or updates `item` and returns its record. Blocking: call it
    /// off the window's thread.
    ///
    /// An update replaces the package or Skill that the earlier install
    /// created and keeps its local name; a first install of a widget gets a
    /// free package name derived from the manifest's `name`.
    ///
    /// Fails with [`GalleryErrorKind::Install`], [`GalleryErrorKind::InvalidDownload`]
    /// or [`GalleryErrorKind::Network`]. A failed first install leaves nothing
    /// behind; a failed update leaves the previously installed version in place.
    pub fn install(&self, item: &GalleryItem) -> Result<GalleryInstalledRecord, GalleryError> {
        let _one_at_a_time = INSTALLING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        require_valid(item)?;
        let prepared = self.download(item)?;
        let installed = self.install_prepared(item, &prepared);
        safe_files::delete_tree(&prepared);
        installed
    }

    fn install_prepared(&self, item: &GalleryItem, prepared: &Path) -> Result<GalleryInstalledRecord, GalleryError> {
        let existing = self.registry.record(&item.id);
        let (local_identifier, fresh) = match item.kind {
            GalleryItemKind::Widget => {
                let target = existing.as_ref().and_then(|record| self.installed_widget(item, record));
                (self.install_widget(item, prepared, target.as_ref())?, target.is_none())
            }
            GalleryItemKind::Skill => {
                let fresh = !self.skills.is_installed(&item.id);
                (self.install_skill(item, prepared)?, fresh)
            }
        };
        let record = GalleryInstalledRecord { item_id: item.id.clone(), kind: item.kind, version: item.version.clone(), local_identifier, content_fingerprint: item.content_fingerprint(), installed_at: (self.now)() };
        if self.registry.save(&record).is_err() {
            // Without a record the item could not be updated later; undo a first install.
            if fresh {
                match item.kind {
                    GalleryItemKind::Widget => drop(self.packages.delete(&record.local_identifier)),
                    GalleryItemKind::Skill => drop(self.skills.delete(&item.id)),
                }
            }
            return Err(GalleryError::install("The Gallery installation could not be recorded."));
        }
        Ok(record)
    }

    /// Downloads one listed file of `item` and returns it only if it matches
    /// the index (status, final host, byte count, SHA-256). Used to show a
    /// widget's manifest before installing.
    pub fn download_verified(&self, item: &GalleryItem, path: &str) -> Result<Vec<u8>, GalleryError> {
        require_valid(item)?;
        let file = item.files.iter().find(|file| file.path == path).ok_or_else(|| GalleryError::install(format!("{} does not list {path}.", item.id)))?;
        self.fetch_verified(file)
    }

    fn fetch_verified(&self, file: &GalleryFile) -> Result<Vec<u8>, GalleryError> {
        let request = GalleryRequest { url: file.url.clone(), headers: vec![("User-Agent".to_owned(), GalleryRepository::USER_AGENT.to_owned())], timeout_milliseconds: DOWNLOAD_TIMEOUT_MILLISECONDS };
        let response = self.transport.fetch(&request)?;
        let verified = response.status == 200 && validator::is_raw_github_url(&response.final_url) && i64::try_from(response.body.len()).is_ok_and(|length| length == file.bytes) && sha256(&response.body) == file.sha256;
        if !verified {
            return Err(GalleryError::new(GalleryErrorKind::InvalidDownload, format!("Downloaded file failed status, host, size, or SHA-256 validation: {}", file.path)));
        }
        Ok(response.body)
    }

    /// Downloads every file into a fresh directory; on any failure the directory is removed.
    fn download(&self, item: &GalleryItem) -> Result<PathBuf, GalleryError> {
        let root = safe_files::new_work_directory(&self.temporary_root, "GalleryInstall").map_err(|_| GalleryError::install("The download directory is unavailable."))?;
        let stored = (|| -> Result<(), GalleryError> {
            let unusable = |_: std::io::Error| GalleryError::install("A downloaded file could not be stored.");
            let opened = safe_files::open_directory(&root).map_err(unusable)?;
            for file in &item.files {
                let data = self.fetch_verified(file)?;
                // The validator already refused traversal; the write is relative to the open
                // directory, one checked component at a time, and never through a link.
                let parts = Some(file.path.split('/').collect::<Vec<_>>()).filter(|parts| validator::is_safe_relative_path(&file.path) && parts.iter().all(|part| path_rules::valid_component(part)));
                let Some((name, directories)) = parts.as_deref().and_then(<[&str]>::split_last) else {
                    return Err(GalleryError::new(GalleryErrorKind::InvalidDownload, format!("{} contains unsafe path {}.", item.id, file.path)));
                };
                let mut directory = None;
                for part in directories {
                    directory = Some(safe_files::create_directory_at(directory.as_ref().unwrap_or(&opened), part).map_err(unusable)?);
                }
                safe_files::write_new_at(directory.as_ref().unwrap_or(&opened), name, &data).map_err(unusable)?;
            }
            Ok(())
        })();
        match stored {
            Ok(()) => Ok(root),
            Err(error) => {
                safe_files::delete_tree(&root);
                Err(error)
            }
        }
    }

    /// The package an earlier install of `item` created, if it is still that item.
    fn installed_widget(&self, item: &GalleryItem, record: &GalleryInstalledRecord) -> Option<PackageInfo> {
        if record.kind != GalleryItemKind::Widget {
            return None;
        }
        self.packages.list().ok()?.into_iter().find(|info| info.name == record.local_identifier && info.manifest_id.as_deref() == Some(item.id.as_str()))
    }

    fn install_widget(&self, item: &GalleryItem, source: &Path, target: Option<&PackageInfo>) -> Result<String, GalleryError> {
        // The package store never installs dot-files or __Build; an item listing one cannot be installed completely.
        if let Some(file) = item.files.iter().find(|file| path_rules::visible_components(&file.path).is_none()) {
            return Err(GalleryError::install(format!("Widget {} lists a path that cannot be installed: {}", item.id, file.path)));
        }
        let unprepared = || GalleryError::install("The downloaded widget could not be prepared.");
        let mut contents: Vec<(String, Vec<u8>)> = Vec::new();
        for file in &item.files {
            let parts: Vec<&str> = file.path.split('/').collect();
            let bytes = safe_files::existing_file(source, &parts).and_then(|opened| safe_files::read_bounded(opened, validator::MAX_FILE_BYTES as u64)).ok_or_else(unprepared)?;
            contents.push((format!("{ARCHIVE_ROOT}/{}", file.path), bytes));
        }
        let entries: Vec<(&str, &[u8])> = contents.iter().map(|(name, bytes)| (name.as_str(), bytes.as_slice())).collect();
        let archive = write_archive(&entries).map_err(|_| unprepared())?;

        let expected: BTreeSet<&str> = item.files.iter().map(|file| file.path.as_str()).collect();
        // What this layer or the injected validator said, in its own words.
        let refusal: RefCell<Option<GalleryError>> = RefCell::new(None);
        let validate = |staged: &dyn PackageFiles| -> Result<(), PackageError> {
            let checked = (|| -> Result<(), GalleryError> {
                let manifest = staged.read_text(manifests::FILE_NAME).and_then(|text| files::parse_object(&text));
                let text = |key: &str| manifest.as_ref().and_then(|manifest| manifest.get(key)).and_then(serde_json::Value::as_str);
                let Some(manifest) = manifest.as_ref().filter(|_| text("id") == Some(item.id.as_str()) && text("version") == Some(item.version.as_str())) else {
                    return Err(GalleryError::install("Downloaded widget identity or version does not match the Gallery index."));
                };
                self.require_runtime(item, manifest)?;
                let staged_paths = staged.paths();
                if staged_paths.iter().map(String::as_str).collect::<BTreeSet<&str>>() != expected {
                    return Err(GalleryError::install("The downloaded widget could not be staged completely."));
                }
                self.widget_validator.map_or(Ok(()), |validator| validator(staged).map_err(GalleryError::install))
            })();
            checked.map_err(|error| {
                let refused = PackageError::new(codes::INVALID_MANIFEST, error.message.clone());
                *refusal.borrow_mut() = Some(error);
                refused
            })
        };
        let imported = self.packages.import_archive(&mut archive.as_slice(), None, Some(&validate)).map_err(|error| refusal.take().unwrap_or_else(|| GalleryError::install(if error.message.is_empty() { "The widget package was rejected.".to_owned() } else { error.message })))?;
        let Some(target) = target.filter(|target| target.name != imported.name) else { return Ok(imported.name) };

        // Update: the verified package is already installed under a temporary name. Swap it in.
        self.carry(&target.directory, &imported.directory);
        if self.packages.delete(&target.name).is_err() {
            let _ = self.packages.delete(&imported.name);
            return Err(GalleryError::install("The installed widget could not be replaced."));
        }
        Ok(self.packages.rename(&imported.name, &target.name).map_or(imported.name, |renamed| renamed.name))
    }

    /// Refuses a widget this program cannot run: its `runtimeVersion` must be
    /// the contract version of the index entry, and its minimum API
    /// (`minimumRuntimeVersion`, else `runtimeVersion`) must have the same
    /// major and a minor not above the API this program implements
    /// (`WidgetRuntimeRequirement.supports`). A cached index does not bypass this.
    fn require_runtime(&self, item: &GalleryItem, manifest: &Object) -> Result<(), GalleryError> {
        let contract = manifest.get("runtimeVersion").and_then(serde_json::Value::as_str);
        if contract != Some(item.minimum_runtime_version.as_str()) {
            return Err(GalleryError::install(format!("{} requires unsupported runtime {}.", item.id, contract.unwrap_or("(missing)"))));
        }
        let Some(supported) = self.runtime_api_version.as_deref() else { return Ok(()) };
        let requirement = match manifest.get("minimumRuntimeVersion") {
            Some(value) => value.as_str(),
            None => contract,
        };
        if !requirement.is_some_and(|requirement| supports(requirement, supported)) {
            return Err(GalleryError::install(format!("{} requires Runtime API {}, but this app supports {supported}. Update ScriptWidget to install it.", item.name, requirement.unwrap_or("(invalid)"))));
        }
        Ok(())
    }

    fn install_skill(&self, item: &GalleryItem, source: &Path) -> Result<String, GalleryError> {
        let manifest = files::read_private(source, SkillManifest::FILE_NAME, skill_validator::MAX_MANIFEST_BYTES);
        let instruction = files::read_private(source, SkillManifest::INSTRUCTION_FILE_NAME, skill_validator::MAX_INSTRUCTION_BYTES);
        let (Some(manifest), Some(instruction)) = (manifest, instruction) else { return Err(GalleryError::install(format!("Skill {} exceeds the Skills 1.0 size limits.", item.id))) };
        let refused = |error: crate::skills::SkillError| GalleryError::install(if error.message.is_empty() { "The skill was rejected.".to_owned() } else { error.message });
        let skill = skill_validator::load(&manifest, &instruction).map_err(refused)?;
        if skill.id != item.id || skill.version != item.version {
            return Err(GalleryError::install("Downloaded skill identity or version does not match the Gallery index."));
        }
        self.skills.install(&manifest, &instruction, true).map_err(refused)?;
        Ok(item.id.clone())
    }

    /// Copies small regular bookkeeping files; links, directories and large files are skipped.
    fn carry(&self, from: &Path, to: &Path) {
        for name in &self.carried_files {
            if name.is_empty() || name.contains(['/', '\\']) || name == "." || name == ".." {
                continue;
            }
            let Some(bytes) = safe_files::existing_file(from, &[name.as_str()]).and_then(|file| safe_files::read_bounded(file, MAX_CARRIED_BYTES)) else { continue };
            // The update is still valid without the bookkeeping file.
            let _ = safe_files::open_directory(to).and_then(|directory| safe_files::write_new_at(&directory, name, &bytes));
        }
    }
}

fn require_valid(item: &GalleryItem) -> Result<(), GalleryError> {
    let issues = validator::validate_item(item);
    if issues.is_empty() { Ok(()) } else { Err(GalleryError::install(issues.iter().map(|issue| issue.message.as_str()).collect::<Vec<_>>().join("\n"))) }
}

/// Lowercase hexadecimal SHA-256 of `data`.
pub fn sha256(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// True when a program implementing API `current` can run a package requiring
/// `minimum`: both are `major.minor`, the majors are equal and the required
/// minor is not newer. Anything unparseable is unsupported.
pub fn supports(minimum: &str, current: &str) -> bool {
    // `^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$`
    fn parse(text: &str) -> Option<(u32, u32)> {
        let number = |part: &str| ((1..=3).contains(&part.len()) && part.bytes().all(|byte| byte.is_ascii_digit()) && (part == "0" || !part.starts_with('0'))).then(|| part.parse().ok()).flatten();
        let (major, minor) = text.split_once('.')?;
        Some((number(major)?, number(minor)?))
    }
    matches!((parse(minimum), parse(current)), (Some(requested), Some(supported)) if requested.0 == supported.0 && requested.1 <= supported.1)
}
