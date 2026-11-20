//! The generate → run → fix loop with a scripted model and a fake runtime.
//! Ported from `AgentLoopTest.kt`, and the loop cases of `AiSourceEditsTest.kt`
//! and `AiJsxCheckTest.kt`.

mod ai_common;

use ai_common::*;
use sw_core::ai::*;

const USAGE_PER_CALL: AiTokenUsage = AiTokenUsage { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 };

fn request() -> AgentLoopRequest {
    fresh("a clock", 20)
}

fn describe(event: &AgentLoopEvent) -> String {
    match event {
        AgentLoopEvent::Thinking { iteration } => format!("thinking{iteration}"),
        AgentLoopEvent::Produced { iteration, .. } => format!("produced{iteration}"),
        AgentLoopEvent::Running { iteration } => format!("running{iteration}"),
        AgentLoopEvent::RanFailed { iteration, .. } => format!("failed{iteration}"),
        AgentLoopEvent::RanSucceeded { iteration } => format!("succeeded{iteration}"),
        AgentLoopEvent::TokensUsed { usage } => format!("tokens{}", usage.total_tokens),
        AgentLoopEvent::Note { iteration, .. } => format!("note{iteration}"),
        AgentLoopEvent::Partial { iteration, .. } => format!("partial{iteration}"),
    }
}

fn roles(conversation: &[AiMessage]) -> Vec<Role> {
    conversation.iter().map(|message| message.role).collect()
}

#[test]
fn succeeds_on_the_first_try() {
    let chat = FakeChat::texts(&["```jsx\n$render(<vstack/>)\n```"]);
    let mut events: Vec<String> = Vec::new();
    let mut validated: Vec<(String, Option<String>)> = Vec::new();
    let outcome = AgentLoop::new(&chat).run(
        &request(),
        &mut |source, manifest| {
            validated.push((source.to_owned(), manifest.map(str::to_owned)));
            ok()
        },
        &AiCancellation::new(),
        &mut |event| events.push(describe(event)),
    );
    assert_eq!(succeeded(&outcome), ("$render(<vstack/>)", None, None));
    assert_eq!(outcome.usage(), USAGE_PER_CALL);
    assert_eq!(validated, [("$render(<vstack/>)".to_owned(), None)]);
    assert_eq!(events, ["thinking1", "tokens15", "produced1", "running1", "succeeded1"]);
    let conversations = chat.conversations();
    assert_eq!(conversations.len(), 1);
    assert_eq!(roles(&conversations[0]), [Role::System, Role::User]);
    assert_eq!(conversations[0][0].content, "SYSTEM");
    assert!(conversations[0][1].content.contains("Widget size: medium") && conversations[0][1].content.contains("a clock"));
}

#[test]
fn fixes_after_one_error_by_feeding_the_failure_back() {
    let chat = FakeChat::texts(&["$render(<broken>)", "$render(<vstack/>)"]);
    let mut events: Vec<String> = Vec::new();
    let outcome = AgentLoop::new(&chat).run(
        &request(),
        &mut |source, _| if source.contains("broken") { ValidationResult::failure("scriptError: broken is not defined", vec!["[log] start".into(), "[error] boom".into()]) } else { ok() },
        &AiCancellation::new(),
        &mut |event| events.push(describe(event)),
    );
    assert_eq!(succeeded(&outcome).0, "$render(<vstack/>)");
    assert_eq!(outcome.usage(), AiTokenUsage::new(20, 10, 30));
    assert_eq!(events, ["thinking1", "tokens15", "produced1", "running1", "failed1", "thinking2", "tokens30", "produced2", "running2", "succeeded2"]);
    let conversations = chat.conversations();
    let second = &conversations[1];
    assert_eq!(roles(second), [Role::System, Role::User, Role::Assistant, Role::User]);
    assert_eq!(conversations[0][1], second[1]);
    assert_eq!(second[2].content, "$render(<broken>)");
    for part in ["scriptError: broken is not defined", "[error] boom", "$render(<broken>)"] {
        assert!(second[3].content.contains(part), "{part}");
    }
}

#[test]
fn gives_up_at_the_cap_and_returns_the_last_attempt() {
    let chat = FakeChat::texts(&["attempt"]);
    let mut runs = 0;
    let outcome = run(&chat, &fresh("a clock", 3), |_, _| {
        runs += 1;
        fail(&format!("scriptError: still broken {runs}"))
    });
    let AgentLoopOutcome::Exhausted { last_source, last_error, usage, .. } = outcome else { panic!("{outcome:?}") };
    assert_eq!((chat.calls(), runs), (3, 3));
    assert_eq!(last_source.as_deref(), Some("attempt"));
    assert_eq!(last_error.as_deref(), Some("scriptError: still broken 3"));
    assert_eq!(usage.total_tokens, 45);
}

#[test]
fn iteration_limit_is_clamped_like_swift() {
    assert_eq!(AgentLoop::iteration_limit(0), 1);
    assert_eq!(AgentLoop::iteration_limit(-5), 1);
    assert_eq!(AgentLoop::iteration_limit(20), 20);
    assert_eq!(AgentLoop::iteration_limit(5000), 100);
    let chat = FakeChat::texts(&["attempt"]);
    run(&chat, &fresh("a clock", 0), |_, _| fail("e"));
    assert_eq!(chat.calls(), 1);
}

#[test]
fn cancellation_before_start_makes_no_call() {
    let chat = FakeChat::texts(&["x"]);
    let cancellation = AiCancellation::new();
    cancellation.cancel();
    let outcome = AgentLoop::new(&chat).run(&request(), &mut |_, _| ok(), &cancellation, &mut |_| {});
    assert!(matches!(outcome, AgentLoopOutcome::Cancelled { .. }));
    assert_eq!(chat.calls(), 0);
}

#[test]
fn cancellation_during_the_model_call_stops_before_validation() {
    let cancellation = AiCancellation::new();
    let inside = cancellation.clone();
    let chat = FakeChat::with_hook(vec!["code".into()], move |_| inside.cancel());
    let mut validated = false;
    let outcome = AgentLoop::new(&chat).run(
        &request(),
        &mut |_, _| {
            validated = true;
            ok()
        },
        &cancellation,
        &mut |_| {},
    );
    assert!(matches!(outcome, AgentLoopOutcome::Cancelled { .. }));
    assert!(!validated);
    assert_eq!(outcome.usage().total_tokens, 15);
}

#[test]
fn cancellation_surfaced_as_a_client_error_is_not_a_failure() {
    let chat = FakeChat::new(vec![AiClientError::cancelled().into()]);
    assert!(matches!(run(&chat, &request(), |_, _| ok()), AgentLoopOutcome::Cancelled { .. }));
}

#[test]
fn cancellation_during_validation_wins() {
    let cancellation = AiCancellation::new();
    let mut events: Vec<String> = Vec::new();
    let chat = FakeChat::texts(&["code"]);
    let outcome = AgentLoop::new(&chat).run(
        &request(),
        &mut |_, _| {
            cancellation.cancel();
            ok()
        },
        &cancellation,
        &mut |event| events.push(describe(event)),
    );
    assert!(matches!(outcome, AgentLoopOutcome::Cancelled { .. }));
    assert!(!events.contains(&"succeeded1".to_owned()));
}

/// In Kotlin a model can also throw something that is not a client error, whose text is then
/// not shown. A model here can only return an `AiClientError`; one without text gets the fixed sentence.
#[test]
fn provider_failure_ends_the_loop_with_its_safe_message() {
    let chat = FakeChat::new(vec![AiClientError::with_status(AiErrorKind::Http, "The AI server rejected authentication.", 401).into()]);
    let outcome = run(&chat, &request(), |_, _| ok());
    assert_eq!(outcome, AgentLoopOutcome::Failed { message: "The AI server rejected authentication.".into(), usage: AiTokenUsage::ZERO });
    let silent = FakeChat::new(vec![AiClientError::new(AiErrorKind::Network, "").into()]);
    assert_eq!(run(&silent, &request(), |_, _| ok()), AgentLoopOutcome::Failed { message: "The AI request failed.".into(), usage: AiTokenUsage::ZERO });
}

#[test]
fn network_declaration_is_canonicalized_and_passed_to_validation() {
    let reply = "$render(<vstack/>)\n\n```json\n{\"networkDomains\": [\"API.example.com\"], \"permissions\": [\"network\"]}\n```";
    let mut seen: Option<String> = None;
    let chat = FakeChat::texts(&[reply]);
    let outcome = run(&chat, &request(), |_, manifest| {
        seen = manifest.map(str::to_owned);
        ok()
    });
    assert_eq!(seen.as_deref(), Some(r#"{"permissions":["network"],"networkDomains":["api.example.com"]}"#));
    assert_eq!(succeeded(&outcome), ("$render(<vstack/>)", seen.as_deref(), None));
}

#[test]
fn invalid_declaration_is_fed_back_without_running_the_widget() {
    let chat = FakeChat::texts(&["$render(<vstack/>)\n```json\n{\"permissions\": [\"location\"]}\n```", "$render(<vstack/>)"]);
    let mut runs = 0;
    let outcome = run(&chat, &request(), |_, _| {
        runs += 1;
        ok()
    });
    assert!(matches!(outcome, AgentLoopOutcome::Succeeded { .. }));
    assert_eq!(runs, 1);
    let repair = &chat.conversations()[1][3].content;
    assert!(repair.contains("The network declaration block is not valid: \"permissions\" must be exactly [\"network\"]; no other permission can be declared."));
    assert!(!repair.contains("Invalid package declaration"));
}

#[test]
fn empty_and_truncated_replies_are_retried() {
    let cut = AiChatResult { truncated: true, ..AiChatResult::new("$render(<vsta", AiTokenUsage::ZERO) };
    let chat = FakeChat::new(vec!["```\n```".into(), cut.into(), "$render(<vstack/>)".into()]);
    let mut runs = 0;
    let outcome = run(&chat, &request(), |_, _| {
        runs += 1;
        ok()
    });
    assert!(matches!(outcome, AgentLoopOutcome::Succeeded { .. }));
    assert_eq!(runs, 1);
    assert!(chat.conversations()[1][3].content.contains("no JSX code"));
    assert!(chat.conversations()[2][3].content.contains("cut off"));
}

#[test]
fn refine_sends_the_current_code_and_keeps_it_when_the_first_call_fails() {
    let mode = Mode::Refine { current_code: "OLD CODE".into(), instruction: "make it blue".into(), current_declaration: Some(r#"{"permissions":["network"],"networkDomains":["a.example.com"]}"#.into()), runtime_diagnostic: None };
    let chat = FakeChat::texts(&["NEW CODE"]);
    let outcome = run(&chat, &AgentLoopRequest::new(mode, AiWidgetSize::Medium, "SYSTEM"), |_, _| ok());
    // No declaration in the reply: the caller keeps the package's existing manifest.
    assert_eq!(succeeded(&outcome), ("NEW CODE", None, None));
    let first = &chat.conversations()[0];
    assert_eq!(first.len(), 2);
    for part in ["OLD CODE", "make it blue", "a.example.com"] {
        assert!(first[1].content.contains(part), "{part}");
    }
}

#[test]
fn skills_text_is_appended_to_the_user_request_only() {
    let chat = FakeChat::texts(&["code"]);
    run(&chat, &AgentLoopRequest { skills_text: Some("- Tidy v1:\n  be tidy".into()), ..request() }, |_, _| ok());
    let conversation = &chat.conversations()[0];
    assert_eq!(conversation[0].content, "SYSTEM");
    assert!(conversation[1].content.contains("a clock\n\nApply these ScriptWidget skills:\n- Tidy v1:\n  be tidy"));
}

// Replies written as edit blocks (AiSourceEditsTest.kt)

const GOOD: &str = "$render(<vstack><text>Hello</text></vstack>)\n";
const BETTER: &str = "$render(<vstack><text>Hello</text><text>World</text></vstack>)\n";

fn edit(summary: &str, pairs: &[(&str, &str)]) -> String {
    let blocks: Vec<String> = pairs.iter().map(|(search, replace)| format!("<<<<<<< SEARCH\n{search}\n=======\n{replace}\n>>>>>>> REPLACE")).collect();
    format!("SUMMARY: {summary}\n```edit\n{}\n```", blocks.join("\n"))
}

fn turn_about(current: Option<&str>) -> AgentLoopRequest {
    turn_request(current, "Say Hi instead")
}

#[test]
fn a_turn_answered_with_edit_blocks_changes_only_that_place() {
    let chat = FakeChat::new(vec![edit("Says Hi now.", &[("<text>Hello</text>", "<text>Hi</text>")]).into()]);
    let mut validated: Vec<String> = Vec::new();
    let outcome = run(&chat, &turn_about(Some(GOOD)), |source, _| {
        validated.push(source.to_owned());
        ok()
    });
    assert_eq!(succeeded(&outcome), ("$render(<vstack><text>Hi</text></vstack>)\n", None, Some("Says Hi now.")));
    assert_eq!(validated, ["$render(<vstack><text>Hi</text></vstack>)\n"]);
    assert_eq!(chat.calls(), 1);
}

#[test]
fn an_edit_that_does_not_apply_is_sent_back_and_the_full_code_is_accepted() {
    let chat = FakeChat::new(vec![edit("Says Hi now.", &[("<text>Goodbye</text>", "<text>Hi</text>")]).into(), format!("SUMMARY: Says Hi now.\n```jsx\n{BETTER}```").into()]);
    let mut validated: Vec<String> = Vec::new();
    let outcome = run(&chat, &turn_about(Some(GOOD)), |source, _| {
        validated.push(source.to_owned());
        ok()
    });
    assert_eq!(succeeded(&outcome).0, BETTER);
    assert_eq!(validated, [BETTER], "nothing runs from a refused edit");
    let repair = chat.last_of(1);
    assert!(repair.contains("could not be applied") && repair.contains("is not in the current code"));
    assert!(repair.contains("<text>Hello</text>"), "the code it was shown is sent again");
}

#[test]
fn edits_that_never_apply_end_the_turn_without_a_candidate() {
    let chat = FakeChat::new(vec![edit("Tried.", &[("nowhere", "x")]).into()]);
    let mut runs = 0;
    let outcome = run(&chat, &turn_about(Some(GOOD)), |_, _| {
        runs += 1;
        ok()
    });
    assert!(matches!(outcome, AgentLoopOutcome::Exhausted { .. }));
    assert_eq!(runs, 0);
    assert_eq!(chat.calls() as i32, AiConversationLimits::MAX_ATTEMPTS_PER_TURN);
}

#[test]
fn edit_blocks_for_a_new_widget_are_refused() {
    let chat = FakeChat::new(vec![edit("Tried.", &[("a", "b")]).into(), format!("SUMMARY: Made it.\n```jsx\n{GOOD}```").into()]);
    assert_eq!(succeeded(&run(&chat, &turn_about(None), |_, _| ok())).0, GOOD);
}

#[test]
fn a_repair_written_as_edits_changes_the_failed_attempt() {
    let broken = "$render(<vstack><text>Hi</text></vstac>)\n";
    let chat = FakeChat::new(vec![format!("SUMMARY: Says Hi now.\n```jsx\n{broken}```").into(), edit("Fixed the tag.", &[("</vstac>", "</vstack>")]).into()]);
    let outcome = run(&chat, &turn_about(Some(GOOD)), |source, _| if source.contains("</vstac>") { fail("transformError") } else { ok() });
    assert_eq!(succeeded(&outcome).0, "$render(<vstack><text>Hi</text></vstack>)\n");
}

// The check for tags and attributes that do not exist, inside the loop (AiJsxCheckTest.kt)

#[test]
fn the_loop_sends_a_made_up_value_back_although_the_widget_runs() {
    let wrong = "```jsx\n$render(<date date={new Date()} style=\"weekday\" />)\n```";
    let right = "```jsx\n$render(<date date={new Date()} style=\"date\" />)\n```";
    let chat = FakeChat::texts(&[wrong, right]);
    let mut ran = 0;
    let outcome = run(&chat, &fresh("the weekday", 4), |_, _| {
        ran += 1;
        ok()
    });
    assert!(succeeded(&outcome).0.contains("style=\"date\""));
    assert_eq!(ran, 2, "both ran; running alone would have accepted the first");
    assert!(chat.last_of(1).contains("style=\"weekday\" on <date> is not one of its values"));
}

#[test]
fn on_the_last_attempt_a_widget_that_runs_is_kept() {
    let chat = FakeChat::texts(&["```jsx\n$render(<date date={new Date()} style=\"weekday\" />)\n```"]);
    let outcome = run(&chat, &fresh("the weekday", 3), |_, _| ok());
    assert!(matches!(outcome, AgentLoopOutcome::Succeeded { .. }));
    assert_eq!(chat.calls(), 3);
}

/// What Linux does not have is sent back like any other made-up tag: the scrolling list of Android.
#[test]
fn the_loop_sends_the_android_list_back_on_linux() {
    let chat = FakeChat::texts(&["```jsx\n$render(<list spacing=\"4\"><text>a</text></list>)\n```", "```jsx\n$render(<vstack><text>a</text></vstack>)\n```"]);
    let outcome = run(&chat, &fresh("a list", 4), |_, _| ok());
    assert!(succeeded(&outcome).0.contains("<vstack>"));
    assert!(chat.last_of(1).contains("<list> is not a ScriptWidget tag"));
}
