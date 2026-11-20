//! How a version of a conversation becomes a package: in memory for the trial
//! run, and on disk when it is saved or applied. Port of the `AiCandidates`
//! object of `Android/app/.../ui/AiConversationScreen.kt`; the Linux command
//! line and the management window share it. The model only ever influences
//! the network declaration.

use std::collections::BTreeMap;
use std::sync::Arc;

use super::conversation::AiConversationVersion;
use super::output::{AiManifestDeclaration, AiManifests, ValidationResult};
use crate::library::{InstalledPackage, Library};
use crate::package_files::{MemoryPackageFiles, PackageFiles};
use crate::packages::limits::MAX_SCRIPT_BYTES;
use crate::packages::{DiskPackageFiles, PackageError, codes};
use crate::runtime::{RunRequest, RunResult, WidgetRuntime};

/// The identity a candidate runs under: its `$storage` is not that of any installed widget.
pub const PREVIEW_PACKAGE_ID: &str = "ai-preview";

/// A package's files with some text files replaced in memory; nothing is written to disk.
pub struct OverlayPackageFiles {
    base: DiskPackageFiles,
    overrides: BTreeMap<String, String>,
}

impl PackageFiles for OverlayPackageFiles {
    fn paths(&self) -> Vec<String> {
        let mut paths = self.base.paths();
        paths.extend(self.overrides.keys().cloned());
        paths.sort_unstable();
        paths.dedup();
        paths
    }

    fn exists(&self, path: &str) -> bool {
        self.overrides.contains_key(path) || self.base.exists(path)
    }

    fn read_text(&self, path: &str) -> Option<String> {
        self.overrides.get(path).cloned().or_else(|| self.base.read_text(path))
    }

    fn read_bytes(&self, path: &str) -> Option<Vec<u8>> {
        self.overrides.get(path).map(|text| text.clone().into_bytes()).or_else(|| self.base.read_bytes(path))
    }
}

/// Draws a finished run and says why it could not be drawn. The painter
/// (`sw-render`) depends on this crate, so the caller brings it.
pub type Draw<'a> = &'a dyn Fn(&RunRequest, &RunResult) -> Result<(), String>;

pub struct AiCandidates;

impl AiCandidates {
    /// Entry file of an installed package: the manifest's `entry`, or `main.jsx` for a legacy package.
    pub fn entry_of(installed: &InstalledPackage) -> String {
        AiManifests::entry(installed.manifest.as_ref())
    }

    /// Hosts an installed widget may already contact.
    pub fn allowed_hosts(installed: Option<&InstalledPackage>) -> Vec<String> {
        AiManifestDeclaration::from_manifest(installed.and_then(|installed| installed.manifest.as_ref())).map(|declaration| declaration.network_domains).unwrap_or_default()
    }

    /// The declaration a version runs and is saved with. A new widget gets exactly what the
    /// version declares. An installed widget keeps the hosts it already has and gains the
    /// declared ones: a conversation never takes a permission away from a widget.
    pub fn declaration(installed: Option<&InstalledPackage>, domains: &[String]) -> Option<String> {
        let mut hosts = Self::allowed_hosts(installed);
        for domain in domains {
            if !hosts.contains(domain) {
                hosts.push(domain.clone());
            }
        }
        if hosts.is_empty() { None } else { Some(AiManifestDeclaration::new(vec!["network".into()], hosts).to_json()) }
    }

    /// Declared hosts the installed widget may not contact yet; the user is asked before they are added.
    pub fn new_hosts(installed: Option<&InstalledPackage>, domains: &[String]) -> Vec<String> {
        let allowed = Self::allowed_hosts(installed);
        domains.iter().filter(|domain| !allowed.contains(domain)).cloned().collect()
    }

    /// The manifest text of a version, or `None` for a legacy package that has no `widget.json`.
    pub fn manifest_text(installed: Option<&InstalledPackage>, domains: &[String], new_name: &str) -> Option<String> {
        if installed.is_some_and(|installed| installed.manifest.is_none()) {
            return None;
        }
        Some(AiManifests::text(installed.and_then(|installed| installed.manifest.as_ref()), Self::declaration(installed, domains).as_deref(), new_name))
    }

    /// In-memory package of a version: a fresh one, or the installed package with its entry replaced.
    pub fn files(installed: Option<&InstalledPackage>, source: &str, domains: &[String], new_name: &str) -> Arc<dyn PackageFiles> {
        let manifest = Self::manifest_text(installed, domains, new_name);
        match installed {
            None => Arc::new(MemoryPackageFiles::new([(AiManifests::DEFAULT_ENTRY.to_owned(), source.to_owned()), (AiManifests::FILE_NAME.to_owned(), manifest.unwrap_or_default())], [])),
            Some(installed) => {
                let mut overrides = BTreeMap::new();
                overrides.insert(Self::entry_of(installed), source.to_owned());
                if let Some(manifest) = manifest {
                    overrides.insert(AiManifests::FILE_NAME.to_owned(), manifest);
                }
                Arc::new(OverlayPackageFiles { base: installed.files(), overrides })
            }
        }
    }

    /// The script globals `source` uses that Linux does not implement and `baseline` (the widget before the turn) did not use already.
    fn newly_unsupported(source: &str, baseline: Option<&str>) -> Option<String> {
        let api = crate::library::unsupported_api(source)?;
        let before = baseline.is_some_and(|baseline| {
            let bytes = baseline.as_bytes();
            baseline.match_indices(&api).any(|(at, _)| !bytes.get(at + api.len()).is_some_and(|next| next.is_ascii_alphanumeric() || *next == b'_'))
        });
        (!before).then_some(api)
    }

    /// Compiles and executes a candidate in memory, exactly as the preview will, and with
    /// `draw` also paints it. Blocking. `baseline` is the widget's code before the turn: what it
    /// already used is not held against the candidate.
    #[allow(clippy::too_many_arguments)]
    pub fn validate(runtime: &WidgetRuntime, installed: Option<&InstalledPackage>, source: &str, declaration_json: Option<&str>, family: &str, dark_mode: bool, baseline: Option<&str>, draw: Option<Draw<'_>>) -> ValidationResult {
        if source.len() > MAX_SCRIPT_BYTES {
            return ValidationResult::failure(format!("resourceLimit: main.jsx exceeds {} KiB.", MAX_SCRIPT_BYTES / 1024), Vec::new());
        }
        let domains = declaration_json.and_then(|text| AiManifestDeclaration::parse(text).ok()).map(|declaration| declaration.network_domains).unwrap_or_default();
        let mut request = RunRequest::new(Self::files(installed, source, &domains, "AI Widget"), PREVIEW_PACKAGE_ID);
        request.family = family.to_owned();
        request.dark_mode = dark_mode;
        let run = runtime.run(&request);
        let execution = &run.execution;
        let logs: Vec<String> = execution.logs.iter().map(|entry| format!("[{}] {}", entry.level, entry.message)).collect();
        let result = ValidationResult::from_execution(execution.tree.as_deref(), execution.error.as_ref().map(|error| error.kind.as_str()), execution.error.as_ref().map(|error| error.message.as_str()), logs.clone());
        // A global Linux lacks fails in ways that do not name the reason ("not a function"), or not at
        // all when the script catches the error: either way the model is told what it is.
        let unsupported = Self::newly_unsupported(source, baseline).map(|api| format!("The widget uses features that are not supported on Linux: {api} is not implemented here and every call to it fails."));
        if !result.ok {
            return match unsupported {
                Some(unsupported) => ValidationResult::failure(format!("{}\n\n{unsupported}", result.error_summary.as_deref().unwrap_or("Runtime returned no element.")), result.logs),
                None => result,
            };
        }
        if let Some(unsupported) = unsupported {
            return ValidationResult::failure(unsupported, logs);
        }
        if let Some(draw) = draw
            && let Err(message) = draw(&request, &run)
        {
            return ValidationResult::failure(format!("internalError: the widget ran but could not be drawn: {}", super::take(&message, 400)), logs);
        }
        result
    }

    /// A package name for a conversation that is saved as a new widget: its title when that can
    /// be a name, with what a name cannot hold taken out, and "AI Widget" otherwise.
    pub fn suggested_name(title: &str) -> String {
        let title: String = title.trim_end_matches('…').chars().map(|character| if character.is_control() || "/\\:".contains(character) { ' ' } else { character }).collect();
        let title = title.trim().trim_start_matches('.').trim();
        if !title.is_empty() && crate::packages::names::is_valid(title) { title.to_owned() } else { "AI Widget".to_owned() }
    }

    /// Saves a version as a new widget; a taken name gets a numbered suffix.
    pub fn save_new(library: &Library, new_name: &str, version: &AiConversationVersion) -> Result<InstalledPackage, PackageError> {
        let unique = library.store().unique_name(new_name)?;
        library.create(&unique, &version.source, Self::manifest_text(None, &version.network_domains, &unique).as_deref())
    }

    /// Writes a version into an installed widget: its entry, and its manifest only when the
    /// version adds hosts. Everything else of the package stays as it is.
    pub fn apply(library: &Library, target: &InstalledPackage, version: &AiConversationVersion) -> Result<InstalledPackage, PackageError> {
        // A present manifest that cannot be read is not replaced by a guess.
        if target.manifest_present && target.manifest.is_none() {
            return Err(PackageError::new(codes::INVALID_MANIFEST, "widget.json of this widget cannot be read; nothing was changed."));
        }
        library.write_file(&target.name, &Self::entry_of(target), version.source.as_bytes())?;
        if let Some(manifest) = Self::manifest_text(Some(target), &version.network_domains, &target.name)
            && !Self::new_hosts(Some(target), &version.network_domains).is_empty()
        {
            library.write_file(&target.name, AiManifests::FILE_NAME, manifest.as_bytes())?;
        }
        Ok(library.find(&target.name).unwrap_or_else(|| target.clone()))
    }
}
