//! `$dataSource.request(pluginID, operationID, parameters)`. Ported from
//! `Windows/src/ScriptWidget.Core/Plugins/DataSourceModule.cs`
//! (`ScriptWidgetRuntimeDataSource` in Swift).

use std::sync::{Arc, OnceLock};

use serde_json::Value;

use crate::api::fetch::{self, BLOCKED_MESSAGE, Cancel, FetchError, FetchModule, Response, Url};
use crate::api::policy::{self, NetworkDeclaration};
use crate::api::workers::BoundedExecutor;
use crate::executor::{Completion, ExecutionRequest, ExecutionSession, NativeModule};
use crate::json::{Object, ObjectExt, quote};
use crate::plugins::manifest::{PluginError, PluginErrorKind, PluginManifest, PluginUrl};
use crate::plugins::requests;
use crate::plugins::store::PluginStore;

/// Performs one HTTP exchange for a plugin request: method, URL, headers,
/// body, timeout in milliseconds, the redirect rule and cancellation.
/// Production uses [`FetchModule::perform`], which resolves every hop and
/// refuses private addresses; tests inject a fake so they stay offline. The
/// redirect rule must be consulted for every redirect target before it is
/// followed.
pub type DataSourceTransport = Arc<dyn Fn(&str, &Url, &[(String, String)], Option<&[u8]>, u64, &dyn Fn(&Url) -> bool, Option<Cancel>) -> Result<Response, FetchError> + Send + Sync>;

/// Runs the request off the JavaScript thread.
pub type DataSourceExecutor = Arc<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>;

pub const SESSION_ENDED: &str = "Execution session is no longer active";
pub const LIVE_ACTIVITY: &str = "[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app";
pub const TIMELINE: &str = "[timeline_read_only] Future entries cannot make live service requests";
pub const NETWORK_PERMISSION: &str = "Plugin requests require the network permission";
pub const HTTPS_ONLY: &str = "Data source requests require HTTPS";
pub const PLUGIN_HOST: &str = "Plugin request escaped its declared hosts.";
pub const PACKAGE_HOST: &str = "Data source host is not declared in widget.json networkDomains.";
pub const BUDGET: &str = "Network request budget exceeded";

/// What the destination rules need to know about the package, detached from
/// the request so that a worker thread can apply them to redirect targets.
#[derive(Clone)]
pub struct PackageScope {
    session: Arc<ExecutionSession>,
    has_manifest: bool,
    network: NetworkDeclaration,
}

impl PackageScope {
    pub fn of(request: &ExecutionRequest<'_>) -> Self {
        Self { session: request.session.clone(), has_manifest: request.prepared.has_manifest, network: NetworkDeclaration::of(request) }
    }
}

/// Presentation rules: a finished execution gets nothing; Live Activity
/// presentations and future timeline entries are rendered ahead of time and
/// must not make live requests. Returns the rejection message, the Swift
/// wording, or `None` when the rule is satisfied.
pub fn presentation_error(request: &ExecutionRequest<'_>) -> Option<&'static str> {
    if request.session.finished() {
        Some(SESSION_ENDED)
    } else if policy::is_live_activity(request) {
        Some(LIVE_ACTIVITY)
    } else if policy::is_timeline_projection(request) {
        Some(TIMELINE)
    } else {
        None
    }
}

/// Declaration rules: the package's validated `widget.json` must list
/// `plugin_id` in `plugins` and hold the `network` permission. A package
/// without a manifest declares nothing, so it is refused: installing a
/// plugin never grants a widget anything by itself.
pub fn declaration_error(request: &ExecutionRequest<'_>, plugin_id: &str) -> Option<String> {
    let manifest = request.prepared.manifest.as_ref().filter(|_| request.prepared.has_manifest);
    let declared = manifest.and_then(|manifest| manifest.opt_array("plugins")).is_some_and(|plugins| plugins.iter().any(|item| item.as_str() == Some(plugin_id)));
    if !declared {
        return Some(format!("Plugin {plugin_id} is not declared in widget.json"));
    }
    (!policy::has_permission(request, "network")).then(|| NETWORK_PERMISSION.to_owned())
}

/// Destination rules for the initial URL and for every redirect target:
/// HTTPS only, a public host name without credentials, a host the plugin
/// declares, and a host the package allows through `network` and
/// `networkDomains`. A plugin therefore never enlarges what the package may
/// reach, and a package never reaches a host the plugin did not declare.
pub fn destination_error(scope: &PackageScope, plugin: &PluginManifest, url: &Url) -> Option<&'static str> {
    if url.scheme() != "https" {
        return Some(HTTPS_ONLY);
    }
    let host = url.host_str().unwrap_or("").to_lowercase();
    // Same textual rule as `fetch`: a host, no credentials, not local or private.
    if PluginUrl::unbracket(&host).is_empty() {
        return Some("URL host is required");
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Some("URL credentials are not allowed");
    }
    if policy::blocked_host_name(PluginUrl::unbracket(&host)) {
        return Some(BLOCKED_MESSAGE);
    }
    if !policy::host_matches(&host, plugin.hosts.iter().map(String::as_str)) {
        return Some(PLUGIN_HOST);
    }
    if !scope.has_manifest || !scope.network.allows_host(&host) {
        return Some(PACKAGE_HOST);
    }
    None
}

/// True when a redirect to `url` may be followed; the execution must still be running.
pub fn allows_redirect(scope: &PackageScope, plugin: &PluginManifest, url: &Url) -> bool {
    !scope.session.finished() && destination_error(scope, plugin, url).is_none()
}

/// Handles the asynchronous operation `datasource.request` with payload
/// `{pluginID, operationID, parameters}` and resolves with the mapped response.
///
/// Every rule is checked here, in this order, with the Swift error strings:
/// execution still active, not a Live Activity, not a timeline projection,
/// plugin declared in `widget.json`, `network` permission, plugin installed
/// and valid, request built only from declared parameters, HTTPS destination
/// inside both the plugin's hosts and the package's `networkDomains`, and the
/// per-execution network budget shared with `fetch`. Redirects are
/// re-validated against the same destination rules. Errors never contain
/// response content, header values or parameter values. The JavaScript
/// installer is not a security boundary.
pub struct DataSourceModule {
    store: Arc<PluginStore>,
    transport: DataSourceTransport,
    executor: DataSourceExecutor,
}

impl DataSourceModule {
    pub const OPERATION: &'static str = "datasource.request";
    /// The Swift fetch session's per-request timeout (5 s); the 10 s total is enforced by the transport.
    pub const TIMEOUT_MILLISECONDS: u64 = 5_000;

    /// The module over the bounded `fetch` transport and a bounded worker pool.
    pub fn new(store: Arc<PluginStore>) -> Self {
        static FETCH: OnceLock<FetchModule> = OnceLock::new();
        static POOL: OnceLock<BoundedExecutor> = OnceLock::new();
        let transport: DataSourceTransport =
            Arc::new(|method, url, headers, body, timeout, allow_redirect, cancel| FETCH.get_or_init(FetchModule::new).perform(method, url, headers, body, timeout, allow_redirect, cancel));
        let executor: DataSourceExecutor = Arc::new(|work| POOL.get_or_init(|| BoundedExecutor::new(fetch::MAXIMUM_CONCURRENT)).execute(work));
        Self::with_parts(store, transport, executor)
    }

    pub fn with_parts(store: Arc<PluginStore>, transport: DataSourceTransport, executor: DataSourceExecutor) -> Self {
        Self { store, transport, executor }
    }
}

impl NativeModule for DataSourceModule {
    fn handles(&self, operation: &str) -> bool {
        operation == Self::OPERATION
    }

    fn apis(&self) -> &[&'static str] {
        &["$dataSource"]
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>, done: Completion) {
        let fail = |done: Completion, message: &str| done.complete(false, Some(quote(message)));
        if operation != Self::OPERATION {
            return fail(done, &format!("Unsupported operation {operation}"));
        }
        if let Some(presentation) = presentation_error(request) {
            return fail(done, presentation);
        }
        let text = |name: &str| payload.and_then(|job| job.get(name)).and_then(Value::as_str).map(str::to_owned);
        let (Some(plugin_id), Some(operation_id)) = (text("pluginID"), text("operationID")) else {
            return fail(done, "Data source requests need a plugin id and an operation id");
        };
        if let Some(declaration) = declaration_error(request, &plugin_id) {
            return fail(done, &declaration);
        }
        let values = payload.and_then(|job| job.opt_object("parameters")).cloned().unwrap_or_default();
        let scope = PackageScope::of(request);
        let store = self.store.clone();
        let transport = self.transport.clone();

        (self.executor)(Box::new(move || {
            let session = scope.session.clone();
            let outcome = (|| -> Result<Option<String>, PluginError> {
                let plugin = store.manifest(&plugin_id).ok_or_else(|| PluginError::new(PluginErrorKind::NotFound, format!("Plugin {plugin_id} is not installed")))?;
                let prepared = requests::prepare(&plugin, &operation_id, &values)?;
                if let Some(destination) = destination_error(&scope, &plugin, &prepared.url) {
                    return Err(PluginError::new(PluginErrorKind::Permission, destination));
                }
                if session.finished() || session.add_network_request() > fetch::MAXIMUM_REQUESTS {
                    return Err(PluginError::new(PluginErrorKind::Network, BUDGET));
                }
                let ended = session.clone();
                let response = transport(
                    &prepared.method,
                    &prepared.url,
                    &prepared.headers,
                    prepared.body.as_deref(),
                    Self::TIMEOUT_MILLISECONDS,
                    &|redirected: &Url| allows_redirect(&scope, &plugin, redirected),
                    Some(Arc::new(move || ended.finished())),
                )
                .map_err(|error| {
                    let message = match &error {
                        FetchError::Failed(message) if !message.is_empty() => message.as_str(),
                        // Text from the network stack can quote the URL, which may carry parameter values.
                        _ => "Data source request failed",
                    };
                    PluginError::new(PluginErrorKind::Network, message)
                })?;
                if session.finished() {
                    return Ok(None);
                }
                requests::map_response(&prepared.operation, response.status, &response.body).map(Some)
            })();
            match outcome {
                Ok(Some(json)) => done.complete(true, Some(json)),
                // The execution ended: there is nobody to answer.
                Ok(None) => drop(done),
                Err(error) => done.complete(false, Some(quote(&error.message))),
            }
        }));
    }
}
