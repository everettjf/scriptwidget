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
import Combine
import ZipArchive
import JavaScriptCore
import ImageIO
import CryptoKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AppIntents
import UIKit
#elseif os(macOS)
import AppKit
#endif
#if canImport(AppIntentsTesting)
import AppIntentsTesting
#endif
// Both the iOS and macOS apps build with module name "ScriptWidget"
// (the macOS target "ScriptWidgetMac" ships PRODUCT_NAME = ScriptWidget).
@testable import ScriptWidget

/// Skips a test that reads the repository checkout through `#filePath`. Such
/// tests run on Simulator and macOS; a physical device cannot see the Mac's disk.
func skipUnlessRepositoryCheckout(_ directory: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw XCTSkip("Reads the repository checkout; runs on Simulator and macOS, not on a device.")
    }
}

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

final class ScriptWidgetFrameTests: XCTestCase {
    func testSquareFrameShorthandMatchesExplicitDimensions() {
        for value: Any in ["64", 64, 64.0, NSNumber(value: 64)] {
            let shorthand = ScriptWidgetAttributeFrameModifier(.init(tagString: "ring", props: ["frame": value], children: nil))
            let explicit = ScriptWidgetAttributeFrameModifier(.init(tagString: "ring", props: ["frame": "64,64"], children: nil))
            XCTAssertEqual(shorthand.frameMode, explicit.frameMode)
            XCTAssertEqual(shorthand.width, 64)
            XCTAssertEqual(shorthand.height, 64)
        }
        for value: Any in ["-1", "nan", "inf", true] {
            let invalid = ScriptWidgetAttributeFrameModifier(.init(tagString: "ring", props: ["frame": value], children: nil))
            XCTAssertEqual(invalid.frameMode, .none)
        }
    }

    func testExtraLargePreviewMatchesWideDesignHint() {
        XCTAssertEqual(AIWidgetSize.extraLarge.previewSize.width, 639)
        XCTAssertEqual(AIWidgetSize.extraLarge.previewSize.height, 345)
    }
}

final class ScriptWidgetBackgroundTests: XCTestCase {
    func testNamedColorWithOpacityIsParsed() {
        XCTAssertNotNil(ScriptWidgetAttributeColor("green,0.5").color)
        XCTAssertNil(ScriptWidgetAttributeColor("not-a-color,0.5").color)
    }

    func testOnlyConfiguredRootUsesWidgetContainerBackground() {
        let child = ScriptWidgetRuntimeElement(
            tagString: "text",
            props: ["background": "blue"],
            children: ["Nested"]
        )
        let root = ScriptWidgetRuntimeElement(
            tagString: "vstack",
            props: ["background": "green"],
            children: [child]
        )
        let equivalentButDistinctRoot = ScriptWidgetRuntimeElement(
            tagString: "vstack",
            props: ["background": "green"],
            children: [child]
        )
        let context = ScriptWidgetElementContext(
            runtime: nil,
            debugMode: false,
            scriptName: "BackgroundTest",
            scriptParameter: "",
            package: globalScriptWidgetPackage,
            containerBackgroundElement: root
        )

        XCTAssertTrue(context.usesContainerBackground(for: root))
        XCTAssertFalse(context.usesContainerBackground(for: child))
        XCTAssertFalse(context.usesContainerBackground(for: equivalentButDistinctRoot))
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
        XCTAssertEqual(ScriptWidgetRuntimeContract.apiVersion, "1.6")
        XCTAssertEqual(ScriptWidgetRuntimeContract.globalAPIs, ScriptWidgetRuntimeContract.globalAPIs.sorted())
        XCTAssertTrue(ScriptWidgetRuntimeContract.globalAPIs.contains("$render"))
        XCTAssertTrue(ScriptWidgetRuntimeContract.globalAPIs.contains("$runtime"))
        XCTAssertTrue(ScriptWidgetRuntimeContract.globalAPIs.contains("$xml"))
    }

    func testSourceMemoryBudgetRejectsOversizedScripts() {
        let oversized = String(repeating: "x", count: ScriptWidgetRuntimeContract.maximumSourceBytes + 1)
        XCTAssertNotNil(ScriptWidgetRuntimeContract.validateSource(oversized))
        XCTAssertNil(ScriptWidgetRuntimeContract.validateSource("$render(<text>ok</text>)"))
    }

    func testBundledExamplesFitThePublishedSourceBudget() throws {
        try skipUnlessRepositoryCheckout(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
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

    func testDocumentSessionRestoresDraftTracksBaselineAndClearsAfterSave() {
        store.save(documentID: "/widget/main.jsx", baseContent: "saved", content: "draft")
        let session = StudioDocumentSession(drafts: store)

        XCTAssertEqual(session.open(documentID: "/widget/main.jsx", content: "saved"), "draft")
        XCTAssertFalse(session.needsSave("saved"))
        XCTAssertTrue(session.needsSave("draft"))

        session.markSaved("draft")
        XCTAssertFalse(session.needsSave("draft"))
        XCTAssertNil(store.recover(documentID: "/widget/main.jsx", currentContent: "draft"))
    }

    func testFailedSaveRetainsDraftAndRejectsStaleDocument() {
        let session = StudioDocumentSession(drafts: store)
        _ = session.open(documentID: "/widget/a.jsx", content: "original")
        XCTAssertFalse(session.save("edits", documentID: "/widget/a.jsx", writer: { _ in false }))
        XCTAssertEqual(session.savedContent, "original")
        XCTAssertEqual(store.recover(documentID: "/widget/a.jsx", currentContent: "original")?.content, "edits")
        _ = session.open(documentID: "/widget/b.jsx", content: "other")
        var wrote = false
        XCTAssertFalse(session.save("stale-a", documentID: "/widget/a.jsx", writer: { _ in wrote = true; return true }))
        XCTAssertFalse(wrote)
        XCTAssertEqual(session.savedContent, "other")
    }

    func testDocumentSessionDraftNeverCrossesDocumentIdentity() {
        let session = StudioDocumentSession(drafts: store)
        _ = session.open(documentID: "/widget/a.jsx", content: "a")
        session.recordDraft("draft-a")
        _ = session.open(documentID: "/widget/b.jsx", content: "b")
        session.recordDraft("draft-b")

        XCTAssertEqual(store.recover(documentID: "/widget/a.jsx", currentContent: "a")?.content, "draft-a")
        XCTAssertEqual(store.recover(documentID: "/widget/b.jsx", currentContent: "b")?.content, "draft-b")
    }

    @MainActor func testClosingHandoffWaitsForAllEditorsAndKeepsPathsIndependent() {
        let id = directory.appendingPathComponent("main.jsx").path
        let first = StudioDocumentHandoff.begin(id), second = StudioDocumentHandoff.begin(id)
        var recovered: String?
        StudioDocumentHandoff.afterClosing(id) {
            recovered = self.store.recover(documentID: id, currentContent: "base")?.content
        }
        var otherOpened = false
        StudioDocumentHandoff.afterClosing(id + ".other") { otherOpened = true }
        XCTAssertTrue(otherOpened)
        store.save(documentID: id, baseContent: "base", content: "first")
        StudioDocumentHandoff.finish(id, token: first)
        StudioDocumentHandoff.finish(id, token: first)
        XCTAssertNil(recovered)
        store.save(documentID: id, baseContent: "base", content: "last")
        StudioDocumentHandoff.finish(id, token: second)
        XCTAssertEqual(recovered, "last")
    }

    func testBufferedEditsUseUTF16OffsetsAndRecoverWithoutAnAsyncRead() {
        let session = StudioDocumentSession(drafts: store)
        _ = session.open(documentID: "/widget/main.jsx", content: "A\u{1F642}Bcd")
        XCTAssertTrue(session.bufferChange(["version": 1, "changes": [
            ["from": 0, "to": 1, "insert": "Start"],
            ["from": 4, "to": 6, "insert": "end"],
        ]]))
        session.persistBufferedDraft()
        let reopened = StudioDocumentSession(drafts: store)
        XCTAssertEqual(reopened.open(documentID: "/widget/main.jsx", content: "A\u{1F642}Bcd"), "Start\u{1F642}Bend")
        XCTAssertEqual(reopened.bufferedVersion, 0)
        _ = session.open(documentID: "/widget/combining.jsx", content: "Ae\u{301}B")
        XCTAssertTrue(session.bufferChange(["version": 1, "changes": [["from": 2, "to": 3, "insert": "X"]]]))
        XCTAssertEqual(session.bufferedContent, "AeXB")
    }

    func testMalformedOrOutOfOrderBufferedEditsAreAtomic() {
        let session = StudioDocumentSession(drafts: store)
        _ = session.open(documentID: "/widget/main.jsx", content: "A\u{1F642}B")
        // The rightmost replacement succeeds locally, then a split surrogate
        // boundary fails: neither replacement may reach the recovery buffer.
        XCTAssertFalse(session.bufferChange(["version": 1, "changes": [
            ["from": 2, "to": 3, "insert": "bad"],
            ["from": 3, "to": 4, "insert": "good"],
        ]]))
        XCTAssertEqual(session.bufferedContent, "A\u{1F642}B")
        XCTAssertEqual(session.bufferedVersion, 0)
        XCTAssertFalse(session.bufferChange(["version": 2, "changes": [["from": 0, "to": 1, "insert": "gap"]]]))
        XCTAssertFalse(session.bufferChange(["version": 1, "changes": [
            ["from": 0, "to": 3, "insert": "overlap"],
            ["from": 1, "to": 3, "insert": "overlap"],
        ]]))
        XCTAssertEqual(session.bufferedContent, "A\u{1F642}B")
        session.persistBufferedDraft()
        XCTAssertNil(store.recover(documentID: "/widget/main.jsx", currentContent: "A\u{1F642}B"))
    }

    func testOlderSnapshotsCannotOverwriteBufferedManualEdits() {
        let session = StudioDocumentSession(drafts: store)
        _ = session.open(documentID: "/widget/main.jsx", content: "base")
        XCTAssertTrue(session.bufferSnapshot("proposal", version: 4))
        XCTAssertTrue(session.bufferChange(["version": 5, "changes": [["from": 0, "to": 8, "insert": "manual"]]]))
        XCTAssertFalse(session.bufferSnapshot("proposal", version: 4))
        session.persistBufferedDraft()
        XCTAssertEqual(store.recover(documentID: "/widget/main.jsx", currentContent: "base")?.content, "manual")
        _ = session.open(documentID: "/widget/other.jsx", content: "other")
        XCTAssertEqual(session.bufferedVersion, 0)
        XCTAssertEqual(session.bufferedContent, "other")
    }

    func testStudioSnapshotNormalizesReverseSelection() throws {
        let snapshot = try XCTUnwrap(StudioDocumentSnapshot(state: [
            "content": "hello",
            "version": 4,
            "selection": ["from": 5, "to": 2],
        ]))
        XCTAssertEqual(snapshot.content, "hello")
        XCTAssertEqual(snapshot.version, 4)
        XCTAssertEqual(snapshot.selection, 2..<5)
        XCTAssertNil(StudioDocumentSnapshot(state: ["version": 1]))
    }
}

final class StudioEditorBundleIntegrationTests: XCTestCase {
    func testEmbeddedBundleContainsNativeAndWebStudioEntrypointsAndAssets() throws {
        let outerURL = try XCTUnwrap(Bundle.main.url(forResource: "StudioEditor", withExtension: "bundle"))
        let studioBundle = try XCTUnwrap(Bundle(url: outerURL))
        let resourceURL = try XCTUnwrap(studioBundle.resourceURL)
        let indexURL = resourceURL.appendingPathComponent("index.html")
        let html = try String(contentsOf: indexURL, encoding: .utf8)

        XCTAssertTrue(html.contains("id=\"native-editor\""))
        XCTAssertTrue(html.contains("id=\"web-studio\""))
        XCTAssertTrue(html.contains("ScriptWidget Web Studio"))

        let expression = try NSRegularExpression(pattern: #"(?:src|href)=\"\./([^\"]+)\""#)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let assets = expression.matches(in: html, range: range).compactMap { match -> String? in
            guard let assetRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[assetRange])
        }
        XCTAssertFalse(assets.isEmpty)
        for asset in assets {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent(asset).path), "Missing Studio asset: \(asset)")
        }
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

    func testWWDC26ManifestCapabilitiesRoundTripAndValidate() throws {
        let package = try makePackage()
        var manifest = WidgetPackageManifest.newProject(name: "Modern Widget")
        manifest.supportedFamilies.append(.systemExtraLargePortrait)
        manifest.permissions = [.network, .storage]
        manifest.networkDomains = ["push.example.com"]
        manifest.actions = [
            .init(
                id: "refresh",
                title: "Refresh Dashboard",
                description: "Fetch the latest dashboard data",
                systemImage: "arrow.clockwise",
                function: "refreshWidget"
            ),
            .init(
                id: "focus",
                title: "Set Focus",
                description: nil,
                systemImage: "timer",
                function: "setFocus"
            ),
        ]
        manifest.controls = [
            .init(
                id: "refresh",
                type: .button,
                title: "Refresh",
                subtitle: nil,
                systemImage: "arrow.clockwise",
                action: nil,
                actionID: "refresh",
                stateKey: nil
            ),
            .init(
                id: "focus",
                type: .toggle,
                title: "Focus",
                subtitle: "Focus mode",
                systemImage: "timer",
                action: nil,
                actionID: "focus",
                stateKey: "focus.enabled"
            ),
        ]
        manifest.pushUpdates = .init(
            registrationURL: "https://push.example.com/widget/register",
            channel: "modern-widget"
        )

        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertEqual(package.readManifest(), manifest)
        XCTAssertTrue(WidgetPackageManifestValidator.validate(manifest, package: package).isValid)
    }

    func testActionReferencesFailClosed() throws {
        let package = try makePackage()
        var manifest = WidgetPackageManifest.newProject(name: "Broken Actions")
        manifest.actions = [
            .init(id: "duplicate", title: "First", description: nil, systemImage: "play", function: "run"),
            .init(id: "DUPLICATE", title: "", description: String(repeating: "x", count: 161), systemImage: "../bad", function: "run()"),
        ]
        manifest.controls = [
            .init(id: "missing", type: .button, title: "Missing", subtitle: nil, systemImage: "play", action: nil, actionID: "unknown", stateKey: nil),
            .init(id: "ambiguous", type: .button, title: "Ambiguous", subtitle: nil, systemImage: "play", action: "run", actionID: "duplicate", stateKey: nil),
        ]

        let codes = Set(WidgetPackageManifestValidator.validate(manifest, package: package).errors.map(\.code))
        XCTAssertTrue(codes.contains("duplicate_actions"))
        XCTAssertTrue(codes.contains("invalid_action_title"))
        XCTAssertTrue(codes.contains("invalid_action_description"))
        XCTAssertTrue(codes.contains("invalid_action_image"))
        XCTAssertTrue(codes.contains("invalid_action_function"))
        XCTAssertTrue(codes.contains("missing_control_action"))
        XCTAssertTrue(codes.contains("ambiguous_control_action"))
    }

    func testControlAndPushCapabilitiesFailClosed() throws {
        let package = try makePackage()
        var manifest = WidgetPackageManifest.newProject(name: "Unsafe Capabilities")
        manifest.controls = [
            .init(
                id: "bad toggle",
                type: .toggle,
                title: "",
                subtitle: nil,
                systemImage: "../icon",
                action: "run()",
                stateKey: nil
            ),
        ]
        manifest.pushUpdates = .init(
            registrationURL: "https://127.0.0.1/register",
            channel: "bad channel"
        )

        let codes = Set(WidgetPackageManifestValidator.validate(manifest, package: package).errors.map(\.code))
        XCTAssertTrue(codes.contains("invalid_control_id"))
        XCTAssertTrue(codes.contains("invalid_control_title"))
        XCTAssertTrue(codes.contains("invalid_control_image"))
        XCTAssertTrue(codes.contains("invalid_control_action"))
        XCTAssertTrue(codes.contains("invalid_control_state"))
        XCTAssertTrue(codes.contains("push_network"))
        XCTAssertTrue(codes.contains("invalid_push_url"))
        XCTAssertTrue(codes.contains("invalid_push_channel"))
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

final class ScriptWidgetActionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func makeActionPackage(name: String = "Action Test") throws -> (ScriptWidgetPackage, WidgetPackageManifest) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let package = ScriptWidgetPackage(path: directory)
        XCTAssertTrue(package.writeMainFile(content: "function refresh() {}").0)
        var manifest = WidgetPackageManifest.newProject(name: name)
        manifest.id = "dev.scriptwidget.action-test"
        manifest.actions = [
            .init(
                id: "refresh",
                title: "Refresh",
                description: "Refresh the widget",
                systemImage: "arrow.clockwise",
                function: "refresh"
            ),
        ]
        XCTAssertTrue(package.writeManifest(manifest).0)
        return (package, manifest)
    }

    func testCatalogUsesStableIdentifiersAndRejectsMalformedPresentManifests() throws {
        let (package, manifest) = try makeActionPackage()
        let catalog = ScriptWidgetActionCatalog(packages: [package])
        XCTAssertEqual(catalog.actions().map(\.identifier), ["\(manifest.id)::refresh"])
        XCTAssertEqual(catalog.resolve(identifier: "\(manifest.id)::refresh")?.action.function, "refresh")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: package.manifestPath)) as? [String: Any])
        object["executable"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: package.manifestPath)
        XCTAssertTrue(catalog.actions().isEmpty, "Malformed Package 2.0 manifests must fail closed on system surfaces")
    }

    func testResolvedButtonIntentPreservesLocalActionWithoutGlobalDiscovery() throws {
        let (package, _) = try makeActionPackage()
        let resolved = try XCTUnwrap(ScriptWidgetActionCatalog(packages: [package]).actions().first)
        let intent = RunScriptWidgetActionIntent(resolved: resolved)
        XCTAssertEqual(intent.action.id, resolved.identifier)
        XCTAssertEqual(intent.action.title, resolved.action.title)
    }

    func testExecutorProvidesSharedActionAndLegacyControlEnvironments() throws {
        let (package, manifest) = try makeActionPackage()
        let resolved = try XCTUnwrap(ScriptWidgetActionCatalog(packages: [package]).actions().first)
        var captured: [String: String] = [:]
        var reloadCount = 0
        let executor = ScriptWidgetActionExecutor(
            catalog: .init(packages: [package]),
            runAction: { _, environments in
                captured = environments
                return nil
            },
            reloadWidgets: { reloadCount += 1 }
        )

        XCTAssertNoThrow(try executor.execute(
            resolved: resolved,
            source: .control,
            value: true,
            contextID: "dashboard-toggle"
        ).get())
        XCTAssertEqual(captured["action-id"], manifest.actions?.first?.id)
        XCTAssertEqual(captured["action-source"], "control")
        XCTAssertEqual(captured["action-value"], "true")
        XCTAssertEqual(captured["control-id"], "dashboard-toggle")
        XCTAssertEqual(captured["control-value"], "true")
        XCTAssertEqual(reloadCount, 1)
    }

    func testToggleRequiresStorageAndPersistsNamespacedValue() throws {
        let (package, _) = try makeActionPackage()
        var resolved = try XCTUnwrap(ScriptWidgetActionCatalog(packages: [package]).actions().first)
        let suiteName = "ScriptWidgetActionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ToggleStorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let executor = ScriptWidgetActionExecutor(
            catalog: .init(packages: [package]),
            runAction: { _, _ in nil },
            reloadWidgets: {},
            defaults: defaults,
            storageContainer: lockDirectory
        )

        if case .failure(let error) = executor.setToggleValue(
            true,
            resolved: resolved,
            stateKey: "focus.enabled",
            source: .widget
        ) {
            XCTAssertEqual(error, .storageDenied)
        } else {
            XCTFail("Storage must be declared before a toggle action can persist state")
        }
        var storageManifest = resolved.manifest
        storageManifest.permissions = [.storage]
        resolved = .init(package: package, manifest: storageManifest, action: resolved.action)
        XCTAssertNoThrow(try executor.setToggleValue(
            true,
            resolved: resolved,
            stateKey: "focus.enabled",
            source: .widget
        ).get())
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).focus.enabled"), "true")
        if case .failure(let error) = executor.setToggleValue(
            true,
            resolved: resolved,
            stateKey: "../secret",
            source: .widget
        ) {
            XCTAssertEqual(error, .invalidStateKey)
        } else {
            XCTFail("Unsafe toggle state keys must fail closed")
        }
    }

    func testUnavailableToggleStorageDoesNotRunActionOrReload() throws {
        let (package, _) = try makeActionPackage()
        var resolved = try XCTUnwrap(ScriptWidgetActionCatalog(packages: [package]).actions().first)
        var manifest = resolved.manifest
        manifest.permissions = [.storage]
        resolved = .init(package: package, manifest: manifest, action: resolved.action)
        let domain = "UnavailableToggle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = "script.\(package.name).focus.enabled"
        defaults.set("false", forKey: key)
        var ranAction = false
        var reloaded = false
        let executor = ScriptWidgetActionExecutor(
            catalog: .init(packages: [package]),
            runAction: { _, _ in ranAction = true; return nil },
            reloadWidgets: { reloaded = true },
            defaults: defaults,
            storageContainer: FileManager.default.temporaryDirectory.appendingPathComponent("AbsentToggle-\(UUID().uuidString)")
        )
        if case .failure(let error) = executor.setToggleValue(true, resolved: resolved, stateKey: "focus.enabled", source: .control) {
            XCTAssertEqual(error, .storageUnavailable)
        } else { XCTFail("Unavailable storage must fail without executing the action") }
        XCTAssertEqual(defaults.string(forKey: key), "false")
        XCTAssertFalse(ranAction)
        XCTAssertFalse(reloaded)
    }

}

#if canImport(AppIntentsTesting)
@available(macOS 27.0, iOS 27.0, *)
final class ScriptWidgetAppIntentsMetadataTests: XCTestCase {
    func testRunActionIntentAcceptsDeclaredActionEntity() throws {
        let definitions = IntentDefinitions(bundleIdentifier: "com.everettjf.scriptwidget")
        let actionEntity = definitions.entities["ScriptWidgetActionEntity"]
        let reference = actionEntity.makeReference(identifier: "dev.scriptwidget.test::refresh")
        let intent = definitions.intents["RunScriptWidgetActionIntent"].makeIntent(action: reference)
        let captured: AnyAppEntity = try intent.action

        XCTAssertEqual(intent.identifier, "RunScriptWidgetActionIntent")
        XCTAssertNoThrow(try actionEntity.isInstance(captured))
    }

    func testToggleIntentMetadataKeepsValueAndStateParameters() throws {
        let definitions = IntentDefinitions(bundleIdentifier: "com.everettjf.scriptwidget")
        let intent = definitions.intents["SetScriptWidgetActionValueIntent"].makeIntent(
            value: true,
            actionID: "dev.scriptwidget.test::toggle",
            stateKey: "focus.enabled"
        )
        let value: Bool = try intent.value
        let actionID: String = try intent.actionID
        let stateKey: String = try intent.stateKey

        XCTAssertTrue(value)
        XCTAssertEqual(actionID, "dev.scriptwidget.test::toggle")
        XCTAssertEqual(stateKey, "focus.enabled")
    }
}
#endif

final class ScriptManagerLifecycleTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptManagerTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeManager(_ label: String) throws -> ScriptManager {
        ScriptManager(isBuild: true, scriptDirectoryOverride: try makeDirectory(label))
    }

    func testCreateListRenameDuplicateDeleteLifecycle() throws {
        let manager = try makeManager("Lifecycle")

        XCTAssertTrue(manager.createScript(
            content: "$render(<text>Lifecycle</text>)",
            recommendPackageName: "Lifecycle",
            imageCopyPath: nil
        ).0)
        XCTAssertEqual(manager.listScripts().map(\.name), ["Lifecycle"])

        let package = manager.getScriptPackage(packageName: "Lifecycle")
        XCTAssertEqual(package.readMainFile().0, "$render(<text>Lifecycle</text>)")
        XCTAssertEqual(package.readManifest()?.name, "Lifecycle")

        XCTAssertTrue(manager.renameScript(srcPackageName: "Lifecycle", destPackageName: "Renamed").0)
        XCTAssertFalse(manager.isExist(packageName: "Lifecycle"))
        XCTAssertTrue(manager.isExist(packageName: "Renamed"))

        let duplicate = manager.duplicateScript(sourcePackageName: "Renamed")
        XCTAssertTrue(duplicate.0, duplicate.1)
        XCTAssertEqual(duplicate.1, "Renamed Remix")
        XCTAssertEqual(manager.listScripts().map(\.name), ["Renamed", "Renamed Remix"])

        _ = manager.deleteScript(packageName: "Renamed")
        XCTAssertFalse(manager.isExist(packageName: "Renamed"))
        XCTAssertEqual(manager.listScripts().map(\.name), ["Renamed Remix"])
    }

    func testExportedWidgetArchiveIsSelectableByZIPImporter() throws {
        let manager = try makeManager("ArchiveFileType")
        XCTAssertTrue(manager.createScript(content: "$render(<text>Archive</text>)",
                                           recommendPackageName: "Archive", imageCopyPath: nil).0)
        let model = try XCTUnwrap(manager.listScripts().first)
        let ext = URL(fileURLWithPath: model.exportFileName).pathExtension
        XCTAssertEqual(ext, "swt", "Keep existing exported archives compatible")
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let archive = try XCTUnwrap(declarations.first { ($0["UTTypeIdentifier"] as? String) == "com.everettjf.scriptwidget.archive" })
        XCTAssertEqual(archive["UTTypeConformsTo"] as? [String], [UTType.zip.identifier])
        let tags = try XCTUnwrap(archive["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], [ext])
        let type = try XCTUnwrap(UTType(filenameExtension: ext))
        XCTAssertTrue(type.conforms(to: .zip), "The system ZIP picker must accept the app's own .swt export")
    }

    func testExportImportRoundTripDeduplicatesWithoutOverwrite() throws {
        let source = try makeManager("ExportSource")
        XCTAssertTrue(source.createScript(
            content: "$render(<text>Exported</text>)",
            recommendPackageName: "Round Trip",
            imageCopyPath: nil
        ).0)
        let sourceModel = try XCTUnwrap(source.listScripts().first)
        let archive = try makeDirectory("Archive").appendingPathComponent("round-trip.swt")
        XCTAssertTrue(source.exportScript(model: sourceModel, toPath: archive))

        let destination = try makeManager("ImportDestination")
        let first = destination.importScriptPackage(fromPath: archive)
        XCTAssertTrue(first.succeeded, first.message)
        XCTAssertEqual(first.packageName, "Round Trip")
        XCTAssertEqual(
            destination.getScriptPackage(packageName: "Round Trip").readMainFile().0,
            "$render(<text>Exported</text>)"
        )

        let second = destination.importScriptPackage(fromPath: archive)
        XCTAssertTrue(second.succeeded, second.message)
        XCTAssertEqual(second.packageName, "Round Trip (1)")
        XCTAssertEqual(destination.listScripts().map(\.name), ["Round Trip", "Round Trip (1)"])
        XCTAssertEqual(
            destination.getScriptPackage(packageName: "Round Trip").readMainFile().0,
            "$render(<text>Exported</text>)",
            "A duplicate import must never overwrite the existing package"
        )
    }

    func testMalformedArchiveFailsWithoutLeavingPartialPackage() throws {
        let manager = try makeManager("Malformed")
        let archive = try makeDirectory("MalformedArchive").appendingPathComponent("invalid.swt")
        try Data("not a zip archive".utf8).write(to: archive)

        let result = manager.importScriptPackage(fromPath: archive)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.packageName)
        XCTAssertTrue(manager.listScripts().isEmpty)
        XCTAssertEqual(manager.scriptCount(), 0)
    }

    func testMalformedPresentManifestFailsClosedOnImport() throws {
        // A present but malformed widget.json is authoritative: import must
        // reject the package instead of replacing it with a legacy manifest.
        let manager = try makeManager("MalformedManifest")
        let packageRoot = try makeDirectory("MalformedManifestSource").appendingPathComponent("Tampered")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data("$render(<text>Tampered</text>)".utf8).write(to: packageRoot.appendingPathComponent("main.jsx"))
        let manifest = #"{"formatVersion":2,"id":"com.example.tampered","name":"Tampered","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[],"permissionz":["network"]}"#
        try Data(manifest.utf8).write(to: packageRoot.appendingPathComponent("widget.json"))
        let archive = try makeDirectory("MalformedManifestArchive").appendingPathComponent("tampered.swt")
        XCTAssertTrue(SSZipArchive.createZipFile(atPath: archive.path, withContentsOfDirectory: packageRoot.path, keepParentDirectory: true))

        let result = manager.importScriptPackage(fromPath: archive)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.message, "widget.json is invalid.")
        XCTAssertTrue(manager.listScripts().isEmpty)
    }

    func testDefaultRepositoryPreservesManagerListingAndOrdering() throws {
        let manager = try makeManager("Repository")
        XCTAssertTrue(manager.createScript(content: "B", recommendPackageName: "Beta", imageCopyPath: nil).0)
        XCTAssertTrue(manager.createScript(content: "A", recommendPackageName: "Alpha", imageCopyPath: nil).0)

        let repository = DefaultScriptPackageRepository(manager: manager)

        XCTAssertEqual(repository.listScripts().map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(repository.listScripts().map(\.name), manager.listScripts().map(\.name))
    }
}

final class PackageListRefreshTests: XCTestCase {
    private final class SequencedListing: ScriptPackageListing {
        let firstStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let allowFirstToFinish = DispatchSemaphore(value: 0)

        private let lock = NSLock()
        private var callCount = 0
        private let stale: [ScriptModel]
        private let latest: [ScriptModel]

        init(stale: [ScriptModel], latest: [ScriptModel]) {
            self.stale = stale
            self.latest = latest
        }

        func listScripts() -> [ScriptModel] {
            lock.lock()
            callCount += 1
            let call = callCount
            lock.unlock()

            if call == 1 {
                firstStarted.signal()
                _ = allowFirstToFinish.wait(timeout: .now() + 5)
                return stale
            }
            secondFinished.signal()
            return latest
        }
    }

    func testLatestPackageReloadWinsWhenEarlierReadFinishesLater() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageRefreshTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = ScriptModel(package: ScriptWidgetPackage(path: root.appendingPathComponent("Stale")))
        let latest = ScriptModel(package: ScriptWidgetPackage(path: root.appendingPathComponent("Latest")))
        let listing = SequencedListing(stale: [stale], latest: [latest])

#if os(macOS)
        let store = SharedAppStore(packages: listing)
#else
        let store = ScriptWidgetHomeViewDataObject(packages: listing)
#endif
        XCTAssertEqual(listing.firstStarted.wait(timeout: .now() + 2), .success)
#if os(macOS)
        store.reloadUserScripts()
#else
        store.reload()
#endif
        XCTAssertEqual(listing.secondFinished.wait(timeout: .now() + 2), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
#if os(macOS)
        XCTAssertEqual(store.scriptModels.map(\.name), ["Latest"])
#else
        XCTAssertEqual(store.models.map(\.name), ["Latest"])
#endif

        listing.allowFirstToFinish.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
#if os(macOS)
        XCTAssertEqual(store.scriptModels.map(\.name), ["Latest"])
#else
        XCTAssertEqual(store.models.map(\.name), ["Latest"])
#endif
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

final class GalleryTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testRepositoryGalleryIndexAndHashesValidate() throws {
        try skipUnlessRepositoryCheckout(repositoryRoot)
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/index.json"))
        let index = try XCTUnwrap(try GalleryIndexValidator.decode(data).get())
        XCTAssertGreaterThanOrEqual(index.items.count, ScriptWidgetRecordKind.allCases.count + 2)
        for item in index.items {
            for file in item.files {
                let marker = "/Gallery/"
                let remotePath = try XCTUnwrap(file.url.path.range(of: marker).map { String(file.url.path[$0.upperBound...]) })
                let localData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/").appendingPathComponent(remotePath))
                XCTAssertEqual(localData.count, file.bytes)
                XCTAssertEqual(GalleryInstaller.sha256(localData), file.sha256)
            }
        }
    }

    func testIndexRejectsUnknownFieldsAndUnsafePaths() throws {
        try skipUnlessRepositoryCheckout(repositoryRoot)
        let source = try Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/index.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        object["futureField"] = true
        if case .success = GalleryIndexValidator.decode(try JSONSerialization.data(withJSONObject: object)) {
            XCTFail("Unknown fields must fail closed")
        }

        let index = try GalleryIndexValidator.decode(source).get()
        let original = try XCTUnwrap(index.items.first)
        let badFile = GalleryFile(path: "../main.jsx", url: original.files[0].url, sha256: original.files[0].sha256, bytes: original.files[0].bytes)
        let badItem = GalleryItem(id: original.id, kind: original.kind, name: original.name, version: original.version, summary: original.summary, symbol: original.symbol, author: original.author, license: original.license, tags: original.tags, minimumRuntimeVersion: original.minimumRuntimeVersion, sourceURL: original.sourceURL, featured: original.featured, files: [badFile, original.files[1]])
        XCTAssertFalse(GalleryIndexValidator.validate(.init(schemaVersion: 1, generatedAt: Date(), repository: index.repository, items: [badItem])).isValid)
    }

    func testClientUsesETagAndFallsBackToVerifiedOfflineCache() async throws {
        try skipUnlessRepositoryCheckout(repositoryRoot)
        let source = try Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/index.json"))
        let indexURL = GalleryClient.defaultIndexURL
        let transport = GalleryTestTransport(responses: [
            .success((source, response(url: indexURL, status: 200, headers: ["ETag": "gallery-v1"]))),
            .success((Data(), response(url: indexURL, status: 304))),
            .failure(GalleryError.network("offline"))
        ])
        let directory = makeTemporaryDirectory()
        let client = GalleryClient(indexURL: indexURL, transport: transport, cache: .init(directory: directory), now: Date.init)

        let online = try await client.load(forceRefresh: true)
        XCTAssertFalse(online.isOffline)
        let revalidated = try await client.load(forceRefresh: true)
        XCTAssertFalse(revalidated.isOffline)
        XCTAssertEqual(online.index, revalidated.index)
        let offline = try await client.load(forceRefresh: true)
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(online.index, offline.index)
        let conditionalHeader = await transport.lastRequestHeader("If-None-Match")
        XCTAssertEqual(conditionalHeader, "gallery-v1")
    }

    func testInstallerVerifiesAndInstallsWidgetAndSkillTransactionally() async throws {
        try skipUnlessRepositoryCheckout(repositoryRoot)
        let indexData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/index.json"))
        let index = try GalleryIndexValidator.decode(indexData).get()
        var responses: [URL: Result<(Data, HTTPURLResponse), Error>] = [:]
        for item in index.items {
            for file in item.files {
                let marker = "/Gallery/"
                let remotePath = try XCTUnwrap(file.url.path.range(of: marker).map { String(file.url.path[$0.upperBound...]) })
                let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/").appendingPathComponent(remotePath))
                responses[file.url] = .success((data, response(url: file.url, status: 200)))
            }
        }
        let root = makeTemporaryDirectory()
        let registry = GalleryInstallationRegistry(fileURL: root.appendingPathComponent("registry.json"))
        let installer = GalleryInstaller(
            transport: GalleryTestTransport(mappedResponses: responses),
            registry: registry,
            scriptManager: ScriptManager(isBuild: false, scriptDirectoryOverride: root.appendingPathComponent("Scripts"), buildDirectoryOverride: root.appendingPathComponent("Cache")),
            skillManager: AIWidgetSkillManager(directory: root.appendingPathComponent("Skills")),
            buildAfterInstall: true
        )

        for item in index.items {
            let record = try await installer.install(item)
            XCTAssertEqual(record.itemID, item.id)
            XCTAssertEqual(installer.state(for: item), .installed)
            if item.kind == .widget {
                let package = ScriptWidgetPackage(path: root.appendingPathComponent("Cache").appendingPathComponent(record.localIdentifier))
                let manifest = try XCTUnwrap(package.readManifest())
                XCTAssertEqual(manifest.id, item.id)
                XCTAssertEqual(manifest.runtimeVersion, item.minimumRuntimeVersion)
                if item.id.hasPrefix("app.scriptwidget.template.") {
                    let originalURL = repositoryRoot.appendingPathComponent("Shared/ScriptWidgetRuntime/Resource/Script.bundle/template").appendingPathComponent(item.name).appendingPathComponent("widget.json")
                    let original = try JSONDecoder().decode(WidgetPackageManifest.self, from: Data(contentsOf: originalURL))
                    XCTAssertEqual(manifest.minimumRuntimeVersion, original.minimumRuntimeVersion)
                    let requirement = original.minimumRuntimeVersion ?? original.runtimeVersion
                    XCTAssertTrue(item.summary.contains("Requires Runtime API \(requirement)"))
                    XCTAssertTrue(WidgetRuntimeRequirement.supports(requirement, current: ScriptWidgetBuildContract.nativeRuntimeAPIVersion))
                    if original.minimumRuntimeVersion == nil {
                        XCTAssertTrue(WidgetRuntimeRequirement.supports(requirement, current: "1.0"))
                    }
                    if item.files.contains(where: { $0.path == "record-template.json" }) {
                        _ = try ScriptWidgetRecordKind.load(package: package)
                    }
                }
                let source = try String(contentsOf: package.jsxPath, encoding: .utf8)
                guard case .success = ScriptWidgetPrecompiler.compileNow(package: package, source: source) else {
                    XCTFail("Gallery installed package failed compilation: \(item.id)")
                    continue
                }
                XCTAssertNotNil(ScriptWidgetCompiledArtifactStore.load(package: package, source: source))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Scripts/Gallery Hello Card/main.jsx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Skills/privacy-review/SKILL.md").path))
    }

    func testChangedFingerprintAtSameVersionOffersUpdate() throws {
        try skipUnlessRepositoryCheckout(repositoryRoot)
        let root = makeTemporaryDirectory()
        let registry = GalleryInstallationRegistry(fileURL: root.appendingPathComponent("registry.json"))
        let item = try XCTUnwrap(try GalleryIndexValidator.decode(Data(contentsOf: repositoryRoot.appendingPathComponent("Gallery/index.json"))).get().items.first)
        try registry.save(.init(itemID: item.id, kind: item.kind, version: item.version, localIdentifier: "Local", contentFingerprint: "different", installedAt: Date()))
        XCTAssertEqual(registry.state(for: item), .updateAvailable(current: item.version))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func response(url: URL, status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

private actor GalleryTestTransport: GalleryTransport {
    private var queuedResponses: [Result<(Data, HTTPURLResponse), Error>]
    private var mappedResponses: [URL: Result<(Data, HTTPURLResponse), Error>]
    private(set) var requests: [URLRequest] = []

    init(responses: [Result<(Data, HTTPURLResponse), Error>] = [], mappedResponses: [URL: Result<(Data, HTTPURLResponse), Error>] = [:]) {
        queuedResponses = responses
        self.mappedResponses = mappedResponses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: Result<(Data, HTTPURLResponse), Error>
        requests.append(request)
        if !queuedResponses.isEmpty {
            result = queuedResponses.removeFirst()
        } else if let url = request.url, let mapped = mappedResponses[url] {
            result = mapped
        } else {
            result = .failure(GalleryError.network("No test response"))
        }
        return try result.get()
    }

    func lastRequestHeader(_ field: String) -> String? {
        requests.last?.value(forHTTPHeaderField: field)
    }
}

final class DataSourcePluginTests: XCTestCase {
    func testBuiltInPluginsValidate() {
        XCTAssertEqual(DataSourcePluginManager.builtIns.count, 2)
        for plugin in DataSourcePluginManager.builtIns {
            XCTAssertTrue(DataSourcePluginValidator.validate(plugin).isValid, plugin.id)
        }
    }

    func testRequestBuilderMapsPathQueryHeaderAndJSONBody() throws {
        let plugin = DataSourcePluginManifest(
            formatVersion: 1,
            id: "dev.scriptwidget.test-source",
            name: "Test Source",
            version: "1.0.0",
            summary: "Test",
            symbol: "network",
            author: "Tests",
            license: "MIT",
            minimumRuntimeVersion: ScriptWidgetBuildContract.runtimeAPIVersion,
            baseURL: URL(string: "https://api.example.com")!,
            hosts: ["api.example.com"],
            operations: [.init(
                id: "update",
                title: "Update",
                method: "POST",
                path: "/users/{user}",
                responseType: .json,
                parameters: [
                    .init(id: "user", label: "User", location: .path, required: true, defaultValue: nil),
                    .init(id: "page", label: "Page", location: .query, required: false, defaultValue: "1"),
                    .init(id: "X-Token", label: "Token", location: .header, required: true, defaultValue: nil),
                    .init(id: "enabled", label: "Enabled", location: .jsonBody, required: true, defaultValue: nil)
                ]
            )]
        )
        let prepared = try DataSourceRequestBuilder.prepare(
            plugin: plugin,
            operationID: "update",
            values: ["user": "hello world", "X-Token": "secret", "enabled": true]
        )
        XCTAssertEqual(prepared.request.url?.absoluteString, "https://api.example.com/users/hello%20world?page=1")
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "X-Token"), "secret")
        let body = try XCTUnwrap(prepared.request.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Bool])?["enabled"], true)
    }

    func testManifestDecoderFailsClosedAndRejectsHTTP() throws {
        let builtIn = try XCTUnwrap(DataSourcePluginManager.builtIns.first)
        let encoded = try JSONEncoder().encode(builtIn)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unexpected"] = true
        if case .success = DataSourcePluginValidator.decode(try JSONSerialization.data(withJSONObject: object)) {
            XCTFail("Unknown plugin fields must fail closed")
        }

        var unsafe = builtIn
        unsafe.baseURL = URL(string: "http://api.open-meteo.com")!
        XCTAssertFalse(DataSourcePluginValidator.validate(unsafe).isValid)
    }

    func testNetworkPolicyMatchesExactAndWildcardHosts() {
        XCTAssertTrue(ScriptWidgetNetworkPolicy.host("api.example.com", matchesAny: ["api.example.com"]))
        XCTAssertTrue(ScriptWidgetNetworkPolicy.host("weather.example.com", matchesAny: ["*.example.com"]))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.host("example.com", matchesAny: ["*.example.com"]))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.host("example.com.evil.test", matchesAny: ["*.example.com"]))
    }

    func testMalformedPackageManifestFailsNetworkClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NetworkPolicy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = ScriptWidgetPackage(path: root, readonly: false)
        XCTAssertTrue(ScriptWidgetNetworkPolicy.packageAllows(URL(string: "https://example.com")!, package: package), "Legacy package remains compatible")
        try Data("{not-json".utf8).write(to: package.manifestPath)
        XCTAssertFalse(ScriptWidgetNetworkPolicy.packageAllows(URL(string: "https://example.com")!, package: package), "Malformed Package 2.0 must fail closed")
    }
}


final class CalendarQueryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_773_000_000)

    func testDefaultRangeFollowsLocalDayAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T20:00:00Z"))
        let query = try ScriptWidgetCalendarQuery(nil, now: spring, calendar: calendar)
        XCTAssertEqual(query.end.timeIntervalSince(query.start), 23 * 3_600)
        XCTAssertEqual(query.limit, 10)
        XCTAssertEqual(query.maxAgeSeconds, 60)
        XCTAssertTrue(query.calendarIDs.isEmpty)
    }

    func testInvalidQueriesFailBeforeSystemAccess() {
        let options: [[String: Any]] = [
            ["unknown": true], ["limit": true], ["limit": 0], ["limit": 51], ["limit": 1.5],
            ["maxAgeSeconds": -1], ["maxAgeSeconds": Double.infinity], ["maxAgeSeconds": true],
            ["calendarIDs": []], ["calendarIDs": ["same", "same"]], ["calendarIDs": [1]],
            ["calendarIDs": [String(repeating: "日", count: 86)]],
            ["calendarIDs": (0..<17).map(String.init)], ["start": "not a date"], ["start": 123],
            ["start": "2026-01-01"], ["start": "2026-01-02T00:00:00Z", "end": "2026-01-01T00:00:00Z"],
            ["start": "2026-01-01T00:00:00Z", "end": "2026-03-01T00:00:00Z"],
        ]
        for item in options { XCTAssertThrowsError(try ScriptWidgetCalendarQuery(item, now: now), "\(item)") }
    }

    func testCacheIdentityIncludesScopeAndIgnoresIdentifierOrder() throws {
        let a = try ScriptWidgetCalendarQuery(["calendarIDs": ["a", "b"], "limit": 5], now: now)
        let b = try ScriptWidgetCalendarQuery(["calendarIDs": ["b", "a"], "limit": 5, "maxAgeSeconds": 0], now: now)
        let c = try ScriptWidgetCalendarQuery(["calendarIDs": ["a"], "limit": 5], now: now)
        let d = try ScriptWidgetCalendarQuery(["calendarIDs": ["a", "b"], "limit": 6], now: now)
        XCTAssertEqual(a.cacheIdentity, b.cacheIdentity)
        XCTAssertNotEqual(a.cacheIdentity, c.cacheIdentity)
        XCTAssertNotEqual(a.cacheIdentity, d.cacheIdentity)
        XCTAssertEqual(a.cacheIdentity.count, 64)
    }

    func testDataQueryBudgetIsPerExecutionAndStopsAfterCancellation() {
        let first = ScriptWidgetExecutionSession()
        let second = ScriptWidgetExecutionSession()
        for _ in 0..<8 { XCTAssertTrue(first.registerDataQuery()) }
        XCTAssertFalse(first.registerDataQuery())
        XCTAssertTrue(second.registerDataQuery())
        second.cancel(.explicit)
        XCTAssertFalse(second.registerDataQuery())
    }
}

final class CalendarCacheTests: XCTestCase {
    func testCacheTTLIdentityScopeAndUntrustedPayloads() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let query = try ScriptWidgetCalendarQuery(["calendarIDs": ["personal"], "maxAgeSeconds": 120], now: now)
        let event: [String: Any] = ["id": "event", "calendarID": "personal", "title": "Read", "start": "2026-01-01T15:00:00Z", "end": "2026-01-01T16:00:00Z", "allDay": false]
        let value: [String: Any] = ["status": "ready", "items": [event], "fetchedAt": "2026-01-01T11:59:00Z", "source": "system", "stale": false, "truncated": false]
        let record: [String: Any] = ["query": query.cacheIdentity, "timestamp": now.timeIntervalSince1970 - 90, "value": value]
        func decode(_ object: [String: Any]) throws -> [String: Any]? {
            ScriptWidgetCalendarCache.decode(try JSONSerialization.data(withJSONObject: object), query: query, now: now)
        }
        let decoded = try XCTUnwrap(decode(record))
        XCTAssertEqual(decoded["source"] as? String, "cache")
        XCTAssertEqual(decoded["stale"] as? Bool, true)
        XCTAssertNil(try decode(record.merging(["timestamp": now.timeIntervalSince1970 - 121]) { _, new in new }))
        XCTAssertNil(try decode(record.merging(["timestamp": now.timeIntervalSince1970 + 1]) { _, new in new }))
        XCTAssertNil(try decode(record.merging(["timestamp": true]) { _, new in new }))
        XCTAssertNil(try decode(record.merging(["query": "other-query"]) { _, new in new }))
        var otherEvent = event; otherEvent["calendarID"] = "other-calendar"
        var otherValue = value; otherValue["items"] = [otherEvent]
        XCTAssertNil(try decode(record.merging(["value": otherValue]) { _, new in new }))
        otherValue = value; otherValue["items"] = Array(repeating: event, count: 51)
        XCTAssertNil(try decode(record.merging(["value": otherValue]) { _, new in new }))
        otherValue = value; otherValue["unexpected"] = "not part of the contract"
        XCTAssertNil(try decode(record.merging(["value": otherValue]) { _, new in new }))
        XCTAssertNil(ScriptWidgetCalendarCache.decode(Data(repeating: 32, count: 65 * 1_024), query: query, now: now))
        let uncached = try ScriptWidgetCalendarQuery(["calendarIDs": ["personal"], "maxAgeSeconds": 0], now: now)
        XCTAssertNil(ScriptWidgetCalendarCache.decode(try JSONSerialization.data(withJSONObject: record), query: uncached, now: now))
    }
}

final class CalendarSourceSelectionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots.removeAll(); super.tearDown()
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarSources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return root
    }

    func testMissingPreferenceKeepsAccessButExplicitEmptySelectionBlocksQueries() throws {
        let container = try root()
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container), .all)
        let selected = ScriptWidgetCalendarSelection(calendarIDs: ["personal"])
        try selected.save(container: container)
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container), selected)
        XCTAssertEqual(try selected.permittedIDs(available: ["personal", "work"], requested: []), ["personal"])
        XCTAssertThrowsError(try selected.permittedIDs(available: ["personal", "work"], requested: ["work"]))
        XCTAssertThrowsError(try selected.permittedIDs(available: [], requested: ["personal"]))
        try ScriptWidgetCalendarSelection(calendarIDs: []).save(container: container)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: container).permittedIDs(available: ["personal"], requested: []))
        XCTAssertEqual(ScriptWidgetCalendarSelection(calendarIDs: ["b", "a"]).identity, ScriptWidgetCalendarSelection(calendarIDs: ["a", "b"]).identity)
    }

    func testMalformedPresentSettingsNeverFallBackToAllCalendars() throws {
        let container = try root(), file = container.appendingPathComponent(ScriptWidgetCalendarSelection.fileName)
        for bad: [String: Any] in [
            ["formatVersion": true, "mode": "all", "calendarIDs": []],
            ["formatVersion": 2, "mode": "all", "calendarIDs": []],
            ["formatVersion": 1, "mode": "all", "calendarIDs": ["personal"]],
            ["formatVersion": 1, "mode": "selected", "calendarIDs": ["a", "a"]],
            ["formatVersion": 1, "mode": "selected", "calendarIDs": [String(repeating: "日", count: 86)]],
            ["formatVersion": 1, "mode": "selected", "calendarIDs": (0..<65).map(String.init)],
            ["formatVersion": 1, "mode": "selected", "calendarIDs": [], "extra": true]
        ] {
            try JSONSerialization.data(withJSONObject: bad).write(to: file, options: .atomic)
            XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: container))
        }
        try (ScriptWidgetCalendarSelection.all.encoded + Data(repeating: 32, count: ScriptWidgetCalendarSelection.maximumBytes)).write(to: file, options: .atomic)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: container))
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: nil))
    }

    func testOpaqueCalendarIdentifiersAreByteExactAcrossSelectionQueryAndDisk() throws {
        let a = "caf\u{00e9}", b = "cafe\u{0301}", container = try root()
        let selected = ScriptWidgetCalendarSelection(calendarIDs: [a])
        XCTAssertTrue(selected.allows(a)); XCTAssertFalse(selected.allows(b))
        XCTAssertNotEqual(selected, ScriptWidgetCalendarSelection(calendarIDs: [b]))
        XCTAssertThrowsError(try selected.permittedIDs(available: [a, b], requested: [b]))
        let both = ScriptWidgetCalendarSelection(calendarIDs: [a, b])
        XCTAssertTrue(ScriptWidgetCalendarSelection.validIDs([a, b]))
        try both.save(container: container)
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container).calendarIDs?.map { Data($0.utf8) }, both.calendarIDs?.map { Data($0.utf8) })
        let first = try ScriptWidgetCalendarQuery(["calendarIDs": [a]])
        let second = try ScriptWidgetCalendarQuery(["calendarIDs": [b]])
        XCTAssertNotEqual(first.cacheIdentity, second.cacheIdentity)
        XCTAssertEqual(try ScriptWidgetCalendarQuery(["calendarIDs": [a, b]]).calendarIDs.count, 2)
    }

    func testLinksAndStaleNativeDraftsCannotReplaceSourceSettings() throws {
        let container = try root(), outside = try root(), target = outside.appendingPathComponent("settings.json")
        try ScriptWidgetCalendarSelection.all.encoded.write(to: target)
        let file = container.appendingPathComponent(ScriptWidgetCalendarSelection.fileName)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: container))
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection(calendarIDs: []).save(container: container))
        XCTAssertEqual(try Data(contentsOf: target), ScriptWidgetCalendarSelection.all.encoded)
        try FileManager.default.removeItem(at: file); try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: container))
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection(calendarIDs: []).save(container: container))
        try FileManager.default.removeItem(at: file)
        let a = ScriptWidgetCalendarSelection(calendarIDs: ["a"])
        try a.save(container: container, replacing: .all)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection(calendarIDs: ["b"]).save(container: container, replacing: .all))
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container), a)
        let alias = outside.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: container)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.all.save(container: alias))
    }

    func testCacheCannotWidenNativeSelectionOrReuseAnUntaggedSnapshot() throws {
        let now = Date(), query = try ScriptWidgetCalendarQuery(nil, now: now)
        let event: [String: Any] = ["id": "event", "calendarID": "personal", "title": "Read", "start": ISO8601DateFormatter().string(from: query.start.addingTimeInterval(3600)), "end": ISO8601DateFormatter().string(from: query.start.addingTimeInterval(7200)), "allDay": false]
        var value: [String: Any] = ["status": "ready", "items": [event], "fetchedAt": ISO8601DateFormatter().string(from: now), "source": "system", "stale": false, "truncated": false]
        var record: [String: Any] = ["query": query.cacheIdentity, "timestamp": now.timeIntervalSince1970, "value": value]
        let personal = ScriptWidgetCalendarSelection(calendarIDs: ["personal"])
        func data() throws -> Data { try JSONSerialization.data(withJSONObject: record) }
        XCTAssertNotNil(ScriptWidgetCalendarCache.decode(try data(), query: query, now: now))
        XCTAssertNil(ScriptWidgetCalendarCache.decode(try data(), query: query, now: now, selection: personal))
        record["selection"] = personal.identity
        XCTAssertNotNil(ScriptWidgetCalendarCache.decode(try data(), query: query, now: now, selection: personal))
        XCTAssertNil(ScriptWidgetCalendarCache.decode(try data(), query: query, now: now, selection: .all))
        var outside = event; outside["calendarID"] = "work"; value["items"] = [outside]; record["value"] = value
        XCTAssertNil(ScriptWidgetCalendarCache.decode(try data(), query: query, now: now, selection: personal))
    }

    @MainActor
    func testNativeSourceEditorSavesExplicitlyRejectsConflictsAndPreservesDrafts() async throws {
        let container = try root(), sources: [ScriptWidgetCalendarSource] = [.init(id: "personal", title: "Personal"), .init(id: "work", title: "Work")]
        var refreshes = 0
        let first = ScriptWidgetCalendarSourcesModel(container: container, authorization: { "authorized" }, loadSources: { sources }, onSaved: { refreshes += 1 })
        let second = ScriptWidgetCalendarSourcesModel(container: container, authorization: { "authorized" }, loadSources: { sources }, onSaved: {})
        await first.reload(); await second.reload()
        first.useAll = false; first.select("personal", enabled: true)
        await first.reload(); XCTAssertFalse(first.useAll); XCTAssertEqual(first.selectedIDs, ["personal"])
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container), .all, "Drafts must not publish automatically")
        first.save(); XCTAssertFalse(first.isError); XCTAssertEqual(refreshes, 1)
        second.useAll = false; second.select("work", enabled: true); second.save(); XCTAssertTrue(second.isError)
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container).calendarIDs, ["personal"])
        await second.reload(discardDraft: true); XCTAssertEqual(second.selectedIDs, ["personal"])
    }

    @MainActor
    func testNativeEditorRepairsCorruptSettingsToExplicitNoneAndChecksAuthorizationAgain() async throws {
        let container = try root()
        try Data("broken".utf8).write(to: container.appendingPathComponent(ScriptWidgetCalendarSelection.fileName))
        var allowed = true
        let model = ScriptWidgetCalendarSourcesModel(container: container, authorization: { allowed ? "authorized" : "denied" }, loadSources: { [] }, onSaved: {})
        await model.reload(); XCTAssertTrue(model.isError); XCTAssertFalse(model.useAll)
        model.save(); XCTAssertFalse(model.isError); XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container).calendarIDs, [])
        allowed = false; model.useAll = true; model.save(); XCTAssertTrue(model.isError)
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: container).calendarIDs, [])
    }
}

final class WidgetRuntimeRequirementTests: XCTestCase {
    func testOnlyCanonicalSameMajorRequirementsAreSupported() {
        for value in ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6"] { XCTAssertTrue(WidgetRuntimeRequirement.supports(value), value) }
        for value in ["1.7", "1.10", "2.0", "0.9", "01.3", "1.03", "1.3.0", "1", "1.9999", ">=1.3", " 1.3"] {
            XCTAssertFalse(WidgetRuntimeRequirement.supports(value), value)
        }
        XCTAssertTrue(WidgetRuntimeRequirement.supports("1.9", current: "1.10"))
        XCTAssertFalse(WidgetRuntimeRequirement.supports("1.10", current: "1.9"))
    }

    func testManifestMinimumRuntimeRoundTripsAndFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MinimumRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = ScriptWidgetPackage(path: directory)
        var manifest = WidgetPackageManifest.newProject(name: "Minimum Runtime")
        for value in [nil, "1.0", "1.3", "1.4", "2.0", "01.3"] as [String?] {
            manifest.minimumRuntimeVersion = value
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("widget.json"))
            XCTAssertEqual(package.readManifest()?.minimumRuntimeVersion, value)
            let report = WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false)
            XCTAssertEqual(report.isValid, value == nil || value == "1.0" || value == "1.3" || value == "1.4", value ?? "absent")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        object["minimumRuntimeVersion"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("widget.json"))
        XCTAssertNil(package.readManifest())
    }

    func testHealthReviewNeverRevealsReadPermission() {
        XCTAssertEqual(ScriptWidgetHealthReviewState.evaluate(available: false, shouldRequest: false), .unavailable)
        XCTAssertEqual(ScriptWidgetHealthReviewState.evaluate(available: true, shouldRequest: true), .reviewRequired)
        XCTAssertEqual(ScriptWidgetHealthReviewState.evaluate(available: true, shouldRequest: false), .reviewCompleted)
        XCTAssertEqual(ScriptWidgetHealthReviewState.evaluate(available: true, shouldRequest: nil), .reviewRequired)
        XCTAssertEqual(ScriptWidgetHealthReviewState.evaluate(available: true, shouldRequest: false, failed: true), .failed)
        for state: ScriptWidgetHealthReviewState in [.checking, .unavailable, .reviewRequired, .reviewCompleted, .failed] {
            XCTAssertEqual(state.readAuthorization, "notDisclosed")
        }
    }
}

final class AtomicStorageTests: XCTestCase {
    private var directories: [URL] = []
    private var domains: [String] = []

    override func tearDown() {
        for domain in domains { let store = UserDefaults(suiteName: domain)!; store.removePersistentDomain(forName: domain); _ = store.synchronize() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func context() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtomicStorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let domain = "app.scriptwidget.atomic.tests.\(UUID().uuidString)"
        domains.append(domain)
        return (directory, try XCTUnwrap(UserDefaults(suiteName: domain)))
    }

    func testStringConflictsTypesAndNamespaceIsolation() throws {
        let (root, defaults) = try context()
        func cas(_ namespace: String, _ expected: String, _ value: String) -> Bool {
            ScriptWidgetAtomicPreferences.compareAndSetString(container: root, defaults: defaults, namespace: namespace, key: "count", expected: expected, value: value)
        }
        XCTAssertTrue(cas("first.", "", "1"))
        XCTAssertFalse(cas("first.", "", "lost"))
        XCTAssertTrue(cas("first.", "1", "2"))
        XCTAssertTrue(cas("second.", "", "other"))
        XCTAssertEqual(defaults.string(forKey: "first.count"), "2")
        XCTAssertEqual(defaults.string(forKey: "second.count"), "other")
        defaults.set(Data("{}".utf8), forKey: "first.count")
        _ = defaults.synchronize()
        XCTAssertFalse(cas("first.", "", "lost"))
        XCTAssertEqual(defaults.data(forKey: "first.count"), Data("{}".utf8))
    }

    func testJSONComparisonIgnoresObjectOrderAndPreservesInvalidHistory() throws {
        let (root, defaults) = try context()
        func cas(_ expected: [AnyHashable: Any], _ value: [AnyHashable: Any]) -> Bool {
            ScriptWidgetAtomicPreferences.compareAndSetJSON(container: root, defaults: defaults, namespace: "json.", key: "state", expected: expected, value: value)
        }
        XCTAssertTrue(cas([:], ["b": 2, "a": 1]))
        XCTAssertTrue(cas(["a": 1, "b": 2], ["a": 2]))
        XCTAssertFalse(cas(["a": 1], ["a": 3]))
        defaults.set(Data("not JSON".utf8), forKey: "json.state")
        _ = defaults.synchronize()
        XCTAssertFalse(cas([:], ["lost": true]))
        XCTAssertEqual(defaults.data(forKey: "json.state"), Data("not JSON".utf8))
        XCTAssertNil(ScriptWidgetAtomicPreferences.encodeJSON(["n": Double.nan]))
        XCTAssertNil(ScriptWidgetAtomicPreferences.encodeJSON(["huge": String(repeating: "日", count: 90_000)]))
    }

    func testChildSymlinksCannotRedirectLockFiles() throws {
        let (root, _) = try context()
        let (outside, _) = try context()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("__StorageLocks.v1"), withDestinationURL: outside)
        var invoked = false
        let result = ScriptWidgetStorageLock.withExclusiveAccess(container: root, namespace: "private") { invoked = true; return 1 }
        XCTAssertNil(result)
        XCTAssertFalse(invoked)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testContentionTimesOutWithoutBlockingOtherPackages() throws {
        let (root, _) = try context()
        let entered = expectation(description: "lock held")
        let finished = expectation(description: "lock released")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = ScriptWidgetStorageLock.withExclusiveAccess(container: root, namespace: "one") {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
                return true
            }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 1)
        XCTAssertEqual(ScriptWidgetStorageLock.withExclusiveAccess(container: root, namespace: "two") { 2 }, 2)
        XCTAssertNil(ScriptWidgetStorageLock.withExclusiveAccess(container: root, namespace: "one") { 1 })
        release.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(ScriptWidgetStorageLock.withExclusiveAccess(container: root, namespace: "one") { 1 }, 1)
    }

    func testCancellationAndUTF8BudgetsRejectBeforeMutation() throws {
        let (root, defaults) = try context()
        var checks = 0
        let committed = ScriptWidgetAtomicPreferences.mutate(container: root, defaults: defaults, namespace: "cancel.", isActive: {
            checks += 1
            return checks == 1
        }) { store in try store.writeValue("must not commit", forKey: "cancel.value"); return true }
        XCTAssertFalse(committed)
        XCTAssertNil(defaults.object(forKey: "cancel.value"))
        XCTAssertFalse(ScriptWidgetAtomicPreferences.compareAndSetString(container: root, defaults: defaults, namespace: "budget.", key: String(repeating: "日", count: 86), expected: "", value: "value"))
        XCTAssertFalse(ScriptWidgetAtomicPreferences.compareAndSetString(container: root, defaults: defaults, namespace: "budget.", key: "value", expected: "", value: String(repeating: "日", count: 90_000)))
        XCTAssertNil(defaults.object(forKey: "budget.value"))
    }

}

final class TemplateInstallationTests: XCTestCase {
    private var cacheNames: [String] = []

    override func tearDown() {
        if let root = ScriptManager.getSandboxBuildDirectoryURL() {
            for name in cacheNames { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        }
        super.tearDown()
    }
    func testWholePackageCopiesPreserveRequirementsAndResourcesWithFreshIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptWidgetPackage(path: root.appendingPathComponent("TemplateSource-\(UUID().uuidString)"))
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeFile(relativePath: "src/main.jsx", content: "$render(<text>Real agenda</text>);").0)
        XCTAssertTrue(source.writeFile(relativePath: "data/nested.txt", content: "resource").0)
        var manifest = WidgetPackageManifest.newProject(name: "Agenda-\(UUID().uuidString)")
        manifest.entry = "src/main.jsx"
        manifest.minimumRuntimeVersion = "1.3"
        manifest.permissions = [.calendar, .storage]
        XCTAssertTrue(source.writeManifest(manifest).0)
        let original = try Data(contentsOf: source.manifestPath)
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root.appendingPathComponent("library"))
        let first = manager.createScript(fromTemplate: source)
        let second = manager.createScript(fromTemplate: source)
        if first.0 { cacheNames.append(first.1) }
        if second.0 { cacheNames.append(second.1) }
        XCTAssertTrue(first.0, first.1); XCTAssertTrue(second.0, second.1)
        XCTAssertNotEqual(first.1, second.1)
        let installed = manager.getScriptPackage(packageName: first.1)
        let copied = try XCTUnwrap(installed.readManifest())
        XCTAssertEqual(copied.minimumRuntimeVersion, "1.3")
        XCTAssertEqual(copied.permissions, [.calendar, .storage])
        XCTAssertEqual(copied.entry, "src/main.jsx")
        XCTAssertNotEqual(copied.id, manifest.id)
        XCTAssertNotEqual(copied.id, manager.getScriptPackage(packageName: second.1).readManifest()?.id)
        XCTAssertEqual(installed.readFile(relativePath: "data/nested.txt").0, "resource")
        XCTAssertEqual(installed.readMainFile().0, "$render(<text>Real agenda</text>);")
        XCTAssertEqual(try Data(contentsOf: source.manifestPath), original)
        XCTAssertEqual(manager.scriptCount(), 2)
    }

    func testRejectedTemplateNeverPublishesPartialLibraryOrFollowsHiddenSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadTemplate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptWidgetPackage(path: root.appendingPathComponent("TemplateSource-\(UUID().uuidString)"))
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeMainFile(content: "$render(<text>source</text>);").0)
        let outside = root.appendingPathComponent("outside.txt")
        try "untouched".write(to: outside, atomically: true, encoding: .utf8)
        let link = source.path.appendingPathComponent(".hidden-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root.appendingPathComponent("library"))
        XCTAssertFalse(manager.createScript(fromTemplate: source).0)
        XCTAssertEqual(manager.scriptCount(), 0)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        try FileManager.default.removeItem(at: link)
        var manifest = WidgetPackageManifest.newProject(name: "Future")
        manifest.minimumRuntimeVersion = "1.999"
        try JSONEncoder().encode(manifest).write(to: source.manifestPath)
        XCTAssertFalse(manager.createScript(fromTemplate: source).0)
        XCTAssertEqual(manager.scriptCount(), 0)
        manifest.minimumRuntimeVersion = nil
        manifest.name = "../escape"
        try JSONEncoder().encode(manifest).write(to: source.manifestPath)
        XCTAssertFalse(manager.createScript(fromTemplate: source).0)
        XCTAssertEqual(manager.scriptCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
}


final class LocationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_268_800)

    private func record(age: Double = 60, precision: String = "full") -> [String: Any] {
        ["latitude": 37.3349, "longitude": -122.009, "altitude": 0, "accuracy": 10,
         "verticalAccuracy": 10, "speed": -1, "course": -1,
         "timestampSeconds": now.timeIntervalSince1970 - age, "accuracyAuthorization": precision]
    }

    func testSystemAndWidgetAuthorizationsAreIndependentOfCachePresence() {
        for status in ["notDetermined", "denied", "restricted", "unknown", "disabled"] {
            XCTAssertFalse(ScriptWidgetLocationPolicy.canRead(servicesEnabled: true, status: status, widget: false, widgetAuthorized: true), status)
            XCTAssertFalse(ScriptWidgetLocationPolicy.canRead(servicesEnabled: true, status: status, widget: true, widgetAuthorized: true), status)
        }
        for status in ["authorizedAlways", "authorizedWhenInUse"] {
            XCTAssertTrue(ScriptWidgetLocationPolicy.canRead(servicesEnabled: true, status: status, widget: false, widgetAuthorized: false))
            XCTAssertFalse(ScriptWidgetLocationPolicy.canRead(servicesEnabled: true, status: status, widget: true, widgetAuthorized: false))
            XCTAssertTrue(ScriptWidgetLocationPolicy.canRead(servicesEnabled: true, status: status, widget: true, widgetAuthorized: true))
            XCTAssertFalse(ScriptWidgetLocationPolicy.canRead(servicesEnabled: false, status: status, widget: true, widgetAuthorized: true))
        }
    }

    func testLocationCacheValidatesBoundsFreshnessAndPrecision() throws {
        func decode(_ value: [String: Any], precision: String = "full", maxAge: Double = 120) throws -> [String: Any]? {
            ScriptWidgetLocationCache.decode(try JSONSerialization.data(withJSONObject: value), accuracyAuthorization: precision, maxAgeSeconds: maxAge, now: now)
        }
        let fresh = try XCTUnwrap(decode(record()))
        XCTAssertEqual(fresh["age"] as? Double, 60)
        XCTAssertEqual(fresh["isStale"] as? Bool, false)
        XCTAssertNil(fresh["timestampSeconds"])
        XCTAssertEqual(try decode(record(age: 121))?["isStale"] as? Bool, true)
        XCTAssertNil(try decode(record(age: 86_401)))
        XCTAssertNil(try decode(record(age: -1)))
        XCTAssertNil(try decode(record(), precision: "reduced"))
        XCTAssertNotNil(try decode(record(precision: "reduced"), precision: "reduced"))
        for (key, value) in [("latitude", 91), ("longitude", -181), ("latitude", true), ("accuracy", -1), ("timestampSeconds", "yesterday"), ("accuracyAuthorization", "unknown"), ("extra", 1)] as [(String, Any)] {
            var invalid = record(); invalid[key] = value
            XCTAssertNil(try decode(invalid), key)
        }
        XCTAssertNil(ScriptWidgetLocationCache.decode(Data(repeating: 32, count: 4_097), accuracyAuthorization: "full", maxAgeSeconds: 0, now: now))
    }

    func testRevocationInvalidPayloadAndPrecisionDowngradeEraseCachedCoordinates() throws {
        let domain = "LocationCacheTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        let data = try JSONSerialization.data(withJSONObject: record())
        for (allowed, precision) in [(false, "full"), (true, "reduced")] {
            store.set(data, forKey: ScriptWidgetLocationCache.key)
            XCTAssertNil(ScriptWidgetLocationCache.read(defaults: store, allowed: allowed, accuracyAuthorization: precision, maxAgeSeconds: 120, now: now))
            XCTAssertNil(store.object(forKey: ScriptWidgetLocationCache.key))
        }
        store.set(Data("invalid".utf8), forKey: ScriptWidgetLocationCache.key)
        XCTAssertNil(ScriptWidgetLocationCache.read(defaults: store, allowed: true, accuracyAuthorization: "full", maxAgeSeconds: nil, now: now))
        XCTAssertNil(store.object(forKey: ScriptWidgetLocationCache.key))
        store.set(data, forKey: ScriptWidgetLocationCache.key)
        XCTAssertNotNil(ScriptWidgetLocationCache.read(defaults: store, allowed: true, accuracyAuthorization: "full", maxAgeSeconds: 120, now: now))
        XCTAssertNotNil(store.object(forKey: ScriptWidgetLocationCache.key))
    }

    func testPackagePermissionFailsClosedAndPreservesLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocationPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = ScriptWidgetPackage(path: root, readonly: true)
        XCTAssertTrue(ScriptWidgetLocationPolicy.packageAllows(package))
        var manifest = WidgetPackageManifest.newProject(name: "Location")
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        XCTAssertFalse(ScriptWidgetLocationPolicy.packageAllows(package))
        manifest.permissions = [.location]
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        XCTAssertTrue(ScriptWidgetLocationPolicy.packageAllows(package))
        manifest.minimumRuntimeVersion = "1.999"
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        XCTAssertFalse(ScriptWidgetLocationPolicy.packageAllows(package))
        try Data("invalid".utf8).write(to: package.manifestPath)
        XCTAssertFalse(ScriptWidgetLocationPolicy.packageAllows(package))
    }
}


final class TimelinePlanningTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func plan(_ times: [String], zone: String = "UTC", now: String) -> ScriptWidgetTimelinePlan {
        let value = date(now)
        return ScriptWidgetTimelinePlan(schedule: .init(dailyTimes: times, timeZone: zone), now: value, fallbackReload: value.addingTimeInterval(86_400))
    }

    func testImmediateEntryLegacyFrequencyAndBoundedFutureTransitions() {
        let now = date("2026-01-01T05:00:00Z")
        let legacy = ScriptWidgetTimelinePlan(schedule: nil, now: now, fallbackReload: now.addingTimeInterval(3_600))
        XCTAssertEqual(legacy.entries.count, 1)
        XCTAssertEqual(legacy.entries[0].date, now)
        XCTAssertFalse(legacy.entries[0].isProjection)
        XCTAssertEqual(legacy.reloadAfter, now.addingTimeInterval(3_600))
        let scheduled = plan(["06:00", "12:00", "18:00", "22:00"], now: "2026-01-01T05:00:00Z")
        XCTAssertEqual(scheduled.entries.count, 5)
        XCTAssertEqual(scheduled.entries.map(\.slot), [3, 0, 1, 2, 3])
        XCTAssertTrue(scheduled.entries.dropFirst().allSatisfy(\.isProjection))
        XCTAssertTrue(scheduled.entries.allSatisfy { $0.date <= now.addingTimeInterval(86_400) })
        XCTAssertEqual(scheduled.entries[1].environments(timeZone: scheduled.timeZone)["timeline-date"], "2026-01-01T06:00:00.000Z")
    }

    func testMidnightYearBoundaryAndNonHourTimeZone() {
        let midnight = plan(["00:00", "12:00"], now: "2026-12-31T23:59:00Z")
        XCTAssertEqual(midnight.entries[1].date, date("2027-01-01T00:00:00Z"))
        XCTAssertEqual(midnight.entries[1].slot, 0)
        let kathmandu = plan(["06:00", "18:00"], zone: "Asia/Kathmandu", now: "2026-01-01T00:00:00Z")
        XCTAssertEqual(kathmandu.entries[1].date, date("2026-01-01T00:15:00Z"))
        XCTAssertEqual(kathmandu.timeZone.identifier, "Asia/Kathmandu")
        let local = ScriptWidgetTimelinePlan(schedule: .init(dailyTimes: ["06:00"], timeZone: nil), now: date("2026-01-01T00:00:00Z"), fallbackReload: date("2026-01-02T00:00:00Z"), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(local.entries[1].date, date("2026-01-01T21:00:00Z"))
    }

    func testDSTGapCollapseAndRepeatedHourFirstOccurrence() {
        let gap = plan(["02:00", "02:30", "06:00"], zone: "America/Los_Angeles", now: "2026-03-08T09:00:00Z")
        XCTAssertEqual(gap.entries[1].date, date("2026-03-08T10:00:00Z"))
        XCTAssertEqual(gap.entries[1].slot, 1)
        XCTAssertEqual(Set(gap.entries.map(\.date)).count, gap.entries.count)
        let repeated = plan(["01:30", "02:30"], zone: "America/Los_Angeles", now: "2026-11-01T08:00:00Z")
        XCTAssertEqual(repeated.entries[1].date, date("2026-11-01T08:30:00Z"))
        XCTAssertFalse(repeated.entries.contains { $0.date == date("2026-11-01T09:30:00Z") })
        let afterRollback = plan(["01:30", "02:30"], zone: "America/Los_Angeles", now: "2026-11-01T09:10:00Z")
        XCTAssertEqual(afterRollback.entries[0].slot, 0)
    }

    func testCapacityRequestsReloadBeforeAnOmittedSpringTransition() {
        let value = plan(["06:00", "06:10", "06:20", "06:30"], zone: "America/Los_Angeles", now: "2026-03-07T13:59:00Z")
        XCTAssertEqual(value.entries.count, ScriptWidgetTimelinePlan.maximumEntries)
        XCTAssertLessThanOrEqual(value.reloadAfter, value.entries.last!.date)
    }

    func testInvalidSchedulesAndUnknownNestedKeysFailClosed() throws {
        for times in [[], ["25:00"], ["6:00"], ["06:00", "06:00"], ["12:00", "06:00"], ["00:00", "01:00", "02:00", "03:00", "04:00"]] as [[String]] {
            XCTAssertFalse(WidgetPackageTimeline(dailyTimes: times, timeZone: "UTC").isValid)
        }
        XCTAssertFalse(WidgetPackageTimeline(dailyTimes: ["06:00"], timeZone: "GMT+0200").isValid)
        XCTAssertFalse(WidgetPackageTimeline(dailyTimes: ["06:00"], timeZone: "Earth/Unknown").isValid)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineManifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = ScriptWidgetPackage(path: root, readonly: true)
        var manifest = WidgetPackageManifest.newProject(name: "Timeline")
        manifest.timeline = .init(dailyTimes: ["06:00", "22:00"], timeZone: "UTC")
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        XCTAssertEqual(package.readManifest()?.timeline, manifest.timeline)
        XCTAssertTrue(WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false).isValid)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        object["timeline"] = ["dailyTimes": ["06:00"], "execute": "untrusted"]
        try JSONSerialization.data(withJSONObject: object).write(to: package.manifestPath)
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
    }
}

final class ScriptWidgetRecordStoreTests: XCTestCase {
    private var fixtures: [(root: URL, suite: String)] = []
    override func tearDown() {
        for fixture in fixtures {
            UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixtures.removeAll()
        super.tearDown()
    }
    private func makeStore(_ kind: ScriptWidgetRecordKind = .hydration, name: String? = nil, peers: @escaping () -> [String] = { [] }) throws -> ScriptWidgetRecordStore {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordStoreTests-" + id)
        let directory = root.appendingPathComponent(name ?? ("Records-" + id))
        let container = root.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let suite = "app.scriptwidget.record-tests." + id
        fixtures.append((root, suite))
        let package = ScriptWidgetPackage(path: directory, readonly: false)
        var manifest = WidgetPackageManifest.newProject(name: package.name)
        manifest.minimumRuntimeVersion = "1.3"; manifest.permissions = [.storage]
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("widget.json"))
        try Data("$render(<text>Records</text>);".utf8).write(to: directory.appendingPathComponent("main.jsx"))
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "kind": kind.rawValue]).write(to: directory.appendingPathComponent("record-template.json"))
        return try ScriptWidgetRecordStore(package: package, container: container, defaults: XCTUnwrap(UserDefaults(suiteName: suite)), peers: peers)
    }
    private func key(_ store: ScriptWidgetRecordStore, _ key: String) -> String { "script.\(store.package.name)." + key }
    private let sample = #"{"version":1,"revision":1,"entries":[{"date":"2026-01-01","value":250}],"undo":null}"#

    func testPublishedBackupSchemaCoversEveryNativeKindAndItsExactKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try skipUnlessRepositoryCheckout(root)
        let data = try Data(contentsOf: root.appendingPathComponent("Shared/ScriptWidgetRuntime/Resource/record-backup.schema.json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let kinds = try XCTUnwrap(properties["kind"]?["enum"] as? [String])
        XCTAssertEqual(Set(kinds), Set(ScriptWidgetRecordKind.allCases.map(\.rawValue)))
        XCTAssertEqual(kinds.count, ScriptWidgetRecordKind.allCases.count)
        let branches = try XCTUnwrap(schema["allOf"] as? [[String: Any]])
        XCTAssertEqual(branches.count, kinds.count)
        for kind in ScriptWidgetRecordKind.allCases {
            let matching = branches.filter { branch in
                let condition = branch["if"] as? [String: Any]
                let fields = condition?["properties"] as? [String: [String: Any]]
                return fields?["kind"]?["const"] as? String == kind.rawValue
            }
            XCTAssertEqual(matching.count, 1, kind.rawValue)
            let rule = try XCTUnwrap(matching.first?["then"] as? [String: Any], kind.rawValue)
            let fields = try XCTUnwrap(rule["properties"] as? [String: [String: Any]])
            for field in ["values", "unsupportedValues"] {
                let names = try XCTUnwrap(fields[field]?["propertyNames"] as? [String: Any])
                let allowed = try XCTUnwrap(names["enum"] as? [String])
                XCTAssertEqual(Set(allowed), Set(kind.keys), "\(kind.rawValue).\(field)")
                XCTAssertEqual(allowed.count, kind.keys.count)
                XCTAssertFalse(allowed.contains("credentials"))
            }
            let store = try makeStore(kind)
            let snapshot = try store.settingConfiguration(kind.defaults, in: store.read())
            let backup = try store.backup(snapshot)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
            XCTAssertEqual(envelope["kind"] as? String, kind.rawValue)
            XCTAssertEqual(Set(envelope.keys), Set(try XCTUnwrap(schema["required"] as? [String])))
            XCTAssertEqual(try store.previewRestore(backup).snapshot, snapshot)
        }
    }

    func testBackupRoundTripIsScopedAndRestoresRecordsWithConfiguration() throws {
        let store = try makeStore()
        try store.defaults.writeValue("must not export", forKey: key(store, "credentials"))
        try store.defaults.writeValue("other package", forKey: "script.Other.hydration.v1")
        let empty = try store.read()
        var incoming = try store.settingConfiguration(["goal": 10, "glassML": 200], in: empty)
        incoming.values["hydration.v1"] = sample
        try store.apply(incoming, expected: empty)
        let data = try store.backup(store.read())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("must not export"))
        let preview = try store.previewRestore(data)
        XCTAssertEqual(preview.sourceName, store.package.name)
        XCTAssertEqual(preview.rows.map(\.value), ["250 mL"])
        let current = try store.read()
        try store.apply(.init(values: [:]), expected: current)
        try store.apply(preview.snapshot, expected: store.read())
        XCTAssertEqual(try store.read(), incoming)
        XCTAssertEqual(try store.defaults.readValue(forKey: key(store, "credentials")) as? String, "must not export")
        XCTAssertEqual(try store.defaults.readValue(forKey: "script.Other.hydration.v1") as? String, "other package")
        let reopened = try ScriptWidgetRecordStore(package: store.package, container: store.container,
                                                  defaults: XCTUnwrap(UserDefaults(suiteName: fixtures.last!.suite)))
        XCTAssertEqual(try reopened.read(), incoming)
    }

    func testRestoreRejectsConcurrentWidgetEditsWithoutPartiallyApplyingConfiguration() throws {
        let store = try makeStore()
        let expected = try store.read()
        let replacement = try store.settingConfiguration(["goal": 12, "glassML": 300], in: expected)
        XCTAssertTrue(ScriptWidgetAtomicPreferences.compareAndSetString(container: store.container, defaults: store.defaults,
                                                                      namespace: "script.\(store.package.name).", key: "hydration.v1", expected: "", value: sample))
        XCTAssertThrowsError(try store.apply(replacement, expected: expected)) { XCTAssertEqual($0 as? ScriptWidgetRecordError, .conflict) }
        XCTAssertEqual(try store.read().values["hydration.v1"], sample)
        XCTAssertNil(try store.read().values[ScriptWidgetRecordStore.configurationKey])
    }

    func testValidBackupCanRepairWronglyTypedDataButCannotIgnoreAnInterveningChange() throws {
        let store = try makeStore()
        let good = ScriptWidgetRecordSnapshot(values: ["hydration.v1": sample])
        let backup = try store.backup(good)
        try store.defaults.writeValue(Data("wrong type".utf8), forKey: key(store, "hydration.v1"))
        let broken = try store.read()
        XCTAssertEqual(broken.unsupported.count, 1)
        XCTAssertThrowsError(try store.rows(in: broken))
        let quarantine = try store.backup(broken)
        XCTAssertThrowsError(try store.previewRestore(quarantine))
        let preview = try store.previewRestore(backup)
        try store.defaults.writeValue(Data("newer wrong type".utf8), forKey: key(store, "hydration.v1"))
        XCTAssertThrowsError(try store.apply(preview.snapshot, expected: broken)) { XCTAssertEqual($0 as? ScriptWidgetRecordError, .conflict) }
        try store.apply(preview.snapshot, expected: store.read())
        XCTAssertEqual(try store.read(), good)
    }

    func testMalformedStringsRemainExportableAndAreRejectedOnRestore() throws {
        let store = try makeStore()
        try store.defaults.writeValue("broken JSON", forKey: key(store, "hydration.v1"))
        let current = try store.read()
        XCTAssertEqual(current.values["hydration.v1"], "broken JSON")
        XCTAssertThrowsError(try store.rows(in: current))
        let data = try store.backup(current)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("broken JSON"))
        XCTAssertThrowsError(try store.previewRestore(data))
        XCTAssertEqual(try store.read(), current)
    }

    func testBackupCannotSupplyForeignKeysKindsPathsOrUnsupportedVersions() throws {
        let store = try makeStore()
        let valid = try JSONSerialization.jsonObject(with: store.backup(.init(values: [:]))) as! [String: Any]
        let cases: [[String: Any]] = [
            valid.merging(["values": ["credentials": "token"]]) { _, new in new },
            valid.merging(["kind": "mood"]) { _, new in new },
            valid.merging(["formatVersion": 2]) { _, new in new },
            valid.merging(["formatVersion": true]) { _, new in new },
            valid.merging(["packageName": "../escape"]) { _, new in new },
            valid.merging(["namespace": "script.Other."]) { _, new in new },
            valid.merging(["values": ["hydration.v1": #"{"version":1,"revision":true,"entries":[],"undo":null}"#]]) { _, new in new },
        ]
        for item in cases { XCTAssertThrowsError(try store.previewRestore(JSONSerialization.data(withJSONObject: item))) }
        XCTAssertThrowsError(try store.previewRestore(Data(repeating: 32, count: ScriptWidgetRecordStore.maximumBackupBytes + 1)))
        XCTAssertEqual(try store.read().values, [:])
    }

    @MainActor
    func testLauncherSavesOrderedLinksAndEncodesShortcutInputWithoutParameterInjection() throws {
        let store=try makeStore(.launcher),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        let item=ScriptWidgetLauncherItem(id:"shortcut",title:"Read",icon:"play.fill",type:"shortcut",target:"阅读 + Plan & finish",input:"One+two & next=secret\n✓")
        let url=try item.destination(),parts=try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false))
        XCTAssertEqual(parts.queryItems?.map(\.name),["name","input","text"])
        XCTAssertEqual(parts.queryItems?.first(where:{$0.name=="name"})?.value,item.target)
        XCTAssertEqual(parts.queryItems?.first(where:{$0.name=="text"})?.value,item.input)
        model.launcherItems=[item,ScriptWidgetLauncherItem.defaults[0]];model.habitTitle="My links";model.accent="rose";model.saveConfiguration()
        XCTAssertFalse(model.isError,model.message ?? "")
        let current=try store.read(),values=try store.configuration(in:current)
        XCTAssertEqual(ScriptWidgetLauncherItem.decode(values["items"])?.map(\.id),["shortcut","github"])
        XCTAssertEqual(try store.previewRestore(store.backup(current)).snapshot,current)
        let captured=try XCTUnwrap(model.prepareLauncherTest(id:item.id));XCTAssertEqual(captured.1,url)
        model.finishLauncherTest(item:item,accepted:false);XCTAssertTrue(model.launcherTestFailed);XCTAssertTrue(model.launcherTestMessage?.contains("Couldn’t open")==true)
        model.finishLauncherTest(item:item,accepted:true);XCTAssertFalse(model.launcherTestFailed);XCTAssertTrue(model.launcherTestMessage?.contains("accepted")==true)
        model.launcherItems.removeFirst();model.finishLauncherTest(item:item,accepted:false);XCTAssertFalse(model.launcherTestFailed,"Late callbacks must not retarget an edited draft")
    }

    func testLauncherRejectsUnsafeOrMalformedLinksAndEnforcesConfigurationBudget() throws {
        let store=try makeStore(.launcher),current=try store.read(),base=ScriptWidgetLauncherItem.defaults[0]
        for target in ["https://user:pass@example.com","https://example.com/%zz","https://example.com:70000","https://example.com/with space"] {
            var item=base;item.target=target;XCTAssertThrowsError(try item.destination(),target)
        }
        for target in ["javascript:alert(1)","file:///tmp/private","scriptwidget://import","app-prefs:root","https://example.com"] {
            var item=base;item.type="app";item.target=target;XCTAssertThrowsError(try item.destination(),target)
        }
        var large=base;large.target="https://example.com/"+String(repeating:"a",count:1800)
        let items=(0..<6).map { index -> ScriptWidgetLauncherItem in var item=large;item.id=String(index);return item }
        let settings:[String:Any]=["title":"Six links","accent":"blue","items":items.map(\.dictionary)]
        let next=try store.settingConfiguration(settings,in:current)
        XCTAssertGreaterThan(next.values[ScriptWidgetRecordStore.configurationKey]?.utf8.count ?? 0,4096)
        XCTAssertNoThrow(try store.validate(next))
        XCTAssertThrowsError(try store.settingConfiguration(["title":"Bad","accent":"blue","items":[base.dictionary,base.dictionary]],in:current))
    }

    @MainActor
    func testRepositoryConfigurationAndBackupExcludeTransientCounts() throws {
        let store=try makeStore(.repoStats),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        model.repository="apple/swift";model.accent="green";model.saveConfiguration()
        XCTAssertFalse(model.isError,model.message ?? "")
        let current=try store.read();XCTAssertEqual(try store.configuration(in:current)["repository"] as? String,"apple/swift")
        XCTAssertTrue(try store.rows(in:current).isEmpty)
        try store.defaults.writeValue("transient public counts",forKey:"script."+store.package.name+".github.stats.v1")
        let backup=try store.backup(current)
        XCTAssertFalse(String(decoding:backup,as:UTF8.self).contains("transient public counts"))
        XCTAssertEqual(try store.previewRestore(backup).snapshot,current)
        for invalid:[String:Any] in [["repository":"owner/.."],["repository":"owner/repo/extra"],["repository":"user:token/repo"],["repository":"https://github.com/owner/repo"],["repository":"owner/repo?x=1"],["repository":"-owner/repo"],["repository":true],["accent":"red"]] {
            XCTAssertThrowsError(try store.settingConfiguration(store.kind.defaults.merging(invalid){_,new in new},in:current))
        }
        model.previewRestore(backup);XCTAssertTrue(model.restoreConfigurationSummary?.contains("apple/swift")==true)
    }

    @MainActor
    func testHealthCardConfigurationRestoresGoalsWithoutHealthReadings() throws {
        let store = try makeStore(.healthCard), model = ScriptWidgetRecordsModel(package: store.package, store: store)
        model.healthMetric = "energy"; model.stepsGoal = 9000; model.energyGoal = 650; model.saveConfiguration()
        XCTAssertFalse(model.isError, model.message ?? "")
        let snapshot = try store.read()
        XCTAssertEqual(try store.configuration(in: snapshot)["energyGoal"] as? Int, 650)
        XCTAssertTrue(try store.rows(in: snapshot).isEmpty)
        try store.defaults.writeValue("private health sample", forKey: "script." + store.package.name + ".health.cache")
        let backup = try store.backup(snapshot)
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("private health sample"))
        XCTAssertEqual(try store.previewRestore(backup).snapshot, snapshot)
        for invalid: [String: Any] in [["metric":"sleep"],["stepsGoal":true],["stepsGoal":0],["stepsGoal":100001],["energyGoal":1.5],["energyGoal":10001]] {
            XCTAssertThrowsError(try store.settingConfiguration(store.kind.defaults.merging(invalid) { _, new in new }, in: snapshot))
        }
        model.previewRestore(backup); XCTAssertTrue(model.restoreConfigurationSummary?.contains("650") == true)
    }

    func testWeatherConfigurationValidatesCoordinatesAndBackupsExcludeForecastLocationCache() throws {
        let store=try makeStore(.weather),before=try store.read()
        let values: [String:Any] = ["city":"London","latitude":51.5,"longitude":-0.12,"useLocation":false,"unit":"f"]
        let updated=try store.settingConfiguration(values,in:before)
        try store.apply(updated,expected:before)
        try store.defaults.writeValue("private coarse GPS forecast",forKey:"script."+store.package.name+".weather.met.v1")
        let backup=try store.backup(store.read()),restored=try store.previewRestore(backup)
        XCTAssertFalse(String(decoding:backup,as:UTF8.self).contains("private coarse GPS forecast"))
        XCTAssertEqual(try store.configuration(in:restored.snapshot)["city"] as? String,"London")
        for invalid: [String:Any] in [["latitude":91],["longitude":-181],["latitude":true],["longitude":Double.infinity],["unit":"kelvin"],["useLocation":1],["city":String(repeating:"x",count:61)]] {
            XCTAssertThrowsError(try store.settingConfiguration(values.merging(invalid){_,new in new},in:updated))
        }
    }

    @MainActor
    func testWeatherCitySelectionAndConfigurationSaveRequireNoSystemLocationAccess() throws {
        let store=try makeStore(.weather),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        model.chooseCity(.init(name:"London",latitude:51.5,longitude:-0.12))
        model.weatherUseLocation=false;model.weatherUnit="f";model.saveConfiguration()
        XCTAssertFalse(model.isError,model.message ?? "")
        let values=try store.configuration(in:store.read())
        XCTAssertEqual(values["city"] as? String,"London");XCTAssertEqual(values["latitude"] as? Double,51.5)
        XCTAssertEqual(values["unit"] as? String,"f");XCTAssertEqual(values["useLocation"] as? Bool,false)
    }

    private func photoFixture(width: Int = 1600, height: Int = 800) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.8,green:0.2,blue:0.1,alpha:1)); context.fill(CGRect(x:0,y:0,width:width/2,height:height))
        context.setFillColor(CGColor(red:0.1,green:0.3,blue:0.8,alpha:1)); context.fill(CGRect(x:width/2,y:0,width:width/2,height:height))
        return try XCTUnwrap(context.makeImage())
    }

    func testWallpaperCropKeepsExactPixelRectangleAndBoundsOutput() throws {
        let image=try photoFixture(width:1600,height:1200)
        let selection=ScriptWidgetWallpaperCrop(x:1000,y:200,width:600,height:800)
        XCTAssertEqual(try selection.rectangle(imageWidth:1600,imageHeight:1200),CGRect(x:1000,y:200,width:600,height:800))
        let cropped=try selection.cropped(image);XCTAssertEqual(cropped.width,600);XCTAssertEqual(cropped.height,800)
        let bytes=try ScriptWidgetPhotoPreparation.encode(cropped),source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil)),result=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let pixels=try XCTUnwrap(result.dataProvider?.data),pointer=try XCTUnwrap(CFDataGetBytePtr(pixels));XCTAssertGreaterThan(pointer[2],pointer[0])
        let large=try ScriptWidgetWallpaperCrop(x:0,y:0,width:1600,height:1200).cropped(image)
        XCTAssertEqual(large.width,1024);XCTAssertEqual(large.height,768)
        for crop in [ScriptWidgetWallpaperCrop(x:-1,y:0,width:1,height:1),.init(x:0,y:0,width:0,height:1),.init(x:1600,y:0,width:1,height:1),.init(x:0,y:1199,width:1,height:2),.init(x:Int.max,y:0,width:Int.max,height:1)] {
            XCTAssertThrowsError(try crop.rectangle(imageWidth:1600,imageHeight:1200))
        }
        for family in ScriptWidgetWallpaperAsset.families {
            for (width,height) in [(1206,2622),(2752,2064),(100,100),(1,1)] {
                XCTAssertNoThrow(try ScriptWidgetWallpaperCrop.initial(family:family,imageWidth:width,imageHeight:height).rectangle(imageWidth:width,imageHeight:height))
            }
        }
    }

    func testWallpaperCropUsesTopLeftPixelsWithoutFlippingSavedRows() throws {
        let rgba=Data([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255])
        let provider=try XCTUnwrap(CGDataProvider(data:rgba as CFData))
        let image=try XCTUnwrap(CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let top=try ScriptWidgetWallpaperCrop(x:0,y:0,width:1,height:1).cropped(image),bottom=try ScriptWidgetWallpaperCrop(x:1,y:1,width:1,height:1).cropped(image)
        let topData=try XCTUnwrap(top.dataProvider?.data),t=try XCTUnwrap(CFDataGetBytePtr(topData))
        XCTAssertGreaterThan(t[0],200);XCTAssertLessThan(t[2],10)
        let bottomData=try XCTUnwrap(bottom.dataProvider?.data),b=try XCTUnwrap(CFDataGetBytePtr(bottomData))
        XCTAssertGreaterThan(b[0],200);XCTAssertGreaterThan(b[1],200);XCTAssertLessThan(b[2],10)
        let full=try ScriptWidgetWallpaperCrop(x:0,y:0,width:2,height:2).cropped(image)
        let bytes=try XCTUnwrap(full.dataProvider?.data),pointer=try XCTUnwrap(CFDataGetBytePtr(bytes))
        XCTAssertGreaterThan(pointer[0],200);XCTAssertLessThan(pointer[2],10)
        XCTAssertGreaterThan(pointer[10],200);XCTAssertLessThan(pointer[8],10)
    }

    @MainActor
    func testWallpaperPortableDefaultsLoadInNativeConfigurationWithoutWritingRecords() throws {
        let store = try makeStore(.wallpaper)
        var values = ScriptWidgetRecordKind.wallpaper.defaults
        values["title"] = "From Web Studio"
        values["content"] = "date"
        values["backgrounds"] = [["family":"medium", "appearance":"light", "label":"Top left", "image":"background-00000000-0000-4000-8000-000000000001"]]
        let raw = try XCTUnwrap(try store.settingConfiguration(values, in: store.read()).values[ScriptWidgetRecordStore.configurationKey])
        let url = store.package.path.appendingPathComponent("wallpaper.json")
        try Data(raw.utf8).write(to: url)
        let model = ScriptWidgetRecordsModel(package: store.package, store: store)
        XCTAssertFalse(model.isError, model.message ?? "")
        XCTAssertEqual(model.habitTitle, "From Web Studio")
        XCTAssertEqual(model.wallpaperContent, "date")
        XCTAssertEqual(model.wallpaperBackgrounds.first?.label, "Top left")
        XCTAssertTrue(try store.read().values.isEmpty, "Portable defaults do not seed user storage")
        model.habitTitle = "My native choice"
        model.saveConfiguration()
        XCTAssertFalse(model.isError, model.message ?? "")
        try Data("broken package configuration".utf8).write(to: url)
        model.reload()
        XCTAssertFalse(model.isError, "Saved native settings take precedence over broken portable defaults")
        XCTAssertEqual(model.habitTitle, "My native choice")
        XCTAssertThrowsError(try store.configuration(in: .init(values: [ScriptWidgetRecordStore.configurationKey:"invalid saved settings"])))
    }

    func testWallpaperPortableConfigurationRejectsPresentInvalidFilesAndUnsafePaths() throws {
        let store = try makeStore(.wallpaper)
        let url = store.package.path.appendingPathComponent("wallpaper.json")
        XCTAssertEqual(try store.configuration(in: store.read())["title"] as? String, "My space")
        for data in [Data(), Data("{}".utf8), Data([0xff]), Data(repeating: 32, count: 4097)] {
            try data.write(to: url)
            XCTAssertThrowsError(try store.configuration(in: store.read()))
        }
        try FileManager.default.removeItem(at: url)
        let outside = store.container.appendingPathComponent("outside-wallpaper.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.configuration(in: store.read()))
        let water = try makeStore(.hydration)
        try Data("invalid but unrelated".utf8).write(to: water.package.path.appendingPathComponent("wallpaper.json"))
        XCTAssertEqual(try water.configuration(in: water.read())["goal"] as? Int, 8)
    }

    @MainActor
    func testWallpaperSelectionsSaveExplicitlyProtectResourcesAndRoundTripConfiguration() throws {
        let store=try makeStore(.wallpaper),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        let image=try ScriptWidgetWallpaperCrop(x:0,y:0,width:400,height:200).cropped(photoFixture())
        XCTAssertTrue(model.addWallpaperCrop(image,family:"medium",appearance:"light",label:"Top left"))
        let first=try XCTUnwrap(model.wallpaperBackgrounds.first)
        XCTAssertTrue(try store.read().values.isEmpty)
        model.wallpaperContent="date";model.habitTitle="My space";model.saveConfiguration();XCTAssertFalse(model.isError,model.message ?? "")
        let saved=try store.read(),backup=try model.exportBackup()
        XCTAssertEqual(ScriptWidgetWallpaperAsset.decode(try store.configuration(in:saved)["backgrounds"]),[first])
        XCTAssertTrue(model.addWallpaperCrop(image,family:"medium",appearance:"light",label:"Top right"))
        XCTAssertEqual(model.wallpaperBackgrounds.count,1);XCTAssertEqual(model.wallpaperAssets.count,2)
        model.deleteUnusedWallpaper(first.image);XCTAssertEqual(model.wallpaperAssets.count,2,"Saved selections remain protected while a new crop is only a draft")
        model.saveConfiguration();model.deleteUnusedWallpaper(first.image);XCTAssertEqual(model.wallpaperAssets.count,1)
        model.previewRestore(backup);model.restore();XCTAssertFalse(model.isError)
        XCTAssertEqual(model.wallpaperBackgrounds,[first],"A configuration backup preserves references without inventing image files")
        XCTAssertFalse(model.wallpaperAssets.contains{$0.name==first.image})
        var invalid=ScriptWidgetRecordKind.wallpaper.defaults
        invalid["backgrounds"]=[first.dictionary,first.dictionary]
        XCTAssertThrowsError(try store.settingConfiguration(invalid,in:saved))
        for value in ["../private","photo-00000000-0000-4000-8000-000000000001","background-INVALID"] {
            var entry=first.dictionary;entry["image"]=value;invalid["backgrounds"]=[entry]
            XCTAssertThrowsError(try store.settingConfiguration(invalid,in:saved))
        }
        var linked=first.dictionary;linked["label"]="hidden\u{202e}"
        XCTAssertNil(ScriptWidgetWallpaperAsset.decode([linked]))
        XCTAssertNil(ScriptWidgetPackage(path:store.package.path,readonly:true).saveWallpaperImage(image))
    }

    func testWallpaperImportRetainsOrientationBoundsAndStripsMetadata() throws {
        let input=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(input,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try photoFixture(width:2500,height:1400),[kCGImagePropertyOrientation:6,kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.7,kCGImagePropertyGPSLatitudeRef:"N"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared=try ScriptWidgetPhotoPreparation.load(data:input as Data,maximumPixelSize:3072)
        XCTAssertEqual(prepared.width,1400);XCTAssertEqual(prepared.height,2500)
        let store=try makeStore(.wallpaper),crop=try ScriptWidgetWallpaperCrop(x:100,y:100,width:800,height:400).cropped(prepared)
        let name=try XCTUnwrap(store.package.saveWallpaperImage(crop)),bytes=try XCTUnwrap(ScriptWidgetPackageFiles.read(root:store.package.path,relative:"image/"+name+".png"))
        let source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil)),properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]);XCTAssertNil(properties[kCGImagePropertyOrientation])
        XCTAssertEqual(store.package.getImageList().count,1)
        for _ in 1..<12 { XCTAssertNotNil(store.package.saveWallpaperImage(crop)) };XCTAssertNil(store.package.saveWallpaperImage(crop))
    }

    func testPhotoPreparationBoundsCropAndRemovesOriginalMetadata() throws {
        let input = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(input,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try photoFixture(),[
            kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.7,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:122.4,kCGImagePropertyGPSLongitudeRef:"W"],
            kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2026:01:01 12:00:00"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try XCTUnwrap(CGImageSourceCreateWithData(input,nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original,0,nil) as? [CFString:Any])
        XCTAssertNotNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil((metadata[kCGImagePropertyExifDictionary] as? [CFString:Any])?[kCGImagePropertyExifDateTimeOriginal])
        let prepared = try ScriptWidgetPhotoPreparation.load(data:input as Data)
        XCTAssertLessThanOrEqual(max(prepared.width,prepared.height),1536)
        let cropped = try ScriptWidgetPhotoPreparation.crop(prepared,zoom:1,horizontal:0,vertical:0.5)
        XCTAssertEqual(cropped.width,cropped.height); XCTAssertLessThanOrEqual(cropped.width,768)
        let store = try makeStore(.photoCard)
        let name = try XCTUnwrap(store.package.savePhotoImage(cropped))
        let bytes = try XCTUnwrap(ScriptWidgetPackageFiles.read(root:store.package.path,relative:"image/"+name+".png"))
        let result = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result,0,nil) as? [CFString:Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let outputExif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any] ?? [:]
        XCTAssertNil(outputExif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertTrue(Set(outputExif.keys).isSubset(of:[kCGImagePropertyExifColorSpace,kCGImagePropertyExifPixelXDimension,kCGImagePropertyExifPixelYDimension]))
        let pixel = try XCTUnwrap(CGImageSourceCreateImageAtIndex(result,0,nil))
        let data = try XCTUnwrap(pixel.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertGreaterThan(pointer[0],pointer[2])
        XCTAssertEqual(try store.read().values,[:],"Importing an asset must not invent records or overwrite saved settings")
        XCTAssertThrowsError(try ScriptWidgetPhotoPreparation.load(data:Data("not an image".utf8)))
        XCTAssertThrowsError(try ScriptWidgetPhotoPreparation.load(data:Data(repeating:0,count:ScriptWidgetPhotoPreparation.maximumInputBytes+1)))
        for zoom in [0,5,Double.nan] { XCTAssertThrowsError(try ScriptWidgetPhotoPreparation.crop(prepared,zoom:zoom,horizontal:0.5,vertical:0.5)) }
        XCTAssertThrowsError(try ScriptWidgetPhotoPreparation.crop(prepared,zoom:1,horizontal:1.1,vertical:0.5))
    }

    func testPhotoPreparationRejectsOversizedDimensionsLinkedFilesAndFullAssetLibrary() throws {
        let store = try makeStore(.photoCard)
        let wide = try ScriptWidgetPhotoPreparation.encode(photoFixture(width:20001,height:1))
        XCTAssertThrowsError(try ScriptWidgetPhotoPreparation.load(data:wide))
        let bytes = try ScriptWidgetPhotoPreparation.encode(photoFixture(width:64,height:64))
        let source = store.package.path.appendingPathComponent("input.png"), link = store.package.path.appendingPathComponent("linked.png")
        try bytes.write(to:source)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try ScriptWidgetPhotoPreparation.load(url:link))
        let image = try ScriptWidgetPhotoPreparation.crop(photoFixture(width:64,height:64),zoom:1,horizontal:0.5,vertical:0.5)
        var names = Set<String>()
        for _ in 0..<12 { names.insert(try XCTUnwrap(store.package.savePhotoImage(image))) }
        XCTAssertEqual(names.count,12); XCTAssertNil(store.package.savePhotoImage(image))
        XCTAssertNil(ScriptWidgetPackage(path:store.package.path,readonly:true).savePhotoImage(image))
    }

    @MainActor
    func testPhotoConfigurationPreservesOrderedSelectionsAndRequiresExplicitSave() throws {
        let store = try makeStore(.photoCard)
        let model = ScriptWidgetRecordsModel(package:store.package,store:store)
        let image = try ScriptWidgetPhotoPreparation.crop(photoFixture(),zoom:2,horizontal:1,vertical:0.5)
        XCTAssertTrue(model.addPhoto(image)); XCTAssertTrue(model.addPhoto(image))
        XCTAssertEqual(model.photoAssets.count,2); XCTAssertEqual(model.photoNames.count,2)
        XCTAssertTrue(try store.read().values.isEmpty)
        let first = model.photoNames[0]
        model.movePhoto(model.photoNames[1],offset:-1)
        model.movePhoto("missing",offset:1)
        XCTAssertEqual(model.orderedPhotoAssets.map(\.name),model.photoNames)
        model.photoLayout="duo"; model.photoCaption="Two good moments"; model.habitTitle="Together"
        model.saveConfiguration(); XCTAssertFalse(model.isError,model.message ?? "")
        let saved = try store.read(), config = try store.configuration(in:saved)
        XCTAssertEqual(config["photos"] as? [String],model.photoNames)
        let backup = try model.exportBackup(); XCTAssertLessThan(backup.count,4096)
        XCTAssertTrue(String(decoding:backup,as:UTF8.self).contains(first))
        let protected = model.protectedPhotoNames
        model.photoNames.removeAll(); XCTAssertTrue(model.protectedPhotoNames.isSuperset(of:protected))
        model.deleteUnusedPhoto(first); XCTAssertEqual(model.photoAssets.count,2)
        model.saveConfiguration(); model.deleteUnusedPhoto(first); XCTAssertEqual(model.photoAssets.count,1)
        model.previewRestore(backup); XCTAssertTrue(model.restoreConfigurationSummary?.contains("Two good moments") == true)
        model.restore(); XCTAssertFalse(model.isError)
        XCTAssertEqual(model.photoNames.count,2,"Restore preserves settings even if photo files must be restored separately")
        XCTAssertFalse(model.photoAssets.contains { $0.name == first })
        let base = ScriptWidgetRecordKind.photoCard.defaults
        for bad: [String: Any] in [["photos":["../secret"]],["photos":[first,first]],["layout":"remote"],["caption":String(repeating:"x",count:81)],["title":" "]] {
            XCTAssertThrowsError(try store.settingConfiguration(base.merging(bad){_,new in new},in:saved))
        }
    }

    func testCountdownConfigurationValidatesCalendarDatesAndRestoresWithoutHistory() throws {
        let store = try makeStore(.countdown)
        let empty = try store.read()
        let config: [String: Any] = ["title": "Leap day", "targetDate": "2028-02-29", "repeatYearly": true, "accent": "rose"]
        let updated = try store.settingConfiguration(config, in: empty)
        try store.apply(updated, expected: empty)
        XCTAssertTrue(try store.rows(in: updated).isEmpty)
        let restored = try store.previewRestore(store.backup(updated))
        XCTAssertEqual(try store.configuration(in: restored.snapshot)["targetDate"] as? String, "2028-02-29")
        for badDate in ["2027-02-29", "2028-04-31", "1969-12-31", "10000-01-01", "2028-2-01", "2028-01-01T00:00:00"] {
            XCTAssertThrowsError(try store.settingConfiguration(config.merging(["targetDate": badDate]) { _, new in new }, in: updated))
        }
        XCTAssertThrowsError(try store.settingConfiguration(config.merging(["repeatYearly": 1]) { _, new in new }, in: updated))
        XCTAssertThrowsError(try store.settingConfiguration(config.merging(["accent": "red"]) { _, new in new }, in: updated))
        XCTAssertThrowsError(try store.settingConfiguration(config.merging(["title": String(repeating: "a", count: 41)]) { _, new in new }, in: updated))
        XCTAssertEqual(try store.read(), updated)
        XCTAssertThrowsError(try store.apply(updated, expected: empty))
    }

    @MainActor
    func testCountdownModelSavesDateTitleRecurrenceAndAccent() throws {
        let store = try makeStore(.countdown)
        let model = ScriptWidgetRecordsModel(package: store.package, store: store)
        model.habitTitle = "Summer trip"
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        model.countdownDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 7, day: 12, hour: 12)))
        model.repeatYearly = true; model.accent = "green"
        model.saveConfiguration()
        XCTAssertFalse(model.isError, model.message ?? "")
        let config = try store.configuration(in: store.read())
        XCTAssertEqual(config["targetDate"] as? String, "2027-07-12")
        XCTAssertEqual(config["title"] as? String, "Summer trip")
        XCTAssertEqual(config["repeatYearly"] as? Bool, true)
        XCTAssertEqual(config["accent"] as? String, "green")
        model.previewRestore(try model.exportBackup())
        XCTAssertTrue(model.restoreConfigurationSummary?.contains("Summer trip") == true)
        model.restore()
        XCTAssertFalse(model.isError, model.message ?? "")
    }

    func testCompanionHistoryConfigurationBackupAndInvalidActions() throws {
        for kind in [ScriptWidgetRecordKind.plantCare,.pocketPet] {
            let store=try makeStore(kind)
            var incoming=try store.settingConfiguration(kind.defaults,in:store.read())
            let value:Any=kind == .plantCare ? 1 : ["feed","play"]
            let data=try JSONSerialization.data(withJSONObject:["version":1,"revision":1,"entries":[["date":"2026-01-01","value":value]],"undo":NSNull()])
            incoming.values[kind.keys[0]]=String(decoding:data,as:UTF8.self)
            try store.apply(incoming,expected:store.read())
            XCTAssertEqual(try store.rows(in:store.read()).count,1)
            let backup=try store.backup(store.read()),restored=try store.previewRestore(backup)
            XCTAssertEqual(restored.snapshot,incoming)
            XCTAssertThrowsError(try store.settingConfiguration(["title":""],in:incoming))
            var invalid=incoming
            let badValue:Any=kind == .plantCare ? true : ["feed","feed"]
            invalid.values[kind.keys[0]]=String(decoding:try JSONSerialization.data(withJSONObject:["version":1,"revision":2,"entries":[["date":"2026-01-01","value":badValue]],"undo":NSNull()]),as:UTF8.self)
            XCTAssertThrowsError(try store.validate(invalid))
        }
        let plant=try makeStore(.plantCare)
        for interval in [0,31,true,2.5] as [Any] { XCTAssertThrowsError(try plant.settingConfiguration(["title":"Fern","intervalDays":interval],in:plant.read())) }
    }

    func testEveryConfigurationKindValidatesAndPreservesHistoryKeys() throws {
        for kind in ScriptWidgetRecordKind.allCases {
            let store = try makeStore(kind)
            let snapshot = try store.settingConfiguration(kind.defaults, in: .init(values: [:]))
            try store.validate(snapshot)
            try store.apply(snapshot, expected: store.read())
            let parsed = try store.configuration(in: store.read())
            XCTAssertEqual(Set(parsed.keys), Set(kind.defaults.keys))
            XCTAssertThrowsError(try store.settingConfiguration(["unknown": "value"], in: snapshot))
        }
        let water = try makeStore()
        XCTAssertThrowsError(try water.settingConfiguration(["goal": true, "glassML": 250], in: .init(values: [:])))
        XCTAssertThrowsError(try water.settingConfiguration(["goal": 8, "glassML": 2001], in: .init(values: [:])))
        let checklist = try makeStore(.checklist)
        XCTAssertThrowsError(try checklist.settingConfiguration(["items": ["Keys", "Keys"]], in: .init(values: [:])))
        XCTAssertThrowsError(try checklist.settingConfiguration(["items": ["  "]], in: .init(values: [:])))
    }

    func testHeatmapKeepsStableIDsAndDisplaysConfiguredNames() throws {
        let store = try makeStore(.habitHeatmap)
        var next = try store.settingConfiguration(["readName": "阅读", "runName": "Move", "meditateName": "Pause"], in: store.read())
        next.values["habitHeatmap.v1.read"] = #"["2026-01-01","2026-01-01","2026-01-02"]"#
        try store.apply(next, expected: store.read())
        let rows = try store.rows(in: store.read())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.label), ["阅读", "阅读"])
        XCTAssertEqual(try store.previewRestore(store.backup(store.read())).snapshot, next)
    }

    func testScopeRechecksPermissionIdentityAndDescriptorBeforeAnyWrite() throws {
        let store = try makeStore()
        let before = try store.read()
        var manifest = try XCTUnwrap(store.package.readManifest())
        manifest.permissions = []
        try JSONEncoder().encode(manifest).write(to: store.package.manifestPath)
        XCTAssertThrowsError(try store.apply(.init(values: [:]), expected: before))
        manifest.permissions = [.storage]; manifest.id = "local.replaced"
        try JSONEncoder().encode(manifest).write(to: store.package.manifestPath)
        XCTAssertThrowsError(try store.read())
        let other = try makeStore()
        try FileManager.default.removeItem(at: other.package.path.appendingPathComponent("record-template.json"))
        let outside = other.package.path.deletingLastPathComponent().appendingPathComponent("descriptor.json")
        try Data(#"{"formatVersion":1,"kind":"hydration"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: other.package.path.appendingPathComponent("record-template.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try other.read())
    }

    func testDottedNamespaceOverlapsAndUnavailableContainersFailClosed() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try ScriptWidgetRecordStore(package: store.package, container: store.container, defaults: store.defaults,
                                                         peers: { [store.package.name + ".child"] })) { XCTAssertEqual($0 as? ScriptWidgetRecordError, .ambiguousNamespace) }
        try FileManager.default.removeItem(at: store.container)
        XCTAssertThrowsError(try store.read()) { XCTAssertEqual($0 as? ScriptWidgetRecordError, .unavailable) }
        XCTAssertThrowsError(try store.apply(.init(values: [:]), expected: .init(values: [:])))
    }

    func testBackupFileReaderRejectsLinksSpecialFilesAndOversizedInputs() throws {
        let store = try makeStore()
        let file = store.container.appendingPathComponent("backup.json")
        let data = try store.backup(.init(values: [:]))
        try data.write(to: file)
        XCTAssertEqual(try ScriptWidgetRecordStore.readBackup(at: file), data)
        let link = store.container.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ScriptWidgetRecordStore.readBackup(at: link))
        let pipe = store.container.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try ScriptWidgetRecordStore.readBackup(at: pipe))
        let hard = store.container.appendingPathComponent("hard.json")
        try FileManager.default.linkItem(at: file, to: hard)
        XCTAssertThrowsError(try ScriptWidgetRecordStore.readBackup(at: hard))
        try FileManager.default.removeItem(at: hard)
        try Data(repeating: 32, count: ScriptWidgetRecordStore.maximumBackupBytes + 1).write(to: file)
        XCTAssertThrowsError(try ScriptWidgetRecordStore.readBackup(at: file))
        XCTAssertThrowsError(try ScriptWidgetRecordStore.readBackup(at: store.container))
    }
}

extension ScriptWidgetRecordStoreTests {
    @MainActor
    func testRecordsModelSavesDefaultsPreviewsAndRejectsStaleRestore() async throws {
        let store = try makeStore()
        let model = ScriptWidgetRecordsModel(package: store.package, store: store)
        model.goal = 12; model.glassML = 300
        model.saveConfiguration()
        XCTAssertFalse(model.isError)
        XCTAssertEqual(try store.configuration(in: store.read())["glassML"] as? Int, 300)
        let exported = try model.exportBackup()
        model.previewRestore(exported)
        XCTAssertNotNil(model.pending)
        XCTAssertTrue(model.restoreConfigurationSummary?.contains("12 glasses") == true)
        XCTAssertTrue(ScriptWidgetAtomicPreferences.compareAndSetString(container: store.container, defaults: store.defaults,
                                                                      namespace: "script.\(store.package.name).", key: "hydration.v1", expected: "", value: sample))
        model.restore()
        XCTAssertTrue(model.isError)
        XCTAssertNil(model.pending)
        XCTAssertEqual(try store.read().values["hydration.v1"], sample)
        model.reload()
        XCTAssertFalse(model.isError)
        XCTAssertEqual(model.rows.count, 1)
        model.previewRestore(exported)
        model.restore()
        XCTAssertFalse(model.isError)
        XCTAssertEqual(model.rows.count, 0)
    }

    func testConfigurationCanRepairItsOwnWrongTypeWithoutDiscardingRecords() throws {
        let store = try makeStore()
        try store.defaults.writeValue(sample, forKey: key(store, "hydration.v1"))
        try store.defaults.writeValue(["old": "wrong type"], forKey: key(store, ScriptWidgetRecordStore.configurationKey))
        let old = try store.read()
        XCTAssertEqual(old.unsupported.count, 1)
        let fixed = try store.settingConfiguration(store.kind.defaults, in: old)
        try store.apply(fixed, expected: old)
        XCTAssertEqual(try store.read().values["hydration.v1"], sample)
        XCTAssertTrue(try store.read().unsupported.isEmpty)
    }
}

#if os(iOS)
extension ScriptWidgetRecordStoreTests {
    @MainActor
    func testExportWallpaperWizardSnapshotsWhenRequested() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_WALLPAPER_WIZARD"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_WALLPAPER_WIZARD for native crop/configuration captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first),previous=scene.windows.first{$0.isKeyWindow}
        let window=UIWindow(windowScene:scene);window.frame=scene.screen.bounds;defer{window.isHidden=true;previous?.makeKey()}
        let image=try photoFixture(width:600,height:1300)
        for dark in [false,true] {
            let controller=UIHostingController(rootView:ScriptWidgetWallpaperCropView(image:image,initialAppearance:dark ? "dark":"light",save:{_,_,_,_ in false}).environment(\.colorScheme,dark ? .dark:.light))
            window.rootViewController=controller;window.makeKeyAndVisible();controller.view.layoutIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let result=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in XCTAssertTrue(window.drawHierarchy(in:window.bounds,afterScreenUpdates:true))}
            try XCTUnwrap(result.pngData()).write(to:output.appendingPathComponent(dark ? "wizard-dark.png":"wizard-light.png"))
        }
        // Same phone width, taller offscreen canvas to inspect the scrollable preview/save controls.
        window.frame=CGRect(x:0,y:0,width:scene.screen.bounds.width,height:1500)
        let expanded=UIHostingController(rootView:ScriptWidgetWallpaperCropView(image:image,save:{_,_,_,_ in false}))
        window.rootViewController=expanded;window.makeKeyAndVisible();expanded.view.layoutIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
        let expandedImage=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in XCTAssertTrue(window.drawHierarchy(in:window.bounds,afterScreenUpdates:true))}
        try XCTUnwrap(expandedImage.pngData()).write(to:output.appendingPathComponent("wizard-expanded-canvas.png"))
        window.frame=scene.screen.bounds
        let store=try makeStore(.wallpaper,name:"Wallpaper Match Demo"),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        XCTAssertTrue(model.addWallpaperCrop(try ScriptWidgetWallpaperCrop.initial(family:"medium",imageWidth:image.width,imageHeight:image.height).cropped(image),family:"medium",appearance:"light",label:"Top left"))
        model.saveConfiguration();XCTAssertFalse(model.isError)
        let controller=UIHostingController(rootView:ScriptWidgetRecordsView(model:model));window.rootViewController=controller;window.makeKeyAndVisible();controller.view.layoutIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
        let result=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in XCTAssertTrue(window.drawHierarchy(in:window.bounds,afterScreenUpdates:true))}
        try XCTUnwrap(result.pngData()).write(to:output.appendingPathComponent("configuration.png"))
    }

    @MainActor
    func testExportRecordManagerScreenshots() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_RECORD_MANAGER"], !outputPath.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_RECORD_MANAGER to export native record manager screens")
        }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true; previous?.makeKey() }
        for kind in ScriptWidgetRecordKind.allCases {
            let store = try makeStore(kind, name: kind.title + " Demo")
            var snapshot = ScriptWidgetRecordSnapshot(values: [:])
            if kind == .photoCard || kind == .weather || kind == .healthCard || kind == .repoStats || kind == .launcher || kind == .wallpaper {
                snapshot = try store.settingConfiguration(kind.defaults, in: snapshot)
            } else if kind == .countdown {
                snapshot = try store.settingConfiguration(["title": "Summer trip", "targetDate": "2027-07-12", "repeatYearly": false, "accent": "blue"], in: snapshot)
            } else if kind == .habitHeatmap {
                snapshot.values["habitHeatmap.v1.read"] = #"["2026-01-01","2026-01-02"]"#
            } else {
                let value: Any = kind == .pocketPet ? ["feed"] : kind == .checklist ? ["Passport"] : kind == .mood ? 4 : [.habitStreak,.plantCare].contains(kind) ? 1 : 250
                let bytes = try JSONSerialization.data(withJSONObject: ["version":1,"revision":1,"entries":[["date":"2026-01-01","value":value]],"undo":NSNull()])
                snapshot.values[kind.keys[0]] = String(decoding: bytes, as: UTF8.self)
            }
            try store.apply(snapshot, expected: store.read())
            try store.backup(snapshot, now: Date(timeIntervalSince1970: 1767355200)).write(to: output.appendingPathComponent(kind.rawValue + "-backup.json"), options: .atomic)
            let model = ScriptWidgetRecordsModel(package: store.package, store: store)
            for preview in [false, true] {
                if preview { model.previewRestore(try store.backup(snapshot, now: Date(timeIntervalSince1970: 1767355200))) }
                let controller = UIHostingController(rootView: ScriptWidgetRecordsView(model: model))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let data = try XCTUnwrap(image.pngData())
                let name = kind.rawValue + (preview ? "-restore" : "-configuration") + ".png"
                try data.write(to: output.appendingPathComponent(name), options: .atomic)
            }
        }
    }
}
#endif

extension ScriptWidgetRecordStoreTests {
    func testLocalRecordsRemainRecoverableWhenEntryAndMetadataAreEvictedButCacheIsValid() throws {
        let store = try makeStore()
        let manifest = try XCTUnwrap(store.package.readManifest())
        XCTAssertTrue(store.package.writeManifest(manifest).0)
        XCTAssertTrue(store.package.writeFile(relativePath: "record-template.json", content: #"{"formatVersion":1,"kind":"hydration"}"#).0)
        defer {
            if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: store.package.name) }
        }
        try store.defaults.writeValue(sample, forKey: key(store, "hydration.v1"))
        for relative in ["main.jsx", "widget.json", "record-template.json"] {
            try FileManager.default.removeItem(at: store.package.path.appendingPathComponent(relative))
        }
        XCTAssertEqual(try store.rows(in: store.read()).first?.value, "250 mL")
        _ = try store.previewRestore(store.backup(store.read()))
        // A present malformed descriptor remains authoritative over old cache.
        try Data(repeating: 32, count: 4097).write(to: store.package.path.appendingPathComponent("record-template.json"))
        XCTAssertThrowsError(try store.read())
    }
}

#if os(macOS)
extension ScriptWidgetRecordStoreTests {
    @MainActor
    func testExportActionDirectoryScreenshot() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LAUNCHER"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_LAUNCHER for the action directory") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let packages=["Hydration Goal","Control Switch"].map{ScriptWidgetPackage(bundle:"Script",relativePath:"template/"+$0)}
        let catalog=ScriptWidgetActionCatalog(packages:packages)
        XCTAssertEqual(catalog.actions().count,6)
        let host=NSHostingController(rootView:NavigationStack{ScriptWidgetActionDirectoryView(catalog:{catalog})}.frame(width:640,height:840).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:840),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=host;window.orderBack(nil);host.view.layoutSubtreeIfNeeded();defer{window.close()}
        try await Task.sleep(nanoseconds:200_000_000)
        let bitmap=try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds));host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("action-directory.png"))
    }

    @MainActor
    func testExportLauncherConfigurationScreenshot() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LAUNCHER"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_LAUNCHER for launcher configuration") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=try makeStore(.launcher,name:"My launcher"),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        let item=ScriptWidgetLauncherItem(id:"shortcut",title:"Morning",icon:"play.fill",type:"shortcut",target:"Morning Plan",input:"Hello")
        model.launcherItems=[item];model.habitTitle="My links";model.saveConfiguration();model.finishLauncherTest(item:item,accepted:false)
        let host=NSHostingController(rootView:ScriptWidgetRecordsView(model:model).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:940),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=host;window.orderBack(nil);host.view.layoutSubtreeIfNeeded();defer{window.close()}
        try await Task.sleep(nanoseconds:200_000_000)
        let bitmap=try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds));host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("launcher-configuration.png"))
    }

    @MainActor
    func testExportRepositoryConfigurationScreenshot() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_REPOSITORY"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_REPOSITORY for repository configuration") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=try makeStore(.repoStats,name:"My repository"),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        model.repository="everettjf/ScriptWidget";model.saveConfiguration()
        let host=NSHostingController(rootView:ScriptWidgetRecordsView(model:model).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:680),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=host;window.orderBack(nil);host.view.layoutSubtreeIfNeeded();defer{window.close()}
        try await Task.sleep(nanoseconds:200_000_000)
        let bitmap=try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds));host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("repository-configuration.png"))
    }

    @MainActor
    func testExportHealthConfigurationScreenshot() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_HEALTH"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_HEALTH for native health configuration") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=try makeStore(.healthCard,name:"My daily health"),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        model.healthMetric="energy";model.energyGoal=650;model.saveConfiguration()
        let host=NSHostingController(rootView:ScriptWidgetRecordsView(model:model).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=host;window.orderBack(nil);host.view.layoutSubtreeIfNeeded();defer{window.close()}
        try await Task.sleep(nanoseconds:200_000_000)
        let bitmap=try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds));host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("health-configuration.png"))
    }

    @MainActor
    func testExportWeatherConfigurationScreenshot() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_WEATHER"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_WEATHER for native weather configuration") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=try makeStore(.weather,name:"London weather"),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        model.chooseCity(.init(name:"London",latitude:51.5,longitude:-0.12));model.saveConfiguration()
        let host=NSHostingController(rootView:ScriptWidgetRecordsView(model:model).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:880),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=host;window.orderBack(nil);host.view.layoutSubtreeIfNeeded();defer{window.close()}
        try await Task.sleep(nanoseconds:200_000_000)
        let bitmap=try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds));host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("weather-configuration.png"))
    }

    @MainActor
    func testExportPhotoConfigurationScreenshot() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_PHOTOS"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_PHOTOS for native photo configuration") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=try makeStore(.photoCard,name:"My moments"),model=ScriptWidgetRecordsModel(package:store.package,store:store)
        let photo=try ScriptWidgetPhotoPreparation.crop(photoFixture(),zoom:1,horizontal:0.5,vertical:0.5)
        XCTAssertTrue(model.addPhoto(photo));XCTAssertTrue(model.addPhoto(photo))
        model.habitTitle="My moments";model.photoCaption="A little collection";model.photoLayout="duo";model.saveConfiguration()
        let host=NSHostingController(rootView:ScriptWidgetRecordsView(model:model).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:880),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=host;window.orderBack(nil);host.view.layoutSubtreeIfNeeded()
        defer{window.close()}
        try await Task.sleep(nanoseconds:350_000_000)
        let bitmap=try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds));host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("photo-configuration.png"))
    }

    @MainActor
    func testExportCountdownConfigurationScreenshot() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_COUNTDOWN"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_COUNTDOWN for native countdown configuration") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = try makeStore(.countdown, name: "Summer trip")
        let snapshot = try store.settingConfiguration(["title":"Summer trip","targetDate":"2027-07-12","repeatYearly":false,"accent":"blue"], in: store.read())
        try store.apply(snapshot, expected: store.read())
        let model = ScriptWidgetRecordsModel(package: store.package, store: store)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:740), styleMask:[.titled], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingController(rootView: ScriptWidgetRecordsView(model:model))
        window.contentViewController = host; window.orderBack(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds:150_000_000)
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds))
        host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("countdown-configuration.png"))
    }

    @MainActor
    func testExportMacRecordManagerScreenshots() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_RECORD_MANAGER"], !outputPath.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_RECORD_MANAGER to export native record manager screens")
        }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = try makeStore(.hydration, name: "Water Demo")
        let snapshot = ScriptWidgetRecordSnapshot(values: ["hydration.v1": sample])
        try store.apply(snapshot, expected: store.read())
        let model = ScriptWidgetRecordsModel(package: store.package, store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for preview in [false, true] {
            if preview { model.previewRestore(try store.backup(snapshot, now: Date(timeIntervalSince1970: 1767355200))) }
            let host = NSHostingController(rootView: ScriptWidgetRecordsView(model: model))
            window.contentViewController = host
            window.setContentSize(NSSize(width: 640, height: 800))
            window.orderBack(nil)
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try bytes.write(to: output.appendingPathComponent(preview ? "mac-hydration-restore.png" : "mac-hydration-configuration.png"), options: .atomic)
        }
    }
}
#endif

final class StorageNamespaceMigrationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUpWithError() throws {
        suite = "app.scriptwidget.namespace-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NamespaceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func bootstrap(_ names: [String]) throws -> ScriptWidgetStorageNamespaceIndex {
        try ScriptWidgetStorageNamespaces.bootstrap(existingNames: names, inventoryIsComplete: true, container: root, defaults: defaults)
    }
    private func namespace(_ name: String) throws -> String { try ScriptWidgetStorageNamespaces.namespace(for: name, container: root, defaults: defaults) }
    private func field(_ key: String) throws -> ScriptWidgetLegacyStoragePreview { try ScriptWidgetStorageNamespaces.preview(field: key, container: root, defaults: defaults) }

    func testUnambiguousMigrationPreservesTypesOriginalsAndNativeOnlyMetadata() throws {
        defaults.set("12", forKey: "script.Foo.count")
        defaults.set(Data(#"{"n":1}"#.utf8), forKey: "script.Foo.json")
        defaults.set(true, forKey: "script.Foo.flag")
        defaults.set("orphan", forKey: "script.Deleted.secret")
        let index = try bootstrap(["Foo"])
        let prefix = try namespace("Foo")
        XCTAssertEqual(defaults.string(forKey: prefix + "count"), "12")
        XCTAssertEqual(defaults.data(forKey: prefix + "json"), Data(#"{"n":1}"#.utf8))
        XCTAssertTrue(defaults.bool(forKey: prefix + "flag"))
        XCTAssertEqual(defaults.string(forKey: "script.Foo.count"), "12")
        XCTAssertEqual(defaults.string(forKey: "script.Deleted.secret"), "orphan")
        XCTAssertFalse(prefix.hasPrefix("script."))
        XCTAssertFalse(ScriptWidgetStorageNamespaces.registryKey.hasPrefix(prefix))
        XCTAssertEqual(try bootstrap(["New"]), index, "Inventory is sealed once prepared")
        XCTAssertThrowsError(try namespace("New"))
    }

    func testDottedNamesNeverShareNewPrefixesOrAllowParentClearToTouchChild() throws {
        _ = try bootstrap(["Foo", "Foo.Bar"])
        let parent = try namespace("Foo"), child = try namespace("Foo.Bar")
        XCTAssertNotEqual(parent, child)
        XCTAssertFalse(child.hasPrefix(parent))
        defaults.set("parent", forKey: parent + "Bar.value")
        defaults.set("child", forKey: child + "value")
        XCTAssertTrue(ScriptWidgetAtomicPreferences.mutate(container: root, defaults: defaults, namespace: parent) { store in
            for (key, _) in try store.values(in: parent) { try store.removeValue(forKey: key) }
            return true
        })
        XCTAssertNil(defaults.object(forKey: parent + "Bar.value"))
        XCTAssertEqual(defaults.string(forKey: child + "value"), "child")
        _ = try namespace("Foo.Bar") // A user clear cannot erase the identity index.
    }

    func testAmbiguousLegacyKeysRequireExplicitIndependentCopySelection() throws {
        defaults.set("shared", forKey: "script.Foo.Bar.value")
        defaults.set("parent only", forKey: "script.Foo.count")
        let index = try bootstrap(["Foo", "Foo.Bar"])
        XCTAssertThrowsError(try namespace("Foo")) { XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .reviewRequired) }
        XCTAssertThrowsError(try namespace("Foo.Bar"))
        let preview = try field("script.Foo.Bar.value")
        XCTAssertEqual(preview.field.candidates.count, 2)
        try ScriptWidgetStorageNamespaces.resolve(preview, to: Set(index.owners.map(\.id)), container: root, defaults: defaults)
        let parent = try namespace("Foo"), child = try namespace("Foo.Bar")
        XCTAssertEqual(defaults.string(forKey: parent + "Bar.value"), "shared")
        XCTAssertEqual(defaults.string(forKey: child + "value"), "shared")
        defaults.set("new parent", forKey: parent + "Bar.value")
        XCTAssertEqual(defaults.string(forKey: child + "value"), "shared")
        XCTAssertEqual(defaults.string(forKey: "script.Foo.Bar.value"), "shared")
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.pending(container: root, defaults: defaults).isEmpty)
    }

    func testResolutionSourceAndTargetConflictsHaveNoPartialEffects() throws {
        defaults.set("old", forKey: "script.Foo.Bar.value")
        let index = try bootstrap(["Foo", "Foo.Bar"])
        let stale = try field("script.Foo.Bar.value")
        defaults.set("new", forKey: "script.Foo.Bar.value")
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.resolve(stale, to: Set(index.owners.map(\.id)), container: root, defaults: defaults))
        let preview = try field("script.Foo.Bar.value")
        let parent = try XCTUnwrap(index.owners.first { $0.name == "Foo" })
        let child = try XCTUnwrap(index.owners.first { $0.name == "Foo.Bar" })
        defaults.set("intervening", forKey: child.namespace + "value")
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.resolve(preview, to: [parent.id, child.id], container: root, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: parent.namespace + "Bar.value"))
        XCTAssertEqual(defaults.string(forKey: child.namespace + "value"), "intervening")
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.resolve(try field("script.Foo.Bar.value"), to: [UUID().uuidString.lowercased()], container: root, defaults: defaults))
        XCTAssertEqual(try ScriptWidgetStorageNamespaces.pending(container: root, defaults: defaults).count, 1)
    }

    func testArchiveChoiceDoesNotGuessAnOwnerOrDeleteLegacyData() throws {
        defaults.set("preserved", forKey: "script.Foo.Bar.value")
        _ = try bootstrap(["Foo", "Foo.Bar"])
        try ScriptWidgetStorageNamespaces.resolve(try field("script.Foo.Bar.value"), to: [], container: root, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: try namespace("Foo") + "Bar.value"))
        XCTAssertNil(defaults.object(forKey: try namespace("Foo.Bar") + "value"))
        XCTAssertEqual(defaults.string(forKey: "script.Foo.Bar.value"), "preserved")
    }

    func testPreparedJournalResumesSameIDsAndNeverPublishesStalePartialCopies() throws {
        defaults.set("1", forKey: "script.Foo.count")
        defaults.set(Data("small".utf8), forKey: "script.Foo.data")
        var journal = try bootstrap(["Foo"])
        let id = try XCTUnwrap(journal.owners.first?.id)
        let prefix = try namespace("Foo")
        journal.phase = "prepared"
        for position in journal.legacy.indices { journal.legacy[position].resolved = false }
        defaults.set(try JSONEncoder().encode(journal), forKey: ScriptWidgetStorageNamespaces.registryKey)
        defaults.set("2", forKey: "script.Foo.count")
        let large = Data(repeating: 1, count: ScriptWidgetAtomicPreferences.maximumValueBytes + 1)
        defaults.set(large, forKey: "script.Foo.data")
        let resumed = try bootstrap(["Do not grant new eligibility"])
        XCTAssertEqual(resumed.owners.first?.id, id)
        XCTAssertEqual(defaults.string(forKey: prefix + "count"), "2")
        XCTAssertNil(defaults.object(forKey: prefix + "data"), "A stale staged copy must not leak through an archive choice")
        XCTAssertThrowsError(try namespace("Foo"))
        let preview = try field("script.Foo.data")
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.resolve(preview, to: [id], container: root, defaults: defaults))
        try ScriptWidgetStorageNamespaces.resolve(preview, to: [], container: root, defaults: defaults)
        XCTAssertEqual(try namespace("Foo"), prefix)
        XCTAssertEqual(defaults.data(forKey: "script.Foo.data"), large)
        XCTAssertNil(defaults.object(forKey: prefix + "data"))
    }

    func testFreshImportCannotClaimOrphanedLegacyDataOrAReusedNamesRecords() throws {
        defaults.set("old orphan", forKey: "script.Foo.secret")
        _ = try bootstrap([])
        let first = try ScriptWidgetStorageNamespaces.registerFresh(name: "Foo", container: root, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: first.namespace + "secret"))
        defaults.set("first owner", forKey: first.namespace + "secret")
        try ScriptWidgetStorageNamespaces.retire(name: "Foo", container: root, defaults: defaults)
        let second = try ScriptWidgetStorageNamespaces.registerFresh(name: "Foo", container: root, defaults: defaults)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(defaults.object(forKey: second.namespace + "secret"))
        XCTAssertEqual(defaults.string(forKey: first.namespace + "secret"), "first owner")
        XCTAssertEqual(defaults.string(forKey: "script.Foo.secret"), "old orphan")
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.registerFresh(name: "Foo", container: root, defaults: defaults))
    }

    func testRenameKeepsIdentityWhileLaterNameReuseGetsFreshStorage() throws {
        defaults.set("history", forKey: "script.Foo.value")
        _ = try bootstrap(["Foo"])
        let before = try namespace("Foo")
        try ScriptWidgetStorageNamespaces.rename(from: "Foo", to: "Foo.Renamed", container: root, defaults: defaults)
        XCTAssertEqual(try namespace("Foo.Renamed"), before)
        XCTAssertThrowsError(try namespace("Foo"))
        _ = try ScriptWidgetStorageNamespaces.registerFresh(name: "Foo", container: root, defaults: defaults)
        XCTAssertNotEqual(try namespace("Foo"), before)
        XCTAssertEqual(defaults.string(forKey: before + "value"), "history")
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.rename(from: "Foo.Renamed", to: "Foo", container: root, defaults: defaults))
    }

    func testCanonicalNamesAndInvalidNamesMatchPackageFilenameRules() throws {
        _ = try bootstrap(["Cafe\u{301}", "👩‍💻 Focus"])
        XCTAssertEqual(try namespace("Café"), try namespace("Cafe\u{301}"))
        for name in ["", " ", "../outside", "/outside", ".hidden", "C:relative", "__Build", "bad\0name", String(repeating: "a", count: 81), String(repeating: "😀", count: 61)] {
            XCTAssertFalse(ScriptWidgetPackageName.isValid(name))
            XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.canonicalName(name))
        }
        for name in ["阅读记录", "👩‍💻 Focus", "e\u{301}", "Foo.Bar"] {
            XCTAssertTrue(ScriptWidgetPackageName.isValid(name))
            XCTAssertEqual(try ScriptWidgetStorageNamespaces.canonicalName(name), name.precomposedStringWithCanonicalMapping)
        }
    }

    func testMalformedPresentRegistryFailsClosedWithoutRebuildingOrTouchingLegacy() throws {
        defaults.set("preserve", forKey: "script.Foo.value")
        for value: Any in ["wrong type", Data("broken".utf8), Data(#"{"formatVersion":true,"phase":"ready","owners":[],"legacy":[]}"#.utf8), Data(#"{"formatVersion":1,"phase":"ready","owners":[],"legacy":[],"extra":true}"#.utf8)] {
            defaults.set(value, forKey: ScriptWidgetStorageNamespaces.registryKey)
            XCTAssertThrowsError(try bootstrap(["Foo"]))
            XCTAssertEqual(defaults.string(forKey: "script.Foo.value"), "preserve")
        }
    }

    func testForgedCandidateBindingAndDuplicateIdentitiesAreRejected() throws {
        defaults.set("old", forKey: "script.Foo.value")
        let index = try bootstrap(["Foo", "Bar"])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as! [String: Any]
        var fields = object["legacy"] as! [[String: Any]]
        fields[0]["candidates"] = [["ownerID":index.owners.first { $0.name == "Bar" }!.id,"key":"value"]]
        object["legacy"] = fields
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertThrowsError(try namespace("Foo"))
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as! [String: Any]
        var owners = object["owners"] as! [[String: Any]]
        owners[1]["id"] = owners[0]["id"]
        object["owners"] = owners
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertThrowsError(try namespace("Foo"))
    }

    func testNamespaceBudgetsPermitCleanupButNeverUnboundedGrowth() throws {
        _ = try bootstrap(["Foo"])
        let prefix = try namespace("Foo")
        defaults.set(Data(repeating: 0, count: ScriptWidgetStorageNamespaces.maximumNamespaceBytes), forKey: prefix + "large")
        XCTAssertFalse(try ScriptWidgetStorageNamespaces.fitsBudget(namespace: prefix, defaults: defaults, replacing: ["extra":"x"]))
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.fitsBudget(namespace: prefix, defaults: defaults, replacing: ["large":"smaller"]))
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.fitsBudget(namespace: prefix, defaults: defaults, replacing: [:], removing: ["large"]))
        defaults.set(Data(repeating: 0, count: ScriptWidgetStorageNamespaces.maximumNamespaceBytes + 1), forKey: prefix + "large")
        defaults.set("xx", forKey: prefix + "small")
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.fitsBudget(namespace: prefix, defaults: defaults, replacing: ["small":"x"]))
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.fitsBudget(namespace: prefix, defaults: defaults, replacing: ["small":"xx"]))
        XCTAssertFalse(try ScriptWidgetStorageNamespaces.fitsBudget(namespace: prefix, defaults: defaults, replacing: ["small":"xxx"]))
    }

    func testOwnerLimitRejectsRegistrationWithoutRetiringAnExistingOwner() throws {
        let owners = (0..<ScriptWidgetStorageNamespaces.maximumOwners).map {
            ScriptWidgetStorageOwner(name: "Owner\($0)", id: UUID().uuidString.lowercased(), active: true, legacyName: "")
        }
        let data = try JSONEncoder().encode(ScriptWidgetStorageNamespaceIndex(phase: "ready", owners: owners, legacy: []))
        defaults.set(data, forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.registerFresh(name: "Owner0", replacing: true, container: root, defaults: defaults)) {
            XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .limitExceeded)
        }
        XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey), data)
        XCTAssertEqual(try namespace("Owner0"), owners[0].namespace)
    }
}

extension StorageNamespaceMigrationTests {
    func testIncompleteInventoryNeverAutomaticallyAssignsACompoundLegacyKey() throws {
        defaults.set("plain", forKey: "script.Foo.count")
        defaults.set("uncertain", forKey: "script.Foo.Bar.value")
        let index = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: ["Foo"], inventoryIsComplete: false, container: root, defaults: defaults)
        let owner = try XCTUnwrap(index.owners.first)
        XCTAssertEqual(defaults.string(forKey: owner.namespace + "count"), "plain")
        XCTAssertNil(defaults.object(forKey: owner.namespace + "Bar.value"))
        XCTAssertThrowsError(try namespace("Foo")) { XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .reviewRequired) }
        XCTAssertEqual(try ScriptWidgetStorageNamespaces.pending(container: root, defaults: defaults).map(\.key), ["script.Foo.Bar.value"])
        // A later complete listing must not silently change the sealed grant.
        _ = try bootstrap(["Foo", "Foo.Bar"])
        XCTAssertNil(defaults.object(forKey: owner.namespace + "Bar.value"))
    }
}


extension StorageNamespaceMigrationTests {
    private var publicationLocation: String { String(repeating: "a", count: 64) }
    private var publicationReceipt: ScriptWidgetStoragePublicationReceipt { .init(device: 7, inode: 42) }
    private enum PublicationProbeError: Error { case interrupted }

    private func install(inspect: (ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState,
                         publish: (ScriptWidgetStorageOwner) throws -> Void) throws -> ScriptWidgetStorageOwner {
        try ScriptWidgetStorageNamespaces.publishFresh(name: "Foo", location: publicationLocation, receipt: publicationReceipt,
            container: root, defaults: defaults, inspect: inspect, publish: publish)
    }
    private func recover(_ state: ScriptWidgetStoragePublicationState) throws -> ScriptWidgetStorageInstallationRecovery {
        try ScriptWidgetStorageNamespaces.recoverInstallation(location: publicationLocation, container: root, defaults: defaults) { name, receipt in
            XCTAssertEqual(name, "Foo"); XCTAssertEqual(receipt, publicationReceipt)
            return state
        }
    }
    private func interruptedPublication() throws -> ScriptWidgetStorageOwner {
        var reserved: ScriptWidgetStorageOwner?
        var inspectingAfterPublication = false
        XCTAssertThrowsError(try install(inspect: { _ in
            if inspectingAfterPublication { throw PublicationProbeError.interrupted }
            return .absent
        }, publish: { owner in
            reserved = owner
            inspectingAfterPublication = true
        }))
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
        return try XCTUnwrap(reserved)
    }

    func testNativePublicationCommitsFreshIdentityAndPreservesPreviousRecords() throws {
        _ = try bootstrap(["Foo", "Other"])
        let old = try namespace("Foo"), other = try namespace("Other")
        defaults.set("private history", forKey: old + "record")
        var published = false
        let owner = try install(inspect: { _ in published ? .matching : .absent }, publish: { owner in
            XCTAssertFalse(owner.active)
            XCTAssertNotEqual(owner.namespace, old)
            XCTAssertEqual(defaults.string(forKey: old + "record"), "private history")
            published = true
        })
        XCTAssertTrue(owner.active)
        XCTAssertEqual(try namespace("Foo"), owner.namespace)
        XCTAssertNotEqual(owner.namespace, old)
        XCTAssertNil(defaults.object(forKey: owner.namespace + "record"))
        XCTAssertEqual(defaults.string(forKey: old + "record"), "private history")
        XCTAssertEqual(try namespace("Other"), other)
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
        XCTAssertEqual(try recover(.matching), .none)
    }

    func testPublicationRefusesOccupiedDestinationBeforeSavingIntentOrCallingPublisher() throws {
        _ = try bootstrap(["Foo"])
        let before = defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)
        for state in [ScriptWidgetStoragePublicationState.matching, .different] {
            XCTAssertThrowsError(try install(inspect: { _ in state }, publish: { _ in XCTFail("Must not replace an occupied directory") })) {
                XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .conflict)
            }
            XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey), before)
            XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
        }
    }

    func testFailedPublicationRollsBackReservationWithoutDeletingPriorValues() throws {
        _ = try bootstrap(["Foo"])
        let before = try namespace("Foo")
        defaults.set("retained", forKey: before + "record")
        XCTAssertThrowsError(try install(inspect: { _ in .absent }, publish: { _ in throw PublicationProbeError.interrupted })) {
            XCTAssertTrue($0 is PublicationProbeError)
        }
        XCTAssertEqual(try namespace("Foo"), before)
        XCTAssertEqual(defaults.string(forKey: before + "record"), "retained")
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
        XCTAssertEqual(try bootstrap([]).owners.count, 1)
    }

    func testPublisherErrorAfterAtomicRenameCommitsFromReceiptWithoutRunningAgain() throws {
        _ = try bootstrap([])
        var published = false, calls = 0
        let owner = try install(inspect: { _ in published ? .matching : .absent }, publish: { _ in
            calls += 1; published = true
            throw PublicationProbeError.interrupted
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try namespace("Foo"), owner.namespace)
    }

    func testInterruptedPublicationDeniesAffectedLookupAndOtherMutationsUntilRecovery() throws {
        _ = try bootstrap(["Foo", "Other"])
        let old = try namespace("Foo"), other = try namespace("Other")
        defaults.set("retained", forKey: old + "record")
        _ = try interruptedPublication()
        XCTAssertThrowsError(try namespace("Foo")) { XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .unavailable) }
        XCTAssertEqual(try namespace("Other"), other)
        XCTAssertThrowsError(try bootstrap(["New"]))
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.registerFresh(name: "New", container: root, defaults: defaults))
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.rename(from: "Other", to: "Changed", container: root, defaults: defaults))
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.retire(name: "Other", container: root, defaults: defaults))
        XCTAssertThrowsError(try install(inspect: { _ in .absent }, publish: { _ in XCTFail("Cannot install during recovery") }))
        XCTAssertEqual(try recover(.absent), .rolledBack)
        XCTAssertEqual(try namespace("Foo"), old)
        XCTAssertEqual(defaults.string(forKey: old + "record"), "retained")
    }

    func testInterruptedPublishedDirectoryRecoversExactReservedIdentity() throws {
        _ = try bootstrap(["Foo"])
        let old = try namespace("Foo")
        let reserved = try interruptedPublication()
        guard case .committed(let owner) = try recover(.matching) else { return XCTFail("Expected commit") }
        XCTAssertEqual(owner.id, reserved.id)
        XCTAssertEqual(try namespace("Foo"), reserved.namespace)
        XCTAssertNotEqual(reserved.namespace, old)
        XCTAssertEqual(try recover(.matching), .none)
    }

    func testRecoveryCannotGuessDifferentLocationOrDifferentDirectory() throws {
        _ = try bootstrap(["Foo"])
        _ = try interruptedPublication()
        let journal = defaults.data(forKey: ScriptWidgetStorageNamespaces.installationKey)
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.recoverInstallation(location: String(repeating: "b", count: 64), container: root, defaults: defaults) { _, _ in
            XCTFail("Must not inspect an unrelated root"); return .matching
        })
        XCTAssertThrowsError(try recover(.different)) { XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .conflict) }
        XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.installationKey), journal)
        XCTAssertThrowsError(try namespace("Foo"))
        _ = try recover(.matching)
    }

    func testJournalBeforeReservationSaveCanRollbackOrCommitWithoutNewIdentity() throws {
        for published in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            _ = try bootstrap(["Foo"])
            let old = try namespace("Foo")
            let before = defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)
            let reserved = try interruptedPublication()
            // Recreate the crash window after durable intent but before index save.
            defaults.set(before, forKey: ScriptWidgetStorageNamespaces.registryKey)
            if published {
                guard case .committed(let owner) = try recover(.matching) else { return XCTFail("Expected commit") }
                XCTAssertEqual(owner.id, reserved.id)
                XCTAssertEqual(try namespace("Foo"), reserved.namespace)
            } else {
                XCTAssertEqual(try recover(.absent), .rolledBack)
                XCTAssertEqual(try namespace("Foo"), old)
            }
        }
    }

    func testCommittedIdentityNeverRollsBackIfDirectoryDisappearsBeforeJournalCleanup() throws {
        _ = try bootstrap(["Foo"])
        let old = try namespace("Foo")
        let reserved = try interruptedPublication()
        var index = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)))
        let position = try XCTUnwrap(index.owners.firstIndex(where: { $0.id == reserved.id }))
        index.owners[position].active = true
        defaults.set(try JSONEncoder().encode(index), forKey: ScriptWidgetStorageNamespaces.registryKey)
        guard case .committed(let owner) = try recover(.absent) else { return XCTFail("Expected committed identity") }
        XCTAssertEqual(owner.id, reserved.id)
        XCTAssertEqual(try namespace("Foo"), reserved.namespace)
        XCTAssertNotEqual(try namespace("Foo"), old)
    }

    func testMalformedJournalFailsClosedAndCannotResetIndexOrRunPublisher() throws {
        _ = try bootstrap(["Foo"])
        _ = try interruptedPublication()
        let valid = try XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.installationKey))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let registry = defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)
        var cases: [Any] = ["wrong type", Data("{broken".utf8)]
        for (key, value) in [("unknown", true as Any), ("formatVersion", true as Any), ("previousOwnerID", NSNull()), ("location", "../escape")] {
            var object = original; object[key] = value
            cases.append(try JSONSerialization.data(withJSONObject: object))
        }
        var booleanReceipt = original
        booleanReceipt["receipt"] = ["device": true, "inode": 42] as [String: Any]
        cases.append(try JSONSerialization.data(withJSONObject: booleanReceipt))
        for value in cases {
            defaults.set(value, forKey: ScriptWidgetStorageNamespaces.installationKey)
            XCTAssertThrowsError(try namespace("Foo"))
            XCTAssertThrowsError(try recover(.matching))
            XCTAssertThrowsError(try install(inspect: { _ in .absent }, publish: { _ in XCTFail("Invalid journal must stop publication") }))
            XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey), registry)
        }
        defaults.set(valid, forKey: ScriptWidgetStorageNamespaces.installationKey)
        _ = try recover(.absent)
    }
}


extension TemplateInstallationTests {
    func testRemixPublishesWholePackageWithFreshManifestAndNoGeneratedCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemixInstall-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root)
        let source = manager.getScriptPackage(packageName: "Original-" + UUID().uuidString)
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeFile(relativePath: "src/main.jsx", content: "$render(<text>Remix</text>);").0)
        XCTAssertTrue(source.writeFile(relativePath: "lib/value.js", content: "module.exports = 42;").0)
        let binary = Data([0, 1, 2, 128, 255])
        XCTAssertTrue(ScriptWidgetPackageFiles.write(binary, root: source.path, relative: "assets/nested/data.bin"))
        var manifest = WidgetPackageManifest.newProject(name: source.name)
        manifest.entry = "src/main.jsx"; manifest.permissions = [.storage, .calendar]; manifest.minimumRuntimeVersion = "1.3"
        manifest.description = "Keep attribution and settings"
        XCTAssertTrue(source.writeManifest(manifest).0)
        let original = try Data(contentsOf: source.manifestPath)
        let generated = source.path.appendingPathComponent("__Build")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("stale compiler artifact".utf8).write(to: generated.appendingPathComponent("old.js"))
        var ids = Set<String>()
        for _ in 0..<2 {
            let result = manager.duplicateScript(sourcePackageName: source.name)
            XCTAssertTrue(result.0, result.1)
            guard result.0 else { continue }
            cacheNames.append(result.1)
            let copied = manager.getScriptPackage(packageName: result.1)
            let actual = try XCTUnwrap(copied.readManifest())
            XCTAssertNotEqual(actual.id, manifest.id)
            XCTAssertTrue(ids.insert(actual.id).inserted)
            var expected = manifest; expected.id = actual.id; expected.name = result.1
            XCTAssertEqual(actual, expected)
            XCTAssertFalse(ScriptWidgetNetworkPolicy.packageAllows(try XCTUnwrap(URL(string: "https://example.com/public.json")), package: copied))
            XCTAssertEqual(copied.readMainFile().0, "$render(<text>Remix</text>);")
            XCTAssertEqual(copied.readFile(relativePath: "lib/value.js").0, "module.exports = 42;")
            XCTAssertEqual(ScriptWidgetPackageFiles.read(root: copied.path, relative: "assets/nested/data.bin"), binary)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path.appendingPathComponent("__Build").path))
        }
        XCTAssertEqual(try Data(contentsOf: source.manifestPath), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.appendingPathComponent("old.js").path))
        XCTAssertEqual(manager.scriptCount(), 3)
    }

    func testLegacyRemixPreservesManifestlessCompatibilityAndAllResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyRemix-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root)
        let source = manager.getScriptPackage(packageName: "Legacy-" + UUID().uuidString)
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeMainFile(content: "$render(<text>{$device.name()}</text>);").0)
        XCTAssertTrue(source.writeFile(relativePath: "images/nested.txt", content: "legacy resource").0)
        XCTAssertFalse(source.hasManifest)
        let result = manager.duplicateScript(sourcePackageName: source.name)
        XCTAssertTrue(result.0, result.1)
        guard result.0 else { return }
        cacheNames.append(result.1)
        let copied = manager.getScriptPackage(packageName: result.1)
        XCTAssertFalse(copied.hasManifest)
        XCTAssertEqual(copied.readMainFile().0, source.readMainFile().0)
        XCTAssertEqual(copied.readFile(relativePath: "images/nested.txt").0, "legacy resource")
        XCTAssertFalse(source.hasManifest)
    }

    func testRemixRejectsMalformedManifestOrHiddenLinkWithoutPublishingPartialPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InvalidRemix-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root)
        let source = manager.getScriptPackage(packageName: "Invalid-" + UUID().uuidString)
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeMainFile(content: "$render(<text>Original</text>);").0)
        try Data("{bad".utf8).write(to: source.manifestPath)
        XCTAssertFalse(manager.duplicateScript(sourcePackageName: source.name).0)
        XCTAssertEqual(manager.scriptCount(), 1)
        try FileManager.default.removeItem(at: source.manifestPath)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.path.appendingPathComponent(".hidden-link"), withDestinationURL: outside)
        XCTAssertFalse(manager.duplicateScript(sourcePackageName: source.name).0)
        XCTAssertEqual(manager.scriptCount(), 1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
        XCTAssertEqual(source.readMainFile().0, "$render(<text>Original</text>);")
    }

    func testRemixNameTruncatesWithinUTF8BudgetWithoutSplittingGraphemes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnicodeRemix-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root)
        let source = manager.getScriptPackage(packageName: String(UUID().uuidString.prefix(16)) + String(repeating: "😀", count: 56))
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeMainFile(content: "$render(<text>Emoji</text>);").0)
        let result = manager.duplicateScript(sourcePackageName: source.name)
        XCTAssertTrue(result.0, result.1)
        guard result.0 else { return }
        cacheNames.append(result.1)
        XCTAssertTrue(ScriptWidgetPackageName.isValid(result.1))
        XCTAssertTrue(result.1.hasSuffix(" Remix"))
        XCTAssertLessThanOrEqual(result.1.utf8.count, 240)
        XCTAssertEqual(manager.getScriptPackage(packageName: result.1).readMainFile().0, source.readMainFile().0)
    }
}


extension TemplateInstallationTests {
    func testInstallingLegacyTemplateDoesNotSilentlyChangeItsPermissionModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyTemplate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptWidgetPackage(path: root.appendingPathComponent("Legacy-" + UUID().uuidString))
        cacheNames.append(source.name)
        XCTAssertTrue(source.writeMainFile(content: "$render(<text>Legacy network template</text>);").0)
        let url = try XCTUnwrap(URL(string: "https://example.com/public.json"))
        XCTAssertTrue(ScriptWidgetNetworkPolicy.packageAllows(url, package: source))
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root.appendingPathComponent("library"))
        let result = manager.createScript(fromTemplate: source)
        XCTAssertTrue(result.0, result.1)
        guard result.0 else { return }
        cacheNames.append(result.1)
        let installed = manager.getScriptPackage(packageName: result.1)
        XCTAssertFalse(installed.hasManifest, "Installation must not invent empty Package 2.0 permission declarations")
        XCTAssertTrue(ScriptWidgetNetworkPolicy.packageAllows(url, package: installed))
        XCTAssertEqual(installed.readMainFile().0, source.readMainFile().0)
        XCTAssertFalse(source.hasManifest)
    }
}

final class NativePackageInstallationTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var container: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var context: ScriptWidgetPackageStorageContext!
    private var cachedNames: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeInstall-" + UUID().uuidString)
        library = root.appendingPathComponent("library")
        container = root.appendingPathComponent("preferences")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        suite = "app.scriptwidget.native-install-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if let build = ScriptManager.getSandboxBuildDirectoryURL() {
            for name in cachedNames { _ = ScriptWidgetPackageFiles.removeTree(root: build, relative: name) }
        }
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult private func inventory(_ names: [String] = []) throws -> ScriptWidgetStorageNamespaceIndex {
        try ScriptWidgetStorageNamespaces.bootstrap(existingNames: names, inventoryIsComplete: true, container: container, defaults: defaults)
    }
    private func manager(in directory: URL? = nil) -> ScriptManager {
        ScriptManager(isBuild: true, scriptDirectoryOverride: directory ?? library, storageContext: context)
    }
    private func namespace(_ name: String) throws -> String {
        try ScriptWidgetStorageNamespaces.namespace(for: name, container: container, defaults: defaults)
    }
    private func makeTemplate(name: String, legacy: Bool = false) throws -> ScriptWidgetPackage {
        let package = ScriptWidgetPackage(path: root.appendingPathComponent("Source-" + UUID().uuidString))
        cachedNames.append(package.name)
        XCTAssertTrue(package.writeMainFile(content: "$render(<text>Installed</text>);").0)
        XCTAssertTrue(package.writeFile(relativePath: "lib/value.js", content: "module.exports = 42;").0)
        if !legacy {
            var manifest = WidgetPackageManifest.newProject(name: name)
            manifest.minimumRuntimeVersion = "1.3"; manifest.permissions = [.storage]
            XCTAssertTrue(package.writeManifest(manifest).0)
        }
        return package
    }

    func testBlankCreationPublishesManifestSourceImagesAndFreshNativeIdentityTogether() throws {
        let name = "Blank-" + UUID().uuidString
        defaults.set("orphan remains", forKey: "script." + name + ".secret")
        _ = try inventory()
        let images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let binary = Data([0, 128, 255])
        try binary.write(to: images.appendingPathComponent("photo.bin"))
        let manager = manager()
        let created = manager.createScript(content: "$render(<text>Blank</text>);", recommendPackageName: name, imageCopyPath: images)
        XCTAssertTrue(created.0, created.1)
        cachedNames.append(name)
        let package = manager.getScriptPackage(packageName: name)
        XCTAssertEqual(package.readMainFile().0, "$render(<text>Blank</text>);")
        XCTAssertEqual(package.readManifest()?.name, name)
        XCTAssertEqual(ScriptWidgetPackageFiles.read(root: package.path, relative: "image/photo.bin"), binary)
        let prefix = try namespace(name)
        XCTAssertNil(defaults.object(forKey: prefix + "secret"))
        XCTAssertEqual(defaults.string(forKey: "script." + name + ".secret"), "orphan remains")
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
        XCTAssertEqual(try inventory().owners.filter(\.active).map(\.name), [name])
    }

    func testTemplateAndRemixUseRealPublicationAdapterWithIndependentRecords() throws {
        _ = try inventory()
        let source = try makeTemplate(name: "Agenda-" + UUID().uuidString)
        let manager = manager()
        let installed = manager.createScript(fromTemplate: source)
        XCTAssertTrue(installed.0, installed.1)
        guard installed.0 else { return }
        cachedNames.append(installed.1)
        let first = try namespace(installed.1)
        defaults.set("private", forKey: first + "record")
        let duplicate = manager.duplicateScript(sourcePackageName: installed.1)
        XCTAssertTrue(duplicate.0, duplicate.1)
        guard duplicate.0 else { return }
        cachedNames.append(duplicate.1)
        let second = try namespace(duplicate.1)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(defaults.object(forKey: second + "record"))
        XCTAssertEqual(defaults.string(forKey: first + "record"), "private")
        let a = manager.getScriptPackage(packageName: installed.1), b = manager.getScriptPackage(packageName: duplicate.1)
        XCTAssertNotEqual(a.readManifest()?.id, b.readManifest()?.id)
        XCTAssertEqual(b.readManifest()?.permissions, [.storage])
        XCTAssertEqual(b.readManifest()?.minimumRuntimeVersion, "1.3")
        XCTAssertEqual(b.readFile(relativePath: "lib/value.js").0, "module.exports = 42;")
        XCTAssertEqual(try inventory().owners.filter(\.active).count, 2)
    }

    func testArchiveImportsKeepPublicManifestIDButNeverReuseNativeStorageIdentity() throws {
        _ = try inventory()
        let source = try makeTemplate(name: "Imported-" + UUID().uuidString)
        let archive = root.appendingPathComponent("widget.swt")
        XCTAssertTrue(SSZipArchive.createZipFile(atPath: archive.path, withContentsOfDirectory: source.path.path, keepParentDirectory: true))
        let manager = manager()
        var prefixes = Set<String>()
        for _ in 0..<2 {
            let result = manager.importScriptPackage(fromPath: archive)
            XCTAssertTrue(result.succeeded, result.message)
            let name = try XCTUnwrap(result.packageName)
            cachedNames.append(name)
            let package = manager.getScriptPackage(packageName: name)
            XCTAssertEqual(package.readManifest()?.id, source.readManifest()?.id)
            XCTAssertEqual(package.readFile(relativePath: "lib/value.js").0, "module.exports = 42;")
            let prefix = try namespace(name)
            XCTAssertTrue(prefixes.insert(prefix).inserted)
            XCTAssertNil(defaults.object(forKey: prefix + "record"))
            defaults.set("only this installation", forKey: prefix + "record")
        }
        XCTAssertEqual(try inventory().owners.count, 2)
    }

    func testInstallerNeverBootstrapsFromImportedNamesAndFailsWithoutNativeInventory() throws {
        let name = "Unknown-" + UUID().uuidString
        let source = try makeTemplate(name: name)
        defaults.set("do not grant", forKey: "script." + name + ".secret")
        let manager = manager()
        let created = manager.createScript(content: "$render(<text>New</text>);", recommendPackageName: name, imageCopyPath: nil)
        XCTAssertFalse(created.0)
        XCTAssertFalse(manager.createScript(fromTemplate: source).0)
        XCTAssertTrue(manager.listScripts().isEmpty)
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
        XCTAssertEqual(defaults.string(forKey: "script." + name + ".secret"), "do not grant")
        defaults.set(Data("invalid native index".utf8), forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertFalse(manager.createScript(fromTemplate: source).0)
        XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey), Data("invalid native index".utf8))
        XCTAssertTrue(manager.listScripts().isEmpty)
    }

    func testRejectedPreparationAndMismatchedLibraryPublishNeitherFilesNorOwners() throws {
        _ = try inventory()
        let before = defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)
        let images = root.appendingPathComponent("unsafe-images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("hidden"), withDestinationURL: outside)
        XCTAssertFalse(manager().createScript(content: "source", recommendPackageName: "Rejected", imageCopyPath: images).0)
        let other = root.appendingPathComponent("other-library")
        XCTAssertFalse(manager(in: other).createScript(content: "source", recommendPackageName: "WrongRoot", imageCopyPath: nil).0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path), "A managed manager must not create a missing or mismatched library root")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [])
        XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey), before)
        XCTAssertEqual(try Data(contentsOf: outside), Data("unchanged".utf8))
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
    }

    func testSavingExistingPackagePreservesIdentityAndRejectsInvalidManifestBeforeWriting() throws {
        _ = try inventory()
        let name = "Edited-" + UUID().uuidString
        let manager = manager()
        XCTAssertTrue(manager.saveScript(packageName: name, content: "original", imageCopyPath: nil).0)
        cachedNames.append(name)
        let prefix = try namespace(name)
        defaults.set("keep", forKey: prefix + "record")
        XCTAssertTrue(manager.saveScript(packageName: name, content: "edited", imageCopyPath: nil).0)
        XCTAssertEqual(try namespace(name), prefix)
        let package = manager.getScriptPackage(packageName: name)
        XCTAssertEqual(package.readMainFile().0, "edited")
        try Data("{bad".utf8).write(to: package.manifestPath)
        let rejected = manager.saveScript(packageName: name, content: "must not replace", imageCopyPath: nil)
        XCTAssertFalse(rejected.0)
        XCTAssertEqual(try String(contentsOf: package.path.appendingPathComponent("main.jsx"), encoding: .utf8), "edited")
        XCTAssertEqual(try Data(contentsOf: package.manifestPath), Data("{bad".utf8))
        XCTAssertEqual(defaults.string(forKey: prefix + "record"), "keep")
    }

    func testLegacyTemplateAndExistingLegacySaveRetainTheirFormatWithNativeIdentity() throws {
        _ = try inventory()
        let source = try makeTemplate(name: "unused", legacy: true)
        let manager = manager()
        let result = manager.createScript(fromTemplate: source)
        XCTAssertTrue(result.0, result.1)
        guard result.0 else { return }
        cachedNames.append(result.1)
        let prefix = try namespace(result.1)
        let installed = manager.getScriptPackage(packageName: result.1)
        XCTAssertFalse(installed.hasManifest)
        XCTAssertTrue(manager.saveScript(packageName: result.1, content: "legacy edit", imageCopyPath: nil).0)
        XCTAssertFalse(installed.hasManifest)
        XCTAssertEqual(installed.readMainFile().0, "legacy edit")
        XCTAssertEqual(try namespace(result.1), prefix)
    }

    func testDescriptorReceiptsRejectLinksSpecialFilesCaseAliasesAndChangedStagingIdentity() throws {
        let prepared = root.appendingPathComponent("prepared")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: root, relative: "prepared"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prepared)
        XCTAssertThrowsError(try ScriptWidgetPackageFiles.directoryReceipt(root: root, relative: "link"))
        XCTAssertThrowsError(try ScriptWidgetPackageFiles.directoryReceipt(root: root, relative: "PREPARED"))
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ScriptWidgetPackageFiles.directoryReceipt(root: root, relative: "pipe"))
        XCTAssertNil(try ScriptWidgetPackageFiles.directoryReceipt(root: root, relative: "missing"))
        XCTAssertThrowsError(try ScriptWidgetPackageStorageContext(libraryRoot: link, container: container, defaults: defaults))
        try FileManager.default.moveItem(at: prepared, to: root.appendingPathComponent("original-prepared"))
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        XCTAssertFalse(ScriptWidgetPackageFiles.publishDirectory(prepared, root: library, name: "Changed", expectedReceipt: receipt))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path))
    }

    private enum Interrupted: Error { case inspection }
    private func leaveInterruptedPublication(name: String, published: Bool) throws -> ScriptWidgetStorageOwner {
        let prepared = root.appendingPathComponent("Prepared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data("complete".utf8), root: prepared, relative: "main.jsx"))
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: prepared.deletingLastPathComponent(), relative: prepared.lastPathComponent))
        var reserved: ScriptWidgetStorageOwner?, interrupted = false
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.publishFresh(name: name, location: context.locationIdentifier, receipt: receipt,
            container: container, defaults: defaults, inspect: { _ in
                if interrupted { throw Interrupted.inspection }
                return .absent
            }, publish: { owner in
                reserved = owner
                if published { XCTAssertTrue(ScriptWidgetPackageFiles.publishDirectory(prepared, root: self.library, name: name, expectedReceipt: receipt)) }
                interrupted = true
            }))
        return try XCTUnwrap(reserved)
    }

    func testRealDirectoryRecoveryCommitsReservedIdentityOrRollsBackWithoutDeletingRecords() throws {
        for published in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            let name = "Recover-" + UUID().uuidString
            _ = try inventory([name])
            let previous = try namespace(name)
            defaults.set("preserved", forKey: previous + "record")
            let reserved = try leaveInterruptedPublication(name: name, published: published)
            XCTAssertThrowsError(try namespace(name))
            let coldContext = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
            let recovered = try coldContext.recoverInstallation()
            if published {
                guard case .committed(let owner) = recovered else { return XCTFail("Expected commit") }
                XCTAssertEqual(owner.id, reserved.id)
                XCTAssertEqual(try namespace(name), reserved.namespace)
                XCTAssertNil(defaults.object(forKey: reserved.namespace + "record"))
                XCTAssertEqual(try String(contentsOf: library.appendingPathComponent(name).appendingPathComponent("main.jsx"), encoding: .utf8), "complete")
            } else {
                XCTAssertEqual(recovered, .rolledBack)
                XCTAssertEqual(try namespace(name), previous)
            }
            XCTAssertEqual(defaults.string(forKey: previous + "record"), "preserved")
            XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.installationKey))
        }
    }

    func testReplacedLibraryRootCannotReplayAnInterruptedPublication() throws {
        _ = try inventory()
        _ = try leaveInterruptedPublication(name: "Recover-" + UUID().uuidString, published: true)
        let journal = defaults.data(forKey: ScriptWidgetStorageNamespaces.installationKey)
        let oldRoot = root.appendingPathComponent("original-library")
        try FileManager.default.moveItem(at: library, to: oldRoot)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        XCTAssertThrowsError(try context.recoverInstallation())
        let replacement = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        XCTAssertNotEqual(replacement.locationIdentifier, context.locationIdentifier)
        XCTAssertThrowsError(try replacement.recoverInstallation())
        XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.installationKey), journal)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [])
        try FileManager.default.removeItem(at: library)
        try FileManager.default.moveItem(at: oldRoot, to: library)
        guard case .committed = try context.recoverInstallation() else { return XCTFail("Original root should recover") }
    }
}

final class NativeCacheIdentityTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var cache: URL!
    private var container: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var context: ScriptWidgetPackageStorageContext!
    private var packageName: String!
    private var creator: ScriptManager!
    private var builder: ScriptManager!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheIdentity-" + UUID().uuidString)
        library = root.appendingPathComponent("library"); cache = root.appendingPathComponent("cache"); container = root.appendingPathComponent("preferences")
        for directory in [library!, cache!, container!] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        suite = "app.scriptwidget.cache-identity-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: container, defaults: defaults)
        context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        creator = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context)
        builder = ScriptManager(isBuild: false, scriptDirectoryOverride: library, storageContext: context, buildDirectoryOverride: cache)
        packageName = "Owned-" + UUID().uuidString
        let created = creator.createScript(content: "$render(<text>Original</text>);", recommendPackageName: packageName, imageCopyPath: nil)
        XCTAssertTrue(created.0, created.1)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if let build = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: build, relative: packageName) }
        try FileManager.default.removeItem(at: root)
    }
    private func build() throws {
        let result = builder.buildScriptPackage(package: creator.getScriptPackage(packageName: packageName))
        XCTAssertTrue(result.0, result.1)
    }
    private func cachedBinding() throws -> ScriptWidgetStorageDirectoryBinding {
        try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults).boundDirectory(name: packageName, role: .cache)
    }
    private func prepared(_ content: String = "prepared") throws -> URL {
        let directory = cache.appendingPathComponent(".prepared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data(content.utf8), root: directory, relative: "main.jsx"))
        return directory
    }

    func testActualBuilderPublishesMatchingSourceAndCacheIdentitiesAndReplacesAtomically() throws {
        let source = try context.boundDirectory(name: packageName, role: .source)
        try build()
        let first = try cachedBinding()
        XCTAssertEqual(first.ownerID, source.ownerID)
        XCTAssertEqual(first.role, .cache)
        XCTAssertNotEqual(first.location, source.location)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent(packageName).appendingPathComponent("main.jsx"), encoding: .utf8), "$render(<text>Original</text>);")
        let package = creator.getScriptPackage(packageName: packageName)
        XCTAssertTrue(package.writeMainFile(content: "$render(<text>Updated</text>);").0)
        try build()
        let second = try cachedBinding()
        XCTAssertEqual(second.ownerID, first.ownerID)
        XCTAssertNotEqual(second.receipt, first.receipt)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent(packageName).appendingPathComponent("main.jsx"), encoding: .utf8), "$render(<text>Updated</text>);")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.path).contains { $0.hasPrefix(".staging-") })
    }

    func testFreshSameNameInstallationCannotReadOldCacheOrInheritOldRecords() throws {
        try build()
        let old = try cachedBinding()
        let oldPrefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        defaults.set("private history", forKey: oldPrefix + "record")
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertTrue(creator.createScript(content: "$render(<text>New install</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        let fresh = try context.boundDirectory(name: packageName, role: .source)
        XCTAssertNotEqual(fresh.ownerID, old.ownerID)
        XCTAssertThrowsError(try cachedBinding())
        let newPrefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: newPrefix + "record"))
        XCTAssertEqual(defaults.string(forKey: oldPrefix + "record"), "private history")
        try build()
        XCTAssertEqual(try cachedBinding().ownerID, fresh.ownerID)
    }

    func testCacheCopyFromRetiredSourceSnapshotCannotBindToNewInstallation() throws {
        try build()
        let snapshot = try context.boundDirectory(name: packageName, role: .source)
        let pending = try prepared("old script copy")
        let cached = try Data(contentsOf: cache.appendingPathComponent(packageName).appendingPathComponent("main.jsx"))
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertTrue(creator.createScript(content: "$render(<text>Fresh</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        XCTAssertThrowsError(try context.publishCache(pending, source: snapshot, cacheRoot: cache))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(packageName).appendingPathComponent("main.jsx")), cached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testUnrecordedCachePublicationFailsClosedUntilARebuild() throws {
        try build()
        let old = try cachedBinding()
        let pending = try prepared("publication before metadata commit")
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: cache, relative: pending.lastPathComponent))
        // Simulate process death after the real directory swap but before the
        // preferences update. Never infer a grant from the new package files.
        XCTAssertTrue(ScriptWidgetPackageFiles.replaceCacheDirectory(pending, root: cache, name: packageName, expectedReceipt: receipt))
        XCTAssertThrowsError(try cachedBinding())
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source).ownerID, old.ownerID)
        try build()
        XCTAssertEqual(try cachedBinding().ownerID, old.ownerID)
    }

    func testRetiredOwnerAndRenamedButUnboundDirectoryCannotResolveCachedScope() throws {
        try build()
        let original = try cachedBinding()
        try ScriptWidgetStorageNamespaces.rename(from: packageName, to: "Renamed", container: container, defaults: defaults)
        XCTAssertThrowsError(try cachedBinding())
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.boundDirectory(name: "Renamed", role: .cache, location: original.location,
            receipt: original.receipt, container: container, defaults: defaults))
        try ScriptWidgetStorageNamespaces.retire(name: "Renamed", container: container, defaults: defaults)
        XCTAssertThrowsError(try cachedBinding())
    }

    func testRecreatedCacheRootRequiresANewValidatedBindingAndCanBeRebuilt() throws {
        try build()
        let old = try cachedBinding()
        let moved = root.appendingPathComponent("old-cache")
        try FileManager.default.moveItem(at: cache, to: moved)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: moved.appendingPathComponent(packageName), to: cache.appendingPathComponent(packageName))
        XCTAssertThrowsError(try cachedBinding())
        try build()
        let fresh = try cachedBinding()
        XCTAssertEqual(fresh.ownerID, old.ownerID)
        XCTAssertNotEqual(fresh.location, old.location)
    }

    func testMalformedDirectoryMetadataRejectsLookupAndPublicationWithoutResettingIt() throws {
        try build()
        let valid = try XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.directoriesKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var cases: [Any] = ["wrong type", Data("{bad".utf8), Data(repeating: 32, count: ScriptWidgetStorageNamespaces.maximumRegistryBytes + 1)]
        for (key, value) in [("unknown", true as Any), ("formatVersion", true as Any)] {
            var mutated = object; mutated[key] = value
            cases.append(try JSONSerialization.data(withJSONObject: mutated))
        }
        for (key, value) in [("ownerID", "not-a-uuid" as Any), ("role", "automatic" as Any), ("receipt", ["device": true, "inode": 1] as Any)] {
            var mutated = object, rows = entries
            rows[0][key] = value; mutated["entries"] = rows
            cases.append(try JSONSerialization.data(withJSONObject: mutated))
        }
        var duplicate = object; duplicate["entries"] = entries + [entries[0]]
        cases.append(try JSONSerialization.data(withJSONObject: duplicate))
        let pending = try prepared()
        let source = try context.boundDirectory(name: packageName, role: .source)
        for value in cases {
            defaults.set(value, forKey: ScriptWidgetStorageNamespaces.directoriesKey)
            XCTAssertThrowsError(try cachedBinding())
            XCTAssertThrowsError(try context.publishCache(pending, source: source, cacheRoot: cache))
            XCTAssertFalse(creator.createScript(content: "no grant", recommendPackageName: "Rejected", imageCopyPath: nil).0)
            XCTAssertFalse(creator.isExist(packageName: "Rejected"))
            if let data = value as? Data { XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.directoriesKey), data) }
            else { XCTAssertEqual(defaults.string(forKey: ScriptWidgetStorageNamespaces.directoriesKey), value as? String) }
        }
    }

    func testInventoriedSourceBindingIsExplicitIdempotentAndCannotReassignDirectories() throws {
        let legacyName = "Legacy-" + UUID().uuidString
        defaults.removePersistentDomain(forName: suite)
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [legacyName], inventoryIsComplete: true, container: container, defaults: defaults)
        let legacy = library.appendingPathComponent(legacyName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertThrowsError(try context.boundDirectory(name: legacyName, role: .source))
        try context.bindInventoriedSource(name: legacyName)
        let original = try context.boundDirectory(name: legacyName, role: .source)
        try context.bindInventoriedSource(name: legacyName)
        XCTAssertEqual(try context.boundDirectory(name: legacyName, role: .source), original)
        try FileManager.default.moveItem(at: legacy, to: root.appendingPathComponent("original-legacy"))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertThrowsError(try context.bindInventoriedSource(name: legacyName))
        XCTAssertThrowsError(try context.boundDirectory(name: legacyName, role: .source))
    }

    func testInventoriedBindingDoesNotBypassAmbiguousLegacyReviewOrAuthorizeFreshOwners() throws {
        let legacyName = "Legacy-" + UUID().uuidString
        defaults.removePersistentDomain(forName: suite)
        defaults.set("ambiguous", forKey: "script." + legacyName + ".Child.value")
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [legacyName, legacyName + ".Child"], inventoryIsComplete: true, container: container, defaults: defaults)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(legacyName), withIntermediateDirectories: true)
        try context.bindInventoriedSource(name: legacyName)
        XCTAssertThrowsError(try context.boundDirectory(name: legacyName, role: .source)) {
            XCTAssertEqual($0 as? ScriptWidgetStorageNamespaceError, .reviewRequired)
        }
        let fresh = try ScriptWidgetStorageNamespaces.registerFresh(name: "Fresh", container: container, defaults: defaults)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(fresh.name), withIntermediateDirectories: true)
        XCTAssertThrowsError(try context.bindInventoriedSource(name: fresh.name))
    }

    func testCacheCannotReplaceAuthoredSourcesOrCopyAnUnrelatedPackage() throws {
        let package = creator.getScriptPackage(packageName: packageName)
        let overlap = ScriptManager(isBuild: false, scriptDirectoryOverride: library, storageContext: context, buildDirectoryOverride: package.path)
        XCTAssertFalse(overlap.buildScriptPackage(package: package).0)
        XCTAssertEqual(package.readMainFile().0, "$render(<text>Original</text>);")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: package.path.path).contains { $0.hasPrefix(".staging-") })
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let fake = unrelated.appendingPathComponent(packageName)
        try FileManager.default.copyItem(at: package.path, to: fake)
        XCTAssertFalse(builder.buildScriptPackage(package: ScriptWidgetPackage(path: fake)).0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testCachePublisherRejectsLinkedDestinationAndChangedPreparedReceipt() throws {
        let snapshot = try context.boundDirectory(name: packageName, role: .source)
        let pending = try prepared()
        let link = cache.appendingPathComponent(packageName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library.appendingPathComponent(packageName))
        XCTAssertThrowsError(try context.publishCache(pending, source: snapshot, cacheRoot: cache))
        XCTAssertEqual(creator.getScriptPackage(packageName: packageName).readMainFile().0, "$render(<text>Original</text>);")
        try FileManager.default.removeItem(at: link)
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: cache, relative: pending.lastPathComponent))
        try FileManager.default.moveItem(at: pending, to: cache.appendingPathComponent("held"))
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        XCTAssertFalse(ScriptWidgetPackageFiles.replaceCacheDirectory(pending, root: cache, name: packageName, expectedReceipt: receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testPublisherErrorAfterSwapCommitsOnlyTheActuallyVerifiedCache() throws {
        let source = try context.boundDirectory(name: packageName, role: .source)
        let cacheContext = try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults)
        let pending = try prepared()
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: cache, relative: pending.lastPathComponent))
        var calls = 0
        let binding = try ScriptWidgetStorageNamespaces.publishCache(source: source, location: cacheContext.locationIdentifier, receipt: receipt,
            container: container, defaults: defaults, sourceStillMatches: { true }, inspect: {
                guard let actual = try ScriptWidgetPackageFiles.directoryReceipt(root: self.cache, relative: self.packageName) else { return .absent }
                return actual == receipt ? .matching : .different
            }, publish: {
                calls += 1
                XCTAssertTrue(ScriptWidgetPackageFiles.replaceCacheDirectory(pending, root: self.cache, name: self.packageName, expectedReceipt: receipt))
                throw CocoaError(.fileWriteUnknown)
            })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try cachedBinding(), binding)
    }
}

extension NativeCacheIdentityTests {
    func testInterruptedReplacementRollbackRetainsPreviousFallbackCacheBinding() throws {
        try build()
        let old = try cachedBinding()
        let prefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        defaults.set("private retained", forKey: prefix + "record")
        try FileManager.default.moveItem(at: library.appendingPathComponent(packageName), to: root.appendingPathComponent("held-source"))
        let pending = try prepared("new source before identity commit")
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: cache, relative: pending.lastPathComponent))
        var reserved: ScriptWidgetStorageOwner?, published = false
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.publishFresh(name: packageName, location: context.locationIdentifier, receipt: receipt,
            container: container, defaults: defaults, inspect: { _ in
                if published { throw CocoaError(.fileReadUnknown) }
                return .absent
            }, publish: { owner in
                reserved = owner
                XCTAssertTrue(ScriptWidgetPackageFiles.publishDirectory(pending, root: self.library, name: self.packageName, expectedReceipt: receipt))
                published = true
            }))
        let unexposed = try XCTUnwrap(reserved)
        // Recreate the crash window after directory metadata was saved but
        // before the inactive reservation became the committed identity.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.directoriesKey))) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let staged = ScriptWidgetStorageDirectoryBinding(name: packageName, ownerID: unexposed.id, role: .source, location: context.locationIdentifier, receipt: receipt)
        entries.append(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(staged)) as? [String: Any]))
        object["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ScriptWidgetStorageNamespaces.directoriesKey)
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertEqual(try context.recoverInstallation(), .rolledBack)
        XCTAssertEqual(try cachedBinding(), old)
        XCTAssertEqual(defaults.string(forKey: prefix + "record"), "private retained")
        let repaired = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.directoriesKey))) as? [String: Any])
        XCTAssertFalse((repaired["entries"] as? [[String: Any]] ?? []).contains { $0["ownerID"] as? String == unexposed.id })
    }
}

final class SynchronousRuntimeResultTests: XCTestCase {
    func testCompletionWithoutValueIsAnExplicitError() {
        let result = ScriptWidgetSynchronousResult<Int>()
        result.finish(.finished)
        let output = result.wait(until: .now() + .seconds(1))
        XCTAssertNil(output.0)
        XCTAssertEqual(output.1?.category, "Internal")
        XCTAssertTrue(output.1?.displayMessage.contains("without producing") == true)
    }

    func testValueIsPublishedBeforeCompletionAndLateValuesCannotReplaceIt() {
        let result = ScriptWidgetSynchronousResult<Int>()
        result.receive(42); result.finish(.finished)
        result.receive(99); result.finish(.failure(.scriptError("late")))
        let output = result.wait(until: .now() + .seconds(1))
        XCTAssertEqual(output.0, 42)
        XCTAssertNil(output.1)
    }

    func testTimeoutClosesResultAndCancelsALateSubscription() {
        let result = ScriptWidgetSynchronousResult<Int>()
        var timedOut = false, cancelled = false
        let output = result.wait(until: .now()) { timedOut = true }
        XCTAssertNil(output.0); XCTAssertEqual(output.1?.category, "Resource Limit")
        XCTAssertTrue(timedOut)
        result.receive(42); result.finish(.finished)
        result.install(AnyCancellable { cancelled = true })
        result.publisherLane.queue.sync {}
        XCTAssertTrue(cancelled)
    }

    func testWorkerCompletionAndSubscriptionInstallationRacePreservesEveryValue() {
        for index in 0..<200 {
            let result = ScriptWidgetSynchronousResult<Int>()
            DispatchQueue.global().async {
                result.receive(index)
                result.finish(.finished)
                result.install(AnyCancellable {})
            }
            let output = result.wait(until: .now() + .seconds(2))
            XCTAssertEqual(output.0, index)
            XCTAssertNil(output.1)
        }
    }
}

final class NativeQueryCancellationTests: XCTestCase {
    func testNativeCancellationIsBoundedAndRunsOnceOutsideTheSessionLock() throws {
        let session = ScriptWidgetExecutionSession()
        var calls = 0
        for _ in 0..<ScriptWidgetExecutionSession.maximumDataQueries {
            XCTAssertNotNil(session.registerCancellation {
                calls += 1
                XCTAssertFalse(session.isActive)
            })
        }
        XCTAssertNil(session.registerCancellation { XCTFail("Over-budget resource") })
        session.cancel(.superseded); session.cancel(.timeout); session.finish()
        XCTAssertEqual(calls, ScriptWidgetExecutionSession.maximumDataQueries)
        XCTAssertNil(session.registerCancellation { XCTFail("Completed resource") })
    }

    func testCompletedQueryIsUnregisteredAndDoesNotCancelLater() throws {
        let session = ScriptWidgetExecutionSession()
        var calls = 0
        let registration = try XCTUnwrap(session.registerCancellation { calls += 1 })
        session.completeCancellation(registration)
        session.finish()
        XCTAssertEqual(calls, 0)
    }

    func testQueryCompletingBeforeInstallationDoesNotLeaveACancellationHook() {
        let session = ScriptWidgetExecutionSession()
        let query = ScriptWidgetQueryCancellation(session: session)
        query.complete()
        XCTAssertFalse(query.install { XCTFail("Completed query should not be cancelled") })
        session.finish()
    }

    func testCompletingAnInstalledQueryRemovesItsResourceHook() {
        let session = ScriptWidgetExecutionSession()
        let query = ScriptWidgetQueryCancellation(session: session)
        XCTAssertTrue(query.install { XCTFail("Completed query should not be cancelled") })
        query.complete(); query.complete(); session.finish()
    }
}

extension NativeQueryCancellationTests {
    func testAQueryCannotInstallMultipleCancellationHandlers() {
        let session = ScriptWidgetExecutionSession()
        let query = ScriptWidgetQueryCancellation(session: session)
        var calls = 0
        XCTAssertTrue(query.install { calls += 1 })
        XCTAssertFalse(query.install { XCTFail("Duplicate query resource") })
        session.cancel(.explicit)
        XCTAssertEqual(calls, 1)
    }
}

extension GalleryTests {
    private func nativeGalleryPayload(version: String) throws -> (GalleryItem, [URL: Result<(Data, HTTPURLResponse), Error>]) {
        var manifest = WidgetPackageManifest.newProject(name: "Native Gallery Fixture")
        manifest.id = "dev.scriptwidget.native-install"; manifest.version = version; manifest.permissions = [.storage]
        let payloads = ["widget.json": try JSONEncoder().encode(manifest), "main.jsx": Data("$render(<text>\(version)</text>);".utf8)]
        var responses: [URL: Result<(Data, HTTPURLResponse), Error>] = [:]
        let files = payloads.keys.sorted().map { name -> GalleryFile in
            let url = URL(string: "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/widgets/native-fixture/\(version)/\(name)")!
            let data = payloads[name]!
            responses[url] = .success((data, response(url: url, status: 200)))
            return GalleryFile(path: name, url: url, sha256: GalleryInstaller.sha256(data), bytes: data.count)
        }
        return (.init(id: manifest.id, kind: .widget, name: manifest.name, version: version, summary: "Native Gallery identity fixture",
            symbol: "square", author: "ScriptWidget", license: "MIT", tags: ["test"], minimumRuntimeVersion: ScriptWidgetBuildContract.runtimeAPIVersion,
            sourceURL: URL(string: "https://github.com/everettjf/scriptwidget/tree/main/Gallery")!, featured: false, files: files), responses)
    }

    func testVerifiedInstallerUsesNativeProvenanceForUpdateDespitePoisonedLocalName() async throws {
        let root = makeTemporaryDirectory()
        let library = root.appendingPathComponent("Scripts"), container = root.appendingPathComponent("Container")
        for directory in [library, container] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let suite = "app.scriptwidget.gallery-native-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: container, defaults: defaults)
        let context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context, buildDirectoryOverride: root.appendingPathComponent("Cache"))
        let registry = GalleryInstallationRegistry(fileURL: root.appendingPathComponent("registry.json"))
        let (first, firstResponses) = try nativeGalleryPayload(version: "1.0.0")
        let (next, nextResponses) = try nativeGalleryPayload(version: "2.0.0")
        let installer = GalleryInstaller(transport: GalleryTestTransport(mappedResponses: firstResponses.merging(nextResponses) { _, new in new }),
            registry: registry, scriptManager: manager, skillManager: AIWidgetSkillManager(directory: root.appendingPathComponent("Skills")), buildAfterInstall: false)
        let installed = try await installer.install(first)
        let original = try XCTUnwrap(context.gallerySource(itemID: first.id))
        XCTAssertEqual(installed.localIdentifier, original.name)
        XCTAssertEqual(installer.state(for: first), .installed)
        defaults.set("kept", forKey: "ScriptWidgetStorage.v2:" + original.ownerID + ":record")
        let victimName = "Other-" + UUID().uuidString
        XCTAssertTrue(manager.createScript(content: "$render(<text>do not replace</text>);", recommendPackageName: victimName, imageCopyPath: nil).0)
        let victim = manager.getScriptPackage(packageName: victimName)
        var forged = try XCTUnwrap(victim.readManifest()); forged.id = first.id
        XCTAssertTrue(victim.writeManifest(forged).0)
        try registry.save(.init(itemID: first.id, kind: .widget, version: first.version, localIdentifier: victimName,
            contentFingerprint: first.contentFingerprint, installedAt: Date()))
        let updated = try await installer.install(next)
        let current = try XCTUnwrap(context.gallerySource(itemID: first.id))
        XCTAssertEqual(updated.localIdentifier, original.name)
        XCTAssertEqual(current.ownerID, original.ownerID); XCTAssertNotEqual(current.receipt, original.receipt)
        XCTAssertEqual(defaults.string(forKey: "ScriptWidgetStorage.v2:" + original.ownerID + ":record"), "kept")
        XCTAssertEqual(victim.readMainFile().0, "$render(<text>do not replace</text>);")
        XCTAssertEqual(installer.state(for: next), .installed)
    }

    func testNativeInstallerRejectsBadHashBeforePublishingAnyOwner() async throws {
        let root = makeTemporaryDirectory(), suite = "app.scriptwidget.gallery-hash-tests." + UUID().uuidString
        let library = root.appendingPathComponent("Scripts"), container = root.appendingPathComponent("Container")
        for directory in [library, container] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: container, defaults: defaults)
        let context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context)
        let (item, responses) = try nativeGalleryPayload(version: "1.0.0")
        var invalid = responses
        let file = try XCTUnwrap(item.files.first)
        invalid[file.url] = .success((Data(repeating: 120, count: file.bytes), response(url: file.url, status: 200)))
        let installer = GalleryInstaller(transport: GalleryTestTransport(mappedResponses: invalid),
            registry: GalleryInstallationRegistry(fileURL: root.appendingPathComponent("registry.json")), scriptManager: manager,
            skillManager: AIWidgetSkillManager(directory: root.appendingPathComponent("Skills")), buildAfterInstall: false)
        do { _ = try await installer.install(item); XCTFail("Invalid downloaded bytes must not publish") } catch {}
        XCTAssertTrue(manager.listScripts().isEmpty)
        XCTAssertNil(try context.gallerySource(itemID: item.id))
    }
}

#if canImport(AppIntentsTesting)
@available(macOS 27.0, iOS 27.0, *)
extension ScriptWidgetAppIntentsMetadataTests {
    func testDirectFunctionIntentPublishesAllTransportParameters() throws {
        let definitions = IntentDefinitions(bundleIdentifier: "com.everettjf.scriptwidget")
        let intent = definitions.intents["ButtonActionAppIntent"].makeIntent(functionName: "update", packageName: "Example",
            scriptParameter: "Read", executionScope: "transport-scope")
        let function: String = try intent.functionName
        let package: String = try intent.packageName
        let parameter: String = try intent.scriptParameter
        let scope: String = try intent.executionScope
        XCTAssertEqual(function, "update"); XCTAssertEqual(package, "Example")
        XCTAssertEqual(parameter, "Read"); XCTAssertEqual(scope, "transport-scope")
    }
}
#endif

/// Oversized legacy values are supplied in memory: persisting deliberately
/// invalid-sized values can invalidate a simulator preference domain itself.
/// All normal records/metadata still use the real isolated UserDefaults suite.
private final class StorageReviewLargeValueDefaults: UserDefaults, @unchecked Sendable {
    enum Value: Sendable { case text(String), data(Data) }
    let simulatedKey: String
    private let simulatedValue: Value
    private let counterLock = NSLock()
    private var reads = 0
    private var mutations = 0
    var simulatedMutations: Int { counterLock.lock(); defer { counterLock.unlock() }; return mutations }
    var simulatedReads: Int { counterLock.lock(); defer { counterLock.unlock() }; return reads }
    init(suite: String, key: String, value: Value) {
        simulatedKey = key; simulatedValue = value
        super.init(suiteName: suite)!
    }
    private var value: Any {
        switch simulatedValue { case .text(let text): return text; case .data(let data): return data }
    }
    override func object(forKey key: String) -> Any? {
        if key == simulatedKey {
            counterLock.lock(); reads += 1; counterLock.unlock()
            return super.object(forKey: key) ?? value
        }
        return super.object(forKey: key)
    }
    override func set(_ value: Any?, forKey key: String) {
        if key == simulatedKey { counterLock.lock(); mutations += 1; counterLock.unlock() }
        super.set(value, forKey: key)
    }
    override func removeObject(forKey key: String) {
        if key == simulatedKey { counterLock.lock(); mutations += 1; counterLock.unlock() }
        super.removeObject(forKey: key)
    }
    override func dictionaryRepresentation() -> [String: Any] {
        var values = super.dictionaryRepresentation()
        if values[simulatedKey] == nil { values[simulatedKey] = value }
        return values
    }
}

final class NativeStorageReviewTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var container: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var context: ScriptWidgetPackageStorageContext!
    private var service: ScriptWidgetStorageUpgradeService!
    private let key = "script.Read.logs.count"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageReview-" + UUID().uuidString)
        library = root.appendingPathComponent("library"); container = root.appendingPathComponent("container")
        for path in [library!, container!] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        for name in ["Read", "Read.logs"] {
            let directory = library.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let package = ScriptWidgetPackage(path: directory)
            var manifest = WidgetPackageManifest.newProject(name: name); manifest.permissions = [.storage]
            XCTAssertTrue(package.writeMainFile(content: "$render(<text>review</text>);").0)
            XCTAssertTrue(package.writeManifest(manifest).0)
        }
        suite = "app.scriptwidget.storage-review-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        service = .init(context: context, isUsingICloud: false)
        defaults.set("3", forKey: key)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func prepare() throws {
        let inventory = try service.inventory()
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: Array(inventory.entries.keys), inventoryIsComplete: inventory.isComplete,
            container: container, defaults: defaults)
        for name in inventory.entries.keys { try context.bindInventoriedSource(name: name) }
    }

    func testInventoryIsReadOnlyAndICloudNeverAssumesCompleteness() throws {
        let local = try service.inventory()
        XCTAssertEqual(Set(local.entries.keys), ["Read", "Read.logs"])
        XCTAssertTrue(local.isComplete)
        XCTAssertFalse(try ScriptWidgetLibraryInventory.capture(context: context, isUsingICloud: true).isComplete)
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
        XCTAssertThrowsError(try service.fields())
        XCTAssertEqual(defaults.string(forKey: key), "3")
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
    }

    func testInventoryRejectsLinksAndUnsupportedFoldersWithoutFollowingThem() throws {
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Linked"), withDestinationURL: root)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(".Unsupported"), withIntermediateDirectories: true)
        let inventory = try service.inventory()
        XCTAssertFalse(inventory.isComplete)
        XCTAssertEqual(Set(inventory.rejectedNames), ["Linked", ".Unsupported"])
        XCTAssertEqual(Set(inventory.entries.keys), ["Read", "Read.logs"])
    }

    func testReviewedCopyTargetsOnlyExplicitOwnerAndKeepsOriginal() throws {
        try prepare()
        let preview = try service.preview(field: key)
        XCTAssertEqual(preview.text, "3"); XCTAssertEqual(preview.candidates.count, 2)
        XCTAssertTrue(preview.candidates.allSatisfy(\.canCopy))
        let chosen = try XCTUnwrap(preview.candidates.first { $0.owner.name == "Read.logs" })
        let other = try XCTUnwrap(preview.candidates.first { $0.owner.name == "Read" })
        try service.copy(preview, to: [chosen.id])
        XCTAssertEqual(defaults.string(forKey: chosen.owner.namespace + chosen.key), "3")
        XCTAssertNil(defaults.object(forKey: other.owner.namespace + other.key))
        XCTAssertEqual(defaults.string(forKey: key), "3")
        XCTAssertTrue(try service.fields().isEmpty)
    }

    func testSelectingBothOwnersCreatesIndependentCopies() throws {
        try prepare()
        let preview = try service.preview(field: key)
        try service.copy(preview, to: Set(preview.candidates.map(\.id)))
        let first = preview.candidates[0], second = preview.candidates[1]
        defaults.set("changed", forKey: first.owner.namespace + first.key)
        XCTAssertEqual(defaults.string(forKey: second.owner.namespace + second.key), "3")
        XCTAssertEqual(defaults.string(forKey: key), "3")
    }

    func testSourceAndDestinationChangesRequireFreshReview() throws {
        try prepare()
        var preview = try service.preview(field: key)
        let selected = try XCTUnwrap(preview.candidates.first)
        defaults.set("4", forKey: key)
        XCTAssertThrowsError(try service.copy(preview, to: [selected.id]))
        XCTAssertNil(defaults.object(forKey: selected.owner.namespace + selected.key))
        preview = try service.preview(field: key)
        defaults.set("new target", forKey: selected.owner.namespace + selected.key)
        XCTAssertThrowsError(try service.copy(preview, to: [selected.id]))
        XCTAssertEqual(defaults.string(forKey: selected.owner.namespace + selected.key), "new target")
        XCTAssertEqual(try service.fields().count, 1)
    }

    func testDirectoryOrOwnerRenameAfterPreviewPreventsAssignment() throws {
        try prepare()
        let preview = try service.preview(field: key)
        let chosen = try XCTUnwrap(preview.candidates.first { $0.owner.name == "Read" })
        try ScriptWidgetStorageNamespaces.rename(from: "Read", to: "Renamed", container: container, defaults: defaults)
        XCTAssertThrowsError(try service.copy(preview, to: [chosen.id]))
        XCTAssertNil(defaults.object(forKey: chosen.owner.namespace + chosen.key))
    }

    func testForeignLibraryCannotUseReviewFromOriginalEvenIfDirectoryWasMoved() throws {
        try prepare()
        let preview = try service.preview(field: key)
        let chosen = try XCTUnwrap(preview.candidates.first { $0.owner.name == "Read" })
        let foreignRoot = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library.appendingPathComponent("Read"), to: foreignRoot.appendingPathComponent("Read"))
        let foreignContext = try ScriptWidgetPackageStorageContext(libraryRoot: foreignRoot, container: container, defaults: defaults)
        let foreign = ScriptWidgetStorageUpgradeService(context: foreignContext, isUsingICloud: false)
        XCTAssertTrue(try foreign.fields().isEmpty)
        XCTAssertThrowsError(try foreign.copy(preview, to: [chosen.id]))
        XCTAssertNil(defaults.object(forKey: chosen.owner.namespace + chosen.key))
    }

    func testKeepOriginalWorksWhenValueCannotBePreviewedAndPreservesTargets() throws {
        try prepare()
        let field = try XCTUnwrap(service.fields().first)
        let original = Data(repeating: 7, count: ScriptWidgetStorageNamespaces.maximumLegacyValueBytes + 1)
        // Remove the small persisted value, then model an oversized legacy
        // source without submitting that payload to the preference daemon.
        defaults.removeObject(forKey: key)
        let provider = StorageReviewLargeValueDefaults(suite: suite, key: key, value: .data(original))
        let reviewedContext = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: provider)
        let review = ScriptWidgetStorageUpgradeService(context: reviewedContext, isUsingICloud: false)
        XCTAssertThrowsError(try review.preview(field: key))
        let reads = provider.simulatedReads
        try review.keepOriginal(field)
        XCTAssertEqual(provider.simulatedReads, reads, "Keeping originals must not read/fingerprint their payload")
        XCTAssertEqual(provider.simulatedMutations, 0, "Keeping originals must not write/remove their payload")
        XCTAssertTrue(try review.fields().isEmpty)
        XCTAssertEqual((provider.object(forKey: key) as? Data)?.count, original.count)
        XCTAssertThrowsError(try review.keepOriginal(field))
    }

    func testReviewTextIsBoundedAndRootReplacementIsRefused() throws {
        try prepare()
        defaults.set(String(repeating: "x", count: 2000), forKey: key)
        let preview = try service.preview(field: key)
        XCTAssertEqual(preview.text.utf8.count, 1024)
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("old-library"))
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.inventory())
        XCTAssertThrowsError(try service.copy(preview, to: [preview.candidates[0].id]))
    }

    @MainActor
    func testReviewModelClearsStaleSelectionAndAllowsExplicitKeep() throws {
        try prepare()
        let model = ScriptWidgetStorageUpgradeModel(service: service)
        let field = try XCTUnwrap(model.fields.first)
        model.show(field)
        let selected = try XCTUnwrap(model.preview?.candidates.first)
        model.selectedOwners = [selected.id]
        defaults.set("new value", forKey: key)
        model.copySelection()
        XCTAssertTrue(model.isError); XCTAssertNil(model.preview); XCTAssertTrue(model.selectedOwners.isEmpty)
        model.keep(field)
        XCTAssertFalse(model.isError); XCTAssertTrue(model.fields.isEmpty)
        XCTAssertEqual(defaults.string(forKey: key), "new value")
    }
}

extension NativeStorageReviewTests {
    func testInventoryIgnoresOrdinaryMetadataButRecognizesCloudPlaceholders() throws {
        try Data().write(to: library.appendingPathComponent(".DS_Store"))
        try Data("notes".utf8).write(to: library.appendingPathComponent("notes.txt"))
        XCTAssertTrue(try service.inventory().isComplete)
        try Data().write(to: library.appendingPathComponent(".Read.missing.icloud"))
        let inventory = try service.inventory()
        XCTAssertFalse(inventory.isComplete)
        XCTAssertTrue(inventory.rejectedNames.contains(".Read.missing.icloud"))
    }

    @MainActor
    func testExportNativeStorageReviewScreenshots() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_STORAGE_REVIEW"], !outputPath.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_STORAGE_REVIEW to export record review screens")
        }
        try prepare()
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = ScriptWidgetStorageUpgradeModel(service: service)
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true; previous?.makeKey() }
        for preview in [false, true] {
            if preview {
                model.show(try XCTUnwrap(model.fields.first))
                model.selectedOwners = [try XCTUnwrap(model.preview?.candidates.first).id]
            }
            let host = UIHostingController(rootView: ScriptWidgetStorageUpgradeView(model: model))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(preview ? "ios-review-preview.png" : "ios-review-list.png"), options: .atomic)
        }
        #elseif os(macOS)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for preview in [false, true] {
            if preview {
                model.show(try XCTUnwrap(model.fields.first))
                model.selectedOwners = [try XCTUnwrap(model.preview?.candidates.first).id]
            }
            let host = NSHostingController(rootView: ScriptWidgetStorageUpgradeView(model: model))
            window.contentViewController = host; window.setContentSize(NSSize(width: 640, height: 800)); window.orderBack(nil)
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(preview ? "mac-review-preview.png" : "mac-review-list.png"), options: .atomic)
        }
        #endif
    }
}

extension NativeStorageReviewTests {
    func testReviewRetainsFixedSizeFingerprintsForLargeExistingTargets() throws {
        try prepare()
        let state = try ScriptWidgetStorageNamespaces.reviewState(container: container, defaults: defaults)
        let owner = try XCTUnwrap(state.0.owners.first { $0.name == "Read" })
        let old = String(repeating: "x", count: 9 * 1024 * 1024)
        let provider = StorageReviewLargeValueDefaults(suite: suite, key: owner.namespace + "logs.count", value: .text(old))
        let reviewedContext = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: provider)
        let review = ScriptWidgetStorageUpgradeService(context: reviewedContext, isUsingICloud: false)
        let preview = try review.preview(field: key)
        XCTAssertEqual(preview.legacy.sourceFingerprint.count, 32)
        XCTAssertTrue(preview.legacy.targetFingerprints.values.allSatisfy { $0.count == 32 })
        let chosen = try XCTUnwrap(preview.candidates.first { $0.id == owner.id })
        try review.copy(preview, to: [chosen.id])
        XCTAssertEqual(defaults.string(forKey: owner.namespace + chosen.key), "3")
        XCTAssertEqual(defaults.string(forKey: key), "3")
    }
}

final class StorageCapacityStudyTests: XCTestCase {
    /// Opt-in measurement. A successful test means the study ran and wrote its
    /// report; the report's `passed` field is the capacity result.
    func testExportRealPreferenceCapacityStudy() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_STORAGE_CAPACITY_REPORT"], !outputPath.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_STORAGE_CAPACITY_REPORT to measure real preference capacity")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapacityStudy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.scriptwidget.capacity-study." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func residentBytes() -> UInt64? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size) / 4
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? info.resident_size : nil
        }
        func payload(_ owner: Int, _ key: Int) -> String {
            var state = UInt32(owner * 8 + key + 1), bytes = [UInt8]()
            bytes.reserveCapacity(ScriptWidgetAtomicPreferences.maximumValueBytes)
            for _ in 0..<ScriptWidgetAtomicPreferences.maximumValueBytes {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes.append(33 + UInt8((state >> 16) % 90))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let initialRSS = residentBytes()
        var times: [Double] = [], verified = 0, failure: String?
        var prefixes: [String] = []
        do {
            _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: root, defaults: preferences)
            for ownerIndex in 0..<4 {
                let owner = try ScriptWidgetStorageNamespaces.registerFresh(name: "Capacity-\(ownerIndex)", container: root, defaults: preferences)
                prefixes.append(owner.namespace)
                for keyIndex in 0..<8 {
                    let key = "value-\(keyIndex)", value = payload(ownerIndex, keyIndex)
                    let start = DispatchTime.now().uptimeNanoseconds
                    guard ScriptWidgetAtomicPreferences.compareAndSetString(container: root, defaults: preferences, namespace: owner.namespace,
                        key: key, expected: "", value: value, canStore: { store, replacement in
                            (try? ScriptWidgetStorageNamespaces.fitsBudget(namespace: owner.namespace, defaults: store, replacing: [key: replacement])) == true
                        }), preferences.synchronize(), preferences.data(forKey: ScriptWidgetStorageNamespaces.registryKey) != nil,
                          preferences.string(forKey: owner.namespace + key) == value else { throw ScriptWidgetStorageNamespaceError.invalidRegistry }
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    verified += 1
                }
            }
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            guard reopened.synchronize() else { throw ScriptWidgetStorageNamespaceError.unavailable }
            for (owner, prefix) in prefixes.enumerated() {
                for key in 0..<8 where reopened.string(forKey: prefix + "value-\(key)") != payload(owner, key) {
                    throw ScriptWidgetStorageNamespaceError.invalidRegistry
                }
            }
        } catch { failure = (error as? ScriptWidgetStorageNamespaceError).map { String(describing: $0) } ?? "unexpected" }
        let sorted = times.sorted()
        #if os(iOS)
        let platform = "iOS Simulator/test host"
        #else
        let platform = "macOS/test host"
        #endif
        var report: [String: Any] = ["platform": platform, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "passed": failure == nil, "failure": failure ?? "", "ownersRequested": 4, "keysPerOwner": 8,
            "bytesPerValue": ScriptWidgetAtomicPreferences.maximumValueBytes, "valuesVerified": verified,
            "payloadBytesVerified": verified * ScriptWidgetAtomicPreferences.maximumValueBytes,
            "p50Milliseconds": sorted.isEmpty ? 0 : sorted[(sorted.count - 1) / 2],
            "p95Milliseconds": sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
            "maximumMilliseconds": sorted.last ?? 0,
            "sameProcessReopenOnly": true, "signedAppGroup": false, "widgetExtension": false]
        report["initialResidentBytes"] = initialRSS
        report["finalResidentBytes"] = residentBytes()
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}

final class NativeStorageFileTests: XCTestCase {
    private var root: URL!
    private var owner: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        owner = UUID().uuidString.lowercased()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testNonemptyStoreWithoutVersionIsNotAdopted() throws {
        let directory = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: original)
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "preserve")
    }

    func testDirectoryCaseAliasCannotBecomeEmptyStore() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("RECORDS"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
    }

    func testLogicalPropertyListBudgetRejectsSharedReferenceExpansionBeforeReplacingFile() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        var initial = ScriptWidgetStorageFileMap(); initial["safe"] = "old"
        try store.commitNamespace(ownerID: owner, values: initial)
        var next = initial
        next["many"] = Array(repeating: Data(repeating: 1, count: 64 * 1024), count: 100)
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: next))
        XCTAssertNil(try store.readNamespace(ownerID: owner)["many"])
    }
}

extension NativeStorageFileTests {
    private var recordURL: URL {
        root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("records").appendingPathComponent(owner + ".bin")
    }

    func testTypedRoundTripAndByteExactUnicodeKeys() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        var values = ScriptWidgetStorageFileMap()
        values["text"] = "你好 🟢"; values["bytes"] = Data([0, 1, 255])
        values["date"] = Date(timeIntervalSince1970: 1_700_000_000)
        values["number"] = NSNumber(value: 12); values["bool"] = NSNumber(value: true)
        values["nested"] = ["items": ["a", "b"]]
        values["é"] = "NFC"; values["e\u{301}"] = "NFD"
        try store.commitNamespace(ownerID: owner, values: values)
        let reopened = try ScriptWidgetStorageFiles(container: root).readNamespace(ownerID: owner)
        XCTAssertEqual(reopened.count, 8)
        XCTAssertEqual(reopened["text"] as? String, "你好 🟢")
        XCTAssertEqual(reopened["bytes"] as? Data, Data([0, 1, 255]))
        XCTAssertEqual(reopened["date"] as? Date, values["date"] as? Date)
        XCTAssertEqual(reopened["number"] as? NSNumber, 12)
        XCTAssertEqual(reopened["bool"] as? NSNumber, true)
        XCTAssertEqual(reopened["nested"] as? [String: [String]], ["items": ["a", "b"]])
        XCTAssertEqual(reopened["é"] as? String, "NFC")
        XCTAssertEqual(reopened["e\u{301}"] as? String, "NFD")
        XCTAssertEqual(try store.readNamespace(ownerID: UUID().uuidString.lowercased()).count, 0)
    }

    func testTransactionFalseAndThrownErrorPreserveAllKeys() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        XCTAssertTrue(try store.transaction(ownerID: owner) { values in
            values["history"] = "before"; values["config"] = "old"; return true
        })
        let before = try Data(contentsOf: recordURL)
        XCTAssertFalse(try store.transaction(ownerID: owner) { values in
            values["history"] = "after"; values["config"] = nil; return false
        })
        XCTAssertEqual(try Data(contentsOf: recordURL), before)
        XCTAssertThrowsError(try store.transaction(ownerID: owner) { values in
            values["history"] = "after"; throw ScriptWidgetStorageFileError.unavailable
        })
        XCTAssertEqual(try Data(contentsOf: recordURL), before)
        XCTAssertTrue(try store.transaction(ownerID: owner) { values in
            values["history"] = "after"; values["config"] = "new"; return true
        })
        let result = try store.readNamespace(ownerID: owner)
        XCTAssertEqual(result["history"] as? String, "after")
        XCTAssertEqual(result["config"] as? String, "new")
    }

    func testNamespaceLimitsRejectWithoutReplacingPreviousFile() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        var initial = ScriptWidgetStorageFileMap(); initial["safe"] = "old"
        try store.commitNamespace(ownerID: owner, values: initial)
        let before = try Data(contentsOf: recordURL)
        var next = initial; next["large"] = String(repeating: "x", count: ScriptWidgetAtomicPreferences.maximumValueBytes + 1)
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: next))
        next = initial; next[String(repeating: "x", count: 257)] = "x"
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: next))
        next = initial
        for index in 0..<1024 { next["key-\(index)"] = "x" }
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: next))
        next = .init()
        for index in 0..<9 { next["key-\(index)"] = Data(repeating: 1, count: ScriptWidgetAtomicPreferences.maximumValueBytes) }
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: next))
        XCTAssertEqual(try Data(contentsOf: recordURL), before)
        for invalid in ["../escape", owner.uppercased(), "not-a-uuid", ""] {
            XCTAssertThrowsError(try store.readNamespace(ownerID: invalid))
            XCTAssertThrowsError(try store.commitNamespace(ownerID: invalid, values: initial))
        }
    }

    func testPresentCorruptRecordsNeverBecomeEmpty() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        var initial = ScriptWidgetStorageFileMap(); initial["key"] = "value"
        try store.commitNamespace(ownerID: owner, values: initial)
        let valid = try Data(contentsOf: recordURL)
        var wrongMagic = valid; wrongMagic[0] = 0
        var wrongOwner = valid; wrongOwner[8] = wrongOwner[8] == 97 ? 98 : 97
        var wrongType = valid; wrongType[50] = 255
        var trailing = valid; trailing.append(0)
        for invalid in [Data(), valid.prefix(47), wrongMagic, wrongOwner, wrongType, trailing] {
            try invalid.write(to: recordURL, options: .atomic)
            XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
            XCTAssertThrowsError(try store.transaction(ownerID: owner) { values in values["new"] = "value"; return true })
            XCTAssertEqual(try Data(contentsOf: recordURL), invalid)
        }
    }

    func testLinksAndFIFOAreRejectedForReadsAndReplacement() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        var initial = ScriptWidgetStorageFileMap(); initial["key"] = "value"
        try store.commitNamespace(ownerID: owner, values: initial)
        let outside = root.appendingPathComponent("preserve")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.removeItem(at: recordURL)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: outside)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: initial))
        try FileManager.default.removeItem(at: recordURL)
        XCTAssertEqual(link(outside.path, recordURL.path), 0)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: initial))
        try FileManager.default.removeItem(at: recordURL)
        XCTAssertEqual(mkfifo(recordURL.path, 0o600), 0)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
        XCTAssertThrowsError(try store.commitNamespace(ownerID: owner, values: initial))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
    }

    func testMetadataRoundTripBoundsAndCompletedJournalRemoval() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        let key = "ScriptWidgetStorage.TestJournal.v2"
        let original = Data(repeating: 10, count: ScriptWidgetStorageNamespaces.maximumRegistryBytes)
        XCTAssertNil(try store.readMetadata(key: key))
        try store.writeMetadata(key: key, data: original)
        XCTAssertEqual(try ScriptWidgetStorageFiles(container: root).readMetadata(key: key), original)
        XCTAssertThrowsError(try store.writeMetadata(key: key, data: Data(count: original.count + 1)))
        XCTAssertEqual(try store.readMetadata(key: key), original)
        XCTAssertThrowsError(try store.writeMetadata(key: "", data: Data()))
        XCTAssertThrowsError(try store.readMetadata(key: String(repeating: "x", count: 257)))
        try store.removeMetadata(key: key)
        XCTAssertNil(try store.readMetadata(key: key))
        try store.removeMetadata(key: key)
    }

    func testMetadataCorruptionIsPreservedDuringRemoval() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        let key = "journal"
        try store.writeMetadata(key: key, data: Data("original".utf8))
        let directory = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("metadata")
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.readMetadata(key: key))
        XCTAssertThrowsError(try store.removeMetadata(key: key))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testReplacedContainerAndInvalidVersionAreRejected() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        let marker = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("version")
        try Data("wrong-version".utf8).write(to: marker, options: .atomic)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root))
        let moved = root.deletingLastPathComponent().appendingPathComponent("Replaced-" + UUID().uuidString)
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
    }
}

extension StorageCapacityStudyTests {
    func testExportRealFileCapacityStudy() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_STORAGE_FILE_CAPACITY_REPORT"], !outputPath.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_STORAGE_FILE_CAPACITY_REPORT to measure native file capacity")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileCapacityStudy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func payload(_ owner: Int, _ key: Int) -> String {
            var state = UInt32(owner * 8 + key + 1), bytes = [UInt8]()
            bytes.reserveCapacity(ScriptWidgetAtomicPreferences.maximumValueBytes)
            for _ in 0..<ScriptWidgetAtomicPreferences.maximumValueBytes {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes.append(33 + UInt8((state >> 16) % 90))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        var times: [Double] = [], verified = 0, failure: Error?
        do {
            let suite = "app.scriptwidget.file-capacity-study." + UUID().uuidString
            let legacy = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { legacy.removePersistentDomain(forName: suite) }
            let backend = try ScriptWidgetFileStorageBackend(container: root, legacy: legacy)
            _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: root, defaults: backend)
            let owners = try (0..<4).map { try ScriptWidgetStorageNamespaces.registerFresh(name: "Capacity-\($0)", container: root, defaults: backend).namespace }
            for (ownerIndex, owner) in owners.enumerated() {
                for keyIndex in 0..<8 {
                    let value = payload(ownerIndex, keyIndex), key = "value-\(keyIndex)"
                    let start = DispatchTime.now().uptimeNanoseconds
                    guard ScriptWidgetAtomicPreferences.compareAndSetString(container: root, defaults: backend, namespace: owner,
                        key: key, expected: "", value: value, canStore: { staged, replacement in
                            (try? ScriptWidgetStorageNamespaces.fitsBudget(namespace: owner, defaults: staged, replacing: [key: replacement])) == true
                        }), try backend.readValue(forKey: owner + key) as? String == value else { throw ScriptWidgetStorageFileError.invalidData }
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    verified += 1
                }
            }
            let reopened = try ScriptWidgetFileStorageBackend(container: root, legacy: legacy)
            for (ownerIndex, owner) in owners.enumerated() {
                guard try ScriptWidgetStorageNamespaces.namespace(for: "Capacity-\(ownerIndex)", container: root, defaults: reopened) == owner else { throw ScriptWidgetStorageFileError.invalidData }
                for keyIndex in 0..<8 {
                    guard try reopened.readValue(forKey: owner + "value-\(keyIndex)") as? String == payload(ownerIndex, keyIndex) else { throw ScriptWidgetStorageFileError.invalidData }
                }
            }
            XCTAssertNil(legacy.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
            XCTAssertTrue(legacy.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("ScriptWidgetStorage.v2:") })
        } catch { failure = error }
        let sorted = times.sorted()
        let report: [String: Any] = ["backend": "native-files+identity-coordinator", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "passed": failure == nil, "failure": failure.map { String(describing: type(of: $0)) } ?? "",
            "ownersRequested": 4, "keysPerOwner": 8, "bytesPerValue": ScriptWidgetAtomicPreferences.maximumValueBytes,
            "valuesVerified": verified, "payloadBytesVerified": verified * ScriptWidgetAtomicPreferences.maximumValueBytes,
            "p50Milliseconds": sorted.isEmpty ? 0 : sorted[(sorted.count - 1) / 2],
            "p95Milliseconds": sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
            "maximumMilliseconds": sorted.last ?? 0,
            "sameProcessReopenOnly": true, "signedAppGroup": false, "widgetExtension": false, "productionCutover": false]
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        if let failure { throw failure }
        XCTAssertEqual(verified, 32)
    }
}

extension NativeStorageFileTests {
    func testFileMigrationAmbiguityRequiresExplicitCopyAndPreservesOriginal() throws {
        let suite = "app.scriptwidget.file-migration-test." + UUID().uuidString
        let legacy = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { legacy.removePersistentDomain(forName: suite) }
        let key = "script.Foo.Bar.value"
        legacy.set("original", forKey: key)
        let backend = try ScriptWidgetFileStorageBackend(container: root, legacy: legacy)
        let index = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: ["Foo", "Foo.Bar"], inventoryIsComplete: true, container: root, defaults: backend)
        let parent = try XCTUnwrap(index.owners.first { $0.name == "Foo" })
        let child = try XCTUnwrap(index.owners.first { $0.name == "Foo.Bar" })
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.namespace(for: "Foo", container: root, defaults: backend))
        let preview = try ScriptWidgetStorageNamespaces.preview(field: key, container: root, defaults: backend)
        try ScriptWidgetStorageNamespaces.resolve(preview, to: [child.id], container: root, defaults: backend)
        XCTAssertEqual(try backend.readValue(forKey: child.namespace + "value") as? String, "original")
        XCTAssertNil(try backend.readValue(forKey: parent.namespace + "Bar.value"))
        XCTAssertEqual(legacy.string(forKey: key), "original")
        XCTAssertNil(legacy.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
        XCTAssertEqual(try ScriptWidgetStorageNamespaces.namespace(for: "Foo.Bar", container: root, defaults: backend), child.namespace)
    }
}

private final class ReadOnlyLegacyDefaults: UserDefaults, @unchecked Sendable {
    override func synchronize() -> Bool { false }
}

final class NativeStorageProfileTests: XCTestCase {
    private var root: URL!, first: URL!, second: URL!, container: URL!, cache: URL!
    private var suite: String!, legacy: UserDefaults!, service: ScriptWidgetStorageProfiles!
    private enum Interrupted: Error { case requested }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageProfiles-" + UUID().uuidString)
        first = root.appendingPathComponent("first"); second = root.appendingPathComponent("second")
        container = root.appendingPathComponent("container"); cache = root.appendingPathComponent("cache")
        for url in [first!, second!, container!, cache!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        suite = "app.scriptwidget.profiles-test." + UUID().uuidString
        legacy = try XCTUnwrap(UserDefaults(suiteName: suite))
        service = try ScriptWidgetStorageProfiles(container: container, legacy: legacy)
        try widget(first); try widget(second)
    }
    override func tearDownWithError() throws {
        legacy.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func widget(_ library: URL, name: String = "Read") throws {
        let directory = library.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("$render(<text>ready</text>);".utf8).write(to: directory.appendingPathComponent("main.jsx"))
    }
    private func snapshot(_ context: ScriptWidgetPackageStorageContext, name: String = "Read") throws -> ScriptWidgetExecutionSnapshot {
        try ScriptWidgetExecutionSnapshot(name: name, role: .source, context: context)
    }
    private func set(_ value: String, context: ScriptWidgetPackageStorageContext, key: String = "count") throws {
        let prefix = try snapshot(context).storageNamespace
        XCTAssertTrue(ScriptWidgetAtomicPreferences.mutate(container: container, defaults: context.defaults, namespace: prefix) { staged in
            try context.validateLibraryRoot()
            try staged.writeValue(value, forKey: prefix + key); return true
        })
    }

    func testApplicationOpenAndFileRecordsDoNotRequireLegacyPreferencesSynchronization() throws {
        legacy.set("7", forKey: "script.Read.count")
        let readOnlyLegacy = try XCTUnwrap(ReadOnlyLegacyDefaults(suiteName: suite))
        XCTAssertFalse(readOnlyLegacy.synchronize())
        let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: readOnlyLegacy)
        let application = ScriptWidgetApplicationLibraryService(profiles: profiles, initialRoot: first,
            initialIsUsingICloud: false, alternatives: [])
        let opened = try application.open()
        let context = try XCTUnwrap(opened.sourceManager?.storageContext)
        let captured = try snapshot(context)
        XCTAssertEqual(try context.defaults.readValue(forKey: captured.storageNamespace + "count") as? String, "7")
        try set("8", context: context)
        let reopened = try application.open()
        XCTAssertEqual(opened.selection, reopened.selection)
        let reopenedContext = try XCTUnwrap(reopened.sourceManager?.storageContext)
        XCTAssertEqual(try reopenedContext.defaults.readValue(forKey: captured.storageNamespace + "count") as? String, "8")
        XCTAssertEqual(readOnlyLegacy.string(forKey: "script.Read.count"), "7")
        XCTAssertNil(readOnlyLegacy.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
    }

    func testInitialActivationMigratesOnlyInventoriedRecordsAndPreservesOriginals() throws {
        legacy.set("7", forKey: "script.Read.count")
        XCTAssertTrue(service.legacyAccessAllowed())
        let context = try service.activate(root: first, isUsingICloud: false)
        let captured = try snapshot(context)
        XCTAssertEqual(try context.defaults.readValue(forKey: captured.storageNamespace + "count") as? String, "7")
        XCTAssertEqual(legacy.string(forKey: "script.Read.count"), "7")
        XCTAssertNil(legacy.object(forKey: ScriptWidgetStorageNamespaces.registryKey))
        XCTAssertFalse(service.legacyAccessAllowed())
        XCTAssertEqual(try service.profiles().count, 1)
        let reopened = try ScriptWidgetStorageProfiles(container: container, legacy: legacy)
        XCTAssertEqual(try snapshot(reopened.currentContext()).storageNamespace, captured.storageNamespace)
    }

    func testIdenticalNamesInDifferentLibrariesAreIsolatedAndOldActivationNeverResumes() throws {
        legacy.set("7", forKey: "script.Read.count")
        let a = try service.activate(root: first, isUsingICloud: false)
        let original = try snapshot(a)
        try set("12", context: a)
        let b = try service.activate(root: second, isUsingICloud: false, allowSwitch: true)
        let other = try snapshot(b)
        XCTAssertNotEqual(other.storageNamespace, original.storageNamespace)
        XCTAssertNil(try b.defaults.readValue(forKey: other.storageNamespace + "count"))
        XCTAssertThrowsError(try original.validateIdentity())
        try set("23", context: b)
        let restored = try service.activate(root: first, isUsingICloud: false, allowSwitch: true)
        XCTAssertEqual(try snapshot(restored).storageNamespace, original.storageNamespace)
        XCTAssertEqual(try restored.defaults.readValue(forKey: original.storageNamespace + "count") as? String, "12")
        XCTAssertThrowsError(try original.validateIdentity(), "An execution invalidated by a switch must not revive on return")
        XCTAssertThrowsError(try other.validateIdentity())
        XCTAssertEqual(try b.defaults.readValue(forKey: other.storageNamespace + "count") as? String, "23", "Native recovery retains the inactive library's records")
        XCTAssertEqual(legacy.string(forKey: "script.Read.count"), "7")
    }

    func testImplicitLibrarySwitchIsRejectedBeforeChangingActiveState() throws {
        let a = try service.activate(root: first, isUsingICloud: false)
        let captured = try snapshot(a)
        XCTAssertThrowsError(try service.activate(root: second, isUsingICloud: false))
        XCTAssertNoThrow(try captured.validateIdentity())
        XCTAssertEqual(try service.profiles().count, 1)
    }

    func testPreparingStateFreezesOldContextsAndRetryKeepsTheOriginalOwner() throws {
        let a = try service.activate(root: first, isUsingICloud: false)
        let captured = try snapshot(a)
        try set("kept", context: a)
        XCTAssertThrowsError(try service.activate(root: first, isUsingICloud: false) { step in
            if step == "planned" { throw Interrupted.requested }
        })
        XCTAssertFalse(service.legacyAccessAllowed())
        XCTAssertThrowsError(try service.currentContext())
        XCTAssertThrowsError(try captured.validateIdentity())
        let resumed = try ScriptWidgetStorageProfiles(container: container, legacy: legacy).activate(root: first, isUsingICloud: false)
        XCTAssertEqual(try snapshot(resumed).storageNamespace, captured.storageNamespace)
        XCTAssertEqual(try resumed.defaults.readValue(forKey: captured.storageNamespace + "count") as? String, "kept")
        XCTAssertThrowsError(try captured.validateIdentity())
    }

    func testDirectoryReplacementDuringInterruptedInitialInventoryGetsFreshRecords() throws {
        legacy.set("old", forKey: "script.Read.count")
        XCTAssertThrowsError(try service.activate(root: first, isUsingICloud: false) { step in
            if step == "inventory" { throw Interrupted.requested }
        })
        try FileManager.default.moveItem(at: first.appendingPathComponent("Read"), to: root.appendingPathComponent("original-read"))
        try widget(first)
        let context = try service.activate(root: first, isUsingICloud: false)
        let captured = try snapshot(context)
        XCTAssertNil(try context.defaults.readValue(forKey: captured.storageNamespace + "count"))
        let state = try ScriptWidgetStorageNamespaces.reviewState(container: container, defaults: context.defaults)
        let old = try XCTUnwrap(state.0.owners.first { !$0.active && $0.name == "Read" })
        XCTAssertNotEqual(old.id, captured.binding.ownerID)
        XCTAssertEqual(try context.defaults.readValue(forKey: old.namespace + "count") as? String, "old")
        XCTAssertEqual(legacy.string(forKey: "script.Read.count"), "old")
    }

    func testNewSyncedDirectoryIsAdoptedWithoutClaimingLegacyRecords() throws {
        let firstContext = try service.activate(root: first, isUsingICloud: true)
        let initial = try snapshot(firstContext)
        legacy.set("unassigned", forKey: "script.New.count")
        try widget(first, name: "New")
        let context = try service.activate(root: first, isUsingICloud: true)
        let new = try snapshot(context, name: "New")
        XCTAssertNil(try context.defaults.readValue(forKey: new.storageNamespace + "count"))
        XCTAssertEqual(try snapshot(context).storageNamespace, initial.storageNamespace)
        XCTAssertEqual(legacy.string(forKey: "script.New.count"), "unassigned")
    }

    func testCacheContextsInheritActivationRevocation() throws {
        let source = try service.activate(root: first, isUsingICloud: false)
        let copied = try source.contextForCacheRoot(cache)
        let reopened = try service.currentContext(cacheRoot: cache)
        XCTAssertNoThrow(try copied.validateLibraryRoot())
        XCTAssertNoThrow(try reopened.validateLibraryRoot())
        _ = try service.activate(root: second, isUsingICloud: false, allowSwitch: true)
        XCTAssertThrowsError(try copied.validateLibraryRoot())
        XCTAssertThrowsError(try reopened.validateLibraryRoot())
    }

    func testMalformedProfileIndexIsPreservedAndNeverAllowsLegacyFallback() throws {
        _ = try service.activate(root: first, isUsingICloud: false)
        let files = try ScriptWidgetStorageFiles(container: container)
        let saved = try XCTUnwrap(files.readMetadata(key: ScriptWidgetStorageProfiles.indexKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object["untrusted"] = "ignored fields must fail"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        try files.writeMetadata(key: ScriptWidgetStorageProfiles.indexKey, data: invalid)
        XCTAssertFalse(service.legacyAccessAllowed())
        XCTAssertThrowsError(try service.currentContext())
        XCTAssertThrowsError(try service.activate(root: first, isUsingICloud: false))
        XCTAssertEqual(try files.readMetadata(key: ScriptWidgetStorageProfiles.indexKey), invalid)
    }

    func testMissingProfileStorageIsNotRecreatedAsAnEmptyIdentityIndex() throws {
        let context = try service.activate(root: first, isUsingICloud: false)
        let captured = try snapshot(context)
        try set("keep", context: context)
        let profile = try XCTUnwrap(service.profiles().first)
        let directory = container.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("profiles")
            .appendingPathComponent(profile.id).appendingPathComponent(ScriptWidgetStorageFiles.directoryName)
        let backup = root.appendingPathComponent("preserved-store")
        try FileManager.default.moveItem(at: directory, to: backup)
        XCTAssertThrowsError(try captured.validateIdentity())
        XCTAssertThrowsError(try service.currentContext())
        XCTAssertThrowsError(try service.activate(root: first, isUsingICloud: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testCompetingActivationWorkerFailsWithoutChangingTheJournal() throws {
        var competed = false
        let context = try service.activate(root: first, isUsingICloud: false) { step in
            if step == "inventory" {
                competed = true
                XCTAssertThrowsError(try self.service.activate(root: second!, isUsingICloud: false, allowSwitch: true))
            }
        }
        XCTAssertTrue(competed)
        XCTAssertEqual(context.libraryRoot.path, first.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(try service.profiles().count, 1)
    }
}

extension NativeStorageFileTests {
    func testStoreDirectoryReplacementAndAnchorLossNeverBecomeAnEmptyStore() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        var initial = ScriptWidgetStorageFileMap(); initial["kept"] = "record"
        try store.commitNamespace(ownerID: owner, values: initial)
        let directory = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName)
        let moved = root.appendingPathComponent("preserved-original")
        try FileManager.default.moveItem(at: directory, to: moved)
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".ScriptWidgetStorage.v2.anchor"))
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root))
        XCTAssertEqual(try Data(contentsOf: recordURL).isEmpty, false)
    }
}

extension NativeStorageProfileTests {
    func testInterruptedAdoptionBetweenIndexAndBindingKeepsItsJournaledUUID() throws {
        legacy.set("unrelated", forKey: "script.New.count")
        let original = try service.activate(root: first, isUsingICloud: false)
        let backend = try XCTUnwrap(original.defaults as? ScriptWidgetFileStorageBackend)
        let profile = try XCTUnwrap(service.profiles().first)
        try widget(first, name: "New")
        let hash = SHA256.hash(data: Data(ScriptWidgetStorageNamespaces.directoriesKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = container.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("profiles").appendingPathComponent(profile.id)
            .appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("metadata").appendingPathComponent(hash + ".bin")
        let saved = try Data(contentsOf: target)
        let outside = root.appendingPathComponent("preserve-outside")
        try Data("untouched".utf8).write(to: outside)
        XCTAssertThrowsError(try service.activate(root: first, isUsingICloud: false) { step in
            if step == "planned" {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }
        })
        let rawJournal = try XCTUnwrap(backend.files.readMetadata(key: "ScriptWidgetStorage.LibraryInventory.v1"))
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: rawJournal) as? [String: Any])
        let planned = try XCTUnwrap((journal["plans"] as? [[String: Any]])?.first { $0["name"] as? String == "New" }?["ownerID"] as? String)
        let indexData = try XCTUnwrap(backend.readValue(forKey: ScriptWidgetStorageNamespaces.registryKey) as? Data)
        let intermediate = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: indexData)
        XCTAssertEqual(intermediate.owners.first { $0.active && $0.name == "New" }?.id, planned)
        XCTAssertThrowsError(try service.currentContext())
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target, options: .atomic)
        let resumed = try service.activate(root: first, isUsingICloud: false)
        let next = try snapshot(resumed, name: "New")
        XCTAssertEqual(next.binding.ownerID, planned)
        XCTAssertNil(try resumed.defaults.readValue(forKey: next.storageNamespace + "count"))
        let final = try ScriptWidgetStorageNamespaces.reviewState(container: container, defaults: resumed.defaults)
        XCTAssertEqual(final.0.owners.filter { $0.name == "New" }.count, 1)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }

    func testReappearingRetiredDirectoryDoesNotReuseACompletedAdoptionPlan() throws {
        _ = try service.activate(root: first, isUsingICloud: false)
        try widget(first, name: "New")
        let original = try service.activate(root: first, isUsingICloud: false)
        let captured = try snapshot(original, name: "New")
        try original.defaults.writeValue("old", forKey: captured.storageNamespace + "count")
        // Simulate a retired source reappearing with its original receipt.
        try ScriptWidgetStorageNamespaces.retire(name: "New", container: container, defaults: original.defaults)
        let resumed = try service.activate(root: first, isUsingICloud: false)
        let fresh = try snapshot(resumed, name: "New")
        XCTAssertNotEqual(fresh.binding.ownerID, captured.binding.ownerID)
        XCTAssertNil(try resumed.defaults.readValue(forKey: fresh.storageNamespace + "count"))
        XCTAssertEqual(try resumed.defaults.readValue(forKey: captured.storageNamespace + "count") as? String, "old")
    }
}

final class PreviewStorageBackendTests: XCTestCase {
    func testRejectedTransactionRestoresAllFieldsAndRejectsOtherNamespaces() throws {
        let namespace = "script.Preview."
        let memory = ScriptWidgetPreviewStorageBackend(namespace: namespace)
        try memory.writeValue("old", forKey: namespace + "config")
        XCTAssertFalse(try memory.mutateValues(in: namespace) { values in
            try values.writeValue("new", forKey: namespace + "config"); return false
        })
        XCTAssertEqual(try memory.readValue(forKey: namespace + "config") as? String, "old")
        XCTAssertThrowsError(try memory.mutateValues(in: namespace) { values in
            try values.writeValue("new", forKey: namespace + "config")
            try values.writeValue(Data(count: ScriptWidgetAtomicPreferences.maximumValueBytes + 1), forKey: namespace + "history")
            return true
        })
        XCTAssertEqual(try memory.readValue(forKey: namespace + "config") as? String, "old")
        XCTAssertNil(try memory.readValue(forKey: namespace + "history"))
        XCTAssertThrowsError(try memory.readValue(forKey: "script.Other.secret"))
        XCTAssertThrowsError(try memory.writeValue("value", forKey: "script.Other.key"))
        XCTAssertThrowsError(try memory.values(in: "script.Other."))
    }

    func testOnlyPreviewBackendCanUseCASWithoutAContainerLock() throws {
        let memory = ScriptWidgetPreviewStorageBackend(namespace: "script.Preview.")
        XCTAssertTrue(ScriptWidgetAtomicPreferences.compareAndSetString(container: nil, defaults: memory, namespace: "script.Preview.", key: "count", expected: "", value: "1"))
        XCTAssertFalse(ScriptWidgetAtomicPreferences.compareAndSetString(container: nil, defaults: memory, namespace: "script.Preview.", key: "count", expected: "", value: "2"))
        let suite = "app.scriptwidget.preview-no-lock." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ScriptWidgetAtomicPreferences.compareAndSetString(container: nil, defaults: preferences, namespace: "script.Legacy.", key: "count", expected: "", value: "1"))
        XCTAssertNil(preferences.object(forKey: "script.Legacy.count"))
    }
}

#if os(macOS)
final class LegacyCutoverProcessTests: XCTestCase {
    func testIndependentLegacyWriterStopsBeforeMigrationAndCannotRestartAfterReady() throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageGateProcess-" + id)
        let container = root.appendingPathComponent("container"), library = root.appendingPathComponent("library")
        for url in [container, library.appendingPathComponent("Read")] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let suite = "app.scriptwidget.cutover-process." + id
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var children: [Process] = []
        defer {
            for child in children where child.isRunning {
                child.terminate()
                let deadline = Date().addingTimeInterval(2)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("$render(<text>ready</text>);".utf8).write(to: library.appendingPathComponent("Read/main.jsx"))
        func child(report: String) throws -> Process {
            let process = Process()
            process.executableURL = try XCTUnwrap(Bundle.main.executableURL)
            process.arguments = ["-storage-cutover-probe", "write", root.path, suite, report]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !key.hasPrefix("XCTest") && !key.hasPrefix("XCInject") && key != "DYLD_INSERT_LIBRARIES"
            }
            try process.run(); children.append(process)
            return process
        }
        func waitFor(_ file: String, process: Process) throws {
            let deadline = Date().addingTimeInterval(8)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) && process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) else {
                XCTFail("Independent native host did not produce its bounded fixture report")
                throw ScriptWidgetStorageNamespaceError.unavailable
            }
        }
        func waitForExit(_ process: Process) throws {
            let deadline = Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard !process.isRunning else { throw ScriptWidgetStorageNamespaceError.unavailable }
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let writer = try child(report: "writer.json")
        try waitFor("writer-started", process: writer)
        let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: defaults)
        let context = try profiles.activate(root: library, isUsingICloud: false) { step in
            if step == "preparing" { try waitFor("writer.json", process: writer) }
        }
        try waitForExit(writer)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("writer.json"))) as? [String: Any])
        let completed = try XCTUnwrap(report["completedWrites"] as? Int)
        XCTAssertGreaterThan(completed, 0); XCTAssertEqual(report["blocked"] as? Bool, true)
        let snapshot = try ScriptWidgetExecutionSnapshot(name: "Read", role: .source, context: context)
        XCTAssertEqual(try context.defaults.readValue(forKey: snapshot.storageNamespace + "count") as? String, String(completed))
        XCTAssertEqual(try context.defaults.readValue(forKey: snapshot.storageNamespace + "mirror") as? String, String(completed))
        let restarted = try child(report: "stopped.json")
        try waitFor("stopped.json", process: restarted)
        try waitForExit(restarted)
        let stopped = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("stopped.json"))) as? [String: Any])
        XCTAssertEqual(stopped["completedWrites"] as? Int, 0); XCTAssertEqual(stopped["blocked"] as? Bool, true)
        _ = defaults.synchronize()
        XCTAssertEqual(defaults.string(forKey: "script.Read.count"), String(completed))
        XCTAssertEqual(defaults.string(forKey: "script.Read.mirror"), String(completed))
    }
}
#endif


#if os(iOS)
final class ScriptWidgetLauncherDeepLinkTests: XCTestCase {
    @MainActor
    func testHostlessExternalLinksReachSystemAndUnavailableHandlersReportFailure() throws {
        var opened:[URL]=[],accepted:[Bool]=[]
        let opener:DeepLinkManager.Opener={url,completion in opened.append(url);completion(false)}
        for raw in ["mailto:hello@example.com","tel:+1234567","shortcuts://run-shortcut?name=Example"] {
            DeepLinkManager.openDeepLink(url:try XCTUnwrap(URL(string:raw)),open:opener,completion:{accepted.append($0)})
        }
        XCTAssertEqual(opened.count,3);XCTAssertEqual(accepted,[false,false,false])
        for raw in ["widget-deeplink://default","scriptwidget://import","SCRIPTWIDGET://open"] {
            DeepLinkManager.openDeepLink(url:try XCTUnwrap(URL(string:raw)),open:opener,completion:{_ in XCTFail("Internal links must not be forwarded")})
        }
        XCTAssertEqual(opened.count,3)
    }
}
#endif

#if os(iOS)
@available(iOS 16.2,*)
@MainActor
private final class LocalActivityHarness {
    var rows:[ScriptLiveActivityRow]=[]
    var supported=true,enabled=true,foreground=true
    var requests=0,updates=0,ends=0
    var denyRequest=false,pauseUpdate=false,removeOnUpdate=false
    var pending:CheckedContinuation<Void,Never>?
    var updateStarted:(()->Void)?
    var binding=ScriptWidgetLiveActivityBinding(profileID:"00000000-0000-4000-8000-000000000001",ownerID:"00000000-0000-4000-8000-000000000002")
    var bindingError:ScriptWidgetLiveActivityBindingError?
    let clock=Date(timeIntervalSince1970:1767269700)
    func manager()->ScriptLiveActivityManager {
        let client=ScriptLiveActivityClient(supported:{self.supported},enabled:{self.enabled},foreground:{self.foreground},list:{self.rows},request:{attributes,state,stale in
            if self.denyRequest { throw ScriptLiveActivityFailure.systemRefused }
            self.requests+=1;let id="local-\(self.requests)"
            self.rows.append(.init(id:id,attributes:attributes,state:state,status:"active",staleDate:stale));return id
        },update:{id,state,stale in
            self.updates+=1
            if self.pauseUpdate { await withCheckedContinuation{self.pending=$0;self.updateStarted?()} }
            if self.removeOnUpdate {self.rows.removeAll{$0.id==id};return}
            if let index=self.rows.firstIndex(where:{$0.id==id}) {self.rows[index] = .init(id:id,attributes:self.rows[index].attributes,state:state,status:"active",staleDate:stale)}
        },end:{id,_,_ in self.ends+=1;self.rows.removeAll{$0.id==id}})
        return ScriptLiveActivityManager(client:client,prepare:{name in(self.binding,name)},currentName:{_ in if let error=self.bindingError{throw error};return "Current installation"},now:{self.clock},observeSystem:false)
    }
}

@available(iOS 16.2,*)
@MainActor
final class ScriptWidgetLocalLiveActivityTests:XCTestCase {
    private func check(_ value:Bool,expected:Bool,file:StaticString=#filePath,line:UInt=#line) { XCTAssertEqual(value,expected,file:file,line:line) }

    func testCreateReopenUpdateAndEndUseSystemListWithoutSavedIDGuessing() async throws {
        let h=LocalActivityHarness(),first=h.manager()
        let id=try XCTUnwrap(first.create(scriptName:"Focus",scriptParameter:"parameter",initialState:"started"))
        XCTAssertEqual(first.activities.count,1)
        let reopened=h.manager();XCTAssertEqual(reopened.activities.first?.id,id)
        let stale=h.clock.addingTimeInterval(900)
        let before=try XCTUnwrap(reopened.activities.first?.state)
        check(await reopened.update(activityID:id,state:"updated",staleDate:stale,expectedState:before),expected:true)
        XCTAssertEqual(h.rows.first?.state.scriptState,"updated");XCTAssertEqual(h.rows.first?.staleDate,stale)
        check(await reopened.dismiss(activityID:id),expected:true);XCTAssertTrue(reopened.activities.isEmpty)
        check(await reopened.update(activityID:id,state:"late"),expected:false);XCTAssertEqual(h.updates,1)
    }

    func testPayloadBudgetCountsAttributesAndJSONEscapingAndPreservesLegacyDecode() throws {
        let h=LocalActivityHarness(),manager=h.manager()
        XCTAssertTrue(ScriptLiveActivityManager.isValidState(String(repeating:"a",count:4096)))
        XCTAssertFalse(ScriptLiveActivityManager.isValidState(String(repeating:"a",count:4097)))
        XCTAssertNil(manager.create(scriptName:"Focus",scriptParameter:"",initialState:String(repeating:"a",count:4096)))
        XCTAssertNil(manager.create(scriptName:"Focus",scriptParameter:"",initialState:String(repeating:"\"",count:2000)))
        XCTAssertEqual(h.requests,0)
        let legacy=try JSONDecoder().decode(ScriptLiveActivityAttributes.self,from:Data(#"{"scriptName":"Focus","scriptParameter":""}"#.utf8))
        XCTAssertNil(legacy.binding)
        let state=try JSONDecoder().decode(ScriptLiveActivityAttributes.ContentState.self,from:Data(#"{"scriptState":"old"}"#.utf8))
        XCTAssertEqual(state.updatedAt.timeIntervalSince1970,0)
    }

    func testUnsupportedDisabledBackgroundDuplicateLimitAndSystemFailureRemainVisible() throws {
        for condition in ["unsupported","disabled","background","system"] {
            let h=LocalActivityHarness()
            if condition=="unsupported"{h.supported=false};if condition=="disabled"{h.enabled=false};if condition=="background"{h.foreground=false};if condition=="system"{h.denyRequest=true}
            let manager=h.manager();XCTAssertNil(manager.create(scriptName:"Focus",scriptParameter:""));XCTAssertTrue(manager.isError);XCTAssertFalse(manager.isWorking);XCTAssertEqual(h.requests,0)
        }
        let h=LocalActivityHarness(),manager=h.manager()
        XCTAssertNotNil(manager.create(scriptName:"Focus",scriptParameter:""))
        XCTAssertNil(manager.create(scriptName:"Focus",scriptParameter:""));XCTAssertEqual(h.requests,1)
        for _ in 0..<3 {XCTAssertNotNil(manager.create(scriptName:"Focus",scriptParameter:"",allowDuplicate:true))}
        XCTAssertNil(manager.create(scriptName:"Focus",scriptParameter:"other",allowDuplicate:true));XCTAssertEqual(h.requests,4)
    }

    func testStaleDraftAndChangedInstallationCannotOverwriteOrRetargetActivity() async throws {
        let h=LocalActivityHarness(),manager=h.manager()
        let expected=h.binding
        h.binding=ScriptWidgetLiveActivityBinding(profileID:expected.profileID,ownerID:"00000000-0000-4000-8000-000000000003")
        XCTAssertNil(manager.create(scriptName:"Focus",scriptParameter:"",expectedBinding:expected));XCTAssertEqual(h.requests,0)
        let id=try XCTUnwrap(manager.create(scriptName:"Focus",scriptParameter:"",initialState:"before")),baseline=try XCTUnwrap(h.rows.first?.state)
        h.rows[0] = .init(id:id,attributes:h.rows[0].attributes,state:.init(scriptState:"external",updatedAt:h.clock.addingTimeInterval(1)),status:"active",staleDate:nil)
        check(await manager.update(activityID:id,state:"stale draft",expectedState:baseline),expected:false);XCTAssertEqual(h.updates,0);XCTAssertEqual(h.rows[0].state.scriptState,"external")
    }

    func testReconcileEndsLegacyRetiredAndOtherLibraryButKeepsTemporarilyUnavailable() async throws {
        for error in [ScriptWidgetLiveActivityBindingError.libraryUnavailable,.installationUnavailable,.installationRetired,.differentLibrary] {
            let h=LocalActivityHarness(),manager=h.manager();_ = try XCTUnwrap(manager.create(scriptName:"Focus",scriptParameter:""));h.bindingError=error
            await manager.reconcile()
            XCTAssertEqual(h.ends,[.installationRetired,.differentLibrary].contains(error) ? 1 : 0)
        }
        let h=LocalActivityHarness(),manager=h.manager()
        h.rows=[.init(id:"legacy",attributes:.init(scriptName:"Focus",scriptParameter:""),state:.init(scriptState:"legacy"),status:"active",staleDate:nil)]
        await manager.reconcile();XCTAssertEqual(h.ends,1)
    }

    func testUpdateSuspensionCannotStartDuplicatesOrDeliverSuccessAfterRetirement() async throws {
        let h=LocalActivityHarness(),manager=h.manager(),id=try XCTUnwrap(manager.create(scriptName:"Focus",scriptParameter:""))
        h.pauseUpdate=true
        var operation:Task<Bool,Never>!
        await withCheckedContinuation { started in
            h.updateStarted={started.resume()}
            operation=Task{await manager.update(activityID:id,state:"in flight")}
        }
        XCTAssertTrue(manager.isWorking);XCTAssertNil(manager.create(scriptName:"Other",scriptParameter:"different"));XCTAssertEqual(h.requests,1)
        h.bindingError = .installationRetired
        await manager.reconcile()
        h.pending?.resume();h.pending=nil
        check(await operation.value,expected:false)
        await manager.reconcile()
        XCTAssertTrue(h.rows.isEmpty)
    }
}
#endif

#if os(iOS)
@available(iOS 16.2,*)
@MainActor
final class ScriptWidgetActivityKitIntegrationTests:XCTestCase {
    func testExplicitFreshSimulatorUsesActualActivityKitAndBoundTemplate() async throws {
        let environment=ProcessInfo.processInfo.environment
        guard environment["SCRIPTWIDGET_ACTIVITYKIT_SMOKE"]=="1" else { throw XCTSkip("Opt-in actual ActivityKit lifecycle on a dedicated fresh simulator") }
        guard let expected=environment["SCRIPTWIDGET_ACTIVITYKIT_SMOKE_UDID"],environment["SIMULATOR_UDID"]==expected,
              environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("ScriptWidget ActivityKit QA")==true else {
            XCTFail("Actual ActivityKit test requires its explicitly identified private simulator");return
        }
        var phase=environment["SCRIPTWIDGET_ACTIVITYKIT_PHASE"] ?? "lifecycle"
        guard ["lifecycle","create","restore","relaunch"].contains(phase) else { XCTFail("Unknown ActivityKit smoke phase");return }
        if phase == "relaunch" {
            let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("activitykit-smoke.json")
            phase=FileManager.default.fileExists(atPath:report.path) ? "restore" : "create"
        }
        if phase == "restore" {
            try await restoreAfterProcessExit(simulator:expected,environment:environment)
            return
        }
        let client=ScriptLiveActivityClient.system
        XCTAssertTrue(client.supported());XCTAssertTrue(client.enabled(),"Simulator must support local activities")
        XCTAssertTrue(client.foreground(),"ActivityKit start requires a foreground app")
        guard client.list().isEmpty else { XCTFail("Fresh simulator unexpectedly contains existing activities; nothing will be ended");return }
        let container=try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.everettjf.scriptwidget"))
        let profiles=try ScriptWidgetStorageProfiles(container:container,legacy:ScriptWidgetStorageProfiles.liveLegacyPreferences)
        guard try profiles.profiles().isEmpty else { XCTFail("Fresh simulator already contains an active library; existing data will not be changed");return }
        let library=container.appendingPathComponent("ActivityKit-QA-Library",isDirectory:true)
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        let session=try ScriptWidgetLibrarySession.activate(profiles:profiles,root:library,isUsingICloud:false)
        let sourceManager=try XCTUnwrap(session.sourceManager)
        let installation=sourceManager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Live Activity Demo"))
        XCTAssertTrue(installation.0,installation.1)
        let package=sourceManager.getScriptPackage(packageName:installation.1)
        let build=await Task.detached { sourceManager.buildScriptPackage(package:package,requireSharedContainer:true) }.value
        XCTAssertTrue(build.0,build.1)
        let (binding,execution)=try ScriptWidgetLiveActivityBinding.capture(name:installation.1)
        XCTAssertEqual(execution.snapshot?.binding.ownerID,binding.ownerID)
        let manager=ScriptLiveActivityManager(client:client,observeSystem:false)
        let initial=#"{"title":"Reading QA","detail":"Actual ActivityKit request","progress":1,"total":8}"#
        let updated=#"{"title":"Reading QA","detail":"Actual ActivityKit update","progress":3,"total":8}"#
        let id=try XCTUnwrap(manager.create(scriptName:installation.1,scriptParameter:"",initialState:initial,staleDate:Date().addingTimeInterval(600),expectedBinding:binding),manager.message ?? "ActivityKit request failed")
        do {
            let row=try XCTUnwrap(client.list().first(where:{$0.id==id}))
            XCTAssertEqual(row.attributes.binding,binding);XCTAssertEqual(row.state.scriptState,initial)
            if phase == "create" {
                let runID=try XCTUnwrap(environment["SCRIPTWIDGET_ACTIVITYKIT_RUN_ID"])
                XCTAssertNotNil(UUID(uuidString:runID))
                let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("activitykit-smoke.json")
                let bytes=try JSONSerialization.data(withJSONObject:["phase":"created","activityID":id,"binding":binding.ownerID,
                    "profile":binding.profileID,"simulator":expected,"runID":runID,"pid":ProcessInfo.processInfo.processIdentifier,
                    "name":installation.1,"state":initial],options:[.sortedKeys])
                try bytes.write(to:report,options:.atomic)
                try bytes.write(to:report.deletingLastPathComponent().appendingPathComponent("activitykit-created.json"),options:.atomic)
                return // The owned simulator script terminates this host before the restore launch.
            }
            let reopened=ScriptLiveActivityManager(client:client,observeSystem:false)
            XCTAssertEqual(reopened.activities.first?.id,id)
            let accepted=await reopened.update(activityID:id,state:updated,expectedState:row.state)
            XCTAssertTrue(accepted,reopened.message ?? "ActivityKit update failed")
            XCTAssertEqual(client.list().first(where:{$0.id==id})?.state.scriptState,updated)
            let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("activitykit-smoke.json")
            try JSONSerialization.data(withJSONObject:["phase":"updated","activityID":id,"binding":binding.ownerID,"simulator":expected],options:[.sortedKeys]).write(to:report,options:.atomic)
            if environment["SCRIPTWIDGET_ACTIVITYKIT_CAPTURE"]=="1" { try await Task.sleep(for:.seconds(30)) }
            let ended=await reopened.dismiss(activityID:id)
            XCTAssertTrue(ended,reopened.message ?? "ActivityKit end failed")
            XCTAssertFalse(client.list().contains(where:{$0.id==id && $0.isRunning}))
            try JSONSerialization.data(withJSONObject:["phase":"ended","simulator":expected],options:[.sortedKeys]).write(to:report,options:.atomic)
        } catch {
            await client.end(id,nil,.immediate)
            throw error
        }
    }

    private func restoreAfterProcessExit(simulator:String,environment:[String:String]) async throws {
        let runID=try XCTUnwrap(environment["SCRIPTWIDGET_ACTIVITYKIT_RUN_ID"])
        XCTAssertNotNil(UUID(uuidString:runID))
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let bytes=try XCTUnwrap(ScriptWidgetPackageFiles.read(root:documents,relative:"activitykit-smoke.json",maximumBytes:4096))
        var report=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        guard report["phase"] as? String == "created",report["simulator"] as? String == simulator,
              report["runID"] as? String == runID else { XCTFail("Restore requires this run's creation checkpoint");return }
        let writerPID=try XCTUnwrap(report["pid"] as? Int)
        guard writerPID>0,writerPID<=Int(Int32.max),writerPID != Int(ProcessInfo.processInfo.processIdentifier) else {
            XCTFail("Must launch a different app process");return
        }
        let writerStatus=kill(pid_t(writerPID),0),writerError=errno
        guard writerStatus == -1,writerError == ESRCH else { XCTFail("Writer must have exited before the restore launch");return }
        let id=try XCTUnwrap(report["activityID"] as? String),name=try XCTUnwrap(report["name"] as? String)
        let binding=ScriptWidgetLiveActivityBinding(profileID:try XCTUnwrap(report["profile"] as? String),ownerID:try XCTUnwrap(report["binding"] as? String))
        let client=ScriptLiveActivityClient.system
        let row=try XCTUnwrap(client.list().first(where:{$0.id==id && $0.isRunning}),"ActivityKit must retain the original activity across host termination")
        guard row.attributes.binding == binding else { XCTFail("Activity binding differs from this run's checkpoint");return }
        XCTAssertEqual(row.state.scriptState,report["state"] as? String)
        XCTAssertEqual(try binding.currentName(),name,"The saved native library and installation must survive")
        let (_,execution)=try ScriptWidgetLiveActivityBinding.capture(name:name)
        XCTAssertEqual(execution.snapshot?.binding.ownerID,binding.ownerID)
        let manager=ScriptLiveActivityManager(client:client,observeSystem:false)
        XCTAssertEqual(manager.activities.filter{$0.id==id}.count,1)
        let updated=#"{"title":"Reading QA","detail":"Restored in a new process","progress":5,"total":8}"#
        do {
            let accepted=await manager.update(activityID:id,state:updated,expectedState:row.state)
            XCTAssertTrue(accepted,manager.message ?? "Restored activity update failed")
            XCTAssertEqual(client.list().first(where:{$0.id==id})?.state.scriptState,updated)
            if environment["SCRIPTWIDGET_ACTIVITYKIT_CAPTURE"]=="1" { try await Task.sleep(for:.seconds(30)) }
            let ended=await manager.dismiss(activityID:id)
            XCTAssertTrue(ended,manager.message ?? "Restored activity end failed")
            XCTAssertFalse(client.list().contains(where:{$0.id==id && $0.isRunning}))
            report["phase"]="ended";report["readerPID"]=ProcessInfo.processInfo.processIdentifier
            report["restoredFromSystemList"]=true;report["writerProcessWasGone"]=true;report["lastState"]=updated
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:documents.appendingPathComponent("activitykit-smoke.json"),options:.atomic)
        } catch {
            await client.end(id,nil,.immediate)
            throw error
        }
    }
}
#endif

final class RemindersPolicyTests: XCTestCase {
    private let options: [String: Any] = ["start": "2026-02-03T00:00:00Z", "end": "2026-02-04T00:00:00Z"]

    func testQueryValidationAndSeparateCompletionIdentity() throws {
        let query = try ScriptWidgetRemindersQuery(options)
        let completed = try ScriptWidgetRemindersQuery(options.merging(["completed": true]) { _, b in b })
        XCTAssertFalse(query.completed); XCTAssertTrue(completed.completed)
        XCTAssertNotEqual(query.identity, completed.identity)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var losAngeles = utc; losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertNotEqual(try ScriptWidgetRemindersQuery(options, calendar: utc).identity, try ScriptWidgetRemindersQuery(options, calendar: losAngeles).identity)

        for extra: [String: Any] in [["completed": 1], ["completed": "true"], ["completed": NSNull()], ["listIDs": []], ["listIDs": ["a", "a"]], ["calendarIDs": ["a"]], ["limit": true], ["limit": 51], ["end": "2026-04-03T00:00:00Z"], ["start": "2026-02-03"]] {
            XCTAssertThrowsError(try ScriptWidgetRemindersQuery(options.merging(extra) { _, b in b }))
        }
        let a = "caf\u{00e9}", b = "cafe\u{0301}"
        let ids = try ScriptWidgetRemindersQuery(options.merging(["listIDs": [a, b]]) { _, b in b })
        XCTAssertEqual(ids.window.calendarIDs.count, 2)
    }

    func testFloatingDueDatesCompletionWindowsAndOpaqueListIDs() throws {
        let query = try ScriptWidgetRemindersQuery(options)
        func item(due: String?, timed: Bool = true, completed: Bool = false, at: String? = nil, list: String = "personal") -> ScriptWidgetReminderItem {
            .init(id: "1", listID: list, title: "Reading", due: due, hasTime: timed, completed: completed, completedAt: at, priority: 0)
        }
        XCTAssertTrue(item(due: "2026-02-03T10:00:00Z").matches(query, selection: .all))
        XCTAssertFalse(item(due: "2026-02-04T00:00:00Z").matches(query, selection: .all))
        XCTAssertTrue(item(due: "2026-02-03", timed: false).matches(query, selection: .all))
        XCTAssertFalse(item(due: "2026-02-30", timed: false).matches(query, selection: .all))
        XCTAssertFalse(item(due: nil, timed: false).matches(query, selection: .all))
        let done = try ScriptWidgetRemindersQuery(options.merging(["completed": true]) { _, b in b })
        XCTAssertTrue(item(due: nil, timed: false, completed: true, at: "2026-02-03T12:00:00Z").matches(done, selection: .all))
        XCTAssertFalse(item(due: nil, timed: false, completed: true).matches(done, selection: .all))
        XCTAssertFalse(item(due: "2026-02-03T10:00:00Z", list: "cafe\u{0301}").matches(query, selection: .init(calendarIDs: ["caf\u{00e9}"])))
        let floating = ScriptWidgetReminderItem.dueValue(DateComponents(year: 2026, month: 2, day: 3))
        XCTAssertEqual(floating.text, "2026-02-03"); XCTAssertFalse(floating.hasTime)
        XCTAssertNil(ScriptWidgetReminderItem.dueValue(DateComponents(year: 2026, month: 2, day: 30)).text)
    }

    func testCacheRejectsWrongScopeQueryStatusAndMalformedRows() throws {
        let query = try ScriptWidgetRemindersQuery(options), now = Date()
        let row = ScriptWidgetReminderItem(id: "1", listID: "personal", title: "Reading", due: "2026-02-03T12:00:00Z", hasTime: true, completed: false, completedAt: nil, priority: 0).dictionary
        let value: [String: Any] = ["status": "ready", "items": [row], "fetchedAt": ISO8601DateFormatter().string(from: now), "source": "system", "stale": false, "truncated": false]
        var object: [String: Any] = ["query": query.identity, "selection": ScriptWidgetCalendarSelection.all.identity, "timestamp": now.timeIntervalSince1970, "value": value]
        func decode(_ selection: ScriptWidgetCalendarSelection = .all) throws -> [String: Any]? {
            ScriptWidgetRemindersCache.decode(try JSONSerialization.data(withJSONObject: object), query: query, selection: selection, now: now)
        }
        XCTAssertEqual(try decode()?["source"] as? String, "cache")
        XCTAssertNil(try decode(.init(calendarIDs: ["personal"])))
        object["query"] = "other"; XCTAssertNil(try decode()); object["query"] = query.identity
        object["timestamp"] = now.addingTimeInterval(1).timeIntervalSince1970; XCTAssertNil(try decode()); object["timestamp"] = now.timeIntervalSince1970
        for bad: [String: Any] in [["priority": true], ["priority": 10], ["completed": true], ["due": "invalid"], ["listID": ""], ["extra": "sensitive"]] {
            var changed = value; changed["items"] = [row.merging(bad) { _, b in b }]; object["value"] = changed
            XCTAssertNil(try decode())
        }
    }

    func testCalendarAndReminderSelectionsAreIndependentAndFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderScope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ScriptWidgetCalendarSelection(calendarIDs: ["calendar"]).save(container: root)
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: root, kind: .reminders), .all)
        let selection = ScriptWidgetCalendarSelection(calendarIDs: ["reminder"])
        try selection.save(container: root, kind: .reminders)
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: root).calendarIDs, ["calendar"])
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: root, kind: .reminders), selection)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.all.save(container: root, replacing: .all, kind: .reminders))
        let file = root.appendingPathComponent(ScriptWidgetEventSourceKind.reminders.fileName)
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: root, kind: .reminders))
        XCTAssertEqual(try ScriptWidgetCalendarSelection.load(container: root).calendarIDs, ["calendar"])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent(ScriptWidgetEventSourceKind.calendar.fileName))
        XCTAssertThrowsError(try ScriptWidgetCalendarSelection.load(container: root, kind: .reminders))
    }
}


extension RemindersPolicyTests {
    func testFileBackendAllowsOnlyBoundedHashedPrivateSnapshotKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderMetadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.scriptwidget.reminder-metadata." + UUID().uuidString, legacy = UserDefaults(suiteName: suite)!
        defer { legacy.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let backend = try ScriptWidgetFileStorageBackend(container: root, legacy: legacy)
        for prefix in ["ScriptWidget.CalendarCache.v1.", "ScriptWidget.RemindersCache.v1."] {
            let valid = prefix + String(repeating: "a", count: 64)
            try backend.writeValue(Data([1, 2, 3]), forKey: valid)
            XCTAssertEqual(try backend.readValue(forKey: valid) as? Data, Data([1, 2, 3]))
            for suffix in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "G", count: 64), "../personal"] {
                XCTAssertThrowsError(try backend.writeValue(Data([4]), forKey: prefix + suffix))
            }
        }
    }
}


extension RemindersPolicyTests {
    func testDeterministicCacheUsesTemporaryRootInsteadOfHostAppGroup() throws {
        XCTAssertTrue(ScriptManager.usesIsolatedUnitTestBuildCache)
        let root = try XCTUnwrap(ScriptManager.getSandboxBuildDirectoryURL())
        XCTAssertEqual(root.standardizedFileURL, ScriptManager.localFallbackDirectoryURL("__Build").standardizedFileURL)
        XCTAssertTrue(root.path.contains("ScriptWidgetTests"))
    }
}


final class RemindersMutationTests: XCTestCase {
    private let requestID = "550e8400-e29b-41d4-a716-446655440000"
    private func options(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["requestID": requestID, "listID": "personal", "title": "Read a chapter"].merging(changes) { _, new in new }
    }
    func testCreationRejectsMalformedDatesTypesAndUnknownFields() throws {
        let request = try ScriptWidgetReminderMutation(kind: .create, options: options(["due": "2028-02-29", "priority": 4]))
        XCTAssertEqual(request.due, "2028-02-29"); XCTAssertEqual(request.priority, 4); XCTAssertNil(request.id)
        for changes: [String: Any] in [["title": " "], ["title": String(repeating: "é", count: 513)], ["title": "a\nb"], ["due": "2026-02-29"], ["due": "2026-02-29T12:00:00Z"], ["due": "2026-03-01T24:00:00Z"], ["due": "bad"], ["priority": true], ["priority": 1.5], ["priority": 10], ["listID": ""], ["requestID": "unstable"], ["requestID": requestID.uppercased()], ["completed": true], ["id": "foreign"]] {
            XCTAssertThrowsError(try ScriptWidgetReminderMutation(kind: .create, options: options(changes)))
        }
    }
    func testUpdatesDistinguishAbsentAndClearedDueDatesAndRejectEmptyChanges() throws {
        let base: [String: Any] = ["requestID": requestID, "listID": "personal", "id": "reminder", "title": "Read"]
        let preserve = try ScriptWidgetReminderMutation(kind: .update, options: base)
        let clear = try ScriptWidgetReminderMutation(kind: .update, options: base.merging(["due": NSNull()]) { _, b in b })
        XCTAssertFalse(preserve.changesDue); XCTAssertTrue(clear.changesDue); XCTAssertNil(clear.due)
        XCTAssertNotEqual(preserve.fingerprint, clear.fingerprint)
        var empty = base; empty.removeValue(forKey: "title")
        XCTAssertThrowsError(try ScriptWidgetReminderMutation(kind: .update, options: empty))
    }
    func testCompletionRequiresDesiredBooleanAndFingerprintsBindThePayload() throws {
        let base: [String: Any] = ["requestID": requestID, "listID": "personal", "id": "reminder", "completed": true]
        let first = try ScriptWidgetReminderMutation(kind: .setCompleted, options: base)
        let replay = try ScriptWidgetReminderMutation(kind: .setCompleted, options: base.merging(["requestID": UUID().uuidString.lowercased()]) { _, b in b })
        XCTAssertEqual(first.fingerprint, replay.fingerprint)
        XCTAssertNotEqual(first.fingerprint, try ScriptWidgetReminderMutation(kind: .setCompleted, options: base.merging(["completed": false]) { _, b in b }).fingerprint)
        for bad: Any in [1, "true", NSNull()] {
            XCTAssertThrowsError(try ScriptWidgetReminderMutation(kind: .setCompleted, options: base.merging(["completed": bad]) { _, b in b }))
        }
    }
    func testScriptEnvironmentsCannotGrantNativeActionAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderAction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = ScriptWidgetPackage(path: root)
        func state(action: Bool = false, projection: Bool = false, activity: Bool = false, preview: Bool = false) -> ScriptWidgetRunningState {
            let value = ScriptWidgetRunningState(package: preview ? ScriptWidgetPackage(path: root, readonly: true) : package,
                isTimelineProjection: projection, isLiveActivityPresentation: activity, isUserInitiatedAction: action)
            value.storageContainerForTesting = root
            return value
        }
        XCTAssertFalse(ScriptWidgetReminderMutation.permitsAction(state()))
        XCTAssertFalse(ScriptWidgetReminderMutation.permitsAction(state(action: true, projection: true)))
        XCTAssertFalse(ScriptWidgetReminderMutation.permitsAction(state(action: true, activity: true)))
        XCTAssertFalse(ScriptWidgetReminderMutation.permitsAction(state(action: true, preview: true)))
        let allowed = state(action: true); XCTAssertTrue(ScriptWidgetReminderMutation.permitsAction(allowed))
        allowed.executionSession.cancel(.explicit); XCTAssertFalse(ScriptWidgetReminderMutation.permitsAction(allowed))
        let forged = ScriptWidgetRuntime(package: package, environments: ["widget-size": "action", "action-id": "complete", "action-source": "widget"])
        XCTAssertFalse(try XCTUnwrap(forged.runningState).isUserInitiatedAction)
    }
}

final class RemindersWriteReceiptTests: XCTestCase {
    private var root: URL!, backend: ScriptWidgetFileStorageBackend!, defaults: UserDefaults!, suite: String!
    private let key = "ScriptWidget.RemindersWrites.v1." + String(repeating: "a", count: 64)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderWrites-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "app.scriptwidget.reminder-writes." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        backend = try ScriptWidgetFileStorageBackend(container: root, legacy: defaults)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func request(_ title: String = "Read", id: String = "550e8400-e29b-41d4-a716-446655440000") throws -> ScriptWidgetReminderMutation {
        try .init(kind: .create, options: ["requestID": id, "listID": "personal", "title": title])
    }
    func testReceiptsSurviveReopeningAndNeverRepeatACompletedCreate() throws {
        let mutation = try request(); var writes = 0
        func perform(_ store: any ScriptWidgetStorageBackend) throws -> [String: Any] {
            try ScriptWidgetReminderMutationLedger.perform(mutation, container: root, backend: store, key: key, validate: {}) { commit in
                try commit(); writes += 1; return "system-id"
            }
        }
        XCTAssertEqual(try perform(backend)["replayed"] as? Bool, false)
        let reopened = try ScriptWidgetFileStorageBackend(container: root, legacy: defaults)
        XCTAssertEqual(try perform(reopened)["replayed"] as? Bool, true)
        XCTAssertEqual(writes, 1)
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(request("Changed"), container: root, backend: reopened, key: key, validate: {}) { _ in XCTFail("Conflicting request reached EventKit"); return "bad" }) { error in
            XCTAssertTrue(error.localizedDescription.contains("request_conflict"))
        }
        XCTAssertNil(defaults.object(forKey: key))
    }
    func testInterruptedCommitIsRetainedAsUnknownAndNeverAutomaticallyRetried() throws {
        enum Interrupted: Error { case afterCommit }
        let mutation = try request(); var writes = 0
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(mutation, container: root, backend: backend, key: key, validate: {}) { commit in
            try commit(); writes += 1; throw Interrupted.afterCommit
        })
        let reopened = try ScriptWidgetFileStorageBackend(container: root, legacy: defaults)
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(mutation, container: root, backend: reopened, key: key, validate: {}) { _ in writes += 1; return "duplicate" }) { error in
            XCTAssertTrue(error.localizedDescription.contains("outcome_unknown"))
        }
        XCTAssertEqual(writes, 1)
    }
    func testRevocationBeforeCommitDoesNotReserveOrApplyARequest() throws {
        var authorized = true, commits = 0
        let mutation = try request()
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(mutation, container: root, backend: backend, key: key,
            validate: { if !authorized { throw ScriptWidgetRemindersError.denied } }) { commit in
                authorized = false; try commit(); commits += 1; return "forbidden"
            })
        XCTAssertNil(try backend.readValue(forKey: key)); XCTAssertEqual(commits, 0)
    }
    func testCorruptAndUnknownLedgerFieldsFailBeforeSystemWrites() throws {
        try backend.writeValue(Data("broken".utf8), forKey: key)
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(request(), container: root, backend: backend, key: key, validate: {}) { _ in XCTFail("Malformed ledger reached EventKit"); return "bad" })
        try backend.writeValue(Data(#"{"formatVersion":1,"entries":[],"unknown":true}"#.utf8), forKey: key)
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(request(), container: root, backend: backend, key: key, validate: {}) { _ in XCTFail("Unknown fields reached EventKit"); return "bad" })
    }
    func testPendingReceiptsAreNotExpiredOrEvicted() throws {
        let mutation = try request()
        enum Stopped: Error { case stopped }
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(mutation, container: root, backend: backend, key: key, now: Date(timeIntervalSince1970: 100), validate: {}) { commit in try commit(); throw Stopped.stopped })
        XCTAssertThrowsError(try ScriptWidgetReminderMutationLedger.perform(mutation, container: root, backend: backend, key: key, now: Date(timeIntervalSince1970: 100 + 30 * 86400), validate: {}) { _ in XCTFail("Old pending operation was repeated"); return "bad" })
    }
}

final class PhotosPolicyTests: XCTestCase {
    func testQueriesRejectUnknownFieldsTypesAndUnboundedRequests() throws {
        let defaults = try ScriptWidgetPhotoQuery(nil)
        XCTAssertEqual(defaults.limit, 4); XCTAssertEqual(defaults.offset, 0); XCTAssertEqual(defaults.maxAgeSeconds, 3600)
        for value: [String: Any] in [["limit": true], ["limit": 0], ["limit": 5], ["limit": 1.5], ["offset": -1], ["offset": 64], ["maxAgeSeconds": 86401], ["maxAgeSeconds": Double.nan], ["albumID": "forged"]] {
            XCTAssertThrowsError(try ScriptWidgetPhotoQuery(value))
        }
    }
    func testExplicitSelectionDefaultsToNoneAndRejectsStaleAndMalformedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosPolicy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try ScriptWidgetPhotoSelection.load(container: root), .empty)
        let selected = ScriptWidgetPhotoSelection(assetIDs: ["asset/opaque"], albumIDs: ["album/opaque"])
        try selected.save(container: root, replacing: .empty)
        XCTAssertEqual(try ScriptWidgetPhotoSelection.load(container: root), selected)
        XCTAssertThrowsError(try ScriptWidgetPhotoSelection.empty.save(container: root, replacing: .empty))
        let duplicate = ScriptWidgetPhotoSelection(assetIDs: ["same", "same"], albumIDs: [])
        XCTAssertThrowsError(try duplicate.save(container: root, replacing: selected))
        let path = root.appendingPathComponent(ScriptWidgetPhotoSelection.fileName)
        try Data(#"{"formatVersion":1,"assetIDs":[],"albumIDs":[],"all":true}"#.utf8).write(to: path)
        XCTAssertThrowsError(try ScriptWidgetPhotoSelection.load(container: root))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertThrowsError(try ScriptWidgetPhotoSelection.load(container: root))
    }
    func testOpaqueIDsRemainDistinctWithoutGrantingAllPhotos() throws {
        let composed = "café", decomposed = "cafe\u{301}"
        XCTAssertTrue(ScriptWidgetPhotoSelection.valid([composed, decomposed], maximum: 24))
        XCTAssertNotEqual(ScriptWidgetPhotoSelection(assetIDs: [composed], albumIDs: []).identity,
                          ScriptWidgetPhotoSelection(assetIDs: [decomposed], albumIDs: []).identity)
        XCTAssertFalse(ScriptWidgetPhotoSelection.valid([String(repeating: "x", count: 1025)], maximum: 24))
    }
}

final class ExpandedHealthPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1793664000)
    func testRangesDatesUnitsAndLocalDSTBoundaries() throws {
        let sleep = try ScriptWidgetHealthReadQuery(kind: .sleepSummary, options: nil, now: now)
        XCTAssertEqual(sleep.end.timeIntervalSince(sleep.start), 86400)
        for options: [String:Any] in [["limit": 4],["start":"2026-02-29T00:00:00Z"],["end":"2026-03-01T24:00:00Z"],["start":true],["unknown":0],["end":NSNull()]] {
            XCTAssertThrowsError(try ScriptWidgetHealthReadQuery(kind: .sleepSummary, options: options, now: now))
        }
        for raw: Any in [0,51,true,1.5,NSNull()] { XCTAssertThrowsError(try ScriptWidgetHealthReadQuery(kind:.workouts,options:["limit":raw],now:now)) }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"America/New_York")!
        let march=try ScriptWidgetHealthReadQuery(kind:.activitySummary,options:["date":"2026-03-08"],now:now,calendar:calendar)
        let november=try ScriptWidgetHealthReadQuery(kind:.activitySummary,options:["date":"2026-11-01"],now:now,calendar:calendar)
        XCTAssertEqual(march.end.timeIntervalSince(march.start),23*3600);XCTAssertEqual(november.end.timeIntervalSince(november.start),25*3600)
        XCTAssertThrowsError(try ScriptWidgetHealthReadQuery(kind:.activitySummary,options:["date":"9999-01-01"],now:now))
    }
    func testSleepUnionsDuplicateSourcesClipsAndDoesNotAddInBedToSleep() throws {
        let base=Date(timeIntervalSince1970:0)
        let query=try ScriptWidgetHealthReadQuery(kind:.sleepSummary,options:["start":"1970-01-01T00:00:00Z","end":"1970-01-01T00:10:00Z"],now:now)
        let segments:[ScriptWidgetSleepSegment]=[
            .init(start:base.addingTimeInterval(-60),end:base.addingTimeInterval(660),stage:.inBed,source:"bed"),
            .init(start:base,end:base.addingTimeInterval(600),stage:.core,source:"watch"),
            .init(start:base,end:base.addingTimeInterval(600),stage:.core,source:"duplicate"),
            .init(start:base.addingTimeInterval(60),end:base.addingTimeInterval(180),stage:.deep,source:"watch"),
            .init(start:base.addingTimeInterval(150),end:base.addingTimeInterval(210),stage:.awake,source:"watch"),
            .init(start:base.addingTimeInterval(300),end:base.addingTimeInterval(600),stage:.unspecified,source:"other")]
        let result=try ScriptWidgetHealthReadout.sleep(segments,truncated:false).object(for:query)
        XCTAssertEqual(result["totalSleepSeconds"] as? Double,540)
        XCTAssertEqual(result["inBedSeconds"] as? Double,600);XCTAssertEqual(result["awakeSeconds"] as? Double,60)
        XCTAssertEqual((result["stages"] as? [String:Double])?["deep"],90)
        XCTAssertEqual(result["conflictSeconds"] as? Double,450)
        XCTAssertNil(result["sources"]);XCTAssertEqual(result["sourceCount"] as? Int,4)
    }
    func testSleepEmptyAndBoundsNeverInventSamples() throws {
        let query=try ScriptWidgetHealthReadQuery(kind:.sleepSummary,options:nil,now:now)
        let empty=try ScriptWidgetHealthReadout.sleep([],truncated:false).object(for:query)
        XCTAssertEqual(empty["hasSamples"] as? Bool,false);XCTAssertEqual(empty["totalSleepSeconds"] as? Double,0)
        let segment=ScriptWidgetSleepSegment(start:query.start,end:query.end,stage:.core,source:"watch")
        XCTAssertThrowsError(try ScriptWidgetHealthReadout.sleep(Array(repeating:segment,count:257),truncated:true).object(for:query))
        let partial=try ScriptWidgetHealthReadout.sleep([segment],truncated:true).object(for:query)
        XCTAssertEqual(partial["truncated"] as? Bool,true)
    }
    func testActivitySupportsMoveTimeMissingGoalsAndKnownZero() throws {
        let query=try ScriptWidgetHealthReadQuery(kind:.activitySummary,options:nil,now:now)
        let known=try ScriptWidgetHealthReadout.activity(.init(moveMode:"moveTime",move:0,moveGoal:60,exercise:0,exerciseGoal:nil,stand:0,standGoal:nil)).object(for:query)
        XCTAssertEqual(known["hasSamples"] as? Bool,true)
        XCTAssertEqual((known["move"] as? [String:Any])?["unit"] as? String,"min")
        XCTAssertTrue((known["exercise"] as? [String:Any])?["goal"] is NSNull)
        let empty=try ScriptWidgetHealthReadout.activity(nil).object(for:query)
        XCTAssertEqual(empty["hasSamples"] as? Bool,false)
        XCTAssertThrowsError(try ScriptWidgetHealthReadout.activity(.init(moveMode:"activeEnergy",move:-1,moveGoal:0,exercise:0,exerciseGoal:0,stand:0,standGoal:0)).object(for:query))
    }
    func testWorkoutsEnforceContainmentOrderingAndOptionalStatistics() throws {
        let query=try ScriptWidgetHealthReadQuery(kind:.workouts,options:nil,now:now)
        let row=ScriptWidgetHealthWorkout(id:UUID().uuidString.lowercased(),activity:"running",start:now.addingTimeInterval(-3600),end:now.addingTimeInterval(-900),duration:2700,energyKcal:nil,distanceMeters:nil)
        let result=try ScriptWidgetHealthReadout.workouts([row],truncated:false).object(for:query)
        XCTAssertTrue((result["items"] as? [[String:Any]])?.first?["energyKcal"] is NSNull)
        XCTAssertThrowsError(try ScriptWidgetHealthReadout.workouts([row,row],truncated:false).object(for:query))
        let outside=ScriptWidgetHealthWorkout(id:UUID().uuidString,activity:"running",start:query.start.addingTimeInterval(-1),end:query.end,duration:10,energyKcal:0,distanceMeters:0)
        XCTAssertFalse(outside.valid(in:query))
    }
}

final class GifPipelineTests: XCTestCase {
    override func tearDown() { ScriptWidgetGifPipeline.removeAll(); super.tearDown() }
    private func gif(width: Int = 32, height: Int = 16, frames: Int = 2) throws -> Data {
        let data = NSMutableData(), context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,"com.compuserve.gif" as CFString,frames,nil))
        for index in 0..<frames {
            context.setFillColor(CGColor(red:index == 0 ? 1 : 0,green:CGFloat(index)/CGFloat(frames),blue:index == 0 ? 0 : 1,alpha:1))
            context.fill(CGRect(x:0,y:0,width:width,height:height))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:Double(index+1)*0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    func testFrameTimingAndStaticFirstFrameWithoutThirdPartyDecoder() throws {
        let bytes = try gif(), sequence = try XCTUnwrap(ScriptWidgetGifPipeline.sequence(data:bytes,animated:true))
        XCTAssertEqual(sequence.frames.count,2); XCTAssertEqual(sequence.duration,0.3,accuracy:0.001)
        XCTAssertEqual(sequence.frameIndex(elapsed:0.05),0); XCTAssertEqual(sequence.frameIndex(elapsed:0.15),1)
        XCTAssertEqual(sequence.frameIndex(elapsed:0.35),0); XCTAssertEqual(sequence.frameIndex(elapsed:Double.infinity),0)
        let still = try XCTUnwrap(ScriptWidgetGifPipeline.sequence(data:bytes,animated:false))
        XCTAssertEqual(still.frames.count,1); XCTAssertFalse(still.frameLimitFallback)
        XCTAssertEqual(still.frames[0].width,32); XCTAssertEqual(still.frames[0].height,16)
    }
    func testFramesAreDownsampledWithinAggregateDecodedBudget() throws {
        let sequence = try XCTUnwrap(ScriptWidgetGifPipeline.sequence(data:gif(width:256,height:256,frames:60),animated:true))
        XCTAssertEqual(sequence.frames.count,60)
        XCTAssertLessThanOrEqual(sequence.decodedBytes,ScriptWidgetGifPipeline.maximumDecodedBytes)
        XCTAssertTrue(sequence.frames.allSatisfy { $0.width <= 128 && $0.height <= 128 })
    }
    func testFrameLimitFallsBackToFirstFrameWithoutExpandingTheSequence() throws {
        let sequence = try XCTUnwrap(ScriptWidgetGifPipeline.sequence(data:gif(frames:61),animated:true))
        XCTAssertTrue(sequence.frameLimitFallback); XCTAssertEqual(sequence.frames.count,1)
    }
    func testInputCanvasAndInvalidTypeAreRejectedBeforePixelDecode() throws {
        XCTAssertNil(ScriptWidgetGifPipeline.sequence(data:Data(repeating:0,count:ScriptWidgetGifPipeline.maximumInputBytes+1),animated:true))
        XCTAssertNil(ScriptWidgetGifPipeline.sequence(data:Data("GIF89a".utf8),animated:true))
        XCTAssertNil(try ScriptWidgetGifPipeline.sequence(data:gif(width:2048,height:1024),animated:true))
    }
    func testBoundedFileReadsRejectLinksAndDoNotReuseStalePathCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gif-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("sample.gif"), link = root.appendingPathComponent("linked.gif")
        try gif().write(to:file); XCTAssertNotNil(ScriptWidgetGifPipeline.sequence(at:file,animated:true))
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertNil(ScriptWidgetGifPipeline.sequence(at:link,animated:true)); XCTAssertNil(ScriptWidgetGifPipeline.sequence(at:root,animated:true))
        try Data("not a GIF".utf8).write(to:file); XCTAssertNil(ScriptWidgetGifPipeline.sequence(at:file,animated:true))
        XCTAssertNil(ScriptWidgetGifPipeline.sequence(at:URL(string:"https://example.test/sample.gif")!,animated:true))
    }
    @MainActor func testPublicGifTimingAndInactiveFallbackRenderActualPixels() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gif")
        try gif().write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        for (elapsed, live) in [(0.0,true),(0.15,true),(0.15,false)] {
            let content = DynamicGifView(gifPath:file)
                .environment(\.scriptWidgetVisualAccessibility,.init(reduceMotion:false))
                .environment(\.scriptWidgetAnimationPreview,.init(elapsed:elapsed,live:live)).frame(width:120,height:60)
            let renderer = ImageRenderer(content:content), image = try XCTUnwrap(renderer.cgImage)
            var pixel = [UInt8](repeating:0,count:4)
            let context = try XCTUnwrap(CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
            #if os(macOS)
            let blue = false
            #else
            let blue = elapsed > 0.1 && live
            #endif
            XCTAssertGreaterThan(pixel[blue ? 2 : 0],200)
            XCTAssertLessThan(pixel[blue ? 0 : 2],40)
        }
    }
    @MainActor func testReducedMotionViewActuallyRendersTheFirstFrame() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gif")
        try gif().write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        let renderer = ImageRenderer(content:DynamicGifView(gifPath:file).environment(\.scriptWidgetVisualAccessibility,.init(reduceMotion:true)).frame(width:120,height:60))
        let image = try XCTUnwrap(renderer.cgImage)
        var pixel = [UInt8](repeating:0,count:4)
        let context = try XCTUnwrap(CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
        XCTAssertGreaterThan(pixel[0],200); XCTAssertLessThan(pixel[2],40)
        if let path = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_GIF"] {
            #if os(macOS)
            let platform = "macos"
            #else
            let platform = "ios"
            #endif
            let directory = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            try (data as Data).write(to:directory.appendingPathComponent(platform+"-reduced-motion.png"))
            try gif().write(to:directory.appendingPathComponent("sample.gif"))
            try gif(frames:61).write(to:directory.appendingPathComponent("many-frames.gif"))
        }
    }
}

final class PublicAnimationTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)
    func testSignedIntervalsRemainFiniteAndKeepTheLegacyHalfTurnConvention() {
        let utc = TimeZone(secondsFromGMT: 0)!
        for (interval, angle): (Double, Double) in [(10,90),(-10,-90),(0,0),(0.1,0)] {
            XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clock",interval:interval,date:epoch.addingTimeInterval(5),timeZone:utc),angle,accuracy:0.00001)
        }
        XCTAssertEqual(ScriptWidgetAnimationPhase.period(-0.01),-0.25)
        for value in [Double.nan, .infinity, -.infinity] { XCTAssertEqual(ScriptWidgetAnimationPhase.period(value),10) }
        XCTAssertTrue(ScriptWidgetAnimationPhase.clockAngle(type:"clock",interval:1e308,date:Date(),timeZone:utc).isFinite)
        XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clock",date:Date(timeIntervalSince1970:1e308)),0)
    }
    func testClockTimezoneDSTAndMinuteTypoAlias() {
        let utc = TimeZone(secondsFromGMT:0)!, kathmandu = TimeZone(identifier:"Asia/Kathmandu")!
        XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clockMinute",date:epoch,timeZone:kathmandu),270,accuracy:0.00001)
        XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clockHour",date:epoch,timeZone:kathmandu),172.5,accuracy:0.00001)
        XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clockSecond",date:epoch.addingTimeInterval(15),timeZone:utc),90,accuracy:0.00001)
        let ny = TimeZone(identifier:"America/New_York")!, formatter = ISO8601DateFormatter()
        let before = formatter.date(from:"2026-03-08T06:59:59Z")!, after = formatter.date(from:"2026-03-08T07:00:00Z")!
        XCTAssertLessThan(ScriptWidgetAnimationPhase.clockAngle(type:"clockHour",date:before,timeZone:ny),60)
        XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clockHour",date:after,timeZone:ny),90,accuracy:0.00001)
        XCTAssertEqual(ScriptWidgetAnimationPhase.clockAngle(type:"clockMiniute",date:after,timeZone:ny),ScriptWidgetAnimationPhase.clockAngle(type:"clockMinute",date:after,timeZone:ny))
    }
    func testSwingFiniteLimitsSignedDistanceAndRestPose() {
        for (time, expected): (Double,Double) in [(0,0),(0.5,10),(1,0),(1.5,-10),(2,0)] {
            XCTAssertEqual(ScriptWidgetAnimationPhase.swing(elapsed:time,duration:1,distance:10),expected,accuracy:0.00001)
        }
        XCTAssertEqual(ScriptWidgetAnimationPhase.swing(elapsed:0.5,duration:1,distance:-10),-10,accuracy:0.00001)
        for value in [Double.nan, .infinity, -.infinity] { XCTAssertEqual(ScriptWidgetAnimationPhase.swing(elapsed:value,duration:1,distance:10),0) }
        XCTAssertTrue(ScriptWidgetAnimationPhase.swing(elapsed:1e308,duration:0.1,distance:1e308).isFinite)
        XCTAssertEqual(ScriptWidgetAnimationPhase.swingDistance(1e308),10_000)
        XCTAssertEqual(ScriptWidgetAnimationPhase.swingDuration(-1),1)
    }
    func testNativeAnimationPhaseCorpusForBrowser() throws {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try skipUnlessRepositoryCheckout(repository)
        let formatter = ISO8601DateFormatter()
        var cases: [[String:Any]] = []
        for instant in ["2001-01-01T00:00:05Z","2026-03-08T06:59:59Z","2026-03-08T07:00:00Z","2026-11-01T06:30:15Z"] {
            let date = formatter.date(from:instant)!
            for zone in ["UTC","Asia/Kathmandu","America/New_York","America/Los_Angeles"] {
                for type in ["clockSecond","clockMinute","clockMiniute","clockHour","clock"] {
                    for interval: Double in (type == "clock" ? [10,-10,0.1,1e308] : [10]) {
                        cases.append(["type":type,"date":date.timeIntervalSince1970*1000,"timezone":zone,"interval":interval,
                            "angle":ScriptWidgetAnimationPhase.clockAngle(type:type,interval:interval,date:date,timeZone:TimeZone(identifier:zone)!)])
                    }
                }
            }
        }
        let fixture = repository.appendingPathComponent("Web/preview-engine/test/parity/public-animation-phases.json")
        let encoded = try JSONSerialization.data(withJSONObject:cases,options:[.prettyPrinted,.sortedKeys])
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_ANIMATION_PHASES"] == "1" { try encoded.write(to:fixture,options:.atomic) }
        else {
            let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? NSArray
            XCTAssertEqual(saved,try JSONSerialization.jsonObject(with:encoded) as? NSArray)
        }
        XCTAssertEqual(cases.count,128)
    }
    @MainActor func testScheduledPresentationDateIsCapturedAndInvalidDatesDoNotOverrideViews() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("animation-date-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let package = ScriptWidgetPackage(path:root,readonly:true)
        let runtime = ScriptWidgetRuntime(package:package,environments:["timeline-date":"2026-11-01T06:30:15.000Z"])
        let expected = ISO8601DateFormatter().date(from:"2026-11-01T06:30:15Z")!
        XCTAssertEqual(runtime.presentationDate,expected)
        let context = ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Fixture",scriptParameter:"",package:package)
        XCTAssertEqual(context.animationDate,expected)
        runtime.setEnvironment("timeline-date","invalid")
        XCTAssertNil(runtime.presentationDate); XCTAssertEqual(context.animationDate,expected)
        let previousClock = ScriptWidgetRenderClock.fixedNow
        ScriptWidgetRenderClock.fixedNow = epoch
        defer { ScriptWidgetRenderClock.fixedNow = previousClock }
        let snapshot = ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Snapshot",scriptParameter:"",package:package)
        XCTAssertEqual(snapshot.animationDate,epoch)
        runtime.setEnvironment("timeline-date","2026-11-01T06:30:15.000Z")
        let planned = ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Planned",scriptParameter:"",package:package)
        XCTAssertEqual(planned.animationDate,expected)
    }
    func testNativeAnimationParsingKeepsSignedPeriodsAndRejectsNonfiniteJSON() {
        func modifier(_ value: String) -> ScriptWidgetAttributeAnimationModifier {
            .init(ScriptWidgetRuntimeElement(tagString:"rect",props:["animation":value],children:nil))
        }
        let configured = modifier("animation:{\"type\":\"clockHour\",\"timezone\":\"Asia/Kathmandu\",\"anchor\":\"topLeading\"}")
        XCTAssertEqual(configured.clockTimezone.identifier,"Asia/Kathmandu")
        XCTAssertEqual(configured.clockAnchor.x,0); XCTAssertEqual(configured.clockAnchor.y,0)
        XCTAssertEqual(modifier("clockCustom,-0.1").clockCustomInterval,-0.25)
        XCTAssertEqual(modifier("clockCustom,nan").animationType,"")
        XCTAssertEqual(modifier("animation:{\"type\":\"clock\",\"interval\":1e309}").animationType,"error")
        XCTAssertEqual(modifier("animation:{\"type\":\"swing\",\"duration\":-1,\"distance\":1e8}").swingDuration,1)
        XCTAssertEqual(modifier("animation:{\"type\":\"swing\",\"duration\":-1,\"distance\":1e8}").swingDistance,10_000)
    }
    @MainActor func testPublicTimelineSchedulesVisibleFramesAndStaticModeDoesNotAdvance() async throws {
        final class Probe {
            private let lock = NSLock(); private var values: [Double] = []
            func record(_ value: Double) { lock.lock(); defer { lock.unlock() }; if values.count < 256 { values.append(value) } }
            var samples: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let live = Probe(), frozen = Probe()
        func content(_ probe: Probe, _ preview: ScriptWidgetAnimationPreview) -> AnyView {
            AnyView(ScriptWidgetAnimationFrame { _, elapsed in
                let _ = probe.record(elapsed)
                Color(red:1,green:0,blue:0)
            }.environment(\.scriptWidgetAnimationPreview,preview).environment(\.scriptWidgetVisualAccessibility,.init(reduceMotion:false)).frame(width:80,height:40))
        }
        #if os(macOS)
        let host = NSHostingView(rootView:content(live,.init(live:true)))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:80,height:40),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:content(live,.init(live:true)))
        window.frame = CGRect(x:0,y:0,width:80,height:40); window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKey() }
        #endif
        let deadline = Date().addingTimeInterval(3)
        while live.samples.count < 3 && Date() < deadline { try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertGreaterThanOrEqual(live.samples.count,3)
        XCTAssertGreaterThan(live.samples.max() ?? 0,0.02)
        host.rootView = content(frozen,.init(live:false))
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertFalse(frozen.samples.isEmpty)
        XCTAssertTrue(frozen.samples.allSatisfy { $0 == 0 })
    }
    @MainActor func testPublicSwingAndClockRenderActualPosesAndExport() throws {
        func centroid<V:View>(_ content:V, name:String) throws -> Double {
            let renderer = ImageRenderer(content:content); renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating:0,count:width*height*4)
            let context = try XCTUnwrap(CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            var sum = 0.0, count = 0
            for y in 0..<height { for x in 0..<width { let p = (y*width+x)*4; if pixels[p]>200 && pixels[p+1]<40 && pixels[p+2]<40 && pixels[p+3]>200 { sum += Double(x); count += 1 } } }
            XCTAssertGreaterThan(count,10)
            if let output = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_PUBLIC_ANIMATION"] {
                #if os(macOS)
                let platform = "macos"
                #else
                let platform = "ios"
                #endif
                let root = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let bytes = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil))
                CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
                try (bytes as Data).write(to:root.appendingPathComponent(platform+"-"+name+".png"))
            }
            return sum / Double(max(count,1))
        }
        func swing(_ elapsed: Double) -> some View {
            ScriptWidgetAnimationFrame { _, time in Color(red:1,green:0,blue:0).frame(width:4,height:12).offset(x:ScriptWidgetAnimationPhase.swing(elapsed:time,duration:1,distance:10)) }
                .environment(\.scriptWidgetAnimationPreview,.init(elapsed:elapsed)).frame(width:80,height:40)
        }
        let rest = try centroid(swing(0),name:"swing-rest"), peak = try centroid(swing(0.5),name:"swing-peak")
        XCTAssertEqual(peak-rest,10,accuracy:0.5)
        let hand = ZStack { Color.clear; Color(red:1,green:0,blue:0).frame(width:4,height:16).offset(y:-8) }.frame(width:40,height:40)
        let element = ScriptWidgetRuntimeElement(tagString:"rect",props:["animation":"animation:{\"type\":\"clockSecond\",\"timezone\":\"UTC\"}"],children:nil)
        let zero = try centroid(hand.modifier(ScriptWidgetAttributeAnimationModifier(element,referenceDate:epoch)),name:"clock-zero")
        let quarterView = hand.modifier(ScriptWidgetAttributeAnimationModifier(element,referenceDate:epoch.addingTimeInterval(15)))
        let quarter = try centroid(quarterView,name:"clock-quarter")
        let reduced = try centroid(quarterView.environment(\.scriptWidgetVisualAccessibility,.init(reduceMotion:true)),name:"clock-reduced")
        XCTAssertEqual(quarter-zero,8,accuracy:0.5); XCTAssertEqual(reduced,quarter,accuracy:0.5)
    }
}

extension NativeStorageFileTests {
    private func legacyVolumeFixture(changedMount: Bool, retainMarker: Bool = false) throws -> (Data, UInt64) {
        let store = try ScriptWidgetStorageFiles(container: root)
        var values = ScriptWidgetStorageFileMap(); values["kept"] = "original record"
        try store.commitNamespace(ownerID: owner, values: values)
        let bytes = try Data(contentsOf: recordURL)
        let original = store.storageReceipt.device
        let logical = changedMount ? original ^ 1 : original
        var anchor = Data("SWANCH01".utf8)
        for value in [logical, store.storageReceipt.inode] {
            for shift in (0..<8).reversed() { anchor.append(UInt8((value >> (shift * 8)) & 255)) }
        }
        try anchor.write(to: root.appendingPathComponent(".ScriptWidgetStorage.v2.anchor"))
        if !retainMarker { try FileManager.default.removeItem(at: root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("volume")) }
        return (bytes, logical)
    }

    func testRemountedNativeVolumePreservesRecordsReceiptsAndLogicalDevice() throws {
        let (bytes, logical) = try legacyVolumeFixture(changedMount: true)
        let reopened = try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: root)
        XCTAssertEqual(reopened.storageReceipt.device, logical)
        XCTAssertEqual(try reopened.readNamespace(ownerID: owner)["kept"] as? String, "original record")
        XCTAssertEqual(try Data(contentsOf: recordURL), bytes)
        let source = root.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fd = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return XCTFail("Fixture directory could not open") }
        defer { close(fd) }
        let receipt = try ScriptWidgetStoragePublicationReceipt.capture(directory: fd, groupRoot: root)
        XCTAssertEqual(receipt.device, logical)
        let nested = try reopened.profileFiles(id: UUID().uuidString.lowercased())
        XCTAssertEqual(nested.storageReceipt.device, logical)
        XCTAssertEqual(try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: nil).storageReceipt, reopened.storageReceipt)
    }

    func testChangedLegacyMountOutsideNativeGroupIsNotAutomaticallyAdopted() throws {
        let (bytes, _) = try legacyVolumeFixture(changedMount: true)
        let anchorURL = root.appendingPathComponent(".ScriptWidgetStorage.v2.anchor")
        let anchor = try Data(contentsOf: anchorURL)
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: nil))
        XCTAssertEqual(try Data(contentsOf: anchorURL), anchor)
        XCTAssertEqual(try Data(contentsOf: recordURL), bytes)
    }

    func testLegacyVolumeUpgradeResumesAfterMarkerPublicationWithoutChangingRecords() throws {
        let (bytes, _) = try legacyVolumeFixture(changedMount: true, retainMarker: true)
        let reopened = try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: nil)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".ScriptWidgetStorage.v2.anchor")).prefix(8), Data("SWANCH02".utf8))
        XCTAssertEqual(try reopened.readNamespace(ownerID: owner)["kept"] as? String, "original record")
        XCTAssertEqual(try Data(contentsOf: recordURL), bytes)
    }

    func testModernVolumeProofCannotBeRemovedAndRecreatedAsLegacy() throws {
        let store = try ScriptWidgetStorageFiles(container: root)
        let marker = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("volume")
        try FileManager.default.removeItem(at: marker)
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: root))
        XCTAssertThrowsError(try store.readNamespace(ownerID: owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testForeignVolumeProofIsRejectedEvenForTheNativeRecoveryRoot() throws {
        let (bytes, _) = try legacyVolumeFixture(changedMount: true, retainMarker: true)
        let marker = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("volume")
        try (Data("SWVOL001".utf8) + Data(repeating: 0xff, count: 16)).write(to: marker)
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: root))
        XCTAssertEqual(try Data(contentsOf: recordURL), bytes)
    }

    func testVolumeProofSymlinkAndHardlinkDoNotAuthorizeAStore() throws {
        _ = try ScriptWidgetStorageFiles(container: root)
        let marker = root.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("volume")
        let kept = root.appendingPathComponent("kept-volume-proof")
        try FileManager.default.moveItem(at: marker, to: kept)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: kept)
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: root))
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.linkItem(at: kept, to: marker)
        XCTAssertThrowsError(try ScriptWidgetStorageFiles(container: root, legacyRecoveryRoot: root))
    }
}

#if os(iOS)
@available(iOS 17.0, *)
final class ScriptWidgetActionHostTests: XCTestCase {
    func testDeclaredActionsUseTheApplicationHostBeforeIOS27() {
        let actionType: Any.Type = RunScriptWidgetActionIntent.self
        let toggleType: Any.Type = SetScriptWidgetActionValueIntent.self
        XCTAssertTrue(actionType is any LiveActivityIntent.Type)
        XCTAssertTrue(toggleType is any LiveActivityIntent.Type)
    }
}
#endif
