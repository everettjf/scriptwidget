//! The facade that compiles and executes one package with the native APIs of
//! this host. Ported from `Windows/src/ScriptWidget.Core/WidgetRuntime.cs`.
//!
//! The Windows class also paints. Here the painter (`sw-render`) depends on
//! this crate, not the other way round, so that `sw-core` builds without
//! Skia: `sw_render::widget::render_run` takes the result of [`WidgetRuntime::run`]
//! and does the last step. Everything that decides what a package may do is
//! here: the modules, the environment, the network policy for remote images.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::api::fetch::{self, FetchModule, Url};
use crate::api::policy::{self, NetworkDeclaration};
use crate::api::system::{self, Screen};
use crate::api::weather::FetchWeatherTransport;
use crate::api::documents::DocumentsModule;
use crate::api::music::{MprisPlatform, MusicModule};
use crate::api::notifications::NotificationsModule;
use crate::api::photos::PhotosModule;
use crate::api::services::ServicesModule;
use crate::api::{StorageModule, SystemStores, WeatherModule};
use crate::compiler::{PackageCompiler, PrepareOptions, PreparedPackage, RuntimeError, is_text_file};
use crate::data_paths::DataPaths;
use crate::executor::{ExecutionError, ExecutionRequest, ExecutionResult, ExecutionSession, NativeModule, ScriptExecutor};
use crate::json::{ObjectExt, parse_object, quote, stringify};
use crate::package_files::PackageFiles;
use crate::plugins::{DataSourceModule, PluginStore};
use crate::shared_scripts::SharedScripts;
use crate::timeline::TimelinePlanner;

/// Everything needed to run one package once.
#[derive(Clone)]
pub struct RunRequest {
    pub files: Arc<dyn PackageFiles>,
    /// Stable identity of the installed package; namespaces storage and caches.
    pub package_id: String,
    /// "small", "medium", "large" or "extraLarge".
    pub family: String,
    /// `$getenv("widget-param")`.
    pub parameter: String,
    pub dark_mode: bool,
    /// Declared action to run (`actions[].id`), or `None` to render.
    pub action_id: Option<String>,
    /// Legacy `onClick="name"` function to call after the entry.
    pub call_function: Option<String>,
    /// Further `$getenv` values; they win over the ones the runtime sets.
    pub extra_environments: Vec<(String, String)>,
    /// Directory for the compiled-artifact cache; `None` disables caching.
    pub build_directory: Option<PathBuf>,
    /// The display `$device` reports.
    pub screen: Screen,
}

impl RunRequest {
    pub fn new(files: Arc<dyn PackageFiles>, package_id: impl Into<String>) -> Self {
        Self {
            files,
            package_id: package_id.into(),
            family: "medium".into(),
            parameter: String::new(),
            dark_mode: false,
            action_id: None,
            call_function: None,
            extra_environments: Vec::new(),
            build_directory: None,
            screen: Screen::default(),
        }
    }
}

/// What a finished execution may still fetch for its picture: the `<image url>` sources, under the package's own network declaration.
#[derive(Debug, Clone)]
pub struct RemoteImageScope {
    package_id: String,
    declaration: NetworkDeclaration,
    session: Arc<ExecutionSession>,
    /// False for a future timeline entry and a Live Activity, which make no live requests.
    live: bool,
}

pub struct RunResult {
    pub execution: ExecutionResult,
    /// `None` when the package did not compile.
    pub prepared: Option<PreparedPackage>,
    /// When the package's daily schedule next changes slot, in epoch milliseconds; the host runs the package again then.
    pub next_timeline_transition: Option<i64>,
    /// True when the script's output may depend on the light or dark theme it ran under.
    pub depends_on_appearance: bool,
    /// `None` when nothing was executed.
    pub remote_images: Option<RemoteImageScope>,
}

const MAXIMUM_CACHED_ARTIFACTS: usize = 6;
const MAXIMUM_REMOTE_IMAGES: usize = 8;
const IMAGE_BUDGET: Duration = Duration::from_millis(6000);
const IMAGE_CACHE: Duration = Duration::from_secs(15 * 60);
const IMAGE_TIMEOUT_MILLISECONDS: u64 = 4000;
const MAXIMUM_ERROR_CHARACTERS: usize = 400;

/// The Linux runtime without the painter. One instance per process; every
/// method may be called from any thread.
pub struct WidgetRuntime {
    scripts: Arc<SharedScripts>,
    compiler: PackageCompiler,
    executor: ScriptExecutor,
    timeline: TimelinePlanner,
    storage: Arc<StorageModule>,
    fetch: Arc<FetchModule>,
    plugins: Arc<PluginStore>,
    system: SystemStores,
    modules: Vec<Arc<dyn NativeModule>>,
    image_cache: PathBuf,
}

impl WidgetRuntime {
    /// `scripts` are the generated JavaScript assets (see [`crate::resources`]);
    /// `paths` is where storage, plugins and caches of this instance live.
    pub fn new(scripts: Arc<SharedScripts>, paths: &DataPaths) -> io::Result<Self> {
        Self::with_modules(scripts, paths, Vec::new())
    }

    /// [`WidgetRuntime::new`] with further native modules after the built-in ones.
    pub fn with_modules(scripts: Arc<SharedScripts>, paths: &DataPaths, extra_modules: Vec<Arc<dyn NativeModule>>) -> io::Result<Self> {
        let storage = Arc::new(StorageModule::new(paths.storage()));
        let fetch = Arc::new(FetchModule::new());
        let plugins = Arc::new(PluginStore::new(paths.plugins()));
        let weather = WeatherModule::new(Arc::new(FetchWeatherTransport::new(fetch.clone())), paths.cache().join("weather"), WeatherModule::user_agent(env!("CARGO_PKG_VERSION")));
        Self::with_system(scripts, paths, SystemStores::for_runs(paths, fetch.clone()), storage, fetch, plugins, weather, extra_modules)
    }

    /// [`WidgetRuntime::new`] over other stores for the data APIs: another keyring, another `busctl`. For tests.
    pub fn with_stores(scripts: Arc<SharedScripts>, paths: &DataPaths, system: SystemStores) -> io::Result<Self> {
        let storage = Arc::new(StorageModule::new(paths.storage()));
        let fetch = Arc::new(FetchModule::new());
        let plugins = Arc::new(PluginStore::new(paths.plugins()));
        let weather = WeatherModule::new(Arc::new(FetchWeatherTransport::new(fetch.clone())), paths.cache().join("weather"), WeatherModule::user_agent(env!("CARGO_PKG_VERSION")));
        Self::with_system(scripts, paths, system, storage, fetch, plugins, weather, Vec::new())
    }

    #[allow(clippy::too_many_arguments)]
    fn with_system(scripts: Arc<SharedScripts>, paths: &DataPaths, system: SystemStores, storage: Arc<StorageModule>, fetch: Arc<FetchModule>, plugins: Arc<PluginStore>, weather: WeatherModule, extra_modules: Vec<Arc<dyn NativeModule>>) -> io::Result<Self> {
        let mut modules: Vec<Arc<dyn NativeModule>> = vec![
            storage.clone(),
            fetch.clone(),
            Arc::new(DataSourceModule::new(plugins.clone())),
            Arc::new(weather),
            Arc::new(MusicModule::new(Arc::new(MprisPlatform::new(system.bus.clone())))),
            Arc::new(NotificationsModule::new(system.notification_platform.clone(), system.notifications.clone(), system.grants.clone())),
            Arc::new(ServicesModule::new(system.services.clone())),
            Arc::new(DocumentsModule::new(system.documents.clone())),
            Arc::new(PhotosModule::new(system.photos.clone())),
        ];
        modules.extend(extra_modules);
        Ok(Self {
            compiler: PackageCompiler::new(scripts.clone())?,
            executor: ScriptExecutor::new(scripts.clone()),
            timeline: TimelinePlanner::new(scripts.clone()),
            scripts,
            storage,
            fetch,
            plugins,
            system,
            modules,
            image_cache: paths.cache().join("remote-images"),
        })
    }

    pub fn scripts(&self) -> &Arc<SharedScripts> {
        &self.scripts
    }

    pub fn compiler(&self) -> &PackageCompiler {
        &self.compiler
    }

    pub fn timeline(&self) -> &TimelinePlanner {
        &self.timeline
    }

    pub fn storage(&self) -> &StorageModule {
        &self.storage
    }

    pub fn plugins(&self) -> &PluginStore {
        &self.plugins
    }

    /// What the data APIs keep between runs: grants, picked files, pending notifications, the connected service.
    pub fn system(&self) -> &SystemStores {
        &self.system
    }

    /// Compiles a package, reusing the cached artifact when no source changed.
    pub fn prepare(&self, request: &RunRequest) -> Result<PreparedPackage, RuntimeError> {
        let cache_file = request.build_directory.as_ref().map(|directory| directory.join(format!("prepared-{}.json", self.cache_key(request))));
        if let Some(cached) = cache_file.as_deref().and_then(read_artifact) {
            return Ok(cached);
        }
        let options = PrepareOptions { action_id: request.action_id.as_deref(), call_function: request.call_function.as_deref(), ..Default::default() };
        let prepared = self.compiler.prepare(request.files.as_ref(), &options)?;
        if let (Some(file), Some(directory)) = (&cache_file, &request.build_directory) {
            // The cache is an optimization: a failure to write it changes nothing.
            let _ = write_artifact(directory, file, &prepared);
        }
        Ok(prepared)
    }

    fn cache_key(&self, request: &RunRequest) -> String {
        let mut digest = Sha256::new();
        digest.update(self.scripts.contract().opt_string("compilerFingerprint").as_bytes());
        let mut add = |text: &str| {
            digest.update(text.as_bytes());
            digest.update([0u8]);
        };
        add(request.action_id.as_deref().unwrap_or(""));
        add(request.call_function.as_deref().unwrap_or(""));
        for path in request.files.paths() {
            add(&path);
            add(&if is_text_file(&path) { request.files.read_text(&path).unwrap_or_default() } else { String::new() });
        }
        hex(&digest.finalize())[..32].to_owned()
    }

    /// Compiles the package the way an installation would; the error says why it is invalid.
    pub fn validate_package(&self, files: &dyn PackageFiles) -> Result<(), RuntimeError> {
        self.compiler.prepare(files, &PrepareOptions::default()).map(|_| ())
    }

    /// Compiles and executes. A compile failure is returned as an execution error.
    pub fn run(&self, request: &RunRequest) -> RunResult {
        let prepared = match self.prepare(request) {
            Ok(prepared) => prepared,
            Err(error) => {
                let execution = ExecutionResult { error: Some(ExecutionError { kind: error.kind, message: error.message }), ..Default::default() };
                return RunResult { execution, prepared: None, next_timeline_transition: None, depends_on_appearance: false, remote_images: None };
            }
        };
        let mut environments = vec![
            ("widget-size".to_owned(), request.family.clone()),
            ("widget-param".to_owned(), request.parameter.clone()),
            // Linux draws every widget in full color, as Windows does.
            ("widget-rendering-mode".to_owned(), "fullColor".to_owned()),
        ];
        // The cached artifact carries the slot of the moment it was compiled; use the slot of now.
        let schedule = self.timeline.state(prepared.manifest.as_ref());
        if let Some(schedule) = &schedule {
            environments.extend(schedule.environments.iter().cloned());
        }
        environments.extend(request.extra_environments.iter().cloned());

        let session = Arc::new(ExecutionSession::default());
        let mut execution = ExecutionRequest::new(&prepared, request.files.as_ref());
        execution.environments = environments;
        execution.dark_mode = request.dark_mode;
        execution.device = Some(system::device_info(request.screen));
        execution.system = Some(system::system_info());
        execution.modules = self.modules.clone();
        execution.package_id = request.package_id.clone();
        execution.session = session.clone();
        let scope = RemoteImageScope {
            package_id: request.package_id.clone(),
            declaration: NetworkDeclaration::of(&execution),
            live: !policy::is_timeline_projection(&execution) && !policy::is_live_activity(&execution),
            session: session.clone(),
        };
        let result = self.executor.execute(&execution);
        RunResult {
            execution: result,
            next_timeline_transition: schedule.and_then(|schedule| schedule.next_transition_milliseconds),
            depends_on_appearance: session.read_appearance(),
            remote_images: Some(scope),
            prepared: Some(prepared),
        }
    }

    /// A canonical tree that explains `error` with its category and recovery hint.
    pub fn error_tree(&self, error: Option<&ExecutionError>) -> String {
        let kind = error.map_or("internalError", |error| error.kind.as_str());
        let categories = self.scripts.error_categories();
        let category = categories.opt_object(kind).or_else(|| categories.opt_object("internalError"));
        let title = category.and_then(|category| category.opt_string_or_none("category")).unwrap_or_else(|| "Internal".into());
        let recovery = category.map(|category| category.opt_string("recovery")).unwrap_or_default();
        let message: String = error.map_or("Unknown error", |error| error.message.as_str()).chars().take(MAXIMUM_ERROR_CHARACTERS).collect();
        // Fixed colors: the card keeps its light background in dark mode.
        message_tree(&[
            (&format!("{title} error"), r##"{"color":"#b91c1c","font":"caption","fontWeight":"bold"}"##),
            (&message, r##"{"color":"#1f2937","font":"caption"}"##),
            (&recovery, r##"{"color":"#6b7280","font":"caption2"}"##),
        ])
    }

    /// A card with a title and a line of explanation, for widgets that have nothing to run.
    pub fn notice_tree(title: &str, detail: &str) -> String {
        message_tree(&[(title, r##"{"color":"#1f2937","font":"caption","fontWeight":"bold"}"##), (detail, r##"{"color":"#6b7280","font":"caption2"}"##)])
    }

    /// Downloads the http(s) `<image url>` sources a tree references, bounded
    /// in count, size and time, under the same network policy as `fetch`:
    /// public hosts only, and for a Package 2.0 widget only the hosts it
    /// declares. Returns the files by URL; an image that could not be fetched
    /// is left out and drawn as a placeholder.
    pub fn fetch_remote_images(&self, tree: &str, scope: &RemoteImageScope) -> HashMap<String, PathBuf> {
        let mut result = HashMap::new();
        if !scope.live {
            return result;
        }
        // A tree nested deeper than serde_json reads by default gets no remote images.
        let Ok(parsed) = serde_json::from_str::<Value>(tree) else { return result };
        let mut urls = Vec::new();
        collect_image_urls(&parsed, &mut urls);
        if urls.is_empty() || create_private(&self.image_cache).is_err() {
            return result;
        }
        let deadline = Instant::now() + IMAGE_BUDGET;
        for text in urls.into_iter().take(MAXIMUM_REMOTE_IMAGES) {
            let Ok(url) = Url::parse(&text) else { continue };
            let allowed = |target: &Url| fetch::validation_error(target).is_none() && target.host_str().is_some_and(|host| scope.declaration.allows_host(fetch::unbracket(host)));
            if !allowed(&url) {
                continue;
            }
            let file = self.image_cache.join(hex(&Sha256::digest(format!("{}\n{text}", scope.package_id).as_bytes())));
            let fresh = std::fs::metadata(&file).and_then(|metadata| metadata.modified()).is_ok_and(|modified| SystemTime::now().duration_since(modified).is_ok_and(|age| age < IMAGE_CACHE));
            if !fresh
                && Instant::now() < deadline
                && scope.session.add_network_request() <= fetch::MAXIMUM_REQUESTS
                && let Ok(response) = self.fetch.perform("GET", &url, &[], None, IMAGE_TIMEOUT_MILLISECONDS, &allowed, None)
                && (200..=299).contains(&response.status)
                && !response.body.is_empty()
            {
                // A failure leaves a stale copy or the placeholder.
                let _ = replace_file(&file, &response.body);
            }
            // A stale copy is better than a placeholder when the network is unavailable.
            if file.is_file() {
                result.insert(text, file);
            }
        }
        result
    }
}

fn message_tree(lines: &[(&str, &str)]) -> String {
    let children: Vec<String> = lines.iter().map(|(text, props)| format!(r#"{{"$element":"text","props":{props},"children":[{}]}}"#, quote(text))).collect();
    format!(
        r##"{{"$element":"vstack","props":{{"alignment":"leading","background":"#fef2f2","frame":"max,topLeading","padding":"12","spacing":4}},"children":[{}]}}"##,
        children.join(",")
    )
}

fn collect_image_urls(node: &Value, urls: &mut Vec<String>) {
    match node {
        Value::Object(item) => {
            if item.opt_string("$element") == "image"
                && let Some(props) = item.opt_object("props")
            {
                let direct = props.opt_string("url");
                let url = if direct.is_empty() { props.opt_string("src") } else { direct };
                if (url.starts_with("http://") || url.starts_with("https://")) && !urls.contains(&url) {
                    urls.push(url);
                }
            }
            if let Some(children) = item.get("children") {
                collect_image_urls(children, urls);
            }
        }
        Value::Array(items) => items.iter().for_each(|child| collect_image_urls(child, urls)),
        _ => {}
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn create_private(directory: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)
}

/// Writes `bytes` beside `file` and renames the result over it, so a reader never sees half a file.
fn replace_file(file: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut temporary = file.as_os_str().to_owned();
    temporary.push(format!(".{}.tmp", std::process::id()));
    let temporary = PathBuf::from(temporary);
    std::fs::write(&temporary, bytes).and_then(|()| std::fs::rename(&temporary, file)).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

fn read_artifact(file: &Path) -> Option<PreparedPackage> {
    PreparedPackage::from_json(&parse_object(&std::fs::read_to_string(file).ok()?).ok()?).ok()
}

/// Keeps the cache small: one artifact per (source, action) pair, older ones removed.
fn write_artifact(directory: &Path, file: &Path, prepared: &PreparedPackage) -> io::Result<()> {
    create_private(directory)?;
    let mut old: Vec<(SystemTime, PathBuf)> = std::fs::read_dir(directory)?
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let name = entry.file_name().into_string().ok()?;
            (name.starts_with("prepared-") && name.ends_with(".json")).then(|| Some((entry.metadata().ok()?.modified().ok()?, entry.path())))?
        })
        .collect();
    old.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    for (_, stale) in old.into_iter().skip(MAXIMUM_CACHED_ARTIFACTS - 1) {
        let _ = std::fs::remove_file(stale);
    }
    replace_file(file, stringify(&prepared.to_json()).as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_image_urls_are_collected_once_and_only_http() {
        let tree: Value = serde_json::from_str(
            r#"{"$element":"vstack","props":null,"children":[
                {"$element":"image","props":{"url":"https://example.com/a.png"},"children":[]},
                {"$element":"hstack","props":null,"children":[
                    {"$element":"image","props":{"src":"http://example.com/b.png"},"children":[]},
                    {"$element":"image","props":{"url":"https://example.com/a.png"},"children":[]},
                    {"$element":"image","props":{"src":"res:local.png"},"children":[]},
                    {"$element":"image","props":{"url":"","src":"file:///etc/passwd"},"children":[]},
                    {"$element":"text","props":{"url":"https://example.com/not-an-image"},"children":["x"]}]}]}"#,
        )
        .unwrap();
        let mut urls = Vec::new();
        collect_image_urls(&tree, &mut urls);
        assert_eq!(urls, ["https://example.com/a.png", "http://example.com/b.png"]);
    }

    #[test]
    fn message_cards_are_canonical_trees() {
        let tree: Value = serde_json::from_str(&WidgetRuntime::notice_tree("No \"widget\"", "line\ntwo")).unwrap();
        assert_eq!(tree["$element"], "vstack");
        assert_eq!(tree["children"][0]["children"][0], "No \"widget\"");
        assert_eq!(tree["children"][1]["children"][0], "line\ntwo");
        assert_eq!(tree["children"][1]["props"]["font"], "caption2");
    }
}
