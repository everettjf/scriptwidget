//! Runs the built `scriptwidget` program as the background service
//! (`scriptwidget host run`) and as its clients, in a session of its own: a
//! temporary runtime directory, a temporary data directory, and a search
//! path that holds nothing but two recording stand-ins for `xdg-open` and
//! `scriptwidget-studio`. No browser is started, no system bus is asked, and
//! the user's own service is never touched.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-cli --test desktop

use std::io::{BufRead, BufReader};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use serde_json::Value;

const EXIT_FAILED: i32 = 1;
const EXIT_USAGE: i32 = 2;
const EXIT_NEEDS_SERVICE: i32 = 69;
const WAIT: Duration = Duration::from_secs(30);
const ID: &str = "0123456789abcdef";

fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
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
        assert_eq!(report["ok"], code == 0);
        report
    }
}

/// The output of a running command, line by line.
struct Lines {
    child: Child,
    lines: Receiver<String>,
}

impl Lines {
    fn start(command: &mut Command) -> Self {
        let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().expect("the program starts");
        let output = child.stdout.take().unwrap();
        let (sender, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines().map_while(Result::ok) {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self { child, lines }
    }

    #[track_caller]
    fn next(&mut self) -> Value {
        let line = self.lines.recv_timeout(WAIT).expect("another line");
        serde_json::from_str(&line).unwrap_or_else(|error| panic!("not JSON ({error}): {line}"))
    }

    #[track_caller]
    fn event(&mut self, wanted: impl Fn(&Value) -> bool) -> Value {
        loop {
            let event = self.next();
            if wanted(&event) {
                return event;
            }
        }
    }

    /// Waits for the command to end; returns its exit code and the lines it had not been asked for yet.
    #[track_caller]
    fn finish(mut self) -> (i32, Vec<Value>) {
        let deadline = Instant::now() + WAIT;
        let code = loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                break status.code().expect("the program exits by itself");
            }
            assert!(Instant::now() < deadline, "the command ends");
            std::thread::sleep(Duration::from_millis(20));
        };
        let mut rest = Vec::new();
        while let Ok(line) = self.lines.recv_timeout(Duration::from_secs(2)) {
            rest.push(serde_json::from_str(&line).unwrap());
        }
        (code, rest)
    }
}

impl Drop for Lines {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One user's session with nothing in it but ScriptWidget.
struct Desk {
    root: PathBuf,
    service: Option<Child>,
}

impl Desk {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        // Short: the path of a socket is limited to about a hundred bytes.
        let root = PathBuf::from("/tmp").join(format!("swd-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&root);
        for folder in ["", "run", "home", "work", "bin"] {
            std::fs::DirBuilder::new().mode(0o700).create(root.join(folder)).unwrap();
        }
        // Stand-ins that write their arguments, one a line, and start nothing.
        for program in ["xdg-open", "scriptwidget-studio"] {
            let path = root.join("bin").join(program);
            std::fs::write(&path, format!("#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done >> '{}'\n", root.join(format!("{program}.log")).display())).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        Self { root, service: None }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }

    fn socket(&self) -> PathBuf {
        self.path("run/scriptwidget/host.sock")
    }

    /// A command with nothing inherited: no display, no bus, no programs but the stand-ins.
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_scriptwidget"));
        command.env_clear();
        command.env("HOME", self.path("home")).env("SCRIPTWIDGET_DATA", self.path("data")).env("XDG_RUNTIME_DIR", self.path("run")).env("PATH", self.path("bin"));
        command.env("TZ", "UTC").env("LANG", "en_US.UTF-8");
        command.env("SCRIPTWIDGET_RUNTIME_ASSETS", repository().join("Linux/assets/scriptwidget")).env("SCRIPTWIDGET_TEMPLATES", repository().join("Shared/ScriptWidgetRuntime/Resource/Script.bundle"));
        command.current_dir(self.path("work"));
        command
    }

    fn run(&self, arguments: &[&str]) -> Outcome {
        let output = self.command().args(arguments).output().expect("the program starts");
        Outcome { code: output.status.code().expect("the program exits by itself"), stdout: String::from_utf8(output.stdout).unwrap(), stderr: String::from_utf8(output.stderr).unwrap() }
    }

    #[track_caller]
    fn ok(&self, arguments: &[&str]) -> Value {
        self.run(arguments).expect(0)
    }

    fn start_service(&mut self) {
        let log = std::fs::File::create(self.path("service.log")).unwrap();
        let child = self.command().args(["host", "run"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(log).spawn().expect("the service starts");
        self.service = Some(child);
        let deadline = Instant::now() + WAIT;
        while self.run(&["widgets"]).code != 0 {
            assert!(Instant::now() < deadline, "the service answers: {}", self.service_log());
            std::thread::sleep(Duration::from_millis(30));
        }
    }

    fn service_log(&self) -> String {
        std::fs::read_to_string(self.path("service.log")).unwrap_or_default()
    }

    /// Sends a signal to the service and returns how it ended: its exit code, or `None` when the signal ended it.
    fn signal_service(&mut self, signal: i32) -> Option<i32> {
        let mut child = self.service.take().expect("a running service");
        // SAFETY: the child is ours and has not been waited for, so the identifier is still its own.
        unsafe { libc::kill(child.id() as i32, signal) };
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                return status.code();
            }
            assert!(Instant::now() < deadline, "the service ends: {}", self.service_log());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn package(&self, name: &str, source: &str, extra: &str) -> PathBuf {
        let directory = self.path(&format!("work/{name}"));
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("main.jsx"), source).unwrap();
        std::fs::write(
            directory.join("widget.json"),
            format!(
                r#"{{"formatVersion":2,"id":"com.example.{}","name":"{name}","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall","systemMedium","systemLarge"],"permissions":["storage"],"networkDomains":[]{extra}}}"#,
                name.to_lowercase()
            ),
        )
        .unwrap();
        directory
    }

    fn widget(&self, id: &str) -> Value {
        self.ok(&["widgets"])["widgets"].as_array().unwrap().iter().find(|widget| widget["id"] == id).cloned().unwrap_or_else(|| panic!("no widget {id}"))
    }

    #[track_caller]
    fn until(&self, id: &str, what: &str, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            let widget = self.widget(id);
            if done(&widget) {
                return widget;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}: {widget}");
            std::thread::sleep(Duration::from_millis(30));
        }
    }

    fn log(&self, program: &str) -> Vec<String> {
        std::fs::read_to_string(self.path(&format!("{program}.log"))).unwrap_or_default().lines().map(str::to_owned).collect()
    }
}

impl Drop for Desk {
    fn drop(&mut self) {
        if let Some(mut child) = self.service.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

const COUNTER: &str = r##"
function bump() { $storage.setString("count", String(Number($storage.getString("count") || "0") + 1)); }
const count = $storage.getString("count") || "0";
$render(
  <vstack frame="max" background="#1f2937">
    <button onClick="bump"><text color="white">{"Count " + count}</text></button>
    <link url="https://example.com/?q=a&b=$(id) ;x"><text color="white">web</text></link>
    <link url="javascript:alert(1)"><text color="white">script</text></link>
  </vstack>
);
"##;

#[test]
fn without_the_service_desktop_commands_exit_69_and_say_how_to_start_it() {
    let desk = Desk::new();
    let commands: [&[&str]; 13] = [
        &["add", "Clock", "--family", "small"],
        &["remove", ID],
        &["widgets"],
        &["refresh"],
        &["peek"],
        &["arrange", "on"],
        &["tap", ID, "0"],
        &["move", ID, "eDP-1", "-10", "20"],
        &["screen", "eDP-1", "1.5", "1920", "1200"],
        &["theme", "dark"],
        &["menu", ID, "resize-small"],
        &["session", "locked"],
        &["dev", "."],
    ];
    for arguments in commands {
        let outcome = desk.run(arguments);
        let report = outcome.expect(EXIT_NEEDS_SERVICE);
        assert_eq!(report["command"], arguments[0]);
        assert_eq!(report["error"]["kind"], "service.unavailable");
        assert!(outcome.stderr.contains("needs the background service, which is not running. Start it with: systemctl --user start scriptwidget.service"), "{}", outcome.stderr);
    }
    // `watch` prints events, not a report: one `bye` that says why there is nothing to watch.
    let outcome = desk.run(&["watch"]);
    assert_eq!(outcome.code, EXIT_NEEDS_SERVICE);
    assert_eq!(outcome.stdout, "{\"event\":\"bye\",\"reason\":\"not-running\"}\n");
    assert!(outcome.stderr.contains("[service.unavailable]") && outcome.stderr.contains("systemctl --user start scriptwidget.service"), "{}", outcome.stderr);
    // The same without a session at all.
    let output = desk.command().env_remove("XDG_RUNTIME_DIR").args(["widgets"]).output().unwrap();
    assert_eq!(output.status.code(), Some(EXIT_NEEDS_SERVICE));
    // Nothing was created by asking.
    assert!(!desk.path("run/scriptwidget").exists() && !desk.path("data").exists());

    // A wrong argument is a usage error, with or without a service.
    let wrong: [&[&str]; 14] = [
        &["add"],
        &["add", "../etc"],
        &["add", "Clock", "--family", "huge"],
        &["remove", "not-an-id"],
        &["remove", "../../../etc/passwd"],
        &["tap", ID, "one"],
        &["tap", ID, "-1"],
        &["move", ID, "a screen", "1", "2"],
        &["move", ID, "eDP-1", "1"],
        &["screen", "eDP-1", "big", "1", "1"],
        &["screen", "eDP-1", "100", "1920", "1080"],
        &["theme", "blue"],
        &["menu", ID, "delete-everything"],
        &["host", "walk"],
    ];
    for arguments in wrong {
        let report = desk.run(arguments).expect(EXIT_USAGE);
        assert_eq!(report["error"]["kind"], "usage", "{arguments:?}");
    }
}

#[test]
fn the_command_line_drives_the_service() {
    let mut desk = Desk::new();
    desk.package("Counter", COUNTER, "");
    assert_eq!(desk.ok(&["install", "Counter"])["name"], "Counter");
    desk.start_service();
    let doctor = desk.ok(&["doctor"]);
    assert_eq!(doctor["checks"]["service"], "passed");
    assert_eq!((doctor["service"]["running"].as_bool(), doctor["service"]["protocol"].as_u64()), (Some(true), Some(1)));

    let mut watch = Lines::start(desk.command().arg("watch"));
    assert_eq!(watch.next()["event"], "hello");
    assert_eq!(desk.run(&["add", "Missing"]).expect(EXIT_USAGE)["error"]["kind"], "package.unknown");
    assert_eq!(desk.run(&["add", "Counter", "--family", "extraLarge"]).expect(EXIT_FAILED)["error"]["kind"], "family.unsupported");
    let added = desk.ok(&["add", "Counter", "--family", "large"]);
    let id = added["id"].as_str().unwrap().to_owned();
    let first = watch.event(|event| event["event"] == "widget");
    assert_eq!((first["id"].as_str(), first["version"].as_u64(), first["height"].as_u64()), (Some(id.as_str()), Some(1), Some(345)));
    assert_eq!(first["regions"].as_array().unwrap().len(), 3);
    assert!(Path::new(first["image"].as_str().unwrap()).starts_with(desk.path("run/scriptwidget/frames")));

    // A tap on the button: the picture changes.
    assert_eq!(desk.ok(&["tap", &id, "0"])["action"], "button");
    let second = watch.event(|event| event["event"] == "widget");
    assert_eq!(second["version"], 2);
    assert_ne!(second["image"], first["image"]);
    assert_eq!(desk.ok(&["tap", &id, "0", "2"])["action"], "button");
    assert_eq!(watch.event(|event| event["event"] == "widget")["version"], 3);
    assert_eq!(desk.run(&["tap", &id, "9"]).expect(EXIT_USAGE)["error"]["kind"], "region.unknown");

    // A link goes to xdg-open as one argument, whatever is in it; a script address goes nowhere.
    assert_eq!(desk.ok(&["tap", &id, "1"])["action"], "link");
    let deadline = Instant::now() + WAIT;
    while desk.log("xdg-open").is_empty() {
        assert!(Instant::now() < deadline, "xdg-open was started");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(desk.log("xdg-open"), ["https://example.com/?q=a&b=$(id)%20;x"], "one argument, no shell");
    assert_eq!(desk.run(&["tap", &id, "2"]).expect(EXIT_FAILED)["error"]["kind"], "link.refused");
    assert_eq!(desk.log("xdg-open").len(), 1);

    // The words of the menu.
    desk.ok(&["menu", &id, "edit"]);
    let deadline = Instant::now() + WAIT;
    while desk.log("scriptwidget-studio").len() < 2 {
        assert!(Instant::now() < deadline, "scriptwidget-studio was started");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(desk.log("scriptwidget-studio"), ["--edit", "Counter"]);
    desk.ok(&["menu", &id, "resize-small"]);
    let small = watch.event(|event| event["event"] == "widget" && event["height"] == 170);
    assert_eq!((small["width"].as_u64(), small["family"].as_str()), (Some(170), Some("small")));

    // Where it is, on which screen, at what scale, in which theme.
    desk.ok(&["screen", "eDP-1", "2", "1440", "900"]);
    watch.event(|event| event["event"] == "widget");
    let moved = desk.ok(&["move", &id, "eDP-1", "-50", "299.6"]);
    assert_eq!((moved["x"].as_i64(), moved["y"].as_i64()), (Some(0), Some(300)));
    let event = watch.event(|event| event["event"] == "widget" && event["screen"] == "eDP-1");
    assert_eq!((event["x"].as_i64(), event["y"].as_i64()), (Some(0), Some(300)));
    assert_eq!(desk.ok(&["theme", "dark"])["dark"], true);
    assert_eq!(desk.ok(&["session", "locked"])["locked"], true);
    assert_eq!(desk.ok(&["session", "unlocked"])["locked"], false);
    let listed = desk.until(&id, "the widget at rest", |widget| widget["busy"] == false && widget["scale"] == 2.0);
    assert_eq!((listed["package"].as_str(), listed["family"].as_str(), listed["screen"].as_str(), listed["x"].as_i64()), (Some("Counter"), Some("small"), Some("eDP-1"), Some(0)));

    // Modes.
    assert_eq!(desk.ok(&["arrange"])["arrange"], true);
    assert_eq!(watch.event(|event| event["event"] == "mode"), serde_json::json!({ "event": "mode", "arrange": true, "peek": true }), "arranging raises the widgets");
    assert_eq!(desk.ok(&["peek", "on"])["peek"], true);
    assert_eq!(desk.ok(&["arrange", "off"])["arrange"], false);
    assert_eq!(desk.ok(&["refresh"])["refreshed"], 1);
    assert_eq!(desk.ok(&["refresh", &id])["refreshed"], 1);
    assert_eq!(desk.ok(&["refresh", "--package", "Counter"])["refreshed"], 1);

    // A second service in the same session is refused and disturbs nothing.
    let second_service = desk.run(&["host", "run"]);
    assert_eq!(second_service.code, EXIT_USAGE);
    assert!(second_service.stderr.contains("already running"), "{}", second_service.stderr);
    assert_eq!(desk.ok(&["widgets"])["widgets"].as_array().unwrap().len(), 1);

    // SIGTERM: every watcher gets `bye`, the service exits with 0 and leaves no socket and no picture.
    assert_eq!(desk.signal_service(libc::SIGTERM), Some(0), "{}", desk.service_log());
    let (code, rest) = watch.finish();
    assert_eq!(code, 0, "watch ends with the service");
    assert_eq!(rest.last(), Some(&serde_json::json!({ "event": "bye", "reason": "shutdown" })));
    assert!(!desk.socket().exists());
    assert_eq!(std::fs::read_dir(desk.path("run/scriptwidget/frames")).unwrap().count(), 0);
    assert_eq!(desk.run(&["widgets"]).code, EXIT_NEEDS_SERVICE);

    // Started again, the widget is where it was.
    desk.start_service();
    let back = desk.until(&id, "the widget after a restart", |widget| widget["version"].as_u64() >= Some(1));
    assert_eq!((back["family"].as_str(), back["screen"].as_str(), back["y"].as_i64()), (Some("small"), Some("eDP-1"), Some(300)));
    desk.ok(&["remove", &id]);
    assert!(desk.ok(&["widgets"])["widgets"].as_array().unwrap().is_empty());
    let log = desk.service_log();
    assert!(!log.contains("example.com") && !log.contains("Count "), "the log names no link and no content: {log}");
}

#[test]
fn a_service_that_dies_is_noticed_and_can_be_started_again() {
    let mut desk = Desk::new();
    desk.package("Counter", COUNTER, "");
    desk.ok(&["install", "Counter"]);
    desk.start_service();
    let id = desk.ok(&["add", "Counter"])["id"].as_str().unwrap().to_owned();
    let mut watch = Lines::start(desk.command().arg("watch"));
    watch.event(|event| event["event"] == "widget");

    // Killed without a chance to say anything.
    assert_eq!(desk.signal_service(libc::SIGKILL), None);
    let (code, rest) = watch.finish();
    assert_eq!(code, EXIT_NEEDS_SERVICE);
    assert_eq!(rest.last(), Some(&serde_json::json!({ "event": "bye", "reason": "lost" })), "watch says that the connection was lost");
    assert!(desk.socket().exists(), "the socket file of the killed service is still there");
    assert_eq!(desk.run(&["widgets"]).expect(EXIT_NEEDS_SERVICE)["error"]["kind"], "service.unavailable");

    // The next service removes what the dead one left and shows the same widget.
    desk.start_service();
    let back = desk.until(&id, "the widget after a crash", |widget| widget["version"].as_u64() >= Some(1));
    assert_eq!(back["package"], "Counter");
    let frames: Vec<String> = std::fs::read_dir(desk.path("run/scriptwidget/frames")).unwrap().map(|entry| entry.unwrap().file_name().into_string().unwrap()).collect();
    assert_eq!(frames.len(), 1, "{frames:?}");
    assert_eq!(desk.signal_service(libc::SIGINT), Some(0), "Ctrl-C ends it as cleanly as SIGTERM");
    assert!(!desk.socket().exists());
}

#[test]
fn dev_copies_the_folder_and_refreshes_its_widgets() {
    let mut desk = Desk::new();
    let folder = desk.package("Live", r##"$render(<vstack frame="max" background="#dc2626"><text>one</text></vstack>);"##, "");
    desk.start_service();

    let mut dev = Lines::start(desk.command().args(["dev", "Live", "--family", "small"]));
    let ready = dev.next();
    assert_eq!((ready["event"].as_str(), ready["package"].as_str(), ready["added"].as_bool()), (Some("ready"), Some("Live"), Some(true)));
    let id = ready["widgets"][0].as_str().unwrap().to_owned();
    let first = desk.until(&id, "the first picture", |widget| widget["version"].as_u64() >= Some(1) && widget["busy"] == false);
    assert_eq!((first["package"].as_str(), first["family"].as_str()), (Some("Live"), Some("small")));
    let installed = desk.path("data/Packages/Live");
    assert_eq!(std::fs::read(installed.join("main.jsx")).unwrap(), std::fs::read(folder.join("main.jsx")).unwrap());

    // Saving a file: copied, and the widget shows it.
    std::fs::write(folder.join("main.jsx"), r##"$import("lib/color.js"); $render(<vstack frame="max" background={color}><text>two</text></vstack>);"##).unwrap();
    std::fs::create_dir_all(folder.join("lib")).unwrap();
    std::fs::write(folder.join("lib/color.js"), "var color = \"#16a34a\";").unwrap();
    let synced = dev.event(|event| event["event"] == "synced");
    let written: Vec<&str> = synced["written"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert!(written.contains(&"main.jsx"), "{synced}");
    let second = desk.until(&id, "the new picture", |widget| widget["version"].as_u64() > first["version"].as_u64() && widget["busy"] == false && installed.join("lib/color.js").is_file());
    assert_eq!(second["error"], Value::Null, "{second}");

    // Removing a file removes it from the installed copy too.
    std::fs::write(folder.join("main.jsx"), r##"$render(<vstack frame="max" background="#2563eb"><text>three</text></vstack>);"##).unwrap();
    std::fs::remove_file(folder.join("lib/color.js")).unwrap();
    let synced = dev.event(|event| event["event"] == "synced" && event["removed"].as_array().is_some_and(|removed| !removed.is_empty()));
    assert_eq!(synced["removed"], serde_json::json!(["lib/color.js"]));
    assert!(!installed.join("lib/color.js").exists());
    desk.until(&id, "the third picture", |widget| widget["version"].as_u64() > second["version"].as_u64());

    // A link in the folder is refused; nothing of its target is copied, and dev keeps watching.
    std::fs::write(desk.path("secret.txt"), "secret").unwrap();
    std::os::unix::fs::symlink(desk.path("secret.txt"), folder.join("leak.txt")).unwrap();
    let error = dev.event(|event| event["event"] == "error");
    assert!(error["code"].is_string(), "{error}");
    assert!(!installed.join("leak.txt").exists());
    std::fs::remove_file(folder.join("leak.txt")).unwrap();
    drop(dev);

    // Run again on the same folder: the widget is found, not added a second time.
    let mut dev = Lines::start(desk.command().args(["dev", "Live"]));
    let ready = dev.next();
    assert_eq!((ready["added"].as_bool(), ready["widgets"].as_array().map(Vec::len)), (Some(false), Some(1)));
    drop(dev);

    // A package of the same name that did not come from this folder is not overwritten.
    let other = desk.path("work/elsewhere/Live");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(other.join("main.jsx"), "$render(<text>other</text>);").unwrap();
    let refused = desk.run(&["dev", "elsewhere/Live"]).expect(EXIT_FAILED);
    assert_eq!(refused["error"]["kind"], "dev.package_exists");
    assert!(std::fs::read_to_string(installed.join("main.jsx")).unwrap().contains("three"));
    // With --adopt it is.
    let mut dev = Lines::start(desk.command().args(["dev", "elsewhere/Live", "--adopt"]));
    assert_eq!(dev.next()["event"], "ready");
    assert!(std::fs::read_to_string(installed.join("main.jsx")).unwrap().contains("other"));
    assert!(!installed.join("widget.json").exists(), "the installed copy holds exactly the files of the folder");
    drop(dev);

    // Without the service dev copies nothing.
    assert_eq!(desk.signal_service(libc::SIGTERM), Some(0));
    desk.package("Later", "$render(<text>later</text>);", "");
    desk.run(&["dev", "Later"]).expect(EXIT_NEEDS_SERVICE);
    assert!(!desk.path("data/Packages/Later").exists());
}
