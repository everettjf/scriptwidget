//! The conversation model, its files and its turns, with a scripted model and
//! a fake runtime. Ported from `AiConversationTest.kt`.

mod ai_common;
mod api_common;

use ai_common::*;
use api_common::temporary_directory;
use serde_json::{Value, json};
use sw_core::ai::*;

const DECLARATION: &str = r#"{"permissions":["network"],"networkDomains":["api.example.com"]}"#;

fn new() -> AiConversation {
    AiConversation::new(now_milliseconds())
}

fn says(text: String) -> FakeChat {
    FakeChat::new(vec![text.into()])
}

fn easy(conversation: &mut AiConversation, request: &str, note: &str, code: &str) -> AiConversationTurn {
    turn(conversation, request, &says(reply(note, code, None)), |_, _| ok())
}

#[test]
fn a_turn_that_runs_becomes_a_version_with_its_note() {
    let mut conversation = new();
    let chat = says(reply("Made a clock.", "$render(<vstack/>)", None));
    let turn = turn(&mut conversation, "a clock\nwith seconds", &chat, |_, _| ok());
    assert_eq!((turn.status, turn.note.as_deref(), turn.repairs, turn.usage.total_tokens), (Status::Succeeded, Some("Made a clock."), 0, 15));
    assert_eq!(conversation.title, "a clock");
    let version = conversation.current_version().unwrap();
    assert_eq!((version.number, version.source.as_str()), (1, "$render(<vstack/>)\n"));
    assert_eq!(turn.version_id.as_deref(), Some(version.id.as_str()));
    assert_eq!(version.declaration_json(), None);
    let user = chat.last_of(0);
    assert!(user.contains("The user asks for a new widget:\na clock\nwith seconds"));
    assert!(user.contains("SUMMARY:"));
}

#[test]
fn the_second_turn_sends_the_current_code_and_the_history() {
    let mut conversation = new();
    easy(&mut conversation, "a clock", "Made a clock.", "ONE");
    easy(&mut conversation, "bigger", "Bigger.", "TWO");
    let chat = says(reply("Red.", "THREE", None));
    turn(&mut conversation, "make it red", &chat, |_, _| ok());
    let user = chat.last_of(0);
    assert!(user.contains("1. User: a clock\n   You: Made a clock."));
    assert!(user.contains("2. User: bigger\n   You: Bigger."));
    assert!(user.contains("Current working widget code:\n\n```jsx\nTWO\n"));
    assert!(user.contains("```jsx\nONE\n"), "the version before is sent for reference");
    assert!(user.contains("It declares no network use."));
    assert!(user.contains("The user now asks:\nmake it red"));
    assert_eq!(conversation.versions.iter().map(|version| version.number).collect::<Vec<_>>(), [1, 2, 3]);
    assert_eq!(conversation.versions[2].parent_id.as_deref(), Some(conversation.versions[1].id.as_str()));
}

#[test]
fn a_repaired_turn_counts_its_repairs_and_keeps_the_first_note() {
    let mut conversation = new();
    let chat = FakeChat::new(vec![reply("Made a list.", "BROKEN", None).into(), "```jsx\nFIXED\n```".into()]);
    let turn = turn(&mut conversation, "a list", &chat, |source, _| if source.contains("BROKEN") { fail("scriptError: boom") } else { ok() });
    assert_eq!((turn.status, turn.repairs, turn.note.as_deref(), turn.error_summary), (Status::Succeeded, 1, Some("Made a list."), None));
    assert_eq!(conversation.current_version().unwrap().source, "FIXED\n");
    assert_eq!(conversation.versions.len(), 1);
    assert!(chat.last_of(1).contains("Keep the reply form of this conversation"));
}

#[test]
fn a_turn_that_never_runs_leaves_the_widget_as_it_was() {
    let mut conversation = new();
    easy(&mut conversation, "a clock", "Made a clock.", "GOOD");
    let before = conversation.current_version_id.clone();
    let chat = says(reply("Tried.", "BAD", None));
    let turn = turn(&mut conversation, "add a chart", &chat, |_, _| fail("scriptError: no chart"));
    assert_eq!(turn.status, Status::Unconverged);
    assert_eq!(chat.calls() as i32, AiConversationLimits::MAX_ATTEMPTS_PER_TURN);
    assert_eq!(turn.repairs, i64::from(AiConversationLimits::MAX_ATTEMPTS_PER_TURN));
    assert_eq!((turn.error_summary.as_deref(), turn.failed_source.as_deref(), turn.version_id), (Some("scriptError: no chart"), Some("BAD\n"), None));
    assert_eq!(conversation.current_version_id, before);
    assert_eq!(conversation.versions.len(), 1);
    assert!(!conversation.history_for_prompt().iter().any(|told| told.id == turn.id), "a failed turn is not history");
}

#[test]
fn a_provider_failure_is_shown_and_can_be_retried() {
    let mut conversation = new();
    let failed = turn(&mut conversation, "a clock", &FakeChat::new(vec![AiClientError::new(AiErrorKind::Http, "The provider refused the request (401).").into()]), |_, _| ok());
    assert_eq!((failed.status, failed.error_summary.as_deref()), (Status::Failed, Some("The provider refused the request (401).")));
    assert!(conversation.versions.is_empty());
    let started = AiConversationTurns::retry(&mut conversation, &failed.id, "SYSTEM", None, 5).unwrap();
    assert_eq!(conversation.turn(&started.turn_id).unwrap().request, "a clock");
    assert_eq!(conversation.turns.iter().map(|turn| turn.id.as_str()).collect::<Vec<_>>(), [started.turn_id.as_str()]);
    let outcome = run(&says(reply("Made a clock.", "OK", None)), &started.loop_request, |_, _| ok());
    AiConversationTurns::apply_outcome(&mut conversation, &started.turn_id, Some(&outcome), 6);
    assert_eq!(conversation.turn(&started.turn_id).unwrap().status, Status::Succeeded);
    assert!(AiConversationTurns::retry(&mut conversation, &started.turn_id, "SYSTEM", None, 7).is_none(), "a turn that ran can not be sent again");
}

/// Android's "unknown failure shows no exception text": the outcome that has nothing to say.
#[test]
fn a_failure_without_an_outcome_shows_a_fixed_sentence() {
    let mut conversation = new();
    let started = AiConversationTurns::begin(&mut conversation, "a clock", "SYSTEM", None, None, 1).unwrap();
    AiConversationTurns::apply_outcome(&mut conversation, &started.turn_id, None, 2);
    let turn = conversation.turn(&started.turn_id).unwrap();
    assert_eq!((turn.status, turn.error_summary.as_deref()), (Status::Failed, Some("The request could not be completed.")));
    assert!(!conversation.is_running());
}

#[test]
fn a_cancelled_turn_changes_nothing() {
    let mut conversation = new();
    let started = AiConversationTurns::begin(&mut conversation, "a clock", "SYSTEM", None, None, 1).unwrap();
    assert!(AiConversationTurns::begin(&mut conversation, "another", "SYSTEM", None, None, 2).is_none(), "one turn at a time");
    let cancellation = AiCancellation::new();
    cancellation.cancel();
    let outcome = AgentLoop::new(&FakeChat::texts(&["unused"])).run(&started.loop_request, &mut |_, _| ok(), &cancellation, &mut |_| {});
    AiConversationTurns::apply_outcome(&mut conversation, &started.turn_id, Some(&outcome), 3);
    assert_eq!(conversation.turn(&started.turn_id).unwrap().status, Status::Cancelled);
    assert!(conversation.versions.is_empty());
    assert!(!conversation.is_running());
}

#[test]
fn the_declaration_of_a_turn_is_kept_with_its_version_and_sent_back() {
    let mut conversation = new();
    let mut validated: Vec<Option<String>> = Vec::new();
    turn(&mut conversation, "bitcoin price", &says(reply("Shows the price.", "FETCH", Some(r#"{"permissions":["network"],"networkDomains":["API.Example.com"]}"#))), |_, manifest| {
        validated.push(manifest.map(str::to_owned));
        ok()
    });
    assert_eq!(conversation.current_version().unwrap().network_domains, ["api.example.com"]);
    assert_eq!(validated, [Some(DECLARATION.to_owned())]);
    let chat = says(reply("Offline now.", "STATIC", None));
    turn(&mut conversation, "use fixed data", &chat, |_, _| ok());
    assert!(chat.last_of(0).contains(&format!("Its network declaration: {DECLARATION}")));
    assert!(conversation.current_version().unwrap().network_domains.is_empty(), "a version without a declaration has no network");
}

#[test]
fn an_invalid_declaration_is_not_run_and_is_repaired() {
    let mut conversation = new();
    let mut ran: Vec<String> = Vec::new();
    let chat = FakeChat::new(vec![reply("Reads the calendar.", "CAL", Some(r#"{"permissions":["calendar"],"networkDomains":[]}"#)).into(), reply("Plain.", "PLAIN", None).into()]);
    let turn = turn(&mut conversation, "my calendar", &chat, |source, _| {
        ran.push(source.to_owned());
        ok()
    });
    assert_eq!(ran, ["PLAIN\n"]);
    assert_eq!(turn.repairs, 1);
    assert!(chat.last_of(1).contains("Invalid package declaration"));
}

#[test]
fn going_back_and_asking_again_leaves_the_later_turns_behind() {
    let mut conversation = new();
    let first = easy(&mut conversation, "a clock", "Clock.", "ONE");
    let second = easy(&mut conversation, "blue", "Blue.", "TWO");
    assert!(conversation.select_version(first.version_id.as_deref().unwrap(), 9));
    let chat = says(reply("Green.", "THREE", None));
    let third = turn(&mut conversation, "green", &chat, |_, _| ok());
    let abandoned = |turn: &AiConversationTurn| conversation.turn(&turn.id).unwrap().is_abandoned;
    assert_eq!((abandoned(&first), abandoned(&second), abandoned(&third)), (false, true, false));
    let user = chat.last_of(0);
    assert!(!user.contains("blue"), "a turn left behind is not sent");
    assert!(user.contains("```jsx\nONE\n"));
    assert_eq!(conversation.current_version().unwrap().parent_id, first.version_id);
    assert_eq!(conversation.current_version().unwrap().number, 3);
    assert!(!conversation.select_version("missing", 10));
}

#[test]
fn code_changed_outside_the_conversation_becomes_a_version_that_is_not_history() {
    let mut conversation = new();
    easy(&mut conversation, "a clock", "Clock.", "ONE");
    assert!(!conversation.adopt_external_source("ONE\n", Vec::new(), 2), "the same code adds nothing");
    assert!(conversation.adopt_external_source("EDITED", vec!["a.example.com".into()], 3));
    let manual = conversation.turns.last().unwrap().clone();
    assert!(manual.is_manual_edit);
    assert_eq!(conversation.current_version().unwrap().number, 2);
    assert_eq!(conversation.current_version().unwrap().network_domains, ["a.example.com"]);
    let chat = says(reply("Red.", "THREE", None));
    turn(&mut conversation, "red", &chat, |_, _| ok());
    let user = chat.last_of(0);
    assert!(user.contains("```jsx\nEDITED\n") && user.contains("1. User: a clock") && !user.contains("2. User:"));
    assert!(AiConversationTurns::retry(&mut conversation, &manual.id, "SYSTEM", None, 4).is_none());
}

#[test]
fn only_the_newest_versions_are_kept_and_numbers_are_not_reused() {
    let mut conversation = new();
    let limit = AiConversationLimits::MAX_VERSIONS;
    for index in 0..limit + 5 {
        conversation.add_version(&format!("v{index}"), Vec::new(), 1);
    }
    assert_eq!(conversation.versions.len(), limit);
    assert_eq!(conversation.current_version().unwrap().number, limit as i64 + 5);
    assert_eq!(conversation.versions.iter().map(|version| version.number).min(), Some(6));
    let first = conversation.versions[0].id.clone();
    conversation.select_version(&first, 2);
    conversation.add_version("another", Vec::new(), 3);
    assert_eq!(conversation.current_version().unwrap().number, limit as i64 + 6);
    assert_eq!(conversation.latest_version().unwrap().source, "another");
}

#[test]
fn a_conversation_survives_its_file() {
    let mut conversation = new();
    conversation.size = AiWidgetSize::Large;
    turn(&mut conversation, "bitcoin", &says(reply("Price.", "FETCH", Some(DECLARATION))), |_, _| ok());
    turn(&mut conversation, "chart", &says(reply("Tried.", "BAD", None)), |_, _| fail("scriptError: x"));
    conversation.package_id = Some("Bitcoin".into());
    let text = conversation.to_json().to_string();
    let read = AiConversation::from_json(&serde_json::from_str(&text).unwrap()).unwrap();
    assert_eq!(read.to_json().to_string(), text);
    assert_eq!(read, conversation);
    assert_eq!((read.size, read.package_id.as_deref()), (AiWidgetSize::Large, Some("Bitcoin")));
    assert_eq!(read.current_version().unwrap().network_domains, ["api.example.com"]);
    assert_eq!((read.turns[1].status, read.turns[1].failed_source.as_deref()), (Status::Unconverged, Some("BAD\n")));
}

#[test]
fn a_running_turn_is_read_back_as_interrupted() {
    let mut conversation = new();
    AiConversationTurns::begin(&mut conversation, "a clock", "SYSTEM", None, None, 1).unwrap();
    let mut read = AiConversation::from_json(&conversation.to_json()).unwrap();
    assert_eq!(read.turns.len(), 1);
    assert_eq!(read.turns[0].status, Status::Interrupted);
    assert!(!read.is_running());
    let id = read.turns[0].id.clone();
    assert!(AiConversationTurns::retry(&mut read, &id, "SYSTEM", None, 2).is_some());
}

#[test]
fn malformed_conversations_fail_closed() {
    let mut conversation = new();
    conversation.add_version("x", Vec::new(), 1);
    let good = conversation.to_json();
    let with = |key: &str, value: Value| {
        let mut changed = good.clone();
        changed[key] = value;
        AiConversation::from_json(&changed)
    };
    assert!(with("formatVersion", json!(2)).is_none());
    assert!(with("id", json!("../../escape")).is_none());
    assert!(with("id", json!("short")).is_none());
    assert!(with("versions", json!("none")).is_none());
    assert!(with("versions", json!([{ "id": "a" }])).is_none());
    assert!(with("turns", json!([{ "id": "t", "request": "r", "status": "unknown", "createdAt": 1 }])).is_none(), "an unknown status is not guessed");
    assert!(with("packageId", json!(5)).is_none());
    assert!(AiConversation::from_json(&json!({})).is_none());
    assert!(AiConversation::from_json(&json!([1])).is_none());
    assert!(AiConversation::from_json(&good).is_some());
}

#[test]
fn the_store_keeps_conversations_and_ignores_what_is_not_one() {
    use std::os::unix::fs::PermissionsExt;
    let directory = temporary_directory("ai-store").join("ai-conversations");
    let store = AiConversationStore::new(&directory);
    assert!(store.summaries(false).is_empty());
    let mut draft = new();
    easy(&mut draft, "a clock", "Clock.", "ONE");
    draft.updated_at = 10;
    let mut bound = new();
    easy(&mut bound, "weather", "Weather.", "W");
    bound.package_id = Some("Weather".into());
    bound.updated_at = 20;
    assert!(store.save(&draft) && store.save(&bound));
    std::fs::write(directory.join("notes.json"), "{\"hello\": 1}").unwrap();
    std::fs::write(directory.join("broken.json"), "{").unwrap();
    std::fs::write(directory.join("copied-under-another-name.json"), draft.to_json().to_string()).unwrap();
    // A link to a conversation elsewhere is not read.
    let outside = temporary_directory("ai-store-outside").join("elsewhere.json");
    let mut foreign = new();
    easy(&mut foreign, "foreign", "Foreign.", "F");
    std::fs::write(&outside, foreign.to_json().to_string()).unwrap();
    std::os::unix::fs::symlink(&outside, directory.join(format!("{}.json", foreign.id))).unwrap();

    assert_eq!(store.summaries(false).iter().map(|summary| summary.id.as_str()).collect::<Vec<_>>(), [bound.id.as_str(), draft.id.as_str()]);
    assert_eq!(store.summaries(true).iter().map(|summary| summary.id.as_str()).collect::<Vec<_>>(), [draft.id.as_str()]);
    assert_eq!(store.load(&draft.id).unwrap().title, "a clock");
    assert_eq!(store.latest("Weather").unwrap().id, bound.id);
    assert!(store.latest("Missing").is_none());
    assert!(store.load("../notes").is_none() && store.load(&foreign.id).is_none());
    assert!(directory.join("notes.json").is_file() && directory.join("broken.json").is_file(), "foreign files are left alone");
    // Requests and sources are the user's: the folder and the files are for the user only.
    assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(directory.join(format!("{}.json", draft.id))).unwrap().permissions().mode() & 0o777, 0o600);
    store.delete(&draft.id);
    assert!(store.load(&draft.id).is_none());
    store.delete_for_package("Weather");
    assert!(store.latest("Weather").is_none());
    assert!(!std::fs::read_dir(&directory).unwrap().any(|entry| entry.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
    assert_eq!(std::fs::read_to_string(&outside).unwrap(), foreign.to_json().to_string(), "what a link points at is not touched");
}

#[test]
fn the_store_keeps_only_the_newest_conversations() {
    let store = AiConversationStore::new(temporary_directory("ai-store-many"));
    let ids: Vec<String> = (1..=AiConversationLimits::MAX_CONVERSATIONS + 3)
        .map(|index| {
            let mut conversation = new();
            conversation.begin_turn(&format!("request {index}"), 1);
            conversation.mark_running_turns_interrupted();
            conversation.updated_at = index as i64;
            assert!(store.save(&conversation));
            conversation.id
        })
        .collect();
    let kept: Vec<String> = store.summaries(false).into_iter().map(|summary| summary.id).collect();
    assert_eq!(kept.len(), AiConversationLimits::MAX_CONVERSATIONS);
    assert!(!ids[..3].iter().any(|id| kept.contains(id)));
    assert_eq!(kept.first(), ids.last());
}

#[test]
fn a_conversation_file_holds_no_credential_or_provider() {
    let mut conversation = new();
    easy(&mut conversation, "a clock", "Clock.", "ONE");
    fn collect(value: &Value, keys: &mut Vec<String>) {
        match value {
            Value::Object(object) => {
                for (key, value) in object {
                    keys.push(key.clone());
                    collect(value, keys);
                }
            }
            Value::Array(items) => items.iter().for_each(|item| collect(item, keys)),
            _ => {}
        }
    }
    let mut keys = Vec::new();
    collect(&conversation.to_json(), &mut keys);
    assert!(keys.len() > 20);
    let counts = ["promptTokens", "completionTokens", "totalTokens"];
    for key in keys.iter().filter(|key| !counts.contains(&key.as_str())) {
        assert!(!["key", "token", "secret", "authorization", "baseurl", "model", "provider"].iter().any(|word| key.to_lowercase().contains(word)), "{key}");
    }
}

#[test]
fn turn_replies_are_read_leniently() {
    let full = PromptBuilder::parse_turn_reply("SUMMARY: Made it blue.\n```jsx\n$render(<vstack/>) // end\n```\n```json\n{\"permissions\":[\"network\"],\"networkDomains\":[\"a.example.com\"]}\n```");
    assert_eq!(full.note.as_deref(), Some("Made it blue."));
    assert_eq!(full.candidate.source, "$render(<vstack/>) // end\n");
    assert!(full.candidate.manifest_json.unwrap().contains("a.example.com"));
    let bare = PromptBuilder::parse_turn_reply("$render(<vstack/>)");
    assert_eq!((bare.note, bare.candidate.source.as_str()), (None, "$render(<vstack/>)\n"));
    let unfenced = PromptBuilder::parse_turn_reply("Summary: plain\n$render(<vstack/>)");
    assert_eq!((unfenced.note.as_deref(), unfenced.candidate.source.as_str()), (Some("plain"), "$render(<vstack/>)\n"));
    assert_eq!(PromptBuilder::parse_turn_reply("SUMMARY: nothing").candidate.source, "");
    let long = PromptBuilder::parse_turn_reply(&format!("SUMMARY: {}\n```jsx\nA\n```", "x".repeat(900)));
    assert_eq!(long.note.unwrap().chars().count(), AiConversationLimits::NOTE_CHARACTERS + 1);
    // Text that is not ASCII is cut between characters.
    assert_eq!(PromptBuilder::clip(&"小".repeat(10), 4), "小小小小…");
}

#[test]
fn skills_and_diagnostics_are_part_of_a_turn() {
    let mut conversation = new();
    conversation.add_version("ONE", Vec::new(), 1);
    let started = AiConversationTurns::begin(&mut conversation, "fix it", "SYSTEM", Some("Skill: use rounded corners"), Some("scriptError: line 3"), 2).unwrap();
    let Mode::Turn { context } = &started.loop_request.mode else { panic!("a turn") };
    let text = PromptBuilder::user_prompt_turn(context);
    assert!(text.contains("Apply these ScriptWidget skills in every turn:\nSkill: use rounded corners"));
    assert!(text.contains("The latest local ScriptWidget runtime diagnostic is:\nscriptError: line 3"));
    assert_eq!(started.loop_request.max_iterations, AiConversationLimits::MAX_ATTEMPTS_PER_TURN);
    assert!(AiConversationTurns::begin(&mut new(), "   ", "SYSTEM", None, None, 3).is_none());
}
