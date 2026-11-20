//! Skills 1.0: reusable instructions for the AI conversation. A port of
//! `Android/core/src/main/java/com/everettjf/scriptwidget/core/skills`
//! (`Skill.kt` here, `SkillStore.kt` in [`store`]), itself a port of
//! `AIWidgetSkill` and `AIWidgetSkillManager` in Swift.
//!
//! A Skill is prompt text and nothing else: a package holds exactly
//! `skill.json` and `SKILL.md`. No field names a file to run, a tool, a
//! permission or a network host, a manifest with a key outside the schema is
//! refused, and nothing in this module evaluates an instruction. The only way
//! a Skill reaches anything is as text appended to an AI request
//! ([`SkillStore::enabled_skills_prompt_text`]).

mod store;

use std::fmt;

use serde_json::{Map, Value};

use crate::gallery::files;

pub use store::SkillStore;

/// A usable Skill: validated metadata plus its instruction text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skill {
    pub id: String,
    pub title: String,
    pub version: String,
    pub symbol: String,
    pub summary: String,
    pub instruction: String,
    pub tags: Vec<String>,
    pub author: Option<String>,
    pub minimum_runtime_version: String,
    pub is_built_in: bool,
}

/// The content of `skill.json` (`skill.schema.json`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillManifest {
    pub format_version: i32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub summary: String,
    pub symbol: String,
    pub prompt_file: String,
    pub tags: Vec<String>,
    pub author: Option<String>,
    pub minimum_runtime_version: String,
}

impl SkillManifest {
    /// `AIWidgetSkillManifest.currentFormatVersion`.
    pub const CURRENT_FORMAT_VERSION: i32 = 1;
    /// `ScriptWidgetBuildContract.runtimeAPIVersion`.
    pub const RUNTIME_CONTRACT_VERSION: &'static str = "1.0";
    pub const FILE_NAME: &'static str = "skill.json";
    pub const INSTRUCTION_FILE_NAME: &'static str = "SKILL.md";

    /// JSON of this manifest, containing only schema fields.
    pub fn encode(&self) -> Vec<u8> {
        let mut json = Map::new();
        let text = |value: &str| Value::String(value.to_owned());
        json.insert("formatVersion".into(), Value::from(self.format_version));
        json.insert("id".into(), text(&self.id));
        json.insert("name".into(), text(&self.name));
        json.insert("version".into(), text(&self.version));
        json.insert("summary".into(), text(&self.summary));
        json.insert("symbol".into(), text(&self.symbol));
        json.insert("promptFile".into(), text(&self.prompt_file));
        json.insert("tags".into(), Value::Array(self.tags.iter().map(|tag| text(tag)).collect()));
        json.insert("minimumRuntimeVersion".into(), text(&self.minimum_runtime_version));
        if let Some(author) = &self.author {
            json.insert("author".into(), text(author));
        }
        let mut bytes = serde_json::to_vec_pretty(&Value::Object(json)).unwrap_or_default();
        bytes.push(b'\n');
        bytes
    }
}

/// One reason a Skill was refused; `id` matches the Swift issue identifiers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillValidationIssue {
    pub id: &'static str,
    pub message: String,
}

/// The stable, machine-readable codes of [`SkillError`].
pub mod errors {
    /// `skill.json` or `SKILL.md` is larger than its limit.
    pub const TOO_LARGE: &str = "too_large";
    /// `skill.json` is not one UTF-8 JSON object with every required, correctly typed field.
    pub const INVALID_MANIFEST: &str = "invalid_manifest";
    /// `skill.json` has a key that Skills 1.0 does not define.
    pub const UNKNOWN_FIELD: &str = "unknown_field";
    /// `SKILL.md` is not valid UTF-8.
    pub const INVALID_INSTRUCTION: &str = "invalid_instruction";
    /// The manifest or instruction breaks a validation rule; see [`super::SkillError::issues`].
    pub const INVALID_SKILL: &str = "invalid_skill";
    /// The package is not exactly `skill.json` and `SKILL.md`.
    pub const INVALID_PACKAGE: &str = "invalid_package";
    /// The ZIP archive failed the hardened preflight or could not be read back exactly.
    pub const INVALID_ARCHIVE: &str = "invalid_archive";
    pub const DUPLICATE: &str = "duplicate_skill";
    pub const NOT_FOUND: &str = "skill_not_found";
    pub const BUILT_IN: &str = "built_in_skill";
    pub const STORAGE_UNAVAILABLE: &str = "storage_unavailable";
}

/// The single failure type of the Skills layer. `code` is one of [`errors`];
/// `issues` lists every broken validation rule when there are several.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillError {
    pub code: &'static str,
    pub message: String,
    pub issues: Vec<SkillValidationIssue>,
}

impl SkillError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), issues: Vec::new() }
    }
}

impl fmt::Display for SkillError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for SkillError {}

/// Strict Skills 1.0 validation, ported from `AIWidgetSkillValidator` and `AIWidgetSkillPackage.load`.
pub mod validator {
    use super::*;

    /// `maximumInstructionBytes`: `SKILL.md`.
    pub const MAX_INSTRUCTION_BYTES: usize = 64 * 1024;
    /// `maximumManifestBytes`: `skill.json`.
    pub const MAX_MANIFEST_BYTES: usize = 32 * 1024;
    /// `maximumPackageBytes`: a whole `.swskill` archive.
    pub const MAX_PACKAGE_BYTES: usize = 256 * 1024;
    pub const MAX_NAME_LENGTH: usize = 80;
    pub const MAX_SUMMARY_LENGTH: usize = 240;
    pub const MAX_SYMBOL_LENGTH: usize = 80;
    pub const MAX_TAGS: usize = 20;

    const ALLOWED_KEYS: [&str; 10] = ["formatVersion", "id", "name", "version", "summary", "symbol", "promptFile", "tags", "author", "minimumRuntimeVersion"];

    /// Decodes `skill.json`.
    ///
    /// Refused: more than 32 KiB; bytes that are not strict UTF-8; anything
    /// but one strict JSON object (no second document, no repeated key); a key
    /// outside the schema (an unknown capability such as `executable` must
    /// fail closed, not be ignored); a missing required field; a field of the
    /// wrong JSON type.
    pub fn parse_manifest(bytes: &[u8]) -> Result<SkillManifest, SkillError> {
        if bytes.len() > MAX_MANIFEST_BYTES {
            return Err(SkillError::new(errors::TOO_LARGE, "skill.json exceeds 32 KiB."));
        }
        let json = std::str::from_utf8(bytes).ok().and_then(files::parse_object).ok_or_else(|| SkillError::new(errors::INVALID_MANIFEST, "skill.json must be one UTF-8 JSON object."))?;
        let mut unknown: Vec<&str> = json.keys().map(String::as_str).filter(|key| !ALLOWED_KEYS.contains(key)).collect();
        if !unknown.is_empty() {
            unknown.sort_unstable();
            return Err(SkillError::new(errors::UNKNOWN_FIELD, format!("skill.json contains unknown fields: {}.", unknown.join(", "))));
        }
        let malformed = |key: &str| SkillError::new(errors::INVALID_MANIFEST, format!("skill.json field {key} is missing or has the wrong type."));
        let string = |key: &str| json.get(key).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| malformed(key));
        let format_version = json.get("formatVersion").and_then(files::integer).and_then(|value| i32::try_from(value).ok()).ok_or_else(|| malformed("formatVersion"))?;
        let tags = json.get("tags").and_then(Value::as_array).ok_or_else(|| malformed("tags"))?.iter().map(|tag| tag.as_str().map(str::to_owned).ok_or_else(|| malformed("tags"))).collect::<Result<Vec<_>, _>>()?;
        let author = match json.get("author") {
            None => None,
            Some(value) => Some(value.as_str().map(str::to_owned).ok_or_else(|| malformed("author"))?),
        };
        Ok(SkillManifest {
            format_version,
            id: string("id")?,
            name: string("name")?,
            version: string("version")?,
            summary: string("summary")?,
            symbol: string("symbol")?,
            prompt_file: string("promptFile")?,
            tags,
            author,
            minimum_runtime_version: string("minimumRuntimeVersion")?,
        })
    }

    /// Semantic rules; an empty result means the Skill is acceptable.
    ///
    /// Refused: a format other than 1; an id outside
    /// `[A-Za-z0-9][A-Za-z0-9.-]{2,127}`; a blank or over-long name, summary
    /// or symbol; a version that is not `major.minor.patch[-pre]`; a runtime
    /// contract other than `1.0`; a `promptFile` other than `SKILL.md` (a
    /// Skill cannot point at another file); more than 20 tags or tags equal
    /// ignoring case; blank instructions; instructions above 64 KiB.
    pub fn validate(manifest: &SkillManifest, instruction: &str) -> Vec<SkillValidationIssue> {
        let mut issues = Vec::new();
        let mut reject = |id: &'static str, message: String| issues.push(SkillValidationIssue { id, message });
        if manifest.format_version != SkillManifest::CURRENT_FORMAT_VERSION {
            reject("unsupported_format", format!("Skill format {} is not supported.", manifest.format_version));
        }
        if !files::is_identifier(&manifest.id) {
            reject("invalid_id", "Skill id must use 3–128 letters, numbers, dots, or hyphens.".into());
        }
        if !files::bounded(&manifest.name, MAX_NAME_LENGTH) {
            reject("invalid_name", "Skill name must contain 1–80 characters.".into());
        }
        if !files::is_semantic_version(&manifest.version) {
            reject("invalid_version", "Skill version must be semantic, for example 1.0.0.".into());
        }
        if manifest.minimum_runtime_version != SkillManifest::RUNTIME_CONTRACT_VERSION {
            reject("unsupported_runtime", format!("Skill requires runtime {}, but this app supports {}.", manifest.minimum_runtime_version, SkillManifest::RUNTIME_CONTRACT_VERSION));
        }
        if manifest.prompt_file != SkillManifest::INSTRUCTION_FILE_NAME {
            reject("invalid_prompt_file", "Skills 1.0 requires promptFile to be SKILL.md.".into());
        }
        if !files::bounded(&manifest.summary, MAX_SUMMARY_LENGTH) {
            reject("invalid_summary", "Skill summary must contain 1–240 characters.".into());
        }
        if manifest.symbol.is_empty() || manifest.symbol.chars().count() > MAX_SYMBOL_LENGTH {
            reject("invalid_symbol", "Skill symbol is invalid.".into());
        }
        if manifest.tags.len() > MAX_TAGS || !files::unique_ignoring_case(manifest.tags.iter().map(String::as_str)) {
            reject("invalid_tags", "Use at most 20 unique tags.".into());
        }
        if instruction.trim().is_empty() {
            reject("empty_instruction", "SKILL.md must contain instructions.".into());
        }
        if instruction.len() > MAX_INSTRUCTION_BYTES {
            reject("instruction_too_large", "SKILL.md exceeds 64 KiB.".into());
        }
        issues
    }

    /// Decodes and validates the two files of a Skills 1.0 package. Sizes are
    /// checked on the bytes that will be stored, and `SKILL.md` must be strict UTF-8.
    pub fn load(manifest_bytes: &[u8], instruction_bytes: &[u8]) -> Result<Skill, SkillError> {
        let manifest = parse_manifest(manifest_bytes)?;
        if instruction_bytes.len() > MAX_INSTRUCTION_BYTES {
            return Err(SkillError::new(errors::TOO_LARGE, "SKILL.md exceeds 64 KiB."));
        }
        let instruction = std::str::from_utf8(instruction_bytes).map_err(|_| SkillError::new(errors::INVALID_INSTRUCTION, "SKILL.md must be UTF-8 text."))?;
        let issues = validate(&manifest, instruction);
        if !issues.is_empty() {
            let message = issues.iter().map(|issue| issue.message.as_str()).collect::<Vec<_>>().join("\n");
            return Err(SkillError { code: errors::INVALID_SKILL, message, issues });
        }
        Ok(Skill {
            id: manifest.id,
            title: manifest.name,
            version: manifest.version,
            symbol: manifest.symbol,
            summary: manifest.summary,
            instruction: instruction.to_owned(),
            tags: manifest.tags,
            author: manifest.author,
            minimum_runtime_version: manifest.minimum_runtime_version,
            is_built_in: false,
        })
    }

    /// Directory name for a Skill: lowercase ASCII letters and digits joined by `-`, or `skill`.
    pub fn slug(value: &str) -> String {
        let mut slug = String::new();
        for character in value.to_lowercase().chars() {
            if character.is_ascii_lowercase() || character.is_ascii_digit() {
                slug.push(character);
            } else if !slug.is_empty() && !slug.ends_with('-') {
                slug.push('-');
            }
        }
        let slug: String = slug.trim_matches('-').chars().take(64).collect();
        let slug = slug.trim_matches('-');
        if slug.is_empty() { "skill".to_owned() } else { slug.to_owned() }
    }
}

/// The read-only Skills shipped with the app (`AIWidgetSkills.builtIns` in Swift).
pub fn built_ins() -> &'static [Skill] {
    static BUILT_INS: std::sync::OnceLock<Vec<Skill>> = std::sync::OnceLock::new();
    BUILT_INS.get_or_init(|| {
        let skill = |id: &str, title: &str, symbol: &str, summary: &str, instruction: &str, tags: &[&str]| Skill {
            id: id.into(),
            title: title.into(),
            version: "1.0.0".into(),
            symbol: symbol.into(),
            summary: summary.into(),
            instruction: instruction.into(),
            tags: tags.iter().map(|tag| (*tag).to_owned()).collect(),
            author: None,
            minimum_runtime_version: SkillManifest::RUNTIME_CONTRACT_VERSION.into(),
            is_built_in: true,
        };
        vec![
            skill(
                "responsive-layout",
                "Responsive Layout",
                "rectangle.3.group",
                "Adapt one script to every widget family.",
                "Use $getenv(\"widget-size\") to create intentional small, medium, and large layouts. Keep the information hierarchy readable in every family.",
                &["layout"],
            ),
            skill(
                "accessible-design",
                "Accessible Design",
                "accessibility",
                "Improve contrast, hierarchy, and legibility.",
                "Use strong text/background contrast, avoid color as the only signal, keep important text legible, and prefer concise labels.",
                &["accessibility"],
            ),
            skill(
                "resilient-data",
                "Resilient Data",
                "network.badge.shield.half.filled",
                "Handle network and missing-data failures.",
                "When data is remote or optional, validate it and render a useful fallback state. Never expose secrets or invent unsupported runtime APIs.",
                &["network", "safety"],
            ),
            skill(
                "visual-polish",
                "Visual Polish",
                "paintbrush.pointed",
                "Apply a coherent native visual system.",
                "Create a restrained native-looking visual system with consistent spacing, typography, color, and alignment. Avoid decorative clutter.",
                &["design"],
            ),
            skill(
                "runtime-debugger",
                "Runtime Debugger",
                "ladybug",
                "Repair errors with the smallest safe change.",
                "Prioritize the supplied runtime diagnostic. Make the smallest correction that fixes it, preserve unrelated behavior, and use only documented ScriptWidget APIs.",
                &["debugging"],
            ),
        ]
    })
}
