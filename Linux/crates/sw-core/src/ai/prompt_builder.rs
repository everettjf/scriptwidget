//! The system and user messages of the widget-generation agent. Port of
//! `PromptBuilder.kt` (`Shared/ScriptWidgetRuntime/AI/PromptBuilder.swift`),
//! with the facts of Linux in place of those of Android.

use std::collections::BTreeMap;

use super::conversation::AiConversationLimits;
use super::output::{AiCandidate, AiOutput};
use super::{length, take, trim};
use crate::api::{fetch, storage};
use crate::packages::limits::MAX_SCRIPT_BYTES;

/// The sizes a widget can have on the Linux desktop. Port of the system cases of `AIWidgetSize`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiWidgetSize {
    Small,
    Medium,
    Large,
    ExtraLarge,
}

impl AiWidgetSize {
    pub const ALL: [Self; 4] = [Self::Small, Self::Medium, Self::Large, Self::ExtraLarge];

    pub fn family(self) -> &'static str {
        match self {
            Self::Small => "small",
            Self::Medium => "medium",
            Self::Large => "large",
            Self::ExtraLarge => "extraLarge",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Small => "Small",
            Self::Medium => "Medium",
            Self::Large => "Large",
            Self::ExtraLarge => "Extra Large",
        }
    }

    /// The hints of the Swift original; the sizes are the points the shared renderer draws a family at.
    pub fn design_hint(self) -> &'static str {
        match self {
            Self::Small => "Square, ~170x170 px. Keep it to one or two key pieces of information.",
            Self::Medium => "Wide rectangle, ~329x170 px. Room for a small grid or two columns.",
            Self::Large => "Square, ~329x345 px. Multiple sections / richer layout.",
            Self::ExtraLarge => "Wide rectangle, ~639x345 px. Dashboard-style density is fine.",
        }
    }

    /// The size for a preview family name; unknown names fall back to [`AiWidgetSize::Medium`].
    pub fn from_family(family: Option<&str>) -> Self {
        Self::ALL.into_iter().find(|size| Some(size.family()) == family).unwrap_or(Self::Medium)
    }
}

/// Compact reference manual for the system prompt, built from the usage
/// examples in `Script.bundle` (`component/<name>/main.jsx`, `api/<name>/main.jsx`):
/// the same files `AIReferenceSnapshotLoader` samples on Apple platforms.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiReference {
    pub components_block: String,
    pub apis_block: String,
}

impl AiReference {
    /// Cap per file so the prompt stays bounded.
    pub const MAXIMUM_LINES_PER_FILE: usize = 40;
    /// Above this many characters only [`AiReference::PRIORITY_APIS`] are kept.
    pub const SOFT_CHARACTER_BUDGET: usize = 60_000;
    /// An example larger than this is not read.
    pub const MAXIMUM_EXAMPLE_BYTES: u64 = 256 * 1024;
    /// `AIReferenceSnapshotLoader.priorityAPIs`.
    pub const PRIORITY_APIS: [&'static str; 11] = ["fetch", "http", "storage", "location", "health", "calendar", "device", "file", "getenv", "system", "console"];
    /// Bundled component examples with no Linux surface.
    pub const LINUX_EXCLUDED_COMPONENTS: [&'static str; 1] = ["live-activity"];

    /// Port of `AIReferenceSnapshot.combined`.
    pub fn combined(&self) -> String {
        let mut out = String::new();
        if !self.components_block.is_empty() {
            out.push_str("=== COMPONENTS (JSX tags) ===\n");
            out.push_str(&self.components_block);
            out.push('\n');
        }
        if !self.apis_block.is_empty() {
            out.push_str("=== APIs (globals) ===\n");
            out.push_str(&self.apis_block);
        }
        out
    }

    /// Builds the reference from example sources keyed by directory name.
    /// Port of `AIReferenceSnapshotLoader.build`, minus the examples Linux
    /// cannot run: an example for a global that reports `unsupported_platform`
    /// here (see [`crate::library::is_unsupported_api`]) would invite its use.
    pub fn build(components: &BTreeMap<String, String>, apis: &BTreeMap<String, String>) -> Self {
        let components: BTreeMap<&str, &str> = components.iter().filter(|(name, _)| !Self::LINUX_EXCLUDED_COMPONENTS.contains(&name.as_str())).map(|(name, text)| (name.as_str(), text.as_str())).collect();
        let usable: BTreeMap<&str, &str> = apis.iter().filter(|(name, _)| !crate::library::is_unsupported_api(name)).map(|(name, text)| (name.as_str(), text.as_str())).collect();
        let components_block = section(&components, false);
        let mut apis_block = section(&usable, false);
        if length(&components_block) + length(&apis_block) > Self::SOFT_CHARACTER_BUDGET {
            apis_block = section(&usable, true);
        }
        Self { components_block, apis_block }
    }

    /// Reads the examples of an installation: `templates` is the folder with
    /// the `component` and `api` groups (see [`crate::resources`]). A folder or
    /// file that is missing, too large, a link or not UTF-8 is left out.
    pub fn load(templates: Option<&std::path::Path>) -> Self {
        let Some(templates) = templates else { return Self::default() };
        let read = |group: &str| {
            let mut sources = BTreeMap::new();
            let Ok(entries) = std::fs::read_dir(templates.join(group)) else { return sources };
            for entry in entries.flatten() {
                let Ok(name) = entry.file_name().into_string() else { continue };
                let file = entry.path().join("main.jsx");
                let plain = std::fs::symlink_metadata(&file).is_ok_and(|metadata| metadata.is_file() && metadata.len() <= Self::MAXIMUM_EXAMPLE_BYTES);
                if plain && let Ok(text) = std::fs::read_to_string(&file) {
                    sources.insert(name, text);
                }
            }
            sources
        };
        Self::build(&read("component"), &read("api"))
    }
}

fn section(sources: &BTreeMap<&str, &str>, priority_only: bool) -> String {
    let parts: Vec<String> = sources.iter().filter(|(name, _)| !priority_only || AiReference::PRIORITY_APIS.contains(name)).map(|(name, text)| format!("// === {name} ===\n{}", limit(text))).collect();
    parts.join("\n\n")
}

fn limit(text: &str) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    if lines.len() <= AiReference::MAXIMUM_LINES_PER_FILE { text.to_owned() } else { format!("{}\n// ...", lines[..AiReference::MAXIMUM_LINES_PER_FILE].join("\n")) }
}

/// What ScriptWidget for Linux cannot do, phrased for the model. The Linux
/// counterpart of `AndroidPromptNotes`; the facts are those of
/// `docs/platform-support.md`.
pub struct LinuxPromptNotes;

impl LinuxPromptNotes {
    /// Script globals that exist only as "not supported" stubs on Linux: the
    /// list the library keeps templates out by (`crate::library::unsupported_apis`).
    pub fn unsupported_globals() -> Vec<String> {
        crate::library::unsupported_apis().iter().map(|name| format!("${name}")).collect()
    }

    /// One line per unsupported capability.
    pub fn unsupported_lines() -> Vec<String> {
        vec![
            format!("These globals are not implemented and every call fails with unsupported_platform: {}.", Self::unsupported_globals().join(", ")),
            "Lock Screen accessory sizes (accessoryInline, accessoryCircular, accessoryRectangular) do not exist; only small, medium, large and extraLarge.".into(),
            "Live Activities, Dynamic Island content ($dynamic_island), Control Widgets and push-triggered refresh are not available.".into(),
            "backgroundMaterial falls back to a plain background color; do not rely on it.".into(),
            "The animation property moves on the desktop: clock hands follow the time, swings and custom intervals play at up to 20 frames a second. Previews show one frame.".into(),
            "<link> opens http, https and mailto URLs only.".into(),
            "The scrolling <list> tag and the material.<role> colors exist only on Android; never use them.".into(),
        ]
    }

    /// The system data APIs Linux implements, with what a model needs to know
    /// about each. The Linux counterpart of `AndroidPromptNotes.systemDataLines`:
    /// one line each, because the reference has their examples.
    pub fn system_data_lines() -> Vec<String> {
        vec![
            "Each needs its permission in widget.json, which you cannot declare (rule 3), and a step by the user in the ScriptWidget window (Data access, in the editor). \
In this preview they report unavailable or reject: check isAvailable() and authorizationStatus() where they exist, wrap calls in try/catch and render a short setup message. The user adds the permission after saving."
                .into(),
            "$music.current() is what a media player on this desktop plays ({state, hasItem, title, artist, album, duration, position}); its provider is \"mpris\". There are no playback controls and no artwork.".into(),
            "$photos.items({limit: 4}) returns only pictures the user picked for this widget, as items[].image for <image url>; there are no albums.".into(),
            "$documents.list(), readJSON(id) and readCSV(id) read only the JSON and CSV files the user picked for this widget.".into(),
            "$services.status(\"github\") and profile(\"github\") use a GitHub token the user enters in Settings (no sign-in), with the services and network permissions and api.github.com. Never put a token in code.".into(),
            "$notifications (status, pending, schedule, cancel): schedule and cancel work only in a button or toggle action, and a notification is shown only while the ScriptWidget service runs.".into(),
        ]
    }

    /// The budgets the Linux runtime enforces on every run.
    pub fn runtime_limit_lines() -> Vec<String> {
        vec![
            "A run must finish within 5 seconds, including all awaited network calls.".into(),
            format!("JavaScript memory is limited to {} MiB.", sw_quickjs::DEFAULT_MEMORY_LIMIT / (1024 * 1024)),
            format!("main.jsx may be at most {} KiB.", MAX_SCRIPT_BYTES / 1024),
            format!(
                "Network: at most {} requests per run ({} concurrent), each response at most {} MiB, each request body at most {} MiB, {} seconds per request. Only public http(s) hosts; no localhost or private addresses.",
                fetch::MAXIMUM_REQUESTS,
                fetch::MAXIMUM_CONCURRENT,
                fetch::MAXIMUM_RESPONSE_BYTES / (1024 * 1024),
                fetch::MAXIMUM_REQUEST_BODY_BYTES / (1024 * 1024),
                fetch::MAXIMUM_TOTAL_MILLISECONDS / 1000
            ),
            format!("$storage: at most {} keys, {} KiB per value, {} MiB in total.", storage::MAXIMUM_KEYS, storage::MAXIMUM_VALUE_BYTES / 1024, storage::MAXIMUM_TOTAL_BYTES / (1024 * 1024)),
        ]
    }
}

/// What one turn of a conversation tells the model. Port of `AITurnContext`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiTurnContext {
    /// Earlier applied turns, oldest first.
    pub history: Vec<Exchange>,
    /// The widget as it is now; `None` when the turn starts a new widget.
    pub current_code: Option<String>,
    /// The version before the current one, if any.
    pub previous_code: Option<String>,
    pub request: String,
    /// Formatted text of the enabled Skills; `None` for none.
    pub skills_text: Option<String>,
    pub size: AiWidgetSize,
    /// Canonical network declaration of the current widget, if any.
    pub current_declaration: Option<String>,
    pub runtime_diagnostic: Option<String>,
}

impl AiTurnContext {
    /// A turn with no history, Skills, declaration or diagnostic.
    pub fn new(current_code: Option<&str>, request: &str, size: AiWidgetSize) -> Self {
        Self { history: Vec::new(), current_code: current_code.map(str::to_owned), previous_code: None, request: request.to_owned(), skills_text: None, size, current_declaration: None, runtime_diagnostic: None }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exchange {
    pub request: String,
    pub note: Option<String>,
}

/// A turn reply, split.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiTurnReply {
    pub note: Option<String>,
    pub candidate: AiCandidate,
}

/// Builds the system and user messages of the widget-generation agent.
pub struct PromptBuilder;

const RULES: &str = r##"You are a ScriptWidget code generator. ScriptWidget runs widgets
written in a constrained JSX dialect inside a sandboxed JavaScript
engine. This widget will run on ScriptWidget for Linux.
Output ONLY a single JSX snippet: no prose, no explanations.
The one exception is the package declaration described in rule 3.

RULES:
1. Call $render(<...>) exactly once. The root element MUST be a
   layout container (vstack / hstack / zstack).
2. Do NOT use `import`, `require`, `module`, any Node APIs, or
   any DOM / browser APIs.
3. Networking is ONLY via the globally injected `fetch(url)`
   (returns a string) or the `$http.*` API. A widget that uses the
   network MUST end its answer, after the JSX, with exactly one fenced
   block that declares the permission and every host it contacts:
   ```json
   {"permissions": ["network"], "networkDomains": ["api.example.com"]}
   ```
   Hosts are exact names or `*.example.com`. Undeclared hosts are
   blocked. A widget that does not use the network must not add
   this block. No other permission can be declared.
4. Top-level `await` is allowed: the runtime wraps your code in
   an async `$main` function.
5. Date/time: the global `moment` library is available. Plain JS
   `Date` also works.
6. Persistent data: `$storage.setString(key, value)` and
   `$storage.getString(key)` for strings; `$storage.setJSON(key, object)`
   and `$storage.getJSON(key)` for objects. Check write success.
   Do not invent `$storage.set` or `$storage.get`.
   `$storage` stays on this device.
7. Only use tags, props, and APIs that appear in the REFERENCE
   section or under SYSTEM DATA below. Do not invent new ones.
8. When calling `fetch`, always wrap it in try/catch so the
   widget still renders something useful on network failure.
9. Prefer readable typography (`font="title"`, `"headline"`,
   `"caption"`, `"caption2"`) and sensible spacing. Match the
   visual density to the declared widget size.
10. Keep the output self-contained: no external files, no
    image assets the user hasn't provided.
11. Respect light and dark appearances. Prefer color="primary"
    and color="secondary" for text; never hardcode white text
    on a transparent background.
12. Use frame="width,height" for explicit sizes, e.g. frame="60,60".
    Leave room for stroke thickness and padding. Do not apply
    frame="max" to every row: it expands height too. Use
    frame="max,24" for a full-width row with a fixed height
    when appropriate.
    frame="max,leading" fills both directions and aligns the content
    (center, leading, trailing, top, bottom, topLeading, ...). There
    is no "auto" and no space after the comma: for a full-width row
    as tall as its content, put a <spacer/> inside the <hstack>.
    <text>, <date>, <image> and the other tags without children take
    no tags inside them: write <date ... /> next to a <text>, not in it.
    A linear $gradient needs both points, e.g. $gradient({type: "linear",
    colors: ["#0f172a", "#166534"], startPoint: "top", endPoint: "bottom"}).
13. Charts use data={$json([{label: "Mon", value: 3}])}, not JSX
    child marks. Keep chart axes legible: avoid a fixed dark
    background with default light-appearance axes. Prefer the
    default background or select a matching background using
    $device.isdarkmode().
14. Preserve the requested labels and values. Do not invent
    meeting locations, extra events, or live data. For fixed
    demo data do not call the network.
15. Scheduled widgets use timeline-date/timeline-slot from $getenv, not
    a replaced Date global. Future entries are read-only: do not save
    records or fetch live data while projecting them.
16. $file.exists(path) checks regular files inside the current package.
    Give a useful missing-resource state instead of inventing a photo."##;

impl PromptBuilder {
    /// Skills text beyond this many characters is cut; Skills 1.0 instructions are at most 64 KiB each.
    pub const MAXIMUM_SKILLS_CHARACTERS: usize = 64 * 1024;
    /// As much of one console line as a repair request repeats.
    pub const MAXIMUM_LOG_LINE_CHARACTERS: usize = 300;
    /// As many of the last console lines as a repair or a runtime diagnostic carries.
    pub const MAXIMUM_LOG_LINES: usize = 10;

    /// How a turn that changes existing code may answer: with all of the code, or with the
    /// places that change. The same words as `PromptBuilder.editReplyRule`; see [`super::AiSourceEdits`].
    pub const EDIT_REPLY_RULE: &'static str = "then EITHER the FULL widget code in one ```jsx fenced block,
OR, when only a few places change, edit blocks instead of the full code:
```edit
<<<<<<< SEARCH
lines copied exactly from the current code, with their indentation
=======
the lines that replace them
>>>>>>> REPLACE
```
Write one SEARCH/REPLACE pair for each place, as many as the change needs. Each SEARCH
text must be in the current code exactly once: copy enough neighbouring lines to make
it so. An empty REPLACE part deletes the lines. Prefer edit blocks for a small change
and the full code when most of the widget changes. Never use both forms in one reply.";

    /// Added to a repair request inside a conversation, where the reply form still holds.
    pub const TURN_REPAIR_SUFFIX: &'static str = "\n\nKeep the reply form of this conversation: the full code in one ```jsx block, then the ```json network declaration block only if the widget uses the network.";

    /// The system prompt with the limits and the unsupported list of this system.
    pub fn system_prompt(reference: &AiReference) -> String {
        Self::system_prompt_with(reference, &LinuxPromptNotes::unsupported_lines(), &LinuxPromptNotes::runtime_limit_lines())
    }

    /// The system prompt: generation rules, the Linux limits and unsupported
    /// list, then the component/API reference.
    ///
    /// The rules are those of the Android prompt, which follow the Swift one.
    /// Its long rules about the system data APIs are replaced by the short
    /// SYSTEM DATA section for the ones Linux implements and by the
    /// unsupported list for the rest, and the output contract has the
    /// optional package declaration because a package made here always has a
    /// manifest that must declare network access.
    pub fn system_prompt_with(reference: &AiReference, unsupported: &[String], runtime_limits: &[String]) -> String {
        let mut out = String::from(RULES);
        out.push_str("\n\nRUNTIME LIMITS (enforced; a widget that exceeds them fails):\n");
        for line in runtime_limits {
            out.push_str(&format!("- {line}\n"));
        }
        out.push_str("\nNOT SUPPORTED ON LINUX (never use these; if the request needs one, render a short explanation instead):\n");
        for line in unsupported {
            out.push_str(&format!("- {line}\n"));
        }
        out.push_str("\nSYSTEM DATA ON LINUX (these work; use one only when the request needs it):\n");
        for line in LinuxPromptNotes::system_data_lines() {
            out.push_str(&format!("- {line}\n"));
        }
        out.push('\n');
        out.push_str(&reference.combined());
        out
    }

    /// Appends enabled Skills to the user's request, as `AIWidgetSkills.augment` does.
    /// `skills_text` is already formatted prompt text; blank or `None` leaves `prompt` unchanged.
    /// Skills only add instructions: they cannot change rules, permissions or tools.
    pub fn augment_with_skills(prompt: &str, skills_text: Option<&str>) -> String {
        let skills = take(trim(skills_text.unwrap_or("")), Self::MAXIMUM_SKILLS_CHARACTERS);
        if skills.is_empty() {
            return prompt.to_owned();
        }
        format!("{prompt}\n\nApply these ScriptWidget skills:\n{skills}")
    }

    /// Port of `userPromptFirst`.
    pub fn user_prompt_first(user_description: &str, size: AiWidgetSize) -> String {
        let text = format!(
            "Widget size: {}\nSize hint: {}\n\nUser description:\n{user_description}\n\nReturn the complete JSX snippet (plus the network declaration block only if it uses the network). No explanation.",
            size.family(),
            size.design_hint()
        );
        trim(&text).to_owned()
    }

    /// Port of `userPromptFix`: the failed code, the runtime feedback and the last ten log lines.
    /// A script may print anything, including what it read from this computer, so only the start
    /// of each of those lines is sent.
    pub fn user_prompt_fix(previous_code: &str, error_summary: &str, recent_logs: &[String]) -> String {
        let log_block = if recent_logs.is_empty() {
            "(no console output)".to_owned()
        } else {
            recent_logs[recent_logs.len().saturating_sub(Self::MAXIMUM_LOG_LINES)..].iter().map(|line| Self::clip(line, Self::MAXIMUM_LOG_LINE_CHARACTERS)).collect::<Vec<_>>().join("\n")
        };
        let text = format!(
            "Your previous code failed to run:\n\n```jsx\n{previous_code}\n```\n\nRuntime feedback:\n{error_summary}\n\nLast console output:\n{log_block}\n\nFix the code and return the FULL corrected JSX only (plus the network declaration block only if it uses the network). No explanation."
        );
        trim(&text).to_owned()
    }

    /// What a turn is told about a version that failed when the preview ran it: the error, then the
    /// last console lines under the limits of a repair. Port of `PromptBuilder.runtimeDiagnostic`;
    /// [`Self::user_prompt_turn`] cuts the whole to 2,000 characters.
    pub fn runtime_diagnostic(error_summary: &str, logs: &[String]) -> String {
        if logs.is_empty() {
            return error_summary.to_owned();
        }
        let lines: Vec<String> = logs[logs.len().saturating_sub(Self::MAXIMUM_LOG_LINES)..].iter().map(|line| Self::clip(line, Self::MAXIMUM_LOG_LINE_CHARACTERS)).collect();
        format!("{error_summary}\nLast console output:\n{}", lines.join("\n"))
    }

    /// Port of `userPromptRefine` / `userPromptCopilot`: improve an installed widget.
    /// `current_declaration` is the package's current network declaration, if any, so the
    /// model knows which hosts are already allowed.
    pub fn user_prompt_refine(current_code: &str, refine_instruction: &str, current_declaration: Option<&str>, runtime_diagnostic: Option<&str>) -> String {
        let declaration = current_declaration.filter(|text| !super::is_blank(text)).map(|text| format!("\n\nIts current package declaration is:\n```json\n{text}\n```")).unwrap_or_default();
        let diagnostic = runtime_diagnostic.filter(|text| !super::is_blank(text)).map(|text| format!("\n\nThe latest local ScriptWidget runtime diagnostic is:\n{text}")).unwrap_or_default();
        let text = format!(
            "Current widget code:\n\n```jsx\n{current_code}\n```{declaration}{diagnostic}\n\nApply this change request from the user:\n{refine_instruction}\n\nPreserve working behavior that is unrelated to the request. Use only documented ScriptWidget APIs.\nReturn the FULL updated JSX only (plus the network declaration block only if it uses the network). No explanation."
        );
        trim(&text).to_owned()
    }

    /// Port of `userPromptTurn`: one turn of a conversation about a widget. The reply form it
    /// asks for (a SUMMARY line, the code, the declaration) replaces the system prompt's
    /// "only JSX" rule, so a turn can say what it changed.
    pub fn user_prompt_turn(context: &AiTurnContext) -> String {
        let mut parts: Vec<String> = Vec::new();
        parts.push(format!("You are working with the user on one ScriptWidget widget over several turns.\nWidget size: {}\nSize hint: {}", context.size.family(), context.size.design_hint()));
        let skills = take(trim(context.skills_text.as_deref().unwrap_or("")), Self::MAXIMUM_SKILLS_CHARACTERS);
        if !skills.is_empty() {
            parts.push(format!("Apply these ScriptWidget skills in every turn:\n{skills}"));
        }
        if !context.history.is_empty() {
            let lines: Vec<String> = context
                .history
                .iter()
                .enumerate()
                .map(|(index, exchange)| {
                    format!(
                        "{}. User: {}\n   You: {}",
                        index + 1,
                        Self::clip(&exchange.request, AiConversationLimits::HISTORY_REQUEST_CHARACTERS),
                        Self::clip(exchange.note.as_deref().unwrap_or("Done."), AiConversationLimits::HISTORY_NOTE_CHARACTERS)
                    )
                })
                .collect();
            parts.push(format!("Earlier turns, oldest first (each one was applied):\n{}", lines.join("\n")));
        }
        if let Some(previous) = context.previous_code.as_deref().filter(|previous| !previous.is_empty() && length(previous) <= AiConversationLimits::PREVIOUS_SOURCE_CHARACTERS) {
            parts.push(format!("The version before your last change, for reference only (the user may ask to bring something back):\n\n```jsx\n{previous}\n```"));
        }
        let current = context.current_code.as_deref().filter(|current| !current.is_empty());
        match current {
            Some(current) => {
                let declaration = match context.current_declaration.as_deref().filter(|text| !super::is_blank(text)) {
                    None => "It declares no network use.".to_owned(),
                    Some(text) => format!("Its network declaration: {text}"),
                };
                let diagnostic = context.runtime_diagnostic.as_deref().filter(|text| !super::is_blank(text)).map(|text| format!("\n\nThe latest local ScriptWidget runtime diagnostic is:\n{}", Self::clip(text, 2_000))).unwrap_or_default();
                parts.push(format!(
                    "Current working widget code:\n\n```jsx\n{current}\n```\n\n{declaration}{diagnostic}\n\nThe user now asks:\n{}\n\nChange only what the request needs and keep everything else as it is.",
                    context.request
                ));
            }
            None => parts.push(format!("The user asks for a new widget:\n{}", context.request)),
        }
        let code_rule = if current.is_none() { "then the FULL widget code in one ```jsx fenced block." } else { Self::EDIT_REPLY_RULE };
        parts.push(format!(
            "Reply in exactly this form, which replaces the output rule above for this conversation:
SUMMARY: one short sentence saying what you made or changed, written in the language of the request below (a request in English gets an English sentence)
{code_rule}
If, and only if, the widget uses `fetch` or `$http`, end with one more fenced block
that declares every host it contacts:
```json
{{\"permissions\": [\"network\"], \"networkDomains\": [\"api.example.com\"]}}
```
Hosts are exact lowercase names or `*.example.com`. A host that is not declared is
blocked. No other permission can be declared. Nothing else."
        ));
        parts.join("\n\n")
    }

    /// Port of `parseTurnReply`: the model's note, the widget code and the declaration, if any.
    /// A reply without the SUMMARY line or without a fence is still read as code. The code ends
    /// with a line break, like a file.
    pub fn parse_turn_reply(raw: &str) -> AiTurnReply {
        let candidate = AiOutput::extract(raw);
        let mut note = None;
        let fence = raw.find("```");
        let head = fence.map_or(raw, |fence| &raw[..fence]);
        let mut source = candidate.source;
        for line in head.lines() {
            let trimmed = trim(line);
            if !trimmed.get(.."summary:".len()).is_some_and(|start| start.eq_ignore_ascii_case("summary:")) {
                continue;
            }
            let value = trim(&trimmed["summary:".len()..]);
            if !value.is_empty() {
                note = Some(Self::clip(value, AiConversationLimits::NOTE_CHARACTERS));
            }
            // Without a fence the SUMMARY line is part of what was read as code.
            if fence.is_none() {
                source = trim(&source.replacen(line, "", 1)).to_owned();
            }
            break;
        }
        AiTurnReply { note, candidate: AiCandidate { source: if source.is_empty() { String::new() } else { format!("{source}\n") }, manifest_json: candidate.manifest_json } }
    }

    /// Port of `previewOfPartialReply`: what the text written so far looks like as code.
    pub fn preview_of_partial_reply(partial: &str) -> &str {
        let Some(open) = partial.find("```") else { return partial };
        let Some(newline) = partial[open + 3..].find('\n') else { return "" };
        let code = &partial[open + 3 + newline + 1..];
        match code.find("```") {
            Some(close) => &code[..close],
            None => code,
        }
    }

    pub fn clip(text: &str, limit: usize) -> String {
        if length(text) > limit { format!("{}…", take(text, limit)) } else { text.to_owned() }
    }
}

/// A starter prompt shown where a conversation starts. Port of `AIExamplePrompt`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiExamplePrompt {
    pub title: &'static str,
    pub size: AiWidgetSize,
    pub prompt: &'static str,
}

/// Port of `AIExamplePrompts.all`, as Android has it: the Weather prompt uses
/// fixed coordinates and the Steps prompt is omitted, because `$location` and
/// `$health` are not available on Linux either.
pub struct AiExamplePrompts;

impl AiExamplePrompts {
    pub fn all() -> &'static [AiExamplePrompt] {
        const ALL: [AiExamplePrompt; 7] = [
            AiExamplePrompt {
                title: "Weather",
                size: AiWidgetSize::Medium,
                prompt: "Show the current weather for Shanghai (latitude 31.23, longitude 121.47) using the Open-Meteo API \
(https://api.open-meteo.com/v1/forecast). Dark navy background. \
Big temperature in Celsius, feels-like temperature below in a smaller caption, \
and the weather code. Handle a failed request gracefully with a message.",
            },
            AiExamplePrompt {
                title: "Clock",
                size: AiWidgetSize::Small,
                prompt: "A minimalist clock widget. Show the current time as a large HH:mm, \
today's weekday and date below in a muted caption. \
Dark gradient background from near-black to deep purple.",
            },
            AiExamplePrompt {
                title: "Countdown",
                size: AiWidgetSize::Medium,
                prompt: "A countdown widget to 2026-12-31. Show days remaining as a big number, \
with the label 'days until New Year' underneath. \
Warm orange-to-red gradient background, light text.",
            },
            AiExamplePrompt {
                title: "Crypto Price",
                size: AiWidgetSize::Medium,
                prompt: "Fetch the current Bitcoin price in USD from \
https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true \
and display it. Large USD price, a second line with the 24h change \
(green with ▲ if positive, red with ▼ if negative). Black background.",
            },
            AiExamplePrompt {
                title: "Battery Ring",
                size: AiWidgetSize::Small,
                prompt: "Show the device battery percentage via $device as a number in the center \
of a circular gauge ring. Use green above 50%, yellow 20-50%, red below 20%. \
Dark background.",
            },
            AiExamplePrompt {
                title: "Quote",
                size: AiWidgetSize::Large,
                prompt: "A daily quote widget. Hardcode 7 short inspirational quotes (one per weekday) \
and display the one matching today's weekday. \
Quote in a readable body font centered, author on a second line in caption. \
Soft pastel gradient background.",
            },
            AiExamplePrompt {
                title: "Habit Grid",
                size: AiWidgetSize::Large,
                prompt: "A GitHub-style 7x5 habit tracker grid (35 cells). Hardcode a boolean \
array of 35 values representing the last 35 days of a 'read 20 mins' habit. \
Green filled cells for completed, gray for missed. \
Header: 'Reading streak' with current streak count in the top-right.",
            },
        ];
        &ALL
    }
}
