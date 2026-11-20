//! `$notifications`: options, the order of the checks, the per-widget grant,
//! the list of pending notifications and the delivery the background service
//! drives. The desktop is a stand-in; `api_bus.rs` covers the bus itself.

mod api_common;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use api_common::*;
use serde_json::{Value, json};
use sw_core::NativeModule;
use sw_core::api::notifications::{NotificationDelivery, NotificationPlatform, NotificationStore, NotificationsModule, ScheduledNotification, fixed_offset_next_local_time, notification_rules, system_next_local_time};
use sw_core::api::support::{CallContext, SystemAccessGrants, SystemServiceError, iso_dates};
use sw_core::json::Object;

const OWNER: &str = "11111111-1111-4111-8111-111111111111";
const OTHER: &str = "22222222-2222-4222-8222-222222222222";

#[derive(Default)]
struct FakeDesktop {
    disabled: AtomicBool,
    shown: Mutex<Vec<(String, String)>>,
}

impl NotificationPlatform for FakeDesktop {
    fn enabled(&self) -> bool {
        !self.disabled.load(Ordering::SeqCst)
    }

    fn post(&self, title: &str, body: &str) -> bool {
        self.shown.lock().unwrap().push((title.to_owned(), body.to_owned()));
        true
    }
}

struct Fixture {
    now: Arc<AtomicI64>,
    directory: PathBuf,
    desktop: Arc<FakeDesktop>,
    store: Arc<NotificationStore>,
    grants: Arc<SystemAccessGrants>,
    module: NotificationsModule,
}

impl Fixture {
    fn new() -> Self {
        let now = Arc::new(AtomicI64::new(iso_dates::parse("2026-11-19T10:00:00Z").unwrap()));
        let directory = temporary_directory("notifications");
        let desktop = Arc::new(FakeDesktop::default());
        let store = Arc::new(NotificationStore::new(directory.join("notifications.json")));
        let grants = Arc::new(SystemAccessGrants::new(directory.join("grants.json")));
        assert!(grants.set(OWNER, "notifications", true) && grants.set(OTHER, "notifications", true));
        let clock = now.clone();
        let module = NotificationsModule::with_clock(desktop.clone(), store.clone(), grants.clone(), Arc::new(move || clock.load(Ordering::SeqCst)), fixed_offset_next_local_time(0));
        Self { now, directory, desktop, store, grants, module }
    }

    fn now(&self) -> i64 {
        self.now.load(Ordering::SeqCst)
    }

    fn delivery(&self) -> NotificationDelivery {
        // Shown at once, on the calling thread, so a test sees it without waiting.
        NotificationDelivery::with_parts(self.store.clone(), self.desktop.clone(), fixed_offset_next_local_time(0), Arc::new(|work| work()))
    }

    fn shown(&self) -> Vec<(String, String)> {
        self.desktop.shown.lock().unwrap().clone()
    }
}

fn reader(owner: &str) -> CallContext {
    CallContext::new(owner, true, &["notifications"], &[], Some("1.6"))
}

fn action(owner: &str) -> CallContext {
    let mut context = reader(owner);
    context.is_action = true;
    context
}

fn options(value: Value) -> Object {
    value.as_object().unwrap().clone()
}

fn at(text: &str) -> i64 {
    iso_dates::parse(text).unwrap()
}

fn code(error: SystemServiceError) -> String {
    error.message()
}

#[test]
fn options_are_strict_and_bounded() {
    let now = at("2026-11-19T10:00:00Z");
    let parse = |value: Value| notification_rules::parse(OWNER, &options(value), now);
    let once = parse(json!({"key": "water", "title": "Drink", "body": "A glass of water", "date": "2026-11-19T10:00:01Z"})).unwrap();
    assert_eq!(once, ScheduledNotification { owner: OWNER.into(), key: "water".into(), title: "Drink".into(), body: "A glass of water".into(), date: Some(now + 1000), daily: None });
    let daily = parse(json!({"key": "a_B-9", "title": "T", "body": "B", "daily": {"hour": 23, "minute": 0}})).unwrap();
    assert_eq!((daily.daily, daily.date, daily.repeats()), (Some((23, 0)), None, true));
    // The longest texts that fit.
    assert!(parse(json!({"key": "k".repeat(64), "title": "t".repeat(256), "body": "b".repeat(1024), "daily": {"hour": 0, "minute": 59}})).is_ok());
    let invalid = [
        json!({"key": "k", "title": "T", "body": "B"}),
        json!({"key": "k", "title": "T", "body": "B", "date": "2026-11-19T10:00:01Z", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "date": "2026-11-19T10:00:00Z"}),
        json!({"key": "k", "title": "T", "body": "B", "date": "2026-11-19T09:00:00Z"}),
        json!({"key": "k", "title": "T", "body": "B", "date": "2027-11-21T10:00:00Z"}),
        json!({"key": "k", "title": "T", "body": "B", "date": "2026-11-20"}),
        json!({"key": "k", "title": "T", "body": "B", "date": 1_800_000_000_000i64}),
        json!({"key": "k k", "title": "T", "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "../x", "title": "T", "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k".repeat(65), "title": "T", "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": " ", "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": "t".repeat(257), "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "b".repeat(1025), "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": "T\nU", "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "a\u{202e}b", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": 5, "body": "B", "daily": {"hour": 1, "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 24, "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 1, "minute": 60}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 1.5, "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": "1", "minute": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 1, "minute": 1, "second": 1}}),
        json!({"key": "k", "title": "T", "body": "B", "daily": [1, 1]}),
        json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 1, "minute": 1}, "sound": "loud"}),
    ];
    for value in invalid {
        assert_eq!(parse(value.clone()).unwrap_err().0, code(SystemServiceError::InvalidOptions), "{value}");
    }
}

#[test]
fn the_gate_decides_which_refusal_a_script_sees() {
    let fixture = Fixture::new();
    let good = options(json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 12, "minute": 0}}));
    let refusal = |context: &CallContext| fixture.module.schedule(context, Some(&good)).unwrap_err().0;
    // Not installed, not declared, an older runtime: permission_denied.
    for context in [
        { let mut context = CallContext::new("preview", true, &["notifications"], &[], Some("1.6")); context.is_action = true; context },
        { let mut context = CallContext::new(OWNER, true, &["network"], &[], Some("1.6")); context.is_action = true; context },
        { let mut context = CallContext::new(OWNER, false, &["notifications"], &[], Some("1.6")); context.is_action = true; context },
        { let mut context = CallContext::new(OWNER, true, &["notifications"], &[], Some("1.5")); context.is_action = true; context },
    ] {
        assert_eq!(refusal(&context), code(SystemServiceError::PermissionDenied));
    }
    // A write outside an action, in a future timeline entry or in a Live Activity: read_only.
    assert_eq!(refusal(&reader(OWNER)), code(SystemServiceError::ReadOnly));
    let mut projection = action(OWNER);
    projection.is_timeline_projection = true;
    assert_eq!(refusal(&projection), code(SystemServiceError::ReadOnly));
    assert_eq!(fixture.module.status(&projection).unwrap_err().0, code(SystemServiceError::ReadOnly));
    // No grant from the user: permission_denied, for reads too.
    assert!(fixture.grants.set(OWNER, "notifications", false));
    assert_eq!(refusal(&action(OWNER)), code(SystemServiceError::PermissionDenied));
    assert_eq!(fixture.module.status(&reader(OWNER)).unwrap_err().0, code(SystemServiceError::PermissionDenied));
    assert_eq!(fixture.module.pending(&reader(OWNER)).unwrap_err().0, code(SystemServiceError::PermissionDenied));
    assert!(fixture.grants.set(OWNER, "notifications", true));
    // A grant file that is not this program's denies everything.
    std::fs::write(fixture.directory.join("grants.json"), "{}").unwrap();
    assert_eq!(refusal(&action(OWNER)), code(SystemServiceError::Unavailable));
    assert!(fixture.grants.set(OWNER, "notifications", true));
    // The query budget.
    let spent = Arc::new(AtomicU32::new(0));
    let counter = spent.clone();
    let mut budget = reader(OWNER).with_probes(move || counter.fetch_add(1, Ordering::SeqCst) < 2, || true, || true);
    budget.is_action = true;
    assert!(fixture.module.schedule(&budget, Some(&good)).is_ok());
    assert!(fixture.module.status(&budget).is_ok());
    assert_eq!(fixture.module.pending(&budget).unwrap_err().0, code(SystemServiceError::QueryLimit));
    // Bad options are told after the gate; no notification service is permission_denied after the options.
    assert_eq!(fixture.module.schedule(&action(OWNER), None).unwrap_err().0, code(SystemServiceError::InvalidOptions));
    fixture.desktop.disabled.store(true, Ordering::SeqCst);
    assert_eq!(refusal(&action(OWNER)), code(SystemServiceError::PermissionDenied));
    assert_eq!(fixture.module.status(&reader(OWNER)).unwrap(), json!({"authorization": "denied"}));
    fixture.desktop.disabled.store(false, Ordering::SeqCst);
    assert_eq!(fixture.module.status(&reader(OWNER)).unwrap(), json!({"authorization": "authorized"}));
}

#[test]
fn a_widget_sees_and_cancels_only_its_own() {
    let fixture = Fixture::new();
    let schedule = |owner: &str, value: Value| fixture.module.schedule(&action(owner), Some(&options(value)));
    assert_eq!(schedule(OWNER, json!({"key": "tea", "title": "Tea", "body": "Kettle", "date": "2026-11-19T10:05:00Z"})).unwrap(), json!({"key": "tea", "status": "scheduled"}));
    schedule(OWNER, json!({"key": "daily", "title": "Stand", "body": "Up", "daily": {"hour": 9, "minute": 30}})).unwrap();
    schedule(OTHER, json!({"key": "tea", "title": "Theirs", "body": "Other", "date": "2026-11-19T11:00:00Z"})).unwrap();
    assert_eq!(
        fixture.module.pending(&reader(OWNER)).unwrap(),
        json!([
            {"key": "tea", "title": "Tea", "body": "Kettle", "repeats": false, "date": "2026-11-19T10:05:00Z"},
            {"key": "daily", "title": "Stand", "body": "Up", "repeats": true, "date": "2026-11-20T09:30:00Z"},
        ])
    );
    // The same key replaces the slot.
    schedule(OWNER, json!({"key": "tea", "title": "Green tea", "body": "Kettle", "date": "2026-11-19T10:06:00Z"})).unwrap();
    let mine = fixture.module.pending(&reader(OWNER)).unwrap();
    assert_eq!(mine.as_array().unwrap().len(), 2);
    assert!(mine.as_array().unwrap().iter().any(|row| row["title"] == "Green tea"));
    // Cancelling takes this widget's slot, never the other widget's with the same key.
    assert_eq!(fixture.module.cancel(&action(OWNER), Some(&json!("tea"))).unwrap(), json!({"key": "tea", "status": "cancellationRequested"}));
    assert_eq!(fixture.module.pending(&reader(OTHER)).unwrap().as_array().unwrap().len(), 1);
    assert_eq!(fixture.module.pending(&reader(OWNER)).unwrap().as_array().unwrap().len(), 1);
    // Cancelling what is not there is not an error; a key that is not one is.
    assert!(fixture.module.cancel(&action(OWNER), Some(&json!("gone"))).is_ok());
    for key in [json!("no key"), json!(5), Value::Null] {
        assert_eq!(fixture.module.cancel(&action(OWNER), Some(&key)).unwrap_err().0, code(SystemServiceError::InvalidOptions));
    }
    assert_eq!(fixture.module.cancel(&reader(OWNER), Some(&json!("daily"))).unwrap_err().0, code(SystemServiceError::ReadOnly));
    // A deleted widget leaves nothing behind.
    fixture.module.retire(OWNER);
    assert!(fixture.store.all().unwrap().iter().all(|entry| entry.owner == OTHER));
    assert!(!fixture.grants.granted(OWNER, "notifications").unwrap());
}

#[test]
fn slots_are_limited_per_widget_and_in_total() {
    let fixture = Fixture::new();
    let schedule = |owner: &str, key: String| fixture.module.schedule(&action(owner), Some(&options(json!({"key": key, "title": "T", "body": "B", "daily": {"hour": 1, "minute": 1}}))));
    for index in 0..notification_rules::MAXIMUM_PER_OWNER {
        schedule(OWNER, format!("k{index}")).unwrap();
    }
    assert_eq!(schedule(OWNER, "one-more".into()).unwrap_err().0, code(SystemServiceError::LimitExceeded));
    assert!(schedule(OWNER, "k0".into()).is_ok(), "replacing always fits");
    for index in 0..notification_rules::MAXIMUM_TOTAL - notification_rules::MAXIMUM_PER_OWNER {
        schedule(OTHER, format!("k{index}")).unwrap();
    }
    assert_eq!(fixture.store.all().unwrap().len(), notification_rules::MAXIMUM_TOTAL);
    assert_eq!(schedule(OTHER, "one-more".into()).unwrap_err().0, code(SystemServiceError::LimitExceeded));
}

#[test]
fn a_damaged_list_is_unavailable_never_empty() {
    let fixture = Fixture::new();
    let good = options(json!({"key": "k", "title": "T", "body": "B", "daily": {"hour": 12, "minute": 0}}));
    for text in [
        "{ not json",
        r#"{"formatVersion":1}"#,
        r#"{"pending":[{"owner":"x","key":"k","title":"T","body":"B","date":1,"hour":null,"minute":null}]}"#,
        r#"{"pending":[{"owner":"11111111-1111-4111-8111-111111111111","key":"k","title":"T","body":"B","date":1,"hour":1,"minute":1}]}"#,
        r#"{"pending":[{"owner":"11111111-1111-4111-8111-111111111111","key":"k","title":"T","body":"B","date":null,"hour":25,"minute":1}]}"#,
        r#"{"pending":[{"owner":"11111111-1111-4111-8111-111111111111","key":"../k","title":"T","body":"B","date":1,"hour":null,"minute":null}]}"#,
        r#"{"pending":[{"owner":"11111111-1111-4111-8111-111111111111","key":"k","title":"T\u0007","body":"B","date":1,"hour":null,"minute":null}]}"#,
    ] {
        std::fs::write(fixture.directory.join("notifications.json"), text).unwrap();
        assert_eq!(fixture.module.pending(&reader(OWNER)).unwrap_err().0, code(SystemServiceError::Unavailable), "{text}");
        assert_eq!(fixture.module.schedule(&action(OWNER), Some(&good)).unwrap_err().0, code(SystemServiceError::Unavailable), "{text}");
        assert_eq!(fixture.delivery().deliver_due(fixture.now(), &|_| true), None, "nothing is shown from a list that cannot be read");
        assert_eq!(std::fs::read_to_string(fixture.directory.join("notifications.json")).unwrap(), text, "the file is left as it is");
    }
    assert!(fixture.shown().is_empty());
}

#[test]
fn what_is_due_is_shown_once() {
    let fixture = Fixture::new();
    let schedule = |value: Value| fixture.module.schedule(&action(OWNER), Some(&options(value))).unwrap();
    schedule(json!({"key": "soon", "title": "Soon", "body": "In a minute", "date": "2026-11-19T10:01:00Z"}));
    schedule(json!({"key": "later", "title": "Later", "body": "In an hour", "date": "2026-11-19T11:00:00Z"}));
    let delivery = fixture.delivery();
    let exists = |_: &str| true;
    // Nothing is due yet; the service is told when to look again.
    assert_eq!(delivery.deliver_due(fixture.now(), &exists), Some(at("2026-11-19T10:01:00Z")));
    assert!(fixture.shown().is_empty());
    assert_eq!(delivery.deliver_due(at("2026-11-19T10:01:00Z"), &exists), Some(at("2026-11-19T11:00:00Z")));
    assert_eq!(fixture.shown(), [("Soon".to_owned(), "In a minute".to_owned())]);
    // Looking again shows nothing twice; it is gone from the list.
    assert_eq!(delivery.deliver_due(at("2026-11-19T10:02:00Z"), &exists), Some(at("2026-11-19T11:00:00Z")));
    assert_eq!(fixture.shown().len(), 1);
    assert_eq!(fixture.store.all().unwrap().len(), 1);
    // One whose time passed while nothing looked (the service was not running) is shown at the next look.
    assert_eq!(fixture.delivery().deliver_due(at("2026-11-25T00:00:00Z"), &exists), None);
    assert_eq!(fixture.shown().len(), 2);
    assert!(fixture.store.all().unwrap().is_empty());
}

#[test]
fn a_daily_notification_comes_back_and_is_not_caught_up() {
    let fixture = Fixture::new();
    fixture.module.schedule(&action(OWNER), Some(&options(json!({"key": "noon", "title": "Noon", "body": "Lunch", "daily": {"hour": 12, "minute": 0}})))).unwrap();
    let delivery = fixture.delivery();
    let exists = |_: &str| true;
    assert_eq!(delivery.deliver_due(fixture.now(), &exists), Some(at("2026-11-19T12:00:00Z")));
    assert_eq!(delivery.deliver_due(at("2026-11-19T12:00:02Z"), &exists), Some(at("2026-11-20T12:00:00Z")));
    assert_eq!(fixture.shown().len(), 1);
    assert_eq!(delivery.deliver_due(at("2026-11-19T12:00:03Z"), &exists), Some(at("2026-11-20T12:00:00Z")));
    assert_eq!(fixture.shown().len(), 1, "once a day");
    assert_eq!(fixture.store.all().unwrap().len(), 1, "it stays in the list");
    // A service that starts after noon does not show yesterday's: the next one is tomorrow's.
    let restarted = fixture.delivery();
    assert_eq!(restarted.deliver_due(at("2026-11-21T15:00:00Z"), &exists), Some(at("2026-11-22T12:00:00Z")));
    assert_eq!(fixture.shown().len(), 1);
    // After the clock was set, the time is worked out again.
    delivery.rearm();
    assert_eq!(delivery.deliver_due(at("2026-11-19T08:00:00Z"), &exists), Some(at("2026-11-19T12:00:00Z")));
    // Changing the time of day replaces the armed time.
    fixture.module.schedule(&action(OWNER), Some(&options(json!({"key": "noon", "title": "Noon", "body": "Lunch", "daily": {"hour": 9, "minute": 15}})))).unwrap();
    assert_eq!(delivery.deliver_due(at("2026-11-19T08:00:00Z"), &exists), Some(at("2026-11-19T09:15:00Z")));
}

#[test]
fn a_flood_is_slowed_and_a_deleted_widget_is_dropped() {
    let fixture = Fixture::new();
    for index in 0..6 {
        fixture.module.schedule(&action(OWNER), Some(&options(json!({"key": format!("k{index}"), "title": format!("T{index}"), "body": "B", "date": "2026-11-19T10:00:01Z"})))).unwrap();
    }
    fixture.module.schedule(&action(OTHER), Some(&options(json!({"key": "theirs", "title": "Other", "body": "B", "date": "2026-11-19T10:00:01Z"})))).unwrap();
    let delivery = fixture.delivery();
    let due = at("2026-11-19T10:00:05Z");
    // Four of the six now; the other widget is not held back by this one.
    assert_eq!(delivery.deliver_due(due, &|_| true), Some(due + NotificationDelivery::RATE_WINDOW_MILLISECONDS));
    assert_eq!(fixture.shown().iter().filter(|(title, _)| title.starts_with('T')).count(), NotificationDelivery::MAXIMUM_PER_WINDOW);
    assert_eq!(fixture.shown().iter().filter(|(title, _)| title == "Other").count(), 1);
    assert_eq!(delivery.deliver_due(due + 30_000, &|_| true), Some(due + 60_000), "still waiting");
    assert_eq!(fixture.shown().len(), 5);
    // A minute later the rest: delayed, not dropped.
    assert_eq!(delivery.deliver_due(due + 60_000, &|_| true), None);
    assert_eq!(fixture.shown().len(), 7);

    // The notifications of a widget that was deleted are removed without being shown.
    fixture.module.schedule(&action(OWNER), Some(&options(json!({"key": "orphan", "title": "Orphan", "body": "B", "date": "2026-11-19T10:00:01Z"})))).unwrap();
    assert_eq!(delivery.deliver_due(due + 600_000, &|owner| owner != OWNER), None);
    assert_eq!(fixture.shown().len(), 7);
    assert!(fixture.store.all().unwrap().is_empty());
}

#[test]
fn the_next_local_time_is_strictly_later() {
    let utc = fixed_offset_next_local_time(0);
    assert_eq!(utc(at("2026-11-19T10:00:00Z"), 10, 0), at("2026-11-20T10:00:00Z"), "the same minute is tomorrow");
    assert_eq!(utc(at("2026-11-19T09:59:59Z"), 10, 0), at("2026-11-19T10:00:00Z"));
    let tokyo = fixed_offset_next_local_time(9 * 3600);
    assert_eq!(tokyo(at("2026-11-19T10:00:00Z"), 8, 30), at("2026-11-19T23:30:00Z"));
    // The system's zone, whatever it is here: later than now, within a day and an hour of daylight saving, on the asked minute.
    let system = system_next_local_time();
    let now = at("2026-11-19T10:00:30Z");
    let next = system(now, 7, 45);
    assert!(next > now && next - now <= 25 * 3_600_000, "{next}");
    assert_eq!(next % 60_000, 0, "zones are whole minutes from UTC");
    assert!(system(next, 7, 45) > next);
}

#[test]
fn a_script_reaches_the_module_through_the_bridge() {
    let fixture = Fixture::new();
    let modules: Vec<Arc<dyn NativeModule>> = vec![Arc::new(fixture.module.clone())];
    let manifest = widget_manifest(r#"["notifications"]"#, "[]").replace(r#""runtimeVersion":"1.0""#, r#""runtimeVersion":"1.0","minimumRuntimeVersion":"1.6""#);
    let source = "let text; try { const status = await $notifications.status(); const pending = await $notifications.pending(); let write; try { await $notifications.schedule({key: 'k', title: 'T', body: 'B', daily: {hour: 1, minute: 2}}); write = 'scheduled'; } catch (error) { write = String(error.message ?? error); } text = [status.authorization, pending.length, write].join('|'); } catch (error) { text = String(error.message ?? error); }\n$render(<text>{text}</text>);";
    let run_as = |owner: &str, manifest: &str| {
        let result = run(source, Some(manifest), modules.clone(), &[], |request| request.package_id = owner.to_owned());
        assert!(result.error.is_none(), "error: {:?}", result.error);
        let tree: Value = serde_json::from_str(result.tree.as_deref().expect("tree")).unwrap();
        tree["children"].as_array().unwrap().iter().map(|child| child.as_str().unwrap_or("").to_owned()).collect::<String>()
    };
    // Drawing a widget is not an action: it may read, and its write is refused.
    assert_eq!(run_as(OWNER, &manifest), format!("authorized|0|{}", code(SystemServiceError::ReadOnly)));
    assert_eq!(run_as("cli:/tmp/x", &manifest), code(SystemServiceError::PermissionDenied));
    assert_eq!(run_as(OWNER, &widget_manifest("[]", "[]")), code(SystemServiceError::PermissionDenied));
    assert!(fixture.store.all().unwrap().is_empty());
}
