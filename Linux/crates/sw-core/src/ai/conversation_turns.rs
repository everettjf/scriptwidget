//! How a conversation changes over one turn. Port of `AiConversationTurns.kt`.

use super::agent_loop::{AgentLoopEvent, AgentLoopOutcome, AgentLoopRequest, Mode};
use super::conversation::{AiConversation, AiConversationLimits, Status};
use super::output::AiManifestDeclaration;
use super::prompt_builder::{AiTurnContext, Exchange, PromptBuilder};
use super::{is_blank, trim};

/// A turn that was started: its identifier and what to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Started {
    pub turn_id: String,
    pub loop_request: AgentLoopRequest,
}

/// How a conversation changes over one turn. Port of the turn handling of
/// `AIConversationSession`, without the threads: the caller starts a turn,
/// runs [`super::AgentLoop`] with the request from [`Started::loop_request`],
/// feeds its events to [`AiConversationTurns::apply_event`] and its outcome to
/// [`AiConversationTurns::apply_outcome`], all on the thread that owns the
/// conversation.
///
/// A turn that does not succeed leaves the versions and the current version
/// exactly as they were.
pub struct AiConversationTurns;

impl AiConversationTurns {
    /// Starts a turn for `request` and returns it with what to send. A blank request, and a
    /// conversation that is already running a turn, start nothing.
    pub fn begin(conversation: &mut AiConversation, request: &str, system_prompt: &str, skills_text: Option<&str>, runtime_diagnostic: Option<&str>, now: i64) -> Option<Started> {
        if conversation.is_running() || is_blank(request) {
            return None;
        }
        // The history is read before the new turn is added, and after turns off the current path are marked.
        let turn_id = conversation.begin_turn(trim(request), now).id.clone();
        let turn_request = conversation.turn(&turn_id)?.request.clone();
        let current = conversation.current_version();
        let context = AiTurnContext {
            history: conversation.history_for_prompt().into_iter().map(|turn| Exchange { request: turn.request.clone(), note: turn.note.clone() }).collect(),
            current_code: current.map(|version| version.source.clone()),
            previous_code: conversation.version(current.and_then(|version| version.parent_id.as_deref())).map(|version| version.source.clone()),
            request: turn_request,
            skills_text: skills_text.map(str::to_owned),
            size: conversation.size,
            current_declaration: current.and_then(|version| version.declaration_json()),
            runtime_diagnostic: runtime_diagnostic.map(str::to_owned),
        };
        let loop_request = AgentLoopRequest { mode: Mode::Turn { context }, size: conversation.size, system_prompt: system_prompt.to_owned(), max_iterations: AiConversationLimits::MAX_ATTEMPTS_PER_TURN, skills_text: None };
        Some(Started { turn_id, loop_request })
    }

    /// Whether [`AiConversationTurns::retry`] would send `turn` again: it did not succeed, it is not
    /// running, and it is a request, not a change made outside the conversation.
    pub fn can_retry(conversation: &AiConversation, turn_id: &str) -> bool {
        conversation.turn(turn_id).is_some_and(|turn| !conversation.is_running() && !turn.is_manual_edit && !matches!(turn.status, Status::Succeeded | Status::Running))
    }

    /// Sends a turn that did not succeed again, from the version it started from: that version
    /// becomes the current one when it still exists, the turn is taken out and its request starts
    /// a new turn. Port of `AIConversationSession.retry`.
    pub fn retry(conversation: &mut AiConversation, turn_id: &str, system_prompt: &str, skills_text: Option<&str>, now: i64) -> Option<Started> {
        if !Self::can_retry(conversation, turn_id) {
            return None;
        }
        let turn = conversation.turn(turn_id)?;
        let request = turn.request.clone();
        if let Some(base) = turn.base_version_id.clone().filter(|base| conversation.version(Some(base)).is_some()) {
            conversation.current_version_id = Some(base);
        }
        conversation.turns.retain(|turn| turn.id != turn_id);
        Self::begin(conversation, &request, system_prompt, skills_text, None, now)
    }

    /// Records progress of the running turn `turn_id`.
    pub fn apply_event(conversation: &mut AiConversation, turn_id: &str, event: &AgentLoopEvent) {
        let Some(turn) = conversation.turn_mut(turn_id).filter(|turn| turn.status == Status::Running) else { return };
        match event {
            AgentLoopEvent::RanFailed { error_summary, .. } => {
                turn.repairs += 1;
                turn.error_summary = Some(clip_error(error_summary));
            }
            AgentLoopEvent::TokensUsed { usage } => turn.usage = *usage,
            AgentLoopEvent::Note { text, .. } => turn.note = Some(text.clone()),
            _ => {}
        }
    }

    /// Ends the running turn `turn_id`. An outcome of `None` is a failure with no text to show.
    /// Only a success adds a version and moves the current version.
    pub fn apply_outcome(conversation: &mut AiConversation, turn_id: &str, outcome: Option<&AgentLoopOutcome>, now: i64) {
        if !conversation.turn(turn_id).is_some_and(|turn| turn.status == Status::Running) {
            return;
        }
        // Only a success changes the versions; it does so before the turn is written to.
        let version_id = match outcome {
            Some(AgentLoopOutcome::Succeeded { source, manifest_json, .. }) => {
                let domains = manifest_json.as_deref().and_then(|text| AiManifestDeclaration::parse(text).ok()).map(|declaration| declaration.network_domains).unwrap_or_default();
                Some(conversation.add_version(source, domains, now).id.clone())
            }
            _ => None,
        };
        let Some(turn) = conversation.turn_mut(turn_id) else { return };
        if let Some(outcome) = outcome {
            turn.usage = outcome.usage();
        }
        match outcome {
            Some(AgentLoopOutcome::Succeeded { note, .. }) => {
                turn.status = Status::Succeeded;
                turn.version_id = version_id;
                turn.note = note.clone().or(turn.note.take()).or_else(|| Some("Done.".into()));
                turn.error_summary = None;
            }
            Some(AgentLoopOutcome::Exhausted { last_source, last_error, .. }) => {
                turn.status = Status::Unconverged;
                turn.error_summary = Some(clip_error(last_error.as_deref().unwrap_or("The widget did not run.")));
                turn.failed_source = last_source.clone();
            }
            Some(AgentLoopOutcome::Cancelled { .. }) => {
                turn.status = Status::Cancelled;
                turn.error_summary = None;
            }
            Some(AgentLoopOutcome::Failed { message, .. }) => {
                turn.status = Status::Failed;
                turn.error_summary = Some(clip_error(message));
            }
            None => {
                turn.status = Status::Failed;
                turn.error_summary = Some("The request could not be completed.".into());
            }
        }
        conversation.updated_at = now;
    }
}

fn clip_error(text: &str) -> String {
    PromptBuilder::clip(text, AiConversationLimits::ERROR_CHARACTERS)
}
