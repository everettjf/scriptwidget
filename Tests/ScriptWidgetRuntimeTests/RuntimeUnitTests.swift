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
// Both the iOS and macOS apps build with module name "ScriptWidget"
// (the macOS target "ScriptWidgetMac" ships PRODUCT_NAME = ScriptWidget).
@testable import ScriptWidget

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
}

final class TranspileCacheTests: XCTestCase {

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
