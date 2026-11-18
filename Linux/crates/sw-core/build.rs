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
    for name in ["icu-i18n", "icu-uc"] {
        // Emits the link flags and returns the include paths of the headers.
        let library = pkg_config::Config::new()
            .probe(name)
            .unwrap_or_else(|error| panic!("the ICU development files ({name}.pc) are required: {error}"));
        for path in library.include_paths {
            build.include(path);
        }
    }
    build.compile("swicu");
}
