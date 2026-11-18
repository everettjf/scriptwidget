//! Validates manifests and transpiles JSX with the same Babel bundle and
//! prepare code as the web preview engine. Ported from
//! `Windows/src/ScriptWidget.Core/Runtime/PackageCompiler.cs`.

use std::fmt;
use std::sync::Arc;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::{Value, json};
use sw_quickjs::{Engine, JsError};

use crate::intl;
use crate::json::{Object, ObjectExt, as_text, parse_object, stringify};
use crate::package_files::PackageFiles;
use crate::shared_scripts::SharedScripts;

/// A failure with the error kind of the shared engine ("transformError", "resourceLimit", …).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeError {
    pub kind: String,
    pub message: String,
}

impl RuntimeError {
    pub fn new(kind: &str, message: impl Into<String>) -> Self {
        Self { kind: kind.to_owned(), message: message.into() }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self::new("internalError", message)
    }
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "[{}] {}", self.kind, self.message)
    }
}

impl std::error::Error for RuntimeError {}

/// Output of preparing a package: transpiled entry, transpiled imports and the validated manifest.
#[derive(Debug, Clone, Default)]
pub struct PreparedPackage {
    pub code: String,
    /// Transpiled code, or the compiler's error record, by package path.
    pub imports: std::collections::HashMap<String, String>,
    pub manifest: Option<Object>,
    pub has_manifest: bool,
    pub action_id: Option<String>,
    /// In the order the compiler produced them.
    pub timeline_environment: Vec<(String, String)>,
}

impl PreparedPackage {
    pub fn to_json(&self) -> Value {
        let imports: Object = self.imports.iter().map(|(path, code)| (path.clone(), Value::String(code.clone()))).collect();
        let environment: Object = self.timeline_environment.iter().map(|(name, value)| (name.clone(), Value::String(value.clone()))).collect();
        json!({
            "code": self.code,
            "imports": imports,
            "manifest": self.manifest,
            "hasManifest": self.has_manifest,
            "actionID": self.action_id,
            "timelineEnvironment": environment,
        })
    }

    pub fn from_json(json: &Object) -> Result<Self, RuntimeError> {
        let strings = |name: &str| -> Vec<(String, String)> {
            json.opt_object(name).map(|map| map.iter().map(|(key, value)| (key.clone(), as_text(value).unwrap_or_default())).collect()).unwrap_or_default()
        };
        Ok(Self {
            code: json.opt_string_or_none("code").ok_or_else(|| RuntimeError::internal("Compiler returned no code"))?,
            imports: strings("imports").into_iter().collect(),
            manifest: json.opt_object("manifest").cloned(),
            has_manifest: json.opt_bool("hasManifest", false),
            action_id: if json.is_null("actionID") { None } else { Some(json.opt_string("actionID")) },
            timeline_environment: strings("timelineEnvironment"),
        })
    }
}

/// What to prepare besides the files themselves.
#[derive(Debug, Clone, Default)]
pub struct PrepareOptions<'a> {
    /// Entry file when it is not the manifest's.
    pub entry: Option<&'a str>,
    /// Trusted code evaluated before the entry; tests use it to fix the clock.
    pub prelude: &'a str,
    pub action_id: Option<&'a str>,
    pub call_function: Option<&'a str>,
}

const IDLE: Duration = Duration::from_secs(45);
const COMPILE_TIMEOUT_MILLISECONDS: u64 = 30_000;
const COMPILER_MEMORY: usize = 384 * 1024 * 1024;
const COMPILER_JS_STACK: usize = 12 * 1024 * 1024;
const COMPILER_THREAD_STACK: usize = 16 * 1024 * 1024;

struct Job {
    function: &'static str,
    arguments: Vec<String>,
    reply: Sender<Result<Option<String>, JsError>>,
}

/// The compiler context. Babel is expensive to load, so the context lives on
/// one dedicated thread and is released after a period of disuse. Package
/// code never executes in this context: it is only parsed and transformed.
pub struct PackageCompiler {
    jobs: Option<Sender<Job>>,
    worker: Option<JoinHandle<()>>,
}

impl PackageCompiler {
    pub fn new(scripts: Arc<SharedScripts>) -> std::io::Result<Self> {
        let (jobs, queue) = mpsc::channel::<Job>();
        let worker = std::thread::Builder::new().name("scriptwidget-compiler".into()).stack_size(COMPILER_THREAD_STACK).spawn(move || {
            let mut engine: Option<Engine<'static>> = None;
            loop {
                let job = if engine.is_some() {
                    match queue.recv_timeout(IDLE) {
                        Ok(job) => job,
                        Err(RecvTimeoutError::Timeout) => {
                            engine = None;
                            continue;
                        }
                        Err(RecvTimeoutError::Disconnected) => break,
                    }
                } else {
                    match queue.recv() {
                        Ok(job) => job,
                        Err(_) => break,
                    }
                };
                let current = match engine.take() {
                    Some(current) => current,
                    None => match create_engine(&scripts) {
                        Ok(created) => created,
                        Err(error) => {
                            let _ = job.reply.send(Err(error));
                            continue;
                        }
                    },
                };
                let mut current = current;
                current.set_deadline(COMPILE_TIMEOUT_MILLISECONDS);
                let arguments: Vec<Option<&str>> = job.arguments.iter().map(|argument| Some(argument.as_str())).collect();
                let result = current.call(job.function, &arguments);
                current.set_deadline(0);
                // An interrupted compile can leave Babel's own state half updated: start over next time.
                if !matches!(&result, Err(error) if error.interrupted) {
                    engine = Some(current);
                }
                let _ = job.reply.send(result);
            }
        })?;
        Ok(Self { jobs: Some(jobs), worker: Some(worker) })
    }

    fn call(&self, function: &'static str, arguments: Vec<String>) -> Result<Option<String>, JsError> {
        let stopped = || JsError { message: "The compiler thread has stopped".into(), interrupted: false };
        let (reply, answer) = mpsc::channel();
        self.jobs.as_ref().ok_or_else(stopped)?.send(Job { function, arguments, reply }).map_err(|_| stopped())?;
        answer.recv().map_err(|_| stopped())?
    }

    /// Validates and transpiles a package. The error carries the engine's error kind.
    pub fn prepare(&self, files: &dyn PackageFiles, options: &PrepareOptions<'_>) -> Result<PreparedPackage, RuntimeError> {
        let mut text = Object::new();
        let mut binaries = Vec::new();
        for path in files.paths() {
            match is_text_file(&path).then(|| files.read_text(&path)).flatten() {
                Some(content) => {
                    text.insert(path, Value::String(content));
                }
                None => binaries.push(Value::String(path)),
            }
        }
        let mut job = json!({ "files": text, "binaries": binaries, "prelude": options.prelude });
        for (name, value) in [("entry", options.entry), ("actionID", options.action_id), ("callFunction", options.call_function)] {
            if let Some(value) = value {
                job[name] = Value::String(value.to_owned());
            }
        }
        let output = self.call("__swPrepare", vec![stringify(&job)]).map_err(|error| {
            RuntimeError::new(if error.interrupted { "resourceLimit" } else { "internalError" }, if error.message.is_empty() { "Compiler failed".to_owned() } else { error.message })
        })?;
        let prepared = parse_object(&output.ok_or_else(|| RuntimeError::internal("Compiler returned nothing"))?).map_err(RuntimeError::internal)?;
        if !prepared.opt_bool("ok", false) {
            let error = prepared.opt_object("error");
            return Err(RuntimeError {
                kind: error.and_then(|error| error.opt_string_or_none("kind")).unwrap_or_else(|| "internalError".into()),
                message: error.and_then(|error| error.opt_string_or_none("message")).unwrap_or_else(|| "Package could not be prepared".into()),
            });
        }
        PreparedPackage::from_json(&prepared)
    }

    /// Returns {ok, manifest?, error?, issues[]} from the shared manifest validator.
    pub fn validate_manifest(&self, manifest_text: &str, paths: &[String]) -> Result<Object, RuntimeError> {
        let paths_text = stringify(&Value::Array(paths.iter().cloned().map(Value::String).collect()));
        self.object("__swValidateManifest", vec![manifest_text.to_owned(), paths_text])
    }

    /// Timeline plan for a `timeline` manifest object: {entries:[{date, environments}], reloadDate}.
    pub fn timeline_plan(&self, schedule: &Object, now_milliseconds: i64, system_time_zone: &str) -> Result<Object, RuntimeError> {
        self.object("__swTimeline", vec![crate::json::stringify_object(schedule), now_milliseconds.to_string(), system_time_zone.to_owned()])
    }

    fn object(&self, function: &'static str, arguments: Vec<String>) -> Result<Object, RuntimeError> {
        let output = self.call(function, arguments).map_err(|error| RuntimeError::new(if error.interrupted { "resourceLimit" } else { "internalError" }, error.message))?;
        parse_object(&output.ok_or_else(|| RuntimeError::internal("Compiler returned nothing"))?).map_err(RuntimeError::internal)
    }
}

impl Drop for PackageCompiler {
    fn drop(&mut self) {
        // Closing the queue ends the worker, which releases the engine on its own thread.
        self.jobs = None;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn create_engine(scripts: &SharedScripts) -> Result<Engine<'static>, JsError> {
    let host = |operation: &str, payload: Option<&str>| match operation {
        "url.parse" => Ok(parse_url(payload.unwrap_or(""))),
        _ => intl::call(operation, payload),
    };
    let mut engine = Engine::with_limits(host, COMPILER_MEMORY, COMPILER_JS_STACK)?;
    // The prelude captures the native entry point before the host file removes it.
    engine.evaluate(COMPILER_PRELUDE, "compiler-prelude.js")?;
    for name in ["host.js", "core.js", "prepare.js", "compiler.js"] {
        let text = scripts.text(name).map_err(|error| JsError { message: format!("ScriptWidget runtime asset could not be read: {error}"), interrupted: false })?;
        engine.evaluate(&text, name)?;
    }
    Ok(engine)
}

/// WHATWG components of the absolute URLs the manifest validator inspects, or `None`.
pub(crate) fn parse_url(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let url = url::Url::parse(trimmed).ok()?;
    let host = url.host_str().filter(|host| !host.is_empty())?;
    if matches!(url.scheme(), "mailto" | "urn" | "data" | "javascript" | "file") {
        return None;
    }
    Some(stringify(&json!({
        "href": trimmed,
        "protocol": format!("{}:", url.scheme()),
        "hostname": host.to_lowercase().trim_start_matches('[').trim_end_matches(']'),
        "port": url.port().map(|port| port.to_string()).unwrap_or_default(),
        "pathname": if url.path().is_empty() { "/" } else { url.path() },
        "search": url.query().map(|query| format!("?{query}")).unwrap_or_default(),
        "hash": url.fragment().map(|fragment| format!("#{fragment}")).unwrap_or_default(),
        "username": url.username(),
        "password": url.password().unwrap_or(""),
    })))
}

/// Text files are handed to the compiler; everything else only has to exist.
/// Same list as the Windows and Android hosts.
pub fn is_text_file(path: &str) -> bool {
    const EXTENSIONS: [&str; 14] = ["js", "jsx", "mjs", "json", "txt", "md", "csv", "svg", "xml", "htm", "html", "css", "yml", "yaml"];
    path.rsplit_once('.').is_some_and(|(_, extension)| EXTENSIONS.iter().any(|known| extension.eq_ignore_ascii_case(known)))
}

/// Globals the trusted compiler code expects. JavaScriptCore contexts have a
/// console object, and the shared manifest validator measures UTF-8 lengths
/// with TextEncoder. Package code never runs here.
const COMPILER_PRELUDE: &str = r#"
globalThis.console = { log() {}, info() {}, warn() {}, error() {}, debug() {}, trace() {} };
{
  const native = globalThis.__swNative;
  globalThis.URL = class URL {
    constructor(text) {
      const parsed = native("url.parse", String(text));
      if (parsed === null) throw new TypeError("Invalid URL");
      Object.assign(this, JSON.parse(parsed));
    }
    toString() { return this.href; }
  };
}
globalThis.TextEncoder = class TextEncoder {
  encode(text) {
    const bytes = [];
    for (const character of String(text ?? "")) {
      const code = character.codePointAt(0);
      if (code < 0x80) bytes.push(code);
      else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      else if (code < 0x10000) {
        const safe = code >= 0xd800 && code <= 0xdfff ? 0xfffd : code;
        bytes.push(0xe0 | (safe >> 12), 0x80 | ((safe >> 6) & 63), 0x80 | (safe & 63));
      } else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    }
    return new Uint8Array(bytes);
  }
};
"#;

#[cfg(test)]
mod tests {
    use super::{is_text_file, parse_url};

    #[test]
    fn recognizes_text_files_by_extension() {
        for path in ["main.jsx", "lib/util.JS", "data.json", "a.b.yaml", "page.htm", "notes.md"] {
            assert!(is_text_file(path), "{path}");
        }
        for path in ["image.png", "README", "archive.json.gz", "jsx"] {
            assert!(!is_text_file(path), "{path}");
        }
    }

    #[test]
    fn url_components_match_what_the_validator_reads() {
        let parsed: serde_json::Value = serde_json::from_str(&parse_url(" https://User:pw@API.Example.com:8443/v1/items?x=1#top ").unwrap()).unwrap();
        assert_eq!(parsed["href"], "https://User:pw@API.Example.com:8443/v1/items?x=1#top");
        assert_eq!(parsed["protocol"], "https:");
        assert_eq!(parsed["hostname"], "api.example.com");
        assert_eq!(parsed["port"], "8443");
        assert_eq!(parsed["pathname"], "/v1/items");
        assert_eq!(parsed["search"], "?x=1");
        assert_eq!(parsed["hash"], "#top");
        assert_eq!(parsed["username"], "User");
        assert_eq!(parsed["password"], "pw");
        let plain: serde_json::Value = serde_json::from_str(&parse_url("https://example.com").unwrap()).unwrap();
        assert_eq!((plain["port"].as_str(), plain["pathname"].as_str(), plain["search"].as_str()), (Some(""), Some("/"), Some("")));
        assert_eq!(parse_url("http://[::1]/").map(|text| serde_json::from_str::<serde_json::Value>(&text).unwrap()["hostname"].clone()), Some("::1".into()));
        for text in ["", "example.com", "/relative", "mailto:a@example.com", "file:///etc/passwd", "javascript:alert(1)", "data:text/plain,hi"] {
            assert_eq!(parse_url(text), None, "{text}");
        }
    }
}
