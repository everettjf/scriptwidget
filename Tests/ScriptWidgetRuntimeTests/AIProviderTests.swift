//
//  AIProviderTests.swift
//  ScriptWidgetRuntimeTests
//
//  The AI client against stub servers: redirects, the two API styles, replies
//  that were cut off, refused or empty, and what a key may contain. No
//  network, no real key.
//

import XCTest
@testable import ScriptWidget

final class AIProviderTests: XCTestCase {

    private static let secret = "sk-provider-secret-4c1d"
    private var urlSession: URLSession!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProviderStub.self]
        urlSession = URLSession(configuration: configuration)
        RedirectingProviderStub.reset()
        ScriptedProviderStub.reset()
    }

    override func tearDown() {
        urlSession.invalidateAndCancel()
        RedirectingProviderStub.reset()
        ScriptedProviderStub.reset()
    }

    private func openAISettings(host: String) -> AISettings {
        var profile = AIProfile.makeDefault()
        profile.baseURL = "http://\(host)"
        profile.model = "stub-model"
        profile.apiKey = Self.secret
        return AISettings(profile: profile, maxIterations: 1, temperature: 0)
    }

    private let ping = [AIMessage(role: .user, content: "ping")]

    // MARK: - redirects

    /// A redirect could carry the key to another host, so none is followed.
    func testChatDoesNotFollowARedirect() async {
        let client = AIClient(session: urlSession)
        do {
            _ = try await client.chat(messages: ping, settings: openAISettings(host: "redirect.test"))
            XCTFail("a redirect must not end as a reply")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("redirect"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(Self.secret))
        }
        XCTAssertEqual(RedirectingProviderStub.requests(to: "redirect.test"), 1)
        XCTAssertEqual(RedirectingProviderStub.requests(to: "elsewhere.test"), 0, "the redirect target must never be asked")
        XCTAssertFalse(RedirectingProviderStub.keySeenElsewhere)
    }

    func testStreamedChatDoesNotFollowARedirectAndDoesNotAskAgain() async {
        let client = AIClient(session: urlSession)
        do {
            _ = try await client.chatStream(messages: ping, settings: openAISettings(host: "redirect.test")) { _ in }
            XCTFail("a redirect must not end as a reply")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("redirect"), error.localizedDescription)
        }
        XCTAssertEqual(RedirectingProviderStub.requests(to: "redirect.test"), 1, "a redirect is not a reason to ask in the plain form")
        XCTAssertEqual(RedirectingProviderStub.requests(to: "elsewhere.test"), 0)
        XCTAssertFalse(RedirectingProviderStub.keySeenElsewhere)
    }

    func testModelListDoesNotFollowARedirect() async {
        let client = AIClient(session: urlSession)
        do {
            _ = try await client.availableModels(profile: openAISettings(host: "redirect.test").profile)
            XCTFail("a redirect must not end as a model list")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(Self.secret))
        }
        XCTAssertEqual(RedirectingProviderStub.requests(to: "elsewhere.test"), 0)
        XCTAssertFalse(RedirectingProviderStub.keySeenElsewhere)
    }

    /// The Messages API key travels in `x-api-key`, which no system strips.
    func testAnthropicRequestsDoNotFollowARedirect() async {
        let client = AIClient(session: urlSession)
        let settings = anthropicSettings(host: "redirect.test")
        for streamed in [false, true] {
            do {
                if streamed {
                    _ = try await client.chatStream(messages: ping, settings: settings) { _ in }
                } else {
                    _ = try await client.chat(messages: ping, settings: settings)
                }
                XCTFail("a redirect must not end as a reply")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("redirect"), error.localizedDescription)
            }
        }
        _ = try? await client.availableModels(profile: settings.profile)
        XCTAssertEqual(RedirectingProviderStub.requests(to: "redirect.test"), 3)
        XCTAssertEqual(RedirectingProviderStub.requests(to: "elsewhere.test"), 0)
        XCTAssertFalse(RedirectingProviderStub.keySeenElsewhere)
    }

    // MARK: - request shape

    private func anthropicSettings(host: String = "anthropic.test") -> AISettings {
        var profile = AIProfile.makeAnthropic()
        profile.baseURL = "http://\(host)"
        profile.apiKey = Self.secret
        return AISettings(profile: profile, maxIterations: 1, temperature: 0.7)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testAnthropicPresetIsTheOneAndroidHas() {
        let profile = AIProfile.makeAnthropic()
        XCTAssertEqual(profile.providerKind, .anthropic)
        XCTAssertEqual(profile.normalizedBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(profile.model, "claude-fable-5-2")
        XCTAssertEqual(AIProfile.anthropicSuggestedModels, ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(profile.authMethod, .apiKey)
        XCTAssertFalse(profile.isConfigured, "a key is needed")
        var keyed = profile
        keyed.apiKey = Self.secret
        XCTAssertTrue(keyed.isConfigured)
        keyed.baseURL = "https://api.anthropic.com/v1/messages"
        XCTAssertNil(keyed.endpointURL, "the base URL only, without the endpoint path")
        keyed.baseURL = ""
        XCTAssertEqual(keyed.normalizedBaseURL, "https://api.anthropic.com")
    }

    func testAnthropicProfileRoundTripsWithoutItsKey() throws {
        var profile = AIProfile.makeAnthropic()
        profile.apiKey = Self.secret
        let data = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Self.secret))
        let decoded = try JSONDecoder().decode(AIProfile.self, from: data)
        XCTAssertEqual(decoded.providerKind, .anthropic)
        XCTAssertEqual(decoded.apiKey, "", "the key lives in the Keychain")
    }

    func testAnthropicRequestUsesTheMessagesAPIShape() async throws {
        let messages = [
            AIMessage(role: .system, content: "SYSTEM A"),
            AIMessage(role: .user, content: "make a clock"),
            AIMessage(role: .assistant, content: ""),
            AIMessage(role: .system, content: "SYSTEM B"),
            AIMessage(role: .user, content: "fix it"),
        ]
        let request = try await AIClient().makeChatRequest(messages: messages, settings: anthropicSettings(), stream: false)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://anthropic.test/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), Self.secret)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.url?.absoluteString.contains(Self.secret) ?? true)

        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-fable-5-2")
        XCTAssertEqual(json["max_tokens"] as? Int, 16_000)
        XCTAssertEqual(json["system"] as? String, "SYSTEM A\n\nSYSTEM B")
        // Sampling parameters are not sent: current Claude models reject them.
        for key in ["temperature", "top_p", "top_k", "stream", "stream_options"] { XCTAssertNil(json[key], key) }
        let sent = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(sent, [
            ["role": "user", "content": "make a clock"],
            ["role": "user", "content": "fix it"],
        ], "no system message and no message without text")
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains(Self.secret))

        let streamed = try await AIClient().makeChatRequest(messages: messages, settings: anthropicSettings(), stream: true)
        XCTAssertEqual(try body(streamed)["stream"] as? Bool, true)
        XCTAssertNil(try body(streamed)["stream_options"])
        XCTAssertEqual(streamed.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testOpenAIRequestUsesTheChatCompletionsShape() async throws {
        let messages = [AIMessage(role: .system, content: "SYSTEM"), AIMessage(role: .user, content: "make a clock")]
        let request = try await AIClient().makeChatRequest(messages: messages, settings: openAISettings(host: "openai.test"), stream: true)
        XCTAssertEqual(request.url?.absoluteString, "http://openai.test/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + Self.secret)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "stub-model")
        XCTAssertEqual(json["temperature"] as? Double, 0)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertNil(json["max_tokens"])
        XCTAssertEqual((json["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }, ["system", "user"])
    }

    // MARK: - what a key may contain

    func testKeyIsTrimmedAndMustBePrintableASCIIOfAtMost4096Characters() throws {
        XCTAssertEqual(try AIClient.validatedKey("  sk-abc_123.~ \n"), "sk-abc_123.~")
        XCTAssertEqual(try AIClient.validatedKey(String(repeating: "k", count: 4_096)).count, 4_096)
        XCTAssertThrowsError(try AIClient.validatedKey("   ")) { XCTAssertEqual($0 as? AIClientError, .missingAPIKey) }
        // A line break inside a key could start another header.
        for bad in ["sk-abc\r\nX-Injected: 1", "sk-abc\tdef", "sk-abc\u{7F}", "sk-密钥", "sk-abc\u{0}", String(repeating: "k", count: 4_097)] {
            XCTAssertThrowsError(try AIClient.validatedKey(bad), bad.prefix(12).debugDescription) {
                XCTAssertEqual($0 as? AIClientError, .invalidAPIKey)
                XCTAssertEqual($0.localizedDescription, "The API key contains characters that are not allowed.")
            }
        }
    }

    func testUnsafeKeyIsRejectedBeforeAnyRequest() async {
        ScriptedProviderStub.enqueue(200, #"{"choices":[{"message":{"content":"pong"}}]}"#)
        let client = AIClient(session: scriptedSession())
        for kind in ["openai", "anthropic"] {
            var settings = kind == "openai" ? openAISettings(host: "scripted.test") : anthropicSettings(host: "scripted.test")
            settings.profile.apiKey = "sk-abc\r\nX-Injected: 1"
            do {
                _ = try await client.chat(messages: ping, settings: settings)
                XCTFail("an unsafe key must not be sent")
            } catch {
                XCTAssertEqual(error as? AIClientError, .invalidAPIKey)
            }
            do {
                _ = try await client.availableModels(profile: settings.profile)
                XCTFail("an unsafe key must not be sent")
            } catch {
                XCTAssertEqual(error as? AIClientError, .invalidAPIKey)
            }
        }
        XCTAssertTrue(ScriptedProviderStub.requests.isEmpty)
    }

    // MARK: - reading a whole reply

    private func parse(_ kind: AIProviderKind, _ json: String) throws -> AIChatResult {
        try AIClient.parseChatResponse(kind: kind, data: Data(json.utf8))
    }

    private func failure(_ kind: AIProviderKind, _ json: String) -> AIClientError? {
        do { _ = try parse(kind, json); return nil } catch { return error as? AIClientError }
    }

    func testParsesAnthropicTextBlocksAndUsage() throws {
        let result = try parse(.anthropic, #"{"type":"message","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Hello "},{"type":"tool_use","id":"t","name":"n","input":{}},{"type":"text","text":"there"}],"stop_reason":"end_turn","usage":{"input_tokens":20,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":7}}"#)
        XCTAssertEqual(result.content, "Hello there")
        XCTAssertEqual(result.usage, AITokenUsage(promptTokens: 25, completionTokens: 7, totalTokens: 32))
        XCTAssertFalse(result.truncated)
    }

    func testAnthropicMaxTokensStopIsReportedAsTruncated() throws {
        XCTAssertTrue(try parse(.anthropic, #"{"content":[{"type":"text","text":"$render(<vstack>"}],"stop_reason":"max_tokens"}"#).truncated)
    }

    func testAnthropicRefusalAndEmptyContentFail() {
        XCTAssertEqual(failure(.anthropic, #"{"content":[{"type":"text","text":"I can not help with that."}],"stop_reason":"refusal"}"#), .refused)
        XCTAssertEqual(AIClientError.refused.localizedDescription, "The model declined this request. Rephrase the description and try again.")
        XCTAssertEqual(failure(.anthropic, #"{"content":[{"type":"thinking","thinking":"hidden"}],"stop_reason":"end_turn"}"#), .emptyResponse)
        XCTAssertEqual(failure(.anthropic, #"{"content":[{"type":"text","text":"  \n"}],"stop_reason":"end_turn"}"#), .emptyResponse)
    }

    func testParsesChatCompletionAndUsage() throws {
        let result = try parse(.openAICompatible, #"{"choices":[{"message":{"role":"assistant","content":"$render(<vstack/>)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#)
        XCTAssertEqual(result.content, "$render(<vstack/>)")
        XCTAssertEqual(result.usage, AITokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15), "a missing total is the sum")
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(try parse(.ollama, #"{"choices":[{"message":{"content":"$render(<vstack>"},"finish_reason":"length"}]}"#).truncated)
    }

    func testChatCompletionWithoutContentIsEmpty() {
        XCTAssertEqual(failure(.openAICompatible, #"{"choices":[{"message":{"content":null,"refusal":"no"},"finish_reason":"stop"}]}"#), .emptyResponse)
        XCTAssertEqual(failure(.openAICompatible, #"{"choices":[{"message":{"content":"   "},"finish_reason":"stop"}]}"#), .emptyResponse)
    }

    func testMalformedJSONFailsClosed() {
        for body in ["", "not json", "[1,2]", #"{"choices":[]}"#, #"{"choices":"x"}"#] {
            XCTAssertEqual(failure(.openAICompatible, body), .upstream(AIClient.unreadableResponse), body)
        }
        XCTAssertEqual(failure(.anthropic, #"{"stop_reason":"end_turn"}"#), .upstream(AIClient.unreadableResponse))
    }

    func testErrorObjectInASuccessfulResponseIsAnErrorWithItsCodeOnly() {
        XCTAssertEqual(failure(.anthropic, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded, body text"}}"#),
                       .upstream("The AI server reported an error (overloaded_error)."))
        XCTAssertEqual(failure(.openAICompatible, #"{"error":{"message":"free text with spaces","code":"model_not_found"}}"#),
                       .upstream("The AI server reported an error (model_not_found)."))
        // A code that is not a short machine word is not shown.
        XCTAssertEqual(failure(.openAICompatible, #"{"error":{"type":"free text with spaces"}}"#),
                       .upstream("The AI server reported an error."))
    }

    // MARK: - reading a stream (recorded event shapes)

    private func read(_ reader: inout AIStreamReader, _ events: [String]) throws -> [String] {
        var seen: [String] = []
        for event in events where try reader.read(line: "data: " + event) { seen.append(reader.text) }
        return seen
    }

    func testOpenAIStreamIsReadAsItArrivesAndEndsAsOneText() throws {
        var reader = AIStreamReader(anthropic: false)
        let seen = try read(&reader, [
            #"{"choices":[{"delta":{"content":"SUMMARY: 你好。\n"}}]}"#,
            #"{"choices":[{"delta":{"content":"```jsx\n$render("}}]}"#,
            #"{"choices":[{"delta":{"content":"<vstack/>)\n```"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#,
            "[DONE]",
        ])
        let whole = "SUMMARY: 你好。\n```jsx\n$render(<vstack/>)\n```"
        XCTAssertEqual(reader.text, whole)
        XCTAssertEqual(reader.usage, AITokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15))
        XCTAssertFalse(reader.truncated)
        XCTAssertTrue(reader.sawEvent)
        XCTAssertEqual(seen.count, 3)
        XCTAssertTrue(seen.allSatisfy { whole.hasPrefix($0) }, "every report is the text so far")
    }

    func testOpenAIStreamCutOffAtTheLimitIsTruncated() throws {
        var reader = AIStreamReader(anthropic: false)
        _ = try read(&reader, [#"{"choices":[{"delta":{"content":"$render(<vstack>"}}]}"#, #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#])
        XCTAssertTrue(reader.truncated)
    }

    func testAnthropicStreamKeepsOnlyTheTextAndCountsTokens() throws {
        var reader = AIStreamReader(anthropic: true)
        // Lines that are not data, and an event that can not be read, change nothing.
        XCTAssertFalse(try reader.read(line: "event: message_start"))
        XCTAssertFalse(try reader.read(line: ": keep-alive"))
        XCTAssertFalse(try reader.read(line: "data: {broken"))
        XCTAssertFalse(reader.sawEvent)
        _ = try read(&reader, [
            #"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":3}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}"#,
            #"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"there"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertEqual(reader.text, "Hello there")
        XCTAssertEqual(reader.usage, AITokenUsage(promptTokens: 23, completionTokens: 7, totalTokens: 30))
        XCTAssertTrue(reader.truncated)
        XCTAssertFalse(reader.refused)
    }

    func testAnthropicStreamReportsARefusalAndAnErrorEvent() throws {
        var refused = AIStreamReader(anthropic: true)
        _ = try read(&refused, [
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"I can not"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}"#,
        ])
        XCTAssertTrue(refused.refused)

        var broken = AIStreamReader(anthropic: true)
        XCTAssertThrowsError(try read(&broken, [
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"$render("}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ])) { XCTAssertEqual($0 as? AIClientError, .upstream("The AI server reported an error (overloaded_error).")) }
    }

    // MARK: - against a stub server

    private func scriptedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProviderStub.self]
        return URLSession(configuration: configuration)
    }

    private static func events(_ events: [String]) -> String { events.map { "event: x\ndata: \($0)\n\n" }.joined() }

    func testAnthropicChatIsReadInBothFormsWithItsOwnHeaders() async throws {
        ScriptedProviderStub.enqueue(200, #"{"content":[{"type":"text","text":"pong"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":1}}"#)
        ScriptedProviderStub.enqueue(200, Self.events([
            #"{"type":"message_start","message":{"usage":{"input_tokens":4}}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"po"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"ng"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
            #"{"type":"message_stop"}"#,
        ]), contentType: "text/event-stream")
        ScriptedProviderStub.enqueue(200, #"{"data":[{"id":"claude-b"},{"id":"claude-a"},{"id":"claude-a"}],"has_more":false}"#)
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        let settings = anthropicSettings(host: "scripted.test")

        let plain = try await client.chat(messages: ping, settings: settings)
        XCTAssertEqual(plain.content, "pong")
        XCTAssertEqual(plain.usage.totalTokens, 5)

        let collected = TextCollector()
        let streamed = try await client.chatStream(messages: ping, settings: settings) { await collected.append($0) }
        XCTAssertEqual(streamed.content, "pong")
        XCTAssertEqual(streamed.usage, AITokenUsage(promptTokens: 4, completionTokens: 2, totalTokens: 6))
        XCTAssertFalse(streamed.truncated)
        let seen = await collected.texts
        XCTAssertEqual(seen.last, "pong")

        let models = try await client.availableModels(profile: settings.profile)
        XCTAssertEqual(models, ["claude-a", "claude-b"])

        let requests = ScriptedProviderStub.requests
        XCTAssertEqual(requests.map(\.path), ["/v1/messages", "/v1/messages", "/v1/models"])
        XCTAssertEqual(requests[2].query, "limit=1000")
        for request in requests {
            XCTAssertEqual(request.headers["x-api-key"], Self.secret)
            XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
            XCTAssertNil(request.headers["Authorization"])
        }
    }

    func testAnthropicRefusalIsReportedAsRefusedInBothForms() async {
        ScriptedProviderStub.enqueue(200, #"{"content":[],"stop_reason":"refusal"}"#)
        ScriptedProviderStub.enqueue(200, Self.events([
            #"{"type":"message_start","message":{"usage":{"input_tokens":4}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#,
        ]), contentType: "text/event-stream")
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        let settings = anthropicSettings(host: "scripted.test")
        do { _ = try await client.chat(messages: ping, settings: settings); XCTFail("refused") } catch { XCTAssertEqual(error as? AIClientError, .refused) }
        do { _ = try await client.chatStream(messages: ping, settings: settings) { _ in }; XCTFail("refused") } catch { XCTAssertEqual(error as? AIClientError, .refused) }
        XCTAssertEqual(ScriptedProviderStub.requests.count, 2, "a refusal is not asked again in the plain form")
    }

    func testAgentLoopEndsARefusedRequestWithoutRepairing() async {
        ScriptedProviderStub.enqueue(200, #"{"content":[],"stop_reason":"refusal"}"#)
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        let request = AgentLoopRequest(mode: .fresh(userDescription: "a clock"), size: .small,
                                       settings: anthropicSettings(host: "scripted.test"), maxIterations: 4)
        let outcome = await AgentLoop(client: AIClient(session: session)).run(request) { _ in }
        guard case .failed(let message, _) = outcome else { return XCTFail("a refusal ends the run") }
        XCTAssertEqual(message, "The model declined this request. Rephrase the description and try again.")
        XCTAssertEqual(ScriptedProviderStub.requests.count, 1)
    }

    func testAnthropicStreamCutOffAtTheLimitIsTruncated() async throws {
        ScriptedProviderStub.enqueue(200, Self.events([
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"$render(<vstack>"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":16000}}"#,
        ]), contentType: "text/event-stream")
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        let result = try await AIClient(session: session).chatStream(messages: ping, settings: anthropicSettings(host: "scripted.test")) { _ in }
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.content, "$render(<vstack>")
    }

    /// A server that ignores "stream" and answers with one JSON body is read as it is.
    func testPlainBodyAnsweringAStreamedRequestIsReadWithoutASecondRequest() async throws {
        ScriptedProviderStub.enqueue(200, "{\n  \"choices\": [\n    {\"message\": {\"content\": \"plain reply\"}, \"finish_reason\": \"length\"}\n  ],\n  \"usage\": {\"prompt_tokens\": 1, \"completion_tokens\": 2}\n}")
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        let collected = TextCollector()
        let result = try await AIClient(session: session).chatStream(messages: ping, settings: openAISettings(host: "scripted.test")) { await collected.append($0) }
        XCTAssertEqual(result.content, "plain reply")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.usage.totalTokens, 3)
        XCTAssertEqual(ScriptedProviderStub.requests.count, 1)
        let seen = await collected.texts
        XCTAssertEqual(seen, ["plain reply"])
    }

    func testHTTPErrorsAreFixedTextWithTheStatusAndAShortCodeOnly() async {
        ScriptedProviderStub.enqueue(500, #"{"type":"error","error":{"type":"api_error","message":"body text \#(Self.secret)"}}"#)
        ScriptedProviderStub.enqueue(401, #"{"error":{"message":"bad key \#(Self.secret)"}}"#)
        ScriptedProviderStub.enqueue(400, "<html>not json</html>")
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        var messages: [String] = []
        for _ in 0..<3 {
            do { _ = try await client.chat(messages: ping, settings: anthropicSettings(host: "scripted.test")) } catch { messages.append(error.localizedDescription) }
        }
        XCTAssertEqual(messages, [
            "The AI server could not complete the request (HTTP 500) (api_error).",
            "The AI server rejected authentication. Check this profile's credentials.",
            "The AI server could not complete the request (HTTP 400).",
        ])
    }

    /// An error code is the one place a server could echo the key into a message.
    func testErrorCodeThatEchoesTheKeyIsScrubbed() async {
        ScriptedProviderStub.enqueue(500, #"{"error":{"type":"\#(Self.secret)"}}"#)
        let session = scriptedSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIClient(session: session).chat(messages: ping, settings: openAISettings(host: "scripted.test"))
            XCTFail("HTTP 500 is not a reply")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The AI request failed.")
        }
    }
}

/// `redirect.test` answers every request with a redirect to `elsewhere.test`,
/// which answers like a provider and records what reached it.
final class RedirectingProviderStub: URLProtocol {
    private static let lock = NSLock()
    private static var hosts: [String] = []
    private static var leaked = false

    static func requests(to host: String) -> Int { lock.withLock { hosts.filter { $0 == host }.count } }
    /// True when a request to the redirect target carried a credential header.
    static var keySeenElsewhere: Bool { lock.withLock { leaked } }
    static func reset() { lock.withLock { hosts = []; leaked = false } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["redirect.test", "elsewhere.test"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let hasKey = request.value(forHTTPHeaderField: "Authorization") != nil
            || request.value(forHTTPHeaderField: "x-api-key") != nil
        Self.lock.withLock {
            Self.hosts.append(host)
            if host == "elsewhere.test", hasKey { Self.leaked = true }
        }
        if host == "redirect.test" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = "elsewhere.test"
            guard let target = components?.url, let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": target.absoluteString]
            ) else { return }
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // When the redirect is refused, the redirect itself is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: String
        if url.path.hasSuffix("/models") {
            body = #"{"data":[{"id":"stolen-model"}]}"#
        } else if (request.value(forHTTPHeaderField: "Accept") ?? "").contains("event-stream") {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"stolen\"}}]}\n\ndata: [DONE]\n\n"
        } else {
            body = #"{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"stolen"},"finish_reason":"stop"}]}"#
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor TextCollector {
    private(set) var texts: [String] = []
    func append(_ text: String) { texts.append(text) }
}

/// `scripted.test` answers from a queue and records what it was asked.
final class ScriptedProviderStub: URLProtocol {
    struct Recorded {
        let path: String
        let query: String?
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var queue: [(status: Int, body: String, contentType: String)] = []
    private static var recorded: [Recorded] = []

    static var requests: [Recorded] { lock.withLock { recorded } }
    static func enqueue(_ status: Int, _ body: String, contentType: String = "application/json") {
        lock.withLock { queue.append((status, body, contentType)) }
    }
    static func reset() { lock.withLock { queue = []; recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "scripted.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let next = Self.lock.withLock { () -> (status: Int, body: String, contentType: String) in
            Self.recorded.append(Recorded(path: url.path, query: url.query, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.queue.isEmpty ? (503, "{}", "application/json") : Self.queue.removeFirst()
        }
        guard let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil,
                                             headerFields: ["Content-Type": next.contentType]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The texts of the AI surfaces. The apps are English only; the table holds
/// the singular and plural forms and is read from the app that hosts the tests.
final class AILocalizationTests: XCTestCase {

    private func table(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "the app has no \(language).lproj")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func text(_ key: String, _ language: String, _ arguments: CVarArg...) throws -> String {
        let format = try table(language).localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }

    /// The interface is English only, whatever language the system uses.
    func testAppHasEnglishOnly() {
        XCTAssertEqual(Set(Bundle.main.localizations).subtracting(["Base"]), ["en"])
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        func chosen(_ preferred: [String]) -> String? {
            Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferred).first
        }
        for preferred in [["en-GB"], ["zh-Hans-CN", "en-US"], ["fr-FR"], ["ja-JP", "zh-Hans-CN"]] {
            XCTAssertEqual(chosen(preferred), "en", preferred.joined(separator: ", "))
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.resourcePath ?? "")) ?? []
        XCTAssertEqual(Set(folders.filter { $0.hasSuffix(".lproj") }).subtracting(["Base.lproj"]), ["en.lproj"])
    }

    func testCountsHaveSingularAndPluralFormsInEnglish() throws {
        XCTAssertEqual(try text("Fixed automatically %lld times", "en", 1), "Fixed automatically 1 time")
        XCTAssertEqual(try text("Fixed automatically %lld times", "en", 3), "Fixed automatically 3 times")
        XCTAssertEqual(try text("⋯ %lld unchanged lines", "en", 1), "⋯ 1 unchanged line")
        XCTAssertEqual(try text("⋯ %lld unchanged lines", "en", 12), "⋯ 12 unchanged lines")
        XCTAssertEqual(try text("%lld lines added, %lld removed", "en", 1, 2), "1 line added, 2 removed")
        XCTAssertEqual(try text("%lld lines added, %lld removed", "en", 4, 1), "4 lines added, 1 removed")
        XCTAssertEqual(try text("%lld lines added, %lld removed. Show the changes.", "en", 1, 0), "1 line added, 0 removed. Show the changes.")
        XCTAssertEqual(try text("%lld tokens", "en", 1), "1 token")
        XCTAssertEqual(try text("%lld tokens", "en", 312), "312 tokens")
        XCTAssertEqual(try text("%lld versions · %@", "en", 1, "today"), "1 version · today")
        XCTAssertEqual(try text("%lld versions · %@", "en", 2, "today"), "2 versions · today")
    }
}
