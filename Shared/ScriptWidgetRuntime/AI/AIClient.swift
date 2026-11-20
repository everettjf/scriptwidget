//
//  AIClient.swift
//  ScriptWidget
//
//  Chat against an OpenAI-compatible chat-completions endpoint, the Anthropic
//  Messages API or Apple Private Cloud Compute, as configured in AISettings.
//  The Kotlin port is AiClient, the Rust port is ai/client.rs.
//
//  The credential is placed in a request header and nowhere else, and no
//  redirect is followed: a redirect could carry that header to another host.
//  An error's text is fixed text plus, at most, the HTTP status and a short
//  error code of the provider; never the credential and never a response body.
//

import Foundation
import SwiftOpenAI
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AITokenUsage: Equatable, Codable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    static let zero = AITokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)

    static func + (lhs: AITokenUsage, rhs: AITokenUsage) -> AITokenUsage {
        AITokenUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }
}

struct AIChatResult {
    let content: String
    let usage: AITokenUsage
    /// True when the provider stopped at its output limit: the text is not whole.
    var truncated = false
}

enum AIClientError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidBaseURL(String)
    case emptyResponse
    case refused
    case appleIntelligenceUnavailable(String)
    case quotaLimitReached(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is not set. Open Settings → AI to configure it."
        case .invalidAPIKey:
            return "The API key contains characters that are not allowed."
        case .invalidBaseURL(let url):
            return "Base URL is invalid: \(url)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .refused:
            return "The model declined this request. Rephrase the description and try again."
        case .appleIntelligenceUnavailable(let reason):
            return "Apple Intelligence is unavailable: \(reason)"
        case .quotaLimitReached(let details):
            return "Apple Private Cloud Compute's daily quota has been exhausted. \(details) You can also switch to an OpenAI-compatible profile in Settings → AI."
        case .upstream(let message):
            return message
        }
    }
}

/// Refuses every redirect. A request that carries a credential is made with
/// this delegate, so that the credential can only reach the host it was
/// written for; the redirect itself comes back as the response.
final class AINoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor AIClient {
    static let shared = AIClient()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    static let anthropicVersion = "2023-06-01"
    /// Room for a full widget plus the model's own reasoning.
    static let anthropicMaxTokens = 16_000
    static let maximumKeyLength = 4_096
    static let maximumResponseBytes = 4 * 1_048_576

    func chat(messages: [AIMessage], settings: AISettings) async throws -> AIChatResult {
        if settings.providerKind == .applePrivateCloudCompute {
            return try await applePrivateCloudComputeChat(messages: messages, settings: settings)
        }
        let request = try await makeChatRequest(messages: messages, settings: settings, stream: false)
        do {
            let (data, httpResponse) = try await session.data(for: request, delegate: AINoRedirectDelegate())
            guard let http = httpResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try Self.checkStatus(http.statusCode, body: data)
            return try Self.parseChatResponse(kind: settings.providerKind, data: data)
        } catch let error as AIClientError {
            throw Self.scrubbed(error, of: request)
        } catch {
            throw Self.scrubbed(.upstream(error.localizedDescription), of: request)
        }
    }

    /// The same request as `chat`, read as it is written. `onText` receives the
    /// whole text so far, no more often than every 80 ms and once at the end.
    ///
    /// A server that refuses or garbles the streamed form is asked again in the
    /// plain form, as long as nothing was received yet; one that ignores
    /// "stream" and answers with one JSON body is read as it is. Authentication,
    /// rate limit, a redirect and cancellation are reported as they are. Apple
    /// Private Cloud Compute answers in one piece.
    func chatStream(
        messages: [AIMessage],
        settings: AISettings,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> AIChatResult {
        if settings.providerKind == .applePrivateCloudCompute {
            let result = try await applePrivateCloudComputeChat(messages: messages, settings: settings)
            await onText(result.content)
            return result
        }
        let request = try await makeChatRequest(messages: messages, settings: settings, stream: true)
        var reader = AIStreamReader(anthropic: settings.providerKind == .anthropic)
        do {
            let (bytes, httpResponse) = try await session.bytes(for: request, delegate: AINoRedirectDelegate())
            guard let http = httpResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if [401, 403, 429].contains(http.statusCode) || (300..<400).contains(http.statusCode) {
                try Self.checkStatus(http.statusCode)
            }
            guard (200..<300).contains(http.statusCode) else { throw StreamUnusable() }
            var lastSent = Date.distantPast
            // A body that is not an event stream: the server ignored "stream".
            var plain: [String] = []
            var plainBytes = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else {
                    if !reader.sawEvent, !plain.isEmpty || line.hasPrefix("{") {
                        plainBytes += line.utf8.count + 1
                        guard plainBytes <= Self.maximumResponseBytes else {
                            throw AIClientError.upstream("The AI response exceeded the size limit.")
                        }
                        plain.append(line)
                    }
                    continue
                }
                if line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]" { break }
                if try reader.read(line: line), Date().timeIntervalSince(lastSent) >= 0.08 {
                    lastSent = Date()
                    await onText(reader.text)
                }
            }
            if reader.refused { throw AIClientError.refused }
            guard reader.sawEvent else {
                guard !plain.isEmpty else { throw StreamUnusable() }
                let result: AIChatResult
                do {
                    result = try Self.parseChatResponse(kind: settings.providerKind, data: Data(plain.joined(separator: "\n").utf8))
                } catch AIClientError.upstream(Self.unreadableResponse) {
                    throw StreamUnusable()
                }
                await onText(result.content)
                return result
            }
            guard !reader.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.emptyResponse }
            await onText(reader.text)
            return AIChatResult(content: reader.text, usage: reader.usage, truncated: reader.truncated)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIClientError {
            throw Self.scrubbed(error, of: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Text already shown must not be replaced by a second, different answer.
            guard reader.text.isEmpty else { throw Self.scrubbed(.upstream(error.localizedDescription), of: request) }
            let result = try await chat(messages: messages, settings: settings)
            await onText(result.content)
            return result
        }
    }

    private struct StreamUnusable: Error {}

    // MARK: - reading a reply

    static let unreadableResponse = "The AI server returned a response that could not be read. Check the API base URL."

    /// Reads a whole chat response of either API style.
    static func parseChatResponse(kind: AIProviderKind, data: Data) throws -> AIChatResult {
        guard data.count <= maximumResponseBytes else { throw AIClientError.upstream("The AI response exceeded the size limit.") }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIClientError.upstream(unreadableResponse)
        }
        return kind == .anthropic ? try parseAnthropic(json) : try parseChatCompletion(json)
    }

    private static func parseAnthropic(_ json: [String: Any]) throws -> AIChatResult {
        if json["type"] as? String == "error" || json["error"] is [String: Any] {
            throw AIClientError.upstream("The AI server reported an error\(errorCode(json)).")
        }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw AIClientError.refused }
        guard let blocks = json["content"] as? [Any] else { throw AIClientError.upstream(unreadableResponse) }
        var text = ""
        for case let block as [String: Any] in blocks where block["type"] as? String == "text" {
            // Thinking and tool blocks are not widget code.
            text += block["text"] as? String ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.emptyResponse }
        let usage = json["usage"] as? [String: Any]
        let input = count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens") + count(usage, "cache_read_input_tokens")
        let output = count(usage, "output_tokens")
        return AIChatResult(
            content: text,
            usage: AITokenUsage(promptTokens: input, completionTokens: output, totalTokens: input + output),
            truncated: stop == "max_tokens"
        )
    }

    private static func parseChatCompletion(_ json: [String: Any]) throws -> AIChatResult {
        let choices = json["choices"] as? [Any]
        if choices == nil, let error = json["error"], !(error is NSNull) {
            throw AIClientError.upstream("The AI server reported an error\(errorCode(json)).")
        }
        guard let choice = choices?.first as? [String: Any] else { throw AIClientError.upstream(unreadableResponse) }
        let content = (choice["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.emptyResponse }
        let usage = json["usage"] as? [String: Any]
        let prompt = count(usage, "prompt_tokens")
        let completion = count(usage, "completion_tokens")
        let total = count(usage, "total_tokens")
        return AIChatResult(
            content: content,
            usage: AITokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total > 0 ? total : prompt + completion),
            truncated: choice["finish_reason"] as? String == "length"
        )
    }

    fileprivate static func count(_ usage: [String: Any]?, _ key: String) -> Int {
        max(0, (usage?[key] as? NSNumber)?.intValue ?? 0)
    }

    /// A short machine error code such as `invalid_request_error`, never free text.
    fileprivate static func errorCode(_ json: [String: Any]?) -> String {
        guard let error = json?["error"] as? [String: Any] else { return "" }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        for key in ["type", "code"] {
            if let code = error[key] as? String, (1...64).contains(code.unicodeScalars.count),
               code.unicodeScalars.allSatisfy(allowed.contains) {
                return " (\(code))"
            }
        }
        return ""
    }

    private static func checkStatus(_ status: Int, body: Data? = nil) throws {
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 300..<400: throw AIClientError.upstream("The AI server answered with a redirect, which is not followed. Check the API base URL.")
        case 401, 403: throw AIClientError.upstream("The AI server rejected authentication. Check this profile's credentials.")
        case 404: throw AIClientError.upstream("The AI endpoint or model was not found. Check the API base URL and model name.")
        case 429: throw AIClientError.upstream("The AI server's usage limit was reached. Wait and try again.")
        default:
            // An error body is only looked at for its short code.
            let json = body.flatMap { $0.count <= 65_536 ? (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] : nil }
            throw AIClientError.upstream("The AI server could not complete the request (HTTP \(status))\(errorCode(json)).")
        }
    }

    /// Last line of defence: an error that somehow mentions the credential is
    /// replaced by one that does not.
    private static func scrubbed(_ error: AIClientError, of request: URLRequest) -> AIClientError {
        let text = error.errorDescription ?? ""
        for header in ["Authorization", "x-api-key"] {
            guard var secret = request.value(forHTTPHeaderField: header) else { continue }
            if secret.hasPrefix("Bearer ") { secret.removeFirst(7) }
            if !secret.isEmpty, text.contains(secret) { return .upstream("The AI request failed.") }
        }
        return error
    }

    // MARK: - building a request

    /// The key as it goes into a header: trimmed, at most 4096 characters, and
    /// printable ASCII only. A control character could start another header.
    static func validatedKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIClientError.missingAPIKey }
        guard key.unicodeScalars.count <= maximumKeyLength,
              key.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            throw AIClientError.invalidAPIKey
        }
        return key
    }

    private static func setCredential(_ key: String, kind: AIProviderKind, on request: inout URLRequest) {
        if kind == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }

    /// Builds the chat request for the profile's API style. The credential goes
    /// into its header and nowhere else. Not private so that its shape can be tested.
    func makeChatRequest(messages: [AIMessage], settings: AISettings, stream: Bool) async throws -> URLRequest {
        let isAnthropic = settings.providerKind == .anthropic
        let needsKey = isAnthropic || settings.authMethod != .none
        let trimmedKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needsKey || !trimmedKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        let baseURLString = settings.normalizedBaseURL
        guard let base = settings.profile.endpointURL else {
            throw AIClientError.invalidBaseURL(baseURLString)
        }

        // For OAuth profiles, refresh the access token if it's near expiry
        // and persist the refreshed credential before using it. Plain API
        // key profiles pass through unchanged.
        var resolvedKey = ""
        if settings.authMethod == .oauth, !isAnthropic {
            guard settings.profile.isOpenAIHost else {
                throw AIClientError.upstream("OAuth credentials can only be used with the OpenAI endpoint.")
            }
            do {
                resolvedKey = try await AIOpenAIOAuthVault.resolvedAccessToken(from: trimmedKey)
            } catch {
                throw AIClientError.upstream("OAuth refresh failed: \(error.localizedDescription)")
            }
        } else if needsKey {
            resolvedKey = trimmedKey
        }
        if needsKey { resolvedKey = try Self.validatedKey(resolvedKey) }

        let modelId = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else { throw AIClientError.upstream("Choose a model before generating a widget.") }

        var request = URLRequest(url: base.appendingPathComponent(isAnthropic ? "v1/messages" : "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if needsKey { Self.setCredential(resolvedKey, kind: settings.providerKind, on: &request) }
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        do {
            var object: [String: Any]
            if isAnthropic {
                // The Messages API takes the system prompt as a top-level field
                // and requires max_tokens. Sampling parameters are not sent:
                // current Claude models reject them. A message without text is
                // refused by the API, so it is left out.
                object = ["model": modelId, "max_tokens": Self.anthropicMaxTokens]
                let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
                if !system.isEmpty { object["system"] = system }
                object["messages"] = messages
                    .filter { $0.role != .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { ["role": $0.role == .assistant ? "assistant" : "user", "content": $0.content] }
            } else {
                let chatMessages: [ChatCompletionParameters.Message] = messages.map { msg in
                    let role: ChatCompletionParameters.Message.Role
                    switch msg.role {
                    case .system: role = .system
                    case .user: role = .user
                    case .assistant: role = .assistant
                    }
                    return ChatCompletionParameters.Message(role: role, content: .text(msg.content))
                }
                let parameters = ChatCompletionParameters(
                    messages: chatMessages,
                    model: .custom(modelId),
                    temperature: settings.temperature
                )
                guard let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any] else {
                    throw AIClientError.upstream("The AI request could not be prepared.")
                }
                object = encoded
                if stream { object["stream_options"] = ["include_usage": true] }
            }
            if stream { object["stream"] = true }
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        } catch let error as AIClientError {
            throw error
        } catch {
            throw AIClientError.upstream(error.localizedDescription)
        }
        return request
    }

    func availableModels(profile: AIProfile) async throws -> [String] {
        guard let base = profile.endpointURL else { throw AIClientError.invalidBaseURL(profile.baseURL) }
        let isAnthropic = profile.providerKind == .anthropic
        guard profile.authMethod != .oauth || isAnthropic else {
            throw AIClientError.upstream("Enter the model name manually for an OAuth profile.")
        }
        var url = base.appendingPathComponent("v1/models")
        if isAnthropic, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if isAnthropic || profile.authMethod == .apiKey {
            Self.setCredential(try Self.validatedKey(profile.apiKey), kind: profile.providerKind, on: &request)
        }
        let (data, response) = try await session.data(for: request, delegate: AINoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.upstream("Could not load models. Check the server address and authentication.")
        }
        if (300..<400).contains(http.statusCode) { try Self.checkStatus(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else {
            throw AIClientError.upstream("Could not load models. Check the server address and authentication.")
        }
        guard data.count <= 1_048_576 else { throw AIClientError.upstream("The model list is too large.") }
        struct ModelList: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return Array(Set(list.data.map(\.id))).sorted()
    }

    private func applePrivateCloudComputeChat(
        messages: [AIMessage],
        settings: AISettings
    ) async throws -> AIChatResult {
#if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, *) else {
            throw AIClientError.appleIntelligenceUnavailable("Private Cloud Compute requires iOS or macOS 27 or later.")
        }

        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw AIClientError.appleIntelligenceUnavailable("this device or app is not eligible for Private Cloud Compute.")
        case .unavailable(.systemNotReady):
            throw AIClientError.appleIntelligenceUnavailable("Private Cloud Compute is not ready. Check Apple Intelligence and network settings.")
        @unknown default:
            throw AIClientError.appleIntelligenceUnavailable("Private Cloud Compute reported an unknown availability state.")
        }

        if model.quotaUsage.isLimitReached {
            throw AIClientError.quotaLimitReached(quotaResetMessage(model.quotaUsage.resetDate))
        }

        let instructions = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let prompt = messages
            .filter { $0.role != .system }
            .map { message in
                let label: String
                switch message.role {
                case .system: label = "System"
                case .user: label = "User"
                case .assistant: label = "Assistant"
                }
                return "\(label):\n\(message.content)"
            }
            .joined(separator: "\n\n")

        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    temperature: settings.temperature,
                    maximumResponseTokens: 8_192
                ),
                contextOptions: ContextOptions(reasoningLevel: .moderate)
            )
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw AIClientError.emptyResponse
            }
            return AIChatResult(
                content: content,
                usage: AITokenUsage(
                    promptTokens: response.usage.input.totalTokenCount,
                    completionTokens: response.usage.output.totalTokenCount,
                    totalTokens: response.usage.totalTokenCount
                )
            )
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached(let details):
                throw AIClientError.quotaLimitReached(quotaResetMessage(details.resetDate))
            case .networkFailure:
                throw AIClientError.upstream("Private Cloud Compute could not connect. Check your network and try again.")
            case .serviceUnavailable:
                throw AIClientError.appleIntelligenceUnavailable("the Private Cloud Compute service is temporarily unavailable.")
            @unknown default:
                throw AIClientError.upstream(error.localizedDescription)
            }
        } catch let error as AIClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIClientError.appleIntelligenceUnavailable("the request could not be completed. Check Apple Intelligence and network access, then try again. If the problem persists, select another profile in Settings → AI.")
        }
#else
        throw AIClientError.appleIntelligenceUnavailable("this build does not include the macOS/iOS 27 Foundation Models SDK.")
#endif
    }

    private func quotaResetMessage(_ resetDate: Date?) -> String {
        guard let resetDate else {
            return "Try again after the daily quota resets."
        }
        return "Try again after \(resetDate.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// Reads a server-sent event stream of either API style line by line and
/// keeps the text so far. The Kotlin port is AiStreamReader.
struct AIStreamReader {
    let anthropic: Bool

    private(set) var text = ""
    /// True once a line held an event that could be read.
    private(set) var sawEvent = false
    /// The provider stopped at its output limit.
    private(set) var truncated = false
    /// The model declined the request.
    private(set) var refused = false
    private var input = 0
    private var output = 0
    private var total = 0

    var usage: AITokenUsage {
        AITokenUsage(promptTokens: input, completionTokens: output, totalTokens: total > 0 ? total : input + output)
    }

    init(anthropic: Bool) { self.anthropic = anthropic }

    /// Reads one line of the stream. Returns true when the text grew.
    mutating func read(line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return false }
        sawEvent = true
        guard let piece = try anthropic ? anthropicEvent(json) : chatCompletionEvent(json), !piece.isEmpty else { return false }
        guard text.utf8.count + piece.utf8.count <= AIClient.maximumResponseBytes else {
            throw AIClientError.upstream("The AI response exceeded the size limit.")
        }
        text += piece
        return true
    }

    private mutating func chatCompletionEvent(_ json: [String: Any]) -> String? {
        if let usage = json["usage"] as? [String: Any] {
            input = AIClient.count(usage, "prompt_tokens")
            output = AIClient.count(usage, "completion_tokens")
            total = AIClient.count(usage, "total_tokens")
        }
        guard let choice = (json["choices"] as? [Any])?.first as? [String: Any] else { return nil }
        if choice["finish_reason"] as? String == "length" { truncated = true }
        return (choice["delta"] as? [String: Any])?["content"] as? String
    }

    private mutating func anthropicEvent(_ json: [String: Any]) throws -> String? {
        switch json["type"] as? String {
        case "message_start":
            if let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] {
                input = AIClient.count(usage, "input_tokens") + AIClient.count(usage, "cache_creation_input_tokens")
                    + AIClient.count(usage, "cache_read_input_tokens")
            }
        case "message_delta":
            if let usage = json["usage"] as? [String: Any] { output = AIClient.count(usage, "output_tokens") }
            switch (json["delta"] as? [String: Any])?["stop_reason"] as? String {
            case "max_tokens": truncated = true
            case "refusal": refused = true
            default: break
            }
        case "content_block_delta":
            // Thinking and tool input are not widget code.
            if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                return delta["text"] as? String
            }
        case "error":
            // The stream broke off; what was read so far is not a reply.
            throw AIClientError.upstream("The AI server reported an error\(AIClient.errorCode(json)).")
        default:
            break
        }
        return nil
    }
}
