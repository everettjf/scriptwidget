//! Installed Data Source Plugins. Ported from
//! `Windows/src/ScriptWidget.Core/Plugins/PluginStore.cs`, itself a port of
//! `DataSourcePluginManager`.
//!
//! Each plugin is a directory below the root holding `plugin.json` and an
//! optional `README.md`, nothing else. Imported files are untrusted: they are
//! bounded, validated completely before anything is written, staged in a
//! private directory and published with one rename, so a failed import leaves
//! nothing behind and readers never see a partial plugin.

use std::io::Read;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use crate::plugins::files::{self, ArchiveEntry};
use crate::plugins::manifest::{self, PluginError, PluginErrorKind, PluginManifest, PluginOperation, PluginParameter, PluginParameterLocation, PluginResponseType};

/// A plugin the store can serve. Built-in plugins ship with the app and have no directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledPlugin {
    pub manifest: PluginManifest,
    pub built_in: bool,
    pub readme: Option<String>,
}

/// `DataSourcePluginManager.maximumPackageBytes`: the largest archive or manifest accepted for import.
pub const MAXIMUM_PACKAGE_BYTES: usize = 512 * 1024;
/// Largest `README.md` stored or shown (Swift bounds it only by the archive limits).
pub const MAXIMUM_README_BYTES: usize = 512 * 1024;
pub const MANIFEST_FILE: &str = "plugin.json";
pub const README_FILE: &str = "README.md";
const STAGING_DIRECTORY: &str = ".staging";
const NOT_A_PACKAGE: &str = "Archive must contain one Data Source Plugin 1.0 package.";

/// The plugins every ScriptWidget build ships, identical to `DataSourcePluginManager.builtIns`.
pub fn built_ins() -> &'static [PluginManifest] {
    static BUILT_INS: OnceLock<Vec<PluginManifest>> = OnceLock::new();
    BUILT_INS.get_or_init(|| {
        let parameter = |id: &str, label: &str, location, required, default_value: &str| PluginParameter { id: id.into(), label: label.into(), location, required, default_value: Some(default_value.into()) };
        let plugin = |id: &str, name: &str, summary: &str, symbol: &str, author: &str, license: &str, host: &str, operation: PluginOperation| PluginManifest {
            format_version: 1,
            id: id.into(),
            name: name.into(),
            version: "1.0.0".into(),
            summary: summary.into(),
            symbol: symbol.into(),
            author: author.into(),
            license: license.into(),
            minimum_runtime_version: "1.0".into(),
            base_url: format!("https://{host}"),
            hosts: vec![host.into()],
            operations: vec![operation],
        };
        vec![
            plugin(
                "app.scriptwidget.datasource.open-meteo",
                "Open-Meteo",
                "Weather forecasts without an API key.",
                "cloud.sun",
                "Open-Meteo",
                "CC BY 4.0",
                "api.open-meteo.com",
                PluginOperation {
                    id: "forecast".into(),
                    title: "Forecast".into(),
                    method: "GET".into(),
                    path: "/v1/forecast".into(),
                    response_type: PluginResponseType::Json,
                    parameters: vec![
                        parameter("latitude", "Latitude", PluginParameterLocation::Query, true, "37.7749"),
                        parameter("longitude", "Longitude", PluginParameterLocation::Query, true, "-122.4194"),
                        parameter("current", "Current fields", PluginParameterLocation::Query, false, "temperature_2m,weather_code"),
                        parameter("timezone", "Timezone", PluginParameterLocation::Query, false, "auto"),
                    ],
                },
            ),
            plugin(
                "app.scriptwidget.datasource.github",
                "GitHub Public API",
                "Public repository metadata from GitHub.",
                "chevron.left.forwardslash.chevron.right",
                "GitHub",
                "API Terms",
                "api.github.com",
                PluginOperation {
                    id: "repository".into(),
                    title: "Repository".into(),
                    method: "GET".into(),
                    path: "/repos/{owner}/{repo}".into(),
                    response_type: PluginResponseType::Json,
                    parameters: vec![parameter("owner", "Owner", PluginParameterLocation::Path, true, "everettjf"), parameter("repo", "Repository", PluginParameterLocation::Path, true, "scriptwidget")],
                },
            ),
        ]
    })
}

pub struct PluginStore {
    root: PathBuf,
    staging: PathBuf,
    gate: Mutex<()>,
}

fn invalid(message: &str) -> PluginError {
    PluginError::invalid(message)
}

fn storage(message: &str) -> PluginError {
    PluginError::new(PluginErrorKind::Storage, message)
}

impl PluginStore {
    pub fn new(root: impl AsRef<Path>) -> Self {
        let root = std::path::absolute(root.as_ref()).unwrap_or_else(|_| root.as_ref().to_owned());
        Self { staging: root.join(STAGING_DIRECTORY), root, gate: Mutex::new(()) }
    }

    /// Built-in plugins not replaced by an installed one, plus installed plugins, sorted by name.
    pub fn list(&self) -> Vec<InstalledPlugin> {
        let mut custom: Vec<InstalledPlugin> = Vec::new();
        for directory in self.directories() {
            if let Some(manifest) = load(&directory).filter(|manifest| !custom.iter().any(|known| known.manifest.id == manifest.id)) {
                custom.push(InstalledPlugin { manifest, built_in: false, readme: read_text(&directory, README_FILE, MAXIMUM_README_BYTES) });
            }
        }
        let mut plugins: Vec<InstalledPlugin> = built_ins()
            .iter()
            .filter(|manifest| !custom.iter().any(|known| known.manifest.id == manifest.id))
            .map(|manifest| InstalledPlugin { manifest: manifest.clone(), built_in: true, readme: Some(built_in_readme(manifest)) })
            .collect();
        plugins.append(&mut custom);
        plugins.sort_by_cached_key(|plugin| plugin.manifest.name.to_uppercase());
        plugins
    }

    /// The validated manifest for `id`, or `None`. A stored manifest is
    /// validated again on every read, so a file altered on disk after import
    /// is never used unless it still passes.
    pub fn manifest(&self, id: &str) -> Option<PluginManifest> {
        self.directories().iter().filter_map(|directory| load(directory)).find(|manifest| manifest.id == id).or_else(|| built_ins().iter().find(|manifest| manifest.id == id).cloned())
    }

    /// Installs a plugin from a `.swplugin` ZIP archive or a bare `plugin.json`.
    ///
    /// Security rules, each failing closed:
    /// - at most 512 KiB of input;
    /// - an archive passes the archive preflight (no traversal, absolute
    ///   paths, backslashes, symlinks, encrypted entries, case collisions or
    ///   forged directories);
    /// - the package root (archive root or its single directory) holds only
    ///   `plugin.json` and an optional `README.md`, both regular files: a
    ///   plugin cannot carry code or other payloads;
    /// - entries are inflated with their real sizes counted, never trusting
    ///   declared sizes, and their CRC-32 checked; `plugin.json` is at most
    ///   256 KiB and `README.md` 512 KiB of UTF-8;
    /// - the manifest passes [`manifest::decode`];
    /// - an id that is already installed or built in is refused rather than replaced.
    pub fn install(&self, input: &mut dyn Read) -> Result<PluginManifest, PluginError> {
        let bytes = read_input(input)?;
        let (manifest_bytes, readme) = if is_zip(&bytes) { unpack(&bytes)? } else { (bytes, None) };
        let manifest = manifest::decode(&manifest_bytes)?;
        let _guard = self.gate.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.manifest(&manifest.id).is_some() {
            return Err(invalid(&format!("Plugin {} is already installed.", manifest.id)));
        }
        let work = self.work_directory("install")?;
        let installed = (|| -> Result<(), PluginError> {
            let failed = |_: std::io::Error| storage("The plugin could not be installed.");
            let prepared = work.join("plugin");
            files::create_private_directory(&prepared).map_err(failed)?;
            files::write_new(&prepared.join(MANIFEST_FILE), &manifest_bytes).map_err(failed)?;
            if let Some(readme) = &readme {
                files::write_new(&prepared.join(README_FILE), readme).map_err(failed)?;
            }
            files::publish(&prepared, &self.unique_directory(&manifest.name)).map_err(|error| storage(&error.0))
        })();
        files::delete_tree(&work);
        installed.map(|()| manifest)
    }

    /// Removes the installed plugin `id`. The directory is first renamed out
    /// of the store, so the plugin disappears atomically. Built-in plugins
    /// cannot be deleted.
    pub fn delete(&self, id: &str) -> Result<(), PluginError> {
        let _guard = self.gate.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(directory) = self.directory_of(id) else {
            let built_in = built_ins().iter().any(|manifest| manifest.id == id);
            return Err(PluginError::new(PluginErrorKind::NotFound, if built_in { "Built-in plugins cannot be deleted." } else { "Plugin not found." }));
        };
        let work = self.work_directory("delete")?;
        let moved = std::fs::rename(&directory, work.join("plugin")).map_err(|_| storage("The plugin could not be deleted."));
        files::delete_tree(&work);
        moved
    }

    /// Plugin `id` as a `.swplugin` ZIP with `plugin.json` and, when present,
    /// `README.md` at the archive root. Only those two files are ever
    /// exported, so nothing else placed in the plugin directory can leak.
    pub fn export(&self, id: &str) -> Result<Vec<u8>, PluginError> {
        let not_found = || PluginError::new(PluginErrorKind::NotFound, "Plugin not found.");
        let mut contents: Vec<(&str, Vec<u8>)> = Vec::new();
        match self.directory_of(id) {
            Some(directory) => {
                contents.push((MANIFEST_FILE, read_bytes(&directory, MANIFEST_FILE, manifest::MAXIMUM_MANIFEST_BYTES).ok_or_else(not_found)?));
                if let Some(readme) = read_bytes(&directory, README_FILE, MAXIMUM_README_BYTES) {
                    contents.push((README_FILE, readme));
                }
            }
            None => {
                let built_in = built_ins().iter().find(|manifest| manifest.id == id).ok_or_else(not_found)?;
                contents.push((MANIFEST_FILE, built_in.to_json().into_bytes()));
                contents.push((README_FILE, built_in_readme(built_in).into_bytes()));
            }
        }
        let entries: Vec<(&str, &[u8])> = contents.iter().map(|(name, bytes)| (*name, bytes.as_slice())).collect();
        files::write_archive(&entries).map_err(|_| storage("Could not create the .swplugin archive."))
    }

    // MARK: - Storage

    /// Plugin directories: real directories (never links) whose names are not hidden.
    fn directories(&self) -> Vec<PathBuf> {
        if !files::real_directory(&self.root) {
            return Vec::new();
        }
        let mut names: Vec<String> = files::names(&self.root).unwrap_or_default().into_iter().filter(|name| !name.starts_with('.')).collect();
        names.sort_unstable();
        names.iter().map(|name| self.root.join(name)).filter(|path| files::real_directory(path)).collect()
    }

    fn directory_of(&self, id: &str) -> Option<PathBuf> {
        self.directories().into_iter().find(|directory| load(directory).is_some_and(|manifest| manifest.id == id))
    }

    fn work_directory(&self, prefix: &str) -> Result<PathBuf, PluginError> {
        let unavailable = || storage("The plugin directory is unavailable.");
        // Private to the user, like every other directory of the data folder.
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&self.root).map_err(|_| unavailable())?;
        if !files::real_directory(&self.root) {
            return Err(unavailable());
        }
        files::new_work_directory(&self.staging, prefix).map_err(|_| unavailable())
    }

    /// Directory names are derived from the plugin name but reduced to `[a-z0-9-]`, so they cannot traverse.
    fn unique_directory(&self, name: &str) -> PathBuf {
        let mut slug = String::new();
        for character in name.to_lowercase().chars() {
            if character.is_ascii_lowercase() || character.is_ascii_digit() {
                slug.push(character);
            } else if !slug.is_empty() && !slug.ends_with('-') {
                slug.push('-');
            }
        }
        let slug = slug.trim_end_matches('-');
        let base = if slug.is_empty() { "plugin" } else { slug };
        let mut path = self.root.join(base);
        let mut index = 2;
        while files::occupied(&path) {
            path = self.root.join(format!("{base}-{index}"));
            index += 1;
        }
        path
    }
}

// MARK: - Import

fn read_input(input: &mut dyn Read) -> Result<Vec<u8>, PluginError> {
    let mut bytes = Vec::new();
    input.take(MAXIMUM_PACKAGE_BYTES as u64 + 1).read_to_end(&mut bytes).map_err(|_| storage("The plugin file could not be read."))?;
    if bytes.len() > MAXIMUM_PACKAGE_BYTES {
        return Err(invalid("A plugin package may not exceed 512 KiB."));
    }
    if bytes.is_empty() {
        return Err(invalid(NOT_A_PACKAGE));
    }
    Ok(bytes)
}

fn is_zip(bytes: &[u8]) -> bool {
    bytes.len() >= 4 && bytes.starts_with(b"PK")
}

/// The bytes of `plugin.json` and `README.md` (or `None`) from a validated archive.
fn unpack(archive: &[u8]) -> Result<(Vec<u8>, Option<Vec<u8>>), PluginError> {
    let entries = files::validate_archive(archive)?;
    // Hidden files and the macOS resource directory are ignored, as in the Swift importer.
    let visible: Vec<&ArchiveEntry> = entries.iter().filter(|entry| entry.parts[0] != "__MACOSX" && !entry.parts.iter().any(|part| part.starts_with('.'))).collect();
    let at_root = visible.iter().any(|entry| entry.parts.len() == 1 && !entry.is_directory && entry.parts[0] == MANIFEST_FILE);
    let mut prefix = 0;
    if !at_root {
        let mut roots: Vec<&str> = visible.iter().filter(|entry| entry.parts.len() > 1 || entry.is_directory).map(|entry| entry.parts[0].as_str()).collect();
        roots.sort_unstable();
        roots.dedup();
        if roots.len() != 1 {
            return Err(invalid(NOT_A_PACKAGE));
        }
        prefix = 1;
    }
    let members: Vec<&ArchiveEntry> = visible.into_iter().filter(|entry| entry.parts.len() > prefix).collect();
    let allowed = |entry: &&ArchiveEntry| !entry.is_directory && entry.parts.len() == prefix + 1 && [MANIFEST_FILE, README_FILE].contains(&entry.parts[prefix].as_str());
    let member = |name: &str| members.iter().find(|entry| entry.parts[prefix] == name).copied();
    let Some(manifest_entry) = member(MANIFEST_FILE).filter(|_| members.iter().all(allowed)) else {
        return Err(invalid("A plugin package allows only plugin.json and optional README.md."));
    };
    let inflate = |entry: &ArchiveEntry, maximum_bytes: usize, too_large: &str| -> Result<Vec<u8>, PluginError> {
        if entry.uncompressed_size > maximum_bytes as u64 {
            return Err(invalid(too_large));
        }
        files::inflate(archive, entry, maximum_bytes).map_err(|_| invalid("The plugin archive is corrupt."))
    };
    let manifest = inflate(manifest_entry, manifest::MAXIMUM_MANIFEST_BYTES, "plugin.json exceeds 256 KiB.")?;
    let readme = member(README_FILE).map(|entry| inflate(entry, MAXIMUM_README_BYTES, "README.md exceeds 512 KiB.")).transpose()?;
    if readme.as_ref().is_some_and(|readme| manifest::decode_utf8(readme).is_none()) {
        return Err(invalid("README.md must be UTF-8 text."));
    }
    Ok((manifest, readme))
}

fn load(directory: &Path) -> Option<PluginManifest> {
    manifest::decode(&read_bytes(directory, MANIFEST_FILE, manifest::MAXIMUM_MANIFEST_BYTES)?).ok()
}

/// Reads a regular, singly linked file that is not a symlink and stays inside `directory`.
fn read_bytes(directory: &Path, name: &str, maximum_bytes: usize) -> Option<Vec<u8>> {
    files::read_bounded(&files::existing_file(directory, name)?, maximum_bytes)
}

fn read_text(directory: &Path, name: &str, maximum_bytes: usize) -> Option<String> {
    let bytes = read_bytes(directory, name, maximum_bytes)?;
    manifest::decode_utf8(&bytes).map(str::to_owned)
}

fn built_in_readme(manifest: &PluginManifest) -> String {
    format!("# {}\n\n{}\n", manifest.name, manifest.summary)
}
