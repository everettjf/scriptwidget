//! The user's Skills under `root/<slug>/`, the read-only built-ins and the
//! set of enabled Skills. A port of `SkillStore.kt` (`AIWidgetSkillManager`
//! in Swift).
//!
//! Security model: a Skill is two text files that are only ever read as data.
//! The store never executes, evaluates or loads anything from a Skill, and a
//! Skill cannot declare tools, hosts or runtime permissions: `skill.json` is
//! refused when it has a key outside the schema. Every Skill is validated
//! when it enters the store and again each time it is read, so a directory
//! that was altered on disk (extra file, link, oversized or malformed file)
//! is not listed.
//!
//! Installs are prepared in a hidden staging directory and published with one
//! atomic rename; a failed install or import leaves no Skill and no staging
//! files. Mutations are serialized per instance; use one instance per root.

use std::collections::BTreeSet;
use std::io::{self, Read};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use serde_json::Value;

use super::{Skill, SkillError, SkillManifest, built_ins, errors, validator};
use crate::gallery::files;
use crate::packages::archive;
use crate::packages::limits::ArchiveLimits;
use crate::packages::preflight::{self, Entry};
use crate::packages::safe_files;
use crate::plugins::files::write_archive;

const ENABLED_FILE: &str = ".enabled.json";
const MAX_ENABLED_BYTES: usize = 256 * 1024;
const MAX_DIRECTORY_ATTEMPTS: usize = 10_000;
/// The two files of a package, in byte order.
const PACKAGE_FILES: [&str; 2] = [SkillManifest::INSTRUCTION_FILE_NAME, SkillManifest::FILE_NAME];

/// Skill-sized archive limits: 256 KiB in total, 64 KiB per file, a handful of shallow entries.
fn archive_limits() -> ArchiveLimits {
    ArchiveLimits {
        maximum_archive_bytes: validator::MAX_PACKAGE_BYTES,
        maximum_expanded_bytes: validator::MAX_PACKAGE_BYTES as u64,
        maximum_file_bytes: validator::MAX_INSTRUCTION_BYTES as u64,
        maximum_file_count: 16,
        maximum_path_depth: 3,
    }
}

struct Stored {
    directory: PathBuf,
    skill: Skill,
    manifest: Vec<u8>,
    instruction: Vec<u8>,
}

#[derive(Debug)]
pub struct SkillStore {
    root: PathBuf,
    gate: Mutex<()>,
}

fn storage(message: &str) -> SkillError {
    SkillError::new(errors::STORAGE_UNAVAILABLE, message)
}

fn not_found() -> SkillError {
    SkillError::new(errors::NOT_FOUND, "Skill not found.")
}

fn is_built_in(id: &str) -> bool {
    built_ins().iter().any(|skill| skill.id == id)
}

impl SkillStore {
    pub fn new(root: impl AsRef<Path>) -> Self {
        Self { root: safe_files::root(root.as_ref()), gate: Mutex::new(()) }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        self.gate.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Built-in Skills that no installed Skill replaces, followed by
    /// installed Skills sorted by title. The order is deterministic, which
    /// keeps [`SkillStore::enabled_skills_prompt_text`] stable.
    pub fn list(&self) -> Vec<Skill> {
        let mut custom: Vec<Skill> = self.stored().into_iter().map(|stored| stored.skill).collect();
        custom.sort_by_cached_key(|skill| (skill.title.to_lowercase(), skill.id.clone()));
        let mut skills: Vec<Skill> = built_ins().iter().filter(|skill| !custom.iter().any(|installed| installed.id == skill.id)).cloned().collect();
        skills.append(&mut custom);
        skills
    }

    /// The Skill with `id`, installed or built-in, or `None`.
    pub fn find(&self, id: &str) -> Option<Skill> {
        self.list().into_iter().find(|skill| skill.id == id)
    }

    /// True when an installed (not built-in) Skill has `id`.
    pub fn is_installed(&self, id: &str) -> bool {
        self.stored().iter().any(|stored| stored.skill.id == id)
    }

    /// Validates and installs a Skill from the exact bytes of its two files.
    ///
    /// Both files must pass [`validator::load`]. An installed Skill with the
    /// same id is replaced in place when `replace_existing` is set and
    /// refused otherwise, so an import can never silently overwrite a Skill.
    /// The stored files are byte-for-byte the given ones.
    ///
    /// Fails with the validation code, `duplicate_skill` or `storage_unavailable`.
    pub fn install(&self, manifest: &[u8], instruction: &[u8], replace_existing: bool) -> Result<Skill, SkillError> {
        let _guard = self.lock();
        let skill = validator::load(manifest, instruction)?;
        let existing = self.stored().into_iter().find(|stored| stored.skill.id == skill.id);
        if !replace_existing && (existing.is_some() || is_built_in(&skill.id)) {
            return Err(SkillError::new(errors::DUPLICATE, format!("A skill with id {} is already installed.", skill.id)));
        }
        let staging = safe_files::child(&self.root, &format!(".staging-{}", safe_files::unique_token()));
        let backup = safe_files::child(&self.root, &format!(".backup-{}", safe_files::unique_token()));
        let saved = (|| -> io::Result<()> {
            // Private to the user, like every other directory of the data folder.
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&self.root)?;
            if !safe_files::real_directory(&self.root) {
                return Err(io::Error::other("Skills directory is a link"));
            }
            safe_files::create_private_directory(&staging)?;
            let opened = safe_files::open_directory(&staging)?;
            safe_files::write_new_at(&opened, SkillManifest::FILE_NAME, manifest)?;
            safe_files::write_new_at(&opened, SkillManifest::INSTRUCTION_FILE_NAME, instruction)?;
            match &existing {
                Some(existing) => {
                    std::fs::rename(&existing.directory, &backup)?;
                    safe_files::rename_without_replacing(&staging, &existing.directory).inspect_err(|_| {
                        // The Skill that was there stays.
                        let _ = std::fs::rename(&backup, &existing.directory);
                    })
                }
                None => safe_files::rename_without_replacing(&staging, &self.free_directory(&skill.title)?),
            }
        })();
        safe_files::delete_tree(&staging);
        safe_files::delete_tree(&backup);
        saved.map(|()| skill).map_err(|_| storage("The skill could not be saved."))
    }

    /// Deletes an installed Skill and forgets its enabled state. Built-in Skills cannot be deleted.
    ///
    /// Fails with `built_in_skill`, `skill_not_found` or `storage_unavailable`.
    pub fn delete(&self, id: &str) -> Result<(), SkillError> {
        let _guard = self.lock();
        let Some(target) = self.stored().into_iter().find(|stored| stored.skill.id == id) else {
            return Err(if is_built_in(id) { SkillError::new(errors::BUILT_IN, "Built-in skills cannot be deleted.") } else { not_found() });
        };
        // The directory first leaves its name with one rename, so the Skill disappears at once.
        let trash = safe_files::child(&self.root, &format!(".deleted-{}", safe_files::unique_token()));
        if std::fs::rename(&target.directory, &trash).is_err() {
            safe_files::delete_tree(&target.directory);
        }
        safe_files::delete_tree(&trash);
        if safe_files::occupied(&target.directory) {
            return Err(storage("The skill could not be deleted."));
        }
        if !is_built_in(id) {
            let mut enabled = self.read_enabled();
            enabled.remove(id);
            self.write_enabled(&enabled)?;
        }
        Ok(())
    }

    /// Ids the user enabled. Nothing is enabled by default, and an unreadable state file enables nothing.
    pub fn enabled_ids(&self) -> BTreeSet<String> {
        let _guard = self.lock();
        self.read_enabled()
    }

    pub fn is_enabled(&self, id: &str) -> bool {
        self.enabled_ids().contains(id)
    }

    /// Enables or disables a Skill for AI requests. Only an existing Skill can be enabled.
    ///
    /// Fails with `skill_not_found` or `storage_unavailable`.
    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), SkillError> {
        let _guard = self.lock();
        if enabled && !self.list().iter().any(|skill| skill.id == id) {
            return Err(not_found());
        }
        let mut current = self.read_enabled();
        if enabled {
            current.insert(id.to_owned());
        } else {
            current.remove(id);
        }
        self.write_enabled(&current)
    }

    /// Enabled Skills that still exist and validate, in [`SkillStore::list`] order.
    pub fn enabled_skills(&self) -> Vec<Skill> {
        let enabled = self.enabled_ids();
        self.list().into_iter().filter(|skill| enabled.contains(&skill.id)).collect()
    }

    /// The text appended to an AI prompt for the enabled Skills, or an empty
    /// string when none is enabled. Each Skill contributes its name, version
    /// and complete instructions, in [`SkillStore::list`] order
    /// (`AIWidgetSkills.augment` in Swift).
    ///
    /// This is the only way a Skill influences the app: as untrusted advice
    /// inside a prompt. It grants no tool, file, network or runtime permission.
    pub fn enabled_skills_prompt_text(&self) -> String {
        Self::prompt_text_of(&self.enabled_skills())
    }

    /// The Skills with `ids` that still exist and validate, in [`SkillStore::list`] order, whether enabled or not.
    pub fn skills_with(&self, ids: &[String]) -> Vec<Skill> {
        self.list().into_iter().filter(|skill| ids.contains(&skill.id)).collect()
    }

    /// The same text for the Skills with `ids`, whether enabled or not: a conversation names its
    /// own Skills. An id that no longer exists or no longer validates contributes nothing.
    pub fn prompt_text(&self, ids: &[String]) -> String {
        Self::prompt_text_of(&self.skills_with(ids))
    }

    /// The Skills a conversation's turn is sent with: the ones it names, or without a choice the enabled ones.
    pub fn skills_for(&self, chosen: Option<&[String]>) -> Vec<Skill> {
        match chosen {
            Some(ids) => self.skills_with(ids),
            None => self.enabled_skills(),
        }
    }

    fn prompt_text_of(selected: &[Skill]) -> String {
        if selected.is_empty() {
            return String::new();
        }
        let lines: Vec<String> = selected.iter().map(|skill| format!("- {} v{}:\n  {}", skill.title, skill.version, skill.instruction.replace('\n', "\n  "))).collect();
        format!("Apply these ScriptWidget skills:\n{}", lines.join("\n"))
    }

    /// `prompt` followed by [`SkillStore::enabled_skills_prompt_text`]; unchanged when no Skill is enabled.
    pub fn augment(&self, prompt: &str) -> String {
        let skills = self.enabled_skills_prompt_text();
        if skills.is_empty() { prompt.to_owned() } else { format!("{prompt}\n\n{skills}") }
    }

    /// Imports one Skill from a `.swskill`/ZIP archive without replacing anything.
    ///
    /// Hardening, each step failing closed: at most 256 KiB is read; the
    /// complete central directory is preflighted like a widget archive (no
    /// traversal, absolute path, backslash, colon, NUL, non-UTF-8 name,
    /// duplicate or case-colliding path, symbolic link or special file,
    /// encryption, unknown compression, or ZIP64/size inconsistency) with
    /// Skill-sized limits; apart from dot-files and `__MACOSX`, the archive
    /// must hold exactly `skill.json` and `SKILL.md`, at its root or inside
    /// one top-level directory; each file is inflated in memory with a hard
    /// byte bound and must match its declared size and CRC-32 (zip bomb
    /// guard); the content then passes [`SkillStore::install`]. No other
    /// archive entry is ever read, and nothing of the archive touches the disk.
    ///
    /// Fails with `too_large`, `invalid_archive`, `invalid_package`, or any [`SkillStore::install`] code.
    pub fn import_archive(&self, input: &mut dyn Read) -> Result<Skill, SkillError> {
        let mut archive_bytes = Vec::new();
        input.take(validator::MAX_PACKAGE_BYTES as u64 + 1).read_to_end(&mut archive_bytes).map_err(|_| SkillError::new(errors::INVALID_ARCHIVE, "The Skill archive could not be read."))?;
        if archive_bytes.len() > validator::MAX_PACKAGE_BYTES {
            return Err(SkillError::new(errors::TOO_LARGE, "A Skill package may not exceed 256 KiB."));
        }
        let entries = preflight::validate(&archive_bytes, &archive_limits()).map_err(|error| SkillError::new(errors::INVALID_ARCHIVE, format!("The Skill archive was rejected ({}).", error.code)))?;
        let visible: Vec<&Entry> = entries.iter().filter(|entry| entry.parts[0] != "__MACOSX" && !entry.parts.iter().any(|part| part.starts_with('.'))).collect();
        let package_files: Vec<&Entry> = visible.iter().copied().filter(|entry| !entry.is_directory).collect();
        let at_root = package_files.iter().any(|entry| entry.parts.len() == 1);
        let depth = if at_root { 1 } else { 2 };
        let prefix: &[String] = if at_root { &[] } else { package_files.first().map_or(&[], |entry| &entry.parts[..1]) };
        let mut names: Vec<&str> = package_files.iter().filter_map(|entry| entry.parts.last().map(String::as_str)).collect();
        names.sort_unstable();
        let well_formed = package_files.iter().all(|entry| entry.parts.len() == depth && entry.parts[..depth - 1] == *prefix)
            && visible.iter().filter(|entry| entry.is_directory).all(|entry| !at_root && entry.parts == prefix)
            && names == PACKAGE_FILES;
        if !well_formed {
            return Err(SkillError::new(errors::INVALID_PACKAGE, "Skills 1.0 allows only skill.json and SKILL.md."));
        }
        let read = |name: &str, limit: usize| -> Result<Vec<u8>, SkillError> {
            let corrupt = || SkillError::new(errors::INVALID_ARCHIVE, "The Skill archive is corrupt or does not match its declared sizes.");
            let entry = package_files.iter().find(|entry| entry.parts.last().is_some_and(|last| last == name)).ok_or_else(corrupt)?;
            if entry.uncompressed_size > limit as u64 {
                return Err(SkillError::new(errors::TOO_LARGE, format!("{name} exceeds its Skills 1.0 size limit.")));
            }
            archive::read_entry(&archive_bytes, entry, limit as u64).map_err(|_| corrupt())
        };
        let manifest = read(SkillManifest::FILE_NAME, validator::MAX_MANIFEST_BYTES)?;
        let instruction = read(SkillManifest::INSTRUCTION_FILE_NAME, validator::MAX_INSTRUCTION_BYTES)?;
        self.install(&manifest, &instruction, false)
    }

    /// Imports one Skill from a folder that holds its two files, without
    /// replacing anything. (Android has no such import; a folder is how a
    /// Skill is written on a desktop.)
    ///
    /// Apart from dot-files, the folder must hold exactly `skill.json` and
    /// `SKILL.md`, both regular files that are not links, spelled exactly so
    /// and within their size limits. The bytes then pass [`SkillStore::install`];
    /// the folder itself is only read.
    ///
    /// Fails with `invalid_package`, `too_large`, or any [`SkillStore::install`] code.
    pub fn import_directory(&self, directory: &Path) -> Result<Skill, SkillError> {
        let directory = safe_files::root(directory);
        let invalid = || SkillError::new(errors::INVALID_PACKAGE, "Skills 1.0 allows only skill.json and SKILL.md.");
        let mut children: Vec<String> = safe_files::names(&directory).filter(|listing| !listing.foreign).ok_or_else(invalid)?.names.into_iter().filter(|name| !name.starts_with('.')).collect();
        children.sort_unstable();
        if children != PACKAGE_FILES {
            return Err(invalid());
        }
        let read = |name: &str, limit: usize| -> Result<Vec<u8>, SkillError> {
            let file = safe_files::existing_file(&directory, &[name]).ok_or_else(|| SkillError::new(errors::INVALID_PACKAGE, format!("{name} must be a regular file that is not a link.")))?;
            safe_files::read_bounded(file, limit as u64).ok_or_else(|| SkillError::new(errors::TOO_LARGE, format!("{name} exceeds its Skills 1.0 size limit.")))
        };
        let manifest = read(SkillManifest::FILE_NAME, validator::MAX_MANIFEST_BYTES)?;
        let instruction = read(SkillManifest::INSTRUCTION_FILE_NAME, validator::MAX_INSTRUCTION_BYTES)?;
        self.install(&manifest, &instruction, false)
    }

    /// A Skill as a ZIP holding exactly `skill.json` and `SKILL.md` at its
    /// root. An installed Skill is exported byte-for-byte after
    /// re-validation; a built-in Skill gets a generated manifest.
    ///
    /// Fails with `skill_not_found`.
    pub fn export_archive(&self, id: &str) -> Result<Vec<u8>, SkillError> {
        let (manifest, instruction) = match self.stored().into_iter().find(|stored| stored.skill.id == id) {
            Some(custom) => (custom.manifest, custom.instruction),
            None => {
                let built_in = built_ins().iter().find(|skill| skill.id == id).ok_or_else(not_found)?;
                let manifest = SkillManifest {
                    format_version: SkillManifest::CURRENT_FORMAT_VERSION,
                    id: built_in.id.clone(),
                    name: built_in.title.clone(),
                    version: built_in.version.clone(),
                    summary: built_in.summary.clone(),
                    symbol: built_in.symbol.clone(),
                    prompt_file: SkillManifest::INSTRUCTION_FILE_NAME.into(),
                    tags: built_in.tags.clone(),
                    author: built_in.author.clone(),
                    minimum_runtime_version: built_in.minimum_runtime_version.clone(),
                };
                (manifest.encode(), built_in.instruction.clone().into_bytes())
            }
        };
        write_archive(&[(SkillManifest::FILE_NAME, manifest.as_slice()), (SkillManifest::INSTRUCTION_FILE_NAME, instruction.as_slice())]).map_err(|_| storage("The skill could not be exported."))
    }

    /// Installed Skills that are intact. A Skill directory must be a real
    /// directory (not a link) whose visible entries are exactly the two
    /// regular, singly linked files, each within its size limit and passing
    /// validation. When two directories claim one id, the first by directory
    /// name wins.
    fn stored(&self) -> Vec<Stored> {
        if !safe_files::real_directory(&self.root) {
            return Vec::new();
        }
        let mut names: Vec<String> = safe_files::names(&self.root).map(|listing| listing.names).unwrap_or_default().into_iter().filter(|name| !name.starts_with('.')).collect();
        names.sort_unstable();
        let mut result: Vec<Stored> = Vec::new();
        for name in names {
            let directory = safe_files::child(&self.root, &name);
            if let Some(stored) = read(directory).filter(|stored| !result.iter().any(|known| known.skill.id == stored.skill.id)) {
                result.push(stored);
            }
        }
        result
    }

    fn free_directory(&self, preferred_name: &str) -> io::Result<PathBuf> {
        let base = validator::slug(preferred_name);
        let taken: Vec<String> = safe_files::names(&self.root).map(|listing| listing.names).unwrap_or_default().iter().map(|name| name.to_lowercase()).collect();
        std::iter::once(base.clone())
            .chain((2..=MAX_DIRECTORY_ATTEMPTS).map(|index| format!("{base}-{index}")))
            .find(|candidate| !taken.contains(candidate))
            .map(|name| safe_files::child(&self.root, &name))
            .ok_or_else(|| io::Error::other("No free Skill directory name"))
    }

    fn read_enabled(&self) -> BTreeSet<String> {
        let text = files::read_private(&self.root, ENABLED_FILE, MAX_ENABLED_BYTES).and_then(|bytes| String::from_utf8(bytes).ok());
        let Some(Ok(Value::Array(items))) = text.map(|text| crate::plugins::strict_json::parse(&text, false)) else { return BTreeSet::new() };
        // One entry that is not text makes the whole file unreadable.
        items.iter().map(|item| item.as_str().map(str::to_owned)).collect::<Option<BTreeSet<String>>>().unwrap_or_default()
    }

    fn write_enabled(&self, ids: &BTreeSet<String>) -> Result<(), SkillError> {
        let text = crate::json::stringify(&Value::Array(ids.iter().map(|id| Value::String(id.clone())).collect()));
        files::write_atomically(&safe_files::child(&self.root, ENABLED_FILE), text.as_bytes()).map_err(|_| storage("The enabled skills could not be saved."))
    }
}

fn read(directory: PathBuf) -> Option<Stored> {
    if !safe_files::real_directory(&directory) {
        return None;
    }
    let mut children: Vec<String> = safe_files::names(&directory)?.names.into_iter().filter(|name| !name.starts_with('.')).collect();
    children.sort_unstable();
    if children != PACKAGE_FILES {
        return None;
    }
    let manifest = files::read_private(&directory, SkillManifest::FILE_NAME, validator::MAX_MANIFEST_BYTES)?;
    let instruction = files::read_private(&directory, SkillManifest::INSTRUCTION_FILE_NAME, validator::MAX_INSTRUCTION_BYTES)?;
    let skill = validator::load(&manifest, &instruction).ok()?;
    Some(Stored { directory, skill, manifest, instruction })
}
