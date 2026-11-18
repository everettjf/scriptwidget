//! Compiles the ICU shim and links the system ICU.
//!
//! ICU's C functions are exported with the major version in their names
//! (`udat_open_78`); only the headers know the suffix. The shim is compiled
//! against the installed headers and re-exports the functions the Intl bridge
//! needs under fixed `sw_` names.

fn main() {
    println!("cargo:rerun-if-changed=native/icu_shim.c");
    let mut build = cc::Build::new();
    build.std("c11").file("native/icu_shim.c").warnings(true);
    // The shim is a static library that refers to ICU, so ICU has to come after
    // it on the link line: the link flags are printed once the shim is built.
    let mut libraries = Vec::new();
    for name in ["icu-i18n", "icu-uc"] {
        let library = pkg_config::Config::new()
            .cargo_metadata(false)
            .probe(name)
            .unwrap_or_else(|error| panic!("the ICU development files ({name}.pc) are required: {error}"));
        for path in &library.include_paths {
            build.include(path);
        }
        libraries.push(library);
    }
    build.compile("swicu");
    for library in &libraries {
        for path in &library.link_paths {
            println!("cargo:rustc-link-search=native={}", path.display());
        }
        for name in &library.libs {
            println!("cargo:rustc-link-lib={name}");
        }
    }
}
