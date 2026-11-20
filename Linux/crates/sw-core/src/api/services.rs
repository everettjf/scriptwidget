//! `$services`: `status("github")` and `profile("github")`, the fixed
//! authenticated read of the user's own GitHub profile. The rules are the
//! ones of `Android/core/.../system/ServicesModule.kt`: a fine-grained
//! personal access token the user pastes, no OAuth.
//!
//! Where the pieces live on Linux:
//! - The token is in the Secret Service (the system keyring), through
//!   `secret-tool` like the AI key but under its own kind. It is never
//!   written to a file of this program, a package, a log or a report, and no
//!   function here returns it to a caller outside this module.
//! - What is not secret (the account's name and number, when it was
//!   connected, which widgets may read the profile) is in a private file of
//!   the data folder.
//!
//! A script cannot choose an account, an address, a header or a token.

use std::collections::BTreeSet;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::ai::credentials::{ApiKey, CredentialError, CredentialStore};
use crate::api::fetch::{FetchModule, Url};
use crate::api::support::{CallContext, PrivateFile, SystemReject, is_owner, run_system, system_log, system_options};
use crate::api::weather::Clock;
use crate::executor::{Completion, ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, parse_object, quote, stringify};
use crate::plugins::strict_json;

/// Script-visible connected-service errors, with the Apple runtime's codes and wording.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceError {
    Expired,
    Credential,
    Locked,
    Storage,
    Conflict,
    NotConnected,
    Permission,
    Operation,
    NetworkLimit,
    RateLimit,
    Unavailable,
}

impl ServiceError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Expired => "[service_expired] Start a new service authorization.",
            Self::Credential => "[service_credential] The service credential is invalid. Reconnect in the app.",
            Self::Locked => "[service_locked] Unlock this device to use the connected service.",
            Self::Storage => "[service_storage] Secure credential storage is unavailable.",
            Self::Conflict => "[service_conflict] Service settings changed. Reload before saving.",
            Self::NotConnected => "[service_not_connected] Connect a service in the app.",
            Self::Permission => "[service_permission] Allow this service operation in the app.",
            Self::Operation => "[service_operation] This service operation is unsupported.",
            Self::NetworkLimit => "[network_limit] Too many concurrent or total network requests.",
            Self::RateLimit => "[service_rate_limit] The service is rate limited. Try again later.",
            Self::Unavailable => "[service_unavailable] The service is currently unavailable.",
        }
    }

    pub fn reject(self) -> SystemReject {
        SystemReject(self.message().to_owned())
    }
}

/// The account under which tokens are kept in the keyring.
pub const KEYRING_ACCOUNT: &str = "github";
/// The kind and label of the keyring item (see [`crate::ai::credentials::SecretToolStore::for_kind`]).
pub const KEYRING_KIND: &str = "service-token";
pub const KEYRING_LABEL: &str = "ScriptWidget service token";

/// A fine-grained personal access token: `github_pat_` followed by 20 to 244 letters, digits and underscores.
pub fn valid_token(token: &str) -> bool {
    token.strip_prefix("github_pat_").is_some_and(|rest| (20..=244).contains(&rest.len()) && rest.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'))
}

/// What is known about the connected account, without its token.
#[derive(Clone, PartialEq, Eq)]
pub struct ServiceConnection {
    pub connection_id: String,
    pub subject: String,
    pub username: String,
    /// The installations that may read the profile.
    pub grants: BTreeSet<String>,
    pub connected_at: i64,
}

impl fmt::Debug for ServiceConnection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<private service connection>")
    }
}

impl ServiceConnection {
    pub const MAXIMUM_GRANTS: usize = 256;

    fn encode(&self) -> String {
        stringify(&json!({ "formatVersion": 1, "connectionID": self.connection_id, "subject": self.subject, "username": self.username, "grants": self.grants, "connectedAt": self.connected_at }))
    }

    /// `service_storage` when the stored record is not exactly the expected shape.
    fn decode(text: &str) -> Result<Self, SystemReject> {
        let storage = || ServiceError::Storage.reject();
        let root = parse_object(text).map_err(|_| storage())?;
        let string = |name: &str| root.get(name).and_then(Value::as_str).map(str::to_owned).ok_or_else(storage);
        let listed: Vec<String> = root.opt_array("grants").ok_or_else(storage)?.iter().map(|item| item.as_str().map(str::to_owned).ok_or_else(storage)).collect::<Result<_, _>>()?;
        let grants: BTreeSet<String> = listed.iter().cloned().collect();
        let connection = Self { connection_id: string("connectionID")?, subject: string("subject")?, username: string("username")?, grants, connected_at: root.get("connectedAt").and_then(Value::as_i64).ok_or_else(storage)? };
        let subject_is_a_number = (1..=16).contains(&connection.subject.len()) && connection.subject.bytes().all(|byte| byte.is_ascii_digit()) && !connection.subject.starts_with('0');
        if root.get("formatVersion").and_then(Value::as_i64) != Some(1)
            || root.len() != 6
            || !is_owner(&connection.connection_id)
            || !subject_is_a_number
            || !github_profile::valid_username(&connection.username)
            || listed.len() > Self::MAXIMUM_GRANTS
            || connection.grants.len() != listed.len()
            || !listed.iter().all(|grant| is_owner(grant))
        {
            return Err(storage());
        }
        Ok(connection)
    }
}

/// A response to the fixed profile request. Printing it never reveals its body.
#[derive(Clone, PartialEq, Eq)]
pub struct ServiceHttpResponse {
    pub status: u16,
    pub content_type: Option<String>,
    pub rate_limited: bool,
    pub body: Vec<u8>,
}

impl fmt::Debug for ServiceHttpResponse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<private native service response>")
    }
}

/// Sends the fixed authenticated GET. Any failure is treated as `service_unavailable`.
pub trait ServiceTransport: Send + Sync {
    #[allow(clippy::result_unit_err)]
    fn get(&self, url: &str, headers: &[(String, String)]) -> Result<ServiceHttpResponse, ()>;
}

/// The fixed GitHub profile request and the small typed projection of its response.
pub mod github_profile {
    use super::*;

    pub const HOST: &str = "api.github.com";
    pub const URL: &str = "https://api.github.com/user";
    pub const MAXIMUM_RESPONSE_BYTES: usize = 128 * 1024;
    const MAXIMUM_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;

    /// A GitHub login: a letter or digit, then up to 38 letters, digits, `_` or `-`.
    pub fn valid_username(value: &str) -> bool {
        let bytes = value.as_bytes();
        (1..=39).contains(&bytes.len()) && bytes[0].is_ascii_alphanumeric() && bytes.iter().all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'-')
    }

    /// The only headers ever sent. Scripts cannot add, remove or read them.
    pub fn headers(token: &str) -> Vec<(String, String)> {
        [("Authorization", format!("Bearer {token}")), ("User-Agent", "ScriptWidget".to_owned()), ("Accept", "application/vnd.github+json".to_owned()), ("X-GitHub-Api-Version", "2026-03-10".to_owned())]
            .into_iter()
            .map(|(name, value)| (name.to_owned(), value))
            .collect()
    }

    /// HTTP status rules: 401 is `service_expired`; 429, or 403 with a
    /// rate-limit signal, is `service_rate_limit`; other 403 is
    /// `service_permission`; anything but 200 with `application/json` and at
    /// most 128 KiB is `service_unavailable`.
    pub fn validate_http(response: &ServiceHttpResponse) -> Result<(), SystemReject> {
        let error = if response.body.len() > MAXIMUM_RESPONSE_BYTES {
            ServiceError::Unavailable
        } else if response.status == 401 {
            ServiceError::Expired
        } else if response.status == 429 || (response.status == 403 && response.rate_limited) {
            ServiceError::RateLimit
        } else if response.status == 403 {
            ServiceError::Permission
        } else if response.status != 200 || response.content_type.as_deref().map(|kind| kind.split(';').next().unwrap_or("").trim().to_ascii_lowercase()).as_deref() != Some("application/json") {
            ServiceError::Unavailable
        } else {
            return Ok(());
        };
        Err(error.reject())
    }

    /// Maps the provider response to exactly `service, subject, username,
    /// displayName, publicRepositories, privateRepositories, followers,
    /// following`. Missing optional values are null, never zero. Email,
    /// location and every other provider field are dropped. A text field
    /// that contains the token rejects the whole response.
    pub fn decode(response: &ServiceHttpResponse, token: &str) -> Result<Object, SystemReject> {
        validate_http(response)?;
        let unavailable = || ServiceError::Unavailable.reject();
        let text = std::str::from_utf8(&response.body).map_err(|_| unavailable())?;
        let Ok(Value::Object(root)) = strict_json::parse(text, true) else { return Err(unavailable()) };
        let integer = |key: &str, required: bool| -> Result<Option<u64>, SystemReject> {
            if root.is_null(key) {
                return if required { Err(unavailable()) } else { Ok(None) };
            }
            match system_options::json_number(root.get(key)) {
                Some(value) if value.is_finite() && (0.0..=MAXIMUM_SAFE_INTEGER).contains(&value) && value.fract() == 0.0 => Ok(Some(value as u64)),
                _ => Err(unavailable()),
            }
        };
        let string = |key: &str, required: bool, maximum: usize| -> Result<Option<String>, SystemReject> {
            if root.is_null(key) {
                return if required { Err(unavailable()) } else { Ok(None) };
            }
            match root.get(key) {
                Some(Value::String(value)) if value.len() <= maximum && !system_options::has_control_characters(value) && (token.is_empty() || !value.contains(token)) && !(required && value.is_empty()) => Ok(Some(value.clone())),
                _ => Err(unavailable()),
            }
        };
        let id = integer("id", true)?.filter(|id| *id > 0).ok_or_else(unavailable)?;
        let login = string("login", true, 39)?.filter(|login| valid_username(login)).ok_or_else(unavailable)?;
        let profile = json!({
            "service": "github",
            "subject": id.to_string(),
            "username": login,
            "displayName": string("name", false, 256)?,
            "publicRepositories": integer("public_repos", true)?,
            "privateRepositories": integer("total_private_repos", false)?,
            "followers": integer("followers", false)?,
            "following": integer("following", false)?,
        });
        match profile {
            Value::Object(profile) => Ok(profile),
            _ => Err(unavailable()),
        }
    }
}

/// The profile request through [`FetchModule::perform`]: public addresses only, every redirect refused.
pub struct FetchServiceTransport {
    fetch: Arc<FetchModule>,
}

impl FetchServiceTransport {
    /// Shorter than Android's five seconds: the keyring is asked first, inside the same five-second run.
    pub const TIMEOUT_MILLISECONDS: u64 = 3_500;

    pub fn new(fetch: Arc<FetchModule>) -> Self {
        Self { fetch }
    }
}

impl ServiceTransport for FetchServiceTransport {
    fn get(&self, url: &str, headers: &[(String, String)]) -> Result<ServiceHttpResponse, ()> {
        let url = Url::parse(url).map_err(|_| ())?;
        let response = self.fetch.perform("GET", &url, headers, None, Self::TIMEOUT_MILLISECONDS, &|_| false, None).map_err(|_| ())?;
        if response.body.len() > github_profile::MAXIMUM_RESPONSE_BYTES {
            return Err(());
        }
        let rate_limited = response.headers.get("x-ratelimit-remaining").is_some_and(|left| left == "0") || response.headers.contains_key("retry-after");
        Ok(ServiceHttpResponse { status: response.status, content_type: response.headers.get("content-type").cloned(), rate_limited, body: response.body })
    }
}

/// What the application may show about the account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceSummary {
    pub username: String,
    pub grants: BTreeSet<String>,
    pub connected_at: i64,
}

/// Account connection and per-widget grants, used by the settings, the
/// command line and [`ServicesModule`]. The token is verified against GitHub
/// before it is stored and is never returned by any method here.
pub struct ServiceConnections {
    record: PrivateFile,
    tokens: Arc<dyn CredentialStore>,
    transport: Arc<dyn ServiceTransport>,
    clock: Clock,
}

impl ServiceConnections {
    pub fn new(record: impl Into<PathBuf>, tokens: Arc<dyn CredentialStore>, transport: Arc<dyn ServiceTransport>) -> Self {
        Self::with_clock(record, tokens, transport, Arc::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)))
    }

    pub fn with_clock(record: impl Into<PathBuf>, tokens: Arc<dyn CredentialStore>, transport: Arc<dyn ServiceTransport>, clock: Clock) -> Self {
        Self { record: PrivateFile::new(record, 64 * 1024), tokens, transport, clock }
    }

    fn locked<T>(&self, work: impl FnOnce() -> T) -> T {
        let lock = self.record.lock();
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        work()
    }

    fn load(&self) -> Result<Option<ServiceConnection>, SystemReject> {
        match self.record.read() {
            Ok(Some(text)) => ServiceConnection::decode(&text).map(Some),
            Ok(None) => Ok(None),
            Err(_) => Err(ServiceError::Storage.reject()),
        }
    }

    /// The connected account, or `None`. `service_storage` when the record cannot be read.
    pub fn connection(&self) -> Result<Option<ServiceConnection>, SystemReject> {
        self.locked(|| self.load())
    }

    /// Account name and grants for the settings, or `None` when not connected.
    pub fn summary(&self) -> Result<Option<ServiceSummary>, SystemReject> {
        Ok(self.connection()?.map(|connection| ServiceSummary { username: connection.username, grants: connection.grants, connected_at: connection.connected_at }))
    }

    /// Verifies `token` with the fixed profile request, keeps it in the
    /// keyring and records a new connection. A new connection has a new
    /// identity and no widget grants: reconnecting never inherits access.
    /// Returns the GitHub login, or a rejection with a `service_*` code.
    pub fn connect(&self, token: &str) -> Result<String, SystemReject> {
        let trimmed = token.trim();
        if !valid_token(trimmed) {
            return Err(ServiceError::Credential.reject());
        }
        let profile = self.fetch(trimmed)?;
        let key = ApiKey::new(trimmed).map_err(|_| ServiceError::Credential.reject())?;
        let connection = ServiceConnection {
            connection_id: crate::packages::manifests::fresh_id().trim_start_matches("local.").to_owned(),
            subject: profile.opt_string("subject"),
            username: profile.opt_string("username"),
            grants: BTreeSet::new(),
            connected_at: (self.clock)(),
        };
        self.locked(|| {
            self.tokens.save(KEYRING_ACCOUNT, &key).map_err(|_| ServiceError::Storage.reject())?;
            if !self.record.write(&connection.encode()) {
                // No token stays in the keyring without the record that says whose it is.
                let _ = self.tokens.remove(KEYRING_ACCOUNT);
                return Err(ServiceError::Storage.reject());
            }
            Ok(())
        })?;
        system_log::call("services.connect", "ok");
        Ok(connection.username)
    }

    /// Removes the token and every grant. `service_storage` when the keyring refused, in which case the record stays too.
    pub fn disconnect(&self) -> Result<(), SystemReject> {
        self.locked(|| {
            match self.tokens.remove(KEYRING_ACCOUNT) {
                Ok(_) => {}
                Err(_) => return Err(ServiceError::Storage.reject()),
            }
            self.record.delete();
            Ok(())
        })?;
        system_log::call("services.disconnect", "ok");
        Ok(())
    }

    /// Grants or revokes the profile read for one installed widget. False when not connected or the owner is not an installation.
    pub fn set_grant(&self, installation: &str, granted: bool) -> bool {
        self.locked(|| {
            let Ok(Some(mut connection)) = self.load() else { return false };
            if !is_owner(installation) {
                return false;
            }
            if granted {
                connection.grants.insert(installation.to_owned());
            } else {
                connection.grants.remove(installation);
            }
            connection.grants.len() <= ServiceConnection::MAXIMUM_GRANTS && self.record.write(&connection.encode())
        })
    }

    /// The token, for the request only. `service_credential` when the keyring holds none or something else.
    fn token(&self) -> Result<ApiKey, SystemReject> {
        match self.tokens.load(KEYRING_ACCOUNT) {
            Ok(Some(key)) if valid_token(key.expose()) => Ok(key),
            Ok(_) | Err(CredentialError::Invalid(_)) | Err(CredentialError::Missing(_)) => Err(ServiceError::Credential.reject()),
            Err(CredentialError::Unavailable(_)) => Err(ServiceError::Storage.reject()),
        }
    }

    fn fetch(&self, token: &str) -> Result<Object, SystemReject> {
        let response = self.transport.get(github_profile::URL, &github_profile::headers(token)).map_err(|()| ServiceError::Unavailable.reject())?;
        github_profile::decode(&response, token)
    }
}

/// `$services`: `status("github")` and `profile("github")`. No method returns credentials.
#[derive(Clone)]
pub struct ServicesModule {
    connections: Arc<ServiceConnections>,
}

impl ServicesModule {
    pub const PERMISSION: &'static str = "services";

    pub fn new(connections: Arc<ServiceConnections>) -> Self {
        Self { connections }
    }

    pub fn connections(&self) -> &Arc<ServiceConnections> {
        &self.connections
    }

    fn permitted(context: &CallContext) -> bool {
        context.is_installed() && context.declares(Self::PERMISSION)
    }

    /// Checks shared by both methods, in the Apple runtime's order: installed
    /// owner with the `services` permission (`service_permission`), a
    /// supported provider (`service_operation`), no future entry or Live
    /// Activity (`timeline_read_only`), the query budget (`query_limit`).
    fn admit(&self, context: &CallContext, service: &str) -> Result<Option<ServiceConnection>, SystemReject> {
        if !Self::permitted(context) {
            return Err(ServiceError::Permission.reject());
        }
        if service != "github" {
            return Err(ServiceError::Operation.reject());
        }
        if context.is_timeline_projection || context.is_live_activity {
            return Err(SystemReject("[timeline_read_only] Read services in the current entry, then reuse a display snapshot".into()));
        }
        if !context.consume_data_query() {
            return Err(SystemReject("[query_limit] Too many system data queries".into()));
        }
        self.connections.connection()
    }

    /// Authority is checked again before delivery: a disconnect, reconnect or grant change invalidates a pending result.
    fn confirm(&self, context: &CallContext, connection: Option<&ServiceConnection>, needs_grant: bool) -> Result<(), SystemReject> {
        if !Self::permitted(context) {
            return Err(ServiceError::Permission.reject());
        }
        let current = self.connections.connection()?;
        if current.as_ref().map(|current| &current.connection_id) != connection.map(|connection| &connection.connection_id) {
            return Err(ServiceError::Conflict.reject());
        }
        if needs_grant && !current.is_some_and(|current| current.grants.contains(&context.installation)) {
            return Err(ServiceError::Permission.reject());
        }
        Ok(())
    }

    /// `notConnected`, `notGranted` or `connected`. Makes no network request and does not ask the keyring.
    pub fn status(&self, context: &CallContext, service: &str) -> Result<&'static str, SystemReject> {
        let connection = self.admit(context, service)?;
        let status = match &connection {
            None => "notConnected",
            Some(connection) if connection.grants.contains(&context.installation) => "connected",
            Some(_) => "notGranted",
        };
        self.confirm(context, connection.as_ref(), false)?;
        Ok(status)
    }

    /// The fixed authenticated profile read. Beyond [`Self::status`]: a
    /// connection (`service_not_connected`), this installation's grant and
    /// `network` with `api.github.com` declared (`service_permission`), the
    /// network budget (`network_limit`), and a response for the connected
    /// user (`service_credential`).
    pub fn profile(&self, context: &CallContext, service: &str) -> Result<Object, SystemReject> {
        let connection = self.admit(context, service)?.ok_or_else(|| ServiceError::NotConnected.reject())?;
        if !connection.grants.contains(&context.installation) || !context.allows_host(github_profile::HOST) {
            return Err(ServiceError::Permission.reject());
        }
        if !context.consume_network_request() {
            return Err(ServiceError::NetworkLimit.reject());
        }
        let result = self.connections.token().and_then(|token| self.connections.fetch(token.expose()));
        self.confirm(context, Some(&connection), true)?;
        let profile = result?;
        if profile.opt_string("subject") != connection.subject {
            return Err(ServiceError::Credential.reject());
        }
        Ok(profile)
    }
}

impl NativeModule for ServicesModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("services.")
    }

    fn apis(&self) -> &[&'static str] {
        &["$services"]
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>, done: Completion) {
        let context = CallContext::from_request(request);
        let service = payload.and_then(|payload| payload.get("service")).and_then(Value::as_str).unwrap_or("").to_owned();
        let module = self.clone();
        match operation {
            "services.status" => run_system(operation, done, move || module.status(&context, &service).map(quote)),
            "services.profile" => run_system(operation, done, move || module.profile(&context, &service).map(|profile| crate::json::stringify_object(&profile))),
            _ => done.complete(false, Some(quote(&format!("Unsupported operation {operation}")))),
        }
    }
}
