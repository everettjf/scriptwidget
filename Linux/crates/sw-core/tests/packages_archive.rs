//! `.swt` archives: preflight, extraction and export. Ported from `PackageArchiveTests.cs`.

#[path = "packages_support/mod.rs"]
mod support;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use support::{
    RawEntry, SYMBOLIC_LINK, TemporaryFolder, assert_code, assert_lying_size_rejected, deflated_zip, entry, entry_names, forge_declared_size, manifest, nested, raw_zip, read_zip, symlink, tree, widget_zip,
    write_file,
};
use sw_core::PackageFiles;
use sw_core::packages::limits::{MAX_FILE_BYTES, MAX_FILE_COUNT};
use sw_core::packages::{ArchiveLimits, DiskPackageFiles, PackageError, archive};

struct Fixture {
    temporary: TemporaryFolder,
    staging: PathBuf,
    library: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temporary = TemporaryFolder::new();
        Self { staging: temporary.new_folder("staging"), library: temporary.new_folder("library"), temporary }
    }

    fn extract(&self, bytes: &[u8]) -> Result<archive::ExtractedPackage, PackageError> {
        archive::extract(&mut &bytes[..], &self.staging, &ArchiveLimits::default())
    }

    fn import_to(&self, bytes: &[u8], destination: &Path) -> Result<Option<String>, PackageError> {
        archive::import_to(&mut &bytes[..], &self.staging, destination, &ArchiveLimits::default())
    }

    /// Refused by the preflight alone and by an import, which must leave nothing behind.
    #[track_caller]
    fn assert_rejected_with(&self, code: &str, bytes: &[u8], limits: &ArchiveLimits) {
        assert_code(code, archive::preflight(bytes, limits));
        let destination = self.library.join("Target");
        assert_code(code, archive::import_to(&mut &bytes[..], &self.staging, &destination, limits));
        assert!(!destination.exists());
        assert!(tree(&self.staging).is_empty(), "staging: {:?}", tree(&self.staging));
        assert!(tree(&self.library).is_empty());
    }

    #[track_caller]
    fn assert_rejected(&self, code: &str, bytes: &[u8]) {
        self.assert_rejected_with(code, bytes, &ArchiveLimits::default());
    }

    #[track_caller]
    fn assert_rejected_on_extract(&self, code: &str, bytes: &[u8]) {
        assert_code(code, self.extract(bytes));
        assert!(tree(&self.staging).is_empty());
    }

    /// A package directory with authored files, caches, hidden files and links to a file and a directory outside.
    fn sample_package(&self) -> PathBuf {
        let root = self.temporary.new_folder("source/My Widget");
        write_file(&root.join("widget.json"), manifest("My Widget").as_bytes());
        write_file(&root.join("main.jsx"), "$render(<text>阅读</text>);".as_bytes());
        write_file(&root.join("src/b.js"), b"b");
        write_file(&root.join("src/a.js"), b"a");
        write_file(&root.join("image/logo.png"), &(0..2048).map(|index| (index * 31) as u8).collect::<Vec<u8>>());
        write_file(&root.join("__Build/main.js"), b"compiled");
        write_file(&root.join("src/__Build/a.js"), b"compiled");
        write_file(&root.join(".DS_Store"), b"junk");
        write_file(&root.join(".git/config"), b"junk");
        let secret = self.temporary.new_file("secret.txt", "secret");
        symlink(&root.join("link.txt"), &secret);
        symlink(&root.join("linkdir"), secret.parent().unwrap());
        root
    }
}

fn limits(change: impl FnOnce(&mut ArchiveLimits)) -> ArchiveLimits {
    let mut limits = ArchiveLimits::default();
    change(&mut limits);
    limits
}

fn export_with(root: &Path, name: &str, limits: &ArchiveLimits) -> Result<Vec<u8>, PackageError> {
    let mut output = Vec::new();
    archive::export(root, name, &mut output, &BTreeMap::new(), limits).map(|()| output)
}

fn export(root: &Path) -> Vec<u8> {
    export_with(root, root.file_name().unwrap().to_str().unwrap(), &ArchiveLimits::default()).unwrap()
}

// Preflight: paths

#[test]
fn rejects_traversal_paths() {
    let fixture = Fixture::new();
    for name in ["../escape.txt", "Widget/../../escape.txt", "Widget/../main.jsx", "..", "Widget/./main.jsx", "./main.jsx"] {
        fixture.assert_rejected("archive_unsafe_path", &raw_zip(&[entry("Widget/main.jsx"), entry(name)]));
    }
}

#[test]
fn rejects_absolute_backslash_drive_and_control_paths() {
    let fixture = Fixture::new();
    let too_long = format!("Widget/{}", "n".repeat(256));
    let names = [
        "/etc/passwd",
        "/Widget/main.jsx",
        "\\Widget\\main.jsx",
        "Widget\\main.jsx",
        "Widget/..\\..\\escape.txt",
        "C:/Widget/main.jsx",
        "C:main.jsx",
        "Widget/main.jsx:stream",
        "Widget/ma\0in.jsx",
        "Widget/line\nbreak.js",
        "Widget/bidi\u{202E}.js",
        &too_long,
    ];
    for name in names {
        fixture.assert_rejected("archive_unsafe_path", &raw_zip(&[entry("Widget/main.jsx"), entry(name)]));
    }
}

#[test]
fn rejects_non_utf8_names() {
    let fixture = Fixture::new();
    fixture.assert_rejected("archive_unsafe_path", &raw_zip(&[entry("ignored").name_bytes(&[b'W', b'/', 0xC3, 0x28])]));
}

#[test]
fn rejects_excessive_nesting() {
    let fixture = Fixture::new();
    let deep = nested("d", 16);
    assert_eq!(archive::preflight(&raw_zip(&[entry(&deep)]), &ArchiveLimits::default()).unwrap(), [deep.as_str()]);
    fixture.assert_rejected("archive_unsafe_path", &raw_zip(&[entry(&format!("{deep}/main.jsx"))]));
}

#[test]
fn rejects_duplicate_and_case_colliding_paths() {
    let fixture = Fixture::new();
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[RawEntry::new("Widget/main.jsx", "one"), RawEntry::new("widget/MAIN.jsx", "two")]));
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[RawEntry::new("Widget/main.jsx", "one"), RawEntry::new("Widget/main.jsx", "two")]));
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[entry("Widget/main.jsx"), entry("Widget/a.js"), entry("Widget/A.js")]));
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[entry("Widget/main.jsx"), entry("Widget/src/a.js"), entry("Widget/SRC/b.js")]));
}

#[test]
fn rejects_unicode_normalization_collisions() {
    let fixture = Fixture::new();
    let composed = "Widget/caf\u{E9}.js";
    let decomposed = "Widget/cafe\u{301}.js";
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[entry("Widget/main.jsx"), entry(composed), entry(decomposed)]));
}

#[test]
fn rejects_a_path_used_as_both_file_and_directory() {
    let fixture = Fixture::new();
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[entry("Widget/main.jsx"), entry("Widget/data"), entry("Widget/data/a.json")]));
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[entry("Widget/main.jsx"), entry("Widget/data/a.json"), entry("Widget/data")]));
}

// Preflight: entry kinds

#[test]
fn rejects_symbolic_link_entries() {
    let fixture = Fixture::new();
    fixture.assert_rejected("archive_symlink", &raw_zip(&[entry("Widget/main.jsx"), RawEntry::new("Widget/link.js", "/etc/passwd").mode(SYMBOLIC_LINK)]));
}

#[test]
fn rejects_symbolic_link_directory_entries() {
    let fixture = Fixture::new();
    // A link named like a directory, followed by a file that would be written through it.
    fixture.assert_rejected("archive_symlink", &raw_zip(&[entry("Widget/main.jsx"), RawEntry::new("Widget/out/", "/tmp").mode(SYMBOLIC_LINK), entry("Widget/out/escape.txt")]));
    fixture.assert_rejected("archive_path_collision", &raw_zip(&[entry("Widget/main.jsx"), RawEntry::new("Widget/out", "/tmp"), entry("Widget/out/escape.txt")]));
}

#[test]
fn rejects_special_files_encryption_and_unknown_compression() {
    let fixture = Fixture::new();
    // FIFO, character device, block device and socket.
    for kind in [0x11A4u32, 0x21A4, 0x61A4, 0xC1A4] {
        fixture.assert_rejected("archive_symlink", &raw_zip(&[RawEntry::new("Widget/special", "").mode(kind << 16)]));
    }
    fixture.assert_rejected("archive_encrypted", &raw_zip(&[entry("Widget/main.jsx").flags(0x0801)]));
    fixture.assert_rejected("archive_unsupported_compression", &raw_zip(&[entry("Widget/main.jsx").method(12)]));
}

// Preflight: limits

#[test]
fn rejects_too_many_entries() {
    let fixture = Fixture::new();
    let entries: Vec<RawEntry> = (0..=MAX_FILE_COUNT).map(|index| entry(&format!("Widget/f{index}.js"))).collect();
    assert_eq!(entries.len(), 501);
    fixture.assert_rejected("archive_too_many_entries", &raw_zip(&entries));
    assert_eq!(archive::preflight(&raw_zip(&entries[..500]), &ArchiveLimits::default()).unwrap().len(), 500);
}

#[test]
fn rejects_oversized_entry_by_declared_size() {
    let fixture = Fixture::new();
    fixture.assert_rejected("archive_file_too_large", &raw_zip(&[entry("Widget/main.jsx"), entry("Widget/big.bin").declared_size(MAX_FILE_BYTES + 1)]));
    archive::preflight(&raw_zip(&[entry("Widget/main.jsx"), entry("Widget/big.bin").declared_size(MAX_FILE_BYTES)]), &ArchiveLimits::default()).unwrap();
}

#[test]
fn rejects_oversized_total_by_declared_size() {
    let fixture = Fixture::new();
    let mut entries = vec![entry("Widget/main.jsx")];
    entries.extend((1..=3).map(|index| entry(&format!("Widget/part{index}.bin")).declared_size(22 * 1024 * 1024)));
    fixture.assert_rejected("archive_expanded_too_large", &raw_zip(&entries));
}

#[test]
fn rejects_oversized_entry_and_total_with_real_data() {
    let fixture = Fixture::new();
    let tight = limits(|limits| {
        limits.maximum_file_bytes = 1024;
        limits.maximum_expanded_bytes = 2048;
    });
    fixture.assert_rejected_with("archive_file_too_large", &raw_zip(&[entry("Widget/main.jsx"), RawEntry::new("Widget/big.bin", vec![0; 1025])]), &tight);
    let mut entries = vec![entry("Widget/main.jsx")];
    entries.extend((1..=3).map(|index| RawEntry::new(&format!("Widget/part{index}.bin"), vec![0; 1000])));
    fixture.assert_rejected_with("archive_expanded_too_large", &raw_zip(&entries), &tight);
}

#[test]
fn rejects_empty_oversized_and_malformed_archives() {
    let fixture = Fixture::new();
    fixture.assert_rejected("archive_size", &[]);
    fixture.assert_rejected_with("archive_size", &widget_zip(), &limits(|limits| limits.maximum_archive_bytes = 64));
    fixture.assert_rejected("archive_malformed", &[0; 10]);
    fixture.assert_rejected("archive_malformed", b"this is not a zip archive at all, just text");
    let valid = widget_zip();
    fixture.assert_rejected("archive_malformed", &[&valid[..], &[1, 2, 3]].concat());
    let mut bad_offset = valid.clone();
    let end = valid.len() - 22;
    bad_offset[end + 16] = 0x7F;
    fixture.assert_rejected("archive_malformed", &bad_offset);
    let mut second_disk = valid.clone();
    second_disk[end + 4] = 1;
    fixture.assert_rejected("archive_multi_disk", &second_disk);
    let mut wrong_count = valid.clone();
    wrong_count[end + 10] = 1;
    fixture.assert_rejected("archive_multi_disk", &wrong_count);
    let mut wrong_signature = valid.clone();
    let central = u32::from_le_bytes(valid[end + 16..end + 20].try_into().unwrap()) as usize;
    wrong_signature[central] = b'X';
    fixture.assert_rejected("archive_malformed", &wrong_signature);
    fixture.assert_rejected("archive_invalid_ratio", &raw_zip(&[RawEntry::new("Widget/main.jsx", "").declared_size(2 * 1024 * 1024).declared_compressed_size(0)]));
}

#[test]
fn an_archive_larger_than_the_limit_is_not_read_to_the_end() {
    let fixture = Fixture::new();
    // The input would never end; reading stops one byte past the limit.
    let mut endless = std::io::repeat(0x50);
    assert_code("archive_size", archive::extract(&mut endless, &fixture.staging, &limits(|limits| limits.maximum_archive_bytes = 4096)));
    assert!(tree(&fixture.staging).is_empty());
}

// Extraction

#[test]
fn zip_bomb_with_lying_size_headers_stops_at_the_declared_size() {
    let fixture = Fixture::new();
    // More than the 64 MiB a package may expand to: an extraction that only compared sizes at the end of
    // the entry would run into that limit, and report it, long after it should have stopped.
    let bomb = deflated_zip(&[("Widget/main.jsx", b"x"), ("Widget/bomb.bin", &vec![0; 80 * 1024 * 1024])]);
    assert!(bomb.len() < 128 * 1024, "the bomb must be small on the wire");
    let forged = forge_declared_size(&bomb, 1, 16);
    assert_eq!(archive::preflight(&forged, &ArchiveLimits::default()).unwrap().len(), 2);
    let destination = fixture.library.join("Bomb");
    assert_lying_size_rejected(fixture.import_to(&forged, &destination));
    assert!(!destination.exists());
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn inflation_is_counted_against_the_limits_even_when_headers_agree() {
    let fixture = Fixture::new();
    // Declared sizes pass the preflight, then the real stream is checked against them.
    let archive_bytes = deflated_zip(&[("Widget/main.jsx", b"x"), ("Widget/a.bin", &[0; 4096])]);
    assert_lying_size_rejected(fixture.extract(&forge_declared_size(&archive_bytes, 1, 100)));
    assert_code("archive_size_mismatch", fixture.extract(&forge_declared_size(&archive_bytes, 1, 8192)));
    assert!(tree(&fixture.staging).is_empty());
    // With honest headers the same archive is refused by limits that are tighter than its content.
    let tight = limits(|limits| limits.maximum_expanded_bytes = 4096);
    assert_code("archive_expanded_too_large", archive::extract(&mut &archive_bytes[..], &fixture.staging, &tight));
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn stored_entry_with_lying_size_is_rejected() {
    let fixture = Fixture::new();
    let archive_bytes = raw_zip(&[entry("Widget/main.jsx"), RawEntry::new("Widget/data.bin", vec![7; 4096]).declared_size(16)]);
    assert_lying_size_rejected(fixture.extract(&archive_bytes));
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn corrupted_content_fails_the_checksum() {
    let fixture = Fixture::new();
    let mut archive_bytes = raw_zip(&[RawEntry::new("Widget/main.jsx", "render()")]);
    archive_bytes[30 + "Widget/main.jsx".len()] = b'X';
    assert_code("archive_corrupt", fixture.extract(&archive_bytes));
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn a_corrupt_deflate_stream_is_rejected() {
    let fixture = Fixture::new();
    let mut archive_bytes = deflated_zip(&[("Widget/main.jsx", &b"abcdefgh".repeat(64))]);
    // Inside the compressed data of the only entry.
    let start = 30 + "Widget/main.jsx".len();
    for byte in &mut archive_bytes[start..start + 6] {
        *byte = 0xFF;
    }
    let error = fixture.extract(&archive_bytes).expect_err("corrupt stream");
    assert!(["archive_corrupt", "archive_size_mismatch"].contains(&error.code.as_str()), "{error}");
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn local_headers_that_disagree_with_the_central_directory_are_corrupt() {
    let fixture = Fixture::new();
    let valid = raw_zip(&[RawEntry::new("Widget/main.jsx", "render()")]);
    let end = valid.len() - 22;
    let central = u32::from_le_bytes(valid[end + 16..end + 20].try_into().unwrap()) as usize;
    // The central directory points past the archive, at something that is not a local header, or at a header for another name.
    let mut bad_offset = valid.clone();
    bad_offset[central + 42..central + 46].copy_from_slice(&0x00FF_FFFFu32.to_le_bytes());
    assert_code("archive_corrupt", fixture.extract(&bad_offset));
    let mut not_a_header = valid.clone();
    not_a_header[central + 42] = 4;
    assert_code("archive_corrupt", fixture.extract(&not_a_header));
    let mut other_name = valid.clone();
    other_name[30] = b'X';
    assert_code("archive_corrupt", fixture.extract(&other_name));
    let mut other_method = valid.clone();
    other_method[8] = 8;
    assert_code("archive_corrupt", fixture.extract(&other_method));
    // Encrypted according to the local header only.
    let mut encrypted = valid.clone();
    encrypted[6] |= 1;
    assert_code("archive_encrypted", fixture.extract(&encrypted));
    // The data would run past the end of the archive.
    let truncated = raw_zip(&[RawEntry::new("Widget/main.jsx", "x").declared_compressed_size(1_000_000).declared_size(1_000_000)]);
    assert_code("archive_corrupt", fixture.extract(&truncated));
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn extracts_only_authored_files_of_the_single_package_root() {
    let fixture = Fixture::new();
    let archive_bytes = raw_zip(&[
        RawEntry::new("Widget/widget.json", "{}"),
        RawEntry::new("Widget/main.jsx", "main"),
        RawEntry::new("Widget/src/util.js", "util"),
        RawEntry::new("Widget/empty/", ""),
        RawEntry::new("Widget/__Build/main.js", "planted"),
        RawEntry::new("Widget/src/__build/x.js", "planted"),
        RawEntry::new("Widget/src/deep/__BUILD/y.js", "planted"),
        RawEntry::new("Widget/.DS_Store", "junk"),
        RawEntry::new("Widget/.git/config", "junk"),
        RawEntry::new("__MACOSX/Widget/._main.jsx", "junk"),
        RawEntry::new("__MACOSX/other.txt", "junk"),
        RawEntry::new("README.txt", "stray top-level file"),
    ]);
    {
        let extracted = fixture.extract(&archive_bytes).unwrap();
        assert_eq!(extracted.root_name(), Some("Widget"));
        assert_eq!(tree(extracted.directory()), ["main.jsx", "src/", "src/util.js", "widget.json"]);
        assert_eq!(std::fs::read_to_string(extracted.directory().join("src/util.js")).unwrap(), "util");
        assert!(extracted.directory().starts_with(&fixture.staging));
    }
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn accepts_files_at_the_archive_root_and_rejects_ambiguous_roots() {
    let fixture = Fixture::new();
    let flat = raw_zip(&[RawEntry::new("main.jsx", "main"), RawEntry::new("image/a.png", "png"), RawEntry::new("__Build/main.js", "planted")]);
    {
        let extracted = fixture.extract(&flat).unwrap();
        assert_eq!(extracted.root_name(), None);
        assert_eq!(tree(extracted.directory()), ["image/", "image/a.png", "main.jsx"]);
    }
    fixture.assert_rejected_on_extract("archive_no_package", &raw_zip(&[entry("One/main.jsx"), entry("Two/main.jsx")]));
    fixture.assert_rejected_on_extract("archive_no_package", &raw_zip(&[entry("readme.txt")]));
    fixture.assert_rejected_on_extract("archive_no_package", &raw_zip(&[entry("__Build/main.jsx"), entry(".hidden/main.jsx")]));
    fixture.assert_rejected_on_extract("archive_no_package", &raw_zip(&[RawEntry::new("Widget/", "")]));
}

#[test]
fn import_moves_into_place_and_never_replaces_an_existing_directory() {
    let fixture = Fixture::new();
    let destination = fixture.library.join("Installed");
    assert_eq!(fixture.import_to(&widget_zip(), &destination).unwrap().as_deref(), Some("Widget"));
    assert_eq!(tree(&destination), ["main.jsx", "widget.json"]);
    assert!(tree(&fixture.staging).is_empty());
    std::fs::write(destination.join("main.jsx"), "mine").unwrap();
    assert_code("package_exists", fixture.import_to(&widget_zip(), &destination));
    assert_eq!(std::fs::read_to_string(destination.join("main.jsx")).unwrap(), "mine");
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn imports_deflated_archives() {
    let fixture = Fixture::new();
    let text = "a".repeat(100_000);
    let extracted = fixture.extract(&deflated_zip(&[("Widget/main.jsx", text.as_bytes()), ("Widget/widget.json", b"{}")])).unwrap();
    assert_eq!(std::fs::read_to_string(extracted.directory().join("main.jsx")).unwrap(), text);
}

// Export

const EXPORTED: [&str; 5] = ["My Widget/image/logo.png", "My Widget/main.jsx", "My Widget/src/a.js", "My Widget/src/b.js", "My Widget/widget.json"];

#[test]
fn export_skips_caches_dot_files_and_links_and_sorts_entries() {
    let fixture = Fixture::new();
    let archive_bytes = export(&fixture.sample_package());
    assert_eq!(entry_names(&archive_bytes), EXPORTED);
    assert_eq!(archive::preflight(&archive_bytes, &ArchiveLimits::default()).unwrap(), EXPORTED);
    let contents = read_zip(&archive_bytes);
    assert_eq!(contents[1].1, "$render(<text>阅读</text>);".as_bytes());
    assert_eq!(contents[0].1.len(), 2048);
}

#[test]
fn export_is_deterministic() {
    let fixture = Fixture::new();
    let root = fixture.sample_package();
    let first = export(&root);
    let main = std::fs::File::options().write(true).open(root.join("main.jsx")).unwrap();
    main.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000)).unwrap();
    assert_eq!(export(&root), first);
}

#[test]
fn export_then_import_round_trips_every_file() {
    let fixture = Fixture::new();
    let root = fixture.sample_package();
    let destination = fixture.library.join("Copy");
    assert_eq!(fixture.import_to(&export(&root), &destination).unwrap().as_deref(), Some("My Widget"));
    let original = DiskPackageFiles::new(&root);
    let copy = DiskPackageFiles::new(&destination);
    assert_eq!(original.paths(), copy.paths());
    assert_eq!(copy.paths().len(), 5);
    for path in original.paths() {
        assert_eq!(original.read_bytes(&path), copy.read_bytes(&path), "{path}");
    }
    assert!(tree(&fixture.staging).is_empty());
}

#[test]
fn export_applies_limits_and_sanitizes_the_root_name() {
    let fixture = Fixture::new();
    let root = fixture.sample_package();
    assert_eq!(entry_names(&export_with(&root, "Ratio 16:9", &ArchiveLimits::default()).unwrap())[0], "Ratio 16-9/image/logo.png");
    assert_code("file_too_large", export_with(&root, "W", &limits(|limits| limits.maximum_file_bytes = 1024)));
    assert_code("package_too_large", export_with(&root, "W", &limits(|limits| limits.maximum_expanded_bytes = 2048)));
    assert_code("too_many_entries", export_with(&root, "W", &limits(|limits| limits.maximum_file_count = 4)));
    assert_code("archive_size", export_with(&root, "W", &limits(|limits| limits.maximum_archive_bytes = 512)));
    assert_code("archive_no_package", export_with(&fixture.temporary.new_folder("empty"), "W", &ArchiveLimits::default()));
    // A file nested 16 deep lists on disk, but under the archive's root directory it would be 17 components.
    write_file(&root.join(nested("d", 15)).join("deep.txt"), b"deep");
    assert!(DiskPackageFiles::new(&root).paths().contains(&(nested("d", 15) + "/deep.txt")));
    let mut output = Vec::new();
    assert_code("invalid_path", archive::export(&root, "W", &mut output, &BTreeMap::new(), &ArchiveLimits::default()));
    assert!(output.is_empty(), "nothing is written unless the whole archive was produced");
}

#[test]
fn a_file_that_cannot_be_an_archive_entry_stops_the_export() {
    let fixture = Fixture::new();
    let root = fixture.sample_package();
    // As in the Android test: the name lists on disk, but an archive entry may not hold a colon.
    write_file(&root.join("a:b.txt"), b"colon");
    assert!(DiskPackageFiles::new(&root).paths().contains(&"a:b.txt".to_owned()));
    assert_code("invalid_path", export_with(&root, "W", &ArchiveLimits::default()));
}

#[test]
fn extra_files_are_added_and_replace_disk_files() {
    let fixture = Fixture::new();
    let root = fixture.sample_package();
    let mut output = Vec::new();
    archive::export(&root, "W", &mut output, &support::extras(&[("widget.json", "{\"generated\":true}"), ("notes/new.txt", "new")]), &ArchiveLimits::default()).unwrap();
    let contents: BTreeMap<String, Vec<u8>> = read_zip(&output).into_iter().collect();
    assert_eq!(contents["W/widget.json"], b"{\"generated\":true}");
    assert_eq!(contents["W/notes/new.txt"], b"new");
    assert_eq!(contents.len(), 6);
    for path in ["../escape.txt", "/abs.txt", ".hidden", "__Build/x.js", "a\\b"] {
        assert_code("invalid_path", archive::export(&root, "W", &mut Vec::new(), &support::extras(&[(path, "x")]), &ArchiveLimits::default()));
    }
}

#[test]
fn checksum_matches_the_zip_crc32() {
    assert_eq!(archive::crc32(b"123456789"), 0xCBF4_3926);
    assert_eq!(archive::crc32(b""), 0);
    assert_eq!(support::crc32(b"123456789"), 0xCBF4_3926);
}

// Other ZIP software

fn run(command: &mut std::process::Command) -> String {
    let output = command.output().unwrap_or_else(|error| panic!("{command:?}: {error}"));
    assert!(output.status.success(), "{command:?}: {}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap()
}

/// The archives this crate reads and writes are checked everywhere else with
/// fixtures and a reader written for these tests. This one asks software that
/// shares no code with it: Info-ZIP and Python's `zipfile`.
#[test]
#[ignore = "needs the zip, unzip and python3 commands; run with `cargo test -- --ignored`"]
fn other_zip_software_reads_exports_and_writes_importable_archives() {
    use std::process::Command;
    let fixture = Fixture::new();
    let root = fixture.sample_package();
    let exported = fixture.temporary.path("exported.swt");
    std::fs::write(&exported, export(&root)).unwrap();

    // Reading an export.
    run(Command::new("unzip").arg("-t").arg(&exported));
    assert_eq!(run(Command::new("unzip").arg("-Z1").arg(&exported)).lines().collect::<Vec<_>>(), EXPORTED);
    let listed = run(Command::new("python3").args(["-c", "import sys, zipfile\nz = zipfile.ZipFile(sys.argv[1])\nassert z.testzip() is None\nprint('\\n'.join(z.namelist()))"]).arg(&exported));
    assert_eq!(listed.lines().collect::<Vec<_>>(), EXPORTED);
    let unpacked = fixture.temporary.new_folder("unpacked");
    run(Command::new("unzip").arg("-q").arg(&exported).arg("-d").arg(&unpacked));
    let original = DiskPackageFiles::new(&root);
    for path in original.paths() {
        assert_eq!(std::fs::read(unpacked.join("My Widget").join(&path)).ok(), original.read_bytes(&path), "{path}");
    }

    // Importing what they write: directory entries, extra fields, stored and deflated files.
    let made = fixture.temporary.new_folder("made");
    write_file(&made.join("Widget/widget.json"), manifest("Widget").as_bytes());
    write_file(&made.join("Widget/main.jsx"), "$render(<text>阅读</text>);".as_bytes());
    write_file(&made.join("Widget/src/data.txt"), "compressible ".repeat(10_000).as_bytes());
    write_file(&made.join("Widget/image/tiny.bin"), &[0, 1, 2]);
    let by_zip = fixture.temporary.path("by-zip.zip");
    run(Command::new("zip").current_dir(&made).arg("-r").arg("-q").arg(&by_zip).arg("Widget"));
    let by_python = fixture.temporary.path("by-python.zip");
    let script = "import os, sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:\n    for base, _, names in os.walk('Widget'):\n        for name in names:\n            z.write(os.path.join(base, name))";
    run(Command::new("python3").current_dir(&made).args(["-c", script]).arg(&by_python));
    for written in [&by_zip, &by_python] {
        let extracted = fixture.extract(&std::fs::read(written).unwrap()).unwrap_or_else(|error| panic!("{written:?}: {error}"));
        assert_eq!(extracted.root_name(), Some("Widget"));
        assert_eq!(tree(extracted.directory()), ["image/", "image/tiny.bin", "main.jsx", "src/", "src/data.txt", "widget.json"], "{written:?}");
        for path in ["widget.json", "main.jsx", "src/data.txt", "image/tiny.bin"] {
            assert_eq!(std::fs::read(extracted.directory().join(path)).unwrap(), std::fs::read(made.join("Widget").join(path)).unwrap(), "{written:?} {path}");
        }
    }
    assert!(tree(&fixture.staging).is_empty());
}
