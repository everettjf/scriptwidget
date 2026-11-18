//! The read-only view of a package directory. Ported from `DiskPackageFilesTests.cs`.

#[path = "packages_support/mod.rs"]
mod support;

use std::path::PathBuf;

use support::{TemporaryFolder, assert_code, hard_link, nested, symlink, write_file};
use sw_core::PackageFiles;
use sw_core::packages::DiskPackageFiles;
use sw_core::packages::limits::{MAX_BINARY_READ_BYTES, MAX_FILE_COUNT, MAX_SCRIPT_BYTES, MAX_TEXT_BYTES};

struct Fixture {
    temporary: TemporaryFolder,
    root: PathBuf,
    outside: PathBuf,
    files: DiskPackageFiles,
}

impl Fixture {
    fn new() -> Self {
        let temporary = TemporaryFolder::new();
        let root = temporary.new_folder("library/Widget");
        let outside = temporary.new_folder("outside");
        write_file(&outside.join("secret.txt"), b"secret");
        write_file(&outside.join("secret.js"), b"secret()");
        let fixture = Self { files: DiskPackageFiles::new(&root), temporary, root, outside };
        fixture.write("main.jsx", b"$render(<text/>);");
        fixture.write("widget.json", b"{}");
        fixture.write("src/util/helper.js", b"export const a = 1;");
        fixture.write("image/logo.png", b"PNG");
        fixture
    }

    fn write(&self, path: &str, bytes: &[u8]) {
        write_file(&self.root.join(path), bytes);
    }

    fn link(&self, path: &str, target: PathBuf) {
        symlink(&self.root.join(path), &target);
    }

    fn assert_refused(&self, path: &str) {
        assert!(!self.files.exists(path), "{path:?} exists");
        assert_eq!(self.files.read_text(path), None, "{path:?}");
        assert_eq!(self.files.read_bytes(path), None, "{path:?}");
    }
}

const LISTED: [&str; 4] = ["image/logo.png", "main.jsx", "src/util/helper.js", "widget.json"];

#[test]
fn lists_regular_files_as_sorted_normalized_paths() {
    let fixture = Fixture::new();
    assert_eq!(fixture.files.paths(), LISTED);
    assert_eq!(fixture.files.list().unwrap(), LISTED);
}

#[test]
fn listing_skips_dot_files_build_cache_and_links() {
    let fixture = Fixture::new();
    fixture.write(".DS_Store", b"x");
    fixture.write(".git/config", b"x");
    fixture.write("src/.cache/tmp.js", b"x");
    fixture.write("__Build/main.js", b"compiled");
    fixture.write("src/__build/main.js", b"compiled");
    fixture.link("linked.js", fixture.outside.join("secret.js"));
    fixture.link("linkedDir", fixture.outside.clone());
    fixture.link("dangling.js", fixture.outside.join("missing.js"));
    assert_eq!(fixture.files.paths(), LISTED);
}

#[test]
fn reads_existing_files() {
    let fixture = Fixture::new();
    assert!(fixture.files.exists("main.jsx"));
    assert!(fixture.files.exists("src/util/helper.js"));
    assert_eq!(fixture.files.read_text("src/util/helper.js").as_deref(), Some("export const a = 1;"));
    assert_eq!(fixture.files.read_bytes("image/logo.png").as_deref(), Some(&b"PNG"[..]));
    assert_eq!(fixture.files.read_bytes("widget.json").as_deref(), Some(&b"{}"[..]));
}

#[test]
fn rejects_paths_that_are_not_normalized_package_relative_paths() {
    let fixture = Fixture::new();
    write_file(&fixture.root.parent().unwrap().join("sibling.js"), b"sibling");
    let absolute_inside = fixture.root.join("main.jsx").to_string_lossy().into_owned();
    let absolute_outside = fixture.outside.join("secret.js").to_string_lossy().into_owned();
    let too_deep = nested("d", 17) + ".js";
    let too_long = "x".repeat(256) + ".js";
    let unsafe_paths = [
        "",
        "/",
        ".",
        "..",
        "../sibling.js",
        "../Widget/main.jsx",
        "src/../main.jsx",
        "src/../../sibling.js",
        "./main.jsx",
        "src//util/helper.js",
        "main.jsx/",
        "/main.jsx",
        &absolute_inside,
        &absolute_outside,
        "src\\util\\helper.js",
        "..\\sibling.js",
        "main.jsx\0",
        "main\0.jsx",
        "C:main.jsx",
        "src/util/helper.js\n",
        &too_deep,
        &too_long,
    ];
    for path in unsafe_paths {
        fixture.assert_refused(path);
    }
}

#[test]
fn exists_is_true_only_for_regular_files() {
    let fixture = Fixture::new();
    assert!(!fixture.files.exists("src"));
    assert!(!fixture.files.exists("src/util"));
    assert!(!fixture.files.exists("missing.js"));
    assert!(!fixture.files.exists("main.jsx/child.js"));
    assert_eq!(fixture.files.read_bytes("src"), None);
}

#[test]
fn rejects_symbolic_links_at_every_component() {
    let fixture = Fixture::new();
    fixture.link("linked.js", fixture.outside.join("secret.js"));
    fixture.link("linkedDir", fixture.outside.clone());
    fixture.link("src/deep/link", fixture.outside.clone());
    fixture.link("inside.js", fixture.root.join("main.jsx"));
    fixture.link("relative.js", PathBuf::from("main.jsx"));
    fixture.link("dangling.js", fixture.outside.join("missing.js"));
    for path in ["linked.js", "linkedDir/secret.js", "linkedDir/secret.txt", "src/deep/link/secret.js", "inside.js", "relative.js", "dangling.js", "linkedDir"] {
        fixture.assert_refused(path);
    }
}

#[test]
fn rejects_a_package_root_that_is_itself_a_link() {
    let fixture = Fixture::new();
    let alias = fixture.temporary.path("alias");
    symlink(&alias, &fixture.root);
    let linked = DiskPackageFiles::new(&alias);
    assert!(linked.paths().is_empty());
    assert!(!linked.exists("main.jsx"));
    assert_eq!(linked.read_text("main.jsx"), None);
    assert_eq!(linked.read_bytes("main.jsx"), None);
    assert!(DiskPackageFiles::new(fixture.temporary.path("missing")).paths().is_empty());
}

#[test]
fn rejects_hard_linked_files() {
    let fixture = Fixture::new();
    hard_link(&fixture.root.join("hard.js"), &fixture.outside.join("secret.js"));
    fixture.assert_refused("hard.js");
    assert!(!fixture.files.paths().contains(&"hard.js".to_owned()));
    // A second link from inside the package is as much a second name as one from outside.
    hard_link(&fixture.root.join("twin.jsx"), &fixture.root.join("main.jsx"));
    fixture.assert_refused("twin.jsx");
    fixture.assert_refused("main.jsx");
}

#[test]
fn rejects_case_aliases_and_hidden_or_cache_paths() {
    let fixture = Fixture::new();
    fixture.write(".env", b"TOKEN=1");
    fixture.write("__Build/main.js", b"compiled");
    for path in ["MAIN.jsx", "Main.JSX", "SRC/util/helper.js", "Widget.json", ".env", "__Build/main.js", "__build/main.js"] {
        assert!(!fixture.files.exists(path), "{path}");
        assert_eq!(fixture.files.read_bytes(path), None, "{path}");
    }
}

#[test]
fn read_text_returns_only_bounded_utf8_text_files() {
    let fixture = Fixture::new();
    fixture.write("data.bin", b"text in a binary file");
    fixture.write("bad.txt", &[0x66, 0xC3, 0x28]);
    fixture.write("big.jsx", &vec![b'a'; MAX_SCRIPT_BYTES + 1]);
    fixture.write("edge.jsx", &vec![b'a'; MAX_SCRIPT_BYTES]);
    fixture.write("EDGE.MJS", &vec![b'a'; MAX_SCRIPT_BYTES + 1]);
    fixture.write("notes.txt", &vec![b'a'; MAX_SCRIPT_BYTES + 1]);
    fixture.write("huge.txt", &vec![b'a'; MAX_TEXT_BYTES + 1]);
    fixture.write("unicode.md", "阅读 👩‍💻".as_bytes());
    assert_eq!(fixture.files.read_text("image/logo.png"), None);
    assert_eq!(fixture.files.read_text("data.bin"), None);
    assert_eq!(fixture.files.read_text("bad.txt"), None);
    assert_eq!(fixture.files.read_text("big.jsx"), None);
    assert_eq!(fixture.files.read_text("EDGE.MJS"), None);
    assert_eq!(fixture.files.read_text("edge.jsx").map(|text| text.len()), Some(MAX_SCRIPT_BYTES));
    assert_eq!(fixture.files.read_text("notes.txt").map(|text| text.len()), Some(MAX_SCRIPT_BYTES + 1));
    assert_eq!(fixture.files.read_text("huge.txt"), None);
    assert_eq!(fixture.files.read_text("unicode.md").as_deref(), Some("阅读 👩‍💻"));
    assert_eq!(fixture.files.read_bytes("huge.txt").map(|bytes| bytes.len()), Some(MAX_TEXT_BYTES + 1));
}

#[test]
fn read_bytes_is_capped_at_sixteen_mebibytes() {
    let fixture = Fixture::new();
    fixture.write("edge.bin", &vec![0; MAX_BINARY_READ_BYTES]);
    fixture.write("big.bin", &vec![0; MAX_BINARY_READ_BYTES + 1]);
    assert_eq!(fixture.files.read_bytes("edge.bin").map(|bytes| bytes.len()), Some(MAX_BINARY_READ_BYTES));
    assert_eq!(fixture.files.read_bytes("big.bin"), None);
    assert!(fixture.files.exists("big.bin"));
    assert_eq!(fixture.files.read_bytes_up_to("big.bin", MAX_BINARY_READ_BYTES as u64 + 1).map(|bytes| bytes.len()), Some(MAX_BINARY_READ_BYTES + 1));
}

#[test]
fn listing_fails_closed_beyond_the_entry_limit() {
    let fixture = Fixture::new();
    for index in 0..MAX_FILE_COUNT {
        fixture.write(&format!("many/f{index}.txt"), b"x");
    }
    assert_code("too_many_entries", fixture.files.list());
    // Through the runtime's view, a package with too many files has none: it cannot be compiled or run.
    assert!(fixture.files.paths().is_empty());
}

#[test]
fn listing_stops_at_the_depth_limit() {
    let fixture = Fixture::new();
    fixture.write(&(nested("d", 15) + "/ok.js"), b"x");
    fixture.write(&(nested("e", 16) + "/deep.js"), b"x");
    let listed = fixture.files.paths();
    assert!(listed.iter().any(|path| path.ends_with("/ok.js")));
    assert!(!listed.iter().any(|path| path.ends_with("/deep.js")));
}
