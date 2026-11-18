//! Executes every package of the parity corpus and draws its tree at the
//! three desktop widget sizes, scale 2. Fails on a layout or paint error and
//! on an empty bitmap; a handful of the pictures are saved for review. The
//! Linux counterpart of `EveryCorpusPackageRendersAtEverySize` in
//! `Windows/tests/ScriptWidget.Core.Tests/Render/RenderTests.cs`.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-render --test corpus -- --nocapture
//!   SCRIPTWIDGET_RENDER_ALL=1 cargo test -p sw-render --test corpus    # keep every picture
//!
//! This file holds a single test because it sets the time zone of the whole
//! process (see `sw-core/tests/parity.rs`).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use sw_core::api::StorageModule;
use sw_core::compiler::PrepareOptions;
use sw_core::{ExecutionRequest, MemoryPackageFiles, NativeModule, PackageCompiler, PackageFiles, ScriptExecutor, SharedScripts, intl};
use sw_render::{RenderRequest, WidgetRenderer};

/// 2026-01-01 12:00 UTC.
const FIXED_NOW: i64 = 1_767_268_800_000;

/// Packages whose pictures are written for review: clocks, charts, Chinese text, emoji, images, gradients and whole templates.
const REVIEWED: &[&str] = &[
    "api/gradient",
    "component/button",
    "component/chart",
    "component/gauge",
    "component/gif",
    "component/icon",
    "component/image",
    "component/ring",
    "component/text",
    "component/toggle",
    "template/Activity Rings",
    "template/Animation Aquarium",
    "template/Animation Clock",
    "template/Daily Agenda",
    "template/Image Basic Usage",
    "template/Lunar Date",
    "template/Material Study",
    "template/Month Calendar",
    "template/Mood Check-in",
    "template/Nyan Cat",
    "template/Personal Dashboard",
    "template/Shape",
    "template/System Status Panel",
    "template/Text Year Days Left",
    "template/Weather Glance",
    "template/World Clock Faces",
];

fn linux_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn file_name(name: &str) -> String {
    name.replace(['/', ' '], "_")
}

/// The bytes of a package image, from the repository's bundled packages. The
/// corpus lists binary files by name only; without the file the package is
/// drawn with an empty one, which the layout shows as a missing image.
fn binary(package: &str, path: &str) -> Vec<u8> {
    let repository = linux_directory().join("..");
    let bundled = repository.join("Shared/ScriptWidgetRuntime/Resource/Script.bundle").join(package).join(path);
    let gallery = repository.join("Gallery/widgets").join(package.trim_start_matches("gallery/")).join(path);
    std::fs::read(bundled).or_else(|_| std::fs::read(gallery)).unwrap_or_default()
}

fn clip(text: &str, length: usize) -> String {
    text.chars().take(length).collect()
}

fn percentile(sorted: &[Duration], fraction: f64) -> Duration {
    sorted.get(((sorted.len() as f64 - 1.0) * fraction).round() as usize).copied().unwrap_or_default()
}

fn milliseconds(duration: Duration) -> String {
    format!("{:.2}", duration.as_secs_f64() * 1000.0)
}

#[test]
fn every_corpus_package_renders_at_every_size() {
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

    let write_all = std::env::var("SCRIPTWIDGET_RENDER_ALL").as_deref() == Ok("1");
    let output = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/out");
    let sizes = [("small", 170.0f32, 170.0f32), ("medium", 329.0, 170.0), ("large", 329.0, 345.0)];
    for (family, _, _) in sizes {
        let directory = output.join(family);
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("output directory");
    }

    let scripts = Arc::new(SharedScripts::new(linux_directory().join("assets/scriptwidget")).expect("shared scripts"));
    let compiler = PackageCompiler::new(scripts.clone()).expect("compiler thread");
    let executor = ScriptExecutor::new(scripts.clone());
    let start = std::time::Instant::now();
    let renderer = WidgetRenderer::with_locale(scripts, locale).expect("render thread");
    let fonts = renderer.fonts().expect("fonts");
    // Starting the thread, loading the bundled fonts and asking fontconfig for the system ones.
    let font_time = start.elapsed();
    let storage_directory = std::env::temp_dir().join(format!("scriptwidget-render-storage-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&storage_directory);
    let storage: Arc<dyn NativeModule> = Arc::new(StorageModule::new(&storage_directory));

    let mut failures: Vec<String> = Vec::new();
    let (mut layout, mut paint, mut encode) = (Duration::ZERO, Duration::ZERO, Duration::ZERO);
    let mut totals: Vec<Duration> = Vec::new();
    let mut slowest = (Duration::ZERO, String::new());
    let mut first = None;
    let (mut binaries_found, mut binaries_missing, mut hit_regions, mut gif_slots, mut written) = (0usize, 0usize, 0usize, 0usize, 0usize);
    for (index, item) in packages.iter().enumerate() {
        let name = item["name"].as_str().unwrap_or("?");
        let text = item["files"].as_object().expect("package files").iter().map(|(path, content)| (path.clone(), content.as_str().unwrap_or("").to_owned()));
        let binaries: Vec<(String, Vec<u8>)> = item["binaries"].as_array().into_iter().flatten().filter_map(|path| Some((path.as_str()?.to_owned(), binary(name, path.as_str()?)))).collect();
        binaries_found += binaries.iter().filter(|(_, data)| !data.is_empty()).count();
        binaries_missing += binaries.iter().filter(|(_, data)| data.is_empty()).count();
        let files = Arc::new(MemoryPackageFiles::new(text, binaries));

        let prepared = match compiler.prepare(files.as_ref(), &PrepareOptions { prelude, ..Default::default() }) {
            Ok(prepared) => prepared,
            Err(error) => {
                failures.push(format!("{name}: prepare failed [{}] {}", error.kind, clip(&error.message, 300)));
                continue;
            }
        };
        let mut request = ExecutionRequest::new(&prepared, files.as_ref());
        request.modules = vec![storage.clone()];
        request.package_id = format!("render-{index}");
        let result = executor.execute(&request);
        let Some(tree) = result.tree else {
            let error = result.error.as_ref();
            failures.push(format!("{name}: no tree: [{}] {}", error.map_or("", |error| error.kind.as_str()), clip(error.map_or("", |error| error.message.as_str()), 300)));
            continue;
        };

        for (family, width, height) in sizes {
            let mut request = RenderRequest::new(tree.clone(), width, height, 2.0);
            request.family = family.to_owned();
            request.files = Some(files.clone() as Arc<dyn PackageFiles>);
            request.now_milliseconds = Some(FIXED_NOW);
            let rendered = match renderer.render(request.clone()) {
                Ok(rendered) => rendered,
                Err(error) => {
                    failures.push(format!("{name} ({family}): {}", clip(&error.message, 500)));
                    continue;
                }
            };
            let total = rendered.layout_time + rendered.paint_time;
            first.get_or_insert(total);
            layout += rendered.layout_time;
            paint += rendered.paint_time;
            if total > slowest.0 {
                slowest = (total, format!("{name} ({family})"));
            }
            totals.push(total);
            hit_regions += rendered.hit_regions.len();
            gif_slots += rendered.gif_slots.len();
            if (rendered.pixel_width, rendered.pixel_height) != ((width * 2.0) as u32, (height * 2.0) as u32) {
                failures.push(format!("{name} ({family}): bitmap is {}x{}", rendered.pixel_width, rendered.pixel_height));
            }
            if rendered.pixels.len() != rendered.pixel_width as usize * rendered.pixel_height as usize * 4 {
                failures.push(format!("{name} ({family}): {} bytes for {}x{}", rendered.pixels.len(), rendered.pixel_width, rendered.pixel_height));
            }
            if rendered.pixels.chunks_exact(4).all(|pixel| pixel[3] == 0) {
                failures.push(format!("{name} ({family}): bitmap is empty"));
            }
            // Premultiplied: no color channel exceeds the alpha.
            if rendered.pixels.chunks_exact(4).any(|pixel| pixel[0] > pixel[3] || pixel[1] > pixel[3] || pixel[2] > pixel[3]) {
                failures.push(format!("{name} ({family}): a pixel is not premultiplied"));
            }
            for hit in &rendered.hit_regions {
                let bounds = hit.bounds;
                if !(bounds.width() > 0.0 && bounds.height() > 0.0) || hit.interaction.is_empty() {
                    failures.push(format!("{name} ({family}): tap region {bounds:?} {:?}", hit.interaction));
                }
            }
            if write_all || REVIEWED.contains(&name) {
                let encode_start = std::time::Instant::now();
                match rendered.encode_png() {
                    Ok(png) => {
                        encode += encode_start.elapsed();
                        written += 1;
                        std::fs::write(output.join(family).join(file_name(name) + ".png"), png).expect("PNG file");
                    }
                    Err(error) => failures.push(format!("{name} ({family}): {error}")),
                }
                // The recorded elements, to compare a picture with the CSS it was drawn from.
                if write_all {
                    std::fs::write(output.join(family).join(file_name(name) + ".json"), renderer.layout(request).unwrap_or_default()).expect("layout file");
                }
            }
        }
    }
    let _ = std::fs::remove_dir_all(&storage_directory);
    drop(renderer);
    drop(compiler);
    intl::set_locale_override(None);
    // SAFETY: as above; the compiler and render threads have ended.
    unsafe { intl::set_time_zone_override(None) };

    let renders = totals.len();
    totals.sort_unstable();
    let mean = |total: Duration| milliseconds(total / renders.max(1) as u32);
    let summary = format!(
        "rendered {renders} bitmaps of {} packages on {} {}; layout mean {} ms, paint mean {} ms; whole render median {} ms, 95th percentile {} ms, slowest {} ms ({}), first {} ms (it creates the layout context), finding the fonts before it {} ms; PNG encoding mean {} ms over {written} files; {hit_regions} tap regions, {gif_slots} animated GIFs; package images found {binaries_found}, missing {binaries_missing}; bundled Inter {}; CJK families {:?}; monospace {:?}; serif {:?}; {}",
        packages.len(),
        std::env::consts::OS,
        std::env::consts::ARCH,
        mean(layout),
        mean(paint),
        milliseconds(percentile(&totals, 0.5)),
        milliseconds(percentile(&totals, 0.95)),
        milliseconds(slowest.0),
        slowest.1,
        milliseconds(first.unwrap_or_default()),
        milliseconds(font_time),
        milliseconds(encode / written.max(1) as u32),
        fonts.bundled,
        fonts.cjk_families,
        fonts.monospace,
        fonts.serif,
        output.display(),
    );
    println!("{summary}");
    for failure in &failures {
        println!("  {failure}");
    }
    assert!(!packages.is_empty(), "corpus is empty");
    assert!(fonts.bundled, "the bundled Inter was not loaded");
    assert!(failures.is_empty(), "{summary}\n{}", failures.join("\n"));
}
