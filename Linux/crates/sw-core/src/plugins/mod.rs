//! Data Source Plugin 1.0: declarative HTTPS mappings behind `$dataSource`.
//! Ported from `Windows/src/ScriptWidget.Core/Plugins`.
//!
//! A plugin is a `plugin.json` and an optional `README.md`. It is data, not
//! code: it cannot load anything native and cannot enlarge what a widget may
//! reach. Manifests, archives and responses are untrusted.

pub mod files;
pub mod manifest;
pub mod module;
pub mod requests;
pub mod store;
pub mod strict_json;

pub use manifest::{PluginError, PluginErrorKind, PluginManifest, PluginOperation, PluginParameter, PluginParameterLocation, PluginResponseType, PluginValidationIssue};
pub use module::DataSourceModule;
pub use requests::PreparedDataSourceRequest;
pub use store::{InstalledPlugin, PluginStore};
