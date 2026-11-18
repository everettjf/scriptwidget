//! Native APIs behind the script globals, and the policy they share.
//!
//! Globals that no module here implements (`$calendar`, `$health`, `$music`
//! and the like) are answered by the shared kernel: `isAvailable()` returns
//! false and calls reject with `[unsupported_platform]`. A module names the
//! globals it does implement in [`crate::NativeModule::apis`].

pub mod fetch;
pub mod http;
pub mod policy;
pub mod storage;
pub mod support;
pub mod system;
pub mod weather;
pub mod workers;

pub use fetch::FetchModule;
pub use storage::StorageModule;
pub use weather::WeatherModule;
