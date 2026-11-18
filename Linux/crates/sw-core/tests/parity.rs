//! Runs every bundled package that needs no live data through QuickJS and
//! compares the canonical element tree, byte for byte, with the one
//! JavaScriptCore produced (Web/preview-engine/test/parity/native-trees.json).
//! The Linux counterpart of Windows/tests/ScriptWidget.Core.Tests/ParityTests.cs.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-core --test parity -- --nocapture
//!
//! This file holds a single test because it sets the time zone of the whole
//! process (the corpus was recorded in one zone): Cargo runs each test file
//! as its own program, and with one test nothing else reads the environment
//! or local time while it changes. The zone reaches JavaScript's `Date`
//! through the C library (TZ and tzset) and Intl through ICU, to which the
//! bridge passes the zone by name.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use sw_core::api::StorageModule;
use sw_core::compiler::PrepareOptions;
use sw_core::{ExecutionRequest, MemoryPackageFiles, NativeModule, PackageCompiler, ScriptExecutor, SharedScripts, intl};

fn linux_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// A stretch of text around a byte offset, cut at character boundaries.
fn window(text: &str, at: usize) -> &str {
    let mut start = at.saturating_sub(60);
    while !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = (at + 100).min(text.len());
    while !text.is_char_boundary(end) {
        end += 1;
    }
    &text[start..end]
}

fn clip(text: &str, length: usize) -> String {
    text.chars().take(length).collect()
}

#[test]
fn bundled_packages_produce_the_same_trees_as_javascriptcore() {
    let corpus_file = linux_directory().join("tests/assets/parity-corpus.json");
    let corpus_text = std::fs::read_to_string(&corpus_file).unwrap_or_else(|error| panic!("{}: {error}. Run node Linux/scripts/build-shared-js.mjs.", corpus_file.display()));
    let corpus: Value = serde_json::from_str(&corpus_text).expect("parity corpus is JSON");
    let time_zone = corpus["timeZone"].as_str().expect("corpus time zone");
    let locale = corpus["locale"].as_str().unwrap_or("en-US");
    let prelude = corpus["prelude"].as_str().unwrap_or("");
    let packages = corpus["corpus"].as_array().expect("corpus packages");

    // SAFETY: the only test of this program, and no other thread exists yet
    // that reads the environment or converts local time.
    unsafe { intl::set_time_zone_override(Some(time_zone)) };
    intl::set_locale_override(Some(locale));

    let scripts = Arc::new(SharedScripts::new(linux_directory().join("assets/scriptwidget")).expect("shared scripts"));
    let compiler = PackageCompiler::new(scripts.clone()).expect("compiler thread");
    let executor = ScriptExecutor::new(scripts);
    // Each package starts with empty storage, like the JavaScriptCore reference run.
    let storage_directory = std::env::temp_dir().join(format!("scriptwidget-parity-storage-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&storage_directory);
    let storage: Arc<dyn NativeModule> = Arc::new(StorageModule::new(&storage_directory));

    let mut failures: Vec<String> = Vec::new();
    let (mut compile, mut execute, mut slowest, mut first_compile) = (Duration::ZERO, Duration::ZERO, Duration::ZERO, None);
    for (index, item) in packages.iter().enumerate() {
        let name = item["name"].as_str().unwrap_or("?");
        let text = item["files"].as_object().expect("package files").iter().map(|(path, content)| (path.clone(), content.as_str().unwrap_or("").to_owned()));
        let binaries = item["binaries"].as_array().into_iter().flatten().filter_map(|path| Some((path.as_str()?.to_owned(), Vec::new())));
        let files = MemoryPackageFiles::new(text, binaries);
        let expected = item["expected"]["tree"].as_str();

        let compile_start = Instant::now();
        let prepared = match compiler.prepare(&files, &PrepareOptions { prelude, ..Default::default() }) {
            Ok(prepared) => prepared,
            Err(error) => {
                failures.push(format!("{name}: prepare failed [{}] {}", error.kind, clip(&error.message, 300)));
                continue;
            }
        };
        // The first compile also loads Babel into a new context.
        first_compile.get_or_insert(compile_start.elapsed());
        compile += compile_start.elapsed();

        let mut request = ExecutionRequest::new(&prepared, &files);
        request.modules = vec![storage.clone()];
        request.package_id = format!("parity-{index}");
        let result = executor.execute(&request);
        execute += result.elapsed;
        slowest = slowest.max(result.elapsed);

        let Some(expected) = expected else {
            failures.push(format!("{name}: no native reference tree"));
            continue;
        };
        match result.tree.as_deref() {
            Some(actual) if actual == expected => {}
            Some(actual) => {
                let at = actual.bytes().zip(expected.bytes()).take_while(|(left, right)| left == right).count();
                failures.push(format!("{name}: tree differs at byte {at}\n      native: {}\n      linux : {}", window(expected, at), window(actual, at)));
            }
            None => {
                let error = result.error.as_ref();
                failures.push(format!("{name}: error [{}] {}", error.map_or("", |error| error.kind.as_str()), clip(error.map_or("", |error| error.message.as_str()), 400)));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&storage_directory);
    drop(compiler);
    intl::set_locale_override(None);
    // SAFETY: as above; the compiler thread has ended.
    unsafe { intl::set_time_zone_override(None) };

    let total = packages.len();
    let summary = format!(
        "parity {}/{total}; ICU {}; {} {}; time zone {time_zone}; compile {} ms total (first {} ms, with loading Babel); execute {} ms total, slowest {} ms",
        total - failures.len(),
        intl::icu_version(),
        std::env::consts::OS,
        std::env::consts::ARCH,
        compile.as_millis(),
        first_compile.unwrap_or_default().as_millis(),
        execute.as_millis(),
        slowest.as_millis(),
    );
    println!("{summary}");
    for failure in &failures {
        println!("  {failure}");
    }
    assert!(total > 0, "corpus is empty");
    assert!(failures.is_empty(), "{summary}\n{}", failures.join("\n"));
}
