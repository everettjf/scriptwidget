//! The library of installed packages. Ported from `PackageStoreTests.cs`.

#[path = "packages_support/mod.rs"]
mod support;

use std::path::PathBuf;

use support::{RawEntry, SOURCE, SYMBOLIC_LINK, TemporaryFolder, assert_code, deflated_zip, forge_declared_size, hard_link, manifest, package_zip, raw_zip, symlink, tree, widget_zip, write_file};
use sw_core::PackageFiles;
use sw_core::json::{ObjectExt, parse_object};
use sw_core::packages::limits::{MAX_FILE_BYTES, MAX_FILE_COUNT, MAX_METADATA_BYTES, MAX_SCRIPT_BYTES};
use sw_core::packages::{PackageError, PackageInfo, PackageStore, archive};

struct Fixture {
    temporary: TemporaryFolder,
    library: PathBuf,
    staging: PathBuf,
    store: PackageStore,
}

impl Fixture {
    fn new() -> Self {
        let temporary = TemporaryFolder::new();
        let library = temporary.path("library");
        let staging = temporary.path("staging");
        Self { store: PackageStore::new(&library, &staging), temporary, library, staging }
    }

    fn names(&self) -> Vec<String> {
        self.store.list().unwrap().into_iter().map(|package| package.name).collect()
    }

    fn staging_tree(&self) -> Vec<String> {
        tree(&self.staging)
    }

    fn import(&self, archive: &[u8], suggested: Option<&str>) -> Result<PackageInfo, PackageError> {
        self.store.import_archive(&mut &archive[..], suggested, None)
    }

    fn export(&self, name: &str) -> Result<Vec<u8>, PackageError> {
        let mut output = Vec::new();
        self.store.export_archive(name, &mut output).map(|()| output)
    }

    fn in_library(&self, path: &str) -> PathBuf {
        self.library.join(path)
    }

    fn write_in_library(&self, path: &str, text: &str) {
        write_file(&self.in_library(path), text.as_bytes());
    }

    fn read_text(&self, name: &str, path: &str) -> String {
        String::from_utf8(self.store.read_file(name, path).unwrap()).unwrap()
    }

    fn find(&self, name: &str) -> PackageInfo {
        self.store.list().unwrap().into_iter().find(|package| package.name == name).unwrap()
    }
}

fn is_local_id(id: &str) -> bool {
    id.strip_prefix("local.").is_some_and(|uuid| uuid.len() == 36 && uuid.bytes().all(|byte| byte == b'-' || byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
}

// create / list

#[test]
fn create_writes_source_and_default_manifest_atomically() {
    let fixture = Fixture::new();
    let created = fixture.store.create("My Widget", SOURCE, None).unwrap();
    assert_eq!(created.name, "My Widget");
    assert_eq!(created.directory, fixture.library.join("My Widget"));
    assert!(created.has_manifest);
    assert_eq!(created.manifest_name.as_deref(), Some("My Widget"));
    assert_eq!(created.manifest_version.as_deref(), Some("1.0.0"));
    assert!(is_local_id(created.manifest_id.as_deref().unwrap()), "{:?}", created.manifest_id);
    assert_eq!(std::fs::read_to_string(created.directory.join("main.jsx")).unwrap(), SOURCE);
    let manifest_text = std::fs::read_to_string(created.directory.join("widget.json")).unwrap();
    assert!(!manifest_text.contains('\r'));
    let manifest = parse_object(&manifest_text).unwrap();
    assert_eq!(manifest.opt_i32("formatVersion", 0), 2);
    assert_eq!(manifest.opt_string("runtimeVersion"), "1.0");
    assert_eq!(manifest.opt_string("entry"), "main.jsx");
    assert!(manifest.opt_array("permissions").unwrap().is_empty());
    assert_eq!(tree(&created.directory), ["main.jsx", "widget.json"]);
    assert_eq!(fixture.store.list().unwrap(), [created]);
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn generated_manifests_use_line_feeds_and_keep_unicode() {
    let fixture = Fixture::new();
    let created = fixture.store.create("阅读记录", SOURCE, None).unwrap();
    let text = std::fs::read_to_string(created.directory.join("widget.json")).unwrap();
    assert!(!text.contains('\r'));
    assert!(text.ends_with("]\n}\n"), "{text}");
    assert!(text.contains("\"name\": \"阅读记录\""), "{text}");
    assert_eq!(
        parse_object(&text).unwrap().keys().collect::<Vec<_>>(),
        ["formatVersion", "id", "name", "version", "runtimeVersion", "entry", "supportedFamilies", "permissions", "networkDomains", "plugins", "actions", "controls"]
    );
}

#[test]
fn create_honors_a_supplied_manifest_and_its_entry() {
    let fixture = Fixture::new();
    let manifest = manifest("Custom").replace("\"main.jsx\"", "\"src/app.jsx\"");
    let created = fixture.store.create("Custom", SOURCE, Some(&manifest)).unwrap();
    assert_eq!(created.manifest_id.as_deref(), Some("com.example.widget"));
    assert_eq!(created.manifest_version.as_deref(), Some("1.2.3"));
    assert_eq!(std::fs::read_to_string(created.directory.join("widget.json")).unwrap(), manifest);
    assert_eq!(std::fs::read_to_string(created.directory.join("src/app.jsx")).unwrap(), SOURCE);
}

#[test]
fn create_fails_closed_and_leaves_nothing_behind() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    assert_code("package_exists", store.create("Widget", "other", None));
    assert_code("package_exists", store.create("WIDGET", "other", None));
    let too_long = "a".repeat(81);
    for name in ["", " ", "..", "../escape", "a/b", "a\\b", ".hidden", "__Build", "C:x", &too_long] {
        assert_code("invalid_name", store.create(name, SOURCE, None));
    }
    assert_code("invalid_manifest", store.create("Bad", SOURCE, Some("{not json")));
    assert_code("invalid_manifest", store.create("Bad", SOURCE, Some("[]")));
    assert_code("invalid_manifest", store.create("Bad", SOURCE, Some("{\"name\":\"Bad\"}")));
    assert_code("invalid_manifest", store.create("Bad", SOURCE, Some("{\"entry\":\"main.jsx\",\"entry\":\"other.jsx\"}")));
    for entry in ["../main.jsx", "/main.jsx", "a\\\\b.jsx", "main.txt", "widget.json", ".hidden.js", "__Build/main.js", "C:/main.jsx"] {
        assert_code("invalid_entry", store.create("Bad", SOURCE, Some(&format!("{{\"entry\":\"{entry}\"}}"))));
    }
    assert_code("file_too_large", store.create("Big", &"a".repeat(MAX_SCRIPT_BYTES + 1), None));
    assert_code("file_too_large", store.create("Big", SOURCE, Some(&format!("{{\"entry\":\"main.jsx\",\"description\":\"{}\"}}", "d".repeat(MAX_METADATA_BYTES)))));
    assert!(std::fs::read_to_string(fixture.in_library("Widget/main.jsx")).unwrap().contains("Hello"));
    assert_eq!(fixture.names(), ["Widget"]);
    assert_eq!(tree(&fixture.library), ["Widget/", "Widget/main.jsx", "Widget/widget.json"]);
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn list_reports_only_real_package_directories() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Beta", SOURCE, None).unwrap();
    store.create("Alpha", SOURCE, None).unwrap();
    fixture.write_in_library("Legacy/main.jsx", SOURCE);
    fixture.write_in_library("Broken/widget.json", "{not json");
    fixture.write_in_library("Typed/widget.json", "{\"id\":7,\"name\":[\"x\"],\"version\":\"2.0.0\"}");
    fixture.write_in_library("WrongCase/Widget.JSON", &manifest("WrongCase"));
    std::fs::create_dir_all(fixture.in_library(".hidden")).unwrap();
    std::fs::create_dir_all(fixture.in_library("__Build")).unwrap();
    fixture.write_in_library("stray.txt", "file");
    symlink(&fixture.in_library("Linked"), &fixture.in_library("Alpha"));

    assert_eq!(fixture.names(), ["Alpha", "Beta", "Broken", "Legacy", "Typed", "WrongCase"]);
    assert!(!fixture.find("Legacy").has_manifest);
    assert_eq!(fixture.find("Legacy").manifest_name, None);
    assert!(fixture.find("Broken").has_manifest);
    assert_eq!(fixture.find("Broken").manifest_id, None);
    assert_eq!(fixture.find("Typed").manifest_id, None);
    assert_eq!(fixture.find("Typed").manifest_name, None);
    assert_eq!(fixture.find("Typed").manifest_version.as_deref(), Some("2.0.0"));
    assert!(fixture.find("WrongCase").has_manifest);
    assert_eq!(fixture.find("WrongCase").manifest_name, None);
    assert_code("package_not_found", store.files("Linked"));
    assert_code("package_not_found", store.read_file("Linked", "main.jsx"));
    assert_code("package_not_found", store.delete("Linked"));
    assert_code("package_not_found", store.files("ALPHA"));
}

#[test]
fn library_root_must_not_be_a_link() {
    let fixture = Fixture::new();
    let real = fixture.temporary.new_folder("real");
    let alias = fixture.temporary.path("alias");
    symlink(&alias, &real);
    let linked = PackageStore::new(&alias, &fixture.staging);
    assert_code("storage_unavailable", linked.list());
    assert_code("storage_unavailable", linked.create("Widget", SOURCE, None));
    assert_code("storage_unavailable", linked.import_archive(&mut &widget_zip()[..], None, None));
    assert!(tree(&real).is_empty());
    assert!(fixture.staging_tree().is_empty());
}

// import

#[test]
fn import_installs_under_the_manifest_name_not_the_archive_name() {
    let fixture = Fixture::new();
    let installed = fixture.import(&package_zip("ArchiveFolder", "Manifest Name", &[("src/a.js", "a")]), Some("FileName")).unwrap();
    assert_eq!(installed.name, "Manifest Name");
    assert_eq!(installed.manifest_name.as_deref(), Some("Manifest Name"));
    assert_eq!(installed.manifest_id.as_deref(), Some("com.example.widget"));
    assert_eq!(installed.manifest_version.as_deref(), Some("1.2.3"));
    assert_eq!(fixture.store.files("Manifest Name").unwrap().paths(), ["main.jsx", "src/a.js", "widget.json"]);
    assert_eq!(fixture.names(), ["Manifest Name"]);
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn import_picks_a_unique_name_on_collision() {
    let fixture = Fixture::new();
    assert_eq!(fixture.import(&widget_zip(), None).unwrap().name, "Widget");
    assert_eq!(fixture.import(&widget_zip(), None).unwrap().name, "Widget (1)");
    assert_eq!(fixture.import(&widget_zip(), None).unwrap().name, "Widget (2)");
    assert_eq!(fixture.import(&package_zip("Widget", "WIDGET", &[]), None).unwrap().name, "WIDGET (3)");
    assert_eq!(parse_object(&fixture.read_text("Widget (1)", "widget.json")).unwrap().opt_string("name"), "Widget");
    assert_eq!(fixture.names(), ["WIDGET (3)", "Widget", "Widget (1)", "Widget (2)"]);
}

#[test]
fn unique_name_shortens_the_stem_and_skips_case_and_normalization_aliases() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    assert_eq!(store.unique_name("Fresh").unwrap(), "Fresh");
    let long_name = "a".repeat(80);
    store.create(&long_name, SOURCE, None).unwrap();
    assert_eq!(store.unique_name(&long_name).unwrap(), "a".repeat(76) + " (1)");
    store.create("Caf\u{E9}", SOURCE, None).unwrap();
    assert_eq!(store.unique_name("Caf\u{E9}").unwrap(), "Caf\u{E9} (1)");
    assert_eq!(store.unique_name("CAF\u{C9}").unwrap(), "CAF\u{C9} (1)");
    assert_eq!(store.unique_name("Cafe\u{301}").unwrap(), "Cafe\u{301} (1)");
    store.create("Caf\u{E9} (1)", SOURCE, None).unwrap();
    assert_eq!(store.unique_name("Caf\u{E9}").unwrap(), "Caf\u{E9} (2)");
    assert_code("invalid_name", store.unique_name("../x"));
    // Compared in upper case: the Kelvin sign is the letter K.
    store.create("Kelvin", SOURCE, None).unwrap();
    assert_code("package_exists", store.create("\u{212A}elvin", SOURCE, None));
    assert_eq!(store.unique_name("\u{212A}elvin").unwrap(), "\u{212A}elvin (1)");
}

#[test]
fn import_migrates_legacy_packages() {
    let fixture = Fixture::new();
    let meta = "{\"description\":\"Old\",\"category\":\"Tools\",\"tags\":[\"a\",\"b\"],\"featured\":true,\"icon\":5}";
    let nested = fixture.import(&raw_zip(&[RawEntry::new("Old Widget/main.jsx", SOURCE), RawEntry::new("Old Widget/meta.json", meta)]), Some("ignored")).unwrap();
    assert_eq!(nested.name, "Old Widget");
    assert!(nested.has_manifest);
    assert_eq!(nested.manifest_id.as_deref(), Some("legacy.old-widget"));
    let manifest = parse_object(&fixture.read_text("Old Widget", "widget.json")).unwrap();
    assert_eq!(manifest.opt_string("description"), "Old");
    assert_eq!(manifest.opt_string("category"), "Tools");
    assert_eq!(manifest.opt_array("tags").unwrap().len(), 2);
    assert!(!manifest.has("featured"));
    assert!(!manifest.has("icon"));
    assert_eq!(manifest.opt_string("entry"), "main.jsx");

    assert_eq!(fixture.import(&raw_zip(&[RawEntry::new("main.jsx", SOURCE), RawEntry::new("meta.json", "{broken")]), Some("Shared File")).unwrap().name, "Shared File");
    assert_eq!(fixture.import(&raw_zip(&[RawEntry::new("main.jsx", SOURCE)]), Some("../bad")).unwrap().name, "Imported Widget");
    assert_eq!(fixture.import(&raw_zip(&[RawEntry::new("main.jsx", SOURCE)]), None).unwrap().name, "Imported Widget (1)");
}

#[test]
fn rejected_imports_leave_nothing_in_library_or_staging() {
    let fixture = Fixture::new();
    fixture.store.create("Existing", SOURCE, None).unwrap();
    let before = tree(&fixture.library);
    let main = || RawEntry::new("W/main.jsx", SOURCE);
    let with_manifest = |content: &[u8]| raw_zip(&[RawEntry::new("W/widget.json", content), main()]);
    let long_root = format!("{}/main.jsx", "n".repeat(81));
    let rejected: Vec<(&str, &[&str], Vec<u8>)> = vec![
        ("traversal", &["archive_unsafe_path"], raw_zip(&[main(), RawEntry::new("../Existing/main.jsx", "owned")])),
        ("absolute", &["archive_unsafe_path"], raw_zip(&[RawEntry::new("/W/main.jsx", SOURCE)])),
        ("backslash", &["archive_unsafe_path"], raw_zip(&[RawEntry::new("W\\main.jsx", SOURCE)])),
        ("symlink", &["archive_symlink"], raw_zip(&[main(), RawEntry::new("W/link", "../Existing").mode(SYMBOLIC_LINK)])),
        ("collision", &["archive_path_collision"], raw_zip(&[main(), RawEntry::new("W/MAIN.jsx", SOURCE)])),
        ("entries", &["archive_too_many_entries"], raw_zip(&(0..501).map(|index| RawEntry::new(&format!("W/f{index}.js"), "x")).collect::<Vec<_>>())),
        ("file size", &["archive_file_too_large"], raw_zip(&[main().declared_size(MAX_FILE_BYTES + 1)])),
        // Both codes: see `assert_lying_size_rejected`.
        ("bomb", &["archive_size_mismatch", "archive_corrupt"], forge_declared_size(&deflated_zip(&[("W/main.jsx", SOURCE.as_bytes()), ("W/bomb.bin", &vec![0; 8 * 1024 * 1024])]), 1, 8)),
        ("no package", &["archive_no_package"], raw_zip(&[RawEntry::new("A/main.jsx", SOURCE), RawEntry::new("B/main.jsx", SOURCE)])),
        ("wrong-case manifest", &["invalid_manifest_case"], raw_zip(&[RawEntry::new("W/Widget.json", manifest("W")), main()])),
        ("malformed manifest", &["invalid_manifest"], with_manifest(b"{bad")),
        ("non-object manifest", &["invalid_manifest"], with_manifest(b"[1]")),
        ("non-UTF-8 manifest", &["invalid_manifest"], with_manifest(&[0x7B, 0xC3, 0x28, 0x7D])),
        ("nameless manifest", &["invalid_manifest"], with_manifest(b"{\"name\":5}")),
        ("empty manifest", &["invalid_manifest"], with_manifest(b"")),
        ("manifest with trailing text", &["invalid_manifest"], with_manifest(b"{\"name\":\"W\"} trailing")),
        ("manifest with a comment", &["invalid_manifest"], with_manifest(b"{\"name\":\"W\" /* c */}")),
        ("manifest with a duplicate key", &["invalid_manifest"], with_manifest(b"{\"name\":\"W\",\"name\":\"Existing\"}")),
        ("oversized manifest", &["invalid_manifest"], with_manifest(format!("{{\"name\":\"W\",\"description\":\"{}\"}}", "d".repeat(MAX_METADATA_BYTES)).as_bytes())),
        ("unsafe manifest name", &["invalid_name"], package_zip("Widget", "../Existing", &[])),
        ("reserved manifest name", &["invalid_name"], package_zip("Widget", "__Build", &[])),
        ("legacy without entry", &["missing_entry"], raw_zip(&[RawEntry::new("W/other.jsx", SOURCE)])),
        ("unsafe legacy name", &["invalid_name"], raw_zip(&[RawEntry::new(&long_root, SOURCE)])),
    ];
    for (label, codes, archive) in rejected {
        let error = fixture.import(&archive, Some("Suggested")).expect_err(label);
        assert!(codes.contains(&error.code.as_str()), "{label}: {error}");
        assert_eq!(tree(&fixture.library), before, "{label}");
        assert!(fixture.staging_tree().is_empty(), "{label}");
    }
}

#[test]
fn validation_hook_runs_before_publication_and_can_veto() {
    let fixture = Fixture::new();
    let seen = std::cell::RefCell::new(Vec::new());
    let veto = |files: &dyn PackageFiles| -> Result<(), PackageError> {
        *seen.borrow_mut() = files.paths();
        assert!(files.read_text("widget.json").unwrap().contains("\"runtimeVersion\""));
        Err(PackageError::new("unsupported_runtime", "Runtime 9.0 is incompatible with 1.0."))
    };
    assert_code("unsupported_runtime", fixture.store.import_archive(&mut &widget_zip()[..], None, Some(&veto)));
    assert_eq!(*seen.borrow(), ["main.jsx", "widget.json"]);
    assert!(fixture.names().is_empty());
    assert!(tree(&fixture.library).is_empty());
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn import_never_installs_build_caches_or_hidden_files() {
    let fixture = Fixture::new();
    let archive = raw_zip(&[
        RawEntry::new("W/widget.json", manifest("Clean")),
        RawEntry::new("W/main.jsx", SOURCE),
        RawEntry::new("W/__Build/main.js", "planted"),
        RawEntry::new("W/src/__Build/deep.js", "planted"),
        RawEntry::new("W/src/ok.js", "ok"),
        RawEntry::new("W/.env", "SECRET=1"),
        RawEntry::new("__MACOSX/W/._main.jsx", "fork"),
    ]);
    assert_eq!(fixture.import(&archive, None).unwrap().name, "Clean");
    assert_eq!(tree(&fixture.in_library("Clean")), ["main.jsx", "src/", "src/ok.js", "widget.json"]);
}

#[test]
fn concurrent_imports_get_names_and_staging_directories_of_their_own() {
    let fixture = Fixture::new();
    let archive = widget_zip();
    let mut installed: Vec<String> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..12).map(|_| scope.spawn(|| fixture.import(&archive, None).unwrap().name)).collect();
        workers.into_iter().map(|worker| worker.join().unwrap()).collect()
    });
    installed.sort_unstable();
    let mut expected: Vec<String> = std::iter::once("Widget".to_owned()).chain((1..12).map(|index| format!("Widget ({index})"))).collect();
    expected.sort_unstable();
    assert_eq!(installed, expected);
    assert_eq!(fixture.names(), expected);
    for name in &expected {
        assert_eq!(tree(&fixture.in_library(name)), ["main.jsx", "widget.json"], "{name}");
    }
    assert!(fixture.staging_tree().is_empty());
}

// export

#[test]
fn export_then_import_round_trips_the_package() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Round Trip", SOURCE, None).unwrap();
    store.write_file("Round Trip", "src/lib/util.js", b"export default 1;").unwrap();
    store.write_file("Round Trip", "image/logo.png", &(0..4096).map(|index| (index * 7) as u8).collect::<Vec<u8>>()).unwrap();
    fixture.write_in_library("Round Trip/__Build/main.js", "compiled");
    fixture.write_in_library("Round Trip/.DS_Store", "junk");
    symlink(&fixture.in_library("Round Trip/link.js"), &fixture.in_library("Round Trip/main.jsx"));

    let archive_bytes = fixture.export("Round Trip").unwrap();
    assert_eq!(fixture.export("Round Trip").unwrap(), archive_bytes);
    assert_eq!(
        archive::preflight(&archive_bytes, &Default::default()).unwrap(),
        ["Round Trip/image/logo.png", "Round Trip/main.jsx", "Round Trip/src/lib/util.js", "Round Trip/widget.json"]
    );
    let copy = fixture.import(&archive_bytes, None).unwrap();
    assert_eq!(copy.name, "Round Trip (1)");
    let original = store.files("Round Trip").unwrap();
    let imported = store.files(&copy.name).unwrap();
    assert_eq!(original.paths(), imported.paths());
    for path in original.paths() {
        assert_eq!(original.read_bytes(&path), imported.read_bytes(&path), "{path}");
    }
    assert_eq!(fixture.find("Round Trip").manifest_id, copy.manifest_id);
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn export_migrates_legacy_packages_without_touching_the_library() {
    let fixture = Fixture::new();
    fixture.write_in_library("Legacy/main.jsx", SOURCE);
    fixture.write_in_library("Legacy/meta.json", "{\"description\":\"Old\"}");
    let archive_bytes = fixture.export("Legacy").unwrap();
    assert_eq!(archive::preflight(&archive_bytes, &Default::default()).unwrap(), ["Legacy/main.jsx", "Legacy/meta.json", "Legacy/widget.json"]);
    assert!(!fixture.in_library("Legacy/widget.json").exists());
    std::fs::remove_dir_all(fixture.in_library("Legacy")).unwrap();
    let imported = fixture.import(&archive_bytes, None).unwrap();
    assert_eq!(imported.name, "Legacy");
    assert_eq!(imported.manifest_id.as_deref(), Some("legacy.legacy"));
    assert_eq!(parse_object(&fixture.read_text("Legacy", "widget.json")).unwrap().opt_string("description"), "Old");
}

#[test]
fn export_refuses_invalid_packages() {
    let fixture = Fixture::new();
    fixture.write_in_library("Broken/widget.json", "{bad");
    fixture.write_in_library("Broken/main.jsx", SOURCE);
    fixture.write_in_library("Cased/WIDGET.json", &manifest("Cased"));
    std::fs::create_dir_all(fixture.in_library("Empty")).unwrap();
    let mut output = Vec::new();
    assert_code("invalid_manifest", fixture.store.export_archive("Broken", &mut output));
    assert_code("invalid_manifest_case", fixture.store.export_archive("Cased", &mut output));
    assert_code("missing_entry", fixture.store.export_archive("Empty", &mut output));
    assert_code("package_not_found", fixture.store.export_archive("Missing", &mut output));
    assert_code("invalid_name", fixture.store.export_archive("../Broken", &mut output));
    assert!(output.is_empty());
}

// duplicate / rename / delete

#[test]
fn duplicate_copies_files_and_refreshes_identity() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    let original = store.create("Widget", SOURCE, None).unwrap();
    store.write_file("Widget", "src/a.js", b"a").unwrap();
    fixture.write_in_library("Widget/__Build/main.js", "compiled");
    fixture.write_in_library("Widget/.DS_Store", "junk");

    let copy = store.duplicate("Widget").unwrap();
    assert_eq!(copy.name, "Widget Remix");
    assert_eq!(copy.manifest_name.as_deref(), Some("Widget Remix"));
    assert_ne!(original.manifest_id, copy.manifest_id);
    assert!(is_local_id(copy.manifest_id.as_deref().unwrap()));
    assert_eq!(tree(&copy.directory), ["main.jsx", "src/", "src/a.js", "widget.json"]);
    assert_eq!(fixture.read_text("Widget Remix", "main.jsx"), SOURCE);
    assert_eq!(fixture.find("Widget").manifest_name.as_deref(), Some("Widget"));
    assert_eq!(store.duplicate("Widget").unwrap().name, "Widget Remix (1)");
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn duplicate_keeps_legacy_packages_legacy_and_rejects_unsafe_sources() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    fixture.write_in_library("Legacy/main.jsx", SOURCE);
    let copy = store.duplicate("Legacy").unwrap();
    assert_eq!(copy.name, "Legacy Remix");
    assert!(!copy.has_manifest);
    assert_eq!(tree(&copy.directory), ["main.jsx"]);

    let secret = fixture.temporary.new_file("secret.txt", "");
    symlink(&fixture.in_library("Legacy/link.txt"), &secret);
    assert_code("unsafe_file", store.duplicate("Legacy"));
    fixture.write_in_library("Broken/widget.json", "{bad");
    assert_code("invalid_manifest", store.duplicate("Broken"));
    assert_code("package_not_found", store.duplicate("Missing"));
    assert_eq!(fixture.names(), ["Broken", "Legacy", "Legacy Remix"]);
    assert!(fixture.staging_tree().is_empty());
}

#[test]
fn rename_moves_the_directory_and_refuses_collisions() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    store.create("Other", SOURCE, None).unwrap();
    let renamed = store.rename("Widget", "阅读记录").unwrap();
    assert_eq!(renamed.name, "阅读记录");
    assert_eq!(renamed.manifest_name.as_deref(), Some("Widget"));
    assert_eq!(fixture.names(), ["Other", "阅读记录"]);
    assert_eq!(store.rename("阅读记录", "阅读记录").unwrap().name, "阅读记录");
    assert_code("package_exists", store.rename("阅读记录", "Other"));
    assert_code("package_exists", store.rename("阅读记录", "OTHER"));
    assert_code("package_exists", store.rename("Other", "other"));
    assert_code("invalid_name", store.rename("Other", "../escape"));
    assert_code("invalid_name", store.rename("Other", "__Build"));
    assert_code("package_not_found", store.rename("Widget", "Again"));
    assert_eq!(fixture.names(), ["Other", "阅读记录"]);
}

#[test]
fn delete_removes_the_package_without_following_links() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    let keep = fixture.temporary.new_folder("keep");
    std::fs::write(keep.join("precious.txt"), "keep me").unwrap();
    symlink(&fixture.in_library("Widget/link"), &keep);
    symlink(&fixture.in_library("Widget/file-link"), &keep.join("precious.txt"));
    store.delete("Widget").unwrap();
    assert!(fixture.names().is_empty());
    assert!(!fixture.in_library("Widget").exists());
    assert_eq!(std::fs::read_to_string(keep.join("precious.txt")).unwrap(), "keep me");
    assert!(fixture.staging_tree().is_empty());
    assert_code("package_not_found", store.delete("Widget"));
    assert_code("invalid_name", store.delete(".."));
}

// write_file / read_file

#[test]
fn write_file_replaces_content_atomically() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    store.write_file("Widget", "main.jsx", b"new source").unwrap();
    store.write_file("Widget", "src/deep/util.js", b"util").unwrap();
    store.write_file("Widget", "src/deep/util.js", b"util 2").unwrap();
    assert_eq!(fixture.read_text("Widget", "main.jsx"), "new source");
    assert_eq!(fixture.read_text("Widget", "src/deep/util.js"), "util 2");
    // No temporary file may remain.
    assert_eq!(tree(&fixture.in_library("Widget")), ["main.jsx", "src/", "src/deep/", "src/deep/util.js", "widget.json"]);
}

#[test]
fn write_file_rejects_unsafe_paths_and_keeps_old_content() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    std::fs::create_dir_all(fixture.in_library("Sibling")).unwrap();
    let before = tree(&fixture.library);
    let absolute = fixture.in_library("Sibling/x.js").to_string_lossy().into_owned();
    let too_deep = support::nested("d", 17);
    let too_long = "x".repeat(256);
    let unsafe_paths = [
        "",
        "/",
        "..",
        "../Sibling/main.jsx",
        "src/../../Sibling/x.js",
        "src/../main.jsx",
        "./main.jsx",
        "/main.jsx",
        &absolute,
        "src\\x.js",
        "..\\Sibling\\x.js",
        "main\0.jsx",
        "C:x.js",
        ".hidden",
        "src/.hidden/x.js",
        "__Build/main.js",
        "src/__BUILD/main.js",
        &too_deep,
        &too_long,
    ];
    for path in unsafe_paths {
        assert_code("invalid_path", store.write_file("Widget", path, b"owned"));
    }
    assert_code("invalid_manifest_case", store.write_file("Widget", "Widget.json", b"{}"));
    assert_code("unsafe_file", store.write_file("Widget", "MAIN.jsx", b"owned"));
    assert_code("unsafe_file", store.write_file("Widget", "main.jsx/child.js", b"owned"));
    assert_code("file_too_large", store.write_file("Widget", "big.bin", &vec![0; MAX_FILE_BYTES as usize + 1]));
    assert_code("file_too_large", store.write_file("Widget", "widget.json", &vec![0; MAX_METADATA_BYTES + 1]));
    assert_code("package_not_found", store.write_file("Missing", "main.jsx", b"x"));
    assert_code("invalid_name", store.write_file("../Sibling", "main.jsx", b"x"));
    assert_eq!(tree(&fixture.library), before);
    assert_eq!(fixture.read_text("Widget", "main.jsx"), SOURCE);
}

#[test]
fn write_file_never_writes_through_links() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    let outside = fixture.temporary.new_folder("outside");
    let victim = outside.join("victim.txt");
    std::fs::write(&victim, "original").unwrap();
    symlink(&fixture.in_library("Widget/link.txt"), &victim);
    symlink(&fixture.in_library("Widget/linkdir"), &outside);
    symlink(&fixture.in_library("Widget/dangling.txt"), &outside.join("created.txt"));
    hard_link(&fixture.in_library("Widget/hard.txt"), &victim);

    for path in ["link.txt", "linkdir/victim.txt", "linkdir/new.txt", "linkdir/sub/new.txt", "dangling.txt", "hard.txt"] {
        assert_code("unsafe_file", store.write_file("Widget", path, b"owned"));
    }
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "original");
    assert_eq!(tree(&outside), ["victim.txt"]);
    for path in ["link.txt", "linkdir/victim.txt", "dangling.txt", "hard.txt"] {
        assert_code("file_not_found", store.read_file("Widget", path));
    }
}

#[test]
fn write_file_enforces_the_entry_limit() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    for index in 0..MAX_FILE_COUNT - 2 {
        fixture.write_in_library(&format!("Widget/f{index}.txt"), "x");
    }
    assert_code("too_many_entries", store.write_file("Widget", "one-more.txt", b"x"));
    store.write_file("Widget", "f0.txt", b"replaced").unwrap();
    assert_eq!(fixture.read_text("Widget", "f0.txt"), "replaced");
}

#[test]
fn read_file_reports_missing_and_unsafe_paths() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    store.create("Widget", SOURCE, None).unwrap();
    assert_eq!(fixture.read_text("Widget", "main.jsx"), SOURCE);
    assert_code("file_not_found", store.read_file("Widget", "missing.js"));
    assert_code("file_not_found", store.read_file("Widget", "MAIN.JSX"));
    assert_code("invalid_path", store.read_file("Widget", "../Widget/main.jsx"));
    assert_code("invalid_path", store.read_file("Widget", "/etc/hosts"));
    assert_code("invalid_path", store.read_file("Widget", "a\\b"));
    assert_code("package_not_found", store.read_file("Missing", "main.jsx"));
}
