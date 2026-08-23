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
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    case appleIntelligenceUnavailable(String)
    case quotaLimitReached(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is not set. Open Settings → AI to configure it."
        case .invalidBaseURL(let url):
            return "Base URL is invalid: \(url)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .appleIntelligenceUnavailable(let reason):
            return "Apple Intelligence is unavailable: \(reason)"
        case .quotaLimitReached(let details):
            return "Private Cloud Compute quota reached. \(details)"
        case .upstream(let message):
            return message
        }
    }
}

actor AIClient {
    static let shared = AIClient()

    func chat(messages: [AIMessage], settings: AISettings) async throws -> AIChatResult {
        if settings.providerKind == .applePrivateCloudCompute {
            return try await applePrivateCloudComputeChat(messages: messages, settings: settings)
        }

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
        } catch {
            throw AIClientError.upstream(error.localizedDescription)
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
