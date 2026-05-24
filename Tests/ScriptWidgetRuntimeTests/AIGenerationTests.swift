//
//  AIGenerationTests.swift
//  ScriptWidgetRuntimeTests
//
//  Integration tests for the AI Generate agent loop (PR #11). These make
//  REAL calls to an OpenAI-compatible endpoint and therefore cost tokens,
//  so they are gated on an API key in the environment and SKIP (not fail)
//  when it is absent — CI without a key stays green.
//
//  Running locally / in CI
//  -----------------------
//    TEST_RUNNER_ROCKY_OPENAI_APIKEY="$ROCKY_OPENAI_APIKEY" \
//      xcodebuild test -scheme ScriptWidgetRuntimeTests \
//      -destination 'platform=macOS'
//
//  xcodebuild forwards host env vars prefixed with TEST_RUNNER_ into the
//  test process (prefix stripped). The plain name also works where the
//  test process inherits the environment (e.g. macOS). Optional overrides:
//    ROCKY_OPENAI_BASEURL  (default https://api.openai.com)
//    ROCKY_OPENAI_MODEL    (default gpt-4o-mini — cheap)
//    AI_EVAL_FULL=1        run the full bundled-template benchmark
//    AI_EVAL_ATTEMPTS=N    attempts per case for the full benchmark (default 1)
//

import XCTest
@testable import ScriptWidget

final class AIGenerationTests: XCTestCase {

    private struct Env {
        let apiKey: String
        let baseURL: String
        let model: String
    }

    /// Reads the API key from the environment under either the plain name or
    /// the TEST_RUNNER_-prefixed name xcodebuild injects into the runner.
    private func resolveEnv() throws -> Env {
        let env = ProcessInfo.processInfo.environment
        func read(_ name: String) -> String? {
            for key in [name, "TEST_RUNNER_\(name)"] {
                if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    return v
                }
            }
            return nil
        }
        guard let apiKey = read("ROCKY_OPENAI_APIKEY") else {
            throw XCTSkip("ROCKY_OPENAI_APIKEY not set — skipping live AI generation test.")
        }
        return Env(
            apiKey: apiKey,
            baseURL: read("ROCKY_OPENAI_BASEURL") ?? AIProfile.defaultBaseURL,
            model: read("ROCKY_OPENAI_MODEL") ?? "gpt-4o-mini"
        )
    }

    private func makeSettings(_ env: Env, maxIterations: Int) -> AISettings {
        let profile = AIProfile(
            id: "test-profile",
            name: "test",
            baseURL: env.baseURL,
            model: env.model,
            apiKey: env.apiKey,
            authMethod: .apiKey
        )
        return AISettings(profile: profile, maxIterations: maxIterations, temperature: 0.2)
    }

    // MARK: - Smoke: one fresh generation, end-to-end (LLM → JSX → render)

    func testFreshGenerationProducesRenderableWidget() async throws {
        let env = try resolveEnv()
        let maxIterations = 6
        let request = AgentLoopRequest(
            mode: .fresh(userDescription: "A simple widget that displays the text \"Hello World\" centered."),
            size: .medium,
            settings: makeSettings(env, maxIterations: maxIterations),
            maxIterations: maxIterations
        )

        let outcome = await AgentLoop().run(request) { _ in }

        switch outcome {
        case let .succeeded(jsx, element, usage):
            XCTAssertFalse(jsx.isEmpty, "generated JSX should not be empty")
            XCTAssertFalse(element.tagAsString()?.isEmpty ?? true, "rendered element should have a tag")
            XCTAssertGreaterThan(usage.totalTokens, 0, "a real call should report token usage")
        case let .exhausted(_, lastError, _):
            XCTFail("agent exhausted \(maxIterations) iterations without a renderable widget. Last error: \(lastError ?? "none")")
        case let .failed(message, _):
            XCTFail("agent loop failed (likely API/config): \(message)")
        case .cancelled:
            XCTFail("agent loop was unexpectedly cancelled")
        }
    }

    // MARK: - Full benchmark (opt-in: AI_EVAL_FULL=1)

    func testFullTemplateBenchmark() async throws {
        let env = try resolveEnv()
        guard ProcessInfo.processInfo.environment["AI_EVAL_FULL"] == "1" else {
            throw XCTSkip("AI_EVAL_FULL != 1 — skipping the full (expensive) template benchmark.")
        }

        let cases = AIEvalDataset.loadStandard()
        XCTAssertFalse(cases.isEmpty, "benchmark dataset should load from bundled templates")

        let attempts = Int(ProcessInfo.processInfo.environment["AI_EVAL_ATTEMPTS"] ?? "1") ?? 1
        let report = await AIEvalRunner.shared.run(
            cases: cases,
            settings: makeSettings(env, maxIterations: 20),
            attemptsPerCase: attempts,
            parallelism: 3
        )

        // Persist the report so the run is inspectable; don't fail on quality
        // (that's a tuning signal, not a correctness gate), but do require the
        // harness to have actually exercised the loop and passed at least one.
        if let dir = try? AIEvalReportWriter.write(report) {
            print("AI eval report written to: \(dir.path)")
        }
        XCTAssertGreaterThan(report.totalAttempts, 0)
        XCTAssertGreaterThan(report.totalPasses, 0, "expected at least one template to generate successfully")
    }
}
