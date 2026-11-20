//! Where the API key of the AI provider lives. Android keeps it in the
//! Keystore-backed store of the app; Linux keeps it in the Secret Service
//! (the system keyring: GNOME Keyring, KeePassXC, KWallet), as
//! `docs/linux/plan.md` requires. It is never written to a configuration
//! file, a package, a prompt or a conversation.
//!
//! The keyring is reached through `secret-tool`, the command of libsecret,
//! and not through a D-Bus library: the Secret Service protocol needs a D-Bus
//! client and its own session encryption, which would be the largest
//! dependency of this crate, for three operations. The secret travels to
//! `secret-tool` on its standard input and back on its standard output: never
//! in an argument (other users can read those in `/proc`) and never in the
//! environment of a child.
//!
//! When `secret-tool` or a keyring is missing, nothing is stored anywhere
//! else: the operation fails with a sentence that says so. For one run a key
//! may be given in the `SCRIPTWIDGET_AI_KEY` environment variable instead; it
//! is used for that run and never saved.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fmt;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Mutex;

use super::client::require_key;
use super::profile::AiProviderKind;

/// The environment variable that carries a key for one run.
pub const ENVIRONMENT_KEY: &str = "SCRIPTWIDGET_AI_KEY";

/// An API key. Its `Debug` text is a placeholder, and it has no `Display`:
/// the only way to the text is [`ApiKey::expose`], at the place that sends it.
#[derive(Clone, PartialEq, Eq)]
pub struct ApiKey(String);

impl ApiKey {
    /// The key without surrounding whitespace, or why it can not be one:
    /// empty, too long, or with characters that could start a header line.
    pub fn new(text: &str) -> Result<Self, CredentialError> {
        match require_key(text) {
            Ok(key) => Ok(Self(key.to_owned())),
            Err(error) => Err(CredentialError::Invalid(if super::is_blank(text) { "The API key is empty.".into() } else { error.message })),
        }
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ApiKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ApiKey(<hidden>)")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialError {
    /// The keyring, or the program that reaches it, can not be used. Nothing was stored elsewhere.
    Unavailable(String),
    /// What was given is not a key.
    Invalid(String),
    /// No key is stored for the provider and none was given for this run.
    Missing(String),
}

impl CredentialError {
    pub fn message(&self) -> &str {
        match self {
            Self::Unavailable(message) | Self::Invalid(message) | Self::Missing(message) => message,
        }
    }
}

impl fmt::Display for CredentialError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message())
    }
}

impl std::error::Error for CredentialError {}

/// Keeps one key per provider. `account` is the provider's identifier ([`AiProviderKind::id`]).
pub trait CredentialStore: Send + Sync {
    fn load(&self, account: &str) -> Result<Option<ApiKey>, CredentialError>;
    fn save(&self, account: &str, key: &ApiKey) -> Result<(), CredentialError>;
    /// Returns whether there was a key to remove.
    fn remove(&self, account: &str) -> Result<bool, CredentialError>;
}

/// The key a run uses: the one given for this run, else the stored one.
pub fn key_for(store: &dyn CredentialStore, one_run: Option<&ApiKey>, kind: AiProviderKind) -> Result<ApiKey, CredentialError> {
    if let Some(key) = one_run {
        return Ok(key.clone());
    }
    store.load(kind.id())?.ok_or_else(|| CredentialError::Missing(format!("No API key is stored for {}. Store one with: scriptwidget ai key set", kind.display_name())))
}

/// The key the environment gives for this run: the value of [`ENVIRONMENT_KEY`]
/// as the caller read it. Unset or empty is no key.
pub fn key_from_environment(value: Option<OsString>) -> Result<Option<ApiKey>, CredentialError> {
    let Some(value) = value.filter(|value| !value.is_empty()) else { return Ok(None) };
    let text = value.into_string().map_err(|_| CredentialError::Invalid(format!("{ENVIRONMENT_KEY} contains characters that are not allowed.")))?;
    if super::is_blank(&text) {
        return Ok(None);
    }
    ApiKey::new(&text).map(Some).map_err(|_| CredentialError::Invalid(format!("{ENVIRONMENT_KEY} contains characters that are not allowed.")))
}

fn valid_account(account: &str) -> Result<(), CredentialError> {
    if (1..=32).contains(&account.len()) && account.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-') { Ok(()) } else { Err(CredentialError::Invalid("That is not a provider.".into())) }
}

const NOT_INSTALLED: &str = "The secret-tool program (part of libsecret) was not found, so the key cannot be kept in the system keyring. Nothing was stored. \
Install libsecret, or give the key for one run in the SCRIPTWIDGET_AI_KEY environment variable.";
const KEYRING_FAILED: &str = "The system keyring (Secret Service) could not be used. Nothing was stored elsewhere. \
Check that a keyring such as GNOME Keyring or KeePassXC is running and unlocked, or give the key for one run in the SCRIPTWIDGET_AI_KEY environment variable.";
/// More than a key can be: what `secret-tool` printed is then not one.
const MAXIMUM_OUTPUT_BYTES: usize = 16 * 1024;

/// The Secret Service through `secret-tool`. An item is found by its
/// attributes: `application scriptwidget`, `kind ai-api-key` and
/// `account <provider>`.
pub struct SecretToolStore {
    program: PathBuf,
}

impl Default for SecretToolStore {
    fn default() -> Self {
        Self::new()
    }
}

impl SecretToolStore {
    /// `secret-tool` as the `PATH` finds it.
    pub fn new() -> Self {
        Self { program: PathBuf::from("secret-tool") }
    }

    /// Another program that takes the same arguments; for tests.
    pub fn with_program(program: impl Into<PathBuf>) -> Self {
        Self { program: program.into() }
    }

    fn attributes(account: &str) -> [&str; 6] {
        ["application", "scriptwidget", "kind", "ai-api-key", "account", account]
    }

    /// Runs `secret-tool`; `secret` goes to its standard input. Returns whether it succeeded, what it printed, and whether it complained.
    fn run(&self, arguments: &[&str], secret: Option<&str>) -> Result<(bool, Vec<u8>, bool), CredentialError> {
        let mut command = Command::new(&self.program);
        // The child gets no key through its environment, whatever this process was started with.
        command.args(arguments).env_remove(ENVIRONMENT_KEY).stdin(if secret.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn().map_err(|error| CredentialError::Unavailable(if error.kind() == std::io::ErrorKind::NotFound { NOT_INSTALLED } else { KEYRING_FAILED }.into()))?;
        if let (Some(secret), Some(mut input)) = (secret, child.stdin.take()) {
            // secret-tool reads to the end of its input and takes all of it as the secret: no line break is added.
            // A program that ended without reading is reported by its exit status below.
            let _ = input.write_all(secret.as_bytes());
        }
        let output = child.wait_with_output().map_err(|_| CredentialError::Unavailable(KEYRING_FAILED.into()))?;
        // What the program wrote to standard error is not forwarded and not logged.
        Ok((output.status.success(), output.stdout, !output.stderr.iter().all(u8::is_ascii_whitespace)))
    }
}

impl CredentialStore for SecretToolStore {
    fn load(&self, account: &str) -> Result<Option<ApiKey>, CredentialError> {
        valid_account(account)?;
        let mut arguments = vec!["lookup"];
        arguments.extend(Self::attributes(account));
        let (succeeded, output, complained) = self.run(&arguments, None)?;
        if !succeeded {
            // Without an item secret-tool ends with a failure and says nothing; with no keyring it says why.
            return if complained { Err(CredentialError::Unavailable(KEYRING_FAILED.into())) } else { Ok(None) };
        }
        if output.is_empty() {
            return Ok(None);
        }
        let text = std::str::from_utf8(&output).ok().filter(|_| output.len() <= MAXIMUM_OUTPUT_BYTES).ok_or_else(|| CredentialError::Invalid("What the keyring holds for this provider is not an API key. Store the key again.".into()))?;
        ApiKey::new(text.strip_suffix('\n').unwrap_or(text)).map(Some).map_err(|_| CredentialError::Invalid("What the keyring holds for this provider is not an API key. Store the key again.".into()))
    }

    fn save(&self, account: &str, key: &ApiKey) -> Result<(), CredentialError> {
        valid_account(account)?;
        let label = format!("--label=ScriptWidget AI key ({account})");
        let mut arguments = vec!["store", label.as_str()];
        arguments.extend(Self::attributes(account));
        let (succeeded, _, _) = self.run(&arguments, Some(key.expose()))?;
        if succeeded { Ok(()) } else { Err(CredentialError::Unavailable(KEYRING_FAILED.into())) }
    }

    fn remove(&self, account: &str) -> Result<bool, CredentialError> {
        let existed = self.load(account).map(|key| key.is_some()).or_else(|error| match error {
            // An item that is not a key is still an item to remove.
            CredentialError::Invalid(_) => Ok(true),
            other => Err(other),
        })?;
        if !existed {
            // `secret-tool clear` ends with a failure and says nothing when there is no item
            // (seen with libsecret on Omarchy 4.5), which must not read as a missing keyring.
            return Ok(false);
        }
        let mut arguments = vec!["clear"];
        arguments.extend(Self::attributes(account));
        let (succeeded, _, _) = self.run(&arguments, None)?;
        if succeeded { Ok(existed) } else { Err(CredentialError::Unavailable(KEYRING_FAILED.into())) }
    }
}

/// Keys in memory, for tests and for nothing else: they are gone with the process.
#[derive(Default)]
pub struct MemoryCredentialStore {
    keys: Mutex<HashMap<String, ApiKey>>,
    /// When set, every operation fails as a missing keyring does.
    unavailable: bool,
}

impl MemoryCredentialStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// A store that behaves like a system without a keyring.
    pub fn unavailable() -> Self {
        Self { keys: Mutex::default(), unavailable: true }
    }

    fn check(&self, account: &str) -> Result<(), CredentialError> {
        valid_account(account)?;
        if self.unavailable { Err(CredentialError::Unavailable(KEYRING_FAILED.into())) } else { Ok(()) }
    }
}

impl CredentialStore for MemoryCredentialStore {
    fn load(&self, account: &str) -> Result<Option<ApiKey>, CredentialError> {
        self.check(account)?;
        Ok(self.keys.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(account).cloned())
    }

    fn save(&self, account: &str, key: &ApiKey) -> Result<(), CredentialError> {
        self.check(account)?;
        self.keys.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(account.to_owned(), key.clone());
        Ok(())
    }

    fn remove(&self, account: &str) -> Result<bool, CredentialError> {
        self.check(account)?;
        Ok(self.keys.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(account).is_some())
    }
}
