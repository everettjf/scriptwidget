//! Builds the API reference of the code editor into the program.
//!
//! `node Linux/scripts/build-shared-js.mjs` writes it to
//! `Linux/assets/scriptwidget/api-reference.json` from the metadata the other
//! editors complete from. When that file is missing the program still
//! builds, with an editor that completes nothing, and the build says so.

use std::path::PathBuf;

fn main() {
    let source = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget/api-reference.json");
    let target = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("api-reference.json");
    println!("cargo:rerun-if-changed={}", source.display());
    let json = std::fs::read_to_string(&source).unwrap_or_else(|_| {
        println!("cargo:warning={} is missing: the code editor will complete nothing. Run node Linux/scripts/build-shared-js.mjs.", source.display());
        "{}".to_owned()
    });
    std::fs::write(target, json).expect("write the API reference");
}
