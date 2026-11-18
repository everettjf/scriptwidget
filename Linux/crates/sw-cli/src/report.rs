//! The JSON report every command prints, and the fixed exit codes.
//!
//! The envelope is the one of the Mac command line
//! (`Tools/ScriptWidgetCLI/Resources/report-v1.schema.json`): `reportVersion`,
//! `command`, `status`, `tool`, `diagnostics`, and for package commands
//! `checks`, `backend`, `sourceHash` and `artifacts`. The other members are
//! the ones the Windows `swcli` prints for the same command (`ok`, `error`,
//! `tree`, `logs`, `pixelWidth`, …), under the same names.

use std::io::{IsTerminal, Write};

use serde_json::{Map, Value, json};
use sw_core::packages::PackageError;

/// The command succeeded.
pub const EXIT_PASSED: i32 = 0;
/// The package, the archive or the script is at fault: an invalid manifest, a compile or script error, an unsafe archive entry.
pub const EXIT_FAILED: i32 = 1;
/// The command line is wrong, or the environment is: a missing folder, an output that cannot be written, missing runtime files.
pub const EXIT_USAGE: i32 = 2;
/// ScriptWidget itself failed.
pub const EXIT_INTERNAL: i32 = 3;
/// The command needs the background service, which is not running (`EX_UNAVAILABLE` of sysexits.h).
pub const EXIT_NEEDS_SERVICE: i32 = 69;

/// Why a command stopped before it had a result of its own.
#[derive(Debug)]
pub struct Failure {
    pub exit: i32,
    pub code: String,
    pub message: String,
}

impl Failure {
    pub fn new(exit: i32, code: &str, message: impl Into<String>) -> Self {
        Self { exit, code: code.to_owned(), message: message.into() }
    }

    pub fn usage(message: impl Into<String>) -> Self {
        Self::new(EXIT_USAGE, "usage", message)
    }

    /// A problem of the machine or the installation, not of the package.
    pub fn environment(code: &str, message: impl Into<String>) -> Self {
        Self::new(EXIT_USAGE, code, message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(EXIT_INTERNAL, "tool.internal", message)
    }
}

impl From<PackageError> for Failure {
    /// The package layer's codes are the diagnostics' codes. Only a library that cannot be used is the machine's fault.
    fn from(error: PackageError) -> Self {
        let exit = if error.code == sw_core::packages::codes::STORAGE_UNAVAILABLE { EXIT_USAGE } else { EXIT_FAILED };
        Self { exit, code: error.code, message: error.message }
    }
}

pub const STAGES: [&str; 5] = ["package", "compile", "execute", "render", "export"];

pub struct Report {
    fields: Map<String, Value>,
    diagnostics: Vec<Value>,
    checks: Option<Map<String, Value>>,
    exit: i32,
}

impl Report {
    pub fn new(command: &str) -> Self {
        let mut fields = Map::new();
        fields.insert("reportVersion".into(), json!(1));
        fields.insert("command".into(), json!(command));
        fields.insert("status".into(), Value::Null);
        fields.insert("ok".into(), Value::Null);
        fields.insert("tool".into(), json!({ "name": "scriptwidget", "version": env!("CARGO_PKG_VERSION"), "platform": "linux", "architecture": std::env::consts::ARCH }));
        Self { fields, diagnostics: Vec::new(), checks: None, exit: EXIT_PASSED }
    }

    /// A report for a package command: the five stages start as "notRun".
    pub fn with_stages(command: &str, backend: &str) -> Self {
        let mut report = Self::new(command);
        report.set("backend", json!(backend));
        report.checks = Some(STAGES.iter().map(|stage| ((*stage).to_owned(), json!("notRun"))).collect());
        report
    }

    pub fn set(&mut self, name: &str, value: Value) {
        self.fields.insert(name.to_owned(), value);
    }

    pub fn check(&mut self, name: &str, passed: bool) {
        self.checks.get_or_insert_with(Map::new).insert(name.to_owned(), json!(if passed { "passed" } else { "failed" }));
    }

    pub fn check_not_run(&mut self, name: &str) {
        self.checks.get_or_insert_with(Map::new).insert(name.to_owned(), json!("notRun"));
    }

    pub fn diagnostic(&mut self, severity: &str, code: &str, message: &str) {
        self.diagnostics.push(json!({ "severity": severity, "code": code, "message": message }));
    }

    /// Diagnostics as another layer produced them: objects with `severity`, `code` and `message`.
    pub fn diagnostics(&mut self, items: impl IntoIterator<Item = Value>) {
        self.diagnostics.extend(items.into_iter().filter(Value::is_object));
    }

    pub fn has_warning(&self) -> bool {
        self.diagnostics.iter().any(|item| item["severity"] == "warning")
    }

    /// Marks the command as failed with `error` as its reason: `{kind, message}`, as the Windows reports have it.
    pub fn fail(&mut self, exit: i32, kind: &str, message: &str) {
        if self.exit == EXIT_PASSED {
            self.exit = exit;
            self.set("error", json!({ "kind": kind, "message": message }));
            self.diagnostic("error", kind, message);
        }
    }

    /// Fails a report that passed so far, without replacing an earlier reason.
    pub fn fail_on_warnings(&mut self) {
        if self.exit == EXIT_PASSED && self.has_warning() {
            self.exit = EXIT_FAILED;
        }
    }

    pub fn from_failure(command: &str, failure: &Failure) -> Self {
        let mut report = Self::new(command);
        report.fail(failure.exit, &failure.code, &failure.message);
        report
    }

    /// Adds a failure that happened part-way to a report that already has results.
    pub fn absorb(&mut self, failure: &Failure) {
        self.fail(failure.exit, &failure.code, &failure.message);
    }

    /// Prints the report to standard output and its errors and warnings to standard error; returns the exit code.
    pub fn finish(mut self) -> i32 {
        let status = match self.exit {
            EXIT_PASSED => "passed",
            EXIT_FAILED => "failed",
            _ => "error",
        };
        self.fields.insert("status".into(), json!(status));
        self.fields.insert("ok".into(), json!(self.exit == EXIT_PASSED));
        if !self.fields.contains_key("error") {
            self.fields.insert("error".into(), Value::Null);
        }
        if let Some(checks) = self.checks.take() {
            self.fields.insert("checks".into(), Value::Object(checks));
        }
        print_diagnostics(&self.diagnostics);
        self.fields.insert("diagnostics".into(), Value::Array(std::mem::take(&mut self.diagnostics)));
        let text = serde_json::to_string_pretty(&Value::Object(self.fields)).unwrap_or_else(|_| "{}".into());
        let mut output = std::io::stdout().lock();
        // A closed pipe is the reader's choice; the exit code still tells the result.
        let _ = writeln!(output, "{text}");
        let _ = output.flush();
        self.exit
    }
}

/// True when messages for a person may carry color: both streams are a
/// terminal, and the user did not ask for plain text. Reports are never colored.
fn color() -> bool {
    std::io::stdout().is_terminal()
        && std::io::stderr().is_terminal()
        && std::env::var_os("NO_COLOR").is_none_or(|value| value.is_empty())
        && std::env::var_os("TERM").is_none_or(|term| term != "dumb")
}

fn print_diagnostics(diagnostics: &[Value]) {
    let color = color();
    let mut errors = std::io::stderr().lock();
    for item in diagnostics {
        let severity = item["severity"].as_str().unwrap_or("error");
        if severity != "error" && severity != "warning" {
            continue;
        }
        let (start, end) = match (color, severity) {
            (false, _) => ("", ""),
            (true, "warning") => ("\x1b[33m", "\x1b[0m"),
            (true, _) => ("\x1b[31m", "\x1b[0m"),
        };
        // Control characters of a message that came from a package never reach the terminal.
        let message: String = item["message"].as_str().unwrap_or("").chars().map(|character| if character.is_control() && character != '\n' { ' ' } else { character }).collect();
        let _ = writeln!(errors, "{start}{severity}{end}: [{}] {message}", item["code"].as_str().unwrap_or(""));
    }
}
