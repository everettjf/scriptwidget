//! Installing, listing, exporting and deleting plugins. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Plugins/PluginStoreTests.cs`.

mod plugins_common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use plugins_common::*;
use serde_json::json;
use sw_core::plugins::manifest::{self, PluginErrorKind, PluginManifest};
use sw_core::plugins::store::{self, PluginStore, built_ins};

struct Fixture {
    temporary: PathBuf,
    root: PathBuf,
    store: PluginStore,
}

impl Fixture {
    fn new() -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let temporary = std::env::temp_dir().join(format!("scriptwidget-test-plugins-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&temporary);
        std::fs::create_dir_all(&temporary).unwrap();
        let root = temporary.join("Plugins");
        Self { store: PluginStore::new(&root), root, temporary }
    }

    fn install(&self, bytes: &[u8]) -> Result<PluginManifest, manifest::PluginError> {
        self.store.install(&mut &bytes[..])
    }

    /// Installed plugin directories; the hidden staging directory must be empty.
    fn installed(&self) -> Vec<String> {
        assert_eq!(names(&self.root.join(".staging")), [] as [&str; 0]);
        names(&self.root).into_iter().filter(|name| name != ".staging").collect()
    }

    fn assert_import_rejected(&self, expected: &str, archive: &[u8]) {
        let error = self.install(archive).expect_err("the import must be refused");
        assert!(error.message.contains(expected), "Expected \"{expected}\" in \"{}\"", error.message);
        assert_eq!(self.installed(), [] as [&str; 0]);
        assert_eq!(self.store.manifest(ID), None);
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.temporary);
    }
}

fn names(directory: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(directory).into_iter().flatten().map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned()).collect();
    names.sort_unstable();
    names
}

fn entry(name: &str, data: &[u8]) -> RawEntry {
    RawEntry::new(name, data)
}

fn mode(path: &Path) -> u32 {
    std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn lists_built_ins_when_nothing_is_installed() {
    let fixture = Fixture::new();
    let listed = fixture.store.list();
    assert_eq!(listed.iter().map(|plugin| plugin.manifest.name.as_str()).collect::<Vec<_>>(), ["GitHub Public API", "Open-Meteo"]);
    assert!(listed.iter().all(|plugin| plugin.built_in && plugin.readme.as_deref().is_some_and(|readme| readme.starts_with("# "))));
    assert!(fixture.store.manifest("app.scriptwidget.datasource.open-meteo").is_some());
    assert_eq!(fixture.store.manifest("dev.unknown.plugin"), None);
    assert!(!fixture.root.exists(), "listing must not create the directory");
}

#[test]
fn installs_bare_plugin_json() {
    let fixture = Fixture::new();
    assert_eq!(fixture.install(&bytes()).unwrap().id, ID);
    assert_eq!(fixture.installed(), ["test-source"]);
    assert_eq!(names(&fixture.root.join("test-source")), ["plugin.json"]);
    let listed = fixture.store.list();
    let plugin = listed.iter().find(|plugin| plugin.manifest.id == ID).unwrap();
    assert!(!plugin.built_in);
    assert_eq!(plugin.readme, None);
    assert_eq!(listed.len(), built_ins().len() + 1);
    assert_eq!(fixture.store.manifest(ID), Some(base_manifest()));
    // Everything the store writes is private to the user.
    assert_eq!(mode(&fixture.root), 0o700);
    assert_eq!(mode(&fixture.root.join("test-source")), 0o700);
    assert_eq!(mode(&fixture.root.join("test-source/plugin.json")), 0o600);
}

#[test]
fn installs_archive_with_files_at_the_root() {
    let fixture = Fixture::new();
    fixture.install(&raw_zip(&[entry("plugin.json", &bytes()), entry("README.md", b"# Test\n\nHello")])).unwrap();
    assert_eq!(names(&fixture.root.join("test-source")), ["README.md", "plugin.json"]);
    assert_eq!(fixture.store.list().iter().find(|plugin| plugin.manifest.id == ID).unwrap().readme.as_deref(), Some("# Test\n\nHello"));
}

#[test]
fn installs_archive_with_one_directory_and_ignores_hidden_files() {
    let fixture = Fixture::new();
    fixture
        .install(&raw_zip(&[
            RawEntry::directory("Test/"),
            RawEntry::deflated("Test/plugin.json", &bytes()),
            RawEntry::deflated("Test/README.md", b"docs"),
            RawEntry::deflated("Test/.DS_Store", &[1]),
            RawEntry::deflated("__MACOSX/Test/._plugin.json", &[2]),
            RawEntry::deflated(".hidden", &[3]),
        ]))
        .unwrap();
    assert_eq!(names(&fixture.root.join("test-source")), ["README.md", "plugin.json"]);
}

#[test]
fn duplicate_ids_are_refused() {
    let fixture = Fixture::new();
    fixture.install(&bytes()).unwrap();
    assert_eq!(fixture.install(&bytes()).unwrap_err().message, format!("Plugin {ID} is already installed."));
    assert_eq!(fixture.installed(), ["test-source"]);
    let built_in = &built_ins()[0];
    assert_eq!(fixture.install(built_in.to_json().as_bytes()).unwrap_err().message, format!("Plugin {} is already installed.", built_in.id));
}

#[test]
fn directory_names_are_slugs_and_never_collide() {
    let fixture = Fixture::new();
    fixture.install(&bytes_with(|root| root["name"] = json!("../../Evil  Name!"))).unwrap();
    fixture
        .install(&bytes_with(|root| {
            root["name"] = json!("evil name");
            root["id"] = json!("dev.scriptwidget.second");
        }))
        .unwrap();
    fixture
        .install(&bytes_with(|root| {
            root["name"] = json!("数据");
            root["id"] = json!("dev.scriptwidget.third");
        }))
        .unwrap();
    // Names that mean something to a shell or to other systems are plain directory names here.
    fixture
        .install(&bytes_with(|root| {
            root["name"] = json!("CON");
            root["id"] = json!("dev.scriptwidget.fourth");
        }))
        .unwrap();
    fixture
        .install(&bytes_with(|root| {
            root["name"] = json!(".staging");
            root["id"] = json!("dev.scriptwidget.fifth");
        }))
        .unwrap();
    assert_eq!(fixture.installed(), ["con", "evil-name", "evil-name-2", "plugin", "staging"]);
    assert_eq!(names(&fixture.temporary), ["Plugins"]);
}

#[test]
fn invalid_manifests_are_not_installed() {
    let fixture = Fixture::new();
    fixture.assert_import_rejected("plugin.json contains unknown fields.", &bytes_with(|root| root["unexpected"] = json!(true)));
    fixture.assert_import_rejected("baseURL must be an HTTPS URL", &raw_zip(&[entry("plugin.json", &bytes_with(|root| root["baseURL"] = json!("http://api.example.com")))]));
    fixture.assert_import_rejected("plugin.json is not valid JSON.", b"not json");
    fixture.assert_import_rejected("Archive must contain one Data Source Plugin 1.0 package.", b"");
}

#[test]
fn oversize_input_is_rejected() {
    let fixture = Fixture::new();
    fixture.assert_import_rejected("A plugin package may not exceed 512 KiB.", &vec![b' '; store::MAXIMUM_PACKAGE_BYTES + 1]);
    fixture.assert_import_rejected("A plugin package may not exceed 512 KiB.", &raw_zip(&[entry("plugin.json", &bytes()), entry("README.md", &vec![0u8; store::MAXIMUM_PACKAGE_BYTES])]));
    // A highly compressible README fits the archive limit but not the expanded limit.
    fixture.assert_import_rejected("README.md exceeds 512 KiB.", &raw_zip(&[RawEntry::deflated("plugin.json", &bytes()), RawEntry::deflated("README.md", &vec![b'a'; store::MAXIMUM_README_BYTES + 1])]));
    fixture.assert_import_rejected("plugin.json exceeds 256 KiB.", &raw_zip(&[RawEntry::deflated("plugin.json", &vec![b' '; manifest::MAXIMUM_MANIFEST_BYTES + 1])]));
    // A reader that never ends is cut off at the limit.
    let error = fixture.store.install(&mut std::io::repeat(b' ')).unwrap_err();
    assert_eq!(error.message, "A plugin package may not exceed 512 KiB.");
}

#[test]
fn only_plugin_json_and_readme_are_allowed() {
    let fixture = Fixture::new();
    let manifest = bytes();
    let only = "A plugin package allows only plugin.json and optional README.md.";
    fixture.assert_import_rejected(only, &raw_zip(&[entry("plugin.json", &manifest), entry("main.js", b"fetch()")]));
    fixture.assert_import_rejected(only, &raw_zip(&[entry("plugin.json", &manifest), entry("lib/native.so", b"x")]));
    fixture.assert_import_rejected(only, &raw_zip(&[entry("Test/plugin.json", &manifest), entry("Test/extra/plugin.json", &manifest)]));
    fixture.assert_import_rejected(only, &raw_zip(&[entry("Test/README.md", b"no manifest")]));
    fixture.assert_import_rejected(only, &raw_zip(&[entry("Test/Plugin.json", &manifest)]));
    fixture.assert_import_rejected(only, &raw_zip(&[entry("plugin.json", &manifest), entry("readme.md", b"wrong case")]));
    fixture.assert_import_rejected(only, &raw_zip(&[entry("plugin.json", &manifest), RawEntry::directory("README.md/")]));
    let package = "Archive must contain one Data Source Plugin 1.0 package.";
    fixture.assert_import_rejected(package, &raw_zip(&[entry("A/plugin.json", &manifest), entry("B/plugin.json", &manifest)]));
    fixture.assert_import_rejected(package, &raw_zip(&[entry("README.md", b"no package")]));
    fixture.assert_import_rejected("README.md must be UTF-8 text.", &raw_zip(&[entry("plugin.json", &manifest), entry("README.md", &[0xFF])]));
}

#[test]
fn unsafe_archives_are_rejected_before_anything_is_written() {
    let fixture = Fixture::new();
    let manifest = bytes();
    let plugin = entry("plugin.json", &manifest);
    let with = |other: RawEntry| raw_zip(&[plugin.clone(), other]);
    for name in ["../README.md", "/README.md", "Test\\README.md", "C:README.md", "a/./README.md", "a\u{202e}b", "a\nb"] {
        fixture.assert_import_rejected("unsafe or non-UTF-8 path", &with(entry(name, b"x")));
    }
    let mut not_utf8 = with(entry("README.mX", b"x"));
    let at = not_utf8.windows(9).position(|window| window == b"README.mX").unwrap();
    let positions: Vec<usize> = not_utf8.windows(9).enumerate().filter(|(_, window)| *window == b"README.mX").map(|(index, _)| index + 8).collect();
    assert!(positions.len() == 2 && positions[0] == at + 8);
    for position in positions {
        not_utf8[position] = 0xFF;
    }
    fixture.assert_import_rejected("unsafe or non-UTF-8 path", &not_utf8);
    fixture.assert_import_rejected("Symbolic links are not allowed", &with(RawEntry { external_attributes: 0xA1FF << 16, ..entry("README.md", b"/etc/hosts") }));
    fixture.assert_import_rejected("Only regular files and directories", &with(RawEntry { external_attributes: 0x1000 << 16, ..entry("README.md", b"") }));
    fixture.assert_import_rejected("duplicate or case-colliding paths", &with(entry("PLUGIN.JSON", &manifest)));
    fixture.assert_import_rejected("duplicate or case-colliding paths", &with(entry("plugin.json", &manifest)));
    fixture.assert_import_rejected("duplicate or case-colliding paths", &raw_zip(&[plugin.clone(), entry(".caf\u{e9}", b"1"), entry(".cafe\u{301}", b"2")]));
    fixture.assert_import_rejected("duplicate or case-colliding paths", &raw_zip(&[plugin.clone(), entry("README.md", b"file"), entry("README.md/inner", b"and directory")]));
    fixture.assert_import_rejected("Encrypted package entries", &raw_zip(&[RawEntry { flags: 0x0801, ..plugin.clone() }]));
    fixture.assert_import_rejected("Unsupported ZIP compression method", &raw_zip(&[RawEntry { method: 12, ..plugin.clone() }]));
    fixture.assert_import_rejected("no valid ZIP central directory", b"PK\x03\x04 truncated");
    let mut trailing = raw_zip(std::slice::from_ref(&plugin));
    trailing.extend_from_slice(b"extra");
    fixture.assert_import_rejected("malformed ZIP footer", &trailing);
    let many: Vec<RawEntry> = (0..501).map(|index| entry(&format!(".f{index}"), b"")).collect();
    fixture.assert_import_rejected("Archive must contain 1–500 entries.", &raw_zip(&many));
    assert_eq!(names(&fixture.temporary), [] as [&str; 0]);
}

#[test]
fn forged_sizes_and_corrupt_entries_are_rejected() {
    let fixture = Fixture::new();
    let manifest = bytes();
    let archive = raw_zip(&[RawEntry::deflated("plugin.json", &manifest)]);
    let corrupt = "The plugin archive is corrupt.";
    fixture.assert_import_rejected(corrupt, &forge_declared_size(&archive, 0, manifest.len() as u32 - 1));
    fixture.assert_import_rejected(corrupt, &forge_declared_size(&archive, 0, manifest.len() as u32 + 1));
    let mut stored = raw_zip(&[entry("plugin.json", &manifest)]);
    stored[40 + "plugin.json".len()] += 1;
    fixture.assert_import_rejected(corrupt, &stored);
    let stored = raw_zip(&[entry("plugin.json", &manifest)]);
    fixture.assert_import_rejected(corrupt, &forge_declared_size(&stored, 0, manifest.len() as u32 - 1));
    // A local header that is not where the directory says it is.
    let mut misplaced = raw_zip(&[entry("plugin.json", &manifest)]);
    misplaced[2] = 9;
    fixture.assert_import_rejected(corrupt, &misplaced);
    // Truncated deflate data.
    let mut cut = raw_zip(&[RawEntry::deflated("plugin.json", &manifest)]);
    for byte in &mut cut[45..60] {
        *byte = 0xFF;
    }
    fixture.assert_import_rejected(corrupt, &cut);
}

#[test]
fn export_round_trips_through_import() {
    let fixture = Fixture::new();
    fixture.install(&raw_zip(&[entry("plugin.json", &bytes()), entry("README.md", b"# Docs")])).unwrap();
    let exported = fixture.store.export(ID).unwrap();
    let second = PluginStore::new(fixture.temporary.join("Other"));
    assert_eq!(second.install(&mut &exported[..]).unwrap().id, ID);
    assert_eq!(second.list().iter().find(|plugin| plugin.manifest.id == ID).unwrap().readme.as_deref(), Some("# Docs"));
    assert_eq!(second.manifest(ID), Some(base_manifest()));
    // The same plugin always yields the same bytes.
    assert_eq!(fixture.store.export(ID).unwrap(), exported);
    assert_eq!(second.export(ID).unwrap(), exported);
}

#[test]
fn export_includes_only_the_plugin_files() {
    let fixture = Fixture::new();
    fixture.install(&bytes()).unwrap();
    std::fs::write(fixture.root.join("test-source/secret.txt"), "not part of the plugin").unwrap();
    assert_eq!(read_zip(&fixture.store.export(ID).unwrap()).iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["plugin.json"]);
}

#[test]
fn built_ins_export_but_cannot_be_deleted() {
    let fixture = Fixture::new();
    let built_in = &built_ins()[1];
    // A built-in id is already present, so the export is checked by decoding it.
    let entries = read_zip(&fixture.store.export(&built_in.id).unwrap());
    assert_eq!(entries.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["plugin.json", "README.md"]);
    assert_eq!(&manifest::decode(&entries[0].1).unwrap(), built_in);
    let delete = |id: &str| fixture.store.delete(id).unwrap_err();
    assert_eq!((delete(&built_in.id).kind, delete(&built_in.id).message.as_str()), (PluginErrorKind::NotFound, "Built-in plugins cannot be deleted."));
    assert_eq!(delete("dev.unknown.plugin").message, "Plugin not found.");
    assert_eq!(fixture.store.export("dev.unknown.plugin").unwrap_err().message, "Plugin not found.");
}

#[test]
fn delete_removes_the_plugin() {
    let fixture = Fixture::new();
    fixture.install(&bytes()).unwrap();
    fixture.store.delete(ID).unwrap();
    assert_eq!(fixture.installed(), [] as [&str; 0]);
    assert_eq!(fixture.store.manifest(ID), None);
    assert_eq!(fixture.store.list().len(), built_ins().len());
    fixture.install(&bytes()).unwrap();
    assert_eq!(fixture.installed(), ["test-source"]);
}

#[test]
fn tampered_or_linked_directories_are_not_loaded() {
    let fixture = Fixture::new();
    let (root, store) = (&fixture.root, &fixture.store);
    fixture.install(&bytes()).unwrap();
    let file = root.join("test-source/plugin.json");
    std::fs::write(&file, bytes_with(|root| root["baseURL"] = json!("http://api.example.com"))).unwrap();
    assert_eq!(store.manifest(ID), None, "a stored manifest is validated on every read");
    std::fs::write(&file, bytes()).unwrap();
    assert!(store.manifest(ID).is_some());

    // A link in the store is neither a plugin directory nor a plugin file.
    const LINKED: &str = "dev.scriptwidget.linked";
    let outside = fixture.temporary.join("outside");
    std::fs::create_dir(&outside).unwrap();
    let linked = outside.join("plugin.json");
    std::fs::write(&linked, bytes_with(|root| root["id"] = json!(LINKED))).unwrap();
    // The file itself is a valid plugin when it sits in a real directory of the store.
    std::fs::create_dir(root.join("control")).unwrap();
    std::fs::copy(&linked, root.join("control/plugin.json")).unwrap();
    assert!(store.manifest(LINKED).is_some());
    std::fs::remove_dir_all(root.join("control")).unwrap();

    std::os::unix::fs::symlink(&outside, root.join("linked")).unwrap();
    assert_eq!(store.manifest(LINKED), None, "a linked directory");
    std::fs::create_dir(root.join("real")).unwrap();
    std::os::unix::fs::symlink(&linked, root.join("real/plugin.json")).unwrap();
    assert_eq!(store.manifest(LINKED), None, "a linked file");
    std::fs::remove_file(root.join("real/plugin.json")).unwrap();
    std::fs::hard_link(&linked, root.join("real/plugin.json")).unwrap();
    assert_eq!(store.manifest(LINKED), None, "a file with a second name outside the store");
    assert!(!store.list().iter().any(|plugin| plugin.manifest.id == LINKED));
    assert_eq!(store.export(LINKED).unwrap_err().message, "Plugin not found.");
    // A named pipe in place of the manifest is not waited on.
    std::fs::remove_file(root.join("real/plugin.json")).unwrap();
    let pipe = std::ffi::CString::new(root.join("real/plugin.json").to_str().unwrap()).unwrap();
    // SAFETY: the path is a NUL-terminated string that lives until the call returns.
    assert_eq!(unsafe { libc::mkfifo(pipe.as_ptr(), 0o600) }, 0);
    assert_eq!(store.manifest(LINKED), None, "a pipe");
    // Another spelling of the manifest's name beside it makes the directory ambiguous on some file systems.
    std::fs::remove_file(root.join("real/plugin.json")).unwrap();
    std::fs::copy(&linked, root.join("real/plugin.json")).unwrap();
    assert!(store.manifest(LINKED).is_some());
    if std::fs::write(root.join("real/PLUGIN.JSON"), bytes()).is_ok() && names(&root.join("real")).len() == 2 {
        assert_eq!(store.manifest(LINKED), None, "a case alias");
    }

    // The store's own directory may not be a link either.
    let elsewhere = fixture.temporary.join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, fixture.temporary.join("LinkedStore")).unwrap();
    let through_link = PluginStore::new(fixture.temporary.join("LinkedStore"));
    assert_eq!(through_link.install(&mut &bytes()[..]).unwrap_err().kind, PluginErrorKind::Storage);
    assert_eq!(names(&elsewhere), [] as [&str; 0]);
}

#[test]
fn list_is_sorted_by_name_across_built_in_and_installed_plugins() {
    let fixture = Fixture::new();
    fixture.install(&bytes_with(|root| root["name"] = json!("alpha"))).unwrap();
    fixture
        .install(&bytes_with(|root| {
            root["name"] = json!("Hub");
            root["id"] = json!("dev.scriptwidget.second");
        }))
        .unwrap();
    assert_eq!(fixture.store.list().iter().map(|plugin| plugin.manifest.name.as_str()).collect::<Vec<_>>(), ["alpha", "GitHub Public API", "Hub", "Open-Meteo"]);
    // An installed plugin with a built-in's id cannot be imported, but one put there by hand replaces it in the list once.
    let directory = fixture.root.join("manual");
    std::fs::create_dir(&directory).unwrap();
    std::fs::write(directory.join("plugin.json"), built_ins()[0].to_json()).unwrap();
    let listed = fixture.store.list();
    assert_eq!(listed.iter().filter(|plugin| plugin.manifest.id == built_ins()[0].id).map(|plugin| plugin.built_in).collect::<Vec<_>>(), [false]);
}
