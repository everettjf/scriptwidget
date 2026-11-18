//! Runs a whole service inside the test process, on a runtime directory and
//! a data directory of its own, and talks to it through its real socket.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-host
//!
//! Nothing here opens a window, starts a browser or touches the user's own
//! service: links go to a launcher that only records them.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sw_core::library::Library;
use sw_core::{DataPaths, Resources};
use sw_host::{Clock, Launcher, ManualClock, Request, RuntimePaths, Service, ServiceOptions, SessionEvent, StartError, Switch, SystemClock, client};

const WAIT: Duration = Duration::from_secs(30);
/// 2026-01-01 12:00:20 UTC.
const START: i64 = 1_767_268_820_000;

#[derive(Default)]
struct Recorder {
    links: Mutex<Vec<String>>,
    studio: Mutex<Vec<Option<String>>>,
}

impl Launcher for Recorder {
    fn open_link(&self, url: &str) -> bool {
        self.links.lock().unwrap().push(url.to_owned());
        true
    }

    fn open_studio(&self, package: Option<&str>) -> bool {
        self.studio.lock().unwrap().push(package.map(str::to_owned));
        true
    }
}

/// One user's session: a runtime directory and a data directory, removed afterwards.
struct Session {
    root: PathBuf,
    runtime: RuntimePaths,
    data: DataPaths,
    launcher: Arc<Recorder>,
    manual: Arc<ManualClock>,
    /// How long a replaced picture stays, in milliseconds.
    grace: u64,
}

impl Session {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        // Short: the path of a socket is limited to about a hundred bytes.
        let root = PathBuf::from("/tmp").join(format!("swh-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        std::fs::DirBuilder::new().mode(0o700).create(root.join("run")).unwrap();
        let data = DataPaths::new(Some(&root.join("data"))).unwrap();
        Self { runtime: RuntimePaths::under(&root.join("run")), data, root, launcher: Arc::default(), manual: Arc::new(ManualClock::new(START)), grace: 300 }
    }

    fn options(&self) -> ServiceOptions {
        let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let resources = Resources { runtime: repository.join("Linux/assets/scriptwidget"), templates: None };
        let mut options = ServiceOptions::new(self.runtime.clone(), self.data.clone(), resources);
        options.launcher = self.launcher.clone();
        options.frame_grace = self.grace;
        options
    }

    /// A service on the real clock.
    fn start(&self) -> Service {
        let mut options = self.options();
        options.clock = Arc::new(SystemClock::new());
        Service::start(options).expect("the service starts")
    }

    /// A service whose clock only moves when the test moves it.
    fn start_manual(&self) -> Service {
        let mut options = self.options();
        options.clock = self.manual.clone();
        Service::start(options).expect("the service starts")
    }

    fn library(&self) -> Library {
        Library::new(&self.data, None)
    }

    /// Installs a package with a Package 2.0 manifest; `extra` adds members to it.
    fn install(&self, name: &str, source: &str, permissions: &str, extra: &str) {
        let manifest = format!(
            r#"{{"formatVersion":2,"id":"com.example.{}","name":"{name}","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall","systemMedium","systemLarge"],"permissions":[{permissions}],"networkDomains":[]{extra}}}"#,
            name.to_lowercase().replace(' ', "-")
        );
        self.library().create(name, source, Some(&manifest)).expect("the package installs");
    }

    fn socket(&self) -> PathBuf {
        self.runtime.socket()
    }

    fn ask(&self, request: Request) -> Value {
        client::request(&self.socket(), &request).unwrap_or_else(|error| panic!("{request:?} failed: {error:?}"))
    }

    fn refused(&self, request: Request) -> String {
        match client::request(&self.socket(), &request) {
            Err(client::ClientError::Refused { code, .. }) => code,
            other => panic!("{request:?} should have been refused: {other:?}"),
        }
    }

    fn widgets(&self) -> Vec<Value> {
        self.ask(Request::Widgets)["widgets"].as_array().cloned().unwrap()
    }

    fn widget(&self, id: &str) -> Value {
        self.widgets().into_iter().find(|widget| widget["id"] == id).unwrap_or_else(|| panic!("no widget {id}"))
    }

    /// Waits until the widget satisfies `done`, and returns it.
    #[track_caller]
    fn until(&self, id: &str, what: &str, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            let widget = self.widget(id);
            if done(&widget) {
                return widget;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}: {widget}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Adds a widget and waits for its first picture.
    #[track_caller]
    fn add(&self, package: &str, family: Option<&str>) -> String {
        let id = self.ask(Request::Add { package: package.into(), family: family.map(str::to_owned) })["id"].as_str().unwrap().to_owned();
        self.until(&id, "the first picture", |widget| widget["version"].as_u64() >= Some(1) && widget["busy"] == false);
        id
    }

    /// Waits until the widget's script has run `runs` times and nothing is running.
    #[track_caller]
    fn runs(&self, id: &str, runs: u64) -> Value {
        self.until(id, &format!("{runs} runs"), |widget| widget["runs"].as_u64() >= Some(runs) && widget["busy"] == false)
    }

    fn frame_files(&self) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(self.runtime.frames()).unwrap().map(|entry| entry.unwrap().file_name().into_string().unwrap()).collect();
        names.sort();
        names
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// A connection that reads one JSON object a line.
struct Connection {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Connection {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).expect("the socket accepts");
        stream.set_read_timeout(Some(WAIT)).unwrap();
        Self { reader: BufReader::new(stream.try_clone().unwrap()), stream }
    }

    fn watch(socket: &Path) -> Self {
        let mut connection = Self::open(socket);
        connection.send("{\"op\":\"watch\"}");
        connection
    }

    fn send(&mut self, line: &str) {
        // In one piece: the service may answer and close as soon as it has seen enough of a line.
        self.stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    }

    /// The next line, or `None` when the connection has ended.
    fn line(&mut self) -> Option<Value> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(count) if count > 0 => Some(serde_json::from_str(&line).unwrap_or_else(|error| panic!("not JSON ({error}): {line}"))),
            _ => None,
        }
    }

    #[track_caller]
    fn next(&mut self) -> Value {
        self.line().expect("another line")
    }

    /// Reads events until one satisfies `wanted`.
    #[track_caller]
    fn event(&mut self, wanted: impl Fn(&Value) -> bool) -> Value {
        loop {
            let event = self.line().expect("the stream ended before the event came");
            if wanted(&event) {
                return event;
            }
        }
    }

    fn code(&mut self, line: &str) -> String {
        self.send(line);
        let reply = self.next();
        assert_eq!(reply["ok"], false, "{line} -> {reply}");
        reply["error"]["code"].as_str().unwrap().to_owned()
    }
}

fn png_size(path: &Path) -> (u32, u32) {
    let bytes = std::fs::read(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n", "{} is a PNG", path.display());
    let number = |at: usize| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
    (number(16), number(20))
}

fn image(event: &Value) -> PathBuf {
    PathBuf::from(event["image"].as_str().expect("an image path"))
}

/// A GIF of solid frames from a palette of black, red, green and blue; delays in hundredths of a second.
fn gif(width: u16, height: u16, frames: &[(u8, u16)]) -> Vec<u8> {
    let mut data = Vec::new();
    data.extend_from_slice(b"GIF89a");
    data.extend_from_slice(&width.to_le_bytes());
    data.extend_from_slice(&height.to_le_bytes());
    data.extend_from_slice(&[0x91, 0, 0]);
    data.extend_from_slice(&[0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]);
    data.extend_from_slice(&[0x21, 0xFF, 0x0B]);
    data.extend_from_slice(b"NETSCAPE2.0");
    data.extend_from_slice(&[3, 1, 0, 0, 0]);
    for (color, delay) in frames {
        data.extend_from_slice(&[0x21, 0xF9, 4, 0]);
        data.extend_from_slice(&delay.to_le_bytes());
        data.extend_from_slice(&[0, 0]);
        data.push(0x2C);
        data.extend_from_slice(&[0, 0, 0, 0]);
        data.extend_from_slice(&width.to_le_bytes());
        data.extend_from_slice(&height.to_le_bytes());
        data.push(0);
        data.push(2);
        let mut bits: Vec<bool> = Vec::new();
        let mut push = |code: u8| (0..3).for_each(|bit| bits.push(code >> bit & 1 == 1));
        for _ in 0..usize::from(width) * usize::from(height) {
            push(4);
            push(*color);
        }
        push(5);
        let bytes: Vec<u8> = bits.chunks(8).map(|chunk| chunk.iter().enumerate().fold(0u8, |byte, (bit, set)| byte | (u8::from(*set) << bit))).collect();
        for block in bytes.chunks(255) {
            data.push(block.len() as u8);
            data.extend_from_slice(block);
        }
        data.push(0);
    }
    data.push(0x3B);
    data
}

const PLAIN: &str = r##"$render(<vstack frame="max" background="#1d4ed8"><text color="white">{$getenv("widget-size") + ($device.isdarkmode() ? " dark" : " light")}</text></vstack>);"##;

/// A counter in storage: one button calls a function of the script, one names a declared action,
/// one names an action the manifest does not declare, one reloads; then a toggle and three links.
const CONTROLS: &str = r##"
function bump() { $storage.setString("count", String(Number($storage.getString("count") || "0") + 1)); }
function secret() { $storage.setString("count", "999"); }
const count = $storage.getString("count") || "0";
const flag = $storage.getString("flag") === "true";
$render(
  <vstack frame="max" background={flag ? "#16a34a" : "#1f2937"}>
    <button onClick="bump"><text color="white">{"Count " + count}</text></button>
    <button actionID="bump.declared"><text color="white">declared</text></button>
    <button actionID="secret"><text color="white">undeclared</text></button>
    <button action="reload"><text color="white">reload</text></button>
    <toggle on={flag} stateKey="flag" onClick="noop"><text color="white">flag</text></toggle>
    <link url="https://example.com/a page"><text color="white">web</text></link>
    <link url="file:///etc/passwd"><text color="white">file</text></link>
    <link url="mailto:someone@example.com"><text color="white">mail</text></link>
  </vstack>
);
function noop() {}
"##;

const CONTROLS_ACTIONS: &str = r#","actions":[{"id":"bump.declared","title":"Bump","systemImage":"plus.circle","function":"bump"}]"#;

fn install_controls(session: &Session) {
    session.install("Controls", CONTROLS, "\"storage\"", CONTROLS_ACTIONS);
}

#[test]
fn a_watcher_gets_hello_the_widgets_and_every_change() {
    let session = Session::new();
    session.install("Plain", PLAIN, "", "");
    let service = session.start();
    assert_eq!(std::fs::metadata(session.socket()).unwrap().mode() & 0o777, 0o600);
    assert_eq!(std::fs::metadata(session.runtime.directory()).unwrap().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(session.runtime.frames()).unwrap().mode() & 0o777, 0o700);

    let mut first = Connection::watch(&session.socket());
    assert_eq!(first.next(), json!({ "event": "hello", "protocol": 1, "dark": false, "arrange": false, "peek": false, "service": env!("CARGO_PKG_VERSION") }));

    let added = session.ask(Request::Add { package: "Plain".into(), family: None });
    assert_eq!((added["package"].as_str(), added["family"].as_str()), (Some("Plain"), Some("medium")));
    let id = added["id"].as_str().unwrap().to_owned();
    assert!(sw_host::protocol::is_identifier(&id));

    let widget = first.next();
    assert_eq!(widget["event"], "widget");
    assert_eq!(widget["id"], id.as_str());
    assert_eq!((widget["width"].as_u64(), widget["height"].as_u64(), widget["version"].as_u64()), (Some(329), Some(170), Some(1)));
    assert_eq!((widget["screen"].as_str(), widget["x"].as_i64(), widget["y"].as_i64()), (Some(""), Some(40), Some(40)));
    assert_eq!(widget["regions"], json!([]));
    assert!(widget.get("frames").is_none(), "a picture that does not move has no frames");
    assert_eq!(widget["family"], "medium");
    assert_eq!(widget["families"], json!(["small", "medium", "large"]));
    let picture = image(&widget);
    assert!(picture.is_absolute() && picture.starts_with(session.runtime.frames()));
    assert_eq!(png_size(&picture), (329, 170), "drawn at scale 1 until a screen says otherwise");
    assert_eq!(std::fs::metadata(&picture).unwrap().mode() & 0o777, 0o600);
    assert!(picture.file_name().unwrap().to_str().unwrap().starts_with(&format!("{id}-")));

    // A watcher that connects later gets the whole state first.
    let mut second = Connection::watch(&session.socket());
    assert_eq!(second.next()["event"], "hello");
    assert_eq!(second.next(), widget);
    assert_eq!(session.ask(Request::Status)["watchers"], 2);

    // Modes are service state, told to every watcher.
    // Arranging raises the widgets above the windows and puts them back afterwards.
    let answer = session.ask(Request::Arrange(Switch::On));
    assert_eq!((answer["arrange"].as_bool(), answer["peek"].as_bool()), (Some(true), Some(true)));
    session.ask(Request::Arrange(Switch::On));
    session.ask(Request::Arrange(Switch::Toggle));
    session.ask(Request::Peek(Switch::Toggle));
    session.ask(Request::Arrange(Switch::Toggle));
    for watcher in [&mut first, &mut second] {
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": true, "peek": true }));
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": false, "peek": false }), "saying on twice is one change; peek is as it was before");
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": false, "peek": true }));
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": true, "peek": true }));
    }
    let mut third = Connection::watch(&session.socket());
    assert_eq!(third.next(), json!({ "event": "hello", "protocol": 1, "dark": false, "arrange": true, "peek": true, "service": env!("CARGO_PKG_VERSION") }));
    drop(third);
    // Peek that was on before arranging stays on after it; peek set while arranging is the user's choice.
    session.ask(Request::Arrange(Switch::Off));
    session.ask(Request::Arrange(Switch::On));
    session.ask(Request::Peek(Switch::Off));
    session.ask(Request::Arrange(Switch::Off));
    for watcher in [&mut first, &mut second] {
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": false, "peek": true }));
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": true, "peek": true }));
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": true, "peek": false }));
        assert_eq!(watcher.next(), json!({ "event": "mode", "arrange": false, "peek": false }));
    }

    // A move is told with the picture unchanged.
    let moved = session.ask(Request::Move { id: id.clone(), screen: "DP-1".into(), x: -30, y: 500 });
    assert_eq!((moved["x"].as_i64(), moved["y"].as_i64()), (Some(-30), Some(500)), "an unknown screen has no edges to keep to");
    let event = first.next();
    assert_eq!((event["screen"].as_str(), event["x"].as_i64(), event["y"].as_i64(), event["version"].as_u64()), (Some("DP-1"), Some(-30), Some(500), Some(1)));
    assert_eq!(event["image"], widget["image"]);
    assert_eq!(second.next(), event);

    session.ask(Request::Remove { id: id.clone() });
    for watcher in [&mut first, &mut second] {
        assert_eq!(watcher.next(), json!({ "event": "remove", "id": id }));
    }
    assert_eq!(session.refused(Request::Remove { id: id.clone() }), "widget.unknown");
    assert!(session.widgets().is_empty());

    service.stop("shutdown");
    for watcher in [&mut first, &mut second] {
        assert_eq!(watcher.next(), json!({ "event": "bye", "reason": "shutdown" }));
        assert!(watcher.line().is_none(), "bye is the last line");
    }
    assert!(!session.socket().exists(), "no socket is left behind");
    assert!(session.frame_files().is_empty(), "no picture is left behind");
}

#[test]
fn placements_survive_a_restart() {
    let session = Session::new();
    session.install("Plain", PLAIN, "", "");
    session.install("Other", PLAIN, "", "");
    let service = session.start();
    let one = session.add("Plain", Some("small"));
    let two = session.add("Other", None);
    session.ask(Request::Screen { name: "eDP-1".into(), scale: 2000, width: 1440, height: 900 });
    session.ask(Request::Theme { dark: true });
    let moved = session.ask(Request::Move { id: one.clone(), screen: "eDP-1".into(), x: 5000, y: -7 });
    assert_eq!((moved["x"].as_i64(), moved["y"].as_i64()), (Some(1440 - 170), Some(0)), "kept on a screen whose size is known");
    session.ask(Request::Menu { id: two.clone(), word: "resize-large".into() });
    let before = session.until(&two, "the large picture", |widget| widget["height"] == 345 && widget["busy"] == false && widget["scale"] == 2.0);
    let old_picture = before["image"].as_str().unwrap().to_owned();
    service.stop("shutdown");

    let saved: Value = serde_json::from_str(&std::fs::read_to_string(session.data.widgets()).unwrap()).unwrap();
    assert_eq!(saved["version"], 1);
    assert_eq!(saved["widgets"][0], json!({ "id": one, "package": session.library().find("Plain").unwrap().installation, "family": "small", "screen": "eDP-1", "x": 1270, "y": 0 }));
    assert_eq!(std::fs::metadata(session.data.widgets()).unwrap().mode() & 0o777, 0o600);

    let service = session.start();
    let mut watcher = Connection::watch(&session.socket());
    assert_eq!(watcher.next()["dark"], true, "the theme is remembered");
    let widgets: Vec<Value> = [watcher.event(|event| event["event"] == "widget"), watcher.event(|event| event["event"] == "widget")].into();
    let found = |id: &str| widgets.iter().find(|widget| widget["id"] == id).unwrap_or_else(|| panic!("{id} is back")).clone();
    let (first, second) = (found(&one), found(&two));
    assert_eq!((first["screen"].as_str(), first["x"].as_i64(), first["y"].as_i64(), first["family"].as_str()), (Some("eDP-1"), Some(1270), Some(0), Some("small")));
    assert_eq!((second["family"].as_str(), second["width"].as_u64(), second["height"].as_u64()), (Some("large"), Some(329), Some(345)));
    assert_eq!(png_size(&image(&first)), (340, 340), "the screen's scale is remembered too");
    assert_ne!(second["image"].as_str().unwrap(), old_picture, "a picture's path is never used twice, also across restarts");
    assert_eq!(session.widgets().len(), 2);
    drop(service);
}

#[test]
fn a_tap_runs_the_action_and_the_picture_changes() {
    let mut session = Session::new();
    // Long enough for the tap below that names the picture before the current one.
    session.grace = 2500;
    install_controls(&session);
    let _service = session.start();
    let mut watcher = Connection::watch(&session.socket());
    let id = session.add("Controls", Some("large"));
    let first = watcher.event(|event| event["event"] == "widget");
    let regions = first["regions"].as_array().unwrap();
    assert_eq!(regions.len(), 8, "{first}");
    for (n, region) in regions.iter().enumerate() {
        assert_eq!(region["n"], n);
        assert!(region["width"].as_i64() > Some(0) && region["height"].as_i64() > Some(0), "{region}");
        assert!(region["x"].as_i64() >= Some(0) && region["x"].as_i64().unwrap() + region["width"].as_i64().unwrap() <= 329, "{region}");
        assert_eq!(region.as_object().unwrap().len(), 5, "a region is a number and a rectangle, nothing of the package: {region}");
    }
    let storage = |key: &str| sw_core::api::StorageModule::new(session.data.storage()).get_string(&session.library().find("Controls").unwrap().installation, key);

    // The button with a function of the script.
    assert_eq!(session.ask(Request::Tap { id: id.clone(), n: 0, version: None })["action"], "button");
    let second = watcher.event(|event| event["event"] == "widget");
    assert_eq!(second["version"], 2);
    assert_ne!(second["image"], first["image"], "a new picture has a new path");
    assert_ne!(std::fs::read(image(&second)).unwrap(), std::fs::read(image(&first)).unwrap_or_default());
    assert_eq!(storage("count"), "1");

    // The button with a declared action, tapped on the picture before: its table is still known.
    assert_eq!(session.ask(Request::Tap { id: id.clone(), n: 1, version: Some(1) })["action"], "button");
    assert_eq!(watcher.event(|event| event["event"] == "widget")["version"], 3);
    assert_eq!(storage("count"), "2");

    // An action the manifest does not declare runs nothing; the script still runs again and draws the same picture.
    let runs = session.widget(&id)["runs"].as_u64().unwrap();
    session.ask(Request::Tap { id: id.clone(), n: 2, version: None });
    let after = session.runs(&id, runs + 1);
    assert_eq!(storage("count"), "2", "secret() was not called");
    assert_eq!(after["version"], 3, "the same picture is not published again");

    // Reload runs the script again.
    assert_eq!(session.ask(Request::Tap { id: id.clone(), n: 3, version: None })["action"], "reload");
    assert_eq!(session.runs(&id, runs + 2)["version"], 3);

    // The toggle saves its new state, then the picture is green.
    let answer = session.ask(Request::Tap { id: id.clone(), n: 4, version: None });
    assert_eq!((answer["action"].as_str(), answer["value"].as_bool()), (Some("toggle"), Some(true)));
    let toggled = watcher.event(|event| event["event"] == "widget");
    assert_eq!(toggled["version"], 4);
    assert_eq!(storage("flag"), "true");
    let answer = session.ask(Request::Tap { id: id.clone(), n: 4, version: None });
    assert_eq!(answer["value"], false, "the table of the new picture knows the toggle is on");
    assert_eq!(watcher.event(|event| event["event"] == "widget")["version"], 5);
    assert_eq!(storage("flag"), "false");

    // Numbers that select nothing.
    assert_eq!(session.refused(Request::Tap { id: id.clone(), n: 8, version: None }), "region.unknown");
    assert_eq!(session.refused(Request::Tap { id: id.clone(), n: 0, version: Some(99) }), "version.stale");
    assert_eq!(session.refused(Request::Tap { id: "0123456789abcdef".into(), n: 0, version: None }), "widget.unknown");

    // Replaced pictures leave the directory after the grace time; the current one stays.
    let current = session.widget(&id)["image"].as_str().unwrap().to_owned();
    let deadline = Instant::now() + WAIT;
    while session.frame_files().len() > 1 {
        assert!(Instant::now() < deadline, "old pictures are deleted: {:?}", session.frame_files());
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(session.frame_files(), [Path::new(&current).file_name().unwrap().to_str().unwrap()]);
    assert!(!image(&first).exists());
    assert_eq!(session.refused(Request::Tap { id, n: 0, version: Some(1) }), "version.stale", "and their tables are forgotten with them");
}

#[test]
fn links_open_only_web_and_mail_addresses() {
    let session = Session::new();
    install_controls(&session);
    let _service = session.start();
    let id = session.add("Controls", Some("large"));
    let tap = |n: u32| Request::Tap { id: id.clone(), n, version: None };

    assert_eq!(session.ask(tap(5))["action"], "link");
    assert_eq!(*session.launcher.links.lock().unwrap(), ["https://example.com/a%20page"], "the canonical form of the parsed address");
    assert_eq!(session.refused(tap(6)), "link.refused");
    assert_eq!(session.launcher.links.lock().unwrap().len(), 1, "a file address starts nothing");
    assert_eq!(session.ask(tap(7))["action"], "link");
    assert_eq!(session.launcher.links.lock().unwrap().last().map(String::as_str), Some("mailto:someone@example.com"));
    assert_eq!(session.widget(&id)["runs"], 1, "a link does not run the script");

    // The menu: edit names the installed package by its own name; the words are a fixed list.
    session.ask(Request::Menu { id: id.clone(), word: "edit".into() });
    assert_eq!(*session.launcher.studio.lock().unwrap(), [Some("Controls".to_owned())]);
    session.ask(Request::Menu { id: id.clone(), word: "refresh".into() });
    session.runs(&id, 2);
    assert_eq!(session.refused(Request::Menu { id: id.clone(), word: "resize-extraLarge".into() }), "family.unsupported");
    let mut raw = Connection::open(&session.socket());
    assert_eq!(raw.code(&format!("{{\"op\":\"menu\",\"id\":\"{id}\",\"word\":\"run\"}}")), "request.invalid");
    session.ask(Request::Menu { id: id.clone(), word: "remove".into() });
    assert!(session.widgets().is_empty());
}

#[test]
fn what_is_not_a_request_is_refused() {
    let session = Session::new();
    session.install("Plain", PLAIN, "", "");
    let _service = session.start();
    let id = session.add("Plain", None);

    let mut connection = Connection::open(&session.socket());
    for line in ["hello", "{}", "[1,2]", "{\"op\":\"shell\",\"command\":\"id\"}", "{\"op\":\"add\",\"package\":\"../../etc\"}", "{\"op\":\"remove\",\"id\":\"../../../tmp/x\"}", "{\"op\":\"tap\",\"id\":\"0123456789abcdef\",\"n\":\"0\"}"] {
        assert_eq!(connection.code(line), "request.invalid", "{line}");
    }
    assert_eq!(connection.code("{\"op\":\"tap\",\"id\":\"0123456789abcdef\",\"n\":0}"), "widget.unknown");
    assert_eq!(connection.code("{\"op\":\"add\",\"package\":\"Nothing Here\"}"), "package.unknown");
    assert_eq!(connection.code("{\"op\":\"add\",\"package\":\"Plain\",\"family\":\"extraLarge\"}"), "family.unsupported");
    // The eighth line that is not a request at all ends the connection.
    assert_eq!(connection.code("x"), "request.invalid");
    assert!(connection.line().is_none());

    // A connection keeps working after a refusal, and serves several requests.
    let mut connection = Connection::open(&session.socket());
    assert_eq!(connection.code("nonsense"), "request.invalid");
    connection.send("{\"op\":\"status\"}");
    assert_eq!(connection.next()["ok"], true);
    connection.send("{\"op\":\"widgets\"}");
    assert_eq!(connection.next()["widgets"][0]["id"], id.as_str());

    // A line without an end is cut off at the limit.
    let mut connection = Connection::open(&session.socket());
    connection.stream.write_all(&[b'a'; 5000]).unwrap();
    let reply = connection.next();
    assert_eq!(reply["error"]["code"], "request.too_long");
    assert!(connection.line().is_none(), "and the connection is closed");

    // A long line that does end is refused as well.
    let mut connection = Connection::open(&session.socket());
    assert_eq!(connection.code(&format!("{{\"op\":\"add\",\"package\":\"{}\"}}", "b".repeat(4200))), "request.too_long");

    // Bytes that are not text.
    let mut connection = Connection::open(&session.socket());
    connection.stream.write_all(&[0xff, 0xfe, 0x00, 0x80, b'\n']).unwrap();
    assert_eq!(connection.next()["error"]["code"], "request.invalid");
    assert!(connection.line().is_none());

    // What a watcher sends after `watch` is ignored.
    let mut watcher = Connection::watch(&session.socket());
    assert_eq!(watcher.next()["event"], "hello");
    assert_eq!(watcher.next()["event"], "widget");
    watcher.send("{\"op\":\"remove\",\"id\":\"0123456789abcdef\"}");
    watcher.send(&"z".repeat(10_000));
    session.ask(Request::Peek(Switch::On));
    assert_eq!(watcher.next()["event"], "mode");

    // Nothing above disturbed the service.
    assert_eq!(session.widgets().len(), 1);
    assert_eq!(session.widget(&id)["version"], 1);
}

#[test]
fn a_connection_of_another_user_is_refused() {
    let session = Session::new();
    let mut options = session.options();
    // The kernel reports this process's user for the test's own connection; the service is told to expect someone else.
    // SAFETY: geteuid has no preconditions and cannot fail.
    options.expected_user = Some(unsafe { libc::geteuid() } + 1);
    let _service = Service::start(options).unwrap();
    let mut connection = Connection::open(&session.socket());
    let reply = connection.next();
    assert_eq!(reply["error"]["code"], "peer.refused", "refused before anything is read");
    assert!(connection.line().is_none());
    assert!(matches!(client::request(&session.socket(), &Request::Status), Err(client::ClientError::Refused { code, .. }) if code == "peer.refused"));
}

#[test]
fn one_service_a_session_and_a_stale_socket_is_replaced() {
    let session = Session::new();
    let service = session.start();
    assert!(matches!(Service::start(session.options()), Err(StartError::AlreadyRunning)));
    assert!(session.socket().exists(), "the refused start left the running service's socket alone");
    assert_eq!(session.ask(Request::Status)["ok"], true);
    service.stop("shutdown");
    assert!(!session.socket().exists());
    assert!(matches!(client::request(&session.socket(), &Request::Status), Err(client::ClientError::NotRunning)));

    // What a crashed service leaves: a socket file nobody listens on, and pictures.
    drop(UnixListener::bind(session.socket()).unwrap());
    assert!(session.socket().exists());
    std::fs::write(session.runtime.frames().join("0123456789abcdef-deadbeef-7.png"), b"old").unwrap();
    assert!(matches!(client::request(&session.socket(), &Request::Status), Err(client::ClientError::NotRunning)));
    let _service = session.start();
    assert_eq!(session.ask(Request::Status)["ok"], true);
    assert!(session.frame_files().is_empty(), "pictures of an earlier run are removed");
}

#[test]
fn no_more_connections_than_the_limit() {
    let session = Session::new();
    let _service = session.start();
    let mut held: Vec<Connection> = (0..sw_host::server::MAXIMUM_CONNECTIONS).map(|_| Connection::open(&session.socket())).collect();
    // Each of them is served.
    held[0].send("{\"op\":\"status\"}");
    assert_eq!(held[0].next()["ok"], true);
    let deadline = Instant::now() + WAIT;
    loop {
        // One too many is told so at once, without having asked anything.
        let mut extra = Connection::open(&session.socket());
        extra.stream.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
        if let Some(reply) = extra.line() {
            assert_eq!(reply["error"]["code"], "service.busy");
            break;
        }
        // The accepting thread had not yet counted every held connection.
        assert!(Instant::now() < deadline, "the limit is enforced");
    }
    held.clear();
    let deadline = Instant::now() + WAIT;
    while client::request(&session.socket(), &Request::Status).is_err() {
        assert!(Instant::now() < deadline, "closed connections make room again");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_gif_becomes_frames_drawn_by_the_service() {
    let session = Session::new();
    session.install("Animated", r##"$render(<vstack frame="max" background="#111827"><gif file="spin"/><text color="white">gif</text></vstack>);"##, "", "");
    session.library().write_file("Animated", "image/spin.gif", &gif(8, 8, &[(1, 20), (2, 30), (3, 50)])).unwrap();
    session.install("Still", r##"$render(<vstack frame="max"><gif file="one"/></vstack>);"##, "", "");
    session.library().write_file("Still", "image/one.gif", &gif(8, 8, &[(2, 10)])).unwrap();
    let _service = session.start();
    let mut watcher = Connection::watch(&session.socket());
    let id = session.add("Animated", Some("small"));
    let event = watcher.event(|event| event["event"] == "widget");
    let frames = event["frames"].as_array().unwrap_or_else(|| panic!("frames: {event}"));
    assert_eq!(frames.iter().map(|frame| frame["ms"].as_u64().unwrap()).collect::<Vec<_>>(), [200, 300, 500]);
    assert_eq!(frames[0]["image"], event["image"], "the picture is the first frame");
    let pictures: Vec<Vec<u8>> = frames.iter().map(|frame| std::fs::read(image(frame)).unwrap()).collect();
    for (index, frame) in frames.iter().enumerate() {
        assert_eq!(png_size(&image(frame)), (170, 170), "every frame is the whole widget");
        assert!(image(frame).file_name().unwrap().to_str().unwrap().ends_with(&format!("-1-{index}.png")));
    }
    assert!(pictures[0] != pictures[1] && pictures[1] != pictures[2] && pictures[0] != pictures[2], "red, green and blue");
    assert_eq!(session.frame_files().len(), 3);
    assert_eq!(session.widget(&id)["frames"], 3);

    // Run again: the same frames are not published a second time.
    session.ask(Request::Refresh { id: Some(id.clone()), package: None });
    assert_eq!(session.runs(&id, 2)["version"], 1);
    assert_eq!(session.frame_files().len(), 3, "and the frames that were drawn to compare are gone");

    // A GIF of one frame is a picture like any other.
    let still = session.add("Still", Some("small"));
    let event = watcher.event(|event| event["event"] == "widget" && event["id"] == still.as_str());
    assert!(event.get("frames").is_none());
}

#[test]
fn scripts_run_on_schedule() {
    let session = Session::new();
    session.install("Plain", PLAIN, "", "");
    let service = session.start_manual();
    let controller = service.controller();
    let clock = session.manual.clone();
    let id = session.add("Plain", None);
    assert_eq!(session.widget(&id)["runs"], 1);
    assert_eq!(session.ask(Request::Status)["refreshMinutes"], 15);
    // Moving the clock and looking again, with time for a run to start if one were due.
    let pass = |milliseconds: u64| {
        clock.advance(milliseconds);
        controller.poke();
        std::thread::sleep(Duration::from_millis(150));
    };

    pass(14 * 60_000);
    assert_eq!(session.runs(&id, 1)["runs"], 1, "not before the interval");
    pass(60_000 + 1);
    assert_eq!(session.runs(&id, 2)["runs"], 2, "every 15 minutes");
    assert_eq!(session.widget(&id)["version"], 1, "the same picture is not published again");
    pass(15 * 60_000 + 1);
    session.runs(&id, 3);

    // The setting is read again when the file changes: between 5 minutes and a day.
    std::fs::write(session.data.settings(), "{\"refreshMinutes\":5}").unwrap();
    assert_eq!(session.ask(Request::Status)["refreshMinutes"], 5);
    pass(15 * 60_000 + 1);
    session.runs(&id, 4);
    pass(5 * 60_000 + 1);
    session.runs(&id, 5);

    // While the session is locked nothing runs; unlocking runs everything once.
    controller.session(SessionEvent::Locked(true));
    assert_eq!(session.ask(Request::Status)["locked"], true);
    pass(60 * 60_000);
    pass(60 * 60_000);
    assert_eq!(session.runs(&id, 5)["runs"], 5, "paused while locked");
    controller.session(SessionEvent::Locked(false));
    session.runs(&id, 6);
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(session.runs(&id, 6)["runs"], 6, "once, not once for the unlock and once for the overdue interval");

    // The display may report the lock instead (a shell that locks without logind).
    session.ask(Request::Session { locked: true });
    pass(60 * 60_000);
    assert_eq!(session.runs(&id, 6)["runs"], 6);
    session.ask(Request::Session { locked: false });
    session.runs(&id, 7);

    // Waking from sleep, as logind reports it, and as the clock shows it.
    pass(3000);
    controller.session(SessionEvent::Sleeping);
    controller.session(SessionEvent::Resumed);
    session.runs(&id, 8);
    controller.session(SessionEvent::ClockChanged);
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(session.runs(&id, 8)["runs"], 8, "two reports of one wake-up are one refresh");
    pass(3000);
    // The wall clock is set an hour ahead and nothing reports it: the service notices the jump itself.
    clock.set_wall(clock.wall() + 3_600_000);
    controller.poke();
    session.runs(&id, 9);

    // A new theme runs the script again and changes the picture; the same theme does nothing.
    session.ask(Request::Theme { dark: true });
    let dark = session.runs(&id, 10);
    assert_eq!(dark["version"], 2);
    session.ask(Request::Theme { dark: true });
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(session.runs(&id, 10)["runs"], 10);

    // A new scale draws the same tree again without running the script.
    let mut watcher = Connection::watch(&session.socket());
    watcher.event(|event| event["event"] == "widget");
    session.ask(Request::Screen { name: "eDP-1".into(), scale: 1500, width: 1920, height: 1200 });
    let event = watcher.event(|event| event["event"] == "widget");
    assert_eq!((event["version"].as_u64(), event["width"].as_u64()), (Some(3), Some(329)), "the logical size stays");
    assert_eq!(png_size(&image(&event)), (494, 255));
    assert_eq!(session.runs(&id, 10)["runs"], 10);
    assert_eq!(session.ask(Request::Status)["screens"]["eDP-1"], json!({ "scale": 1500, "width": 1920, "height": 1200 }));

    // On demand: one widget, a package, all.
    session.ask(Request::Refresh { id: Some(id.clone()), package: None });
    session.runs(&id, 11);
    assert_eq!(session.ask(Request::Refresh { id: None, package: Some("Plain".into()) })["refreshed"], 1);
    session.runs(&id, 12);
    assert_eq!(session.ask(Request::Refresh { id: None, package: None })["refreshed"], 1);
    session.runs(&id, 13);
    assert_eq!(session.refused(Request::Refresh { id: None, package: Some("Missing".into()) }), "package.unknown");
}

#[test]
fn a_running_timer_is_drawn_again_each_second_without_running_the_script() {
    let session = Session::new();
    session.install("Timer", r##"$render(<vstack frame="max" background="#0f172a"><date color="white" font="title" date="start of today" style="timer"/></vstack>);"##, "", "");
    session.install("Plain", PLAIN, "", "");
    let _service = session.start();
    let timer = session.add("Timer", Some("small"));
    let plain = session.add("Plain", Some("small"));
    let before = session.widget(&timer)["version"].as_u64().unwrap();
    std::thread::sleep(Duration::from_millis(3300));
    let after = session.widget(&timer);
    let versions = after["version"].as_u64().unwrap() - before;
    assert!((2..=4).contains(&versions), "one new picture a second: {versions} in 3.3 seconds");
    assert_eq!(after["runs"], 1, "the script ran once");
    let plain = session.widget(&plain);
    assert_eq!((plain["version"].as_u64(), plain["runs"].as_u64()), (Some(1), Some(1)), "a widget without a timer is left alone");
    // The pictures of the seconds that passed do not pile up.
    assert!(session.frame_files().len() <= 4, "{:?}", session.frame_files());
}

#[test]
fn a_package_that_fails_or_is_gone_still_has_a_picture() {
    let session = Session::new();
    session.install("Broken", "throw new Error('no');", "", "");
    session.install("Plain", PLAIN, "", "");
    let _service = session.start();
    let broken = session.add("Broken", None);
    let widget = session.widget(&broken);
    assert_eq!(widget["error"], "scriptException");
    assert!(image(&widget).is_file(), "the error is drawn as a card");

    let plain = session.add("Plain", None);
    session.library().delete("Plain").unwrap();
    session.ask(Request::Refresh { id: Some(plain.clone()), package: None });
    let gone = session.until(&plain, "the notice", |widget| widget["installed"] == false && widget["busy"] == false);
    assert_eq!(gone["version"], 2, "the notice replaces the picture");
    assert_eq!(session.refused(Request::Menu { id: plain.clone(), word: "edit".into() }), "package.unknown");
    session.ask(Request::Menu { id: plain, word: "remove".into() });
    assert_eq!(session.widgets().len(), 1);

    // A socket that does not exist is the client's "not running".
    assert!(matches!(client::request(Path::new("/nonexistent/scriptwidget/host.sock"), &Request::Status), Err(client::ClientError::NotRunning)));
}

#[test]
fn the_clock_of_the_system_goes_forward() {
    let clock = SystemClock::new();
    let (first, wall) = (clock.now(), clock.wall());
    std::thread::sleep(Duration::from_millis(20));
    assert!(clock.now() >= first + 15);
    assert!(wall > 1_700_000_000_000);
}
