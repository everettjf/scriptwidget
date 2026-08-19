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

    private func snapshot(_ element: ScriptWidgetRuntimeElement) -> String {
        let props = element.getProps().map { key, value in
            "\(String(describing: key))=\(String(describing: value))"
        }.sorted().joined(separator: ",")
        let children = element.getChildren().map { child -> String in
            if let nested = child as? ScriptWidgetRuntimeElement { return snapshot(nested) }
            if let nested = child as? [Any] {
                return nested.compactMap { $0 as? ScriptWidgetRuntimeElement }.map(snapshot).joined()
            }
            return "\"\(String(describing: child))\""
        }.joined(separator: ",")
        let tag = element.tagAsString() ?? "unknown"
        return "<\(tag){\(props)}>\(children)</\(tag)>"
    }

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

    #if os(macOS)
    func testFiveMinuteTutorialWidgetRendersOfflineInEveryCoreFamily() {
        for family in ["small", "medium", "large"] {
            let runtime = makeRuntime(environments: ["widget-size": family, "widget-param": ""])
            let (element, error) = runtime.executeJSXSyncForWidget(tutorialWidgetSource)
            XCTAssertNil(error, "\(family): \(String(describing: error?.displayMessage))")
            let text = element.map(collectText) ?? ""
            XCTAssertTrue(text.contains("Hello, ScriptWidget!"), text)
            XCTAssertTrue(text.contains(family), text)
        }
    }
    #endif

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

    func testCanonicalElementTreeGolden() {
        let jsx = "$render(<vstack alignment=\"leading\" spacing={8}><text font=\"headline\">Release</text><hstack><icon systemName=\"checkmark.circle.fill\"/><spacer/><text>Ready</text></hstack></vstack>);"
        let (element, error) = makeRuntime().executeJSXSyncForWidget(jsx)
        XCTAssertNil(error)
        XCTAssertEqual(
            snapshot(element!),
            "<vstack{alignment=leading,spacing=8}><text{font=headline}>\"Release\"</text>,<hstack{}><icon{systemName=checkmark.circle.fill}></icon>,<spacer{}></spacer>,<text{}>\"Ready\"</text></hstack></vstack>"
        )
    }

    func testCachedRuntimePerformanceBudget() {
        let source = "$render(<vstack><text>performance</text><spacer/><text>{$getenv(\"widget-size\")}</text></vstack>);"
        _ = makeRuntime().executeJSXSyncForWidget(source)
        let start = ContinuousClock.now
        for _ in 0..<10 {
            let result = makeRuntime().executeJSXSyncForWidget(source)
            XCTAssertNil(result.1)
            XCTAssertNotNil(result.0)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(3), "10 cached renders exceeded the release performance budget")
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

    func testWidgetRenderingModesReachRuntime() {
        for mode in ["fullColor", "accented", "vibrant"] {
            let runtime = makeRuntime(environments: [
                "widget-size": "medium",
                "widget-param": "",
                "widget-rendering-mode": mode,
            ])
            let (element, error) = runtime.executeJSXSyncForWidget(
                "$render(<text>{$getenv(\"widget-rendering-mode\")}</text>);"
            )
            XCTAssertNil(error)
            XCTAssertEqual(element.map(collectText), mode)
        }
    }

    func testRootCustomComponentIsResolvedBeforeReturning() {
        let jsx = """
        const Shell = ({children}) => <vstack background="#101014">{children}</vstack>;
        const App = () => <Shell><text>Resolved root</text></Shell>;
        $render(<App />);
        """
        let (element, error) = makeRuntime().executeJSXSyncForWidget(jsx)
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        XCTAssertEqual(element?.tagAsString(), "vstack")
        XCTAssertEqual(element?.getProps()["background"] as? String, "#101014")
        XCTAssertEqual(element.map(collectText), "Resolved root")
    }

    func testNestedCustomComponentsAreResolvedBeforeReturning() {
        let jsx = """
        const Badge = ({label}) => <hstack><icon systemName="star"/><text>{label}</text></hstack>;
        const Card = ({children}) => <vstack>{children}</vstack>;
        $render(<Card><Badge label="Nested component" /></Card>);
        """
        let (element, error) = makeRuntime().executeJSXSyncForWidget(jsx)
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        XCTAssertEqual(element?.tagAsString(), "vstack")
        XCTAssertEqual(element?.childrenAsElements().first?.tagAsString(), "hstack")
        XCTAssertTrue(element.map(collectText)?.contains("Nested component") ?? false)

        func containsUnresolvedComponent(_ element: ScriptWidgetRuntimeElement) -> Bool {
            if element.tagAsString() == nil { return true }
            return element.childrenAsElements().contains(where: containsUnresolvedComponent)
        }
        XCTAssertFalse(element.map(containsUnresolvedComponent) ?? true)
    }

    func testSingleChildRootFragmentIsResolved() {
        let (element, error) = makeRuntime().executeJSXSyncForWidget(
            "$render(<><vstack background=\"navy\"><text>One root</text></vstack></>);"
        )
        XCTAssertNil(error)
        XCTAssertEqual(element?.tagAsString(), "vstack")
        XCTAssertEqual(element?.getProps()["background"] as? String, "navy")
    }

    func testMultiChildRootFragmentRemainsAFragment() {
        let (element, error) = makeRuntime().executeJSXSyncForWidget(
            "$render(<><text>One</text><text>Two</text></>);"
        )
        XCTAssertNil(error)
        XCTAssertEqual(element?.tagAsString(), "Fragment")
        XCTAssertEqual(element?.childrenAsElements().count, 2)
    }

    func testRootFragmentWithTextAndElementIsNotIncorrectlyUnwrapped() {
        let (element, error) = makeRuntime().executeJSXSyncForWidget(
            "$render(<>Prefix<text>Body</text></>);"
        )
        XCTAssertNil(error)
        XCTAssertEqual(element?.tagAsString(), "Fragment")
        XCTAssertEqual(element?.getChildren().count, 2)
    }

    func testInvalidRootCustomComponentReturnIsRejected() {
        let (_, error) = makeRuntime().executeJSXSyncForWidget(
            "const App = () => 'not an element'; $render(<App />);"
        )
        XCTAssertTrue(error?.displayMessage.contains("must return a ScriptWidget element") ?? false)
    }

    func testInvalidNestedCustomComponentReturnIsRejected() {
        let (_, error) = makeRuntime().executeJSXSyncForWidget(
            "const Broken = () => 42; $render(<vstack><Broken /></vstack>);"
        )
        XCTAssertTrue(error?.displayMessage.contains("must return a ScriptWidget element") ?? false)
    }

    func testNestedComponentExpansionCannotBypassElementLimit() {
        let jsx = """
        const Flood = () => <vstack>{Array.from({length: 1001}, (_, index) => <text>{index}</text>)}</vstack>;
        $render(<vstack><Flood /></vstack>);
        """
        let (_, error) = makeRuntime().executeJSXSyncForWidget(jsx)
        guard case .resourceLimit = error else {
            return XCTFail("expected expanded element limit, got \(String(describing: error))")
        }
    }

    func testRecursiveCustomComponentIsBounded() {
        let (_, error) = makeRuntime().executeJSXSyncForWidget(
            "const Loop = () => <Loop />; $render(<Loop />);"
        )
        guard case .resourceLimit = error else {
            return XCTFail("expected component depth limit, got \(String(describing: error))")
        }
    }

    func testConcurrentRuntimesKeepEnvironmentStateIsolated() {
        let lock = NSLock()
        var rendered: [Int: String] = [:]
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let token = "runtime-\(index)"
            let runtime = makeRuntime(environments: ["widget-size": "medium", "widget-param": token])
            let (element, error) = runtime.executeJSXSyncForWidget(
                "$render(<text>{$getenv(\"widget-param\")}</text>);"
            )
            lock.lock()
            defer { lock.unlock() }
            if let error {
                failures.append("\(index): \(error.displayMessage)")
            } else if let element {
                rendered[index] = collectText(element)
            } else {
                failures.append("\(index): missing element")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertEqual(rendered.count, 8)
        for index in 0..<8 {
            XCTAssertEqual(rendered[index], "runtime-\(index)")
        }
    }

    func testIPadWidgetFamiliesReachRuntime() {
        for family in ["extraLarge", "extraLargePortrait"] {
            let runtime = makeRuntime(environments: ["widget-size": family, "widget-param": "ipad"])
            let (element, error) = runtime.executeJSXSyncForWidget(
                "$render(<text>{$getenv(\"widget-size\") + ':' + $getenv(\"widget-param\")}</text>);"
            )
            XCTAssertNil(error)
            XCTAssertTrue(collectText(element!).contains("\(family):ipad"))
        }
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
            "Animation Golden Bloom",
            "Animation Lissajous",
            "Animation Orbital Resonance",
            "Animation Phase Wave",
            "Animation Spirograph",
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

    func testBundledTemplateCatalogContainsReadyToUseTemplates() throws {
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

        XCTAssertGreaterThanOrEqual(templateDirectories.count, 65)
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

    func testEveryBundledTemplateRendersWithDefaultConfiguration() throws {
        let templateDirectory = try XCTUnwrap(
            Bundle.main.url(forResource: "template", withExtension: nil, subdirectory: "Script.bundle")
        )
        let directories = try FileManager.default.contentsOfDirectory(
            at: templateDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        XCTAssertGreaterThanOrEqual(directories.count, 65)

        for directory in directories {
            let name = directory.lastPathComponent
            let package = ScriptWidgetPackage(path: directory, readonly: true)
            let source = try XCTUnwrap(package.readMainFile().0, "missing source for \(name)")
            // Public-network availability is not a deterministic test input.
            // Network templates are covered by catalog/source validation and a
            // manually-triggered integration pass; offline templates execute here.
            if source.contains("fetch(") || source.contains("$http.") ||
                source.contains("$location.") || source.contains("$health.") {
                XCTAssertNil(ScriptWidgetRuntimeContract.validateSource(source), name)
                continue
            }
            let runtime = ScriptWidgetRuntime(
                package: package,
                environments: ["widget-size": "medium", "widget-param": ""]
            )
            let (element, error) = runtime.executeJSXSyncForWidget(source)
            XCTAssertNil(error, "\(name) failed: \(String(describing: error?.displayMessage))")
            XCTAssertNotNil(element, "\(name) did not render a root element")
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

    func testDynamicIslandCustomComponentsAreResolvedBeforeReturning() {
        let jsx = """
        const Region = ({text}) => <hstack><text>{text}</text></hstack>;
        $dynamic_island({
          expanded: {
            leading: <Region text="L" />,
            trailing: <Region text="T" />,
            center: null,
            bottom: null,
          },
          compactLeading: <Region text="cl" />,
          compactTrailing: <Region text="ct" />,
          minimal: <Region text="m" />,
        });
        """
        let (island, error) = makeRuntime().executeJSXSyncForDynamicIsland(jsx)
        XCTAssertNil(error, "unexpected error: \(String(describing: error?.displayMessage))")
        XCTAssertEqual(island?.expanded.leading?.tagAsString(), "hstack")
        XCTAssertEqual(island?.compactLeading.tagAsString(), "hstack")
        XCTAssertEqual(island?.compactTrailing.tagAsString(), "hstack")
        XCTAssertEqual(island?.minimal.tagAsString(), "hstack")
    }
}
