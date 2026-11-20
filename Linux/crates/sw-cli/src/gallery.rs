//! `scriptwidget gallery`: the verified catalog of community widgets and
//! Skills. The command-line face of `sw_core::gallery`;
//! `Android/app/.../ui/GalleryScreen.kt` is what the commands follow.
//!
//! The catalog is the curated index on `raw.githubusercontent.com` and
//! nothing else: there is no option that names another address. Every file is
//! checked against the size and SHA-256 the index states before anything is
//! installed. That detects a corrupted or substituted download; it does not
//! review the code. An installed widget still runs only inside the engine,
//! with the permissions and hosts its manifest declares, and an installed
//! Skill is text that is not added to any request until it is enabled.

use std::sync::Arc;

use serde_json::{Value, json};
use sw_core::gallery::{FetchGalleryTransport, GalleryError, GalleryErrorKind, GalleryIndexCache, GalleryInstallState, GalleryInstallationRegistry, GalleryInstaller, GalleryItem, GalleryItemKind, GalleryRepository, GallerySnapshot, GalleryTransport};
use sw_core::json::ObjectExt;
use sw_core::library::{INSTALLATION_FILE, Library, unsupported_api};
use sw_core::skills::SkillStore;
use sw_core::{DataPaths, PackageFiles, Resources, SharedScripts, WidgetRuntime};

use crate::arguments::{Arguments, Shape};
use crate::commands::{resources, user_data};
use crate::report::{EXIT_FAILED, Failure, Report};

const HELP: &str = "\
Usage: scriptwidget gallery <command> [options]

  list [--kind <widget|skill>]
                        The catalog, and for each item whether it is installed or has an update.
  show <id>             One item: what it is, who wrote it, and the files it installs with their
                        sizes and SHA-256.
  install <id>          Download the item's files, check each against the size and SHA-256 in the
                        catalog, and install it: a widget into your widgets, a Skill into your
                        Skills (not enabled). An installed item is updated in place.

  --refresh             Fetch the catalog again now. Without it, a copy younger than 15 minutes is used.
  --data <dir>          The data folder (default: yours).

The catalog is https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json.
When GitHub cannot be reached, list and show use the last catalog that passed the checks and say so
(\"offline\": true); install still needs the connection. The checks detect a corrupted or
substituted download. They do not review the code: read what a widget may do before you install it.
";

impl From<GalleryError> for Failure {
    /// The network and a missing catalog are the machine's situation; everything else is the item's fault.
    fn from(error: GalleryError) -> Self {
        let (code, environment) = match error.kind {
            GalleryErrorKind::InvalidIndex => ("gallery.invalid_index", false),
            GalleryErrorKind::Network => ("gallery.network", true),
            GalleryErrorKind::MissingCache => ("gallery.no_catalog", true),
            GalleryErrorKind::InvalidDownload => ("gallery.invalid_download", false),
            GalleryErrorKind::Install => ("gallery.install_refused", false),
        };
        if environment { Failure::environment(code, error.message) } else { Failure::new(EXIT_FAILED, code, error.message) }
    }
}

pub fn wants_help(arguments: &[String]) -> bool {
    arguments.first().is_some_and(|word| matches!(word.as_str(), "--help" | "-h" | "help"))
}

pub fn help() -> &'static str {
    HELP
}

/// Runs a `gallery` command over the Internet. A failure that stopped it becomes its report, under the command's own name.
pub fn run(arguments: &[String]) -> Report {
    let name = match arguments.first().filter(|word| !word.starts_with('-')) {
        Some(word) => format!("gallery {word}"),
        None => "gallery".to_owned(),
    };
    dispatch(arguments, Arc::new(FetchGalleryTransport::new()), &resources).unwrap_or_else(|failure| Report::from_failure(&name, &failure))
}

/// `transport` is how the catalog and its files are fetched, and `resources`
/// where the runtime files are: the tests of this file give their own.
fn dispatch(arguments: &[String], transport: Arc<dyn GalleryTransport>, resources: &dyn Fn() -> Result<Resources, Failure>) -> Result<Report, Failure> {
    let Some(word) = arguments.first().map(String::as_str) else { return Err(Failure::usage("Missing a gallery command. scriptwidget gallery --help lists them.")) };
    let rest = &arguments[1..];
    match word {
        "list" => list(rest, transport),
        "show" => show(rest, transport),
        "install" => install(rest, transport, resources),
        _ => Err(Failure::usage(format!("Unknown gallery command {word}. scriptwidget gallery --help lists them."))),
    }
}

/// The Gallery over one data folder: the stores an install writes to and the record of what was installed.
struct Session {
    paths: DataPaths,
    transport: Arc<dyn GalleryTransport>,
    library: Library,
    skills: SkillStore,
    registry: GalleryInstallationRegistry,
}

impl Session {
    fn open(arguments: &Arguments, transport: Arc<dyn GalleryTransport>) -> Result<Self, Failure> {
        let paths = user_data(arguments)?;
        Ok(Self { library: Library::new(&paths, None), skills: SkillStore::new(paths.skills()), registry: GalleryInstallationRegistry::new(paths.gallery_installations()), transport, paths })
    }

    fn catalog(&self, arguments: &Arguments, report: &mut Report) -> Result<GallerySnapshot, Failure> {
        let snapshot = GalleryRepository::new(self.transport.clone(), GalleryIndexCache::new(self.paths.gallery_cache())).load(arguments.flag("refresh"))?;
        report.set("catalog", json!({ "url": GalleryRepository::DEFAULT_INDEX_URL, "offline": snapshot.is_offline, "offlineReason": snapshot.offline_reason, "fetchedAt": snapshot.fetched_at, "generatedAt": snapshot.index.generated_at, "items": snapshot.index.items.len() }));
        if snapshot.is_offline {
            report.diagnostic("warning", "gallery.offline", &format!("GitHub could not be reached ({}). This is the last catalog that passed the checks.", snapshot.offline_reason.as_deref().unwrap_or("no reason given")));
        }
        Ok(snapshot)
    }

    fn installer(&self) -> GalleryInstaller<'_> {
        GalleryInstaller::new(self.transport.as_ref(), &self.registry, self.library.store(), &self.skills, self.paths.gallery_downloads()).carried_files(&[INSTALLATION_FILE])
    }

    fn find<'a>(&self, snapshot: &'a GallerySnapshot, id: &str) -> Result<&'a GalleryItem, Failure> {
        snapshot.index.items.iter().find(|item| item.id == id).ok_or_else(|| Failure::usage(format!("The Gallery has no item with the id {id}. scriptwidget gallery list shows them.")))
    }
}

fn state_json(state: &GalleryInstallState) -> Value {
    match state {
        GalleryInstallState::NotInstalled => json!({ "state": "notInstalled" }),
        GalleryInstallState::Installed => json!({ "state": "installed" }),
        GalleryInstallState::UpdateAvailable { current } => json!({ "state": "updateAvailable", "installedVersion": current }),
    }
}

/// An item as a report shows it; its files are listed only where they were asked for.
fn describe(item: &GalleryItem, state: &GalleryInstallState, with_files: bool) -> Value {
    let mut value = json!({
        "id": item.id,
        "kind": item.kind.wire(),
        "name": item.name,
        "version": item.version,
        "summary": item.summary,
        "author": item.author,
        "license": item.license,
        "tags": item.tags,
        "featured": item.featured,
        "sourceUrl": item.source_url,
        "files": item.files.len(),
        "bytes": item.total_bytes(),
        "install": state_json(state),
    });
    if with_files {
        value["files"] = item.files.iter().map(|file| json!({ "path": file.path, "url": file.url, "sha256": file.sha256, "bytes": file.bytes })).collect();
    }
    value
}

const VALUES: &[&str] = &["data"];
const FLAGS: &[&str] = &["refresh"];

fn list(arguments: &[String], transport: Arc<dyn GalleryTransport>) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["data", "kind"], flags: FLAGS, minimum_positionals: 0, maximum_positionals: 0, positionals: "" })?;
    let kind = arguments.value("kind").map(|text| GalleryItemKind::from_wire(text).ok_or_else(|| Failure::usage(format!("Unknown kind {text}: use widget or skill")))).transpose()?;
    let session = Session::open(&arguments, transport)?;
    let mut report = Report::new("gallery list");
    let snapshot = session.catalog(&arguments, &mut report)?;
    let installer = session.installer();
    report.set("items", snapshot.index.items.iter().filter(|item| kind.is_none_or(|kind| item.kind == kind)).map(|item| describe(item, &installer.state(item), false)).collect());
    Ok(report)
}

fn show(arguments: &[String], transport: Arc<dyn GalleryTransport>) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: VALUES, flags: FLAGS, minimum_positionals: 1, maximum_positionals: 1, positionals: "the id of a Gallery item" })?;
    let session = Session::open(&arguments, transport)?;
    let mut report = Report::new("gallery show");
    let snapshot = session.catalog(&arguments, &mut report)?;
    let item = session.find(&snapshot, arguments.positional(0).unwrap_or_default())?;
    report.set("item", describe(item, &session.installer().state(item), true));
    Ok(report)
}

fn install(arguments: &[String], transport: Arc<dyn GalleryTransport>, resources: &dyn Fn() -> Result<Resources, Failure>) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: VALUES, flags: FLAGS, minimum_positionals: 1, maximum_positionals: 1, positionals: "the id of a Gallery item" })?;
    let session = Session::open(&arguments, transport)?;
    let mut report = Report::new("gallery install");
    let snapshot = session.catalog(&arguments, &mut report)?;
    let item = session.find(&snapshot, arguments.positional(0).unwrap_or_default())?;

    // The engine that compiles a widget before it is published, and the API version it implements.
    // A Skill is text: it is checked without the runtime files, so they are not asked for.
    let engine = match item.kind {
        GalleryItemKind::Widget => {
            let resources = resources()?;
            let scripts = SharedScripts::new(&resources.runtime).map(Arc::new).map_err(|error| Failure::environment("tool.resources_missing", error.to_string()))?;
            let runtime = WidgetRuntime::new(scripts.clone(), &session.paths).map_err(|error| Failure::internal(format!("The runtime could not be started: {error}")))?;
            Some((runtime, scripts.contract().opt_string_or_none("apiVersion")))
        }
        GalleryItemKind::Skill => None,
    };
    let compile = |files: &dyn PackageFiles| engine.as_ref().map_or(Ok(()), |(runtime, _)| runtime.validate_package(files).map_err(|error| error.message));
    let installer = match &engine {
        Some((_, api_version)) => session.installer().runtime_api_version(api_version.as_deref()).widget_validator(&compile),
        None => session.installer(),
    };

    let before = installer.state(item);
    let record = match installer.install(item) {
        Ok(record) => record,
        Err(error) => {
            // What the catalog said stays in the report; nothing was installed or changed.
            report.set("item", describe(item, &before, false));
            report.set("installed", json!(false));
            report.absorb(&error.into());
            return Ok(report);
        }
    };
    report.set("item", describe(item, &installer.state(item), false));
    report.set("installed", json!(true));
    report.set("updated", json!(matches!(before, GalleryInstallState::UpdateAvailable { .. })));
    match item.kind {
        GalleryItemKind::Widget => {
            let installed = session.library.find(&record.local_identifier).ok_or_else(|| Failure::internal("The installed widget was not found."))?;
            let hosts: Vec<String> = installed.manifest.as_ref().and_then(|manifest| manifest.opt_array("networkDomains")).map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_owned)).collect()).unwrap_or_default();
            report.set("widget", json!({ "name": installed.name, "title": installed.display_name(), "installation": installed.installation, "directory": installed.directory.display().to_string(), "permissions": installed.permissions(), "networkDomains": hosts }));
            // A widget of the catalog may be written for an API only another platform has.
            let files = installed.files();
            let scripts = files.list().unwrap_or_default().into_iter().filter(|path| path.ends_with(".js") || path.ends_with(".jsx"));
            if let Some(api) = scripts.filter_map(|path| files.read_text(&path)).find_map(|source| unsupported_api(&source)) {
                report.diagnostic("warning", "gallery.unsupported_api", &format!("{} uses {api}, which ScriptWidget for Linux does not implement: it will show that instead of its content.", item.name));
            }
        }
        GalleryItemKind::Skill => {
            let enabled = session.skills.is_enabled(&item.id);
            report.set("skill", session.skills.find(&item.id).map_or(Value::Null, |skill| crate::skills::describe(&skill, enabled, false)));
            if !enabled {
                report.diagnostic("info", "gallery.skill_not_enabled", &format!("{} is installed but not enabled. Enable it with: scriptwidget skills enable {}", item.name, item.id));
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    //! The commands over a stand-in for GitHub that answers from the catalog checked into this
    //! repository. The binary's own tests (`tests/cli.rs`) can only reach `list` and `show`, from
    //! a cache put there beforehand: the program has no way to name another server, by design.

    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU32, Ordering};

    use sw_core::gallery::{GalleryRequest, GalleryResponse};

    use super::*;
    use crate::report::EXIT_USAGE;

    const HELLO: &str = "app.scriptwidget.gallery.hello-card";
    const PRIVACY: &str = "app.scriptwidget.gallery.privacy-review";

    fn repository() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
    }

    /// Serves `Gallery/` of this repository under the trusted address; `tampered` replaces the body of one URL.
    #[derive(Default)]
    struct Checkout {
        tampered: Mutex<HashMap<String, Vec<u8>>>,
        down: Mutex<bool>,
        requests: Mutex<Vec<String>>,
    }

    impl GalleryTransport for Checkout {
        fn fetch(&self, request: &GalleryRequest) -> Result<GalleryResponse, GalleryError> {
            self.requests.lock().unwrap().push(request.url.clone());
            if *self.down.lock().unwrap() {
                return Err(GalleryError::network("GitHub could not be reached."));
            }
            if let Some(body) = self.tampered.lock().unwrap().get(&request.url) {
                return Ok(GalleryResponse::new(200, body.clone(), &[], &request.url));
            }
            let relative = request.url.strip_prefix("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/").ok_or_else(|| GalleryError::network("not the catalog"))?;
            match std::fs::read(repository().join("Gallery").join(relative)) {
                Ok(body) => Ok(GalleryResponse::new(200, body, &[("ETag", "\"checkout\"")], &request.url)),
                Err(_) => Ok(GalleryResponse::new(404, b"Not Found".to_vec(), &[], &request.url)),
            }
        }
    }

    struct Sandbox {
        root: PathBuf,
        github: Arc<Checkout>,
    }

    impl Sandbox {
        fn new() -> Self {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let root = std::env::temp_dir().join(format!("scriptwidget-cli-gallery-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&root).unwrap();
            Self { root: std::fs::canonicalize(root).unwrap(), github: Arc::default() }
        }

        fn data(&self) -> PathBuf {
            self.root.join("data")
        }

        fn run(&self, arguments: &[&str]) -> Result<Report, Failure> {
            let mut arguments: Vec<String> = arguments.iter().map(|argument| argument.to_string()).collect();
            arguments.extend(["--data".to_owned(), self.data().display().to_string()]);
            let resources = || Ok(Resources { runtime: repository().join("Linux/assets/scriptwidget"), templates: None });
            dispatch(&arguments, self.github.clone(), &resources)
        }

        /// A command on a machine where the runtime files are not installed.
        fn run_without_runtime(&self, arguments: &[&str]) -> Result<Report, Failure> {
            let mut arguments: Vec<String> = arguments.iter().map(|argument| argument.to_string()).collect();
            arguments.extend(["--data".to_owned(), self.data().display().to_string()]);
            dispatch(&arguments, self.github.clone(), &|| Err(Failure::environment("tool.resources_missing", "The runtime files were not found.")))
        }

        /// The report of a command as the program would print it.
        #[track_caller]
        fn report(&self, arguments: &[&str]) -> Value {
            self.run(arguments).unwrap_or_else(|failure| panic!("{}: {}", failure.code, failure.message)).into_value()
        }

        /// Everything below the data folder that is not the catalog cache.
        fn written(&self) -> Vec<String> {
            fn walk(folder: &Path, root: &Path, found: &mut Vec<String>) {
                for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        walk(&path, root, found);
                    } else {
                        found.push(path.strip_prefix(root).unwrap().display().to_string());
                    }
                }
            }
            let mut found = Vec::new();
            walk(&self.data(), &self.data(), &mut found);
            found.retain(|path| !path.starts_with("Cache/Gallery/"));
            found.sort();
            found
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn codes(report: &Value) -> Vec<&str> {
        report["diagnostics"].as_array().unwrap().iter().filter_map(|item| item["code"].as_str()).collect()
    }

    fn item<'a>(report: &'a Value, id: &str) -> &'a Value {
        report["items"].as_array().unwrap().iter().find(|item| item["id"] == id).unwrap_or_else(|| panic!("{id} is not listed"))
    }

    #[test]
    fn lists_the_catalog_and_falls_back_to_the_verified_copy_when_github_is_down() {
        let sandbox = Sandbox::new();
        let listed = sandbox.report(&["list"]);
        assert_eq!((listed["command"].as_str(), listed["ok"].as_bool()), (Some("gallery list"), Some(true)));
        assert_eq!(listed["catalog"]["offline"], false);
        assert_eq!(listed["catalog"]["url"], GalleryRepository::DEFAULT_INDEX_URL);
        assert_eq!(item(&listed, HELLO)["install"]["state"], "notInstalled");
        assert_eq!((item(&listed, HELLO)["kind"].as_str(), item(&listed, PRIVACY)["kind"].as_str()), (Some("widget"), Some("skill")));
        let skills = sandbox.report(&["list", "--kind", "skill"]);
        assert!(skills["items"].as_array().unwrap().iter().all(|item| item["kind"] == "skill") && !skills["items"].as_array().unwrap().is_empty());
        assert_eq!(sandbox.github.requests.lock().unwrap().len(), 1, "the second list used the copy on disk");

        *sandbox.github.down.lock().unwrap() = true;
        let offline = sandbox.report(&["list", "--refresh"]);
        assert_eq!((offline["ok"].as_bool(), offline["catalog"]["offline"].as_bool()), (Some(true), Some(true)));
        assert_eq!(codes(&offline), ["gallery.offline"]);
        assert_eq!(offline["items"], listed["items"]);
        // Installing still needs the connection, and leaves nothing behind without it.
        let refused = sandbox.report(&["install", HELLO]);
        assert_eq!((refused["ok"].as_bool(), refused["installed"].as_bool(), refused["error"]["kind"].as_str()), (Some(false), Some(false), Some("gallery.network")));
        assert_eq!(sandbox.written(), [] as [&str; 0]);
    }

    #[test]
    fn without_a_catalog_a_command_says_that_github_was_not_reached() {
        let sandbox = Sandbox::new();
        *sandbox.github.down.lock().unwrap() = true;
        let failure = sandbox.run(&["list"]).err().expect("no catalog");
        assert_eq!((failure.exit, failure.code.as_str()), (EXIT_USAGE, "gallery.network"));
    }

    #[test]
    fn show_lists_the_files_with_their_hashes() {
        let sandbox = Sandbox::new();
        let shown = sandbox.report(&["show", HELLO]);
        let files = shown["item"]["files"].as_array().unwrap();
        assert_eq!(files.iter().map(|file| file["path"].as_str().unwrap()).collect::<Vec<_>>(), ["main.jsx", "widget.json"]);
        assert!(files.iter().all(|file| file["sha256"].as_str().unwrap().len() == 64 && file["url"].as_str().unwrap().starts_with("https://raw.githubusercontent.com/")));
        let unknown = sandbox.run(&["show", "com.example.missing"]).err().expect("an unknown id");
        assert_eq!((unknown.exit, unknown.code.as_str()), (EXIT_USAGE, "usage"));
        for arguments in [&["show"][..], &["install"], &["list", "--kind", "plugin"], &["list", "--index", "https://example.com/index.json"], &["publish"], &[]] {
            assert_eq!(sandbox.run(arguments).err().expect("a usage error").exit, EXIT_USAGE, "{arguments:?}");
        }
    }

    #[test]
    fn installs_a_widget_after_checking_every_file_and_updates_nothing_on_a_second_run() {
        let sandbox = Sandbox::new();
        let installed = sandbox.report(&["install", HELLO]);
        assert_eq!((installed["ok"].as_bool(), installed["installed"].as_bool(), installed["updated"].as_bool()), (Some(true), Some(true), Some(false)));
        assert_eq!(installed["item"]["install"]["state"], "installed");
        assert_eq!(installed["widget"]["name"], "Gallery Hello Card");
        assert_eq!(installed["widget"]["networkDomains"], json!([]));
        let directory = sandbox.data().join("Packages/Gallery Hello Card");
        for file in ["main.jsx", "widget.json"] {
            assert_eq!(std::fs::read(directory.join(file)).unwrap(), std::fs::read(repository().join("Gallery/widgets/hello-card").join(file)).unwrap(), "{file}");
        }
        assert_eq!(item(&sandbox.report(&["list"]), HELLO)["install"]["state"], "installed");
        // Nothing of the download stays, and the record is in the data folder.
        assert!(sandbox.written().contains(&"gallery-installations.json".to_owned()));
        assert!(sandbox.written().iter().all(|path| !path.starts_with("Cache/GalleryDownloads/") && !path.starts_with("Staging/")), "{:?}", sandbox.written());

        // Installed again, it is the same widget under the same name, with the same identity.
        let identity = installed["widget"]["installation"].clone();
        let again = sandbox.report(&["install", HELLO]);
        assert_eq!((again["widget"]["name"].as_str(), &again["widget"]["installation"]), (Some("Gallery Hello Card"), &identity));
        assert_eq!(std::fs::read_dir(sandbox.data().join("Packages")).unwrap().count(), 1);
    }

    #[test]
    fn a_file_that_does_not_match_the_catalog_installs_nothing() {
        let sandbox = Sandbox::new();
        let url = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/widgets/hello-card/main.jsx";
        let original = std::fs::read(repository().join("Gallery/widgets/hello-card/main.jsx")).unwrap();
        // The same number of bytes, other content: only the hash tells.
        let mut substituted = original.clone();
        substituted[0] ^= 1;
        for body in [substituted, [original.as_slice(), b"\n$render(<text>more</text>);"].concat(), b"short".to_vec()] {
            sandbox.github.tampered.lock().unwrap().insert(url.to_owned(), body);
            let refused = sandbox.report(&["install", HELLO]);
            assert_eq!((refused["ok"].as_bool(), refused["installed"].as_bool(), refused["error"]["kind"].as_str()), (Some(false), Some(false), Some("gallery.invalid_download")));
            assert!(refused["error"]["message"].as_str().unwrap().contains("main.jsx"));
            assert_eq!(refused["item"]["install"]["state"], "notInstalled");
            assert_eq!(sandbox.written(), [] as [&str; 0]);
        }
        // A catalog that is not the catalog is refused whole.
        let other = Sandbox::new();
        other.github.tampered.lock().unwrap().insert(GalleryRepository::DEFAULT_INDEX_URL.to_owned(), b"{\"schemaVersion\":2,\"generatedAt\":\"2026-11-12T17:07:53.501Z\",\"repository\":\"https://github.com/a/b\",\"items\":[]}".to_vec());
        let failure = other.run(&["list"]).err().expect("an unsupported catalog");
        assert_eq!((failure.exit, failure.code.as_str()), (EXIT_FAILED, "gallery.invalid_index"));
        assert_eq!(other.written(), [] as [&str; 0]);
    }

    #[test]
    fn a_widget_for_an_api_linux_lacks_is_installed_with_a_warning() {
        let sandbox = Sandbox::new();
        // In the entry script, and in a script the entry imports.
        for id in ["app.scriptwidget.template.health-overview", "app.scriptwidget.template.health-card"] {
            let installed = sandbox.report(&["install", id]);
            assert_eq!(installed["installed"], true, "{installed}");
            assert_eq!(codes(&installed), ["gallery.unsupported_api"], "{id}");
            assert!(installed["diagnostics"][0]["message"].as_str().unwrap().contains("$health"));
        }
        assert_eq!(codes(&sandbox.report(&["install", "app.scriptwidget.template.countdown"])), [] as [&str; 0]);
    }

    #[test]
    fn installs_a_skill_that_stays_off_until_it_is_enabled() {
        let sandbox = Sandbox::new();
        let installed = sandbox.report(&["install", PRIVACY]);
        assert_eq!((installed["ok"].as_bool(), installed["installed"].as_bool()), (Some(true), Some(true)));
        assert_eq!((installed["skill"]["id"].as_str(), installed["skill"]["enabled"].as_bool(), installed["skill"]["builtIn"].as_bool()), (Some(PRIVACY), Some(false), Some(false)));
        assert_eq!(codes(&installed), ["gallery.skill_not_enabled"]);
        let skills = SkillStore::new(sandbox.data().join("Skills"));
        assert!(skills.is_installed(PRIVACY));
        assert_eq!(skills.enabled_skills_prompt_text(), "", "an installed Skill adds nothing to a request");
        assert_eq!(std::fs::read_dir(sandbox.data().join("Packages")).map_or(0, Iterator::count), 0);
        assert_eq!(item(&sandbox.report(&["list"]), PRIVACY)["install"]["state"], "installed");
    }

    #[test]
    fn a_skill_is_installed_without_the_runtime_files_and_a_widget_is_not() {
        let sandbox = Sandbox::new();
        let installed = sandbox.run_without_runtime(&["install", PRIVACY]).unwrap_or_else(|failure| panic!("{}: {}", failure.code, failure.message)).into_value();
        assert_eq!((installed["ok"].as_bool(), installed["installed"].as_bool(), installed["skill"]["id"].as_str()), (Some(true), Some(true), Some(PRIVACY)));
        assert!(SkillStore::new(sandbox.data().join("Skills")).is_installed(PRIVACY));
        // A widget is compiled before it is published: without the runtime nothing is installed.
        let refused = sandbox.run_without_runtime(&["install", HELLO]).err().expect("a widget needs the runtime");
        assert_eq!(refused.code, "tool.resources_missing");
        assert_eq!(std::fs::read_dir(sandbox.data().join("Packages")).map_or(0, Iterator::count), 0);
        // Listing and showing never needed it.
        assert_eq!(item(&sandbox.run_without_runtime(&["list"]).ok().unwrap().into_value(), PRIVACY)["install"]["state"], "installed");
    }
}
