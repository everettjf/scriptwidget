//
//  AgentLoop.swift
//  ScriptWidget
//
//  Core generate → run → fix loop. Stateless; owned by AIGenerateSession.
//

import Foundation

enum AgentLoopOutcome {
    case succeeded(jsx: String, element: ScriptWidgetRuntimeElement, usage: AITokenUsage)
    case exhausted(lastJSX: String?, lastError: String?, usage: AITokenUsage)
    case cancelled(usage: AITokenUsage)
    case failed(message: String, usage: AITokenUsage)
}

enum AgentLoopEvent {
    case thinking(iteration: Int)
    case produced(iteration: Int, jsx: String)
    case running(iteration: Int)
    case ranFailed(iteration: Int, errorSummary: String, logs: [String])
    case ranSucceeded(iteration: Int)
    case tokensUsed(AITokenUsage)  // incremental
}

struct AgentLoopRequest {
    enum Mode {
        case fresh(userDescription: String)
        case refine(currentCode: String, refineInstruction: String)
    }
    let mode: Mode
    let size: AIWidgetSize
    let settings: AISettings
    let maxIterations: Int
}

final class AgentLoop {
    typealias EventHandler = @MainActor (AgentLoopEvent) -> Void

    private let client: AIClient
    private let bridge: AgentRuntimeBridge

    init(client: AIClient = .shared, bridge: AgentRuntimeBridge = .shared) {
        self.client = client
        self.bridge = bridge
    }

    func run(_ request: AgentLoopRequest, onEvent: @escaping EventHandler) async -> AgentLoopOutcome {
        var cumulativeUsage = AITokenUsage.zero

        let systemMessage = AIMessage(role: .system, content: PromptBuilder.systemPrompt(reference: AIReferenceSnapshotLoader.load()))
        let firstUserMessage: AIMessage
        var latestCode: String?

        switch request.mode {
        case .fresh(let description):
            firstUserMessage = AIMessage(role: .user, content: PromptBuilder.userPromptFirst(userDescription: description, size: request.size))
            latestCode = nil
        case .refine(let currentCode, let instruction):
            firstUserMessage = AIMessage(role: .user, content: PromptBuilder.userPromptRefine(currentCode: currentCode, refineInstruction: instruction))
            latestCode = currentCode
        }

        let package: ScriptWidgetPackage
        do {
            package = try bridge.makeSandboxPackage()
        } catch {
            return .failed(message: error.localizedDescription, usage: cumulativeUsage)
        }
        defer { bridge.cleanupSandboxPackage(package) }

        var lastError: String?
        var lastLogs: [String] = []

        let iterationLimit = max(1, request.maxIterations)

        for iteration in 1...iterationLimit {
            if Task.isCancelled {
                return .cancelled(usage: cumulativeUsage)
            }

            await onEvent(.thinking(iteration: iteration))

            let messages: [AIMessage]
            if let previous = latestCode, iteration > 1, let errMsg = lastError {
                messages = [
                    systemMessage,
                    firstUserMessage,
                    AIMessage(role: .assistant, content: previous),
                    AIMessage(role: .user, content: PromptBuilder.userPromptFix(
                        previousCode: previous, errorSummary: errMsg, recentLogs: lastLogs
                    )),
                ]
            } else {
                messages = [systemMessage, firstUserMessage]
            }

            let chatResult: AIChatResult
            do {
                chatResult = try await client.chat(messages: messages, settings: request.settings)
            } catch {
                return .failed(message: error.localizedDescription, usage: cumulativeUsage)
            }

            cumulativeUsage = cumulativeUsage + chatResult.usage
            await onEvent(.tokensUsed(cumulativeUsage))

            if Task.isCancelled {
                return .cancelled(usage: cumulativeUsage)
            }

            let jsx = PromptBuilder.stripCodeFences(chatResult.content)
            latestCode = jsx
            await onEvent(.produced(iteration: iteration, jsx: jsx))

            await onEvent(.running(iteration: iteration))
            let runResult = await bridge.run(jsx: jsx, in: package, size: request.size)

            if Task.isCancelled {
                return .cancelled(usage: cumulativeUsage)
            }

            if runResult.didSucceed, let element = runResult.element {
                await onEvent(.ranSucceeded(iteration: iteration))
                return .succeeded(jsx: jsx, element: element, usage: cumulativeUsage)
            }

            let summary: String
            if let err = runResult.error {
                summary = err.summaryForPrompt
            } else if runResult.element == nil {
                summary = "Runtime returned no element."
            } else {
                summary = "Runtime returned a fallback/placeholder element. The widget did not render real content."
            }
            lastError = summary
            lastLogs = runResult.logs
            await onEvent(.ranFailed(iteration: iteration, errorSummary: summary, logs: runResult.logs))
        }

        return .exhausted(lastJSX: latestCode, lastError: lastError, usage: cumulativeUsage)
    }
}
