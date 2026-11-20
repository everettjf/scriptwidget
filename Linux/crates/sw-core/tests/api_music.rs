//! `$music`: the snapshot rules, the order of the checks and what a script
//! sees. The player is a stand-in; `api_bus.rs` covers MPRIS itself.

mod api_common;

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use api_common::*;
use serde_json::{Value, json};
use sw_core::api::music::{MusicError, MusicModule, MusicPlatform, PlayerReading, music_rules};
use sw_core::api::support::CallContext;
use sw_core::{ExecutionSession, NativeModule};

const OWNER: &str = "11111111-1111-4111-8111-111111111111";

struct FakePlayer {
    available: bool,
    reading: Mutex<Result<Option<PlayerReading>, ()>>,
    reads: AtomicU32,
}

impl FakePlayer {
    fn new(reading: Result<Option<PlayerReading>, ()>) -> Arc<Self> {
        Arc::new(Self { available: true, reading: Mutex::new(reading), reads: AtomicU32::new(0) })
    }
}

impl MusicPlatform for FakePlayer {
    fn is_available(&self) -> bool {
        self.available
    }

    fn read(&self) -> Result<Option<PlayerReading>, ()> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        self.reading.lock().unwrap().clone()
    }
}

fn playing() -> PlayerReading {
    PlayerReading { status: "Playing".into(), has_metadata: true, title: Some("Song".into()), artist: Some("Artist".into()), album: Some("Album".into()), length_microseconds: Some(200_000_000.0), position_microseconds: Some(42_500_000.0) }
}

fn module(player: &Arc<FakePlayer>) -> MusicModule {
    MusicModule::with_clock(player.clone(), Arc::new(|| 1_767_268_800_000))
}

fn context() -> CallContext {
    CallContext::new(OWNER, true, &["music"], &[], Some("1.4"))
}

fn session() -> Arc<ExecutionSession> {
    Arc::new(ExecutionSession::default())
}

#[test]
fn a_snapshot_has_exactly_the_documented_fields() {
    let player = FakePlayer::new(Ok(Some(playing())));
    let snapshot = module(&player).current(&context(), &session()).unwrap();
    assert_eq!(
        Value::Object(snapshot),
        json!({"provider": "mpris", "state": "playing", "hasItem": true, "title": "Song", "artist": "Artist", "album": "Album", "duration": 200.0, "position": 42.5, "capturedAt": "2026-01-01T12:00:00Z"})
    );
    // No player is "stopped" with no item, not an error.
    let nothing = FakePlayer::new(Ok(None));
    assert_eq!(
        Value::Object(module(&nothing).current(&context(), &session()).unwrap()),
        json!({"provider": "mpris", "state": "stopped", "hasItem": false, "title": null, "artist": null, "album": null, "duration": null, "position": null, "capturedAt": "2026-01-01T12:00:00Z"})
    );
}

#[test]
fn readings_are_bounded() {
    let snapshot = |reading: PlayerReading| music_rules::snapshot(Some(&reading), 0);
    for (status, state) in [("Playing", "playing"), ("Paused", "paused"), ("Stopped", "stopped"), ("Buffering", "unknown"), ("", "unknown"), ("playing", "unknown")] {
        assert_eq!(snapshot(PlayerReading { status: status.into(), ..playing() }).state, state, "{status}");
    }
    // Control and format characters are removed; text is cut to 256 characters and 512 bytes.
    let long = snapshot(PlayerReading { title: Some(format!("  a\u{202e}b\n\u{0}c{}", "é".repeat(400))), artist: Some("\u{200b} \n".into()), album: Some("好".repeat(300)), ..playing() });
    let title = long.title.unwrap();
    assert!(title.starts_with("abc") && title.chars().count() == 256 && title.len() <= 512, "{} characters, {} bytes", title.chars().count(), title.len());
    assert_eq!(long.artist, None, "nothing left is null, not an empty string");
    let album = long.album.unwrap();
    assert!(album.len() <= 512 && album.chars().all(|character| character == '好'), "cut at a character, {} bytes", album.len());
    // Times outside the documented ranges are null; the position never passes the duration.
    let times = |length: Option<f64>, position: Option<f64>| {
        let snapshot = snapshot(PlayerReading { length_microseconds: length, position_microseconds: position, ..playing() });
        (snapshot.duration, snapshot.position)
    };
    assert_eq!(times(Some(0.0), Some(-1.0)), (None, None));
    assert_eq!(times(Some(700_000.0 * 1e6), Some(700_000.0 * 1e6)), (None, None));
    assert_eq!(times(Some(f64::NAN), Some(f64::INFINITY)), (None, None));
    assert_eq!(times(Some(10e6), Some(25e6)), (Some(10.0), Some(10.0)));
    assert_eq!(times(None, Some(5e6)), (None, Some(5.0)));
    // A player without a track has a state and maybe a position, nothing else.
    let empty = snapshot(PlayerReading { has_metadata: false, ..playing() });
    assert!(music_rules::valid(&empty));
    assert_eq!((empty.has_item, empty.title, empty.artist, empty.album, empty.duration, empty.position), (false, None, None, None, None, Some(42.5)));
}

#[test]
fn metadata_is_read_from_mpris_properties() {
    let properties = json!({
        "PlaybackStatus": "Paused",
        "Position": 1_500_000,
        "Metadata": {"mpris:trackid": "/x/1", "mpris:length": 60_000_000u64, "xesam:title": "T", "xesam:artist": ["A", "", "B"], "xesam:album": 7, "xesam:url": "file:///secret/path.mp3", "mpris:artUrl": "file:///secret/cover.png"},
    });
    let reading = music_rules::reading(properties.as_object().unwrap());
    assert_eq!(reading, PlayerReading { status: "Paused".into(), has_metadata: true, title: Some("T".into()), artist: Some("A, B".into()), album: None, length_microseconds: Some(60_000_000.0), position_microseconds: Some(1_500_000.0) });
    // The "no track" identifier, an empty dictionary and a missing one all mean no item.
    for metadata in [json!({"mpris:trackid": "/org/mpris/MediaPlayer2/TrackList/NoTrack", "xesam:title": "stale"}), json!({}), Value::Null] {
        let properties = json!({"PlaybackStatus": "Stopped", "Metadata": metadata});
        assert!(!music_rules::reading(properties.as_object().unwrap()).has_metadata, "{properties}");
    }
    // Values of the wrong type are absent, never an error.
    let odd = json!({"PlaybackStatus": 3, "Position": "soon", "Metadata": {"xesam:title": ["a"], "xesam:artist": "Solo", "mpris:length": "long"}});
    let reading = music_rules::reading(odd.as_object().unwrap());
    assert_eq!((reading.status.as_str(), reading.title, reading.artist.as_deref(), reading.length_microseconds, reading.position_microseconds), ("3", None, Some("Solo"), None, None));
}

#[test]
fn the_checks_come_in_the_documented_order() {
    let player = FakePlayer::new(Ok(Some(playing())));
    let module = module(&player);
    let message = |context: &CallContext| module.current(context, &session()).unwrap_err().0;
    // 1. An installed package that declares music.
    for context in [CallContext::new(OWNER, true, &["network"], &[], None), CallContext::new("preview", true, &["music"], &[], None), CallContext::new(OWNER, false, &["music"], &[], None)] {
        assert_eq!(message(&context), MusicError::Permission.message());
        assert_eq!(module.authorization_status(&context), "undeclared");
        assert!(!module.is_available(&context));
    }
    // 2. Not a future timeline entry or a Live Activity, before the budget is touched.
    let spent = Arc::new(AtomicU32::new(0));
    let counted = |spent: &Arc<AtomicU32>| {
        let spent = spent.clone();
        context().with_probes(move || spent.fetch_add(1, Ordering::SeqCst) < 1, || true, || true)
    };
    let mut projection = counted(&spent);
    projection.is_timeline_projection = true;
    assert_eq!(message(&projection), MusicError::ReadOnly.message());
    let mut live = counted(&spent);
    live.is_live_activity = true;
    assert_eq!(message(&live), MusicError::ReadOnly.message());
    assert_eq!(spent.load(Ordering::SeqCst), 0);
    // 3. The query budget.
    let budget = counted(&spent);
    assert!(module.current(&budget, &session()).is_ok());
    assert_eq!(message(&budget), MusicError::QueryLimit.message());
    // 4. A desktop that can be asked.
    let missing = Arc::new(FakePlayer { available: false, reading: Mutex::new(Ok(None)), reads: AtomicU32::new(0) });
    let unavailable = self::module(&missing);
    assert_eq!(unavailable.current(&context(), &session()).unwrap_err().0, MusicError::Unavailable.message());
    assert_eq!(unavailable.authorization_status(&context()), "unavailable");
    assert_eq!(missing.reads.load(Ordering::SeqCst), 0);
    // A bus that fails is a snapshot error.
    let broken = FakePlayer::new(Err(()));
    assert_eq!(self::module(&broken).current(&context(), &session()).unwrap_err().0, MusicError::Snapshot.message());
    assert_eq!(module.authorization_status(&context()), "authorized");
}

#[test]
fn one_execution_shares_one_read() {
    let player = FakePlayer::new(Ok(Some(playing())));
    let module = module(&player);
    let execution = session();
    let first = module.current(&context(), &execution).unwrap();
    *player.reading.lock().unwrap() = Ok(None);
    assert_eq!(module.current(&context(), &execution).unwrap(), first, "the same execution sees the same snapshot");
    assert_eq!(player.reads.load(Ordering::SeqCst), 1);
    assert_eq!(module.current(&context(), &session()).unwrap()["state"], "stopped", "the next execution reads again");
    assert_eq!(player.reads.load(Ordering::SeqCst), 2);
}

fn manifest(permissions: &str) -> String {
    widget_manifest(permissions, "[]")
}

fn run_as(owner: &str, source: &str, manifest: &str, player: &Arc<FakePlayer>) -> String {
    let modules: Vec<Arc<dyn NativeModule>> = vec![Arc::new(module(player))];
    let result = run(source, Some(manifest), modules, &[], |request| request.package_id = owner.to_owned());
    assert!(result.error.is_none(), "error: {:?}", result.error);
    let tree: Value = serde_json::from_str(result.tree.as_deref().expect("tree")).unwrap();
    tree["children"].as_array().unwrap().iter().map(|child| child.as_str().unwrap_or("").to_owned()).collect()
}

const SCRIPT: &str = "let text; try { const now = await $music.current(); text = [$music.isAvailable(), $music.authorizationStatus(), now.provider, now.state, now.title, now.position, Object.keys(now).sort().join('+')].join('|'); } catch (error) { text = [$music.isAvailable(), $music.authorizationStatus(), String(error.message ?? error)].join('|'); }\n$render(<text>{text}</text>);";

#[test]
fn a_script_reads_the_snapshot_and_nothing_else() {
    let player = FakePlayer::new(Ok(Some(playing())));
    assert_eq!(run_as(OWNER, SCRIPT, &manifest(r#"["music"]"#), &player), "true|authorized|mpris|playing|Song|42.5|album+artist+capturedAt+duration+hasItem+position+provider+state+title");
    // Without the permission, and for a package that is not installed, the script is told so.
    assert_eq!(run_as(OWNER, SCRIPT, &manifest("[]"), &player), format!("false|undeclared|{}", MusicError::Permission.message()));
    assert_eq!(run_as("cli:/tmp/x", SCRIPT, &manifest(r#"["music"]"#), &player), format!("false|undeclared|{}", MusicError::Permission.message()));
    assert_eq!(player.reads.load(Ordering::SeqCst), 1, "a refused call never asks the player");
    // There is nothing to control a player with.
    assert_eq!(run_as(OWNER, "$render(<text>{Object.keys($music).sort().join(',')}</text>);", &manifest(r#"["music"]"#), &player), "authorizationStatus,current,isAvailable");
}
