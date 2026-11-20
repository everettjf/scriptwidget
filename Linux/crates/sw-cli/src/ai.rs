//! `scriptwidget ai`: the provider profile, the API key, and the AI
//! conversation about a widget. The command-line face of `sw_core::ai`, the
//! port of the Android AI conversation; `Android/app/.../ui/AiConversationScreen.kt`
//! is what the conversation commands follow.
//!
//! Like every other command, each of these prints one JSON report on standard
//! output. While a turn runs, the reply is written to standard error as the
//! model writes it, with a line for every attempt.
//!
//! The key is read from standard input or typed without echo, goes to the
//! system keyring, and is handed to the client for the request. It is never
//! an argument, never in a report, never in a file this program writes.
//! Everything a model answers is untrusted: it is run in the engine with the
//! limits every run has before it is installed, the only part of a manifest it
//! decides is the network declaration, and what it writes reaches the terminal
//! with its control characters removed.

use std::io::{BufRead, IsTerminal, Read, Write};
use std::sync::{Arc, OnceLock};

use serde_json::{Value, json};
use sw_core::ai::candidates::AiCandidates;
use sw_core::ai::credentials::{self, ENVIRONMENT_KEY};
use sw_core::ai::source_diff::Kind;
use sw_core::ai::*;
use sw_core::library::{FAMILIES, InstalledPackage, Library};
use sw_core::packages::{PackageError, codes, names};
use sw_core::{DataPaths, Resources, RunRequest, RunResult, SharedScripts, WidgetRuntime};
use sw_render::{Presentation, WidgetRenderer};

use crate::arguments::{Arguments, Shape};
use crate::commands::{resources, user_data};
use crate::report::{EXIT_FAILED, Failure, Report};

const HELP: &str = "\
Usage: scriptwidget ai <command> [options]

  show                  The provider, endpoint and model, and whether a key is stored. Never the key.
  set                   --provider <anthropic|openai|custom>  --base-url <https://…>  --model <name>
                        --max-iterations <5-100>  --temperature <0-2>
                        The endpoint must be HTTPS, also on this machine: the request carries the key.
  key set               Store the key of the chosen provider (or --provider <name>) in the system
                        keyring through secret-tool. The key is read from standard input, or typed
                        without echo when standard input is a terminal. It is never an argument.
  key remove            Remove the stored key.
  models                Ask the endpoint which models it lists; a way to test the endpoint and the key.
  new <request>         Start a conversation about a new widget. The reply is written to standard error
                        as it arrives; the code is run and drawn here, and repaired up to three times.
                        --name <name>  --family <small|medium|large|extraLarge>  --no-apply (keep a draft)
                        A widget that contacts hosts is installed only with --allow-new-hosts; without it
                        the widget is kept as a draft and the report names the hosts.
  continue <conversation | package> <request>
                        Continue the conversation about an installed widget (or start one from its code),
                        or a draft by its id (--name names the widget it is installed as).
                        --allow-new-hosts lets the change add hosts the widget may contact.
  retry <conversation | package>
                        Send the last request again when it did not succeed, from the version it started from.
  restart <conversation | package>
                        Start a new conversation from the current version: same widget and size, no
                        earlier turn to send. The way out when a conversation has grown heavy.
  apply <conversation | package>
                        Install the current version of a draft as a new widget (--name), or write the
                        current version of a widget's conversation into the widget. --version <n> picks another.
  conversations [<id>]  List the conversations, or show one.

The Skills you enabled (scriptwidget skills enable <id>) add their instructions to every request of
new, continue and retry; the report names them under skills. --skills <id,id,…> chooses the Skills of
one conversation instead, enabled or not, from then on (an empty --skills value for none).

Options for new, continue and retry:
  --events              Progress as one JSON object a line on standard error, instead of text.
  --quiet               No progress on standard error.
  --data <dir>          The data folder (default: yours).

Without a keyring, give the key for one run in the SCRIPTWIDGET_AI_KEY environment variable; it is
not saved. Conversations are files in the data folder; they hold your requests and the widget code,
never a key.
";

/// The key the environment gave for this run. `main` reads it once, before any
/// thread exists, and takes the variable out of the environment so that no
/// child of this program inherits it.
static ONE_RUN_KEY: OnceLock<Result<Option<ApiKey>, CredentialError>> = OnceLock::new();

/// Records what `SCRIPTWIDGET_AI_KEY` held when the program started.
pub fn set_one_run_key(value: Option<std::ffi::OsString>) {
    let _ = ONE_RUN_KEY.set(credentials::key_from_environment(value));
}

fn one_run_key() -> Result<Option<ApiKey>, Failure> {
    match ONE_RUN_KEY.get() {
        None | Some(Ok(None)) => Ok(None),
        Some(Ok(Some(key))) => Ok(Some(key.clone())),
        Some(Err(error)) => Err(Failure::environment("ai.key_invalid", error.message())),
    }
}

impl From<CredentialError> for Failure {
    fn from(error: CredentialError) -> Self {
        let code = match &error {
            CredentialError::Unavailable(_) => "ai.keyring_unavailable",
            CredentialError::Invalid(_) => "ai.key_invalid",
            CredentialError::Missing(_) => "ai.no_key",
        };
        Failure::environment(code, error.message())
    }
}

fn client_failure(error: &AiClientError) -> Failure {
    let code = match error.kind {
        AiErrorKind::MissingApiKey => "ai.no_key",
        AiErrorKind::InvalidProfile => "ai.invalid_profile",
        AiErrorKind::Network => "ai.network",
        AiErrorKind::Timeout => "ai.timeout",
        AiErrorKind::Http => "ai.http",
        AiErrorKind::ResponseTooLarge | AiErrorKind::MalformedResponse | AiErrorKind::EmptyResponse => "ai.response",
        AiErrorKind::Refused => "ai.refused",
        AiErrorKind::Cancelled => "ai.cancelled",
    };
    Failure::environment(code, error.message.clone())
}

const DATA: &[&str] = &["data"];

fn shape(values: &'static [&'static str], flags: &'static [&'static str], minimum: usize, maximum: usize, positionals: &'static str) -> Shape {
    Shape { values, flags, minimum_positionals: minimum, maximum_positionals: maximum, positionals }
}

/// Runs an `ai` command. A failure that stopped it becomes its report, under the command's own name.
pub fn run(arguments: &[String]) -> Report {
    let words: Vec<&str> = arguments.iter().map(String::as_str).take_while(|word| !word.starts_with('-')).take(if arguments.first().is_some_and(|word| word == "key") { 2 } else { 1 }).collect();
    let name = if words.is_empty() { "ai".to_owned() } else { format!("ai {}", words.join(" ")) };
    dispatch(arguments).unwrap_or_else(|failure| Report::from_failure(&name, &failure))
}

fn dispatch(arguments: &[String]) -> Result<Report, Failure> {
    let Some(word) = arguments.first().map(String::as_str) else { return Err(Failure::usage("Missing an ai command. scriptwidget ai --help lists them.")) };
    let rest = &arguments[1..];
    match word {
        "show" => show(rest),
        "set" => set(rest),
        "key" => key(rest),
        "models" => models(rest),
        "new" => new(rest),
        "continue" => continue_conversation(rest),
        "retry" => retry(rest),
        "restart" => restart(rest),
        "apply" => apply(rest),
        "conversations" => conversations(rest),
        _ => Err(Failure::usage(format!("Unknown ai command {word}. scriptwidget ai --help lists them."))),
    }
}

/// `scriptwidget ai --help`.
pub fn wants_help(arguments: &[String]) -> bool {
    arguments.first().is_some_and(|word| matches!(word.as_str(), "--help" | "-h" | "help"))
}

pub fn help() -> &'static str {
    HELP
}

fn profile_store(paths: &DataPaths) -> AiProfileStore {
    AiProfileStore::new(paths.ai_profile())
}

fn keyring() -> SecretToolStore {
    SecretToolStore::new()
}

fn describe_profile(settings: &AiSettings) -> Value {
    let profile = &settings.profile;
    json!({
        "provider": profile.kind.id(),
        "providerName": profile.kind.display_name(),
        "baseUrl": profile.normalized_base_url(),
        "model": profile.model,
        "maxIterations": settings.max_iterations,
        "temperature": settings.temperature,
        "configured": profile.is_configured(),
        "problem": profile.validation_error(),
        "suggestedModels": profile.kind.suggested_models(),
    })
}

fn provider(arguments: &Arguments, fallback: AiProviderKind) -> Result<AiProviderKind, Failure> {
    match arguments.value("provider") {
        None => Ok(fallback),
        Some(id) => AiProviderKind::from_id(Some(id)).ok_or_else(|| Failure::usage(format!("Unknown provider {id}: use anthropic, openai or custom"))),
    }
}

// show, set

fn show(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(DATA, &[], 0, 0, ""))?;
    let paths = user_data(&arguments)?;
    let store = profile_store(&paths);
    let saved = store.load();
    let settings = saved.clone().unwrap_or_else(|| store.load_or_default());
    let mut report = Report::new("ai show");
    report.set("profile", describe_profile(&settings));
    report.set("saved", json!(saved.is_some()));
    report.set("profileFile", json!(store.file().display().to_string()));
    // Whether there is a key, and where it would come from; never the key.
    let one_run = one_run_key();
    let key = match (&one_run, keyring().load(settings.profile.kind.id())) {
        (Ok(Some(_)), _) => json!({ "available": true, "source": "environment", "note": format!("{ENVIRONMENT_KEY} is used for this run and is not saved.") }),
        (_, Ok(Some(_))) => json!({ "available": true, "source": "keyring" }),
        (_, Ok(None)) => json!({ "available": false, "source": Value::Null }),
        (_, Err(error)) => {
            report.diagnostic("warning", "ai.keyring_unavailable", error.message());
            json!({ "available": false, "source": Value::Null, "problem": error.message() })
        }
    };
    report.set("key", key);
    if let Err(failure) = one_run {
        report.diagnostic("warning", &failure.code, &failure.message);
    }
    Ok(report)
}

fn set(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data", "provider", "base-url", "model", "max-iterations", "temperature"], &[], 0, 0, ""))?;
    let paths = user_data(&arguments)?;
    let store = profile_store(&paths);
    let mut settings = store.load_or_default();
    let kind = provider(&arguments, settings.profile.kind)?;
    if kind != settings.profile.kind {
        // Another provider starts from its own endpoint and model.
        settings.profile = AiProfile::defaults(kind);
    }
    if let Some(url) = arguments.value("base-url") {
        settings.profile.base_url = url.to_owned();
    }
    if let Some(model) = arguments.value("model") {
        settings.profile.model = model.to_owned();
    }
    if let Some(text) = arguments.value("max-iterations") {
        let range = AiSettings::MINIMUM_MAX_ITERATIONS..=AiSettings::MAXIMUM_MAX_ITERATIONS;
        settings.max_iterations = text.parse().ok().filter(|count| range.contains(count)).ok_or_else(|| Failure::usage(format!("--max-iterations must be a whole number from {} to {}", range.start(), range.end())))?;
    }
    if let Some(text) = arguments.value("temperature") {
        settings.temperature = text.parse().ok().filter(|value: &f64| (0.0..=2.0).contains(value)).ok_or_else(|| Failure::usage("--temperature must be a number from 0 to 2"))?;
    }
    if let Some(problem) = settings.profile.validation_error() {
        return Err(Failure::usage(problem));
    }
    store.save(&settings).map_err(|error| Failure::environment("ai.profile_write", format!("The profile could not be saved: {error}")))?;
    let mut report = Report::new("ai set");
    report.set("profile", describe_profile(&store.load().unwrap_or(settings)));
    report.set("profileFile", json!(store.file().display().to_string()));
    Ok(report)
}

// key

/// More than a key can be.
const MAXIMUM_KEY_INPUT_BYTES: u64 = 8 * 1024;

/// Turns the echo of the terminal off for as long as it lives.
pub(crate) struct NoEcho(libc::termios);

impl NoEcho {
    pub(crate) fn start() -> Option<Self> {
        // SAFETY: `termios` is plain data that `tcgetattr` fills in; descriptor 0 is standard input for the life of the process.
        unsafe {
            let mut settings: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut settings) != 0 {
                return None;
            }
            let saved = settings;
            settings.c_lflag &= !libc::ECHO;
            (libc::tcsetattr(0, libc::TCSAFLUSH, &settings) == 0).then_some(Self(saved))
        }
    }
}

impl Drop for NoEcho {
    fn drop(&mut self) {
        // SAFETY: restores the settings `tcgetattr` returned for the same descriptor.
        unsafe { libc::tcsetattr(0, libc::TCSAFLUSH, &self.0) };
    }
}

/// The key as the user gives it: typed without echo at a terminal, or everything on standard input.
fn read_key() -> Result<ApiKey, Failure> {
    let stdin = std::io::stdin();
    let text = if stdin.is_terminal() {
        let hidden = NoEcho::start().ok_or_else(|| Failure::environment("ai.key_input", "The terminal's echo could not be turned off, so the key was not read. Pipe the key to this command instead."))?;
        eprint!("API key (not shown): ");
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        let read = stdin.lock().take(MAXIMUM_KEY_INPUT_BYTES + 1).read_line(&mut line);
        drop(hidden);
        eprintln!();
        read.map_err(|_| Failure::environment("ai.key_input", "The key could not be read."))?;
        line
    } else {
        let mut bytes = Vec::new();
        stdin.lock().take(MAXIMUM_KEY_INPUT_BYTES + 1).read_to_end(&mut bytes).map_err(|_| Failure::environment("ai.key_input", "The key could not be read from standard input."))?;
        String::from_utf8(bytes).map_err(|_| Failure::environment("ai.key_invalid", "The API key contains characters that are not allowed."))?
    };
    if text.len() as u64 > MAXIMUM_KEY_INPUT_BYTES {
        return Err(Failure::environment("ai.key_invalid", "That is too long to be an API key."));
    }
    Ok(ApiKey::new(&text)?)
}

fn key(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data", "provider"], &[], 1, 1, "set or remove"))?;
    let paths = user_data(&arguments)?;
    let kind = provider(&arguments, profile_store(&paths).load_or_default().profile.kind)?;
    let store = keyring();
    match arguments.positional(0) {
        Some("set") => {
            let key = read_key()?;
            store.save(kind.id(), &key)?;
            let mut report = Report::new("ai key set");
            report.set("provider", json!(kind.id()));
            report.set("stored", json!(true));
            report.set("where", json!("keyring"));
            Ok(report)
        }
        Some("remove") => {
            let removed = store.remove(kind.id())?;
            let mut report = Report::new("ai key remove");
            report.set("provider", json!(kind.id()));
            report.set("removed", json!(removed));
            Ok(report)
        }
        _ => Err(Failure::usage("ai key takes set or remove")),
    }
}

// What a request to the model needs

struct Session {
    paths: DataPaths,
    settings: AiSettings,
    key: ApiKey,
}

impl Session {
    /// The profile and the key, checked before anything else is started.
    fn open(arguments: &Arguments) -> Result<Self, Failure> {
        let paths = user_data(arguments)?;
        let settings = profile_store(&paths).load_or_default();
        if let Some(problem) = settings.profile.validation_error() {
            return Err(Failure::environment("ai.invalid_profile", format!("{problem} Set the provider with: scriptwidget ai set")));
        }
        let one_run = one_run_key()?;
        let key = credentials::key_for(&keyring(), one_run.as_ref(), settings.profile.kind)?;
        Ok(Self { paths, settings, key })
    }
}

fn models(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(DATA, &[], 0, 0, ""))?;
    let session = Session::open(&arguments)?;
    let mut report = Report::new("ai models");
    report.set("profile", describe_profile(&session.settings));
    match AiClient::default().list_models(&session.settings.profile, session.key.expose(), &AiCancellation::new()) {
        Ok(models) => report.set("models", json!(models)),
        Err(error) => report.absorb(&client_failure(&error)),
    }
    Ok(report)
}

// A turn

/// Text from a model or a package for the terminal: nothing in it moves the cursor or changes a color.
fn printable(text: &str) -> String {
    text.chars().map(|character| if character.is_control() && character != '\n' && character != '\t' { ' ' } else { character }).collect()
}

#[derive(Clone, Copy, PartialEq)]
enum Progress {
    Text,
    Events,
    Quiet,
}

/// Writes the progress of a turn to standard error.
struct Narrator {
    mode: Progress,
    /// The attempt whose reply is being written, and how much of it is out.
    writing: Option<(i32, usize)>,
}

impl Narrator {
    fn line(&mut self, text: &str) {
        self.end_reply();
        eprintln!("ai: {}", printable(text));
    }

    fn end_reply(&mut self) {
        if self.writing.take().is_some() && self.mode == Progress::Text {
            eprintln!();
        }
    }

    fn event(&mut self, event: &AgentLoopEvent) {
        if self.mode == Progress::Quiet {
            return;
        }
        if self.mode == Progress::Events {
            let line = match event {
                AgentLoopEvent::Thinking { iteration } => json!({ "event": "thinking", "attempt": iteration }),
                AgentLoopEvent::Partial { iteration, text } => {
                    let written = self.writing.filter(|(attempt, _)| attempt == iteration).map_or(0, |(_, written)| written);
                    let added = text.get(written..).unwrap_or(text);
                    self.writing = Some((*iteration, text.len()));
                    json!({ "event": "reply", "attempt": iteration, "text": added })
                }
                AgentLoopEvent::Note { iteration, text } => json!({ "event": "note", "attempt": iteration, "text": text }),
                AgentLoopEvent::Produced { iteration, source, manifest_json } => json!({ "event": "produced", "attempt": iteration, "bytes": source.len(), "declaration": manifest_json }),
                AgentLoopEvent::Running { iteration } => json!({ "event": "running", "attempt": iteration }),
                AgentLoopEvent::RanFailed { iteration, error_summary, .. } => json!({ "event": "failed", "attempt": iteration, "error": error_summary }),
                AgentLoopEvent::RanSucceeded { iteration } => json!({ "event": "succeeded", "attempt": iteration }),
                AgentLoopEvent::TokensUsed { usage } => json!({ "event": "usage", "promptTokens": usage.prompt_tokens, "completionTokens": usage.completion_tokens, "totalTokens": usage.total_tokens }),
            };
            // JSON text has no raw control character: a model cannot write to the terminal through it.
            eprintln!("{line}");
            return;
        }
        match event {
            AgentLoopEvent::Thinking { iteration } => self.line(&format!("attempt {iteration}: waiting for the model")),
            AgentLoopEvent::Partial { iteration, text } => {
                let written = self.writing.filter(|(attempt, _)| attempt == iteration).map_or(0, |(_, written)| written);
                eprint!("{}", printable(text.get(written..).unwrap_or(text)));
                let _ = std::io::stderr().flush();
                self.writing = Some((*iteration, text.len()));
            }
            AgentLoopEvent::Running { iteration } => self.line(&format!("attempt {iteration}: running the widget")),
            AgentLoopEvent::RanFailed { iteration, error_summary, .. } => self.line(&format!("attempt {iteration}: it did not pass: {}", error_summary.lines().next().unwrap_or(""))),
            AgentLoopEvent::RanSucceeded { iteration } => self.line(&format!("attempt {iteration}: the widget runs")),
            AgentLoopEvent::Note { .. } | AgentLoopEvent::Produced { .. } | AgentLoopEvent::TokensUsed { .. } => {}
        }
    }
}

const TURN_VALUES: &[&str] = &["data", "family", "name", "skills"];
const TURN_FLAGS: &[&str] = &["no-apply", "allow-new-hosts", "events", "quiet"];

fn progress(arguments: &Arguments) -> Result<Progress, Failure> {
    match (arguments.flag("events"), arguments.flag("quiet")) {
        (true, true) => Err(Failure::usage("Choose one of --events and --quiet")),
        (true, false) => Ok(Progress::Events),
        (false, true) => Ok(Progress::Quiet),
        (false, false) => Ok(Progress::Text),
    }
}

fn family(arguments: &Arguments) -> Result<Option<AiWidgetSize>, Failure> {
    match arguments.value("family") {
        None => Ok(None),
        Some(family) if FAMILIES.contains(&family) => Ok(Some(AiWidgetSize::from_family(Some(family)))),
        Some(family) => Err(Failure::usage(format!("Unknown family {family}: use small, medium, large or extraLarge"))),
    }
}

fn usage_json(usage: AiTokenUsage) -> Value {
    json!({ "promptTokens": usage.prompt_tokens, "completionTokens": usage.completion_tokens, "totalTokens": usage.total_tokens })
}

fn turn_json(turn: &AiConversationTurn) -> Value {
    json!({
        "id": turn.id, "request": turn.request, "status": turn.status.id(), "note": turn.note, "error": turn.error_summary,
        "repairs": turn.repairs, "versionId": turn.version_id, "baseVersionId": turn.base_version_id, "failedSource": turn.failed_source, "usage": usage_json(turn.usage),
        "abandoned": turn.is_abandoned, "manualEdit": turn.is_manual_edit, "createdAt": turn.created_at,
    })
}

fn version_json(version: &AiConversationVersion, with_source: bool) -> Value {
    let mut value = json!({ "id": version.id, "number": version.number, "networkDomains": version.network_domains, "createdAt": version.created_at, "bytes": version.source.len() });
    if with_source {
        value["source"] = json!(version.source);
    }
    value
}

fn package_json(package: &InstalledPackage) -> Value {
    json!({ "name": package.name, "title": package.display_name(), "installation": package.installation, "directory": package.directory.display().to_string() })
}

/// What changed between two versions, as lines with a few unchanged ones around them.
fn changes_json(before: &str, after: &str) -> Value {
    let Some(summary) = AiSourceDiff::summary(before, after) else { return Value::Null };
    let lines: Vec<Value> = AiSourceDiff::lines(before, after)
        .unwrap_or_default()
        .into_iter()
        .map(|line| match line.kind {
            Kind::Same => json!({ "kind": "same", "text": line.text }),
            Kind::Added => json!({ "kind": "added", "text": line.text }),
            Kind::Removed => json!({ "kind": "removed", "text": line.text }),
            Kind::Skipped => json!({ "kind": "skipped", "lines": line.skipped }),
        })
        .collect();
    json!({ "added": summary.added, "removed": summary.removed, "lines": lines })
}

fn conversation_store(paths: &DataPaths) -> AiConversationStore {
    AiConversationStore::new(paths.ai_conversations())
}

fn save(store: &AiConversationStore, conversation: &AiConversation) -> Result<(), Failure> {
    if store.save(conversation) { Ok(()) } else { Err(Failure::environment("ai.conversation_write", format!("The conversation could not be saved in {}.", store.directory().display()))) }
}

struct Engine {
    resources: Resources,
    runtime: WidgetRuntime,
    renderer: WidgetRenderer,
}

impl Engine {
    fn start(paths: &DataPaths) -> Result<Self, Failure> {
        let resources = resources()?;
        let scripts = SharedScripts::new(&resources.runtime).map(Arc::new).map_err(|error| Failure::environment("tool.resources_missing", error.to_string()))?;
        let runtime = WidgetRuntime::new(scripts.clone(), paths).map_err(|error| Failure::internal(format!("The runtime could not be started: {error}")))?;
        let renderer = WidgetRenderer::new(scripts).map_err(|error| Failure::internal(format!("The renderer could not be started: {error}")))?;
        Ok(Self { resources, runtime, renderer })
    }

    /// Draws a run the way `render` does and says why the widget itself could not be drawn.
    fn draw(&self, request: &RunRequest, result: &RunResult) -> Result<(), String> {
        let presentation = Presentation::for_family(&request.family, 1.0).ok_or_else(|| format!("Unknown family {}", request.family))?;
        match sw_render::render_run(&self.renderer, &self.runtime, request, result, &presentation) {
            Ok(rendered) => rendered.failure.map_or(Ok(()), |failure| Err(failure.message)),
            Err(error) => Err(error.message),
        }
    }
}

/// What a turn sends.
#[derive(Clone, Copy)]
enum Ask<'a> {
    /// A new request, from the current version.
    Request(&'a str),
    /// The turn with this id again, from the version it started from.
    Again(&'a str),
}

/// `--skills`: the Skills of this conversation from now on. Every id must be a Skill that is here.
fn choose_skills(arguments: &Arguments, paths: &DataPaths, conversation: &mut AiConversation) -> Result<(), Failure> {
    let Some(text) = arguments.value("skills") else { return Ok(()) };
    let ids: Vec<&str> = text.split(',').map(str::trim).filter(|id| !id.is_empty()).collect();
    let skills = sw_core::skills::SkillStore::new(paths.skills());
    if let Some(unknown) = ids.iter().find(|id| skills.find(id).is_none()) {
        return Err(Failure::usage(format!("There is no Skill {unknown}. scriptwidget skills list shows them.")));
    }
    conversation.choose_skills(ids, now_milliseconds());
    Ok(())
}

/// Runs one turn of `conversation` and records it. The conversation is saved before the model is
/// asked and after the turn ended, so a turn the program did not survive reads back as interrupted.
#[allow(clippy::too_many_arguments)]
fn run_turn(report: &mut Report, session: &Session, engine: &Engine, store: &AiConversationStore, conversation: &mut AiConversation, installed: Option<&InstalledPackage>, ask: Ask<'_>, mode: Progress) -> Result<AiConversationTurn, Failure> {
    let reference = AiReference::load(engine.resources.templates.as_deref());
    let system_prompt = PromptBuilder::system_prompt(&reference);
    // The Skills of the conversation, or without a choice the ones the user enabled, read when the
    // turn is sent. They add text to the request and nothing else.
    let skills = sw_core::skills::SkillStore::new(session.paths.skills());
    let used = skills.skills_for(conversation.skill_ids.as_deref());
    let skills_text = Some(match &conversation.skill_ids {
        Some(ids) => skills.prompt_text(ids),
        None => skills.enabled_skills_prompt_text(),
    })
    .filter(|text| !text.trim().is_empty());
    report.set("skills", used.iter().map(|skill| json!({ "id": skill.id, "title": skill.title, "version": skill.version })).collect());
    let now = now_milliseconds();
    let started = match ask {
        Ask::Request(request) => AiConversationTurns::begin(conversation, request, &system_prompt, skills_text.as_deref(), None, now).ok_or_else(|| Failure::usage("The request is empty."))?,
        Ask::Again(turn) => AiConversationTurns::retry(conversation, turn, &system_prompt, skills_text.as_deref(), now).ok_or_else(|| Failure::new(EXIT_FAILED, "ai.nothing_to_retry", "That request cannot be sent again."))?,
    };
    // What the turn starts from: for a request sent again, the version it started from the first time.
    let baseline = conversation.current_version().map(|version| version.source.clone());
    save(store, conversation)?;

    let client = AiClient::default();
    let chat = client.bind(session.settings.clone(), session.key.expose());
    let family = conversation.size.family();
    let mut narrator = Narrator { mode, writing: None };
    let draw = |request: &RunRequest, result: &RunResult| engine.draw(request, result);
    let outcome = AgentLoop::new(&chat).run(
        &started.loop_request,
        &mut |source, declaration| AiCandidates::validate(&engine.runtime, installed, source, declaration, family, false, baseline.as_deref(), Some(&draw)),
        &AiCancellation::new(),
        &mut |event| {
            narrator.event(event);
            AiConversationTurns::apply_event(conversation, &started.turn_id, event);
        },
    );
    narrator.end_reply();
    AiConversationTurns::apply_outcome(conversation, &started.turn_id, Some(&outcome), now_milliseconds());
    save(store, conversation)?;

    let turn = conversation.turn(&started.turn_id).cloned().ok_or_else(|| Failure::internal("The turn was lost."))?;
    report.set("conversation", json!({ "id": conversation.id, "title": conversation.title, "size": conversation.size.family(), "versions": conversation.versions.len() }));
    report.set("turn", turn_json(&turn));
    if let Some(advice) = conversation.usage_advice() {
        report.diagnostic("warning", "ai.conversation_large", &advice.message());
    }
    match turn.status {
        Status::Succeeded => {
            if let Some(version) = conversation.current_version() {
                report.set("version", version_json(version, true));
                report.set("changes", baseline.as_deref().map_or(Value::Null, |before| changes_json(before, &version.source)));
            }
        }
        // The model never produced a widget that runs: the widget is as it was, and that is this command's result.
        Status::Unconverged => report.fail(EXIT_FAILED, "ai.unconverged", &format!("No attempt produced a widget that runs: {}", turn.error_summary.as_deref().unwrap_or(""))),
        _ => report.absorb(&Failure::environment("ai.request_failed", turn.error_summary.clone().unwrap_or_else(|| "The request was not completed.".into()))),
    }
    Ok(turn)
}

/// A package name from what the user asked for: the title of the conversation when it can be one.
fn name_for(conversation: &AiConversation, wanted: Option<&str>) -> Result<String, Failure> {
    if let Some(name) = wanted {
        return if names::is_valid(name) { Ok(name.to_owned()) } else { Err(Failure::usage(format!("{name:?} cannot be a package name: no path separators, leading dot or control characters, at most 80 characters"))) };
    }
    Ok(AiCandidates::suggested_name(&conversation.title))
}

fn new(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(TURN_VALUES, TURN_FLAGS, 1, 1, "what the widget should show, as one argument"))?;
    let mode = progress(&arguments)?;
    let size = family(&arguments)?.unwrap_or(AiWidgetSize::Medium);
    let request = arguments.positional(0).unwrap_or_default();
    let mut conversation = AiConversation::new(now_milliseconds());
    conversation.size = size;
    // A name that cannot be used is refused before the model is asked.
    if let Some(name) = arguments.value("name") {
        name_for(&conversation, Some(name))?;
    }
    let session = Session::open(&arguments)?;
    choose_skills(&arguments, &session.paths, &mut conversation)?;
    let engine = Engine::start(&session.paths)?;
    let store = conversation_store(&session.paths);
    let library = Library::new(&session.paths, engine.resources.templates.clone());
    let mut report = Report::new("ai new");
    let turn = run_turn(&mut report, &session, &engine, &store, &mut conversation, None, Ask::Request(request), mode)?;
    after_turn(&mut report, &library, &store, &mut conversation, None, &turn, &arguments)?;
    Ok(report)
}

/// What follows a turn that ran: its version goes into the widget, or a draft becomes a widget,
/// unless `--no-apply` keeps it in the conversation only.
fn after_turn(report: &mut Report, library: &Library, store: &AiConversationStore, conversation: &mut AiConversation, installed: Option<&InstalledPackage>, turn: &AiConversationTurn, arguments: &Arguments) -> Result<(), Failure> {
    report.set("applied", json!(false));
    if turn.status != Status::Succeeded || arguments.flag("no-apply") {
        return Ok(());
    }
    // The widget was made; whether it is installed is a second question, and a refusal there is not lost work.
    let done = match installed {
        Some(installed) => match conversation.current_version().cloned() {
            Some(version) => apply_to(report, library, installed, &version, arguments.flag("allow-new-hosts")),
            None => Ok(()),
        },
        None => {
            let name = name_for(conversation, arguments.value("name"))?;
            install_new(report, library, store, conversation, &name, arguments.flag("allow-new-hosts"))
        }
    };
    if let Err(failure) = done {
        report.absorb(&failure);
    }
    Ok(())
}

/// Saves the current version as a new widget and ties the conversation to it. A version that
/// contacts hosts is installed only when the user said so: the hosts are the model's choice.
fn install_new(report: &mut Report, library: &Library, store: &AiConversationStore, conversation: &mut AiConversation, name: &str, allow_new_hosts: bool) -> Result<(), Failure> {
    let version = conversation.current_version().cloned().ok_or_else(|| Failure::new(EXIT_FAILED, "ai.no_version", "The conversation has no version to install."))?;
    report.set("newHosts", json!(version.network_domains));
    if !version.network_domains.is_empty() && !allow_new_hosts {
        return Err(Failure::environment(
            "ai.new_hosts",
            format!("This widget contacts {}. It was kept as a draft and not installed. To install it: scriptwidget ai apply {} --allow-new-hosts", version.network_domains.join(", "), conversation.id),
        ));
    }
    let installed = AiCandidates::save_new(library, name, &version)?;
    conversation.package_id = Some(installed.installation.clone());
    conversation.updated_at = now_milliseconds();
    save(store, conversation)?;
    report.set("applied", json!(true));
    report.set("package", package_json(&installed));
    report.set("networkDomains", json!(version.network_domains));
    Ok(())
}

/// Writes the current version into `installed`. Hosts the widget may not contact yet are added only when the user said so.
fn apply_to(report: &mut Report, library: &Library, installed: &InstalledPackage, version: &AiConversationVersion, allow_new_hosts: bool) -> Result<(), Failure> {
    let new_hosts = AiCandidates::new_hosts(Some(installed), &version.network_domains);
    report.set("newHosts", json!(new_hosts));
    if !new_hosts.is_empty() && !allow_new_hosts {
        return Err(Failure::environment(
            "ai.new_hosts",
            format!("This version lets the widget contact {}, which it may not contact now. Nothing was changed. To allow it: scriptwidget ai apply {:?} --allow-new-hosts", new_hosts.join(", "), installed.name),
        ));
    }
    let applied = AiCandidates::apply(library, installed, version)?;
    report.set("applied", json!(true));
    report.set("package", package_json(&applied));
    Ok(())
}

fn find_package(library: &Library, name: &str) -> Result<InstalledPackage, Failure> {
    let package = library.find(name).ok_or_else(|| Failure::from(PackageError::new(codes::PACKAGE_NOT_FOUND, format!("There is no widget named {name}. scriptwidget list shows them."))))?;
    if package.manifest_present && package.manifest.is_none() {
        return Err(PackageError::new(codes::INVALID_MANIFEST, format!("widget.json of {name} cannot be read.")).into());
    }
    Ok(package)
}

/// Takes over the code the widget holds now when it is not what the conversation knows as current:
/// code that was changed outside the conversation is taken over, not overwritten by an older version.
fn adopt_installed(library: &Library, installed: &InstalledPackage, conversation: &mut AiConversation, now: i64) -> Result<(), Failure> {
    let entry = AiCandidates::entry_of(installed);
    let source = library.store().read_file(&installed.name, &entry).map_err(Failure::from).and_then(|bytes| String::from_utf8(bytes).map_err(|_| Failure::new(EXIT_FAILED, codes::INVALID_ENTRY, format!("{entry} is not text."))))?;
    conversation.adopt_external_source(&source, AiCandidates::allowed_hosts(Some(installed)), now);
    Ok(())
}

/// The conversation about an installed widget: its newest one, or a new one.
fn conversation_for(store: &AiConversationStore, installed: &InstalledPackage, now: i64) -> AiConversation {
    store.latest(&installed.installation).unwrap_or_else(|| {
        let mut fresh = AiConversation::new(now);
        fresh.package_id = Some(installed.installation.clone());
        fresh.title = installed.display_name();
        fresh
    })
}

/// What `<conversation | package>` names: a conversation by its id, with the widget it belongs to
/// when that is still installed, or the newest conversation of an installed widget. A conversation
/// without an installed widget is a draft. With `create`, a widget nobody talked about yet gets a new one.
fn conversation_named(store: &AiConversationStore, library: &Library, target: &str, create: bool) -> Result<(AiConversation, Option<InstalledPackage>), Failure> {
    if let Some(conversation) = store.load(target) {
        let installed = match conversation.package_id.as_deref().and_then(|installation| library.find_by_installation(installation)) {
            Some(bound) => Some(find_package(library, &bound.name)?),
            None => None,
        };
        return Ok((conversation, installed));
    }
    let missing = || Failure::new(EXIT_FAILED, "ai.no_conversation", format!("{target} is neither a conversation nor an installed widget. scriptwidget ai conversations lists the conversations."));
    if create {
        let installed = find_package(library, target)?;
        return Ok((conversation_for(store, &installed, now_milliseconds()), Some(installed)));
    }
    let installed = find_package(library, target).map_err(|_| missing())?;
    let conversation = store.latest(&installed.installation).ok_or_else(|| Failure::new(EXIT_FAILED, "ai.no_conversation", format!("There is no conversation about {}.", installed.name)))?;
    Ok((conversation, Some(installed)))
}

/// `--name` is for a draft: an installed widget keeps its name.
fn name_is_for_a_draft(arguments: &Arguments, conversation: &AiConversation, installed: Option<&InstalledPackage>) -> Result<(), Failure> {
    match (arguments.value("name"), installed) {
        (Some(_), Some(installed)) => Err(Failure::usage(format!("This conversation belongs to {}; --name is for a draft.", installed.name))),
        (Some(name), None) => name_for(conversation, Some(name)).map(|_| ()),
        (None, _) => Ok(()),
    }
}

fn continue_conversation(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(TURN_VALUES, TURN_FLAGS, 2, 2, "a conversation or an installed widget, and what to change, as one argument each"))?;
    let mode = progress(&arguments)?;
    let size = family(&arguments)?;
    let paths = user_data(&arguments)?;
    let library = Library::new(&paths, None);
    let store = conversation_store(&paths);
    let (mut conversation, installed) = conversation_named(&store, &library, arguments.positional(0).unwrap_or_default(), true)?;
    name_is_for_a_draft(&arguments, &conversation, installed.as_ref())?;
    let session = Session::open(&arguments)?;
    choose_skills(&arguments, &session.paths, &mut conversation)?;
    let engine = Engine::start(&session.paths)?;
    if let Some(installed) = &installed {
        adopt_installed(&library, installed, &mut conversation, now_milliseconds())?;
    }
    if let Some(size) = size {
        conversation.size = size;
    } else if let Some(installed) = installed.as_ref().filter(|_| conversation.turns.iter().all(|turn| turn.is_manual_edit)) {
        // A first turn about this widget: a size it can be placed at.
        let families = installed.families();
        conversation.size = AiWidgetSize::from_family(Some(if families.contains(&"medium") { "medium" } else { families.first().copied().unwrap_or("medium") }));
    }
    let mut report = Report::new("ai continue");
    let turn = run_turn(&mut report, &session, &engine, &store, &mut conversation, installed.as_ref(), Ask::Request(arguments.positional(1).unwrap_or_default()), mode)?;
    after_turn(&mut report, &library, &store, &mut conversation, installed.as_ref(), &turn, &arguments)?;
    Ok(report)
}

/// Sends the last request of a conversation again when it did not succeed. It starts from the
/// version the turn started from, as on the other platforms, and takes the place of that turn.
fn retry(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data", "name", "skills"], TURN_FLAGS, 1, 1, "a conversation or an installed widget"))?;
    let mode = progress(&arguments)?;
    let paths = user_data(&arguments)?;
    let library = Library::new(&paths, None);
    let store = conversation_store(&paths);
    let (mut conversation, installed) = conversation_named(&store, &library, arguments.positional(0).unwrap_or_default(), false)?;
    name_is_for_a_draft(&arguments, &conversation, installed.as_ref())?;
    let last = conversation.turns.iter().rfind(|turn| !turn.is_manual_edit).map(|turn| (turn.id.clone(), turn.status));
    let turn_id = match last {
        Some((id, _)) if AiConversationTurns::can_retry(&conversation, &id) => id,
        Some((_, Status::Succeeded)) => return Err(Failure::new(EXIT_FAILED, "ai.nothing_to_retry", "The last request of this conversation succeeded; there is nothing to send again.")),
        _ => return Err(Failure::new(EXIT_FAILED, "ai.nothing_to_retry", "This conversation has no request to send again.")),
    };
    let session = Session::open(&arguments)?;
    choose_skills(&arguments, &session.paths, &mut conversation)?;
    let engine = Engine::start(&session.paths)?;
    let mut report = Report::new("ai retry");
    let turn = run_turn(&mut report, &session, &engine, &store, &mut conversation, installed.as_ref(), Ask::Again(&turn_id), mode)?;
    after_turn(&mut report, &library, &store, &mut conversation, installed.as_ref(), &turn, &arguments)?;
    Ok(report)
}

/// Starts a new conversation from the current version of another: the way out when one has grown heavy.
/// The old conversation stays where it is; the new one is the widget's newest, so `continue` takes it.
fn restart(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(DATA, &[], 1, 1, "a conversation or an installed widget"))?;
    let paths = user_data(&arguments)?;
    let library = Library::new(&paths, None);
    let store = conversation_store(&paths);
    let (conversation, _) = conversation_named(&store, &library, arguments.positional(0).unwrap_or_default(), false)?;
    // Later than the one it comes from, also within the same millisecond.
    let next = conversation.continued_from_current_version(now_milliseconds().max(conversation.updated_at + 1)).ok_or_else(|| Failure::new(EXIT_FAILED, "ai.no_version", "The conversation has no version to start from."))?;
    save(&store, &next)?;
    let mut report = Report::new("ai restart");
    report.set("from", json!({ "id": conversation.id, "advice": conversation.usage_advice().map(|advice| advice.message()) }));
    report.set("conversation", json!({ "id": next.id, "title": next.title, "size": next.size.family(), "versions": next.versions.len(), "draft": next.is_draft(), "skillIds": next.skill_ids }));
    if let Some(version) = next.current_version() {
        report.set("version", version_json(version, false));
    }
    Ok(report)
}

fn apply(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data", "name", "version"], &["allow-new-hosts"], 1, 1, "a conversation or an installed widget"))?;
    let paths = user_data(&arguments)?;
    let library = Library::new(&paths, None);
    let store = conversation_store(&paths);
    let target = arguments.positional(0).unwrap_or_default();
    let (mut conversation, _) = conversation_named(&store, &library, target, false)?;
    if let Some(text) = arguments.value("version") {
        let number: i64 = text.parse().map_err(|_| Failure::usage("--version must be the number of a version"))?;
        let id = conversation.versions.iter().find(|version| version.number == number).map(|version| version.id.clone()).ok_or_else(|| Failure::new(EXIT_FAILED, "ai.no_version", format!("The conversation has no version {number}.")))?;
        conversation.select_version(&id, now_milliseconds());
    }
    let version = conversation.current_version().cloned().ok_or_else(|| Failure::new(EXIT_FAILED, "ai.no_version", "The conversation has no version to apply."))?;
    let mut report = Report::new("ai apply");
    report.set("conversation", json!({ "id": conversation.id, "title": conversation.title }));
    report.set("version", version_json(&version, false));
    report.set("applied", json!(false));
    // The widget the conversation belongs to, when it is still installed.
    let bound = conversation.package_id.as_deref().and_then(|installation| library.find_by_installation(installation));
    match bound {
        Some(installed) => {
            if arguments.value("name").is_some() {
                return Err(Failure::usage(format!("This conversation belongs to {}; --name is for a draft.", installed.name)));
            }
            let installed = find_package(&library, &installed.name)?;
            // The same check as before a turn is applied: the files as they would be must compile.
            let resources = resources()?;
            let scripts = SharedScripts::new(&resources.runtime).map(Arc::new).map_err(|error| Failure::environment("tool.resources_missing", error.to_string()))?;
            let runtime = WidgetRuntime::new(scripts, &paths).map_err(|error| Failure::internal(format!("The runtime could not be started: {error}")))?;
            let files = AiCandidates::files(Some(&installed), &version.source, &version.network_domains, &installed.name);
            runtime.validate_package(files.as_ref()).map_err(|error| Failure::new(EXIT_FAILED, &error.kind, error.message))?;
            apply_to(&mut report, &library, &installed, &version, arguments.flag("allow-new-hosts"))?;
            save(&store, &conversation)?;
        }
        None => {
            let name = name_for(&conversation, arguments.value("name"))?;
            install_new(&mut report, &library, &store, &mut conversation, &name, arguments.flag("allow-new-hosts"))?;
        }
    }
    Ok(report)
}

fn conversations(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(DATA, &[], 0, 1, "a conversation"))?;
    let paths = user_data(&arguments)?;
    let store = conversation_store(&paths);
    let library = Library::new(&paths, None);
    let package_of = |installation: Option<&str>| installation.and_then(|installation| library.find_by_installation(installation)).map(|package| package.name);
    let mut report = Report::new("ai conversations");
    report.set("folder", json!(store.directory().display().to_string()));
    match arguments.positional(0) {
        None => {
            let listed: Vec<Value> = store
                .summaries(false)
                .into_iter()
                .map(|summary| json!({ "id": summary.id, "title": summary.title, "package": package_of(summary.package_id.as_deref()), "draft": summary.package_id.is_none(), "versions": summary.version_count, "updatedAt": summary.updated_at }))
                .collect();
            report.set("conversations", Value::Array(listed));
        }
        Some(id) => {
            let conversation = store.load(id).ok_or_else(|| Failure::new(EXIT_FAILED, "ai.no_conversation", format!("There is no conversation {id}.")))?;
            let usage = conversation.total_usage();
            report.set(
                "conversation",
                json!({
                    "id": conversation.id, "title": conversation.title, "size": conversation.size.family(), "package": package_of(conversation.package_id.as_deref()),
                    "draft": conversation.is_draft(), "currentVersion": conversation.current_version().map(|version| version.number), "usage": usage_json(usage),
                    "advice": conversation.usage_advice().map(|advice| advice.message()), "createdAt": conversation.created_at, "updatedAt": conversation.updated_at,
                    "skillIds": conversation.skill_ids,
                }),
            );
            report.set("turns", conversation.turns.iter().map(turn_json).collect());
            report.set("versions", conversation.versions.iter().map(|version| version_json(version, Some(&version.id) == conversation.current_version_id.as_ref())).collect());
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_a_model_writes_cannot_drive_the_terminal() {
        assert_eq!(printable("ok \u{1b}[31mred\u{1b}[0m\r\u{7}\u{9b}\tend\n"), "ok  [31mred [0m   \tend\n");
        assert_eq!(printable("你好 — ▲"), "你好 — ▲");
    }

    #[test]
    fn a_package_name_comes_from_the_request_when_it_can_be_one() {
        let mut conversation = AiConversation::new(1);
        for (title, expected) in [("A clock for my desk", "A clock for my desk"), ("show https://api.example.com/v1 prices", "show https   api.example.com v1 prices"), (".hidden", "hidden"), ("", "AI Widget"), ("///", "AI Widget"), ("a title that was cut…", "a title that was cut")] {
            conversation.title = title.to_owned();
            let name = name_for(&conversation, None).unwrap();
            assert_eq!(name, expected);
            assert!(names::is_valid(&name), "{name}");
        }
        assert_eq!(name_for(&conversation, Some("Mine")).unwrap(), "Mine");
        assert!(name_for(&conversation, Some("../escape")).is_err() && name_for(&conversation, Some("")).is_err());
    }

    #[test]
    fn the_commands_take_only_their_own_options() {
        let folder = std::env::temp_dir().join(format!("scriptwidget-cli-ai-{}", std::process::id()));
        let with_data = |words: &[&str]| words.iter().map(|word| word.to_string()).chain(["--data".to_owned(), folder.display().to_string()]).collect::<Vec<_>>();
        for words in [&["show", "extra"][..], &["set", "--key", "sk-x"], &["set", "--api-key=sk-x"], &["key"], &["key", "set", "sk-on-the-command-line"], &["new"], &["new", "a", "b"], &["continue", "only-one"], &["retry"], &["retry", "a", "b"], &["retry", "a", "--family", "small"], &["restart"], &["restart", "a", "--skills", "x"], &["bogus"], &[]] {
            let failure = dispatch(&with_data(words)).err().unwrap_or_else(|| panic!("{words:?} was accepted"));
            assert_eq!(failure.code, "usage", "{words:?}: {}", failure.message);
            assert!(!failure.message.contains("sk-x"), "an argument that looks like a key is not repeated: {}", failure.message);
        }
        let _ = std::fs::remove_dir_all(&folder);
    }
}
