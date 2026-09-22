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
#if os(macOS)
import SwiftUI
import AppKit
#endif
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

    #if os(macOS)
    @MainActor
    func testDeviceAppearanceIsCapturedPerRuntimeBeforeWorkerExecution() async throws {
        let package = try AgentRuntimeBridge.shared.makeSandboxPackage(prefix: "appearance")
        defer { AgentRuntimeBridge.shared.cleanupSandboxPackage(package) }
        var runtimes: [(ScriptWidgetRuntime, String)] = []
        for (name, expected) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                XCTAssertEqual(ScriptWidgetRuntimeDevice.isdarkmode(), expected == "dark")
                runtimes.append((ScriptWidgetRuntime(package: package, environments: [:]), expected))
            }
        }
        for (runtime, expected) in runtimes {
            let output = await Task.detached {
                runtime.executeJSXSyncForWidget("$render(<text>{$device.isdarkmode() ? 'dark' : 'light'}</text>);")
            }.value
            XCTAssertNil(output.1)
            XCTAssertEqual(Self.qualityText(try XCTUnwrap(output.0)), expected)
        }
    }

    private struct QualityCase {
        let id: String
        let size: AIWidgetSize
        let prompt: String
        let expectedText: [String]
        var expectedTagGroups: [[String]] = []
    }

    private struct QualityResult: Codable {
        let id: String
        let size: String
        let attempt: Int
        let prompt: String
        let runtimePassed: Bool
        let expectedText: [String]
        let missingText: [String]
        let missingComponents: [String]
        let error: String?
        let tokens: Int
        let duration: Double
        let screenshots: [String]
    }

    /// Opt-in visual/semantic regression suite. Synthetic, offline prompts only;
    /// no user widgets, personal data or credentials are written to artifacts.
    @MainActor
    func testWidgetQualityMatrix() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard variables["AI_QUALITY"] == "1" else { throw XCTSkip("AI_QUALITY != 1") }
        let env = variables["AI_QUALITY_REPLAY"] == nil ? try resolveEnv() : Env(apiKey: "", baseURL: "http://localhost", model: "replay")
        let path = try XCTUnwrap(variables["AI_QUALITY_OUTPUT"], "Set an explicit local artifact directory")
        guard path.hasPrefix("/") else { return XCTFail("Artifact directory must be absolute") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attempts = max(1, min(3, Int(variables["AI_QUALITY_ATTEMPTS"] ?? "2") ?? 2))
        let cases: [QualityCase] = [
            .init(id: "hydration", size: .small,
                  prompt: "A hydration widget. Show the title Hydration, a ring or progress indicator for 6 of 8 glasses, and the text 6 / 8. Blue accent, readable in light and dark appearances. Use only this fixed data; no network.", expectedText: ["Hydration", "6", "8"], expectedTagGroups: [["ring", "progress"]]),
            .init(id: "metrics", size: .medium,
                  prompt: "A compact business widget with two balanced columns: Revenue $2400 and Orders 32. Use stat components or native text, clear labels and values. Fixed demo data, no network.", expectedText: ["Revenue", "2400", "Orders", "32"]),
            .init(id: "chinese-dashboard", size: .large,
                  prompt: "做一个中文日程 Widget，标题为今日安排，三项日程：09:00 团队会议、14:00 设计评审、18:00 跑步。清晰的时间列、分隔线、留白；浅色和深色都要易读。仅用这些固定数据，不联网。", expectedText: ["今日安排", "09:00", "团队会议", "14:00", "设计评审", "18:00", "跑步"]),
            .init(id: "weekly-chart", size: .medium,
                  prompt: "A weekly steps widget titled Weekly Steps with a native bar chart for Mon 3000, Tue 5000, Wed 4000, Thu 6500, Fri 8000, Sat 7000, Sun 6000. Show Total 39500 as text. Use fixed data only, no HealthKit or network.", expectedText: ["Weekly Steps", "39500"], expectedTagGroups: [["chart"]]),
            .init(id: "wide-dashboard", size: .extraLarge,
                  prompt: "An iPad wide dashboard, four evenly spaced columns titled Focus, Tasks, Water, Steps, with values 25 min, 3 left, 6 cups, 8000. Clear visual hierarchy, no hardcoded screen coordinates. Fixed data only, no network.", expectedText: ["Focus", "Tasks", "Water", "Steps", "25", "8000"]),
            .init(id: "inline", size: .accessoryInline,
                  prompt: "A lock-screen inline widget displaying exactly Next meeting 14:30. Single text line; no background, no network.", expectedText: ["Next meeting 14:30"]),
            .init(id: "circular", size: .accessoryCircular,
                  prompt: "A lock-screen circular widget displaying 75% with a simple progress ring. Monochrome, no background; avoid clipping within 72 by 72 points. Fixed data only.", expectedText: ["75"], expectedTagGroups: [["ring", "gauge"]]),
            .init(id: "rectangular", size: .accessoryRectangular,
                  prompt: "A monochrome lock-screen rectangular widget: title Next train, time 08:45 and destination Central. No background, no network. Short readable lines within 170 by 72 points.", expectedText: ["Next train", "08:45", "Central"])
        ]
        var results: [QualityResult] = []
        let settings = makeSettings(env, maxIterations: 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for sample in cases {
            for attempt in 1...attempts {
                let started = Date()
                let outcome: AgentLoopOutcome
                if let replay = variables["AI_QUALITY_REPLAY"] {
                    let code = try String(contentsOf: URL(fileURLWithPath: replay)
                        .appendingPathComponent("\(sample.id)-\(attempt).jsx"), encoding: .utf8)
                    let package = try AgentRuntimeBridge.shared.makeSandboxPackage(prefix: "quality-replay")
                    let run = await AgentRuntimeBridge.shared.run(jsx: code, in: package, size: sample.size)
                    AgentRuntimeBridge.shared.cleanupSandboxPackage(package)
                    if run.didSucceed, let root = run.element { outcome = .succeeded(jsx: code, element: root, usage: .zero) }
                    else { outcome = .exhausted(lastJSX: code, lastError: run.error?.summaryForPrompt, usage: .zero) }
                } else {
                    outcome = await AgentLoop().run(.init(mode: .fresh(userDescription: sample.prompt),
                        size: sample.size, settings: settings, maxIterations: 4)) { _ in }
                }
                var jsx: String?
                var element: ScriptWidgetRuntimeElement?
                var error: String?
                let tokens: Int
                switch outcome {
                case let .succeeded(code, root, usage): jsx = code; element = root; tokens = usage.totalTokens
                case let .exhausted(code, message, usage): jsx = code; error = message ?? "exhausted"; tokens = usage.totalTokens
                case let .failed(message, usage): error = message; tokens = usage.totalTokens
                case let .cancelled(usage): error = "cancelled"; tokens = usage.totalTokens
                }
                let stem = "\(sample.id)-\(attempt)"
                if let jsx { try jsx.write(to: directory.appendingPathComponent(stem + ".jsx"), atomically: true, encoding: .utf8) }
                var screenshots: [String] = []
                var text = ""
                if let element {
                    text = Self.qualityText(element)
                    for dark in [false, true] {
                        let filename = stem + (dark ? "-dark.png" : "-light.png")
                        try await saveQualityScreenshot(try XCTUnwrap(jsx), size: sample.size, dark: dark,
                                                        to: directory.appendingPathComponent(filename))
                        screenshots.append(filename)
                    }
                }
                results.append(.init(id: sample.id, size: sample.size.rawValue, attempt: attempt,
                    prompt: sample.prompt, runtimePassed: element != nil, expectedText: sample.expectedText, missingText: sample.expectedText.filter { !text.localizedCaseInsensitiveContains($0) },
                    missingComponents: sample.expectedTagGroups.filter { group in
                        guard let element else { return true }
                        return Set(group).isDisjoint(with: Self.qualityTags(element))
                    }.map { $0.joined(separator: " or ") },
                    error: error, tokens: tokens, duration: Date().timeIntervalSince(started), screenshots: screenshots))
                try encoder.encode(results).write(to: directory.appendingPathComponent("quality.json"), options: .atomic)
                print("AI quality: \(stem), runtime=\(element != nil), missing=\(results.last!.missingText.count)")
            }
        }
        let config = ["model": env.model, "host": URL(string: env.baseURL)?.host ?? "invalid", "promptVersion": AIEvalPromptVersion.current,
                      "attempts": String(attempts), "maxIterations": "4", "temperature": "0.2"]
        try encoder.encode(config).write(to: directory.appendingPathComponent("config.json"), options: .atomic)
        XCTAssertEqual(results.count, cases.count * attempts)
        XCTAssertTrue(results.allSatisfy { $0.runtimePassed && $0.missingText.isEmpty && $0.missingComponents.isEmpty }, "Inspect quality.json and screenshots; render/semantic quality gate failed")
    }

    private static func qualityText(_ element: ScriptWidgetRuntimeElement) -> String {
        func strings(_ value: Any) -> [String] {
            if let element = value as? ScriptWidgetRuntimeElement { return [qualityText(element)] }
            if let values = value as? [Any] { return values.flatMap(strings) }
            if let values = value as? [AnyHashable: Any] { return values.values.flatMap(strings) }
            return [String(describing: value)]
        }
        return (element.getChildren().flatMap(strings) + element.getProps().values.flatMap(strings)).joined(separator: " ")
    }

    private static func qualityTags(_ element: ScriptWidgetRuntimeElement) -> Set<String> {
        element.childrenAsElements().reduce(into: Set([element.tagAsString() ?? ""])) { $0.formUnion(qualityTags($1)) }
    }

    @MainActor
    private func saveQualityScreenshot(_ jsx: String, size: AIWidgetSize, dark: Bool, to url: URL) async throws {
        guard #available(macOS 13.0, *) else { throw XCTSkip("ImageRenderer requires macOS 13") }
        let package = try AgentRuntimeBridge.shared.makeSandboxPackage(prefix: "quality-snapshot")
        defer { AgentRuntimeBridge.shared.cleanupSandboxPackage(package) }
        var themedRuntime: ScriptWidgetRuntime?
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        appearance.performAsCurrentDrawingAppearance {
            themedRuntime = ScriptWidgetRuntime(package: package, environments: ["widget-size": size.rawValue])
        }
        let runtime = try XCTUnwrap(themedRuntime)
        let result = await Task.detached { runtime.executeJSXSyncForWidget(jsx) }.value
        XCTAssertNil(result.1, "Theme replay failed")
        let element = try XCTUnwrap(result.0)
        let view = ScriptWidgetElementView(element: element, context: .init(runtime: runtime, debugMode: false,
            scriptName: "Quality", scriptParameter: "", package: package))
            .frame(width: size.previewSize.width, height: size.previewSize.height)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage, "Native snapshot failed")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
    }
    #endif

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
