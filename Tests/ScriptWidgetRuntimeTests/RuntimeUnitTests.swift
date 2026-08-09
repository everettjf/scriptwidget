//
//  RuntimeUnitTests.swift
//  ScriptWidgetRuntimeTests
//
//  Pure unit tests for the shared runtime. These intentionally avoid the
//  JSX→SwiftUI execution path (which needs the bundled Babel/util scripts and
//  an app/device context) and instead cover deterministic, side-effect-free
//  logic so they run reliably in CI.
//
//  Wiring (done once in Xcode, since the project references files explicitly):
//    1. File > New > Target… > Unit Testing Bundle, name it
//       "ScriptWidgetRuntimeTests", host application: ScriptWidget (iOS).
//    2. Add this file to that target.
//    3. Make sure the runtime sources under Shared/ScriptWidgetRuntime are in
//       the host app target (they already are) — @testable import exposes them.
//
//  If you host the tests on the macOS app instead, change the import below to
//  `@testable import ScriptWidgetMac`.
//

import XCTest
import JavaScriptCore
import ImageIO
// Both the iOS and macOS apps build with module name "ScriptWidget"
// (the macOS target "ScriptWidgetMac" ships PRODUCT_NAME = ScriptWidget).
@testable import ScriptWidget

final class AICopilotPromptTests: XCTestCase {
    func testSkillsAugmentPromptDeterministically() {
        let prompt = AIWidgetSkills.augment(
            "Build a calendar",
            selectedIDs: ["accessible-design", "responsive-layout"]
        )
        XCTAssertTrue(prompt.contains("Build a calendar"))
        XCTAssertTrue(prompt.contains("Responsive Layout"))
        XCTAssertTrue(prompt.contains("Accessible Design"))
        XCTAssertFalse(prompt.contains("Runtime Debugger"))
    }

    func testNoSelectedSkillsPreservesPrompt() {
        XCTAssertEqual(AIWidgetSkills.augment("hello", selectedIDs: []), "hello")
    }

    func testCopilotPromptIncludesCodeInstructionAndDiagnostic() {
        let prompt = PromptBuilder.userPromptCopilot(
            currentCode: "$render(<text>old</text>);",
            instruction: "Use a blue background",
            runtimeDiagnostic: "scriptException: boom"
        )
        XCTAssertTrue(prompt.contains("$render(<text>old</text>);"))
        XCTAssertTrue(prompt.contains("Use a blue background"))
        XCTAssertTrue(prompt.contains("scriptException: boom"))
        XCTAssertTrue(prompt.contains("FULL updated JSX"), prompt)
    }

    func testCopilotChangeSummaryCountsReplacementsAndAddedLines() {
        let summary = AICopilotChangeSummary.compare(
            original: "one\ntwo",
            proposed: "one\nchanged\nthree"
        )
        XCTAssertEqual(summary.originalLines, 2)
        XCTAssertEqual(summary.proposedLines, 3)
        XCTAssertEqual(summary.changedLines, 2)
    }
}

final class AIWidgetSkillTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testManifestValidationAcceptsValidSkillAndRejectsInvalidFields() {
        var manifest = AIWidgetSkillManifest.newSkill(name: "Weather Expert")
        XCTAssertTrue(AIWidgetSkillValidator.validate(manifest: manifest, instruction: "Prefer concise forecasts.").isValid)

        manifest.version = "latest"
        manifest.promptFile = "prompt.txt"
        let issueIDs = Set(AIWidgetSkillValidator.validate(manifest: manifest, instruction: "  ").issues.map(\.id))
        XCTAssertTrue(issueIDs.isSuperset(of: ["invalid_version", "invalid_prompt_file", "empty_instruction"]))
    }

    func testPackageRoundTripAndUnknownManifestKeyRejection() throws {
        let directory = makeTemporaryDirectory()
        let package = AIWidgetSkillPackage(directory: directory.appendingPathComponent("weather", isDirectory: true))
        let manifest = AIWidgetSkillManifest.newSkill(name: "Weather Expert")
        XCTAssertTrue(package.save(manifest: manifest, instruction: "Prefer concise forecasts.").0)
        XCTAssertEqual(package.load()?.0, manifest)
        XCTAssertEqual(package.load()?.1, "Prefer concise forecasts.")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: package.manifestURL)) as? [String: Any])
        object["executable"] = "payload.sh"
        try JSONSerialization.data(withJSONObject: object).write(to: package.manifestURL)
        XCTAssertNil(package.load(), "Unknown manifest capabilities must fail closed")
    }

    func testManagerCreateSaveDuplicateDeleteLifecycle() throws {
        let manager = AIWidgetSkillManager(directory: makeTemporaryDirectory())
        let created = manager.create(name: "Release Reviewer")
        XCTAssertTrue(created.0)
        let skillID = created.1
        var package = try XCTUnwrap(manager.package(for: skillID))
        var manifest = try XCTUnwrap(package.load()?.0)
        manifest.summary = "Checks a widget before release."
        XCTAssertTrue(manager.save(skillID: skillID, manifest: manifest, instruction: "Check fallbacks and accessibility.").0)

        let skill = try XCTUnwrap(manager.allSkills().first { $0.id == skillID })
        let duplicate = manager.duplicate(skill)
        XCTAssertTrue(duplicate.0)
        XCTAssertNotEqual(duplicate.1, skillID)
        XCTAssertTrue(manager.delete(skillID: skillID).0)
        package = AIWidgetSkillPackage(directory: package.directory)
        XCTAssertNil(package.load())
    }

    func testExportImportRoundTripAndDuplicateRejection() throws {
        let sourceManager = AIWidgetSkillManager(directory: makeTemporaryDirectory())
        let created = sourceManager.create(name: "Layout Coach")
        XCTAssertTrue(created.0)
        let archive = makeTemporaryDirectory().appendingPathComponent("layout.swskill")
        XCTAssertTrue(sourceManager.export(skillID: created.1, to: archive).0)

        let destinationManager = AIWidgetSkillManager(directory: makeTemporaryDirectory())
        let imported = destinationManager.importSkill(from: archive)
        XCTAssertTrue(imported.succeeded, imported.message)
        XCTAssertEqual(imported.skillID, created.1)
        XCTAssertFalse(destinationManager.importSkill(from: archive).succeeded)
    }

    func testOversizedArchiveIsRejectedBeforeExtraction() throws {
        let archive = makeTemporaryDirectory().appendingPathComponent("oversized.swskill")
        try Data(repeating: 0, count: AIWidgetSkillValidator.maximumPackageBytes + 1).write(to: archive)
        let result = AIWidgetSkillManager(directory: makeTemporaryDirectory()).importSkill(from: archive)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("256 KiB"))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIWidgetSkillTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

#if os(macOS)
final class MacOnboardingProgressStoreTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testFreshInstallPresentsAtWelcomeAndCompletingSuppressesIt() throws {
        let store = MacOnboardingProgressStore(defaults: makeDefaults())
        XCTAssertTrue(store.shouldPresent)
        XCTAssertEqual(store.currentStep, .welcome)

        store.complete()
        XCTAssertFalse(store.shouldPresent)
        XCTAssertEqual(store.currentStep, .welcome)
    }

    func testProgressResumesAndReplayRestartsWithoutLosingCompletion() throws {
        let defaults = makeDefaults()
        let store = MacOnboardingProgressStore(defaults: defaults)
        store.save(step: .preview)
        XCTAssertEqual(MacOnboardingProgressStore(defaults: defaults).currentStep, .preview)

        store.complete()
        store.restart()
        XCTAssertEqual(store.currentStep, .welcome)
        XCTAssertFalse(store.shouldPresent, "Replaying from Help must not turn onboarding back into a first-launch prompt")
    }

    func testTutorialHasFiveStableOrderedSteps() {
        XCTAssertEqual(MacTutorialStep.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(MacTutorialStep.allCases.count, 5)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "MacOnboardingProgressStoreTests.\(UUID().uuidString)"
        suiteNames.append(name)
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }
}
#endif

final class ScriptWidgetRuntimeElementTests: XCTestCase {

    private func makeElement() -> ScriptWidgetRuntimeElement {
        return ScriptWidgetRuntimeElement(
            tagString: "text",
            props: [
                "font": "title",
                "count": 3,
                "ratio": 0.5,
                "flag": true,
                "flagStr": "yes",
                "intStr": "42",
                "doubleStr": "1.5",
            ],
            children: ["hello"]
        )
    }

    func testTagAsString() {
        XCTAssertEqual(makeElement().tagAsString(), "text")
    }

    func testGetPropString() {
        let element = makeElement()
        XCTAssertEqual(element.getPropString("font"), "title")
        XCTAssertNil(element.getPropString("missing"))
    }

    func testGetPropStringFallback() {
        let element = makeElement()
        // Primary key missing -> falls back to the second key.
        XCTAssertEqual(element.getPropString("missing", or: "font"), "title")
        // Primary key present -> uses it.
        XCTAssertEqual(element.getPropString("font", or: "flagStr"), "title")
    }

    func testGetPropInt() {
        let element = makeElement()
        XCTAssertEqual(element.getPropInt("count"), 3)       // native Int
        XCTAssertEqual(element.getPropInt("intStr"), 42)     // string -> Int
        XCTAssertNil(element.getPropInt("font"))             // non-numeric string
        XCTAssertNil(element.getPropInt("missing"))
    }

    func testGetPropDouble() {
        let element = makeElement()
        XCTAssertEqual(element.getPropDouble("ratio"), 0.5)      // native Double
        XCTAssertEqual(element.getPropDouble("doubleStr"), 1.5)  // string -> Double
        XCTAssertNil(element.getPropDouble("font"))
    }

    func testGetPropBool() {
        let element = makeElement()
        XCTAssertEqual(element.getPropBool("flag"), true)        // native Bool
        XCTAssertEqual(element.getPropBool("flagStr"), true)     // "yes" -> true
        XCTAssertNil(element.getPropBool("font"))                // "title" -> nil
        XCTAssertNil(element.getPropBool("missing"))
    }

    func testGetPropBoolStringVariants() {
        let element = ScriptWidgetRuntimeElement(
            tagString: "x",
            props: ["a": "true", "b": "false", "c": "no", "d": "maybe"],
            children: nil
        )
        XCTAssertEqual(element.getPropBool("a"), true)
        XCTAssertEqual(element.getPropBool("b"), false)
        XCTAssertEqual(element.getPropBool("c"), false)
        XCTAssertNil(element.getPropBool("d"))
    }

    func testEmptyPropsAndChildrenDefaults() {
        let element = ScriptWidgetRuntimeElement(tagString: "x", props: nil, children: nil)
        XCTAssertTrue(element.getProps().isEmpty)
        XCTAssertTrue(element.getChildren().isEmpty)
        XCTAssertNil(element.getPropString("any"))
    }

    func testChildrenAsElementsFlattensNestedArraysAndDropsScalars() {
        let leaf1 = ScriptWidgetRuntimeElement(tagString: "a", props: nil, children: nil)
        let leaf2 = ScriptWidgetRuntimeElement(tagString: "b", props: nil, children: nil)
        let leaf3 = ScriptWidgetRuntimeElement(tagString: "c", props: nil, children: nil)

        // Mixed children: a bare element, a nested array of elements, and
        // scalar values that should be ignored by childrenAsElements().
        let parent = ScriptWidgetRuntimeElement(
            tagString: "root",
            props: nil,
            children: [leaf1, [leaf2, [leaf3]], "text node", 7]
        )

        let elements = parent.childrenAsElements()
        XCTAssertEqual(elements.map { $0.tagAsString() }, ["a", "b", "c"])
    }
}

final class ScriptWidgetErrorTests: XCTestCase {

    func testDisplayMessageReturnsUnderlyingMessage() {
        XCTAssertEqual(ScriptWidgetError.undefinedRender("u").displayMessage, "u")
        XCTAssertEqual(ScriptWidgetError.internalError("i").displayMessage, "i")
        XCTAssertEqual(ScriptWidgetError.transformError("t").displayMessage, "t")
        XCTAssertEqual(ScriptWidgetError.scriptError("s").displayMessage, "s")
        XCTAssertEqual(ScriptWidgetError.scriptException("e").displayMessage, "e")
        XCTAssertEqual(ScriptWidgetError.resourceLimit("r").displayMessage, "r")
    }

    func testDiagnosticIncludesCategoryAndRecovery() {
        let diagnostic = ScriptWidgetError.resourceLimit("too large").diagnosticMessage
        XCTAssertTrue(diagnostic.contains("[Resource Limit]"))
        XCTAssertTrue(diagnostic.contains("too large"))
        XCTAssertTrue(diagnostic.contains("Reduce"))
    }
}

final class RuntimeContractTests: XCTestCase {
    func testPublicAPIVersionAndGlobalsAreFixed() {
        XCTAssertEqual(ScriptWidgetRuntimeContract.apiVersion, "1.0")
        XCTAssertEqual(ScriptWidgetRuntimeContract.globalAPIs, ScriptWidgetRuntimeContract.globalAPIs.sorted())
        XCTAssertTrue(ScriptWidgetRuntimeContract.globalAPIs.contains("$render"))
        XCTAssertTrue(ScriptWidgetRuntimeContract.globalAPIs.contains("$runtime"))
    }

    func testSourceMemoryBudgetRejectsOversizedScripts() {
        let oversized = String(repeating: "x", count: ScriptWidgetRuntimeContract.maximumSourceBytes + 1)
        XCTAssertNotNil(ScriptWidgetRuntimeContract.validateSource(oversized))
        XCTAssertNil(ScriptWidgetRuntimeContract.validateSource("$render(<text>ok</text>)"))
    }

    func testBundledExamplesFitThePublishedSourceBudget() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let templates = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/ScriptWidgetRuntime/Resource/Script.bundle/template")
        let files = try FileManager.default.subpathsOfDirectory(atPath: templates.path)
            .filter { $0.hasSuffix("/main.jsx") }
        XCTAssertGreaterThan(files.count, 20)

        for relativePath in files {
            let source = try String(contentsOf: templates.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertNil(ScriptWidgetRuntimeContract.validateSource(source), relativePath)
        }
    }

    func testElementTreeAcceptsReasonableContent() {
        let children = (0..<20).map {
            ScriptWidgetRuntimeElement(tagString: "text", props: ["index": $0], children: ["row"])
        }
        let root = ScriptWidgetRuntimeElement(tagString: "vstack", props: nil, children: children)
        XCTAssertNil(ScriptWidgetRuntimeContract.validateElementTree(root))
    }

    func testElementTreeRejectsNodeBomb() {
        let children = (0..<ScriptWidgetRuntimeContract.maximumElementNodes).map { _ in
            ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: nil)
        }
        let root = ScriptWidgetRuntimeElement(tagString: "vstack", props: nil, children: children)
        XCTAssertNotNil(ScriptWidgetRuntimeContract.validateElementTree(root))
    }

    func testElementTreeRejectsExcessiveDepthAndCycles() {
        let root = ScriptWidgetRuntimeElement(tagString: "root", props: nil, children: nil)
        var cursor = root
        for _ in 0...ScriptWidgetRuntimeContract.maximumElementDepth {
            let child = ScriptWidgetRuntimeElement(tagString: "child", props: nil, children: nil)
            cursor.children = [child]
            cursor = child
        }
        XCTAssertNotNil(ScriptWidgetRuntimeContract.validateElementTree(root))

        let cycle = ScriptWidgetRuntimeElement(tagString: "cycle", props: nil, children: nil)
        cycle.children = [cycle]
        XCTAssertNotNil(ScriptWidgetRuntimeContract.validateElementTree(cycle))
    }

    func testElementTreeRejectsPropertyBomb() {
        var props: [AnyHashable: Any] = [:]
        for index in 0...ScriptWidgetRuntimeContract.maximumPropsPerElement { props["p\(index)"] = index }
        let root = ScriptWidgetRuntimeElement(tagString: "text", props: props, children: nil)
        XCTAssertNotNil(ScriptWidgetRuntimeContract.validateElementTree(root))
    }
}

final class RuntimeSecurityTests: XCTestCase {
    private func makePackage() -> ScriptWidgetPackage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptWidgetSecurity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ScriptWidgetPackage(path: directory)
    }

    func testPackagePathsCannotEscapeRoot() {
        let package = makePackage()
        XCTAssertNotNil(package.resolvedPackageURL(relativePath: "lib/helper.js"))
        XCTAssertNil(package.resolvedPackageURL(relativePath: "../secret.txt"))
        XCTAssertNil(package.resolvedPackageURL(relativePath: "/tmp/secret.txt"))
        XCTAssertFalse(package.writeFile(relativePath: "../secret.txt", content: "secret").0)
    }

    func testFetchPolicyAllowsPublicHTTPAndRejectsLocalResources() {
        XCTAssertNil(ScriptWidgetFetchPolicy.validationError(for: URL(string: "https://example.com/data.json")!))
        XCTAssertNotNil(ScriptWidgetFetchPolicy.validationError(for: URL(string: "file:///tmp/private")!))
        XCTAssertNotNil(ScriptWidgetFetchPolicy.validationError(for: URL(string: "http://localhost:8080")!))
        XCTAssertNotNil(ScriptWidgetFetchPolicy.validationError(for: URL(string: "http://192.168.1.2")!))
        XCTAssertNotNil(ScriptWidgetFetchPolicy.validationError(for: URL(string: "http://172.20.0.2")!))
    }

    func testFetchTimeoutAndStreamingLimitsAreClamped() {
        XCTAssertEqual(ScriptWidgetFetchPolicy.normalizedTimeout(nil), 5)
        XCTAssertEqual(ScriptWidgetFetchPolicy.normalizedTimeout(-20), 1)
        XCTAssertEqual(ScriptWidgetFetchPolicy.normalizedTimeout(500), 10)
        XCTAssertTrue(ScriptWidgetFetchPolicy.canAppend(currentBytes: 100, incomingBytes: 200, limit: 300))
        XCTAssertFalse(ScriptWidgetFetchPolicy.canAppend(currentBytes: 100, incomingBytes: 201, limit: 300))
        XCTAssertFalse(ScriptWidgetFetchPolicy.canAppend(currentBytes: 0, incomingBytes: 301, limit: 300))
    }

    func testPublishedResourceBudgetsRemainBounded() {
        XCTAssertLessThanOrEqual(ScriptWidgetRuntimeContract.maximumSourceBytes, 512 * 1_024)
        XCTAssertLessThanOrEqual(ScriptWidgetFetchManager.maximumResponseBytes, 2 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(ScriptWidgetRuntimeStorage.maximumValueBytes, 256 * 1_024)
        XCTAssertLessThanOrEqual(ScriptWidgetConsoleLogger.maximumEntries, 500)
    }
}

final class TranspileCacheTests: XCTestCase {

    override func tearDown() {
        ScriptWidgetTranspileCache.memoryCostLimit = 4 * 1_024 * 1_024
        ScriptWidgetTranspileCache.memoryCountLimit = 16
        ScriptWidgetTranspileCache.removeAllMemory()
        super.tearDown()
    }

    func testKeyIsDeterministic() {
        let a = ScriptWidgetTranspileCache.key(for: "source-abc", babelFingerprint: "fp1")
        let b = ScriptWidgetTranspileCache.key(for: "source-abc", babelFingerprint: "fp1")
        XCTAssertEqual(a, b)
    }

    func testKeyVariesWithSource() {
        let a = ScriptWidgetTranspileCache.key(for: "source-abc", babelFingerprint: "fp1")
        let b = ScriptWidgetTranspileCache.key(for: "source-abd", babelFingerprint: "fp1")
        XCTAssertNotEqual(a, b)
    }

    func testKeyVariesWithFingerprint() {
        let a = ScriptWidgetTranspileCache.key(for: "source-abc", babelFingerprint: "fp1")
        let b = ScriptWidgetTranspileCache.key(for: "source-abc", babelFingerprint: "fp2")
        XCTAssertNotEqual(a, b)
    }

    func testSetThenGetRoundTrips() {
        // Works via the in-memory layer even when the app group container is
        // unavailable in the test environment.
        let key = "test-\(UUID().uuidString)"
        XCTAssertNil(ScriptWidgetTranspileCache.get(key))
        ScriptWidgetTranspileCache.set(key, "transpiled-output")
        XCTAssertEqual(ScriptWidgetTranspileCache.get(key), "transpiled-output")
    }

    func testFingerprintIsStableForSameInput() {
        let f1 = ScriptWidgetTranspileCache.fingerprint(of: "babel-bundle-bytes")
        let f2 = ScriptWidgetTranspileCache.fingerprint(of: "babel-bundle-bytes")
        XCTAssertFalse(f1.isEmpty)
        XCTAssertEqual(f1, f2)
    }

    func testMemoryCacheHasExplicitBounds() {
        ScriptWidgetTranspileCache.memoryCostLimit = 1_024
        ScriptWidgetTranspileCache.memoryCountLimit = 2
        XCTAssertEqual(ScriptWidgetTranspileCache.memoryCostLimit, 1_024)
        XCTAssertEqual(ScriptWidgetTranspileCache.memoryCountLimit, 2)
    }

    func testDiskCacheTrimKeepsNewestEntriesWithinBothBounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranspileTrim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<5 {
            let url = directory.appendingPathComponent("entry-\(index)")
            try Data(repeating: UInt8(index), count: 10).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))], ofItemAtPath: url.path)
        }

        ScriptWidgetTranspileCache.trim(directory: directory, maximumBytes: 25, maximumEntries: 3)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["entry-3", "entry-4"])
    }
}

final class RuntimePerformanceTraceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ScriptWidgetRuntimeTrace.resetForTesting()
    }

    func testTracePublishesBoundedDurationsAndCounters() {
        let trace = ScriptWidgetRuntimeTrace(operation: "unit-test")
        let value: Int = trace.measure("phase") { 42 }
        trace.increment("bytes", by: 128)
        trace.finish()

        XCTAssertEqual(value, 42)
        let snapshot = ScriptWidgetRuntimeTrace.recentSnapshots().last
        XCTAssertEqual(snapshot?.operation, "unit-test")
        XCTAssertEqual(snapshot?.counters["bytes"], 128)
        XCTAssertNotNil(snapshot?.durations["phase"])
        XCTAssertGreaterThanOrEqual(snapshot?.durations["total"] ?? -1, 0)
    }

    func testTraceHistoryIsBounded() {
        for index in 0..<140 {
            ScriptWidgetRuntimeTrace(operation: "run-\(index)").finish()
        }
        XCTAssertEqual(ScriptWidgetRuntimeTrace.recentSnapshots().count, 100)
        XCTAssertEqual(ScriptWidgetRuntimeTrace.recentSnapshots().first?.operation, "run-40")
    }
}

final class StudioDraftStoreTests: XCTestCase {
    private var directory: URL!
    private var store: StudioDraftStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioDraftStore-\(UUID().uuidString)", isDirectory: true)
        store = StudioDraftStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
        super.tearDown()
    }

    func testDraftRecoversWhenBaseFileIsUnchanged() {
        store.save(documentID: "/widget/main.jsx", baseContent: "saved", content: "unsaved")
        XCTAssertEqual(
            store.recover(documentID: "/widget/main.jsx", currentContent: "saved")?.content,
            "unsaved"
        )
    }

    func testExternalOrICloudChangePreventsStaleDraftRestore() {
        store.save(documentID: "/widget/main.jsx", baseContent: "saved", content: "unsaved")
        XCTAssertNil(store.recover(documentID: "/widget/main.jsx", currentContent: "changed elsewhere"))
    }

    func testSavingBaselineRemovesDraft() {
        store.save(documentID: "/widget/main.jsx", baseContent: "saved", content: "unsaved")
        store.save(documentID: "/widget/main.jsx", baseContent: "saved", content: "saved")
        XCTAssertNil(store.recover(documentID: "/widget/main.jsx", currentContent: "saved"))
    }
}

final class ProjectFileImportTests: XCTestCase {
    private var packageDirectory: URL!
    private var sourceDirectory: URL!
    private var package: ScriptWidgetPackage!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectFileImportTests-\(UUID().uuidString)", isDirectory: true)
        packageDirectory = root.appendingPathComponent("Widget", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        try? FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        package = ScriptWidgetPackage(path: packageDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: packageDirectory.deletingLastPathComponent())
        package = nil
        packageDirectory = nil
        sourceDirectory = nil
        super.tearDown()
    }

    func testTextImportUsesPackageRootAndDeduplicatesWithoutOverwrite() throws {
        let source = sourceDirectory.appendingPathComponent("helpers.js")
        try "first".write(to: source, atomically: true, encoding: .utf8)

        XCTAssertEqual(package.importProjectFile(from: source).1, "helpers.js")
        try "second".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(package.importProjectFile(from: source).1, "helpers-2.js")

        XCTAssertEqual(package.readFile(relativePath: "helpers.js").0, "first")
        XCTAssertEqual(package.readFile(relativePath: "helpers-2.js").0, "second")
    }

    func testImageImportUsesRuntimeImageDirectory() throws {
        let source = sourceDirectory.appendingPathComponent("weather.png")
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        try payload.write(to: source)

        XCTAssertEqual(package.importProjectFile(from: source).1, "image/weather.png")
        XCTAssertEqual(try Data(contentsOf: packageDirectory.appendingPathComponent("image/weather.png")), payload)
    }

    func testImportedJPEGResolvesByBareRuntimeImageName() throws {
        let source = sourceDirectory.appendingPathComponent("forecast.jpg")
        let payload = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try payload.write(to: source)

        XCTAssertTrue(package.importProjectFile(from: source).0)
        let image = try XCTUnwrap(package.getImage("forecast"))
        XCTAssertEqual(image.path.pathExtension.lowercased(), "jpg")
        XCTAssertEqual(try Data(contentsOf: image.path), payload)
    }

    func testImportRejectsResourceOverConfiguredLimit() throws {
        let source = sourceDirectory.appendingPathComponent("large.json")
        try Data(repeating: 0x41, count: 16).write(to: source)
        let result = package.importProjectFile(from: source, maximumBytes: 8)
        XCTAssertFalse(result.0)
        XCTAssertFalse(package.isFileExist(relativePath: "large.json"))
    }
}

final class CompiledArtifactTests: XCTestCase {
    private var package: ScriptWidgetPackage!

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompiledArtifact-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        package = ScriptWidgetPackage(path: directory)
        ScriptWidgetCompiledArtifactStore.remove(package: package)
    }

    override func tearDown() {
        ScriptWidgetCompiledArtifactStore.remove(package: package)
        try? FileManager.default.removeItem(at: package.path)
        package = nil
        super.tearDown()
    }

    func testArtifactRoundTripValidatesEveryHash() throws {
        let source = "$render(<text>compiled</text>);"
        let javaScript = "async function $main(){return 1;}"
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: package, source: source, javaScript: javaScript))
        let artifact = try XCTUnwrap(ScriptWidgetCompiledArtifactStore.load(package: package, source: source))
        XCTAssertEqual(artifact.javaScript, javaScript)
        XCTAssertEqual(artifact.manifest.formatVersion, ScriptWidgetBuildManifest.formatVersion)
        XCTAssertEqual(artifact.manifest.compilerFingerprint, ScriptWidgetCompiler.fingerprint)
        XCTAssertEqual(artifact.manifest.sourceBytes, source.utf8.count)
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.load(package: package, source: source + "// changed"))
    }

    func testCorruptCompiledBytesAreRejected() throws {
        let source = "$render(<text>safe</text>);"
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: package, source: source, javaScript: "valid"))
        let directory = try XCTUnwrap(ScriptWidgetCompiledArtifactStore.artifactDirectory(package: package))
        try Data("tampered".utf8).write(to: directory.appendingPathComponent(ScriptWidgetCompiledArtifactStore.javaScriptName))
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.load(package: package, source: source))
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: package))
    }

    func testLastKnownGoodRemainsAvailableAcrossSourceRevision() throws {
        let original = "$render(<text>stable</text>);"
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: package, source: original, javaScript: "stable-js"))
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.load(package: package, source: original + " broken"))
        XCTAssertEqual(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: package)?.javaScript, "stable-js")
    }

    func testMomentCapabilityInferenceIsConservative() {
        XCTAssertEqual(ScriptWidgetCompiledArtifactStore.inferredLibraries(source: "moment().endOf('year')"), ["moment"])
        XCTAssertEqual(ScriptWidgetCompiledArtifactStore.inferredLibraries(source: "moment.utc()"), ["moment"])
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.inferredLibraries(source: "new Date()").isEmpty)
    }

    func testPrecompilerProducesExecutableArtifact() throws {
        let source = "$render(<text>ready</text>);"
        let result = ScriptWidgetPrecompiler.compileNow(package: package, source: source)
        guard case .success(let artifact) = result else {
            return XCTFail("precompile failed: \(result)")
        }
        XCTAssertTrue(artifact.javaScript.contains("$main"))
        XCTAssertNotNil(ScriptWidgetCompiledArtifactStore.load(package: package, source: source))
    }
}

final class ExecutionSessionTests: XCTestCase {
    func testSessionRejectsWorkAfterCancellation() {
        let session = ScriptWidgetExecutionSession()
        XCTAssertTrue(session.isActive)
        session.cancel(.superseded)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.cancellation, .superseded)
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.com")!)
        XCTAssertFalse(session.register(task))
    }

    func testNetworkConcurrencyBudgetIsEnforced() {
        let session = ScriptWidgetExecutionSession()
        var tasks: [URLSessionDataTask] = []
        for index in 0..<ScriptWidgetExecutionSession.maximumConcurrentNetworkRequests {
            let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/\(index)")!)
            tasks.append(task)
            XCTAssertTrue(session.register(task))
        }
        let overflow = URLSession.shared.dataTask(with: URL(string: "https://example.com/overflow")!)
        XCTAssertFalse(session.register(overflow))
        session.complete(tasks[0])
        XCTAssertTrue(session.register(overflow))
        session.cancel(.explicit)
    }

    func testFinishIsIdempotentAndPreservesFirstReason() {
        let session = ScriptWidgetExecutionSession()
        session.cancel(.timeout)
        session.finish()
        XCTAssertEqual(session.cancellation, .timeout)
    }
}

final class ImagePipelineTests: XCTestCase {
    override func tearDown() {
        ScriptWidgetImagePipeline.removeAll()
        super.tearDown()
    }

    func testImageIsDownsampledToBoundedPixelSize() throws {
        let data = try makePNG(width: 512, height: 256)
        let image = try XCTUnwrap(ScriptWidgetImagePipeline.image(data: data, maximumPixelSize: 64))
#if os(macOS)
        let representation = try XCTUnwrap(image.representations.first)
        // NSImage creates a Retina representation for the bounded thumbnail.
        XCTAssertLessThanOrEqual(max(representation.pixelsWide, representation.pixelsHigh), 128)
#else
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 64)
#endif
    }

    func testOversizedInputIsRejectedBeforeDecode() {
        let data = Data(repeating: 0, count: ScriptWidgetImagePipeline.maximumInputBytes + 1)
        XCTAssertNil(ScriptWidgetImagePipeline.image(data: data))
    }

    func testInvalidImageDataIsRejected() {
        XCTAssertNil(ScriptWidgetImagePipeline.image(data: Data("not-an-image".utf8)))
    }

    func testRemoteImageIsResolvedSynchronouslyAndDownsampled() throws {
        let data = try makePNG(width: 2_048, height: 1_024)
        var fetchCount = 0
        let url = URL(string: "https://example.com/widget-image.png")!
        let image = try XCTUnwrap(ScriptWidgetImagePipeline.synchronousRemoteImage(at: url, timeout: 99) { receivedURL, timeout in
            fetchCount += 1
            XCTAssertEqual(receivedURL, url)
            XCTAssertEqual(timeout, 3)
            return data
        })
        XCTAssertEqual(fetchCount, 1)
#if os(macOS)
        let representation = try XCTUnwrap(image.representations.first)
        XCTAssertLessThanOrEqual(max(representation.pixelsWide, representation.pixelsHigh), 2_048)
#else
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), ScriptWidgetImagePipeline.defaultMaximumPixelSize)
#endif
    }

    func testRemoteImageUsesSynchronousMemoryCache() throws {
        let data = try makePNG(width: 64, height: 64)
        let url = URL(string: "https://example.com/cached-widget-image.png")!
        XCTAssertNotNil(ScriptWidgetImagePipeline.synchronousRemoteImage(at: url) { _, _ in data })
        var secondFetchCalled = false
        XCTAssertNotNil(ScriptWidgetImagePipeline.synchronousRemoteImage(at: url) { _, _ in
            secondFetchCalled = true
            return nil
        })
        XCTAssertFalse(secondFetchCalled)
    }

    func testRemoteImageRejectsPrivateHostsAndOversizedResponses() throws {
        var fetchCalled = false
        XCTAssertNil(ScriptWidgetImagePipeline.synchronousRemoteImage(at: URL(string: "http://localhost/image.png")!) { _, _ in
            fetchCalled = true
            return try? self.makePNG(width: 10, height: 10)
        })
        XCTAssertFalse(fetchCalled)

        let oversized = Data(repeating: 0, count: ScriptWidgetFetchManager.maximumResponseBytes + 1)
        XCTAssertNil(ScriptWidgetImagePipeline.synchronousRemoteImage(at: URL(string: "https://example.com/too-large.png")!) { _, _ in oversized })
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class DescribeExceptionTests: XCTestCase {

    func testNilExceptionDescribesUnknown() {
        XCTAssertEqual(ScriptWidgetRuntime.describeException(nil), "unknown error")
    }

    func testDescribesThrownErrorMessage() {
        let context = JSContext()!
        var captured: JSValue?
        context.exceptionHandler = { _, exception in captured = exception }
        context.evaluateScript("throw new Error('boom problem')")

        XCTAssertNotNil(captured)
        let description = ScriptWidgetRuntime.describeException(captured)
        XCTAssertTrue(description.contains("boom problem"), "unexpected description: \(description)")
    }
}

final class WidgetPackageManifestTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func makePackage() throws -> ScriptWidgetPackage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let package = ScriptWidgetPackage(path: directory)
        XCTAssertTrue(package.writeMainFile(content: "<Text>Package 2.0</Text>").0)
        return package
    }

    func testManifestRoundTripsAndValidates() throws {
        let package = try makePackage()
        var manifest = WidgetPackageManifest.newProject(name: "My Widget")
        manifest.permissions = [.network, .storage]
        manifest.networkDomains = ["api.example.com", "*.example.org"]

        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertEqual(package.readManifest(), manifest)
        XCTAssertTrue(WidgetPackageManifestValidator.validate(manifest, package: package).isValid)
    }

    func testNetworkDomainsRequirePermissionAndValidHosts() throws {
        let package = try makePackage()
        var manifest = WidgetPackageManifest.newProject(name: "Unsafe Widget")
        manifest.networkDomains = ["https://example.com/path"]

        let codes = Set(WidgetPackageManifestValidator.validate(manifest, package: package).errors.map(\.code))
        XCTAssertTrue(codes.contains("undeclared_network"))
        XCTAssertTrue(codes.contains("invalid_network_domain"))
    }

    func testManifestReaderRejectsUnknownFields() throws {
        let package = try makePackage()
        let json = """
        {"formatVersion":2,"id":"com.example.widget","name":"Widget","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[],"permisisons":["network"]}
        """
        try Data(json.utf8).write(to: package.manifestPath)
        XCTAssertNil(package.readManifest())
    }

    func testRejectsUnsupportedRuntimeAndEscapingEntry() throws {
        let package = try makePackage()
        var manifest = WidgetPackageManifest.newProject(name: "Bad Widget")
        manifest.runtimeVersion = "99.0"
        manifest.entry = "../outside.jsx"

        let codes = Set(WidgetPackageManifestValidator.validate(manifest, package: package).errors.map(\.code))
        XCTAssertTrue(codes.contains("unsupported_runtime"))
        XCTAssertTrue(codes.contains("invalid_entry"))
    }

    func testArchivePreflightRejectsTraversalPath() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("Traversal-\(UUID().uuidString).swt")
        temporaryDirectories.append(archive)
        try makeStoredZIP(entryName: "../escape.txt", contents: Data("owned".utf8)).write(to: archive)

        XCTAssertEqual(
            ScriptPackageArchivePreflight.validate(archive),
            "Archive contains an unsafe or non-UTF-8 path."
        )
    }

    func testArchivePreflightRejectsCaseCollidingPaths() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("Collision-\(UUID().uuidString).swt")
        temporaryDirectories.append(archive)
        let first = makeStoredZIP(entryName: "Widget/main.jsx", contents: Data("one".utf8))
        let second = makeStoredZIP(entryName: "widget/MAIN.jsx", contents: Data("two".utf8))
        try mergeStoredZIPs(first, second).write(to: archive)

        XCTAssertEqual(
            ScriptPackageArchivePreflight.validate(archive),
            "Archive contains duplicate or case-colliding paths."
        )
    }

    private func makeStoredZIP(entryName: String, contents: Data) -> Data {
        let name = Data(entryName.utf8)
        var local = Data()
        local.appendLE(UInt32(0x04034B50)); local.appendLE(UInt16(20)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
        local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt32(0))
        local.appendLE(UInt32(contents.count)); local.appendLE(UInt32(contents.count)); local.appendLE(UInt16(name.count)); local.appendLE(UInt16(0))
        local.append(name); local.append(contents)

        var central = Data()
        central.appendLE(UInt32(0x02014B50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
        central.appendLE(UInt32(contents.count)); central.appendLE(UInt32(contents.count)); central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(UInt32(0)); central.append(name)

        var result = local
        result.append(central)
        result.appendLE(UInt32(0x06054B50)); result.appendLE(UInt16(0)); result.appendLE(UInt16(0)); result.appendLE(UInt16(1)); result.appendLE(UInt16(1))
        result.appendLE(UInt32(central.count)); result.appendLE(UInt32(local.count)); result.appendLE(UInt16(0))
        return result
    }

    private func mergeStoredZIPs(_ first: Data, _ second: Data) -> Data {
        let firstEOCD = first.count - 22
        let secondEOCD = second.count - 22
        let firstCentralOffset = Int(first.uint32LEForTest(at: firstEOCD + 16))
        let secondCentralOffset = Int(second.uint32LEForTest(at: secondEOCD + 16))
        let firstLocal = first.prefix(firstCentralOffset)
        let secondLocal = second.prefix(secondCentralOffset)
        let firstCentral = Data(first[firstCentralOffset..<firstEOCD])
        var secondCentral = Data(second[secondCentralOffset..<secondEOCD])
        secondCentral.replaceUInt32LEForTest(at: 42, with: UInt32(firstLocal.count))
        var result = Data(firstLocal); result.append(secondLocal); result.append(firstCentral); result.append(secondCentral)
        result.appendLE(UInt32(0x06054B50)); result.appendLE(UInt16(0)); result.appendLE(UInt16(0)); result.appendLE(UInt16(2)); result.appendLE(UInt16(2))
        result.appendLE(UInt32(firstCentral.count + secondCentral.count)); result.appendLE(UInt32(firstLocal.count + secondLocal.count)); result.appendLE(UInt16(0))
        return result
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint32LEForTest(at index: Int) -> UInt32 {
        UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }

    mutating func replaceUInt32LEForTest(at index: Int, with value: UInt32) {
        var encoded = Data(); encoded.appendLE(value)
        replaceSubrange(index..<(index + 4), with: encoded)
    }
}
