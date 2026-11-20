//! Runs the built `scriptwidget` program against temporary folders: every
//! command that needs no background service, the exit codes, the report
//! shapes, and the archive and path rules as they are reached through the
//! command line.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-cli
//!
//! Every run starts from an empty environment: no `DISPLAY`, no
//! `WAYLAND_DISPLAY`, a home folder of its own.

#[path = "../../sw-core/tests/packages_support/mod.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;
use support::{RawEntry, SYMBOLIC_LINK, TemporaryFolder, raw_zip, read_zip};

const EXIT_FAILED: i32 = 1;
const EXIT_USAGE: i32 = 2;
const EXIT_NEEDS_SERVICE: i32 = 69;

/// 2026-01-01 12:00 UTC.
const FIXED_NOW: &str = "1767268800000";

fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn runtime_assets() -> PathBuf {
    repository().join("Linux/assets/scriptwidget")
}

fn bundled_templates() -> PathBuf {
    repository().join("Shared/ScriptWidgetRuntime/Resource/Script.bundle")
}

struct Outcome {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Outcome {
    #[track_caller]
    fn report(&self) -> Value {
        let report: Value = serde_json::from_str(&self.stdout).unwrap_or_else(|error| panic!("standard output is not one JSON report ({error}):\n{}\n{}", self.stdout, self.stderr));
        assert_eq!(report["reportVersion"], 1);
        assert!(!self.stdout.contains('\u{1b}') && !self.stderr.contains('\u{1b}'), "no color codes when the output is not a terminal");
        let status = match self.code {
            0 => "passed",
            1 => "failed",
            _ => "error",
        };
        assert_eq!(report["status"], status, "status follows the exit code {}:\n{}", self.code, self.stdout);
        assert_eq!(report["ok"], self.code == 0);
        report
    }

    #[track_caller]
    fn expect(&self, code: i32) -> Value {
        assert_eq!(self.code, code, "exit code\nstdout: {}\nstderr: {}", self.stdout, self.stderr);
        self.report()
    }
}

/// One isolated user: a home folder, a data folder and a working folder.
struct Sandbox {
    scratch: TemporaryFolder,
}

impl Sandbox {
    fn new() -> Self {
        let scratch = TemporaryFolder::new();
        for folder in ["home", "work"] {
            scratch.new_folder(folder);
        }
        Self { scratch }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.scratch.path(relative)
    }

    fn work(&self) -> PathBuf {
        self.path("work")
    }

    fn data(&self) -> PathBuf {
        self.path("data")
    }

    /// A command with nothing inherited: in particular no display of any kind.
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_scriptwidget"));
        command.env_clear().env_remove("DISPLAY").env_remove("WAYLAND_DISPLAY");
        command.env("HOME", self.path("home")).env("SCRIPTWIDGET_DATA", self.data()).env("TZ", "UTC").env("LANG", "en_US.UTF-8");
        command.env("SCRIPTWIDGET_RUNTIME_ASSETS", runtime_assets()).env("SCRIPTWIDGET_TEMPLATES", bundled_templates());
        command.current_dir(self.work());
        command
    }

    fn run(&self, arguments: &[&str]) -> Outcome {
        finish(self.command().args(arguments))
    }

    /// A package folder in the working folder, with a Package 2.0 manifest.
    fn package(&self, name: &str, source: &str) -> PathBuf {
        let directory = self.scratch.new_folder(&format!("work/{name}"));
        self.scratch.new_file(&format!("work/{name}/main.jsx"), source);
        self.scratch.new_file(&format!("work/{name}/widget.json"), &manifest(name, ""));
        directory
    }
}

fn finish(command: &mut Command) -> Outcome {
    // A test that has just copied the program can find it "busy": while the copy
    // was being written another test started a child, and that child still holds
    // the file open for writing for a moment. Wait for it instead of failing.
    let mut tries = 0;
    let output = loop {
        match command.output() {
            Err(error) if error.kind() == std::io::ErrorKind::ExecutableFileBusy && tries < 200 => {
                tries += 1;
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            result => break result.expect("the program starts"),
        }
    };
    Outcome { code: output.status.code().expect("the program exits by itself"), stdout: String::from_utf8(output.stdout).expect("UTF-8 output"), stderr: String::from_utf8(output.stderr).expect("UTF-8 errors") }
}

fn manifest(name: &str, extra: &str) -> String {
    format!(
        r#"{{"formatVersion":2,"id":"com.example.cli","name":"{name}","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall","systemMedium","systemLarge"],"permissions":[],"networkDomains":[]{extra}}}"#
    )
}

fn text(path: &Path) -> &str {
    path.to_str().expect("UTF-8 path")
}

/// The authored files of a folder: no folders, no dot-files (an installed package holds its identity in one).
fn package_files(directory: &Path) -> Vec<String> {
    support::tree(directory).into_iter().filter(|path| !path.ends_with('/') && !path.split('/').any(|part| part.starts_with('.'))).collect()
}

fn checks(report: &Value) -> [&str; 5] {
    ["package", "compile", "execute", "render", "export"].map(|stage| report["checks"][stage].as_str().unwrap_or("missing"))
}

fn codes(report: &Value) -> Vec<&str> {
    report["diagnostics"].as_array().expect("diagnostics").iter().filter_map(|item| item["code"].as_str()).collect()
}

/// Width and height from the header of a PNG file.
fn png_size(path: &Path) -> (u32, u32) {
    let bytes = std::fs::read(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n", "{} is a PNG", path.display());
    assert_eq!(&bytes[12..16], b"IHDR");
    let number = |at: usize| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
    (number(16), number(20))
}

#[track_caller]
fn assert_has_a_picture(report: &Value) {
    assert!(report["picture"]["visiblePixels"].as_u64() > Some(0), "something is visible: {}", report["picture"]);
    assert!(report["picture"]["colors"].as_u64() > Some(1), "more than one color: {}", report["picture"]);
}

const HELLO: &str = "$render(<vstack frame=\"max\" background=\"#1d4ed8\"><text color=\"white\">Hello 你好</text></vstack>);";

// The command surface

#[test]
fn help_goes_to_standard_output_and_no_command_is_a_usage_error() {
    let sandbox = Sandbox::new();
    for flag in ["--help", "-h", "help"] {
        let help = sandbox.run(&[flag]);
        assert_eq!(help.code, 0);
        assert!(help.stdout.starts_with("Usage: scriptwidget <command>") && help.stderr.is_empty());
    }
    let nothing = sandbox.run(&[]);
    assert_eq!(nothing.code, EXIT_USAGE);
    assert!(nothing.stdout.is_empty() && nothing.stderr.starts_with("Usage: scriptwidget"));
}

#[test]
fn the_version_is_a_report() {
    let sandbox = Sandbox::new();
    for flag in ["--version", "version"] {
        let report = sandbox.run(&[flag]).expect(0);
        assert_eq!(report["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(report["tool"]["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(report["command"], "--version");
    }
}

#[test]
fn mistakes_on_the_command_line_exit_with_2_and_say_why() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", HELLO);
    for arguments in [
        &["frobnicate"][..],
        &["check"],
        &["check", text(&package), "extra"],
        &["check", text(&package), "--unknown"],
        &["check", text(&package), "--format", "text"],
        &["run", text(&package), "--family", "huge"],
        &["run", text(&package), "--appearance", "both"],
        &["run", text(&package), "--family"],
        &["render", text(&package)],
        &["render", text(&package), "--output", "x.png", "--scale", "64"],
        &["render", text(&package), "--output", "x.png", "--now", "tomorrow"],
        &["timeline", text(&package), "--now", "1.5"],
        &["list", "extra"],
        &["new", "../escape"],
        &["new", ".hidden"],
        &["pack", text(&package), "a.swt", "--output", "b.swt"],
        &["pack", text(&package), "--output", "archive.zip"],
    ] {
        let outcome = sandbox.run(arguments);
        let report = outcome.expect(EXIT_USAGE);
        assert_eq!(report["error"]["kind"], "usage", "{arguments:?}");
        assert_eq!(codes(&report), ["usage"], "{arguments:?}");
        assert!(outcome.stderr.starts_with("error: [usage] "), "{arguments:?}: {}", outcome.stderr);
    }
    assert!(!sandbox.path("work/x.png").exists() && !sandbox.path("escape").exists());
}

// The commands that need the background service are tested in `desktop.rs`.
#[test]
fn a_desktop_command_without_a_session_needs_the_service() {
    let sandbox = Sandbox::new();
    let outcome = sandbox.run(&["widgets"]);
    assert_eq!(outcome.expect(EXIT_NEEDS_SERVICE)["error"]["kind"], "service.unavailable");
}

#[test]
fn a_missing_package_folder_is_an_environment_error() {
    let sandbox = Sandbox::new();
    for command in ["check", "run", "timeline", "pack"] {
        let report = sandbox.run(&[command, "nowhere"]).expect(EXIT_USAGE);
        assert_eq!(report["error"]["kind"], "input.directory", "{command}");
    }
    assert_eq!(sandbox.run(&["render", "nowhere", "--output", "x.png"]).expect(EXIT_USAGE)["error"]["kind"], "input.directory");
    assert_eq!(sandbox.run(&["install", "nowhere.swt"]).expect(EXIT_USAGE)["error"]["kind"], "input.file");
}

// new

#[test]
fn new_creates_a_package_that_checks_and_renders() {
    let sandbox = Sandbox::new();
    let report = sandbox.run(&["new", "My Widget"]).expect(0);
    let directory = sandbox.path("work/My Widget");
    assert_eq!(report["directory"], text(&std::fs::canonicalize(&directory).unwrap()));
    assert_eq!(report["template"], "starter");
    assert_eq!(report["files"], serde_json::json!(["main.jsx", "widget.json"]));
    let written: Value = serde_json::from_str(&std::fs::read_to_string(directory.join("widget.json")).unwrap()).unwrap();
    assert_eq!((written["name"].as_str(), written["formatVersion"].as_i64(), written["entry"].as_str()), (Some("My Widget"), Some(2), Some("main.jsx")));
    assert!(written["id"].as_str().unwrap().starts_with("local."));

    assert_eq!(checks(&sandbox.run(&["check", "My Widget"]).expect(0)), ["passed", "passed", "notRun", "notRun", "notRun"]);
    assert_has_a_picture(&sandbox.run(&["render", "My Widget", "--output", "starter.png"]).expect(0));

    // The name is taken now: nothing is written into the existing folder.
    std::fs::write(directory.join("main.jsx"), "// edited").unwrap();
    let again = sandbox.run(&["new", "My Widget"]).expect(EXIT_FAILED);
    assert_eq!(again["error"]["kind"], "package_exists");
    assert_eq!(std::fs::read_to_string(directory.join("main.jsx")).unwrap(), "// edited");
}

#[test]
fn new_copies_a_bundled_template_under_the_new_name() {
    let sandbox = Sandbox::new();
    let elsewhere = sandbox.scratch.new_folder("elsewhere");
    // A template with a manifest of its own, and one without (it gets a generated one).
    for (template, name) in [("template/Layout Starter", "From Manifest"), ("component/text", "From Legacy"), ("Countdown", "By Name")] {
        let report = sandbox.run(&["new", name, "--template", template, "--directory", text(&elsewhere)]).expect(0);
        assert!(report["template"].as_str().unwrap().ends_with(template), "{}", report["template"]);
        let directory = elsewhere.join(name);
        let written: Value = serde_json::from_str(&std::fs::read_to_string(directory.join("widget.json")).unwrap()).unwrap();
        assert_eq!(written["name"], name);
        assert!(written["id"].as_str().unwrap().starts_with("local."), "a copy never keeps the template's identity: {}", written["id"]);
        assert_eq!(checks(&sandbox.run(&["check", text(&directory)]).expect(0)), ["passed", "passed", "notRun", "notRun", "notRun"], "{template}");
    }
    assert_eq!(sandbox.run(&["new", "X", "--template", "template/No Such Template"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    // A template that needs an API Linux lacks is not offered.
    assert_eq!(sandbox.run(&["new", "X", "--template", "api/health"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    assert!(!sandbox.path("work/X").exists());
}

// check

#[test]
fn check_validates_and_compiles_without_executing() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", "throw new Error('check must not execute');");
    let report = sandbox.run(&["check", text(&package), "--format", "json"]).expect(0);
    assert_eq!(report["command"], "check");
    assert_eq!(report["backend"], "static");
    assert_eq!(checks(&report), ["passed", "passed", "notRun", "notRun", "notRun"]);
    assert_eq!(report["manifest"]["ok"], true);
    assert_eq!(report["manifest"]["manifest"]["name"], "Widget");
    assert_eq!(report["sourceHashAlgorithm"], "ScriptWidgetSource/v1");
    assert_eq!(report["sourceHash"].as_str().map(str::len), Some(64));
    assert_eq!(report["error"], Value::Null);
    // The Windows name of the command.
    assert_eq!(sandbox.run(&["validate", text(&package)]).expect(0)["command"], "check");
}

#[test]
fn the_source_hash_is_the_documented_fingerprint() {
    use std::fmt::Write;
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", "$render(<text>跨语言 ✓</text>);");
    sandbox.scratch.new_folder("work/Widget/image");
    std::fs::write(package.join("image/色.png"), [0u8, 255, 42]).unwrap();
    std::fs::write(package.join(".hidden"), "not part of the package").unwrap();
    // ScriptWidgetSource/v1: a count, then path and content of every file in byte order of the path, each behind its length.
    let mut files: Vec<(String, Vec<u8>)> = ["image/色.png", "main.jsx", "widget.json"].iter().map(|path| (path.to_string(), std::fs::read(package.join(path)).unwrap())).collect();
    files.sort();
    let mut bytes = b"ScriptWidgetSource/v1\n".to_vec();
    bytes.extend((files.len() as u64).to_be_bytes());
    for (path, content) in &files {
        bytes.extend((path.len() as u64).to_be_bytes());
        bytes.extend(path.as_bytes());
        bytes.extend((content.len() as u64).to_be_bytes());
        bytes.extend(content);
    }
    let expected = sha256(&bytes).iter().fold(String::new(), |mut hex, byte| {
        write!(hex, "{byte:02x}").unwrap();
        hex
    });
    assert_eq!(sandbox.run(&["check", text(&package)]).expect(0)["sourceHash"], expected);
}

#[test]
fn check_reports_what_is_wrong_with_a_package() {
    let sandbox = Sandbox::new();

    let broken = sandbox.package("Broken", "$render(<text>wrong</vstack>);");
    let report = sandbox.run(&["check", text(&broken)]).expect(EXIT_FAILED);
    assert_eq!(checks(&report), ["passed", "failed", "notRun", "notRun", "notRun"]);
    assert_eq!(report["error"]["kind"], "scriptException", "the engine's kind for a source that does not parse");
    assert!(report["error"]["message"].as_str().unwrap().contains("SyntaxError"), "{}", report["error"]);

    let unknown_key = sandbox.package("Unknown", HELLO);
    std::fs::write(unknown_key.join("widget.json"), manifest("Unknown", ",\"surprise\":true")).unwrap();
    let outcome = sandbox.run(&["check", text(&unknown_key)]);
    let report = outcome.expect(EXIT_FAILED);
    assert_eq!(checks(&report), ["failed", "notRun", "notRun", "notRun", "notRun"]);
    assert_eq!(report["error"]["kind"], "invalid_manifest");
    assert_eq!(report["manifest"]["ok"], false);
    assert!(report["error"]["message"].as_str().unwrap().contains("surprise"), "unknown keys fail closed and are named: {}", report["error"]);
    assert!(outcome.stderr.starts_with("error: [invalid_manifest] "), "{}", outcome.stderr);

    // Every issue of the validator is a diagnostic; the first one is the reason.
    let issues = sandbox.package("Issues", HELLO);
    std::fs::write(issues.join("widget.json"), manifest("Issues", "").replace("\"entry\":\"main.jsx\"", "\"entry\":\"nope.jsx\"").replace("\"permissions\":[]", "\"permissions\":[\"network\"]")).unwrap();
    let report = sandbox.run(&["check", text(&issues)]).expect(EXIT_FAILED);
    assert_eq!(codes(&report), ["missing_entry", "missing_network_domains", "invalid_manifest"]);
    assert!(report["error"]["message"].as_str().unwrap().contains("[missing_entry]"), "{}", report["error"]);

    let future = sandbox.package("Future", HELLO);
    std::fs::write(future.join("widget.json"), manifest("Future", "").replace("\"formatVersion\":2", "\"formatVersion\":99")).unwrap();
    assert_eq!(sandbox.run(&["check", text(&future)]).expect(EXIT_FAILED)["error"]["kind"], "invalid_manifest", "an unsupported version fails closed");

    let nothing = sandbox.scratch.new_folder("work/Empty");
    assert_eq!(sandbox.run(&["check", text(&nothing)]).expect(EXIT_FAILED)["error"]["kind"], "missing_entry");
}

#[test]
fn a_present_manifest_that_cannot_be_read_is_never_treated_as_legacy() {
    let sandbox = Sandbox::new();
    for (name, content) in [("Malformed", "{ not json"), ("Array", "[]"), ("Duplicate", r#"{"name":"a","name":"b"}"#), ("Binary", "\u{0}\u{1}")] {
        let package = sandbox.package(name, HELLO);
        std::fs::write(package.join("widget.json"), content).unwrap();
        for command in [&["check"][..], &["run"], &["pack"], &["install"], &["timeline"]] {
            let report = sandbox.run(&[command[0], text(&package)]).expect(EXIT_FAILED);
            assert_eq!(report["error"]["kind"], "invalid_manifest", "{name} {command:?}: {report}");
        }
        assert_eq!(sandbox.run(&["render", text(&package), "--output", "legacy.png"]).expect(EXIT_FAILED)["error"]["kind"], "invalid_manifest");
    }
    assert!(!sandbox.path("work/legacy.png").exists() && !sandbox.path("work/Malformed.swt").exists());
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"], serde_json::json!([]));

    // Another spelling of the name is the manifest on other platforms: an error here too.
    let wrong_case = sandbox.scratch.new_folder("work/WrongCase");
    std::fs::write(wrong_case.join("main.jsx"), HELLO).unwrap();
    std::fs::write(wrong_case.join("Widget.JSON"), manifest("WrongCase", "")).unwrap();
    assert_eq!(sandbox.run(&["check", text(&wrong_case)]).expect(EXIT_FAILED)["error"]["kind"], "invalid_manifest_case");

    // A legacy package (main.jsx and no manifest) is still accepted.
    let legacy = sandbox.scratch.new_folder("work/Legacy");
    std::fs::write(legacy.join("main.jsx"), HELLO).unwrap();
    let report = sandbox.run(&["check", text(&legacy)]).expect(0);
    assert_eq!(report["manifest"], Value::Null);
}

// run

#[test]
fn run_prints_the_tree_logs_and_the_environment_it_ran_in() {
    let sandbox = Sandbox::new();
    let package = sandbox.package(
        "Widget",
        "console.log('from the script'); $storage.setString('k', 'v');\n$render(<text>{$getenv('widget-size')}|{$getenv('widget-param')}|{String($device.isdarkmode())}|{$system.platform()}|{$storage.getString('k')}</text>);",
    );
    let report = sandbox.run(&["run", text(&package), "--family", "large", "--param", "p q", "--dark"]).expect(0);
    assert_eq!(report["backend"], "linux-native");
    assert_eq!(checks(&report), ["passed", "passed", "passed", "notRun", "notRun"]);
    assert_eq!(report["tree"]["$element"], "text");
    assert_eq!(report["tree"]["children"], serde_json::json!(["large", "|", "p q", "|", "true", "|", "linux", "|", "v"]));
    assert_eq!(report["logs"], serde_json::json!([{ "level": "log", "message": "from the script" }]));
    assert!(report["elapsedMilliseconds"].as_f64().unwrap() > 0.0);
    assert_eq!(report["nextTimelineTransition"], Value::Null);

    let light = sandbox.run(&["run", text(&package), "--appearance", "light"]).expect(0);
    assert_eq!(light["tree"]["children"][0], "medium");
    assert_eq!(light["tree"]["children"][4], "false");

    // Without --data, storage and caches live in a temporary folder that is gone afterwards.
    assert!(!sandbox.data().exists(), "the user's data folder is not touched");
    assert!(std::fs::read_dir(sandbox.path("home")).unwrap().next().is_none(), "nothing is left in the home folder");
    // With --data they are kept there.
    let kept = sandbox.path("kept");
    sandbox.run(&["run", text(&package), "--data", text(&kept)]).expect(0);
    assert!(kept.join("Storage").is_dir());
}

#[test]
fn run_reports_script_errors_with_exit_1() {
    let sandbox = Sandbox::new();
    let throwing = sandbox.package("Throwing", "console.log('before'); throw new Error('boom');");
    let outcome = sandbox.run(&["run", text(&throwing)]);
    let report = outcome.expect(EXIT_FAILED);
    assert_eq!(checks(&report), ["passed", "passed", "failed", "notRun", "notRun"]);
    assert_eq!(report["tree"], Value::Null);
    assert_eq!(report["error"]["kind"], "scriptException");
    assert!(report["error"]["message"].as_str().unwrap().contains("boom"));
    assert_eq!(report["logs"][0]["message"], "before");
    assert!(outcome.stderr.contains("boom"));

    let endless = sandbox.package("Endless", "while (true) {}");
    let report = sandbox.run(&["run", text(&endless)]).expect(EXIT_FAILED);
    assert_eq!(report["error"]["kind"], "resourceLimit");

    let syntax = sandbox.package("Syntax", "$render(<text>");
    assert_eq!(checks(&sandbox.run(&["run", text(&syntax)]).expect(EXIT_FAILED)), ["passed", "failed", "notRun", "notRun", "notRun"]);
}

#[test]
fn a_package_cannot_read_outside_its_folder() {
    let sandbox = Sandbox::new();
    sandbox.scratch.new_file("work/secret.txt", "secret");
    let package = sandbox.package("Reader", "$render(<text>{JSON.stringify($file.read('../secret.txt'))}|{String($file.exists('../secret.txt'))}|{String($file.exists('/etc/passwd'))}|{String($file.exists('widget.json'))}</text>);");
    let report = sandbox.run(&["run", text(&package)]).expect(0);
    assert_eq!(report["tree"]["children"], serde_json::json!(["\"\"", "|", "false", "|", "false", "|", "true"]));
}

#[test]
fn warnings_fail_the_command_only_when_asked() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Promise", "Promise.all([]); $render(<text>ok</text>);");
    let outcome = sandbox.run(&["run", text(&package)]);
    let report = outcome.expect(0);
    assert!(codes(&report).contains(&"compat.promise"), "{}", report["diagnostics"]);
    assert!(outcome.stderr.starts_with("warning: [compat.promise] "), "{}", outcome.stderr);
    let strict = sandbox.run(&["run", text(&package), "--fail-on-warning"]).expect(EXIT_FAILED);
    assert_eq!(checks(&strict), ["passed", "passed", "passed", "notRun", "notRun"]);
    assert_eq!(strict["error"], Value::Null, "the warning is the reason; nothing else failed");
}

// render

#[test]
fn render_draws_a_png_without_a_graphical_session() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", "$render(<vstack frame=\"max\" background=\"#0f172a\"><text color=\"white\">Hello 你好 🌤️</text><button action=\"reload\"><text>Refresh</text></button></vstack>);");
    let mut command = sandbox.command();
    // Said again where it matters: no X11 and no Wayland display.
    command.env_remove("DISPLAY").env_remove("WAYLAND_DISPLAY").env_remove("XDG_RUNTIME_DIR");
    let outcome = finish(command.args(["render", text(&package), "--family", "medium", "--scale", "2", "--output", "out/deep/widget.png", "--now", FIXED_NOW]));
    let report = outcome.expect(0);
    let output = std::fs::canonicalize(sandbox.work()).unwrap().join("out/deep/widget.png");
    assert_eq!(checks(&report), ["passed", "passed", "passed", "passed", "notRun"]);
    assert_eq!(report["output"], text(&output));
    assert_eq!((report["pixelWidth"].as_u64(), report["pixelHeight"].as_u64()), (Some(658), Some(340)));
    assert_eq!(png_size(&output), (658, 340));
    assert_eq!(report["family"], "medium");
    assert_eq!(report["scale"], 2.0);
    assert_has_a_picture(&report);
    let artifact = &report["artifacts"][0];
    let png = std::fs::read(&output).unwrap();
    assert_eq!(artifact["path"], text(&output));
    assert_eq!(artifact["bytes"], png.len());
    assert_eq!(artifact["sha256"].as_str().unwrap(), sha256(&png).iter().map(|byte| format!("{byte:02x}")).collect::<String>());
    let region = &report["hitRegions"][0];
    assert_eq!(region["interaction"]["type"], "button");
    assert_eq!(region["interaction"]["action"], "reload");
    assert!(region["width"].as_f64().unwrap() > 10.0 && region["height"].as_f64().unwrap() > 5.0 && region["x"].as_f64().unwrap() > 0.0, "{region}");
    assert!(report["layoutMilliseconds"].is_number() && report["paintMilliseconds"].is_number() && report["renderDiagnostics"].is_array());

    // Every family at its size in points, times the scale.
    for (family, scale, size) in [("small", "1", (170, 170)), ("large", "1", (329, 345)), ("extraLarge", "1.5", (959, 518))] {
        let file = format!("{family}.png");
        let report = sandbox.run(&["render", text(&package), "--family", family, "--scale", scale, "--output", &file, "--dark"]).expect(0);
        assert_eq!(png_size(&sandbox.work().join(&file)), size, "{family}");
        assert_has_a_picture(&report);
    }
    // The same input draws the same picture.
    let first = sandbox.run(&["render", text(&package), "--output", "a.png", "--now", FIXED_NOW]).expect(0);
    let second = sandbox.run(&["render", text(&package), "--output", "b.png", "--now", FIXED_NOW]).expect(0);
    assert_eq!(first["artifacts"][0]["sha256"], second["artifacts"][0]["sha256"]);
}

#[test]
fn a_script_error_is_drawn_as_a_card_and_still_fails() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Throwing", "throw new Error('boom');");
    let report = sandbox.run(&["render", text(&package), "--output", "error.png"]).expect(EXIT_FAILED);
    assert_eq!(checks(&report), ["passed", "passed", "failed", "notRun", "notRun"]);
    assert_eq!(report["error"]["kind"], "scriptException");
    assert_eq!(png_size(&sandbox.path("work/error.png")), (658, 340));
    assert_has_a_picture(&report);
}

#[test]
fn render_writes_only_the_file_it_was_asked_for() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", HELLO);

    // Inside the package: refused, also through a link to the folder and with dots in the path.
    support::symlink(&sandbox.path("work/alias"), &package);
    for output in ["Widget/out.png", "Widget/nested/out.png", "alias/out.png", "elsewhere/../Widget/out.png"] {
        let report = sandbox.run(&["render", text(&package), "--output", output]).expect(EXIT_USAGE);
        assert_eq!(report["error"]["kind"], if output.starts_with("elsewhere") { "output.path" } else { "output.inside_package" }, "{output}");
    }
    assert_eq!(support::tree(&package), ["main.jsx", "widget.json"], "the package is unchanged");

    // A link at the output name is refused, and what it points to is not written.
    let precious = sandbox.scratch.new_file("precious.txt", "precious");
    support::symlink(&sandbox.path("work/link.png"), &precious);
    let report = sandbox.run(&["render", text(&package), "--output", "link.png"]).expect(EXIT_USAGE);
    assert_eq!(report["error"]["kind"], "output.symlink");
    assert_eq!(std::fs::read_to_string(&precious).unwrap(), "precious");
    // So is a dangling link, which would otherwise create its target.
    support::symlink(&sandbox.path("work/dangling.png"), &sandbox.path("created-through-link.png"));
    assert_eq!(sandbox.run(&["render", text(&package), "--output", "dangling.png"]).expect(EXIT_USAGE)["error"]["kind"], "output.symlink");
    assert!(!sandbox.path("created-through-link.png").exists());
    // A folder is not replaced.
    sandbox.scratch.new_folder("work/folder.png");
    assert_eq!(sandbox.run(&["render", text(&package), "--output", "folder.png"]).expect(EXIT_USAGE)["error"]["kind"], "output.not_a_file");

    // A regular file is replaced, and nothing else appears next to it.
    sandbox.scratch.new_folder("work/pictures");
    sandbox.scratch.new_file("work/pictures/old.png", "old");
    sandbox.run(&["render", text(&package), "--output", "pictures/old.png"]).expect(0);
    assert_eq!(png_size(&sandbox.path("work/pictures/old.png")), (658, 340));
    assert_eq!(support::tree(&sandbox.path("work/pictures")), ["old.png"], "no temporary file is left");
}

// timeline

#[test]
fn timeline_reports_the_slot_and_the_next_transition() {
    let sandbox = Sandbox::new();
    let plain = sandbox.package("Plain", HELLO);
    let report = sandbox.run(&["timeline", text(&plain)]).expect(0);
    assert_eq!((report["hasSchedule"].as_bool(), &report["environments"], &report["nextTransition"]), (Some(false), &Value::Null, &Value::Null));

    let scheduled = sandbox.package("Scheduled", "$render(<text>{$getenv('timeline-slot')}</text>);");
    std::fs::write(scheduled.join("widget.json"), manifest("Scheduled", ",\"timeline\":{\"dailyTimes\":[\"06:00\",\"18:00\"]}")).unwrap();
    assert_eq!(sandbox.run(&["check", text(&scheduled)]).expect(0)["manifest"]["ok"], true);
    // 2026-01-01 12:00 UTC, in a process whose zone is UTC: the 06:00 slot, until 18:00.
    let report = sandbox.run(&["timeline", text(&scheduled), "--now", FIXED_NOW]).expect(0);
    assert_eq!(report["hasSchedule"], true);
    assert_eq!(report["nextTransition"], 1_767_268_800_000i64 + 6 * 3_600_000);
    assert!(report["environments"].as_object().is_some_and(|environments| !environments.is_empty()), "{}", report["environments"]);
    // run reports the same transition for the host to wake at.
    assert!(sandbox.run(&["run", text(&scheduled)]).expect(0)["nextTimelineTransition"].as_i64() > Some(1_767_268_800_000));
}

// pack

#[test]
fn pack_writes_an_archive_that_installs_again() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", "throw new Error('pack must not execute');");
    sandbox.scratch.new_file("work/Widget/lib/util.js", "function util() {}");
    sandbox.scratch.new_file("work/Widget/.secret", "never exported");
    sandbox.scratch.new_file("work/Widget/__Build/prepared-0.json", "{}");

    let report = sandbox.run(&["pack", text(&package)]).expect(0);
    let archive = std::fs::canonicalize(sandbox.work()).unwrap().join("Widget.swt");
    assert_eq!(checks(&report), ["passed", "passed", "notRun", "notRun", "passed"]);
    assert_eq!(report["output"], text(&archive));
    assert_eq!(report["name"], "Widget");
    let bytes = std::fs::read(&archive).unwrap();
    assert_eq!(report["artifacts"][0]["bytes"], bytes.len());
    let names: Vec<String> = read_zip(&bytes).into_iter().map(|(name, _)| name).collect();
    assert_eq!(names, ["Widget/lib/util.js", "Widget/main.jsx", "Widget/widget.json"], "dot-files and the build cache stay out");

    // An existing archive is kept unless --force is given; the same package packs to the same bytes.
    let again = sandbox.run(&["pack", text(&package)]).expect(EXIT_USAGE);
    assert_eq!(again["error"]["kind"], "output.exists");
    std::fs::write(&archive, "old").unwrap();
    sandbox.run(&["pack", text(&package), "--force"]).expect(0);
    assert_eq!(std::fs::read(&archive).unwrap(), bytes);
    // The output can be named with --output or, as on Windows, as the second argument.
    sandbox.run(&["pack", text(&package), "--output", "named/one.swt"]).expect(0);
    sandbox.run(&["pack", text(&package), "two.swt"]).expect(0);
    assert_eq!(std::fs::read(sandbox.path("work/named/one.swt")).unwrap(), bytes);
    assert_eq!(std::fs::read(sandbox.path("work/two.swt")).unwrap(), bytes);

    // A legacy package gets a manifest in the archive; the folder is not modified.
    let legacy = sandbox.scratch.new_folder("work/Old Style");
    std::fs::write(legacy.join("main.jsx"), HELLO).unwrap();
    sandbox.run(&["pack", text(&legacy)]).expect(0);
    let entries = read_zip(&std::fs::read(sandbox.path("work/Old Style.swt")).unwrap());
    assert_eq!(entries.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["Old Style/main.jsx", "Old Style/widget.json"]);
    assert_eq!(support::tree(&legacy), ["main.jsx"]);

    let installed = sandbox.run(&["install", text(&archive)]).expect(0);
    assert_eq!(installed["name"], "Widget");
}

#[test]
fn pack_refuses_what_does_not_compile_and_unsafe_outputs() {
    let sandbox = Sandbox::new();
    let broken = sandbox.package("Broken", "$render(<text>");
    let report = sandbox.run(&["pack", text(&broken)]).expect(EXIT_FAILED);
    assert_eq!(checks(&report), ["passed", "failed", "notRun", "notRun", "notRun"]);
    assert!(!sandbox.path("work/Broken.swt").exists());

    let package = sandbox.package("Widget", HELLO);
    assert_eq!(sandbox.run(&["pack", text(&package), "--output", "Widget/inside.swt"]).expect(EXIT_USAGE)["error"]["kind"], "output.inside_package");
    let precious = sandbox.scratch.new_file("precious.txt", "precious");
    support::symlink(&sandbox.path("work/link.swt"), &precious);
    for force in [&[][..], &["--force"]] {
        let mut arguments = vec!["pack", text(&package), "--output", "link.swt"];
        arguments.extend(force);
        let report = sandbox.run(&arguments).expect(EXIT_USAGE);
        assert_eq!(report["error"]["kind"], if force.is_empty() { "output.exists" } else { "output.symlink" });
        assert_eq!(std::fs::read_to_string(&precious).unwrap(), "precious");
    }
    assert_eq!(support::tree(&package), ["main.jsx", "widget.json"]);
}

// install and list

#[test]
fn install_adds_archives_and_folders_to_the_library() {
    let sandbox = Sandbox::new();
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"], serde_json::json!([]));

    let archive = sandbox.scratch.new_folder("downloads").join("Any Name.swt");
    std::fs::write(&archive, support::package_zip("Folder In Archive", "Declared Name", &[("lib/a.js", "var a = 1;")])).unwrap();
    let report = sandbox.run(&["install", text(&archive)]).expect(0);
    assert_eq!(checks(&report), ["passed", "passed", "notRun", "notRun", "notRun"]);
    assert_eq!(report["name"], "Declared Name", "the manifest names the package, not the file or the archive folder");
    let directory = PathBuf::from(report["directory"].as_str().unwrap());
    assert_eq!(package_files(&directory), ["lib/a.js", "main.jsx", "widget.json"]);
    assert!(directory.starts_with(std::fs::canonicalize(sandbox.data()).unwrap().join("Packages")));

    // The same archive again: a second copy with a numbered name and an identity of its own.
    let second = sandbox.run(&["install", text(&archive)]).expect(0);
    assert_eq!(second["name"], "Declared Name (1)");
    assert_ne!(second["installation"], report["installation"]);

    // A folder is installed through the same checks.
    let folder = sandbox.package("From Folder", HELLO);
    sandbox.scratch.new_file("work/From Folder/.git/config", "not part of the package");
    let third = sandbox.run(&["install", text(&folder)]).expect(0);
    assert_eq!(third["name"], "From Folder");
    assert_eq!(package_files(&PathBuf::from(third["directory"].as_str().unwrap())), ["main.jsx", "widget.json"]);
    assert!(!Path::new(third["directory"].as_str().unwrap()).join(".git").exists(), "dot-files are not installed");

    let listed = sandbox.run(&["list"]).expect(0);
    let names: Vec<&str> = listed["packages"].as_array().unwrap().iter().map(|package| package["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["Declared Name", "Declared Name (1)", "From Folder"]);
    let first = &listed["packages"][0];
    assert_eq!((first["title"].as_str(), &first["installation"], first["directory"].as_str()), (Some("Declared Name"), &report["installation"], report["directory"].as_str()));
    // An installed package runs from the library like any folder.
    assert_eq!(sandbox.run(&["run", report["directory"].as_str().unwrap()]).expect(0)["tree"]["children"][0], "hi");

    // --data names another library.
    let other = sandbox.path("other-data");
    assert_eq!(sandbox.run(&["list", "--data", text(&other)]).expect(0)["packages"], serde_json::json!([]));
}

#[test]
fn install_refuses_unsafe_archives_and_leaves_nothing_behind() {
    let sandbox = Sandbox::new();
    let downloads = sandbox.scratch.new_folder("downloads");
    let good = |path: &str| RawEntry::new(path, if path.ends_with("widget.json") { support::manifest("Widget") } else { "$render(<text>hi</text>);".to_owned() });
    let cases: Vec<(&str, Vec<RawEntry>, &str)> = vec![
        ("traversal", vec![good("Widget/widget.json"), good("Widget/main.jsx"), RawEntry::new("Widget/../../escaped.txt", "escaped")], "archive_unsafe_path"),
        ("parent", vec![good("widget.json"), good("main.jsx"), RawEntry::new("../escaped.txt", "escaped")], "archive_unsafe_path"),
        ("absolute", vec![good("Widget/widget.json"), good("Widget/main.jsx"), RawEntry::new("/tmp/scriptwidget-escaped.txt", "escaped")], "archive_unsafe_path"),
        ("backslash", vec![good("Widget/widget.json"), good("Widget/main.jsx"), RawEntry::new("Widget\\..\\escaped.txt", "escaped")], "archive_unsafe_path"),
        ("symlink", vec![good("Widget/widget.json"), good("Widget/main.jsx"), RawEntry::new("Widget/link", "/etc/passwd").mode(SYMBOLIC_LINK)], "archive_symlink"),
        ("collision", vec![good("Widget/widget.json"), good("Widget/main.jsx"), RawEntry::new("Widget/Main.JSX", "other")], "archive_path_collision"),
        ("lying-size", vec![good("Widget/widget.json"), RawEntry::new("Widget/main.jsx", vec![b'a'; 4096]).declared_size(16)], "archive_size_mismatch"),
    ];
    for (name, entries, code) in cases {
        let archive = downloads.join(format!("{name}.swt"));
        std::fs::write(&archive, raw_zip(&entries)).unwrap();
        let outcome = sandbox.run(&["install", text(&archive)]);
        let report = outcome.expect(EXIT_FAILED);
        assert_eq!(report["error"]["kind"], code, "{name}");
        assert_eq!(checks(&report)[0], "failed", "{name}");
        assert!(outcome.stderr.contains(&format!("error: [{code}]")), "{name}: {}", outcome.stderr);
    }
    std::fs::write(downloads.join("garbage.swt"), "this is not an archive").unwrap();
    assert!(sandbox.run(&["install", text(&downloads.join("garbage.swt"))]).expect(EXIT_FAILED)["error"]["kind"].as_str().unwrap().starts_with("archive_"));

    // An archive whose package does not compile is refused before it is published.
    std::fs::write(downloads.join("broken.swt"), raw_zip(&[good("Widget/widget.json"), RawEntry::new("Widget/main.jsx", "$render(<text>")])).unwrap();
    let report = sandbox.run(&["install", text(&downloads.join("broken.swt"))]).expect(EXIT_FAILED);
    assert_eq!(checks(&report), ["passed", "failed", "notRun", "notRun", "notRun"]);
    assert!(report["error"]["message"].as_str().unwrap().contains("SyntaxError"), "{}", report["error"]);
    // And one with an invalid manifest.
    std::fs::write(downloads.join("unknown-key.swt"), raw_zip(&[RawEntry::new("Widget/widget.json", manifest("Widget", ",\"surprise\":1")), good("Widget/main.jsx")])).unwrap();
    sandbox.run(&["install", text(&downloads.join("unknown-key.swt"))]).expect(EXIT_FAILED);

    // Nothing was installed, nothing is left in staging, and nothing was written outside the library.
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"], serde_json::json!([]));
    assert_eq!(support::tree(&sandbox.data().join("Packages")), Vec::<String>::new());
    assert!(support::tree(&sandbox.data()).iter().all(|path| !path.contains("escaped")), "{:?}", support::tree(&sandbox.data()));
    for escaped in [sandbox.path("escaped.txt"), sandbox.data().join("escaped.txt"), sandbox.data().join("Staging/escaped.txt"), PathBuf::from("/tmp/scriptwidget-escaped.txt")] {
        assert!(!escaped.exists(), "{}", escaped.display());
    }
    assert_eq!(std::fs::read_dir(sandbox.data().join("Staging")).map(|entries| entries.count()).unwrap_or(0), 0, "staging is clean");
}

// Links in a package folder

#[test]
fn a_link_in_a_package_folder_fails_every_command() {
    let sandbox = Sandbox::new();
    let secret = sandbox.scratch.new_file("secret.txt", "secret");

    let linked_file = sandbox.package("LinkedFile", "$render(<text>{String($file.read('data.txt'))}</text>);");
    support::symlink(&linked_file.join("data.txt"), &secret);
    let linked_folder = sandbox.package("LinkedFolder", HELLO);
    support::symlink(&linked_folder.join("lib"), &sandbox.path("work"));
    let nested = sandbox.package("Nested", HELLO);
    sandbox.scratch.new_folder("work/Nested/a/b");
    support::symlink(&nested.join("a/b/passwd"), Path::new("/etc/passwd"));
    let hard_linked = sandbox.package("HardLinked", HELLO);
    support::hard_link(&hard_linked.join("data.txt"), &secret);
    let linked_entry = sandbox.scratch.new_folder("work/LinkedEntry");
    std::fs::write(linked_entry.join("widget.json"), manifest("LinkedEntry", "")).unwrap();
    support::symlink(&linked_entry.join("main.jsx"), &sandbox.scratch.new_file("outside.jsx", HELLO));

    for package in [&linked_file, &linked_folder, &nested, &hard_linked, &linked_entry] {
        for command in ["check", "run", "pack", "install", "timeline"] {
            let outcome = sandbox.run(&[command, text(package)]);
            let report = outcome.expect(EXIT_FAILED);
            assert_eq!(report["error"]["kind"], "unsafe_file", "{command} {}", package.display());
            if command != "timeline" {
                assert_eq!(checks(&report)[0], "failed", "{command}");
            }
        }
        let report = sandbox.run(&["render", text(package), "--output", "linked.png"]).expect(EXIT_FAILED);
        assert_eq!(report["error"]["kind"], "unsafe_file");
    }
    assert!(!sandbox.path("work/linked.png").exists());
    assert!(std::fs::read_dir(sandbox.work()).unwrap().all(|entry| entry.unwrap().path().extension().is_none_or(|extension| extension != "swt")), "no archive was written");
    assert_eq!(sandbox.run(&["list"]).expect(0)["packages"], serde_json::json!([]));

    // The package folder itself must not be a link.
    let real = sandbox.package("Real", HELLO);
    support::symlink(&sandbox.path("work/Alias"), &real);
    assert_eq!(sandbox.run(&["check", "Alias"]).expect(EXIT_USAGE)["error"]["kind"], "input.directory");

    // What is not part of the authored package is not looked at: a linked dot-folder or build cache does not matter, and is not exported.
    support::symlink(&real.join(".venv"), &sandbox.path("work"));
    support::symlink(&real.join("__Build"), &sandbox.path("work"));
    sandbox.run(&["check", text(&real)]).expect(0);
    sandbox.run(&["pack", text(&real), "--output", "real.swt"]).expect(0);
    let names: Vec<String> = read_zip(&std::fs::read(sandbox.path("work/real.swt")).unwrap()).into_iter().map(|(name, _)| name).collect();
    assert_eq!(names, ["Real/main.jsx", "Real/widget.json"]);
}

// Templates and the installed layout

/// The data directory as a package installs it, assembled by the same script.
fn staged_resources(scratch: &TemporaryFolder) -> PathBuf {
    let root = scratch.path("prefix/share/scriptwidget");
    let status = Command::new("sh").arg(repository().join("Linux/scripts/stage-resources.sh")).arg(&root).stdout(std::process::Stdio::null()).status().expect("sh runs");
    assert!(status.success(), "stage-resources.sh");
    root
}

#[test]
fn templates_lists_what_runs_on_linux() {
    let sandbox = Sandbox::new();
    let report = sandbox.run(&["templates"]).expect(0);
    let templates = report["templates"].as_array().unwrap();
    assert!(templates.len() > 100, "{} templates", templates.len());
    let named = |group: &str, name: &str| templates.iter().find(|template| template["group"] == group && template["name"] == name);
    assert_eq!(named("template", "An Empty Widget").unwrap()["network"], false);
    assert_eq!(named("template", "Countdown").unwrap()["network"], false);
    assert_eq!(named("template", "Daily Quote").unwrap()["network"], true);
    assert!(Path::new(named("component", "text").unwrap()["directory"].as_str().unwrap()).join("main.jsx").is_file());
    // The ones that use an API Linux does not implement are left out, with the reason.
    assert!(named("api", "health").is_none() && named("api", "location").is_none());
    // One that asks for the location in a file its main.jsx imports is left out as well.
    assert!(named("template", "Local Weather (Location)").is_none());
    assert!(report["unavailable"].as_array().unwrap().iter().any(|template| template["name"] == "Local Weather (Location)" && template["api"] == "$location"));
    // What Linux implements is offered: the media player, notifications, picked files and pictures, GitHub.
    for global in ["$music", "$notifications", "$documents", "$photos", "$services"] {
        assert!(!report["unavailable"].as_array().unwrap().iter().any(|template| template["api"] == global), "{global}");
    }
    assert!(named("template", "Music Playback").is_some());
    let unavailable = report["unavailable"].as_array().unwrap();
    assert!(unavailable.iter().any(|template| template["group"] == "api" && template["name"] == "health" && template["api"] == "$health"), "{unavailable:?}");
    assert_eq!(templates.len() + unavailable.len(), ["template", "component", "api"].iter().map(|group| std::fs::read_dir(bundled_templates().join(group)).unwrap().filter(|entry| entry.as_ref().unwrap().path().join("main.jsx").is_file()).count()).sum::<usize>());

    // Without templates the command says so instead of printing an empty list.
    let mut command = sandbox.command();
    command.env_remove("SCRIPTWIDGET_TEMPLATES");
    assert_eq!(finish(command.arg("templates")).expect(EXIT_USAGE)["error"]["kind"], "tool.templates_missing");
}

/// The phase 1 criterion: with no graphical session, `scriptwidget render`
/// draws every bundled template that needs no system data, from the installed
/// layout, at the medium size. A template fails on any error and on an empty
/// picture. The templates that need an API Linux lacks are not listed at all;
/// the listed ones that ask the network are named and not drawn, so that the
/// test does not depend on other people's servers.
#[test]
fn every_bundled_template_that_needs_no_network_renders() {
    let sandbox = Sandbox::new();
    let resources = staged_resources(&sandbox.scratch);
    let command = || {
        let mut command = sandbox.command();
        command.env_remove("SCRIPTWIDGET_RUNTIME_ASSETS").env_remove("SCRIPTWIDGET_TEMPLATES").env("SCRIPTWIDGET_RESOURCES", &resources);
        command.env_remove("DISPLAY").env_remove("WAYLAND_DISPLAY");
        command
    };
    let listed = finish(command().arg("templates")).expect(0);
    let templates: Vec<(String, String, bool)> = listed["templates"]
        .as_array()
        .unwrap()
        .iter()
        .map(|template| (format!("{}/{}", template["group"].as_str().unwrap(), template["name"].as_str().unwrap()), template["directory"].as_str().unwrap().to_owned(), template["network"].as_bool().unwrap()))
        .collect();
    let pictures = sandbox.scratch.new_folder("pictures");
    // Keep the pictures for review with SCRIPTWIDGET_CLI_PICTURES=<folder>.
    let keep = std::env::var_os("SCRIPTWIDGET_CLI_PICTURES").map(PathBuf::from);

    let work: Vec<&(String, String, bool)> = templates.iter().filter(|(_, _, network)| !network).collect();
    let next = std::sync::atomic::AtomicUsize::new(0);
    let failures = std::sync::Mutex::new(Vec::new());
    std::thread::scope(|scope| {
        for _ in 0..std::thread::available_parallelism().map_or(2, |count| count.get().min(8)) {
            scope.spawn(|| {
                loop {
                    let Some((name, directory, _)) = work.get(next.fetch_add(1, std::sync::atomic::Ordering::Relaxed)) else { break };
                    let output = pictures.join(format!("{}.png", name.replace('/', "-")));
                    let outcome = finish(command().args(["render", directory, "--family", "medium", "--scale", "2", "--now", FIXED_NOW, "--output", text(&output)]));
                    let problem = match serde_json::from_str::<Value>(&outcome.stdout) {
                        Err(error) => Some(format!("no report ({error}): {}", outcome.stderr)),
                        Ok(report) if outcome.code != 0 || report["status"] != "passed" => Some(format!("exit {}: {}", outcome.code, report["error"])),
                        Ok(report) if report["checks"]["render"] != "passed" => Some(format!("render {}", report["checks"]["render"])),
                        Ok(report) if !(report["picture"]["visiblePixels"].as_u64() > Some(0) && report["picture"]["colors"].as_u64() > Some(1)) => Some(format!("an empty picture: {}", report["picture"])),
                        Ok(_) if !output.is_file() || png_size(&output) != (658, 340) => Some("no PNG of 658x340 pixels".to_owned()),
                        Ok(_) => None,
                    };
                    if let Some(keep) = &keep {
                        std::fs::create_dir_all(keep).unwrap();
                        let _ = std::fs::copy(&output, keep.join(output.file_name().unwrap()));
                    }
                    if let Some(problem) = problem {
                        failures.lock().unwrap().push(format!("{name}: {problem}"));
                    }
                }
            });
        }
    });
    let mut failures = failures.into_inner().unwrap();
    failures.sort();
    let skipped: Vec<&str> = templates.iter().filter(|(_, _, network)| *network).map(|(name, _, _)| name.as_str()).collect();
    println!("rendered {} of {} listed templates at medium; {} ask the network and were not drawn: {}", work.len() - failures.len(), templates.len(), skipped.len(), skipped.join(", "));
    assert!(work.len() > 100, "only {} templates to draw", work.len());
    assert!(failures.is_empty(), "{} of {} templates failed:\n{}", failures.len(), work.len(), failures.join("\n"));
}

#[test]
fn the_installed_layout_needs_no_settings_and_no_repository() {
    let sandbox = Sandbox::new();
    staged_resources(&sandbox.scratch);
    // <prefix>/bin/scriptwidget finds <prefix>/share/scriptwidget by itself.
    let program = sandbox.scratch.new_folder("prefix/bin").join("scriptwidget");
    std::fs::copy(env!("CARGO_BIN_EXE_scriptwidget"), &program).unwrap();
    let installed = |arguments: &[&str]| {
        let mut command = Command::new(&program);
        command.env_clear().env("HOME", sandbox.path("home")).current_dir(sandbox.work()).args(arguments);
        finish(&mut command)
    };
    let prefix = std::fs::canonicalize(sandbox.path("prefix")).unwrap();

    let doctor = installed(&["doctor"]).expect(0);
    assert_eq!(doctor["paths"]["runtime"], text(&prefix.join("share/scriptwidget/runtime")));
    assert_eq!(doctor["paths"]["templates"], text(&prefix.join("share/scriptwidget/templates")));
    assert_eq!(doctor["paths"]["data"], text(&sandbox.path("home/.local/share/scriptwidget")));
    for check in ["resources", "templates", "engine", "render", "dataDirectory"] {
        assert_eq!(doctor["checks"][check], "passed", "{check}: {doctor}");
    }
    assert_eq!(doctor["checks"]["service"], "notRun");
    assert_eq!(doctor["fonts"]["bundled"], true);
    assert_eq!(doctor["session"]["wayland"], false);
    assert!(!sandbox.path("home/.local").exists(), "doctor creates nothing");

    assert!(installed(&["templates"]).expect(0)["templates"].as_array().unwrap().len() > 100);
    installed(&["new", "Installed", "--template", "template/Countdown"]).expect(0);
    assert_has_a_picture(&installed(&["render", "Installed", "--output", "installed.png"]).expect(0));
    // The user's library follows the XDG directories.
    let report = installed(&["install", "Installed"]).expect(0);
    assert!(Path::new(report["directory"].as_str().unwrap()).starts_with(sandbox.path("home/.local/share/scriptwidget/Packages")), "{}", report["directory"]);
}

#[test]
fn missing_runtime_files_are_an_environment_error() {
    let sandbox = Sandbox::new();
    let package = sandbox.package("Widget", HELLO);
    let bare = |arguments: &[&str]| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_scriptwidget"));
        command.env_clear().env("HOME", sandbox.path("home")).env("XDG_DATA_DIRS", sandbox.path("no-data-dirs")).current_dir(sandbox.work()).args(arguments);
        finish(&mut command)
    };
    for arguments in [&["check", text(&package)][..], &["run", text(&package)], &["render", text(&package), "--output", "x.png"], &["templates"], &["timeline", text(&package)], &["pack", text(&package)]] {
        let outcome = bare(arguments);
        let report = outcome.expect(EXIT_USAGE);
        assert_eq!(report["error"]["kind"], "tool.resources_missing", "{arguments:?}");
        assert!(outcome.stderr.contains("SCRIPTWIDGET_RESOURCES"), "{}", outcome.stderr);
    }
    // doctor reports it as a failed check instead of stopping.
    let doctor = bare(&["doctor"]).expect(EXIT_FAILED);
    assert_eq!(doctor["checks"]["resources"], "failed");
    assert_eq!(doctor["checks"]["engine"], "notRun");
    // What needs no runtime files still works.
    bare(&["new", "Offline"]).expect(0);
    bare(&["list"]).expect(0);

    // A resource folder that is named but wrong is not silently replaced by another.
    let mut command = sandbox.command();
    command.env_remove("SCRIPTWIDGET_RUNTIME_ASSETS").env("SCRIPTWIDGET_RESOURCES", sandbox.path("nowhere"));
    assert_eq!(finish(command.args(["check", text(&package)])).expect(EXIT_USAGE)["error"]["kind"], "tool.resources_missing");
}

/// SHA-256, so that the test does not trust the program's own digest.
fn sha256(bytes: &[u8]) -> Vec<u8> {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).to_vec()
}

// Skills

const PRIVACY_REVIEW: &str = "app.scriptwidget.gallery.privacy-review";

fn skill_seed() -> PathBuf {
    repository().join("Gallery/skills/privacy-review")
}

fn skill<'a>(report: &'a Value, id: &str) -> &'a Value {
    report["skills"].as_array().expect("skills").iter().find(|skill| skill["id"] == id).unwrap_or_else(|| panic!("{id} is not listed"))
}

#[test]
fn skills_and_gallery_explain_themselves() {
    let sandbox = Sandbox::new();
    for group in ["skills", "gallery"] {
        let help = sandbox.run(&[group, "--help"]);
        assert_eq!(help.code, 0);
        assert!(help.stdout.starts_with(&format!("Usage: scriptwidget {group} <command>")) && help.stderr.is_empty());
        let bare = sandbox.run(&[group]);
        assert_eq!(bare.code, EXIT_USAGE);
        assert!(bare.stdout.starts_with("Usage: scriptwidget"));
        let unknown = sandbox.run(&[group, "frobnicate"]).expect(EXIT_USAGE);
        assert_eq!((unknown["command"].as_str(), unknown["error"]["kind"].as_str()), (Some(format!("{group} frobnicate").as_str()), Some("usage")));
    }
    assert!(sandbox.run(&["--help"]).stdout.contains("gallery install <id>"));
    assert!(!sandbox.data().join("Skills").exists(), "asking for help writes nothing");
}

#[test]
fn skills_are_listed_imported_enabled_and_removed() {
    let sandbox = Sandbox::new();
    let listed = sandbox.run(&["skills", "list"]).expect(0);
    assert_eq!(listed["command"], "skills list");
    let skills = listed["skills"].as_array().unwrap();
    assert_eq!(skills.len(), 5, "the Skills shipped with the program");
    assert!(skills.iter().all(|skill| skill["builtIn"] == true && skill["enabled"] == false && skill.get("instruction").is_none()));
    assert_eq!(listed["directory"], text(&sandbox.data().join("Skills")));

    // From a folder: the seed the Gallery ships.
    let imported = sandbox.run(&["skills", "import", text(&skill_seed())]).expect(0);
    assert_eq!((imported["skill"]["id"].as_str(), imported["skill"]["title"].as_str(), imported["skill"]["builtIn"].as_bool(), imported["skill"]["enabled"].as_bool()), (Some(PRIVACY_REVIEW), Some("Privacy Review"), Some(false), Some(false)));
    assert_eq!(support::tree(&sandbox.data().join("Skills")), ["privacy-review/", "privacy-review/SKILL.md", "privacy-review/skill.json"]);
    let shown = sandbox.run(&["skills", "show", PRIVACY_REVIEW]).expect(0);
    assert_eq!(shown["skill"]["instruction"].as_str().unwrap(), std::fs::read_to_string(skill_seed().join("SKILL.md")).unwrap());
    let again = sandbox.run(&["skills", "import", text(&skill_seed())]).expect(EXIT_FAILED);
    assert_eq!(again["error"]["kind"], "skills.duplicate_skill");

    // Enabled, it is named; a built-in can be enabled as well.
    let enabled = sandbox.run(&["skills", "enable", PRIVACY_REVIEW]).expect(0);
    assert_eq!((enabled["command"].as_str(), enabled["enabled"].as_bool()), (Some("skills enable"), Some(true)));
    sandbox.run(&["skills", "enable", "accessible-design"]).expect(0);
    let listed = sandbox.run(&["skills", "list"]).expect(0);
    assert_eq!((skill(&listed, PRIVACY_REVIEW)["enabled"].as_bool(), skill(&listed, "accessible-design")["enabled"].as_bool(), skill(&listed, "visual-polish")["enabled"].as_bool()), (Some(true), Some(true), Some(false)));
    let disabled = sandbox.run(&["skills", "disable", "accessible-design"]).expect(0);
    assert_eq!(disabled["enabledSkills"], serde_json::json!([PRIVACY_REVIEW]));
    assert_eq!(sandbox.run(&["skills", "enable", "com.example.missing"]).expect(EXIT_USAGE)["error"]["kind"], "skills.skill_not_found");
    sandbox.run(&["skills", "disable", "com.example.missing"]).expect(0);

    // Exported and imported by another user, byte for byte, and not enabled there.
    let exported = sandbox.run(&["skills", "export", PRIVACY_REVIEW]).expect(0);
    let archive = sandbox.work().join("privacy-review.swskill");
    assert_eq!(exported["output"], text(&archive));
    let entries = read_zip(&std::fs::read(&archive).unwrap());
    assert_eq!(entries.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["skill.json", "SKILL.md"]);
    assert_eq!(entries[0].1, std::fs::read(skill_seed().join("skill.json")).unwrap());
    assert_eq!(sandbox.run(&["skills", "export", PRIVACY_REVIEW]).expect(EXIT_USAGE)["error"]["kind"], "output.exists");
    sandbox.run(&["skills", "export", PRIVACY_REVIEW, "--force"]).expect(0);
    assert_eq!(sandbox.run(&["skills", "export", PRIVACY_REVIEW, "--output", "skill.txt"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    let other = Sandbox::new();
    let received = other.run(&["skills", "import", text(&archive)]).expect(0);
    assert_eq!((received["skill"]["id"].as_str(), received["skill"]["enabled"].as_bool()), (Some(PRIVACY_REVIEW), Some(false)));

    // Removed, it is gone and no longer enabled; what ships with the program stays.
    sandbox.run(&["skills", "remove", PRIVACY_REVIEW]).expect(0);
    let listed = sandbox.run(&["skills", "list"]).expect(0);
    assert_eq!(listed["skills"].as_array().unwrap().len(), 5);
    assert!(listed["skills"].as_array().unwrap().iter().all(|skill| skill["enabled"] == false));
    assert_eq!(sandbox.run(&["skills", "remove", PRIVACY_REVIEW]).expect(EXIT_USAGE)["error"]["kind"], "skills.skill_not_found");
    assert_eq!(sandbox.run(&["skills", "remove", "visual-polish"]).expect(EXIT_USAGE)["error"]["kind"], "skills.built_in_skill");
    assert_eq!(sandbox.run(&["skills", "show", "com.example.missing"]).expect(EXIT_USAGE)["error"]["kind"], "skills.skill_not_found");
}

#[test]
fn a_skill_that_is_more_than_two_text_files_is_refused() {
    let sandbox = Sandbox::new();
    let manifest = std::fs::read_to_string(skill_seed().join("skill.json")).unwrap();
    let archive = |name: &str, entries: &[RawEntry]| {
        let path = sandbox.work().join(name);
        std::fs::write(&path, raw_zip(entries)).unwrap();
        path
    };
    let json = || RawEntry::new("skill.json", manifest.as_str());
    let text_entry = || RawEntry::new("SKILL.md", "Prefer on-device data.");
    let with_tool = manifest.replacen('{', "{\"tools\":[\"shell\"],", 1);
    let refused = [
        (archive("payload.swskill", &[json(), text_entry(), RawEntry::new("run.sh", "#!/bin/sh")]), "skills.invalid_package"),
        (archive("traversal.swskill", &[json(), text_entry(), RawEntry::new("../escape.md", "x")]), "skills.invalid_archive"),
        (archive("link.swskill", &[json(), RawEntry::new("SKILL.md", "/etc/passwd").mode(SYMBOLIC_LINK)]), "skills.invalid_archive"),
        (archive("tools.swskill", &[RawEntry::new("skill.json", with_tool.as_str()), text_entry()]), "skills.unknown_field"),
        (archive("permissions.swskill", &[RawEntry::new("skill.json", manifest.replacen('{', "{\"permissions\":[\"network\"],", 1)), text_entry()]), "skills.unknown_field"),
        (archive("version.swskill", &[RawEntry::new("skill.json", manifest.replace("\"formatVersion\": 1", "\"formatVersion\": 2")), text_entry()]), "skills.invalid_skill"),
        (archive("large.swskill", &[json(), RawEntry::new("SKILL.md", "x".repeat(64 * 1024 + 1))]), "skills.invalid_archive"),
    ];
    for (path, code) in &refused {
        let report = sandbox.run(&["skills", "import", text(path)]).expect(EXIT_FAILED);
        assert_eq!(report["error"]["kind"], *code, "{}", path.display());
    }
    // A folder with anything else in it, and a file that is not there.
    let folder = sandbox.scratch.new_folder("work/skill");
    sandbox.scratch.new_file("work/skill/skill.json", &manifest);
    sandbox.scratch.new_file("work/skill/SKILL.md", "Prefer on-device data.");
    sandbox.scratch.new_file("work/skill/install.sh", "#!/bin/sh");
    assert_eq!(sandbox.run(&["skills", "import", text(&folder)]).expect(EXIT_FAILED)["error"]["kind"], "skills.invalid_package");
    assert_eq!(sandbox.run(&["skills", "import", "nothing.swskill"]).expect(EXIT_USAGE)["error"]["kind"], "input.file");
    assert_eq!(support::tree(&sandbox.data().join("Skills")), [] as [&str; 0], "nothing was stored");
    assert!(!sandbox.work().join("../escape.md").exists() && !sandbox.data().join("escape.md").exists());
    assert_eq!(sandbox.run(&["skills", "list"]).expect(0)["skills"].as_array().unwrap().len(), 5);
}

// The Gallery, from a copy of the catalog that is already on disk. The program cannot be pointed at
// another server, so nothing here fetches anything; installing is tested in `src/gallery.rs`.

/// Puts the catalog checked into this repository where the program keeps its verified copy, as if fetched just now.
fn seed_catalog(sandbox: &Sandbox, index: &[u8]) {
    let cache = sandbox.scratch.new_folder("data/Cache/Gallery");
    std::fs::write(cache.join("index.json"), index).unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
    std::fs::write(cache.join("metadata.json"), format!("{{\"fetchedAt\":{now}}}")).unwrap();
}

#[test]
fn the_gallery_is_listed_and_shown_from_the_verified_copy() {
    let sandbox = Sandbox::new();
    seed_catalog(&sandbox, &std::fs::read(repository().join("Gallery/index.json")).unwrap());
    let listed = sandbox.run(&["gallery", "list"]).expect(0);
    assert_eq!(listed["command"], "gallery list");
    assert_eq!((listed["catalog"]["offline"].as_bool(), listed["catalog"]["url"].as_str()), (Some(false), Some("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json")));
    let items = listed["items"].as_array().unwrap();
    assert_eq!(listed["catalog"]["items"], items.len());
    assert!(items.len() >= 2 && items.iter().all(|item| item["install"]["state"] == "notInstalled"));
    let hello = items.iter().find(|item| item["id"] == "app.scriptwidget.gallery.hello-card").expect("the hello card");
    assert_eq!((hello["kind"].as_str(), hello["name"].as_str(), hello["files"].as_u64()), (Some("widget"), Some("Gallery Hello Card"), Some(2)));
    let skills = sandbox.run(&["gallery", "list", "--kind", "skill"]).expect(0);
    assert_eq!(skills["items"].as_array().unwrap().iter().map(|item| item["id"].as_str().unwrap()).collect::<Vec<_>>(), [PRIVACY_REVIEW]);

    let shown = sandbox.run(&["gallery", "show", PRIVACY_REVIEW]).expect(0);
    let files = shown["item"]["files"].as_array().unwrap();
    assert_eq!(files.len(), 2);
    for file in files {
        let local = std::fs::read(skill_seed().join(file["path"].as_str().unwrap())).unwrap();
        assert_eq!((file["bytes"].as_u64(), file["sha256"].as_str().map(str::to_owned)), (Some(local.len() as u64), Some(hex(&sha256(&local)))));
    }
    assert_eq!(sandbox.run(&["gallery", "show", "com.example.missing"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    assert_eq!(sandbox.run(&["gallery", "install", "com.example.missing"]).expect(EXIT_USAGE)["error"]["kind"], "usage");
    // There is no way to name another catalog.
    for arguments in [&["gallery", "list", "--index", "https://example.com/index.json"][..], &["gallery", "list", "--url=https://example.com/index.json"], &["gallery", "install", "--from", "https://example.com", PRIVACY_REVIEW]] {
        assert_eq!(sandbox.run(arguments).expect(EXIT_USAGE)["error"]["kind"], "usage", "{arguments:?}");
    }
    assert_eq!(package_files(&sandbox.data().join("Packages")), [] as [&str; 0]);
    assert!(!sandbox.data().join("gallery-installations.json").exists() && !sandbox.data().join("Skills").exists());
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

// Data access: what the user grants and picks for a widget

/// An installed package that declares `permissions` and Runtime 1.6.
fn install_with(sandbox: &Sandbox, name: &str, permissions: &str) {
    let directory = sandbox.scratch.new_folder(&format!("work/{name}"));
    sandbox.scratch.new_file(&format!("work/{name}/main.jsx"), "$render(<text>hi</text>);");
    sandbox.scratch.new_file(&format!("work/{name}/widget.json"), &manifest(name, r#","minimumRuntimeVersion":"1.6""#).replace(r#""permissions":[]"#, &format!(r#""permissions":[{permissions}]"#)));
    sandbox.run(&["install", text(&directory)]).expect(0);
}

#[test]
fn the_data_access_commands_explain_themselves() {
    let sandbox = Sandbox::new();
    for group in ["services", "notifications", "documents", "photos"] {
        let help = sandbox.run(&[group, "--help"]);
        assert_eq!(help.code, 0);
        assert!(help.stdout.starts_with("Usage: scriptwidget <services | notifications | documents | photos> <command>") && help.stderr.is_empty());
        assert_eq!(sandbox.run(&[group]).code, EXIT_USAGE);
        let unknown = sandbox.run(&[group, "frobnicate"]).expect(EXIT_USAGE);
        assert_eq!((unknown["command"].as_str(), unknown["error"]["kind"].as_str()), (Some(format!("{group} frobnicate").as_str()), Some("usage")));
    }
    let usage = sandbox.run(&["--help"]).stdout;
    for line in ["services status | connect | disconnect", "notifications status [<package>]", "documents list <package>", "photos list <package>", "reload  "] {
        assert!(usage.contains(line), "{line}");
    }
    assert!(!sandbox.data().join("System").exists(), "asking for help writes nothing");
    // The interval is the service's to apply: without one the command says so.
    assert_eq!(sandbox.run(&["reload"]).expect(EXIT_NEEDS_SERVICE)["error"]["kind"], "service.unavailable");
}

#[test]
fn documents_are_picked_listed_and_removed_per_widget() {
    let sandbox = Sandbox::new();
    install_with(&sandbox, "Budget", r#""documents""#);
    install_with(&sandbox, "Other", "");
    let budget = sandbox.scratch.new_file("home/Documents/budget.json", r#"{"total": 12.5}"#);
    let rows = sandbox.scratch.new_file("home/Documents/rows.csv", "a,b\n1,2\n");
    assert_eq!(sandbox.run(&["documents", "list", "Budget"]).expect(0)["documents"], serde_json::json!([]));
    let added = sandbox.run(&["documents", "add", "Budget", text(&budget)]).expect(0);
    assert_eq!((added["added"]["name"].as_str(), added["added"]["type"].as_str(), added["declared"].as_bool()), (Some("budget.json"), Some("json"), Some(true)));
    // A path relative to where the command runs is recorded as the absolute one.
    std::fs::copy(&rows, sandbox.work().join("rows.csv")).unwrap();
    let relative = sandbox.run(&["documents", "add", "Budget", "rows.csv"]).expect(0);
    assert!(Path::new(relative["added"]["path"].as_str().unwrap()).is_absolute());
    let listed = sandbox.run(&["documents", "list", "Budget"]).expect(0);
    let documents = listed["documents"].as_array().unwrap();
    assert_eq!(documents.iter().map(|document| (document["name"].as_str().unwrap(), document["bytes"].as_u64().unwrap())).collect::<Vec<_>>(), [("budget.json", 15), ("rows.csv", 8)]);
    assert_eq!(sandbox.run(&["documents", "list", "Other"]).expect(0)["documents"], serde_json::json!([]), "a list is one widget's");
    // The record is private to the user and below System/ in the data folder.
    use std::os::unix::fs::PermissionsExt;
    let index = support::tree(&sandbox.data().join("System/Documents")).into_iter().find(|path| path.ends_with("index.json")).expect("the index");
    assert_eq!(std::fs::metadata(sandbox.data().join("System/Documents").join(&index)).unwrap().permissions().mode() & 0o777, 0o600);

    // What cannot be a widget's document is refused with the reason; a widget that does not ask for documents gets a warning.
    let cases = [("notes.txt", "{}", "documents.unsupported_type"), ("broken.json", "{ nope", "documents.invalid_content"), ("scalar.json", "7", "documents.invalid_content"), ("ragged.csv", "a,b\n1\n", "documents.invalid_content")];
    for (name, content, code) in cases {
        let file = sandbox.scratch.new_file(&format!("home/{name}"), content);
        assert_eq!(sandbox.run(&["documents", "add", "Budget", text(&file)]).expect(EXIT_FAILED)["error"]["kind"], code, "{name}");
    }
    let large = sandbox.scratch.new_file("home/large.json", &format!("[\"{}\"]", "x".repeat(262_144)));
    assert_eq!(sandbox.run(&["documents", "add", "Budget", text(&large)]).expect(EXIT_FAILED)["error"]["kind"], "documents.too_large");
    assert_eq!(sandbox.run(&["documents", "add", "Budget", text(&budget)]).expect(EXIT_FAILED)["error"]["kind"], "documents.duplicate");
    assert_eq!(sandbox.run(&["documents", "add", "Budget", "/nonexistent/x.json"]).expect(EXIT_FAILED)["error"]["kind"], "documents.unreadable");
    assert_eq!(sandbox.run(&["documents", "add", "Missing", text(&budget)]).expect(EXIT_USAGE)["error"]["kind"], "package.unknown");
    let undeclared = sandbox.run(&["documents", "add", "Other", text(&budget)]).expect(0);
    assert_eq!((undeclared["declared"].as_bool(), codes(&undeclared)), (Some(false), vec!["permission.undeclared"]));

    let id = documents[0]["id"].as_str().unwrap();
    let removed = sandbox.run(&["documents", "remove", "Budget", id]).expect(0);
    assert_eq!(removed["documents"].as_array().unwrap().len(), 1);
    assert!(budget.is_file(), "the file itself is not touched");
    assert_eq!(sandbox.run(&["documents", "remove", "Budget", id]).expect(EXIT_USAGE)["error"]["kind"], "documents.not_found");
    assert_eq!(sandbox.run(&["documents", "remove", "Budget", "../../etc"]).expect(EXIT_USAGE)["error"]["kind"], "documents.not_found");
}

#[test]
fn pictures_are_picked_as_thumbnails_and_what_is_no_picture_is_refused() {
    let sandbox = Sandbox::new();
    install_with(&sandbox, "Frame", r#""photos""#);
    // A real picture: this program's own drawing of a widget.
    let package = sandbox.package("Drawn", r##"$render(<vstack frame="max" background="#1d4ed8"><text color="white">picture</text></vstack>);"##);
    let picture = sandbox.path("home/picture.png");
    sandbox.run(&["render", text(&package), "--output", text(&picture), "--family", "large", "--scale", "3"]).expect(0);
    let added = sandbox.run(&["photos", "add", "Frame", text(&picture)]).expect(0);
    assert_eq!((added["added"]["width"].as_u64(), added["added"]["height"].as_u64()), (Some(987), Some(1035)), "the original size");
    let listed = sandbox.run(&["photos", "list", "Frame"]).expect(0);
    assert_eq!((listed["photos"].as_array().unwrap().len(), listed["photos"][0]["readable"].as_bool()), (1, Some(true)));
    // The thumbnail is a JPEG in the cache folder, no larger than the limits.
    let thumbnails: Vec<String> = support::tree(&sandbox.data().join("Cache/photos")).into_iter().filter(|path| path.ends_with(".jpg")).collect();
    assert_eq!(thumbnails.len(), 1);
    let bytes = std::fs::read(sandbox.data().join("Cache/photos").join(&thumbnails[0])).unwrap();
    assert!(bytes.starts_with(&[0xff, 0xd8, 0xff]) && bytes.len() <= 128 * 1024, "{} bytes", bytes.len());

    let text_file = sandbox.scratch.new_file("home/notes.png", "not a picture");
    assert_eq!(sandbox.run(&["photos", "add", "Frame", text(&text_file)]).expect(EXIT_FAILED)["error"]["kind"], "photos.invalid_content");
    assert_eq!(sandbox.run(&["photos", "add", "Frame", text(&picture)]).expect(EXIT_FAILED)["error"]["kind"], "photos.duplicate");
    assert_eq!(sandbox.run(&["photos", "add", "Frame", text(&sandbox.work())]).expect(EXIT_FAILED)["error"]["kind"], "photos.unreadable");
    let id = listed["photos"][0]["id"].as_str().unwrap();
    assert_eq!(sandbox.run(&["photos", "remove", "Frame", id]).expect(0)["photos"], serde_json::json!([]));
    assert!(picture.is_file());
}

#[test]
fn notifications_are_allowed_per_widget_and_services_start_unconnected() {
    let sandbox = Sandbox::new();
    install_with(&sandbox, "Reminder", r#""notifications""#);
    install_with(&sandbox, "Quiet", "");
    let status = sandbox.run(&["notifications", "status"]).expect(0);
    // No session bus in the test's empty environment: no service is running, and nothing is shown anywhere.
    assert_eq!(status["serviceRunning"], false);
    assert_eq!(status["widgets"], serde_json::json!([{"package": "Reminder", "declared": true, "allowed": false, "pending": []}]), "only the widgets that ask");
    let allowed = sandbox.run(&["notifications", "allow", "Reminder"]).expect(0);
    assert_eq!((allowed["allowed"].as_bool(), allowed["declared"].as_bool()), (Some(true), Some(true)));
    assert_eq!(sandbox.run(&["notifications", "status", "Reminder"]).expect(0)["widgets"][0]["allowed"], true);
    assert_eq!(codes(&sandbox.run(&["notifications", "allow", "Quiet"]).expect(0)), ["permission.undeclared"]);
    let denied = sandbox.run(&["notifications", "deny", "Reminder"]).expect(0);
    assert_eq!((denied["allowed"].as_bool(), denied["cancelled"].as_u64()), (Some(false), Some(0)));
    assert_eq!(sandbox.run(&["notifications", "status", "Reminder"]).expect(0)["widgets"][0]["allowed"], false);
    assert_eq!(sandbox.run(&["notifications", "allow", "Missing"]).expect(EXIT_USAGE)["error"]["kind"], "package.unknown");

    // $services: nothing is connected, and nothing can be allowed before something is.
    assert_eq!(sandbox.run(&["services", "status"]).expect(0)["github"], serde_json::json!({"service": "github", "connected": false}));
    assert_eq!(sandbox.run(&["services", "allow", "Reminder"]).expect(EXIT_USAGE)["error"]["kind"], "services.service_not_connected");
    // What is not a fine-grained token is refused before anything is sent anywhere (the input here is not one).
    let mut command = sandbox.command();
    command.args(["services", "connect"]).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    let mut child = command.spawn().unwrap();
    std::io::Write::write_all(child.stdin.as_mut().unwrap(), b"not-a-token-at-all\n").unwrap();
    let output = child.wait_with_output().unwrap();
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!((output.status.code(), report["error"]["kind"].as_str()), (Some(EXIT_USAGE), Some("services.service_credential")));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("not-a-token-at-all") && !String::from_utf8_lossy(&output.stderr).contains("not-a-token-at-all"), "what was typed is not repeated");
    assert!(!sandbox.data().join("System/services.json").exists());
}
