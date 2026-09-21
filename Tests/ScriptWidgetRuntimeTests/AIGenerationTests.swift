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

    func testOllamaNeedsModelButNotAPIKey() {
        var profile = AIProfile.makeOllama()
        XCTAssertFalse(profile.isConfigured)
        profile.model = "installed-model"
        XCTAssertTrue(profile.isConfigured)
        XCTAssertEqual(profile.normalizedBaseURL, "http://localhost:11434")
        XCTAssertTrue(profile.apiKey.isEmpty)
        profile.baseURL = ""
        XCTAssertEqual(profile.normalizedBaseURL, "http://localhost:11434", "Clearing Ollama's address must never route to a cloud host")
    }

    func testCustomEndpointValidationAndCredentialIsolation() {
        var profile = AIProfile.makeDefault()
        profile.apiKey = "test-secret"
        profile.authMethod = .oauth
        let changed = profile.changingEndpoint(to: "http://localhost:11434/v1/")
        XCTAssertEqual(changed.normalizedBaseURL, "http://localhost:11434")
        XCTAssertTrue(changed.apiKey.isEmpty)
        XCTAssertEqual(changed.authMethod, .apiKey)
        for address in ["file:///tmp/api", "api.example.com", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com/chat/completions"] {
            profile.baseURL = address
            XCTAssertNil(profile.endpointURL, address)
        }
        profile.baseURL = "https://example.com/custom/v1/"
        XCTAssertEqual(profile.normalizedBaseURL, "https://example.com/custom")
        XCTAssertFalse(profile.isConfigured, "OAuth must not be used on another host")
    }

    func testAppleMigrationPreservesExistingActiveProfile() throws {
        let suite = "AISettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AIProfile.makeDefault()
        defaults.set(try JSONEncoder().encode([profile]), forKey: AISettingsKey.profiles)
        defaults.set(profile.id, forKey: AISettingsKey.activeProfileID)
        let store = AISettingsStore(defaults: defaults)
        XCTAssertTrue(store.loadProfiles().contains { $0.providerKind == .applePrivateCloudCompute })
        XCTAssertEqual(store.loadActiveProfileID(), profile.id)
    }

    func testOllamaProfileRoundTripsWithoutCredential() throws {
        var profile = AIProfile.makeOllama()
        profile.model = "installed-model"
        let decoded = try JSONDecoder().decode(AIProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.providerKind, .ollama)
        XCTAssertEqual(decoded.authMethod, .none)
        XCTAssertTrue(decoded.isConfigured)
    }

    func testCompatibleRequestsPreserveHostPathAndOmitCredentialsWithoutAuth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibleEndpointStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        var profile = AIProfile.makeOllama()
        profile.baseURL = "http://compat.test/gateway/v1/"
        profile.model = "local-model"
        profile.apiKey = "must-not-be-sent"
        let models = try await client.availableModels(profile: profile)
        XCTAssertEqual(models, ["local-model"])
        let result = try await client.chat(messages: [.init(role: .user, content: "ping")],
                                          settings: AISettings(profile: profile, maxIterations: 1, temperature: 0))
        XCTAssertEqual(result.content, "pong")
    }

    func testOllamaLiveConnectionWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["AI_OLLAMA_TEST_URL"] ?? environment["TEST_RUNNER_AI_OLLAMA_TEST_URL"],
              let model = environment["AI_OLLAMA_TEST_MODEL"] ?? environment["TEST_RUNNER_AI_OLLAMA_TEST_MODEL"] else {
            throw XCTSkip("Ollama live test not configured")
        }
        var profile = AIProfile.makeOllama()
        profile.baseURL = address
        profile.model = model
        let client = AIClient()
        let models = try await client.availableModels(profile: profile)
        XCTAssertTrue(models.contains(model))
        let result = try await client.chat(messages: [.init(role: .user, content: "Reply with exactly pong.")],
                                          settings: AISettings(profile: profile, maxIterations: 1, temperature: 0))
        XCTAssertFalse(result.content.isEmpty)
    }

    @MainActor
    func testResetCannotBeOverwrittenByCancelledGeneration() async {
        let session = AIGenerateSession()
        session.start(userDescription: "A static greeting widget")
        let cancelledTask = session.currentTask
        session.reset()
        await cancelledTask?.value
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.lastJSX)
    }

    func testApplePCCProfileRequiresNoCredential() throws {
        let profile = AIProfile.makeApplePrivateCloudCompute()

        XCTAssertEqual(profile.providerKind, .applePrivateCloudCompute)
        XCTAssertTrue(profile.isConfigured)
        XCTAssertTrue(profile.apiKey.isEmpty)
    }

    func testLegacyProfileDecodesAsOpenAICompatible() throws {
        let legacy = """
        {
          "id": "legacy",
          "name": "Existing",
          "baseURL": "https://api.openai.com",
          "model": "gpt-4o-mini",
          "authMethod": "apiKey"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(AIProfile.self, from: legacy)

        XCTAssertEqual(profile.providerKind, .openAICompatible)
        XCTAssertFalse(profile.isConfigured)
    }

    func testApplePCCProfileRoundTripsWithoutSecret() throws {
        let original = AIProfile.makeApplePrivateCloudCompute()

        let decoded = try JSONDecoder().decode(
            AIProfile.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.providerKind, .applePrivateCloudCompute)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertTrue(decoded.apiKey.isEmpty)
        XCTAssertTrue(decoded.isConfigured)
    }

    func testApplePCCRepairLoopIsCappedAtThreeRequests() {
        let pccRequest = AgentLoopRequest(
            mode: .fresh(userDescription: "A clock"),
            size: .small,
            settings: AISettings(profile: .makeApplePrivateCloudCompute(), maxIterations: 20, temperature: 0),
            maxIterations: 20
        )
        var openAIProfile = AIProfile.makeDefault()
        openAIProfile.apiKey = "test-only"
        let openAIRequest = AgentLoopRequest(
            mode: .fresh(userDescription: "A clock"),
            size: .small,
            settings: AISettings(profile: openAIProfile, maxIterations: 20, temperature: 0),
            maxIterations: 20
        )

        XCTAssertEqual(AgentLoop.iterationLimit(for: pccRequest), 3)
        XCTAssertEqual(AgentLoop.iterationLimit(for: openAIRequest), 20)
    }

    func testApplePCCQuotaErrorOffersAnActionableFallback() {
        let message = AIClientError.quotaLimitReached("Try again tomorrow.").localizedDescription

        XCTAssertTrue(message.contains("daily quota"))
        XCTAssertTrue(message.contains("Try again tomorrow."))
        XCTAssertTrue(message.contains("OpenAI-compatible profile"))
        XCTAssertTrue(message.contains("Settings → AI"))
    }

    func testApplePCCLiveConnection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AI_PCC_LIVE"] == "1"
                || environment["TEST_RUNNER_AI_PCC_LIVE"] == "1" else {
            throw XCTSkip("AI_PCC_LIVE != 1 — skipping live PCC connection test.")
        }
        let settings = AISettings(
            profile: .makeApplePrivateCloudCompute(),
            maxIterations: 1,
            temperature: 0
        )

        let result = try await AIClient.shared.chat(
            messages: [
                AIMessage(role: .system, content: "Reply with exactly pong."),
                AIMessage(role: .user, content: "ping"),
            ],
            settings: settings
        )

        XCTAssertFalse(result.content.isEmpty)
        XCTAssertGreaterThan(result.usage.totalTokens, 0)
    }

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

private final class CompatibleEndpointStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "compat.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body: String
        if request.url?.path == "/gateway/v1/models" {
            body = #"{"data":[{"id":"local-model"},{"id":"local-model"}]}"#
        } else {
            XCTAssertEqual(request.url?.path, "/gateway/v1/chat/completions")
            body = #"{"id":"test","object":"chat.completion","created":1,"model":"local-model","choices":[{"index":0,"message":{"role":"assistant","content":"pong"},"finish_reason":"stop"}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
