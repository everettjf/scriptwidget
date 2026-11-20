//! The library of installed packages with the bundled templates, and the
//! facade that compiles and runs one package: the Linux counterparts of
//! `Hosting/Library.cs` and `WidgetRuntime.cs` on Windows. Needs the assets of
//! `node Linux/scripts/build-shared-js.mjs`.

#[path = "packages_support/mod.rs"]
mod support;

use std::path::PathBuf;
use std::sync::Arc;

use support::{TemporaryFolder, assert_code};
use sw_core::library::Library;
use sw_core::packages::{ArchiveLimits, DiskPackageFiles, validate_source_tree, validate_tree};
use sw_core::{DataPaths, MemoryPackageFiles, PackageFiles, RunRequest, SharedScripts, WidgetRuntime};

fn scripts() -> Arc<SharedScripts> {
    Arc::new(SharedScripts::new(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget")).expect("shared scripts"))
}

fn memory(files: &[(&str, &str)]) -> Arc<dyn PackageFiles> {
    Arc::new(MemoryPackageFiles::new(files.iter().map(|(path, text)| (path.to_string(), text.to_string())), []))
}

/// The real shipped templates: the one that asks for the device's location in a file main.jsx imports is not offered.
#[test]
fn a_template_is_judged_by_all_of_its_scripts() {
    let scratch = TemporaryFolder::new();
    scratch.new_file("templates/template/Local Weather/main.jsx", "$import('location.js');\n$render(<text>{await place()}</text>);");
    scratch.new_file("templates/template/Local Weather/location.js", "async function place() { const fix = await $location.current({timeout: 10}); return String(fix.latitude); }");
    scratch.new_file("templates/template/Now Playing/main.jsx", "$import('player.jsx');\n$render(<text>{await title()}</text>);");
    scratch.new_file("templates/template/Now Playing/player.jsx", "async function title() { return (await $music.current()).title; }");
    scratch.new_file("templates/template/Notes/main.jsx", "$render(<text>notes</text>);");
    // Not a script: what a text or data file says is not what the widget calls.
    scratch.new_file("templates/template/Notes/readme.md", "This widget does not use $health or $location.");
    scratch.new_file("templates/template/Both/main.jsx", "$import('a.js');\n$render(<text>{String($calendar.isAvailable())}</text>);");
    scratch.new_file("templates/template/Both/a.js", "const steps = $health.isAvailable();");
    let library = Library::new(&DataPaths::new(Some(&scratch.path("data"))).unwrap(), Some(scratch.path("templates")));
    let names: Vec<String> = library.bundled().into_iter().map(|package| package.name).collect();
    assert_eq!(names, ["Notes", "Now Playing"], "$music is implemented; $location is not, wherever it is used");
    let unavailable: Vec<(String, String)> = library.unavailable().into_iter().map(|template| (template.name, template.api)).collect();
    assert_eq!(unavailable, [("Both".to_owned(), "$calendar".to_owned()), ("Local Weather".to_owned(), "$location".to_owned())], "the entry's own global is named first");
    assert!(library.find_bundled("Local Weather").is_none());

    // The templates this repository ships, when the test runs in a checkout.
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle");
    if shipped.join("template").is_dir() {
        let library = Library::new(&DataPaths::new(Some(&scratch.path("data"))).unwrap(), Some(shipped));
        assert!(library.find_bundled("Local Weather (Location)").is_none(), "it needs $location, which Linux does not implement");
        assert!(library.unavailable().iter().any(|template| template.name == "Local Weather (Location)" && template.api == "$location"));
        for template in library.bundled() {
            for (path, content) in library.bundled_files(&template) {
                if path.ends_with(".js") || path.ends_with(".jsx") {
                    assert_eq!(sw_core::library::unsupported_api(&String::from_utf8_lossy(&content)), None, "{}/{} {path}", template.group, template.name);
                }
            }
        }
    }
}

/// A templates folder with one runnable template, one that needs an API Linux lacks, and entries that are no templates.
fn templates(scratch: &TemporaryFolder) -> PathBuf {
    scratch.new_file("templates/template/Clock/main.jsx", "$import('lib/label.js');\n$render(<text>{label()}</text>);");
    scratch.new_file("templates/template/Clock/lib/label.js", "function label() { return 'clock'; }");
    scratch.new_file("templates/template/Clock/meta.json", r#"{"description":"A clock"}"#);
    scratch.new_file("templates/template/Clock/.DS_Store", "noise");
    scratch.new_file("templates/template/Clock/__Build/prepared-1.json", "{}");
    scratch.new_file("templates/template/Quote/main.jsx", "const quote = await fetch(\"https://zenquotes.io/api/today\");\n$render(<text>q</text>);");
    scratch.new_file("templates/component/steps/main.jsx", "$render(<text>{String(await $health.steps())}</text>);");
    scratch.new_file("templates/api/declared/main.jsx", "$render(<text>declared</text>);");
    scratch.new_file("templates/api/declared/widget.json", &support::manifest("Template Name"));
    scratch.new_file("templates/api/no-entry/readme.txt", "no main.jsx");
    scratch.new_file("templates/other/ignored/main.jsx", "$render(<text>not a group</text>);");
    scratch.new_file("templates/template/.hidden/main.jsx", "$render(<text>hidden</text>);");
    scratch.new_file("outside.jsx", "$render(<text>outside</text>);");
    scratch.new_folder("templates/template/Linked");
    support::symlink(&scratch.path("templates/template/Linked/main.jsx"), &scratch.path("outside.jsx"));
    scratch.path("templates")
}

fn library(scratch: &TemporaryFolder) -> Library {
    Library::new(&DataPaths::new(Some(&scratch.path("data"))).unwrap(), Some(templates(scratch)))
}

#[test]
fn bundled_templates_are_listed_by_group_and_filtered_by_api() {
    let scratch = TemporaryFolder::new();
    let library = library(&scratch);
    let bundled = library.bundled();
    let names: Vec<(&str, &str, bool)> = bundled.iter().map(|package| (package.group.as_str(), package.name.as_str(), package.network)).collect();
    assert_eq!(names, [("template", "Clock", false), ("template", "Quote", true), ("api", "declared", false)], "groups in the order of the Apple apps; no links, dot-folders or other groups");
    let unavailable = library.unavailable();
    assert_eq!(unavailable.len(), 1);
    assert_eq!((unavailable[0].group.as_str(), unavailable[0].name.as_str(), unavailable[0].api.as_str()), ("component", "steps", "$health"));
    assert_eq!(library.find_bundled("template/Clock").map(|package| package.name), Some("Clock".into()));
    assert_eq!(library.find_bundled("declared").map(|package| package.group), Some("api".into()));
    assert!(library.find_bundled("component/steps").is_none() && library.find_bundled("api/Clock").is_none());
    // No templates folder at all is an empty list, not an error.
    let none = Library::new(&DataPaths::new(Some(&scratch.path("data"))).unwrap(), None);
    assert!(none.bundled().is_empty() && none.unavailable().is_empty());
}

#[test]
fn a_bundled_template_is_copied_into_the_library_with_a_manifest() {
    let scratch = TemporaryFolder::new();
    let library = library(&scratch);
    let clock = library.find_bundled("template/Clock").unwrap();
    assert_eq!(library.bundled_files(&clock).keys().map(String::as_str).collect::<Vec<_>>(), ["lib/label.js", "main.jsx", "meta.json"]);

    let installed = library.install_bundled(&clock).unwrap();
    assert_eq!(installed.name, "Clock");
    assert!(installed.manifest_present);
    assert_eq!(installed.description(), "A clock");
    assert!(installed.permissions().is_empty());
    assert_eq!(installed.files().paths(), ["lib/label.js", "main.jsx", "meta.json", "widget.json"]);
    // A second copy gets a numbered name and an identity of its own.
    let second = library.install_bundled(&clock).unwrap();
    assert_eq!(second.name, "Clock (1)");
    assert_ne!(second.installation, installed.installation);

    // The hosts a template names are declared for it, so its requests are allowed.
    let quote = library.install_bundled(&library.find_bundled("Quote").unwrap()).unwrap();
    assert_eq!(quote.permissions(), ["network"]);
    assert_eq!(quote.manifest.as_ref().unwrap()["networkDomains"], serde_json::json!(["zenquotes.io"]));
    // A template with a manifest keeps it, under the installed name and a fresh id.
    let declared = library.install_bundled(&library.find_bundled("api/declared").unwrap()).unwrap();
    assert_eq!(declared.name, "declared");
    assert_eq!(declared.display_name(), "declared");
    assert!(declared.manifest.as_ref().unwrap()["id"].as_str().unwrap().starts_with("local."));
    assert_eq!(declared.families(), ["small"]);

    let names: Vec<String> = library.list().unwrap().into_iter().map(|package| package.name).collect();
    assert_eq!(names, ["Clock", "Clock (1)", "declared", "Quote"], "sorted without regard to case");
}

#[test]
fn the_installation_identity_survives_a_rename_and_is_not_copied() {
    let scratch = TemporaryFolder::new();
    let library = library(&scratch);
    let created = library.create("Widget", support::SOURCE, None).unwrap();
    assert!((8..=64).contains(&created.installation.len()));
    assert_eq!(library.find("widget").unwrap().installation, created.installation, "found without regard to case, same identity");
    assert_eq!(library.find_by_installation(&created.installation).unwrap().name, "Widget");

    let renamed = library.rename("Widget", "Renamed").unwrap();
    assert_eq!(renamed.installation, created.installation);
    let copy = library.duplicate("Renamed").unwrap();
    assert_ne!(copy.installation, created.installation);

    // An exported archive carries no identity, and importing gives a new one.
    let mut archive = Vec::new();
    library.export_archive("Renamed", &mut archive).unwrap();
    assert!(support::entry_names(&archive).iter().all(|name| !name.contains(".scriptwidget-installation")));
    let imported = library.import_archive(&mut archive.as_slice(), None, None).unwrap();
    assert_ne!(imported.installation, created.installation);

    // A marker that is a link is never read through: the package gets a fresh identity instead.
    let other = scratch.new_file("other-identity", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    let marker = renamed.directory.join(sw_core::library::INSTALLATION_FILE);
    std::fs::remove_file(&marker).unwrap();
    support::symlink(&marker, &other);
    let relisted = library.find("Renamed").unwrap();
    assert_ne!(relisted.installation, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    assert_eq!(std::fs::read_to_string(&other).unwrap(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    assert_eq!(library.find("Renamed").unwrap().installation, relisted.installation, "and keeps it");
}

#[test]
fn writing_a_file_clears_the_build_cache() {
    let scratch = TemporaryFolder::new();
    let library = library(&scratch);
    let created = library.create("Widget", support::SOURCE, None).unwrap();
    let runtime = WidgetRuntime::new(scripts(), &DataPaths::new(Some(&scratch.path("data"))).unwrap()).unwrap();
    let mut request = RunRequest::new(Arc::new(created.files()), created.installation.clone());
    request.build_directory = Some(created.build_directory());
    assert!(runtime.run(&request).execution.tree.unwrap().contains("Hello"));
    let cached: Vec<_> = std::fs::read_dir(created.build_directory()).unwrap().map(|entry| entry.unwrap().file_name().into_string().unwrap()).collect();
    assert!(cached.len() == 1 && cached[0].starts_with("prepared-") && cached[0].ends_with(".json"), "{cached:?}");
    assert_eq!(created.files().paths(), ["main.jsx", "widget.json"], "the cache is not a package file");
    // The second run reads the artifact; the result is the same.
    assert!(runtime.run(&request).execution.tree.unwrap().contains("Hello"));

    library.write_file("Widget", "main.jsx", b"$render(<text>Changed</text>);").unwrap();
    assert!(!created.build_directory().exists());
    assert!(runtime.run(&request).execution.tree.unwrap().contains("Changed"));
}

#[test]
fn the_runtime_sets_the_environment_and_returns_compile_errors_as_results() {
    let scratch = TemporaryFolder::new();
    let runtime = WidgetRuntime::new(scripts(), &DataPaths::new(Some(&scratch.path("data"))).unwrap()).unwrap();
    let mut request = RunRequest::new(memory(&[("main.jsx", "$render(<text>{$getenv('widget-size')}|{$getenv('widget-param')}|{$getenv('widget-rendering-mode')}|{$getenv('extra')}|{String($device.isdarkmode())}</text>);")]), "test:env");
    request.family = "large".into();
    request.parameter = "p".into();
    request.dark_mode = true;
    request.extra_environments = vec![("extra".into(), "x".into())];
    let result = runtime.run(&request);
    assert_eq!(result.execution.error, None);
    assert!(result.execution.tree.as_deref().unwrap().contains(r#""children":["large","|","p","|","fullColor","|","x","|","true"]"#), "{:?}", result.execution.tree);
    assert!(result.depends_on_appearance, "the script asked for the theme");
    assert_eq!(result.next_timeline_transition, None);
    assert!(result.prepared.is_some() && result.remote_images.is_some());

    let broken = runtime.run(&RunRequest::new(memory(&[("main.jsx", "$render(<text>")]), "test:broken"));
    assert!(broken.prepared.is_none() && broken.execution.tree.is_none() && broken.remote_images.is_none());
    let error = broken.execution.error.expect("the compile error");
    assert!(error.message.contains("SyntaxError"), "{error:?}");
    assert!(runtime.validate_package(memory(&[("main.jsx", "$render(<text>")]).as_ref()).is_err());

    // The card for an error is a canonical tree with the category and the message, cut to a bounded length.
    let card: serde_json::Value = serde_json::from_str(&runtime.error_tree(Some(&sw_core::ExecutionError { kind: "resourceLimit".into(), message: "x".repeat(5000) }))).unwrap();
    assert_eq!(card["$element"], "vstack");
    assert!(card["children"][0]["children"][0].as_str().unwrap().ends_with(" error"));
    assert_eq!(card["children"][1]["children"][0].as_str().unwrap().len(), 400);
    assert!(serde_json::from_str::<serde_json::Value>(&runtime.error_tree(None)).is_ok());

    // An image on a private address is never fetched, and a tree without images costs nothing.
    let scope = result.remote_images.unwrap();
    let images = runtime.fetch_remote_images(r#"{"$element":"image","props":{"url":"http://127.0.0.1:9/a.png"},"children":[]}"#, &scope);
    assert!(images.is_empty());
    assert!(!scratch.path("data/Cache/remote-images").join("x").exists());
}

#[test]
fn a_source_folder_may_hold_dot_files_but_no_links_among_its_package_files() {
    let scratch = TemporaryFolder::new();
    let package = scratch.new_folder("Widget");
    scratch.new_file("Widget/main.jsx", support::SOURCE);
    scratch.new_file("Widget/.git/config", "x");
    scratch.new_file("outside.txt", "outside");
    let limits = ArchiveLimits::default();
    validate_source_tree(&package, &limits).unwrap();

    // What is not part of the authored package is not looked at, whatever it is.
    support::symlink(&package.join(".venv"), &scratch.root);
    support::symlink(&package.join("__Build"), &scratch.root);
    validate_source_tree(&package, &limits).unwrap();
    assert_code("unsafe_file", validate_tree(&package, &limits));
    assert_eq!(DiskPackageFiles::new(&package).paths(), ["main.jsx"]);

    // Among the package files a link, a hard link or a special file fails the folder.
    support::symlink(&package.join("data.txt"), &scratch.path("outside.txt"));
    assert_code("unsafe_file", validate_source_tree(&package, &limits));
    std::fs::remove_file(package.join("data.txt")).unwrap();
    support::hard_link(&package.join("hard.txt"), &scratch.path("outside.txt"));
    assert_code("unsafe_file", validate_source_tree(&package, &limits));
    std::fs::remove_file(package.join("hard.txt")).unwrap();
    support::make_fifo(&package.join("pipe"));
    assert_code("unsafe_file", validate_source_tree(&package, &limits));
    std::fs::remove_file(package.join("pipe")).unwrap();
    // Two spellings of one name, where the filesystem keeps both (the Mac's default one does not).
    if !package.join("MAIN.JSX").exists() {
        scratch.new_file("Widget/Main.JSX", "other");
        assert_code("unsafe_file", validate_source_tree(&package, &limits));
        std::fs::remove_file(package.join("Main.JSX")).unwrap();
    }
    validate_source_tree(&package, &limits).unwrap();
    // The folder itself must be a real directory.
    support::symlink(&scratch.path("Alias"), &package);
    assert_code("unsafe_file", validate_source_tree(&scratch.path("Alias"), &limits));
}
