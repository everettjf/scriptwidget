//! Removing one file of an installed package (`PackageStore::delete_file`),
//! which `scriptwidget dev` uses to make an installed package follow a folder.

#![allow(dead_code)]

#[path = "packages_support/mod.rs"]
mod support;

use support::{SOURCE, TemporaryFolder, assert_code, hard_link, symlink, write_file};
use sw_core::packages::PackageStore;

#[test]
fn removes_only_regular_files_inside_the_package() {
    let temporary = TemporaryFolder::new();
    let library = temporary.path("library");
    let store = PackageStore::new(&library, temporary.path("staging"));
    store.create("Widget", SOURCE, None).unwrap();
    store.write_file("Widget", "lib/util.js", b"1").unwrap();
    store.write_file("Widget", "notes.txt", b"2").unwrap();
    let package = library.join("Widget");

    store.delete_file("Widget", "lib/util.js").unwrap();
    assert!(!package.join("lib/util.js").exists());
    assert!(package.join("lib").is_dir(), "the directory stays");
    // Already gone, or never there, is not an error.
    store.delete_file("Widget", "lib/util.js").unwrap();
    store.delete_file("Widget", "nowhere/at/all.js").unwrap();
    assert_code("package_not_found", store.delete_file("Missing", "main.jsx"));

    // Nothing outside the package, no dot-file, no cache.
    let outside = temporary.new_file("outside.txt", "keep");
    for path in ["../outside.txt", "/etc/hostname", "lib/../../outside.txt", "a\\b", "", ".scriptwidget-installation", "__Build/prepared.json", "lib/.hidden"] {
        assert_code("invalid_path", store.delete_file("Widget", path));
    }
    assert!(outside.exists());

    // A link is refused and its target stays; so does a file with a second hard link, and a directory.
    symlink(&package.join("link.txt"), &outside);
    assert_code("unsafe_file", store.delete_file("Widget", "link.txt"));
    assert!(outside.exists() && package.join("link.txt").is_symlink());
    std::fs::remove_file(package.join("link.txt")).unwrap();
    hard_link(&package.join("hard.txt"), &outside);
    assert_code("unsafe_file", store.delete_file("Widget", "hard.txt"));
    assert_eq!(std::fs::read_to_string(&outside).unwrap(), "keep");
    std::fs::remove_file(package.join("hard.txt")).unwrap();
    assert_code("unsafe_file", store.delete_file("Widget", "lib"));

    // A directory on the way that is a link is not walked through.
    let elsewhere = temporary.new_folder("elsewhere");
    write_file(&elsewhere.join("victim.js"), b"keep");
    symlink(&package.join("linked"), &elsewhere);
    assert_code("unsafe_file", store.delete_file("Widget", "linked/victim.js"));
    assert!(elsewhere.join("victim.js").exists());

    store.delete_file("Widget", "notes.txt").unwrap();
    assert!(!package.join("notes.txt").exists() && package.join("main.jsx").exists());
}
