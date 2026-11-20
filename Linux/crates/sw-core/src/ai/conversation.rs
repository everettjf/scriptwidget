//! A multi-turn AI conversation about one widget. Port of `AiConversation.kt`.

use serde_json::{Value, json};

use super::client::AiTokenUsage;
use super::output::AiManifestDeclaration;
use super::prompt_builder::AiWidgetSize;
use super::{is_blank, length, new_id, take, trim};
use crate::json::{Object, ObjectExt};

/// Bounds of a conversation. Port of `AIConversationLimits`.
pub struct AiConversationLimits;

impl AiConversationLimits {
    /// One generation and up to three repairs.
    pub const MAX_ATTEMPTS_PER_TURN: i32 = 4;
    pub const MAX_VERSIONS: usize = 30;
    pub const MAX_CONVERSATIONS: usize = 50;
    pub const MAX_REQUEST_CHARACTERS: usize = 4_000;
    pub const MAX_FILE_BYTES: u64 = 12 * 1024 * 1024;
    /// History sent to the model: the newest turns, shortened.
    pub const HISTORY_TURNS: usize = 12;
    pub const HISTORY_REQUEST_CHARACTERS: usize = 500;
    pub const HISTORY_NOTE_CHARACTERS: usize = 200;
    /// The version before the current one is sent for reference when it is small.
    pub const PREVIOUS_SOURCE_CHARACTERS: usize = 8_000;
    pub const TITLE_CHARACTERS: usize = 40;
    pub const NOTE_CHARACTERS: usize = 300;
    pub const ERROR_CHARACTERS: usize = 600;
    /// From here on the user is told that the conversation has grown heavy.
    pub const HEAVY_PROMPT_TOKENS: i64 = 30_000;
    pub const HEAVY_TOTAL_TOKENS: i64 = 300_000;
    /// How many Skills a conversation can name, and how long one id can be.
    pub const MAX_SKILLS: usize = 64;
    pub const SKILL_ID_CHARACTERS: usize = 128;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    HeavyRequests,
    HeavyTotal,
    VersionsFull,
    HistoryFull,
}

/// Something the user should know about the size of a conversation; the way out is to continue
/// in a new conversation from the current version. Port of `AIConversationUsageAdvice`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AiConversationUsageAdvice {
    pub reason: Reason,
    pub tokens: i64,
}

impl AiConversationUsageAdvice {
    pub fn message(&self) -> String {
        match self.reason {
            Reason::HeavyRequests => format!("Each request now sends about {} tokens. A new conversation from this version sends less.", grouped(self.tokens)),
            Reason::HeavyTotal => format!("This conversation has used {} tokens. A new conversation from this version starts small again.", grouped(self.tokens)),
            Reason::VersionsFull => format!("A conversation keeps {} versions; the oldest are dropped from now on.", AiConversationLimits::MAX_VERSIONS),
            Reason::HistoryFull => format!("The AI is told about the last {} turns only; older requests are no longer sent.", AiConversationLimits::HISTORY_TURNS),
        }
    }
}

/// A number with a comma between its thousands, as `"%,d"` writes it on Android.
fn grouped(number: i64) -> String {
    let digits = number.unsigned_abs().to_string();
    let mut out = String::from(if number < 0 { "-" } else { "" });
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// One version of the widget's source a turn produced. Port of `AIConversationVersion`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiConversationVersion {
    pub id: String,
    /// 1-based, in the order the versions were made; never reused.
    pub number: i64,
    pub source: String,
    pub parent_id: Option<String>,
    pub created_at: i64,
    /// Hosts the widget declared it contacts; empty for a widget that stays offline.
    pub network_domains: Vec<String>,
}

impl AiConversationVersion {
    /// The canonical declaration JSON of this version, or `None` when it declares no network use.
    pub fn declaration_json(&self) -> Option<String> {
        if self.network_domains.is_empty() { None } else { Some(AiManifestDeclaration::new(vec!["network".into()], self.network_domains.clone()).to_json()) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Waiting for the model or running the result. Never read back from disk as such.
    Running,
    Succeeded,
    /// Every attempt failed to run; the widget was left as it was.
    Unconverged,
    /// The provider could not be reached or refused the request.
    Failed,
    Cancelled,
    /// The program closed while the turn was running.
    Interrupted,
}

impl Status {
    const ALL: [Self; 6] = [Self::Running, Self::Succeeded, Self::Unconverged, Self::Failed, Self::Cancelled, Self::Interrupted];

    pub fn id(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Succeeded => "succeeded",
            Self::Unconverged => "unconverged",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Interrupted => "interrupted",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|status| status.id() == id)
    }
}

/// What became of one request. Port of `AIConversationTurn`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiConversationTurn {
    pub id: String,
    /// The user's own words; empty for a manual edit.
    pub request: String,
    /// The version the turn started from; `None` for the first turn of a new widget.
    pub base_version_id: Option<String>,
    pub status: Status,
    /// The model's one-sentence account of what it did.
    pub note: Option<String>,
    /// Why the turn did not succeed; safe to show.
    pub error_summary: Option<String>,
    /// How many attempts failed to run before the turn ended.
    pub repairs: i64,
    /// The version a successful turn produced.
    pub version_id: Option<String>,
    /// The last attempt of a turn that never ran, for the user to look at.
    pub failed_source: Option<String>,
    pub usage: AiTokenUsage,
    pub created_at: i64,
    /// The user went back to an older version and continued from there.
    pub is_abandoned: bool,
    /// Not a request: the widget's code was changed outside the conversation.
    pub is_manual_edit: bool,
}

/// A multi-turn AI conversation about one widget: what the user asked in each
/// turn, what came of it, and every version of the source a successful turn
/// produced. Port of `AIConversation`.
///
/// A conversation never holds a credential and names no provider: the profile
/// that is active when a turn is sent is used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiConversation {
    pub id: String,
    pub title: String,
    pub size: AiWidgetSize,
    pub turns: Vec<AiConversationTurn>,
    pub versions: Vec<AiConversationVersion>,
    pub current_version_id: Option<String>,
    /// Counts versions ever made, so a number is not reused after pruning.
    pub version_counter: i64,
    /// The installation id of the widget the conversation belongs to, which survives a rename; `None` while it is a draft.
    pub package_id: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    /// The ids of the Skills chosen for this conversation; they apply to every turn. `None`
    /// until the user chooses in the conversation: then the Skills enabled in the program apply,
    /// read anew for each turn, which is what every conversation did before this field existed.
    /// An empty list is a choice too: no Skill. Ids only: a Skill's text is read when a turn is sent.
    pub skill_ids: Option<Vec<String>>,
}

impl AiConversation {
    pub const FORMAT_VERSION: i64 = 1;

    /// An empty draft made at `now`.
    pub fn new(now: i64) -> Self {
        Self { id: new_id(), title: String::new(), size: AiWidgetSize::Medium, turns: Vec::new(), versions: Vec::new(), current_version_id: None, version_counter: 0, package_id: None, created_at: now, updated_at: now, skill_ids: None }
    }

    pub fn is_draft(&self) -> bool {
        self.package_id.is_none()
    }

    pub fn current_version(&self) -> Option<&AiConversationVersion> {
        self.version(self.current_version_id.as_deref())
    }

    pub fn latest_version(&self) -> Option<&AiConversationVersion> {
        self.versions.iter().max_by_key(|version| version.number)
    }

    pub fn total_usage(&self) -> AiTokenUsage {
        self.turns.iter().fold(AiTokenUsage::ZERO, |sum, turn| sum + turn.usage)
    }

    pub fn is_running(&self) -> bool {
        self.turns.iter().any(|turn| turn.status == Status::Running)
    }

    /// What the newest finished turn sent per request, on average over its attempts.
    pub fn last_request_tokens(&self) -> i64 {
        let Some(turn) = self.turns.iter().rfind(|turn| turn.usage.prompt_tokens > 0 && turn.status != Status::Running) else { return 0 };
        let attempts = if turn.status == Status::Succeeded { turn.repairs + 1 } else { turn.repairs.max(1) };
        turn.usage.prompt_tokens / attempts.max(1)
    }

    /// The most pressing thing to say about the size of the conversation, if any.
    pub fn usage_advice(&self) -> Option<AiConversationUsageAdvice> {
        let last = self.last_request_tokens();
        if last >= AiConversationLimits::HEAVY_PROMPT_TOKENS {
            return Some(AiConversationUsageAdvice { reason: Reason::HeavyRequests, tokens: last });
        }
        let total = self.total_usage().total_tokens;
        if total >= AiConversationLimits::HEAVY_TOTAL_TOKENS {
            return Some(AiConversationUsageAdvice { reason: Reason::HeavyTotal, tokens: total });
        }
        if self.versions.len() >= AiConversationLimits::MAX_VERSIONS {
            return Some(AiConversationUsageAdvice { reason: Reason::VersionsFull, tokens: 0 });
        }
        let told = self.turns.iter().filter(|turn| turn.status == Status::Succeeded && !turn.is_abandoned && !turn.is_manual_edit).count();
        if told > AiConversationLimits::HISTORY_TURNS {
            return Some(AiConversationUsageAdvice { reason: Reason::HistoryFull, tokens: 0 });
        }
        None
    }

    /// A new conversation that starts from the current version: same size, same widget, one
    /// version, no turns, and so no history to send. `None` without a version.
    pub fn continued_from_current_version(&self, now: i64) -> Option<Self> {
        let current = self.current_version()?;
        let mut next = Self::new(now);
        next.title = self.title.clone();
        next.size = self.size;
        next.package_id = self.package_id.clone();
        next.skill_ids = self.skill_ids.clone();
        next.add_version(&current.source, current.network_domains.clone(), now);
        Some(next)
    }

    pub fn version(&self, id: Option<&str>) -> Option<&AiConversationVersion> {
        let wanted = id?;
        self.versions.iter().find(|version| version.id == wanted)
    }

    pub fn turn(&self, id: &str) -> Option<&AiConversationTurn> {
        self.turns.iter().find(|turn| turn.id == id)
    }

    pub fn turn_mut(&mut self, id: &str) -> Option<&mut AiConversationTurn> {
        self.turns.iter_mut().find(|turn| turn.id == id)
    }

    /// Starts a turn from the current version. Turns made after that version
    /// are marked abandoned: the conversation continues from where the user is.
    pub fn begin_turn(&mut self, request: &str, now: i64) -> &AiConversationTurn {
        self.abandon_turns_off_current_path();
        self.turns.push(AiConversationTurn {
            id: new_id(),
            request: take(request, AiConversationLimits::MAX_REQUEST_CHARACTERS).to_owned(),
            base_version_id: self.current_version_id.clone(),
            status: Status::Running,
            note: None,
            error_summary: None,
            repairs: 0,
            version_id: None,
            failed_source: None,
            usage: AiTokenUsage::ZERO,
            created_at: now,
            is_abandoned: false,
            is_manual_edit: false,
        });
        if self.title.is_empty() {
            self.title = Self::title_from(request);
        }
        self.updated_at = now;
        &self.turns[self.turns.len() - 1]
    }

    /// Records a version and makes it the current one.
    pub fn add_version(&mut self, source: &str, network_domains: Vec<String>, now: i64) -> &AiConversationVersion {
        self.version_counter += 1;
        let id = new_id();
        self.versions.push(AiConversationVersion { id: id.clone(), number: self.version_counter, source: source.to_owned(), parent_id: self.current_version_id.take(), created_at: now, network_domains });
        self.current_version_id = Some(id.clone());
        self.prune_versions();
        self.updated_at = now;
        self.versions.iter().find(|version| version.id == id).expect("the current version is never pruned")
    }

    /// Shows another version. Returns false when it does not exist.
    pub fn select_version(&mut self, id: &str, now: i64) -> bool {
        if self.version(Some(id)).is_none() {
            return false;
        }
        self.current_version_id = Some(id.to_owned());
        self.updated_at = now;
        true
    }

    /// Chooses the Skills of this conversation; ids are deduplicated and sorted, as Swift stores them.
    pub fn choose_skills<'a>(&mut self, ids: impl IntoIterator<Item = &'a str>, now: i64) {
        let mut chosen: Vec<String> = ids.into_iter().filter(|id| !id.is_empty() && length(id) <= AiConversationLimits::SKILL_ID_CHARACTERS).map(str::to_owned).collect();
        chosen.sort();
        chosen.dedup();
        chosen.truncate(AiConversationLimits::MAX_SKILLS);
        self.skill_ids = Some(chosen);
        self.updated_at = now;
    }

    /// The turns the model is told about: finished, not abandoned, not manual edits, oldest first.
    pub fn history_for_prompt(&self) -> Vec<&AiConversationTurn> {
        let told: Vec<&AiConversationTurn> = self.turns.iter().filter(|turn| turn.status == Status::Succeeded && !turn.is_abandoned && !turn.is_manual_edit).collect();
        told[told.len().saturating_sub(AiConversationLimits::HISTORY_TURNS)..].to_vec()
    }

    /// Takes over code that did not come from the AI: what the installed widget
    /// holds when it differs from every version the conversation knows as current.
    /// Returns whether a version was added.
    pub fn adopt_external_source(&mut self, source: &str, network_domains: Vec<String>, now: i64) -> bool {
        if self.current_version().is_some_and(|version| version.source == source) {
            return false;
        }
        self.abandon_turns_off_current_path();
        let base = self.current_version_id.clone();
        let version_id = self.add_version(source, network_domains, now).id.clone();
        self.turns.push(AiConversationTurn {
            id: new_id(),
            request: String::new(),
            base_version_id: base,
            status: Status::Succeeded,
            note: None,
            error_summary: None,
            repairs: 0,
            version_id: Some(version_id),
            failed_source: None,
            usage: AiTokenUsage::ZERO,
            created_at: now,
            is_abandoned: false,
            is_manual_edit: true,
        });
        true
    }

    /// A turn left running by a closed program can never finish.
    pub fn mark_running_turns_interrupted(&mut self) {
        for turn in &mut self.turns {
            if turn.status == Status::Running {
                turn.status = Status::Interrupted;
            }
        }
    }

    fn abandon_turns_off_current_path(&mut self) {
        let Some(current) = self.current_version_id.clone() else { return };
        if self.version(Some(&current)).is_none() {
            return;
        }
        let abandoned: Vec<Option<bool>> = self
            .turns
            .iter()
            // A turn whose version was pruned keeps the state it had.
            .map(|turn| self.version(turn.version_id.as_deref()).map(|produced| !(produced.id == current || self.is_ancestor(&produced.id, &current))))
            .collect();
        for (turn, abandoned) in self.turns.iter_mut().zip(abandoned) {
            if let Some(abandoned) = abandoned {
                turn.is_abandoned = abandoned;
            }
        }
    }

    fn is_ancestor(&self, candidate: &str, version_id: &str) -> bool {
        let mut cursor = self.version(Some(version_id)).and_then(|version| version.parent_id.as_deref());
        let mut steps = 0;
        while let Some(id) = cursor {
            if steps > self.versions.len() {
                break;
            }
            if id == candidate {
                return true;
            }
            cursor = self.version(Some(id)).and_then(|version| version.parent_id.as_deref());
            steps += 1;
        }
        false
    }

    /// Keeps the newest versions and always the current one.
    fn prune_versions(&mut self) {
        let Some(excess) = self.versions.len().checked_sub(AiConversationLimits::MAX_VERSIONS).filter(|excess| *excess > 0) else { return };
        let mut others: Vec<(i64, String)> = self.versions.iter().filter(|version| Some(&version.id) != self.current_version_id.as_ref()).map(|version| (version.number, version.id.clone())).collect();
        others.sort();
        let removed: Vec<String> = others.into_iter().take(excess).map(|(_, id)| id).collect();
        self.versions.retain(|version| !removed.contains(&version.id));
    }

    pub fn to_json(&self) -> Value {
        let versions: Vec<Value> = self
            .versions
            .iter()
            .map(|version| json!({ "id": version.id, "number": version.number, "source": version.source, "parentId": version.parent_id, "createdAt": version.created_at, "networkDomains": version.network_domains }))
            .collect();
        let turns: Vec<Value> = self
            .turns
            .iter()
            .map(|turn| {
                json!({
                    "id": turn.id, "request": turn.request, "baseVersionId": turn.base_version_id,
                    "status": turn.status.id(), "note": turn.note, "errorSummary": turn.error_summary,
                    "repairs": turn.repairs, "versionId": turn.version_id, "failedSource": turn.failed_source,
                    "promptTokens": turn.usage.prompt_tokens, "completionTokens": turn.usage.completion_tokens, "totalTokens": turn.usage.total_tokens,
                    "createdAt": turn.created_at, "isAbandoned": turn.is_abandoned, "isManualEdit": turn.is_manual_edit,
                })
            })
            .collect();
        let mut root = json!({
            "formatVersion": Self::FORMAT_VERSION,
            "id": self.id,
            "title": self.title,
            "size": self.size.family(),
            "currentVersionId": self.current_version_id,
            "versionCounter": self.version_counter,
            "packageId": self.package_id,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "versions": versions,
            "turns": turns,
        });
        // Written only once the user chose: a file without it means "the Skills enabled in the program".
        if let Some(ids) = &self.skill_ids {
            root["skillIds"] = json!(ids);
        }
        root
    }

    pub fn title_from(request: &str) -> String {
        let line = request.lines().find(|line| !is_blank(line)).map(trim).unwrap_or("");
        if length(line) > AiConversationLimits::TITLE_CHARACTERS { format!("{}…", take(line, AiConversationLimits::TITLE_CHARACTERS)) } else { line.to_owned() }
    }

    /// Conversation ids become file names: `^[A-Za-z0-9-]{8,64}$`.
    pub fn is_safe_id(id: &str) -> bool {
        (8..=64).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    }

    /// Reads a saved conversation, failing closed: an unknown format version or a
    /// malformed field gives `None`, never a partly read conversation.
    pub fn from_json(root: &Value) -> Option<Self> {
        let root = root.as_object()?;
        if integer(root, "formatVersion")? != Self::FORMAT_VERSION {
            return None;
        }
        let mut versions = Vec::new();
        for item in root.get("versions")?.as_array()? {
            let item = item.as_object()?;
            let network_domains = match item.get("networkDomains") {
                Some(Value::Array(domains)) => domains.iter().map(|domain| domain.as_str().map(str::to_owned)).collect::<Option<Vec<String>>>()?,
                _ => Vec::new(),
            };
            versions.push(AiConversationVersion { id: string(item, "id")?, number: integer(item, "number")?, source: string(item, "source")?, parent_id: text(item, "parentId")?, created_at: integer(item, "createdAt")?, network_domains });
        }
        let mut turns = Vec::new();
        for item in root.get("turns")?.as_array()? {
            let item = item.as_object()?;
            let count = |key: &str| integer(item, key).unwrap_or(0);
            turns.push(AiConversationTurn {
                id: string(item, "id")?,
                request: string(item, "request")?,
                base_version_id: text(item, "baseVersionId")?,
                status: Status::from_id(&string(item, "status")?)?,
                note: text(item, "note")?,
                error_summary: text(item, "errorSummary")?,
                repairs: count("repairs"),
                version_id: text(item, "versionId")?,
                failed_source: text(item, "failedSource")?,
                usage: AiTokenUsage::new(count("promptTokens"), count("completionTokens"), count("totalTokens")),
                created_at: integer(item, "createdAt")?,
                is_abandoned: item.opt_bool("isAbandoned", false),
                is_manual_edit: item.opt_bool("isManualEdit", false),
            });
        }
        let id = string(root, "id")?;
        if !Self::is_safe_id(&id) {
            return None;
        }
        // Optional. Present, it must be a short list of short strings; anything else is not a conversation.
        let skill_ids = match root.get("skillIds") {
            None | Some(Value::Null) => None,
            Some(Value::Array(items)) if items.len() <= AiConversationLimits::MAX_SKILLS => {
                Some(items.iter().map(|item| item.as_str().filter(|id| !id.is_empty() && length(id) <= AiConversationLimits::SKILL_ID_CHARACTERS).map(str::to_owned)).collect::<Option<Vec<String>>>()?)
            }
            Some(_) => return None,
        };
        let mut conversation = Self {
            id,
            title: root.opt_string("title"),
            size: AiWidgetSize::from_family(Some(&root.opt_string("size"))),
            turns,
            versions,
            current_version_id: text(root, "currentVersionId")?,
            version_counter: integer(root, "versionCounter")?,
            package_id: text(root, "packageId")?,
            created_at: integer(root, "createdAt")?,
            updated_at: integer(root, "updatedAt")?,
            skill_ids,
        };
        conversation.mark_running_turns_interrupted();
        Some(conversation)
    }
}

/// A member that must be a string.
fn string(item: &Object, key: &str) -> Option<String> {
    item.get(key)?.as_str().map(str::to_owned)
}

/// A member that must be a whole number.
fn integer(item: &Object, key: &str) -> Option<i64> {
    item.get(key)?.as_i64()
}

/// A member that is a string, or null or missing; anything else fails the reading (the outer `None`).
fn text(item: &Object, key: &str) -> Option<Option<String>> {
    match item.get(key) {
        None | Some(Value::Null) => Some(None),
        Some(Value::String(text)) => Some(Some(text.clone())),
        Some(_) => None,
    }
}
