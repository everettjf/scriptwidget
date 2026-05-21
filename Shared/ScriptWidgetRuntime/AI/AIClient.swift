//
//  AIClient.swift
//  ScriptWidget
//
//  Thin wrapper around SwiftOpenAI that performs non-streaming chat
//  completions against any OpenAI-compatible endpoint configured in
//  AISettings.
//

import Foundation
import SwiftOpenAI

struct AITokenUsage: Equatable {
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
}

enum AIClientError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL(String)
    case emptyResponse
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is not set. Open Settings → AI to configure it."
        case .invalidBaseURL(let url):
            return "Base URL is invalid: \(url)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .upstream(let message):
            return message
        }
    }
}

actor AIClient {
    static let shared = AIClient()

    func chat(messages: [AIMessage], settings: AISettings) async throws -> AIChatResult {
        let trimmedKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        let baseURLString = settings.normalizedBaseURL
        guard URL(string: baseURLString) != nil else {
            throw AIClientError.invalidBaseURL(baseURLString)
        }

        // For OAuth profiles, refresh the access token if it's near expiry
        // and persist the refreshed credential before using it. Plain API
        // key profiles pass through unchanged.
        let resolvedKey: String
        if settings.authMethod == .oauth {
            do {
                resolvedKey = try await AIOpenAIOAuthVault.resolvedAccessToken(from: trimmedKey)
            } catch {
                throw AIClientError.upstream("OAuth refresh failed: \(error.localizedDescription)")
            }
        } else {
            resolvedKey = trimmedKey
        }

        let service: OpenAIService
        if baseURLString == AISettings.defaultBaseURL {
            service = OpenAIServiceFactory.service(apiKey: resolvedKey)
        } else {
            service = OpenAIServiceFactory.service(
                apiKey: resolvedKey,
                overrideBaseURL: baseURLString
            )
        }

        let chatMessages: [ChatCompletionParameters.Message] = messages.map { msg in
            let role: ChatCompletionParameters.Message.Role
            switch msg.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            }
            return ChatCompletionParameters.Message(role: role, content: .text(msg.content))
        }

        let modelId = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel: Model = modelId.isEmpty ? .custom(AISettings.defaultModel) : .custom(modelId)

        let parameters = ChatCompletionParameters(
            messages: chatMessages,
            model: resolvedModel,
            temperature: settings.temperature
        )

        do {
            let response = try await service.startChat(parameters: parameters)
            guard let content = response.choices?.first?.message?.content, !content.isEmpty else {
                throw AIClientError.emptyResponse
            }
            let usage = AITokenUsage(
                promptTokens: response.usage?.promptTokens ?? 0,
                completionTokens: response.usage?.completionTokens ?? 0,
                totalTokens: response.usage?.totalTokens ?? 0
            )
            return AIChatResult(content: content, usage: usage)
        } catch let err as AIClientError {
            throw err
        } catch {
            throw AIClientError.upstream(error.localizedDescription)
        }
    }
}
