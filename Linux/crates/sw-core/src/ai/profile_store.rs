//! The provider profile on disk: which provider, which endpoint, which model,
//! and the two loop settings. The Linux counterpart of the profile part of
//! `AiSettingsStore.kt` in the Android app.
//!
//! The file (`ai-profile.json` in the data folder) has exactly the members
//! written here. There is no member for a key, a member this code does not
//! know is not kept, and a profile whose base URL carries credentials or a
//! query is refused before anything is written, so the file can be read,
//! printed and backed up without a secret in it. The key is in the keyring
//! ([`super::credentials`]).

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::profile::{AiProfile, AiProviderKind, AiSettings};
use crate::json::ObjectExt;

const FORMAT_VERSION: i64 = 1;
/// A profile is small; anything larger is not ours.
const MAXIMUM_BYTES: u64 = 64 * 1024;

pub struct AiProfileStore {
    file: PathBuf,
}

impl AiProfileStore {
    pub fn new(file: impl Into<PathBuf>) -> Self {
        Self { file: file.into() }
    }

    pub fn file(&self) -> &Path {
        &self.file
    }

    /// The saved settings; `None` when there is no file, or it is not one this
    /// code wrote: another format version, an unknown provider, a member of
    /// the wrong type. Nothing is guessed from a file that does not read.
    pub fn load(&self) -> Option<AiSettings> {
        let metadata = std::fs::symlink_metadata(&self.file).ok()?;
        if !metadata.is_file() || metadata.len() > MAXIMUM_BYTES {
            return None;
        }
        let root = crate::json::parse_object(&std::fs::read_to_string(&self.file).ok()?).ok()?;
        if root.get("formatVersion")?.as_i64()? != FORMAT_VERSION {
            return None;
        }
        let kind = AiProviderKind::from_id(root.get("provider")?.as_str())?;
        let profile = AiProfile::new(kind, root.get("baseUrl")?.as_str()?, root.get("model")?.as_str()?);
        let max_iterations = root.get("maxIterations").and_then(Value::as_i64).map_or(AiSettings::DEFAULT_MAX_ITERATIONS, |value| value.clamp(i64::from(AiSettings::MINIMUM_MAX_ITERATIONS), i64::from(AiSettings::MAXIMUM_MAX_ITERATIONS)) as i32);
        let temperature = Some(root.opt_f64("temperature")).filter(|value| (0.0..=2.0).contains(value)).unwrap_or(AiSettings::DEFAULT_TEMPERATURE);
        Some(AiSettings { profile, max_iterations, temperature })
    }

    /// The saved settings, or the defaults of the first provider.
    pub fn load_or_default(&self) -> AiSettings {
        self.load().unwrap_or_else(|| AiSettings::new(AiProfile::defaults(AiProviderKind::Anthropic)))
    }

    /// Saves the settings. A profile that is not valid is not saved; the error is the sentence that says why.
    pub fn save(&self, settings: &AiSettings) -> std::io::Result<()> {
        if let Some(error) = settings.profile.validation_error() {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, error));
        }
        let value = json!({
            "formatVersion": FORMAT_VERSION,
            "provider": settings.profile.kind.id(),
            "baseUrl": settings.profile.normalized_base_url(),
            "model": super::trim(&settings.profile.model),
            "maxIterations": settings.max_iterations.clamp(AiSettings::MINIMUM_MAX_ITERATIONS, AiSettings::MAXIMUM_MAX_ITERATIONS),
            "temperature": if (0.0..=2.0).contains(&settings.temperature) { settings.temperature } else { AiSettings::DEFAULT_TEMPERATURE },
        });
        let mut text = serde_json::to_string_pretty(&value).map_err(std::io::Error::other)?;
        text.push('\n');
        super::write_private(&self.file, text.as_bytes())
    }
}
