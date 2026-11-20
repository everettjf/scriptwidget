//! Runs the built `scriptwidget ai` commands against a stand-in for an AI
//! provider and a stand-in for the system keyring:
//!
//! - the provider is an HTTPS server on this machine that answers with what a
//!   test scripted, in the streamed form of the Anthropic Messages API, and
//!   records what it was sent;
//! - the keyring is a shell script named `secret-tool`, first in the `PATH`.
//!
//! Everything between the two is the real program: the profile, the key on
//! its way from standard input to the request header, the conversation, the
//! engine that runs each answer, the painter, and the package store.
//!
//! No test contacts a real provider or uses a real key.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-cli --test ai

#[path = "../../sw-core/tests/packages_support/mod.rs"]
mod support;

use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use support::TemporaryFolder;

const KEY: &str = "sk-cli-SECRET-4f1e9a77";
const EXIT_FAILED: i32 = 1;
const EXIT_USAGE: i32 = 2;

// A certificate for localhost and 127.0.0.1 that signs itself, made for these
// tests only (valid for a hundred years). The key protects nothing.
const CERTIFICATE: &str = "-----BEGIN CERTIFICATE-----
MIIBcjCCARigAwIBAgIJAMi4fZPY6DNuMAoGCCqGSM49BAMCMBQxEjAQBgNVBAMM
CWxvY2FsaG9zdDAgFw0yNjExMjAwMDM4MTlaGA8yMTI2MTAyNzAwMzgxOVowFDES
MBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE2zS7
0g8Il+r97xecnpp6UL0/MlRMRERjDqk8mtXrObQUiicJ8V7+3eZDStBsi0zB839F
9rDYwFKgdPQ5IwUOlaNRME8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAwG
A1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMB
MAoGCCqGSM49BAMCA0gAMEUCID6ltl/1YxdIAMqDXSY5pdURHpQbt5md1xXM7B5E
QteTAiEAoyxFXKOu9yZPthNi3ZHO8JdcjxSXwMTW1U78yJnQi6g=
-----END CERTIFICATE-----
";
const TEST_ONLY_KEY: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgByRcax2I4C4d5BGk
8TcnNDCQep8yCKR+UvkCyFSb1OOhRANCAATbNLvSDwiX6v3vF5yemnpQvT8yVExE
RGMOqTya1es5tBSKJwnxXv7d5kNK0GyLTMHzf0X2sNjAUqB09DkjBQ6V
-----END PRIVATE KEY-----
";

fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// What the stand-in provider answers next.
enum Reply {
    /// The text of the model, streamed.
    Text(String),
    /// A refusal with this status.
    Status(u16),
}

struct Provider {
    port: u16,
    /// Head and body of every request.
    requests: Arc<Mutex<Vec<String>>>,
}

impl Provider {
    /// Answers the requests with `replies`, in order; the last one again when they run out.
    fn start(replies: Vec<Reply>) -> Self {
        let certificate = CertificateDer::from_pem_slice(CERTIFICATE.as_bytes()).expect("certificate");
        let key = PrivateKeyDer::from_pem_slice(TEST_ONLY_KEY.as_bytes()).expect("key");
        let config = Arc::new(rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider())).with_safe_default_protocol_versions().unwrap().with_no_client_auth().with_single_cert(vec![certificate], key).expect("server configuration"));
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let port = listener.local_addr().unwrap().port();
        let requests: Arc<Mutex<Vec<String>>> = Arc::default();
        let seen = requests.clone();
        std::thread::spawn(move || {
            for socket in listener.incoming().flatten() {
                let Ok(connection) = rustls::ServerConnection::new(config.clone()) else { continue };
                let mut stream = rustls::StreamOwned::new(connection, socket);
                let Some(request) = read_request(&mut stream) else { continue };
                let index = {
                    let mut seen = seen.lock().unwrap();
                    seen.push(request);
                    seen.len() - 1
                };
                let response = match &replies[index.min(replies.len() - 1)] {
                    Reply::Status(status) => format!("HTTP/1.1 {status} Refused\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{{}}"),
                    Reply::Text(text) => {
                        let body = events(text);
                        format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\n\r\n{body}", body.len())
                    }
                };
                let _ = stream.write_all(response.as_bytes());
                stream.conn.send_close_notify();
                let _ = stream.flush();
            }
        });
        Self { port, requests }
    }

    fn url(&self) -> String {
        format!("https://127.0.0.1:{}", self.port)
    }

    fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }

    /// The JSON body of the request with this index.
    fn body(&self, index: usize) -> Value {
        let request = self.requests()[index].clone();
        serde_json::from_str(request.split_once("\r\n\r\n").expect("a body").1).expect("a JSON body")
    }

    /// The last message the model was sent in the request with this index.
    fn asked(&self, index: usize) -> String {
        self.body(index)["messages"].as_array().unwrap().last().unwrap()["content"].as_str().unwrap().to_owned()
    }
}

/// `text` as the Messages API streams it, a few characters an event.
fn events(text: &str) -> String {
    let mut body = String::from("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":120}}}\n\n");
    let characters: Vec<char> = text.chars().collect();
    for piece in characters.chunks(9) {
        let delta = json!({ "type": "content_block_delta", "index": 0, "delta": { "type": "text_delta", "text": piece.iter().collect::<String>() } });
        body.push_str(&format!("event: content_block_delta\ndata: {delta}\n\n"));
    }
    body.push_str("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":40}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
    body
}

fn read_request(stream: &mut impl Read) -> Option<String> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 8192];
    let end = loop {
        if let Some(end) = data.windows(4).position(|window| window == b"\r\n\r\n") {
            break end + 4;
        }
        match stream.read(&mut chunk) {
            Ok(count) if count > 0 => data.extend_from_slice(&chunk[..count]),
            _ => return None,
        }
    };
    let head = String::from_utf8_lossy(&data[..end]).into_owned();
    let length: usize = head.lines().filter_map(|line| line.split_once(':')).find(|(name, _)| name.eq_ignore_ascii_case("content-length")).and_then(|(_, value)| value.trim().parse().ok()).unwrap_or(0);
    while data.len() < end + length {
        match stream.read(&mut chunk) {
            Ok(count) if count > 0 => data.extend_from_slice(&chunk[..count]),
            _ => break,
        }
    }
    Some(String::from_utf8_lossy(&data).into_owned())
}

/// A reply in the form a turn asks for.
fn reply(note: &str, code: &str, declaration: Option<&str>) -> Reply {
    Reply::Text(format!("SUMMARY: {note}\n```jsx\n{code}\n```{}", declaration.map(|text| format!("\n```json\n{text}\n```")).unwrap_or_default()))
}

struct Outcome {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Outcome {
    #[track_caller]
    fn expect(&self, code: i32) -> Value {
        assert_eq!(self.code, code, "exit code\nstdout: {}\nstderr: {}", self.stdout, self.stderr);
        let report: Value = serde_json::from_str(&self.stdout).unwrap_or_else(|error| panic!("standard output is not one JSON report ({error}):\n{}\n{}", self.stdout, self.stderr));
        assert_eq!(report["reportVersion"], 1);
        assert_eq!(report["ok"], code == 0);
        report
    }
}

/// One isolated user: a home folder, a data folder, and a `PATH` that has the stand-in keyring or no keyring at all.
struct Sandbox {
    scratch: TemporaryFolder,
    keyring: bool,
}

impl Sandbox {
    fn new() -> Self {
        Self::with_keyring(true)
    }

    fn with_keyring(keyring: bool) -> Self {
        let scratch = TemporaryFolder::new();
        for folder in ["home", "work", "bin", "data"] {
            scratch.new_folder(folder);
        }
        std::fs::write(scratch.path("ca.pem"), CERTIFICATE).unwrap();
        if keyring {
            let program = scratch.path("bin/secret-tool");
            std::fs::write(
                &program,
                "#!/bin/sh\ndir=\"$(dirname \"$0\")\"\nprintf '%s\\n' \"$*\" >> \"$dir/arguments\"\nenv > \"$dir/environment\"\ncommand=\"$1\"\nfor last; do :; done\ncase \"$command\" in\n  store) cat > \"$dir/item-$last\" ;;\n  lookup) [ -f \"$dir/item-$last\" ] || exit 1; cat \"$dir/item-$last\" ;;\n  clear) [ -f \"$dir/item-$last\" ] || exit 1; rm -f \"$dir/item-$last\" ;;\nesac\n",
            )
            .unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        Self { scratch, keyring }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.scratch.path(relative)
    }

    fn data(&self) -> PathBuf {
        self.path("data")
    }

    /// A command with nothing inherited. Its certificate authorities are the one of the stand-in provider and nothing else.
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_scriptwidget"));
        command.env_clear();
        command.env("HOME", self.path("home")).env("SCRIPTWIDGET_DATA", self.data()).env("TZ", "UTC").env("LANG", "en_US.UTF-8");
        command.env("SCRIPTWIDGET_RUNTIME_ASSETS", repository().join("Linux/assets/scriptwidget")).env("SCRIPTWIDGET_TEMPLATES", repository().join("Shared/ScriptWidgetRuntime/Resource/Script.bundle"));
        command.env("SSL_CERT_FILE", self.path("ca.pem"));
        // The stand-in script needs sh, cat, rm, env and dirname; nothing else is found.
        command.env("PATH", if self.keyring { format!("{}:/usr/bin:/bin", self.path("bin").display()) } else { self.path("bin").display().to_string() });
        command.current_dir(self.path("work"));
        command
    }

    fn run(&self, arguments: &[&str]) -> Outcome {
        self.finish(self.command().args(arguments), None)
    }

    fn run_with_input(&self, arguments: &[&str], input: &str) -> Outcome {
        self.finish(self.command().args(arguments), Some(input))
    }

    /// Runs the command. Whatever it does, the key is in nothing it prints.
    fn finish(&self, command: &mut Command, input: Option<&str>) -> Outcome {
        command.stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn().expect("the scriptwidget program");
        if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
            stdin.write_all(input.as_bytes()).unwrap();
        }
        let output = child.wait_with_output().unwrap();
        let outcome = Outcome { code: output.status.code().unwrap_or(-1), stdout: String::from_utf8_lossy(&output.stdout).into_owned(), stderr: String::from_utf8_lossy(&output.stderr).into_owned() };
        assert!(!outcome.stdout.contains(KEY) && !outcome.stderr.contains(KEY), "the key was printed:\n{}\n{}", outcome.stdout, outcome.stderr);
        outcome
    }

    /// Points the profile at the stand-in provider and stores the key in the stand-in keyring.
    fn configure(&self, provider: &Provider) {
        self.run(&["ai", "set", "--provider", "anthropic", "--base-url", &provider.url(), "--model", "test-model"]).expect(0);
        self.run_with_input(&["ai", "key", "set"], &format!("{KEY}\n")).expect(0);
    }

    /// The text of a file of an installed widget.
    fn installed(&self, package: &str, file: &str) -> String {
        std::fs::read_to_string(self.data().join("Packages").join(package).join(file)).unwrap_or_else(|error| panic!("{package}/{file}: {error}"))
    }

    /// Every file below the data folder with its text.
    fn data_files(&self) -> Vec<(String, String)> {
        fn walk(folder: &Path, root: &Path, found: &mut Vec<(String, String)>) {
            for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, root, found);
                } else {
                    found.push((path.strip_prefix(root).unwrap().display().to_string(), String::from_utf8_lossy(&std::fs::read(&path).unwrap_or_default()).into_owned()));
                }
            }
        }
        let mut found = Vec::new();
        walk(&self.data(), &self.data(), &mut found);
        found
    }

    #[track_caller]
    fn assert_no_key_on_disk(&self) {
        for (name, text) in self.data_files() {
            assert!(!text.contains(KEY), "{name} holds the key");
        }
        for folder in ["home", "work"] {
            assert_eq!(std::fs::read_dir(self.path(folder)).unwrap().count(), 0, "{folder} was written to");
        }
    }
}

const CLOCK: &str = "$render(\n  <vstack frame=\"max\" background=\"#0f172a\" padding=\"12\">\n    <text font=\"title\" color=\"white\">12:00</text>\n    <text font=\"caption\" color=\"#94a3b8\">Monday</text>\n  </vstack>\n);";

#[test]
fn the_profile_is_set_and_shown_and_plain_http_is_refused() {
    let sandbox = Sandbox::new();
    let first = sandbox.run(&["ai", "show"]).expect(0);
    assert_eq!((&first["command"], &first["saved"], &first["profile"]["provider"], &first["key"]["available"]), (&json!("ai show"), &json!(false), &json!("anthropic"), &json!(false)));

    let set = sandbox.run(&["ai", "set", "--provider", "custom", "--base-url", "https://ollama.lan:8443/v1/", "--model", "llama3", "--max-iterations", "8", "--temperature", "0.2"]).expect(0);
    assert_eq!(set["profile"], json!({"provider":"custom","providerName":"OpenAI-compatible","baseUrl":"https://ollama.lan:8443","model":"llama3","maxIterations":8,"temperature":0.2,"configured":true,"problem":null,"suggestedModels":[]}));
    let shown = sandbox.run(&["ai", "show"]).expect(0);
    assert_eq!((&shown["saved"], &shown["profile"]["baseUrl"]), (&json!(true), &json!("https://ollama.lan:8443")));
    // Another provider starts from its own endpoint and model.
    assert_eq!(sandbox.run(&["ai", "set", "--provider", "openai"]).expect(0)["profile"]["baseUrl"], "https://api.openai.com");

    // As on Android the endpoint is HTTPS, also on this machine: the request carries the key.
    for url in ["http://localhost:11434", "http://127.0.0.1:11434/v1", "http://api.example.com", "https://user:secret@api.example.com", "https://api.example.com/v1/chat/completions", "api.example.com"] {
        let refused = sandbox.run(&["ai", "set", "--provider", "custom", "--base-url", url, "--model", "m"]).expect(EXIT_USAGE);
        assert_eq!(refused["error"]["kind"], "usage", "{url}");
    }
    assert!(sandbox.run(&["ai", "set", "--base-url", "http://localhost:11434"]).expect(EXIT_USAGE)["error"]["message"].as_str().unwrap().contains("https://"));
    for arguments in [&["ai", "set", "--provider", "oauth"][..], &["ai", "set", "--max-iterations", "1000"], &["ai", "set", "--temperature", "hot"], &["ai", "set", "--provider", "custom"], &["ai", "bogus"], &["ai", "key", "set", "typed-on-the-command-line"], &["ai", "set", "--key", "x"]] {
        sandbox.run(arguments).expect(EXIT_USAGE);
    }
    assert_eq!(sandbox.run(&["ai", "show"]).expect(0)["profile"]["provider"], "openai", "a refused change changes nothing");
    let help = sandbox.run(&["ai", "--help"]);
    assert!(help.code == 0 && help.stdout.contains("scriptwidget ai <command>") && help.stdout.contains("SCRIPTWIDGET_AI_KEY"));
    assert!(sandbox.run(&["--help"]).stdout.contains("ai new <request>"));
}

#[test]
fn the_key_goes_from_standard_input_to_the_keyring_and_nowhere_else() {
    let sandbox = Sandbox::new();
    let stored = sandbox.run_with_input(&["ai", "key", "set"], &format!("{KEY}\n")).expect(0);
    assert_eq!((&stored["command"], &stored["provider"], &stored["stored"]), (&json!("ai key set"), &json!("anthropic"), &json!(true)));
    assert_eq!(std::fs::read_to_string(sandbox.path("bin/item-anthropic")).unwrap(), KEY, "the stand-in keyring got exactly the key, on its standard input");
    let arguments = std::fs::read_to_string(sandbox.path("bin/arguments")).unwrap();
    assert!(!arguments.contains(KEY), "{arguments}");
    assert!(!std::fs::read_to_string(sandbox.path("bin/environment")).unwrap().contains(KEY));
    sandbox.assert_no_key_on_disk();

    assert_eq!(sandbox.run(&["ai", "show"]).expect(0)["key"], json!({ "available": true, "source": "keyring" }));
    // A key for another provider is its own.
    sandbox.run_with_input(&["ai", "key", "set", "--provider", "openai"], "another-key").expect(0);
    assert_eq!(std::fs::read_to_string(sandbox.path("bin/item-openai")).unwrap(), "another-key");
    for bad in ["", "\n", "two\nlines\n", "caf\u{e9}"] {
        assert_eq!(sandbox.run_with_input(&["ai", "key", "set"], bad).expect(EXIT_USAGE)["error"]["kind"], "ai.key_invalid", "{bad:?}");
    }
    assert_eq!(std::fs::read_to_string(sandbox.path("bin/item-anthropic")).unwrap(), KEY, "a refused key replaces nothing");

    let removed = sandbox.run(&["ai", "key", "remove"]).expect(0);
    assert_eq!((&removed["command"], &removed["removed"]), (&json!("ai key remove"), &json!(true)));
    assert_eq!(sandbox.run(&["ai", "key", "remove"]).expect(0)["removed"], false);
    assert_eq!(sandbox.run(&["ai", "show"]).expect(0)["key"]["available"], false);
    // Without a key nothing is sent anywhere.
    let provider = Provider::start(vec![reply("x", CLOCK, None)]);
    sandbox.run(&["ai", "set", "--base-url", &provider.url(), "--model", "m"]).expect(0);
    assert_eq!(sandbox.run(&["ai", "new", "a clock"]).expect(EXIT_USAGE)["error"]["kind"], "ai.no_key");
    assert!(provider.requests().is_empty());
}

#[test]
fn without_a_keyring_the_key_is_not_stored_and_one_run_can_bring_its_own() {
    let sandbox = Sandbox::with_keyring(false);
    let refused = sandbox.run_with_input(&["ai", "key", "set"], KEY).expect(EXIT_USAGE);
    assert_eq!(refused["error"]["kind"], "ai.keyring_unavailable");
    let message = refused["error"]["message"].as_str().unwrap();
    assert!(message.contains("secret-tool") && message.contains("Nothing was stored") && message.contains("SCRIPTWIDGET_AI_KEY"), "{message}");
    sandbox.assert_no_key_on_disk();
    let shown = sandbox.run(&["ai", "show"]).expect(0);
    assert_eq!(shown["key"]["available"], false);
    assert!(shown["key"]["problem"].as_str().unwrap().contains("secret-tool"));

    let provider = Provider::start(vec![reply("Shows the time.", CLOCK, None)]);
    sandbox.run(&["ai", "set", "--base-url", &provider.url(), "--model", "test-model"]).expect(0);
    assert_eq!(sandbox.run(&["ai", "new", "a clock"]).expect(EXIT_USAGE)["error"]["kind"], "ai.keyring_unavailable", "no key is made up");
    assert!(provider.requests().is_empty());

    // The key of one run: used for the request, and in no file afterwards.
    assert_eq!(sandbox.finish(sandbox.command().env("SCRIPTWIDGET_AI_KEY", KEY).args(["ai", "show"]), None).expect(0)["key"]["source"], "environment");
    let made = sandbox.finish(sandbox.command().env("SCRIPTWIDGET_AI_KEY", KEY).args(["ai", "new", "a clock", "--name", "Clock", "--quiet"]), None).expect(0);
    assert_eq!((&made["applied"], &made["package"]["name"]), (&json!(true), &json!("Clock")));
    assert!(provider.requests()[0].to_lowercase().contains(&format!("x-api-key: {}", KEY.to_lowercase())), "the key was sent in the header");
    sandbox.assert_no_key_on_disk();
    assert_eq!(sandbox.run(&["ai", "show"]).expect(0)["key"]["available"], false, "it was not saved");
    let invalid = sandbox.finish(sandbox.command().env("SCRIPTWIDGET_AI_KEY", "two\nlines").args(["ai", "new", "a clock"]), None).expect(EXIT_USAGE);
    assert_eq!(invalid["error"]["kind"], "ai.key_invalid");
}

#[test]
fn a_new_widget_is_made_repaired_by_the_engine_and_installed() {
    let sandbox = Sandbox::new();
    let provider = Provider::start(vec![reply("Shows the time.", "$render(<vstack><text>12:00</text></vstac>);", None), reply("Shows the time.", CLOCK, None)]);
    sandbox.configure(&provider);
    let outcome = sandbox.run(&["ai", "new", "a clock\nwith the weekday", "--name", "Clock", "--family", "small"]);
    let report = outcome.expect(0);
    assert_eq!((&report["command"], &report["applied"]), (&json!("ai new"), &json!(true)));
    assert_eq!((&report["turn"]["status"], &report["turn"]["repairs"], &report["turn"]["note"]), (&json!("succeeded"), &json!(1), &json!("Shows the time.")));
    assert_eq!(report["turn"]["usage"], json!({ "promptTokens": 240, "completionTokens": 80, "totalTokens": 320 }));
    assert_eq!((&report["version"]["number"], &report["version"]["source"], &report["changes"]), (&json!(1), &json!(format!("{CLOCK}\n")), &Value::Null));
    assert_eq!((&report["conversation"]["size"], &report["conversation"]["title"]), (&json!("small"), &json!("a clock")));

    // The reply was written to standard error as it arrived, with a line for each attempt.
    for line in ["ai: attempt 1: waiting for the model", "SUMMARY: Shows the time.", "ai: attempt 1: running the widget", "ai: attempt 1: it did not pass: scriptException: SyntaxError", "ai: attempt 2: the widget runs", "<text font=\"title\" color=\"white\">12:00</text>"] {
        assert!(outcome.stderr.contains(line), "{line:?} in\n{}", outcome.stderr);
    }

    // What the provider was sent: the key in the header, a streamed request, the rules for Linux, and for the repair what the engine said.
    let requests = provider.requests();
    assert_eq!(requests.len(), 2);
    let head = requests[0].split("\r\n\r\n").next().unwrap().to_lowercase();
    assert!(requests[0].starts_with("POST /v1/messages HTTP/1.1\r\n"));
    for line in [format!("x-api-key: {}", KEY.to_lowercase()), "anthropic-version: 2023-06-01".into(), "accept: text/event-stream".into(), format!("host: 127.0.0.1:{}", provider.port)] {
        assert!(head.contains(&line), "{line}");
    }
    let first = provider.body(0);
    assert_eq!((&first["model"], &first["stream"]), (&json!("test-model"), &json!(true)));
    let system = first["system"].as_str().unwrap();
    assert!(system.contains("ScriptWidget for Linux") && system.contains("NOT SUPPORTED ON LINUX") && system.contains("// === vstack ==="), "the system prompt has the rules, the limits of Linux and the bundled examples");
    assert!(!system.contains("// === health ===") && !system.contains(KEY));
    assert!(provider.asked(0).contains("The user asks for a new widget:\na clock\nwith the weekday") && provider.asked(0).contains("Widget size: small"));
    assert!(provider.asked(1).contains("Runtime feedback:\nscriptException: SyntaxError") && provider.asked(1).contains("Keep the reply form of this conversation"));
    assert!(!requests.iter().any(|request| request.split_once("\r\n\r\n").unwrap().1.contains(KEY)), "the key is in no body");

    // The widget is in the library like any other, and runs.
    assert_eq!(sandbox.installed("Clock", "main.jsx"), format!("{CLOCK}\n"));
    let manifest: Value = serde_json::from_str(&sandbox.installed("Clock", "widget.json")).unwrap();
    assert_eq!((&manifest["name"], &manifest["permissions"], &manifest["networkDomains"]), (&json!("Clock"), &json!([]), &json!([])));
    let listed = sandbox.run(&["list"]).expect(0);
    assert_eq!(listed["packages"][0]["name"], "Clock");
    assert_eq!(listed["packages"][0]["installation"], report["package"]["installation"]);
    let directory = report["package"]["directory"].as_str().unwrap();
    assert_eq!(sandbox.run(&["run", directory]).expect(0)["tree"]["$element"], "vstack");
    let drawn = sandbox.run(&["render", directory, "--output", sandbox.path("clock.png").to_str().unwrap()]).expect(0);
    assert!(drawn["picture"]["colors"].as_u64() > Some(1));

    // The conversation is a file of its own, tied to the widget, with no key and no provider in it.
    let conversations = sandbox.run(&["ai", "conversations"]).expect(0);
    assert_eq!(conversations["conversations"].as_array().unwrap().len(), 1);
    assert_eq!((&conversations["conversations"][0]["package"], &conversations["conversations"][0]["draft"]), (&json!("Clock"), &json!(false)));
    let id = report["conversation"]["id"].as_str().unwrap();
    let shown = sandbox.run(&["ai", "conversations", id]).expect(0);
    assert_eq!((&shown["turns"][0]["request"], &shown["versions"][0]["source"]), (&json!("a clock\nwith the weekday"), &json!(format!("{CLOCK}\n"))));
    let files = sandbox.data_files();
    let (_, conversation) = files.iter().find(|(name, _)| name.starts_with("AiConversations/")).expect("a conversation file");
    assert!(!conversation.contains("test-model") && !conversation.contains("127.0.0.1") && !conversation.contains("anthropic"), "a conversation names no provider");
    sandbox.assert_no_key_on_disk();
}

#[test]
fn a_conversation_continues_on_an_installed_widget_and_asks_before_new_hosts() {
    let sandbox = Sandbox::new();
    let edit = "SUMMARY: The time is red now.\n```edit\n<<<<<<< SEARCH\n    <text font=\"title\" color=\"white\">12:00</text>\n=======\n    <text font=\"title\" color=\"#ef4444\">12:00</text>\n>>>>>>> REPLACE\n```";
    let online = CLOCK.replace("$render(", "let place = 'offline';\ntry { place = await fetch('https://api.example.com/place'); } catch (error) { place = 'no network'; }\n$render(");
    let provider = Provider::start(vec![reply("Shows the time.", CLOCK, None), Reply::Text(edit.into()), reply("Asks where you are.", &online, Some(r#"{"permissions":["network"],"networkDomains":["API.example.com"]}"#))]);
    sandbox.configure(&provider);
    sandbox.run(&["ai", "new", "a clock", "--name", "Clock", "--quiet"]).expect(0);

    // The second turn changes one place; the model was shown the code and what was said before.
    let second = sandbox.run(&["ai", "continue", "Clock", "make the time red", "--quiet"]).expect(0);
    assert_eq!((&second["command"], &second["applied"], &second["turn"]["note"], &second["version"]["number"]), (&json!("ai continue"), &json!(true), &json!("The time is red now."), &json!(2)));
    assert_eq!((&second["changes"]["added"], &second["changes"]["removed"]), (&json!(1), &json!(1)));
    assert!(second["changes"]["lines"].as_array().unwrap().iter().any(|line| line["kind"] == "added" && line["text"].as_str().unwrap().contains("#ef4444")));
    assert_eq!(sandbox.installed("Clock", "main.jsx"), format!("{}\n", CLOCK.replace("color=\"white\">12:00", "color=\"#ef4444\">12:00")));
    let asked = provider.asked(1);
    assert!(asked.contains("1. User: a clock\n   You: Shows the time.") && asked.contains("Current working widget code:\n\n```jsx\n$render(") && asked.contains("The user now asks:\nmake the time red") && asked.contains("<<<<<<< SEARCH"), "{asked}");

    // The third turn wants the network. The widget runs with the host for the trial, but the installed widget is not changed without a yes.
    let before = (sandbox.installed("Clock", "main.jsx"), sandbox.installed("Clock", "widget.json"));
    let third = sandbox.run(&["ai", "continue", "Clock", "say where I am", "--quiet"]).expect(EXIT_USAGE);
    assert_eq!((&third["error"]["kind"], &third["applied"], &third["newHosts"], &third["turn"]["status"]), (&json!("ai.new_hosts"), &json!(false), &json!(["api.example.com"]), &json!("succeeded")));
    assert!(third["error"]["message"].as_str().unwrap().contains("api.example.com"));
    assert_eq!((sandbox.installed("Clock", "main.jsx"), sandbox.installed("Clock", "widget.json")), before, "nothing was changed");
    assert_eq!(sandbox.run(&["ai", "apply", "Clock"]).expect(EXIT_USAGE)["error"]["kind"], "ai.new_hosts");
    let applied = sandbox.run(&["ai", "apply", "Clock", "--allow-new-hosts"]).expect(0);
    assert_eq!((&applied["applied"], &applied["version"]["number"], &applied["newHosts"]), (&json!(true), &json!(3), &json!(["api.example.com"])));
    assert!(sandbox.installed("Clock", "main.jsx").contains("api.example.com/place"));
    let manifest: Value = serde_json::from_str(&sandbox.installed("Clock", "widget.json")).unwrap();
    assert_eq!((&manifest["permissions"], &manifest["networkDomains"], &manifest["name"]), (&json!(["network"]), &json!(["api.example.com"]), &json!("Clock")));

    // An older version can be put back; the conversation keeps all three.
    assert_eq!(sandbox.run(&["ai", "apply", "Clock", "--version", "1"]).expect(0)["applied"], true);
    assert_eq!(sandbox.installed("Clock", "main.jsx"), format!("{CLOCK}\n"));
    let manifest: Value = serde_json::from_str(&sandbox.installed("Clock", "widget.json")).unwrap();
    assert_eq!(manifest["networkDomains"], json!(["api.example.com"]), "a conversation takes no host away from a widget");
    assert_eq!(sandbox.run(&["ai", "apply", "Clock", "--version", "9"]).expect(EXIT_FAILED)["error"]["kind"], "ai.no_version");
    assert_eq!(sandbox.run(&["ai", "apply", "Clock", "--name", "Other"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    assert_eq!(sandbox.run(&["ai", "continue", "No Such Widget", "x"]).expect(EXIT_FAILED)["error"]["kind"], "package_not_found");
    assert_eq!(provider.requests().len(), 3);
    sandbox.assert_no_key_on_disk();
}

#[test]
fn a_widget_that_was_not_made_here_can_be_talked_about_and_a_draft_installed_later() {
    let sandbox = Sandbox::new();
    let provider = Provider::start(vec![reply("Bigger text.", &CLOCK.replace("font=\"title\"", "font=\"largeTitle\""), None), reply("A quote.", "$render(<vstack><text>Stay curious.</text></vstack>);", None)]);
    sandbox.configure(&provider);
    // A widget written by hand, with a second file.
    let folder = sandbox.path("src/Hand");
    std::fs::create_dir_all(folder.join("lib")).unwrap();
    std::fs::write(folder.join("main.jsx"), CLOCK).unwrap();
    std::fs::write(folder.join("lib/notes.js"), "// mine\n").unwrap();
    sandbox.run(&["install", folder.to_str().unwrap()]).expect(0);

    let changed = sandbox.run(&["ai", "continue", "Hand", "bigger text", "--quiet"]).expect(0);
    assert_eq!((&changed["applied"], &changed["version"]["number"]), (&json!(true), &json!(2)), "the code the widget had is version 1");
    assert!(provider.asked(0).contains(CLOCK) && !provider.asked(0).contains("Earlier turns"), "the hand-written code was sent, and is not a turn");
    assert!(sandbox.installed("Hand", "main.jsx").contains("largeTitle"));
    assert_eq!(sandbox.installed("Hand", "lib/notes.js"), "// mine\n", "the other files are as they were");

    // A draft: nothing is installed until asked.
    let draft = sandbox.run(&["ai", "new", "a quote", "--no-apply", "--events"]);
    let report = draft.expect(0);
    assert_eq!((&report["applied"], &report["turn"]["status"]), (&json!(false), &json!("succeeded")));
    let events: Vec<Value> = draft.stderr.lines().map(|line| serde_json::from_str(line).unwrap_or_else(|_| panic!("not an event: {line}"))).collect();
    assert_eq!(events.first().unwrap()["event"], "thinking");
    assert_eq!(events.iter().filter(|event| event["event"] == "reply").map(|event| event["text"].as_str().unwrap()).collect::<String>(), "SUMMARY: A quote.\n```jsx\n$render(<vstack><text>Stay curious.</text></vstack>);\n```");
    assert_eq!(events.last().unwrap()["event"], "succeeded");
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"].as_array().unwrap().len(), 1);
    let id = report["conversation"]["id"].as_str().unwrap();
    let listed = sandbox.run(&["ai", "conversations"]).expect(0);
    assert!(listed["conversations"].as_array().unwrap().iter().any(|item| item["id"] == id && item["draft"] == true));
    assert_eq!(sandbox.run(&["ai", "apply", id, "--name", "../escape"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    let installed = sandbox.run(&["ai", "apply", id, "--name", "Quote"]).expect(0);
    assert_eq!((&installed["applied"], &installed["package"]["name"]), (&json!(true), &json!("Quote")));
    assert!(sandbox.installed("Quote", "main.jsx").contains("Stay curious."));
    assert_eq!(sandbox.run(&["ai", "conversations", id]).expect(0)["conversation"]["package"], "Quote", "the draft now belongs to the widget");
    assert_eq!(sandbox.run(&["ai", "apply", "0000-not-a-conversation"]).expect(EXIT_FAILED)["error"]["kind"], "ai.no_conversation");
}

/// The hosts a widget contacts are the model's choice, so a widget that uses the network is installed only with a yes.
#[test]
fn a_new_widget_that_uses_the_network_is_a_draft_until_its_hosts_are_allowed() {
    let sandbox = Sandbox::new();
    let online = format!("let text = 'offline';\ntry {{ text = await fetch('https://api.example.com/quote'); }} catch (error) {{ text = 'no network'; }}\n{}", CLOCK.replace("12:00", "{text}"));
    let declaration = r#"{"permissions":["network"],"networkDomains":["api.example.com"]}"#;
    let provider = Provider::start(vec![reply("Shows a quote.", &online, Some(declaration))]);
    sandbox.configure(&provider);
    let kept = sandbox.run(&["ai", "new", "a quote from api.example.com", "--name", "Quote", "--quiet"]).expect(EXIT_USAGE);
    assert_eq!((&kept["error"]["kind"], &kept["applied"], &kept["newHosts"], &kept["turn"]["status"], &kept["version"]["networkDomains"]), (&json!("ai.new_hosts"), &json!(false), &json!(["api.example.com"]), &json!("succeeded"), &json!(["api.example.com"])));
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"], json!([]));
    let id = kept["conversation"]["id"].as_str().unwrap();
    assert!(kept["error"]["message"].as_str().unwrap().contains(id), "the message says how to install it");
    assert_eq!(sandbox.run(&["ai", "apply", id, "--name", "Quote"]).expect(EXIT_USAGE)["error"]["kind"], "ai.new_hosts");
    let installed = sandbox.run(&["ai", "apply", id, "--name", "Quote", "--allow-new-hosts"]).expect(0);
    assert_eq!((&installed["applied"], &installed["package"]["name"]), (&json!(true), &json!("Quote")));
    let manifest: Value = serde_json::from_str(&sandbox.installed("Quote", "widget.json")).unwrap();
    assert_eq!((&manifest["permissions"], &manifest["networkDomains"]), (&json!(["network"]), &json!(["api.example.com"])));
    // Said up front, it is installed at once. A declaration the model may not make installs nothing and grants nothing.
    let again = sandbox.run(&["ai", "new", "a quote", "--name", "Second", "--quiet", "--allow-new-hosts"]).expect(0);
    assert_eq!((&again["applied"], &again["package"]["name"]), (&json!(true), &json!("Second")));
    let greedy = Provider::start(vec![reply("Reads everything.", CLOCK, Some(r#"{"permissions":["network","health"],"networkDomains":["localhost"]}"#))]);
    sandbox.run(&["ai", "set", "--base-url", &greedy.url()]).expect(0);
    let refused = sandbox.run(&["ai", "new", "x", "--name", "Greedy", "--quiet", "--allow-new-hosts"]).expect(EXIT_FAILED);
    assert_eq!((&refused["error"]["kind"], &refused["applied"]), (&json!("ai.unconverged"), &json!(false)));
    assert!(greedy.asked(1).contains("Invalid package declaration"));
    assert!(!sandbox.data().join("Packages/Greedy").exists());
}

#[test]
fn what_never_runs_is_not_installed_and_a_refusal_is_reported_without_the_key() {
    let sandbox = Sandbox::new();
    // A model that writes to the terminal, uses what Linux lacks, and never produces a widget that runs.
    let hostile = "SUMMARY: \u{1b}]0;owned\u{7}Reads your steps.\u{1b}[2J\n```jsx\nconst steps = await $health.steps();\n$render(<vstack><text>{String(steps)}</text></vstack>);\n```";
    let provider = Provider::start(vec![Reply::Text(hostile.into())]);
    sandbox.configure(&provider);
    let outcome = sandbox.run(&["ai", "new", "my steps", "--name", "Steps"]);
    let report = outcome.expect(EXIT_FAILED);
    assert_eq!((&report["error"]["kind"], &report["applied"], &report["turn"]["status"], &report["turn"]["repairs"]), (&json!("ai.unconverged"), &json!(false), &json!("unconverged"), &json!(4)));
    assert!(report["turn"]["failedSource"].as_str().unwrap().contains("$health.steps()"), "the last attempt is kept for the user to look at");
    assert_eq!(provider.requests().len(), 4, "one attempt and three repairs");
    assert!(provider.asked(1).contains("$health is not implemented here"), "the model is told why: {}", provider.asked(1));
    assert!(!outcome.stderr.contains('\u{1b}') && !outcome.stderr.contains('\u{7}') && !outcome.stdout.contains('\u{1b}'), "no control character of the model reached the terminal");
    assert!(outcome.stderr.contains("Reads your steps."));
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"], json!([]));
    assert!(!sandbox.data().join("Packages/Steps").exists());

    // The provider refuses the key: said in a fixed sentence, and nothing is installed.
    let refusing = Provider::start(vec![Reply::Status(401)]);
    sandbox.run(&["ai", "set", "--base-url", &refusing.url()]).expect(0);
    let refused = sandbox.run(&["ai", "new", "a clock"]).expect(EXIT_USAGE);
    assert_eq!((&refused["error"]["kind"], &refused["turn"]["status"]), (&json!("ai.request_failed"), &json!("failed")));
    assert!(refused["error"]["message"].as_str().unwrap().contains("rejected authentication"));
    let models = sandbox.run(&["ai", "models"]).expect(EXIT_USAGE);
    assert_eq!(models["error"]["kind"], "ai.http");
    // A redirect is not followed, and a server nobody runs is a network error, not a hang.
    let closed = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    sandbox.run(&["ai", "set", "--base-url", &format!("https://127.0.0.1:{closed}")]).expect(0);
    assert_eq!(sandbox.run(&["ai", "models"]).expect(EXIT_USAGE)["error"]["kind"], "ai.network");
    sandbox.assert_no_key_on_disk();
}
