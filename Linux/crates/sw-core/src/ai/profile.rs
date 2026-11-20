//! Provider profiles. Port of `AiProfile.kt`.

use std::net::Ipv6Addr;

use super::{is_whitespace, length, trim};

/// Wire protocol and preset of an AI provider. Linux supports API-key providers only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AiProviderKind {
    /// Anthropic Messages API (`/v1/messages`, `x-api-key`).
    Anthropic,
    /// OpenAI chat completions; defaults mirror `AIProfile.defaultBaseURL` / `defaultModel` in Swift.
    OpenAi,
    /// A user-defined endpoint that speaks OpenAI chat completions.
    OpenAiCompatible,
}

impl AiProviderKind {
    pub const ALL: [Self; 3] = [Self::Anthropic, Self::OpenAi, Self::OpenAiCompatible];

    /// The stored identifier.
    pub fn id(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
            Self::OpenAiCompatible => "custom",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Anthropic => "Anthropic",
            Self::OpenAi => "OpenAI",
            Self::OpenAiCompatible => "OpenAI-compatible",
        }
    }

    pub fn default_base_url(self) -> &'static str {
        match self {
            Self::Anthropic => "https://api.anthropic.com",
            Self::OpenAi => "https://api.openai.com",
            Self::OpenAiCompatible => "",
        }
    }

    pub fn default_model(self) -> &'static str {
        match self {
            Self::Anthropic => "claude-fable-5-2",
            Self::OpenAi => "gpt-4o-mini",
            Self::OpenAiCompatible => "",
        }
    }

    pub fn suggested_models(self) -> &'static [&'static str] {
        match self {
            Self::Anthropic => &["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
            Self::OpenAi => &["gpt-4o-mini"],
            Self::OpenAiCompatible => &[],
        }
    }

    /// True when requests use the Anthropic Messages API rather than chat completions.
    pub fn uses_anthropic_messages(self) -> bool {
        self == Self::Anthropic
    }

    /// The provider with this stored `id`, or `None`: an unknown value is never guessed.
    pub fn from_id(id: Option<&str>) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| Some(kind.id()) == id)
    }
}

/// One provider/model entry. It deliberately has no API key field: the key
/// lives in the system keyring and is handed to [`super::AiClient`] per call,
/// so a profile can be persisted, logged or printed without leaking a secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiProfile {
    pub kind: AiProviderKind,
    pub base_url: String,
    pub model: String,
}

impl AiProfile {
    pub const MAXIMUM_MODEL_LENGTH: usize = 200;
    pub const MAXIMUM_BASE_URL_LENGTH: usize = 2048;

    pub fn new(kind: AiProviderKind, base_url: impl Into<String>, model: impl Into<String>) -> Self {
        Self { kind, base_url: base_url.into(), model: model.into() }
    }

    /// The default profile of `kind`.
    pub fn defaults(kind: AiProviderKind) -> Self {
        Self::new(kind, kind.default_base_url(), kind.default_model())
    }

    /// Base URL without trailing slashes or a trailing `/v1` (the client appends
    /// the versioned path itself). Blank input falls back to the provider default.
    /// Port of `AIProfile.normalizedBaseURL`.
    pub fn normalized_base_url(&self) -> String {
        let mut value = trim(&self.base_url);
        if value.is_empty() {
            return self.kind.default_base_url().to_owned();
        }
        value = value.trim_end_matches('/');
        value = value.strip_suffix("/v1").unwrap_or(value);
        value.trim_end_matches('/').to_owned()
    }

    /// Why this profile cannot be used, or `None` when it is valid.
    pub fn validation_error(&self) -> Option<String> {
        if let Some(error) = Self::base_url_error(&self.normalized_base_url()) {
            return Some(error);
        }
        let name = trim(&self.model);
        if name.is_empty() {
            return Some("Choose a model before generating a widget.".into());
        }
        if length(name) > Self::MAXIMUM_MODEL_LENGTH || name.chars().any(char::is_control) {
            return Some("The model name is invalid.".into());
        }
        None
    }

    /// True when the endpoint and model are usable; the API key is checked separately.
    pub fn is_configured(&self) -> bool {
        self.validation_error().is_none()
    }

    /// Validates an already normalized base URL. Port of `AIProfile.endpointURL`,
    /// and like Android (unlike the Apple apps) it requires HTTPS, for every
    /// host: the request carries the API key.
    ///
    /// Kotlin leaves the reading to `java.net.URI`. Here the text is read by
    /// hand with the same outcome for every case of the Android tests, and a
    /// URL the `url` crate then reads differently is refused.
    pub fn base_url_error(normalized: &str) -> Option<String> {
        let invalid = || Some("The API base URL is invalid.".to_owned());
        let needs_https = || Some("The API base URL must start with https://.".to_owned());
        let needs_host = || Some("The API base URL needs a host name.".to_owned());
        if normalized.is_empty() {
            return Some("Enter the API base URL.".into());
        }
        if length(normalized) > Self::MAXIMUM_BASE_URL_LENGTH || normalized.chars().any(|character| is_whitespace(character) || character.is_control() || character == '\\') {
            return invalid();
        }
        let is_scheme = |text: &str| text.starts_with(|first: char| first.is_ascii_alphabetic()) && text.chars().all(|character| character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.'));
        let Some((scheme, rest)) = normalized.split_once(':').filter(|(scheme, _)| is_scheme(scheme)) else { return needs_https() };
        if !scheme.eq_ignore_ascii_case("https") {
            return needs_https();
        }
        let Some(rest) = rest.strip_prefix("//") else { return needs_host() };
        let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let (authority, path) = rest.split_at(end);
        if authority.is_empty() {
            return if path.is_empty() { invalid() } else { needs_host() };
        }
        if authority.contains('@') {
            return Some("The API base URL must not contain credentials.".into());
        }
        if path.contains(['?', '#']) {
            return Some("The API base URL must not contain a query or fragment.".into());
        }
        let (host, port) = match authority.strip_prefix('[') {
            Some(bracketed) => {
                let Some((address, after)) = bracketed.split_once(']') else { return invalid() };
                if address.parse::<Ipv6Addr>().is_err() {
                    return invalid();
                }
                match after.strip_prefix(':') {
                    Some(port) => (address, port),
                    None if after.is_empty() => (address, ""),
                    None => return invalid(),
                }
            }
            None => {
                let (host, port) = authority.rsplit_once(':').unwrap_or((authority, ""));
                if host.is_empty() || !host.chars().all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '.')) {
                    return needs_host();
                }
                (host, port)
            }
        };
        if host.is_empty() {
            return needs_host();
        }
        if !port.is_empty() && !(port.len() <= 5 && port.bytes().all(|byte| byte.is_ascii_digit()) && port.parse::<u32>().is_ok_and(|port| (1..=65535).contains(&port))) {
            return invalid();
        }
        if !path.chars().all(|character| character.is_ascii_alphanumeric() || "-._~!$&'()*+,;=:@/%".contains(character)) {
            return invalid();
        }
        if path.ends_with("/chat/completions") || path.ends_with("/messages") {
            return Some("Enter the base URL only, without the endpoint path.".into());
        }
        if path.split('/').any(|segment| segment == "." || segment == "..") {
            return invalid();
        }
        // The transport reads the URL with the `url` crate: both readings must name the same host.
        let same_host = url::Url::parse(normalized).ok().is_some_and(|url| {
            url.scheme() == "https" && url.username().is_empty() && url.password().is_none() && url.host_str().is_some_and(|read| read.trim_matches(['[', ']']).eq_ignore_ascii_case(host) || host.parse::<Ipv6Addr>().is_ok())
        });
        if !same_host {
            return invalid();
        }
        None
    }
}

/// Snapshot consumed by [`super::AiClient`] and [`super::AgentLoop`]: the active profile plus the loop globals.
#[derive(Debug, Clone, PartialEq)]
pub struct AiSettings {
    pub profile: AiProfile,
    pub max_iterations: i32,
    pub temperature: f64,
}

impl AiSettings {
    /// `AISettings.defaultMaxIterations`.
    pub const DEFAULT_MAX_ITERATIONS: i32 = 20;
    /// Range of the Max Iterations control in docs/ai-generate.md.
    pub const MINIMUM_MAX_ITERATIONS: i32 = 5;
    pub const MAXIMUM_MAX_ITERATIONS: i32 = 100;
    /// `AISettings.defaultTemperature`.
    pub const DEFAULT_TEMPERATURE: f64 = 0.7;

    pub fn new(profile: AiProfile) -> Self {
        Self { profile, max_iterations: Self::DEFAULT_MAX_ITERATIONS, temperature: Self::DEFAULT_TEMPERATURE }
    }
}
