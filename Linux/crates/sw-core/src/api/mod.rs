//! Native APIs behind the script globals, and the policy they share.
//!
//! Globals that no module here implements (`$calendar`, `$health`,
//! `$location` and the like) are answered by the shared kernel:
//! `isAvailable()` returns false and calls reject with
//! `[unsupported_platform]`. A module names the globals it does implement in
//! [`crate::NativeModule::apis`].
//!
//! `$location` stays unimplemented: Omarchy 4.5 ships no GeoClue (neither the
//! service nor its D-Bus activation file), and the desktop portal's Location
//! interface is only a front for it, so there is nothing to ask.

pub mod bus;
pub mod documents;
pub mod fetch;
pub mod http;
pub mod music;
pub mod notifications;
pub mod photos;
pub mod policy;
pub mod services;
pub mod storage;
pub mod stores;
pub mod support;
pub mod system;
pub mod weather;
pub mod workers;

pub use fetch::FetchModule;
pub use storage::StorageModule;
pub use stores::SystemStores;
pub use weather::WeatherModule;
