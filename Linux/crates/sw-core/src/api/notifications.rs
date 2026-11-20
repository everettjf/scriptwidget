//! `$notifications`: `status`, `pending`, `schedule` and `cancel`, shown by
//! the desktop's notification service (`org.freedesktop.Notifications`).
//! The rules are the ones of `Android/core/.../system/NotificationsModule.kt`.
//!
//! How Linux differs from Android, which arms an alarm of the system:
//! - There is no alarm that outlives the program. Pending notifications are
//!   kept in a private file, and the background service ([`NotificationDelivery`],
//!   driven by `sw-host`) shows each one when its time has come. It looks
//!   when it wakes for anything, and it wakes for the next pending time, so a
//!   notification normally appears within a second or two of its time.
//! - That is inexact in these ways: nothing is shown while the service is not
//!   running or the computer sleeps. A one-time notification whose time passed
//!   meanwhile is shown when the service next looks; a daily one is not caught
//!   up and is shown at its next time of day. A widget that asks for more
//!   than four notifications a minute has the rest delayed, not dropped.
//! - A desktop has no per-application notification permission to ask for.
//!   `status()` is `authorized` while a notification service is running and
//!   `denied` while none is. The per-widget grant is the user's switch in the
//!   management window or `scriptwidget notifications allow`.
//! - A notification carries the title and the body as plain text. Where the
//!   service reads markup in the body, the body is escaped first.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::api::bus::SessionBus;
use crate::api::support::{CallContext, PrivateFile, SystemAccessGrants, SystemReject, SystemServiceError, is_owner, iso_dates, run_system, system_gate, system_log, system_options};
use crate::api::weather::Clock;
use crate::executor::{Completion, ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, parse_object, quote, stringify};

/// One scheduled local notification of one installation. Exactly one of `date` or `hour`/`minute` is set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduledNotification {
    pub owner: String,
    pub key: String,
    pub title: String,
    pub body: String,
    /// Epoch milliseconds.
    pub date: Option<i64>,
    pub daily: Option<(u8, u8)>,
}

impl ScheduledNotification {
    pub fn repeats(&self) -> bool {
        self.daily.is_some()
    }

    fn to_json(&self) -> Value {
        json!({ "owner": self.owner, "key": self.key, "title": self.title, "body": self.body, "date": self.date, "hour": self.daily.map(|(hour, _)| hour), "minute": self.daily.map(|(_, minute)| minute) })
    }
}

/// The next moment after `now` (epoch milliseconds) at which the local clock shows `hour:minute`.
pub type NextLocalTime = Arc<dyn Fn(i64, u8, u8) -> i64 + Send + Sync>;

/// [`NextLocalTime`] in the time zone of the process, daylight saving included.
pub fn system_next_local_time() -> NextLocalTime {
    Arc::new(|now_milliseconds, hour, minute| {
        let now = now_milliseconds.div_euclid(1000);
        let candidate = |days: i32| -> Option<i64> {
            // SAFETY: `localtime_r` and `mktime` read and write only the values on this stack.
            unsafe {
                let time = now as libc::time_t;
                let mut local = std::mem::MaybeUninit::<libc::tm>::zeroed();
                if libc::localtime_r(&time, local.as_mut_ptr()).is_null() {
                    return None;
                }
                let mut local = local.assume_init();
                local.tm_mday += days;
                local.tm_hour = i32::from(hour);
                local.tm_min = i32::from(minute);
                local.tm_sec = 0;
                // Let the C library decide whether daylight saving applies on that day.
                local.tm_isdst = -1;
                let seconds = libc::mktime(&mut local);
                (seconds != -1).then_some(seconds as i64)
            }
        };
        let next = (0..=2).filter_map(candidate).find(|seconds| *seconds > now);
        next.unwrap_or(now + 86_400) * 1000
    })
}

/// [`NextLocalTime`] for a fixed offset from UTC, for tests.
pub fn fixed_offset_next_local_time(offset_seconds: i64) -> NextLocalTime {
    Arc::new(move |now_milliseconds, hour, minute| {
        let local = now_milliseconds.div_euclid(1000) + offset_seconds;
        let mut next = local.div_euclid(86_400) * 86_400 + i64::from(hour) * 3600 + i64::from(minute) * 60;
        if next <= local {
            next += 86_400;
        }
        (next - offset_seconds) * 1000
    })
}

/// Limits and pure rules of `$notifications`.
pub mod notification_rules {
    use super::*;

    /// Slots per installation.
    pub const MAXIMUM_PER_OWNER: usize = 32;
    /// Capacity for all widgets together, the same check the Apple runtime makes.
    pub const MAXIMUM_TOTAL: usize = 60;
    pub const MAXIMUM_DATE_WINDOW_MILLISECONDS: i64 = 366 * 86_400_000;
    pub const MAXIMUM_TITLE_BYTES: usize = 256;
    pub const MAXIMUM_BODY_BYTES: usize = 1024;

    /// `schedule(options)` input: closed fields; key `[a-zA-Z0-9_-]{1,64}`;
    /// title and body not blank, without control characters, at most 256 and
    /// 1024 UTF-8 bytes; exactly one of `date` (in the future, at most 366
    /// days away) or `daily` (`{hour: 0–23, minute: 0–59}`, integers).
    pub fn parse(owner: &str, options: &Object, now_milliseconds: i64) -> Result<ScheduledNotification, SystemReject> {
        let invalid = || SystemServiceError::InvalidOptions.reject();
        system_options::fields(options, &["key", "title", "body", "date", "daily"])?;
        let key = system_options::text(system_options::member(options, "key"), 64)?;
        if !system_options::valid_key(&key) {
            return Err(invalid());
        }
        let title = system_options::text(system_options::member(options, "title"), MAXIMUM_TITLE_BYTES)?;
        let body = system_options::text(system_options::member(options, "body"), MAXIMUM_BODY_BYTES)?;
        if options.has("date") == options.has("daily") {
            return Err(invalid());
        }
        let entry = |date, daily| ScheduledNotification { owner: owner.to_owned(), key: key.clone(), title: title.clone(), body: body.clone(), date, daily };
        if options.has("date") {
            let date = system_options::date(options.get("date"))?;
            if date <= now_milliseconds || date - now_milliseconds > MAXIMUM_DATE_WINDOW_MILLISECONDS {
                return Err(invalid());
            }
            return Ok(entry(Some(date), None));
        }
        let daily = options.opt_object("daily").ok_or_else(invalid)?;
        system_options::fields(daily, &["hour", "minute"])?;
        let hour = system_options::integer(system_options::member(daily, "hour"), 0, 23)? as u8;
        let minute = system_options::integer(system_options::member(daily, "minute"), 0, 59)? as u8;
        Ok(entry(None, Some((hour, minute))))
    }

    /// When `entry` is shown next: its date, or the next local `hour:minute` strictly after now.
    pub fn next_trigger(entry: &ScheduledNotification, now_milliseconds: i64, next_local: &NextLocalTime) -> i64 {
        match entry.daily {
            Some((hour, minute)) => next_local(now_milliseconds, hour, minute),
            None => entry.date.unwrap_or(now_milliseconds),
        }
    }

    /// A new slot needs room for all widgets together (60) and for the installation (32); replacing an existing key always fits.
    pub fn has_capacity(all: &[ScheduledNotification], owner: &str, key: &str) -> bool {
        all.iter().any(|entry| entry.owner == owner && entry.key == key) || (all.len() < MAXIMUM_TOTAL && all.iter().filter(|entry| entry.owner == owner).count() < MAXIMUM_PER_OWNER)
    }

    /// Body text for a service that reads markup: the three characters markup is made of, written as entities.
    pub fn escape_markup(text: &str) -> String {
        text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    }
}

/// The durable list of pending notifications; the source of truth for `pending()` and for the service that shows them.
pub struct NotificationStore {
    file: PrivateFile,
}

impl NotificationStore {
    pub fn new(file: impl Into<PathBuf>) -> Self {
        Self { file: PrivateFile::new(file, 256 * 1024) }
    }

    fn locked<T>(&self, work: impl FnOnce() -> T) -> T {
        let lock = self.file.lock();
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        work()
    }

    /// Every pending entry. An unreadable or malformed file is `unavailable`, never an empty list.
    pub fn all(&self) -> Result<Vec<ScheduledNotification>, SystemReject> {
        self.locked(|| self.load())
    }

    fn load(&self) -> Result<Vec<ScheduledNotification>, SystemReject> {
        let unavailable = || SystemServiceError::Unavailable.reject();
        let Some(text) = self.file.read().map_err(|_| unavailable())? else { return Ok(Vec::new()) };
        let root = parse_object(&text).map_err(|_| unavailable())?;
        let items = root.opt_array("pending").filter(|items| items.len() <= notification_rules::MAXIMUM_TOTAL).ok_or_else(unavailable)?;
        items
            .iter()
            .map(|item| {
                let item = item.as_object()?;
                let text = |name: &str| item.get(name).and_then(Value::as_str).map(str::to_owned);
                let number = |name: &str, maximum: i64| item.get(name).and_then(Value::as_i64).filter(|value| (0..=maximum).contains(value));
                let date = item.get("date").and_then(Value::as_i64);
                let daily = number("hour", 23).zip(number("minute", 59)).map(|(hour, minute)| (hour as u8, minute as u8));
                let entry = ScheduledNotification { owner: text("owner")?, key: text("key")?, title: text("title")?, body: text("body")?, date, daily };
                let sound = is_owner(&entry.owner)
                    && system_options::valid_key(&entry.key)
                    && entry.date.is_some() != entry.daily.is_some()
                    && entry.title.len() <= notification_rules::MAXIMUM_TITLE_BYTES
                    && entry.body.len() <= notification_rules::MAXIMUM_BODY_BYTES
                    && !system_options::has_control_characters(&entry.title)
                    && !system_options::has_control_characters(&entry.body);
                sound.then_some(entry)
            })
            .collect::<Option<Vec<_>>>()
            .ok_or_else(unavailable)
    }

    fn save(&self, entries: &[ScheduledNotification]) -> bool {
        self.file.write(&stringify(&json!({ "formatVersion": 1, "pending": entries.iter().map(ScheduledNotification::to_json).collect::<Vec<_>>() })))
    }

    /// Removes one slot and reports whether it existed.
    pub fn remove(&self, owner: &str, key: &str) -> bool {
        self.locked(|| {
            let Ok(entries) = self.load() else { return false };
            let remaining: Vec<_> = entries.iter().filter(|entry| !(entry.owner == owner && entry.key == key)).cloned().collect();
            remaining.len() != entries.len() && self.save(&remaining)
        })
    }
}

/// The desktop side of local notifications.
pub trait NotificationPlatform: Send + Sync {
    /// A notification service is running.
    fn enabled(&self) -> bool;
    /// Shows a notification now. False when it could not be handed to the service.
    fn post(&self, title: &str, body: &str) -> bool;
}

/// `org.freedesktop.Notifications` through `busctl`.
pub struct DesktopNotifications {
    bus: SessionBus,
    markup: OnceLock<bool>,
}

impl DesktopNotifications {
    const LIMIT: Duration = Duration::from_millis(2000);

    pub fn new(bus: SessionBus) -> Self {
        Self { bus, markup: OnceLock::new() }
    }
}

impl NotificationPlatform for DesktopNotifications {
    fn enabled(&self) -> bool {
        self.bus.has_notification_service(Self::LIMIT).unwrap_or(false)
    }

    fn post(&self, title: &str, body: &str) -> bool {
        // Asked once: a service does not change what it reads while it runs. When it cannot be asked, the body is escaped.
        let markup = match self.markup.get() {
            Some(markup) => *markup,
            None => match self.bus.notification_capabilities(Self::LIMIT) {
                Ok(capabilities) => *self.markup.get_or_init(|| capabilities.iter().any(|capability| capability == "body-markup")),
                Err(_) => true,
            },
        };
        let body = if markup { notification_rules::escape_markup(body) } else { body.to_owned() };
        self.bus.notify(title, &body, Self::LIMIT).is_ok()
    }
}

fn system_clock() -> Clock {
    Arc::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64))
}

/// `$notifications`. Entries are keyed per installation; a widget can only
/// see and cancel its own. Scheduling acknowledges that the entry was
/// recorded, not that the notification was shown.
#[derive(Clone)]
pub struct NotificationsModule {
    platform: Arc<dyn NotificationPlatform>,
    store: Arc<NotificationStore>,
    grants: Arc<SystemAccessGrants>,
    clock: Clock,
    next_local: NextLocalTime,
}

impl NotificationsModule {
    pub const PERMISSION: &'static str = "notifications";

    pub fn new(platform: Arc<dyn NotificationPlatform>, store: Arc<NotificationStore>, grants: Arc<SystemAccessGrants>) -> Self {
        Self::with_clock(platform, store, grants, system_clock(), system_next_local_time())
    }

    pub fn with_clock(platform: Arc<dyn NotificationPlatform>, store: Arc<NotificationStore>, grants: Arc<SystemAccessGrants>, clock: Clock, next_local: NextLocalTime) -> Self {
        Self { platform, store, grants, clock, next_local }
    }

    pub fn store(&self) -> &Arc<NotificationStore> {
        &self.store
    }

    pub fn grants(&self) -> &Arc<SystemAccessGrants> {
        &self.grants
    }

    fn check(&self, context: &CallContext, writing: bool) -> Result<(), SystemReject> {
        system_gate::check_granted(context, Self::PERMISSION, writing, Some(&self.grants))
    }

    fn validate(&self, context: &CallContext, writing: bool) -> Result<(), SystemReject> {
        system_gate::validate_granted(context, Self::PERMISSION, writing, Some(&self.grants))
    }

    /// `authorized` while a notification service is running, else `denied`.
    pub fn authorization(&self) -> &'static str {
        if self.platform.enabled() { "authorized" } else { "denied" }
    }

    pub fn status(&self, context: &CallContext) -> Result<Value, SystemReject> {
        self.check(context, false)?;
        Ok(json!({ "authorization": self.authorization() }))
    }

    /// This installation's slots: `{key, title, body, repeats, date}` with the next time each is shown.
    pub fn pending(&self, context: &CallContext) -> Result<Value, SystemReject> {
        self.check(context, false)?;
        let now = (self.clock)();
        let rows: Vec<Value> = self
            .store
            .all()?
            .iter()
            .filter(|entry| entry.owner == context.installation)
            .take(notification_rules::MAXIMUM_PER_OWNER)
            .map(|entry| json!({ "key": entry.key, "title": entry.title, "body": entry.body, "repeats": entry.repeats(), "date": iso_dates::format(notification_rules::next_trigger(entry, now, &self.next_local)) }))
            .collect();
        self.validate(context, false)?;
        Ok(Value::Array(rows))
    }

    /// After the system gate (an action, the native grant, the query budget):
    /// strict options, a notification service (`permission_denied`), capacity
    /// (`limit_exceeded`). The same key replaces the installation's slot.
    pub fn schedule(&self, context: &CallContext, options: Option<&Object>) -> Result<Value, SystemReject> {
        self.check(context, true)?;
        let entry = notification_rules::parse(&context.installation, options.ok_or_else(|| SystemServiceError::InvalidOptions.reject())?, (self.clock)())?;
        if !self.platform.enabled() {
            return Err(SystemServiceError::PermissionDenied.reject());
        }
        self.store.locked(|| {
            let all = self.store.load()?;
            self.validate(context, true)?;
            if !notification_rules::has_capacity(&all, &entry.owner, &entry.key) {
                return Err(SystemServiceError::LimitExceeded.reject());
            }
            let mut next: Vec<_> = all.into_iter().filter(|known| !(known.owner == entry.owner && known.key == entry.key)).collect();
            next.push(entry.clone());
            if !self.store.save(&next) {
                return Err(SystemServiceError::Unavailable.reject());
            }
            Ok(())
        })?;
        Ok(json!({ "key": entry.key, "status": "scheduled" }))
    }

    /// Cancels this installation's pending slot. Notifications that were already shown are not touched.
    pub fn cancel(&self, context: &CallContext, key: Option<&Value>) -> Result<Value, SystemReject> {
        self.check(context, true)?;
        let key = key.and_then(Value::as_str).filter(|key| system_options::valid_key(key)).ok_or_else(|| SystemServiceError::InvalidOptions.reject())?;
        self.validate(context, true)?;
        self.store.remove(&context.installation, key);
        Ok(json!({ "key": key, "status": "cancellationRequested" }))
    }

    /// Cancels every slot of a deleted installation and forgets its grant.
    pub fn retire(&self, installation: &str) {
        let mine: Vec<_> = self.store.all().unwrap_or_default().into_iter().filter(|entry| entry.owner == installation).collect();
        for entry in &mine {
            self.store.remove(&entry.owner, &entry.key);
        }
        self.grants.retire(installation);
        system_log::call("notifications.retire", &format!("ok count={}", mine.len()));
    }
}

impl NativeModule for NotificationsModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("notifications.")
    }

    fn apis(&self) -> &[&'static str] {
        &["$notifications"]
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>, done: Completion) {
        let context = CallContext::from_request(request);
        let module = self.clone();
        let payload = payload.cloned().unwrap_or_default();
        let text = |result: Result<Value, SystemReject>| result.map(|value| stringify(&value));
        match operation {
            "notifications.status" => run_system(operation, done, move || text(module.status(&context))),
            "notifications.pending" => run_system(operation, done, move || text(module.pending(&context))),
            "notifications.schedule" => run_system(operation, done, move || text(module.schedule(&context, payload.opt_object("options")))),
            "notifications.cancel" => run_system(operation, done, move || text(module.cancel(&context, payload.get("key")))),
            _ => done.complete(false, Some(quote(&format!("Unsupported operation {operation}")))),
        }
    }
}

/// Runs work that shows a notification; the service hands it to a background thread.
pub type Dispatch = Arc<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>;

/// Shows pending notifications when their time has come. The background
/// service calls [`NotificationDelivery::deliver_due`] whenever it wakes and
/// sleeps no longer than the time that returns.
pub struct NotificationDelivery {
    store: Arc<NotificationStore>,
    platform: Arc<dyn NotificationPlatform>,
    next_local: NextLocalTime,
    dispatch: Dispatch,
    state: Mutex<DeliveryState>,
}

#[derive(Default)]
struct DeliveryState {
    /// When each daily entry is shown next, by owner, key and time of day.
    armed: HashMap<(String, String, u8, u8), i64>,
    /// When each installation's last notifications were shown.
    recent: HashMap<String, VecDeque<i64>>,
}

impl NotificationDelivery {
    /// An installation's notifications beyond this many in [`Self::RATE_WINDOW_MILLISECONDS`] wait.
    pub const MAXIMUM_PER_WINDOW: usize = 4;
    pub const RATE_WINDOW_MILLISECONDS: i64 = 60_000;

    /// Notifications are shown on the background threads of the system services.
    pub fn new(store: Arc<NotificationStore>, platform: Arc<dyn NotificationPlatform>) -> Self {
        Self::with_parts(store, platform, system_next_local_time(), Arc::new(crate::api::support::run_detached))
    }

    pub fn with_parts(store: Arc<NotificationStore>, platform: Arc<dyn NotificationPlatform>, next_local: NextLocalTime, dispatch: Dispatch) -> Self {
        Self { store, platform, next_local, dispatch, state: Mutex::default() }
    }

    /// Forgets when the daily entries were due: the clock or the time zone changed, so they are worked out again.
    pub fn rearm(&self) {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).armed.clear();
    }

    /// Shows what is due at `now_milliseconds` (wall clock) and returns when
    /// to look again, or `None` when nothing is pending. `installation_exists`
    /// is asked about the owner of each due entry: one whose package was
    /// deleted is removed without being shown. Does not wait for the
    /// notification service.
    pub fn deliver_due(&self, now_milliseconds: i64, installation_exists: &dyn Fn(&str) -> bool) -> Option<i64> {
        // A list that cannot be read shows nothing; it is looked at again when something else wakes the service.
        let entries = self.store.all().ok()?;
        let mut state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let state = &mut *state;
        state.armed.retain(|(owner, key, hour, minute), _| entries.iter().any(|entry| entry.owner == *owner && entry.key == *key && entry.daily == Some((*hour, *minute))));
        let mut next: Option<i64> = None;
        let mut sooner = |candidate: i64| next = Some(next.map_or(candidate, |known: i64| known.min(candidate)));
        for entry in entries {
            let due = match entry.daily {
                Some((hour, minute)) => *state.armed.entry((entry.owner.clone(), entry.key.clone(), hour, minute)).or_insert_with(|| (self.next_local)(now_milliseconds, hour, minute)),
                None => entry.date.unwrap_or(now_milliseconds),
            };
            if due > now_milliseconds {
                sooner(due);
                continue;
            }
            // Asked only for what is due: the answer may cost the caller a look at every package.
            if !installation_exists(&entry.owner) {
                self.store.remove(&entry.owner, &entry.key);
                system_log::call("notifications.fire", "owner_removed");
                continue;
            }
            let recent = state.recent.entry(entry.owner.clone()).or_default();
            while recent.front().is_some_and(|shown| now_milliseconds - shown >= Self::RATE_WINDOW_MILLISECONDS || *shown > now_milliseconds) {
                recent.pop_front();
            }
            if recent.len() >= Self::MAXIMUM_PER_WINDOW {
                // Too many in a minute: this one waits until the oldest of them is a minute old.
                sooner(recent.front().map_or(now_milliseconds, |shown| shown + Self::RATE_WINDOW_MILLISECONDS));
                continue;
            }
            match entry.daily {
                Some((hour, minute)) => {
                    let again = (self.next_local)(now_milliseconds, hour, minute);
                    state.armed.insert((entry.owner.clone(), entry.key.clone(), hour, minute), again);
                    sooner(again);
                }
                // Removed before it is shown, and not shown when it cannot be removed (a disk that
                // refuses the write): a notification is never shown twice.
                None => {
                    if !self.store.remove(&entry.owner, &entry.key) {
                        system_log::call("notifications.fire", "unavailable");
                        continue;
                    }
                }
            }
            state.recent.entry(entry.owner.clone()).or_default().push_back(now_milliseconds);
            let platform = self.platform.clone();
            let repeats = entry.repeats();
            (self.dispatch)(Box::new(move || {
                let shown = platform.post(&entry.title, &entry.body);
                system_log::call("notifications.fire", if !shown { "unavailable" } else if repeats { "ok repeats=true" } else { "ok repeats=false" });
            }));
        }
        state.recent.retain(|_, shown| !shown.is_empty());
        next
    }
}
