//! The AI conversation about the widget that is open in the editor, or about
//! a widget that does not exist yet, without the window: the provider profile
//! and the key, a turn from the request to the version it leaves, and applying
//! that version to the widget or saving it as a new one. The view (`ui/ai.rs`)
//! draws what is here.
//!
//! It follows the conversation screen of the Android app
//! (`Android/app/.../ui/AiConversationScreen.kt`) over the shared port in
//! `sw_core::ai`: the widget is changed only when the user applies a version,
//! hosts are added only when the user agrees, and a turn that does not run
//! leaves everything as it was.
//!
//! The key comes from the system keyring for each turn and is handed to the
//! client; it is in no setting, no conversation and no message this module
//! makes. What a model answers is untrusted: it is shown as text and run only
//! in the engine, with the limits every run has.

use std::sync::{Arc, OnceLock};

use sw_core::InstalledPackage;
use sw_core::ai::candidates::AiCandidates;
use sw_core::ai::credentials::{self, ENVIRONMENT_KEY};
use sw_core::ai::source_diff::Line;
use sw_core::ai::transport::OnBody;
use sw_core::ai::*;

use crate::model::{PreviewRequest, PreviewSource, Studio, StudioError};

/// What `SCRIPTWIDGET_AI_KEY` held when the program started. `main` reads the variable once,
/// before any thread exists, and takes it out of the environment so that no child inherits it.
static ONE_RUN_KEY: OnceLock<Option<ApiKey>> = OnceLock::new();

/// Records the key the environment gave for this run; a value that is not a key is no key.
pub fn set_one_run_key(value: Option<std::ffi::OsString>) -> Result<(), CredentialError> {
    let key = credentials::key_from_environment(value);
    let _ = ONE_RUN_KEY.set(key.clone().unwrap_or(None));
    key.map(|_| ())
}

pub fn one_run_key() -> Option<ApiKey> {
    ONE_RUN_KEY.get().cloned().flatten()
}

/// What "Fix runtime error" asks when nothing is typed: the words of the Apple apps.
pub const FIX_REQUEST: &str = "Fix the current runtime error while keeping the widget's design.";

/// What "Fix runtime error" tells the model about the run that failed: the error as a trial
/// words it, then the last console lines of that run, as the Android and Apple apps send them.
/// `error` is the category and the message, `logs` the level and the message of each line.
pub fn runtime_diagnostic(error: &(String, String), logs: &[(String, String)]) -> String {
    let lines: Vec<String> = logs.iter().map(|(level, message)| format!("[{level}] {message}")).collect();
    PromptBuilder::runtime_diagnostic(&format!("{}: {}", error.0, error.1), &lines)
}

/// Whether there is a key to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyStatus {
    /// In the system keyring.
    Stored,
    /// Given in the environment for this run of the window; not saved.
    ForThisRun,
    Missing,
    /// The keyring cannot be used; the sentence says why.
    Unavailable(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Waiting for the model.
    Thinking,
    /// The reply is arriving.
    Writing,
    /// The code is being run and drawn.
    Running,
    /// An attempt did not pass; the model is asked again.
    Repairing,
}

/// The turn that is running.
#[derive(Debug, Clone)]
pub struct Running {
    pub turn_id: String,
    pub attempt: i32,
    /// How many attempts the turn has.
    pub limit: i32,
    pub phase: Phase,
    /// The reply of the current attempt as far as it is written.
    pub reply: String,
    cancellation: AiCancellation,
}

impl Running {
    /// What the reply so far looks like as code.
    pub fn code(&self) -> &str {
        PromptBuilder::preview_of_partial_reply(&self.reply)
    }
}

/// The current version of a conversation, next to the version before it and to what the widget holds now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    pub version: i64,
    /// The model's one sentence about it.
    pub note: String,
    pub source: String,
    /// Lines added to and removed from the version before this one.
    pub added: usize,
    pub removed: usize,
    /// The lines that differ from the version before, with a few around them; `None` when there is
    /// no version before or the code is too long to compare, and the code is shown instead.
    pub lines: Option<Vec<Line>>,
    /// The hosts this version declares.
    pub domains: Vec<String>,
    /// Hosts this version lets the widget contact that it may not contact now; for a widget that
    /// does not exist yet, every host it declares.
    pub new_hosts: Vec<String>,
    /// True once the widget holds this version.
    pub applied: bool,
}

/// One earlier turn, as the panel lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnRow {
    pub id: String,
    pub request: String,
    pub status: Status,
    /// The model's sentence for a turn that ran, the reason for one that did not.
    pub detail: String,
    pub version: Option<i64>,
    pub repairs: i64,
    pub manual_edit: bool,
    /// It did not succeed and can be sent again.
    pub can_retry: bool,
}

/// What applying did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    /// The widget now holds the version: `path` has the text `source`.
    Done { path: String, source: String },
    /// Nothing was changed: the version adds these hosts, and the user has not agreed yet.
    NeedsConsent(Vec<String>),
}

/// What saving a draft as a new widget did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Saved {
    /// The widget exists under this folder name, and the conversation belongs to it.
    Done { name: String },
    /// Nothing was saved: the widget would contact these hosts, and the user has not agreed yet.
    NeedsConsent(Vec<String>),
}

/// A Skill the conversation can be sent with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillChoice {
    pub id: String,
    pub title: String,
    /// Its text is added to the next turn.
    pub chosen: bool,
}

/// Where the current version is among the versions of a conversation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VersionPlace {
    /// The number of the current version.
    pub number: i64,
    /// The number of the newest version.
    pub latest: i64,
    pub has_previous: bool,
    pub has_next: bool,
}

/// The conversation about one widget, as the panel shows it.
#[derive(Debug, Clone)]
pub struct AiPanel {
    /// The folder name of the widget; `None` while the conversation is a draft about a widget that does not exist yet.
    pub widget: Option<String>,
    pub conversation: AiConversation,
    pub running: Option<Running>,
    pub proposal: Option<Proposal>,
}

impl AiPanel {
    /// The turns so far, oldest first; the running one is not among them.
    pub fn rows(&self) -> Vec<TurnRow> {
        self.conversation
            .turns
            .iter()
            .filter(|turn| turn.status != Status::Running)
            .map(|turn| TurnRow {
                id: turn.id.clone(),
                request: turn.request.clone(),
                status: turn.status,
                detail: if turn.status == Status::Succeeded { turn.note.clone() } else { turn.error_summary.clone() }.unwrap_or_default(),
                version: self.conversation.version(turn.version_id.as_deref()).map(|version| version.number),
                repairs: turn.repairs,
                manual_edit: turn.is_manual_edit,
                can_retry: self.running.is_none() && AiConversationTurns::can_retry(&self.conversation, &turn.id),
            })
            .collect()
    }

    pub fn is_running(&self) -> bool {
        self.running.is_some()
    }

    /// Nothing was asked yet: the place for the example prompts.
    pub fn is_empty(&self) -> bool {
        self.running.is_none() && self.conversation.turns.iter().all(|turn| turn.is_manual_edit)
    }

    pub fn is_draft(&self) -> bool {
        self.widget.is_none()
    }

    /// Asks the running turn to stop; it ends as cancelled and changes nothing.
    pub fn cancel(&self) {
        if let Some(running) = &self.running {
            running.cancellation.cancel();
        }
    }

    /// Takes one event of the running turn `turn_id`. An event of a turn that is over is dropped.
    pub fn event(&mut self, turn_id: &str, event: &AgentLoopEvent) {
        let Some(running) = self.running.as_mut().filter(|running| running.turn_id == turn_id) else { return };
        match event {
            AgentLoopEvent::Thinking { iteration } => {
                running.attempt = *iteration;
                running.phase = if *iteration > 1 { Phase::Repairing } else { Phase::Thinking };
                running.reply.clear();
            }
            AgentLoopEvent::Partial { text, .. } => {
                running.phase = Phase::Writing;
                running.reply.clone_from(text);
            }
            AgentLoopEvent::Running { .. } => running.phase = Phase::Running,
            _ => {}
        }
        AiConversationTurns::apply_event(&mut self.conversation, turn_id, event);
    }

    /// What the advice about a conversation that has grown says, if there is any.
    pub fn advice(&self) -> Option<String> {
        self.conversation.usage_advice().map(|advice| advice.message())
    }

    /// Where the current version is, for "version 2 of 5" and the buttons beside it.
    pub fn version_place(&self) -> Option<VersionPlace> {
        let current = self.conversation.current_version()?.number;
        let numbers = self.conversation.versions.iter().map(|version| version.number);
        Some(VersionPlace { number: current, latest: numbers.clone().max().unwrap_or(current), has_previous: numbers.clone().any(|number| number < current), has_next: numbers.clone().any(|number| number > current) })
    }
}

/// Everything a turn needs on its worker thread. It holds the key for the length of the turn.
pub struct TurnJob {
    pub turn_id: String,
    loop_request: AgentLoopRequest,
    settings: AiSettings,
    key: ApiKey,
    /// The widget the turn changes; `None` for a widget that does not exist yet.
    installed: Option<InstalledPackage>,
    baseline: Option<String>,
    family: String,
    dark: bool,
    cancellation: AiCancellation,
}

/// What a turn sends.
enum Ask<'a> {
    /// A new request, from the current version, with what the last run of the widget reported when that is why it is asked.
    Request { text: &'a str, diagnostic: Option<&'a str> },
    /// The turn with this id again, from the version it started from.
    Again(&'a str),
}

/// One transport for every client this service makes.
struct Shared(Arc<dyn AiTransport>);

impl AiTransport for Shared {
    fn execute(&self, request: &AiHttpRequest, cancellation: &AiCancellation) -> Result<AiHttpResponse, AiClientError> {
        self.0.execute(request, cancellation)
    }

    fn execute_streaming(&self, request: &AiHttpRequest, cancellation: &AiCancellation, on_body: OnBody<'_>) -> Result<AiHttpResponse, AiClientError> {
        self.0.execute_streaming(request, cancellation, on_body)
    }
}

pub struct AiService {
    studio: Arc<Studio>,
    profiles: AiProfileStore,
    conversations: AiConversationStore,
    credentials: Arc<dyn CredentialStore>,
    transport: Arc<dyn AiTransport>,
    one_run_key: Option<ApiKey>,
    system_prompt: OnceLock<String>,
}

impl AiService {
    /// The service of the program: the system keyring and the HTTPS transport.
    /// `one_run_key` is what `SCRIPTWIDGET_AI_KEY` held when the program started, if anything.
    pub fn new(studio: Arc<Studio>, one_run_key: Option<ApiKey>) -> Self {
        Self::with_parts(studio, Arc::new(SecretToolStore::new()), Arc::new(HttpsAiTransport::new()), one_run_key)
    }

    pub fn with_parts(studio: Arc<Studio>, credentials: Arc<dyn CredentialStore>, transport: Arc<dyn AiTransport>, one_run_key: Option<ApiKey>) -> Self {
        let paths = studio.paths();
        Self { profiles: AiProfileStore::new(paths.ai_profile()), conversations: AiConversationStore::new(paths.ai_conversations()), studio, credentials, transport, one_run_key, system_prompt: OnceLock::new() }
    }

    // The provider and the key

    /// The saved provider, endpoint and model, or the defaults.
    pub fn settings(&self) -> AiSettings {
        self.profiles.load_or_default()
    }

    /// Saves the provider, the endpoint and the model. What is not a usable profile is refused with the sentence that says why.
    pub fn save_profile(&self, kind: AiProviderKind, base_url: &str, model: &str) -> Result<AiSettings, StudioError> {
        let mut settings = self.settings();
        settings.profile = AiProfile::new(kind, base_url, model);
        if let Some(problem) = settings.profile.validation_error() {
            return Err(StudioError(problem));
        }
        self.profiles.save(&settings).map_err(|error| StudioError(error.to_string()))?;
        Ok(self.settings())
    }

    pub fn key_status(&self, kind: AiProviderKind) -> KeyStatus {
        if self.one_run_key.is_some() {
            return KeyStatus::ForThisRun;
        }
        match self.credentials.load(kind.id()) {
            Ok(Some(_)) => KeyStatus::Stored,
            Ok(None) => KeyStatus::Missing,
            Err(error) => KeyStatus::Unavailable(error.message().to_owned()),
        }
    }

    /// Puts the key of `kind` into the keyring. Without a keyring it is stored nowhere, and the error says so.
    pub fn store_key(&self, kind: AiProviderKind, text: &str) -> Result<(), StudioError> {
        let key = ApiKey::new(text).map_err(|error| StudioError(error.message().to_owned()))?;
        self.credentials.save(kind.id(), &key).map_err(|error| StudioError(error.message().to_owned()))
    }

    pub fn remove_key(&self, kind: AiProviderKind) -> Result<bool, StudioError> {
        self.credentials.remove(kind.id()).map_err(|error| StudioError(error.message().to_owned()))
    }

    /// The key of `kind` for one request, or the sentence that says where to enter it.
    fn key_for(&self, kind: AiProviderKind) -> Result<ApiKey, StudioError> {
        credentials::key_for(self.credentials.as_ref(), self.one_run_key.as_ref(), kind).map_err(|error| match error {
            CredentialError::Missing(_) => StudioError(format!("No API key is stored for {}. Enter it in Settings.", kind.display_name())),
            other => StudioError(other.message().to_owned()),
        })
    }

    /// Asks the endpoint in the fields of the settings page which models it lists, with the key
    /// of that provider. The endpoint need not be saved; it must be HTTPS like every endpoint.
    /// Blocks for as long as the server takes: call it off the window's thread.
    pub fn models(&self, kind: AiProviderKind, base_url: &str) -> Result<Vec<String>, StudioError> {
        // The list does not depend on the model that is chosen; a profile needs one to be valid.
        let profile = AiProfile::new(kind, base_url, "-");
        if let Some(problem) = profile.validation_error() {
            return Err(StudioError(problem));
        }
        let key = self.key_for(kind)?;
        AiClient::new(Shared(self.transport.clone())).list_models(&profile, key.expose(), &AiCancellation::new()).map_err(|error| StudioError(error.message))
    }

    // The conversation

    fn installed(&self, widget: &str) -> Result<InstalledPackage, StudioError> {
        let package = self.studio.library().find(widget).ok_or_else(|| StudioError(format!("There is no widget named {widget}.")))?;
        if package.manifest_present && package.manifest.is_none() {
            return Err(StudioError("widget.json of this widget cannot be read.".into()));
        }
        Ok(package)
    }

    /// The widget of a panel, or `None` for a draft.
    fn installed_of(&self, panel: &AiPanel) -> Result<Option<InstalledPackage>, StudioError> {
        panel.widget.as_deref().map(|widget| self.installed(widget)).transpose()
    }

    fn entry_text(&self, installed: &InstalledPackage) -> Result<String, StudioError> {
        let entry = AiCandidates::entry_of(installed);
        let bytes = self.studio.library().store().read_file(&installed.name, &entry)?;
        String::from_utf8(bytes).map_err(|_| StudioError(format!("{entry} is not text.")))
    }

    /// Takes over what the widget holds when the conversation has never seen it: code written by
    /// hand, or by a Gallery update. Code that is one of the conversation's versions is not taken
    /// over: the version shown stays the one that is worked on, as in the Apple apps
    /// (`AIConversationSession.adoptEditorSource`). Returns whether a version was added.
    fn adopt_saved(&self, conversation: &mut AiConversation, installed: &InstalledPackage, now: i64) -> Result<bool, StudioError> {
        let saved = self.entry_text(installed)?;
        if conversation.versions.iter().any(|version| version.source == saved) {
            return Ok(false);
        }
        Ok(conversation.adopt_external_source(&saved, AiCandidates::allowed_hosts(Some(installed)), now))
    }

    /// Opens the conversation about a widget: its newest one, or a new one. Code that was
    /// changed outside the conversation (in the editor, for one) becomes its current version.
    /// A current version the widget does not hold (made and not applied, or stepped to) is
    /// shown as the proposal it is: the next request works on it.
    pub fn open(&self, widget: &str) -> Result<AiPanel, StudioError> {
        let installed = self.installed(widget)?;
        let now = now_milliseconds();
        let mut conversation = self.conversations.latest(&installed.installation).unwrap_or_else(|| {
            let mut fresh = AiConversation::new(now);
            fresh.package_id = Some(installed.installation.clone());
            fresh.title = installed.display_name();
            let families = installed.families();
            fresh.size = AiWidgetSize::from_family(Some(if families.contains(&"medium") { "medium" } else { families.first().copied().unwrap_or("medium") }));
            fresh
        });
        let adopted = self.adopt_saved(&mut conversation, &installed, now)?;
        // Only a conversation that has something said in it is a file.
        if adopted && conversation.turns.iter().any(|turn| !turn.is_manual_edit) {
            self.conversations.save(&conversation);
        }
        let mut panel = AiPanel { widget: Some(installed.name), conversation, running: None, proposal: None };
        panel.proposal = self.proposal(&panel).filter(|proposal| !proposal.applied);
        Ok(panel)
    }

    /// A conversation about a widget that does not exist yet. Nothing is a file until a request is sent.
    pub fn new_draft(&self) -> AiPanel {
        AiPanel { widget: None, conversation: AiConversation::new(now_milliseconds()), running: None, proposal: None }
    }

    fn system_prompt(&self) -> &str {
        self.system_prompt.get_or_init(|| PromptBuilder::system_prompt(&AiReference::load(self.studio.templates())))
    }

    /// Starts a turn for `request` and returns the work for a worker thread. The turn works on
    /// the conversation's current version, the one shown, also when the user stepped to it and
    /// the widget holds another; code saved by hand that the conversation has never seen is
    /// taken over first. `unsaved` says that the editor holds changes that are not saved: they
    /// would be in neither.
    /// `family` is the size the preview shows; a draft keeps the size chosen in the conversation.
    pub fn start(&self, panel: &mut AiPanel, request: &str, unsaved: bool, family: &str, dark: bool) -> Result<TurnJob, StudioError> {
        self.begin(panel, Ask::Request { text: request, diagnostic: None }, unsaved, Some(family), dark)
    }

    /// Starts a turn that is asked because the widget's last run failed: `diagnostic` is what that
    /// run reported, and goes to the model with the request. Without a request of the user's own
    /// the turn asks to fix the error and keep the design, in the words of the Apple apps.
    pub fn start_fix(&self, panel: &mut AiPanel, request: &str, diagnostic: &str, unsaved: bool, family: &str, dark: bool) -> Result<TurnJob, StudioError> {
        let text = if request.trim().is_empty() { FIX_REQUEST } else { request };
        self.begin(panel, Ask::Request { text, diagnostic: Some(diagnostic).filter(|text| !text.trim().is_empty()) }, unsaved, Some(family), dark)
    }

    /// Sends a turn that did not succeed again, from the version it started from. That version is
    /// the conversation's own, so what the editor holds does not matter here.
    pub fn retry(&self, panel: &mut AiPanel, turn_id: &str, dark: bool) -> Result<TurnJob, StudioError> {
        self.begin(panel, Ask::Again(turn_id), false, None, dark)
    }

    fn begin(&self, panel: &mut AiPanel, ask: Ask<'_>, unsaved: bool, family: Option<&str>, dark: bool) -> Result<TurnJob, StudioError> {
        if panel.is_running() {
            return Err(StudioError("A request is still running.".into()));
        }
        match &ask {
            Ask::Request { text, .. } if text.trim().is_empty() => return Err(StudioError("Say what to change.".into())),
            Ask::Again(turn) if !AiConversationTurns::can_retry(&panel.conversation, turn) => return Err(StudioError("That request cannot be sent again.".into())),
            _ => {}
        }
        if unsaved {
            return Err(StudioError("Save your changes first: the AI does not see unsaved code.".into()));
        }
        let settings = self.settings();
        if let Some(problem) = settings.profile.validation_error() {
            return Err(StudioError(problem));
        }
        let key = self.key_for(settings.profile.kind)?;
        let installed = self.installed_of(panel)?;
        let now = now_milliseconds();
        if let (Ask::Request { .. }, Some(installed)) = (&ask, &installed) {
            // What was written by hand since the panel was opened is what the turn starts from;
            // otherwise it is the version shown.
            self.adopt_saved(&mut panel.conversation, installed, now)?;
            if let Some(size) = AiWidgetSize::ALL.into_iter().find(|size| Some(size.family()) == family) {
                panel.conversation.size = size;
            }
        }
        // The Skills of this conversation, or without a choice the ones the user turned on, read when
        // the turn is sent: one switched on in the middle of a conversation applies from the next
        // turn. They add text to the request and nothing else.
        let store = self.studio.skill_store();
        let skills = Some(match &panel.conversation.skill_ids {
            Some(ids) => store.prompt_text(ids),
            None => store.enabled_skills_prompt_text(),
        })
        .filter(|text| !text.trim().is_empty());
        let started = match ask {
            Ask::Request { text, diagnostic } => AiConversationTurns::begin(&mut panel.conversation, text, self.system_prompt(), skills.as_deref(), diagnostic, now),
            Ask::Again(turn) => AiConversationTurns::retry(&mut panel.conversation, turn, self.system_prompt(), skills.as_deref(), now),
        }
        .ok_or_else(|| StudioError("A request is still running.".into()))?;
        // What the turn starts from: for a request sent again, the version it started from the first time.
        let baseline = panel.conversation.current_version().map(|version| version.source.clone());
        // Saved before the model is asked: a turn the program does not survive reads back as interrupted.
        self.conversations.save(&panel.conversation);
        let cancellation = AiCancellation::new();
        panel.proposal = None;
        panel.running = Some(Running { turn_id: started.turn_id.clone(), attempt: 1, limit: AgentLoop::iteration_limit(started.loop_request.max_iterations), phase: Phase::Thinking, reply: String::new(), cancellation: cancellation.clone() });
        Ok(TurnJob { turn_id: started.turn_id, loop_request: started.loop_request, settings, key, installed, baseline, family: panel.conversation.size.family().to_owned(), dark, cancellation })
    }

    /// Asks the model and runs what it answers, up to the attempts a turn has. Blocks until the
    /// turn is over: call it on a worker thread and hand the events to [`AiPanel::event`].
    pub fn run(&self, job: &TurnJob, on_event: &mut dyn FnMut(&AgentLoopEvent)) -> AgentLoopOutcome {
        let client = AiClient::new(Shared(self.transport.clone()));
        let chat = client.bind(job.settings.clone(), job.key.expose());
        AgentLoop::new(&chat).run(&job.loop_request, &mut |source, declaration| self.studio.trial(job.installed.as_ref(), source, declaration, &job.family, job.dark, job.baseline.as_deref()), &job.cancellation, on_event)
    }

    /// Ends the turn `turn_id` with what the loop returned. A turn that made a version leaves
    /// it as a proposal; the widget itself is not changed until [`AiService::apply`].
    pub fn finish(&self, panel: &mut AiPanel, turn_id: &str, outcome: &AgentLoopOutcome) {
        if !panel.running.as_ref().is_some_and(|running| running.turn_id == turn_id) {
            return;
        }
        panel.running = None;
        AiConversationTurns::apply_outcome(&mut panel.conversation, turn_id, Some(outcome), now_milliseconds());
        self.conversations.save(&panel.conversation);
        panel.proposal = if matches!(outcome, AgentLoopOutcome::Succeeded { .. }) { self.proposal(panel) } else { None };
    }

    /// The current version next to the version before it, as on the other platforms, and to what the widget holds.
    fn proposal(&self, panel: &AiPanel) -> Option<Proposal> {
        let version = panel.conversation.current_version()?;
        let installed = self.installed_of(panel).ok()?;
        let held = match &installed {
            Some(installed) => Some(self.entry_text(installed).ok()?),
            None => None,
        };
        let parent = panel.conversation.version(version.parent_id.as_deref()).map(|parent| parent.source.as_str());
        let summary = parent.and_then(|parent| AiSourceDiff::summary(parent, &version.source));
        let note = panel.conversation.turns.iter().rfind(|turn| turn.version_id.as_deref() == Some(version.id.as_str())).and_then(|turn| turn.note.clone()).unwrap_or_default();
        Some(Proposal {
            version: version.number,
            note,
            source: version.source.clone(),
            added: summary.map_or(0, |summary| summary.added),
            removed: summary.map_or(0, |summary| summary.removed),
            lines: parent.and_then(|parent| AiSourceDiff::lines(parent, &version.source)),
            domains: version.network_domains.clone(),
            new_hosts: AiCandidates::new_hosts(installed.as_ref(), &version.network_domains),
            applied: held.as_deref() == Some(version.source.as_str()),
        })
    }

    /// Shows the version before (`step` below zero) or after the current one. Nothing is sent to
    /// the provider and the widget is not changed; the version shown is what "Apply" writes, what
    /// a draft is saved as, and what the next request works on, as on Apple and Android.
    /// Returns whether another version is shown now.
    pub fn step_version(&self, panel: &mut AiPanel, step: i32) -> bool {
        if panel.is_running() {
            return false;
        }
        let Some(current) = panel.conversation.current_version().map(|version| version.number) else { return false };
        let numbers = panel.conversation.versions.iter().map(|version| (version.number, version.id.clone()));
        let next = if step < 0 { numbers.filter(|(number, _)| *number < current).max() } else { numbers.filter(|(number, _)| *number > current).min() };
        let Some((_, id)) = next else { return false };
        panel.conversation.select_version(&id, now_milliseconds());
        if panel.conversation.turns.iter().any(|turn| !turn.is_manual_edit) {
            self.conversations.save(&panel.conversation);
        }
        panel.proposal = self.proposal(panel);
        true
    }

    /// Starts a new conversation from the current version: same widget, size and Skills, one
    /// version, no earlier turn to send. The way out when a conversation has grown heavy. The old
    /// conversation stays a file; the new one is the widget's newest, so it is the one that opens.
    pub fn start_over(&self, panel: &mut AiPanel) -> Result<(), StudioError> {
        if panel.is_running() {
            return Err(StudioError("A request is still running.".into()));
        }
        // Later than the one it comes from, also within the same millisecond.
        let now = now_milliseconds().max(panel.conversation.updated_at + 1);
        let next = panel.conversation.continued_from_current_version(now).ok_or_else(|| StudioError("There is no version to start from.".into()))?;
        if !self.conversations.save(&next) {
            return Err(StudioError("The new conversation could not be saved.".into()));
        }
        panel.conversation = next;
        panel.proposal = None;
        Ok(())
    }

    // The Skills of a conversation

    /// Every Skill there is, with whether the next turn of this conversation is sent with it:
    /// the conversation's own choice, or without one the Skills that are turned on.
    pub fn skill_choices(&self, panel: &AiPanel) -> Vec<SkillChoice> {
        let store = self.studio.skill_store();
        let chosen: Vec<String> = store.skills_for(panel.conversation.skill_ids.as_deref()).into_iter().map(|skill| skill.id).collect();
        store.list().into_iter().map(|skill| SkillChoice { chosen: chosen.contains(&skill.id), id: skill.id, title: skill.title }).collect()
    }

    /// Adds a Skill to the conversation or takes it out. The first change makes the Skills that
    /// are turned on the conversation's own choice; from then on the Skills page does not change it.
    pub fn toggle_skill(&self, panel: &mut AiPanel, id: &str) -> Result<(), StudioError> {
        let store = self.studio.skill_store();
        if store.find(id).is_none() {
            return Err(StudioError("That Skill is no longer here.".into()));
        }
        let mut chosen: Vec<String> = store.skills_for(panel.conversation.skill_ids.as_deref()).into_iter().map(|skill| skill.id).collect();
        match chosen.iter().position(|known| known == id) {
            Some(at) => drop(chosen.remove(at)),
            None => chosen.push(id.to_owned()),
        }
        panel.conversation.choose_skills(chosen.iter().map(String::as_str), now_milliseconds());
        self.save_choice(panel);
        Ok(())
    }

    /// Gives the choice back to the Skills page: the conversation follows the Skills that are turned on again.
    pub fn follow_enabled_skills(&self, panel: &mut AiPanel) {
        panel.conversation.skill_ids = None;
        panel.conversation.updated_at = now_milliseconds();
        self.save_choice(panel);
    }

    /// A conversation of a widget keeps its choice at once; a draft is a file from its first request on.
    fn save_choice(&self, panel: &AiPanel) {
        if !panel.is_draft() || !panel.conversation.turns.is_empty() {
            self.conversations.save(&panel.conversation);
        }
    }

    // The proposed version at every size

    /// What to draw to show the current version at the sizes the widget has (a widget that does
    /// not exist yet: at all four), without writing anything: the size's name and the request for
    /// [`Studio::preview`]. Empty without a version.
    pub fn size_previews(&self, panel: &AiPanel, dark: bool, scale: f32) -> Vec<(String, PreviewRequest)> {
        let Some(version) = panel.conversation.current_version() else { return Vec::new() };
        let families: Vec<&'static str> = match self.installed_of(panel) {
            Ok(Some(installed)) => installed.families(),
            Ok(None) => AiWidgetSize::ALL.iter().map(|size| size.family()).collect(),
            Err(_) => return Vec::new(),
        };
        let source = PreviewSource::Candidate { widget: panel.widget.clone(), source: version.source.clone(), domains: version.network_domains.clone() };
        families.into_iter().map(|family| (family.to_owned(), PreviewRequest { source: source.clone(), family: family.to_owned(), dark, scale })).collect()
    }

    // Applying and saving

    /// Writes the proposed version into the widget. Hosts the widget may not contact yet are
    /// added only with `allow_new_hosts`; without it nothing is changed and the hosts are returned.
    pub fn apply(&self, panel: &mut AiPanel, allow_new_hosts: bool) -> Result<Applied, StudioError> {
        if panel.is_running() {
            return Err(StudioError("A request is still running.".into()));
        }
        let version = panel.conversation.current_version().cloned().ok_or_else(|| StudioError("There is nothing to apply.".into()))?;
        let installed = self.installed_of(panel)?.ok_or_else(|| StudioError("This widget does not exist yet: save it as a new widget.".into()))?;
        let new_hosts = AiCandidates::new_hosts(Some(&installed), &version.network_domains);
        if !new_hosts.is_empty() && !allow_new_hosts {
            return Ok(Applied::NeedsConsent(new_hosts));
        }
        let applied = AiCandidates::apply(self.studio.library(), &installed, &version)?;
        if let Some(proposal) = &mut panel.proposal {
            proposal.applied = true;
            proposal.new_hosts.clear();
        }
        Ok(Applied::Done { path: AiCandidates::entry_of(&applied), source: version.source })
    }

    /// The name a draft is offered to be saved under: its title when that can be a name.
    pub fn suggested_name(panel: &AiPanel) -> String {
        AiCandidates::suggested_name(&panel.conversation.title)
    }

    /// Saves the current version of a draft as a new widget named `name` (a taken name gets a
    /// numbered suffix) and ties the conversation to it. A version that declares hosts is saved
    /// only with `allow_hosts`: the hosts are the model's choice, so the user is asked first, as
    /// the Save dialog of the Android app and `--allow-new-hosts` of the command line do.
    pub fn save_new(&self, panel: &mut AiPanel, name: &str, allow_hosts: bool) -> Result<Saved, StudioError> {
        if panel.is_running() {
            return Err(StudioError("A request is still running.".into()));
        }
        if !panel.is_draft() {
            return Err(StudioError("This conversation already belongs to a widget.".into()));
        }
        let version = panel.conversation.current_version().cloned().ok_or_else(|| StudioError("There is nothing to save yet.".into()))?;
        let name = name.trim();
        if !sw_core::packages::names::is_valid(name) {
            return Err(StudioError("That cannot be a widget's name: no path separators, leading dot or control characters, at most 80 characters.".into()));
        }
        if !version.network_domains.is_empty() && !allow_hosts {
            return Ok(Saved::NeedsConsent(version.network_domains));
        }
        let installed = AiCandidates::save_new(self.studio.library(), name, &version)?;
        panel.conversation.package_id = Some(installed.installation.clone());
        panel.conversation.updated_at = now_milliseconds();
        self.conversations.save(&panel.conversation);
        panel.widget = Some(installed.name.clone());
        panel.proposal = self.proposal(panel);
        Ok(Saved::Done { name: installed.name })
    }

    /// The name of the variable a key for one run is given in, for the settings page to name.
    pub fn environment_key() -> &'static str {
        ENVIRONMENT_KEY
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::testing::{Scratch, studio};

    const KEY: &str = "sk-studio-SECRET-93ab";
    const WIDGET: &str = "$render(\n  <vstack frame=\"max\">\n    <text>Hello</text>\n  </vstack>\n);\n";

    /// Answers each request with the next scripted text, as the Messages API does without streaming, and records the requests.
    struct Scripted {
        replies: Mutex<Vec<Result<String, AiClientError>>>,
        requests: Mutex<Vec<AiHttpRequest>>,
        /// Cancels this when a request arrives, to stand for a user who stops a turn.
        cancel_on_request: Mutex<Option<AiPanel>>,
    }

    impl Scripted {
        fn new(replies: Vec<Result<String, AiClientError>>) -> Arc<Self> {
            Arc::new(Self { replies: Mutex::new(replies), requests: Mutex::default(), cancel_on_request: Mutex::default() })
        }

        fn texts(replies: &[&str]) -> Arc<Self> {
            Self::new(replies.iter().map(|reply| Ok(reply.to_string())).collect())
        }

        fn asked(&self, index: usize) -> String {
            let requests = self.requests.lock().unwrap();
            let body: serde_json::Value = serde_json::from_slice(requests[index].body.as_deref().unwrap()).unwrap();
            body["messages"].as_array().unwrap().last().unwrap()["content"].as_str().unwrap().to_owned()
        }

        fn count(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    impl AiTransport for Scripted {
        fn execute(&self, request: &AiHttpRequest, _: &AiCancellation) -> Result<AiHttpResponse, AiClientError> {
            self.requests.lock().unwrap().push(request.clone());
            if request.method == "GET" {
                // What an endpoint lists; never sorted, and with what is not a model's name.
                return Ok(AiHttpResponse::new(200, r#"{"data":[{"id":"model-b"},{"id":"model-a"},{"id":""},{"name":"no id"},{"id":"model-b"}]}"#));
            }
            if let Some(panel) = self.cancel_on_request.lock().unwrap().as_ref() {
                panel.cancel();
            }
            let mut replies = self.replies.lock().unwrap();
            let reply = if replies.len() > 1 { replies.remove(0) } else { replies[0].clone() };
            reply.map(|text| AiHttpResponse::new(200, serde_json::json!({ "content": [{ "type": "text", "text": text }], "usage": { "input_tokens": 50, "output_tokens": 20 } }).to_string()))
        }
    }

    fn reply(note: &str, code: &str) -> String {
        format!("SUMMARY: {note}\n```jsx\n{code}\n```")
    }

    struct Fixture {
        service: AiService,
        studio: Arc<Studio>,
        credentials: Arc<MemoryCredentialStore>,
        transport: Arc<Scripted>,
        widget: String,
    }

    fn fixture(scratch: &Scratch, transport: Arc<Scripted>) -> Fixture {
        let studio = Arc::new(studio(scratch));
        let widget = studio.new_widget("Greeting").unwrap();
        studio.save_text(&widget, "main.jsx", WIDGET).unwrap();
        let credentials = Arc::new(MemoryCredentialStore::new());
        credentials.save("anthropic", &ApiKey::new(KEY).unwrap()).unwrap();
        let service = AiService::with_parts(studio.clone(), credentials.clone(), transport.clone(), None);
        Fixture { service, studio, credentials, transport, widget }
    }

    impl Fixture {
        /// One whole turn on this thread; returns the events the panel was given.
        fn turn(&self, panel: &mut AiPanel, request: &str) -> Vec<AgentLoopEvent> {
            let job = self.service.start(panel, request, false, "medium", false).unwrap();
            let mut events = Vec::new();
            let outcome = self.service.run(&job, &mut |event| events.push(event.clone()));
            for event in &events {
                panel.event(&job.turn_id, event);
            }
            self.service.finish(panel, &job.turn_id, &outcome);
            events
        }

        fn saved(&self) -> String {
            self.studio.read_text(&self.widget, "main.jsx").unwrap().unwrap()
        }
    }

    fn files_below(folder: &std::path::Path, found: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
            if entry.path().is_dir() { files_below(&entry.path(), found) } else { found.push(entry.path()) }
        }
    }

    #[test]
    fn the_skills_that_are_on_are_added_to_the_request_from_the_next_turn() {
        let scratch = Scratch::new("ai-skills");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Says hello.", WIDGET)]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "say hello");
        assert!(!fixture.transport.asked(0).contains("ScriptWidget skills"), "no Skill is on at first");

        // Switched on in the middle of the conversation, a Skill applies from the next turn.
        let skills = crate::skills::Skills::new(fixture.studio.clone());
        skills.set_enabled("accessible-design", true).unwrap();
        fixture.turn(&mut panel, "larger text");
        let asked = fixture.transport.asked(1);
        assert!(asked.contains("Apply these ScriptWidget skills") && asked.contains("- Accessible Design v1.0.0:") && asked.contains("larger text"), "{asked}");
        assert!(!asked.contains("Visual Polish"), "only what is on");

        skills.set_enabled("accessible-design", false).unwrap();
        fixture.turn(&mut panel, "and bold");
        assert!(!fixture.transport.asked(2).contains("ScriptWidget skills"));
        // A Skill is text in a request: the key is still only where it was.
        assert!(fixture.transport.requests.lock().unwrap().iter().all(|request| !String::from_utf8_lossy(request.body.as_deref().unwrap_or_default()).contains(KEY)));
    }

    #[test]
    fn the_service_and_a_job_cross_threads() {
        fn shared<T: Send + Sync>() {}
        fn sent<T: Send>() {}
        shared::<AiService>();
        sent::<TurnJob>();
    }

    #[test]
    fn a_turn_proposes_a_version_and_applying_writes_it() {
        let scratch = Scratch::new("ai-turn");
        let better = WIDGET.replace("<text>Hello</text>", "<text>Hello</text>\n    <text>World</text>");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Says World too.", better.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        assert!(panel.rows().iter().all(|row| row.manual_edit) && panel.proposal.is_none() && !panel.is_running());

        let events = fixture.turn(&mut panel, "also say World");
        assert!(events.iter().any(|event| matches!(event, AgentLoopEvent::Partial { .. })) && matches!(events.last(), Some(AgentLoopEvent::RanSucceeded { iteration: 1 })));
        let proposal = panel.proposal.clone().unwrap();
        assert_eq!((proposal.version, proposal.note.as_str(), proposal.added, proposal.removed, proposal.applied), (2, "Says World too.", 1, 0, false));
        assert!(proposal.new_hosts.is_empty());
        let lines = proposal.lines.unwrap();
        assert_eq!(lines.iter().filter(|line| line.kind == source_diff::Kind::Added).map(|line| line.text.as_str()).collect::<Vec<_>>(), ["    <text>World</text>"]);
        assert_eq!(fixture.saved(), WIDGET, "a proposal changes nothing");
        let row = panel.rows().pop().unwrap();
        assert_eq!((row.request.as_str(), row.status, row.detail.as_str(), row.version, row.manual_edit), ("also say World", Status::Succeeded, "Says World too.", Some(2), false));

        // What the model was sent: the saved code, and the key in the header only.
        assert!(fixture.transport.asked(0).contains(WIDGET.trim_end()) && fixture.transport.asked(0).contains("The user now asks:\nalso say World"));
        let request = fixture.transport.requests.lock().unwrap()[0].clone();
        assert_eq!(request.header("x-api-key"), Some(KEY));
        assert!(!String::from_utf8_lossy(request.body.as_deref().unwrap()).contains(KEY));

        assert_eq!(fixture.service.apply(&mut panel, false).unwrap(), Applied::Done { path: "main.jsx".into(), source: better.clone() });
        assert_eq!(fixture.saved(), better);
        assert!(panel.proposal.as_ref().unwrap().applied);

        // The conversation is a file: opened again, it has the turn and nothing new to adopt.
        let again = fixture.service.open(&fixture.widget).unwrap();
        assert_eq!(again.conversation.id, panel.conversation.id);
        assert_eq!(again.rows().len(), panel.rows().len());
        assert_eq!(again.conversation.current_version().unwrap().source, better);
    }

    #[test]
    fn the_reply_is_shown_while_it_is_written_and_a_repair_starts_over() {
        let scratch = Scratch::new("ai-events");
        let fixture = fixture(&scratch, Scripted::texts(&["unused"]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        let job = fixture.service.start(&mut panel, "x", false, "large", true).unwrap();
        assert_eq!(panel.conversation.size, AiWidgetSize::Large, "the turn is for the size the preview shows");
        let id = job.turn_id.clone();
        let running = |panel: &AiPanel| panel.running.clone().unwrap();
        assert_eq!((running(&panel).phase, running(&panel).attempt, running(&panel).limit), (Phase::Thinking, 1, AiConversationLimits::MAX_ATTEMPTS_PER_TURN), "attempt 1 of the attempts a turn has");
        panel.event(&id, &AgentLoopEvent::Partial { iteration: 1, text: "SUMMARY: A\n```jsx\n$render(".into() });
        assert_eq!((running(&panel).phase, running(&panel).code()), (Phase::Writing, "$render("));
        panel.event(&id, &AgentLoopEvent::Running { iteration: 1 });
        assert_eq!(running(&panel).phase, Phase::Running);
        panel.event(&id, &AgentLoopEvent::RanFailed { iteration: 1, error_summary: "scriptException: x".into(), logs: Vec::new() });
        panel.event(&id, &AgentLoopEvent::Thinking { iteration: 2 });
        assert_eq!((running(&panel).phase, running(&panel).attempt, running(&panel).reply.as_str()), (Phase::Repairing, 2, ""));
        assert_eq!(panel.conversation.turn(&id).unwrap().repairs, 1);
        // An event of another turn, and one after the turn ended, change nothing.
        panel.event("another-turn", &AgentLoopEvent::Running { iteration: 9 });
        assert_eq!(running(&panel).phase, Phase::Repairing);
        fixture.service.finish(&mut panel, "another-turn", &AgentLoopOutcome::Cancelled { usage: AiTokenUsage::ZERO });
        assert!(panel.is_running());
        fixture.service.finish(&mut panel, &id, &AgentLoopOutcome::Cancelled { usage: AiTokenUsage::ZERO });
        assert!(!panel.is_running() && panel.proposal.is_none());
        panel.event(&id, &AgentLoopEvent::Running { iteration: 3 });
        assert!(panel.running.is_none());
        assert_eq!(panel.rows().pop().unwrap().status, Status::Cancelled);
    }

    #[test]
    fn a_turn_that_does_not_run_changes_nothing_and_says_why() {
        let scratch = Scratch::new("ai-fail");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Tried.", "$render(<vstack><text>a</text></vstac>);")]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "break it");
        assert_eq!(fixture.transport.count() as i32, AiConversationLimits::MAX_ATTEMPTS_PER_TURN);
        let row = panel.rows().pop().unwrap();
        assert_eq!((row.status, row.repairs, row.version), (Status::Unconverged, 4, None));
        assert!(row.detail.starts_with("scriptException: SyntaxError"), "{}", row.detail);
        assert!(panel.proposal.is_none());
        assert_eq!(fixture.saved(), WIDGET);
        assert!(matches!(fixture.service.apply(&mut panel, true), Ok(Applied::Done { .. })), "applying puts back what the widget has: the current version is still its own code");
        assert_eq!(fixture.saved(), WIDGET);

        // A provider that refuses: its sentence is shown, and the key is not in it.
        let refused = Scripted::new(vec![Err(AiClientError::with_status(AiErrorKind::Http, "The AI server rejected authentication. Check this profile's API key.", 401))]);
        let scratch = Scratch::new("ai-refused");
        let fixture = self::fixture(&scratch, refused);
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "anything");
        let row = panel.rows().pop().unwrap();
        assert_eq!((row.status, row.detail.as_str()), (Status::Failed, "The AI server rejected authentication. Check this profile's API key."));
    }

    #[test]
    fn stopping_a_turn_ends_it_without_a_version() {
        let scratch = Scratch::new("ai-cancel");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Done.", WIDGET.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        let versions = panel.conversation.versions.len();
        let job = fixture.service.start(&mut panel, "x", false, "medium", false).unwrap();
        // The user stops the turn while the model is being asked.
        *fixture.transport.cancel_on_request.lock().unwrap() = Some(panel.clone());
        let outcome = fixture.service.run(&job, &mut |_| {});
        assert!(matches!(outcome, AgentLoopOutcome::Cancelled { .. }), "{outcome:?}");
        fixture.service.finish(&mut panel, &job.turn_id, &outcome);
        assert_eq!(panel.rows().pop().unwrap().status, Status::Cancelled);
        assert_eq!(panel.conversation.versions.len(), versions);
        assert!(panel.proposal.is_none() && !panel.is_running());
        assert_eq!(fixture.saved(), WIDGET);
    }

    #[test]
    fn new_hosts_are_added_only_when_the_user_agrees() {
        let scratch = Scratch::new("ai-hosts");
        let online = format!("let text = 'offline';\ntry {{ text = await fetch('https://api.example.com/x'); }} catch (error) {{}}\n{}", WIDGET.trim_end());
        let answer = format!("{}\n```json\n{{\"permissions\":[\"network\"],\"networkDomains\":[\"api.example.com\"]}}\n```", reply("Asks the network.", &online));
        let fixture = fixture(&scratch, Scripted::texts(&[&answer]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "ask the network");
        assert_eq!(panel.proposal.as_ref().unwrap().new_hosts, ["api.example.com"]);
        let manifest = fixture.studio.read_text(&fixture.widget, "widget.json").unwrap().unwrap();
        assert_eq!(fixture.service.apply(&mut panel, false).unwrap(), Applied::NeedsConsent(vec!["api.example.com".into()]));
        assert_eq!((fixture.saved(), fixture.studio.read_text(&fixture.widget, "widget.json").unwrap().unwrap()), (WIDGET.to_owned(), manifest), "nothing was changed");
        assert!(matches!(fixture.service.apply(&mut panel, true).unwrap(), Applied::Done { .. }));
        assert!(fixture.saved().contains("api.example.com/x"));
        let manifest: serde_json::Value = serde_json::from_str(&fixture.studio.read_text(&fixture.widget, "widget.json").unwrap().unwrap()).unwrap();
        assert_eq!((&manifest["permissions"], &manifest["networkDomains"]), (&serde_json::json!(["network"]), &serde_json::json!(["api.example.com"])));
        assert!(panel.proposal.as_ref().unwrap().new_hosts.is_empty() && panel.proposal.as_ref().unwrap().applied);
    }

    #[test]
    fn a_turn_does_not_start_without_what_it_needs() {
        let scratch = Scratch::new("ai-start");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("x", WIDGET.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        let refused = |panel: &mut AiPanel, request: &str, unsaved: bool| fixture.service.start(panel, request, unsaved, "medium", false).err().map(|error| error.0);
        assert_eq!(refused(&mut panel, "   ", false).as_deref(), Some("Say what to change."));
        assert!(refused(&mut panel, "x", true).unwrap().contains("Save your changes first"));
        fixture.credentials.remove("anthropic").unwrap();
        let no_key = refused(&mut panel, "x", false).unwrap();
        assert!(no_key.contains("No API key is stored for Anthropic") && no_key.contains("Settings"), "{no_key}");
        assert!(!panel.is_running() && fixture.transport.count() == 0, "nothing was sent");
        assert!(panel.conversation.turns.iter().all(|turn| turn.is_manual_edit), "and no turn was begun");

        fixture.credentials.save("anthropic", &ApiKey::new(KEY).unwrap()).unwrap();
        fixture.service.start(&mut panel, "x", false, "medium", false).unwrap();
        assert_eq!(refused(&mut panel, "y", false).as_deref(), Some("A request is still running."));
        assert!(fixture.service.apply(&mut panel, true).is_err(), "nothing is applied while a turn runs");
        assert!(fixture.service.open("No Such Widget").is_err());

        // Without a keyring the turn does not start, and the sentence says where the key would have been.
        let scratch = Scratch::new("ai-no-keyring");
        let studio = Arc::new(studio(&scratch));
        let widget = studio.new_widget("Lonely").unwrap();
        let service = AiService::with_parts(studio.clone(), Arc::new(MemoryCredentialStore::unavailable()), Scripted::texts(&["x"]), None);
        let mut panel = service.open(&widget).unwrap();
        assert!(service.start(&mut panel, "x", false, "medium", false).err().unwrap().0.contains("keyring"));
        assert!(matches!(service.key_status(AiProviderKind::Anthropic), KeyStatus::Unavailable(_)));
        assert!(service.store_key(AiProviderKind::Anthropic, KEY).unwrap_err().0.contains("Nothing was stored"));
        // The key of one run works without a keyring.
        let service = AiService::with_parts(studio, Arc::new(MemoryCredentialStore::unavailable()), Scripted::texts(&["x"]), Some(ApiKey::new(KEY).unwrap()));
        assert_eq!(service.key_status(AiProviderKind::Anthropic), KeyStatus::ForThisRun);
        assert!(service.start(&mut service.open(&widget).unwrap(), "x", false, "medium", false).is_ok());
    }

    #[test]
    fn code_saved_in_the_editor_is_what_the_next_turn_starts_from() {
        let scratch = Scratch::new("ai-adopt");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("One.", WIDGET.replace("Hello", "One").trim_end()), &reply("Two.", WIDGET.replace("Hello", "Two").trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "say One");
        // The user does not apply it, and edits the widget by hand instead.
        let by_hand = WIDGET.replace("Hello", "By hand");
        fixture.studio.save_text(&fixture.widget, "main.jsx", &by_hand).unwrap();
        fixture.turn(&mut panel, "say Two");
        let asked = fixture.transport.asked(1);
        assert!(asked.contains("By hand") && asked.contains("Current working widget code"), "{asked}");
        assert!(panel.rows().iter().any(|row| row.manual_edit));
        assert_eq!(panel.proposal.as_ref().unwrap().removed, 1);
    }

    #[test]
    fn the_profile_and_the_key_are_set_and_no_file_holds_the_key() {
        let scratch = Scratch::new("ai-settings");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("x", WIDGET.trim_end())]));
        let service = &fixture.service;
        assert_eq!(service.settings().profile, AiProfile::defaults(AiProviderKind::Anthropic));
        for (url, model) in [("http://localhost:11434", "llama3"), ("https://key@api.example.com", "m"), ("https://api.example.com", " ")] {
            assert!(service.save_profile(AiProviderKind::OpenAiCompatible, url, model).is_err(), "{url}");
        }
        assert!(service.save_profile(AiProviderKind::OpenAiCompatible, "http://localhost:11434", "llama3").unwrap_err().0.contains("https://"));
        let saved = service.save_profile(AiProviderKind::OpenAiCompatible, "https://ollama.lan:8443/v1/", "llama3").unwrap();
        assert_eq!(saved.profile, AiProfile::new(AiProviderKind::OpenAiCompatible, "https://ollama.lan:8443", "llama3"));

        assert_eq!(service.key_status(AiProviderKind::OpenAiCompatible), KeyStatus::Missing);
        assert!(service.store_key(AiProviderKind::OpenAiCompatible, "two\nlines").is_err());
        service.store_key(AiProviderKind::OpenAiCompatible, &format!(" {KEY}\n")).unwrap();
        assert_eq!(service.key_status(AiProviderKind::OpenAiCompatible), KeyStatus::Stored);
        assert_eq!(fixture.credentials.load("custom").unwrap().unwrap().expose(), KEY);

        // A whole turn with that key, then every file below the scratch folder is read.
        let mut panel = service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "anything");
        let request = fixture.transport.requests.lock().unwrap()[0].clone();
        assert_eq!((request.url.as_str(), request.header("Authorization")), ("https://ollama.lan:8443/v1/chat/completions", Some(format!("Bearer {KEY}").as_str())));
        let mut files = Vec::new();
        files_below(scratch.root(), &mut files);
        assert!(files.iter().any(|file| file.ends_with("ai-profile.json")) && files.iter().any(|file| file.to_string_lossy().contains("AiConversations")));
        for file in files {
            assert!(!String::from_utf8_lossy(&std::fs::read(&file).unwrap()).contains(KEY), "{} holds the key", file.display());
        }
        assert!(!format!("{:?} {:?}", panel, service.settings()).contains(KEY));

        assert!(service.remove_key(AiProviderKind::OpenAiCompatible).unwrap());
        assert_eq!(service.key_status(AiProviderKind::OpenAiCompatible), KeyStatus::Missing);
    }

    fn unauthorized() -> AiClientError {
        AiClientError::with_status(AiErrorKind::Http, "The AI server rejected authentication. Check this profile's API key.", 401)
    }

    #[test]
    fn a_request_that_failed_is_sent_again_from_the_version_it_started_from() {
        let scratch = Scratch::new("ai-retry");
        let one = WIDGET.replace("Hello", "One");
        let two = one.replace("<text>One</text>", "<text>One</text>\n    <text>Two</text>");
        let fixture = fixture(&scratch, Scripted::new(vec![Ok(reply("One.", one.trim_end())), Err(unauthorized()), Ok(reply("Two.", two.trim_end()))]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "say One");
        fixture.service.apply(&mut panel, false).unwrap();
        assert!(panel.rows().iter().all(|row| !row.can_retry), "a turn that ran is not sent again");
        fixture.turn(&mut panel, "also say Two");
        let failed = panel.rows().pop().unwrap();
        assert_eq!((failed.status, failed.can_retry, failed.request.as_str()), (Status::Failed, true, "also say Two"));
        assert_eq!(panel.conversation.turn(&failed.id).unwrap().base_version_id, panel.conversation.current_version_id);

        // The user looks at the version before, and types in the editor without saving: neither matters.
        assert!(fixture.service.step_version(&mut panel, -1));
        assert_eq!(panel.conversation.current_version().unwrap().source, WIDGET);
        assert_eq!(fixture.service.retry(&mut panel, "no-such-turn", false).err().unwrap().0, "That request cannot be sent again.");
        let job = fixture.service.retry(&mut panel, &failed.id, false).unwrap();
        assert!(panel.rows().iter().all(|row| row.id != failed.id && !row.can_retry), "the new turn takes its place, and nothing is sent again while it runs");
        assert_eq!(fixture.service.retry(&mut panel, &job.turn_id, false).err().unwrap().0, "A request is still running.");
        assert_eq!(panel.conversation.current_version().unwrap().source, one, "the version the failed turn started from is the current one again");
        let outcome = fixture.service.run(&job, &mut |_| {});
        fixture.service.finish(&mut panel, &job.turn_id, &outcome);

        let asked = fixture.transport.asked(2);
        assert!(asked.contains(&format!("Current working widget code:\n\n```jsx\n{one}")) && asked.contains("The user now asks:\nalso say Two"), "{asked}");
        let proposal = panel.proposal.clone().unwrap();
        assert_eq!((proposal.version, proposal.added, proposal.removed, proposal.applied), (3, 1, 0, false));
        let row = panel.rows().pop().unwrap();
        assert_eq!((row.status, row.request.as_str(), row.version, row.can_retry), (Status::Succeeded, "also say Two", Some(3), false));
        assert_eq!(panel.rows().iter().filter(|row| !row.manual_edit).count(), 2);
        assert_eq!(fixture.saved(), one, "nothing is written until it is applied");
        assert_eq!(fixture.service.retry(&mut panel, &job.turn_id, false).err().unwrap().0, "That request cannot be sent again.");
    }

    #[test]
    fn changed_lines_are_those_against_the_version_before_and_versions_are_stepped_through() {
        let scratch = Scratch::new("ai-versions");
        let world = WIDGET.replace("<text>Hello</text>", "<text>Hello</text>\n    <text>World</text>");
        let hi = world.replace("Hello", "Hi");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Says World too.", world.trim_end()), &reply("Says Hi.", hi.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        assert_eq!(panel.version_place(), Some(VersionPlace { number: 1, latest: 1, has_previous: false, has_next: false }));
        assert!(!fixture.service.step_version(&mut panel, -1) && !fixture.service.step_version(&mut panel, 1));
        fixture.turn(&mut panel, "also say World");
        fixture.service.apply(&mut panel, false).unwrap();
        fixture.turn(&mut panel, "say Hi");
        // The third version next to the second, which the widget holds.
        let third = panel.proposal.clone().unwrap();
        assert_eq!((third.version, third.added, third.removed, third.applied), (3, 1, 1, false));
        assert_eq!(panel.version_place(), Some(VersionPlace { number: 3, latest: 3, has_previous: true, has_next: false }));

        // The second version is what the widget holds, and is still shown as what it changed: one line more than the first.
        assert!(fixture.service.step_version(&mut panel, -1));
        let second = panel.proposal.clone().unwrap();
        assert_eq!((second.version, second.note.as_str(), second.added, second.removed, second.applied), (2, "Says World too.", 1, 0, true));
        assert_eq!(second.lines.unwrap().iter().filter(|line| line.kind == source_diff::Kind::Added).map(|line| line.text.as_str()).collect::<Vec<_>>(), ["    <text>World</text>"]);
        assert_eq!(panel.version_place(), Some(VersionPlace { number: 2, latest: 3, has_previous: true, has_next: true }));

        // The first version has none before it: its code is shown, not a comparison.
        assert!(fixture.service.step_version(&mut panel, -1));
        let first = panel.proposal.clone().unwrap();
        assert_eq!((first.version, first.added, first.removed, first.lines, first.applied, first.source.as_str()), (1, 0, 0, None, false, WIDGET));
        assert!(!fixture.service.step_version(&mut panel, -1), "there is no version before the first");
        assert_eq!(fixture.saved(), world, "looking at a version writes nothing");
        // The version shown is the one that is applied.
        assert!(matches!(fixture.service.apply(&mut panel, false).unwrap(), Applied::Done { .. }));
        assert_eq!(fixture.saved(), WIDGET);
        assert!(fixture.service.step_version(&mut panel, 1) && fixture.service.step_version(&mut panel, 1) && !fixture.service.step_version(&mut panel, 1));
        assert_eq!(panel.proposal.as_ref().unwrap().version, 3);

        // Not while a request runs.
        let job = fixture.service.start(&mut panel, "x", false, "medium", false).unwrap();
        assert!(!fixture.service.step_version(&mut panel, -1));
        fixture.service.finish(&mut panel, &job.turn_id, &AgentLoopOutcome::Cancelled { usage: AiTokenUsage::ZERO });
    }

    #[test]
    fn a_conversation_that_has_grown_starts_over_from_its_current_version() {
        let scratch = Scratch::new("ai-start-over");
        let one = WIDGET.replace("Hello", "One");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("One.", one.trim_end()), &reply("Two.", WIDGET.replace("Hello", "Two").trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "say One");
        fixture.service.apply(&mut panel, false).unwrap();
        assert_eq!(panel.advice(), None);
        // A turn that sent a great deal: the notice appears, and with it the way out.
        panel.conversation.turns.last_mut().unwrap().usage = AiTokenUsage::new(AiConversationLimits::HEAVY_PROMPT_TOKENS, 10, AiConversationLimits::HEAVY_PROMPT_TOKENS + 10);
        assert!(panel.advice().unwrap().contains("A new conversation from this version sends less."));
        fixture.service.toggle_skill(&mut panel, "visual-polish").unwrap();
        let old = panel.conversation.id.clone();

        fixture.service.start_over(&mut panel).unwrap();
        assert_ne!(panel.conversation.id, old);
        assert_eq!((panel.conversation.versions.len(), panel.conversation.turns.len(), panel.conversation.current_version().unwrap().source.as_str()), (1, 0, one.as_str()));
        assert_eq!((panel.advice(), panel.proposal.clone(), panel.widget.as_deref()), (None, None, Some(fixture.widget.as_str())));
        assert_eq!(panel.conversation.skill_ids.as_deref(), Some(&["visual-polish".to_owned()][..]), "the Skills of the conversation come along");
        assert!(panel.is_empty());
        assert_eq!(fixture.saved(), one, "the widget is not touched");
        // It is the widget's conversation from now on, and the next request has nothing earlier to send.
        assert_eq!(fixture.service.open(&fixture.widget).unwrap().conversation.id, panel.conversation.id);
        fixture.turn(&mut panel, "say Two");
        let asked = fixture.transport.asked(1);
        assert!(asked.contains(&format!("Current working widget code:\n\n```jsx\n{one}")) && !asked.contains("Earlier turns") && !asked.contains("say One"), "{asked}");
        assert_eq!(panel.proposal.as_ref().unwrap().version, 2);
        // The conversation it came from is still a file.
        let files = std::fs::read_dir(scratch.path("data/AiConversations")).unwrap().count();
        assert_eq!(files, 2);

        // Nothing to start from, and not while a request runs.
        assert!(fixture.service.start_over(&mut fixture.service.new_draft()).is_err());
        let job = fixture.service.start(&mut panel, "x", false, "medium", false).unwrap();
        assert_eq!(fixture.service.start_over(&mut panel).unwrap_err().0, "A request is still running.");
        fixture.service.finish(&mut panel, &job.turn_id, &AgentLoopOutcome::Cancelled { usage: AiTokenUsage::ZERO });
    }

    #[test]
    fn a_conversation_has_skills_of_its_own_once_they_are_chosen_in_it() {
        let scratch = Scratch::new("ai-own-skills");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Says hello.", WIDGET.trim_end())]));
        let skills = crate::skills::Skills::new(fixture.studio.clone());
        skills.set_enabled("accessible-design", true).unwrap();
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        let chosen = |panel: &AiPanel| fixture.service.skill_choices(panel).into_iter().filter(|choice| choice.chosen).map(|choice| choice.id).collect::<Vec<String>>();
        assert_eq!(fixture.service.skill_choices(&panel).len(), skills.rows().len(), "every Skill can be chosen");
        assert_eq!((chosen(&panel), panel.conversation.skill_ids.clone()), (vec!["accessible-design".to_owned()], None), "without a choice the conversation follows the Skills page");

        // The first choice starts from what is on; from then on the Skills page does not change it.
        fixture.service.toggle_skill(&mut panel, "visual-polish").unwrap();
        assert_eq!(panel.conversation.skill_ids.as_deref(), Some(&["accessible-design".to_owned(), "visual-polish".to_owned()][..]));
        fixture.service.toggle_skill(&mut panel, "accessible-design").unwrap();
        skills.set_enabled("responsive-layout", true).unwrap();
        assert_eq!(chosen(&panel), ["visual-polish"]);
        assert_eq!(skills.in_effect().len(), 2, "choosing in a conversation turns nothing on or off");
        fixture.turn(&mut panel, "say hello");
        let asked = fixture.transport.asked(0);
        assert!(asked.contains("- Visual Polish v1.0.0:") && !asked.contains("Accessible Design") && !asked.contains("Responsive Layout"), "{asked}");
        assert_eq!(fixture.service.open(&fixture.widget).unwrap().conversation.skill_ids, panel.conversation.skill_ids, "the choice is in the conversation's file");

        // No Skill is a choice too.
        fixture.service.toggle_skill(&mut panel, "visual-polish").unwrap();
        assert_eq!(panel.conversation.skill_ids, Some(Vec::new()));
        fixture.turn(&mut panel, "again");
        assert!(!fixture.transport.asked(1).contains("ScriptWidget skills"));
        assert!(fixture.service.toggle_skill(&mut panel, "no.such.skill").is_err());
        // Given back, the conversation follows the Skills page again.
        fixture.service.follow_enabled_skills(&mut panel);
        assert_eq!((panel.conversation.skill_ids.clone(), chosen(&panel).len()), (None, 2));
        fixture.turn(&mut panel, "once more");
        assert!(fixture.transport.asked(2).contains("- Accessible Design v1.0.0:") && fixture.transport.asked(2).contains("- Responsive Layout v1.0.0:"));
        assert_eq!(fixture.service.open(&fixture.widget).unwrap().conversation.skill_ids, None);
    }

    #[test]
    fn the_last_run_s_error_goes_to_the_model_when_fixing_it_is_asked_for() {
        let scratch = Scratch::new("ai-fix");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Fixed.", WIDGET.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        let fix = |panel: &mut AiPanel, typed: &str, diagnostic: &str| {
            let job = fixture.service.start_fix(panel, typed, diagnostic, false, "medium", false).unwrap();
            let outcome = fixture.service.run(&job, &mut |_| {});
            fixture.service.finish(panel, &job.turn_id, &outcome);
        };
        fix(&mut panel, "  ", "scriptException: ReferenceError: total is not defined");
        let asked = fixture.transport.asked(0);
        assert!(asked.contains("The latest local ScriptWidget runtime diagnostic is:\nscriptException: ReferenceError: total is not defined"), "{asked}");
        assert!(asked.contains(&format!("The user now asks:\n{FIX_REQUEST}")), "{asked}");
        assert_eq!(panel.rows().pop().unwrap().request, FIX_REQUEST);
        // What the user typed is asked instead, with the same report; an ordinary request carries none.
        fix(&mut panel, "use 0 when there is no total", "scriptException: boom");
        let asked = fixture.transport.asked(1);
        assert!(asked.contains("runtime diagnostic is:\nscriptException: boom") && asked.contains("The user now asks:\nuse 0 when there is no total"), "{asked}");
        fixture.turn(&mut panel, "larger");
        assert!(!fixture.transport.asked(2).contains("runtime diagnostic"));
        // Unsaved changes in the editor would be in neither the widget nor the conversation.
        assert!(fixture.service.start_fix(&mut panel, "", "scriptException: boom", true, "medium", false).err().unwrap().0.contains("Save your changes first"));
    }

    #[test]
    fn fixing_an_error_sends_the_last_ten_console_lines_of_the_failed_run() {
        let scratch = Scratch::new("ai-fix-logs");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Fixed.", WIDGET.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        // What the preview pane holds after a run that failed: the error, and what the script printed.
        let error = ("scriptException".to_owned(), "ReferenceError: total is not defined".to_owned());
        let mut logs: Vec<(String, String)> = (1..=11).map(|number| ("log".to_owned(), format!("line {number}"))).collect();
        logs.push(("error".to_owned(), "z".repeat(400)));
        let diagnostic = runtime_diagnostic(&error, &logs);
        assert!(diagnostic.starts_with("scriptException: ReferenceError: total is not defined\nLast console output:\n[log] line 3\n"), "{diagnostic}");
        assert!(diagnostic.ends_with(&format!("[error] {}…", "z".repeat(292))), "each line is cut as in a repair");
        assert_eq!(runtime_diagnostic(&error, &[]), "scriptException: ReferenceError: total is not defined", "a run that printed nothing sends the error alone");

        let job = fixture.service.start_fix(&mut panel, "", &diagnostic, false, "medium", false).unwrap();
        let outcome = fixture.service.run(&job, &mut |_| {});
        fixture.service.finish(&mut panel, &job.turn_id, &outcome);
        let asked = fixture.transport.asked(0);
        assert!(asked.contains("The latest local ScriptWidget runtime diagnostic is:\nscriptException: ReferenceError: total is not defined\nLast console output:\n[log] line 3\n"), "{asked}");
        assert!(asked.contains("[log] line 11\n[error] zzz") && !asked.contains("[log] line 2\n") && !asked.contains("[log] line 1\n"), "{asked}");
    }

    #[test]
    fn the_next_request_works_on_the_version_shown_and_applying_writes_it() {
        let scratch = Scratch::new("ai-shown");
        let one = WIDGET.replace("Hello", "One");
        let two = WIDGET.replace("Hello", "Two");
        let three = WIDGET.replace("Hello", "Three");
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("One.", one.trim_end()), &reply("Two.", two.trim_end()), &reply("Three.", three.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "say One");
        fixture.service.apply(&mut panel, false).unwrap();
        // A version that is made and not applied is what the next request works on: the widget still holds One.
        fixture.turn(&mut panel, "say Two");
        assert_eq!((fixture.saved(), panel.proposal.as_ref().unwrap().version), (one.clone(), 3));

        // Closed and opened again, the version that was not applied is still the one shown; nothing is taken over.
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        let shown = panel.proposal.clone().expect("the pending version is shown");
        assert_eq!((shown.version, shown.source.as_str(), shown.applied, panel.conversation.versions.len()), (3, two.as_str(), false, 3));
        assert!(panel.rows().iter().filter(|row| row.manual_edit).count() <= 1, "the widget's code was not adopted a second time");

        // The user steps back to the first version. The widget holds One, the panel shows the first.
        assert!(fixture.service.step_version(&mut panel, -1) && fixture.service.step_version(&mut panel, -1));
        assert_eq!((panel.proposal.as_ref().unwrap().version, panel.conversation.current_version().unwrap().source.as_str()), (1, WIDGET));
        let versions = panel.conversation.versions.len();
        fixture.turn(&mut panel, "say Three");
        let asked = fixture.transport.asked(2);
        assert!(asked.contains(&format!("Current working widget code:\n\n```jsx\n{}", WIDGET.trim_end())), "the turn starts from the version shown: {asked}");
        assert!(!asked.contains("<text>One</text>") && !asked.contains("<text>Two</text>"), "not from what the widget holds, nor from the newest version: {asked}");
        assert_eq!(panel.conversation.versions.len(), versions + 1, "only the new version was added");
        let turn = panel.conversation.turns.last().unwrap();
        assert_eq!(panel.conversation.version(turn.base_version_id.as_deref()).unwrap().source, WIDGET);
        let proposal = panel.proposal.clone().unwrap();
        assert_eq!((proposal.source.as_str(), proposal.added, proposal.removed, proposal.applied), (three.as_str(), 1, 1, false), "compared with the version it was made from");
        assert_eq!(fixture.saved(), one, "nothing was written");

        // Apply writes the version shown, whichever that is.
        assert!(fixture.service.step_version(&mut panel, -1));
        let shown = panel.conversation.current_version().unwrap().source.clone();
        assert_ne!(shown, three);
        assert!(matches!(fixture.service.apply(&mut panel, false).unwrap(), Applied::Done { .. }));
        assert_eq!(fixture.saved(), shown);

        // Code written by hand that the conversation has never seen is still taken over first.
        let by_hand = WIDGET.replace("Hello", "By hand");
        fixture.studio.save_text(&fixture.widget, "main.jsx", &by_hand).unwrap();
        fixture.turn(&mut panel, "anything");
        assert!(fixture.transport.asked(3).contains("By hand"));
    }

    #[test]
    fn the_proposed_version_is_drawn_at_every_size_without_being_written() {
        let scratch = Scratch::new("ai-sizes");
        let red = "$render(\n  <vstack frame=\"max\" background=\"#ff0000\">\n    <text>{$getenv(\"widget-size\")}</text>\n  </vstack>\n);\n";
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Red.", red.trim_end())]));
        let mut panel = fixture.service.open(&fixture.widget).unwrap();
        fixture.turn(&mut panel, "make it red");
        let wanted = fixture.service.size_previews(&panel, false, 1.0);
        let families = fixture.studio.widget(&fixture.widget).unwrap().families;
        assert!(families.len() >= 3, "{families:?}");
        assert_eq!(wanted.iter().map(|(family, _)| family.as_str()).collect::<Vec<_>>(), families, "the sizes the widget has");
        for (family, request) in &wanted {
            let result = fixture.studio.preview(request);
            assert_eq!(result.error, None, "{family}");
            let picture = result.picture.expect("a picture");
            let middle = ((picture.pixel_height / 2) * picture.pixel_width + 20) as usize * 4;
            assert_eq!(&picture.pixels[middle..middle + 4], [255, 0, 0, 255], "{family}: the proposed code was drawn, not the widget's");
            assert_eq!(picture.width > picture.height, matches!(family.as_str(), "medium" | "extraLarge"), "{family}");
        }
        assert_eq!(fixture.saved(), WIDGET, "drawing writes nothing");
        assert!(!scratch.path(&format!("data/Packages/{}/__Build", fixture.widget)).exists());

        // A widget that does not exist yet is drawn at all four sizes; without a version there is nothing to draw.
        let mut draft = fixture.service.new_draft();
        assert!(fixture.service.size_previews(&draft, false, 1.0).is_empty());
        fixture.turn(&mut draft, "a red widget");
        let wanted = fixture.service.size_previews(&draft, true, 2.0);
        assert_eq!(wanted.iter().map(|(family, _)| family.as_str()).collect::<Vec<_>>(), ["small", "medium", "large", "extraLarge"]);
        let small = fixture.studio.preview(&wanted[0].1).picture.unwrap();
        assert_eq!((small.pixel_width, small.pixel_height, small.width), (340, 340, 170.0));
        assert!(matches!(&wanted[0].1.source, PreviewSource::Candidate { widget: None, source, domains } if source == red && domains.is_empty()));
    }

    #[test]
    fn a_new_widget_is_made_from_a_description_and_saved_only_when_its_hosts_are_allowed() {
        let scratch = Scratch::new("ai-draft");
        let offline = WIDGET.replace("Hello", "12:00");
        let online = format!("let text = 'offline';\ntry {{ text = await fetch('https://api.example.com/x'); }} catch (error) {{}}\n{}", offline.trim_end());
        let answer = format!("{}\n```json\n{{\"permissions\":[\"network\"],\"networkDomains\":[\"api.example.com\"]}}\n```", reply("Asks the network.", &online));
        let fixture = fixture(&scratch, Scripted::texts(&[&reply("Shows the time.", offline.trim_end()), &answer]));
        let service = &fixture.service;
        let mut panel = service.new_draft();
        assert!(panel.is_draft() && panel.is_empty() && panel.proposal.is_none() && panel.version_place().is_none());
        assert!(service.save_new(&mut panel, "Clock", true).is_err(), "there is nothing to save yet");
        assert_eq!(std::fs::read_dir(scratch.path("data/AiConversations")).map(|entries| entries.count()).unwrap_or(0), 0, "a draft is no file until something is asked");

        // The size is the one chosen in the conversation; the editor's preview has no say.
        panel.conversation.size = AiWidgetSize::Small;
        let job = service.start(&mut panel, "a clock", false, "large", false).unwrap();
        let outcome = service.run(&job, &mut |_| {});
        service.finish(&mut panel, &job.turn_id, &outcome);
        let asked = fixture.transport.asked(0);
        assert!(asked.contains("The user asks for a new widget:\na clock") && asked.contains("Widget size: small") && !asked.contains("Current working widget code"), "{asked}");
        let proposal = panel.proposal.clone().unwrap();
        assert_eq!((proposal.version, proposal.note.as_str(), proposal.lines.clone(), proposal.applied, proposal.new_hosts.len()), (1, "Shows the time.", None, false, 0));
        assert_eq!(proposal.source, offline);
        assert_eq!(AiService::suggested_name(&panel), "a clock");
        assert_eq!(service.apply(&mut panel, true).unwrap_err().0, "This widget does not exist yet: save it as a new widget.");
        assert_eq!(fixture.studio.widgets().unwrap().len(), 1, "nothing was installed");

        // The second turn changes the draft, and its version declares a host.
        fixture.turn(&mut panel, "ask the network");
        assert!(fixture.transport.asked(1).contains(&format!("Current working widget code:\n\n```jsx\n{offline}")));
        let proposal = panel.proposal.clone().unwrap();
        assert_eq!((proposal.version, proposal.domains.clone(), proposal.new_hosts.clone()), (2, vec!["api.example.com".to_owned()], vec!["api.example.com".to_owned()]), "for a new widget every declared host is new");
        assert_eq!((proposal.lines.is_some(), proposal.added, proposal.removed), (true, 2, 0), "compared with the first version");

        for name in ["", "  ", "../escape", ".hidden", "a/b"] {
            assert!(service.save_new(&mut panel, name, true).unwrap_err().0.contains("cannot be a widget's name"), "{name:?}");
        }
        assert_eq!(service.save_new(&mut panel, "Greeting", false).unwrap(), Saved::NeedsConsent(vec!["api.example.com".into()]));
        assert_eq!(fixture.studio.widgets().unwrap().len(), 1, "nothing was saved without a yes");
        assert!(panel.is_draft() && panel.conversation.package_id.is_none());

        // With the yes it is a widget; a taken name gets a number, and the conversation belongs to it.
        assert_eq!(service.save_new(&mut panel, " Greeting ", true).unwrap(), Saved::Done { name: "Greeting (1)".into() });
        assert_eq!(panel.widget.as_deref(), Some("Greeting (1)"));
        assert_eq!(fixture.studio.read_text("Greeting (1)", "main.jsx").unwrap().unwrap(), format!("{online}\n"));
        let manifest: serde_json::Value = serde_json::from_str(&fixture.studio.read_text("Greeting (1)", "widget.json").unwrap().unwrap()).unwrap();
        assert_eq!((&manifest["name"], &manifest["permissions"], &manifest["networkDomains"]), (&serde_json::json!("Greeting (1)"), &serde_json::json!(["network"]), &serde_json::json!(["api.example.com"])));
        assert_eq!(fixture.saved(), WIDGET, "the widget that had the name is as it was");
        let proposal = panel.proposal.clone().unwrap();
        assert!(proposal.applied && proposal.new_hosts.is_empty());
        let reopened = service.open("Greeting (1)").unwrap();
        assert_eq!((reopened.conversation.id.as_str(), reopened.rows().len()), (panel.conversation.id.as_str(), 2), "the editor opens the same conversation");
        assert_eq!(service.save_new(&mut panel, "Again", true).unwrap_err().0, "This conversation already belongs to a widget.");

        // A widget that stays offline is saved without a question.
        let fixture = self::fixture(&Scratch::new("ai-draft-offline"), Scripted::texts(&[&reply("Shows the time.", offline.trim_end())]));
        let mut panel = fixture.service.new_draft();
        fixture.turn(&mut panel, "a clock for my desk");
        let name = AiService::suggested_name(&panel);
        assert_eq!(fixture.service.save_new(&mut panel, &name, false).unwrap(), Saved::Done { name: "a clock for my desk".into() });
        let manifest: serde_json::Value = serde_json::from_str(&fixture.studio.read_text("a clock for my desk", "widget.json").unwrap().unwrap()).unwrap();
        assert_eq!((&manifest["permissions"], &manifest["networkDomains"]), (&serde_json::json!([]), &serde_json::json!([])));
    }

    #[test]
    fn the_endpoint_in_the_fields_is_asked_for_its_models() {
        let scratch = Scratch::new("ai-models");
        let fixture = fixture(&scratch, Scripted::texts(&["unused"]));
        let service = &fixture.service;
        assert_eq!(AiProviderKind::Anthropic.suggested_models().first(), Some(&AiProviderKind::Anthropic.default_model()), "the suggestions the settings page shows start with the default");
        assert!(AiProviderKind::OpenAiCompatible.suggested_models().is_empty());

        // The endpoint need not be saved, and asking saves nothing.
        fixture.credentials.save("custom", &ApiKey::new(KEY).unwrap()).unwrap();
        assert_eq!(service.models(AiProviderKind::OpenAiCompatible, "https://ollama.lan:8443/v1/").unwrap(), ["model-a", "model-b"], "sorted, each once, only what has a name");
        let request = fixture.transport.requests.lock().unwrap()[0].clone();
        assert_eq!((request.method.as_str(), request.url.as_str(), request.header("Authorization")), ("GET", "https://ollama.lan:8443/v1/models", Some(format!("Bearer {KEY}").as_str())));
        assert!(request.body.is_none());
        assert_eq!(service.settings().profile, AiProfile::defaults(AiProviderKind::Anthropic));
        assert_eq!(service.models(AiProviderKind::Anthropic, "").unwrap().len(), 2, "an empty field is the provider's own endpoint");
        let request = fixture.transport.requests.lock().unwrap()[1].clone();
        assert_eq!((request.url.as_str(), request.header("x-api-key")), ("https://api.anthropic.com/v1/models?limit=1000", Some(KEY)));

        // Like every request it goes to HTTPS only, and only with a key.
        assert!(service.models(AiProviderKind::OpenAiCompatible, "http://localhost:11434").unwrap_err().0.contains("https://"));
        let no_key = service.models(AiProviderKind::OpenAi, "").unwrap_err().0;
        assert!(no_key.contains("No API key is stored for OpenAI") && !no_key.contains(KEY), "{no_key}");
        assert_eq!(fixture.transport.count(), 2, "nothing was sent for what was refused");

        // What the endpoint answers when it refuses is said in its fixed sentence.
        let refusing = self::fixture(&Scratch::new("ai-models-refused"), Scripted::new(vec![Err(unauthorized())]));
        struct Refusing;
        impl AiTransport for Refusing {
            fn execute(&self, _: &AiHttpRequest, _: &AiCancellation) -> Result<AiHttpResponse, AiClientError> {
                Ok(AiHttpResponse::new(401, format!("{{\"error\":\"{KEY}\"}}")))
            }
        }
        let service = AiService::with_parts(refusing.studio.clone(), refusing.credentials.clone(), Arc::new(Refusing), None);
        assert_eq!(service.models(AiProviderKind::Anthropic, "").unwrap_err().0, "The AI server rejected authentication. Check this profile's API key.");
    }
}
