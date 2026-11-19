//
//  AIConversationTests.swift
//  ScriptWidgetRuntimeTests
//
//  Multi-turn AI conversations, tested against a stub provider: no network,
//  no key, no tokens. The stub answers the OpenAI-compatible chat endpoint
//  from a queue and records every request body it receives. The generated
//  code runs in the real ScriptWidget runtime.
//

import XCTest
#if os(macOS)
import SwiftUI
import AppKit
#endif
@testable import ScriptWidget

@MainActor
final class AIConversationTests: XCTestCase {

    private static let secret = "sk-stub-secret-7f3a91"
    private static let goodWidget = "$render(<vstack><text>Hello</text></vstack>)"
    private static let betterWidget = "$render(<vstack><text>Hello</text><text>World</text></vstack>)"
    private static let brokenWidget = "const broken = ;"

    private var directory: URL!
    private var store: AIConversationStore!
    private var urlSession: URLSession!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIConversationTests-\(UUID().uuidString)", isDirectory: true)
        store = AIConversationStore(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationProviderStub.self]
        urlSession = URLSession(configuration: configuration)
        ConversationProviderStub.reset()
    }

    override func tearDown() async throws {
        urlSession.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
        ConversationProviderStub.reset()
    }

    private func makeSession(
        _ conversation: AIConversation = AIConversation(),
        skills: String? = nil
    ) -> AIConversationSession {
        let client = AIClient(session: urlSession)
        var profile = AIProfile.makeDefault()
        profile.baseURL = "http://conversation.test"
        profile.model = "stub-model"
        profile.apiKey = Self.secret
        let settings = AISettings(profile: profile, maxIterations: 20, temperature: 0)
        return AIConversationSession(
            conversation: conversation,
            store: store,
            makeLoop: { AgentLoop(client: client) },
            loadSettings: { settings },
            skillsText: { _ in skills }
        )
    }

    private func reply(_ summary: String, _ code: String) -> ConversationProviderStub.Reply {
        .content("SUMMARY: \(summary)\n```jsx\n\(code)\n```")
    }

    // MARK: - prompt and reply format

    func testTurnPromptCarriesHistoryBothSourcesSkillsAndRequest() {
        let prompt = PromptBuilder.userPromptTurn(AITurnContext(
            history: [.init(request: "A greeting card", note: "Made a greeting.")],
            currentCode: "CURRENT_SOURCE",
            previousCode: "PREVIOUS_SOURCE",
            request: "Make the title smaller",
            skillsText: "- Visual Polish v1:\n  Keep it tidy.",
            size: .small
        ))
        for expected in ["A greeting card", "Made a greeting.", "CURRENT_SOURCE", "PREVIOUS_SOURCE",
                         "Make the title smaller", "Visual Polish", "Widget size: small", "SUMMARY:"] {
            XCTAssertTrue(prompt.contains(expected), "prompt should contain \(expected)")
        }
    }

    func testFirstTurnPromptHasNoCodeAndLongHistoryIsClipped() {
        let long = String(repeating: "x", count: 2_000)
        let prompt = PromptBuilder.userPromptTurn(AITurnContext(
            history: [.init(request: long, note: nil)],
            currentCode: nil, previousCode: nil, request: "A clock", skillsText: nil, size: .medium
        ))
        XCTAssertTrue(prompt.contains("The user asks for a new widget"))
        XCTAssertFalse(prompt.contains("Current working widget code"))
        XCTAssertFalse(prompt.contains(long))
        XCTAssertTrue(prompt.contains(String(repeating: "x", count: AIConversationLimits.historyRequestCharacters) + "…"))
    }

    func testReplyParsingAcceptsEveryShapeAModelMaySend() {
        let full = PromptBuilder.parseTurnReply("SUMMARY: 标题改小了\n```jsx\n$render(<text>a</text>)\n```")
        XCTAssertEqual(full.note, "标题改小了")
        XCTAssertEqual(full.code, "$render(<text>a</text>)")

        let noFence = PromptBuilder.parseTurnReply("Summary: Smaller title\n$render(<text>a</text>)")
        XCTAssertEqual(noFence.note, "Smaller title")
        XCTAssertEqual(noFence.code, "$render(<text>a</text>)")

        let codeOnly = PromptBuilder.parseTurnReply("$render(<text>a</text>)")
        XCTAssertNil(codeOnly.note)
        XCTAssertEqual(codeOnly.code, "$render(<text>a</text>)")

        let fenceOnly = PromptBuilder.parseTurnReply("```jsx\n$render(<text>a</text>)\n```")
        XCTAssertNil(fenceOnly.note)
        XCTAssertEqual(fenceOnly.code, "$render(<text>a</text>)")
    }

    func testRepairPromptClipsLongLogLines() {
        let line = String(repeating: "secret-looking-data ", count: 100)
        let prompt = PromptBuilder.userPromptFix(previousCode: "x", errorSummary: "e", recentLogs: [line])
        XCTAssertFalse(prompt.contains(line))
    }

    // MARK: - turns

    func testSecondTurnSendsHistoryAndCurrentSourceAndMakesVersionTwo() async {
        ConversationProviderStub.enqueue([
            reply("Made a greeting.", Self.goodWidget),
            reply("Added a second line.", Self.betterWidget),
        ])
        let session = makeSession(skills: "- Tidy v1:\n  Keep it tidy.")

        session.send("A greeting card")
        await session.settle()
        XCTAssertEqual(session.conversation.turns.first?.status, .succeeded)
        XCTAssertEqual(session.conversation.turns.first?.note, "Made a greeting.")
        XCTAssertEqual(session.conversation.currentVersion?.number, 1)
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertNotNil(session.previewElement)
        XCTAssertEqual(session.conversation.title, "A greeting card")

        session.send("Add a second line")
        await session.settle()
        XCTAssertEqual(session.conversation.versions.count, 2)
        XCTAssertEqual(session.conversation.currentVersion?.number, 2)
        XCTAssertEqual(session.currentSource, Self.betterWidget)
        XCTAssertEqual(session.conversation.totalUsage.totalTokens, 30)

        let bodies = ConversationProviderStub.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertFalse(bodies[0].contains("Current working widget code"))
        XCTAssertTrue(bodies[0].contains("Keep it tidy."))
        let second = bodies[1]
        XCTAssertTrue(second.contains("A greeting card"), "the earlier request is sent")
        XCTAssertTrue(second.contains("Made a greeting."), "the earlier note is sent")
        XCTAssertTrue(second.contains("<text>Hello</text>"), "the current source is sent")
        XCTAssertTrue(second.contains("Add a second line"))
        XCTAssertTrue(second.contains("Keep it tidy."), "skills apply to every turn")
    }

    func testChangeThatNeverRunsLeavesTheWidgetAndPreviewAsTheyWere() async {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget)])
        ConversationProviderStub.enqueue(Array(repeating: reply("Broke it.", Self.brokenWidget), count: 6))
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        let firstVersion = session.conversation.currentVersionID

        session.send("Break it")
        await session.settle()

        let turn = session.conversation.turns[1]
        XCTAssertEqual(turn.status, .unconverged)
        XCTAssertNil(turn.versionID)
        XCTAssertEqual(turn.failedSource, Self.brokenWidget)
        XCTAssertNotNil(turn.errorSummary)
        XCTAssertEqual(session.conversation.currentVersionID, firstVersion)
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertNotNil(session.previewElement, "the last good widget stays on screen")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(ConversationProviderStub.bodies.count, 1 + AIConversationLimits.maxAttemptsPerTurn,
                       "one generation and three repairs, no more")
    }

    func testRepairedTurnSucceedsAndCountsItsRepairs() async {
        ConversationProviderStub.enqueue([
            reply("Made a greeting.", Self.brokenWidget),
            .content(Self.goodWidget),
        ])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()

        let turn = session.conversation.turns[0]
        XCTAssertEqual(turn.status, .succeeded)
        XCTAssertEqual(turn.repairs, 1)
        XCTAssertEqual(turn.note, "Made a greeting.")
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertEqual(session.attemptLogs.count, 2)
        XCTAssertTrue(ConversationProviderStub.bodies[1].contains("failed to run"))
    }

    func testProviderErrorKeepsTheConversationUsableAndRetryWorks() async {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget), .status(500)])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.send("Add a second line")
        await session.settle()

        let failed = session.conversation.turns[1]
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNotNil(failed.errorSummary)
        XCTAssertFalse(failed.errorSummary?.contains(Self.secret) ?? false)
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertNotNil(session.previewElement)

        ConversationProviderStub.enqueue([reply("Added a second line.", Self.betterWidget)])
        session.retry(turnID: failed.id)
        await session.settle()
        XCTAssertEqual(session.conversation.turns.count, 3)
        XCTAssertEqual(session.conversation.turns[2].status, .succeeded)
        XCTAssertEqual(session.currentSource, Self.betterWidget)
    }

    func testStoppingATurnKeepsTheCurrentVersion() async {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget), .hang])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()

        session.send("Add a second line")
        XCTAssertTrue(session.isRunning)
        session.cancel()
        await session.settle()

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.conversation.turns[1].status, .cancelled)
        XCTAssertEqual(session.conversation.currentVersion?.number, 1)
        XCTAssertNotNil(session.previewElement)
        XCTAssertEqual(store.load(id: session.conversation.id)?.turns[1].status, .cancelled)
    }

    func testEmptyRequestAndASecondRequestWhileRunningAreIgnored() async {
        ConversationProviderStub.enqueue([.hang])
        let session = makeSession()
        session.send("   ")
        XCTAssertTrue(session.conversation.turns.isEmpty)
        session.send("A greeting card")
        session.send("Another one")
        XCTAssertEqual(session.conversation.turns.count, 1)
        session.cancel()
        await session.settle()
    }

    // MARK: - versions

    func testGoingBackAndContinuingLeavesTheLaterTurnBehind() async {
        ConversationProviderStub.enqueue([
            reply("Made a greeting.", Self.goodWidget),
            reply("Added a second line.", Self.betterWidget),
            reply("Made it a clock.", "$render(<vstack><text>Clock</text></vstack>)"),
        ])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.send("Add a second line")
        await session.settle()
        let first = session.conversation.versions[0]

        session.selectVersion(first.id)
        await session.settle()
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertEqual(ConversationProviderStub.bodies.count, 2, "going back sends nothing")
        XCTAssertFalse(session.conversation.turns[1].isAbandoned, "looking is not leaving")

        session.send("Make it a clock instead")
        await session.settle()

        XCTAssertTrue(session.conversation.turns[1].isAbandoned)
        XCTAssertFalse(session.conversation.turns[0].isAbandoned)
        XCTAssertEqual(session.conversation.currentVersion?.number, 3)
        XCTAssertEqual(session.conversation.currentVersion?.parentID, first.id)
        let third = ConversationProviderStub.bodies[2]
        XCTAssertFalse(third.contains("Add a second line"), "the abandoned turn is not sent")
        XCTAssertFalse(third.contains("<text>World</text>"), "the abandoned source is not sent")
        XCTAssertTrue(third.contains("A greeting card"))
    }

    func testChangingSizeRunsLocallyAndSendsNothing() async {
        ConversationProviderStub.enqueue([reply("Made it.", "$render(<vstack><text>{$getenv(\"widget-size\")}</text></vstack>)")])
        let session = makeSession()
        session.send("Show the size")
        await session.settle()
        XCTAssertEqual(texts(session.previewElement), ["medium"])

        session.setSize(.large)
        await session.settle()

        XCTAssertEqual(texts(session.previewElement), ["large"], "the widget ran again at the new size")
        XCTAssertEqual(ConversationProviderStub.bodies.count, 1)
        XCTAssertEqual(store.load(id: session.conversation.id)?.size, .large)
    }

    func testVersionsAreCappedAndTheCurrentOneIsKept() {
        var conversation = AIConversation()
        let first = conversation.addVersion(source: "v1")
        for index in 2...(AIConversationLimits.maxVersions + 5) {
            conversation.addVersion(source: "v\(index)")
        }
        XCTAssertEqual(conversation.versions.count, AIConversationLimits.maxVersions)
        XCTAssertNil(conversation.version(first.id))
        XCTAssertEqual(conversation.currentVersion?.number, AIConversationLimits.maxVersions + 5)
    }

    // MARK: - storage

    func testSavedConversationRoundTripsAndHoldsNoCredential() async throws {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget)])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.markSaved(packageName: "Greeting")

        XCTAssertTrue(ConversationProviderStub.authorizations.allSatisfy { $0 == "Bearer " + Self.secret },
                      "the key travels in the request header only")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        for forbidden in [Self.secret, "Bearer", "apiKey", "Authorization", "conversation.test"] {
            XCTAssertFalse(text.contains(forbidden), "a saved conversation must not contain \(forbidden)")
        }

        let loaded = try XCTUnwrap(store.load(id: session.conversation.id))
        XCTAssertEqual(loaded, session.conversation)
        XCTAssertFalse(loaded.isDraft)
        XCTAssertTrue(store.summaries(draftsOnly: true).isEmpty)
        XCTAssertEqual(store.summaries().map(\.id), [loaded.id])

        // A conversation opened again shows its current version without asking the provider.
        let reopened = makeSession(loaded)
        await reopened.settle()
        XCTAssertNotNil(reopened.previewElement)
        XCTAssertEqual(ConversationProviderStub.bodies.count, 1)
    }

    func testTurnLeftRunningIsReadBackAsInterrupted() throws {
        var conversation = AIConversation()
        _ = conversation.beginTurn(request: "A greeting card")
        XCTAssertTrue(store.save(conversation))
        let loaded = try XCTUnwrap(store.load(id: conversation.id))
        XCTAssertEqual(loaded.turns.first?.status, .interrupted)
    }

    func testStoreKeepsOnlyTheNewestConversations() {
        var kept: [UUID] = []
        for index in 0..<(AIConversationLimits.maxConversations + 3) {
            var conversation = AIConversation(now: Date(timeIntervalSince1970: Double(index) * 60))
            _ = conversation.beginTurn(request: "Widget \(index)", now: Date(timeIntervalSince1970: Double(index) * 60))
            XCTAssertTrue(store.save(conversation))
            kept.append(conversation.id)
        }
        let remaining = store.summaries()
        XCTAssertEqual(remaining.count, AIConversationLimits.maxConversations)
        XCTAssertNil(store.load(id: kept[0]))
        XCTAssertNotNil(store.load(id: kept.last!))
    }

    func testUnreadableOrForeignFilesAreIgnored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json"))
        var conversation = AIConversation()
        _ = conversation.beginTurn(request: "A greeting card")
        XCTAssertTrue(store.save(conversation))
        // The same content under another name is not that conversation.
        let other = UUID()
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent(conversation.id.uuidString.lowercased() + ".json"),
            to: directory.appendingPathComponent(other.uuidString.lowercased() + ".json")
        )
        XCTAssertNil(store.load(id: other))
        XCTAssertEqual(store.summaries().count, 1)
    }

    // MARK: - window snapshot (macOS, on request)

    #if os(macOS)
    /// Writes pictures of the conversation window for review. Runs only when
    /// AI_CONVERSATION_SNAPSHOT_DIR names a folder; it asserts nothing about looks.
    func testWriteWindowSnapshotsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["AI_CONVERSATION_SNAPSHOT_DIR"]
                ?? environment["TEST_RUNNER_AI_CONVERSATION_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set AI_CONVERSATION_SNAPSHOT_DIR to write window pictures")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let card = """
        const today = new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });

        $render(
          <vstack frame="max" alignment="leading" background="#0a84ff" padding="16" spacing="6">
            <text font="headline" weight="bold" color="#ffffff">Good morning</text>
            <text font="caption" color="#dbeafe">{today}</text>
            <text font="caption" color="#ffffff">Humidity 48%</text>
            <spacer />
            <text font="largeTitle" weight="bold" color="#ffd60a">21°</text>
          </vstack>,
        );
        """
        var conversation = AIConversation()
        let usage = AITokenUsage(promptTokens: 5_200, completionTokens: 310, totalTokens: 5_510)
        func turn(_ request: String, note: String, source: String, repairs: Int = 0) {
            let turn = conversation.beginTurn(request: request)
            let version = conversation.addVersion(source: source)
            conversation.updateTurn(turn.id) {
                $0.status = .succeeded
                $0.note = note
                $0.versionID = version.id
                $0.repairs = repairs
                $0.usage = usage
            }
        }
        turn("A card with a greeting, today's date and the temperature",
             note: "Made a dark greeting card with the date and temperature.",
             source: card.replacingOccurrences(of: "#0a84ff", with: "#1c1c1e"))
        turn("Make the title smaller and use a blue background",
             note: "Made the title smaller and switched to a blue background.", source: card, repairs: 1)
        let failed = conversation.beginTurn(request: "Turn it into a chart of the week")
        conversation.updateTurn(failed.id) {
            $0.status = .unconverged
            $0.errorSummary = "transformError: Unexpected token (3:14)"
            $0.failedSource = Self.brokenWidget
            $0.repairs = 3
            $0.usage = usage
        }

        try await snapshot(AIGenerateWindowView(conversation: conversation), to: output.appendingPathComponent("conversation.png"))
        try await snapshot(AIGenerateWindowView(), to: output.appendingPathComponent("empty.png"))
    }

    private func snapshot(_ view: some View, to url: URL) async throws {
        let size = NSSize(width: 940, height: 660)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        // The preview runs the widget off the main thread; give it time to arrive.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    #endif

    // MARK: - helpers

    private func texts(_ element: ScriptWidgetRuntimeElement?) -> [String] {
        guard let element else { return [] }
        var found: [String] = []
        for child in element.children ?? [] {
            if let text = child as? String { found.append(text) }
            if let nested = child as? ScriptWidgetRuntimeElement { found += texts(nested) }
        }
        return found
    }
}

/// Answers `http://conversation.test/v1/chat/completions` from a queue.
final class ConversationProviderStub: URLProtocol {
    enum Reply {
        case content(String)
        case status(Int)
        /// Never answers; the request ends only when it is cancelled.
        case hang
    }

    private static let lock = NSLock()
    private static var queue: [Reply] = []
    private static var recordedBodies: [String] = []
    private static var recordedAuthorizations: [String] = []

    static var bodies: [String] { lock.withLock { recordedBodies } }
    static var authorizations: [String] { lock.withLock { recordedAuthorizations } }

    static func enqueue(_ replies: [Reply]) {
        lock.withLock { queue.append(contentsOf: replies) }
    }

    static func reset() {
        lock.withLock {
            queue = []
            recordedBodies = []
            recordedAuthorizations = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "conversation.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        // The JSON body escapes the text; undo that so tests can search for it.
        let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]]
        let text = (messages ?? []).compactMap { $0["content"] as? String }.joined(separator: "\n---\n")
        let next: Reply? = Self.lock.withLock {
            Self.recordedBodies.append(text)
            Self.recordedAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        }
        switch next ?? .status(503) {
        case .hang:
            return
        case .status(let code):
            respond(code, Data("{}".utf8))
        case .content(let content):
            let payload: [String: Any] = [
                "id": "stub", "object": "chat.completion", "created": 1, "model": "stub-model",
                "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
                "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
            ]
            respond(200, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ data: Data) {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
