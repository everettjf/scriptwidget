//
//  AIEvalRunner.swift
//  ScriptWidget
//
//  Run the AI generation benchmark: every case is exercised
//  `attemptsPerCase` times against the supplied AISettings, with up to
//  `parallelism` cases in flight at once. Stochasticity (temperature
//  > 0) is the reason for multi-run averaging — single-shot results
//  are noise.
//
//  The runner depends on AgentLoop alone — it does not touch the
//  SwiftUI session object — so it is safe to drive from any thread.
//

import Foundation

struct AIEvalAttempt: Codable, Equatable {
    let attempt: Int
    let success: Bool
    let iterations: Int
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let durationSec: Double
    let error: String?
    let jsx: String?

    static let placeholder = AIEvalAttempt(
        attempt: 0, success: false, iterations: 0,
        promptTokens: 0, completionTokens: 0, totalTokens: 0,
        durationSec: 0, error: nil, jsx: nil
    )
}

struct AIEvalCaseResult: Codable, Equatable {
    let evalCase: AIEvalCase
    let attempts: [AIEvalAttempt]

    var passCount: Int { attempts.filter { $0.success }.count }
    var totalAttempts: Int { attempts.count }
    var passRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(passCount) / Double(totalAttempts)
    }
    var avgIterations: Double {
        guard !attempts.isEmpty else { return 0 }
        let sum = attempts.reduce(0) { $0 + $1.iterations }
        return Double(sum) / Double(attempts.count)
    }
    var avgTokens: Double {
        guard !attempts.isEmpty else { return 0 }
        let sum = attempts.reduce(0) { $0 + $1.totalTokens }
        return Double(sum) / Double(attempts.count)
    }
}

struct AIEvalReport: Codable {
    let runID: String
    let startedAt: Date
    let finishedAt: Date
    let modelID: String
    let baseURLHost: String
    let temperature: Double
    let maxIterations: Int
    let promptVersion: String
    let attemptsPerCase: Int
    let parallelism: Int
    let results: [AIEvalCaseResult]

    var totalCases: Int { results.count }
    var perfectCases: Int { results.filter { $0.passRate == 1.0 }.count }
    var partialCases: Int { results.filter { $0.passRate > 0 && $0.passRate < 1.0 }.count }
    var failedCases: Int { results.filter { $0.passRate == 0 }.count }
    var totalAttempts: Int { results.reduce(0) { $0 + $1.totalAttempts } }
    var totalPasses: Int { results.reduce(0) { $0 + $1.passCount } }
    var overallPassRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(totalPasses) / Double(totalAttempts)
    }
    var totalTokens: Int { results.flatMap { $0.attempts }.reduce(0) { $0 + $1.totalTokens } }
    var totalDuration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

struct AIEvalRunnerProgress {
    let completed: Int
    let total: Int
    let currentCase: String?
}

/// Bumped whenever the system prompt or the agent loop's message
/// composition is changed substantively. Reports get tagged with this
/// so two reports against the same dataset can be diffed meaningfully.
enum AIEvalPromptVersion {
    static let current = "v1"
}

actor AIEvalRunner {
    static let shared = AIEvalRunner()

    func run(
        cases: [AIEvalCase],
        settings: AISettings,
        attemptsPerCase: Int = 3,
        parallelism: Int = 3,
        onProgress: @escaping @Sendable (AIEvalRunnerProgress) -> Void = { _ in }
    ) async -> AIEvalReport {
        let startedAt = Date()
        let runID = Self.formattedRunID(date: startedAt)

        // Build a flat list of (case-index, attempt-index) jobs so the
        // task group can pull from a single queue regardless of which
        // case finishes first.
        struct Job: Sendable { let caseIndex: Int; let attempt: Int }
        var queue: [Job] = []
        for (i, _) in cases.enumerated() {
            for a in 0..<attemptsPerCase {
                queue.append(Job(caseIndex: i, attempt: a))
            }
        }
        let totalJobs = queue.count

        // Per-case attempt buckets, indexed by case position.
        var attemptsByCase: [[AIEvalAttempt]] = Array(
            repeating: [],
            count: cases.count
        )

        var completed = 0
        let cap = max(1, parallelism)

        await withTaskGroup(of: (Int, AIEvalAttempt).self) { group in
            var queueIdx = 0
            // Prime the pump.
            while queueIdx < queue.count && queueIdx < cap {
                let job = queue[queueIdx]
                queueIdx += 1
                let evalCase = cases[job.caseIndex]
                let attemptIndex = job.attempt
                let caseIndex = job.caseIndex
                let snapshot = settings
                group.addTask { [self] in
                    let attempt = await self.runOnce(
                        attempt: attemptIndex,
                        case: evalCase,
                        settings: snapshot
                    )
                    return (caseIndex, attempt)
                }
            }

            while let (caseIndex, attempt) = await group.next() {
                attemptsByCase[caseIndex].append(attempt)
                completed += 1
                onProgress(AIEvalRunnerProgress(
                    completed: completed,
                    total: totalJobs,
                    currentCase: cases[caseIndex].name
                ))
                if queueIdx < queue.count {
                    let job = queue[queueIdx]
                    queueIdx += 1
                    let evalCase = cases[job.caseIndex]
                    let attemptIndex = job.attempt
                    let nextCaseIndex = job.caseIndex
                    let snapshot = settings
                    group.addTask { [self] in
                        let a = await self.runOnce(
                            attempt: attemptIndex,
                            case: evalCase,
                            settings: snapshot
                        )
                        return (nextCaseIndex, a)
                    }
                }
            }
        }

        let results: [AIEvalCaseResult] = cases.enumerated().map { index, c in
            let sortedAttempts = attemptsByCase[index]
                .sorted { $0.attempt < $1.attempt }
            return AIEvalCaseResult(evalCase: c, attempts: sortedAttempts)
        }

        let finishedAt = Date()
        return AIEvalReport(
            runID: runID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            modelID: settings.model.isEmpty ? AIProfile.defaultModel : settings.model,
            baseURLHost: URL(string: settings.normalizedBaseURL)?.host ?? settings.normalizedBaseURL,
            temperature: settings.temperature,
            maxIterations: settings.maxIterations,
            promptVersion: AIEvalPromptVersion.current,
            attemptsPerCase: attemptsPerCase,
            parallelism: cap,
            results: results
        )
    }

    private func runOnce(
        attempt: Int,
        case evalCase: AIEvalCase,
        settings: AISettings
    ) async -> AIEvalAttempt {
        let start = Date()
        let counter = IterationCounter()
        let loop = AgentLoop()
        let request = AgentLoopRequest(
            mode: .fresh(userDescription: evalCase.prompt),
            size: evalCase.size,
            settings: settings,
            maxIterations: settings.maxIterations
        )
        let outcome = await loop.run(request) { event in
            if case .thinking(let i) = event {
                counter.bump(to: i)
            }
        }
        let duration = Date().timeIntervalSince(start)
        let iterations = counter.value

        switch outcome {
        case let .succeeded(jsx, _, usage):
            return AIEvalAttempt(
                attempt: attempt, success: true, iterations: iterations,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                totalTokens: usage.totalTokens,
                durationSec: duration, error: nil, jsx: jsx
            )
        case let .exhausted(jsx, err, usage):
            return AIEvalAttempt(
                attempt: attempt, success: false, iterations: iterations,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                totalTokens: usage.totalTokens,
                durationSec: duration,
                error: "exhausted: \(err ?? "no error captured")",
                jsx: jsx
            )
        case let .cancelled(usage):
            return AIEvalAttempt(
                attempt: attempt, success: false, iterations: iterations,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                totalTokens: usage.totalTokens,
                durationSec: duration, error: "cancelled", jsx: nil
            )
        case let .failed(message, usage):
            return AIEvalAttempt(
                attempt: attempt, success: false, iterations: iterations,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                totalTokens: usage.totalTokens,
                durationSec: duration, error: message, jsx: nil
            )
        }
    }

    private static func formattedRunID(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private final class IterationCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    func bump(to newValue: Int) {
        lock.lock(); defer { lock.unlock() }
        if newValue > _value { _value = newValue }
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
