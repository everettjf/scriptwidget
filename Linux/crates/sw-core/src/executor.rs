//! Runs one prepared package in a fresh QuickJS context and returns its
//! element tree. Ported from
//! `Windows/src/ScriptWidget.Core/Runtime/ScriptExecutor.cs`.

use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sw_quickjs::{Engine, HostResult, JS_THREAD_STACK, JsError, run_on_js_thread};

use crate::compiler::PreparedPackage;
use crate::intl;
use crate::json::{Object, ObjectExt, parse_object, quote, stringify};
use crate::package_files::{PackageFiles, normalize_package_path};
use crate::shared_scripts::SharedScripts;

/// Name the "not supported" messages use for this host.
pub const PLATFORM_NAME: &str = "Linux";
/// The execution limit of every platform.
pub const DEFAULT_TIMEOUT_MILLISECONDS: u64 = 5000;
const INTERRUPT_GRACE_MILLISECONDS: u64 = 400;
const MAXIMUM_NATIVE_LOGS: usize = 500;

/// Everything one execution may touch.
pub struct ExecutionRequest<'a> {
    pub prepared: &'a PreparedPackage,
    pub files: &'a dyn PackageFiles,
    /// `$getenv` values, in order; later entries with the same name win.
    pub environments: Vec<(String, String)>,
    pub dark_mode: bool,
    pub device: Option<Object>,
    pub system: Option<Object>,
    /// Preview simulations for the shared kernel; production executions leave this empty.
    pub fixtures: Object,
    pub modules: Vec<Arc<dyn NativeModule>>,
    pub timeout_milliseconds: u64,
    /// Package identity for storage namespaces and diagnostics.
    pub package_id: String,
    /// Budgets and cancellation shared by every native call of this execution.
    pub session: Arc<ExecutionSession>,
}

impl<'a> ExecutionRequest<'a> {
    pub fn new(prepared: &'a PreparedPackage, files: &'a dyn PackageFiles) -> Self {
        Self {
            prepared,
            files,
            environments: vec![("widget-size".into(), "medium".into()), ("widget-param".into(), String::new())],
            dark_mode: false,
            device: None,
            system: None,
            fixtures: Object::new(),
            modules: Vec::new(),
            timeout_milliseconds: DEFAULT_TIMEOUT_MILLISECONDS,
            package_id: String::new(),
            session: Arc::new(ExecutionSession::default()),
        }
    }

    pub fn environment(&self, name: &str) -> Option<&str> {
        self.environments.iter().rev().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
    }
}

#[derive(Debug, Default)]
pub struct ExecutionSession {
    network_requests: AtomicU32,
    data_queries: AtomicU32,
    read_appearance: AtomicBool,
    finished: AtomicBool,
}

impl ExecutionSession {
    /// Counts one more network request and returns the new total.
    pub fn add_network_request(&self) -> u32 {
        self.network_requests.fetch_add(1, Ordering::SeqCst) + 1
    }

    pub fn network_requests(&self) -> u32 {
        self.network_requests.load(Ordering::SeqCst)
    }

    pub fn add_data_query(&self) -> u32 {
        self.data_queries.fetch_add(1, Ordering::SeqCst) + 1
    }

    pub fn data_queries(&self) -> u32 {
        self.data_queries.load(Ordering::SeqCst)
    }

    /// True once the script asked whether dark mode is on: its output may differ between themes.
    pub fn read_appearance(&self) -> bool {
        self.read_appearance.load(Ordering::SeqCst)
    }

    /// True when the execution ended; in-flight native work should stop.
    pub fn finished(&self) -> bool {
        self.finished.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecutionError {
    pub kind: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogEntry {
    pub level: String,
    pub message: String,
}

#[derive(Debug, Clone, Default)]
pub struct ExecutionResult {
    /// Canonical tree JSON (see `encodeElement` in the shared kernel), or `None` on error.
    pub tree: Option<String>,
    pub error: Option<ExecutionError>,
    pub logs: Vec<LogEntry>,
    pub diagnostics: Vec<Value>,
    pub elapsed: Duration,
}

/// Completes an asynchronous native operation, from any thread. Dropping it
/// without an answer rejects the operation, so a script never waits for a
/// result that cannot come.
pub struct Completion {
    id: i64,
    delivery: Option<Sender<(i64, bool, Option<String>)>>,
    session: Arc<ExecutionSession>,
}

impl Completion {
    /// `json` is the JSON text of the value, or of the rejection reason.
    pub fn complete(mut self, ok: bool, json: Option<String>) {
        self.deliver(ok, json);
    }

    fn deliver(&mut self, ok: bool, json: Option<String>) {
        if let Some(delivery) = self.delivery.take()
            && !self.session.finished()
        {
            // The receiver is gone once the execution has ended; the answer is then of no use.
            let _ = delivery.send((self.id, ok, json));
        }
    }
}

impl Drop for Completion {
    fn drop(&mut self) {
        self.deliver(false, Some(quote("Native operation ended without a result")));
    }
}

/// A group of native operations exposed to package code through the host
/// bridge. Policy (manifest permissions, budgets) is enforced here and in the
/// JavaScript installers, never by trusting package code.
pub trait NativeModule: Send + Sync {
    fn handles(&self, operation: &str) -> bool;

    /// Script globals this module implements, such as `$weather`; others report "not supported on Linux".
    fn apis(&self) -> &[&'static str] {
        &[]
    }

    /// Synchronous operation. Returns JSON text or `None`; an error is thrown in JavaScript.
    fn call(&self, _request: &ExecutionRequest<'_>, operation: &str, _payload: Option<&str>) -> HostResult {
        Err(format!("Unsupported operation {operation}"))
    }

    /// Asynchronous operation: answer through `done`, now or later from any thread.
    fn start(&self, _request: &ExecutionRequest<'_>, operation: &str, _payload: Option<&Object>, done: Completion) {
        done.complete(false, Some(quote(&format!("Unsupported operation {operation}"))));
    }
}

/// Runs prepared packages. Every execution gets a fresh engine with the
/// default limits: 64 MB of memory, a bounded stack and the request's deadline.
pub struct ScriptExecutor {
    scripts: Arc<SharedScripts>,
}

impl ScriptExecutor {
    pub fn new(scripts: Arc<SharedScripts>) -> Self {
        Self { scripts }
    }

    pub fn execute(&self, request: &ExecutionRequest<'_>) -> ExecutionResult {
        let started = Instant::now();
        let mut result = run_on_js_thread("scriptwidget-js", JS_THREAD_STACK, || self.run(request));
        result.elapsed = started.elapsed();
        result
    }

    fn run(&self, request: &ExecutionRequest<'_>) -> ExecutionResult {
        let (deliver, completions) = mpsc::channel::<(i64, bool, Option<String>)>();
        let finished: RefCell<Option<String>> = RefCell::new(None);
        let native_logs: RefCell<Vec<LogEntry>> = RefCell::new(Vec::new());

        let host = |operation: &str, payload: Option<&str>| -> HostResult {
            match operation {
                "finish" => {
                    *finished.borrow_mut() = payload.map(str::to_owned);
                    Ok(None)
                }
                "package.import" => Ok(compiled_import(request, payload)),
                "package.read" => Ok(normalize_package_path(payload).and_then(|path| request.files.read_text(&path))),
                "package.exists" => Ok(Some(if normalize_package_path(payload).is_some_and(|path| request.files.exists(&path)) { "1" } else { "0" }.into())),
                "support.script" => Ok(self.scripts.support_script(payload.unwrap_or("")).map(|text| text.to_string())),
                "session.appearance" => {
                    request.session.read_appearance.store(true, Ordering::SeqCst);
                    Ok(None)
                }
                "log.log" | "log.error" => {
                    let mut logs = native_logs.borrow_mut();
                    if logs.len() < MAXIMUM_NATIVE_LOGS {
                        logs.push(LogEntry { level: operation["log.".len()..].to_owned(), message: payload.unwrap_or("").to_owned() });
                    }
                    Ok(None)
                }
                "async.start" => {
                    let job = parse_object(payload.ok_or("Missing asynchronous operation")?)?;
                    let name = job.opt_string("operation");
                    let done = Completion { id: job.opt_f64("id") as i64, delivery: Some(deliver.clone()), session: request.session.clone() };
                    match request.modules.iter().find(|module| module.handles(&name)) {
                        Some(module) => module.start(request, &name, job.opt_object("payload"), done),
                        None => done.complete(false, Some(quote(&format!("Unsupported operation {name}")))),
                    }
                    Ok(None)
                }
                _ if intl::handles(operation) => intl::call(operation, payload),
                _ => match request.modules.iter().find(|module| module.handles(operation)) {
                    Some(module) => module.call(request, operation, payload),
                    None => Err(format!("Unsupported operation {operation}")),
                },
            }
        };

        let deadline = Instant::now() + Duration::from_millis(request.timeout_milliseconds);
        let outcome = (|| -> Result<(), JsError> {
            let asset = |name: &str| {
                self.scripts.text(name).map_err(|error| JsError { message: format!("ScriptWidget runtime asset could not be read: {error}"), interrupted: false })
            };
            let token = random_token()?;
            let mut engine = Engine::new(host)?;
            // The interrupt deadline is a backstop for synchronous loops; the
            // kernel's own timeout reports unresolved asynchronous work first.
            engine.set_deadline(request.timeout_milliseconds.saturating_add(INTERRUPT_GRACE_MILLISECONDS));
            for name in self.scripts.host_files() {
                engine.evaluate(&asset(name)?, name)?;
            }
            engine.evaluate(&asset("kernel.js")?, "kernel.js")?;
            let mut supported: Vec<&str> = Vec::new();
            for api in request.modules.iter().flat_map(|module| module.apis().iter().copied()) {
                if !supported.contains(&api) {
                    supported.push(api);
                }
            }
            let job = json!({
                "config": stringify(&self.configuration(request)),
                "code": request.prepared.code,
                "timeoutMilliseconds": request.timeout_milliseconds,
                "supportedAPIs": supported,
                "platformName": PLATFORM_NAME,
            });
            engine.call("__swBoot", &[Some(&token), Some(&stringify(&job))])?;

            while finished.borrow().is_none() {
                engine.run_jobs(10_000)?;
                if finished.borrow().is_some() {
                    break;
                }
                if engine.call(&token, &[Some("pump")])?.as_deref() == Some("1") {
                    continue;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                let completion = if remaining.is_zero() { None } else { completions.recv_timeout(remaining).ok() };
                match completion {
                    None => {
                        engine.call(&token, &[Some("timeout")])?;
                        engine.run_jobs(10_000)?;
                        finished.borrow_mut().get_or_insert_with(timeout_failure);
                    }
                    Some((id, ok, json)) => {
                        engine.call(&token, &[Some("resolve"), Some(&id.to_string()), Some(if ok { "1" } else { "0" }), json.as_deref()])?;
                    }
                }
            }
            Ok(())
        })();
        request.session.finished.store(true, Ordering::SeqCst);

        if let Err(error) = outcome {
            finished.borrow_mut().get_or_insert_with(|| {
                if error.interrupted {
                    timeout_failure()
                } else if error.message.to_lowercase().contains("out of memory") {
                    failure("resourceLimit", "Script exceeded the runtime memory budget")
                } else {
                    failure("internalError", if error.message.is_empty() { "Execution failed" } else { &error.message })
                }
            });
        }
        let result_text = finished.into_inner().unwrap_or_else(|| failure("internalError", "Execution failed"));
        decode(&result_text, native_logs.into_inner())
    }

    fn configuration(&self, request: &ExecutionRequest<'_>) -> Value {
        let prepared = request.prepared;
        let mut environments = Object::new();
        for (name, value) in prepared.timeline_environment.iter().chain(&request.environments) {
            environments.insert(name.clone(), Value::String(value.clone()));
        }
        if let Some(action) = &prepared.action_id {
            if request.environment("action-id").is_none() {
                environments.insert("action-id".into(), Value::String(action.clone()));
            }
            environments.insert("widget-size".into(), Value::String("action".into()));
        }
        let mut config = json!({
            "contract": self.scripts.contract(),
            "environments": environments,
            "actionID": prepared.action_id,
            "liveActivityPresentation": matches!(request.environment("widget-size"), Some("live-activity" | "dynamic-island")),
            "preview": { "appearance": if request.dark_mode { "dark" } else { "light" } },
            "fixtures": request.fixtures,
            "manifest": prepared.manifest,
            "hasManifest": prepared.has_manifest,
            "packageID": request.package_id,
        });
        if let Some(device) = &request.device {
            config["device"] = Value::Object(device.clone());
        }
        if let Some(system) = &request.system {
            config["system"] = Value::Object(system.clone());
        }
        config
    }
}

fn compiled_import(request: &ExecutionRequest<'_>, relative_path: Option<&str>) -> Option<String> {
    let path = normalize_package_path(relative_path)?;
    if !request.files.exists(&path) || request.files.read_text(&path).is_none() {
        return None;
    }
    Some(request.prepared.imports.get(&path).cloned().unwrap_or_else(|| r#"{"ok":false,"kind":"transformError","message":"Not a script file"}"#.into()))
}

/// Name of the driver function in the execution context. Package code cannot guess it.
fn random_token() -> Result<String, JsError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| JsError { message: format!("No random source: {error}"), interrupted: false })?;
    Ok(bytes.iter().fold(String::from("__sw_"), |mut token, byte| {
        token.push_str(&format!("{byte:02x}"));
        token
    }))
}

fn timeout_failure() -> String {
    failure("resourceLimit", "Script exceeded the 5-second execution limit")
}

fn failure(kind: &str, message: &str) -> String {
    stringify(&json!({ "tree": null, "error": { "kind": kind, "message": message }, "logs": [], "diagnostics": [] }))
}

fn decode(result_text: &str, native_logs: Vec<LogEntry>) -> ExecutionResult {
    let json = match parse_object(result_text) {
        Ok(json) => json,
        Err(message) => {
            return ExecutionResult { error: Some(ExecutionError { kind: "internalError".into(), message: format!("Execution result could not be read: {message}") }), logs: native_logs, ..Default::default() };
        }
    };
    let error = json.opt_object("error").map(|error| ExecutionError {
        kind: error.opt_string_or_none("kind").unwrap_or_else(|| "internalError".into()),
        message: error.opt_string("message"),
    });
    let logs: Vec<LogEntry> = json
        .opt_array("logs")
        .map(|logs| logs.iter().filter_map(Value::as_object).map(|item| LogEntry { level: item.opt_string("level"), message: item.opt_string("message") }).collect())
        .unwrap_or_default();
    ExecutionResult {
        tree: if json.is_null("tree") { None } else { Some(json.opt_string("tree")) },
        error,
        logs: if logs.is_empty() { native_logs } else { logs },
        diagnostics: json.opt_array("diagnostics").cloned().unwrap_or_default(),
        elapsed: Duration::ZERO,
    }
}
