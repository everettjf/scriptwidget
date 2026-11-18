//! What the service remembers between runs: the widgets on the desktop
//! (`widgets.json` in the data directory), what the display last said about
//! screens and theme (`display.json` in the cache directory), and the one
//! setting it reads (`refreshMinutes` in `settings.json`). Ported from
//! `Windows/src/ScriptWidget.Core/Hosting/WidgetPlacements.cs`.
//!
//! The files are the user's, but they are still read as untrusted text:
//! anything that is not a valid entry is dropped, never repaired by guessing.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde_json::{Map, Value, json};

use crate::protocol::{self, MAXIMUM_OFFSET, MAXIMUM_SCALE, MAXIMUM_SCREEN_LENGTH, MINIMUM_SCALE};

pub const MAXIMUM_WIDGETS: usize = 64;
pub const MAXIMUM_SCREENS: usize = 16;
pub const DEFAULT_REFRESH_MINUTES: u64 = 15;
pub const MINIMUM_REFRESH_MINUTES: u64 = 5;
pub const MAXIMUM_REFRESH_MINUTES: u64 = 24 * 60;
/// Larger files are not ours.
const MAXIMUM_FILE_BYTES: u64 = 256 * 1024;

/// One widget on the desktop: which package it shows, at what size, and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Placement {
    pub id: String,
    /// The installation identity of the package, which stays the same when the package is renamed.
    pub package: String,
    pub family: String,
    /// The display's name of the screen; empty until the display has placed the widget.
    pub screen: String,
    /// Offset from the screen's top-left corner in logical pixels.
    pub x: i64,
    pub y: i64,
}

/// True for the form `sw_core::library` gives an installation identity.
pub fn is_installation(text: &str) -> bool {
    (8..=64).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

impl Placement {
    fn to_json(&self) -> Value {
        json!({ "id": self.id, "package": self.package, "family": self.family, "screen": self.screen, "x": self.x, "y": self.y })
    }

    fn from_json(item: &Map<String, Value>) -> Option<Self> {
        let text = |name: &str| item.get(name).and_then(Value::as_str);
        let id = text("id").filter(|id| protocol::is_identifier(id))?;
        let package = text("package").filter(|package| is_installation(package))?;
        let family = text("family").filter(|family| protocol::is_family(family)).unwrap_or("medium");
        let screen = text("screen").filter(|screen| protocol::is_screen_name(screen)).unwrap_or("");
        let offset = |name: &str| item.get(name).and_then(Value::as_i64).unwrap_or(0).clamp(-MAXIMUM_OFFSET, MAXIMUM_OFFSET);
        Some(Self { id: id.to_owned(), package: package.to_owned(), family: family.to_owned(), screen: screen.to_owned(), x: offset("x"), y: offset("y") })
    }
}

/// Reads a small JSON object from a regular file, never through a link.
fn read_object(file: &Path) -> Option<Map<String, Value>> {
    use std::io::Read;
    let opened = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK).open(file).ok()?;
    if !opened.metadata().ok()?.is_file() {
        return None;
    }
    let mut text = String::new();
    opened.take(MAXIMUM_FILE_BYTES + 1).read_to_string(&mut text).ok()?;
    if text.len() as u64 > MAXIMUM_FILE_BYTES {
        return None;
    }
    match serde_json::from_str(&text).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

/// Writes beside the file and renames over it: a reader sees the old or the new content, and a link at the name is replaced, not followed.
fn replace(file: &Path, value: &Value) -> std::io::Result<()> {
    let mut temporary = file.as_os_str().to_owned();
    temporary.push(format!(".{}.tmp", std::process::id()));
    let temporary = PathBuf::from(temporary);
    let _ = std::fs::remove_file(&temporary);
    let written = (|| {
        let mut output = std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600).open(&temporary)?;
        output.write_all(serde_json::to_string_pretty(value).unwrap_or_default().as_bytes())?;
        output.write_all(b"\n")?;
        output.sync_all()?;
        std::fs::rename(&temporary, file)
    })();
    written.inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

/// The saved list of desktop widgets.
pub struct Placements {
    file: PathBuf,
    items: Vec<Placement>,
}

impl Placements {
    pub fn load(file: PathBuf) -> Self {
        let mut items: Vec<Placement> = Vec::new();
        if let Some(root) = read_object(&file)
            && let Some(Value::Array(widgets)) = root.get("widgets")
        {
            for placement in widgets.iter().filter_map(Value::as_object).filter_map(Placement::from_json) {
                if items.len() < MAXIMUM_WIDGETS && items.iter().all(|existing| existing.id != placement.id) {
                    items.push(placement);
                }
            }
        }
        Self { file, items }
    }

    pub fn all(&self) -> &[Placement] {
        &self.items
    }

    pub fn find(&self, id: &str) -> Option<&Placement> {
        self.items.iter().find(|item| item.id == id)
    }

    /// Adds a widget and saves. `None` when the limit is reached.
    pub fn add(&mut self, placement: Placement) -> Option<&Placement> {
        if self.items.len() >= MAXIMUM_WIDGETS || self.find(&placement.id).is_some() {
            return None;
        }
        self.items.push(placement);
        self.save();
        self.items.last()
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.items.len();
        self.items.retain(|item| item.id != id);
        let removed = self.items.len() != before;
        if removed {
            self.save();
        }
        removed
    }

    /// Changes one placement and saves when something changed.
    pub fn update(&mut self, id: &str, change: impl FnOnce(&mut Placement)) -> Option<&Placement> {
        let index = self.items.iter().position(|item| item.id == id)?;
        let before = self.items[index].clone();
        change(&mut self.items[index]);
        if self.items[index] != before {
            self.save();
        }
        self.items.get(index)
    }

    fn save(&self) {
        let value = json!({ "version": 1, "widgets": self.items.iter().map(Placement::to_json).collect::<Vec<_>>() });
        if let Err(error) = replace(&self.file, &value) {
            crate::log(&format!("the widget list could not be saved: {error}"));
        }
    }
}

/// A screen as the display reported it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScreenInfo {
    /// Pixels per logical pixel, in thousandths.
    pub scale: i64,
    pub width: i64,
    pub height: i64,
}

impl ScreenInfo {
    pub fn factor(&self) -> f32 {
        self.scale as f32 / 1000.0
    }
}

/// What the display last reported, kept so that a restarted service draws at
/// the right scale and in the right theme before the display reports again.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DisplayMemory {
    pub dark: bool,
    pub screens: BTreeMap<String, ScreenInfo>,
}

impl DisplayMemory {
    pub fn load(file: &Path) -> Self {
        let mut memory = Self::default();
        let Some(root) = read_object(file) else { return memory };
        memory.dark = root.get("dark").and_then(Value::as_bool).unwrap_or(false);
        if let Some(Value::Object(screens)) = root.get("screens") {
            for (name, value) in screens {
                let number = |member: &str, minimum: i64, maximum: i64| value.get(member).and_then(Value::as_i64).filter(|number| (minimum..=maximum).contains(number));
                if memory.screens.len() < MAXIMUM_SCREENS
                    && protocol::is_screen_name(name)
                    && let (Some(scale), Some(width), Some(height)) = (number("scale", MINIMUM_SCALE, MAXIMUM_SCALE), number("width", 1, MAXIMUM_SCREEN_LENGTH), number("height", 1, MAXIMUM_SCREEN_LENGTH))
                {
                    memory.screens.insert(name.clone(), ScreenInfo { scale, width, height });
                }
            }
        }
        memory
    }

    pub fn save(&self, file: &Path) {
        let screens: Map<String, Value> = self.screens.iter().map(|(name, screen)| (name.clone(), json!({ "scale": screen.scale, "width": screen.width, "height": screen.height }))).collect();
        if let Err(error) = replace(file, &json!({ "dark": self.dark, "screens": screens })) {
            crate::log(&format!("the display state could not be saved: {error}"));
        }
    }
}

/// `refreshMinutes` of `settings.json`: how often a widget without a
/// schedule of its own runs again. The file is read again when it changes,
/// so the management window only has to write it.
pub struct Settings {
    file: PathBuf,
    seen: Option<(SystemTime, u64)>,
    refresh_minutes: u64,
}

impl Settings {
    pub fn new(file: PathBuf) -> Self {
        Self { file, seen: None, refresh_minutes: DEFAULT_REFRESH_MINUTES }
    }

    pub fn refresh_minutes(&mut self) -> u64 {
        let stamp = std::fs::metadata(&self.file).ok().and_then(|metadata| Some((metadata.modified().ok()?, metadata.len())));
        if stamp != self.seen || stamp.is_none() {
            self.seen = stamp;
            self.refresh_minutes = read_object(&self.file)
                .and_then(|root| root.get("refreshMinutes").and_then(Value::as_i64))
                .map_or(DEFAULT_REFRESH_MINUTES, |minutes| minutes.clamp(MINIMUM_REFRESH_MINUTES as i64, MAXIMUM_REFRESH_MINUTES as i64) as u64);
        }
        self.refresh_minutes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("sw-host-placements-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    fn placement(id: &str) -> Placement {
        Placement { id: id.into(), package: "0123456789abcdef".into(), family: "small".into(), screen: "eDP-1".into(), x: 40, y: -12 }
    }

    #[test]
    fn placements_survive_a_reload() {
        let directory = scratch("reload");
        let file = directory.join("widgets.json");
        let mut placements = Placements::load(file.clone());
        assert!(placements.all().is_empty());
        placements.add(placement("00000000000000aa")).unwrap();
        placements.add(placement("00000000000000bb")).unwrap();
        assert!(placements.add(placement("00000000000000aa")).is_none(), "an identifier is used once");
        placements.update("00000000000000bb", |item| {
            item.family = "large".into();
            item.x = 300;
        });
        assert!(placements.remove("00000000000000aa"));
        assert!(!placements.remove("00000000000000aa"));
        use std::os::unix::fs::MetadataExt;
        assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o777, 0o600);
        let reloaded = Placements::load(file);
        assert_eq!(reloaded.all(), [Placement { family: "large".into(), x: 300, ..placement("00000000000000bb") }]);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn entries_that_are_not_valid_are_dropped() {
        let directory = scratch("invalid");
        let file = directory.join("widgets.json");
        std::fs::write(
            &file,
            r#"{"version":1,"widgets":[
                {"id":"00000000000000aa","package":"0123456789abcdef","family":"huge","screen":"../../x","x":99999999,"y":"7"},
                {"id":"../../etc/passwd","package":"0123456789abcdef"},
                {"id":"00000000000000bb","package":"../Packages/x"},
                {"id":"00000000000000aa","package":"0123456789abcdef"},
                "text", 7, null]}"#,
        )
        .unwrap();
        let placements = Placements::load(file.clone());
        assert_eq!(placements.all(), [Placement { id: "00000000000000aa".into(), package: "0123456789abcdef".into(), family: "medium".into(), screen: String::new(), x: MAXIMUM_OFFSET, y: 0 }]);
        for text in ["", "[]", "{\"widgets\":7}", "not json"] {
            std::fs::write(&file, text).unwrap();
            assert!(Placements::load(file.clone()).all().is_empty(), "{text}");
        }
        // A link is not followed.
        std::fs::write(directory.join("real.json"), r#"{"widgets":[{"id":"00000000000000aa","package":"0123456789abcdef"}]}"#).unwrap();
        std::fs::remove_file(&file).unwrap();
        std::os::unix::fs::symlink(directory.join("real.json"), &file).unwrap();
        assert!(Placements::load(file).all().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn no_more_widgets_than_the_limit() {
        let directory = scratch("limit");
        let mut placements = Placements::load(directory.join("widgets.json"));
        for index in 0..MAXIMUM_WIDGETS {
            assert!(placements.add(placement(&format!("{index:016x}"))).is_some());
        }
        assert!(placements.add(placement("ffffffffffffffff")).is_none());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn the_display_state_and_the_setting_are_read_within_their_limits() {
        let directory = scratch("display");
        let file = directory.join("display.json");
        let mut memory = DisplayMemory::default();
        memory.dark = true;
        memory.screens.insert("eDP-1".into(), ScreenInfo { scale: 2000, width: 1440, height: 900 });
        memory.save(&file);
        assert_eq!(DisplayMemory::load(&file), memory);
        std::fs::write(&file, r#"{"dark":"yes","screens":{"a b":{"scale":1000,"width":1,"height":1},"DP-1":{"scale":1,"width":1,"height":1},"DP-2":{"scale":1250,"width":2560,"height":1440}}}"#).unwrap();
        let loaded = DisplayMemory::load(&file);
        assert!(!loaded.dark);
        assert_eq!(loaded.screens.keys().collect::<Vec<_>>(), ["DP-2"]);
        assert_eq!(loaded.screens["DP-2"].factor(), 1.25);

        let file = directory.join("settings.json");
        let mut settings = Settings::new(file.clone());
        assert_eq!(settings.refresh_minutes(), 15);
        for (text, minutes) in [("{\"refreshMinutes\":30}", 30), ("{\"refreshMinutes\":1}", 5), ("{\"refreshMinutes\":100000}", 1440), ("{\"refreshMinutes\":\"x\"}", 15), ("broken", 15)] {
            std::fs::write(&file, text).unwrap();
            // The file is read again when its time or size changed; make sure one of them did.
            settings.seen = None;
            assert_eq!(settings.refresh_minutes(), minutes, "{text}");
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
