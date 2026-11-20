//! Chat against OpenAI-compatible chat completions or the Anthropic Messages
//! API, plain and streamed. Port of `AiClient.kt`.

use std::time::Instant;

use serde_json::{Value, json};

use super::profile::{AiProfile, AiProviderKind, AiSettings};
use super::transport::{AiCancellation, AiClientError, AiErrorKind, AiHttpRequest, AiHttpResponse, AiTransport, HttpsAiTransport};
use super::{is_blank, length, trim};
use crate::json::Object;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    System,
    User,
    Assistant,
}

impl Role {
    pub fn wire(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

/// One chat turn. Port of `AIMessage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiMessage {
    pub role: Role,
    pub content: String,
}

impl AiMessage {
    pub fn new(role: Role, content: impl Into<String>) -> Self {
        Self { role, content: content.into() }
    }
}

/// Token counts reported by the provider. Port of `AITokenUsage`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AiTokenUsage {
    pub prompt_tokens: i64,
    pub completion_tokens: i64,
    pub total_tokens: i64,
}

impl AiTokenUsage {
    pub const ZERO: Self = Self { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };

    pub fn new(prompt_tokens: i64, completion_tokens: i64, total_tokens: i64) -> Self {
        Self { prompt_tokens, completion_tokens, total_tokens }
    }
}

impl std::ops::Add for AiTokenUsage {
    type Output = Self;

    fn add(self, other: Self) -> Self {
        Self::new(self.prompt_tokens.saturating_add(other.prompt_tokens), self.completion_tokens.saturating_add(other.completion_tokens), self.total_tokens.saturating_add(other.total_tokens))
    }
}

/// A completed chat call. `truncated` is true when the provider stopped at its output limit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiChatResult {
    pub content: String,
    pub usage: AiTokenUsage,
    pub truncated: bool,
}

impl AiChatResult {
    pub fn new(content: impl Into<String>, usage: AiTokenUsage) -> Self {
        Self { content: content.into(), usage, truncated: false }
    }
}

/// The chat capability the agent loop needs; [`AiClient`] is the production implementation.
pub trait AiChat {
    /// Every failure, cancellation included, is an [`AiClientError`].
    fn chat(&self, messages: &[AiMessage], cancellation: &AiCancellation) -> Result<AiChatResult, AiClientError>;

    /// Like [`AiChat::chat`], and reports the reply as it is written: `on_text` gets all of the text
    /// so far, on the calling thread. A model that can not stream reports nothing until it returns.
    fn chat_stream(&self, messages: &[AiMessage], cancellation: &AiCancellation, _on_text: &mut dyn FnMut(&str)) -> Result<AiChatResult, AiClientError> {
        self.chat(messages, cancellation)
    }
}

/// Chat against OpenAI-compatible chat completions or the Anthropic Messages
/// API. Port of `AIClient.chat` / `chatStream` / `availableModels`.
///
/// The API key is passed per call and only ever placed in a request header.
/// Every failure is an [`AiClientError`] whose message is fixed text plus, at
/// most, the HTTP status and a short provider error code: never the key and
/// never a response body.
pub struct AiClient {
    transport: Box<dyn AiTransport>,
}

impl Default for AiClient {
    fn default() -> Self {
        Self::new(HttpsAiTransport::new())
    }
}

/// An [`AiChat`] bound to settings and a key, for [`super::AgentLoop`].
pub struct BoundChat<'a> {
    client: &'a AiClient,
    settings: AiSettings,
    api_key: String,
}

impl AiChat for BoundChat<'_> {
    fn chat(&self, messages: &[AiMessage], cancellation: &AiCancellation) -> Result<AiChatResult, AiClientError> {
        self.client.chat(messages, &self.settings, &self.api_key, cancellation)
    }

    fn chat_stream(&self, messages: &[AiMessage], cancellation: &AiCancellation, on_text: &mut dyn FnMut(&str)) -> Result<AiChatResult, AiClientError> {
        self.client.chat_stream(messages, &self.settings, &self.api_key, cancellation, on_text)
    }
}

const REFUSED_MESSAGE: &str = "The model declined this request. Rephrase the description and try again.";
const EMPTY_MESSAGE: &str = "The model returned an empty response.";
const TOO_LARGE_MESSAGE: &str = "The AI response exceeded the size limit.";

impl AiClient {
    pub const ANTHROPIC_VERSION: &'static str = "2023-06-01";
    /// Room for a full widget plus the model's own reasoning.
    pub const ANTHROPIC_MAX_TOKENS: i64 = 16_000;
    /// Same 4 MiB cap as `AIClient.chat`.
    pub const MAXIMUM_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
    /// Same 1 MiB cap as `AIClient.availableModels`.
    pub const MAXIMUM_MODELS_BYTES: usize = 1024 * 1024;
    pub const MAXIMUM_KEY_LENGTH: usize = 4096;
    pub const CONNECT_TIMEOUT_MILLISECONDS: u64 = 15_000;
    /// Swift allows 120 s; models that reason before answering need longer for a reply that is not streamed.
    pub const CHAT_TIMEOUT_MILLISECONDS: u64 = 300_000;
    /// Same 15 s as `AIClient.availableModels`.
    pub const MODELS_TIMEOUT_MILLISECONDS: u64 = 15_000;

    pub fn new(transport: impl AiTransport + 'static) -> Self {
        Self { transport: Box::new(transport) }
    }

    /// Sends `messages` and returns the model's text. Blocks; call it off the window's thread.
    pub fn chat(&self, messages: &[AiMessage], settings: &AiSettings, api_key: &str, cancellation: &AiCancellation) -> Result<AiChatResult, AiClientError> {
        let request = self.build_chat_request(messages, settings, api_key, false)?;
        if cancellation.is_cancelled() {
            return Err(AiClientError::cancelled());
        }
        let response = self.perform(&request, api_key, cancellation)?;
        scrub(api_key, self.parse_chat_response(settings.profile.kind, &response))
    }

    /// An [`AiChat`] bound to `settings` and `api_key`, for [`super::AgentLoop`].
    pub fn bind(&self, settings: AiSettings, api_key: &str) -> BoundChat<'_> {
        BoundChat { client: self, settings, api_key: api_key.to_owned() }
    }

    /// Sends `messages` asking for a streamed reply and reports the text so far through `on_text`.
    /// Port of `AIClient.chatStream`. A server that refuses the streamed form, answers it in the
    /// plain form, or sends nothing that can be read is asked once more in the plain way.
    pub fn chat_stream(&self, messages: &[AiMessage], settings: &AiSettings, api_key: &str, cancellation: &AiCancellation, on_text: &mut dyn FnMut(&str)) -> Result<AiChatResult, AiClientError> {
        let request = self.build_chat_request(messages, settings, api_key, true)?;
        if cancellation.is_cancelled() {
            return Err(AiClientError::cancelled());
        }
        let mut events = AiStreamReader::new(settings.profile.kind.uses_anthropic_messages());
        // What was already read is not a reply; a stream that broke off is not retried.
        let response = scrub(api_key, self.transport.execute_streaming(&request, cancellation, &mut |bytes| events.feed(bytes, on_text)))?;
        let result = (|| {
            if matches!(response.status, 401 | 403 | 429) {
                return Err(http_error(&response));
            }
            events.finish(on_text)?;
            if !response.is_success() {
                // The server would not stream: ask in the plain way.
                return self.chat(messages, settings, api_key, cancellation);
            }
            if events.refused() {
                return Err(AiClientError::new(AiErrorKind::Refused, REFUSED_MESSAGE));
            }
            if events.saw_event() && !is_blank(events.text()) {
                on_text(events.text());
                return Ok(AiChatResult { content: events.text().to_owned(), usage: events.usage(), truncated: events.truncated() });
            }
            if events.saw_event() {
                return Err(AiClientError::new(AiErrorKind::EmptyResponse, EMPTY_MESSAGE));
            }
            // A plain JSON body means the server ignored "stream".
            let plain = self.parse_chat_response(settings.profile.kind, &response)?;
            on_text(&plain.content);
            Ok(plain)
        })();
        scrub(api_key, result)
    }

    /// Model identifiers the endpoint lists (`GET /v1/models`), sorted. Used by "Test connection".
    pub fn list_models(&self, profile: &AiProfile, api_key: &str, cancellation: &AiCancellation) -> Result<Vec<String>, AiClientError> {
        let base = endpoint(profile)?;
        let key = require_key(api_key)?;
        let url = format!("{base}/v1/models{}", if profile.kind.uses_anthropic_messages() { "?limit=1000" } else { "" });
        let request = AiHttpRequest {
            method: "GET".into(),
            url,
            headers: authentication(profile.kind, key),
            body: None,
            connect_timeout_milliseconds: Self::CONNECT_TIMEOUT_MILLISECONDS,
            read_timeout_milliseconds: Self::MODELS_TIMEOUT_MILLISECONDS,
            maximum_response_bytes: Self::MAXIMUM_MODELS_BYTES,
        };
        let response = self.perform(&request, api_key, cancellation)?;
        let result = (|| {
            if !response.is_success() {
                return Err(http_error(&response));
            }
            let json = parse_object(&response.body)?;
            let data = json.get("data").and_then(Value::as_array).ok_or_else(malformed)?;
            let mut ids: Vec<String> = data.iter().filter_map(|item| item.as_object()?.get("id")?.as_str()).filter(|id| !id.is_empty() && length(id) <= AiProfile::MAXIMUM_MODEL_LENGTH).map(str::to_owned).collect();
            ids.sort();
            ids.dedup();
            Ok(ids)
        })();
        scrub(api_key, result)
    }

    /// Builds the chat request for the profile's API style. Public so its JSON shape can be tested.
    pub fn build_chat_request(&self, messages: &[AiMessage], settings: &AiSettings, api_key: &str, stream: bool) -> Result<AiHttpRequest, AiClientError> {
        let profile = &settings.profile;
        let base = endpoint(profile)?;
        let key = require_key(api_key)?;
        let model = trim(&profile.model);
        let mut headers: Vec<(String, String)> = vec![("Content-Type".into(), "application/json".into()), ("Accept".into(), "application/json".into())];
        headers.extend(authentication(profile.kind, key));
        let wire = |message: &AiMessage| json!({ "role": message.role.wire(), "content": message.content });
        let mut body = Object::new();
        body.insert("model".into(), json!(model));
        let path;
        if profile.kind.uses_anthropic_messages() {
            path = "/v1/messages";
            // The Messages API takes the system prompt as a top-level field and requires max_tokens.
            // Sampling parameters are not sent: current Claude models reject them.
            body.insert("max_tokens".into(), json!(Self::ANTHROPIC_MAX_TOKENS));
            let system: Vec<&str> = messages.iter().filter(|message| message.role == Role::System).map(|message| message.content.as_str()).collect();
            let system = system.join("\n\n");
            if !system.is_empty() {
                body.insert("system".into(), json!(system));
            }
            body.insert("messages".into(), messages.iter().filter(|message| message.role != Role::System).map(wire).collect());
        } else {
            path = "/v1/chat/completions";
            body.insert("messages".into(), messages.iter().map(wire).collect());
            body.insert("temperature".into(), json!(settings.temperature));
            if stream {
                body.insert("stream_options".into(), json!({ "include_usage": true }));
            }
        }
        if stream {
            body.insert("stream".into(), json!(true));
            if let Some(accept) = headers.iter_mut().find(|(name, _)| name == "Accept") {
                accept.1 = "text/event-stream".into();
            }
        }
        Ok(AiHttpRequest {
            method: "POST".into(),
            url: format!("{base}{path}"),
            headers,
            body: Some(crate::json::stringify_object(&body).into_bytes()),
            connect_timeout_milliseconds: Self::CONNECT_TIMEOUT_MILLISECONDS,
            read_timeout_milliseconds: Self::CHAT_TIMEOUT_MILLISECONDS,
            maximum_response_bytes: Self::MAXIMUM_RESPONSE_BYTES,
        })
    }

    /// Parses a chat response of either API style. Public so error bodies and malformed JSON can be tested.
    pub fn parse_chat_response(&self, kind: AiProviderKind, response: &AiHttpResponse) -> Result<AiChatResult, AiClientError> {
        if !response.is_success() {
            return Err(http_error(response));
        }
        if response.body.len() > Self::MAXIMUM_RESPONSE_BYTES {
            return Err(AiClientError::new(AiErrorKind::ResponseTooLarge, TOO_LARGE_MESSAGE));
        }
        let json = parse_object(&response.body)?;
        if kind.uses_anthropic_messages() { parse_anthropic(&json) } else { parse_chat_completion(&json) }
    }

    fn perform(&self, request: &AiHttpRequest, api_key: &str, cancellation: &AiCancellation) -> Result<AiHttpResponse, AiClientError> {
        scrub(api_key, self.transport.execute(request, cancellation))
    }
}

fn parse_anthropic(json: &Object) -> Result<AiChatResult, AiClientError> {
    if json.get("type").and_then(Value::as_str) == Some("error") || json.get("error").is_some_and(Value::is_object) {
        return Err(AiClientError::new(AiErrorKind::Http, format!("The AI server reported an error{}.", error_code(Some(json)))));
    }
    let stop = json.get("stop_reason").and_then(Value::as_str);
    if stop == Some("refusal") {
        return Err(AiClientError::new(AiErrorKind::Refused, REFUSED_MESSAGE));
    }
    let blocks = json.get("content").and_then(Value::as_array).ok_or_else(malformed)?;
    let mut text = String::new();
    for block in blocks.iter().filter_map(Value::as_object) {
        // Thinking and tool blocks are not widget code.
        if block.get("type").and_then(Value::as_str) == Some("text")
            && let Some(piece) = block.get("text").and_then(Value::as_str)
        {
            text.push_str(piece);
        }
    }
    if is_blank(&text) {
        return Err(AiClientError::new(AiErrorKind::EmptyResponse, EMPTY_MESSAGE));
    }
    let usage = json.get("usage").and_then(Value::as_object);
    let input = count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens") + count(usage, "cache_read_input_tokens");
    let output = count(usage, "output_tokens");
    Ok(AiChatResult { content: text, usage: AiTokenUsage::new(input, output, input + output), truncated: stop == Some("max_tokens") })
}

fn parse_chat_completion(json: &Object) -> Result<AiChatResult, AiClientError> {
    let choices = json.get("choices").and_then(Value::as_array);
    if json.get("error").is_some_and(|error| !error.is_null()) && choices.is_none() {
        return Err(AiClientError::new(AiErrorKind::Http, format!("The AI server reported an error{}.", error_code(Some(json)))));
    }
    let choice = choices.and_then(|choices| choices.first()).and_then(Value::as_object).ok_or_else(malformed)?;
    let content = choice.get("message").and_then(Value::as_object).and_then(|message| message.get("content")).and_then(Value::as_str);
    let Some(content) = content.filter(|content| !is_blank(content)) else { return Err(AiClientError::new(AiErrorKind::EmptyResponse, EMPTY_MESSAGE)) };
    let usage = json.get("usage").and_then(Value::as_object);
    let prompt = count(usage, "prompt_tokens");
    let completion = count(usage, "completion_tokens");
    let total = Some(count(usage, "total_tokens")).filter(|total| *total > 0).unwrap_or(prompt + completion);
    Ok(AiChatResult { content: content.to_owned(), usage: AiTokenUsage::new(prompt, completion, total), truncated: choice.get("finish_reason").and_then(Value::as_str) == Some("length") })
}

/// Last line of defence: an error that somehow mentions the key is replaced by one that does not.
fn scrub<T>(api_key: &str, result: Result<T, AiClientError>) -> Result<T, AiClientError> {
    result.map_err(|error| {
        let key = trim(api_key);
        if !key.is_empty() && error.message.contains(key) { AiClientError { kind: error.kind, message: "The AI request failed.".into(), http_status: error.http_status } } else { error }
    })
}

/// Port of the status mapping in `AIClient.chat`.
fn http_error(response: &AiHttpResponse) -> AiClientError {
    let message = match response.status {
        401 | 403 => "The AI server rejected authentication. Check this profile's API key.".to_owned(),
        404 => "The AI endpoint or model was not found. Check the API base URL and model name.".to_owned(),
        429 => "The AI server's usage limit was reached. Wait and try again.".to_owned(),
        status => format!("The AI server could not complete the request (HTTP {status}){}.", error_code(parse_object(&response.body).ok().as_ref())),
    };
    AiClientError::with_status(AiErrorKind::Http, message, response.status)
}

/// A short machine error code such as `invalid_request_error`, never free text.
fn error_code(json: Option<&Object>) -> String {
    let Some(error) = json.and_then(|json| json.get("error")).and_then(Value::as_object) else { return String::new() };
    let is_code = |text: &&str| (1..=64).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'));
    match ["type", "code"].into_iter().filter_map(|name| error.get(name).and_then(Value::as_str)).find(is_code) {
        Some(code) => format!(" ({code})"),
        None => String::new(),
    }
}

fn parse_object(body: &[u8]) -> Result<Object, AiClientError> {
    std::str::from_utf8(body).ok().and_then(|text| crate::json::parse_object(text).ok()).ok_or_else(malformed)
}

fn malformed() -> AiClientError {
    AiClientError::new(AiErrorKind::MalformedResponse, "The AI server returned a response that could not be read. Check the API base URL.")
}

fn count(usage: Option<&Object>, key: &str) -> i64 {
    // A float-to-integer cast saturates at the bounds.
    usage.and_then(|usage| usage.get(key)).and_then(Value::as_f64).map_or(0, |number| (number as i64).clamp(0, i64::from(i32::MAX)))
}

fn endpoint(profile: &AiProfile) -> Result<String, AiClientError> {
    match profile.validation_error() {
        Some(error) => Err(AiClientError::new(AiErrorKind::InvalidProfile, error)),
        None => Ok(profile.normalized_base_url()),
    }
}

/// The key as it is sent, or why it can not be. Also what a credential store accepts.
pub fn require_key(api_key: &str) -> Result<&str, AiClientError> {
    let key = trim(api_key);
    if key.is_empty() {
        return Err(AiClientError::new(AiErrorKind::MissingApiKey, "API key is not set. Store one with: scriptwidget ai key set"));
    }
    // A key with control characters could inject headers.
    if key.len() > AiClient::MAXIMUM_KEY_LENGTH || key.chars().any(|character| character.is_control() || character as u32 > 0x7e) {
        return Err(AiClientError::new(AiErrorKind::MissingApiKey, "The API key contains characters that are not allowed."));
    }
    Ok(key)
}

fn authentication(kind: AiProviderKind, key: &str) -> Vec<(String, String)> {
    if kind.uses_anthropic_messages() {
        vec![("x-api-key".into(), key.to_owned()), ("anthropic-version".into(), AiClient::ANTHROPIC_VERSION.into())]
    } else {
        vec![("Authorization".into(), format!("Bearer {key}"))]
    }
}

/// Reads a server-sent event stream of either API style as its bytes arrive and keeps the text
/// so far. Lines are split on the bytes, so a character that arrives in two pieces is not broken.
pub struct AiStreamReader {
    anthropic: bool,
    pending: Vec<u8>,
    content: String,
    last_sent: Option<Instant>,
    input: i64,
    output: i64,
    total: i64,
    saw_event: bool,
    truncated: bool,
    refused: bool,
}

impl AiStreamReader {
    const MAXIMUM_LINE_BYTES: usize = 1024 * 1024;
    /// The text so far is reported at most this often while it arrives.
    const REPORT_MILLISECONDS: u128 = 80;

    pub fn new(anthropic: bool) -> Self {
        Self { anthropic, pending: Vec::new(), content: String::new(), last_sent: None, input: 0, output: 0, total: 0, saw_event: false, truncated: false, refused: false }
    }

    pub fn saw_event(&self) -> bool {
        self.saw_event
    }

    pub fn truncated(&self) -> bool {
        self.truncated
    }

    pub fn refused(&self) -> bool {
        self.refused
    }

    pub fn text(&self) -> &str {
        &self.content
    }

    pub fn usage(&self) -> AiTokenUsage {
        AiTokenUsage::new(self.input, self.output, if self.total > 0 { self.total } else { self.input + self.output })
    }

    pub fn feed(&mut self, bytes: &[u8], on_text: &mut dyn FnMut(&str)) -> Result<(), AiClientError> {
        for byte in bytes {
            if *byte == b'\n' {
                let line = std::mem::take(&mut self.pending);
                self.line(String::from_utf8_lossy(&line).trim_end_matches('\r'), on_text)?;
            } else if self.pending.len() < Self::MAXIMUM_LINE_BYTES {
                self.pending.push(*byte);
            }
        }
        Ok(())
    }

    /// Reads a last line that did not end with a line break.
    pub fn finish(&mut self, on_text: &mut dyn FnMut(&str)) -> Result<(), AiClientError> {
        let line = std::mem::take(&mut self.pending);
        if line.is_empty() {
            return Ok(());
        }
        self.line(String::from_utf8_lossy(&line).trim_end_matches('\r'), on_text)
    }

    fn line(&mut self, line: &str, on_text: &mut dyn FnMut(&str)) -> Result<(), AiClientError> {
        let Some(payload) = line.strip_prefix("data:").map(trim) else { return Ok(()) };
        if payload == "[DONE]" || payload.is_empty() {
            return Ok(());
        }
        let Ok(json) = crate::json::parse_object(payload) else { return Ok(()) };
        self.saw_event = true;
        let piece = if self.anthropic { self.anthropic_event(&json) } else { self.chat_completion_event(&json) };
        let Some(piece) = piece.filter(|piece| !piece.is_empty()) else { return Ok(()) };
        if self.content.len() + piece.len() > AiClient::MAXIMUM_RESPONSE_BYTES {
            return Err(AiClientError::new(AiErrorKind::ResponseTooLarge, TOO_LARGE_MESSAGE));
        }
        self.content.push_str(&piece);
        if self.last_sent.is_none_or(|sent| sent.elapsed().as_millis() >= Self::REPORT_MILLISECONDS) {
            self.last_sent = Some(Instant::now());
            on_text(&self.content);
        }
        Ok(())
    }

    fn chat_completion_event(&mut self, json: &Object) -> Option<String> {
        if let Some(usage) = json.get("usage").and_then(Value::as_object) {
            self.input = count(Some(usage), "prompt_tokens");
            self.output = count(Some(usage), "completion_tokens");
            self.total = count(Some(usage), "total_tokens");
        }
        let choice = json.get("choices")?.as_array()?.first()?.as_object()?;
        if choice.get("finish_reason").and_then(Value::as_str) == Some("length") {
            self.truncated = true;
        }
        choice.get("delta")?.as_object()?.get("content")?.as_str().map(str::to_owned)
    }

    fn anthropic_event(&mut self, json: &Object) -> Option<String> {
        match json.get("type").and_then(Value::as_str).unwrap_or("") {
            "message_start" => {
                if let Some(usage) = json.get("message").and_then(Value::as_object).and_then(|message| message.get("usage")).and_then(Value::as_object) {
                    self.input = count(Some(usage), "input_tokens") + count(Some(usage), "cache_creation_input_tokens") + count(Some(usage), "cache_read_input_tokens");
                }
            }
            "message_delta" => {
                if let Some(usage) = json.get("usage").and_then(Value::as_object) {
                    self.output = count(Some(usage), "output_tokens");
                }
                match json.get("delta").and_then(Value::as_object).and_then(|delta| delta.get("stop_reason")).and_then(Value::as_str) {
                    Some("max_tokens") => self.truncated = true,
                    Some("refusal") => self.refused = true,
                    _ => {}
                }
            }
            "content_block_delta" => {
                let delta = json.get("delta")?.as_object()?;
                // Thinking and tool input are not widget code.
                if delta.get("type").and_then(Value::as_str) == Some("text_delta") {
                    return delta.get("text")?.as_str().map(str::to_owned);
                }
            }
            _ => {}
        }
        None
    }
}
