//! The generate → run → fix loop. Port of `AgentLoop.kt`.

use super::client::{AiChat, AiMessage, AiTokenUsage, Role};
use super::jsx_check::{AiJsxCheck, Surface};
use super::output::{AiCandidate, AiManifestDeclaration, AiOutput, ValidationResult};
use super::profile::AiSettings;
use super::prompt_builder::{AiTurnContext, AiWidgetSize, PromptBuilder};
use super::source_edits::{AiSourceEdits, Failure};
use super::transport::{AiCancellation, AiErrorKind};

/// How a run of [`AgentLoop`] ended. Port of `AgentLoopOutcome`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentLoopOutcome {
    /// The candidate compiled and rendered. `manifest_json` is its canonical package declaration, if any.
    Succeeded { source: String, manifest_json: Option<String>, usage: AiTokenUsage, note: Option<String> },
    /// The iteration cap was reached; the last attempt is returned for manual repair.
    Exhausted { last_source: Option<String>, last_manifest_json: Option<String>, last_error: Option<String>, usage: AiTokenUsage },
    Cancelled { usage: AiTokenUsage },
    /// The provider call failed; `message` is safe to show (see [`super::AiClientError`]).
    Failed { message: String, usage: AiTokenUsage },
}

impl AgentLoopOutcome {
    pub fn usage(&self) -> AiTokenUsage {
        match self {
            Self::Succeeded { usage, .. } | Self::Exhausted { usage, .. } | Self::Cancelled { usage } | Self::Failed { usage, .. } => *usage,
        }
    }
}

/// Progress of the loop, delivered on the thread that runs it. Port of `AgentLoopEvent`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentLoopEvent {
    /// Waiting for the model.
    Thinking { iteration: i32 },
    /// The model produced a candidate.
    Produced { iteration: i32, source: String, manifest_json: Option<String> },
    /// The candidate is being compiled and executed.
    Running { iteration: i32 },
    RanFailed { iteration: i32, error_summary: String, logs: Vec<String> },
    RanSucceeded { iteration: i32 },
    /// Cumulative token usage so far.
    TokensUsed { usage: AiTokenUsage },
    /// In a conversation turn: the reply so far, while it is being written.
    Partial { iteration: i32, text: String },
    /// In a conversation turn: the model's one-sentence account of the candidate.
    Note { iteration: i32, text: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// A new widget from a description.
    Fresh { user_description: String },
    /// Change an existing widget; `current_declaration` is its current network declaration JSON, if any.
    Refine { current_code: String, instruction: String, current_declaration: Option<String>, runtime_diagnostic: Option<String> },
    /// One turn of a conversation; Skills are part of the context, not of the request.
    Turn { context: AiTurnContext },
}

/// What to generate. Port of `AgentLoopRequest`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentLoopRequest {
    pub mode: Mode,
    pub size: AiWidgetSize,
    /// Built with [`PromptBuilder::system_prompt`].
    pub system_prompt: String,
    pub max_iterations: i32,
    /// Formatted text of the enabled Skills, appended to the user's request; `None` for none.
    pub skills_text: Option<String>,
}

impl AgentLoopRequest {
    pub fn new(mode: Mode, size: AiWidgetSize, system_prompt: impl Into<String>) -> Self {
        Self { mode, size, system_prompt: system_prompt.into(), max_iterations: AiSettings::DEFAULT_MAX_ITERATIONS, skills_text: None }
    }
}

/// The generate → run → fix loop. Port of `AgentLoop.run`.
///
/// It is synchronous and stateless: call [`AgentLoop::run`] from a background
/// thread. The candidate is judged by the `validate` callback, so this type
/// has no dependency on the JavaScript runtime.
pub struct AgentLoop<'a> {
    chat: &'a dyn AiChat,
    /// The tags and attributes a candidate may use; `None` turns the check off. See [`AiJsxCheck`].
    surface: Option<&'a Surface>,
}

impl<'a> AgentLoop<'a> {
    /// A loop that checks candidates against the tags of this system.
    pub fn new(chat: &'a dyn AiChat) -> Self {
        Self { chat, surface: Some(AiJsxCheck::linux()) }
    }

    pub fn with_surface(chat: &'a dyn AiChat, surface: Option<&'a Surface>) -> Self {
        Self { chat, surface }
    }

    /// Port of `AgentLoop.iterationLimit`: at least one attempt, at most the configured cap.
    /// (The Swift per-provider limit only applies to Apple Private Cloud Compute.)
    pub fn iteration_limit(max_iterations: i32) -> i32 {
        max_iterations.clamp(1, AiSettings::MAXIMUM_MAX_ITERATIONS)
    }

    /// Runs until a candidate validates, the cap is reached, the provider fails or `cancellation` fires.
    ///
    /// `validate` compiles and executes the source with the optional canonical declaration and
    /// reports whether it rendered. `on_event` is the progress callback, called on this thread.
    pub fn run(
        &self,
        request: &AgentLoopRequest,
        validate: &mut dyn FnMut(&str, Option<&str>) -> ValidationResult,
        cancellation: &AiCancellation,
        on_event: &mut dyn FnMut(&AgentLoopEvent),
    ) -> AgentLoopOutcome {
        let mut usage = AiTokenUsage::ZERO;
        let system = AiMessage::new(Role::System, request.system_prompt.clone());
        let first_user;
        let mut latest: Option<AiCandidate>;
        // In a turn: the code the model was shown last, which a reply written as edit blocks changes.
        let mut edit_base: Option<String> = None;
        match &request.mode {
            Mode::Fresh { user_description } => {
                first_user = AiMessage::new(Role::User, PromptBuilder::user_prompt_first(&PromptBuilder::augment_with_skills(user_description, request.skills_text.as_deref()), request.size));
                latest = None;
            }
            Mode::Refine { current_code, instruction, current_declaration, runtime_diagnostic } => {
                first_user = AiMessage::new(
                    Role::User,
                    PromptBuilder::user_prompt_refine(current_code, &PromptBuilder::augment_with_skills(instruction, request.skills_text.as_deref()), current_declaration.as_deref(), runtime_diagnostic.as_deref()),
                );
                latest = Some(AiCandidate::new(current_code.clone(), current_declaration.clone()));
            }
            Mode::Turn { context } => {
                first_user = AiMessage::new(Role::User, PromptBuilder::user_prompt_turn(context));
                latest = None;
                edit_base = context.current_code.clone();
            }
        }
        let is_turn = matches!(request.mode, Mode::Turn { .. });
        let mut note: Option<String> = None;
        let mut last_error: Option<String> = None;
        let mut last_logs: Vec<String> = Vec::new();

        let limit = Self::iteration_limit(request.max_iterations);
        for iteration in 1..=limit {
            if cancellation.is_cancelled() {
                return AgentLoopOutcome::Cancelled { usage };
            }
            on_event(&AgentLoopEvent::Thinking { iteration });

            let messages = match (&latest, &last_error) {
                (Some(previous), Some(error)) if iteration > 1 => vec![
                    system.clone(),
                    first_user.clone(),
                    AiMessage::new(Role::Assistant, previous.as_assistant_message()),
                    AiMessage::new(Role::User, format!("{}{}", PromptBuilder::user_prompt_fix(&previous.source, error, &last_logs), if is_turn { PromptBuilder::TURN_REPAIR_SUFFIX } else { "" })),
                ],
                _ => vec![system.clone(), first_user.clone()],
            };

            let reply = if is_turn { self.chat.chat_stream(&messages, cancellation, &mut |text| on_event(&AgentLoopEvent::Partial { iteration, text: text.to_owned() })) } else { self.chat.chat(&messages, cancellation) };
            let result = match reply {
                Ok(result) => result,
                Err(failure) => {
                    if cancellation.is_cancelled() || failure.kind == AiErrorKind::Cancelled {
                        return AgentLoopOutcome::Cancelled { usage };
                    }
                    return AgentLoopOutcome::Failed { message: if failure.message.is_empty() { "The AI request failed.".into() } else { failure.message }, usage };
                }
            };
            usage = usage + result.usage;
            on_event(&AgentLoopEvent::TokensUsed { usage });
            if cancellation.is_cancelled() {
                return AgentLoopOutcome::Cancelled { usage };
            }

            let extracted = if is_turn {
                let reply = PromptBuilder::parse_turn_reply(&result.content);
                // A repair may leave the summary out: the last one that was given still describes the turn.
                if let Some(text) = &reply.note {
                    note = Some(text.clone());
                    on_event(&AgentLoopEvent::Note { iteration, text: text.clone() });
                }
                let edited = AiSourceEdits::parse(&result.content).and_then(|edits| match edits {
                    None => Ok(None),
                    Some(edits) => match edit_base.as_deref().filter(|base| !base.is_empty()) {
                        None => Err(Failure::new("there is no current code to change")),
                        Some(base) => AiSourceEdits::apply(&edits, base).map(Some),
                    },
                });
                match edited {
                    Ok(Some(edited)) => AiCandidate::new(edited, reply.candidate.manifest_json),
                    Ok(None) => reply.candidate,
                    Err(failure) => {
                        // Refused whole: the model is told why and asked for all of the code.
                        let summary = format!("The edit blocks could not be applied: {}. Reply with the full widget code instead.", failure.reason);
                        if let Some(base) = edit_base.as_deref().filter(|base| !base.is_empty()) {
                            latest = Some(AiCandidate::new(base, latest.and_then(|candidate| candidate.manifest_json)));
                        }
                        last_error = Some(summary.clone());
                        last_logs = Vec::new();
                        on_event(&AgentLoopEvent::RanFailed { iteration, error_summary: summary, logs: Vec::new() });
                        continue;
                    }
                }
            } else {
                AiOutput::extract(&result.content)
            };
            // Parse the declaration before anything runs: an invalid one is feedback for the model, never a guess.
            let mut declaration_error: Option<String> = None;
            let declaration = extracted.manifest_json.as_deref().and_then(|text| match AiManifestDeclaration::parse(text) {
                Ok(declaration) => Some(declaration.to_json()),
                Err(invalid) => {
                    declaration_error = Some(invalid);
                    None
                }
            });
            let candidate = AiCandidate::new(extracted.source, declaration);
            latest = Some(candidate.clone());
            if is_turn && !candidate.source.is_empty() {
                edit_base = Some(candidate.source.clone());
            }
            on_event(&AgentLoopEvent::Produced { iteration, source: candidate.source.clone(), manifest_json: candidate.manifest_json.clone() });

            on_event(&AgentLoopEvent::Running { iteration });
            let ran = if candidate.source.is_empty() {
                ValidationResult::failure("The reply contained no JSX code.", Vec::new())
            } else if result.truncated {
                ValidationResult::failure("The reply was cut off at the output limit. Return a shorter, complete widget.", Vec::new())
            } else if let Some(error) = &declaration_error {
                ValidationResult::failure(AiManifestDeclaration::failure_text(error), Vec::new())
            } else {
                validate(&candidate.source, candidate.manifest_json.as_deref())
            };
            if cancellation.is_cancelled() {
                return AgentLoopOutcome::Cancelled { usage };
            }

            // An attribute that does not exist is ignored when the widget runs, so running proves
            // nothing about it. Not on the last attempt: a widget that runs is better than none.
            let unknown = match self.surface {
                Some(surface) if !candidate.source.is_empty() && declaration_error.is_none() && !result.truncated => AiJsxCheck::summary(&candidate.source, surface),
                _ => None,
            };
            let validation = match unknown {
                None => ran,
                Some(unknown) if !ran.ok => ValidationResult::failure(format!("{}\n\n{unknown}", ran.error_summary.as_deref().unwrap_or("Runtime returned no element.")), ran.logs),
                Some(unknown) if iteration < limit => ValidationResult::failure(unknown, ran.logs),
                Some(_) => ran,
            };

            if validation.ok {
                on_event(&AgentLoopEvent::RanSucceeded { iteration });
                return AgentLoopOutcome::Succeeded { source: candidate.source, manifest_json: candidate.manifest_json, usage, note };
            }
            let summary = validation.error_summary.unwrap_or_else(|| "Runtime returned no element.".into());
            last_error = Some(summary.clone());
            last_logs = validation.logs.clone();
            on_event(&AgentLoopEvent::RanFailed { iteration, error_summary: summary, logs: validation.logs });
        }
        let (last_source, last_manifest_json) = latest.map_or((None, None), |candidate| (Some(candidate.source), candidate.manifest_json));
        AgentLoopOutcome::Exhausted { last_source, last_manifest_json, last_error, usage }
    }
}
