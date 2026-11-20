//! The AI client: request shapes, response parsing, error mapping, and the
//! streamed replies of both API styles against recorded event shapes. Ported
//! from `AiClientTest.kt` and `AiStreamTest.kt`. No test touches the network.

mod ai_common;

use std::sync::{Arc, Mutex};

use ai_common::*;
use serde_json::{Value, json};
use sw_core::ai::transport::OnBody;
use sw_core::ai::*;

const KEY: &str = "sk-test-SECRET-0123456789abcdef";

fn anthropic() -> AiSettings {
    AiSettings::new(AiProfile::defaults(AiProviderKind::Anthropic))
}

fn openai() -> AiSettings {
    AiSettings { temperature: 0.4, ..AiSettings::new(AiProfile::defaults(AiProviderKind::OpenAi)) }
}

fn messages() -> Vec<AiMessage> {
    vec![AiMessage::new(Role::System, "rules"), AiMessage::new(Role::User, "make a clock"), AiMessage::new(Role::Assistant, "old code"), AiMessage::new(Role::User, "fix it")]
}

fn none() -> AiCancellation {
    AiCancellation::new()
}

type Canned = Result<AiHttpResponse, AiClientError>;

/// Records requests and replays canned responses. With `step`, a body is handed over in pieces of that many bytes, as a network would.
#[derive(Clone)]
struct FakeTransport {
    responses: Arc<Mutex<Vec<Canned>>>,
    requests: Arc<Mutex<Vec<AiHttpRequest>>>,
    step: Option<usize>,
}

impl FakeTransport {
    fn new(responses: Vec<Canned>) -> Self {
        Self { responses: Arc::new(Mutex::new(responses)), requests: Arc::default(), step: None }
    }

    fn streaming(responses: Vec<AiHttpResponse>, step: usize) -> Self {
        Self { step: Some(step), ..Self::new(responses.into_iter().map(Ok).collect()) }
    }

    fn requests(&self) -> Vec<AiHttpRequest> {
        self.requests.lock().unwrap().clone()
    }

    fn body(&self, index: usize) -> Value {
        serde_json::from_slice(self.requests()[index].body.as_deref().unwrap()).unwrap()
    }
}

impl AiTransport for FakeTransport {
    fn execute(&self, request: &AiHttpRequest, _: &AiCancellation) -> Canned {
        self.requests.lock().unwrap().push(request.clone());
        self.responses.lock().unwrap().remove(0)
    }

    fn execute_streaming(&self, request: &AiHttpRequest, cancellation: &AiCancellation, on_body: OnBody<'_>) -> Canned {
        let response = self.execute(request, cancellation)?;
        if response.is_success() {
            for piece in response.body.chunks(self.step.unwrap_or(usize::MAX).max(1)) {
                on_body(piece)?;
            }
        }
        Ok(response)
    }
}

fn response(status: u16, body: &str) -> Canned {
    Ok(AiHttpResponse::new(status, body))
}

fn client(responses: Vec<Canned>) -> (AiClient, FakeTransport) {
    let transport = FakeTransport::new(responses);
    (AiClient::new(transport.clone()), transport)
}

fn parse(kind: AiProviderKind, status: u16, body: &str) -> Result<AiChatResult, AiClientError> {
    client(Vec::new()).0.parse_chat_response(kind, &AiHttpResponse::new(status, body))
}

fn assert_no_key(error: &AiClientError) {
    assert!(!error.message.contains(KEY), "{}", error.message);
    assert!(!error.to_string().contains(KEY) && !format!("{error:?}").contains(KEY));
    assert!(std::error::Error::source(error).is_none(), "nothing a lower layer said is carried along");
}

#[test]
fn anthropic_request_uses_the_messages_api_shape() {
    let request = client(Vec::new()).0.build_chat_request(&messages(), &anthropic(), &format!("  {KEY}\n"), false).unwrap();
    assert_eq!(request.method, "POST");
    assert_eq!(request.url, "https://api.anthropic.com/v1/messages");
    assert_eq!(request.header("x-api-key"), Some(KEY));
    assert_eq!(request.header("anthropic-version"), Some("2023-06-01"));
    assert_eq!(request.header("Content-Type"), Some("application/json"));
    assert_eq!(request.header("Authorization"), None);
    let text = String::from_utf8(request.body.clone().unwrap()).unwrap();
    let body: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(body["model"], "claude-fable-5-2");
    assert_eq!(body["max_tokens"], AiClient::ANTHROPIC_MAX_TOKENS);
    assert_eq!(body["system"], "rules");
    let sent = body["messages"].as_array().unwrap();
    assert_eq!(sent.iter().map(|message| message["role"].as_str().unwrap()).collect::<Vec<_>>(), ["user", "assistant", "user"]);
    assert_eq!(sent[0]["content"], "make a clock");
    // Current Claude models reject sampling parameters and non-default thinking configuration.
    assert!(body.get("temperature").is_none() && body.get("thinking").is_none());
    assert!(!text.contains(KEY));
}

#[test]
fn open_ai_request_uses_chat_completions_shape() {
    let request = client(Vec::new()).0.build_chat_request(&messages(), &openai(), KEY, false).unwrap();
    assert_eq!(request.url, "https://api.openai.com/v1/chat/completions");
    assert_eq!(request.header("Authorization"), Some(format!("Bearer {KEY}").as_str()));
    assert_eq!(request.header("x-api-key"), None);
    let body: Value = serde_json::from_slice(request.body.as_deref().unwrap()).unwrap();
    assert_eq!(body["model"], "gpt-4o-mini");
    assert_eq!(body["temperature"], 0.4);
    assert!(body.get("max_tokens").is_none());
    assert_eq!(body["messages"].as_array().unwrap().iter().map(|message| message["role"].as_str().unwrap()).collect::<Vec<_>>(), ["system", "user", "assistant", "user"]);
}

#[test]
fn custom_endpoint_keeps_its_path_and_drops_a_trailing_version() {
    let settings = AiSettings::new(AiProfile::new(AiProviderKind::OpenAiCompatible, "https://gateway.example.com/openai/v1/", "my-model"));
    let request = client(Vec::new()).0.build_chat_request(&messages(), &settings, KEY, false).unwrap();
    assert_eq!(request.url, "https://gateway.example.com/openai/v1/chat/completions");
}

#[test]
fn request_and_response_descriptions_never_contain_secrets_or_bodies() {
    let request = client(Vec::new()).0.build_chat_request(&messages(), &anthropic(), KEY, false).unwrap();
    let described = format!("{request:?}");
    assert!(!described.contains(KEY) && !described.contains("make a clock"), "{described}");
    assert!(described.contains("x-api-key"));
    assert!(!format!("{:?}", AiHttpResponse::new(200, format!("body with {KEY}"))).contains(KEY));
    assert!(!format!("{:?}", anthropic()).contains(KEY));
    assert_eq!(format!("{:?}", ApiKey::new(KEY).unwrap()), "ApiKey(<hidden>)");
}

#[test]
fn parses_anthropic_text_blocks_and_usage() {
    let body = r#"{"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"$render("},{"type":"text","text":"<vstack/>)"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2}}"#;
    let result = client(vec![response(200, body)]).0.chat(&messages(), &anthropic(), KEY, &none()).unwrap();
    assert_eq!(result.content, "$render(<vstack/>)");
    assert_eq!(result.usage, AiTokenUsage::new(12, 5, 17));
    assert!(!result.truncated);
}

#[test]
fn anthropic_max_tokens_stop_is_reported_as_truncated() {
    assert!(parse(AiProviderKind::Anthropic, 200, r#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#).unwrap().truncated);
}

#[test]
fn anthropic_refusal_and_empty_content_fail() {
    assert_eq!(parse(AiProviderKind::Anthropic, 200, r#"{"stop_reason":"refusal","content":[]}"#).unwrap_err().kind, AiErrorKind::Refused);
    assert_eq!(parse(AiProviderKind::Anthropic, 200, r#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"x"}]}"#).unwrap_err().kind, AiErrorKind::EmptyResponse);
}

#[test]
fn parses_chat_completion_and_usage() {
    let body = r#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"code"}}],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}"#;
    let result = client(vec![response(200, body)]).0.chat(&messages(), &openai(), KEY, &none()).unwrap();
    assert_eq!((result.content.as_str(), result.usage), ("code", AiTokenUsage::new(7, 3, 10)));
    assert!(parse(AiProviderKind::OpenAi, 200, r#"{"choices":[{"finish_reason":"length","message":{"content":"co"}}]}"#).unwrap().truncated);
}

#[test]
fn chat_completion_without_content_is_empty() {
    for body in [r#"{"choices":[{"message":{"content":""}}]}"#, r#"{"choices":[{"message":{"content":null}}]}"#, r#"{"choices":[{"message":{}}]}"#] {
        assert_eq!(parse(AiProviderKind::OpenAi, 200, body).unwrap_err().kind, AiErrorKind::EmptyResponse, "{body}");
    }
}

#[test]
fn http_errors_map_to_fixed_messages_without_the_body() {
    let secret_body = format!(r#"{{"type":"error","error":{{"type":"authentication_error","message":"Incorrect API key provided: {KEY}. Internal detail LEAK"}}}}"#);
    for (status, fragment) in [(401, "rejected authentication"), (403, "rejected authentication"), (404, "was not found"), (429, "usage limit"), (500, "HTTP 500"), (400, "HTTP 400")] {
        for settings in [anthropic(), openai()] {
            let error = client(vec![response(status, &secret_body)]).0.chat(&messages(), &settings, KEY, &none()).unwrap_err();
            assert_eq!((error.kind, error.http_status), (AiErrorKind::Http, Some(status)));
            assert!(error.message.contains(fragment), "{}", error.message);
            assert!(!error.message.contains("LEAK") && !error.message.contains("Incorrect"));
            assert_no_key(&error);
        }
    }
    // A short machine code is the only thing taken from an error body.
    let coded = client(vec![response(400, &secret_body)]).0.chat(&messages(), &anthropic(), KEY, &none()).unwrap_err();
    assert!(coded.message.contains("(authentication_error)"));
}

#[test]
fn an_error_code_that_echoes_the_key_is_scrubbed() {
    let error = client(vec![response(500, &format!(r#"{{"error":{{"type":"{KEY}"}}}}"#))]).0.chat(&messages(), &anthropic(), KEY, &none()).unwrap_err();
    assert_no_key(&error);
    let in_band = client(vec![response(200, &format!(r#"{{"type":"error","error":{{"type":"{KEY}"}}}}"#))]).0.chat(&messages(), &anthropic(), KEY, &none()).unwrap_err();
    assert_no_key(&in_band);
}

#[test]
fn malformed_json_fails_closed() {
    for body in ["", "<html>502</html>", "[1,2]", "{\"choices\":", "{}", r#"{"choices":[]}"#, r#"{"choices":"x"}"#] {
        for kind in [AiProviderKind::OpenAi, AiProviderKind::Anthropic] {
            let error = parse(kind, 200, body).unwrap_err();
            assert_eq!(error.kind, AiErrorKind::MalformedResponse, "{kind:?} {body}");
            assert!(!error.message.contains("html"));
        }
    }
}

#[test]
fn error_object_in_a_successful_response_is_an_error() {
    let anthropic_error = parse(AiProviderKind::Anthropic, 200, r#"{"type":"error","error":{"type":"overloaded_error","message":"secret text"}}"#).unwrap_err();
    assert_eq!(anthropic_error.kind, AiErrorKind::Http);
    assert!(anthropic_error.message.contains("overloaded_error") && !anthropic_error.message.contains("secret text"));
    let open_ai_error = parse(AiProviderKind::OpenAi, 200, r#"{"error":{"message":"secret text","code":"model_not_found"}}"#).unwrap_err();
    assert!(open_ai_error.message.contains("model_not_found") && !open_ai_error.message.contains("secret text"));
}

/// In Kotlin a transport can throw anything; here it can only return an
/// `AiClientError`, so the one case left is an error whose own text has the key.
#[test]
fn transport_failures_never_carry_the_key() {
    for style in ["plain", "streamed", "models"] {
        // The streamed request is tried once more in the plain way, which fails the same.
        let failure = || Err(AiClientError::new(AiErrorKind::Network, format!("proxy said {KEY}")));
        let (client, _) = client(vec![failure(), failure()]);
        let error = match style {
            "plain" => client.chat(&messages(), &anthropic(), KEY, &none()).unwrap_err(),
            "streamed" => client.chat_stream(&messages(), &anthropic(), KEY, &none(), &mut |_| {}).unwrap_err(),
            _ => client.list_models(&anthropic().profile, KEY, &none()).unwrap_err(),
        };
        assert_eq!((error.kind, error.message.as_str()), (AiErrorKind::Network, "The AI request failed."), "{style}");
        assert_no_key(&error);
    }
}

#[test]
fn missing_or_unsafe_key_is_rejected_before_any_request() {
    let (client, transport) = client(Vec::new());
    for bad in ["", "   ", "\n"] {
        assert_eq!(client.chat(&messages(), &anthropic(), bad, &none()).unwrap_err().kind, AiErrorKind::MissingApiKey);
    }
    for injected in ["abc\r\nX-Evil: 1", "abc\u{0}def", "kéy", "a\u{7f}b"] {
        let error = client.chat(&messages(), &anthropic(), injected, &none()).unwrap_err();
        assert_eq!(error.kind, AiErrorKind::MissingApiKey);
        assert!(!error.message.contains("X-Evil"));
    }
    assert_eq!(client.chat(&messages(), &anthropic(), &"k".repeat(AiClient::MAXIMUM_KEY_LENGTH + 1), &none()).unwrap_err().kind, AiErrorKind::MissingApiKey);
    assert!(transport.requests().is_empty());
}

#[test]
fn invalid_profile_is_rejected_before_any_request() {
    let (client, transport) = client(Vec::new());
    let insecure = AiSettings::new(AiProfile::new(AiProviderKind::OpenAiCompatible, "http://example.com", "m"));
    assert_eq!(client.chat(&messages(), &insecure, KEY, &none()).unwrap_err().kind, AiErrorKind::InvalidProfile);
    let local = AiSettings::new(AiProfile::new(AiProviderKind::OpenAiCompatible, "http://localhost:11434", "llama"));
    assert_eq!(client.chat_stream(&messages(), &local, KEY, &none(), &mut |_| {}).unwrap_err().kind, AiErrorKind::InvalidProfile);
    let no_model = AiSettings::new(AiProfile::new(AiProviderKind::OpenAi, "", "  "));
    assert_eq!(client.chat(&messages(), &no_model, KEY, &none()).unwrap_err().kind, AiErrorKind::InvalidProfile);
    assert!(transport.requests().is_empty());
}

#[test]
fn cancellation_before_sending_makes_no_request() {
    let (client, transport) = client(Vec::new());
    let cancellation = AiCancellation::new();
    cancellation.cancel();
    assert_eq!(client.chat(&messages(), &anthropic(), KEY, &cancellation).unwrap_err().kind, AiErrorKind::Cancelled);
    assert_eq!(client.chat_stream(&messages(), &anthropic(), KEY, &cancellation, &mut |_| {}).unwrap_err().kind, AiErrorKind::Cancelled);
    assert!(transport.requests().is_empty());
}

#[test]
fn cancellation_runs_registered_actions_once() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let cancellation = AiCancellation::new();
    let count = Arc::new(AtomicUsize::new(0));
    let counted = count.clone();
    let registration = cancellation.on_cancel(move || {
        counted.fetch_add(1, Ordering::SeqCst);
    });
    let unregistered = Arc::new(AtomicUsize::new(0));
    let never = unregistered.clone();
    cancellation
        .on_cancel(move || {
            never.fetch_add(1, Ordering::SeqCst);
        })
        .close();
    cancellation.cancel();
    cancellation.cancel();
    assert_eq!((count.load(Ordering::SeqCst), unregistered.load(Ordering::SeqCst)), (1, 0));
    assert!(cancellation.clone().is_cancelled(), "a clone is the same cancellation");
    registration.close();
    let late = Arc::new(AtomicUsize::new(0));
    let counted = late.clone();
    let _registration = cancellation.on_cancel(move || {
        counted.fetch_add(1, Ordering::SeqCst);
    });
    assert_eq!(late.load(Ordering::SeqCst), 1);
}

#[test]
fn list_models_uses_the_provider_authentication_and_sorts_ids() {
    let body = r#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"name":"no id"},{"id":7}]}"#;
    let (client, transport) = client(vec![response(200, body), response(200, body)]);
    assert_eq!(client.list_models(&anthropic().profile, KEY, &none()).unwrap(), ["a", "b"]);
    assert_eq!(client.list_models(&openai().profile, KEY, &none()).unwrap(), ["a", "b"]);
    let requests = transport.requests();
    assert_eq!((requests[0].method.as_str(), requests[0].url.as_str()), ("GET", "https://api.anthropic.com/v1/models?limit=1000"));
    assert_eq!(requests[0].header("x-api-key"), Some(KEY));
    assert_eq!(requests[1].url, "https://api.openai.com/v1/models");
    assert_eq!(requests[1].header("Authorization"), Some(format!("Bearer {KEY}").as_str()));
    assert!(requests[0].body.is_none());
}

#[test]
fn list_models_failures_are_mapped_and_key_free() {
    let unauthorized = client(vec![response(401, &format!("nope {KEY}"))]).0.list_models(&anthropic().profile, KEY, &none()).unwrap_err();
    assert!(unauthorized.message.contains("rejected authentication"));
    assert_no_key(&unauthorized);
    assert_eq!(client(vec![response(200, "{}")]).0.list_models(&anthropic().profile, KEY, &none()).unwrap_err().kind, AiErrorKind::MalformedResponse);
}

// Streamed replies (AiStreamTest.kt)

fn sse(events: &[&str]) -> AiHttpResponse {
    AiHttpResponse::new(200, events.iter().map(|event| format!("data: {event}\n\n")).collect::<String>())
}

fn delta(text: &str) -> String {
    json!({ "choices": [{ "delta": { "content": text } }] }).to_string()
}

fn one_message() -> Vec<AiMessage> {
    vec![AiMessage::new(Role::User, "make a clock")]
}

#[test]
fn an_open_ai_stream_is_read_as_it_arrives_and_ends_as_one_text() {
    let transport = FakeTransport::streaming(
        vec![sse(&[
            &delta("SUMMARY: 你好。\n"),
            &delta("```jsx\n$render("),
            &delta("<vstack/>)\n```"),
            r#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            r#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#,
            "[DONE]",
        ])],
        7,
    );
    let mut seen: Vec<String> = Vec::new();
    let result = AiClient::new(transport.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |text| seen.push(text.to_owned())).unwrap();
    let whole = "SUMMARY: 你好。\n```jsx\n$render(<vstack/>)\n```";
    assert_eq!(result.content, whole);
    assert_eq!(result.usage, AiTokenUsage::new(10, 5, 15));
    assert!(!result.truncated);
    assert_eq!(seen.last().map(String::as_str), Some(whole));
    assert!(seen.iter().all(|text| whole.starts_with(text.as_str())), "every report is the text so far");
    assert_eq!(transport.requests().len(), 1);
    let body = transport.body(0);
    assert_eq!((&body["stream"], &body["stream_options"]["include_usage"]), (&json!(true), &json!(true)));
    assert_eq!(transport.requests()[0].header("Accept"), Some("text/event-stream"));
}

#[test]
fn an_anthropic_stream_keeps_only_the_text_and_counts_tokens() {
    let transport = FakeTransport::streaming(
        vec![sse(&[
            r#"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":3}}}"#,
            r#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}"#,
            r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}"#,
            r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"there"}}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":7}}"#,
            r#"{"type":"message_stop"}"#,
        ])],
        3,
    );
    let result = AiClient::new(transport.clone()).chat_stream(&one_message(), &anthropic(), KEY, &none(), &mut |_| {}).unwrap();
    assert_eq!(result.content, "Hello there");
    assert_eq!(result.usage, AiTokenUsage::new(23, 7, 30));
    assert!(result.truncated);
    assert_eq!(transport.body(0)["stream"], true);
}

/// The API refuses a message without text; one is left after an empty reply.
#[test]
fn an_anthropic_request_leaves_out_messages_without_text() {
    let history = vec![
        AiMessage::new(Role::System, "rules"),
        AiMessage::new(Role::User, "make a clock"),
        AiMessage::new(Role::Assistant, ""),
        AiMessage::new(Role::User, " \n\t"),
        AiMessage::new(Role::User, "try again"),
    ];
    let (client, _) = client(Vec::new());
    for stream in [false, true] {
        let request = client.build_chat_request(&history, &anthropic(), KEY, stream).unwrap();
        let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        let sent: Vec<(&str, &str)> = body["messages"].as_array().unwrap().iter().map(|message| (message["role"].as_str().unwrap(), message["content"].as_str().unwrap())).collect();
        assert_eq!(sent, [("user", "make a clock"), ("user", "try again")]);
    }
    // Chat completions accepts them, as Swift sends them.
    let request = client.build_chat_request(&history, &openai(), KEY, false).unwrap();
    let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
    assert_eq!(body["messages"].as_array().unwrap().len(), 5);
}

/// An `error` event in the middle of the stream fails the request: the text before it is not a reply.
#[test]
fn an_error_event_in_an_anthropic_stream_fails_the_request() {
    let events = [
        r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"SUMMARY: half"}}"#,
        r#"{"type":"error","error":{"type":"overloaded_error","message":"secret text"}}"#,
    ];
    let transport = FakeTransport::streaming(vec![sse(&events)], 5);
    let error = AiClient::new(transport.clone()).chat_stream(&one_message(), &anthropic(), KEY, &none(), &mut |_| {}).unwrap_err();
    assert_eq!(error.kind, AiErrorKind::Http);
    assert_eq!(error.message, "The AI server reported an error (overloaded_error).");
    assert_eq!(transport.requests().len(), 1, "nothing is sent again");
    // Before any text too, and without a code that can be shown.
    let transport = FakeTransport::streaming(vec![sse(&[r#"{"type":"error","error":{"type":"not a code","message":"x"}}"#])], 5);
    let error = AiClient::new(transport.clone()).chat_stream(&one_message(), &anthropic(), KEY, &none(), &mut |_| {}).unwrap_err();
    assert_eq!(error.message, "The AI server reported an error.");
    assert_eq!(transport.requests().len(), 1);
    // A code that echoes the key is not shown.
    let transport = FakeTransport::streaming(vec![sse(&[&format!(r#"{{"type":"error","error":{{"type":"{KEY}"}}}}"#)])], 5);
    assert_no_key(&AiClient::new(transport).chat_stream(&one_message(), &anthropic(), KEY, &none(), &mut |_| {}).unwrap_err());
    // The same object in a chat-completions stream is not this event.
    let transport = FakeTransport::streaming(vec![sse(&[&delta("whole"), r#"{"type":"error"}"#])], 5);
    assert_eq!(AiClient::new(transport).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |_| {}).unwrap().content, "whole");
}

/// The event stream of the Messages API as a server writes it: `event:` lines, pings, a tool
/// block and CRLF line ends. The reader takes the `data:` lines and of those only the text.
#[test]
fn a_recorded_anthropic_stream_with_event_lines_is_read() {
    let recorded = concat!(
        "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"m\",\"stop_reason\":null,\"usage\":{\"input_tokens\":25,\"cache_creation_input_tokens\":4,\"cache_read_input_tokens\":1,\"output_tokens\":1}}}\r\n\r\n",
        "event: content_block_start\r\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\r\n\r\n",
        "event: ping\r\ndata: {\"type\": \"ping\"}\r\n\r\n",
        ": a comment line\r\n",
        "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"SUMMARY: Uhr.\\n```jsx\\n$render(<text>\"}}\r\n\r\n",
        "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"🕐</text>)\\n```\"}}\r\n\r\n",
        "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":\"}}\r\n\r\n",
        "event: content_block_stop\r\ndata: {\"type\":\"content_block_stop\",\"index\":0}\r\n\r\n",
        "event: message_delta\r\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":15}}\r\n\r\n",
        "event: message_stop\r\ndata: {\"type\":\"message_stop\"}"
    );
    // One byte at a time: a character that arrives in pieces is not broken.
    let mut reader = AiStreamReader::new(true);
    let mut seen: Vec<String> = Vec::new();
    for byte in recorded.as_bytes() {
        reader.feed(&[*byte], &mut |text| seen.push(text.to_owned())).unwrap();
    }
    reader.finish(&mut |_| {}).unwrap();
    assert_eq!(reader.text(), "SUMMARY: Uhr.\n```jsx\n$render(<text>🕐</text>)\n```");
    assert_eq!(reader.usage(), AiTokenUsage::new(30, 15, 45));
    assert!(reader.saw_event() && !reader.truncated() && !reader.refused());
    assert!(seen.iter().all(|text| reader.text().starts_with(text.as_str())));

    let mut refused = AiStreamReader::new(true);
    refused.feed(b"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n", &mut |_| {}).unwrap();
    assert!(refused.refused());
    let transport = FakeTransport::streaming(vec![sse(&[r#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#])], 5);
    assert_eq!(AiClient::new(transport).chat_stream(&one_message(), &anthropic(), KEY, &none(), &mut |_| {}).unwrap_err().kind, AiErrorKind::Refused);
}

/// Chat completions as servers write them: a role-only first chunk, null content, a
/// reasoning field next to the content, a line that is not JSON, and no usage at all.
#[test]
fn a_recorded_chat_completion_stream_is_read() {
    let recorded = concat!(
        "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n",
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":null,\"reasoning_content\":\"thinking about it\"},\"finish_reason\":null}]}\n\n",
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"$render(\"},\"finish_reason\":null}]}\n\n",
        "data: not json\n\n",
        "data:{\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"<vstack/>)\"},\"finish_reason\":\"length\"}]}\n\n",
        "data: [DONE]\n\n"
    );
    let mut reader = AiStreamReader::new(false);
    reader.feed(recorded.as_bytes(), &mut |_| {}).unwrap();
    reader.finish(&mut |_| {}).unwrap();
    assert_eq!(reader.text(), "$render(<vstack/>)");
    assert!(reader.truncated());
    assert_eq!(reader.usage(), AiTokenUsage::ZERO);
}

#[test]
fn a_stream_larger_than_the_limit_is_given_up() {
    let mut reader = AiStreamReader::new(false);
    // A line may be 1 MiB; the text of all lines together 4 MiB.
    let piece = format!("data: {}\n", delta(&"x".repeat(512 * 1024)));
    let mut result = Ok(());
    for _ in 0..9 {
        result = reader.feed(piece.as_bytes(), &mut |_| {});
        if result.is_err() {
            break;
        }
    }
    assert_eq!(result.unwrap_err().kind, AiErrorKind::ResponseTooLarge);
    assert!(reader.text().len() <= AiClient::MAXIMUM_RESPONSE_BYTES);
}

#[test]
fn a_server_that_will_not_stream_is_asked_in_the_plain_way() {
    let plain = r#"{"choices":[{"message":{"content":"plain reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2}}"#;
    // Refuses the streamed form with a 400, then answers the plain request.
    let refusing = FakeTransport::streaming(vec![AiHttpResponse::new(400, "{}"), AiHttpResponse::new(200, plain)], 7);
    let mut seen: Vec<String> = Vec::new();
    assert_eq!(AiClient::new(refusing.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |text| seen.push(text.to_owned())).unwrap().content, "plain reply");
    assert_eq!(refusing.requests().len(), 2);
    assert!(refusing.body(1).get("stream").is_none());
    // Ignores "stream" and answers with one JSON body: read as it is, no second request.
    let ignoring = FakeTransport::streaming(vec![AiHttpResponse::new(200, plain)], 7);
    assert_eq!(AiClient::new(ignoring.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |text| seen.push(text.to_owned())).unwrap().content, "plain reply");
    assert_eq!(ignoring.requests().len(), 1);
    assert_eq!(seen.last().map(String::as_str), Some("plain reply"));
}

#[test]
fn authentication_and_empty_streams_fail_without_the_key() {
    let rejected = AiClient::new(FakeTransport::streaming(vec![AiHttpResponse::new(401, "{}")], 7)).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |_| {}).unwrap_err();
    assert_eq!(rejected.kind, AiErrorKind::Http);
    assert!(!rejected.message.contains(KEY));
    let empty = AiClient::new(FakeTransport::streaming(vec![sse(&[r#"{"choices":[{"delta":{}}]}"#, "[DONE]"])], 7)).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |_| {}).unwrap_err();
    assert_eq!(empty.kind, AiErrorKind::EmptyResponse);
}

#[test]
fn a_transport_that_can_not_stream_still_returns_the_reply() {
    /// Only `execute`: the body is handed over once, at the end.
    struct Whole(AiHttpResponse);
    impl AiTransport for Whole {
        fn execute(&self, _: &AiHttpRequest, _: &AiCancellation) -> Canned {
            Ok(self.0.clone())
        }
    }
    let mut seen: Vec<String> = Vec::new();
    let transport = Whole(sse(&[&delta("whole "), &delta("reply"), "[DONE]"]));
    assert_eq!(AiClient::new(transport).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |text| seen.push(text.to_owned())).unwrap().content, "whole reply");
    assert_eq!(seen.last().map(String::as_str), Some("whole reply"));
}

#[test]
fn a_turn_reports_the_reply_as_it_is_written_and_other_modes_do_not() {
    struct Streaming;
    impl AiChat for Streaming {
        fn chat(&self, _: &[AiMessage], _: &AiCancellation) -> Result<AiChatResult, AiClientError> {
            Ok(AiChatResult::new("$render(<vstack/>)", AiTokenUsage::new(1, 1, 2)))
        }
        fn chat_stream(&self, _: &[AiMessage], _: &AiCancellation, on_text: &mut dyn FnMut(&str)) -> Result<AiChatResult, AiClientError> {
            on_text("SUMMARY: A");
            on_text("SUMMARY: A\n```jsx\n$render(");
            Ok(AiChatResult::new("SUMMARY: A\n```jsx\n$render(<vstack/>)\n```", AiTokenUsage::new(1, 1, 2)))
        }
    }
    let partials = |request: &AgentLoopRequest| {
        let mut partial: Vec<String> = Vec::new();
        AgentLoop::new(&Streaming).run(request, &mut |_, _| ok(), &none(), &mut |event| {
            if let AgentLoopEvent::Partial { text, .. } = event {
                partial.push(text.clone());
            }
        });
        partial
    };
    let partial = partials(&AgentLoopRequest { max_iterations: 2, ..turn_request(None, "a clock") });
    assert_eq!(partial.len(), 2);
    assert_eq!(PromptBuilder::preview_of_partial_reply(&partial[0].replace("SUMMARY: A", "```jsx")), "");
    assert_eq!(PromptBuilder::preview_of_partial_reply(&partial[1]), "$render(");
    assert_eq!(PromptBuilder::preview_of_partial_reply(&partial[0]), "SUMMARY: A");
    assert!(partials(&fresh("a clock", 2)).is_empty());
}

/// The bound chat is what the applications hand to the loop: the key reaches the header and nothing else.
#[test]
fn a_bound_chat_sends_the_key_in_the_header_only() {
    let body = r#"{"content":[{"type":"text","text":"$render(<vstack/>)"}],"usage":{"input_tokens":3,"output_tokens":2}}"#;
    let (client, transport) = client(vec![response(200, body)]);
    let chat = client.bind(anthropic(), KEY);
    let outcome = run(&chat, &fresh("a clock", 1), |_, _| ok());
    assert_eq!(succeeded(&outcome).0, "$render(<vstack/>)");
    let request = &transport.requests()[0];
    assert_eq!(request.header("x-api-key"), Some(KEY));
    assert!(!String::from_utf8_lossy(request.body.as_deref().unwrap()).contains(KEY));
    assert!(!request.url.contains(KEY));
}

/// A transport whose streamed exchange hands over `pieces` and then breaks off with `failure`,
/// and whose plain exchange answers with `plain`. Records every request.
#[derive(Clone)]
struct Breaking {
    pieces: Vec<String>,
    failure: AiClientError,
    plain: Canned,
    requests: Arc<Mutex<Vec<AiHttpRequest>>>,
}

impl Breaking {
    fn new(pieces: &[&str], failure: AiClientError, plain: Canned) -> Self {
        Self { pieces: pieces.iter().map(|piece| piece.to_string()).collect(), failure, plain, requests: Arc::default() }
    }

    /// Whether each request asked for a streamed reply.
    fn streamed(&self) -> Vec<bool> {
        self.requests.lock().unwrap().iter().map(|request| serde_json::from_slice::<Value>(request.body.as_deref().unwrap()).unwrap().get("stream").is_some()).collect()
    }
}

impl AiTransport for Breaking {
    fn execute(&self, request: &AiHttpRequest, _: &AiCancellation) -> Canned {
        self.requests.lock().unwrap().push(request.clone());
        self.plain.clone()
    }

    fn execute_streaming(&self, request: &AiHttpRequest, _: &AiCancellation, on_body: OnBody<'_>) -> Canned {
        self.requests.lock().unwrap().push(request.clone());
        for piece in &self.pieces {
            on_body(piece.as_bytes())?;
        }
        Err(self.failure.clone())
    }
}

/// Port of the last `catch` of `AIClient.chatStream`: a streamed request that failed in transport
/// is asked once more in the plain form, as long as nothing was received yet.
#[test]
fn a_stream_that_fails_before_any_text_is_asked_once_more_in_the_plain_way() {
    let plain = r#"{"choices":[{"message":{"content":"plain reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#;
    let unreachable = || AiClientError::new(AiErrorKind::Network, "The AI server could not be reached. Check your connection and try again.");
    let timeout = || AiClientError::new(AiErrorKind::Timeout, "The AI server did not answer in time. Try again.");
    let ask = |transport: &Breaking, seen: &mut Vec<String>| AiClient::new(transport.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |text| seen.push(text.to_owned()));

    for failure in [unreachable(), timeout()] {
        // Nothing arrived, and events without text arrived: the plain request is the reply.
        for pieces in [&[][..], &["data: {\"choices\":[{\"delta\":{}}]}\n\n"]] {
            let transport = Breaking::new(pieces, failure.clone(), response(200, plain));
            let mut seen = Vec::new();
            let result = ask(&transport, &mut seen).unwrap();
            assert_eq!((result.content.as_str(), result.usage.total_tokens), ("plain reply", 6));
            assert_eq!(transport.streamed(), [true, false], "one streamed request, then one plain request");
            assert_eq!(seen, ["plain reply"]);
        }
    }

    // Once only: when the plain request fails too, its failure is the answer.
    let transport = Breaking::new(&[], unreachable(), Err(timeout()));
    assert_eq!(ask(&transport, &mut Vec::new()).unwrap_err(), timeout());
    assert_eq!(transport.streamed(), [true, false]);
    // The plain request's own refusal is reported as it is.
    let transport = Breaking::new(&[], unreachable(), response(401, "{}"));
    let refused = ask(&transport, &mut Vec::new()).unwrap_err();
    assert_eq!((refused.kind, refused.http_status), (AiErrorKind::Http, Some(401)));
}

#[test]
fn a_stream_is_never_asked_again_after_text_arrived_or_for_a_refusal() {
    let plain = r#"{"choices":[{"message":{"content":"another answer"},"finish_reason":"stop"}]}"#;
    let unreachable = AiClientError::new(AiErrorKind::Network, "The AI server could not be reached. Check your connection and try again.");
    // Text already shown must not be replaced by a second, different answer.
    let first = format!("data: {}\n\n", delta("$render("));
    let broken = Breaking::new(&[&first], unreachable.clone(), response(200, plain));
    let mut seen: Vec<String> = Vec::new();
    let error = AiClient::new(broken.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |text| seen.push(text.to_owned())).unwrap_err();
    assert_eq!(error, unreachable);
    assert_eq!((broken.streamed(), seen), (vec![true], vec!["$render(".to_owned()]));

    // Authentication and the usage limit are answers, not broken connections: reported, never asked again.
    for status in [401, 403, 429] {
        let transport = FakeTransport::streaming(vec![AiHttpResponse::new(status, "{}"), AiHttpResponse::new(200, plain)], 7);
        let error = AiClient::new(transport.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |_| {}).unwrap_err();
        assert_eq!((error.kind, error.http_status), (AiErrorKind::Http, Some(status)));
        assert_eq!(transport.requests().len(), 1, "{status}");
    }
    // Neither is what is no failure of the connection: a redirect, a profile that cannot be used, a reply too large, a stop.
    for failure in [
        AiClientError::with_status(AiErrorKind::Http, "The AI server answered with a redirect, which is not followed. Check the API base URL.", 302),
        AiClientError::new(AiErrorKind::InvalidProfile, "The API base URL must start with https://."),
        AiClientError::new(AiErrorKind::ResponseTooLarge, "The AI response exceeded the size limit."),
        AiClientError::cancelled(),
    ] {
        let transport = Breaking::new(&[], failure.clone(), response(200, plain));
        assert_eq!(AiClient::new(transport.clone()).chat_stream(&one_message(), &openai(), KEY, &none(), &mut |_| {}).unwrap_err(), failure);
        assert_eq!(transport.streamed(), [true]);
    }
    // The user stopped the turn while the connection failed: nothing more is sent.
    #[derive(Clone)]
    struct Stopping(AiCancellation, Arc<Mutex<usize>>);
    impl AiTransport for Stopping {
        fn execute(&self, _: &AiHttpRequest, _: &AiCancellation) -> Canned {
            *self.1.lock().unwrap() += 1;
            Err(AiClientError::new(AiErrorKind::Network, "The AI request could not be sent."))
        }
        fn execute_streaming(&self, request: &AiHttpRequest, cancellation: &AiCancellation, _: OnBody<'_>) -> Canned {
            self.0.cancel();
            self.execute(request, cancellation)
        }
    }
    let stopping = Stopping(AiCancellation::new(), Arc::default());
    assert_eq!(AiClient::new(stopping.clone()).chat_stream(&one_message(), &openai(), KEY, &stopping.0, &mut |_| {}).unwrap_err().kind, AiErrorKind::Network);
    assert_eq!(*stopping.1.lock().unwrap(), 1);
}
