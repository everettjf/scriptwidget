//! Edit replies read, applied and refused; what changed between versions; and
//! the notice for a conversation that has grown. Ported from
//! `AiSourceEditsTest.kt` (its loop cases are in `ai_agent_loop.rs`).

use sw_core::ai::source_diff::{Kind, Line, Summary};
use sw_core::ai::*;

fn reason<T: std::fmt::Debug>(result: Result<T, source_edits::Failure>) -> String {
    result.expect_err("a refusal").reason
}

#[test]
fn edit_blocks_are_read_and_applied_in_order() {
    let reply = "SUMMARY: Two changes.\n```edit\n<<<<<<< SEARCH\n  <text>Hello</text>\n=======\n  <text>Hi</text>\n  <text>there</text>\n>>>>>>> REPLACE\n<<<<<<< SEARCH\nconst a = 1;\n=======\n>>>>>>> REPLACE\n```";
    let edits = AiSourceEdits::parse(reply).unwrap().unwrap();
    assert_eq!(edits, [AiSourceEdit::new("  <text>Hello</text>", "  <text>Hi</text>\n  <text>there</text>"), AiSourceEdit::new("const a = 1;", "")]);
    let source = "const a = 1;\r\n$render(\n  <text>Hello</text>\n)";
    assert_eq!(AiSourceEdits::apply(&edits, source).unwrap(), "\n$render(\n  <text>Hi</text>\n  <text>there</text>\n)\n");
    assert_eq!(AiSourceEdits::parse("SUMMARY: x\n```jsx\n$render(<text>a</text>)\n```").unwrap(), None, "a full reply has no edits");
    assert!(AiSourceEdits::is_edit_reply("  <<<<<<< SEARCH  \r\na") && !AiSourceEdits::is_edit_reply("a <<<<<<< SEARCH b"));
}

#[test]
fn an_edit_that_is_missing_ambiguous_or_malformed_is_refused() {
    let source = "<text>a</text>\n<text>a</text>\n<text>b</text>\n";
    assert!(reason(AiSourceEdits::apply(&[AiSourceEdit::new("<text>c</text>", "x")], source)).contains("is not in the current code"));
    assert!(reason(AiSourceEdits::apply(&[AiSourceEdit::new("<text>a</text>", "x")], source)).contains("2 times"));
    assert!(reason(AiSourceEdits::apply(&[AiSourceEdit::new("<text>b</text>", "x"), AiSourceEdit::new("nowhere", "y")], source)).contains("edit 2"));
    assert!(reason(AiSourceEdits::parse("<<<<<<< SEARCH\na\n=======\nb")).contains("no >>>>>>> REPLACE"));
    assert!(reason(AiSourceEdits::parse("<<<<<<< SEARCH\n\n=======\nb\n>>>>>>> REPLACE")).contains("nothing in its SEARCH"));
    assert!(reason(AiSourceEdits::parse("<<<<<<< SEARCH\na\n>>>>>>> REPLACE")).contains("ends without"));
    assert!(reason(AiSourceEdits::parse("<<<<<<< SEARCH\na\n<<<<<<< SEARCH\nb")).contains("starts before"));
    let many = vec!["<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE"; AiSourceEdits::MAX_EDITS + 1].join("\n");
    assert!(reason(AiSourceEdits::parse(&many)).contains("more than"));
}

#[test]
fn the_turn_prompt_offers_edit_blocks_only_when_there_is_code_to_change() {
    let prompt = |current: Option<&str>| PromptBuilder::user_prompt_turn(&AiTurnContext::new(current, "x", AiWidgetSize::Medium));
    assert!(prompt(Some("CODE")).contains(AiSourceEdits::SEARCH_MARKER));
    assert!(!prompt(None).contains(AiSourceEdits::SEARCH_MARKER));
}

#[test]
fn the_diff_shows_changed_lines_with_context_and_leaves_the_rest_out() {
    let old: String = (1..=20).map(|number| format!("line {number}\n")).collect();
    let new = old.replace("line 10\n", "line ten\nline ten and a half\n");
    assert_eq!(AiSourceDiff::summary(&old, &new), Some(Summary { added: 2, removed: 1 }));
    let lines = AiSourceDiff::lines(&old, &new).unwrap();
    use Kind::*;
    assert_eq!(lines.iter().map(|line| line.kind).collect::<Vec<_>>(), [Skipped, Same, Same, Same, Removed, Added, Added, Same, Same, Same, Skipped]);
    assert_eq!(lines.iter().filter(|line| line.kind == Skipped).map(|line| line.skipped).collect::<Vec<_>>(), [6, 7]);
    assert_eq!(lines.iter().filter(|line| line.kind == Added).map(|line| line.text.as_str()).collect::<Vec<_>>(), ["line ten", "line ten and a half"]);
    assert_eq!(lines.iter().find(|line| line.kind == Removed).unwrap().text, "line 10");
    assert_eq!(AiSourceDiff::lines(&old, &old), Some(Vec::<Line>::new()));
    assert_eq!(AiSourceDiff::summary("a\r\nb\n", "a\nb"), Some(Summary { added: 0, removed: 0 }), "line endings are not a change");
    assert!(AiSourceDiff::summary("a\r\nb\n", "a\nb").unwrap().is_empty());
    assert_eq!(AiSourceDiff::summary(&"x\n".repeat(AiSourceDiff::MAX_LINES + 1), "x"), None);
    // Everything new, and everything gone.
    assert_eq!(AiSourceDiff::summary("", "a\nb\n"), Some(Summary { added: 2, removed: 0 }));
    assert_eq!(AiSourceDiff::summary("a\nb\n", ""), Some(Summary { added: 0, removed: 2 }));
}

#[test]
fn usage_advice_appears_only_when_a_conversation_has_grown() {
    let mut conversation = AiConversation::new(1);
    conversation.size = AiWidgetSize::Large;
    conversation.package_id = Some("installation-1".into());
    assert_eq!(conversation.usage_advice(), None);
    assert!(conversation.continued_from_current_version(2).is_none(), "nothing to continue from");
    fn turn(conversation: &mut AiConversation, prompt: i64, repairs: i64) {
        let id = conversation.begin_turn("Change it", 3).id.clone();
        let source = format!("$render(<text>{}</text>)\n", conversation.version_counter);
        let version = conversation.add_version(&source, vec!["example.com".into()], 3).id.clone();
        let turn = conversation.turn_mut(&id).unwrap();
        turn.status = Status::Succeeded;
        turn.version_id = Some(version);
        turn.repairs = repairs;
        turn.usage = AiTokenUsage::new(prompt, 100, prompt + 100);
    }
    turn(&mut conversation, 5_000, 0);
    assert_eq!(conversation.usage_advice(), None);
    turn(&mut conversation, 70_000, 1);
    assert_eq!(conversation.last_request_tokens(), 35_000);
    assert_eq!(conversation.usage_advice(), Some(AiConversationUsageAdvice { reason: Reason::HeavyRequests, tokens: 35_000 }));
    turn(&mut conversation, 5_000, 0);
    assert_eq!(conversation.usage_advice(), None, "it follows the newest turn");
    for _ in 0..AiConversationLimits::HISTORY_TURNS {
        turn(&mut conversation, 5_000, 0);
    }
    assert_eq!(conversation.usage_advice().map(|advice| advice.reason), Some(Reason::HistoryFull));
    for _ in 0..20 {
        turn(&mut conversation, 5_000, 0);
    }
    assert_eq!(conversation.usage_advice().map(|advice| advice.reason), Some(Reason::VersionsFull));
    turn(&mut conversation, 200_000, 0);
    assert_eq!(conversation.usage_advice().map(|advice| advice.reason), Some(Reason::HeavyRequests));
    assert!(conversation.usage_advice().unwrap().message().contains("200,000"));
    let next = conversation.continued_from_current_version(4).unwrap();
    assert_ne!(next.id, conversation.id);
    assert_eq!(next.versions.iter().map(|version| version.source.as_str()).collect::<Vec<_>>(), [conversation.current_version().unwrap().source.as_str()]);
    assert_eq!(next.current_version().unwrap().network_domains, ["example.com"]);
    assert_eq!((next.size, next.package_id.as_deref()), (AiWidgetSize::Large, Some("installation-1")));
    assert!(next.turns.is_empty());
    assert_eq!(next.usage_advice(), None);
    assert!(next.history_for_prompt().is_empty(), "no earlier turn is sent");
}
