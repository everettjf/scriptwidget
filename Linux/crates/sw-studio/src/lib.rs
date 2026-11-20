//! The ScriptWidget management window for Linux (`scriptwidget-studio`):
//! your widgets, the bundled templates, the code editor with a live preview,
//! and the settings. The Linux counterpart of `Windows/src/ScriptWidget.Studio`.
//!
//! The modules here are the window's logic and need no window; the window
//! itself ([`ui`], on GPUI and gpui-kit) is behind the `ui` feature.
//!
//! Package content is untrusted. The window shows it as text and as the
//! picture `sw-render` draws; it compiles and runs it only inside the engine
//! of `sw-core`, with the limits every run has.

pub mod access;
pub mod ai;
pub mod completion;
pub mod debounce;
pub mod gallery;
pub mod instance;
pub mod launch;
pub mod model;
pub mod service;
pub mod settings;
pub mod skills;
pub mod strings;

#[cfg(test)]
mod testing;

#[cfg(feature = "ui")]
pub mod ui;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
