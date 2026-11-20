//! The AI conversation about the widget that is open in the editor, without
//! the window: the provider profile and the key, a turn from the request to
//! the version it leaves, and applying that version to the widget. The view
//! (`ui/ai.rs`) draws what is here.
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

use crate::model::{Studio, StudioError};

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

/// A version a turn made, next to what the widget holds now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    pub version: i64,
    /// The model's one sentence about it.
    pub note: String,
    pub source: String,
    pub added: usize,
    pub removed: usize,
    /// The changed lines with a few around them; `None` when the code is too long to compare, and the code is shown instead.
    pub lines: Option<Vec<Line>>,
    /// Hosts this version lets the widget contact that it may not contact now.
    pub new_hosts: Vec<String>,
    /// True once the widget holds this version.
    pub applied: bool,
}

/// One earlier turn, as the panel lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnRow {
    pub request: String,
    pub status: Status,
    /// The model's sentence for a turn that ran, the reason for one that did not.
    pub detail: String,
    pub version: Option<i64>,
    pub repairs: i64,
    pub manual_edit: bool,
}

/// What applying did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    /// The widget now holds the version: `path` has the text `source`.
    Done { path: String, source: String },
    /// Nothing was changed: the version adds these hosts, and the user has not agreed yet.
    NeedsConsent(Vec<String>),
}

/// The conversation about one widget, as the panel shows it.
#[derive(Debug, Clone)]
pub struct AiPanel {
    /// The folder name of the widget.
    pub widget: String,
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
                request: turn.request.clone(),
                status: turn.status,
                detail: if turn.status == Status::Succeeded { turn.note.clone() } else { turn.error_summary.clone() }.unwrap_or_default(),
                version: self.conversation.version(turn.version_id.as_deref()).map(|version| version.number),
                repairs: turn.repairs,
                manual_edit: turn.is_manual_edit,
            })
            .collect()
    }

    pub fn is_running(&self) -> bool {
        self.running.is_some()
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
}

/// Everything a turn needs on its worker thread. It holds the key for the length of the turn.
pub struct TurnJob {
    pub turn_id: String,
    loop_request: AgentLoopRequest,
    settings: AiSettings,
    key: ApiKey,
    installed: InstalledPackage,
    baseline: Option<String>,
    family: String,
    dark: bool,
    cancellation: AiCancellation,
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

    // The conversation

    fn installed(&self, widget: &str) -> Result<InstalledPackage, StudioError> {
        let package = self.studio.library().find(widget).ok_or_else(|| StudioError(format!("There is no widget named {widget}.")))?;
        if package.manifest_present && package.manifest.is_none() {
            return Err(StudioError("widget.json of this widget cannot be read.".into()));
        }
        Ok(package)
    }

    fn entry_text(&self, installed: &InstalledPackage) -> Result<String, StudioError> {
        let entry = AiCandidates::entry_of(installed);
        let bytes = self.studio.library().store().read_file(&installed.name, &entry)?;
        String::from_utf8(bytes).map_err(|_| StudioError(format!("{entry} is not text.")))
    }

    /// Opens the conversation about a widget: its newest one, or a new one. Code that was
    /// changed outside the conversation (in the editor, for one) becomes its current version.
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
        let adopted = conversation.adopt_external_source(&self.entry_text(&installed)?, AiCandidates::allowed_hosts(Some(&installed)), now);
        // Only a conversation that has something said in it is a file.
        if adopted && conversation.turns.iter().any(|turn| !turn.is_manual_edit) {
            self.conversations.save(&conversation);
        }
        Ok(AiPanel { widget: installed.name, conversation, running: None, proposal: None })
    }

    fn system_prompt(&self) -> &str {
        self.system_prompt.get_or_init(|| PromptBuilder::system_prompt(&AiReference::load(self.studio.templates())))
    }

    /// Starts a turn for `request` and returns the work for a worker thread. `unsaved` says that
    /// the editor holds changes that are not saved: the model would be shown code the user does not see.
    pub fn start(&self, panel: &mut AiPanel, request: &str, unsaved: bool, family: &str, dark: bool) -> Result<TurnJob, StudioError> {
        if panel.is_running() {
            return Err(StudioError("A request is still running.".into()));
        }
        if request.trim().is_empty() {
            return Err(StudioError("Say what to change.".into()));
        }
        if unsaved {
            return Err(StudioError("Save your changes first: the AI works on the saved code.".into()));
        }
        let settings = self.settings();
        if let Some(problem) = settings.profile.validation_error() {
            return Err(StudioError(problem));
        }
        let key = credentials::key_for(self.credentials.as_ref(), self.one_run_key.as_ref(), settings.profile.kind).map_err(|error| match error {
            CredentialError::Missing(_) => StudioError(format!("No API key is stored for {}. Enter it in Settings.", settings.profile.kind.display_name())),
            other => StudioError(other.message().to_owned()),
        })?;
        let installed = self.installed(&panel.widget)?;
        let now = now_milliseconds();
        // What was saved in the editor since the panel was opened is what the turn starts from.
        panel.conversation.adopt_external_source(&self.entry_text(&installed)?, AiCandidates::allowed_hosts(Some(&installed)), now);
        if let Some(size) = AiWidgetSize::ALL.into_iter().find(|size| size.family() == family) {
            panel.conversation.size = size;
        }
        let baseline = panel.conversation.current_version().map(|version| version.source.clone());
        let started = AiConversationTurns::begin(&mut panel.conversation, request, self.system_prompt(), None, None, now).ok_or_else(|| StudioError("A request is still running.".into()))?;
        // Saved before the model is asked: a turn the program does not survive reads back as interrupted.
        self.conversations.save(&panel.conversation);
        let cancellation = AiCancellation::new();
        panel.proposal = None;
        panel.running = Some(Running { turn_id: started.turn_id.clone(), attempt: 1, phase: Phase::Thinking, reply: String::new(), cancellation: cancellation.clone() });
        Ok(TurnJob { turn_id: started.turn_id, loop_request: started.loop_request, settings, key, installed, baseline, family: panel.conversation.size.family().to_owned(), dark, cancellation })
    }

    /// Asks the model and runs what it answers, up to the attempts a turn has. Blocks until the
    /// turn is over: call it on a worker thread and hand the events to [`AiPanel::event`].
    pub fn run(&self, job: &TurnJob, on_event: &mut dyn FnMut(&AgentLoopEvent)) -> AgentLoopOutcome {
        let client = AiClient::new(Shared(self.transport.clone()));
        let chat = client.bind(job.settings.clone(), job.key.expose());
        AgentLoop::new(&chat).run(&job.loop_request, &mut |source, declaration| self.studio.trial(Some(&job.installed), source, declaration, &job.family, job.dark, job.baseline.as_deref()), &job.cancellation, on_event)
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

    /// The current version next to what the widget holds.
    fn proposal(&self, panel: &AiPanel) -> Option<Proposal> {
        let version = panel.conversation.current_version()?;
        let installed = self.installed(&panel.widget).ok()?;
        let held = self.entry_text(&installed).ok()?;
        let summary = AiSourceDiff::summary(&held, &version.source);
        let note = panel.conversation.turns.iter().rfind(|turn| turn.version_id.as_deref() == Some(version.id.as_str())).and_then(|turn| turn.note.clone()).unwrap_or_default();
        Some(Proposal {
            version: version.number,
            note,
            source: version.source.clone(),
            added: summary.map_or(0, |summary| summary.added),
            removed: summary.map_or(0, |summary| summary.removed),
            lines: AiSourceDiff::lines(&held, &version.source),
            new_hosts: AiCandidates::new_hosts(Some(&installed), &version.network_domains),
            applied: held == version.source,
        })
    }

    /// Writes the proposed version into the widget. Hosts the widget may not contact yet are
    /// added only with `allow_new_hosts`; without it nothing is changed and the hosts are returned.
    pub fn apply(&self, panel: &mut AiPanel, allow_new_hosts: bool) -> Result<Applied, StudioError> {
        if panel.is_running() {
            return Err(StudioError("A request is still running.".into()));
        }
        let version = panel.conversation.current_version().cloned().ok_or_else(|| StudioError("There is nothing to apply.".into()))?;
        let installed = self.installed(&panel.widget)?;
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
        assert_eq!((running(&panel).phase, running(&panel).attempt), (Phase::Thinking, 1));
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
}
