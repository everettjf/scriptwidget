//! The shared pieces of the Runtime 1.6 system services that `$weather`
//! needs. Ported from `Windows/src/ScriptWidget.Core/Api/SystemSupport.cs`;
//! the other services (grants, mutation receipts, permission prompts) are
//! added with the APIs that use them.

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::api::policy;
use crate::api::workers::BoundedExecutor;
use crate::executor::{Completion, ExecutionRequest};
use crate::json::{Object, ObjectExt, as_text, quote, stringify_object};

/// A rejection whose message is delivered to the script verbatim. It never contains user data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemReject(pub String);

impl fmt::Display for SystemReject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for SystemReject {}

/// Error codes shared by the Runtime 1.6 system services. The message is the
/// same sentence the Apple runtime uses, so scripts that match on the
/// bracketed code behave the same on Linux.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SystemServiceError {
    InvalidOptions,
    PermissionDenied,
    Unavailable,
    QueryLimit,
    ReadOnly,
    ScopeChanged,
    LimitExceeded,
    OutcomeUnknown,
    RequestConflict,
}

/// Message for a failure that is not one of the known codes.
pub const SYSTEM_FAILED: &str = "[system_failed] System operation failed; review the result before retrying a write.";

impl SystemServiceError {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidOptions => "invalid_options",
            Self::PermissionDenied => "permission_denied",
            Self::Unavailable => "unavailable",
            Self::QueryLimit => "query_limit",
            Self::ReadOnly => "read_only",
            Self::ScopeChanged => "scope_changed",
            Self::LimitExceeded => "limit_exceeded",
            Self::OutcomeUnknown => "outcome_unknown",
            Self::RequestConflict => "request_conflict",
        }
    }

    pub fn message(self) -> String {
        format!("[{}] System operation could not complete. Existing user data is preserved.", self.code())
    }

    pub fn reject(self) -> SystemReject {
        SystemReject(self.message())
    }
}

type Sink = Arc<dyn Fn(&str) + Send + Sync>;

static LOG_SINK: RwLock<Option<Sink>> = RwLock::new(None);

/// One line per native call. Callers pass operation names and error codes only, never user data.
pub mod system_log {
    use super::{LOG_SINK, Sink};

    /// Sets what receives each line: the host's log, or a test. Nothing is
    /// written by default. Returns the previous sink.
    pub fn set_sink(sink: Option<Sink>) -> Option<Sink> {
        std::mem::replace(&mut *LOG_SINK.write().unwrap_or_else(|poisoned| poisoned.into_inner()), sink)
    }

    pub fn call(operation: &str, outcome: &str) {
        let sink = LOG_SINK.read().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
        if let Some(sink) = sink {
            sink(&format!("{operation} -> {outcome}"));
        }
    }

    /// The bracketed code of a rejection message, or `error` when it has none. The free text is never logged.
    pub fn code(message: &str) -> &str {
        let Some(rest) = message.strip_prefix('[') else { return "error" };
        let Some(end) = rest.find(']') else { return "error" };
        let code = &rest[..end];
        if (1..=40).contains(&code.len()) && code.bytes().all(|byte| byte.is_ascii_alphabetic() || byte == b'_' || byte == b':') { code } else { "error" }
    }
}

/// Background workers for system queries.
fn system_pool() -> &'static BoundedExecutor {
    static POOL: OnceLock<BoundedExecutor> = OnceLock::new();
    POOL.get_or_init(|| BoundedExecutor::new(4))
}

/// Runs `block` off the JavaScript thread, logs one line, and completes
/// `done` exactly once with JSON or a rejection message.
pub fn run_system(operation: &str, done: Completion, block: impl FnOnce() -> Result<String, SystemReject> + Send + 'static) {
    let operation = operation.to_owned();
    system_pool().execute(move || match block() {
        Ok(json) => {
            system_log::call(&operation, "ok");
            done.complete(true, Some(json));
        }
        Err(SystemReject(message)) => {
            let message = if message.is_empty() { SYSTEM_FAILED.to_owned() } else { message };
            system_log::call(&operation, system_log::code(&message));
            done.complete(false, Some(quote(&message)));
        }
    });
}

type Probe = Box<dyn Fn() -> bool + Send + Sync>;

/// The facts about one execution that policy decisions need. Built from the
/// [`ExecutionRequest`] in production and directly in tests, so every rule
/// can be exercised without the JavaScript engine.
pub struct CallContext {
    /// Installation identity; namespaces grants, receipts and caches.
    pub installation: String,
    pub has_manifest: bool,
    pub permissions: HashSet<String>,
    pub network_domains: Vec<String>,
    pub minimum_runtime_version: Option<String>,
    pub is_action: bool,
    pub is_timeline_projection: bool,
    pub is_live_activity: bool,
    data_query: Option<Probe>,
    network_request: Option<Probe>,
    active: Option<Probe>,
}

impl CallContext {
    pub const MAXIMUM_DATA_QUERIES: u32 = 8;
    pub const MAXIMUM_NETWORK_REQUESTS: u32 = 32;

    /// A context without budgets: every query is granted and the execution counts as running.
    pub fn new(installation: &str, has_manifest: bool, permissions: &[&str], network_domains: &[&str], minimum_runtime_version: Option<&str>) -> Self {
        Self {
            installation: installation.to_owned(),
            has_manifest,
            permissions: permissions.iter().map(|item| item.to_string()).collect(),
            network_domains: network_domains.iter().map(|item| item.to_string()).collect(),
            minimum_runtime_version: minimum_runtime_version.map(str::to_owned),
            is_action: false,
            is_timeline_projection: false,
            is_live_activity: false,
            data_query: None,
            network_request: None,
            active: None,
        }
    }

    /// Replaces the budgets and the liveness check.
    pub fn with_probes(
        mut self,
        data_query: impl Fn() -> bool + Send + Sync + 'static,
        network_request: impl Fn() -> bool + Send + Sync + 'static,
        active: impl Fn() -> bool + Send + Sync + 'static,
    ) -> Self {
        self.data_query = Some(Box::new(data_query));
        self.network_request = Some(Box::new(network_request));
        self.active = Some(Box::new(active));
        self
    }

    /// An installed owner is a canonical lowercase UUID; previews and unmanaged packages are not owners.
    pub fn is_installed(&self) -> bool {
        is_owner(&self.installation)
    }

    /// True while the execution is still running; results for a finished execution are dropped.
    pub fn is_active(&self) -> bool {
        self.active.as_ref().is_none_or(|probe| probe())
    }

    /// Takes one of the eight system-data queries of this execution. False when the budget is spent.
    pub fn consume_data_query(&self) -> bool {
        self.data_query.as_ref().is_none_or(|probe| probe())
    }

    /// Takes one of the 32 network requests of this execution.
    pub fn consume_network_request(&self) -> bool {
        self.network_request.as_ref().is_none_or(|probe| probe())
    }

    /// Package 2.0 permission check: a missing manifest never declares anything.
    pub fn declares(&self, permission: &str) -> bool {
        self.has_manifest && self.permissions.contains(permission)
    }

    /// `network` plus a matching `networkDomains` entry, the rule `fetch` applies.
    pub fn allows_host(&self, host: &str) -> bool {
        self.declares("network") && policy::host_matches(host, self.network_domains.iter().map(String::as_str))
    }

    pub fn from_request(request: &ExecutionRequest<'_>) -> Self {
        let manifest = request.prepared.manifest.as_ref();
        let strings = |key: &str| -> Vec<String> {
            manifest.and_then(|manifest| manifest.opt_array(key)).map(|items| items.iter().map(|item| as_text(item).unwrap_or_default()).collect()).unwrap_or_default()
        };
        let runtime = manifest.map(|manifest| manifest.opt_string("minimumRuntimeVersion")).unwrap_or_default();
        let (queries, requests, liveness) = (request.session.clone(), request.session.clone(), request.session.clone());
        Self {
            installation: request.package_id.clone(),
            // A present manifest that could not be read still counts as present: it declares nothing and is never treated as legacy.
            has_manifest: request.prepared.has_manifest,
            permissions: strings("permissions").into_iter().collect(),
            network_domains: strings("networkDomains"),
            minimum_runtime_version: if runtime.is_empty() { None } else { Some(runtime) },
            is_action: policy::is_action(request),
            is_timeline_projection: policy::is_timeline_projection(request),
            is_live_activity: policy::is_live_activity(request),
            data_query: Some(Box::new(move || queries.add_data_query() <= Self::MAXIMUM_DATA_QUERIES)),
            network_request: Some(Box::new(move || requests.add_network_request() <= Self::MAXIMUM_NETWORK_REQUESTS)),
            active: Some(Box::new(move || !liveness.finished())),
        }
    }
}

/// `8-4-4-4-12` lower-case hexadecimal digits.
pub fn is_owner(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
        })
}

/// ISO-8601 instants in the forms the Apple runtime accepts and produces.
pub mod iso_dates {
    /// Epoch milliseconds of a full date-time with a time zone, or `None`.
    /// Dates without a zone or with impossible fields are rejected.
    pub fn parse(text: &str) -> Option<i64> {
        let bytes = text.as_bytes();
        if bytes.len() > 64 {
            return None;
        }
        let mut at = 0usize;
        let digits = |count: usize, at: &mut usize| -> Option<i64> {
            let slice = bytes.get(*at..*at + count)?;
            if !slice.iter().all(u8::is_ascii_digit) {
                return None;
            }
            *at += count;
            Some(slice.iter().fold(0i64, |value, digit| value * 10 + i64::from(digit - b'0')))
        };
        let literal = |expected: u8, at: &mut usize| -> Option<()> {
            if bytes.get(*at) == Some(&expected) {
                *at += 1;
                Some(())
            } else {
                None
            }
        };
        let year = digits(4, &mut at)?;
        literal(b'-', &mut at)?;
        let month = digits(2, &mut at)?;
        literal(b'-', &mut at)?;
        let day = digits(2, &mut at)?;
        literal(b'T', &mut at)?;
        let hour = digits(2, &mut at)?;
        literal(b':', &mut at)?;
        let minute = digits(2, &mut at)?;
        literal(b':', &mut at)?;
        let second = digits(2, &mut at)?;
        let mut fraction = 0i64;
        if bytes.get(at) == Some(&b'.') {
            at += 1;
            let start = at;
            while at < bytes.len() && bytes[at].is_ascii_digit() {
                at += 1;
            }
            if at == start || at - start > 9 {
                return None;
            }
            // Milliseconds: the first three digits, padded on the right.
            for index in 0..3 {
                fraction = fraction * 10 + bytes.get(start + index).filter(|_| start + index < at).map_or(0, |digit| i64::from(digit - b'0'));
            }
        }
        let mut offset_minutes = 0i64;
        match bytes.get(at) {
            Some(b'Z') => at += 1,
            Some(sign @ (b'+' | b'-')) => {
                at += 1;
                let hours = digits(2, &mut at)?;
                literal(b':', &mut at)?;
                let rest = digits(2, &mut at)?;
                if hours > 18 || rest > 59 || (hours == 18 && rest != 0) {
                    return None;
                }
                offset_minutes = (if *sign == b'-' { -1 } else { 1 }) * (hours * 60 + rest);
            }
            _ => return None,
        }
        if at != bytes.len() {
            return None;
        }
        if year < 1 || !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 59 {
            return None;
        }
        let seconds = days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second;
        Some(seconds * 1000 - offset_minutes * 60_000 + fraction)
    }

    /// `2026-11-01T12:00:00Z`: whole seconds, UTC.
    pub fn format(milliseconds: i64) -> String {
        let seconds = if milliseconds >= 0 { milliseconds / 1000 } else { -((-milliseconds + 999) / 1000) };
        let days = seconds.div_euclid(86_400);
        let time = seconds.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", time / 3600, time / 60 % 60, time % 60)
    }

    fn days_in_month(year: i64, month: i64) -> i64 {
        match month {
            2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
            2 => 28,
            4 | 6 | 9 | 11 => 30,
            _ => 31,
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
        let year = if month <= 2 { year - 1 } else { year };
        let era = year.div_euclid(400);
        let year_of_era = year.rem_euclid(400);
        let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
        let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
        era * 146_097 + day_of_era - 719_468
    }

    fn civil_from_days(days: i64) -> (i64, i64, i64) {
        let shifted = days + 719_468;
        let era = shifted.div_euclid(146_097);
        let day_of_era = shifted.rem_euclid(146_097);
        let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
        let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
        let month_index = (5 * day_of_year + 2) / 153;
        let day = day_of_year - (153 * month_index + 2) / 5 + 1;
        let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
        (year_of_era + era * 400 + i64::from(month <= 2), month, day)
    }
}

/// Strict, bounded option parsing shared by the system services. Every failure is `invalid_options`.
pub mod system_options {
    use super::*;

    pub const MAXIMUM_OPTION_BYTES: usize = 16384;

    fn invalid() -> SystemReject {
        SystemServiceError::InvalidOptions.reject()
    }

    /// Rejects unknown fields and option objects above 16 KiB.
    pub fn fields(options: &Object, allowed: &[&str]) -> Result<(), SystemReject> {
        if options.keys().any(|key| !allowed.contains(&key.as_str())) || stringify_object(options).len() > MAXIMUM_OPTION_BYTES {
            return Err(invalid());
        }
        Ok(())
    }

    pub fn has_control_characters(text: &str) -> bool {
        text.chars().any(is_control_or_format)
    }

    /// A finite JSON number inside the range; Booleans and strings are not numbers.
    pub fn number(value: Option<&Value>, minimum: f64, maximum: f64) -> Result<f64, SystemReject> {
        match json_number(value) {
            Some(number) if number.is_finite() && number >= minimum && number <= maximum => Ok(number),
            _ => Err(invalid()),
        }
    }

    /// The value of a JSON number; `None` for everything else.
    pub fn json_number(value: Option<&Value>) -> Option<f64> {
        match value {
            Some(Value::Number(number)) => number.as_f64(),
            _ => None,
        }
    }

    pub fn integer(value: Option<&Value>, minimum: i32, maximum: i32) -> Result<i32, SystemReject> {
        let number = number(value, f64::from(minimum), f64::from(maximum))?;
        if number.round_ties_even() != number {
            return Err(invalid());
        }
        Ok(number as i32)
    }
}

/// True for the Unicode categories Cc (control) and Cf (format).
pub fn is_control_or_format(character: char) -> bool {
    if character.is_control() {
        return true;
    }
    // General category Cf, Unicode 16.
    const FORMAT: &[(u32, u32)] = &[
        (0x00AD, 0x00AD),
        (0x0600, 0x0605),
        (0x061C, 0x061C),
        (0x06DD, 0x06DD),
        (0x070F, 0x070F),
        (0x0890, 0x0891),
        (0x08E2, 0x08E2),
        (0x180E, 0x180E),
        (0x200B, 0x200F),
        (0x202A, 0x202E),
        (0x2060, 0x2064),
        (0x2066, 0x206F),
        (0xFEFF, 0xFEFF),
        (0xFFF9, 0xFFFB),
        (0x110BD, 0x110BD),
        (0x110CD, 0x110CD),
        (0x13430, 0x1343F),
        (0x1BCA0, 0x1BCA3),
        (0x1D173, 0x1D17A),
        (0xE0001, 0xE0001),
        (0xE0020, 0xE007F),
    ];
    let code = character as u32;
    FORMAT.iter().any(|(first, last)| (*first..=*last).contains(&code))
}

/// Digests for cache identities.
pub mod canonical {
    use super::*;

    pub fn sha256(text: &str) -> String {
        Sha256::digest(text.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// File names for per-installation records: a digest, so an identity can never become a path.
    pub fn owner_file_name(installation: &str, suffix: &str) -> String {
        format!("{}{suffix}", &sha256(installation)[..40])
    }
}

/// A present private file that cannot be read; callers fail closed instead of treating it as missing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unreadable;

/// A small private JSON file. Reads are bounded and refuse links and
/// non-regular files; writes replace the file atomically and leave it
/// readable by the user only.
pub struct PrivateFile {
    path: PathBuf,
    maximum_bytes: usize,
}

impl PrivateFile {
    pub fn new(path: impl Into<PathBuf>, maximum_bytes: usize) -> Self {
        Self { path: path.into(), maximum_bytes }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Lock shared by every reader and writer of this path in the process.
    pub fn lock(&self) -> Arc<Mutex<()>> {
        static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
        let key = std::path::absolute(&self.path).unwrap_or_else(|_| self.path.clone());
        let mut locks = LOCKS.get_or_init(Default::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        locks.entry(key).or_default().clone()
    }

    pub fn exists(&self) -> bool {
        std::fs::symlink_metadata(&self.path).is_ok()
    }

    /// File text, or `None` when the file does not exist.
    pub fn read(&self) -> Result<Option<String>, Unreadable> {
        let before = match std::fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(Unreadable),
        };
        if !before.file_type().is_file() {
            return Err(Unreadable);
        }
        let file = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(&self.path).map_err(|_| Unreadable)?;
        let opened = file.metadata().map_err(|_| Unreadable)?;
        // The opened file must be the regular file that was looked at.
        if !opened.is_file() || opened.dev() != before.dev() || opened.ino() != before.ino() || opened.len() > self.maximum_bytes as u64 {
            return Err(Unreadable);
        }
        let mut bytes = Vec::new();
        file.take(self.maximum_bytes as u64 + 1).read_to_end(&mut bytes).map_err(|_| Unreadable)?;
        if bytes.len() > self.maximum_bytes {
            return Err(Unreadable);
        }
        Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
    }

    /// Writes the text through a temporary file and an atomic rename. False
    /// when it exceeds the bound or the disk refuses it.
    pub fn write(&self, text: &str) -> bool {
        if text.len() > self.maximum_bytes {
            return false;
        }
        let mut temporary = self.path.clone().into_os_string();
        temporary.push(".tmp");
        let temporary = PathBuf::from(temporary);
        let written = (|| -> std::io::Result<()> {
            if let Some(parent) = self.path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
                std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
            }
            // The temporary name is fixed and guarded by the file's lock; a stale one is replaced.
            let _ = std::fs::remove_file(&temporary);
            let mut output = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
            output.write_all(text.as_bytes())?;
            output.sync_all()?;
            std::fs::rename(&temporary, &self.path)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written.is_ok()
    }

    pub fn delete(&self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// The shared gate of the Runtime 1.6 system services. The order is the Apple
/// runtime's and decides which code a script sees:
/// 1. `permission_denied`: not an installed owner, no manifest, the permission
///    is not declared, or `minimumRuntimeVersion` is below 1.6;
/// 2. `read_only`: a future timeline entry, a Live Activity presentation, or
///    a write outside a user-initiated action;
/// 3. `query_limit`: the eight-query budget of the execution is spent.
///
/// Services with a per-widget native grant check it between steps 2 and 3; `$weather` has none.
pub mod system_gate {
    use super::*;

    pub fn check(context: &CallContext, permission: &str, writing: bool) -> Result<(), SystemReject> {
        validate(context, permission, writing)?;
        if !context.consume_data_query() {
            return Err(SystemServiceError::QueryLimit.reject());
        }
        Ok(())
    }

    /// Steps 1 and 2 only; repeated before a result is delivered so a changed state stops an in-flight call.
    pub fn validate(context: &CallContext, permission: &str, writing: bool) -> Result<(), SystemReject> {
        if !context.is_installed() || !context.declares(permission) || !supports_runtime("1.6", context.minimum_runtime_version.as_deref()) {
            return Err(SystemServiceError::PermissionDenied.reject());
        }
        if context.is_timeline_projection || context.is_live_activity || (writing && !context.is_action) {
            return Err(SystemServiceError::ReadOnly.reject());
        }
        Ok(())
    }

    /// True when `declared` (`major.minor`) is at least `required`. A missing or malformed version is 0.0.
    pub fn supports_runtime(required: &str, declared: Option<&str>) -> bool {
        fn parts(text: &str) -> Option<(u32, u32)> {
            let (major, minor) = text.split_once('.')?;
            let field = |text: &str| if (1..=4).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_digit()) { text.parse::<u32>().ok() } else { None };
            Some((field(major)?, field(minor)?))
        }
        let Some(need) = parts(required) else { return false };
        let have = declared.and_then(parts).unwrap_or((0, 0));
        have >= need
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owners_are_canonical_lowercase_uuids() {
        assert!(is_owner("11111111-1111-4111-8111-111111111111"));
        assert!(is_owner("abcdef01-2345-6789-abcd-ef0123456789"));
        for value in ["", "preview", "11111111-1111-4111-8111-11111111111", "11111111-1111-4111-8111-1111111111111", "ABCDEF01-2345-6789-abcd-ef0123456789", "11111111x1111-4111-8111-111111111111"] {
            assert!(!is_owner(value), "{value}");
        }
    }

    #[test]
    fn runtime_versions_compare_numerically() {
        use system_gate::supports_runtime;
        assert!(supports_runtime("1.6", Some("1.6")));
        assert!(supports_runtime("1.6", Some("1.10")));
        assert!(supports_runtime("1.6", Some("2.0")));
        for declared in [None, Some("1.5"), Some(""), Some("1"), Some("1.6.0"), Some("v1.6"), Some("1.66666")] {
            assert!(!supports_runtime("1.6", declared), "{declared:?}");
        }
        assert!(!supports_runtime("latest", Some("9.9")));
    }

    #[test]
    fn log_codes_never_carry_free_text() {
        assert_eq!(system_log::code("[permission_denied] System operation could not complete."), "permission_denied");
        assert_eq!(system_log::code("[weather:Limit] x"), "weather:Limit");
        for message in ["no code", "[] empty", "[has space] x", "[unterminated", "x [late] y", "[1234] digits"] {
            assert_eq!(system_log::code(message), "error", "{message}");
        }
        assert_eq!(SystemServiceError::QueryLimit.message(), "[query_limit] System operation could not complete. Existing user data is preserved.");
    }

    #[test]
    fn control_and_format_characters_are_recognized() {
        for character in ['\0', '\n', '\u{7f}', '\u{85}', '\u{ad}', '\u{200b}', '\u{200d}', '\u{202e}', '\u{feff}', '\u{e0041}'] {
            assert!(is_control_or_format(character), "{:x}", character as u32);
        }
        for character in ['a', ' ', '\u{a0}', '\u{2028}', '你', '🌧'] {
            assert!(!is_control_or_format(character), "{:x}", character as u32);
        }
    }

    #[test]
    fn private_files_are_bounded_private_and_refuse_links() {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!("scriptwidget-test-private-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        let file = PrivateFile::new(directory.join("nested").join("record.json"), 16);
        assert_eq!(file.read(), Ok(None));
        assert!(!file.exists());
        assert!(file.write("{\"a\":1}"));
        assert_eq!(file.read(), Ok(Some("{\"a\":1}".into())));
        assert_eq!(std::fs::metadata(file.path()).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(directory.join("nested")).unwrap().permissions().mode() & 0o777, 0o700);
        assert!(!file.write("12345678901234567"), "over the bound");
        assert_eq!(file.read(), Ok(Some("{\"a\":1}".into())));
        // A file that grew behind the bound, a directory and a link are unreadable, not missing.
        std::fs::write(file.path(), "12345678901234567").unwrap();
        assert_eq!(file.read(), Err(Unreadable));
        file.delete();
        std::fs::create_dir(file.path()).unwrap();
        assert_eq!(file.read(), Err(Unreadable));
        std::fs::remove_dir(file.path()).unwrap();
        std::fs::write(directory.join("target.json"), "secret").unwrap();
        std::os::unix::fs::symlink(directory.join("target.json"), file.path()).unwrap();
        assert_eq!(file.read(), Err(Unreadable));
        assert!(file.exists());
        let _ = std::fs::remove_dir_all(&directory);
    }
}
