//! The user's settings (`settings.json` in the data folder), shared with the
//! background service. The keys are the ones the Windows host uses. Keys this
//! window does not know are kept as they are.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::model::write_atomically;

/// The refresh intervals offered, in minutes, as on Windows.
pub const INTERVALS: [u32; 6] = [5, 15, 30, 60, 120, 360];
pub const DEFAULT_REFRESH_MINUTES: u32 = 15;
const MINIMUM_REFRESH_MINUTES: u32 = 5;
const MAXIMUM_REFRESH_MINUTES: u32 = 24 * 60;
/// A settings file is small; anything larger is not ours.
const MAXIMUM_BYTES: u64 = 256 * 1024;

pub struct Settings {
    file: PathBuf,
}

impl Settings {
    pub fn new(file: impl Into<PathBuf>) -> Self {
        Self { file: file.into() }
    }

    pub fn file(&self) -> &Path {
        &self.file
    }

    /// How often widgets without a schedule of their own are refreshed.
    pub fn refresh_minutes(&self) -> u32 {
        self.read().get("refreshMinutes").and_then(Value::as_u64).map_or(DEFAULT_REFRESH_MINUTES, |minutes| minutes.clamp(u64::from(MINIMUM_REFRESH_MINUTES), u64::from(MAXIMUM_REFRESH_MINUTES)) as u32)
    }

    pub fn set_refresh_minutes(&self, minutes: u32) -> std::io::Result<()> {
        let mut values = self.read();
        values.insert("refreshMinutes".into(), Value::from(minutes.clamp(MINIMUM_REFRESH_MINUTES, MAXIMUM_REFRESH_MINUTES)));
        let mut text = serde_json::to_string_pretty(&Value::Object(values)).map_err(std::io::Error::other)?;
        text.push('\n');
        write_atomically(&self.file, text.as_bytes(), 0o600)
    }

    /// The interval of [`INTERVALS`] the setting selects: the first that is not shorter.
    pub fn selected_interval(&self) -> u32 {
        let current = self.refresh_minutes();
        INTERVALS.iter().copied().find(|minutes| *minutes >= current).unwrap_or(INTERVALS[INTERVALS.len() - 1])
    }

    /// A missing, oversized or malformed file reads as no settings.
    fn read(&self) -> Map<String, Value> {
        let readable = std::fs::metadata(&self.file).is_ok_and(|metadata| metadata.is_file() && metadata.len() <= MAXIMUM_BYTES);
        if !readable {
            return Map::new();
        }
        match std::fs::read_to_string(&self.file).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok()) {
            Some(Value::Object(values)) => values,
            _ => Map::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Scratch;

    #[test]
    fn the_interval_is_saved_and_other_keys_are_kept() {
        let scratch = Scratch::new("settings");
        let settings = Settings::new(scratch.path("settings.json"));
        assert_eq!(settings.refresh_minutes(), 15, "no file yet");
        assert_eq!(settings.selected_interval(), 15);

        std::fs::write(settings.file(), r#"{"locked":true,"refreshMinutes":45,"future":{"a":[1,2]}}"#).unwrap();
        assert_eq!(settings.refresh_minutes(), 45);
        assert_eq!(settings.selected_interval(), 60);
        settings.set_refresh_minutes(120).unwrap();
        assert_eq!(settings.refresh_minutes(), 120);
        let saved: Value = serde_json::from_str(&std::fs::read_to_string(settings.file()).unwrap()).unwrap();
        assert_eq!(saved, serde_json::json!({"locked": true, "refreshMinutes": 120, "future": {"a": [1, 2]}}));
        assert_eq!(std::fs::read_dir(scratch.root()).unwrap().count(), 1, "no temporary file is left");
    }

    #[test]
    fn values_out_of_range_and_broken_files_fall_back() {
        let scratch = Scratch::new("settings-range");
        let settings = Settings::new(scratch.path("settings.json"));
        for (text, expected) in [(r#"{"refreshMinutes":1}"#, 5), (r#"{"refreshMinutes":99999}"#, 1440), (r#"{"refreshMinutes":"soon"}"#, 15), (r#"{"refreshMinutes":-3}"#, 15), ("[1,2]", 15), ("{ not json", 15), ("", 15)] {
            std::fs::write(settings.file(), text).unwrap();
            assert_eq!(settings.refresh_minutes(), expected, "{text}");
        }
        settings.set_refresh_minutes(0).unwrap();
        assert_eq!(settings.refresh_minutes(), 5);
        settings.set_refresh_minutes(1_000_000).unwrap();
        assert_eq!(settings.refresh_minutes(), 1440);
        assert_eq!(settings.selected_interval(), 360);
    }
}
