//! The schedule of a package's `timeline.dailyTimes`, evaluated by the
//! planner shared with every platform. The cases are those of
//! `Android/core/src/androidTest/.../TimelineTest.kt`, plus daylight-saving
//! changes and the plan cache.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::Value;
use sw_core::api::support::iso_dates;
use sw_core::json::Object;
use sw_core::{SharedScripts, TimelinePlanner, TimelineState, intl};

/// The zone override is one for the process: the tests of this file take turns.
fn turn() -> MutexGuard<'static, ()> {
    static TURN: Mutex<()> = Mutex::new(());
    TURN.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn planner() -> TimelinePlanner {
    TimelinePlanner::new(Arc::new(SharedScripts::new(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget")).expect("shared scripts")))
}

fn manifest(times: &str, zone: Option<&str>) -> Object {
    let zone = zone.map(|zone| format!(r#","timeZone":"{zone}""#)).unwrap_or_default();
    match serde_json::from_str(&format!(r#"{{"timeline":{{"dailyTimes":{times}{zone}}}}}"#)).expect("manifest") {
        Value::Object(manifest) => manifest,
        _ => unreachable!(),
    }
}

fn at(text: &str) -> i64 {
    iso_dates::parse(text).expect("instant")
}

fn environment<'a>(state: &'a TimelineState, name: &str) -> Option<&'a str> {
    state.environments.iter().find(|(known, _)| known == name).map(|(_, value)| value.as_str())
}

const LOS_ANGELES: Option<&str> = Some("America/Los_Angeles");

#[test]
fn reports_the_current_slot_and_the_next_transition() {
    let _turn = turn();
    // 2026-03-10 15:30 UTC is 08:30 in Los Angeles (daylight time): the 06:00 slot, next change at 12:00 local.
    let state = planner().state_at(Some(&manifest(r#"["06:00","12:00","18:00","22:00"]"#, LOS_ANGELES)), at("2026-03-10T15:30:00Z")).unwrap();
    assert_eq!(environment(&state, "timeline-slot"), Some("0"));
    assert_eq!(environment(&state, "timeline-is-projection"), Some("false"));
    assert_eq!(environment(&state, "timeline-time-zone"), Some("America/Los_Angeles"));
    assert_eq!(environment(&state, "timeline-date"), Some("2026-03-10T15:30:00.000Z"));
    assert_eq!(state.next_transition_milliseconds, Some(at("2026-03-10T19:00:00Z")));
}

#[test]
fn before_the_first_time_of_the_day_the_last_slot_still_applies() {
    let _turn = turn();
    // 03:00 local.
    let state = planner().state_at(Some(&manifest(r#"["06:00","22:00"]"#, LOS_ANGELES)), at("2026-03-10T10:00:00Z")).unwrap();
    assert_eq!(environment(&state, "timeline-slot"), Some("1"));
    assert_eq!(state.next_transition_milliseconds, Some(at("2026-03-10T13:00:00Z")));
}

#[test]
fn uses_the_zone_of_the_machine_when_none_is_declared() {
    let _turn = turn();
    // SAFETY: the tests of this file run one at a time (see `turn`), and no other thread of this process uses local time.
    unsafe { intl::set_time_zone_override(Some("Asia/Shanghai")) };
    // 08:30 in Shanghai.
    let state = planner().state_at(Some(&manifest(r#"["09:00"]"#, None)), at("2026-03-10T00:30:00Z"));
    // SAFETY: as above.
    unsafe { intl::set_time_zone_override(None) };
    let state = state.unwrap();
    assert_eq!(environment(&state, "timeline-time-zone"), Some("Asia/Shanghai"));
    assert_eq!(state.next_transition_milliseconds, Some(at("2026-03-10T01:00:00Z")));
}

#[test]
fn packages_without_a_valid_schedule_have_no_timeline() {
    let _turn = turn();
    let planner = planner();
    assert_eq!(planner.state(None), None);
    assert_eq!(planner.state(Some(&Object::new())), None);
    assert_eq!(planner.state(Some(&manifest(r#"["25:00"]"#, LOS_ANGELES))), None);
    assert_eq!(planner.state(Some(&manifest(r#"["06:00"]"#, Some("Not/AZone")))), None);
    assert_eq!(planner.state(Some(&manifest(r#"["12:00","06:00"]"#, LOS_ANGELES))), None);
    assert_eq!(planner.state(Some(&manifest(r#"["01:00","02:00","03:00","04:00","05:00"]"#, LOS_ANGELES))), None);
    // A schedule is data: text in it is never run.
    assert_eq!(planner.state(Some(&manifest(r#"["06:00\"); throw new Error(\"x"]"#, LOS_ANGELES))), None);
    let mut not_an_object = Object::new();
    not_an_object.insert("timeline".into(), Value::String("daily".into()));
    assert_eq!(planner.state(Some(&not_an_object)), None);
}

#[test]
fn daylight_saving_changes_move_the_transitions_with_the_wall_clock() {
    let _turn = turn();
    let planner = planner();
    let schedule = manifest(r#"["02:30","12:00"]"#, LOS_ANGELES);
    // 8 March 2026: clocks go from 02:00 to 03:00, so 02:30 does not exist; the slot starts at the next valid minute.
    let spring = planner.state_at(Some(&schedule), at("2026-03-08T09:00:00Z")).unwrap(); // 01:00 PST
    assert_eq!(environment(&spring, "timeline-slot"), Some("1"));
    assert_eq!(spring.next_transition_milliseconds, Some(at("2026-03-08T10:00:00Z"))); // 03:00 PDT
    // 1 November 2026: 01:00 to 02:00 happens twice; 12:00 local is 20:00 UTC afterwards, not 19:00.
    let autumn = planner.state_at(Some(&schedule), at("2026-11-01T12:00:00Z")).unwrap(); // 04:00 PST
    assert_eq!(environment(&autumn, "timeline-slot"), Some("0"));
    assert_eq!(autumn.next_transition_milliseconds, Some(at("2026-11-01T20:00:00Z")));
    // A zone whose offset is not a whole hour (+05:45).
    let kathmandu = planner.state_at(Some(&manifest(r#"["09:00"]"#, Some("Asia/Kathmandu"))), at("2026-03-10T03:00:00Z")).unwrap(); // 08:45 local
    assert_eq!(kathmandu.next_transition_milliseconds, Some(at("2026-03-10T03:15:00Z")));
}

#[test]
fn a_plan_is_reused_until_its_next_transition_or_for_an_hour() {
    let _turn = turn();
    let planner = planner();
    let schedule = manifest(r#"["06:00","12:00"]"#, LOS_ANGELES);
    let first = planner.state_at(Some(&schedule), at("2026-03-10T18:30:00Z")).unwrap(); // 11:30 local
    assert_eq!(first.next_transition_milliseconds, Some(at("2026-03-10T19:00:00Z")));
    // Twenty minutes later the same plan answers: its date is the moment it was made.
    let reused = planner.state_at(Some(&schedule), at("2026-03-10T18:50:00Z")).unwrap();
    assert_eq!(reused, first);
    // At the transition the plan is made again and the slot changes.
    let after = planner.state_at(Some(&schedule), at("2026-03-10T19:00:00Z")).unwrap();
    assert_eq!(environment(&after, "timeline-slot"), Some("1"));
    assert_eq!(environment(&after, "timeline-date"), Some("2026-03-10T19:00:00.000Z"));
    // Far from a transition a plan is kept for an hour at most.
    let evening = planner.state_at(Some(&schedule), at("2026-03-10T20:00:00Z")).unwrap();
    assert_eq!(planner.state_at(Some(&schedule), at("2026-03-10T20:59:59Z")).unwrap(), evening);
    assert_ne!(planner.state_at(Some(&schedule), at("2026-03-10T21:00:00Z")).unwrap(), evening);
    // Another schedule has its own plan.
    let other = planner.state_at(Some(&manifest(r#"["06:00","13:00"]"#, LOS_ANGELES)), at("2026-03-10T18:50:00Z")).unwrap();
    assert_eq!(other.next_transition_milliseconds, Some(at("2026-03-10T20:00:00Z")));
}
