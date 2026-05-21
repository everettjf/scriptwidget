//
//  AIGenerateSession.swift
//  ScriptWidget
//
//  Main-actor-facing state machine that drives the agent loop and
//  surfaces progress to SwiftUI views.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor
final class AIGenerateSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case thinking(iteration: Int)
        case running(iteration: Int)
        case fixing(iteration: Int, errorSummary: String)
        case done(jsx: String)
        case exhausted(lastJSX: String?, lastError: String?)
        case failed(String)
        case cancelled
    }

    struct IterationRecord: Identifiable, Equatable {
        let id = UUID()
        let iteration: Int
        let jsx: String
        let errorSummary: String?   // nil = success
        let logs: [String]
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var iterationHistory: [IterationRecord] = []
    @Published private(set) var usage: AITokenUsage = .zero
    @Published private(set) var lastJSX: String?
    @Published private(set) var resultElement: ScriptWidgetRuntimeElement?
    @Published private(set) var isRunning: Bool = false

    @Published var size: AIWidgetSize = .medium

    private var currentTask: Task<Void, Never>?

    var maxIterationsForProgress: Int {
        AISettingsStore.shared.load().maxIterations
    }

    var currentIteration: Int {
        switch phase {
        case .thinking(let i), .running(let i), .fixing(let i, _):
            return i
        default:
            return 0
        }
    }

    func start(userDescription: String) {
        let description = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        let settings = AISettingsStore.shared.load()
        let request = AgentLoopRequest(
            mode: .fresh(userDescription: description),
            size: size,
            settings: settings,
            maxIterations: settings.maxIterations
        )
        kickoff(request: request, initialJSX: nil)
    }

    func refine(currentCode: String, refineInstruction: String) {
        let trimmedCode = currentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstr = refineInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty, !trimmedInstr.isEmpty else { return }
        let settings = AISettingsStore.shared.load()
        let request = AgentLoopRequest(
            mode: .refine(currentCode: trimmedCode, refineInstruction: trimmedInstr),
            size: size,
            settings: settings,
            maxIterations: settings.maxIterations
        )
        kickoff(request: request, initialJSX: trimmedCode)
    }

    func cancel() {
        currentTask?.cancel()
    }

    func reset() {
        cancel()
        phase = .idle
        iterationHistory = []
        usage = .zero
        lastJSX = nil
        resultElement = nil
        isRunning = false
    }

    private func kickoff(request: AgentLoopRequest, initialJSX: String?) {
        currentTask?.cancel()
        iterationHistory = []
        usage = .zero
        lastJSX = initialJSX
        resultElement = nil
        isRunning = true
        phase = .thinking(iteration: 1)

        let loop = AgentLoop()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await loop.run(request) { [weak self] event in
                guard let self else { return }
                self.apply(event: event)
            }
            self.apply(outcome: outcome)
        }
    }

    private func apply(event: AgentLoopEvent) {
        switch event {
        case .thinking(let i):
            phase = .thinking(iteration: i)
        case .produced(let i, let jsx):
            lastJSX = jsx
            // History entry is appended on run result (success or fail).
            _ = i
        case .running(let i):
            phase = .running(iteration: i)
        case .ranFailed(let i, let summary, let logs):
            phase = .fixing(iteration: i, errorSummary: summary)
            iterationHistory.append(IterationRecord(
                iteration: i,
                jsx: lastJSX ?? "",
                errorSummary: summary,
                logs: logs
            ))
        case .ranSucceeded(let i):
            iterationHistory.append(IterationRecord(
                iteration: i,
                jsx: lastJSX ?? "",
                errorSummary: nil,
                logs: []
            ))
        case .tokensUsed(let u):
            usage = u
        }
    }

    private func apply(outcome: AgentLoopOutcome) {
        isRunning = false
        switch outcome {
        case .succeeded(let jsx, let element, let usage):
            lastJSX = jsx
            resultElement = element
            self.usage = usage
            phase = .done(jsx: jsx)
        case .exhausted(let lastJSX, let lastError, let usage):
            if let lastJSX { self.lastJSX = lastJSX }
            self.usage = usage
            phase = .exhausted(lastJSX: lastJSX, lastError: lastError)
        case .cancelled(let usage):
            self.usage = usage
            phase = .cancelled
        case .failed(let message, let usage):
            self.usage = usage
            phase = .failed(message)
        }
    }
}
