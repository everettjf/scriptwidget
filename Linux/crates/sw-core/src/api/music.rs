//! `$music`: a read-only snapshot of what a media player on this desktop is
//! playing, from MPRIS on the session bus. The rules are the ones of
//! `Android/core/.../system/MusicModule.kt`; only where the snapshot comes
//! from differs.
//!
//! Differences from Android, which reads the device's active media session:
//! - `provider` is `mpris`.
//! - Any program of the user can read the session bus, so there is nothing
//!   for the user to allow beyond the package's `music` permission:
//!   `authorizationStatus()` is `authorized` for a package that declares it.
//! - A paused player has a position; MPRIS has no "seeking" or "interrupted"
//!   state, so those are never produced.
//!
//! Nothing is controlled, and no artwork, queue, player name or file
//! address is read or returned, as the contract requires.

use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sw_quickjs::HostResult;

use crate::api::bus::{SessionBus, is_bus_name};
use crate::api::support::{CallContext, SystemReject, is_control_or_format, iso_dates, run_system, system_log, system_options};
use crate::api::weather::Clock;
use crate::executor::{Completion, ExecutionRequest, ExecutionSession, NativeModule};
use crate::json::{Object, ObjectExt, quote, stringify_object};

/// The `$music` rejections, with the Apple runtime's codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MusicError {
    Permission,
    Unavailable,
    Snapshot,
    ReadOnly,
    QueryLimit,
}

impl MusicError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Permission => "[music_permission] Install this widget, declare music and allow Music access in ScriptWidget Settings.",
            Self::Unavailable => "[music_unavailable] Current Music app playback is unavailable on this platform.",
            Self::Snapshot => "[music_snapshot] Playback information could not be read.",
            Self::ReadOnly => "[timeline_read_only] Prepare Music display data in the current entry",
            Self::QueryLimit => "[query_limit] Too many system data queries",
        }
    }

    pub fn reject(self) -> SystemReject {
        SystemReject(self.message().to_owned())
    }
}

/// What one player reports, before any bounding. Times are microseconds, as MPRIS gives them.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PlayerReading {
    /// `Playing`, `Paused`, `Stopped`, or whatever else the player says.
    pub status: String,
    /// False when the player publishes no track at all.
    pub has_metadata: bool,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub length_microseconds: Option<f64>,
    pub position_microseconds: Option<f64>,
}

/// One playback snapshot with exactly the documented fields.
#[derive(Debug, Clone, PartialEq)]
pub struct MusicSnapshot {
    pub state: &'static str,
    pub has_item: bool,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration: Option<f64>,
    pub position: Option<f64>,
    pub captured_at: i64,
}

impl MusicSnapshot {
    pub fn to_json(&self) -> Object {
        match json!({
            "provider": music_rules::PROVIDER,
            "state": self.state,
            "hasItem": self.has_item,
            "title": self.title,
            "artist": self.artist,
            "album": self.album,
            "duration": self.duration,
            "position": self.position,
            "capturedAt": iso_dates::format(self.captured_at),
        }) {
            Value::Object(object) => object,
            _ => Object::new(),
        }
    }
}

/// Pure rules of `$music`.
pub mod music_rules {
    use super::*;

    /// The `provider` value on Linux: any MPRIS player. It is never `appleMusic`.
    pub const PROVIDER: &str = "mpris";
    pub const STATES: [&str; 6] = ["playing", "paused", "stopped", "interrupted", "seeking", "unknown"];
    pub const MAXIMUM_SECONDS: f64 = 604_800.0;
    pub const MAXIMUM_TEXT_CHARACTERS: usize = 256;
    pub const MAXIMUM_TEXT_BYTES: usize = 512;

    /// MPRIS `PlaybackStatus` to the documented states; anything else is `unknown`.
    pub fn state(status: &str) -> &'static str {
        match status {
            "Playing" => "playing",
            "Paused" => "paused",
            "Stopped" => "stopped",
            _ => "unknown",
        }
    }

    /// Text without control or format characters, at most 256 characters and 512 UTF-8 bytes; `None` when nothing is left.
    pub fn text(raw: Option<&str>) -> Option<String> {
        let cleaned: String = raw?.chars().filter(|character| !is_control_or_format(*character)).collect();
        let mut value: String = cleaned.trim().chars().take(MAXIMUM_TEXT_CHARACTERS).collect();
        while value.len() > MAXIMUM_TEXT_BYTES {
            value.pop();
        }
        (!value.is_empty()).then_some(value)
    }

    /// The snapshot for `reading`, or for no player when it is `None` (`stopped`, no item).
    /// - `hasItem` is whether the player publishes a track; without it title, artist, album and duration are null.
    /// - `duration` is positive and at most 604800 seconds, else null; `position` is 0…604800, else null,
    ///   and never past the duration.
    pub fn snapshot(reading: Option<&PlayerReading>, now_milliseconds: i64) -> MusicSnapshot {
        let Some(reading) = reading else {
            return MusicSnapshot { state: "stopped", has_item: false, title: None, artist: None, album: None, duration: None, position: None, captured_at: now_milliseconds };
        };
        let seconds = |microseconds: Option<f64>| microseconds.map(|value| value / 1_000_000.0).filter(|value| value.is_finite());
        let duration = seconds(reading.length_microseconds).filter(|value| *value > 0.0 && *value <= MAXIMUM_SECONDS);
        let position = seconds(reading.position_microseconds).filter(|value| *value >= 0.0 && *value <= MAXIMUM_SECONDS).map(|value| duration.map_or(value, |duration| value.min(duration)));
        let item = reading.has_metadata;
        let kept = |value: &Option<String>| if item { text(value.as_deref()) } else { None };
        MusicSnapshot {
            state: state(&reading.status),
            has_item: item,
            title: kept(&reading.title),
            artist: kept(&reading.artist),
            album: kept(&reading.album),
            duration: duration.filter(|_| item),
            position,
            captured_at: now_milliseconds,
        }
    }

    /// The invariants every delivered snapshot satisfies; a violation is `music_snapshot`.
    pub fn valid(snapshot: &MusicSnapshot) -> bool {
        let ok = |value: &Option<String>| value.as_ref().is_none_or(|value| value.len() <= MAXIMUM_TEXT_BYTES && !system_options::has_control_characters(value));
        STATES.contains(&snapshot.state)
            && ok(&snapshot.title)
            && ok(&snapshot.artist)
            && ok(&snapshot.album)
            && (snapshot.has_item || (snapshot.title.is_none() && snapshot.artist.is_none() && snapshot.album.is_none() && snapshot.duration.is_none()))
            && snapshot.duration.is_none_or(|value| value.is_finite() && value > 0.0 && value <= MAXIMUM_SECONDS)
            && snapshot.position.is_none_or(|value| value.is_finite() && (0.0..=MAXIMUM_SECONDS).contains(&value))
    }

    /// What the properties of `org.mpris.MediaPlayer2.Player` say, as [`SessionBus::properties`] returns them.
    pub fn reading(properties: &Object) -> PlayerReading {
        let metadata = properties.opt_object("Metadata");
        let string = |name: &str| metadata.and_then(|metadata| metadata.get(name)).and_then(Value::as_str).map(str::to_owned);
        // `xesam:artist` is a list; a player that sends one string is read too.
        let artist = metadata.and_then(|metadata| metadata.get("xesam:artist")).and_then(|value| match value {
            Value::Array(names) => {
                let names: Vec<&str> = names.iter().filter_map(Value::as_str).filter(|name| !name.trim().is_empty()).take(8).collect();
                (!names.is_empty()).then(|| names.join(", "))
            }
            Value::String(name) => Some(name.clone()),
            _ => None,
        });
        let track = string("mpris:trackid");
        let has_metadata = metadata.is_some_and(|metadata| !metadata.is_empty()) && track.as_deref() != Some("/org/mpris/MediaPlayer2/TrackList/NoTrack");
        PlayerReading {
            status: properties.opt_string("PlaybackStatus"),
            has_metadata,
            title: string("xesam:title"),
            artist,
            album: string("xesam:album"),
            length_microseconds: system_options::json_number(metadata.and_then(|metadata| metadata.get("mpris:length"))),
            position_microseconds: system_options::json_number(properties.get("Position")),
        }
    }
}

/// The system side of `$music`.
pub trait MusicPlatform: Send + Sync {
    /// This desktop can report media players at all. Must not block.
    fn is_available(&self) -> bool;
    /// The most relevant player, or `None` when there is none. `Err` when the bus could not be asked.
    #[allow(clippy::result_unit_err)]
    fn read(&self) -> Result<Option<PlayerReading>, ()>;
}

/// MPRIS through `busctl`: the players are the bus names that start with
/// `org.mpris.MediaPlayer2.`. One that is playing is preferred, then one
/// that is paused, then the first. At most eight players are asked, and the
/// whole read takes at most three seconds.
pub struct MprisPlatform {
    bus: SessionBus,
}

impl MprisPlatform {
    pub const PREFIX: &'static str = "org.mpris.MediaPlayer2.";
    pub const MAXIMUM_PLAYERS: usize = 8;
    const CALL_LIMIT: Duration = Duration::from_millis(1500);
    const TOTAL_LIMIT: Duration = Duration::from_millis(3000);

    pub fn new(bus: SessionBus) -> Self {
        Self { bus }
    }
}

impl MusicPlatform for MprisPlatform {
    fn is_available(&self) -> bool {
        self.bus.installed()
    }

    fn read(&self) -> Result<Option<PlayerReading>, ()> {
        let deadline = Instant::now() + Self::TOTAL_LIMIT;
        let left = || deadline.saturating_duration_since(Instant::now()).min(Self::CALL_LIMIT);
        let mut players: Vec<String> = self.bus.names(left()).map_err(|_| ())?.into_iter().filter(|name| name.starts_with(Self::PREFIX) && name.len() > Self::PREFIX.len() && is_bus_name(name)).collect();
        players.sort_unstable();
        let mut best: Option<(u8, PlayerReading)> = None;
        for player in players.iter().take(Self::MAXIMUM_PLAYERS) {
            if left() < Duration::from_millis(150) {
                break;
            }
            // A player that left the bus meanwhile, or does not answer, is skipped.
            let Ok(properties) = self.bus.properties(player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", left()) else { continue };
            let reading = music_rules::reading(&properties);
            let rank = match reading.status.as_str() {
                "Playing" => 0,
                "Paused" => 1,
                _ => 2,
            };
            if best.as_ref().is_none_or(|(known, _)| rank < *known) {
                best = Some((rank, reading));
            }
            if rank == 0 {
                break;
            }
        }
        Ok(best.map(|(_, reading)| reading))
    }
}

type Shared = Result<MusicSnapshot, SystemReject>;
/// The snapshot each running execution has seen.
type Snapshots = Arc<Mutex<Vec<(Weak<ExecutionSession>, Shared)>>>;

/// `$music`: `isAvailable()`, `authorizationStatus()` and `current()`, read-only.
///
/// `current()` checks, in the Apple runtime's order: an installed package
/// that declares `music` (`music_permission`); not a future timeline entry
/// or Live Activity (`timeline_read_only`); the eight-query budget
/// (`query_limit`); platform availability (`music_unavailable`). One
/// snapshot is shared by all calls of an execution, and the permission is
/// checked again before delivery. Nothing is persisted or logged.
#[derive(Clone)]
pub struct MusicModule {
    platform: Arc<dyn MusicPlatform>,
    clock: Clock,
    /// One snapshot (or failure) per execution, dropped with the execution.
    snapshots: Snapshots,
}

impl MusicModule {
    pub const PERMISSION: &'static str = "music";

    pub fn new(platform: Arc<dyn MusicPlatform>) -> Self {
        Self::with_clock(platform, Arc::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)))
    }

    pub fn with_clock(platform: Arc<dyn MusicPlatform>, clock: Clock) -> Self {
        Self { platform, clock, snapshots: Arc::default() }
    }

    /// An installed Package 2.0 widget that declares `music`.
    pub fn permitted(context: &CallContext) -> bool {
        context.is_installed() && context.declares(Self::PERMISSION)
    }

    /// Package access and a desktop that can report players. It does not mean a player is running.
    pub fn is_available(&self, context: &CallContext) -> bool {
        Self::permitted(context) && self.platform.is_available()
    }

    /// `undeclared` without package access; `unavailable` without `busctl`; otherwise `authorized`.
    pub fn authorization_status(&self, context: &CallContext) -> &'static str {
        if !Self::permitted(context) {
            "undeclared"
        } else if self.platform.is_available() {
            "authorized"
        } else {
            "unavailable"
        }
    }

    /// The snapshot for this execution; `execution` identifies the execution whose calls share one read.
    pub fn current(&self, context: &CallContext, execution: &Arc<ExecutionSession>) -> Result<Object, SystemReject> {
        if !Self::permitted(context) {
            return Err(MusicError::Permission.reject());
        }
        if context.is_timeline_projection || context.is_live_activity {
            return Err(MusicError::ReadOnly.reject());
        }
        if !context.consume_data_query() {
            return Err(MusicError::QueryLimit.reject());
        }
        if !self.platform.is_available() {
            return Err(MusicError::Unavailable.reject());
        }
        let result = {
            // Held while the bus is asked: a second call of the same execution waits and shares the answer.
            let mut snapshots = self.snapshots.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            snapshots.retain(|(session, _)| session.strong_count() > 0);
            match snapshots.iter().find(|(session, _)| session.as_ptr() == Arc::as_ptr(execution)) {
                Some((_, known)) => known.clone(),
                None => {
                    let fresh = match self.platform.read() {
                        Ok(reading) => Some(music_rules::snapshot(reading.as_ref(), (self.clock)())).filter(music_rules::valid).ok_or_else(|| MusicError::Snapshot.reject()),
                        Err(()) => Err(MusicError::Snapshot.reject()),
                    };
                    snapshots.push((Arc::downgrade(execution), fresh.clone()));
                    fresh
                }
            }
        };
        if !Self::permitted(context) {
            return Err(MusicError::Permission.reject());
        }
        result.map(|snapshot| snapshot.to_json())
    }
}

impl NativeModule for MusicModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("music.")
    }

    fn apis(&self) -> &[&'static str] {
        &["$music"]
    }

    fn call(&self, request: &ExecutionRequest<'_>, operation: &str, _payload: Option<&str>) -> HostResult {
        let context = CallContext::from_request(request);
        let value = match operation {
            "music.isAvailable" => if self.is_available(&context) { "true" } else { "false" }.to_owned(),
            "music.authorizationStatus" => quote(self.authorization_status(&context)),
            _ => return Err(format!("Unsupported operation {operation}")),
        };
        system_log::call(operation, "ok");
        Ok(Some(value))
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, _payload: Option<&Object>, done: Completion) {
        if operation != "music.current" {
            return done.complete(false, Some(quote(&format!("Unsupported operation {operation}"))));
        }
        let context = CallContext::from_request(request);
        let (module, execution) = (self.clone(), request.session.clone());
        run_system(operation, done, move || module.current(&context, &execution).map(|result| stringify_object(&result)));
    }
}
