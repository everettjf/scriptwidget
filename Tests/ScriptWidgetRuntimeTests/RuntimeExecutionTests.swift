//
//  RuntimeExecutionTests.swift
//  ScriptWidgetRuntimeTests
//
//  End-to-end JSX → SwiftUI-element execution tests for the shared runtime.
//  Unlike RuntimeUnitTests (pure logic), these drive the real
//  ScriptWidgetRuntime: Babel transpile (core.js) + util.js + the injected
//  $-APIs, then assert on the resulting element tree. They require the
//  bundled `support/` scripts and `Script.bundle`, which ship in the host
//  app — so they run hosted on the app target, on both iOS and macOS.
//
//  No network is involved; everything here is deterministic.
//

import XCTest
import JavaScriptCore
@testable import ScriptWidget

final class RuntimeExecutionTests: XCTestCase {

    /// A throwaway, writable package rooted in a unique temp directory.
    private func makeTempPackage() -> ScriptWidgetPackage {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScriptWidgetRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ScriptWidgetPackage(path: dir, readonly: false)
    }

    private func makeRuntime(environments: [String: String] = ["widget-size": "medium", "widget-param": ""]) -> ScriptWidgetRuntime {
        ScriptWidgetRuntime(package: makeTempPackage(), environments: environments)
    }

    /// Recursively collect string (text-node) children from an element tree so
    /// tests can assert on rendered text without depending on exact nesting.
    private func collectText(_ element: ScriptWidgetRuntimeElement) -> String {
        var out: [String] = []
        for child in element.getChildren() {
            if let s = child as? String {
                out.append(s)
            }
        }
        for child in element.childrenAsElements() {
            out.append(collectText(child))
        }
        return out.joined(separator: " ")
    }

    // MARK: - Happy path

    func testSimpleVStackRenders() {
        let (element, error) = makeRuntime().executeJSXSyncForWidget(
            "$render(<vstack><text>Hello</text></vstack>);"
        )
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        XCTAssertEqual(element?.tagAsString(), "vstack")
        XCTAssertEqual(collectText(element!).contains("Hello"), true)
    }

    func testNestedLayoutWithPropsRenders() {
        let jsx = """
        $render(
          <vstack frame="max" spacing={4}>
            <hstack>
              <text font="title">Left</text>
              <spacer />
              <text font="caption">Right</text>
            </hstack>
            <text>Body</text>
          </vstack>
        );
        """
        let (element, error) = makeRuntime().executeJSXSyncForWidget(jsx)
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        XCTAssertEqual(element?.tagAsString(), "vstack")
        let text = collectText(element!)
        XCTAssertTrue(text.contains("Left") && text.contains("Right") && text.contains("Body"),
                      "rendered text was: \(text)")
    }

    // MARK: - $getenv passthrough

    func testGetenvIsPassedIntoScript() {
        let runtime = makeRuntime(environments: ["widget-size": "large", "widget-param": "hello-param"])
        let jsx = """
        const size = $getenv("widget-size");
        const param = $getenv("widget-param");
        $render(<vstack><text>{size}</text><text>{param}</text></vstack>);
        """
        let (element, error) = runtime.executeJSXSyncForWidget(jsx)
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        let text = collectText(element!)
        XCTAssertTrue(text.contains("large"), "expected widget-size in output, got: \(text)")
        XCTAssertTrue(text.contains("hello-param"), "expected widget-param in output, got: \(text)")
    }

    func testRuntimeContractIsVisibleToScripts() {
        let jsx = "$render(<text>{$runtime.apiVersion}</text>);"
        let (element, error) = makeRuntime().executeJSXSyncForWidget(jsx)
        XCTAssertNil(error)
        XCTAssertTrue(collectText(element!).contains("1.0"))
    }

    func testNeverResolvingScriptTimesOut() {
        let start = Date()
        let (_, error) = makeRuntime().executeJSXSyncForWidget(
            "if (false) { $render(<text>never</text>); }"
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 7)
        guard case .resourceLimit = error else {
            return XCTFail("expected resource-limit timeout, got \(String(describing: error))")
        }
    }

    // MARK: - Error surfacing (PR #12: visible script errors)

    func testThrownErrorIsSurfaced() {
        let (element, error) = makeRuntime().executeJSXSyncForWidget(
            "throw new Error('boom problem'); $render(<text>never</text>);"
        )
        XCTAssertNil(element)
        XCTAssertNotNil(error, "a thrown error should surface instead of a blank widget")
        XCTAssertTrue(error?.displayMessage.contains("boom problem") ?? false,
                      "error message was: \(String(describing: error?.displayMessage))")
    }

    func testReferenceErrorIsSurfaced() {
        let (_, error) = makeRuntime().executeJSXSyncForWidget(
            "$render(<text>{thisVariableIsNotDefined}</text>);"
        )
        XCTAssertNotNil(error, "a ReferenceError should surface")
    }

    // MARK: - Missing $render fallback

    func testMissingRenderProducesFallbackSentinel() {
        // Scripts that never call $render should yield the documented
        // "#UI Not Found#" placeholder rather than crash or hang.
        let (element, error) = makeRuntime().executeJSXSyncForWidget("const unused = 1 + 1;")
        XCTAssertNil(error)
        XCTAssertNotNil(element)
        XCTAssertTrue(collectText(element!).contains("#UI Not Found#"),
                      "expected fallback sentinel, got: \(collectText(element!))")
    }

    // MARK: - Transpile cache is exercised by the real transform

    func testRepeatedRenderIsStable() {
        // Running the same source twice must yield the same successful result
        // (also exercises the on-disk/in-memory transpile cache path).
        let jsx = "$render(<text>cache me</text>);"
        let first = makeRuntime().executeJSXSyncForWidget(jsx)
        let second = makeRuntime().executeJSXSyncForWidget(jsx)
        XCTAssertNil(first.1)
        XCTAssertNil(second.1)
        XCTAssertEqual(first.0?.tagAsString(), second.0?.tagAsString())
    }

    func testNewBundledTemplatesRenderWithoutNetwork() throws {
        let templateNames = [
            "Weekly Planner",
            "Hydration Goal",
            "Personal Dashboard",
            "Quick Launcher",
            "Daily Agenda",
            "Pomodoro Focus",
            "Mood Check-in",
            "Reading Goal",
            "Savings Goal",
            "Birthday Countdown",
            "Packing Checklist",
            "Meal Planner",
            "Study Tracker",
            "Sleep Schedule",
            "Plant Care",
            "Daily Affirmation",
        ]

        for name in templateNames {
            let package = ScriptWidgetPackage(bundle: "Script", relativePath: "template/\(name)")
            let source = try XCTUnwrap(package.readMainFile().0, "missing source for \(name)")
            let runtime = ScriptWidgetRuntime(
                package: package,
                environments: ["widget-size": "medium", "widget-param": ""]
            )
            let (element, error) = runtime.executeJSXSyncForWidget(source)
            XCTAssertNil(error, "\(name) failed: \(String(describing: error?.displayMessage))")
            XCTAssertNotNil(element, "\(name) did not render an element")
        }
    }

    func testBundledTemplateCatalogContainsSixtyReadyToUseTemplates() throws {
        let templateDirectory = try XCTUnwrap(
            Bundle.main.url(forResource: "template", withExtension: nil, subdirectory: "Script.bundle")
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: templateDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let templateDirectories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        XCTAssertEqual(templateDirectories.count, 60)
        for directory in templateDirectories {
            let mainURL = directory.appendingPathComponent("main.jsx")
            let metadataURL = directory.appendingPathComponent("meta.json")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: mainURL.path),
                "missing main.jsx for \(directory.lastPathComponent)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: metadataURL.path),
                "missing meta.json for \(directory.lastPathComponent)"
            )
            let metadata = try JSONDecoder().decode(ScriptMetadata.self, from: Data(contentsOf: metadataURL))
            XCTAssertNotNil(
                metadata.category.flatMap(ScriptCategory.init(rawValue:)),
                "unknown category for \(directory.lastPathComponent)"
            )
            XCTAssertFalse(metadata.description?.isEmpty ?? true, "missing description for \(directory.lastPathComponent)")
        }
    }

    // MARK: - Dynamic Island path

    func testDynamicIslandRenders() {
        let jsx = """
        $dynamic_island({
          expanded: {
            leading: <text>L</text>,
            trailing: <text>T</text>,
            center: <text>C</text>,
            bottom: <text>B</text>,
          },
          compactLeading: <text>cl</text>,
          compactTrailing: <text>ct</text>,
          minimal: <text>m</text>,
        });
        """
        let (island, error) = makeRuntime().executeJSXSyncForDynamicIsland(jsx)
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        XCTAssertNotNil(island)
        XCTAssertEqual(island?.compactLeading.tagAsString(), "text")
    }
}
