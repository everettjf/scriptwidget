//! Shared by the `api_*` and `plugins_*` tests: the JavaScript runtime, an
//! HTTP exchange that never leaves the process, and helpers to call a module
//! the way the script bridge does. Nothing here reaches the network.
#![allow(dead_code)]

use std::io::Read;
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{Value, json};
use sw_core::api::fetch::{FetchError, FetchModule, Resolver, Transport, TransportRequest, TransportResponse, Url, Wait};
use sw_core::compiler::PrepareOptions;
use sw_core::json::Object;
use sw_core::{Completion, ExecutionRequest, ExecutionResult, MemoryPackageFiles, NativeModule, PackageCompiler, PreparedPackage, ScriptExecutor, SharedScripts};

pub const BLOCKED: &str = "Local and private network hosts are not allowed";
pub const PUBLIC: &str = "93.184.216.34";

pub fn scripts() -> Arc<SharedScripts> {
    static SCRIPTS: OnceLock<Arc<SharedScripts>> = OnceLock::new();
    SCRIPTS.get_or_init(|| Arc::new(SharedScripts::new(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget")).expect("shared scripts"))).clone()
}

pub fn compiler() -> &'static PackageCompiler {
    static COMPILER: OnceLock<PackageCompiler> = OnceLock::new();
    COMPILER.get_or_init(|| PackageCompiler::new(scripts()).expect("compiler thread"))
}

/// A directory of its own for one test.
pub fn temporary_directory(name: &str) -> PathBuf {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let directory = std::env::temp_dir().join(format!("scriptwidget-test-{name}-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("temporary directory");
    directory
}

/// A Package 2.0 manifest as the validator accepts it.
pub fn widget_manifest(permissions: &str, domains: &str) -> String {
    format!(
        r#"{{"entry":"main.jsx","formatVersion":2,"id":"com.example.test","name":"Test","networkDomains":{domains},"permissions":{permissions},"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"}}"#
    )
}

/// Runs a script and returns the execution result.
pub fn run(source: &str, manifest: Option<&str>, modules: Vec<Arc<dyn NativeModule>>, environments: &[(&str, &str)], configure: impl FnOnce(&mut ExecutionRequest<'_>)) -> ExecutionResult {
    let mut text = vec![("main.jsx".to_owned(), source.to_owned())];
    if let Some(manifest) = manifest {
        text.push(("widget.json".to_owned(), manifest.to_owned()));
    }
    let files = MemoryPackageFiles::new(text, []);
    let prepared = compiler().prepare(&files, &PrepareOptions::default()).expect("prepare");
    let mut request = ExecutionRequest::new(&prepared, &files);
    request.environments = vec![("widget-size".into(), "small".into())];
    request.environments.extend(environments.iter().map(|(name, value)| (name.to_string(), value.to_string())));
    request.modules = modules;
    request.package_id = "pkg-a".into();
    configure(&mut request);
    ScriptExecutor::new(scripts()).execute(&request)
}

/// Runs a script whose result is the text of the rendered `<text>`.
pub fn render(source: &str, manifest: Option<&str>, modules: Vec<Arc<dyn NativeModule>>, environments: &[(&str, &str)]) -> String {
    let result = run(source, manifest, modules, environments, |_| {});
    assert!(result.error.is_none(), "error: {:?}", result.error);
    let tree: Value = serde_json::from_str(result.tree.as_deref().expect("tree")).expect("tree JSON");
    tree["children"].as_array().expect("children").iter().map(|child| child.as_str().unwrap_or("").to_owned()).collect()
}

/// A prepared package without code, for calling a module directly.
pub struct Package {
    pub prepared: PreparedPackage,
    pub files: MemoryPackageFiles,
    pub environments: Vec<(String, String)>,
    pub package_id: String,
}

impl Package {
    /// A legacy package: no manifest, so every public host is allowed.
    pub fn legacy() -> Self {
        Self { prepared: PreparedPackage::default(), files: MemoryPackageFiles::default(), environments: vec![("widget-size".into(), "medium".into())], package_id: String::new() }
    }

    pub fn with_manifest(manifest: Value) -> Self {
        let mut package = Self::legacy();
        package.prepared.has_manifest = true;
        package.prepared.manifest = manifest.as_object().cloned();
        package
    }

    /// A Package 2.0 widget with the `network` permission and these domains.
    pub fn with_domains(domains: &[&str]) -> Self {
        Self::with_manifest(json!({ "formatVersion": 2, "permissions": ["network"], "networkDomains": domains }))
    }

    pub fn environments(mut self, environments: &[(&str, &str)]) -> Self {
        self.environments = environments.iter().map(|(name, value)| (name.to_string(), value.to_string())).collect();
        self
    }

    pub fn request(&self) -> ExecutionRequest<'_> {
        let mut request = ExecutionRequest::new(&self.prepared, &self.files);
        request.environments = self.environments.clone();
        request.package_id = self.package_id.clone();
        request
    }
}

/// Starts an asynchronous operation and waits for its single answer.
pub fn start(module: &dyn NativeModule, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>) -> (bool, Value) {
    let (done, answers) = Completion::detached(request.session.clone());
    module.start(request, operation, payload, done);
    let (_, ok, json) = answers.recv_timeout(Duration::from_secs(20)).expect("the operation did not complete");
    assert!(answers.recv_timeout(Duration::from_millis(50)).is_err(), "the operation completed twice");
    (ok, serde_json::from_str(&json.expect("an answer")).expect("answer JSON"))
}

/// The rejection message of an operation that must fail.
pub fn rejection(module: &dyn NativeModule, request: &ExecutionRequest<'_>, operation: &str, payload: &Value) -> String {
    let (ok, value) = start(module, request, operation, payload.as_object());
    assert!(!ok, "expected a rejection, got {value}");
    value.as_str().expect("a message").to_owned()
}

pub fn get(url: &str) -> Value {
    json!({ "method": "GET", "url": url })
}

pub fn addresses(texts: &[&str]) -> Vec<IpAddr> {
    texts.iter().map(|text| text.parse().expect("address")).collect()
}

/// A resolver that answers every name with the same addresses.
pub fn fixed_resolver(texts: &[&str]) -> Resolver {
    let answer = addresses(texts);
    Arc::new(move |_| Ok(answer.clone()))
}

pub fn public_resolver() -> Resolver {
    fixed_resolver(&[PUBLIC])
}

/// One request as the transport received it.
#[derive(Debug, Clone)]
pub struct Recorded {
    pub method: String,
    pub url: Url,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
}

impl Recorded {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(known, _)| known.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }

    pub fn path(&self) -> &str {
        self.url.path()
    }
}

pub enum FakeBody {
    Bytes(Vec<u8>),
    /// Zeros for as long as it is read, or until `length`; `read` counts what was handed out.
    /// A stalled body sends its first bytes and then nothing, like a server that stops answering.
    Zeros { length: Option<u64>, stall: bool, read: Arc<AtomicU64> },
}

pub struct FakeResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: FakeBody,
}

impl FakeResponse {
    pub fn text(status: u16, body: &str) -> Self {
        Self::typed(status, body, "text/plain; charset=utf-8")
    }

    pub fn typed(status: u16, body: &str, content_type: &str) -> Self {
        Self { status, headers: vec![("Content-Type".into(), content_type.into())], body: FakeBody::Bytes(body.as_bytes().to_vec()) }
    }

    pub fn bytes(status: u16, body: &[u8]) -> Self {
        Self { status, headers: Vec::new(), body: FakeBody::Bytes(body.to_vec()) }
    }

    pub fn redirect(status: u16, location: Option<&str>) -> Self {
        Self { status, headers: location.map(|location| ("Location".to_owned(), location.to_owned())).into_iter().collect(), body: FakeBody::Bytes(Vec::new()) }
    }

    pub fn zeros(length: Option<u64>, stall: bool, read: &Arc<AtomicU64>) -> Self {
        Self { status: 200, headers: Vec::new(), body: FakeBody::Zeros { length, stall, read: read.clone() } }
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }
}

struct ZeroReader {
    left: Option<u64>,
    stall: bool,
    read: Arc<AtomicU64>,
    wait: Wait,
}

impl Read for ZeroReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.stall && self.read.load(Ordering::SeqCst) > 0 {
            return Err(self.wait.expire().into_io());
        }
        let take = buffer.len().min(self.left.map_or(usize::MAX, |left| left as usize));
        buffer[..take].fill(0);
        self.left = self.left.map(|left| left - take as u64);
        self.read.fetch_add(take as u64, Ordering::SeqCst);
        Ok(take)
    }
}

type Respond = Box<dyn Fn(&Recorded, &Wait) -> Result<FakeResponse, FetchError> + Send + Sync>;

/// An HTTP exchange that never leaves the process: records each request and answers from a function.
pub struct FakeTransport {
    respond: Respond,
    requests: Mutex<Vec<Recorded>>,
}

impl FakeTransport {
    pub fn new(respond: impl Fn(&Recorded) -> FakeResponse + Send + Sync + 'static) -> Arc<Self> {
        Self::waiting(move |request, _| Ok(respond(request)))
    }

    /// A transport whose answer may depend on the wait, or fail.
    pub fn waiting(respond: impl Fn(&Recorded, &Wait) -> Result<FakeResponse, FetchError> + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self { respond: Box::new(respond), requests: Mutex::new(Vec::new()) })
    }

    pub fn ok() -> Arc<Self> {
        Self::new(|_| FakeResponse::text(200, "ok"))
    }

    pub fn requests(&self) -> Vec<Recorded> {
        self.requests.lock().unwrap().clone()
    }

    pub fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }

    pub fn clear(&self) {
        self.requests.lock().unwrap().clear();
    }
}

impl Transport for FakeTransport {
    fn send(&self, request: &TransportRequest<'_>, wait: &Wait) -> Result<TransportResponse, FetchError> {
        let recorded = Recorded { method: request.method.to_owned(), url: request.url.clone(), headers: request.headers.to_vec(), body: request.body.map(<[u8]>::to_vec) };
        self.requests.lock().unwrap().push(recorded.clone());
        let response = (self.respond)(&recorded, wait)?;
        let body: Box<dyn Read> = match response.body {
            FakeBody::Bytes(bytes) => Box::new(std::io::Cursor::new(bytes)),
            FakeBody::Zeros { length, stall, read } => Box::new(ZeroReader { left: length, stall, read, wait: wait.clone() }),
        };
        Ok(TransportResponse { status: response.status, headers: response.headers, body })
    }
}

/// A fetch module that answers every request in the process, for a name that resolves to a public address.
pub fn offline(transport: &Arc<FakeTransport>) -> FetchModule {
    FetchModule::with_parts(public_resolver(), transport.clone())
}

pub fn url(text: &str) -> Url {
    Url::parse(text).expect("URL")
}

pub fn no_headers() -> Vec<(String, String)> {
    Vec::new()
}

pub fn headers(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(name, value)| (name.to_string(), value.to_string())).collect()
}

pub fn any_redirect(_: &Url) -> bool {
    true
}

/// The message of a request that must fail with one of the module's own sentences.
pub fn failure<T: std::fmt::Debug>(result: Result<T, FetchError>) -> String {
    match result {
        Err(FetchError::Failed(message)) => message,
        other => panic!("expected a refusal, got {other:?}"),
    }
}
