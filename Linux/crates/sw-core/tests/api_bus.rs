//! The session bus as the runtime reaches it: through `busctl`, with fixed
//! arguments.
//!
//! Most tests here run a stand-in program in place of `busctl` and look at
//! the arguments it was given. The last one runs the real `busctl` against a
//! bus of its own (a `dbus-daemon` this test starts, with a stand-in media
//! player and notification service on it), where those programs are
//! installed. No test talks to the session bus of whoever runs the tests.

mod api_common;

use std::io::{BufRead, BufReader, Read};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use api_common::temporary_directory;
use serde_json::Value;
use sw_core::api::bus::{BusError, SessionBus};
use sw_core::api::music::{MprisPlatform, MusicPlatform, music_rules};
use sw_core::api::notifications::{DesktopNotifications, NotificationPlatform};

const LIMIT: Duration = Duration::from_secs(10);

fn executable(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A program that records its arguments (one per line, then `--END--`) and
/// answers by the method it is asked for, from files in its folder.
fn stand_in(directory: &Path) -> SessionBus {
    let program = directory.join("busctl");
    executable(
        &program,
        &format!(
            "#!/bin/sh\nD='{0}'\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done >> \"$D/calls\"\necho '--END--' >> \"$D/calls\"\ncase \"${{10}}\" in\n  GetAll) cat \"$D/player-$7.json\" 2>/dev/null || exit 1 ;;\n  *) cat \"$D/${{10}}.json\" 2>/dev/null || exit 1 ;;\nesac\n",
            directory.display()
        ),
    );
    SessionBus::with_program(program)
}

fn calls(directory: &Path) -> Vec<Vec<String>> {
    let text = std::fs::read_to_string(directory.join("calls")).unwrap_or_default();
    text.split("--END--\n").filter(|call| !call.is_empty()).map(|call| call.lines().map(str::to_owned).collect()).collect()
}

/// What busctl 262 printed for `GetAll` of mpv 0.42 with mpv-mpris on Omarchy 4.5.
const MPV: &str = r#"{"type":"a{sv}","data":[{"PlaybackStatus":{"type":"s","data":"Playing"},"LoopStatus":{"type":"s","data":"Track"},"Rate":{"type":"d","data":1.000000000000000000000000000000000000e+00},"Shuffle":{"type":"b","data":false},"Metadata":{"type":"a{sv}","data":{"xesam:album":{"type":"s","data":"The Album"},"xesam:artist":{"type":"as","data":["An Artist"]},"mpris:trackid":{"type":"o","data":"/mpv/mpris/Track/0"},"xesam:title":{"type":"s","data":"Test --Title \"q\""},"xesam:url":{"type":"s","data":"file:///home/omarchy/swx/t.mp3"},"mpris:length":{"type":"x","data":120000000}}},"Volume":{"type":"d","data":1.000000000000000000000000000000000000e+00},"Position":{"type":"x","data":1857555},"MinimumRate":{"type":"d","data":1.000000000000000020816681711721685133e-02},"MaximumRate":{"type":"d","data":1.000000000000000000000000000000000000e+02},"CanGoNext":{"type":"b","data":false},"CanGoPrevious":{"type":"b","data":false},"CanPlay":{"type":"b","data":true},"CanPause":{"type":"b","data":true},"CanSeek":{"type":"b","data":true},"CanControl":{"type":"b","data":true}}]}"#;

#[test]
fn every_call_is_a_fixed_argument_list() {
    let directory = temporary_directory("bus-arguments");
    let bus = stand_in(&directory);
    std::fs::write(directory.join("ListNames.json"), r#"{"type":"as","data":[["org.freedesktop.DBus",":1.5","org.mpris.MediaPlayer2.mpv.instance-dybtSAIF"]]}"#).unwrap();
    std::fs::write(directory.join("Notify.json"), r#"{"type":"u","data":[7]}"#).unwrap();
    assert_eq!(bus.names(LIMIT).unwrap(), ["org.freedesktop.DBus", ":1.5", "org.mpris.MediaPlayer2.mpv.instance-dybtSAIF"]);
    // Text that would be an option, a second command or a format directive anywhere else is one value here.
    let title = "--help";
    let body = "-v; rm -rf ~ $(id) `id` %s \"quoted\" 小组件";
    assert_eq!(bus.notify(title, body, LIMIT), Ok(7));
    let calls = calls(&directory);
    assert_eq!(calls.len(), 2);
    let head = |call: &Vec<String>| (call[..3].to_vec(), call[4..6].to_vec());
    for call in &calls {
        assert_eq!(head(call), (vec!["--user".to_owned(), "--json=short".into(), "--no-pager".into()], vec!["call".to_owned(), "--".into()]), "{call:?}");
        assert!(call[3].starts_with("--timeout=") && call[3].ends_with("ms"), "{}", call[3]);
    }
    assert_eq!(calls[0][6..], ["org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames"]);
    assert_eq!(calls[1][6..], ["org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", "susssasa{sv}i", "ScriptWidget", "0", "", title, body, "0", "0", "-1"]);
    // A NUL would end the argument early; such text is never passed.
    assert_eq!(bus.notify("a\0b", "x", LIMIT), Err(BusError::Failed));
    assert_eq!(calls.len(), self::calls(&directory).len(), "nothing was run for it");
}

#[test]
fn a_name_from_the_bus_is_checked_before_it_is_used() {
    let directory = temporary_directory("bus-names");
    let bus = stand_in(&directory);
    for name in ["--help", "-x.y", "org.mpris.MediaPlayer2.a b", "org.mpris.MediaPlayer2.a;b", ""] {
        assert_eq!(bus.properties(name, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", LIMIT), Err(BusError::Failed), "{name}");
        assert_eq!(bus.has_owner(name, LIMIT), Err(BusError::Failed), "{name}");
    }
    assert_eq!(bus.properties("org.mpris.MediaPlayer2.x", "--path", "org.mpris.MediaPlayer2.Player", LIMIT), Err(BusError::Failed));
    assert!(calls(&directory).is_empty(), "nothing was run");
}

#[test]
fn failures_of_the_program_are_told_apart() {
    let directory = temporary_directory("bus-failures");
    assert_eq!(SessionBus::with_program(directory.join("missing")).names(LIMIT), Err(BusError::NoProgram));
    assert!(!SessionBus::with_program(directory.join("missing")).installed());
    // No answer file: the stand-in ends with a failure, like busctl without a bus.
    let bus = stand_in(&directory);
    assert!(bus.installed());
    assert_eq!(bus.names(LIMIT), Err(BusError::Failed));
    for (answer, expected) in [("not json", BusError::Failed), (r#"{"type":"as"}"#, BusError::Failed), (r#"{"type":"as","data":["a"]}"#, BusError::Failed), ("[]", BusError::Failed)] {
        std::fs::write(directory.join("ListNames.json"), answer).unwrap();
        assert_eq!(bus.names(LIMIT), Err(expected), "{answer}");
    }
    let hanging = directory.join("hanging");
    executable(&hanging, "#!/bin/sh\nexec sleep 30\n");
    let started = Instant::now();
    assert_eq!(SessionBus::with_program(&hanging).names(Duration::from_millis(300)), Err(BusError::TimedOut));
    assert!(started.elapsed() < Duration::from_secs(5), "the call ended with its limit");
}

#[test]
fn the_player_that_plays_is_read() {
    let directory = temporary_directory("bus-mpris");
    let platform = MprisPlatform::new(stand_in(&directory));
    assert!(platform.is_available());
    // Not every name is a player, and a name that is not a bus name is never asked.
    std::fs::write(
        directory.join("ListNames.json"),
        r#"{"type":"as","data":[["org.freedesktop.DBus","org.mpris.MediaPlayer2.","org.mpris.MediaPlayer2.bad name","org.mpris.MediaPlayer2.paused","org.mpris.MediaPlayer2.gone","org.mpris.MediaPlayer2.mpv.instance-dybtSAIF","org.mpris.MediaPlayer3.x"]]}"#,
    )
    .unwrap();
    std::fs::write(directory.join("player-org.mpris.MediaPlayer2.paused.json"), r#"{"type":"a{sv}","data":[{"PlaybackStatus":{"type":"s","data":"Paused"},"Metadata":{"type":"a{sv}","data":{"xesam:title":{"type":"s","data":"Other"}}}}]}"#).unwrap();
    std::fs::write(directory.join("player-org.mpris.MediaPlayer2.mpv.instance-dybtSAIF.json"), MPV).unwrap();
    let reading = platform.read().unwrap().expect("a player");
    assert_eq!((reading.status.as_str(), reading.title.as_deref(), reading.artist.as_deref(), reading.album.as_deref()), ("Playing", Some("Test --Title \"q\""), Some("An Artist"), Some("The Album")));
    assert_eq!((reading.length_microseconds, reading.position_microseconds, reading.has_metadata), (Some(120_000_000.0), Some(1_857_555.0), true));
    let asked: Vec<String> = calls(&directory).iter().filter(|call| call[9] == "GetAll").map(|call| call[6].clone()).collect();
    assert_eq!(asked, ["org.mpris.MediaPlayer2.gone", "org.mpris.MediaPlayer2.mpv.instance-dybtSAIF"], "in name order, until one plays; the one that left the bus is skipped");
    for call in calls(&directory).iter().filter(|call| call[9] == "GetAll") {
        assert_eq!(call[7..], ["/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "GetAll", "s", "org.mpris.MediaPlayer2.Player"]);
    }

    // Without one that plays, the paused one.
    std::fs::remove_file(directory.join("player-org.mpris.MediaPlayer2.mpv.instance-dybtSAIF.json")).unwrap();
    assert_eq!(platform.read().unwrap().unwrap().title.as_deref(), Some("Other"));
    // No player at all is not an error.
    std::fs::write(directory.join("ListNames.json"), r#"{"type":"as","data":[["org.freedesktop.DBus"]]}"#).unwrap();
    assert_eq!(platform.read(), Ok(None));
    // A bus that cannot be asked is.
    std::fs::remove_file(directory.join("ListNames.json")).unwrap();
    assert_eq!(platform.read(), Err(()));
}

#[test]
fn a_body_is_escaped_for_a_service_that_reads_markup() {
    let directory = temporary_directory("bus-notify");
    std::fs::write(directory.join("NameHasOwner.json"), r#"{"type":"b","data":[true]}"#).unwrap();
    std::fs::write(directory.join("GetCapabilities.json"), r#"{"type":"as","data":[["persistence","body","body-markup","actions"]]}"#).unwrap();
    std::fs::write(directory.join("Notify.json"), r#"{"type":"u","data":[1]}"#).unwrap();
    let desktop = DesktopNotifications::new(stand_in(&directory));
    assert!(desktop.enabled());
    assert!(desktop.post("<b>Title</b> & more", "1 < 2 && <a href=\"x\">link</a>"));
    assert!(desktop.post("Again", "plain"));
    let calls = calls(&directory);
    let notify: Vec<&Vec<String>> = calls.iter().filter(|call| call[9] == "Notify").collect();
    assert_eq!((notify[0][14].as_str(), notify[0][15].as_str()), ("<b>Title</b> & more", "1 &lt; 2 &amp;&amp; &lt;a href=\"x\"&gt;link&lt;/a&gt;"), "a title is never markup; the body is escaped");
    assert_eq!(calls.iter().filter(|call| call[9] == "GetCapabilities").count(), 1, "asked once");

    // A service that reads no markup gets the body as it is.
    let plain = temporary_directory("bus-notify-plain");
    std::fs::write(plain.join("GetCapabilities.json"), r#"{"type":"as","data":[["body"]]}"#).unwrap();
    std::fs::write(plain.join("Notify.json"), r#"{"type":"u","data":[1]}"#).unwrap();
    let desktop = DesktopNotifications::new(stand_in(&plain));
    assert!(desktop.post("T", "1 < 2"));
    assert_eq!(self::calls(&plain).iter().find(|call| call[9] == "Notify").unwrap()[15], "1 < 2");
    // No service: nothing is enabled and nothing is shown.
    let none = temporary_directory("bus-notify-none");
    std::fs::write(none.join("NameHasOwner.json"), r#"{"type":"b","data":[false]}"#).unwrap();
    let desktop = DesktopNotifications::new(stand_in(&none));
    assert!(!desktop.enabled());
    assert!(!desktop.post("T", "B"));
}

// The real busctl, on a bus of this test's own.

struct PrivateBus {
    daemon: Child,
    helper: Option<Child>,
    directory: PathBuf,
}

impl Drop for PrivateBus {
    fn drop(&mut self) {
        for child in self.helper.iter_mut().chain([&mut self.daemon]) {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn found(program: &str) -> bool {
    sw_core::process::on_path(Path::new(program))
}

impl PrivateBus {
    /// `None` where `dbus-daemon` or `busctl` is not installed (a Mac, a minimal container).
    fn start(name: &str) -> Option<Self> {
        if !found("dbus-daemon") || !found("busctl") {
            return None;
        }
        // A short path: the address of a Unix socket is limited to about 100 bytes.
        let directory = PathBuf::from(format!("/tmp/swbus-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let address = format!("unix:path={}", directory.join("bus").display());
        let mut daemon = Command::new("dbus-daemon").args(["--session", "--nofork", "--print-address", "--address", &address]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
        let mut line = String::new();
        BufReader::new(daemon.stdout.take()?).read_line(&mut line).ok()?;
        assert!(line.starts_with("unix:path="), "dbus-daemon printed {line:?}");
        // busctl reaches this bus and no other: the wrapper names it, whatever the environment of the test says.
        executable(&directory.join("busctl"), &format!("#!/bin/sh\nDBUS_SESSION_BUS_ADDRESS='{address}' exec busctl \"$@\"\n"));
        Some(Self { daemon, helper: None, directory })
    }

    fn bus(&self) -> SessionBus {
        SessionBus::with_program(self.directory.join("busctl"))
    }

    /// Starts the stand-in player and notification service; false where Python's D-Bus modules are missing.
    fn start_services(&mut self) -> bool {
        let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/api_fixtures/bus-stand-in.py");
        let importable = Command::new("python3").args(["-c", "import dbus, dbus.service, dbus.mainloop.glib; from gi.repository import GLib"]).stderr(Stdio::null()).status().is_ok_and(|status| status.success());
        if !importable {
            return false;
        }
        let address = format!("unix:path={}", self.directory.join("bus").display());
        let mut helper = Command::new("python3").arg(script).arg(self.directory.join("shown")).env("DBUS_SESSION_BUS_ADDRESS", address).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().expect("python3");
        let mut ready = [0u8; 6];
        let started = helper.stdout.as_mut().unwrap().read_exact(&mut ready).is_ok() && &ready == b"ready\n";
        self.helper = Some(helper);
        assert!(started, "the stand-in services did not start");
        true
    }
}

#[test]
fn the_real_busctl_on_a_private_bus() {
    let Some(mut private) = PrivateBus::start("real") else {
        eprintln!("skipped: dbus-daemon and busctl are not installed here");
        return;
    };
    let bus = private.bus();
    // An empty bus: no player, no notification service.
    assert!(bus.names(LIMIT).unwrap().contains(&"org.freedesktop.DBus".to_owned()));
    let platform = MprisPlatform::new(bus.clone());
    assert_eq!(platform.read(), Ok(None));
    assert_eq!(bus.has_notification_service(LIMIT), Ok(false));
    let desktop = DesktopNotifications::new(bus.clone());
    assert!(!desktop.enabled());
    assert!(!desktop.post("T", "B"), "nothing answers");
    assert_eq!(bus.properties("org.mpris.MediaPlayer2.nobody", "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", LIMIT), Err(BusError::Failed));

    if !private.start_services() {
        eprintln!("skipped the second half: python3 with dbus and gi is not installed here");
        return;
    }
    let reading = platform.read().unwrap().expect("the stand-in player");
    let snapshot = music_rules::snapshot(Some(&reading), 0);
    assert_eq!((snapshot.state, snapshot.has_item, snapshot.title.as_deref(), snapshot.artist.as_deref(), snapshot.album.as_deref()), ("playing", true, Some("Stand-in --title"), Some("First, Second"), Some("An Album")));
    assert_eq!((snapshot.duration, snapshot.position), (Some(200.0), Some(42.5)));
    assert!(!sw_core::json::stringify_object(&snapshot.to_json()).contains("private"), "no address of a file or a cover leaves the bus layer");

    assert!(desktop.enabled());
    let fresh = DesktopNotifications::new(bus);
    assert!(fresh.post("--help", "-v <b>bold</b> & $(id) \"q\" 小组件"));
    let shown: Vec<Value> = std::fs::read_to_string(private.directory.join("shown")).unwrap().lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0], serde_json::json!({"app": "ScriptWidget", "summary": "--help", "body": "-v &lt;b&gt;bold&lt;/b&gt; &amp; $(id) \"q\" 小组件", "actions": 0, "hints": 0, "timeout": -1}));
}
