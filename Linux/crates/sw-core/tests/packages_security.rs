//! The package security rules of `docs/linux/plan.md` section 6, one test per
//! rule. The Linux counterpart of `WindowsPackageSecurityTests.cs`: where
//! that file tests what Win32 does to names, this one tests what a Unix
//! filesystem allows (symbolic links, hard links, special files, file modes,
//! names that are not UTF-8, two spellings of one name side by side).
//!
//! The descriptor-level rules (`openat2` with `RESOLVE_BENEATH`, and its
//! fallback) are tested next to the code, in `src/packages/safe_files.rs`.

#[path = "packages_support/mod.rs"]
mod support;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use support::{RawEntry, SOURCE, TemporaryFolder, assert_code, entry, hard_link, manifest, mode, nested, package_zip, permissions_are_not_enforced, raw_zip, set_mode, symlink, tree, widget_zip, write_file};
use sw_core::compiler::PrepareOptions;
use sw_core::json::ObjectExt;
use sw_core::packages::{ArchiveLimits, PackageError, PackageStore, archive, manifests, names, path_rules, validate_tree};
use sw_core::{ExecutionRequest, PackageCompiler, PackageFiles, ScriptExecutor, SharedScripts};

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

    /// A store with one package, "Widget".
    fn with_widget() -> Self {
        let fixture = Self::new();
        fixture.store.create("Widget", SOURCE, None).unwrap();
        fixture
    }

    fn in_library(&self, path: &str) -> PathBuf {
        self.library.join(path)
    }

    #[cfg(target_os = "linux")]
    fn find_manifest_name(&self, name: &str) -> Option<String> {
        self.store.list().unwrap().into_iter().find(|package| package.name == name).and_then(|package| package.manifest_name)
    }

    fn names(&self) -> Vec<String> {
        self.store.list().unwrap().into_iter().map(|package| package.name).collect()
    }

    fn import(&self, archive: &[u8]) -> Result<String, PackageError> {
        self.store.import_archive(&mut &archive[..], None, None).map(|package| package.name)
    }

    fn exported_names(&self, name: &str) -> Vec<String> {
        let mut output = Vec::new();
        self.store.export_archive(name, &mut output).unwrap();
        archive::preflight(&output, &ArchiveLimits::default()).unwrap()
    }

    /// The path is refused for reading and for writing, and nothing on disk changes.
    #[track_caller]
    fn assert_invalid_path(&self, path: &str) {
        let before = tree(&self.temporary.root);
        assert!(path_rules::components(path).is_none(), "{path:?}");
        assert!(path_rules::visible_components(path).is_none(), "{path:?}");
        assert_code("invalid_path", self.store.write_file("Widget", path, b"owned"));
        assert_code("invalid_path", self.store.read_file("Widget", path));
        let files = self.store.files("Widget").unwrap();
        assert!(!files.exists(path), "{path:?}");
        assert_eq!(files.read_bytes(path), None, "{path:?}");
        assert_eq!(files.read_text(path), None, "{path:?}");
        assert_eq!(tree(&self.temporary.root), before, "{path:?}");
    }

    /// The archive is refused by the preflight, by a bare import and by the store, and nothing is left anywhere.
    #[track_caller]
    fn assert_archive_refused(&self, code: &str, archive_bytes: &[u8]) {
        let before = tree(&self.library);
        assert_code(code, archive::preflight(archive_bytes, &ArchiveLimits::default()));
        assert_code(code, archive::import_to(&mut &archive_bytes[..], &self.staging, &self.library.join("Target"), &ArchiveLimits::default()));
        assert_code(code, self.import(archive_bytes));
        assert_eq!(tree(&self.library), before);
        assert!(tree(&self.staging).is_empty());
    }
}

fn default_limits() -> ArchiveLimits {
    ArchiveLimits::default()
}

/// The name alone, as a directory, and below a directory.
fn in_every_segment(name: &str) -> [String; 4] {
    [name.to_owned(), format!("{name}/main.jsx"), format!("src/{name}"), format!("src/{name}/deep/x.js")]
}

// Paths: traversal, absolute paths, backslashes

#[test]
fn traversal_is_refused_for_reads_writes_and_archives() {
    let fixture = Fixture::with_widget();
    write_file(&fixture.in_library("Sibling/secret.js"), b"secret");
    for path in ["..", "../Sibling/secret.js", "src/../../Sibling/secret.js", "src/../main.jsx", "./main.jsx", "src/./a.js", "src//a.js", "main.jsx/..", "a/../../../etc/passwd"] {
        fixture.assert_invalid_path(path);
    }
    for name in ["../Sibling/owned.js", "Widget/../../Sibling/owned.js", "Widget/../main.jsx", "..", "Widget/./main.jsx", "./main.jsx", "Widget/a/../../../escape"] {
        fixture.assert_archive_refused("archive_unsafe_path", &raw_zip(&[RawEntry::new("Widget/main.jsx", SOURCE), RawEntry::new(name, "owned")]));
    }
    assert_eq!(tree(&fixture.in_library("Sibling")), ["secret.js"]);
}

#[test]
fn absolute_paths_are_refused_for_reads_writes_and_archives() {
    let fixture = Fixture::with_widget();
    write_file(&fixture.in_library("Sibling/secret.js"), b"secret");
    let inside = fixture.in_library("Widget/main.jsx").to_string_lossy().into_owned();
    let outside = fixture.in_library("Sibling/secret.js").to_string_lossy().into_owned();
    for path in ["/", "/etc/passwd", "/main.jsx", "//server/share/x.js", &inside, &outside] {
        fixture.assert_invalid_path(path);
    }
    let absolute_entry = format!("{}/owned.js", fixture.in_library("Sibling").to_string_lossy());
    for name in ["/etc/passwd", "/Widget/main.jsx", "//server/share/x.js", &absolute_entry] {
        fixture.assert_archive_refused("archive_unsafe_path", &raw_zip(&[RawEntry::new("Widget/main.jsx", SOURCE), RawEntry::new(name, "owned")]));
    }
    assert_eq!(tree(&fixture.in_library("Sibling")), ["secret.js"]);
}

#[test]
fn backslashes_are_refused_for_reads_writes_and_archives() {
    let fixture = Fixture::with_widget();
    // On Linux a backslash is an ordinary character of a file name; in a package it never is.
    for path in ["src\\x.js", "..\\Sibling\\x.js", "\\x", "a\\..\\b", "C:\\x", "\\\\server\\share\\x.js", "\\\\?\\C:\\x"] {
        fixture.assert_invalid_path(path);
    }
    for name in ["Widget\\main2.jsx", "\\Widget\\main.jsx", "Widget/..\\..\\escape.txt", "Widget/a\\b.js"] {
        fixture.assert_archive_refused("archive_unsafe_path", &raw_zip(&[RawEntry::new("Widget/main.jsx", SOURCE), RawEntry::new(name, "owned")]));
    }
    // A file with such a name that got into the directory some other way is not part of the package either.
    write_file(&fixture.in_library("Widget/back\\slash.js"), b"x");
    assert_eq!(fixture.store.files("Widget").unwrap().paths(), ["main.jsx", "widget.json"]);
    assert_code("invalid_path", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_code("invalid_path", fixture.store.duplicate("Widget"));
}

#[test]
fn control_characters_drive_prefixes_and_overlong_names_are_refused() {
    let fixture = Fixture::with_widget();
    for name in ["a\u{1}b", "a\u{1F}b", "a\tb", "a\rb", "line\nbreak.js", "bidi\u{202E}.js", "zero\u{200B}width.js"] {
        for path in in_every_segment(name) {
            fixture.assert_invalid_path(&path);
        }
    }
    // What Windows would read as a drive: refused at the start of a path, as on every platform.
    for path in ["C:x.js", "c:", "Z:main.jsx", "C:x/main.jsx", "C:/Widget/main.jsx"] {
        fixture.assert_invalid_path(path);
    }
    fixture.assert_invalid_path("main\0.jsx");
    assert_eq!(path_rules::components(&"x".repeat(255)).map(|parts| parts.len()), Some(1));
    fixture.assert_invalid_path(&"x".repeat(256));
    fixture.assert_invalid_path(&format!("src/{}/a.js", "x".repeat(256)));
    // 86 three-byte characters are 258 UTF-8 bytes, more than a Linux file name holds.
    fixture.assert_invalid_path(&"漢".repeat(86));
    assert!(path_rules::components(&"漢".repeat(85)).is_some());
    assert_eq!(path_rules::components(&nested("d", 16)).map(|parts| parts.len()), Some(16));
    fixture.assert_invalid_path(&nested("d", 17));
}

// Names that only Windows refuses

#[test]
fn names_only_win32_cannot_store_are_ordinary_names_as_on_android() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    // Reserved device names, trailing dots and spaces, and the characters Win32 reserves.
    let windows_only = ["CON", "nul.txt", "COM1.jsx", "aux", "name.", "name ", "a<b>.js", "what?.js", "star*.js", "pipe|line", "say \"hi\".txt"];
    for name in windows_only {
        assert!(path_rules::valid_component(name), "{name:?}");
        let path = format!("data/{name}");
        store.write_file("Widget", &path, name.as_bytes()).unwrap();
        assert_eq!(store.read_file("Widget", &path).unwrap(), name.as_bytes(), "{name:?}");
    }
    assert_eq!(store.files("Widget").unwrap().paths().len(), 2 + windows_only.len());
    validate_tree(&fixture.in_library("Widget"), &default_limits()).unwrap();

    // They survive an export and an import, as they do between two Android devices.
    let mut exported = Vec::new();
    store.export_archive("Widget", &mut exported).unwrap();
    let copy = store.import_archive(&mut &exported[..], None, None).unwrap();
    assert_eq!(store.files(&copy.name).unwrap().paths(), store.files("Widget").unwrap().paths());

    // The same goes for package names; the manifest name is the directory name, unchanged.
    for name in ["Ratio 16:9", "Notes?", "a*b", "Trailing.", "CON", "nul.txt"] {
        assert!(names::is_valid(name), "{name:?}");
        assert_eq!(fixture.import(&package_zip("W", name, &[])).unwrap(), name);
    }
    assert_eq!(store.rename("Notes?", "What?").unwrap().name, "What?");
}

#[test]
fn a_colon_in_an_archive_entry_is_refused_on_every_platform() {
    let fixture = Fixture::with_widget();
    // Drive and stream syntax on Windows: every importer refuses it, so an archive holding it is not a package anywhere.
    for name in ["Widget/a:b.txt", "Widget/main.jsx:stream", "Widget/main.jsx::$DATA", "C:/Widget/x.js", "C:x.js", "Widget/:x", "Widget/sub:dir/x.js"] {
        fixture.assert_archive_refused("archive_unsafe_path", &raw_zip(&[RawEntry::new("Widget/main.jsx", SOURCE), RawEntry::new(name, "owned")]));
    }
    // Entries below __MACOSX, __Build and dot-directories are never extracted, but the whole archive is still refused.
    for name in ["__MACOSX/Widget/a:b", "Widget/__Build/a:b.js", "Widget/.git/a:b", "Widget/.cache/../x", "__MACOSX/../x", "Widget/.hidden/a\\b"] {
        fixture.assert_archive_refused("archive_unsafe_path", &raw_zip(&[RawEntry::new("Widget/main.jsx", SOURCE), RawEntry::new(name, "x")]));
    }
}

// Symbolic links

#[test]
fn symbolic_links_are_refused_at_every_component_and_never_followed() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    let outside = fixture.temporary.new_folder("outside");
    write_file(&outside.join("secret.js"), b"secret()");
    symlink(&fixture.in_library("Widget/out"), &outside);
    symlink(&fixture.in_library("Widget/src/deep/out"), &outside);
    symlink(&fixture.in_library("Widget/self"), &fixture.in_library("Widget"));
    symlink(&fixture.in_library("Widget/up"), Path::new(".."));
    symlink(&fixture.in_library("Widget/secret.js"), &outside.join("secret.js"));
    symlink(&fixture.in_library("Widget/relative.jsx"), Path::new("main.jsx"));
    symlink(&fixture.in_library("Widget/dangling.js"), &outside.join("created.js"));
    symlink(&fixture.in_library("Aliased"), &fixture.in_library("Widget"));
    assert!(fixture.in_library("Widget/out/secret.js").exists(), "the links work for a program that follows them");

    let files = store.files("Widget").unwrap();
    assert_eq!(files.paths(), ["main.jsx", "widget.json"]);
    for path in ["out/secret.js", "src/deep/out/secret.js", "self/main.jsx", "up/Widget/main.jsx", "secret.js", "relative.jsx", "dangling.js", "out", "self"] {
        assert!(!files.exists(path), "{path}");
        assert_eq!(files.read_bytes(path), None, "{path}");
        assert_eq!(files.read_text(path), None, "{path}");
        assert_code("file_not_found", store.read_file("Widget", path));
    }
    for path in ["out/new.js", "out/sub/new.js", "src/deep/out/new.js", "self/main.jsx", "up/owned.js", "secret.js", "relative.jsx", "dangling.js", "out"] {
        assert_code("unsafe_file", store.write_file("Widget", path, b"owned"));
    }
    assert_eq!(tree(&outside), ["secret.js"]);
    assert_eq!(std::fs::read(outside.join("secret.js")).unwrap(), b"secret()");
    assert_eq!(std::fs::read_to_string(fixture.in_library("Widget/main.jsx")).unwrap(), SOURCE);

    assert_code("unsafe_file", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_code("unsafe_file", validate_tree(&fixture.in_library("Aliased"), &default_limits()));
    assert_code("unsafe_file", store.duplicate("Widget"));
    assert_eq!(fixture.names(), ["Widget"]);
    assert_code("package_not_found", store.files("Aliased"));
    assert_code("package_not_found", store.write_file("Aliased", "main.jsx", b"owned"));
    assert_code("package_not_found", store.delete("Aliased"));

    // Export leaves the links out; delete removes them without touching their targets.
    assert_eq!(fixture.exported_names("Widget"), ["Widget/main.jsx", "Widget/widget.json"]);
    store.delete("Widget").unwrap();
    assert!(!fixture.in_library("Widget").exists());
    assert_eq!(tree(&outside), ["secret.js"]);
    assert_eq!(std::fs::read(outside.join("secret.js")).unwrap(), b"secret()");
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn staging_and_library_roots_must_not_be_links() {
    let fixture = Fixture::new();
    let real = fixture.temporary.new_folder("real-staging");
    let alias = fixture.temporary.path("staging-alias");
    symlink(&alias, &real);
    let linked = PackageStore::new(&fixture.library, &alias);
    assert_code("storage_unavailable", linked.create("Widget", SOURCE, None));
    assert_code("storage_unavailable", linked.import_archive(&mut &widget_zip()[..], None, None));
    assert_code("storage_unavailable", archive::extract(&mut &widget_zip()[..], &alias, &default_limits()));
    assert!(tree(&real).is_empty());
    assert!(linked.list().unwrap().is_empty());

    let real_library = fixture.temporary.new_folder("real-library");
    let library_alias = fixture.temporary.path("library-alias");
    symlink(&library_alias, &real_library);
    let linked = PackageStore::new(&library_alias, &fixture.staging);
    assert_code("storage_unavailable", linked.list());
    assert_code("storage_unavailable", linked.create("Widget", SOURCE, None));
    assert_code("storage_unavailable", linked.import_archive(&mut &widget_zip()[..], None, None));
    assert!(tree(&real_library).is_empty());
    assert!(tree(&fixture.staging).is_empty());
}

// Hard links

#[test]
fn hard_linked_files_are_refused_before_anything_is_read() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    let secret = fixture.temporary.new_file("outside/secret.js", "secret()");
    hard_link(&fixture.in_library("Widget/hard.js"), &secret);
    hard_link(&fixture.in_library("Widget/src/deep/hard.js"), &secret);

    let files = store.files("Widget").unwrap();
    assert_eq!(files.paths(), ["main.jsx", "widget.json"]);
    for path in ["hard.js", "src/deep/hard.js"] {
        assert!(!files.exists(path), "{path}");
        assert_eq!(files.read_bytes(path), None, "{path}");
        assert_eq!(files.read_text(path), None, "{path}");
        assert_code("file_not_found", store.read_file("Widget", path));
        // Writing would replace only the name inside the package, but the name is not a package file to begin with.
        assert_code("unsafe_file", store.write_file("Widget", path, b"owned"));
    }
    assert_code("unsafe_file", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_code("unsafe_file", store.duplicate("Widget"));
    assert_eq!(fixture.exported_names("Widget"), ["Widget/main.jsx", "Widget/widget.json"]);
    assert_eq!(std::fs::read_to_string(&secret).unwrap(), "secret()");

    // The manifest itself with a second link is no manifest that can be read: the package is not exported as legacy.
    hard_link(&fixture.temporary.path("outside/manifest-copy.json"), &fixture.in_library("Widget/widget.json"));
    let mut output = Vec::new();
    assert_code("invalid_manifest", store.export_archive("Widget", &mut output));
    assert!(output.is_empty());

    store.delete("Widget").unwrap();
    assert_eq!(std::fs::read_to_string(&secret).unwrap(), "secret()");
}

// Special files

#[test]
fn sockets_and_fifos_are_never_opened() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    support::make_socket(&fixture.in_library("Widget/socket"));
    support::make_fifo(&fixture.in_library("Widget/pipe.txt"));

    // Opening a FIFO for reading blocks until a writer appears; these calls return at once because it is never opened.
    let files = store.files("Widget").unwrap();
    assert_eq!(files.paths(), ["main.jsx", "widget.json"]);
    for path in ["socket", "pipe.txt"] {
        assert!(!files.exists(path), "{path}");
        assert_eq!(files.read_bytes(path), None, "{path}");
        assert_eq!(files.read_text(path), None, "{path}");
        assert_code("file_not_found", store.read_file("Widget", path));
        assert_code("unsafe_file", store.write_file("Widget", path, b"owned"));
    }
    assert_code("unsafe_file", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_code("unsafe_file", store.duplicate("Widget"));
    assert_eq!(fixture.exported_names("Widget"), ["Widget/main.jsx", "Widget/widget.json"]);
    store.delete("Widget").unwrap();
    assert!(!fixture.in_library("Widget").exists());
}

// Case and normalization collisions. Linux keeps both spellings as two files;
// the default macOS filesystem keeps one, so these run on Linux only.

#[cfg(target_os = "linux")]
#[test]
fn case_collisions_on_disk_are_ambiguous() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    write_file(&fixture.in_library("Widget/MAIN.jsx"), b"other");
    write_file(&fixture.in_library("Widget/src/a.js"), b"lower");
    write_file(&fixture.in_library("Widget/SRC/b.js"), b"upper");
    assert_eq!(tree(&fixture.in_library("Widget")).len(), 7);

    let files = store.files("Widget").unwrap();
    assert_eq!(files.paths(), ["widget.json"]);
    for path in ["main.jsx", "MAIN.jsx", "src/a.js", "SRC/b.js"] {
        assert!(!files.exists(path), "{path}");
        assert_eq!(files.read_bytes(path), None, "{path}");
        assert_code("file_not_found", store.read_file("Widget", path));
        assert_code("unsafe_file", store.write_file("Widget", path, b"owned"));
    }
    assert_code("unsafe_file", store.write_file("Widget", "Main.jsx", b"owned"));
    assert_code("unsafe_file", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_code("unsafe_file", store.duplicate("Widget"));
    assert_eq!(std::fs::read_to_string(fixture.in_library("Widget/main.jsx")).unwrap(), SOURCE);
    assert_eq!(std::fs::read(fixture.in_library("Widget/MAIN.jsx")).unwrap(), b"other");

    // The same in the library: two directories that differ in case are not packages, and their name is taken.
    std::fs::create_dir(fixture.in_library("WIDGET")).unwrap();
    assert!(fixture.names().is_empty());
    assert_code("package_not_found", store.files("Widget"));
    assert_code("package_not_found", store.files("WIDGET"));
    assert_code("package_exists", store.create("widget", SOURCE, None));
    assert_eq!(store.unique_name("widget").unwrap(), "widget (1)");
    // A wrongly cased manifest next to the real one is an error, not a second file.
    store.create("Other", SOURCE, None).unwrap();
    write_file(&fixture.in_library("Other/Widget.JSON"), b"{}");
    assert_code("invalid_manifest_case", store.export_archive("Other", &mut Vec::new()));
    assert_code("unsafe_file", store.duplicate("Other"));
    assert_eq!(fixture.find_manifest_name("Other"), None, "with two spellings present, neither is read as the manifest");
}

#[cfg(target_os = "linux")]
#[test]
fn normalization_aliases_on_disk_are_ambiguous() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    let composed = "caf\u{E9}.js";
    let decomposed = "cafe\u{301}.js";
    write_file(&fixture.in_library(&format!("Widget/{composed}")), b"composed");
    write_file(&fixture.in_library(&format!("Widget/{decomposed}")), b"decomposed");
    assert_eq!(tree(&fixture.in_library("Widget")).len(), 4);

    let files = store.files("Widget").unwrap();
    assert_eq!(files.paths(), ["main.jsx", "widget.json"]);
    for name in [composed, decomposed] {
        assert!(!files.exists(name));
        assert_code("file_not_found", store.read_file("Widget", name));
        assert_code("unsafe_file", store.write_file("Widget", name, b"owned"));
    }
    assert_code("unsafe_file", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_eq!(std::fs::read(fixture.in_library(&format!("Widget/{composed}"))).unwrap(), b"composed");
}

#[cfg(target_os = "linux")]
#[test]
fn names_that_are_not_utf8_are_never_part_of_a_package() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    let foreign = OsStr::from_bytes(b"bad\xFF.js");
    std::fs::write(fixture.in_library("Widget").join(foreign), b"x").unwrap();
    std::fs::create_dir(fixture.library.join(OsStr::from_bytes(b"Pack\xFFage"))).unwrap();

    assert_eq!(store.files("Widget").unwrap().paths(), ["main.jsx", "widget.json"]);
    assert_eq!(fixture.names(), ["Widget"]);
    assert_code("invalid_path", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert_code("invalid_path", store.duplicate("Widget"));
    assert_eq!(fixture.exported_names("Widget"), ["Widget/main.jsx", "Widget/widget.json"]);
    store.delete("Widget").unwrap();
    assert!(!fixture.in_library("Widget").exists());
}

// Archives: preflight before extraction, unique temporary directory, transactional install

#[test]
fn the_whole_archive_is_checked_before_anything_is_written() {
    let fixture = Fixture::new();
    // Staging cannot be used at all: its place is taken by a file.
    let blocked = fixture.temporary.new_file("blocked", "");
    let mut entries: Vec<RawEntry> = (0..300).map(|index| RawEntry::new(&format!("Widget/f{index}.js"), "x")).collect();
    entries.push(RawEntry::new("Widget/main.jsx", SOURCE));
    // A well-formed archive gets as far as the staging directory.
    assert_code("storage_unavailable", archive::extract(&mut &raw_zip(&entries)[..], &blocked, &default_limits()));
    // One bad entry at the very end, and the archive is refused before staging is even looked at.
    for (code, last) in [
        ("archive_unsafe_path", RawEntry::new("Widget/../../escape.js", "owned")),
        ("archive_symlink", RawEntry::new("Widget/link", "/etc/passwd").mode(support::SYMBOLIC_LINK)),
        ("archive_path_collision", RawEntry::new("Widget/F0.js", "x")),
        ("archive_file_too_large", RawEntry::new("Widget/big.bin", "x").declared_size(26 * 1024 * 1024)),
    ] {
        let mut bad = entries.clone();
        bad.push(last);
        assert_code(code, archive::extract(&mut &raw_zip(&bad)[..], &blocked, &default_limits()));
    }
    assert_eq!(std::fs::read(&blocked).unwrap(), b"");
}

#[test]
fn archive_limits_hold_for_entry_count_file_size_and_expanded_size() {
    let fixture = Fixture::new();
    let tight = ArchiveLimits { maximum_file_count: 3, maximum_file_bytes: 1000, maximum_expanded_bytes: 1500, ..ArchiveLimits::default() };
    let store = PackageStore::with_limits(&fixture.library, &fixture.staging, tight.clone());
    let import = |entries: &[RawEntry]| store.import_archive(&mut &raw_zip(entries)[..], None, None);
    let main = || RawEntry::new("W/main.jsx", SOURCE);
    assert_code("archive_too_many_entries", import(&[main(), entry("W/a"), entry("W/b"), entry("W/c")]));
    assert_code("archive_file_too_large", import(&[main(), RawEntry::new("W/big", vec![0; 1001])]));
    assert_code("archive_expanded_too_large", import(&[main(), RawEntry::new("W/a", vec![0; 1000]), RawEntry::new("W/b", vec![0; 1000])]));
    assert!(tree(&fixture.library).is_empty() && tree(&fixture.staging).is_empty());
    // At the limits the package installs: a file of exactly 1000 bytes, and three files with the generated manifest.
    assert_eq!(import(&[main(), RawEntry::new("W/a", vec![0; 1000])]).unwrap().name, "W");
    assert_eq!(tree(&fixture.in_library("W")), ["a", "main.jsx", "widget.json"]);
    validate_tree(&fixture.in_library("W"), &tight).unwrap();
    // The limits also hold for what is already on disk: a file grown behind the store's back.
    write_file(&fixture.in_library("W/a"), &[0; 1001]);
    assert_code("file_too_large", validate_tree(&fixture.in_library("W"), &tight));
    assert_code("file_too_large", store.duplicate("W"));
    write_file(&fixture.in_library("W/a"), &[0; 1000]);
    write_file(&fixture.in_library("W/b"), &[0; 100]);
    assert_code("too_many_entries", validate_tree(&fixture.in_library("W"), &tight));
    assert_code("too_many_entries", store.duplicate("W"));
    assert_code("too_many_entries", store.export_archive("W", &mut Vec::new()));
    std::fs::remove_file(fixture.in_library("W/widget.json")).unwrap();
    write_file(&fixture.in_library("W/b"), &[0; 1000]);
    assert_code("package_too_large", validate_tree(&fixture.in_library("W"), &tight));
    assert_code("package_too_large", store.duplicate("W"));
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn each_extraction_gets_a_unique_private_directory_that_is_removed_afterwards() {
    let fixture = Fixture::new();
    let first = archive::extract(&mut &widget_zip()[..], &fixture.staging, &default_limits()).unwrap();
    let second = archive::extract(&mut &widget_zip()[..], &fixture.staging, &default_limits()).unwrap();
    assert_ne!(first.directory(), second.directory());
    for extracted in [&first, &second] {
        let work = extracted.directory().parent().unwrap();
        assert_eq!(work.parent().unwrap(), fixture.staging);
        let name = work.file_name().unwrap().to_str().unwrap();
        assert!(name.starts_with("import-") && name.len() == "import-".len() + 36, "{name}");
        assert_eq!(mode(work), 0o700);
        assert_eq!(mode(extracted.directory()), 0o700);
        assert_eq!(mode(&extracted.directory().join("main.jsx")), 0o600);
    }
    assert_eq!(mode(&fixture.staging), 0o700);
    assert_eq!(tree(&fixture.staging).len(), 2 * 4);
    drop(first);
    assert_eq!(tree(&fixture.staging).len(), 4);
    drop(second);
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn publishing_never_replaces_whatever_holds_the_name() {
    let fixture = Fixture::new();
    let import_to = |destination: &Path| archive::import_to(&mut &widget_zip()[..], &fixture.staging, destination, &default_limits());
    // An empty directory is the one thing a plain rename(2) would silently replace.
    let empty = fixture.temporary.new_folder("library/Empty");
    assert_code("package_exists", import_to(&empty));
    assert!(tree(&empty).is_empty());
    let file = fixture.temporary.new_file("library/File", "mine");
    assert_code("package_exists", import_to(&file));
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "mine");
    let dangling = fixture.library.join("Dangling");
    symlink(&dangling, &fixture.temporary.path("elsewhere"));
    assert_code("package_exists", import_to(&dangling));
    assert!(!fixture.temporary.path("elsewhere").exists(), "nothing was installed through the link");
    // A destination whose directory does not exist cannot be published to, and nothing is created for it.
    assert_code("storage_unavailable", import_to(&fixture.library.join("missing/Widget")));
    assert!(!fixture.library.join("missing").exists());
    assert!(tree(&fixture.staging).is_empty());
}

/// A rename cannot cross filesystems, so a staging directory on another one
/// must be refused instead of falling back to a copy that is not atomic.
#[cfg(target_os = "linux")]
#[test]
fn staging_on_another_filesystem_is_refused() {
    use std::os::unix::fs::MetadataExt;
    let disk = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("cross-filesystem-{}", std::process::id()));
    let memory = PathBuf::from(format!("/dev/shm/scriptwidget-tests-cross-filesystem-{}", std::process::id()));
    struct Cleanup([PathBuf; 2]);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            for directory in &self.0 {
                let _ = std::fs::remove_dir_all(directory);
            }
        }
    }
    let _cleanup = Cleanup([disk.clone(), memory.clone()]);
    std::fs::create_dir_all(&disk).unwrap();
    std::fs::create_dir_all(&memory).unwrap();
    assert_ne!(std::fs::metadata(&disk).unwrap().dev(), std::fs::metadata(&memory).unwrap().dev(), "this test needs /dev/shm and the build directory on two filesystems");
    let store = PackageStore::new(disk.join("library"), memory.join("staging"));
    assert_code("storage_unavailable", store.create("Widget", SOURCE, None));
    let error = store.import_archive(&mut &widget_zip()[..], None, None).expect_err("cross-filesystem import");
    assert_eq!(error.code, "storage_unavailable");
    assert_eq!(error.message, "Staging and library directories must share a filesystem.");
    assert!(tree(&disk.join("library")).is_empty());
    assert!(tree(&memory.join("staging")).is_empty());
    // Deleting needs no rename into staging to succeed: the package is removed where it is.
    write_file(&disk.join("library/Manual/main.jsx"), SOURCE.as_bytes());
    store.delete("Manual").unwrap();
    assert!(tree(&disk.join("library")).is_empty());
    assert!(tree(&memory.join("staging")).is_empty());
}

#[test]
fn an_install_is_all_or_nothing() {
    let fixture = Fixture::with_widget();
    let before = tree(&fixture.library);
    // The last entry is the one that fails, after the others were extracted: by its checksum, and by its size.
    let mut corrupt = raw_zip(&[RawEntry::new("New/widget.json", manifest("New")), RawEntry::new("New/a.js", "a"), RawEntry::new("New/main.jsx", SOURCE)]);
    let position = corrupt.windows(SOURCE.len()).position(|window| window == SOURCE.as_bytes()).unwrap();
    corrupt[position] = b'#';
    assert_code("archive_corrupt", fixture.import(&corrupt));
    let lying = raw_zip(&[RawEntry::new("New/widget.json", manifest("New")), RawEntry::new("New/main.jsx", SOURCE), RawEntry::new("New/z.bin", vec![1; 4096]).declared_size(8)]);
    assert_code("archive_size_mismatch", fixture.import(&lying));
    // A veto after extraction and a manifest that cannot be read are no different.
    let veto = |_: &dyn PackageFiles| -> Result<(), PackageError> { Err(PackageError::new("vetoed", "no")) };
    assert_code("vetoed", fixture.store.import_archive(&mut &package_zip("New", "New", &[])[..], None, Some(&veto)));
    assert_eq!(tree(&fixture.library), before);
    assert!(tree(&fixture.staging).is_empty());
    // And a package that does install appears complete, under its own name, next to the untouched one.
    assert_eq!(fixture.import(&package_zip("New", "New", &[("src/a.js", "a")])).unwrap(), "New");
    assert_eq!(tree(&fixture.in_library("New")), ["main.jsx", "src/", "src/a.js", "widget.json"]);
    assert_eq!(std::fs::read_to_string(fixture.in_library("Widget/main.jsx")).unwrap(), SOURCE);
}

// Manifests

#[test]
fn a_manifest_that_is_present_but_malformed_fails_closed() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    let malformed: [&[u8]; 9] = [b"", b"{bad", b"[1]", b"\"text\"", b"{\"name\":\"W\",}", b"{\"name\":\"W\"} x", b"// c\n{\"name\":\"W\"}", b"{\"name\":\"W\",\"name\":\"X\"}", &[0x7B, 0xC3, 0x28, 0x7D]];
    for (index, content) in malformed.iter().enumerate() {
        // On disk, with a perfectly good main.jsx next to it: the package is never treated as legacy.
        let name = format!("Broken {index}");
        write_file(&fixture.in_library(&format!("{name}/widget.json")), content);
        write_file(&fixture.in_library(&format!("{name}/main.jsx")), SOURCE.as_bytes());
        let listed = store.list().unwrap().into_iter().find(|package| package.name == name).unwrap();
        assert!(listed.has_manifest, "{name}");
        assert_eq!((listed.manifest_id, listed.manifest_name, listed.manifest_version), (None, None, None), "{name}");
        let mut output = Vec::new();
        assert_code("invalid_manifest", store.export_archive(&name, &mut output));
        assert!(output.is_empty());
        assert_code("invalid_manifest", store.duplicate(&name));
        // In an archive.
        assert_code("invalid_manifest", fixture.import(&raw_zip(&[RawEntry::new("W/widget.json", *content), RawEntry::new("W/main.jsx", SOURCE)])));
    }
    assert_eq!(fixture.names().len(), malformed.len());
    assert!(tree(&fixture.staging).is_empty());

    // The reader itself.
    assert!(manifests::parse(None).is_none());
    assert!(manifests::parse(Some("\u{FEFF}{}")).is_none(), "a byte order mark is not JSON");
    assert!(manifests::parse(Some("{\"a\":{\"b\":1,\"b\":2}}")).is_none(), "a duplicate key at any depth");
    assert!(manifests::parse(Some(&format!("{}1{}", "[".repeat(100_000), "]".repeat(100_000)))).is_none(), "nesting is bounded");
    let parsed = manifests::parse(Some("{\"name\":\"W\",\"n\":1.5,\"big\":12345678901234567890,\"list\":[true,null,{\"k\":\"v\"}]}")).unwrap();
    assert_eq!(manifests::string_value(&parsed, "name").as_deref(), Some("W"));
    assert_eq!(manifests::string_value(&parsed, "n"), None);
    assert_eq!(sw_core::json::stringify_object(&parsed), "{\"name\":\"W\",\"n\":1.5,\"big\":12345678901234567890,\"list\":[true,null,{\"k\":\"v\"}]}");
}

fn scripts() -> Arc<SharedScripts> {
    static SCRIPTS: OnceLock<Arc<SharedScripts>> = OnceLock::new();
    SCRIPTS.get_or_init(|| Arc::new(SharedScripts::new(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget")).expect("shared scripts"))).clone()
}

fn compiler() -> &'static PackageCompiler {
    static COMPILER: OnceLock<PackageCompiler> = OnceLock::new();
    COMPILER.get_or_init(|| PackageCompiler::new(scripts()).expect("compiler thread"))
}

#[test]
fn shared_manifest_validator_plugs_into_the_import_hook() {
    let fixture = Fixture::new();
    let validate = |files: &dyn PackageFiles| -> Result<(), PackageError> {
        let result = compiler().validate_manifest(&files.read_text("widget.json").unwrap(), &files.paths()).map_err(|error| PackageError::new("invalid_manifest", error.message))?;
        if result.opt_bool("ok", false) { Ok(()) } else { Err(PackageError::new("invalid_manifest", sw_core::json::stringify_object(&result))) }
    };
    let import = |archive: &[u8]| fixture.store.import_archive(&mut &archive[..], None, Some(&validate));
    assert_eq!(import(&widget_zip()).unwrap().name, "Widget");
    let unknown_key = manifest("Extra").replace("\"permissions\":[]", "\"permissions\":[],\"surprise\":true");
    let unsupported = manifest("Future").replace("\"formatVersion\":2", "\"formatVersion\":99");
    let missing_entry = manifest("NoEntry").replace("\"main.jsx\"", "\"missing.jsx\"");
    for manifest in [unknown_key, unsupported, missing_entry] {
        assert_code("invalid_manifest", import(&raw_zip(&[RawEntry::new("W/widget.json", manifest), RawEntry::new("W/main.jsx", SOURCE)])));
    }
    assert_eq!(fixture.names(), ["Widget"]);
    assert!(tree(&fixture.staging).is_empty());
}

// $file

/// `$file` and `$import` of the shared engine read through `DiskPackageFiles`.
#[test]
fn the_runtime_reads_package_files_from_disk_and_cannot_leave_the_package() {
    let fixture = Fixture::new();
    let store = &fixture.store;
    let main = "$import('lib/label.js');
        const read = (path) => { try { return $file.read(path); } catch (error) { return 'threw'; } };
        $render(<text>{label($file.readJSON('data.json').name)}|{read('../Secret/secret.txt')}|{read('link.txt')}|{read('linkdir/secret.txt')}|{read('hard.txt')}|{read('/etc/hostname')}|{String($file.exists('link.txt'))}|{String($file.exists('data.json'))}</text>);";
    store.create("Widget", main, None).unwrap();
    store.write_file("Widget", "lib/label.js", b"function label(name) { return 'name=' + name; }").unwrap();
    store.write_file("Widget", "data.json", b"{\"name\":\"widget\"}").unwrap();
    let secret = fixture.temporary.new_file("library/Secret/secret.txt", "TOP-SECRET");
    symlink(&fixture.in_library("Widget/link.txt"), &secret);
    symlink(&fixture.in_library("Widget/linkdir"), secret.parent().unwrap());
    hard_link(&fixture.in_library("Widget/hard.txt"), &secret);

    let files = store.files("Widget").unwrap();
    let prepared = compiler().prepare(&files, &PrepareOptions::default()).expect("prepare");
    let request = ExecutionRequest::new(&prepared, &files);
    let result = ScriptExecutor::new(scripts()).execute(&request);
    let rendered = result.tree.unwrap_or_else(|| panic!("no tree: {:?}", result.error));
    assert!(rendered.contains(r#""children":["name=widget","|","","|","","|","","|","","|","","|","false","|","true"]"#), "{rendered}");
    assert!(!rendered.contains("TOP-SECRET"));
}

// Permissions

#[test]
fn everything_the_store_writes_is_private_to_the_user() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    store.write_file("Widget", "src/deep/util.js", b"util").unwrap();
    store.write_file("Widget", "main.jsx", b"replaced").unwrap();
    store.duplicate("Widget").unwrap();
    fixture.import(&package_zip("Imported", "Imported", &[("data/a.json", "{}")])).unwrap();
    assert_eq!(fixture.names(), ["Imported", "Widget", "Widget Remix"]);
    fn check(directory: &Path) {
        for entry in std::fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                assert_eq!(mode(&path), 0o700, "{path:?}");
                check(&path);
            } else {
                assert_eq!(mode(&path), 0o600, "{path:?}");
            }
        }
    }
    check(&fixture.library);
    assert_eq!(mode(&fixture.library), 0o700);
    assert_eq!(mode(&fixture.staging), 0o700);
}

#[test]
fn a_file_the_user_cannot_read_is_not_a_package_file() {
    let fixture = Fixture::with_widget();
    if permissions_are_not_enforced(&fixture.temporary) {
        eprintln!("SKIPPED a_file_the_user_cannot_read_is_not_a_package_file: running as root, file modes are not enforced");
        return;
    }
    let store = &fixture.store;
    store.write_file("Widget", "locked.js", b"locked").unwrap();
    set_mode(&fixture.in_library("Widget/locked.js"), 0o000);
    let files = store.files("Widget").unwrap();
    assert!(!files.exists("locked.js"));
    assert_eq!(files.read_bytes("locked.js"), None);
    assert_code("file_not_found", store.read_file("Widget", "locked.js"));
    // It still counts as a file of the directory, so an export or a copy fails instead of silently dropping it.
    assert_code("file_too_large", store.export_archive("Widget", &mut Vec::new()));
    assert_code("unsafe_file", store.duplicate("Widget"));
    // A directory that cannot be searched hides its files the same way.
    store.write_file("Widget", "sealed/inner.js", b"inner").unwrap();
    set_mode(&fixture.in_library("Widget/sealed"), 0o000);
    assert!(!files.exists("sealed/inner.js"));
    assert_code("unsafe_file", store.write_file("Widget", "sealed/new.js", b"owned"));
    assert_code("unsafe_file", validate_tree(&fixture.in_library("Widget"), &default_limits()));
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn directories_that_cannot_be_written_fail_cleanly() {
    let fixture = Fixture::with_widget();
    if permissions_are_not_enforced(&fixture.temporary) {
        eprintln!("SKIPPED directories_that_cannot_be_written_fail_cleanly: running as root, file modes are not enforced");
        return;
    }
    let store = &fixture.store;
    // A read-only library: nothing can be published, and nothing stays in staging.
    set_mode(&fixture.library, 0o500);
    assert_code("storage_unavailable", store.create("Second", SOURCE, None));
    let error = store.import_archive(&mut &package_zip("W", "Second", &[])[..], None, None).expect_err("read-only library");
    assert_eq!(error.code, "storage_unavailable", "{error}");
    assert_code("storage_unavailable", store.duplicate("Widget"));
    assert_code("storage_unavailable", store.rename("Widget", "Renamed"));
    assert_eq!(fixture.names(), ["Widget"]);
    assert!(tree(&fixture.staging).is_empty());
    set_mode(&fixture.library, 0o700);

    // A read-only package directory: the old content stays, and no temporary file is left.
    set_mode(&fixture.in_library("Widget"), 0o500);
    assert_code("storage_unavailable", store.write_file("Widget", "main.jsx", b"owned"));
    assert_code("unsafe_file", store.write_file("Widget", "new/file.js", b"owned"));
    assert_eq!(store.read_file("Widget", "main.jsx").unwrap(), SOURCE.as_bytes());
    assert_eq!(tree(&fixture.in_library("Widget")), ["main.jsx", "widget.json"]);
    set_mode(&fixture.in_library("Widget"), 0o700);

    // A read-only staging directory: nothing can be prepared, so nothing is installed.
    set_mode(&fixture.staging, 0o500);
    assert_code("storage_unavailable", store.create("Second", SOURCE, None));
    assert_code("storage_unavailable", store.import_archive(&mut &widget_zip()[..], None, None));
    assert_code("storage_unavailable", store.duplicate("Widget"));
    assert_eq!(fixture.names(), ["Widget"]);
    set_mode(&fixture.staging, 0o700);
}

#[test]
fn delete_removes_directories_that_lost_their_permissions() {
    let fixture = Fixture::with_widget();
    let store = &fixture.store;
    store.write_file("Widget", "locked/deep/a.js", b"a").unwrap();
    store.write_file("Widget", "sealed/b.js", b"b").unwrap();
    set_mode(&fixture.in_library("Widget/locked/deep"), 0o500);
    set_mode(&fixture.in_library("Widget/locked"), 0o500);
    set_mode(&fixture.in_library("Widget/sealed"), 0o000);
    store.delete("Widget").unwrap();
    assert!(!fixture.in_library("Widget").exists());
    assert!(fixture.names().is_empty());
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn extra_files_cannot_smuggle_unsafe_paths_into_an_export() {
    let fixture = Fixture::with_widget();
    for path in ["../escape.txt", "/abs.txt", "a\\b", ".hidden", "__Build/x.js", "src/../x.js", "C:x"] {
        let extras: BTreeMap<String, Vec<u8>> = [(path.to_owned(), b"x".to_vec())].into();
        let mut output = Vec::new();
        assert_code("invalid_path", archive::export(&fixture.in_library("Widget"), "Widget", &mut output, &extras, &default_limits()));
        assert!(output.is_empty());
    }
}
