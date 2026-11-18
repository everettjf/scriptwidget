//! Compiles the QuickJS-NG sources the Android and Windows apps build
//! (`Android/core/src/main/cpp/quickjs`) together with the C binding in
//! `native/swquickjs.c`. No system or third-party QuickJS is used, so every
//! platform runs the same engine.

use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let quickjs = manifest.join("../../../Android/core/src/main/cpp/quickjs");
    let binding = manifest.join("native/swquickjs.c");
    assert!(
        quickjs.join("quickjs.c").is_file(),
        "QuickJS-NG sources not found at {}; sw-quickjs builds inside the ScriptWidget repository",
        quickjs.display()
    );

    let sources = ["quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c"];
    let mut build = cc::Build::new();
    build
        .std("c11")
        .include(&quickjs)
        .define("_GNU_SOURCE", None)
        // The interpreter is unusable unoptimized (Babel alone takes many
        // seconds), so it is optimized in debug builds as well, with the
        // level the Android build uses.
        .opt_level(2)
        .warnings(false)
        .flag_if_supported("-fvisibility=hidden")
        .file(&binding);
    for name in sources {
        build.file(quickjs.join(name));
    }
    // SW_QUICKJS_ASAN=1 builds the C side with AddressSanitizer and links its
    // runtime. Rust itself is not instrumented (that needs a nightly
    // toolchain), so the runtime is not first in the library list: run the
    // tests with LD_PRELOAD set to the path `cc -print-file-name=libasan.so`
    // prints. Linux only.
    println!("cargo:rerun-if-env-changed=SW_QUICKJS_ASAN");
    if std::env::var_os("SW_QUICKJS_ASAN").is_some_and(|value| value == "1") {
        build.flag("-fsanitize=address").flag("-fno-omit-frame-pointer");
        println!("cargo:rustc-link-lib=asan");
    }
    build.compile("swquickjs");

    println!("cargo:rerun-if-changed={}", binding.display());
    for entry in std::fs::read_dir(&quickjs).expect("QuickJS source directory") {
        println!("cargo:rerun-if-changed={}", entry.expect("QuickJS source file").path().display());
    }
    println!("cargo:rustc-link-lib=m");
}
