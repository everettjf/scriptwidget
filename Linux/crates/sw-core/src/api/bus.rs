//! The session D-Bus, reached through `busctl` (part of systemd) and not
//! through a D-Bus library: see the dependency notes in `Linux/Cargo.toml`.
//! Three things are asked of the bus: which media players there are and what
//! they play (MPRIS), whether a notification service is there, and to show a
//! notification.
//!
//! Every call is `busctl --user --json=short --timeout=… call -- <destination>
//! <path> <interface> <member> [<signature> <values>…]` as an argument list,
//! never through a shell. Text that comes from a package (the title and body
//! of a notification) is only ever a value after `--` and after the
//! signature, where `busctl` reads it as that value and nothing else. A bus
//! name that came from the bus is checked against the D-Bus name grammar
//! before it is used as a destination. The child is killed when it does not
//! end in time (see [`crate::process`]).

use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use crate::json::{Object, ObjectExt};
use crate::process::{RunError, on_path, run_bounded};

/// The bus, or the program that reaches it, gave no usable answer. The reason is not passed to scripts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BusError {
    /// `busctl` is not installed.
    NoProgram,
    /// No session bus, no such service, a refusal, or an answer that is not what was asked for.
    Failed,
    TimedOut,
}

/// More than an answer to one of the calls here can be.
const MAXIMUM_REPLY_BYTES: usize = 256 * 1024;
const DBUS: (&str, &str, &str) = ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
const NOTIFICATIONS: (&str, &str, &str) = ("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications");

#[derive(Debug, Clone)]
pub struct SessionBus {
    program: PathBuf,
}

impl Default for SessionBus {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionBus {
    /// `busctl` as the `PATH` finds it.
    pub fn new() -> Self {
        Self { program: PathBuf::from("busctl") }
    }

    /// Another program that takes the same arguments; for tests.
    pub fn with_program(program: impl Into<PathBuf>) -> Self {
        Self { program: program.into() }
    }

    /// Whether the program is there at all. Starts nothing.
    pub fn installed(&self) -> bool {
        on_path(&self.program)
    }

    /// One method call; the `data` of busctl's JSON answer.
    fn call(&self, target: (&str, &str, &str), member: &str, values: &[&str], limit: Duration) -> Result<Vec<Value>, BusError> {
        // busctl gives up a little before this process stops waiting for it.
        let timeout = format!("--timeout={}ms", limit.as_millis().saturating_sub(100).max(100));
        let mut arguments = vec!["--user", "--json=short", "--no-pager", timeout.as_str(), "call", "--", target.0, target.1, target.2, member];
        arguments.extend_from_slice(values);
        let finished = run_bounded(&self.program, &arguments, None, limit, MAXIMUM_REPLY_BYTES, &[crate::ai::credentials::ENVIRONMENT_KEY]).map_err(|error| match error {
            RunError::NotFound => BusError::NoProgram,
            RunError::TimedOut => BusError::TimedOut,
            RunError::Failed | RunError::TooMuchOutput => BusError::Failed,
        })?;
        if !finished.success {
            return Err(BusError::Failed);
        }
        match serde_json::from_slice::<Value>(&finished.stdout) {
            Ok(Value::Object(mut reply)) => match reply.remove("data") {
                Some(Value::Array(data)) => Ok(data),
                _ => Err(BusError::Failed),
            },
            _ => Err(BusError::Failed),
        }
    }

    /// The names on the bus that have an owner now.
    pub fn names(&self, limit: Duration) -> Result<Vec<String>, BusError> {
        let data = self.call(DBUS, "ListNames", &[], limit)?;
        let names = data.first().and_then(Value::as_array).ok_or(BusError::Failed)?;
        Ok(names.iter().filter_map(Value::as_str).map(str::to_owned).collect())
    }

    pub fn has_owner(&self, name: &str, limit: Duration) -> Result<bool, BusError> {
        if !is_bus_name(name) {
            return Err(BusError::Failed);
        }
        self.call(DBUS, "NameHasOwner", &["s", name], limit)?.first().and_then(Value::as_bool).ok_or(BusError::Failed)
    }

    /// Every property of one interface of an object, with the D-Bus type
    /// wrappers of busctl's JSON removed (see [`plain`]).
    pub fn properties(&self, destination: &str, path: &str, interface: &str, limit: Duration) -> Result<Object, BusError> {
        if !is_bus_name(destination) || !is_bus_name(interface) || !is_object_path(path) {
            return Err(BusError::Failed);
        }
        let data = self.call((destination, path, "org.freedesktop.DBus.Properties"), "GetAll", &["s", interface], limit)?;
        match data.into_iter().next().map(plain) {
            Some(Value::Object(properties)) => Ok(properties),
            _ => Err(BusError::Failed),
        }
    }

    /// Whether a notification service owns its name now.
    pub fn has_notification_service(&self, limit: Duration) -> Result<bool, BusError> {
        self.has_owner(NOTIFICATIONS.0, limit)
    }

    /// What the notification service says it can do, such as `body-markup`.
    pub fn notification_capabilities(&self, limit: Duration) -> Result<Vec<String>, BusError> {
        let data = self.call(NOTIFICATIONS, "GetCapabilities", &[], limit)?;
        Ok(data.first().and_then(Value::as_array).ok_or(BusError::Failed)?.iter().filter_map(Value::as_str).map(str::to_owned).collect())
    }

    /// Shows one notification from "ScriptWidget" with the service's default
    /// timeout, no actions and no hints, and returns the service's number for it.
    /// `title` and `body` are passed as values; the caller bounds them.
    pub fn notify(&self, title: &str, body: &str, limit: Duration) -> Result<u32, BusError> {
        // No argument may hold a NUL: the operating system would cut it there.
        if title.contains('\0') || body.contains('\0') {
            return Err(BusError::Failed);
        }
        // app_name, replaces_id, app_icon, summary, body, actions (none), hints (none), expire_timeout (the service's default).
        let data = self.call(NOTIFICATIONS, "Notify", &["susssasa{sv}i", "ScriptWidget", "0", "", title, body, "0", "0", "-1"], limit)?;
        data.first().and_then(Value::as_u64).and_then(|number| u32::try_from(number).ok()).ok_or(BusError::Failed)
    }
}

/// A D-Bus bus or interface name: elements of letters, digits, `_` and `-`
/// joined by dots, at most 255 bytes, or a unique name (`:1.42`). Never
/// something `busctl` could read as an option.
pub fn is_bus_name(name: &str) -> bool {
    let body = name.strip_prefix(':').unwrap_or(name);
    !name.is_empty()
        && name.len() <= 255
        && body.contains('.')
        && body.split('.').all(|element| !element.is_empty() && element.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'))
        && !name.starts_with('-')
}

/// A D-Bus object path: `/`, or elements of letters, digits and `_` each led by a slash.
pub fn is_object_path(path: &str) -> bool {
    path == "/" || (path.starts_with('/') && path.len() <= 255 && path[1..].split('/').all(|element| !element.is_empty() && element.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')))
}

/// busctl writes a variant as `{"type": "<signature>", "data": <value>}`. This
/// replaces every such wrapper by its value, to any depth the answer has.
pub fn plain(value: Value) -> Value {
    match value {
        Value::Object(object) => {
            if object.len() == 2 && object.get("type").is_some_and(Value::is_string) && object.has("data") {
                let mut object = object;
                return plain(object.remove("data").unwrap_or(Value::Null));
            }
            Value::Object(object.into_iter().map(|(name, member)| (name, plain(member))).collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(plain).collect()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_paths_follow_the_dbus_grammar() {
        for name in ["org.mpris.MediaPlayer2.mpv.instance-dybtSAIF", "org.freedesktop.Notifications", ":1.89", "a.b"] {
            assert!(is_bus_name(name), "{name}");
        }
        for name in ["", "--help", "-a.b", "org", "org..x", "org.x.", "org.x y", "org.x;rm", "org.mpris/x", &format!("a.{}", "b".repeat(255))] {
            assert!(!is_bus_name(name), "{name}");
        }
        for path in ["/", "/org/mpris/MediaPlayer2", "/a_1"] {
            assert!(is_object_path(path), "{path}");
        }
        for path in ["", "org", "//", "/a/", "/a-b", "/a b", "--x"] {
            assert!(!is_object_path(path), "{path}");
        }
    }

    #[test]
    fn variants_are_unwrapped() {
        // What busctl 262 printed for mpv on Omarchy 4.5, shortened.
        let reply: Value = serde_json::from_str(
            r#"{"PlaybackStatus":{"type":"s","data":"Playing"},"Metadata":{"type":"a{sv}","data":{"xesam:artist":{"type":"as","data":["An Artist"]},"mpris:length":{"type":"x","data":120000000},"xesam:title":{"type":"s","data":"T"}}},"Position":{"type":"x","data":1857555}}"#,
        )
        .unwrap();
        let plain = plain(reply);
        assert_eq!(plain["PlaybackStatus"], "Playing");
        assert_eq!(plain["Metadata"]["xesam:artist"][0], "An Artist");
        assert_eq!(plain["Metadata"]["mpris:length"], 120000000);
        assert_eq!(plain["Position"], 1857555);
        // A track that is itself named like a wrapper stays text.
        assert_eq!(super::plain(serde_json::json!({"type": "s", "data": {"type": "s", "data": "x"}})), "x");
    }
}
