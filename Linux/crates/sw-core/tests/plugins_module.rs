//! `$dataSource.request` as the script bridge calls it. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Plugins/DataSourceModuleTests.cs`.

mod api_common;
mod plugins_common;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use api_common::{BLOCKED, FakeResponse, FakeTransport, Package, render, temporary_directory, url, widget_manifest};
use plugins_common::*;
use serde_json::{Value, json};
use sw_core::api::fetch::{self, Cancel, FetchError, FetchModule, Resolver, Response, Url};
use sw_core::plugins::manifest::{PluginManifest, PluginOperation};
use sw_core::plugins::module::{self, DataSourceExecutor, DataSourceModule, DataSourceTransport, PackageScope};
use sw_core::plugins::{PluginStore, requests};
use sw_core::{Completion, ExecutionRequest, NativeModule};

#[derive(Debug, Clone)]
struct Call {
    method: String,
    url: Url,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
    timeout: u64,
}

type Respond = Box<dyn Fn(&Call, &dyn Fn(&Url) -> bool) -> Result<Response, FetchError> + Send + Sync>;

/// Offline transport: records each call and answers with `respond`.
struct Fake {
    respond: Mutex<Respond>,
    calls: Mutex<Vec<Call>>,
}

impl Fake {
    fn respond(&self, respond: impl Fn(&Call, &dyn Fn(&Url) -> bool) -> Result<Response, FetchError> + Send + Sync + 'static) {
        *self.respond.lock().unwrap() = Box::new(respond);
    }

    fn calls(&self) -> Vec<Call> {
        self.calls.lock().unwrap().clone()
    }
}

fn response(status: u16, body: &str) -> Result<Response, FetchError> {
    Ok(Response { status, body: body.as_bytes().to_vec(), headers: HashMap::new() })
}

struct Fixture {
    temporary: PathBuf,
    store: Arc<PluginStore>,
    transport: Arc<Fake>,
    plugin: PluginManifest,
}

impl Fixture {
    fn new() -> Self {
        let temporary = temporary_directory("datasource");
        let store = Arc::new(PluginStore::new(temporary.join("Plugins")));
        store.install(&mut &bytes()[..]).expect("the test plugin");
        let transport = Arc::new(Fake { respond: Mutex::new(Box::new(|_, _| response(200, "{\"ok\":true}"))), calls: Mutex::default() });
        Self { temporary, store, transport, plugin: base_manifest() }
    }

    /// The module over the fake transport, running the request on the calling thread.
    fn module(&self) -> DataSourceModule {
        let fake = self.transport.clone();
        let transport: DataSourceTransport = Arc::new(move |method, url, headers, body, timeout, allow_redirect, _: Option<Cancel>| {
            let call = Call { method: method.to_owned(), url: url.clone(), headers: headers.to_vec(), body: body.map(<[u8]>::to_vec), timeout };
            fake.calls.lock().unwrap().push(call.clone());
            (fake.respond.lock().unwrap())(&call, allow_redirect)
        });
        DataSourceModule::with_parts(self.store.clone(), transport, direct())
    }

    /// Starts the operation; `None` when no answer arrived.
    fn run_with(&self, module: &DataSourceModule, request: &ExecutionRequest<'_>, payload: Option<&Value>) -> Option<(bool, Value)> {
        let (done, answers) = Completion::detached(request.session.clone());
        module.start(request, DataSourceModule::OPERATION, payload.and_then(Value::as_object), done);
        let (_, ok, json) = answers.recv_timeout(Duration::from_millis(200)).ok()?;
        assert!(answers.try_recv().is_err(), "done must be called exactly once");
        Some((ok, serde_json::from_str(&json.expect("an answer")).expect("answer JSON")))
    }

    fn run(&self, package: &Package, payload: Value) -> (bool, Value) {
        self.run_with(&self.module(), &package.request(), Some(&payload)).expect("an answer")
    }

    fn assert_rejected(&self, expected: &str, outcome: (bool, Value)) {
        assert_eq!(outcome, (false, json!(expected)));
        assert_eq!(self.transport.calls().len(), 0, "a rejected request must not reach the network");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.temporary);
    }
}

fn direct() -> DataSourceExecutor {
    Arc::new(|work| work())
}

fn widget(plugins: Option<&[&str]>, permissions: &[&str], domains: Option<&[&str]>) -> Package {
    let mut manifest = json!({ "formatVersion": 2, "permissions": permissions });
    if let Some(plugins) = plugins {
        manifest["plugins"] = json!(plugins);
    }
    if let Some(domains) = domains {
        manifest["networkDomains"] = json!(domains);
    }
    Package::with_manifest(manifest)
}

fn default_widget() -> Package {
    widget(Some(&[ID]), &["network"], Some(&["api.example.com"]))
}

fn with_domains(domains: &[&str]) -> Package {
    widget(Some(&[ID]), &["network"], Some(domains))
}

fn payload(plugin: &str, operation: &str, parameters: Value) -> Value {
    json!({ "pluginID": plugin, "operationID": operation, "parameters": parameters })
}

fn status() -> Value {
    payload(ID, "status", json!({}))
}

#[test]
fn exposes_the_data_source_global_and_operation() {
    let fixture = Fixture::new();
    let module = fixture.module();
    assert_eq!(module.apis(), ["$dataSource"]);
    assert!(module.handles("datasource.request"));
    assert!(!module.handles("http.request"));
}

#[test]
fn resolves_json_and_text_responses() {
    let fixture = Fixture::new();
    fixture.transport.respond(|_, _| response(200, "plain text"));
    assert_eq!(fixture.run(&default_widget(), status()), (true, json!("plain text")));
    let calls = fixture.transport.calls();
    assert_eq!((calls[0].url.as_str(), calls[0].method.as_str(), calls[0].timeout), ("https://api.example.com/status", "GET", DataSourceModule::TIMEOUT_MILLISECONDS));

    fixture.transport.respond(|_, _| response(200, "{\"name\":\"Ada\",\"tags\":[1,2]}"));
    let parameters = json!({ "user": "ada l", "X-Token": "t", "enabled": true, "undeclared": "x" });
    let (ok, value) = fixture.run(&default_widget(), payload(ID, "update", parameters));
    assert!(ok);
    assert_eq!(value["name"], "Ada");
    let call = &fixture.transport.calls()[1];
    assert_eq!((call.url.as_str(), call.method.as_str()), ("https://api.example.com/users/ada%20l?page=1", "POST"));
    assert!(call.headers.contains(&("X-Token".to_owned(), "t".to_owned())));
    assert_eq!(call.body.as_deref(), Some(&b"{\"enabled\":true}"[..]));
}

#[test]
fn built_in_plugins_work_when_declared() {
    let fixture = Fixture::new();
    let id = "app.scriptwidget.datasource.github";
    let package = widget(Some(&[id]), &["network"], Some(&["api.github.com"]));
    assert!(fixture.run(&package, json!({ "pluginID": id, "operationID": "repository" })).0);
    assert_eq!(fixture.transport.calls()[0].url.as_str(), "https://api.github.com/repos/everettjf/scriptwidget");
}

#[test]
fn undeclared_plugin_is_rejected() {
    let fixture = Fixture::new();
    let message = format!("Plugin {ID} is not declared in widget.json");
    fixture.assert_rejected(&message, fixture.run(&widget(Some(&["dev.scriptwidget.other"]), &["network"], Some(&["api.example.com"])), status()));
    fixture.assert_rejected(&message, fixture.run(&widget(None, &["network"], Some(&["api.example.com"])), status()));
    fixture.assert_rejected(&message, fixture.run(&widget(Some(&[]), &["network"], Some(&["api.example.com"])), status()));
    // A legacy package has no manifest and therefore declares nothing, even if stale manifest data is present.
    fixture.assert_rejected(&message, fixture.run(&Package::legacy(), status()));
    let mut stale = default_widget();
    stale.prepared.has_manifest = false;
    fixture.assert_rejected(&message, fixture.run(&stale, status()));
    // Installing a plugin grants nothing: the built-in is installed but not declared.
    fixture.assert_rejected("Plugin app.scriptwidget.datasource.github is not declared in widget.json", fixture.run(&default_widget(), payload("app.scriptwidget.datasource.github", "repository", json!({}))));
}

#[test]
fn missing_network_permission_is_rejected() {
    let fixture = Fixture::new();
    fixture.assert_rejected("Plugin requests require the network permission", fixture.run(&widget(Some(&[ID]), &[], Some(&["api.example.com"])), status()));
    fixture.assert_rejected("Plugin requests require the network permission", fixture.run(&widget(Some(&[ID]), &["location"], Some(&["api.example.com"])), status()));
}

#[test]
fn host_missing_from_network_domains_is_rejected() {
    let fixture = Fixture::new();
    let message = "Data source host is not declared in widget.json networkDomains.";
    fixture.assert_rejected(message, fixture.run(&with_domains(&["other.example.com"]), status()));
    fixture.assert_rejected(message, fixture.run(&with_domains(&[]), status()));
    fixture.assert_rejected(message, fixture.run(&widget(Some(&[ID]), &["network"], None), status()));
    fixture.assert_rejected(message, fixture.run(&with_domains(&["*.api.example.com"]), status()));
    assert!(fixture.run(&with_domains(&["*.example.com"]), status()).0);
}

#[test]
fn host_missing_from_plugin_hosts_is_rejected() {
    let fixture = Fixture::new();
    let package = with_domains(&["api.example.com", "evil.example.net"]);
    let scope = PackageScope::of(&package.request());
    assert_eq!(module::destination_error(&scope, &fixture.plugin, &url("https://evil.example.net/status")), Some("Plugin request escaped its declared hosts."));
    assert_eq!(module::destination_error(&scope, &fixture.plugin, &url("https://api.example.com/status")), None);
    // The package allows the host, the plugin does not declare it: a tampered manifest is still refused.
    let tampered = PluginManifest { base_url: "https://evil.example.net".into(), ..fixture.plugin.clone() };
    assert_eq!(requests::prepare(&tampered, "status", &values(json!({}))).unwrap_err().message, "Plugin request escaped its declared hosts.");
}

#[test]
fn http_and_private_destinations_are_rejected() {
    let fixture = Fixture::new();
    let package = with_domains(&["api.example.com", "localhost", "10.0.0.1"]);
    let scope = PackageScope::of(&package.request());
    let destination = |plugin: &PluginManifest, address: &str| module::destination_error(&scope, plugin, &url(address));
    assert_eq!(destination(&fixture.plugin, "http://api.example.com/status"), Some("Data source requests require HTTPS"));
    assert_eq!(destination(&fixture.plugin, "ftp://api.example.com/status"), Some("Data source requests require HTTPS"));
    assert_eq!(destination(&fixture.plugin, "file:///status"), Some("Data source requests require HTTPS"));
    assert_eq!(destination(&fixture.plugin, "https://user:pw@api.example.com/status"), Some("URL credentials are not allowed"));
    let local = PluginManifest { hosts: vec!["api.example.com".into(), "localhost".into(), "10.0.0.1".into()], ..fixture.plugin.clone() };
    assert_eq!(destination(&local, "https://localhost/status"), Some(BLOCKED));
    assert_eq!(destination(&local, "https://10.0.0.1/status"), Some(BLOCKED));
    assert_eq!(destination(&local, "https://167772161/status"), Some(BLOCKED), "10.0.0.1 written as one number");
}

#[test]
fn timeline_projections_and_live_activities_are_rejected() {
    let fixture = Fixture::new();
    let timeline = "[timeline_read_only] Future entries cannot make live service requests";
    fixture.assert_rejected(timeline, fixture.run(&default_widget().environments(&[("widget-size", "medium"), ("timeline-is-projection", "true")]), status()));
    let mut compiled = default_widget();
    compiled.prepared.timeline_environment = vec![("timeline-is-projection".into(), "true".into())];
    fixture.assert_rejected(timeline, fixture.run(&compiled, status()));
    let live = "[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app";
    fixture.assert_rejected(live, fixture.run(&default_widget().environments(&[("widget-size", "live-activity")]), status()));
    fixture.assert_rejected(live, fixture.run(&default_widget().environments(&[("widget-size", "dynamic-island")]), status()));
    assert!(fixture.run(&default_widget().environments(&[("widget-size", "medium"), ("timeline-is-projection", "false")]), status()).0);
}

#[test]
fn a_finished_execution_is_rejected() {
    let fixture = Fixture::new();
    let package = default_widget();
    let request = package.request();
    assert_eq!(module::presentation_error(&request), None);
    request.session.finish();
    assert_eq!(module::presentation_error(&request), Some("Execution session is no longer active"));
    // Nobody is left to hear the rejection, and nothing is sent.
    assert_eq!(fixture.run_with(&fixture.module(), &request, Some(&status())), None);
    assert_eq!(fixture.transport.calls().len(), 0);
}

#[test]
fn the_request_budget_is_shared_with_fetch() {
    let fixture = Fixture::new();
    let module = fixture.module();
    let package = default_widget();
    let request = package.request();
    for _ in 0..fetch::MAXIMUM_REQUESTS {
        assert!(fixture.run_with(&module, &request, Some(&status())).unwrap().0);
    }
    assert_eq!(fixture.run_with(&module, &request, Some(&status())), Some((false, json!("Network request budget exceeded"))));
    assert_eq!(fixture.transport.calls().len(), fetch::MAXIMUM_REQUESTS as usize);

    // Requests made by fetch count against the same budget.
    let shared = package.request();
    for _ in 0..fetch::MAXIMUM_REQUESTS {
        shared.session.add_network_request();
    }
    assert_eq!(fixture.run_with(&module, &shared, Some(&status())), Some((false, json!("Network request budget exceeded"))));
    assert_eq!(fixture.transport.calls().len(), fetch::MAXIMUM_REQUESTS as usize);
}

#[test]
fn rejected_requests_do_not_consume_the_budget() {
    let fixture = Fixture::new();
    let module = fixture.module();
    let package = default_widget();
    let request = package.request();
    for job in [payload(ID, "missing", json!({})), payload(ID, "update", json!({})), payload("dev.scriptwidget.other", "status", json!({}))] {
        assert!(!fixture.run_with(&module, &request, Some(&job)).unwrap().0);
    }
    let undeclared_host = with_domains(&["other.example.com"]);
    let other = undeclared_host.request();
    assert!(!fixture.run_with(&module, &other, Some(&status())).unwrap().0);
    assert_eq!((request.session.network_requests(), other.session.network_requests()), (0, 0));
}

#[test]
fn redirects_are_restricted_to_declared_https_hosts() {
    let fixture = Fixture::new();
    let decisions: Arc<Mutex<Vec<(String, bool)>>> = Arc::default();
    let seen = decisions.clone();
    fixture.transport.respond(move |_, allow_redirect| {
        for target in ["https://api.example.com/moved", "https://evil.example.net/x", "https://cdn.example.com/x", "http://api.example.com/moved", "https://localhost/x", "https://user@api.example.com/x"] {
            seen.lock().unwrap().push((target.to_owned(), allow_redirect(&url(target))));
        }
        if !allow_redirect(&url("https://evil.example.net/x")) {
            return Err(FetchError::failed("Redirect target is not allowed"));
        }
        response(200, "{}")
    });
    let outcome = fixture.run(&with_domains(&["*.example.com", "evil.example.net"]), status());
    assert_eq!(outcome, (false, json!("Redirect target is not allowed")));
    let expected = [
        ("https://api.example.com/moved", true),
        ("https://evil.example.net/x", false),   // allowed by the package, not declared by the plugin
        ("https://cdn.example.com/x", false),    // allowed by the package wildcard, not declared by the plugin
        ("http://api.example.com/moved", false), // downgrade
        ("https://localhost/x", false),
        ("https://user@api.example.com/x", false),
    ];
    assert_eq!(*decisions.lock().unwrap(), expected.map(|(target, allowed)| (target.to_owned(), allowed)));

    // A host the plugin declares but the package does not allow is refused as well.
    let wide = PluginManifest { hosts: vec!["api.example.com".into(), "cdn.example.org".into()], ..fixture.plugin.clone() };
    let narrow = default_widget();
    let request = narrow.request();
    let scope = PackageScope::of(&request);
    assert!(!module::allows_redirect(&scope, &wide, &url("https://cdn.example.org/x")));
    assert!(module::allows_redirect(&scope, &wide, &url("https://api.example.com/x")));
    request.session.finish();
    assert!(!module::allows_redirect(&scope, &wide, &url("https://api.example.com/x")));
}

#[test]
fn uninstalled_plugin_and_bad_requests_are_rejected() {
    let fixture = Fixture::new();
    let other = "dev.scriptwidget.other";
    fixture.assert_rejected(&format!("Plugin {other} is not installed"), fixture.run(&widget(Some(&[other]), &["network"], Some(&["api.example.com"])), payload(other, "status", json!({}))));
    fixture.assert_rejected(&format!("Operation missing was not found in {ID}."), fixture.run(&default_widget(), payload(ID, "missing", json!({}))));
    fixture.assert_rejected("Missing required parameter user.", fixture.run(&default_widget(), payload(ID, "update", json!({}))));
    let needs_ids = "Data source requests need a plugin id and an operation id";
    fixture.assert_rejected(needs_ids, fixture.run(&default_widget(), json!({ "pluginID": 7, "operationID": "status" })));
    fixture.assert_rejected(needs_ids, fixture.run(&default_widget(), json!({ "pluginID": ID })));
    let package = default_widget();
    assert_eq!(fixture.run_with(&fixture.module(), &package.request(), None), Some((false, json!(needs_ids))));
    let (done, answers) = Completion::detached(package.request().session.clone());
    fixture.module().start(&package.request(), "datasource.other", status().as_object(), done);
    assert_eq!(answers.recv_timeout(Duration::from_secs(1)).unwrap().2.as_deref(), Some("\"Unsupported operation datasource.other\""));
}

#[test]
fn response_failures_use_the_swift_messages() {
    let fixture = Fixture::new();
    let text = |job: Value| fixture.run(&default_widget(), job).1;
    fixture.transport.respond(|_, _| response(500, "{\"secret\":\"body\"}"));
    assert_eq!(text(status()), "Data source request failed");
    fixture.transport.respond(|_, _| Ok(Response { status: 200, body: vec![0xFF], headers: HashMap::new() }));
    assert_eq!(text(status()), "Data source returned non-UTF-8 text");
    fixture.transport.respond(|_, _| response(200, "<html>"));
    assert_eq!(text(payload(ID, "update", json!({ "user": "u", "X-Token": "t", "enabled": 1 }))), "Data source returned invalid JSON");
    fixture.transport.respond(|_, _| Ok(Response { status: 200, body: vec![0; fetch::MAXIMUM_RESPONSE_BYTES + 1], headers: HashMap::new() }));
    assert_eq!(text(status()), "Data source response exceeds 2 MiB.");
    fixture.transport.respond(|_, _| Err(FetchError::failed(BLOCKED)));
    assert_eq!(text(status()), BLOCKED);
    // Text from the network stack may quote the URL and its parameter values; it is not forwarded.
    fixture.transport.respond(|call, _| Err(FetchError::Transport(format!("failed to connect to {}?token=secret", call.url))));
    assert_eq!(text(status()), "Data source request failed");
    fixture.transport.respond(|_, _| Err(FetchError::failed("")));
    assert_eq!(text(status()), "Data source request failed");
}

#[test]
fn results_are_dropped_after_the_execution_ends() {
    let fixture = Fixture::new();
    let package = default_widget();
    let request = package.request();
    let session = request.session.clone();
    fixture.transport.respond(move |_, _| {
        session.finish();
        response(200, "ok")
    });
    assert_eq!(fixture.run_with(&fixture.module(), &request, Some(&status())), None);
    assert_eq!(fixture.transport.calls().len(), 1);
}

/// The same rules over the real `fetch` module, with the HTTP exchange and the
/// resolver replaced. A plugin request never leaves HTTPS, its declared hosts
/// or public addresses.
#[test]
fn the_fetch_transport_keeps_plugin_requests_on_declared_public_https_hosts() {
    let fixture = Fixture::new();
    let location: Arc<Mutex<String>> = Arc::new(Mutex::new("https://api.example.com/moved".into()));
    let target = location.clone();
    let exchange = FakeTransport::new(move |request| if request.path() == "/status" { FakeResponse::redirect(302, Some(&target.lock().unwrap())) } else { FakeResponse::text(200, "moved") });
    let address: Arc<Mutex<String>> = Arc::new(Mutex::new("93.184.216.34".into()));
    let answer = address.clone();
    let resolver: Resolver = Arc::new(move |host: &str| match host {
        "api.example.com" => Ok(vec![answer.lock().unwrap().parse().unwrap()]),
        _ => Err(std::io::Error::other("unknown host")),
    });
    let fetch = Arc::new(FetchModule::with_parts(resolver, exchange.clone()));
    let module = || {
        let fetch = fetch.clone();
        let transport: DataSourceTransport = Arc::new(move |method, url, headers, body, timeout, allow_redirect, cancel| fetch.perform(method, url, headers, body, timeout, allow_redirect, cancel));
        DataSourceModule::with_parts(fixture.store.clone(), transport, direct())
    };
    let run = |package: &Package| fixture.run_with(&module(), &package.request(), Some(&status())).unwrap();

    assert_eq!(run(&default_widget()), (true, json!("moved")));
    let requests = exchange.requests();
    assert_eq!(requests.iter().map(|request| request.url.as_str()).collect::<Vec<_>>(), ["https://api.example.com/status", "https://api.example.com/moved"]);
    assert_eq!(requests[0].header("User-Agent"), Some("ScriptWidget-DataSource/1"));

    for to in ["http://api.example.com/moved", "https://evil.example.net/x", "https://cdn.example.com/x", "https://127.0.0.1/x", "https://user:pw@api.example.com/x", "file:///etc/passwd"] {
        exchange.clear();
        *location.lock().unwrap() = to.to_owned();
        assert_eq!(run(&with_domains(&["*.example.com", "evil.example.net", "127.0.0.1"])), (false, json!("Redirect target is not allowed")), "{to}");
        assert_eq!(exchange.count(), 1);
    }

    // The declared host itself resolving to a private address is refused before anything is sent.
    exchange.clear();
    *address.lock().unwrap() = "10.0.0.7".into();
    assert_eq!(run(&default_widget()), (false, json!(BLOCKED)));
    assert_eq!(exchange.count(), 0);
}

/// From a script, through the JavaScript installer and the bridge.
#[test]
fn scripts_reach_a_declared_plugin_and_nothing_else() {
    let fixture = Fixture::new();
    fixture.transport.respond(|call, _| response(200, &format!("{{\"path\":\"{}\"}}", call.url.path())));
    let script = r#"
        $dataSource.request("dev.scriptwidget.test-source", "update", { user: "ada", "X-Token": "t", enabled: true }).then(
          value => $render(<text>{value.path}</text>), error => $render(<text>{"error: " + String(error)}</text>))
    "#;
    let manifest = |plugins: &str, domains: &str| widget_manifest(r#"["network"]"#, domains).replace(r#""plugins":[]"#, &format!(r#""plugins":{plugins}"#));
    let declared = manifest(r#"["dev.scriptwidget.test-source"]"#, r#"["api.example.com"]"#);
    assert_eq!(render(script, Some(&declared), vec![Arc::new(fixture.module())], &[]), "/users/ada");
    let undeclared = render(script, Some(&manifest("[]", r#"["api.example.com"]"#)), vec![Arc::new(fixture.module())], &[]);
    assert!(undeclared.starts_with("error: ") && undeclared.contains("not declared"), "{undeclared}");
    let wrong_host = render(script, Some(&manifest(r#"["dev.scriptwidget.test-source"]"#, r#"["example.org"]"#)), vec![Arc::new(fixture.module())], &[]);
    assert!(wrong_host.starts_with("error: "), "{wrong_host}");
    assert_eq!(fixture.transport.calls().len(), 1);
    // The operation is one the plugin declares; the store's types stay what they were.
    let _: &PluginOperation = &fixture.plugin.operations[0];
}
