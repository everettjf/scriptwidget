//! What the host tells scripts about the machine (`$system`).
//!
//! Only the platform name is filled in so far; the kernel answers the other
//! `$system` and `$device` members with its defaults until the Linux
//! equivalents of `Windows/src/ScriptWidget.Core/Api/DeviceInfo.cs` exist.

use serde_json::Value;

use crate::json::Object;

/// `$system.platform()` on this host.
pub const PLATFORM: &str = "linux";

/// The `system` member of an execution request.
pub fn system_info() -> Object {
    let mut system = Object::new();
    system.insert("platform".into(), Value::String(PLATFORM.into()));
    system
}
