//! Shared by the AI tests: a scripted model and the helpers that run a turn
//! the way the applications do. Ported from the fakes of the Android tests
//! (`Android/core/src/test/java/com/everettjf/scriptwidget/core/ai`).
#![allow(dead_code)]

use std::cell::RefCell;

use sw_core::ai::*;

/// One scripted answer of the fake model.
pub enum Reply {
    Text(String),
    Result(AiChatResult),
    Error(AiClientError),
}

impl From<&str> for Reply {
    fn from(text: &str) -> Self {
        Self::Text(text.to_owned())
    }
}

impl From<String> for Reply {
    fn from(text: String) -> Self {
        Self::Text(text)
    }
}

impl From<AiChatResult> for Reply {
    fn from(result: AiChatResult) -> Self {
        Self::Result(result)
    }
}

impl From<AiClientError> for Reply {
    fn from(error: AiClientError) -> Self {
        Self::Error(error)
    }
}

/// Replies in order, the last one again when they run out. Records every conversation.
pub struct FakeChat {
    replies: Vec<Reply>,
    conversations: RefCell<Vec<Vec<AiMessage>>>,
    on_call: Box<dyn Fn(usize)>,
}

impl FakeChat {
    pub fn new(replies: Vec<Reply>) -> Self {
        Self { replies, conversations: RefCell::default(), on_call: Box::new(|_| {}) }
    }

    pub fn texts(replies: &[&str]) -> Self {
        Self::new(replies.iter().map(|reply| Reply::from(*reply)).collect())
    }

    pub fn with_hook(replies: Vec<Reply>, on_call: impl Fn(usize) + 'static) -> Self {
        Self { replies, conversations: RefCell::default(), on_call: Box::new(on_call) }
    }

    pub fn conversations(&self) -> Vec<Vec<AiMessage>> {
        self.conversations.borrow().clone()
    }

    pub fn calls(&self) -> usize {
        self.conversations.borrow().len()
    }

    /// The last message of the call with this index.
    pub fn last_of(&self, call: usize) -> String {
        self.conversations.borrow()[call].last().unwrap().content.clone()
    }
}

impl AiChat for FakeChat {
    fn chat(&self, messages: &[AiMessage], _: &AiCancellation) -> Result<AiChatResult, AiClientError> {
        self.conversations.borrow_mut().push(messages.to_vec());
        let count = self.calls();
        (self.on_call)(count);
        match &self.replies[count.min(self.replies.len()) - 1] {
            Reply::Text(text) => Ok(AiChatResult::new(text.clone(), AiTokenUsage::new(10, 5, 15))),
            Reply::Result(result) => Ok(result.clone()),
            Reply::Error(error) => Err(error.clone()),
        }
    }
}

pub fn ok() -> ValidationResult {
    ValidationResult::success(Vec::new())
}

pub fn fail(summary: &str) -> ValidationResult {
    ValidationResult::failure(summary, Vec::new())
}

/// Runs the loop with no cancellation and no listener.
pub fn run(chat: &dyn AiChat, request: &AgentLoopRequest, mut validate: impl FnMut(&str, Option<&str>) -> ValidationResult) -> AgentLoopOutcome {
    AgentLoop::new(chat).run(request, &mut validate, &AiCancellation::new(), &mut |_| {})
}

pub fn fresh(description: &str, max_iterations: i32) -> AgentLoopRequest {
    AgentLoopRequest { max_iterations, ..AgentLoopRequest::new(Mode::Fresh { user_description: description.into() }, AiWidgetSize::Medium, "SYSTEM") }
}

/// A conversation turn about `current` (or a new widget) with the attempts a turn has.
pub fn turn_request(current: Option<&str>, request: &str) -> AgentLoopRequest {
    AgentLoopRequest { max_iterations: AiConversationLimits::MAX_ATTEMPTS_PER_TURN, ..AgentLoopRequest::new(Mode::Turn { context: AiTurnContext::new(current, request, AiWidgetSize::Medium) }, AiWidgetSize::Medium, "SYSTEM") }
}

/// A reply in the form a turn asks for.
pub fn reply(note: &str, code: &str, declaration: Option<&str>) -> String {
    format!("SUMMARY: {note}\n```jsx\n{code}\n```{}", declaration.map(|text| format!("\n```json\n{text}\n```")).unwrap_or_default())
}

/// Runs one whole turn the way the applications do, on this thread. Returns the turn as it ended.
pub fn turn(conversation: &mut AiConversation, request: &str, chat: &dyn AiChat, mut validate: impl FnMut(&str, Option<&str>) -> ValidationResult) -> AiConversationTurn {
    let started = AiConversationTurns::begin(conversation, request, "SYSTEM", None, None, now_milliseconds()).expect("a turn starts");
    let outcome = AgentLoop::new(chat).run(&started.loop_request, &mut validate, &AiCancellation::new(), &mut |event| AiConversationTurns::apply_event(conversation, &started.turn_id, event));
    AiConversationTurns::apply_outcome(conversation, &started.turn_id, Some(&outcome), now_milliseconds());
    conversation.turn(&started.turn_id).unwrap().clone()
}

pub fn succeeded(outcome: &AgentLoopOutcome) -> (&str, Option<&str>, Option<&str>) {
    match outcome {
        AgentLoopOutcome::Succeeded { source, manifest_json, note, .. } => (source, manifest_json.as_deref(), note.as_deref()),
        other => panic!("expected a success, got {other:?}"),
    }
}
