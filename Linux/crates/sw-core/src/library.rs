//! The user's widget library under the data folder, plus the read-only
//! templates shipped with the application. Ported from
//! `Windows/src/ScriptWidget.Core/Hosting/Library.cs`. All package I/O goes
//! through the hardened [`PackageStore`].

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::data_paths::DataPaths;
use crate::json::{Object, ObjectExt, as_text};
use crate::packages::limits::{MAX_FILE_BYTES, MAX_FILE_COUNT, MAX_METADATA_BYTES, MAX_PATH_DEPTH};
use crate::packages::{DiskPackageFiles, ImportValidator, PackageError, PackageInfo, PackageStore, codes, manifests, path_rules};

/// The widget sizes a Linux desktop shows, by the name `$getenv("widget-size")` returns.
pub const FAMILIES: [&str; 4] = ["small", "medium", "large", "extraLarge"];

/// The short family name for a manifest's WidgetKit name ("systemMedium"), or `None` for a size Linux does not show.
pub fn family_from_manifest(name: &str) -> Option<&'static str> {
    match name {
        "systemSmall" => Some("small"),
        "systemMedium" => Some("medium"),
        "systemLarge" => Some("large"),
        "systemExtraLarge" => Some("extraLarge"),
        _ => None,
    }
}

/// One installed package. `installation` stays the same when the package is renamed.
#[derive(Debug, Clone, PartialEq)]
pub struct InstalledPackage {
    pub name: String,
    pub directory: PathBuf,
    pub installation: String,
    /// The manifest as read leniently for display; `None` when absent or unreadable.
    pub manifest: Option<Object>,
    /// True when widget.json exists, readable or not. A present manifest that cannot be read fails closed.
    pub manifest_present: bool,
}

impl InstalledPackage {
    pub fn files(&self) -> DiskPackageFiles {
        DiskPackageFiles::new(&self.directory)
    }

    pub fn build_directory(&self) -> PathBuf {
        self.directory.join("__Build")
    }

    pub fn display_name(&self) -> String {
        self.manifest.as_ref().map(|manifest| manifest.opt_string("name")).filter(|title| !title.is_empty()).unwrap_or_else(|| self.name.clone())
    }

    pub fn description(&self) -> String {
        self.manifest.as_ref().map(|manifest| manifest.opt_string("description")).unwrap_or_default()
    }

    pub fn permissions(&self) -> Vec<String> {
        self.manifest.as_ref().and_then(|manifest| manifest.opt_array("permissions")).map(|items| items.iter().map(|item| as_text(item).unwrap_or_default()).collect()).unwrap_or_default()
    }

    /// Widget sizes the manifest lists that Linux can show; every size when it lists none.
    pub fn families(&self) -> Vec<&'static str> {
        let declared: Vec<&str> = self
            .manifest
            .as_ref()
            .and_then(|manifest| manifest.opt_array("supportedFamilies"))
            .map(|items| items.iter().filter_map(|item| family_from_manifest(item.as_str()?)).collect())
            .unwrap_or_default();
        if declared.is_empty() { FAMILIES.to_vec() } else { FAMILIES.iter().copied().filter(|family| declared.contains(family)).collect() }
    }
}

/// A template or example shipped with the application.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundledPackage {
    /// "template", "component" or "api".
    pub group: String,
    pub name: String,
    pub directory: PathBuf,
    /// True when one of its scripts asks the network for data (`fetch`,
    /// `$http`, `$weather`, `$dataSource`): its picture depends on a server.
    pub network: bool,
}

/// A shipped template that is not offered because it uses a script global Linux does not implement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnavailableTemplate {
    pub group: String,
    pub name: String,
    /// The first such global in its entry, with the dollar sign.
    pub api: String,
}

/// The name of the dot-file that holds a package's installation identity. Package listings and exports skip dot-files.
pub const INSTALLATION_FILE: &str = ".scriptwidget-installation";

const GROUPS: [&str; 3] = ["template", "component", "api"];

/// Script globals Linux does not implement in this release (plan 4.9). A
/// template that uses one would only show "not supported", so it is left out
/// of the template list. The same list as on Windows.
const UNSUPPORTED_APIS: [&str; 14] = ["health", "calendar", "reminders", "photos", "contacts", "home", "icloud", "alarms", "maps", "services", "music", "notifications", "location", "documents"];

/// What marks a script as asking the network for data.
const NETWORK_TOKENS: [&str; 4] = ["fetch(", "$http.", "$weather.", "$dataSource."];

pub struct Library {
    root: PathBuf,
    templates: Option<PathBuf>,
    store: PackageStore,
}

impl Library {
    /// `templates` is the folder with the bundled template groups (see [`crate::resources`]); `None` when none are installed.
    pub fn new(paths: &DataPaths, templates: Option<PathBuf>) -> Self {
        let root = paths.packages();
        Self { store: PackageStore::new(&root, paths.package_staging()), root, templates }
    }

    pub fn store(&self) -> &PackageStore {
        &self.store
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Installed packages, sorted by name without regard to case.
    pub fn list(&self) -> Result<Vec<InstalledPackage>, PackageError> {
        let mut packages = self.store.list()?;
        packages.sort_by_key(|info| (info.name.to_lowercase(), info.name.clone()));
        Ok(packages.into_iter().map(describe).collect())
    }

    /// The package with this name, compared without regard to case.
    pub fn find(&self, name: &str) -> Option<InstalledPackage> {
        let wanted = name.to_lowercase();
        self.store.list().ok()?.into_iter().find(|info| info.name.to_lowercase() == wanted).map(describe)
    }

    pub fn find_by_installation(&self, installation: &str) -> Option<InstalledPackage> {
        self.list().ok()?.into_iter().find(|package| package.installation == installation)
    }

    /// Creates a package; a taken name gets a numbered suffix.
    pub fn create(&self, name: &str, source: &str, manifest: Option<&str>) -> Result<InstalledPackage, PackageError> {
        Ok(describe(self.store.create(&self.store.unique_name(name)?, source, manifest)?))
    }

    /// `validate` checks the unpacked files before they are installed; an error refuses the package.
    pub fn import_archive(&self, input: &mut dyn Read, suggested_name: Option<&str>, validate: Option<ImportValidator<'_>>) -> Result<InstalledPackage, PackageError> {
        let info = self.store.import_archive(input, suggested_name, validate)?;
        // An archive never carries another installation's identity.
        forget_installation(&info.directory);
        Ok(describe(info))
    }

    pub fn export_archive(&self, name: &str, output: &mut dyn Write) -> Result<(), PackageError> {
        self.store.export_archive(name, output)
    }

    pub fn delete(&self, name: &str) -> Result<(), PackageError> {
        self.store.delete(name)
    }

    pub fn rename(&self, name: &str, new_name: &str) -> Result<InstalledPackage, PackageError> {
        Ok(describe(self.store.rename(name, new_name)?))
    }

    pub fn duplicate(&self, name: &str) -> Result<InstalledPackage, PackageError> {
        let copy = self.store.duplicate(name)?;
        forget_installation(&copy.directory);
        Ok(describe(copy))
    }

    pub fn write_file(&self, name: &str, path: &str, bytes: &[u8]) -> Result<(), PackageError> {
        self.store.write_file(name, path, bytes)?;
        self.clear_build(name);
        Ok(())
    }

    /// Removes one file of an installed package; a file that is already gone is not an error.
    pub fn delete_file(&self, name: &str, path: &str) -> Result<(), PackageError> {
        self.store.delete_file(name, path)?;
        self.clear_build(name);
        Ok(())
    }

    /// Removes the compiled-artifact cache of a package.
    pub fn clear_build(&self, name: &str) {
        if let Some(installed) = self.find(name) {
            let build = installed.build_directory();
            // Only a real directory: a link with that name is not ours to follow.
            if std::fs::symlink_metadata(&build).is_ok_and(|metadata| metadata.is_dir()) {
                let _ = std::fs::remove_dir_all(build);
            }
        }
    }

    // Bundled templates

    /// The bundled templates that can run on Linux, grouped as the Apple apps group them.
    pub fn bundled(&self) -> Vec<BundledPackage> {
        self.shipped().into_iter().filter_map(|(package, unsupported)| unsupported.is_none().then_some(package)).collect()
    }

    /// The shipped templates [`Library::bundled`] leaves out, with the reason.
    pub fn unavailable(&self) -> Vec<UnavailableTemplate> {
        self.shipped().into_iter().filter_map(|(package, unsupported)| Some(UnavailableTemplate { group: package.group, name: package.name, api: unsupported? })).collect()
    }

    /// A bundled template by "group/name" or by name alone, compared exactly.
    pub fn find_bundled(&self, reference: &str) -> Option<BundledPackage> {
        let bundled = self.bundled();
        match reference.split_once('/') {
            Some((group, name)) => bundled.into_iter().find(|package| package.group == group && package.name == name),
            None => bundled.into_iter().find(|package| package.name == reference),
        }
    }

    /// Every shipped template with a readable entry, and the unsupported global it uses, if any.
    fn shipped(&self) -> Vec<(BundledPackage, Option<String>)> {
        let mut result = Vec::new();
        let Some(templates) = &self.templates else { return result };
        for group in GROUPS {
            let directory = templates.join(group);
            let mut names: Vec<String> = std::fs::read_dir(&directory).into_iter().flatten().filter_map(|entry| entry.ok()?.file_name().into_string().ok()).filter(|name| !path_rules::is_excluded(name)).collect();
            names.sort_by_key(|name| (name.to_lowercase(), name.clone()));
            for name in names {
                let package = directory.join(&name);
                // Read through the package view: a linked or oversized entry is no template.
                let Some(main) = DiskPackageFiles::new(&package).read_bytes_up_to(manifests::LEGACY_ENTRY, MAX_FILE_BYTES).and_then(|bytes| String::from_utf8(bytes).ok()) else { continue };
                let unsupported = unsupported_api(&main);
                let mut bundled = BundledPackage { group: group.to_owned(), name, directory: package, network: false };
                bundled.network = self.bundled_files(&bundled).iter().any(|(path, content)| {
                    (path.ends_with(".js") || path.ends_with(".jsx")) && std::str::from_utf8(content).is_ok_and(|source| NETWORK_TOKENS.iter().any(|token| source.contains(token)))
                });
                result.push((bundled, unsupported));
            }
        }
        result
    }

    /// Files of a bundled package by relative path. Dot-files, `__Build`, links and oversized files are left out.
    pub fn bundled_files(&self, bundled: &BundledPackage) -> BTreeMap<String, Vec<u8>> {
        let files = DiskPackageFiles::new(&bundled.directory);
        let mut result = BTreeMap::new();
        for path in files.list().unwrap_or_default().into_iter().take(MAX_FILE_COUNT) {
            if path.split('/').count() <= MAX_PATH_DEPTH
                && let Some(bytes) = files.read_bytes_up_to(&path, MAX_FILE_BYTES)
            {
                result.insert(path, bytes);
            }
        }
        result
    }

    /// The entry source and the manifest text a copy of a bundled template
    /// named `name` starts with: its own `widget.json` under the new name and
    /// a fresh `id`, or the one [`bundled_manifest`] generates.
    pub fn bundled_sources(name: &str, files: &BTreeMap<String, Vec<u8>>) -> Result<(String, String), PackageError> {
        let text = |path: &str| files.get(path).and_then(|bytes| String::from_utf8(bytes.clone()).ok());
        let main = text(manifests::LEGACY_ENTRY).ok_or_else(|| PackageError::new(codes::MISSING_ENTRY, "Template has no main.jsx"))?;
        let manifest = match files.get(manifests::FILE_NAME) {
            Some(_) => {
                let mut manifest = manifests::parse(text(manifests::FILE_NAME).as_deref()).ok_or_else(|| PackageError::new(codes::INVALID_MANIFEST, "widget.json is invalid."))?;
                manifest.insert("id".into(), Value::String(manifests::fresh_id()));
                manifest.insert("name".into(), Value::String(name.to_owned()));
                manifest
            }
            None => bundled_manifest(name, files),
        };
        Ok((main, String::from_utf8(manifests::encode(&manifest)).unwrap_or_default()))
    }

    /// Copies a bundled template into the library; a taken name gets a numbered suffix.
    pub fn install_bundled(&self, bundled: &BundledPackage) -> Result<InstalledPackage, PackageError> {
        let files = self.bundled_files(bundled);
        let name = self.store.unique_name(&bundled.name)?;
        let (main, manifest) = Self::bundled_sources(&name, &files)?;
        let entry = manifests::parse(Some(&manifest)).and_then(|manifest| manifests::string_value(&manifest, "entry")).unwrap_or_else(|| manifests::LEGACY_ENTRY.to_owned());
        let source = if entry == manifests::LEGACY_ENTRY { main } else { files.get(&entry).and_then(|bytes| String::from_utf8(bytes.clone()).ok()).ok_or_else(|| PackageError::new(codes::MISSING_ENTRY, "Template entry does not exist."))? };
        let created = self.store.create(&name, &source, Some(&manifest))?;
        for (path, bytes) in &files {
            if *path != entry && path != manifests::FILE_NAME {
                self.store.write_file(&created.name, path, bytes).inspect_err(|_| {
                    // No half-copied template stays in the library.
                    let _ = self.store.delete(&created.name);
                })?;
            }
        }
        Ok(describe(created))
    }
}

/// The first script global in `source`, with its dollar sign, that Linux does not implement.
pub fn unsupported_api(source: &str) -> Option<String> {
    let bytes = source.as_bytes();
    source.match_indices('$').find_map(|(at, _)| {
        let rest = &source[at + 1..];
        UNSUPPORTED_APIS.iter().find(|name| rest.starts_with(**name) && !bytes.get(at + 1 + name.len()).is_some_and(|next| next.is_ascii_alphanumeric() || *next == b'_')).map(|name| format!("${name}"))
    })
}

/// The script globals, without the dollar sign, that Linux does not implement in this release.
pub fn unsupported_apis() -> &'static [&'static str] {
    &UNSUPPORTED_APIS
}

/// True for a script global without the dollar sign, such as `health`, that Linux does not implement in this release.
pub fn is_unsupported_api(name: &str) -> bool {
    UNSUPPORTED_APIS.contains(&name)
}

/// The manifest for a bundled template that has no `widget.json`. A copy in
/// the library always has a manifest, and a manifest without `network` stops
/// every request, so the hosts the template names in its own source are
/// declared for it. This is done only for the templates shipped with the
/// app, never for an imported package.
pub fn bundled_manifest(name: &str, files: &BTreeMap<String, Vec<u8>>) -> Object {
    let metadata = files.get(manifests::LEGACY_METADATA).and_then(|bytes| std::str::from_utf8(bytes).ok());
    let mut manifest = manifests::legacy_manifest(name, metadata);
    manifest.insert("id".into(), Value::String(manifests::fresh_id()));
    let mut hosts = BTreeSet::new();
    for (path, content) in files {
        if !path.ends_with(".js") && !path.ends_with(".jsx") {
            continue;
        }
        for line in String::from_utf8_lossy(content).lines().filter(|line| !line.trim_start().starts_with("//")) {
            hosts.extend(source_hosts(line).filter(|host| declarable_host(host)));
        }
    }
    if !hosts.is_empty() {
        manifest.insert("permissions".into(), Value::Array(vec![Value::String("network".into())]));
        manifest.insert("networkDomains".into(), Value::Array(hosts.into_iter().map(Value::String).collect()));
    }
    manifest
}

/// The lower-cased host of every `http://` and `https://` in a line: the run of letters, digits, dots and hyphens after it.
fn source_hosts(line: &str) -> impl Iterator<Item = String> + '_ {
    ["http://", "https://"].into_iter().flat_map(move |scheme| {
        line.match_indices(scheme).map(move |(at, _)| {
            let rest = &line[at + scheme.len()..];
            let end = rest.find(|character: char| !(character.is_ascii_alphanumeric() || character == '.' || character == '-')).unwrap_or(rest.len());
            rest[..end].to_ascii_lowercase()
        })
    })
}

/// A complete public host name: at least two labels of letters, digits and inner hyphens, the last one letters only.
fn declarable_host(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    let label = |text: &str| {
        let bytes = text.as_bytes();
        !bytes.is_empty()
            && bytes.iter().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
            && bytes[0] != b'-'
            && bytes[bytes.len() - 1] != b'-'
    };
    labels.len() >= 2 && labels.iter().all(|text| label(text)) && labels.last().is_some_and(|last| last.len() >= 2 && last.bytes().all(|byte| byte.is_ascii_lowercase()))
}

fn describe(info: PackageInfo) -> InstalledPackage {
    let manifest = if info.has_manifest {
        DiskPackageFiles::new(&info.directory).read_bytes_up_to(manifests::FILE_NAME, MAX_METADATA_BYTES as u64).and_then(|bytes| String::from_utf8(bytes).ok()).and_then(|text| manifests::parse(Some(&text)))
    } else {
        None
    };
    InstalledPackage { installation: installation(&info.directory), name: info.name, manifest, manifest_present: info.has_manifest, directory: info.directory }
}

fn marker_options() -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    // Never through a link, and private to the user.
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600);
    options
}

/// Stable identity kept in a dot-file, which package listings and exports skip.
fn installation(directory: &Path) -> String {
    let marker = directory.join(INSTALLATION_FILE);
    let existing = marker_options().read(true).open(&marker).ok().and_then(|file| {
        let mut text = String::new();
        file.take(257).read_to_string(&mut text).ok()?;
        let text = text.trim().to_owned();
        ((8..=64).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')).then_some(text)
    });
    if let Some(existing) = existing {
        return existing;
    }
    let created = manifests::fresh_id().trim_start_matches("local.").to_owned();
    // An unreadable or malformed marker is replaced; when that fails the identity lasts for this run only.
    let _ = std::fs::remove_file(&marker);
    if let Ok(mut file) = marker_options().write(true).create_new(true).open(&marker) {
        let _ = file.write_all(created.as_bytes());
    }
    created
}

fn forget_installation(directory: &Path) {
    let _ = std::fs::remove_file(directory.join(INSTALLATION_FILE));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(main: &str, meta: Option<&str>) -> BTreeMap<String, Vec<u8>> {
        let mut files = BTreeMap::from([("main.jsx".to_owned(), main.as_bytes().to_vec())]);
        if let Some(meta) = meta {
            files.insert("meta.json".to_owned(), meta.as_bytes().to_vec());
        }
        files
    }

    fn strings(manifest: &Object, key: &str) -> Vec<String> {
        manifest.opt_array(key).expect(key).iter().map(|item| item.as_str().unwrap().to_owned()).collect()
    }

    // The four tests of Windows/tests/ScriptWidget.Core.Tests/Packages/BundledManifestTests.cs.

    #[test]
    fn declares_the_hosts_named_in_the_source() {
        let manifest = bundled_manifest(
            "Daily Quote",
            &files(
                "// https://atomsprout.com/scriptwidget\nconst url = \"https://ZenQuotes.io/api/today\";\nconst other = `http://api.example.com/${id}`;\nconst result = await fetch(url);\n",
                Some("{\"description\":\"A quote\",\"category\":\"productivity\"}"),
            ),
        );
        assert_eq!(strings(&manifest, "permissions"), ["network"]);
        assert_eq!(strings(&manifest, "networkDomains"), ["api.example.com", "zenquotes.io"]);
        assert_eq!(manifest.opt_string("description"), "A quote");
        assert!(manifest.opt_string("id").starts_with("local."));
    }

    #[test]
    fn a_template_without_urls_gets_no_network_permission() {
        let manifest = bundled_manifest("Clock", &files("// see https://example.com\n$render(<text>hi</text>)\n", None));
        assert!(strings(&manifest, "permissions").is_empty());
        assert!(strings(&manifest, "networkDomains").is_empty());
    }

    #[test]
    fn names_the_globals_linux_does_not_implement() {
        for name in ["health", "calendar", "location", "music"] {
            assert!(is_unsupported_api(name), "{name}");
        }
        for name in ["storage", "device", "system", "file", "http", "xml", "weather", "dataSource", "healthy", ""] {
            assert!(!is_unsupported_api(name), "{name}");
        }
        assert_eq!(unsupported_api("const steps = await $health.steps();").as_deref(), Some("$health"));
        assert_eq!(unsupported_api("$storage.get('a'); if ($music) {}").as_deref(), Some("$music"));
        assert_eq!(unsupported_api("$healthy(); $locations; health.steps(); $calendar_x"), None);
        assert_eq!(unsupported_api("x = $location"), Some("$location".into()));
    }

    #[test]
    fn hosts_that_cannot_be_declared_are_left_out() {
        let manifest =
            bundled_manifest("Odd", &files("fetch(`https://api.${region}.example.com/x`); fetch(\"http://localhost/x\"); fetch(\"http://192.168.1.1/x\"); fetch(\"https://-bad.example.com\");\n", None));
        assert!(strings(&manifest, "permissions").is_empty());
        assert!(strings(&manifest, "networkDomains").is_empty());
    }

    #[test]
    fn manifest_family_names_map_to_the_short_ones() {
        let package = |families: &str| InstalledPackage {
            name: "A".into(),
            directory: "/nowhere".into(),
            installation: "x".into(),
            manifest: Some(crate::json::parse_object(&format!("{{\"supportedFamilies\":{families}}}")).unwrap()),
            manifest_present: true,
        };
        assert_eq!(package("[\"systemLarge\",\"systemSmall\",\"accessoryCircular\"]").families(), ["small", "large"]);
        assert_eq!(package("[]").families(), FAMILIES);
        assert_eq!(package("[\"accessoryInline\"]").families(), FAMILIES, "as on Windows: nothing Linux can show means every size");
    }
}
