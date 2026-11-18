//! The ScriptWidget background service for Linux (plan, sections 4.4 and
//! 4.8; the protocol is written down in `docs/linux/protocol.md`).
//!
//! The service opens no window. It runs each placed widget's script on a
//! schedule, draws it to PNG files under `$XDG_RUNTIME_DIR/scriptwidget/frames/`,
//! and tells every connected display which widget has a new picture, where
//! it goes, how large it is and which areas can be tapped. A display sends
//! back numbers: which region was tapped, where a widget was dragged to.
//!
//! It is a library so that the tests can run a whole service inside the test
//! process, and so that there is one installed program: `scriptwidget host
//! run` in `sw-cli` is the service, and the same crate gives the command line
//! its client side.

pub mod client;
pub mod clock;
pub mod frames;
pub mod launcher;
pub mod paths;
pub mod placements;
pub mod protocol;
pub mod schedule;
pub mod server;
pub mod service;
pub mod session;
pub mod surfaces;
pub mod worker;

pub use clock::{Clock, ManualClock, SystemClock};
pub use launcher::{Launcher, SystemLauncher};
pub use paths::RuntimePaths;
pub use protocol::{Refusal, Request, Switch};
pub use service::{Controller, Service, ServiceOptions, StartError};
pub use session::SessionEvent;

/// One line for the journal. Never a credential, a response body or the content of a user's file:
/// identifiers, error kinds and paths of the service's own files only.
pub fn log(message: &str) {
    eprintln!("scriptwidget-host: {message}");
}
