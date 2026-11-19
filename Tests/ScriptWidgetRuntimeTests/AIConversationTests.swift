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
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import ScriptWidget

@MainActor
final class AIConversationTests: XCTestCase {

    private static let secret = "sk-stub-secret-7f3a91"
    private static let goodWidget = "$render(<vstack><text>Hello</text></vstack>)\n"
    private static let betterWidget = "$render(<vstack><text>Hello</text><text>World</text></vstack>)\n"
    private static let brokenWidget = "const broken = ;\n"

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
        skills: String? = nil,
        sandbox: AgentSandboxSetup? = nil
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
            skillsText: { _ in skills },
            sandbox: sandbox
        )
    }

    /// A widget folder with a second file that main.jsx imports.
    private func makeWidgetFolder(manifest: WidgetPackageManifest?) throws -> URL {
        let folder = directory.appendingPathComponent("Widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "globalThis.Greeting = { text: \"From the library\" };"
            .write(to: folder.appendingPathComponent("lib/greeting.js"), atomically: true, encoding: .utf8)
        try Self.importingWidget.write(to: folder.appendingPathComponent("main.jsx"), atomically: true, encoding: .utf8)
        if let manifest {
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        }
        return folder
    }

    private static let importingWidget = """
    if (!$import("lib/greeting.js")) throw new Error("lib/greeting.js is missing");
    $render(<vstack><text>{Greeting.text}</text></vstack>)
    """

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
        XCTAssertEqual(full.code, "$render(<text>a</text>)\n")

        let noFence = PromptBuilder.parseTurnReply("Summary: Smaller title\n$render(<text>a</text>)")
        XCTAssertEqual(noFence.note, "Smaller title")
        XCTAssertEqual(noFence.code, "$render(<text>a</text>)\n")

        let codeOnly = PromptBuilder.parseTurnReply("$render(<text>a</text>)")
        XCTAssertNil(codeOnly.note)
        XCTAssertEqual(codeOnly.code, "$render(<text>a</text>)\n")

        let fenceOnly = PromptBuilder.parseTurnReply("```jsx\n$render(<text>a</text>)\n```")
        XCTAssertNil(fenceOnly.note)
        XCTAssertEqual(fenceOnly.code, "$render(<text>a</text>)\n")
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

    // MARK: - edit replies

    private func edit(_ summary: String, _ pairs: [(String, String)]) -> ConversationProviderStub.Reply {
        let blocks = pairs.map { "<<<<<<< SEARCH\n\($0.0)\n=======\n\($0.1)\n>>>>>>> REPLACE" }.joined(separator: "\n")
        return .content("SUMMARY: \(summary)\n```edit\n\(blocks)\n```")
    }

    func testEditBlocksAreReadAndAppliedInOrder() throws {
        let reply = """
        SUMMARY: Two changes.
        ```edit
        <<<<<<< SEARCH
          <text>Hello</text>
        =======
          <text>Hi</text>
          <text>there</text>
        >>>>>>> REPLACE
        <<<<<<< SEARCH
        const a = 1;
        =======
        >>>>>>> REPLACE
        ```
        """
        let edits = try XCTUnwrap(AISourceEdits.parse(reply))
        XCTAssertEqual(edits, [
            AISourceEdit(search: "  <text>Hello</text>", replace: "  <text>Hi</text>\n  <text>there</text>"),
            AISourceEdit(search: "const a = 1;", replace: ""),
        ])
        let source = "const a = 1;\r\n$render(\n  <text>Hello</text>\n)"
        XCTAssertEqual(try AISourceEdits.apply(edits, to: source), "\n$render(\n  <text>Hi</text>\n  <text>there</text>\n)\n")
        XCTAssertNil(try AISourceEdits.parse("SUMMARY: x\n```jsx\n$render(<text>a</text>)\n```"), "a full reply has no edits")
    }

    func testEditThatIsMissingAmbiguousOrMalformedIsRefused() throws {
        func reason(_ body: () throws -> Void) -> String {
            do { try body() } catch { return (error as? AISourceEdits.Failure)?.reason ?? "other" }
            return "none"
        }
        let source = "<text>a</text>\n<text>a</text>\n<text>b</text>\n"
        XCTAssertTrue(reason { _ = try AISourceEdits.apply([AISourceEdit(search: "<text>c</text>", replace: "x")], to: source) }.contains("is not in the current code"))
        XCTAssertTrue(reason { _ = try AISourceEdits.apply([AISourceEdit(search: "<text>a</text>", replace: "x")], to: source) }.contains("2 times"))
        // Nothing is applied when a later edit fails.
        XCTAssertTrue(reason {
            _ = try AISourceEdits.apply([AISourceEdit(search: "<text>b</text>", replace: "x"), AISourceEdit(search: "nowhere", replace: "y")], to: source)
        }.contains("edit 2"))
        XCTAssertTrue(reason { _ = try AISourceEdits.parse("<<<<<<< SEARCH\na\n=======\nb") }.contains("no >>>>>>> REPLACE"))
        XCTAssertTrue(reason { _ = try AISourceEdits.parse("<<<<<<< SEARCH\n\n=======\nb\n>>>>>>> REPLACE") }.contains("nothing in its SEARCH"))
        XCTAssertTrue(reason { _ = try AISourceEdits.parse("<<<<<<< SEARCH\na\n>>>>>>> REPLACE") }.contains("ends without"))
        let many = Array(repeating: "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE", count: AISourceEdits.maxEdits + 1).joined(separator: "\n")
        XCTAssertTrue(reason { _ = try AISourceEdits.parse(many) }.contains("more than"))
    }

    func testTurnPromptOffersEditBlocksOnlyWhenThereIsCodeToChange() {
        func prompt(_ current: String?) -> String {
            PromptBuilder.userPromptTurn(AITurnContext(
                history: [], currentCode: current, previousCode: nil, request: "x",
                skillsText: nil, size: .medium, currentDomains: [], runtimeDiagnostic: nil
            ))
        }
        XCTAssertTrue(prompt("CODE").contains(AISourceEdits.searchMarker))
        XCTAssertFalse(prompt(nil).contains(AISourceEdits.searchMarker))
    }

    func testTurnAnsweredWithEditBlocksChangesOnlyThatPlace() async {
        ConversationProviderStub.enqueue([
            reply("Made a greeting.", Self.goodWidget),
            edit("Says Hi now.", [("<text>Hello</text>", "<text>Hi</text>")]),
        ])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.send("Say Hi instead")
        await session.settle()

        let turn = session.conversation.turns[1]
        XCTAssertEqual(turn.status, .succeeded, turn.errorSummary ?? "")
        XCTAssertEqual(turn.note, "Says Hi now.")
        XCTAssertEqual(turn.repairs, 0)
        XCTAssertEqual(session.currentSource, "$render(<vstack><text>Hi</text></vstack>)\n")
        XCTAssertEqual(texts(session.previewElement), ["Hi"])
    }

    func testEditThatDoesNotApplyIsSentBackAndTheFullCodeIsAccepted() async {
        ConversationProviderStub.enqueue([
            reply("Made a greeting.", Self.goodWidget),
            edit("Says Hi now.", [("<text>Goodbye</text>", "<text>Hi</text>")]),
            reply("Says Hi now.", Self.betterWidget),
        ])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.send("Say Hi instead")
        await session.settle()

        let turn = session.conversation.turns[1]
        XCTAssertEqual(turn.status, .succeeded, turn.errorSummary ?? "")
        XCTAssertEqual(turn.repairs, 1)
        XCTAssertEqual(session.currentSource, Self.betterWidget)
        let repair = ConversationProviderStub.bodies.last ?? ""
        XCTAssertTrue(repair.contains("could not be applied"), "the model is told why")
        XCTAssertTrue(repair.contains("is not in the current code"))
    }

    func testEditsThatNeverApplyLeaveTheWidgetAsItWas() async {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget)])
        ConversationProviderStub.enqueue(Array(repeating: edit("Tried.", [("nowhere", "x")]), count: 6))
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.send("Change it")
        await session.settle()

        XCTAssertEqual(session.conversation.turns[1].status, .unconverged)
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertEqual(session.conversation.versions.count, 1)
    }

    // MARK: - what changed between versions

    func testDiffShowsChangedLinesWithContextAndLeavesTheRestOut() throws {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\nline ten and a half\n")
        XCTAssertEqual(AISourceDiff.summary(old: old, new: new), AISourceDiff.Summary(added: 2, removed: 1))
        let lines = try XCTUnwrap(AISourceDiff.lines(old: old, new: new))
        XCTAssertEqual(lines.map(\.kind), [
            .skipped(count: 6), .same, .same, .same, .removed, .added, .added, .same, .same, .same, .skipped(count: 7),
        ])
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["line ten", "line ten and a half"])
        XCTAssertEqual(lines.first { $0.kind == .removed }?.text, "line 10")
        XCTAssertEqual(AISourceDiff.lines(old: old, new: old), [])
        XCTAssertEqual(AISourceDiff.summary(old: "a\r\nb\n", new: "a\nb"), AISourceDiff.Summary(added: 0, removed: 0), "line endings are not a change")
        let long = String(repeating: "x\n", count: AISourceDiff.maxLines + 1)
        XCTAssertNil(AISourceDiff.summary(old: long, new: "x"))
    }

    // MARK: - a conversation that has grown heavy

    func testUsageAdviceAppearsOnlyWhenAConversationHasGrown() throws {
        var conversation = AIConversation(size: .large, skillIDs: ["visual-polish"])
        XCTAssertNil(conversation.usageAdvice)
        XCTAssertNil(conversation.continuedFromCurrentVersion(), "nothing to continue from")

        func turn(_ prompt: Int, repairs: Int = 0) {
            let turn = conversation.beginTurn(request: "Change it")
            let version = conversation.addVersion(source: "$render(<text>\(conversation.versionCounter)</text>)\n", networkDomains: ["example.com"])
            conversation.updateTurn(turn.id) {
                $0.status = .succeeded
                $0.versionID = version.id
                $0.repairs = repairs
                $0.usage = AITokenUsage(promptTokens: prompt, completionTokens: 100, totalTokens: prompt + 100)
            }
        }
        turn(5_000)
        XCTAssertNil(conversation.usageAdvice)
        // Two attempts shared 70,000 tokens: 35,000 each.
        turn(70_000, repairs: 1)
        XCTAssertEqual(conversation.lastRequestTokens, 35_000)
        XCTAssertEqual(conversation.usageAdvice?.reason, .heavyRequests(tokens: 35_000))
        turn(5_000)
        XCTAssertNil(conversation.usageAdvice, "it follows the newest turn")
        for _ in 0..<AIConversationLimits.historyTurns { turn(5_000) }
        XCTAssertEqual(conversation.usageAdvice?.reason, .historyFull)
        for _ in 0..<20 { turn(5_000) }
        XCTAssertEqual(conversation.usageAdvice?.reason, .versionsFull)
        turn(200_000)
        XCTAssertEqual(conversation.usageAdvice?.reason, .heavyRequests(tokens: 200_000))

        let next = try XCTUnwrap(conversation.continuedFromCurrentVersion())
        XCTAssertNotEqual(next.id, conversation.id)
        XCTAssertEqual(next.versions.map(\.source), [conversation.currentVersion?.source])
        XCTAssertEqual(next.currentVersion?.networkDomains, ["example.com"])
        XCTAssertEqual(next.size, .large)
        XCTAssertEqual(next.skillIDs, ["visual-polish"])
        XCTAssertTrue(next.turns.isEmpty && next.isDraft)
        XCTAssertNil(next.usageAdvice)
        XCTAssertTrue(next.historyForPrompt().isEmpty, "no earlier turn is sent")
    }

    // MARK: - tags and attributes that do not exist

    func testWidgetThatUsesOnlyWhatExistsHasNoProblem() {
        let source = """
        // <nothing here="x"> is a tag
        const title = "a <b c> in a string";
        const wide = count<limit && other < 3;
        $render(
          <vstack frame="max" alignment="leading" background="#0a84ff" padding="16" spacing="6" {...extra}>
            <text font="title,bold" weight="bold" fontDesign="rounded" color={dark ? "white" : "black"}>It's {title}</text>
            <date date={new Date()} style="timer" />
            <date date={now} style={"relative"} />
            {rows.map((row) => <hstack key={row.id}><Card title={row.title} flavour="x" /></hstack>)}
            <image systemName="sun.max" mode="fit" clip="circle" />
            <Ring side={96} />
          </vstack>,
        );
        """
        XCTAssertEqual(AIJSXCheck.problems(in: source), [])
        XCTAssertNil(AIJSXCheck.summary(of: source))
    }

    func testAttributeOrValueOrTagThatDoesNotExistIsNamed() {
        let weekday = AIJSXCheck.problems(in: "$render(<date date={now} style=\"weekday\" />)")
        XCTAssertEqual(weekday, ["style=\"weekday\" on <date> is not one of its values; it would be ignored. Use one of: time, date, relative, offset, timer."])

        let format = AIJSXCheck.problems(in: "$render(<vstack><date date={now} format=\"EEEE\" /></vstack>)")
        XCTAssertTrue(format.first?.hasPrefix("<date> has no attribute \"format\"; it would be ignored. Its attributes are: date, style, ") == true, format.first ?? "")

        let tag = AIJSXCheck.problems(in: "$render(<row><text>a</text></row>)")
        XCTAssertTrue(tag.first?.hasPrefix("<row> is not a ScriptWidget tag. The tags are: vstack, hstack, ") == true, tag.first ?? "")

        XCTAssertTrue(AIJSXCheck.problems(in: "return <text fontWeight={\"huge\"}>a</text>").first?.contains("fontWeight=\"huge\"") == true)
        XCTAssertEqual(AIJSXCheck.problems(in: "$render(<text fontWeight={weight}>a</text>)"), [], "a value that is computed is not judged")
        XCTAssertEqual(AIJSXCheck.problems(in: "$render(<vstack><row/><row/></vstack>)").count, 1)
        let many = (1...12).map { "<text madeUp\($0)=\"1\">a</text>" }.joined()
        XCTAssertEqual(AIJSXCheck.problems(in: "$render(<vstack>\(many)</vstack>)").count, AIJSXCheck.maxProblems)
        XCTAssertTrue(AIJSXCheck.problems(in: "$render(<list spacing=\"4\"></list>)").first?.contains("<list> is not a ScriptWidget tag") == true,
                      "the scrolling list is a tag on Android only")
        XCTAssertEqual(AIJSXCheck.problems(in: "$render(<list spacing=\"4\"></list>)", surface: AIJSXCheck.parseSurface(AIJSXSurfaceData.text, system: "android")), [])
    }

    func testTagInsideATagWithoutChildrenIsNamed() {
        let nested = AIJSXCheck.problems(in: "$render(<vstack><text font=\"caption\"><date date=\"now\" style=\"date\" /></text></vstack>)")
        XCTAssertEqual(nested, ["<text> takes no tags inside it, so the <date> in it is not shown. Put it next to the <text>, not in it."])
        XCTAssertEqual(AIJSXCheck.problems(in: "$render(<vstack><text>{rows.map((row) => <Row />)} a < b</text><text>Plain {value}</text><date date=\"now\" /></vstack>)"), [])
    }

    /// Every template and example in the app passes: the check must not cry wolf.
    func testEveryBundledWidgetPassesTheCheck() throws {
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "Script", withExtension: "bundle"))
        var count = 0
        var wrong: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "jsx" {
            count += 1
            let problems = AIJSXCheck.problems(in: try String(contentsOf: file, encoding: .utf8))
            if !problems.isEmpty { wrong.append("\(file.path.replacingOccurrences(of: bundle.path, with: "")): \(problems.joined(separator: " | "))") }
        }
        XCTAssertGreaterThan(count, 50)
        XCTAssertEqual(wrong, [])
    }

    func testMadeUpValueIsSentBackAlthoughTheWidgetRuns() async {
        let wrong = "$render(<date date={new Date()} style=\"weekday\" />)\n"
        let right = "$render(<date date={new Date()} style=\"date\" />)\n"
        ConversationProviderStub.enqueue([reply("Shows the weekday.", wrong), reply("Shows the date.", right)])
        let session = makeSession()
        session.send("Show the weekday")
        await session.settle()

        let turn = session.conversation.turns[0]
        XCTAssertEqual(turn.status, .succeeded, turn.errorSummary ?? "")
        XCTAssertEqual(turn.repairs, 1)
        XCTAssertEqual(session.currentSource, right)
        XCTAssertTrue(ConversationProviderStub.bodies.last?.contains("is not one of its values") == true, "the model is told what does not exist")
    }

    func testOnTheLastAttemptAWidgetThatRunsIsKept() async {
        let wrong = "$render(<date date={new Date()} style=\"weekday\" />)\n"
        ConversationProviderStub.enqueue(Array(repeating: reply("Shows the weekday.", wrong), count: 6))
        let session = makeSession()
        session.send("Show the weekday")
        await session.settle()

        let turn = session.conversation.turns[0]
        XCTAssertEqual(turn.status, .succeeded, turn.errorSummary ?? "")
        XCTAssertEqual(turn.repairs, AIConversationLimits.maxAttemptsPerTurn - 1)
        XCTAssertEqual(session.currentSource, wrong)
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
        XCTAssertEqual(session.conversation.turns.count, 2, "the new turn takes the place of the failed one")
        XCTAssertEqual(session.conversation.turns[1].status, .succeeded)
        XCTAssertFalse(session.conversation.turns.contains { $0.id == failed.id })
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

    // MARK: - streaming

    func testReplyIsReadAsItIsWrittenAndEndsAsOneText() async {
        let content = "SUMMARY: Made a greeting.\n```jsx\n\(Self.goodWidget)\n```"
        ConversationProviderStub.enqueue([.content(content)])
        let client = AIClient(session: urlSession)
        var profile = AIProfile.makeDefault()
        profile.baseURL = "http://conversation.test"
        profile.model = "stub-model"
        profile.apiKey = Self.secret
        let collected = Collected()
        let result = try? await client.chatStream(
            messages: [.init(role: .user, content: "hi")],
            settings: AISettings(profile: profile, maxIterations: 1, temperature: 0)
        ) { text in await collected.append(text) }

        XCTAssertEqual(result?.content, content)
        XCTAssertEqual(result?.usage.totalTokens, 15, "usage comes from the last event")
        let texts = await collected.texts
        XCTAssertEqual(texts.last, content)
        XCTAssertTrue(texts.allSatisfy { content.hasPrefix($0) }, "every update is the text so far")
        XCTAssertEqual(ConversationProviderStub.streamFlags, [true])
    }

    func testTurnUsesTheStreamedFormAndClearsTheLiveTextWhenDone() async {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget)])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        XCTAssertEqual(ConversationProviderStub.streamFlags, [true])
        XCTAssertEqual(session.conversation.turns[0].status, .succeeded)
        XCTAssertEqual(session.conversation.turns[0].usage.totalTokens, 15)
        XCTAssertEqual(session.liveText, "")
    }

    func testServerWithoutStreamingIsAskedAgainInThePlainForm() async {
        ConversationProviderStub.enqueue([.plainOnly("SUMMARY: Made a greeting.\n```jsx\n\(Self.goodWidget)\n```")])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        XCTAssertEqual(session.conversation.turns[0].status, .succeeded)
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertEqual(ConversationProviderStub.refusedStreams, 1)
        XCTAssertEqual(ConversationProviderStub.streamFlags, [false])
    }

    func testPartialReplyShowsOnlyTheCode() {
        XCTAssertEqual(PromptBuilder.previewOfPartialReply("SUMMARY: Made it.\n```jsx\n$render(<te"), "$render(<te")
        XCTAssertEqual(PromptBuilder.previewOfPartialReply("SUMMARY: Made it.\n```js"), "")
        XCTAssertEqual(PromptBuilder.previewOfPartialReply("```jsx\nA\n```\n```json\n{}"), "A\n")
    }

    // MARK: - network declaration

    func testDeclarationParsingAcceptsOnlyTheNetworkForListedPublicHosts() {
        XCTAssertEqual(AINetworkDeclaration.parse(json: nil), .none)
        XCTAssertEqual(AINetworkDeclaration.parse(json: "{}"), .none)
        XCTAssertEqual(
            AINetworkDeclaration.parse(json: #"{"permissions":["network"],"networkDomains":["api.example.com","*.example.org"]}"#),
            .declared(AINetworkDeclaration(domains: ["api.example.com", "*.example.org"]))
        )
        let rejected = [
            #"{"permissions":["network","location"],"networkDomains":["api.example.com"]}"#,
            #"{"permissions":["health"]}"#,
            #"{"permissions":["network"],"networkDomains":[]}"#,
            #"{"permissions":["network"],"networkDomains":["https://api.example.com/path"]}"#,
            #"{"permissions":["network"],"networkDomains":["API.Example.com"]}"#,
            #"{"permissions":["network"],"networkDomains":["api.example.com"],"actions":[]}"#,
            #"{"networkDomains":["api.example.com"]}"#,
            "[1]",
            "not json",
        ]
        for json in rejected {
            guard case .invalid = AINetworkDeclaration.parse(json: json) else {
                XCTFail("should be rejected: \(json)")
                continue
            }
        }
        let many = (0...AINetworkDeclaration.maximumDomains).map { "\"h\($0).example.com\"" }.joined(separator: ",")
        guard case .invalid = AINetworkDeclaration.parse(json: #"{"permissions":["network"],"networkDomains":["# + many + "]}") else {
            return XCTFail("too many hosts should be rejected")
        }
    }

    func testReplyParsingSeparatesTheDeclarationFromTheCode() {
        let reply = PromptBuilder.parseTurnReply("""
        SUMMARY: Shows a quote.
        ```jsx
        $render(<text>a</text>)
        ```
        ```json
        {"permissions": ["network"], "networkDomains": ["api.example.com"]}
        ```
        """)
        XCTAssertEqual(reply.note, "Shows a quote.")
        XCTAssertEqual(reply.code, "$render(<text>a</text>)\n")
        XCTAssertEqual(reply.declaration, #"{"permissions": ["network"], "networkDomains": ["api.example.com"]}"#)

        // Even without a fence around the code, the declaration is never taken for the widget.
        let bare = PromptBuilder.parseTurnReply("$render(<text>a</text>)\n```json\n{\"permissions\": []}\n```")
        XCTAssertEqual(bare.code, "$render(<text>a</text>)\n")
        XCTAssertNotNil(bare.declaration)
    }

    func testDeclaredHostsAreKeptSentToTheNextTurnAndAreAllThePreviewMayReach() async throws {
        let declaration = #"{"permissions": ["network"], "networkDomains": ["api.example.com"]}"#
        ConversationProviderStub.enqueue([
            .content("SUMMARY: Made it.\n```jsx\n\(Self.goodWidget)\n```\n```json\n\(declaration)\n```"),
            reply("Went offline.", Self.betterWidget),
        ])
        let session = makeSession()
        session.send("A quote of the day")
        await session.settle()

        XCTAssertEqual(session.currentSource, Self.goodWidget, "the declaration is not part of the source")
        XCTAssertEqual(session.currentDomains, ["api.example.com"])
        let package = try XCTUnwrap(session.previewPackage)
        let manifest = try XCTUnwrap(package.readManifest())
        XCTAssertEqual(manifest.permissions, [.network])
        XCTAssertEqual(manifest.networkDomains, ["api.example.com"])
        XCTAssertTrue(ScriptWidgetNetworkPolicy.packageAllows(URL(string: "https://api.example.com/q")!, package: package))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.packageAllows(URL(string: "https://other.example.net/")!, package: package))
        XCTAssertEqual(store.load(id: session.conversation.id)?.currentVersion?.networkDomains, ["api.example.com"])

        session.send("Do it without the network")
        await session.settle()
        XCTAssertTrue(ConversationProviderStub.bodies[1].contains("api.example.com"), "the model is told what is declared")
        XCTAssertEqual(session.currentDomains, [], "a reply without the block declares nothing")
        let offline = try XCTUnwrap(package.readManifest())
        XCTAssertEqual(offline.permissions, [])
        XCTAssertFalse(ScriptWidgetNetworkPolicy.packageAllows(URL(string: "https://api.example.com/q")!, package: package),
                       "a widget that declares nothing gets no network in the preview, as after saving")
    }

    func testInvalidDeclarationIsNotRunAndIsSentBackForRepair() async {
        let bad = #"{"permissions": ["network", "location"], "networkDomains": ["api.example.com"]}"#
        ConversationProviderStub.enqueue([
            .content("SUMMARY: Made it.\n```jsx\n\(Self.goodWidget)\n```\n```json\n\(bad)\n```"),
            reply("Made it.", Self.goodWidget),
        ])
        let session = makeSession()
        session.send("A quote of the day")
        await session.settle()

        let turn = session.conversation.turns[0]
        XCTAssertEqual(turn.status, .succeeded)
        XCTAssertEqual(turn.repairs, 1)
        XCTAssertEqual(session.currentDomains, [])
        XCTAssertTrue(ConversationProviderStub.bodies[1].contains("network declaration block is not valid"))
        XCTAssertTrue(ConversationProviderStub.bodies[1].contains("no other permission"))
    }

    // MARK: - sizes

    func testThumbnailSizesAreRenderedLocally() async {
        ConversationProviderStub.enqueue([reply("Made it.", "$render(<vstack><text>{$getenv(\"widget-size\")}</text></vstack>)")])
        let session = makeSession()
        session.send("Show the size")
        await session.settle()
        for size in AIConversationSession.thumbnailSizes {
            XCTAssertEqual(texts(session.previews[size]), [size.rawValue])
        }
        XCTAssertEqual(ConversationProviderStub.bodies.count, 1)

        session.setSize(.accessoryRectangular)
        await session.settle()
        XCTAssertEqual(texts(session.previewElement), ["accessoryRectangular"])
        XCTAssertEqual(ConversationProviderStub.bodies.count, 1)
    }

    // MARK: - a conversation about an existing widget

    func testCodeFromTheEditorBecomesAVersionAndIsNotSentAsARequest() async {
        ConversationProviderStub.enqueue([reply("Added a second line.", Self.betterWidget)])
        let session = makeSession()
        session.adoptEditorSource(Self.goodWidget)
        await session.settle()

        XCTAssertEqual(session.conversation.versions.count, 1)
        XCTAssertEqual(session.conversation.turns.first?.isManualEdit, true)
        XCTAssertEqual(session.currentSource, Self.goodWidget)
        XCTAssertNotNil(session.previewElement)
        XCTAssertEqual(ConversationProviderStub.bodies.count, 0, "taking over the editor's code sends nothing")

        session.send("Add a second line")
        await session.settle()
        let body = ConversationProviderStub.bodies[0]
        XCTAssertTrue(body.contains("<text>Hello</text>"), "the editor's code is the widget the AI changes")
        XCTAssertFalse(body.contains("Earlier turns"), "a manual edit is not an earlier request")
        XCTAssertEqual(session.conversation.currentVersion?.number, 2)
    }

    func testEditorStillHoldingAnOlderVersionDoesNotReplaceThePendingOne() async {
        ConversationProviderStub.enqueue([reply("Added a second line.", Self.betterWidget)])
        let session = makeSession()
        session.adoptEditorSource(Self.goodWidget)
        session.send("Add a second line")
        await session.settle()

        // The new version was not applied: the editor still holds version 1.
        session.adoptEditorSource(Self.goodWidget)
        XCTAssertEqual(session.currentSource, Self.betterWidget, "the pending version stays the one being worked on")
        XCTAssertEqual(session.conversation.versions.count, 2)

        // Code the conversation never saw is the user's own edit.
        let edited = "$render(<vstack><text>Mine</text></vstack>)"
        session.adoptEditorSource(edited)
        await session.settle()
        XCTAssertEqual(session.currentSource, edited)
        XCTAssertEqual(session.conversation.versions.count, 3)
        XCTAssertEqual(session.conversation.turns.last?.isManualEdit, true)
    }

    func testCandidateRunsWithTheWidgetsOwnFiles() async throws {
        let folder = try makeWidgetFolder(manifest: nil)
        ConversationProviderStub.enqueue([reply("Kept the import.", Self.importingWidget + "\n// changed")])
        let session = makeSession(sandbox: AgentSandboxSetup(seedDirectory: folder, baseManifest: nil))
        session.adoptEditorSource(Self.importingWidget)
        await session.settle()
        XCTAssertEqual(texts(session.previewElement), ["From the library"], "the preview copy has lib/greeting.js")

        session.send("Change something")
        await session.settle()
        XCTAssertEqual(session.conversation.turns.last?.status, .succeeded,
                       session.conversation.turns.last?.errorSummary ?? "")
        XCTAssertTrue(session.currentSource.hasSuffix("// changed\n"),
                      "a last line that is a comment still runs: the code ends with a line break")
        XCTAssertEqual(texts(session.previewElement), ["From the library"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("main.jsx"), encoding: .utf8),
                       Self.importingWidget, "the widget itself is not touched")
    }

    func testCandidateRunsWithTheWidgetsOwnPermissionsPlusDeclaredHosts() async throws {
        var manifest = WidgetPackageManifest.newProject(name: "Bound")
        manifest.permissions = [.storage, .network]
        manifest.networkDomains = ["one.example.com"]
        let folder = try makeWidgetFolder(manifest: manifest)
        let declaration = #"{"permissions": ["network"], "networkDomains": ["two.example.com"]}"#
        ConversationProviderStub.enqueue([
            .content("SUMMARY: Kept it.\n```jsx\n\(Self.importingWidget)\n// v2\n```\n```json\n\(declaration)\n```"),
        ])
        let session = makeSession(sandbox: AgentSandboxSetup(seedDirectory: folder, baseManifest: manifest))
        session.adoptEditorSource(Self.importingWidget)
        session.send("Use a second host")
        await session.settle()

        XCTAssertEqual(session.conversation.turns.last?.status, .succeeded,
                       session.conversation.turns.last?.errorSummary ?? "")
        let preview = try XCTUnwrap(session.previewPackage?.readManifest())
        XCTAssertEqual(preview.id, manifest.id)
        XCTAssertEqual(Set(preview.permissions), [.storage, .network], "nothing but the network is ever added")
        XCTAssertEqual(preview.networkDomains, ["one.example.com", "two.example.com"])
        let saved = try JSONDecoder().decode(WidgetPackageManifest.self,
                                             from: Data(contentsOf: folder.appendingPathComponent("widget.json")))
        XCTAssertEqual(saved.networkDomains, ["one.example.com"], "the widget's own manifest is not changed by a turn")
    }

    func testSandboxSetupNeverInventsAManifestForALegacyWidget() {
        let legacy = AgentSandboxSetup(seedDirectory: directory, baseManifest: nil)
        XCTAssertNil(legacy.manifest(declaring: ["api.example.com"]))
    }

    func testSeedingSkipsLinksAndTheBuildCacheAndRefusesAnOversizedWidget() throws {
        let folder = try makeWidgetFolder(manifest: nil)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("__Build"), withIntermediateDirectories: true)
        try "cache".write(to: folder.appendingPathComponent("__Build/cache.js"), atomically: true, encoding: .utf8)
        let outside = directory.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: outside)

        let package = try AgentRuntimeBridge.shared.makeSandboxPackage(prefix: "seed-test")
        defer { AgentRuntimeBridge.shared.cleanupSandboxPackage(package) }
        XCTAssertTrue(AgentRuntimeBridge.shared.seed(package, from: folder))
        let copied = package.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("lib/greeting.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("link.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("__Build/cache.js").path))

        for index in 0...AgentRuntimeBridge.seedMaximumFiles {
            try "x".write(to: folder.appendingPathComponent("lib/f\(index).js"), atomically: true, encoding: .utf8)
        }
        let second = try AgentRuntimeBridge.shared.makeSandboxPackage(prefix: "seed-test")
        defer { AgentRuntimeBridge.shared.cleanupSandboxPackage(second) }
        XCTAssertFalse(AgentRuntimeBridge.shared.seed(second, from: folder))
    }

    func testConversationIsFoundAgainByTheWidgetItWasSavedAs() async {
        ConversationProviderStub.enqueue([reply("Made a greeting.", Self.goodWidget)])
        let session = makeSession()
        session.send("A greeting card")
        await session.settle()
        session.markSaved(packageName: "Greeting", packageID: "local.abc")

        XCTAssertEqual(store.latest(packageID: "local.abc", packageName: "Renamed")?.id, session.conversation.id,
                       "the manifest id finds it after a rename")
        XCTAssertNil(store.latest(packageID: "local.other", packageName: "Greeting"),
                     "another widget that took the old name does not get the conversation")
        XCTAssertEqual(store.latest(packageID: nil, packageName: "Greeting")?.id, session.conversation.id)
        XCTAssertNil(store.latest(packageID: nil, packageName: "Other"))
    }

    func testRuntimeDiagnosticIsPartOfTheRequest() {
        let prompt = PromptBuilder.userPromptTurn(AITurnContext(
            history: [], currentCode: "CODE", previousCode: nil, request: "Fix it", skillsText: nil,
            size: .small, runtimeDiagnostic: "scriptException: boom"
        ))
        XCTAssertTrue(prompt.contains("scriptException: boom"))
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

    // MARK: - a real model, on request

    /// Three turns against a real OpenAI-compatible provider. Costs tokens, so it
    /// runs only when ROCKY_OPENAI_APIKEY is set (see AIGenerationTests for the
    /// variables). With AI_CONVERSATION_LIVE_DIR set, the sources and a short
    /// account of each turn are written there; the key is never written.
    func testThreeTurnsAgainstARealProviderWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        func read(_ name: String) -> String? {
            for key in [name, "TEST_RUNNER_\(name)"] {
                if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        guard let key = read("ROCKY_OPENAI_APIKEY") else {
            throw XCTSkip("ROCKY_OPENAI_APIKEY not set — skipping the live conversation test.")
        }
        let profile = AIProfile(
            id: "live-conversation", name: "live",
            baseURL: read("ROCKY_OPENAI_BASEURL") ?? AIProfile.defaultBaseURL,
            model: read("ROCKY_OPENAI_MODEL") ?? AIProfile.defaultModel,
            apiKey: key, authMethod: .apiKey
        )
        let settings = AISettings(profile: profile, maxIterations: 20, temperature: 0.2)
        let session = AIConversationSession(store: store, loadSettings: { settings }, skillsText: { _ in nil })

        let requests = [
            "A card that says Hello in large text with today's date under it, on a light background",
            "Make the Hello text smaller and change the background to dark blue with white text",
            "Add a line at the bottom that says Have a nice day",
        ]
        var report: [String] = []
        for (index, request) in requests.enumerated() {
            let started = Date()
            session.send(request)
            await session.settle()
            let turn = try XCTUnwrap(session.conversation.turns.last)
            report.append("""
            Turn \(index + 1): \(request)
              status: \(turn.status.rawValue), repairs: \(turn.repairs), tokens: \(turn.usage.totalTokens),             seconds: \(Int(Date().timeIntervalSince(started)))
              note: \(turn.note ?? "(none)")
              error: \(turn.errorSummary ?? "(none)")
            """)
            if let folder = read("AI_CONVERSATION_LIVE_DIR") {
                let output = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try (turn.failedSource ?? session.currentSource)
                    .write(to: output.appendingPathComponent("turn-\(index + 1).jsx"), atomically: true, encoding: .utf8)
                try report.joined(separator: "\n").write(
                    to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            }
            XCTAssertEqual(turn.status, .succeeded, "turn \(index + 1) should run: \(turn.errorSummary ?? "")")
            XCTAssertNotNil(turn.note, "the model should say what it did")
        }
        print(report.joined(separator: "\n"))

        XCTAssertEqual(session.conversation.versions.count, 3)
        let final = session.currentSource
        XCTAssertTrue(final.contains("Hello"), "an unrelated part survives the later turns")
        XCTAssertTrue(final.localizedCaseInsensitiveContains("Have a nice day"))
        XCTAssertNotNil(session.previewElement)
    }

    // MARK: - multi-turn quality

    /// One request of a multi-turn case, and what the code has to look like after it.
    struct ConversationEvalStep {
        let request: String
        /// Go back to this version number before sending, as a user would.
        var fromVersion: Int? = nil
        /// Text the code must hold after the turn, compared without case.
        var mustContain: [String] = []
        var mustNotContain: [String] = []
        /// A small request should touch few lines: added plus removed, at most this.
        var maxChangedLines: Int? = nil
    }

    struct ConversationEvalCase {
        let id: String
        let size: AIWidgetSize
        let steps: [ConversationEvalStep]
    }

    /// The cases the live run sends. Every later step is a small change, so
    /// that a model that rewrites everything shows in the changed lines.
    static let conversationEvalCases: [ConversationEvalCase] = [
        ConversationEvalCase(id: "greeting", size: .medium, steps: [
            ConversationEvalStep(request: "A card that says Hello in large text with today's date under it, on a light background", mustContain: ["Hello"]),
            ConversationEvalStep(request: "Change the word Hello to Welcome. Change nothing else.", mustContain: ["Welcome"], mustNotContain: ["Hello"], maxChangedLines: 6),
            ConversationEvalStep(request: "Add a line at the bottom that says Have a nice day", mustContain: ["Welcome", "Have a nice day"], maxChangedLines: 12),
            ConversationEvalStep(request: "Make the background dark blue and all text white", fromVersion: 1, mustContain: ["Hello"], mustNotContain: ["Have a nice day"]),
        ]),
        ConversationEvalCase(id: "habits", size: .large, steps: [
            ConversationEvalStep(request: "A habit tracker with three rows: Water 6 of 8, Reading 20 of 30 and Steps 4200 of 8000. Each row has its name, the numbers and a progress bar. Use fixed sample data.", mustContain: ["Water", "Reading", "Steps"]),
            ConversationEvalStep(request: "Rename Reading to Study. Change nothing else.", mustContain: ["Study", "Water", "Steps"], mustNotContain: ["Reading"], maxChangedLines: 6),
            ConversationEvalStep(request: "Remove the Steps row", mustContain: ["Study", "Water"], mustNotContain: ["Steps"]),
            ConversationEvalStep(request: "Add a title at the top that says Today", mustContain: ["Today", "Study", "Water"], maxChangedLines: 12),
        ]),
        ConversationEvalCase(id: "clock", size: .small, steps: [
            ConversationEvalStep(request: "The current time in large text and the date under it in small text, centered, on a black background with white text", mustContain: ["<date"]),
            ConversationEvalStep(request: "Show the date as a relative time instead", mustContain: ["relative"], maxChangedLines: 8),
            ConversationEvalStep(request: "Make the background dark green", mustContain: ["<date"], maxChangedLines: 8),
        ]),
        ConversationEvalCase(id: "chinese", size: .medium, steps: [
            ConversationEvalStep(request: "做一个卡片，大字显示“早上好”，下面一行小字显示“今天也要加油”，浅色背景", mustContain: ["早上好", "今天也要加油"]),
            ConversationEvalStep(request: "把“早上好”改成“晚上好”，其他不要动", mustContain: ["晚上好", "今天也要加油"], mustNotContain: ["早上好"], maxChangedLines: 6),
            ConversationEvalStep(request: "背景换成深色，文字换成白色", mustContain: ["晚上好", "今天也要加油"]),
        ]),
    ]

    /// Runs `cases` through a session each and returns one record per turn.
    private func runConversationEval(
        _ cases: [ConversationEvalCase], makeSession: () -> AIConversationSession, output: URL? = nil
    ) async throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        for evalCase in cases {
            let session = makeSession()
            session.setSize(evalCase.size)
            for (index, step) in evalCase.steps.enumerated() {
                if let number = step.fromVersion, let version = session.conversation.versions.first(where: { $0.number == number }) {
                    session.selectVersion(version.id)
                }
                let before = session.currentSource
                let started = Date()
                session.send(step.request)
                await session.settle()
                let turn = try XCTUnwrap(session.conversation.turns.last)
                let after = turn.status == .succeeded ? session.currentSource : (turn.failedSource ?? "")
                let changes = before.isEmpty ? nil : AISourceDiff.summary(old: before, new: after)
                let changed = changes.map { $0.added + $0.removed }
                let missing = turn.status == .succeeded
                    ? step.mustContain.filter { !after.localizedCaseInsensitiveContains($0) } : step.mustContain
                let unwanted = step.mustNotContain.filter { after.localizedCaseInsensitiveContains($0) }
                let tooMany = turn.status == .succeeded && step.maxChangedLines != nil && (changed ?? 0) > (step.maxChangedLines ?? 0)
                var record: [String: Any] = [
                    "case": evalCase.id, "turn": index + 1, "request": step.request,
                    "status": turn.status.rawValue, "repairs": turn.repairs,
                    "promptTokens": turn.usage.promptTokens, "completionTokens": turn.usage.completionTokens,
                    "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                    "lines": AISourceDiff.split(after).count,
                    "missing": missing, "unwanted": unwanted, "tooManyChangedLines": tooMany,
                    "passed": turn.status == .succeeded && missing.isEmpty && unwanted.isEmpty && !tooMany,
                    "note": turn.note ?? "", "error": turn.errorSummary ?? "",
                ]
                if let changes { record["added"] = changes.added; record["removed"] = changes.removed }
                if let limit = step.maxChangedLines { record["maxChangedLines"] = limit }
                records.append(record)
                if let output {
                    try after.write(to: output.appendingPathComponent("\(evalCase.id)-turn-\(index + 1).jsx"), atomically: true, encoding: .utf8)
                }
            }
        }
        if let output {
            let data = try JSONSerialization.data(withJSONObject: ["turns": records], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("conversation-quality.json"))
            try Self.conversationEvalReport(records).write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
        return records
    }

    /// The records as a page a person reads.
    static func conversationEvalReport(_ records: [[String: Any]]) -> String {
        func number(_ record: [String: Any], _ key: String) -> Int { record[key] as? Int ?? 0 }
        let passed = records.filter { $0["passed"] as? Bool == true }.count
        let later = records.filter { number($0, "turn") > 1 && $0["status"] as? String == "succeeded" }
        let changed = later.map { number($0, "added") + number($0, "removed") }
        let share = later.map { Double(number($0, "added") + number($0, "removed")) / Double(max(1, number($0, "lines"))) }
        var lines = [
            "# Multi-turn AI quality", "",
            "- Turns passed: \(passed) of \(records.count)",
            "- Repairs: \(records.map { number($0, "repairs") }.reduce(0, +))",
            "- Tokens: \(records.map { number($0, "promptTokens") }.reduce(0, +)) sent, \(records.map { number($0, "completionTokens") }.reduce(0, +)) received",
            "- Changed lines per later turn: \(changed.isEmpty ? 0 : changed.reduce(0, +) / changed.count) on average; \(share.isEmpty ? 0 : Int((share.reduce(0, +) / Double(share.count) * 100).rounded()))% of the widget's lines",
            "", "| Case | Turn | Result | Repairs | +/− lines | Sent | Received | Seconds | Problem |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for record in records {
            var problems: [String] = []
            if let error = record["error"] as? String, !error.isEmpty, record["status"] as? String != "succeeded" { problems.append(String(error.prefix(80))) }
            if let missing = record["missing"] as? [String], !missing.isEmpty { problems.append("missing: " + missing.joined(separator: ", ")) }
            if let unwanted = record["unwanted"] as? [String], !unwanted.isEmpty { problems.append("still there: " + unwanted.joined(separator: ", ")) }
            if record["tooManyChangedLines"] as? Bool == true { problems.append("changed more than \(number(record, "maxChangedLines")) lines") }
            let diff = record["added"] == nil ? "new" : "+\(number(record, "added")) −\(number(record, "removed"))"
            lines.append("| \(record["case"] ?? "") | \(number(record, "turn")) | \(record["passed"] as? Bool == true ? "passed" : (record["status"] as? String ?? "")) | \(number(record, "repairs")) | \(diff) | \(number(record, "promptTokens")) | \(number(record, "completionTokens")) | \(record["seconds"] ?? "") | \(problems.joined(separator: "; ").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The harness itself, with scripted replies: no key, no network.
    func testConversationEvalRecordsWhatEachTurnChangedAndMissed() async throws {
        let first = "$render(\n  <vstack>\n    <text>Hello</text>\n    <text>Today</text>\n  </vstack>\n)\n"
        ConversationProviderStub.enqueue([
            reply("Made a greeting.", first),
            edit("Says Welcome.", [("    <text>Hello</text>", "    <text>Welcome</text>")]),
            // Asked for one more line, rewrote everything and forgot it.
            reply("Rewrote it.", "$render(\n  <hstack>\n    <text>Welcome</text>\n    <spacer />\n    <text>Now</text>\n  </hstack>\n)\n"),
        ])
        let output = directory.appendingPathComponent("eval", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let records = try await runConversationEval([
            ConversationEvalCase(id: "scripted", size: .medium, steps: [
                ConversationEvalStep(request: "A greeting", mustContain: ["Hello"]),
                ConversationEvalStep(request: "Say Welcome", mustContain: ["Welcome"], mustNotContain: ["Hello"], maxChangedLines: 2),
                ConversationEvalStep(request: "Add a line that says Bye", mustContain: ["Bye"], maxChangedLines: 2),
            ]),
        ], makeSession: { self.makeSession() }, output: output)

        XCTAssertEqual(records.map { $0["passed"] as? Bool }, [true, true, false])
        XCTAssertNil(records[0]["added"], "a new widget has nothing to compare with")
        XCTAssertEqual(records[1]["added"] as? Int, 1)
        XCTAssertEqual(records[1]["removed"] as? Int, 1)
        XCTAssertEqual(records[2]["missing"] as? [String], ["Bye"])
        XCTAssertEqual(records[2]["tooManyChangedLines"] as? Bool, true)
        let report = try String(contentsOf: output.appendingPathComponent("report.md"), encoding: .utf8)
        XCTAssertTrue(report.contains("Turns passed: 2 of 3"))
        XCTAssertTrue(report.contains("missing: Bye; changed more than 2 lines"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("scripted-turn-2.jsx").path))
        XCTAssertFalse(try String(contentsOf: output.appendingPathComponent("conversation-quality.json"), encoding: .utf8).contains(Self.secret))
    }

    /// The multi-turn cases against a real provider. It costs tokens, so it runs
    /// only with AI_CONVERSATION_QUALITY=1 and ROCKY_OPENAI_APIKEY set; see
    /// Scripts/ai-conversation-quality.sh. The key is never written.
    func testConversationQualityAgainstARealProviderWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        func read(_ name: String) -> String? {
            for key in [name, "TEST_RUNNER_\(name)"] {
                if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
            }
            return nil
        }
        guard read("AI_CONVERSATION_QUALITY") == "1", let key = read("ROCKY_OPENAI_APIKEY") else {
            throw XCTSkip("Set AI_CONVERSATION_QUALITY=1 and ROCKY_OPENAI_APIKEY to run the multi-turn quality cases.")
        }
        let profile = AIProfile(
            id: "live-conversation-quality", name: "live",
            baseURL: read("ROCKY_OPENAI_BASEURL") ?? AIProfile.defaultBaseURL,
            model: read("ROCKY_OPENAI_MODEL") ?? AIProfile.defaultModel,
            apiKey: key, authMethod: .apiKey
        )
        let settings = AISettings(profile: profile, maxIterations: 20, temperature: 0.2)
        let output = read("AI_CONVERSATION_QUALITY_OUTPUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let store = try XCTUnwrap(self.store)
        let records = try await runConversationEval(
            Self.conversationEvalCases,
            makeSession: { AIConversationSession(store: store, loadSettings: { settings }, skillsText: { _ in nil }) },
            output: output
        )
        print(Self.conversationEvalReport(records))
        let failed = records.filter { $0["passed"] as? Bool != true }.map { "\($0["case"] ?? "") turn \($0["turn"] ?? "")" }
        XCTAssertEqual(failed, [], "see report.md")
    }

    /// One turn that needs the network, against a real provider and a real
    /// public host (httpbin.org). Runs only with ROCKY_OPENAI_APIKEY set.
    func testNetworkWidgetAgainstARealProviderWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        func read(_ name: String) -> String? {
            for key in [name, "TEST_RUNNER_\(name)"] {
                if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        guard let key = read("ROCKY_OPENAI_APIKEY") else {
            throw XCTSkip("ROCKY_OPENAI_APIKEY not set — skipping the live network-widget test.")
        }
        let profile = AIProfile(
            id: "live-conversation", name: "live",
            baseURL: read("ROCKY_OPENAI_BASEURL") ?? AIProfile.defaultBaseURL,
            model: read("ROCKY_OPENAI_MODEL") ?? AIProfile.defaultModel,
            apiKey: key, authMethod: .apiKey
        )
        let settings = AISettings(profile: profile, maxIterations: 20, temperature: 0.2)
        let session = AIConversationSession(store: store, loadSettings: { settings }, skillsText: { _ in nil })

        session.send("Fetch https://httpbin.org/uuid, which returns JSON like {\"uuid\": \"...\"}, and show the uuid in small text under the title Random ID. Show a short message if it can not be loaded.")
        await session.settle()

        let turn = try XCTUnwrap(session.conversation.turns.last)
        let report = """
        status: \(turn.status.rawValue), repairs: \(turn.repairs), tokens: \(turn.usage.totalTokens)
        note: \(turn.note ?? "(none)")
        error: \(turn.errorSummary ?? "(none)")
        declared: \(session.currentDomains)
        """
        print(report)
        if let folder = read("AI_CONVERSATION_LIVE_DIR") {
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try (turn.failedSource ?? session.currentSource)
                .write(to: output.appendingPathComponent("network.jsx"), atomically: true, encoding: .utf8)
            try report.write(to: output.appendingPathComponent("network-report.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(turn.status, .succeeded, turn.errorSummary ?? "")
        XCTAssertEqual(session.currentDomains, ["httpbin.org"], "the widget declares the host it contacts")
        XCTAssertTrue(session.currentSource.contains("httpbin.org"))
    }

    // MARK: - pictures of the window and the screen (on request)

    private static func snapshotFolder() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["AI_CONVERSATION_SNAPSHOT_DIR"]
                ?? environment["TEST_RUNNER_AI_CONVERSATION_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set AI_CONVERSATION_SNAPSHOT_DIR to write pictures")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    /// Two turns that worked and one that did not, as the pictures show them.
    private static func sampleConversation() -> AIConversation {
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
        return conversation
    }

    #if os(macOS)
    /// Writes pictures of the conversation window for review. Runs only when
    /// AI_CONVERSATION_SNAPSHOT_DIR names a folder; it asserts nothing about looks.
    func testWriteWindowSnapshotsWhenRequested() async throws {
        let output = try Self.snapshotFolder()
        try await snapshot(AIGenerateWindowView(conversation: Self.sampleConversation()), to: output.appendingPathComponent("conversation.png"))
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
    #else
    /// Writes pictures of the conversation screen of the device the tests run
    /// on, an iPhone or an iPad. Runs only when AI_CONVERSATION_SNAPSHOT_DIR
    /// names a folder; it asserts nothing about looks.
    func testWriteScreenSnapshotsWhenRequested() async throws {
        let output = try Self.snapshotFolder()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try await snapshot(NavigationStack { AIGenerateView(conversation: Self.sampleConversation()) },
                           to: output.appendingPathComponent("\(device)-conversation.png"))
        try await snapshot(NavigationStack { AIGenerateView() },
                           to: output.appendingPathComponent("\(device)-empty.png"))
    }

    private func snapshot(_ view: some View, to url: URL) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No window scene to draw in")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // The preview runs the widget off the main thread; give it time to arrive.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: url)
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

private actor Collected {
    private(set) var texts: [String] = []
    func append(_ text: String) { texts.append(text) }
}

/// Answers `http://conversation.test/v1/chat/completions` from a queue.
final class ConversationProviderStub: URLProtocol {
    enum Reply {
        case content(String)
        case status(Int)
        /// Never answers; the request ends only when it is cancelled.
        case hang
        /// Answered only in the plain form; the streamed form gets HTTP 400.
        case plainOnly(String)
    }

    private static let lock = NSLock()
    private static var queue: [Reply] = []
    private static var recordedBodies: [String] = []
    private static var recordedAuthorizations: [String] = []
    private static var recordedStreamFlags: [Bool] = []
    private static var refused = 0

    /// Whether each answered request asked for the streamed form.
    static var streamFlags: [Bool] { lock.withLock { recordedStreamFlags } }
    /// Streamed requests that were refused and asked again in the plain form.
    static var refusedStreams: Int { lock.withLock { refused } }

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
            recordedStreamFlags = []
            refused = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "conversation.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let wantsStream = object?["stream"] as? Bool ?? false
        // The JSON body escapes the text; undo that so tests can search for it.
        let messages = object?["messages"] as? [[String: Any]]
        let text = (messages ?? []).compactMap { $0["content"] as? String }.joined(separator: "\n---\n")
        let next: Reply? = Self.lock.withLock {
            // A server without streaming refuses the streamed form and is asked again.
            if wantsStream, case .plainOnly = Self.queue.first {
                Self.refused += 1
                return .status(400)
            }
            Self.recordedBodies.append(text)
            Self.recordedStreamFlags.append(wantsStream)
            Self.recordedAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return Self.queue.isEmpty ? .status(503) : Self.queue.removeFirst()
        }
        switch next ?? .status(503) {
        case .hang:
            return
        case .status(let code):
            respond(code, Data("{}".utf8))
        case .content(let content), .plainOnly(let content):
            let usage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15]
            guard wantsStream else {
                let payload: [String: Any] = [
                    "id": "stub", "object": "chat.completion", "created": 1, "model": "stub-model",
                    "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
                    "usage": usage,
                ]
                respond(200, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
                return
            }
            // Server-sent events: the text in pieces, then the usage, then the end mark.
            var events = ""
            var rest = Substring(content)
            while !rest.isEmpty {
                let piece = rest.prefix(7)
                rest = rest.dropFirst(7)
                let chunk: [String: Any] = ["choices": [["index": 0, "delta": ["content": String(piece)]]]]
                events += "data: " + Self.json(chunk) + "\n\n"
            }
            events += "data: " + Self.json(["choices": [], "usage": usage]) + "\n\n"
            events += "data: [DONE]\n\n"
            respond(200, Data(events.utf8), contentType: "text/event-stream")
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ data: Data, contentType: String = "application/json") {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType]
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
