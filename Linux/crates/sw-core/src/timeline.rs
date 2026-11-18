//! Evaluates a package's `timeline.dailyTimes` schedule with the planner
//! shared with iOS and the web preview (`Web/preview-engine/src/timeline.js`),
//! so slots, time zones and daylight-saving rules agree on every platform.
//! Ported from `Windows/src/ScriptWidget.Core/Runtime/TimelinePlanner.cs`.
//!
//! iOS hands WidgetKit pre-rendered future entries. Linux, like Android and
//! Windows, wakes at the next transition and runs the script again as the
//! current entry.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;
use sw_quickjs::{DEFAULT_STACK_LIMIT, Engine, JS_THREAD_STACK, JsError, run_on_js_thread};

use crate::api::support::iso_dates;
use crate::intl;
use crate::json::{Object, ObjectExt, as_text, parse_object, stringify_object};
use crate::shared_scripts::SharedScripts;

/// The current timeline entry of a package and when the next one starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimelineState {
    /// In the order the planner produced them.
    pub environments: Vec<(String, String)>,
    /// Epoch milliseconds.
    pub next_transition_milliseconds: Option<i64>,
}

struct Cached {
    state: TimelineState,
    from: i64,
    until: i64,
}

const PLANNER_MEMORY: usize = 32 * 1024 * 1024;
const PLANNER_DEADLINE_MILLISECONDS: u64 = 6000;
const MAXIMUM_CACHED_PLANS: usize = 32;
const HOUR_MILLISECONDS: i64 = 3_600_000;

pub struct TimelinePlanner {
    scripts: Arc<SharedScripts>,
    cache: Mutex<HashMap<String, Cached>>,
}

impl TimelinePlanner {
    pub fn new(scripts: Arc<SharedScripts>) -> Self {
        Self { scripts, cache: Mutex::new(HashMap::new()) }
    }

    /// The entry that applies now. `None` when the manifest declares no schedule or the schedule is invalid.
    pub fn state(&self, manifest: Option<&Object>) -> Option<TimelineState> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64);
        self.state_at(manifest, now)
    }

    /// The entry that applies at `now_milliseconds`.
    pub fn state_at(&self, manifest: Option<&Object>, now_milliseconds: i64) -> Option<TimelineState> {
        let schedule = manifest?.opt_object("timeline")?;
        // A plan stays correct until its next transition, so widgets that refresh often reuse it.
        let key = format!("{}|{}", stringify_object(schedule), intl::default_time_zone());
        {
            let cache = self.cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(hit) = cache.get(&key).filter(|hit| now_milliseconds >= hit.from && now_milliseconds < hit.until) {
                return Some(hit.state.clone());
            }
        }
        let state = self.evaluate(schedule, now_milliseconds)?;
        let until = state.next_transition_milliseconds.unwrap_or(i64::MAX).min(now_milliseconds.saturating_add(HOUR_MILLISECONDS));
        let mut cache = self.cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if cache.len() >= MAXIMUM_CACHED_PLANS {
            cache.clear();
        }
        cache.insert(key, Cached { state: state.clone(), from: now_milliseconds, until });
        Some(state)
    }

    fn evaluate(&self, schedule: &Object, now_milliseconds: i64) -> Option<TimelineState> {
        // A failure is not reported in detail: the schedule is package data, and the manifest
        // validator has already told the author what is wrong with it.
        let plan = self.plan(schedule, now_milliseconds).ok().flatten().and_then(|text| parse_object(&text).ok())?;
        let entries = plan.opt_array("entries").filter(|entries| !entries.is_empty())?;
        let current = entries[0].as_object()?.opt_object("environments")?;
        let environments = current.iter().map(|(name, value)| (name.clone(), as_text(value).unwrap_or_default())).collect();
        let next = entries.get(1).and_then(Value::as_object).map(|entry| entry.opt_string("date")).filter(|date| !date.is_empty()).and_then(|date| iso_dates::parse(&date));
        Some(TimelineState { environments, next_transition_milliseconds: next })
    }

    /// Runs the shared planner in a small context: it needs Intl and the prepare bundle, not Babel.
    fn plan(&self, schedule: &Object, now_milliseconds: i64) -> Result<Option<String>, JsError> {
        run_on_js_thread("scriptwidget-timeline", JS_THREAD_STACK, || {
            let asset = |name: &str| self.scripts.text(name).map_err(|error| JsError { message: format!("ScriptWidget runtime asset could not be read: {error}"), interrupted: false });
            let mut engine = Engine::with_limits(|operation: &str, payload: Option<&str>| intl::call(operation, payload), PLANNER_MEMORY, DEFAULT_STACK_LIMIT)?;
            engine.set_deadline(PLANNER_DEADLINE_MILLISECONDS);
            engine.evaluate(&asset("host.js")?, "host.js")?;
            engine.evaluate(
                "globalThis.TextEncoder = class { encode(text) { return new Uint8Array(unescape(encodeURIComponent(String(text))).split('').map(function (c) { return c.charCodeAt(0); })); } };",
                "prelude.js",
            )?;
            engine.evaluate(&asset("prepare.js")?, "prepare.js")?;
            engine.evaluate(
                "globalThis.__swPlan = function (schedule, now, zone) { var time = Number(now);\
                 return JSON.stringify(__swPrepareBundle.buildTimelinePlan(JSON.parse(schedule), new Date(time), new Date(time + 3600000), zone)); };",
                "timeline-driver.js",
            )?;
            engine.call("__swPlan", &[Some(&stringify_object(schedule)), Some(&now_milliseconds.to_string()), Some(&intl::default_time_zone())])
        })
    }
}
