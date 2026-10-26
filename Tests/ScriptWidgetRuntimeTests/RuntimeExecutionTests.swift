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
import Photos
import Darwin
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif
@testable import ScriptWidget

// These functional tests exercise native snapshots and persistence, not cold
// Babel startup on a shared CI simulator. Prepare real compiler output without
// executing widget code or extending either production deadline. Cached-runtime
// performance and execution/compilation limits retain separate coverage.
private func prepareFunctionalTranspile(_ source: String, wrapMain: Bool = true) throws {
    let input = wrapMain ? ScriptWidgetCompiler.wrappedSource(source) : source
    let key = ScriptWidgetTranspileCache.key(for: input, babelFingerprint: ScriptWidgetCompiler.fingerprint)
    guard ScriptWidgetTranspileCache.get(key) == nil else { return }
    let babel = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "support", fileName: "core.js"))
    let output = try ScriptWidgetCompiler.compile(input, babelContent: babel).get()
    ScriptWidgetTranspileCache.set(key, output)
}

private enum WeatherTemplateFixtures {
    static let now = 1767269700000.0
    static let parameter = #"{"city":"London","latitude":51.5,"longitude":-0.12,"useLocation":false,"unit":"c"}"#
    static var directory: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web/preview-engine/test/parity") }
    static func body() throws -> String {
        let url=directory.appendingPathComponent("weather-response.json")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Weather corpus fixtures require the repository checkout") }
        return try String(contentsOf:url,encoding:.utf8)
    }
    static func source(_ main: String, mode: String) throws -> String {
        let body=try body(), response: [String:Any] = ["status":200,"body":body,"headers":["expires":"Thu, 01 Jan 2026 13:00:00 GMT","last-modified":"Thu, 01 Jan 2026 12:00:00 GMT"]]
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:response,options:[.sortedKeys]),as:UTF8.self)
        var prefix="""
        let fixtureClock=\(now); Date.now=()=>fixtureClock; Math.random=()=>0;
        globalThis.$location={isAvailable:()=>false,authorizationStatus:()=>"unavailable",isAuthorizedForWidgetUpdates:()=>false};
        globalThis.$http={getResponse:()=>({then(resolve,reject){resolve(\(encoded));}})};
        """
        if mode == "saved" || mode == "stale" {
            prefix += "\nif(!$import('lib/weather.js'))throw new Error('fixture import'); await localWeather.load(localWeather.options('',\(String(decoding:try JSONEncoder().encode(parameter),as:UTF8.self))),fixtureClock,false);"
        }
        if mode == "stale" { prefix += "\nfixtureClock+=3600000;" }
        if mode == "stale" || mode == "unavailable" { prefix += "\nglobalThis.$http={getResponse:()=>({then(resolve,reject){reject('isolated network failure');}})};" }
        return prefix + "\n" + main
    }
}

final class RuntimeExecutionTests: XCTestCase {

    func testValidationHostReplacesSystemAPIsBeforeEntryAndImportedCode() throws {
        let package = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: package.path) }
        try "function fixtureLocale() { return $system.locale(); }".write(to: package.path.appendingPathComponent("helper.jsx"), atomically: true, encoding: .utf8)
        let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium"])
        runtime.validationHostInstaller = { context in
            context.evaluateScript("$system = Object.freeze({locale: function () { return 'validation-fixture'; }});")
        }
        let result = runtime.executeJSXSyncForWidget("$import('helper.jsx'); $render(<text>{fixtureLocale()}</text>);")
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), "validation-fixture")
        let normal = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium"])
        XCTAssertNil(normal.validationHostInstaller)
        let other = normal.executeJSXSyncForWidget("$render(<text>{typeof $system.locale}</text>);")
        XCTAssertEqual(collectText(try XCTUnwrap(other.0)), "function")
    }


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
        storageRuntime(package: makeTempPackage(), environments: environments)
    }

    private func storageRuntime(package: ScriptWidgetPackage, environments: [String: String]) -> ScriptWidgetRuntime {
        let runtime = ScriptWidgetRuntime(package: package, environments: environments)
        #if DEBUG
        // An isolated available backend, regardless of signing on this host.
        // Signed app-group acceptance is separate from these bridge tests.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWidgetAtomicBridge-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runtime.runningState?.storageContainerForTesting = root
        runtime.runningState?.storageDefaultsForTesting = UserDefaults(suiteName: "app.scriptwidget.atomic.bridge.\(ProcessInfo.processInfo.processIdentifier)")
        #endif
        return runtime
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

    func testNumericSquareFrameSurvivesJSXBridge() throws {
        let output = makeRuntime().executeJSXSyncForWidget("$render(<ring value={0.75} frame={64} />);")
        XCTAssertNil(output.1)
        let frame = ScriptWidgetAttributeFrameModifier(try XCTUnwrap(output.0))
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 64)
    }

    private func habitSource(day: Int, month: Int = 3, year: Int = 2026) throws -> String {
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Habit Heatmap/main.jsx"))
        return """
        const NativeDate = Date;
        Date = class extends NativeDate {
          constructor(...args) { super(...(args.length ? args : [\(year), \(month - 1), \(day), 12])); }
        };
        """ + source
    }

    private func habitRuntime(_ package: ScriptWidgetPackage, size: String = "medium") -> ScriptWidgetRuntime {
        if !FileManager.default.fileExists(atPath: package.path.appendingPathComponent("lib/records.js").path),
           let source = ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Habit Heatmap/lib/records.js") {
            XCTAssertTrue(ScriptWidgetPackageFiles.write(Data(source.utf8), root: package.path, relative: "lib/records.js"))
        }
        return storageRuntime(package: package, environments: ["widget-size": size, "widget-param": ""])
    }

    func testHabitHeatmapExplicitCheckInPersistsAndDoesNotDoubleCount() throws {
        let package = makeTempPackage()
        defer {
            _ = habitRuntime(package).executeJSXSyncForWidget("$storage.clear(); $render(<text>clean</text>);")
            try? FileManager.default.removeItem(at: package.path)
        }
        func text(_ day: Int, size: String = "medium") throws -> String {
            let result = habitRuntime(package, size: size).executeJSXSyncForWidget(try habitSource(day: day))
            XCTAssertNil(result.1)
            return collectText(try XCTUnwrap(result.0))
        }
        func tap(_ day: Int, _ action: String = "checkInRead") throws {
            let result = habitRuntime(package, size: "action").executeJSXSyncForFunction(try habitSource(day: day), action)
            XCTAssertNil(result.1, String(describing: result.1))
        }
        XCTAssertTrue(try text(7).contains("0 days"))
        XCTAssertTrue(try text(7).contains("Check in"))
        try tap(7)
        try tap(7)
        XCTAssertTrue(try text(7).contains("1 day"))
        XCTAssertTrue(try text(7).contains("Done today"))
        // March 8 crosses the US spring DST boundary. Yesterday's streak remains
        // visible until today's check-in; a refresh alone must not complete today.
        XCTAssertTrue(try text(8).contains("1 day"))
        XCTAssertTrue(try text(8).contains("Check in"))
        try tap(8)
        XCTAssertTrue(try text(8).contains("2 days"))
        XCTAssertTrue(try text(10).contains("0 days"))
        try tap(10)
        try tap(10, "checkInRun")
        let stored = habitRuntime(package).executeJSXSyncForWidget("""
        $render(<text>{$storage.getString("habitHeatmap.v1.read") + "|" + $storage.getString("habitHeatmap.v1.run")}</text>);
        """)
        let heatmap = habitRuntime(package, size: "action").executeJSXSyncForWidget(try habitSource(day: 10) + "\n$render(<text>{String(logs[0].filter(level => level === 4).length)}</text>);")
        XCTAssertNil(heatmap.1)
        XCTAssertEqual(collectText(try XCTUnwrap(heatmap.0)), "3")
        XCTAssertEqual(collectText(try XCTUnwrap(stored.0)), #"["2026-03-07","2026-03-08","2026-03-10"]|["2026-03-10"]"#)
        for family in ["small", "medium", "large", "extraLarge", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
            let result = habitRuntime(package, size: family).executeJSXSyncForWidget(try habitSource(day: 10))
            XCTAssertNil(result.1, family)
            XCTAssertNotNil(result.0, family)
        }
        let unrelated = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: unrelated.path) }
        let fresh = habitRuntime(unrelated).executeJSXSyncForWidget(try habitSource(day: 10))
        XCTAssertTrue(collectText(try XCTUnwrap(fresh.0)).contains("0 days"))
    }

    func testHabitHeatmapRejectsCorruptHistoryAndReportsSaveFailure() throws {
        let source = try habitSource(day: 1, month: 1)
        for value in ["not json", #"["2026-02-30"]"#, #"{"unexpected":true}"#] {
            let encoded = String(data: try JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            let stub = """
            $storage = { getString: (key) => key === "recordTemplate.config.v1" ? "" : \(encoded)[0], setString: () => { throw new Error("must not overwrite"); } };
            """
            let output = habitRuntime(makeTempPackage(), size: "action").executeJSXSyncForFunction(stub + source, "checkInRead")
            XCTAssertTrue(output.1?.displayMessage.contains("history") == true)
        }
        let failed = habitRuntime(makeTempPackage(), size: "action").executeJSXSyncForFunction(
            "$storage = { getString: () => '', compareAndSetString: () => false };" + source, "checkInRead")
        XCTAssertTrue(failed.1?.displayMessage.contains("Could not save check-in") == true)
        // Real calendar keys around year boundaries, rather than UTC date strings.
        let output = habitRuntime(makeTempPackage()).executeJSXSyncForWidget(source + "\n$render(<text>{dateKey(dayOffset(today, -1))}</text>);")
        XCTAssertNil(output.1)
        XCTAssertEqual(collectText(try XCTUnwrap(output.0)), "2025-12-31")
    }

    func testRecordTemplatesPersistUndoAndResetThroughRealImportsAndBridge() throws {
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "Script", withExtension: "bundle"))
        for (name, key, actions, expected) in [
            ("Hydration Goal", "hydration.v1", "addGlass(); addGlass(); resetToday(); undoRecord();", "500"),
            ("Mood Check-in", "mood.v1", "moodFour(); moodFour(); moodTwo(); undoRecord(); undoRecord();", "4"),
            ("Packing Checklist", "checklist.v1", "toggleOne(); toggleTwo(); resetToday(); undoRecord();", #"["Charger","Passport"]"#),
            ("Habit Streak Tracker", "habitStreak.v2", "checkIn(); checkIn(); resetToday(); undoRecord();", "1"),
        ] {
            let package = makeTempPackage()
            try FileManager.default.removeItem(at: package.path)
            try FileManager.default.copyItem(at: bundle.appendingPathComponent("template/" + name), to: package.path)
            defer {
                _ = storageRuntime(package: package, environments: ["widget-size": "function"]).executeJSXSyncForWidget("$storage.clear(); $render(<text>clean</text>);")
                try? FileManager.default.removeItem(at: package.path)
                if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: package.name) }
            }
            let source = try String(contentsOf: package.path.appendingPathComponent("main.jsx"), encoding: .utf8)
            let clock = "const OriginalDate=Date; Date=class extends OriginalDate { constructor(...args) { super(...(args.length ? args : [2026,2,8,12])); } };\n"
            func run(_ suffix: String, size: String = "function") throws -> String {
                let result = storageRuntime(package: package, environments: ["widget-size": size, "widget-param": ""]).executeJSXSyncForWidget(clock + source + suffix)
                XCTAssertNil(result.1, "\(name): \(String(describing: result.1))")
                return collectText(try XCTUnwrap(result.0))
            }
            // A normal refresh must never create a record.
            let inspect = "\n$render(<text>{$storage.getString('\(key)')}</text>);"
            XCTAssertEqual(try run(inspect, size: "large"), "")
            let saved = try run("\n" + actions + inspect)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
            let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, name)
            XCTAssertEqual(entries[0]["date"] as? String, "2026-03-08", name)
            let value = try JSONSerialization.data(withJSONObject: entries[0]["value"]!, options: [.fragmentsAllowed, .sortedKeys])
            XCTAssertEqual(String(data: value, encoding: .utf8), expected, name)
            XCTAssertTrue(state["undo"] is NSNull)
            XCTAssertEqual(try run(inspect), saved, "A new runtime must see the saved record")
            for family in ["small", "medium", "large", "extraLarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
                XCTAssertFalse(try run("", size: family).isEmpty, "\(name)/\(family)")
            }
        }
    }

    func testNativeRecordConfigurationReachesRealWidgetActionsAndInstanceOverrides() throws {
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "Script", withExtension: "bundle"))
        let package = makeTempPackage()
        try FileManager.default.removeItem(at: package.path)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("template/Hydration Goal"), to: package.path)
        defer {
            _ = storageRuntime(package: package, environments: ["widget-size": "function"]).executeJSXSyncForWidget("$storage.clear(); $render(<text>clean</text>);")
            try? FileManager.default.removeItem(at: package.path)
            if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: package.name) }
        }
        let prepared = storageRuntime(package: package, environments: ["widget-size": "function", "widget-param": ""])
        #if DEBUG
        let defaults = try XCTUnwrap(prepared.runningState?.storageDefaultsForTesting)
        let container = try XCTUnwrap(prepared.runningState?.storageContainerForTesting)
        let store = try ScriptWidgetRecordStore(package: package, container: container, defaults: defaults)
        let before = try store.read()
        try store.apply(store.settingConfiguration(["goal": 12, "glassML": 300], in: before), expected: before)
        let source = try String(contentsOf: package.path.appendingPathComponent("main.jsx"), encoding: .utf8)
        let inspect = "\naddGlass(); $render(<text>{String(target)+'|'+String(glassML)+'|'+String(JSON.parse($storage.getString('hydration.v1')).entries[0].value)}</text>);"
        let result = prepared.executeJSXSyncForWidget(source + inspect)
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), "3600|300|300")
        let instance = storageRuntime(package: package, environments: ["widget-size": "function", "widget-param": #"{"goal":4,"glassML":200}"#])
        let override = instance.executeJSXSyncForWidget(source + inspect)
        XCTAssertNil(override.1)
        XCTAssertEqual(collectText(try XCTUnwrap(override.0)), "800|200|500")
        XCTAssertEqual(try store.rows(in: store.read()).first?.value, "500 mL")
        #else
        throw XCTSkip("Requires isolated storage backend")
        #endif
    }

    func testRecordCapacityCorruptionAndUnavailableStoragePreserveNativeHistory() throws {
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "Script", withExtension: "bundle"))
        let package = makeTempPackage()
        try FileManager.default.removeItem(at: package.path)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("template/Hydration Goal"), to: package.path)
        defer {
            _ = storageRuntime(package: package, environments: ["widget-size": "function"]).executeJSXSyncForWidget("$storage.clear(); $render(<text>clean</text>);")
            try? FileManager.default.removeItem(at: package.path)
            if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: package.name) }
        }
        let source = try String(contentsOf: package.path.appendingPathComponent("main.jsx"), encoding: .utf8)
        let clock = "const OriginalDate=Date; Date=class extends OriginalDate { constructor(...args) { super(...(args.length ? args : [2026,2,8,12])); } };\n"
        let fixtures = [
            (#"{"version":1,"revision":1,"entries":[{"date":"2026-03-08","value":63900}],"undo":null}"#, "record limit would be exceeded", false),
            (#"{"version":1,"revision":1,"entries":[{"date":"2026-02-30","value":250}],"undo":null}"#, "Saved history is invalid", false),
            (#"{"version":1,"revision":1,"entries":[{"date":"2026-03-08","value":250}],"undo":null}"#, "storage:unavailable", true),
        ]
        for (raw, expected, unavailable) in fixtures {
            let encoded = String(data: try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed), encoding: .utf8)!
            let setup = storageRuntime(package: package, environments: ["widget-size": "function"])
            XCTAssertNil(setup.executeJSXSyncForWidget("$storage.setString('hydration.v1', \(encoded)); $render(<text>seeded</text>);").1)
            let runtime = storageRuntime(package: package, environments: ["widget-size": "function", "widget-param": ""])
            #if DEBUG
            if unavailable { runtime.runningState?.storageContainerForTesting = FileManager.default.temporaryDirectory.appendingPathComponent("UnavailableRecordContainer-\(UUID().uuidString)") }
            #endif
            let result = runtime.executeJSXSyncForFunction(clock + source, "addGlass")
            XCTAssertTrue(result.1?.displayMessage.contains(expected) == true, String(describing: result.1))
            let inspect = storageRuntime(package: package, environments: ["widget-size": "function"]).executeJSXSyncForWidget("$render(<text>{$storage.getString('hydration.v1')}</text>);")
            XCTAssertNil(inspect.1)
            XCTAssertEqual(collectText(try XCTUnwrap(inspect.0)), raw)
        }
    }

    func testHabitStreakMigrationNeverMarksRefreshOrRewritesLegacyCounters() throws {
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "Script", withExtension: "bundle"))
        let package = makeTempPackage()
        try FileManager.default.removeItem(at: package.path)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("template/Habit Streak Tracker"), to: package.path)
        defer {
            _ = storageRuntime(package: package, environments: ["widget-size": "function"]).executeJSXSyncForWidget("$storage.clear(); $render(<text>clean</text>);")
            try? FileManager.default.removeItem(at: package.path)
            if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: package.name) }
        }
        func runtime(_ size: String = "function") -> ScriptWidgetRuntime {
            storageRuntime(package: package, environments: ["widget-size": size, "widget-param": "Read"])
        }
        XCTAssertNil(runtime().executeJSXSyncForWidget("$storage.setString('habit.lastDate','2026-03-07'); $storage.setString('habit.streak','912'); $render(<text>seeded</text>);").1)
        let source = try String(contentsOf: package.path.appendingPathComponent("main.jsx"), encoding: .utf8)
        let rendered = runtime("large").executeJSXSyncForWidget(source)
        XCTAssertNil(rendered.1)
        let text = collectText(try XCTUnwrap(rendered.0))
        XCTAssertTrue(text.contains("0 days")); XCTAssertTrue(text.contains("912 (unverified)"))
        let inspect = "$render(<text>{JSON.stringify({history:$storage.getString('habitStreak.v2'),oldDate:$storage.getString('habit.lastDate'),oldStreak:$storage.getString('habit.streak')})}</text>);"
        let initial = runtime().executeJSXSyncForWidget(inspect)
        let raw = collectText(try XCTUnwrap(initial.0))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String])
        XCTAssertEqual(decoded, ["history": "", "oldDate": "2026-03-07", "oldStreak": "912"])
        XCTAssertNil(runtime().executeJSXSyncForFunction(source, "checkIn").1)
        XCTAssertNil(runtime().executeJSXSyncForFunction(source, "checkIn").1)
        let current = runtime().executeJSXSyncForWidget(inspect)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(collectText(try XCTUnwrap(current.0)).utf8)) as? [String: String])
        XCTAssertEqual(saved["oldDate"], "2026-03-07"); XCTAssertEqual(saved["oldStreak"], "912")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(saved["history"]).utf8)) as? [String: Any])
        XCTAssertEqual((state["entries"] as? [Any])?.count, 1)
        XCTAssertEqual(state["revision"] as? Int, 1)
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testLegacyWidgetActionRetainsItsConfigurationParameter() throws {
        let package = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: package.path) }
        let parameter = "Tickets,Water,Keys"
        let intent = ButtonActionAppIntent(functionName: "toggleOne", package: package, scriptParameter: parameter)
        XCTAssertEqual(intent.actionEnvironments["widget-param"], parameter)
        XCTAssertEqual(intent.actionEnvironments["widget-size"], "function")
        XCTAssertEqual(intent.actionEnvironments["action-source"], "widget")
        let source = "$render(<text>{$getenv('widget-param')}</text>);"
        let result = storageRuntime(package: package, environments: intent.actionEnvironments).executeJSXSyncForWidget(source)
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), parameter)
        XCTAssertEqual(ButtonActionAppIntent(functionName: "noop", package: package).actionEnvironments["widget-param"], "")
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

    func testConcurrentRuntimesKeepEnvironmentStateIsolated() throws {
        let source = "$render(<text>{$getenv(\"widget-param\")}</text>);"
        // Exercise concurrent environment isolation without racing eight cold
        // Babel compilations of identical source on constrained CI simulators.
        // Each concurrent execution still gets its own package and JSContext.
        let warmup = makeRuntime(environments: ["widget-size": "medium", "widget-param": "warmup"])
            .executeJSXSyncForWidget(source)
        XCTAssertNil(warmup.1)
        XCTAssertEqual(collectText(try XCTUnwrap(warmup.0)), "warmup")

        let lock = NSLock()
        var rendered: [Int: String] = [:]
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let token = "runtime-\(index)"
            let runtime = makeRuntime(environments: ["widget-size": "medium", "widget-param": token])
            let (element, error) = runtime.executeJSXSyncForWidget(source)
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
        XCTAssertEqual(collectText(element!), ScriptWidgetRuntimeContract.apiVersion)
    }

    func testXMLParserReturnsStructuredNodes() {
        let source = """
        const root = $xml.parse('<feed lang="en"><title>News &amp; More</title><item id="7"><![CDATA[Hi]]></item></feed>');
        const title = root.children.find(node => node.name === 'title');
        const item = root.children.find(node => node.name === 'item');
        $render(<text>{root.name + ':' + root.attributes.lang + ':' + title.text + ':' + item.attributes.id + ':' + item.text}</text>);
        """
        let (element, error) = makeRuntime().executeJSXSyncForWidget(source)
        XCTAssertNil(error, "\(String(describing: error?.displayMessage))")
        XCTAssertEqual(element.map(collectText), "feed:en:News & More:7:Hi")
    }

    func testXMLParserRejectsInvalidAndUnsafeInput() {
        let source = """
        const cases = [
          '<feed><title></feed>',
          '<!DOCTYPE feed [<!ENTITY secret SYSTEM "file:///etc/passwd">]><feed>&secret;</feed>',
          '<feed>' + '<item/>'.repeat(2049) + '</feed>',
          '<feed>' + 'x'.repeat(262145) + '</feed>'
        ];
        const rejected = cases.every(input => {
          try { $xml.parse(input); return false; } catch (error) { return true; }
        });
        $render(<text>{String(rejected)}</text>);
        """
        let (element, error) = makeRuntime().executeJSXSyncForWidget(source)
        XCTAssertNil(error, "\(String(describing: error?.displayMessage))")
        XCTAssertEqual(element.map(collectText), "true")
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

    /// Asserts the runaway script released its thread and its VM.
    /// JavaScriptCore serialises entry into a VM, so while a loop spins a
    /// follow-up execution on the same runtime blocks until it, too, hits the
    /// execution limit. Runtimes are single-use, so the follow-up fails on
    /// redeclaring util.js globals; reaching that error promptly proves the
    /// VM accepted new work. Process-wide CPU sampling is not evidence about
    /// this VM: compiler, WebKit and other hosted-test work can run concurrently.
    private func assertRuntimeStopped(_ runtime: ScriptWidgetRuntime, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        let (_, error) = runtime.executeJSXSyncForWidget("$render(<text>after</text>);")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "runtime VM still locked", file: file, line: line)
        if case .resourceLimit = error {
            XCTFail("runtime VM still busy: \(String(describing: error))", file: file, line: line)
        }
    }

    func testRunawaySynchronousLoopIsTerminatedAtTimeLimit() {
        let runtime = makeRuntime()
        let start = Date()
        let (element, error) = runtime.executeJSXSyncForWidget(
            "while (true) {} $render(<text>never</text>);"
        )
        XCTAssertNil(element)
        XCTAssertLessThan(Date().timeIntervalSince(start), 7)
        guard case .resourceLimit = error else {
            return XCTFail("expected resource-limit timeout, got \(String(describing: error))")
        }
        assertRuntimeStopped(runtime)
    }

    func testRunawayFunctionLoopIsTerminatedAtTimeLimit() {
        let runtime = makeRuntime()
        let (_, error) = runtime.executeJSXSyncForFunction(
            "async function onTap() { while (true) {} }", "onTap"
        )
        guard case .resourceLimit = error else {
            return XCTFail("expected resource-limit timeout, got \(String(describing: error))")
        }
        assertRuntimeStopped(runtime)
    }

    func testCompilerRejectsExpiredDeadline() {
        let result = ScriptWidgetCompiler.compile("x", babelContent: "", timeLimit: 0)
        guard case .failure(.resourceLimit) = result else {
            return XCTFail("expected resource-limit failure, got \(result)")
        }
    }

    func testTimeoutCannotBeSwallowedByCatchOrFinally() {
        let runtime = makeRuntime()
        let (_, error) = runtime.executeJSXSyncForWidget("""
            try { while (true) { try { while (true) {} } catch (e) {} } }
            finally { while (true) {} }
            """)
        guard case .resourceLimit = error else {
            return XCTFail("expected resource-limit timeout, got \(String(describing: error))")
        }
        assertRuntimeStopped(runtime)
    }

    func testDynamicCodeCannotBypassExecutionGuard() {
        for source in [
            "eval('while (true) {}')",
            "(0, eval)('while (true) {}')",
            "new Function('while (true) {}')()",
            "(() => {}).constructor('while (true) {}')()",
            "(async function(){}).constructor('while (true) {}')()",
            "(function*(){}).constructor('while (true) {}')().next()",
            "(async function*(){}).constructor('while (true) {}')().next()"
        ] {
            let start = Date()
            let (_, error) = makeRuntime().executeJSXSyncForWidget(source)
            XCTAssertNotNil(error, source)
            XCTAssertTrue(error?.displayMessage.contains("Dynamic code") == true, source)
            XCTAssertLessThan(Date().timeIntervalSince(start), 3, source)
        }
    }

    func testGuardCannotBeShadowedOrReplaced() {
        let (_, shadowError) = makeRuntime().executeJSXSyncForWidget("""
            function run(__scriptWidgetCheckExecution) { /* private-widget-source-marker */ while (true) {} }
            run(() => {});
            """)
        XCTAssertNotNil(shadowError)
        XCTAssertTrue(shadowError?.displayMessage.contains("Reserved runtime identifier") == true)
        XCTAssertFalse(shadowError?.displayMessage.contains("private-widget-source-marker") == true,
                       "compiler policy errors must not include source fragments in public runtime logs")

        let (element, error) = makeRuntime().executeJSXSyncForWidget("""
            const descriptor = Object.getOwnPropertyDescriptor(globalThis, '__scriptWidgetCheckExecution');
            $render(<text>{String(descriptor.writable) + ':' + String(descriptor.configurable)}</text>);
            """)
        XCTAssertNil(error)
        XCTAssertTrue(element.map(collectText)?.contains("false:false") ?? false)
    }

    func testInstrumentedLoopAndFunctionFormsPreserveResults() {
        let (element, error) = makeRuntime().executeJSXSyncForWidget("""
            let total = 0;
            for (let i = 0; i < 3; i++) total += i;
            for (const value of [1, 2]) total += value;
            for (const key in {x: 1}) total += key.length;
            do { total++; } while (total < 9);
            const twice = value => value * 2;
            const boundTwice = Function.prototype.bind.call(twice, null);
            function* values() { yield boundTwice(total); }
            $render(<text>{String(values().next().value)}</text>);
            """)
        XCTAssertNil(error)
        XCTAssertTrue(element.map(collectText)?.contains("18") ?? false)
    }

    func testBusyButFiniteScriptIsNotInterruptedBeforeTimeLimit() {
        // A busy finite loop must still complete within the execution limit.
        let (element, error) = makeRuntime().executeJSXSyncForWidget("""
            const start = Date.now();
            while (Date.now() - start < 800) {}
            $render(<text>finished</text>);
            """)
        XCTAssertNil(error)
        XCTAssertTrue(element.map(collectText)?.contains("finished") ?? false)
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

    private func calendarSelectionFixture() throws -> (root: URL, package: ScriptWidgetPackage, defaults: UserDefaults, suite: String) {
        let root = makeTempPackage().path, path = root.appendingPathComponent("Widget")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let package = ScriptWidgetPackage(path: path, readonly: false)
        var manifest = WidgetPackageManifest.newProject(name: "Widget")
        manifest.permissions = [.calendar]; manifest.minimumRuntimeVersion = "1.3"
        try JSONEncoder().encode(manifest).write(to: path.appendingPathComponent("widget.json"))
        let suite = "app.scriptwidget.calendar-selection." + UUID().uuidString
        return (root, package, try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func calendarSelectionRuntime(root: URL, package: ScriptWidgetPackage, defaults: UserDefaults, provider: ScriptWidgetCalendarProvider,
                                          environments: [String: String] = ["widget-size": "medium"]) -> ScriptWidgetRuntime {
        let runtime = ScriptWidgetRuntime(package: package, environments: environments)
        runtime.runningState?.storageContainerForTesting = root
        runtime.runningState?.storageDefaultsForTesting = defaults
        runtime.runningState?.calendarProviderForTesting = provider
        return runtime
    }

    func testNativeCalendarSourceSelectionFiltersMetadataEventsAndCache() throws {
        let f = try calendarSelectionFixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: f.root)
        var queries = 0
        let provider = ScriptWidgetCalendarProvider(authorizationStatus: { "authorized" }, sources: {
            [.init(id: "personal", title: "Personal"), .init(id: "work", title: "Private Work")]
        }, events: { query, ids, _ in
            queries += 1; XCTAssertEqual(ids, ["personal"])
            return (["personal", "work"].map { .init(id: $0, calendarID: $0, title: $0 == "work" ? "private-event" : "Reading", start: query.start.addingTimeInterval(3600), end: query.start.addingTimeInterval(7200), allDay: false) }, false)
        })
        let runtime = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider)
        let result = runtime.executeJSXSyncForWidget("""
            const options={start:'2026-01-01T00:00:00Z',end:'2026-01-02T00:00:00Z'};
            const sources=await $calendar.calendars();
            let blocked=false;try{await $calendar.events({...options,calendarIDs:['work']});}catch(error){blocked=String(error).includes('invalid_options');}
            const first=await $calendar.events(options),cached=await $calendar.events(options);
            $render(<text>{JSON.stringify({sources,items:first.items,cache:cached.source,blocked})}</text>);
        """)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        let text = collectText(try XCTUnwrap(result.0))
        XCTAssertTrue(text.contains("Reading")); XCTAssertFalse(text.contains("private-event")); XCTAssertFalse(text.contains("Private Work"))
        XCTAssertTrue(text.contains(#""cache":"cache""#)); XCTAssertTrue(text.contains(#""blocked":true"#)); XCTAssertEqual(queries, 1)
        XCTAssertEqual(f.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("ScriptWidget.CalendarCache.") }.count, 1)
        try ScriptWidgetCalendarSelection(calendarIDs: ["work"]).save(container: f.root)
        let projected = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider,
            environments: ["widget-size": "medium", "timeline-date": "2026-01-01T12:00:00Z", "timeline-is-projection": "true"])
            .executeJSXSyncForWidget("try{await $calendar.events({start:'2026-01-01T00:00:00Z',end:'2026-01-02T00:00:00Z'});}catch(e){$render(<text>{String(e)}</text>);}")
        XCTAssertNil(projected.1); XCTAssertTrue(collectText(try XCTUnwrap(projected.0)).contains("timeline_read_only")); XCTAssertEqual(queries, 1)
    }

    func testNativeCalendarScopeChangeDuringQueryCannotDeliverOrCacheOldEvents() throws {
        let f = try calendarSelectionFixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: f.root)
        let provider = ScriptWidgetCalendarProvider(authorizationStatus: { "authorized" }, sources: { [.init(id: "personal", title: "Personal")] }, events: { query, _, _ in
            try ScriptWidgetCalendarSelection(calendarIDs: []).save(container: f.root)
            return ([.init(id: "private", calendarID: "personal", title: "must-not-escape", start: query.start, end: query.end, allDay: false)], false)
        })
        let runtime = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider)
        let result = runtime.executeJSXSyncForWidget("try{const r=await $calendar.events();$render(<text>{JSON.stringify(r)}</text>);}catch(e){$render(<text>{String(e)}</text>);}")
        XCTAssertNil(result.1); let text = collectText(try XCTUnwrap(result.0))
        XCTAssertTrue(text.contains("selection changed")); XCTAssertFalse(text.contains("must-not-escape"))
        XCTAssertFalse(f.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ScriptWidget.CalendarCache.") })
        let again = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider)
            .executeJSXSyncForWidget("const c=await $calendar.calendars();let blocked=false;try{await $calendar.events();}catch(e){blocked=String(e).includes('No Calendar sources');}$render(<text>{JSON.stringify({count:c.length,blocked})}</text>);")
        XCTAssertNil(again.1); XCTAssertTrue(collectText(try XCTUnwrap(again.0)).contains(#""count":0,"blocked":true"#))
    }

    func testNativeCalendarScopeIsRecheckedBeforeDeliveringAnExistingCache() throws {
        let f = try calendarSelectionFixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: f.root)
        let source = "const r=await $calendar.events({start:'2026-01-01T00:00:00Z',end:'2026-01-02T00:00:00Z'});$render(<text>{JSON.stringify(r)}</text>);"
        var provider = ScriptWidgetCalendarProvider(authorizationStatus: { "authorized" }, sources: { [.init(id: "personal", title: "Personal")] }, events: { query, _, _ in
            ([.init(id: "event", calendarID: "personal", title: "cached-private", start: query.start, end: query.end, allDay: false)], false)
        })
        let first = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider).executeJSXSyncForWidget(source)
        XCTAssertNil(first.1); XCTAssertTrue(collectText(try XCTUnwrap(first.0)).contains("cached-private"))
        var checks = 0, queries = 0
        provider.authorizationStatus = {
            checks += 1
            if checks == 2 { try? ScriptWidgetCalendarSelection(calendarIDs: []).save(container: f.root) }
            return "authorized"
        }
        provider.events = { _, _, _ in queries += 1; return ([], false) }
        let guarded = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider)
            .executeJSXSyncForWidget("try{" + source + "}catch(e){$render(<text>{String(e)}</text>);}")
        XCTAssertNil(guarded.1); let text = collectText(try XCTUnwrap(guarded.0))
        XCTAssertTrue(text.contains("selection changed")); XCTAssertFalse(text.contains("cached-private")); XCTAssertEqual(queries, 0)
        XCTAssertFalse(f.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ScriptWidget.CalendarCache.") })
    }

    func testNativeCalendarSourcesDoNotConfuseUnicodeEquivalentOpaqueIdentifiers() throws {
        let f = try calendarSelectionFixture(), selected = "caf\u{00e9}", outside = "cafe\u{0301}"
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        try ScriptWidgetCalendarSelection(calendarIDs: [selected]).save(container: f.root)
        let provider = ScriptWidgetCalendarProvider(authorizationStatus: { "authorized" }, sources: {
            [.init(id: selected, title: "Personal"), .init(id: outside, title: "private-source")]
        }, events: { query, _, _ in
            ([.init(id: "allowed", calendarID: selected, title: "Allowed reading", start: query.start, end: query.end, allDay: false),
              .init(id: "outside", calendarID: outside, title: "private-event", start: query.start, end: query.end, allDay: false)], false)
        })
        let result = calendarSelectionRuntime(root: f.root, package: f.package, defaults: f.defaults, provider: provider)
            .executeJSXSyncForWidget("const sources=await $calendar.calendars(),events=await $calendar.events();$render(<text>{JSON.stringify({sources,events})}</text>);")
        XCTAssertNil(result.1); let text = collectText(try XCTUnwrap(result.0))
        XCTAssertTrue(text.contains("Allowed reading")); XCTAssertFalse(text.contains("private-source") || text.contains("private-event"))
    }

    @MainActor
    func testExportCalendarSourceSelectionFixtures() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_CALENDAR_SOURCES"], !directory.isEmpty else {
            throw XCTSkip("Opt-in isolated Calendar source editor screenshots")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sources: [ScriptWidgetCalendarSource] = [.init(id: "personal", title: "Personal"), .init(id: "work", title: "Work — a calendar title that needs a little more room")]
        for mode in ["all", "selected", "none", "corrupt", "conflict"] {
            let root = makeTempPackage().path
            defer { try? FileManager.default.removeItem(at: root) }
            if mode == "selected" { try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: root) }
            if mode == "none" { try ScriptWidgetCalendarSelection(calendarIDs: []).save(container: root) }
            if mode == "corrupt" { try Data("broken".utf8).write(to: root.appendingPathComponent(ScriptWidgetCalendarSelection.fileName)) }
            let model = ScriptWidgetCalendarSourcesModel(container: root, authorization: { "authorized" }, loadSources: { sources }, onSaved: {})
            await model.reload()
            XCTAssertEqual(model.sources.count, 2)
            if mode == "conflict" {
                model.useAll = false; model.select("work", enabled: true)
                try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: root)
                model.save(); XCTAssertTrue(model.isError)
            }
            for dark in [false, true] {
                #if os(macOS)
                let width: CGFloat = 480, height: CGFloat = 560, platform = "mac"
                #else
                let width: CGFloat = 393, height: CGFloat = 640, platform = "ios"
                #endif
                let content = CalendarSourcesSettingsView(model: model).padding(20)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .background(dark ? Color(red: 0.1, green: 0.1, blue: 0.12) : Color(red: 0.97, green: 0.97, blue: 0.98))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let png: Data
                #if os(macOS)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                await Task.yield()
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                #else
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                defer { window.isHidden = true; previous?.makeKey() }
                let host = UIHostingController(rootView: content); window.rootViewController = host
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                window.makeKeyAndVisible(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data)
                XCTAssertGreaterThan(Set(pixels as Data).count, 4, "The source editor must render content, not a uniform/black canvas")
                png = try XCTUnwrap(image.pngData())
                window.isHidden = true
                #endif
                try png.write(to: output.appendingPathComponent("sources-\(platform)-\(mode)-\(dark ? "dark" : "light").png"), options: .atomic)
            }
        }
    }

    func testCalendarDeniesLegacyUndeclaredMalformedAndUnsupportedManifests() throws {
        for mode in ["legacy", "undeclared", "malformed", "future-format"] {
            let package = makeTempPackage()
            defer { try? FileManager.default.removeItem(at: package.path) }
            if mode != "legacy" {
                var manifest = WidgetPackageManifest.newProject(name: package.name)
                if mode == "future-format" { manifest.formatVersion = 999; manifest.permissions = [.calendar] }
                let data = mode == "malformed" ? Data("{bad".utf8) : try JSONEncoder().encode(manifest)
                try data.write(to: package.path.appendingPathComponent("widget.json"))
            }
            let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium"])
            let result = runtime.executeJSXSyncForWidget("""
                const status = $calendar.authorizationStatus();
                let failures = 0;
                for (const call of [() => $calendar.requestAuthorization(), () => $calendar.calendars(), () => $calendar.events()]) {
                    try { await call(); } catch(e) { if (String(e).includes('[permission_denied]')) failures++; }
                }
                $render(<text>{status + ':' + failures}</text>);
                """)
            if mode == "malformed" || mode == "future-format" {
                XCTAssertNil(result.0, mode)
                XCTAssertTrue(result.1?.displayMessage.contains("[package:") == true, mode)
            } else {
                XCTAssertNil(result.1, mode)
                XCTAssertEqual(collectText(try XCTUnwrap(result.0)), "undeclared:3", mode)
            }
        }
    }

    func testCalendarRejectsInvalidOptionsWithoutRequestingSystemAccess() throws {
        let package = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: package.path) }
        var manifest = WidgetPackageManifest.newProject(name: package.name)
        manifest.permissions = [.calendar]
        try JSONEncoder().encode(manifest).write(to: package.path.appendingPathComponent("widget.json"))
        let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium"])
        let result = runtime.executeJSXSyncForWidget("""
            let failures = 0;
            for (const options of [{limit: true}, {limit: 51}, {calendarIDs: []}, {start: 'bad'}, {unknown: 1}]) {
                try { await $calendar.events(options); } catch(e) { if (String(e).includes('[invalid_options]')) failures++; }
            }
            $render(<text>{'invalid:' + failures}</text>);
            """)
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), "invalid:5")
    }


    func testTrustedHostAppearanceIsCapturedIndependentlyOfScriptEnvironmentReplacement() throws {
        let package=makeTempPackage();defer{try? FileManager.default.removeItem(at:package.path)}
        for dark in [false,true] {
            let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":"medium"],isDarkMode:dark)
            let result=runtime.executeJSXSyncForWidget("$getenv=()=> 'light';$render(<text>{String($device.isdarkmode())}</text>);")
            XCTAssertNil(result.1,result.1?.displayMessage ?? "")
            XCTAssertTrue(ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0)).contains(dark ? "true":"false"))
            XCTAssertEqual(runtime.runningState?.isDarkMode,dark)
        }
    }

    func testFileExistsRecognizesBinaryAssetsAndRejectsDirectoriesLinksAndBoundaryEscapes() throws {
        let package=makeTempPackage();defer{try? FileManager.default.removeItem(at:package.path)}
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data([0,255,1]),root:package.path,relative:"image/test.png"))
        let outside=FileManager.default.temporaryDirectory.appendingPathComponent("outside-"+UUID().uuidString)
        try Data("outside".utf8).write(to:outside);defer{try? FileManager.default.removeItem(at:outside)}
        try FileManager.default.createSymbolicLink(at:package.path.appendingPathComponent("link"),withDestinationURL:outside)
        let source="""
        const paths=['image/test.png','missing','image','link','../outside','/etc/passwd','image/../image/test.png','image//test.png','C:/test.png','constructor'];
        $render(<text>{JSON.stringify(paths.map(path=>$file.exists(path)))}</text>);
        """
        let result=ScriptWidgetRuntime(package:package,environments:["widget-size":"medium"]).executeJSXSyncForWidget(source)
        XCTAssertNil(result.1,result.1?.displayMessage ?? "")
        let tree=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
        XCTAssertTrue(tree.contains("[true,false,false,false,false,false,false,false,false,false]"))
    }

    func testLiveActivityPresentationCannotUseNetworkPluginsOrLocationAfterReplacingGetenv() throws {
        let package=makeTempPackage();defer{try? FileManager.default.removeItem(at:package.path)}
        var manifest=WidgetPackageManifest.newProject(name:package.name);manifest.permissions=[.network,.location];manifest.networkDomains=["example.com"];manifest.plugins=["example.plugin"]
        let source="""
        $getenv=()=>"medium";const errors=[];
        for(const call of [()=>fetch('https://example.com'),()=>$http.getResponse('https://example.com'),()=>$dataSource.request('example.plugin','read',{}),()=>$location.current(),()=>$location.requestAuthorization()]){
          try{await call();errors.push('unexpected');}catch(error){errors.push(String(error));}
        }
        $render(<text>{JSON.stringify(errors)}</text>);
        """
        XCTAssertTrue(package.writeMainFile(content:source).0)
        let saved=package.writeManifest(manifest);XCTAssertTrue(saved.0,saved.1)
        for surface in ["live-activity","dynamic-island"] {
            let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":surface])
            let result=runtime.executeJSXSyncForWidget(source);XCTAssertNil(result.1,result.1?.displayMessage ?? "")
            let element=try XCTUnwrap(result.0),text=ScriptWidgetElementTreeJSON.encode(element)
            XCTAssertEqual(text.components(separatedBy:"live_activity_unavailable").count-1,5)
            XCTAssertEqual(runtime.runningState?.executionSession.totalNetworkRequests,0)
            XCTAssertEqual(runtime.runningState?.executionSession.totalDataQueries,0)
        }
    }

    func testLiveActivityTemplateStateAndEveryIslandRegionMatchNative() throws {
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Live Activity Demo")
        let main=try XCTUnwrap(package.readMainFile().0)
        let states:[String:String]=[
            "empty":"", "progress":#"{"title":"Reading","detail":"Chapter finished","progress":3,"total":8}"#,
            "timer":#"{"title":"Focus","endsAt":"2026-01-01T12:25:00Z"}"#,
            "expired":#"{"title":"Focus","endsAt":"2026-01-01T11:00:00Z"}"#,
            "invalid":"{not JSON", "invalidProgress":#"{"progress":9,"total":8}"#,
            "unknown":#"{"secret":"must not display"}"#, "stale":#"{"title":"Reading","progress":3,"total":8}"#
        ]
        var trees:[String:String]=[:]
        for (variant,state) in states {
            let environments=["widget-size":"live-activity","live-activity-state":state,"live-activity-is-stale":variant=="stale" ? "true" : "false"]
            let source="Date.now=()=>1767268800000;\n"+main
            let runtime=ScriptWidgetRuntime(package:package,environments:environments)
            let result=runtime.executeJSXSyncForWidget(source)
            XCTAssertNil(result.1,result.1?.displayMessage ?? "")
            trees[variant+"/lockScreen"]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            let islandRuntime=ScriptWidgetRuntime(package:package,environments:environments.merging(["widget-size":"dynamic-island"]){_,new in new})
            let islandResult=islandRuntime.executeJSXSyncForDynamicIsland(source)
            XCTAssertNil(islandResult.1,islandResult.1?.displayMessage ?? "")
            let island=try XCTUnwrap(islandResult.0)
            for (region,element) in [("leading",island.expanded.leading),("trailing",island.expanded.trailing),("center",island.expanded.center),("bottom",island.expanded.bottom),("compactLeading",island.compactLeading),("compactTrailing",island.compactTrailing),("minimal",island.minimal)] {
                trees[variant+"/"+region]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(element))
            }
            XCTAssertEqual(runtime.runningState?.executionSession.totalNetworkRequests,0)
        }
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("live-activity-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_LIVE_PARITY"]=="1" {
            try JSONSerialization.data(withJSONObject:["states":states,"trees":trees],options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            guard FileManager.default.fileExists(atPath:fixture.path) else { XCTFail("Live Activity parity fixture is missing");return }
            let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(saved?["trees"] as? [String:String],trees)
        }
    }

    #if os(macOS)
    @MainActor
    func testExportLocalLiveActivitySnapshots() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LOCAL_LIVE"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_LOCAL_LIVE for native local activity captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Live Activity Demo"),main=try XCTUnwrap(package.readMainFile().0)
        let states=["empty":"","progress":#"{"title":"Reading","detail":"Chapter finished","progress":3,"total":8}"#,"invalid":"{invalid","expired":#"{"title":"Focus","endsAt":"2026-01-01T11:00:00Z"}"#,"stale":#"{"title":"Reading","progress":3,"total":8}"#]
        for (variant,state) in states {
            let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":"live-activity","live-activity-state":state,"live-activity-is-stale":variant=="stale" ? "true" : "false"])
            let result=await Task.detached { runtime.executeJSXSyncForWidget("Date.now=()=>1767268800000;\n"+main) }.value
            XCTAssertNil(result.1,result.1?.displayMessage ?? "")
            let element=try XCTUnwrap(result.0),context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Live Activity fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
            let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:370,height:116).background(Color.white).environment(\.colorScheme,.light));renderer.scale=2
            let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(variant+".png"))
        }
    }
    #endif

    private func companionStates() throws -> [String:String] {
        var result:[String:String]=[:]
        for (name,kind) in [("Plant Care","plantCare"),("Pocket Pet","pocketPet")] {
            result[name+"/empty"]=""
            for variant in ["today","older"] {
                let value:Any=kind=="plantCare" ? 1 : ["feed","play","rest"]
                let object:[String:Any]=["version":1,"revision":1,"entries":[["date":variant=="today" ? "2026-01-01" : "2025-12-20","value":value]],"undo":NSNull()]
                result[name+"/"+variant]=String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self)
            }
        }
        return result
    }

    @MainActor
    func testCompanionTreesMatchNativeAcrossFamiliesAndAppearances() async throws {
        let states=try companionStates(),prelude=try String(contentsOf:WeatherTemplateFixtures.directory.appendingPathComponent("prelude.js"),encoding:.utf8)
        var trees:[String:String]=[:]
        for name in ["Plant Care","Pocket Pet"] {
            let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/"+name),main=try XCTUnwrap(package.readMainFile().0),kind=name=="Plant Care" ? "plantCare" : "pocketPet"
            for variant in ["empty","today","older"] { for dark in [false,true] { for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
                let raw=try XCTUnwrap(states[name+"/"+variant]),encoded=String(decoding:try JSONEncoder().encode(raw),as:UTF8.self)
                let prefix="\n$device.isdarkmode=()=>\(dark ? "true" : "false");$storage={getString:key=>key==='\(kind).v1'?\(encoded):''};\n"
                let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":"","timeline-date":"2026-01-01T12:00:00Z","timeline-is-projection":"false"])
                let result=await Task.detached { runtime.executeJSXSyncForWidget(prelude+prefix+main) }.value
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let element=try XCTUnwrap(result.0),key=name+"/"+variant+"/"+family+"/"+(dark ? "dark" : "light")
                trees[key]=ScriptWidgetElementTreeJSON.encode(element)
                #if os(macOS)
                if let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_COMPANIONS"],["small","medium","large"].contains(family) {
                    let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                    let size=family=="small" ? CGSize(width:158,height:158) : family=="medium" ? CGSize(width:338,height:158) : CGSize(width:338,height:354)
                    let context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Care fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
                    let background=ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? .white
                    let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,dark ? .dark : .light));renderer.scale=2
                    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(key.replacingOccurrences(of:"/",with:"-")+".png"))
                }
                #endif
            }}}
        }
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("companion-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_COMPANION_PARITY"]=="1" {
            try JSONSerialization.data(withJSONObject:["states":states,"trees":trees,"timeZone":TimeZone.current.identifier],options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            guard FileManager.default.fileExists(atPath:fixture.path) else { XCTFail("Companion parity fixture is missing");return }
            let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(saved?["trees"] as? [String:String],trees)
        }
    }

    private func wallpaperFixtureImage(dark:Bool) throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:600,height:1300,bitsPerComponent:8,bytesPerRow:2400,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors:[CGColor]=dark ? [CGColor(red:0.06,green:0.12,blue:0.25,alpha:1),CGColor(red:0.35,green:0.17,blue:0.45,alpha:1)] : [CGColor(red:0.65,green:0.88,blue:0.85,alpha:1),CGColor(red:0.97,green:0.78,blue:0.64,alpha:1)]
        let gradient=try XCTUnwrap(CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:[0,1]))
        context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:600,y:1300),options:[])
        return try XCTUnwrap(context.makeImage())
    }

    private func wallpaperConfiguration(content:String)->[String:Any] {
        var assets:[[String:Any]]=[]
        for (index,family) in ScriptWidgetWallpaperAsset.families.enumerated() { for dark in [false,true] {
            let suffix=String(format:"%012d",index+1+(dark ? 5 : 0))
            assets.append(["family":family,"appearance":dark ? "dark" : "light","image":"background-00000000-0000-4000-8000-"+suffix,"label":"Calibrated position"])
        }}
        return ["title":"Quiet space","caption":"A little room to breathe","content":content,"ink":"adaptive","backgrounds":assets]
    }

    @MainActor
    func testWallpaperPortableConfigurationUsesNativeFileAPIAndPreservesSavedPrecedence() async throws {
        let template = ScriptWidgetPackage(bundle: "Script", relativePath: "template/Wallpaper Match")
        let package = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: package.path) }
        let main = try XCTUnwrap(template.readMainFile().0)
        XCTAssertTrue(package.writeMainFile(content: main).0)
        XCTAssertTrue(package.writeFile(relativePath: "lib/configuration.js", content: try XCTUnwrap(template.readFile(relativePath: "lib/configuration.js").0)).0)
        var manifest = try XCTUnwrap(template.readManifest()); manifest.name = package.name
        XCTAssertTrue(package.writeManifest(manifest).0)
        let config = wallpaperConfiguration(content: "date")
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["version":1, "kind":"wallpaper", "values":config], options: [.sortedKeys]), as: UTF8.self)
        XCTAssertTrue(package.writeFile(relativePath: "wallpaper.json", content: raw).0)
        let encoded = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        func execute(_ saved: String) async throws -> String {
            let source = "$storage={getString:()=>\(saved)};\n" + main
            let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size":"accessoryRectangular", "timeline-date":"2026-01-01T12:00:00Z"])
            let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
            XCTAssertNil(result.1, result.1?.displayMessage ?? "")
            return ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
        }
        let portableTree = try await execute("\"\"")
        let savedTree = try await execute(encoded)
        XCTAssertEqual(portableTree, savedTree)
        XCTAssertTrue(portableTree.contains("Quiet space"))
        XCTAssertTrue(package.writeFile(relativePath: "wallpaper.json", content: "invalid package data").0)
        let precedenceTree = try await execute(encoded)
        XCTAssertEqual(precedenceTree, savedTree)
        let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size":"medium"])
        let invalid = await Task.detached { runtime.executeJSXSyncForWidget("$storage={getString:()=>\"\"};\n" + main) }.value
        XCTAssertNotNil(invalid.1)
    }

    @MainActor
    func testWallpaperTreesUseActualBinaryFilesAndMatchEveryFamilyAndAppearance() async throws {
        let template=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Wallpaper Match")
        let main=try XCTUnwrap(template.readMainFile().0),helper=try XCTUnwrap(template.readFile(relativePath:"lib/configuration.js").0)
        var trees:[String:String]=[:],configurations:[String:Any]=["empty":NSNull()]
        for variant in ["empty","none","text","date","missing"] {
            let package=makeTempPackage();defer{try? FileManager.default.removeItem(at:package.path)}
            XCTAssertTrue(package.writeMainFile(content:main).0);XCTAssertTrue(package.writeFile(relativePath:"lib/configuration.js",content:helper).0)
            var manifest=try XCTUnwrap(template.readManifest());manifest.name=package.name;let saved=package.writeManifest(manifest);XCTAssertTrue(saved.0,saved.1)
            let config=wallpaperConfiguration(content:variant=="none" ? "none" : variant=="date" ? "date":"text")
            let raw:String
            if variant=="empty" {raw=""} else {
                configurations[variant]=config
                raw=String(decoding:try JSONSerialization.data(withJSONObject:["version":1,"kind":"wallpaper","values":config],options:[.sortedKeys]),as:UTF8.self)
            }
            if variant != "missing" && variant != "empty" {
                for asset in try XCTUnwrap(ScriptWidgetWallpaperAsset.decode(config["backgrounds"])) {
                    let image=try wallpaperFixtureImage(dark:asset.appearance=="dark"),selection=ScriptWidgetWallpaperCrop.initial(family:asset.family,imageWidth:image.width,imageHeight:image.height)
                    XCTAssertTrue(ScriptWidgetPackageFiles.write(try ScriptWidgetPhotoPreparation.encode(selection.cropped(image)),root:package.path,relative:"image/"+asset.image+".png"))
                }
            }
            for dark in [false,true] { for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
                let encoded=String(decoding:try JSONEncoder().encode(raw),as:UTF8.self)
                let source="$storage={getString:()=>\(encoded)};\n"+main
                let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":"","timeline-date":"2026-01-01T12:00:00Z"],isDarkMode:dark)
                let result=await Task.detached{runtime.executeJSXSyncForWidget(source)}.value
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let element=try XCTUnwrap(result.0),key=variant+"/"+family+"/"+(dark ? "dark":"light")
                trees[key]=ScriptWidgetElementTreeJSON.encode(element)
                #if os(macOS)
                if let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_WALLPAPER"],["small","medium","large"].contains(family) {
                    let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                    let size=family=="small" ? CGSize(width:158,height:158):family=="medium" ? CGSize(width:338,height:158):CGSize(width:338,height:354)
                    let context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Wallpaper fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
                    let background=ScriptWidgetAttributeColor(element.getPropString("background") ?? (dark ? "#000000":"#ffffff")).color ?? .white
                    let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,dark ? .dark:.light));renderer.scale=2
                    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(key.replacingOccurrences(of:"/",with:"-")+".png"))
                }
                #endif
            }}
        }
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("wallpaper-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_WALLPAPER_PARITY"]=="1" {
            try JSONSerialization.data(withJSONObject:["trees":trees,"configurations":configurations],options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            guard FileManager.default.fileExists(atPath:fixture.path) else {XCTFail("Wallpaper corpus is missing");return}
            let recorded=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(recorded?["trees"] as? [String:String],trees)
        }
    }

    private func launcherParameters() throws -> [String:String] {
        var items=ScriptWidgetLauncherItem.defaults
        items.append(.init(id:"shortcut",title:"Morning",icon:"play.fill",type:"shortcut",target:"Morning + Plan & Go",input:"Hello & next=✓"))
        items.append(.init(id:"docs",title:"Docs",icon:"star.fill",type:"web",target:"https://xnu.app/scriptwidget/",input:""))
        items.append(.init(id:"mail",title:"Mail",icon:"envelope.fill",type:"app",target:"mailto:hello@example.com",input:""))
        func encode(_ items:[ScriptWidgetLauncherItem]) throws -> String {
            String(decoding:try JSONSerialization.data(withJSONObject:["title":"Quick Launch","accent":"blue","items":items.map(\.dictionary)],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
        }
        return ["default":"","six":try encode(items),"shortcut":try encode([items[3]])]
    }

    private func launcherFixtureSource(_ main:String,state:String="") -> String {
        "globalThis.$device.isdarkmode=()=>false;globalThis.$storage={getString:()=>\(String(decoding:try! JSONEncoder().encode(state),as:UTF8.self))};\n"+main
    }

    func testLauncherAndControlSwitchTreesMatchNativeAcrossEveryFamily() throws {
        let parameters=try launcherParameters();var trees:[String:String]=[:]
        for name in ["Quick Launcher","Control Switch"] {
            let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/"+name),main=try XCTUnwrap(package.readMainFile().0)
            let variants=name=="Quick Launcher" ? ["default","six","shortcut"] : ["off","on"]
            for variant in variants { for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
                let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":parameters[variant] ?? ""])
                let result=runtime.executeJSXSyncForWidget(launcherFixtureSource(main,state:variant=="on" ? "true" : ""))
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                trees[name+"/"+variant+"/"+family]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }}
        }
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("launcher-controls-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_LAUNCHER_PARITY"]=="1" {
            try JSONSerialization.data(withJSONObject:["parameters":parameters,"trees":trees],options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            guard FileManager.default.fileExists(atPath:fixture.path) else { throw XCTSkip("Launcher corpus requires the repository checkout") }
            let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(saved?["trees"] as? [String:String],trees)
        }
    }

    #if os(macOS)
    @MainActor
    func testExportLauncherAndControlSnapshots() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LAUNCHER"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_LAUNCHER for launcher captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let parameters=try launcherParameters()
        for name in ["Quick Launcher","Control Switch"] {
            let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/"+name),main=try XCTUnwrap(package.readMainFile().0)
            for variant in name=="Quick Launcher" ? ["default","six","shortcut"] : ["off","on"] {
                for (family,size) in [("small",CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
                    let source=launcherFixtureSource(main,state:variant=="on" ? "true" : ""),runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":parameters[variant] ?? ""])
                    let result=await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                    XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                    let element=try XCTUnwrap(result.0),context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Launcher fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
                    let background=ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? .white
                    let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,.light));renderer.scale=2
                    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(name+"-"+variant+"-"+family+".png"))
                }
            }
        }
    }
    #endif

    private func repositoryFixtureSource(_ main: String, mode: String) -> String {
        var prefix = """
        let repoClock=1767269700000,repoStars=1280,repoStatus=200;Date.now=()=>repoClock;globalThis.$device.isdarkmode=()=>false;
        globalThis.$http={getResponse:()=>({then(resolve,reject){if(repoStatus===0){reject("isolated offline");return;}resolve({status:repoStatus,headers:{"cache-control":"public, max-age=3600","last-modified":"Thu, 01 Jan 2026 12:00:00 GMT","retry-after":"7200"},body:JSON.stringify({full_name:"everettjf/ScriptWidget",private:false,stargazers_count:repoStars,forks_count:96,open_issues_count:18})});}})};
        """
        if ["history","saved","rate","missing"].contains(mode) {
            if mode != "saved" { prefix += "\nrepoClock-=172800000;repoStars=1200;" }
            prefix += "\nif(!$import('lib/repository.js'))throw new Error('fixture import');await repositoryStats.load(repositoryStats.options('',''),repoClock,false);repoClock=1767269700000;repoStars=1280;"
        }
        if mode == "rate" { prefix += "\nrepoStatus=429;" }
        if mode == "missing" { prefix += "\nrepoStatus=404;" }
        if mode == "unavailable" { prefix += "\nrepoStatus=0;" }
        return prefix + "\n" + main
    }

    func testRepositoryStatesMatchNativeTreesAcrossEveryFamily() throws {
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/GitHub Repo Stats"),main=try XCTUnwrap(package.readMainFile().0)
        var trees:[String:String]=[:]
        for mode in ["fresh","history","saved","rate","missing","unavailable"] {
            for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
                let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family])
                let result=runtime.executeJSXSyncForWidget(repositoryFixtureSource(main,mode:mode))
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                trees[mode+"/"+family]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }
        }
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("repository-stats-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_REPOSITORY_PARITY"] == "1" {
            try JSONSerialization.data(withJSONObject:["trees":trees],options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            guard FileManager.default.fileExists(atPath:fixture.path) else { throw XCTSkip("Repository corpus requires the checkout") }
            let stored=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(stored?["trees"] as? [String:String],trees)
        }
    }

    #if os(macOS)
    @MainActor
    func testExportRepositorySnapshots() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_REPOSITORY"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_REPOSITORY for synthetic repository captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/GitHub Repo Stats"),main=try XCTUnwrap(package.readMainFile().0)
        for mode in ["fresh","history","rate","missing"] {
            for (family,size) in [("small",CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
                let source=repositoryFixtureSource(main,mode:mode),runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family])
                let result=await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let element=try XCTUnwrap(result.0),context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Synthetic repository fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
                let background=ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? .white
                let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,.light));renderer.scale=2
                let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("repository-\(mode)-\(family).png"))
            }
        }
    }
    #endif

    private func healthFixtureSource(_ main: String, metric: String, mode: String) -> String {
        let value = metric == "steps" ? 6840 : metric == "energy" ? 420 : 72
        let unit = metric == "steps" ? "count" : metric == "energy" ? "kcal" : "bpm"
        return """
        Date.now=()=>1767269700000;globalThis.$device.isdarkmode=()=>false;
        globalThis.$health={isAvailable:()=>\(mode == "unavailable" ? "false" : "true"),authorizationStatus:()=>"notDisclosed",
          requestAuthorization:()=>{throw new Error("must not prompt");},
          stepCountToday:read,activeEnergyToday:read,heartRateLatest:read};
        function read(){return {then(resolve,reject){\(mode == "failure" ? "reject('isolated locked fixture');" : "resolve({value:\(mode == "empty" ? 0 : value),hasSamples:\(mode == "empty" ? "false" : "true"),unit:'\(unit)',start:'2026-01-01T08:00:00Z',end:'2026-01-01T12:15:00Z'});")}};}
        \(main)
        """
    }

    func testHealthCardStatesMatchNativeTreesAcrossEveryFamily() throws {
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Health Steps Ring"),main=try XCTUnwrap(package.readMainFile().0)
        var trees:[String:String]=[:]
        for metric in ["steps","energy","heart"] { for mode in ["normal","empty","unavailable","failure"] {
            for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
                let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":"{\"metric\":\"\(metric)\"}"])
                let result=runtime.executeJSXSyncForWidget(healthFixtureSource(main,metric:metric,mode:mode))
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                trees[metric+"/"+mode+"/"+family]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }
        }}
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("health-card-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_HEALTH_PARITY"] == "1" {
            try JSONSerialization.data(withJSONObject:["trees":trees],options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            guard FileManager.default.fileExists(atPath:fixture.path) else { throw XCTSkip("Health parity fixture requires the repository checkout") }
            let stored=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(stored?["trees"] as? [String:String],trees)
        }
    }

    #if os(macOS)
    @MainActor
    func testExportHealthCardSnapshots() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_HEALTH"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_HEALTH for isolated native health captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Health Steps Ring"),main=try XCTUnwrap(package.readMainFile().0)
        for metric in ["steps","energy","heart"] { for mode in ["normal","empty"] {
            for (family,size) in [("small",CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
                let source=healthFixtureSource(main,metric:metric,mode:mode),runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":"{\"metric\":\"\(metric)\"}"])
                let result=await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let element=try XCTUnwrap(result.0),context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Synthetic health fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
                let background=ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? .white
                let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,.light));renderer.scale=2
                let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("health-\(metric)-\(mode)-\(family).png"))
            }
        }}
    }
    #endif

    func testWeatherForecastStatesMatchNativeTreesAcrossEveryFamily() throws {
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Local Weather (Location)")
        let main=try XCTUnwrap(package.readMainFile().0)
        var trees: [String:String] = [:]
        for mode in ["fresh","saved","stale","unavailable"] {
            for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryCircular","accessoryRectangular","accessoryInline"] {
                let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":WeatherTemplateFixtures.parameter])
                let result=runtime.executeJSXSyncForWidget(try WeatherTemplateFixtures.source(main,mode:mode))
                XCTAssertNil(result.1,"\(mode)/\(family): \(result.1?.displayMessage ?? "")")
                trees[mode+"/"+family]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }
        }
        let fixture=WeatherTemplateFixtures.directory.appendingPathComponent("weather-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_WEATHER_PARITY"] == "1" {
            try JSONSerialization.data(withJSONObject:["trees":trees],options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            let stored=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(stored?["trees"] as? [String:String],trees)
        }
    }

    #if os(macOS)
    @MainActor
    func testExportWeatherForecastSnapshots() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_WEATHER"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_WEATHER for isolated weather captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let package=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Local Weather (Location)"),main=try XCTUnwrap(package.readMainFile().0)
        for mode in ["fresh","stale","unavailable"] {
            for (family,size) in [("small",CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
                let source=try WeatherTemplateFixtures.source(main,mode:mode),runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":WeatherTemplateFixtures.parameter])
                let result=await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let element=try XCTUnwrap(result.0),context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Weather fixture",scriptParameter:"",package:package,containerBackgroundElement:element)
                let background=ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? .white
                let renderer=ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,.light));renderer.scale=2
                let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("weather-\(mode)-\(family).png"))
            }
        }
    }
    #endif

    private static let photoFixtureNames = (1...4).map { "photo-00000000-0000-4000-8000-" + String(format:"%012d",$0) }
    private func photoParameter(layout: String) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:["title":"My moments","caption":"A little collection","layout":layout,"photos":Self.photoFixtureNames],options:[.sortedKeys]),as:UTF8.self)
    }
    func testPhotoCardLayoutsMatchFixedNativeTreesAcrossEveryFamily() throws {
        let package = ScriptWidgetPackage(bundle:"Script",relativePath:"template/Photo Card")
        let source = try XCTUnwrap(package.readMainFile().0)
        var trees: [String:String] = [:]
        for layout in ["single","duo","grid"] {
            for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryCircular","accessoryRectangular","accessoryInline"] {
                let runtime = ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":try photoParameter(layout:layout)])
                let result = runtime.executeJSXSyncForWidget(source)
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                trees[layout + "/" + family] = ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }
        }
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web/preview-engine/test/parity/photo-card-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_PHOTO_PARITY"] == "1" {
            try JSONSerialization.data(withJSONObject:["trees":trees],options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:fixture,options:.atomic)
        } else {
            let object = try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any]
            XCTAssertEqual(object?["trees"] as? [String:String],trees)
        }
    }

    #if os(macOS)
    @MainActor
    func testExportPhotoCardAndCropSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_PHOTOS"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_PHOTOS for native photo captures") }
        let output = URL(fileURLWithPath:directory)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let mutable = makeTempPackage()
        defer { try? FileManager.default.removeItem(at:mutable.path) }
        try FileManager.default.removeItem(at:mutable.path)
        let bundle = try XCTUnwrap(Bundle.main.url(forResource:"Script",withExtension:"bundle"))
        try FileManager.default.copyItem(at:bundle.appendingPathComponent("template/Photo Card"),to:mutable.path)
        var sample: CGImage?
        for (index,name) in Self.photoFixtureNames.enumerated() {
            let canvas = try XCTUnwrap(CGContext(data:nil,width:768,height:768,bitsPerComponent:8,bytesPerRow:3072,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            let backgrounds: [(CGFloat,CGFloat,CGFloat)] = [(0.82,0.92,0.94),(0.98,0.89,0.78),(0.85,0.88,0.96),(0.89,0.93,0.82)]
            let color = backgrounds[index]
            canvas.setFillColor(CGColor(red:color.0,green:color.1,blue:color.2,alpha:1)); canvas.fill(CGRect(x:0,y:0,width:768,height:768))
            canvas.setFillColor(CGColor(red:0.99,green:0.78,blue:0.35,alpha:1)); canvas.fillEllipse(in:CGRect(x:430,y:450,width:150,height:150))
            canvas.setFillColor(CGColor(red:0.25+CGFloat(index)*0.06,green:0.48,blue:0.42,alpha:1)); canvas.fillEllipse(in:CGRect(x:-160,y:-350,width:1200,height:800))
            canvas.setFillColor(CGColor(red:0.13,green:0.32+CGFloat(index)*0.04,blue:0.3,alpha:1)); canvas.fillEllipse(in:CGRect(x:270,y:-330,width:1000,height:650))
            let image = try XCTUnwrap(canvas.makeImage()); sample = image
            XCTAssertTrue(ScriptWidgetPackageFiles.ensureDirectory(root:mutable.path,relative:"image"))
            XCTAssertTrue(ScriptWidgetPackageFiles.write(try ScriptWidgetPhotoPreparation.encode(image),root:mutable.path,relative:"image/"+name+".png"))
        }
        let package = ScriptWidgetPackage(path:mutable.path,readonly:true), source = try XCTUnwrap(package.readMainFile().0)
        for layout in ["single","duo","grid"] {
            for (family,size) in [("small",CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
                let runtime = ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-param":try photoParameter(layout:layout)])
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let element = try XCTUnwrap(result.0)
                let context = ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Photo sample artwork",scriptParameter:"",package:package,containerBackgroundElement:element)
                let background = ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? .white
                let renderer = ImageRenderer(content:ScriptWidgetElementView(element:element,context:context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme,.light))
                renderer.scale=2
                let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("photo-\(layout)-\(family).png"))
            }
        }
        let cropView = ScriptWidgetPhotoCropView(image:try XCTUnwrap(sample),save:{ _ in false })
        let host = NSHostingView(rootView:cropView.frame(width:540,height:580).background(Color.white).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:580),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try await Task.sleep(nanoseconds:150_000_000)
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("photo-crop.png"))
    }
    #endif

    func testCountdownPackageRendersSavedDefaultsAndLegacyParametersNatively() throws {
        let package = ScriptWidgetPackage(bundle: "Script", relativePath: "template/Countdown")
        let source = try XCTUnwrap(package.readMainFile().0)
        var trees: [String: String] = [:]
        for family in ["small", "medium", "large", "extraLarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
            let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": family, "widget-param": "2026-03-09 Trip", "timeline-date": "2026-03-08T12:00:00"])
            let result = runtime.executeJSXSyncForWidget(source)
            XCTAssertNil(result.1, "\(family): \(result.1?.displayMessage ?? "")")
            let element = try XCTUnwrap(result.0)
            trees[family] = ScriptWidgetElementTreeJSON.encode(element)
            let text = collectText(element)
            XCTAssertTrue(text.contains("1"), family)
            if family != "accessoryCircular" { XCTAssertTrue(text.contains("Trip"), family) }
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web/preview-engine/test/parity/countdown-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_COUNTDOWN_PARITY"] == "1" {
            let document: [String: Any] = ["timeZone": TimeZone.current.identifier, "trees": trees]
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]).write(to: fixture, options: .atomic)
        } else {
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]
            XCTAssertEqual(document?["trees"] as? [String: String], trees)
        }
        let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium", "widget-param": "", "timeline-date": "2028-02-29T12:00:00"])
        let result = runtime.executeJSXSyncForWidget("""
            $storage.setString('recordTemplate.config.v1', JSON.stringify({version:1,kind:'countdown',values:{title:'Leap day',targetDate:'2024-02-29',repeatYearly:true,accent:'rose'}}));
            """ + source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        let text = collectText(try XCTUnwrap(result.0))
        XCTAssertTrue(text.contains("Today")); XCTAssertTrue(text.contains("Leap day"))
    }

    #if os(macOS)
    @MainActor
    func testExportCountdownWidgetSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_COUNTDOWN"] else {
            throw XCTSkip("Set SCRIPTWIDGET_EXPORT_COUNTDOWN for isolated native countdown renders")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let package = ScriptWidgetPackage(bundle: "Script", relativePath: "template/Countdown")
        let source = try XCTUnwrap(package.readMainFile().0)
        for (family, size) in [("small", CGSize(width:158,height:158)), ("medium", CGSize(width:338,height:158)), ("large", CGSize(width:338,height:354))] {
            for dark in [false, true] {
                let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size":family,"widget-param":"2027-07-12 Summer trip","timeline-date":"2027-06-30T12:00:00"])
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1, result.1?.displayMessage ?? "")
                let element = try XCTUnwrap(result.0)
                let context = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: "Countdown fixture", scriptParameter: "", package: package, containerBackgroundElement: element)
                let background = ScriptWidgetAttributeColor(element.getPropString("background") ?? "#ffffff").color ?? Color.white
                let renderer = ImageRenderer(content: ScriptWidgetElementView(element: element, context: context).frame(width:size.width,height:size.height).background(background).environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to: output.appendingPathComponent("countdown-\(family)-\(dark ? "dark" : "light").png"))
            }
        }
    }
    #endif

    private func calendarTemplateFixture(mode: String) throws -> String {
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Calendar Agenda/main.jsx"))
        let item = #"{"id":"sample","calendarID":"personal","title":"Read and recharge","start":"2026-01-01T15:00:00Z","end":"2026-01-01T15:30:00Z","allDay":false}"#
        let status = mode == "denied" ? "denied" : "authorized"
        let items = mode == "empty" ? "[]" : "[" + item + "]"
        let response = mode == "selection" ? "reject('[permission_denied] No Calendar sources are selected')" : "resolve({items: \(items), stale: false})"
        return """
            const $calendar = {
                isAvailable: () => true, authorizationStatus: () => '\(status)',
                events: () => ({then(resolve,reject) {\(response)}})
            };
            """ + source
    }

    func testCalendarTemplateRendersReadyEmptyAndDeniedAcrossFamilies() throws {
        for mode in ["ready", "empty", "denied", "selection"] {
            let source = try calendarTemplateFixture(mode: mode)
            for family in ["small", "medium", "large", "xlarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
                let result = makeRuntime(environments: ["widget-size": family, "widget-param": ""]).executeJSXSyncForWidget(source)
                XCTAssertNil(result.1, "\(mode) \(family)")
                let text = collectText(try XCTUnwrap(result.0))
                if mode == "ready" && family != "accessoryCircular" { XCTAssertTrue(text.contains("Read and recharge"), family) }
                if mode == "denied" { XCTAssertFalse(text.contains("Read and recharge"), family) }
                if mode == "selection" {
                    XCTAssertTrue(text.contains("Choose") || text.contains("Check"), family)
                    XCTAssertFalse(text.contains("No events") || text.contains("0 events"), family)
                }
                if mode == "empty" && family != "accessoryCircular" { XCTAssertTrue(text.contains("clear") || text.contains("No events"), family) }
            }
        }
    }

    #if os(iOS)
    @MainActor
    func testExportCalendarTemplateFixtureSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_CALENDAR"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_CALENDAR to export isolated native layout fixtures")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for mode in ["ready", "empty", "denied", "selection"] {
            let source = try calendarTemplateFixture(mode: mode)
            for (family, size) in [("small", CGSize(width: 158, height: 158)), ("medium", CGSize(width: 338, height: 158)), ("large", CGSize(width: 338, height: 354))] {
                let runtime = makeRuntime(environments: ["widget-size": family, "widget-param": ""])
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1)
                let element = try XCTUnwrap(result.0)
                let package = makeTempPackage()
                defer { try? FileManager.default.removeItem(at: package.path) }
                let context = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: "Calendar fixture", scriptParameter: "", package: package, containerBackgroundElement: element)
                let renderer = ImageRenderer(content: BrowserPreviewSnapshotView(element: element, context: context, size: size).environment(\.colorScheme, .light))
                renderer.scale = 2
                let png = try XCTUnwrap(renderer.uiImage?.pngData())
                try png.write(to: output.appendingPathComponent("\(mode)-\(family).png"), options: .atomic)
            }
        }
    }
    #endif


    private func remindersTemplateFixture(mode: String) throws -> String {
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Reminders Agenda/main.jsx"))
        let item = #"{"id":"sample","listID":"personal","title":"Read and recharge","due":"2026-01-01T15:00:00Z","hasTime":true,"completed":false,"completedAt":null,"priority":0}"#
        let status = mode == "denied" ? "denied" : "authorized"
        let items = mode == "empty" ? "[]" : "[" + item + "]"
        let response = mode == "selection" ? "reject('[permission_denied] No Reminder lists are selected')" : "resolve({items: \(items), stale: false})"
        return """
            const $reminders = {
                isAvailable: () => true, authorizationStatus: () => '\(status)',
                items: () => ({then(resolve,reject) {\(response)}})
            };
            """ + source
    }

    func testRemindersTemplateRendersReadyEmptyAndDeniedAcrossFamilies() throws {
        for mode in ["ready", "empty", "denied", "selection"] {
            let source = try remindersTemplateFixture(mode: mode)
            for family in ["small", "medium", "large", "xlarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
                let result = makeRuntime(environments: ["widget-size": family, "widget-param": ""]).executeJSXSyncForWidget(source)
                XCTAssertNil(result.1, "\(mode) \(family)")
                let text = collectText(try XCTUnwrap(result.0))
                if mode == "ready" && family != "accessoryCircular" { XCTAssertTrue(text.contains("Read and recharge"), family) }
                if mode == "denied" { XCTAssertFalse(text.contains("Read and recharge"), family) }
                if mode == "selection" {
                    XCTAssertTrue(text.contains("Choose") || text.contains("Check") || text.contains("Review list access"), family)
                    XCTAssertFalse(text.contains("Nothing due") || text.contains("0 items"), family)
                }
                if mode == "empty" && family != "accessoryCircular" { XCTAssertTrue(text.contains("No reminders due") || text.contains("Nothing due"), family) }
            }
        }
    }

    #if os(iOS)
    @MainActor
    func testExportRemindersTemplateFixtureSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_REMINDERS"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_REMINDERS to export isolated native layout fixtures")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for mode in ["ready", "empty", "denied", "selection"] {
            let source = try remindersTemplateFixture(mode: mode)
            for (family, size) in [("small", CGSize(width: 158, height: 158)), ("medium", CGSize(width: 338, height: 158)), ("large", CGSize(width: 338, height: 354))] {
                let runtime = makeRuntime(environments: ["widget-size": family, "widget-param": ""])
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1)
                let element = try XCTUnwrap(result.0)
                let package = makeTempPackage()
                defer { try? FileManager.default.removeItem(at: package.path) }
                let context = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: "Reminders fixture", scriptParameter: "", package: package, containerBackgroundElement: element)
                let renderer = ImageRenderer(content: BrowserPreviewSnapshotView(element: element, context: context, size: size).environment(\.colorScheme, .light))
                renderer.scale = 2
                let png = try XCTUnwrap(renderer.uiImage?.pngData())
                try png.write(to: output.appendingPathComponent("\(mode)-\(family).png"), options: .atomic)
            }
        }
    }
    #endif


    func testTimelineProjectionIsReadOnlyEvenWhenScriptReplacesGetenv() throws {
        let runtime = makeRuntime(environments: ["timeline-date": "2026-01-01T12:00:00.000Z", "timeline-is-projection": "true"])
        let store = try XCTUnwrap(runtime.runningState?.storageDefaultsForTesting)
        let namespace = try XCTUnwrap(runtime.runningState?.storageNamespace)
        store.set("saved", forKey: namespace + "day")
        store.set(try JSONSerialization.data(withJSONObject: ["keep": true]), forKey: namespace + "object")
        defer { store.removeObject(forKey: namespace + "day"); store.removeObject(forKey: namespace + "object") }
        let result = runtime.executeJSXSyncForWidget("""
            $getenv = () => 'false';
            const writes = [$storage.setString('day','lost'),$storage.setJSON('object',{lost:true}),$storage.compareAndSetString('day','saved','lost'),$storage.compareAndSetJSON('object',{keep:true},{lost:true}),$storage.remove('day'),$storage.clear()];
            let blocked = 0;
            for(const call of [() => fetch('https://example.com'), () => $http.post('https://example.com',{}), () => $dataSource.request('example.plugin','read',{})]) {
                try { await call(); } catch(error) { if(String(error).includes('[timeline_read_only]')) blocked++; }
            }
            $render(<text>{JSON.stringify({writes,blocked,day:$storage.getString('day'),object:$storage.getJSON('object')})}</text>);
            """)
        XCTAssertNil(result.1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(collectText(try XCTUnwrap(result.0)).utf8)) as? [String: Any])
        XCTAssertEqual(object["writes"] as? [Bool], [false, false, false, false, false, false])
        XCTAssertEqual(object["blocked"] as? Int, 3)
        XCTAssertEqual(object["day"] as? String, "saved")
        XCTAssertEqual((object["object"] as? [String: Bool])?["keep"], true)
    }

    func testScheduledThemeUsesPlannedSlotAcrossEveryFamily() throws {
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Day Rhythm/main.jsx"))
        let titles = ["Morning focus", "Afternoon flow", "Evening reset", "Quiet hours"]
        for slot in 0..<4 {
            for family in ["small", "medium", "large", "extraLarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
                let environment = ["widget-size": family, "timeline-date": "2026-01-01T12:00:00.000Z", "timeline-slot": String(slot), "timeline-is-projection": "true"]
                let result = makeRuntime(environments: environment).executeJSXSyncForWidget(source)
                XCTAssertNil(result.1, "\(slot) \(family)")
                let text = collectText(try XCTUnwrap(result.0))
                if family == "accessoryCircular" { XCTAssertTrue(text.contains("\(slot + 1)/4")) }
                else { XCTAssertTrue(text.contains(titles[slot]), family) }
            }
        }
    }

    func testExportScheduledThemeCanonicalTrees() throws {
        guard let file = ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_TIMELINE_PARITY"], !file.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_UPDATE_TIMELINE_PARITY to export fixed-date canonical trees")
        }
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Day Rhythm/main.jsx"))
        var trees: [String: String] = [:]
        for slot in 0..<4 {
            for family in ["small", "medium", "large", "extraLarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"] {
                let result = makeRuntime(environments: ["widget-size": family, "timeline-date": "2026-01-01T12:00:00.000Z", "timeline-slot": String(slot), "timeline-is-projection": "true"]).executeJSXSyncForWidget(source)
                XCTAssertNil(result.1)
                trees["\(slot)@\(family)"] = ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }
        }
        let object: [String: Any] = ["scope": "Day Rhythm with fixed planned date and slot, native resolved element trees", "entries": trees]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    func testFiveScheduledEntriesRetainBoundedRuntimeStateAndRecordBaseline() throws {
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return status == KERN_SUCCESS ? info.phys_footprint : 0
        }
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Day Rhythm/main.jsx"))
        let now = Date(timeIntervalSince1970: 1_767_243_600)
        let plan = ScriptWidgetTimelinePlan(schedule: .init(dailyTimes: ["06:00", "12:00", "18:00", "22:00"], timeZone: "UTC"), now: now, fallbackReload: now.addingTimeInterval(86_400))
        let baseline = footprint()
        let started = ContinuousClock.now
        var retained: [(ScriptWidgetRuntime, ScriptWidgetRuntimeElement)] = []
        for entry in plan.entries {
            let runtime = makeRuntime(environments: entry.environments(timeZone: plan.timeZone).merging(["widget-size": "medium"]) { _, next in next })
            let result = runtime.executeJSXSyncForWidget(source)
            XCTAssertNil(result.1)
            retained.append((runtime, try XCTUnwrap(result.0)))
        }
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(retained.count, 5)
        XCTAssertLessThan(elapsed, .seconds(5), "The representative five-entry theme exceeded its generation budget")
        let peak = footprint()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let data: [String: Any] = ["entries": retained.count, "seconds": seconds, "baselineFootprint": baseline, "retainedFootprint": peak, "deltaBytes": peak > baseline ? peak - baseline : 0, "scope": "Hosted test process with five retained JavaScript runtimes, not WidgetKit extension memory acceptance"]
        let encoded = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "timeline-runtime-baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_TIMELINE_BASELINE"], !directory.isEmpty {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            #if os(iOS)
            let filename = "ios-baseline.json"
            #else
            let filename = "macos-baseline.json"
            #endif
            try encoded.write(to: path.appendingPathComponent(filename), options: .atomic)
        }
    }

    #if os(iOS)
    @MainActor
    func testExportScheduledThemeSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_TIMELINE"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_TIMELINE to export isolated native scheduled layouts")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/Day Rhythm/main.jsx"))
        for slot in 0..<4 {
            for (family, size) in [("small", CGSize(width: 158, height: 158)), ("medium", CGSize(width: 338, height: 158)), ("large", CGSize(width: 338, height: 354))] {
                let runtime = makeRuntime(environments: ["widget-size": family, "timeline-slot": String(slot), "timeline-is-projection": "true"])
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1)
                let element = try XCTUnwrap(result.0)
                let package = makeTempPackage()
                defer { try? FileManager.default.removeItem(at: package.path) }
                let context = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: "Timeline fixture", scriptParameter: "", package: package, containerBackgroundElement: element)
                let renderer = ImageRenderer(content: BrowserPreviewSnapshotView(element: element, context: context, size: size).environment(\.colorScheme, .light))
                renderer.scale = 2
                try XCTUnwrap(renderer.uiImage?.pngData()).write(to: output.appendingPathComponent("phase-\(slot)-\(family).png"), options: .atomic)
            }
        }
    }
    #endif

    private func locationTemplateFixture(mode: String, name: String = "Location Snapshot") throws -> String {
        let source = try XCTUnwrap(ScriptManager.readBundleFile(bundle: "Script", fileName: "template/\(name)/main.jsx"))
        let status = mode == "denied" ? "denied" : "authorizedWhenInUse"
        let message = mode == "widgetDenied" ? "[widget_not_authorized] Widget location is not approved" : "[no_data] No location fix"
        let body = mode == "ready" ? "resolve({latitude:37.3349,longitude:-122.009,accuracy:1000,timestamp:'2026-01-01T12:00:00Z'})" : "reject('\(message)')"
        return """
            const $location = {
                isAvailable: () => true, authorizationStatus: () => '\(status)', isAuthorizedForWidgetUpdates: () => \(mode != "widgetDenied"),
                current: () => ({then(resolve,reject) { \(body); }})
            };
            """ + source
    }

    func testLocationTemplatesExplainDeniedWidgetAccessAndMissingFixAcrossFamilies() throws {
        for name in ["Location Snapshot", "Local Weather (Location)"] {
            for mode in ["denied", "widgetDenied", "empty"] {
                let source = try locationTemplateFixture(mode: mode, name: name)
                for family in ["small", "medium", "large", "xlarge", "extraLargePortrait"] {
                    let runtime = name == "Local Weather (Location)" ? ScriptWidgetRuntime(package: ScriptWidgetPackage(bundle:"Script",relativePath:"template/" + name),environments:["widget-size":family]) : makeRuntime(environments:["widget-size":family])
                    let result = runtime.executeJSXSyncForWidget(source)
                    XCTAssertNil(result.1, "\(name) \(mode) \(family)")
                    let text = collectText(try XCTUnwrap(result.0))
                    XCTAssertFalse(text.contains("37.3349"))
                    if name == "Local Weather (Location)" { XCTAssertTrue(text.contains("Choose a saved city"), text) }
                    else {
                        if mode == "widgetDenied" { XCTAssertTrue(text.contains("Allow widget location") || text.contains("Allow widgets")) }
                        if mode == "empty" { XCTAssertTrue(text.contains("Location unavailable") || text.contains("No location yet")) }
                    }
                }
            }
        }
    }

    #if os(iOS)
    @MainActor
    func testExportLocationTemplateFixtureSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LOCATION"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_LOCATION to export isolated native layout fixtures")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for mode in ["ready", "widgetDenied", "empty"] {
            let source = try locationTemplateFixture(mode: mode)
            for (family, size) in [("small", CGSize(width: 158, height: 158)), ("medium", CGSize(width: 338, height: 158)), ("large", CGSize(width: 338, height: 354))] {
                let runtime = makeRuntime(environments: ["widget-size": family])
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1)
                let element = try XCTUnwrap(result.0)
                let package = makeTempPackage()
                defer { try? FileManager.default.removeItem(at: package.path) }
                let context = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: "Location fixture", scriptParameter: "", package: package, containerBackgroundElement: element)
                let renderer = ImageRenderer(content: BrowserPreviewSnapshotView(element: element, context: context, size: size).environment(\.colorScheme, .light))
                renderer.scale = 2
                try XCTUnwrap(renderer.uiImage?.pngData()).write(to: output.appendingPathComponent("\(mode)-\(family).png"), options: .atomic)
            }
        }
    }
    #endif

    #if os(iOS)
    @MainActor
    func testLocationCoreLocationBridgeWithExplicitSimulatorFixture() async throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_LOCATION_SIMULATOR_PROBE"] == "1" else {
            throw XCTSkip("Run on a dedicated simulator with explicit Location Services permission and fixed coordinates")
        }
        #if targetEnvironment(simulator)
        let package = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: package.path) }
        var manifest = WidgetPackageManifest.newProject(name: package.name)
        manifest.permissions = [.location]
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        let runtime = storageRuntime(package: package, environments: ["widget-size": "medium"])
        let result = await Task.detached {
            runtime.executeJSXSyncForWidget("""
                const location = await $location.current({timeout:3});
                $render(<text>{JSON.stringify({latitude:location.latitude,longitude:location.longitude,accuracy:location.accuracy,age:location.age,status:$location.authorizationStatus()})}</text>);
                """)
        }.value
        XCTAssertNil(result.1)
        let text = collectText(try XCTUnwrap(result.0))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(object["latitude"] as? Double), 37.3349, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["longitude"] as? Double), -122.009, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(object["accuracy"] as? Double), 0)
        XCTAssertLessThan(try XCTUnwrap(object["age"] as? Double), 60)
        XCTAssertTrue(["authorizedAlways", "authorizedWhenInUse"].contains(object["status"] as? String ?? ""))
        #else
        throw XCTSkip("This probe uses simulator-controlled coordinates, never a person's device location")
        #endif
    }

    func testUndeclaredLocationCannotPromptOrReturnCoordinates() throws {
        let package = makeTempPackage()
        defer { try? FileManager.default.removeItem(at: package.path) }
        let manifest = WidgetPackageManifest.newProject(name: package.name)
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        let result = storageRuntime(package: package, environments: [:]).executeJSXSyncForWidget("""
            let denied = 0;
            try { await $location.current(); } catch(error) { if(String(error).includes('[permission_denied]')) denied++; }
            try { await $location.requestAuthorization(); } catch(error) { if(String(error).includes('[permission_denied]')) denied++; }
            $render(<text>{$location.authorizationStatus() + '|' + $location.isAuthorizedForWidgetUpdates() + '|' + denied}</text>);
            """)
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), "undeclared|false|2")
    }
    #endif

    func testHealthReadAuthorizationDoesNotClaimIndividualGrants() throws {
        let result = makeRuntime().executeJSXSyncForWidget("$render(<text>{$health.authorizationStatus()}</text>);")
        XCTAssertNil(result.1)
        let status = collectText(try XCTUnwrap(result.0))
        XCTAssertTrue(["notDisclosed", "unavailable"].contains(status))
    }

    func testPackagePreflightRejectsFutureRuntimeBeforeAllExecutionSurfaces() throws {
        for minimum in ["1.5", "2.0", "01.3"] {
            let package = makeTempPackage()
            defer { try? FileManager.default.removeItem(at: package.path) }
            var manifest = WidgetPackageManifest.newProject(name: package.name)
            manifest.minimumRuntimeVersion = minimum
            try JSONEncoder().encode(manifest).write(to: package.path.appendingPathComponent("widget.json"))
            let source = """
                $storage.setString('preflight-probe', 'executed');
                function actionProbe() { $storage.setString('preflight-probe', 'action'); }
                $render(<text>Executed</text>);
                """
            let environments = ["widget-size": "medium"]
            let widget = ScriptWidgetRuntime(package: package, environments: environments).executeJSXSyncForWidget(source)
            let island = ScriptWidgetRuntime(package: package, environments: environments).executeJSXSyncForDynamicIsland(source)
            let action = ScriptWidgetRuntime(package: package, environments: environments).executeJSXSyncForFunction(source, "actionProbe")
            for error in [widget.1, island.1, action.1] {
                XCTAssertTrue(error?.displayMessage.contains("minimum_runtime") == true, minimum)
            }
            let defaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard
            XCTAssertNil(defaults.object(forKey: "script.\(package.name).preflight-probe"))
        }
    }


    func testStorageCompareAndSetExecutesThroughNativeBridge() throws {
        let package = makeTempPackage()
        defer {
            _ = storageRuntime(package: package, environments: [:]).executeJSXSyncForWidget("$storage.clear(); $render(<text>clear</text>);")
            try? FileManager.default.removeItem(at: package.path)
        }
        let runtime = storageRuntime(package: package, environments: [:])
        let result = runtime.executeJSXSyncForWidget("""
            const first = $storage.compareAndSetString('count','','1');
            const stale = $storage.compareAndSetString('count','','lost');
            const next = $storage.compareAndSetString('count','1','2');
            const json = $storage.compareAndSetJSON('state',{}, {b:2,a:1});
            const update = $storage.compareAndSetJSON('state',{a:1,b:2},{a:2});
            $render(<text>{[first,stale,next,json,update,$storage.getString('count'),$storage.getJSON('state').a].join('|')}</text>);
            """)
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), "true|false|true|true|true|2|2")
    }

    func testHabitConflictRereadsAndPreservesAnotherWritersDay() throws {
        let source = try habitSource(day: 3, month: 1)
        let prefix = """
            const conflictFixture = {raw:'["2026-01-01"]', attempts:0};
            $storage = {
                getString: key => key.endsWith('.read') ? conflictFixture.raw : '',
                compareAndSetString(key,expected,next) {
                    conflictFixture.attempts++;
                    if(conflictFixture.attempts === 1) { conflictFixture.raw = '["2026-01-01","2026-01-02"]'; return false; }
                    if(conflictFixture.raw !== expected) return false;
                    conflictFixture.raw = next; return true;
                }
            };
            """
        let suffix = """
            const finalRender = $render;
            $render = () => {};
            checkInRead();
            $render = finalRender;
            $render(<text>{conflictFixture.raw + '|' + conflictFixture.attempts}</text>);
            """
        let package = makeTempPackage()
        defer {
            try? FileManager.default.removeItem(at: package.path)
            if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: package.name) }
        }
        let result = habitRuntime(package, size: "action").executeJSXSyncForWidget(prefix + source + suffix)
        XCTAssertNil(result.1)
        XCTAssertEqual(collectText(try XCTUnwrap(result.0)), #"["2026-01-01","2026-01-02","2026-01-03"]|2"#)
    }


    #if DEBUG
    func testAtomicStorageUnavailableDoesNotFallBackToAnUncoordinatedWrite() throws {
        let runtime = makeRuntime()
        let defaults = try XCTUnwrap(runtime.runningState?.storageDefaultsForTesting)
        let namespace = try XCTUnwrap(runtime.runningState?.storageNamespace)
        defaults.set("history", forKey: namespace + "saved")
        _ = defaults.synchronize()
        defer { defaults.removeObject(forKey: namespace + "saved"); _ = defaults.synchronize() }
        runtime.runningState?.storageContainerForTesting = FileManager.default.temporaryDirectory.appendingPathComponent("AbsentAtomicContainer-\(UUID().uuidString)")
        let result = runtime.executeJSXSyncForWidget("""
            const saved = $storage.compareAndSetString('saved','history','lost');
            $render(<text>{String(saved) + '|' + $storage.getString('saved')}</text>);
            """)
        // The entire declared shared root is missing, so the migration fence
        // cannot authorize a read. Preserve history instead of treating that
        // failure as an empty record or using an uncoordinated write.
        XCTAssertTrue(result.1?.displayMessage.contains("storage:unavailable") == true)
        XCTAssertNil(result.0)
        XCTAssertEqual(defaults.string(forKey: namespace + "saved"), "history")
    }
    #endif

}

final class NativeSnapshotExecutionTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var cache: URL!
    private var container: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var context: ScriptWidgetPackageStorageContext!
    private var packageName: String!
    private var manager: ScriptManager!
    private var package: ScriptWidgetPackage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExecutionSnapshot-" + UUID().uuidString)
        library = root.appendingPathComponent("library"); cache = root.appendingPathComponent("cache"); container = root.appendingPathComponent("preferences")
        for directory in [library!, cache!, container!] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        suite = "app.scriptwidget.execution-snapshot-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: container, defaults: defaults)
        context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        manager = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context)
        packageName = "Snapshot-" + UUID().uuidString
        XCTAssertTrue(manager.createScript(content: "$render(<text>captured</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        package = manager.getScriptPackage(packageName: packageName)
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if let build = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: build, relative: packageName) }
        try FileManager.default.removeItem(at: root)
    }
    private func capture(_ override: String? = nil, limits: ScriptWidgetExecutionSnapshotLimits = .init()) throws -> ScriptWidgetExecutionSnapshot {
        try ScriptWidgetExecutionSnapshot(name: packageName, role: .source, context: context, entryOverride: override, limits: limits)
    }
    private func runtime(_ captured: ScriptWidgetExecutionSnapshot, projection: Bool = false) -> ScriptWidgetRuntime {
        ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium", "timeline-is-projection": projection ? "true" : "false"], executionSnapshot: captured)
    }
    private func text(_ element: ScriptWidgetRuntimeElement) -> String {
        (element.getChildren().compactMap { $0 as? String } + element.childrenAsElements().map(text)).joined(separator: " ")
    }
    private func render(_ source: String, projection: Bool = false) throws -> String {
        try autoreleasepool {
            let captured = try capture(source)
            let result = runtime(captured, projection: projection).executeJSXSyncForWidget(captured.source)
            XCTAssertNil(result.1, result.1?.displayMessage ?? "")
            return text(try XCTUnwrap(result.0))
        }
    }

    func testMainImportsFilesImagesAndManifestRemainFrozenAfterSourceEdits() throws {
        XCTAssertTrue(package.writeFile(relativePath: "lib/helper.js", content: "var capturedValue = 'old helper';").0)
        XCTAssertTrue(package.writeFile(relativePath: "data.json", content: #"{"value":"old file"}"#).0)
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data([1, 2, 3]), root: package.path, relative: "image/frozen.png"))
        XCTAssertTrue(package.writeMainFile(content: "$import('lib/helper.js'); $render(<text>{capturedValue + ':' + $file.readJSON('data.json').value}</text>);").0)
        let captured = try capture()
        try prepareFunctionalTranspile(captured.source)
        try prepareFunctionalTranspile(try XCTUnwrap(captured.package.readFile(relativePath: "lib/helper.js").0), wrapMain: false)
        XCTAssertTrue(package.writeFile(relativePath: "lib/helper.js", content: "var capturedValue = 'new helper';").0)
        XCTAssertTrue(package.writeFile(relativePath: "data.json", content: #"{"value":"new file"}"#).0)
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data([9]), root: package.path, relative: "image/frozen.png"))
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        let result = runtime(captured).executeJSXSyncForWidget(captured.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "old helper:old file")
        XCTAssertEqual(captured.package.readManifest()?.permissions, [.storage])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(captured.package.getImage("frozen")).path), Data([1, 2, 3]))
        XCTAssertFalse(captured.package.writeMainFile(content: "must not change").0)
    }

    func testFileExistsUsesFrozenResourceSnapshotAfterOriginalAssetIsRemoved() throws {
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data([0,255]),root:package.path,relative:"image/present.png"))
        XCTAssertTrue(package.writeMainFile(content:"$render(<text>{String($file.exists('image/present.png'))}</text>);").0)
        let captured=try capture()
        XCTAssertTrue(ScriptWidgetPackageFiles.removeFile(root:package.path,relative:"image/present.png"))
        let result=runtime(captured).executeJSXSyncForWidget(captured.source)
        XCTAssertNil(result.1,result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)),"true")
    }

    func testStorageBridgeUsesOriginalUUIDAndPersistsAcrossIndependentSnapshots() throws {
        let source = """
        const old = $storage.getString('count');
        const next = String(Number(old || '0') + 1);
        if (!$storage.compareAndSetString('count', old, next)) throw new Error('CAS failed');
        if (!$storage.setJSON('json', {value: next})) throw new Error('JSON write failed');
        if (!$storage.compareAndSetJSON('json', {value: next}, {value: 'done'})) throw new Error('JSON CAS failed');
        $render(<text>{next + ':' + $storage.getJSON('json').value}</text>);
        """
        XCTAssertEqual(try render(source), "1:done")
        XCTAssertEqual(try render(source), "2:done")
        let prefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: prefix + "count"), "2")
        XCTAssertNil(defaults.object(forKey: "script." + packageName + ".count"))
    }

    func testSnapshotNeverAdoptsCallerSourceWithoutExplicitNativeEditorOverride() throws {
        let captured = try capture()
        let wrong = runtime(captured).executeJSXSyncForWidget("$storage.setString('wrong', '1'); $render(<text>other</text>);")
        XCTAssertTrue(wrong.1?.displayMessage.contains("source_changed") == true)
        XCTAssertNil(defaults.object(forKey: captured.storageNamespace + "wrong"))
        XCTAssertEqual(try render("$render(<text>explicit preview</text>);"), "explicit preview")
    }

    func testReinstalledIdentityStopsStaleRuntimeBeforeAnyStorageSideEffect() throws {
        let captured = try capture("$storage.setString('side-effect', 'must not write'); $render(<text>stale</text>);")
        let stale = runtime(captured)
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertTrue(manager.createScript(content: "$render(<text>fresh</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        let freshPrefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        XCTAssertNotEqual(freshPrefix, captured.storageNamespace)
        let result = stale.executeJSXSyncForWidget(captured.source)
        XCTAssertTrue(result.1?.displayMessage.contains("identity_changed") == true)
        XCTAssertNil(defaults.object(forKey: freshPrefix + "side-effect"))
        XCTAssertNil(defaults.object(forKey: captured.storageNamespace + "side-effect"))
    }

    func testStoragePermissionIsFrozenAndMissingDeclarationFailsClosed() throws {
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        let captured = try capture("$storage.setString('denied', '1'); $render(<text>unexpected</text>);")
        manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        let result = runtime(captured).executeJSXSyncForWidget(captured.source)
        XCTAssertTrue(result.1?.displayMessage.contains("permission_denied") == true)
        XCTAssertNil(defaults.object(forKey: captured.storageNamespace + "denied"))
    }

    func testProjectionCannotWriteRemoveOrClearRealRecords() throws {
        XCTAssertEqual(try render("$storage.setString('keep', 'original'); $render(<text>ready</text>);"), "ready")
        let output = try render("""
        const denied = [$storage.setString('keep','changed'), $storage.setJSON('json',{n:1}),
          $storage.compareAndSetString('keep','original','changed'), $storage.remove('keep'), $storage.clear()];
        $render(<text>{String(denied.every(value => value === false)) + ':' + $storage.getString('keep')}</text>);
        """, projection: true)
        XCTAssertEqual(output, "true:original")
    }

    func testScopedStringJSONAndCASWritesRespectTheAggregateBudget() throws {
        let prefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        for index in 0..<ScriptWidgetStorageNamespaces.maximumNamespaceKeys { defaults.set("x", forKey: prefix + "key-\(index)") }
        let output = try render("""
        const rejected = [$storage.setString('extra','x'), $storage.setJSON('json',{n:1}),
          $storage.compareAndSetString('cas','','x'), $storage.compareAndSetJSON('cas-json',{}, {n:1})];
        const updated = $storage.setString('key-0','updated');
        const removed = $storage.remove('key-1');
        const added = $storage.compareAndSetString('new-after-remove','','ok');
        $render(<text>{String(rejected.every(value => value === false)) + ':' + String(updated && removed && added)}</text>);
        """)
        XCTAssertEqual(output, "true:true")
        XCTAssertNil(defaults.object(forKey: prefix + "extra"))
    }

    func testWholeCacheSnapshotRunsWithoutMixingAnUnavailableSource() throws {
        let builder = ScriptManager(isBuild: false, scriptDirectoryOverride: library, storageContext: context, buildDirectoryOverride: cache)
        let built = builder.buildScriptPackage(package: package)
        XCTAssertTrue(built.0, built.1)
        let cacheContext = try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults)
        let captured = try ScriptWidgetExecutionSnapshot(name: packageName, role: .cache, context: cacheContext)
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        let result = runtime(captured).executeJSXSyncForWidget(captured.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "captured")
        XCTAssertEqual(captured.binding.ownerID, try cacheContext.boundDirectory(name: packageName, role: .cache).ownerID)
    }

    func testCapturedRuntimeCannotLoadOrPersistGlobalCompiledArtifacts() throws {
        let captured = try capture()
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: ScriptWidgetPackage(path: package.path, readonly: false), source: captured.source,
            javaScript: "throw new Error('must not load global artifact');"))
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.load(package: captured.package, source: captured.source))
        XCTAssertFalse(ScriptWidgetCompiledArtifactStore.save(package: captured.package, source: captured.source, javaScript: "not trusted"))
        let result = runtime(captured).executeJSXSyncForWidget(captured.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "captured")
    }

    func testSnapshotRetainsResourcesAfterRuntimeReleaseAndCleansUpAfterLastPackage() throws {
        var captured: ScriptWidgetExecutionSnapshot? = try capture()
        var retained: ScriptWidgetPackage? = captured?.package
        weak let files = retained?.executionFiles
        let directory = try XCTUnwrap(files?.directory)
        captured = nil
        XCTAssertNotNil(files)
        XCTAssertEqual(retained?.readMainFile().0, "$render(<text>captured</text>);")
        retained = nil
        XCTAssertNil(files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSnapshotCopyRejectsTraversalLinksAndDeclaredResourceLimits() throws {
        XCTAssertTrue(package.writeFile(relativePath: "data.txt", content: String(repeating: "x", count: 128)).0)
        var limits = ScriptWidgetExecutionSnapshotLimits(); limits.maximumFileBytes = 64
        XCTAssertThrowsError(try capture(limits: limits))
        limits = .init(); limits.maximumEntries = 1
        XCTAssertThrowsError(try capture(limits: limits))
        limits = .init(); limits.maximumTotalBytes = 64
        XCTAssertThrowsError(try capture(limits: limits))
        limits = .init(); limits.maximumDepth = 1
        XCTAssertTrue(package.writeFile(relativePath: "nested/data.txt", content: "nested").0)
        XCTAssertThrowsError(try capture(limits: limits))
        let outside = root.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: package.path.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try capture())
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("link"))
        XCTAssertEqual(link(outside.path, package.path.appendingPathComponent("hard-link").path), 0)
        XCTAssertThrowsError(try capture())
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("hard-link"))
        XCTAssertEqual(mkfifo(package.path.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try capture())
        XCTAssertEqual(try Data(contentsOf: outside), Data("private".utf8))
    }

    func testExecutionLeaseBudgetDoesNotEvictActiveResources() throws {
        let temporary = root.appendingPathComponent("leases")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var leases = try (0..<ScriptWidgetExecutionFiles.maximumActiveSnapshots).map { _ in try ScriptWidgetExecutionFiles(temporaryRoot: temporary) }
        let first = try XCTUnwrap(leases.first).directory
        XCTAssertThrowsError(try ScriptWidgetExecutionFiles(temporaryRoot: temporary))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        leases.removeLast()
        let replacement = try ScriptWidgetExecutionFiles(temporaryRoot: temporary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.directory.path))
        leases.removeAll()
    }

    func testScopedByteBudgetRejectsNewValuesButAllowsShrinkingRecords() throws {
        let prefix = try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults)
        for index in 0..<8 { defaults.set(String(repeating: "x", count: 256 * 1024), forKey: prefix + "large-\(index)") }
        let output = try render("""
        const rejected = [$storage.setString('extra','x'), $storage.setJSON('json',{n:1}),
          $storage.compareAndSetString('cas','','x'), $storage.compareAndSetJSON('cas-json',{}, {n:1})];
        const shrunk = $storage.setString('large-0','small');
        const added = $storage.setString('after-shrink','allowed');
        $render(<text>{String(rejected.every(value => value === false)) + ':' + String(shrunk && added)}</text>);
        """)
        XCTAssertEqual(output, "true:true")
    }

    func testOversizedEntryAndInvalidManifestCannotCreateARunnableSnapshot() throws {
        XCTAssertTrue(package.writeMainFile(content: String(repeating: "x", count: ScriptWidgetExecutionSnapshot.maximumSourceBytes + 1)).0)
        XCTAssertThrowsError(try capture())
        XCTAssertTrue(package.writeMainFile(content: "$render(<text>normal</text>);").0)
        try Data("{invalid".utf8).write(to: package.manifestPath)
        XCTAssertThrowsError(try capture())
    }

    func testRendererUsesSnapshotResourcesInsteadOfTheMutableCallerPackage() throws {
        let captured = try capture()
        let runtime = runtime(captured)
        let renderContext = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: packageName, scriptParameter: "", package: package)
        XCTAssertEqual(renderContext.package.path, captured.package.path)
        XCTAssertNotNil(renderContext.package.executionFiles)
        XCTAssertTrue(package.writeMainFile(content: "$render(<text>changed</text>);").0)
        XCTAssertEqual(renderContext.package.readMainFile().0, "$render(<text>captured</text>);")
    }

    func testFunctionExecutionWritesTheSameCapturedUUIDNamespace() throws {
        let captured = try capture("""
        function checkIn() {
          if (!$storage.compareAndSetString('action-count','','1')) throw new Error('Action CAS failed');
        }
        $render(<text>ready</text>);
        """)
        let result = runtime(captured).executeJSXSyncForFunction(captured.source, "checkIn")
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(defaults.string(forKey: captured.storageNamespace + "action-count"), "1")
        XCTAssertNil(defaults.object(forKey: "script." + packageName + ".action-count"))
    }

    func testLegacyRendererKeepsTheExplicitResourcePackage() throws {
        let originalRuntime = ScriptWidgetRuntime(package: package, environments: [:])
        let resources = ScriptWidgetPackage(path: root.appendingPathComponent("explicit-resources"), readonly: true)
        let context = ScriptWidgetElementContext(runtime: originalRuntime, debugMode: false, scriptName: packageName, scriptParameter: "", package: resources)
        XCTAssertEqual(context.package.path, resources.path)
        XCTAssertNil(context.package.executionFiles)
    }
}

private final class NativeIdentityURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (NativeIdentityURLProtocol) -> Void] = [:]
    static func set(_ host: String, handler: ((NativeIdentityURLProtocol) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }
    override class func canInit(with request: URLRequest) -> Bool {
        Self.lock.lock();defer{Self.lock.unlock()}
        return request.url?.host?.hasPrefix("native-identity-") == true || handlers[request.url?.host ?? ""] != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
        if let handler { handler(self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    }
    override func stopLoading() {}
    func respond(_ text: String, status: Int = 200, headers: [String: String] = ["Content-Type": "text/plain"]) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class NativeAPIIdentityTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var container: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var context: ScriptWidgetPackageStorageContext!
    private var packageName: String!
    private var host: String!
    private var manager: ScriptManager!
    private var package: ScriptWidgetPackage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("APIIdentity-" + UUID().uuidString)
        library = root.appendingPathComponent("library"); container = root.appendingPathComponent("preferences")
        for directory in [library!, container!] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        suite = "app.scriptwidget.api-identity-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [], inventoryIsComplete: true, container: container, defaults: defaults)
        context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: defaults)
        manager = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context)
        packageName = "APIs-" + UUID().uuidString
        host = "native-identity-" + UUID().uuidString.lowercased() + ".example.com"
        XCTAssertTrue(manager.createScript(content: "$render(<text>ready</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        package = manager.getScriptPackage(packageName: packageName)
        var manifest = try XCTUnwrap(package.readManifest())
        manifest.permissions = [.network, .storage]; manifest.networkDomains = [host]
        XCTAssertTrue(package.writeManifest(manifest).0)
    }
    override func tearDownWithError() throws {
        NativeIdentityURLProtocol.set(host, handler: nil)
        defaults.removePersistentDomain(forName: suite)
        if let build = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: build, relative: packageName) }
        try FileManager.default.removeItem(at: root)
    }
    private func captured(_ source: String? = nil) throws -> ScriptWidgetExecutionSnapshot {
        try ScriptWidgetExecutionSnapshot(name: packageName, role: .source, context: context, entryOverride: source)
    }
    private func state() throws -> ScriptWidgetRunningState {
        let snapshot = try captured()
        return ScriptWidgetRunningState(package: snapshot.package, executionSnapshot: snapshot)
    }
    private func callbacks(_ state: ScriptWidgetRunningState) throws -> (JSContext, JSValue, JSValue) {
        let js = try XCTUnwrap(JSContext())
        js.scriptWidgetRunningState = state
        js.evaluateScript("var received = []; function success(v) { received.push('ok:' + String(v)); } function failure(v) { received.push('error:' + String(v)); }")
        return (js, try XCTUnwrap(js.objectForKeyedSubscript("success")), try XCTUnwrap(js.objectForKeyedSubscript("failure")))
    }
    private func values(_ js: JSContext, state: ScriptWidgetRunningState) -> [String] {
        state.executionSession.callbackQueue.sync {}
        return js.objectForKeyedSubscript("received")?.toArray() as? [String] ?? []
    }

    func testPromiseEntryChecksItsCallbackContextBeforeStartingTheNativeProducer() throws {
        let state = try state(), callbacks = try callbacks(state)
        var started = false
        let promise = ScriptWidgetRuntimePromise { _, _ in started = true }
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        promise.then(callbacks.1, callbacks.2)
        XCTAssertFalse(started)
        XCTAssertTrue(values(callbacks.0, state: state).first?.contains("execution_inactive") == true)
        XCTAssertEqual(state.executionSession.cancellation, .superseded)
    }

    func testPromiseDeliversAtMostOneValueOnItsSerialCallbackQueue() throws {
        let state = try state(), callbacks = try callbacks(state)
        let promise = ScriptWidgetRuntimePromise { resolve, reject in
            resolve.call(withArguments: ["first"])
            reject.call(withArguments: ["second"])
            resolve.call(withArguments: ["third"])
        }
        promise.then(callbacks.1, callbacks.2)
        XCTAssertEqual(values(callbacks.0, state: state), ["ok:first"])
    }

    func testPromiseCallbacksDoNotKeepTheirOwnVirtualMachineAndSnapshotAlive() throws {
        for settles in [false, true] {
            weak var virtualMachine: JSVirtualMachine?
            weak var resources: ScriptWidgetExecutionFiles?
            try autoreleasepool {
                let state = try state(), callbacks = try callbacks(state)
                virtualMachine = callbacks.0.virtualMachine
                resources = state.executionSnapshot?.package.executionFiles
                let promise = ScriptWidgetRuntimePromise { resolve, reject in
                    // JS retains the native blocks; their callbacks must not
                    // root the VM in return, even for an unresolved producer.
                    callbacks.0.setObject(resolve, forKeyedSubscript: "pendingResolve" as NSString)
                    callbacks.0.setObject(reject, forKeyedSubscript: "pendingReject" as NSString)
                    if settles { resolve.call(withArguments: ["done"]) }
                }
                promise.then(callbacks.1, callbacks.2)
                state.executionSession.callbackQueue.sync {}
                state.executionSession.finish()
            }
            let deadline = Date().addingTimeInterval(1)
            while (virtualMachine != nil || resources != nil) && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertNil(virtualMachine, "Promise VM retained; settled=\(settles)")
            XCTAssertNil(resources, "Promise snapshot retained; settled=\(settles)")
        }
    }

    func testLateNativePayloadFromReplacedIdentityIsNeverDeliveredToUserCode() throws {
        let state = try state(), callbacks = try callbacks(state)
        var pending: JSValue?
        let promise = ScriptWidgetRuntimePromise { resolve, _ in pending = resolve }
        promise.then(callbacks.1, callbacks.2)
        XCTAssertNotNil(pending)
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertTrue(manager.createScript(content: "$render(<text>new</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        pending?.call(withArguments: ["private late payload"])
        let received = values(callbacks.0, state: state)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received[0].contains("execution_identity_changed"))
        XCTAssertFalse(received[0].contains("private late payload"))
        XCTAssertEqual(state.executionSession.cancellation, .superseded)
    }

    func testFinishedSessionDropsBothLateSuccessAndLateError() throws {
        let state = try state(), callbacks = try callbacks(state)
        var success: JSValue?, failure: JSValue?
        let promise = ScriptWidgetRuntimePromise { resolve, reject in success = resolve; failure = reject }
        promise.then(callbacks.1, callbacks.2)
        state.executionSession.finish()
        success?.call(withArguments: ["late"]); failure?.call(withArguments: ["late error"])
        XCTAssertEqual(values(callbacks.0, state: state), [])
    }

    func testCallbackRechecksIdentityWhenItsQueueWasBlockedDuringReplacement() throws {
        let state = try state(), callbacks = try callbacks(state)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        state.executionSession.callbackQueue.async { entered.signal(); _ = release.wait(timeout: .now() + .seconds(2)) }
        XCTAssertEqual(entered.wait(timeout: .now() + .seconds(1)), .success)
        let promise = ScriptWidgetRuntimePromise { resolve, _ in resolve.call(withArguments: ["must not escape"] ) }
        promise.then(callbacks.1, callbacks.2)
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        release.signal()
        XCTAssertTrue(values(callbacks.0, state: state).first?.contains("execution_identity_changed") == true)
    }

    func testHTTPResponseMetadataKeepsLegacyStringsAndFiltersHeaders() throws {
        NativeIdentityURLProtocol.set(host) { item in
            if item.request.url?.path == "/not-modified" { item.respond("",status:304,headers:["Expires":"Thu, 01 Jan 2026 13:00:00 GMT"]); return }
            item.respond("response text",status:503,headers:["Content-Type":"text/plain","Cache-Control":"max-age=3600","Last-Modified":"Thu, 01 Jan 2026 12:00:00 GMT","Set-Cookie":"private=secret","Authorization":"secret","X-Private":"secret","Retry-After":String(repeating:"x",count:2049)])
        }
        let source = """
        const value = await $http.getResponse('https://\(host!)/data');
        const unchanged = await $http.getResponse('https://\(host!)/not-modified');
        const legacy = await $http.get('https://\(host!)/data');
        $render(<text>{JSON.stringify({value,unchanged,legacy})}</text>);
        """
        let snapshot = try captured(source),runtime = ScriptWidgetRuntime(package:package,environments:[:],executionSnapshot:snapshot)
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[NativeIdentityURLProtocol.self]
        runtime.runningState?.fetchManagerForTesting=ScriptWidgetFetchManager(configuration:configuration)
        let result=runtime.executeJSXSyncForWidget(snapshot.source)
        XCTAssertNil(result.1,result.1?.displayMessage ?? "")
        let text=try XCTUnwrap(result.0).getChildren().compactMap{$0 as? String}.joined()
        let document=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
        let value=try XCTUnwrap(document["value"] as? [String:Any]),headers=try XCTUnwrap(value["headers"] as? [String:String])
        XCTAssertEqual(value["status"] as? Int,503);XCTAssertEqual(value["body"] as? String,"response text")
        XCTAssertEqual(headers,["content-type":"text/plain","cache-control":"max-age=3600","last-modified":"Thu, 01 Jan 2026 12:00:00 GMT"])
        XCTAssertEqual((document["unchanged"] as? [String:Any])?["status"] as? Int,304)
        XCTAssertEqual((document["unchanged"] as? [String:Any])?["body"] as? String,"")
        XCTAssertEqual(document["legacy"] as? String,"response text")
    }

    func testRealFetchBridgeUsesGuardedPromiseAndInjectedTransportWithoutNetworkAccess() throws {
        NativeIdentityURLProtocol.set(host) { $0.respond("isolated response") }
        let source = """
        const response = await $fetch('https://\(host!)/data');
        if (!$storage.setString('response', response)) throw new Error('storage failed');
        $render(<text>{response}</text>);
        """
        let snapshot = try captured(source)
        let runtime = ScriptWidgetRuntime(package: package, environments: [:], executionSnapshot: snapshot)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeIdentityURLProtocol.self]
        runtime.runningState?.fetchManagerForTesting = ScriptWidgetFetchManager(configuration: configuration)
        let result = runtime.executeJSXSyncForWidget(snapshot.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(defaults.string(forKey: snapshot.storageNamespace + "response"), "isolated response")
    }

    func testRedirectPolicyUsesFrozenDomainsPluginHTTPSAndCurrentIdentity() throws {
        let state = try state()
        let allowed = try XCTUnwrap(URL(string: "https://" + host + "/next"))
        XCTAssertTrue(ScriptWidgetNetworkPolicy.allowsRedirect(allowed, state: state))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.allowsRedirect(try XCTUnwrap(URL(string: "https://other.example.com/next")), state: state))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.allowsRedirect(try XCTUnwrap(URL(string: "https://127.0.0.1/next")), state: state))
        XCTAssertTrue(ScriptWidgetNetworkPolicy.allowsRedirect(allowed, state: state, pluginHosts: ["*.example.com"]))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.allowsRedirect(allowed, state: state, pluginHosts: ["other.example.com"]))
        XCTAssertFalse(ScriptWidgetNetworkPolicy.allowsRedirect(try XCTUnwrap(URL(string: "http://" + host + "/next")), state: state, pluginHosts: [host]))
        var current = try XCTUnwrap(package.readManifest()); current.networkDomains = ["other.example.com"]
        XCTAssertTrue(package.writeManifest(current).0)
        XCTAssertTrue(ScriptWidgetNetworkPolicy.allowsRedirect(allowed, state: state))
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        XCTAssertFalse(ScriptWidgetNetworkPolicy.allowsRedirect(allowed, state: state))
    }
}

extension NativeAPIIdentityTests {
    func testRealFetchDropsLateResponseAfterIdentityRetirementAndCancelsItsSession() throws {
        let started = expectation(description: "isolated request started")
        let cancelled = expectation(description: "identity cancellation observed")
        var pending: NativeIdentityURLProtocol?
        NativeIdentityURLProtocol.set(host) { protocolObject in pending = protocolObject; started.fulfill() }
        let state = try state(), callbacks = try callbacks(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeIdentityURLProtocol.self]
        state.fetchManagerForTesting = ScriptWidgetFetchManager(configuration: configuration)
        _ = state.executionSession.registerCancellation {
            XCTAssertEqual(state.executionSession.cancellation, .superseded)
            cancelled.fulfill()
        }
        callbacks.0["nativeFetch"] = unsafeBitCast(custom_fetch, to: JSValue.self)
        callbacks.0.evaluateScript("nativeFetch('https://\(host!)/late').then(success, failure);")
        wait(for: [started], timeout: 2)
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        try XCTUnwrap(pending).respond("private late response")
        wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(values(callbacks.0, state: state), [])
    }

    func testReadOnlyProjectionRejectsHealthBeforeStartingAnySystemQuery() throws {
        #if canImport(HealthKit)
        let source = """
        try { await $health.stepCountToday(); $render(<text>unexpected data</text>); }
        catch (error) { $render(<text>{String(error)}</text>); }
        """
        var manifest = try XCTUnwrap(package.readManifest())
        manifest.permissions.append(.health)
        XCTAssertTrue(package.writeManifest(manifest).0)
        let snapshot = try captured(source)
        let runtime = ScriptWidgetRuntime(package: package, environments: ["timeline-is-projection": "true"], executionSnapshot: snapshot)
        let result = runtime.executeJSXSyncForWidget(snapshot.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(runtime.runningState?.executionSession.totalDataQueries, 0)
        let text = try XCTUnwrap(result.0).getChildren().compactMap { $0 as? String }.joined()
        XCTAssertTrue(text.contains("timeline_read_only"))
        #else
        throw XCTSkip("HealthKit API is unavailable in this host SDK")
        #endif
    }

    func testHealthQueryBudgetRejectsBeforeHealthKitAccess() throws {
        #if canImport(HealthKit)
        let source = """
        try { await $health.heartRateLatest(); $render(<text>unexpected data</text>); }
        catch (error) { $render(<text>{String(error)}</text>); }
        """
        var manifest = try XCTUnwrap(package.readManifest())
        manifest.permissions.append(.health)
        XCTAssertTrue(package.writeManifest(manifest).0)
        let snapshot = try captured(source)
        let runtime = ScriptWidgetRuntime(package: package, environments: [:], executionSnapshot: snapshot)
        let state = try XCTUnwrap(runtime.runningState)
        for _ in 0..<ScriptWidgetExecutionSession.maximumDataQueries { XCTAssertTrue(state.executionSession.registerDataQuery()) }
        let result = runtime.executeJSXSyncForWidget(snapshot.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        let text = try XCTUnwrap(result.0).getChildren().compactMap { $0 as? String }.joined()
        XCTAssertTrue(text.contains("query_limit"))
        #else
        throw XCTSkip("HealthKit API is unavailable in this host SDK")
        #endif
    }
}


extension NativeSnapshotExecutionTests {
    private func recordSnapshot() throws -> ScriptWidgetExecutionSnapshot {
        XCTAssertTrue(package.writeFile(relativePath: "record-template.json", content: #"{"formatVersion":1,"kind":"hydration"}"#).0)
        return try capture()
    }

    func testNativeRecordConfigurationAndRuntimeShareUUIDWithoutLegacyWrites() throws {
        let snapshot = try recordSnapshot()
        let store = try ScriptWidgetRecordStore(executionSnapshot: snapshot)
        let empty = try store.read()
        let next = try store.settingConfiguration(["goal": 12, "glassML": 300], in: empty)
        try store.apply(next, expected: empty)
        XCTAssertEqual(try render("$render(<text>{String(JSON.parse($storage.getString('recordTemplate.config.v1')).values.goal)}</text>);"), "12")
        XCTAssertNil(defaults.object(forKey: "script." + packageName + ".recordTemplate.config.v1"))
        XCTAssertEqual(try ScriptWidgetRecordStore(executionSnapshot: capture()).read(), next)
    }

    func testNativeRecordRestoreDetectsRealRuntimeConcurrentWrite() throws {
        let snapshot = try recordSnapshot()
        let store = try ScriptWidgetRecordStore(executionSnapshot: snapshot)
        let before = try store.read()
        let next = try store.settingConfiguration(["goal": 12, "glassML": 300], in: before)
        XCTAssertEqual(try render("$storage.setString('recordTemplate.config.v1', JSON.stringify({version:1,kind:'hydration',values:{goal:9,glassML:250}})); $render(<text>saved</text>);"), "saved")
        XCTAssertThrowsError(try store.apply(next, expected: before)) {
            XCTAssertEqual($0 as? ScriptWidgetRecordError, .conflict)
        }
        XCTAssertEqual(try store.configuration(in: store.read())["goal"] as? Int, 9)
    }

    func testNativeRecordStoreRefusesRetiredIdentityAndDoesNotAdoptReinstallation() throws {
        let snapshot = try recordSnapshot()
        let store = try ScriptWidgetRecordStore(executionSnapshot: snapshot)
        let before = try store.read()
        let saved = try store.settingConfiguration(["goal": 12, "glassML": 300], in: before)
        try store.apply(saved, expected: before)
        let backup = try store.backup(saved)
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.apply(before, expected: saved))
        XCTAssertThrowsError(try ScriptWidgetRecordStore(executionSnapshot: snapshot))
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertTrue(manager.createScript(content: "$render(<text>new</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        XCTAssertNil(package.readManifest(), "Old editor descriptors cannot adopt a replacement installation")
        package = manager.getScriptPackage(packageName: packageName)
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        let fresh = try recordSnapshot()
        XCTAssertNotEqual(fresh.storageNamespace, snapshot.storageNamespace)
        let replacement = try ScriptWidgetRecordStore(executionSnapshot: fresh)
        XCTAssertEqual(try replacement.read(), .init(values: [:]))
        XCTAssertEqual(defaults.string(forKey: snapshot.storageNamespace + ScriptWidgetRecordStore.configurationKey), saved.values[ScriptWidgetRecordStore.configurationKey])
        // Explicit restore may transfer records, but cannot transfer installation authority.
        let preview = try replacement.previewRestore(backup)
        try replacement.apply(preview.snapshot, expected: replacement.read())
        XCTAssertEqual(try replacement.read(), saved)
        XCTAssertThrowsError(try store.read())
    }

    func testNativeRecordDescriptorAndPermissionAreFrozenWithSnapshot() throws {
        let snapshot = try recordSnapshot()
        XCTAssertTrue(package.writeFile(relativePath: "record-template.json", content: #"{"formatVersion":1,"kind":"mood"}"#).0)
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        let store = try ScriptWidgetRecordStore(executionSnapshot: snapshot)
        XCTAssertEqual(store.kind, .hydration)
        let before = try store.read()
        try store.apply(store.settingConfiguration(["goal": 10, "glassML": 250], in: before), expected: before)
        XCTAssertThrowsError(try ScriptWidgetRecordStore(executionSnapshot: capture()))
    }

    func testNativeRecordBulkWriteHonorsWholeNamespaceBudgetBeforeAnyMutation() throws {
        let snapshot = try recordSnapshot()
        let store = try ScriptWidgetRecordStore(executionSnapshot: snapshot)
        let before = try store.read()
        let next = try store.settingConfiguration(["goal": 12, "glassML": 300], in: before)
        for index in 0..<ScriptWidgetStorageNamespaces.maximumNamespaceKeys {
            defaults.set("x", forKey: snapshot.storageNamespace + "other-" + String(index))
        }
        XCTAssertThrowsError(try store.apply(next, expected: before))
        XCTAssertEqual(try store.read(), before)
        defaults.removeObject(forKey: snapshot.storageNamespace + "other-0")
        try store.apply(next, expected: before)
        XCTAssertEqual(try store.read(), next)
    }
}

extension NativeSnapshotExecutionTests {
    private func actionFixture() throws -> (ScriptWidgetActionCatalog, ResolvedScriptWidgetAction) {
        var manifest = try XCTUnwrap(package.readManifest())
        manifest.actions = [.init(id: "update", title: "Update", systemImage: "checkmark", function: "update")]
        manifest.controls = [.init(id: "focus", type: .toggle, title: "Focus", systemImage: "switch.2", actionID: "update", stateKey: "focus.enabled")]
        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertTrue(package.writeMainFile(content: """
            function update() {
              $storage.setString('action-result', $storage.getString('focus.enabled') + ':' + $getenv('action-source') + ':' + $getenv('widget-param'));
            }
            $render(<text>ready</text>);
            """).0)
        let catalog = ScriptWidgetActionCatalog(packages: [package], storageContext: context)
        return (catalog, try XCTUnwrap(catalog.actions().first).preparedForExecution())
    }

    func testBoundDeclaredActionRunsFrozenSourceAndUUIDBackend() throws {
        let (catalog, resolved) = try actionFixture()
        let snapshot = try XCTUnwrap(resolved.executionSnapshot)
        XCTAssertTrue(package.writeMainFile(content: "function update(){ throw new Error('new source'); }").0)
        var reloads = 0
        let executor = ScriptWidgetActionExecutor(catalog: catalog, reloadWidgets: { reloads += 1 })
        try executor.execute(resolved: resolved, source: .shortcut).get()
        XCTAssertEqual(defaults.string(forKey: snapshot.storageNamespace + "action-result"), ":shortcut:")
        XCTAssertNil(defaults.object(forKey: "script." + packageName + ".action-result"))
        XCTAssertEqual(reloads, 1)
    }

    func testBoundControlStateAndActionShareStorageAndReader() throws {
        let (catalog, _) = try actionFixture()
        let pair = try XCTUnwrap(catalog.controls(type: .toggle).first)
        let resolved = try pair.0.preparedForExecution()
        let identifier = ScriptWidgetActionCatalog.controlIdentifier(resolved, pair.1)
        XCTAssertNotNil(catalog.resolveControl(identifier: identifier, type: .toggle))
        XCTAssertNil(catalog.resolveControl(identifier: resolved.manifest.id + "::focus", type: .toggle))
        let executor = ScriptWidgetActionExecutor(catalog: catalog, reloadWidgets: {})
        try executor.setToggleValue(true, resolved: resolved, stateKey: "focus.enabled", source: .control).get()
        XCTAssertEqual(defaults.string(forKey: try XCTUnwrap(resolved.executionSnapshot).storageNamespace + "action-result"), "true:control:")
        XCTAssertTrue(try ScriptWidgetActionExecutor.toggleValue(resolved: resolved, stateKey: "focus.enabled"))
        XCTAssertNil(defaults.object(forKey: "script." + packageName + ".focus.enabled"))
    }

    func testRetiredBoundActionsCannotReadWriteExecuteOrReload() throws {
        let (catalog, resolved) = try actionFixture()
        var ran = false, reloaded = false
        let executor = ScriptWidgetActionExecutor(catalog: catalog, runAction: { _, _ in ran = true; return nil }, reloadWidgets: { reloaded = true })
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        XCTAssertThrowsError(try executor.execute(resolved: resolved, source: .widget).get())
        XCTAssertThrowsError(try executor.setToggleValue(true, resolved: resolved, stateKey: "focus.enabled", source: .control).get())
        XCTAssertThrowsError(try ScriptWidgetActionExecutor.toggleValue(resolved: resolved, stateKey: "focus.enabled"))
        XCTAssertNil(catalog.resolve(identifier: resolved.identifier))
        XCTAssertFalse(ran); XCTAssertFalse(reloaded)
    }

    func testBoundActionRejectsForgedFunctionAndChecksControlBudgetBeforeWrites() throws {
        let (catalog, resolved) = try actionFixture()
        let snapshot = try XCTUnwrap(resolved.executionSnapshot)
        let executor = ScriptWidgetActionExecutor(catalog: catalog, reloadWidgets: {})
        var forged = resolved.action; forged.function = "notDeclared"
        let invalid = ResolvedScriptWidgetAction(package: resolved.package, manifest: resolved.manifest, action: forged, executionSnapshot: snapshot)
        XCTAssertThrowsError(try executor.execute(resolved: invalid, source: .shortcut).get())
        for index in 0..<ScriptWidgetStorageNamespaces.maximumNamespaceKeys {
            defaults.set("x", forKey: snapshot.storageNamespace + "other-" + String(index))
        }
        XCTAssertThrowsError(try executor.setToggleValue(true, resolved: resolved, stateKey: "focus.enabled", source: .control).get())
        XCTAssertNil(defaults.object(forKey: snapshot.storageNamespace + "focus.enabled"))
        XCTAssertNil(defaults.object(forKey: snapshot.storageNamespace + "action-result"))
    }

    func testDuplicatePublicPackageIDsHaveDistinctNativeActionIdentifiers() throws {
        let (_, first) = try actionFixture()
        let otherName = "Other-" + UUID().uuidString
        defer {
            if let build = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: build, relative: otherName) }
        }
        XCTAssertTrue(manager.createScript(content: "function update(){}", recommendPackageName: otherName, imageCopyPath: nil).0)
        let other = manager.getScriptPackage(packageName: otherName)
        var manifest = first.manifest; manifest.name = otherName
        XCTAssertTrue(other.writeManifest(manifest).0)
        let catalog = ScriptWidgetActionCatalog(packages: [package, other], storageContext: context)
        XCTAssertEqual(Set(catalog.actions().map { ScriptWidgetActionEntity(resolved:$0).subtitle }),Set([package.name,other.name]))
        XCTAssertTrue(catalog.controls(type:.toggle).allSatisfy { $0.0.controlSubtitle($0.1).hasPrefix($0.0.installationName) })
        let actions = catalog.actions()
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(Set(actions.map(\.identifier)).count, 2)
        for action in actions { XCTAssertNotNil(catalog.resolve(identifier: action.identifier)) }
        XCTAssertNil(catalog.resolve(identifier: first.manifest.id + "::update"))
        // Old name/public-ID mode must not select the first of ambiguous matches.
        let legacy = ScriptWidgetActionCatalog(packages: [package, other])
        XCTAssertNil(legacy.resolve(identifier: first.manifest.id + "::update"))
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testSerializedDirectFunctionIntentReconstructsScopeAndWidgetParameter() throws {
        let (_, resolved) = try actionFixture()
        let snapshot = try XCTUnwrap(resolved.executionSnapshot)
        let intent = ButtonActionAppIntent(functionName: "update", package: snapshot.package, scriptParameter: "read", executionSnapshot: snapshot)
        let packet = try JSONEncoder().encode(intent.request)
        let received = try JSONDecoder().decode(ScriptWidgetDirectActionRequest.self, from: packet)
        let host = ScriptWidgetDirectActionExecutor(manager: manager, reloadWidgets: {})
        try host.execute(received)
        XCTAssertEqual(defaults.string(forKey: snapshot.storageNamespace + "action-result"), ":widget:read")
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        XCTAssertThrowsError(try host.execute(received))
    }
}


extension NativeSnapshotExecutionTests {
    func testSavedActionIdentifierDoesNotFollowSameNameReinstallation() throws {
        let (_, old) = try actionFixture()
        let oldID = old.identifier
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName))
        XCTAssertTrue(manager.createScript(content: "function update(){}", recommendPackageName: packageName, imageCopyPath: nil).0)
        XCTAssertNil(package.readManifest(), "Old editor descriptors cannot adopt a replacement installation")
        package = manager.getScriptPackage(packageName: packageName)
        XCTAssertTrue(package.writeManifest(old.manifest).0)
        let (newCatalog, newAction) = try actionFixture()
        XCTAssertNotEqual(oldID, newAction.identifier)
        XCTAssertNil(newCatalog.resolve(identifier: oldID))
        XCTAssertNotNil(newCatalog.resolve(identifier: newAction.identifier))
        XCTAssertThrowsError(try ScriptWidgetActionExecutor(catalog: newCatalog, reloadWidgets: {}).execute(resolved: old, source: .shortcut).get())
    }

    func testRendererActionCatalogRetainsIdentityAfterRuntimeReferenceExpires() throws {
        let (_, action) = try actionFixture()
        let snapshot = try XCTUnwrap(action.executionSnapshot)
        let renderer = ScriptWidgetElementContext(runtime: runtime(snapshot), debugMode: false, scriptName: packageName,
            scriptParameter: "", package: package)
        renderer.runtime = nil
        XCTAssertTrue(renderer.executionSnapshot === snapshot)
        XCTAssertEqual(renderer.actionCatalog.resolve(package: renderer.package, actionID: "update")?.identifier, action.identifier)
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: defaults)
        XCTAssertNil(renderer.actionCatalog.resolve(package: renderer.package, actionID: "update"))
    }
}

extension NativeSnapshotExecutionTests {
    func testCatalogListsMoreThanSnapshotLeaseLimitWithoutCapturingResourceCopies() throws {
        let (_, first) = try actionFixture()
        var packages = [package!]
        for index in 0..<35 {
            let name = "Catalog-" + String(index) + "-" + UUID().uuidString
            let staging = root.appendingPathComponent("staging-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var manifest = first.manifest; manifest.name = name
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("widget.json"))
            try Data("function update(){}".utf8).write(to: staging.appendingPathComponent("main.jsx"))
            _ = try context.publish(staging, name: name)
            packages.append(manager.getScriptPackage(packageName: name))
        }
        let catalog = ScriptWidgetActionCatalog(packages: packages, storageContext: context)
        let actions = catalog.actions()
        XCTAssertEqual(actions.count, 36)
        XCTAssertEqual(Set(actions.map(\.identifier)).count, 36)
        XCTAssertTrue(actions.allSatisfy { $0.executionSnapshot == nil && $0.nativeBinding != nil })
        let selected = try XCTUnwrap(actions.last).preparedForExecution()
        XCTAssertNotNil(selected.executionSnapshot)
        XCTAssertEqual(selected.ownerID, actions.last?.ownerID)
    }
}

extension NativeSnapshotExecutionTests {
    private func relocationState(_ name: String, _ receipt: ScriptWidgetStoragePublicationReceipt) throws -> ScriptWidgetStoragePublicationState {
        guard let actual = try ScriptWidgetPackageFiles.directoryReceipt(root: library, relative: name) else { return .absent }
        return actual == receipt ? .matching : .different
    }

    private func interruptRelocation(destination: String, deleting: Bool = false, moveDirectory: Bool) throws -> ScriptWidgetStorageDirectoryBinding {
        let binding = try context.boundDirectory(name: packageName, role: .source)
        var interrupted = false
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.relocate(source: binding, destination: destination, deleting: deleting,
            container: container, defaults: defaults, inspect: { name, receipt in
                if interrupted { throw ScriptWidgetStorageNamespaceError.unavailable }
                return try self.relocationState(name, receipt)
            }, move: {
                if moveDirectory {
                    XCTAssertTrue(ScriptWidgetPackageFiles.move(root: self.library, source: self.packageName, destination: destination, expectedReceipt: binding.receipt))
                }
                interrupted = true
            }))
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
        return binding
    }

    func testManagerRenamePreservesUUIDRecordsAndInvalidatesOldExecutionBinding() throws {
        let snapshot = try capture()
        XCTAssertEqual(try render("$storage.setString('kept','record'); $render(<text>saved</text>);"), "saved")
        let name = "Renamed-" + UUID().uuidString
        let result = manager.renameScript(srcPackageName: packageName, destPackageName: name)
        XCTAssertTrue(result.0, result.1)
        let next = try ScriptWidgetExecutionSnapshot(name: name, role: .source, context: context)
        XCTAssertEqual(next.storageNamespace, snapshot.storageNamespace)
        XCTAssertEqual(defaults.string(forKey: next.storageNamespace + "kept"), "record")
        XCTAssertThrowsError(try snapshot.validateIdentity())
        XCTAssertThrowsError(try context.boundDirectory(name: packageName, role: .source))
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
    }

    func testManagerDeleteRetiresIdentityPreservesRecordsAndAllowsFreshSameName() throws {
        let old = try capture()
        defaults.set("kept", forKey: old.storageNamespace + "record")
        XCTAssertTrue(manager.deleteScript(packageName: packageName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path.path))
        XCTAssertThrowsError(try old.validateIdentity())
        XCTAssertEqual(defaults.string(forKey: old.storageNamespace + "record"), "kept")
        XCTAssertFalse(try XCTUnwrap(ScriptWidgetPackageFiles.list(root: library)).contains { $0.hasPrefix(ScriptWidgetStorageNamespaces.retiredDirectoryPrefix) })
        XCTAssertTrue(manager.createScript(content: "$render(<text>new</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        let fresh = try capture()
        XCTAssertNotEqual(fresh.storageNamespace, old.storageNamespace)
        XCTAssertNil(defaults.object(forKey: fresh.storageNamespace + "record"))
    }

    func testRelocationBeforeMoveRecoversRollbackAndExcludesOtherIdentityMutations() throws {
        let target = "Rename-" + UUID().uuidString
        let binding = try interruptRelocation(destination: target, moveDirectory: false)
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults))
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.registerFresh(name: "Other", container: container, defaults: defaults))
        XCTAssertEqual(try context.recoverRelocation(), .rolledBack)
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), binding)
        XCTAssertEqual(try context.recoverRelocation(), .none)
    }

    func testRelocationAfterMoveRecoveryCommitsExactOriginalOwner() throws {
        let target = "Rename-" + UUID().uuidString
        let original = try interruptRelocation(destination: target, moveDirectory: true)
        XCTAssertEqual(try context.recoverRelocation(), .committed(source: packageName, destination: target, deleting: false))
        let renamed = try context.boundDirectory(name: target, role: .source)
        XCTAssertEqual(renamed.ownerID, original.ownerID)
        XCTAssertEqual(renamed.receipt, original.receipt)
        XCTAssertThrowsError(try context.boundDirectory(name: packageName, role: .source))
    }

    func testInterruptedDeleteRecoveryRetiresAndCleansOnlyMatchingTombstone() throws {
        let binding = try context.boundDirectory(name: packageName, role: .source)
        let target = ScriptWidgetStorageNamespaces.retiredDirectoryPrefix + binding.ownerID
        _ = try interruptRelocation(destination: target, deleting: true, moveDirectory: true)
        XCTAssertEqual(try context.recoverRelocation(), .committed(source: packageName, destination: target, deleting: true))
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults))
        XCTAssertNil(try ScriptWidgetPackageFiles.directoryReceipt(root: library, relative: target))
        XCTAssertTrue(manager.listScripts().isEmpty)
    }

    func testRelocationRecoveryRejectsForeignRootAndDifferentDestination() throws {
        let target = "Rename-" + UUID().uuidString
        let binding = try interruptRelocation(destination: target, moveDirectory: true)
        let otherRoot = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = try ScriptWidgetPackageStorageContext(libraryRoot: otherRoot, container: container, defaults: defaults)
        XCTAssertThrowsError(try other.recoverRelocation())
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: library, source: target, destination: "moved-original", expectedReceipt: binding.receipt))
        try FileManager.default.createDirectory(at: library.appendingPathComponent(target), withIntermediateDirectories: true)
        XCTAssertThrowsError(try context.recoverRelocation())
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.registerFresh(name: "NoGrant", container: container, defaults: defaults))
    }

    func testRelocationConflictDoesNotOverwriteDestinationOrChangeOwner() throws {
        let before = try context.boundDirectory(name: packageName, role: .source)
        let target = "Occupied-" + UUID().uuidString
        try FileManager.default.createDirectory(at: library.appendingPathComponent(target), withIntermediateDirectories: true)
        let marker = library.appendingPathComponent(target).appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        XCTAssertFalse(manager.renameScript(srcPackageName: packageName, destPackageName: target).0)
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), before)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
    }

    func testMalformedRelocationMetadataFailsClosedWithoutChangingRecords() throws {
        let binding = try context.boundDirectory(name: packageName, role: .source)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding))
        let base: [String: Any] = ["formatVersion": 1, "binding": encoded, "destination": "Rename", "deleting": false]
        var variants: [[String: Any]] = []
        var invalid = base; invalid["extra"] = true; variants.append(invalid)
        invalid = base; invalid["deleting"] = 0; variants.append(invalid)
        invalid = base; invalid["destination"] = "../outside"; variants.append(invalid)
        invalid = base; invalid["deleting"] = true; variants.append(invalid)
        defaults.set("keep", forKey: "script.original.value")
        for value in variants {
            defaults.set(try JSONSerialization.data(withJSONObject: value), forKey: ScriptWidgetStorageNamespaces.relocationKey)
            XCTAssertThrowsError(try context.recoverRelocation())
            XCTAssertThrowsError(try context.boundDirectory(name: packageName, role: .source))
            XCTAssertEqual(defaults.string(forKey: "script.original.value"), "keep")
            defaults.removeObject(forKey: ScriptWidgetStorageNamespaces.relocationKey)
        }
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), binding)
    }

    func testReceiptScopedCleanupRefusesChangedDirectory() throws {
        let binding = try context.boundDirectory(name: packageName, role: .source)
        let wrong = ScriptWidgetStoragePublicationReceipt(device: binding.receipt.device, inode: binding.receipt.inode + 1)
        XCTAssertFalse(ScriptWidgetPackageFiles.removeTree(root: library, relative: packageName, expectedReceipt: wrong))
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), binding)
        XCTAssertFalse(ScriptWidgetPackageFiles.move(root: library, source: packageName, destination: "Wrong", expectedReceipt: wrong))
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), binding)
    }
}

extension NativeSnapshotExecutionTests {
    func testRenameRecoveryFinishesWhenOwnerCommitPrecedesJournalCleanup() throws {
        let target = "Rename-" + UUID().uuidString
        let binding = try interruptRelocation(destination: target, moveDirectory: true)
        let registryData = try XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey))
        var index = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: registryData)
        let position = try XCTUnwrap(index.owners.firstIndex { $0.id == binding.ownerID })
        index.owners[position].name = target
        defaults.set(try JSONEncoder().encode(index), forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertEqual(try context.recoverRelocation(), .committed(source: packageName, destination: target, deleting: false))
        XCTAssertEqual(try context.boundDirectory(name: target, role: .source).ownerID, binding.ownerID)
        XCTAssertEqual(try context.recoverRelocation(), .none)
    }

    func testCommittedRenameDoesNotRollbackIdentityIfDirectoryIsMovedBackExternally() throws {
        let target = "Rename-" + UUID().uuidString
        let binding = try interruptRelocation(destination: target, moveDirectory: true)
        var index = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)))
        let position = try XCTUnwrap(index.owners.firstIndex { $0.id == binding.ownerID })
        index.owners[position].name = target
        defaults.set(try JSONEncoder().encode(index), forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: library, source: target, destination: packageName, expectedReceipt: binding.receipt))
        XCTAssertThrowsError(try context.recoverRelocation())
        let current = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)))
        XCTAssertEqual(current.owners[position].name, target)
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
    }

    func testRenamedSourceKeepsUUIDButOldNamedCacheCannotBeAdopted() throws {
        let binding = try context.boundDirectory(name: packageName, role: .source)
        let staging = root.appendingPathComponent("cache-stage")
        try FileManager.default.copyItem(at: package.path, to: staging)
        _ = try context.publishCache(staging, source: binding, cacheRoot: cache)
        let cacheContext = try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults)
        XCTAssertEqual(try cacheContext.boundDirectory(name: packageName, role: .cache).ownerID, binding.ownerID)
        let target = "Rename-" + UUID().uuidString
        XCTAssertTrue(manager.renameScript(srcPackageName: packageName, destPackageName: target).0)
        XCTAssertEqual(try context.boundDirectory(name: target, role: .source).ownerID, binding.ownerID)
        XCTAssertThrowsError(try cacheContext.boundDirectory(name: packageName, role: .cache))
        XCTAssertThrowsError(try cacheContext.boundDirectory(name: target, role: .cache))
    }

    func testRetiredCleanupPreservesSubstitutedHiddenDirectory() throws {
        let binding = try context.boundDirectory(name: packageName, role: .source)
        let target = ScriptWidgetStorageNamespaces.retiredDirectoryPrefix + binding.ownerID
        _ = try ScriptWidgetStorageNamespaces.relocate(source: binding, destination: target, deleting: true,
            container: container, defaults: defaults, inspect: relocationState, move: {
                XCTAssertTrue(ScriptWidgetPackageFiles.move(root: self.library, source: self.packageName, destination: target, expectedReceipt: binding.receipt))
            })
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: library, source: target, destination: ".preserved-original", expectedReceipt: binding.receipt))
        try FileManager.default.createDirectory(at: library.appendingPathComponent(target), withIntermediateDirectories: true)
        let marker = library.appendingPathComponent(target).appendingPathComponent("marker")
        try Data("do not remove".utf8).write(to: marker)
        try context.cleanupRetiredDirectories()
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "do not remove")
        XCTAssertNotNil(try ScriptWidgetPackageFiles.directoryReceipt(root: library, relative: ".preserved-original"))
    }
}

extension NativeSnapshotExecutionTests {
    func testRenameRecoveryRefusesUnexpectedRetiredOwner() throws {
        let target = "Rename-" + UUID().uuidString
        let binding = try interruptRelocation(destination: target, moveDirectory: true)
        var index = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)))
        let position = try XCTUnwrap(index.owners.firstIndex { $0.id == binding.ownerID })
        index.owners[position].active = false
        defaults.set(try JSONEncoder().encode(index), forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertThrowsError(try context.recoverRelocation())
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
        let current = try JSONDecoder().decode(ScriptWidgetStorageNamespaceIndex.self, from: XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)))
        XCTAssertFalse(current.owners[position].active)
        XCTAssertEqual(current.owners[position].name, packageName)
    }
}

extension NativeSnapshotExecutionTests {
    func testManagerRetryRecognizesRecoveredRenameAndDeleteAsCompleted() throws {
        let target = "Retry-" + UUID().uuidString
        let binding = try interruptRelocation(destination: target, moveDirectory: true)
        let renamed = manager.renameScript(srcPackageName: packageName, destPackageName: target)
        XCTAssertTrue(renamed.0, renamed.1)
        XCTAssertEqual(try context.boundDirectory(name: target, role: .source).ownerID, binding.ownerID)
        packageName = target
        package = manager.getScriptPackage(packageName: target)
        let tombstone = ScriptWidgetStorageNamespaces.retiredDirectoryPrefix + binding.ownerID
        _ = try interruptRelocation(destination: tombstone, deleting: true, moveDirectory: true)
        XCTAssertTrue(manager.deleteScript(packageName: target))
        XCTAssertTrue(manager.listScripts().isEmpty)
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.relocationKey))
    }
}

extension NativeSnapshotExecutionTests {
    private var galleryTestID: String { "dev.scriptwidget.native-gallery" }
    private func galleryDownload(version: String = "1.0.0") throws -> URL {
        let path = root.appendingPathComponent("download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        var manifest = WidgetPackageManifest.newProject(name: "Gallery Native")
        manifest.id = galleryTestID; manifest.version = version; manifest.permissions = [.storage]
        try JSONEncoder().encode(manifest).write(to: path.appendingPathComponent("widget.json"))
        try Data("$render(<text>\(version)</text>);".utf8).write(to: path.appendingPathComponent("main.jsx"))
        return path
    }
    private func installNativeGallery() throws -> ScriptWidgetStorageDirectoryBinding {
        let download = try galleryDownload()
        let name = "Gallery-" + UUID().uuidString
        XCTAssertEqual(try context.installGallerySource(download, itemID: galleryTestID, version: "1.0.0", freshName: name), name)
        packageName = name; package = manager.getScriptPackage(packageName: name)
        return try XCTUnwrap(context.gallerySource(itemID: galleryTestID))
    }
    private func interruptedGalleryReplacement(swap: Bool) throws -> ScriptWidgetStorageDirectoryBinding {
        let original = try installNativeGallery()
        let stagingName = ScriptWidgetStorageNamespaces.replacementPrefix + UUID().uuidString.lowercased()
        let staging = library.appendingPathComponent(stagingName)
        try FileManager.default.copyItem(at: galleryDownload(version: "2.0.0"), to: staging)
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: library, relative: stagingName))
        var interrupted = false
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.replaceGallerySource(source: original, staging: stagingName, receipt: receipt,
            galleryID: galleryTestID, container: container, defaults: defaults, inspect: { name in
                if interrupted { throw ScriptWidgetStorageNamespaceError.unavailable }
                return try ScriptWidgetPackageFiles.directoryReceipt(root: self.library, relative: name)
            }, swap: {
                if swap { XCTAssertTrue(ScriptWidgetPackageFiles.replaceCacheDirectory(staging, root: self.library, name: original.name, expectedReceipt: receipt)) }
                interrupted = true
            }))
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.replacementKey))
        return original
    }

    func testNativeGalleryUpdateKeepsUUIDRecordsAndInvalidatesOldSnapshotsAndCache() throws {
        let original = try installNativeGallery()
        let snapshot = try capture()
        defaults.set("kept", forKey: snapshot.storageNamespace + "record")
        let stagedCache = root.appendingPathComponent("cache-staging")
        try FileManager.default.copyItem(at: package.path, to: stagedCache)
        _ = try context.publishCache(stagedCache, source: original, cacheRoot: cache)
        let cacheContext = try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults)
        XCTAssertNotNil(try cacheContext.boundDirectory(name: packageName, role: .cache))
        let name = try context.installGallerySource(galleryDownload(version: "2.0.0"), itemID: galleryTestID, version: "2.0.0", freshName: "Ignored")
        XCTAssertEqual(name, packageName)
        let updated = try XCTUnwrap(context.gallerySource(itemID: galleryTestID))
        XCTAssertEqual(updated.ownerID, original.ownerID); XCTAssertNotEqual(updated.receipt, original.receipt)
        XCTAssertThrowsError(try snapshot.validateIdentity())
        XCTAssertThrowsError(try cacheContext.boundDirectory(name: packageName, role: .cache))
        XCTAssertEqual(defaults.string(forKey: snapshot.storageNamespace + "record"), "kept")
        XCTAssertNil(package.readManifest(), "Updated directories require a fresh native descriptor")
        XCTAssertEqual(manager.getScriptPackage(packageName: packageName).readManifest()?.version, "2.0.0")
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.pendingCleanup(location: context.locationIdentifier, container: container, defaults: defaults).isEmpty)
    }

    func testImportedManifestIDCannotAcquireGalleryProvenanceOrUpdateExistingRecords() throws {
        var manifest = try XCTUnwrap(package.readManifest()); manifest.id = galleryTestID
        XCTAssertTrue(package.writeManifest(manifest).0)
        let original = try capture()
        defaults.set("private", forKey: original.storageNamespace + "secret")
        XCTAssertNil(try context.gallerySource(itemID: galleryTestID))
        let originalName = packageName!
        let gallery = try installNativeGallery()
        XCTAssertNotEqual(original.binding.ownerID, gallery.ownerID)
        XCTAssertNotEqual(originalName, gallery.name)
        XCTAssertEqual(defaults.string(forKey: original.storageNamespace + "secret"), "private")
        XCTAssertNil(defaults.object(forKey: "ScriptWidgetStorage.v2:" + gallery.ownerID + ":secret"))
    }

    func testNativeGalleryLookupFollowsRenameButNotSameNameReinstallation() throws {
        let old = try installNativeGallery()
        let target = "Gallery-Renamed-" + UUID().uuidString
        XCTAssertTrue(manager.renameScript(srcPackageName: packageName, destPackageName: target).0)
        XCTAssertEqual(try context.gallerySource(itemID: galleryTestID)?.name, target)
        XCTAssertTrue(manager.deleteScript(packageName: target))
        XCTAssertNil(try context.gallerySource(itemID: galleryTestID))
        XCTAssertTrue(manager.createScript(content: "$render(<text>other</text>);", recommendPackageName: target, imageCopyPath: nil).0)
        let fresh = try installNativeGallery()
        XCTAssertNotEqual(fresh.ownerID, old.ownerID)
        XCTAssertTrue(manager.isExist(packageName: target))
    }

    func testReplacementBeforeSwapRollsBackAndCleansNewStagingOnly() throws {
        let original = try interruptedGalleryReplacement(swap: false)
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.registerFresh(name: "Blocked", container: container, defaults: defaults))
        XCTAssertEqual(try context.recoverReplacement(), .rolledBack)
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), original)
        XCTAssertEqual(package.readManifest()?.version, "1.0.0")
        XCTAssertTrue(try ScriptWidgetStorageNamespaces.pendingCleanup(location: context.locationIdentifier, container: container, defaults: defaults).isEmpty)
    }

    func testReplacementAfterSwapRecoveryKeepsOriginalOwnerAndCommitsNewReceipt() throws {
        let original = try interruptedGalleryReplacement(swap: true)
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: defaults))
        XCTAssertEqual(try context.recoverReplacement(), .committed)
        let updated = try context.boundDirectory(name: packageName, role: .source)
        XCTAssertEqual(updated.ownerID, original.ownerID); XCTAssertNotEqual(updated.receipt, original.receipt)
        XCTAssertNil(package.readManifest(), "Updated directories require a fresh native descriptor")
        XCTAssertEqual(manager.getScriptPackage(packageName: packageName).readManifest()?.version, "2.0.0")
        XCTAssertEqual(try context.recoverReplacement(), .none)
    }

    func testReplacementRecoveryRejectsWrongRootAndUnknownDirectory() throws {
        _ = try interruptedGalleryReplacement(swap: true)
        let foreign = try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults)
        XCTAssertThrowsError(try foreign.recoverReplacement())
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: library, relative: packageName))
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: library, source: packageName, destination: ".preserved-update", expectedReceipt: receipt))
        try FileManager.default.createDirectory(at: package.path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try context.recoverReplacement())
        XCTAssertNotNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.replacementKey))
    }

    func testGalleryUpdateRejectsInvalidCopyBeforeChangingExistingSource() throws {
        let original = try installNativeGallery()
        let invalid = try galleryDownload(version: "2.0.0")
        try FileManager.default.createSymbolicLink(at: invalid.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertThrowsError(try context.installGallerySource(invalid, itemID: galleryTestID, version: "2.0.0", freshName: "Ignored"))
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source), original)
        XCTAssertEqual(package.readManifest()?.version, "1.0.0")
    }
}

extension NativeSnapshotExecutionTests {
    func testReplacementRecoveryCompletesAfterBindingCommitBeforeJournalCleanup() throws {
        let original = try interruptedGalleryReplacement(swap: true)
        let receipt = try XCTUnwrap(ScriptWidgetPackageFiles.directoryReceipt(root: library, relative: packageName))
        let data = try XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.directoriesKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let position = try XCTUnwrap(entries.firstIndex { $0["ownerID"] as? String == original.ownerID && $0["role"] as? String == "source" })
        entries[position]["receipt"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
        object["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ScriptWidgetStorageNamespaces.directoriesKey)
        XCTAssertEqual(try context.recoverReplacement(), .committed)
        XCTAssertEqual(try context.boundDirectory(name: packageName, role: .source).receipt, receipt)
        XCTAssertNil(defaults.object(forKey: ScriptWidgetStorageNamespaces.replacementKey))
    }

    func testMalformedReplacementAndCleanupMetadataCannotAuthorizeDeletion() throws {
        _ = try interruptedGalleryReplacement(swap: false)
        let originalData = try XCTUnwrap(defaults.data(forKey: ScriptWidgetStorageNamespaces.replacementKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        object["staging"] = "../outside"
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ScriptWidgetStorageNamespaces.replacementKey)
        XCTAssertThrowsError(try context.recoverReplacement())
        defaults.set(originalData, forKey: ScriptWidgetStorageNamespaces.replacementKey)
        XCTAssertEqual(try context.recoverReplacement(), .rolledBack)
        defaults.set(try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "entries": [["name": packageName!, "location": context.locationIdentifier,
            "receipt": ["device": 0, "inode": 1]]]]), forKey: ScriptWidgetStorageNamespaces.cleanupKey)
        XCTAssertThrowsError(try context.cleanupReplacementDirectories())
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path.path))
    }

    func testCleanupQueuePreservesReplacedStagingAndAcknowledgesOnlyExpectedReceipt() throws {
        _ = try interruptedGalleryReplacement(swap: true)
        XCTAssertEqual(try ScriptWidgetStorageNamespaces.recoverReplacement(location: context.locationIdentifier, container: container, defaults: defaults,
            inspect: { try ScriptWidgetPackageFiles.directoryReceipt(root: self.library, relative: $0) }), .committed)
        let entry = try XCTUnwrap(ScriptWidgetStorageNamespaces.pendingCleanup(location: context.locationIdentifier, container: container, defaults: defaults).first)
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: library, source: entry.name, destination: ".preserved-old-gallery", expectedReceipt: entry.receipt))
        try FileManager.default.createDirectory(at: library.appendingPathComponent(entry.name), withIntermediateDirectories: true)
        let marker = library.appendingPathComponent(entry.name).appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        try context.cleanupReplacementDirectories()
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertEqual(try ScriptWidgetStorageNamespaces.pendingCleanup(location: context.locationIdentifier, container: container, defaults: defaults), [entry])
    }
}

extension NativeSnapshotExecutionTests {
    func testGalleryPreparationRefusesOversizedOrNonUTF8EntryBeforeAllocatingOwner() throws {
        for data in [Data([0xff, 0xfe]), Data(repeating: 120, count: ScriptWidgetExecutionSnapshot.maximumSourceBytes + 1)] {
            let download = try galleryDownload()
            try data.write(to: download.appendingPathComponent("main.jsx"))
            XCTAssertThrowsError(try context.installGallerySource(download, itemID: galleryTestID, version: "1.0.0", freshName: "Rejected"))
            XCTAssertNil(try context.gallerySource(itemID: galleryTestID))
        }
    }
}

extension NativeSnapshotExecutionTests {
    func testSerializedActionReconstructsIndependentNativeHostAndRejectsUnscopedDowngrade() throws {
        let (_, action) = try actionFixture()
        let snapshot = try XCTUnwrap(action.executionSnapshot)
        let request = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName, scriptParameter: "independent",
            executionScope: ScriptWidgetDirectActionRequest.scope(snapshot.binding))
        let received = try JSONDecoder().decode(ScriptWidgetDirectActionRequest.self, from: JSONEncoder().encode(request))
        let reopened = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container,
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        let host = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: reopened, buildDirectoryOverride: cache)
        var reloads = 0
        let executor = ScriptWidgetDirectActionExecutor(manager: host, reloadWidgets: { reloads += 1 })
        try executor.execute(received)
        XCTAssertEqual(defaults.string(forKey: snapshot.storageNamespace + "action-result"), ":widget:independent")
        XCTAssertEqual(reloads, 1)
        let unscoped = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName, scriptParameter: "", executionScope: "")
        XCTAssertThrowsError(try executor.execute(unscoped))
        let legacyHost = ScriptManager(isBuild: true, scriptDirectoryOverride: library)
        XCTAssertThrowsError(try ScriptWidgetDirectActionExecutor(manager: legacyHost, reloadWidgets: {}).execute(received))
        XCTAssertEqual(reloads, 1)
    }

    func testSerializedCacheActionUsesOnlyTrustedWholeCacheRoot() throws {
        let (_, action) = try actionFixture()
        let original = try XCTUnwrap(action.executionSnapshot)
        let stagedCache = root.appendingPathComponent("intent-cache-stage")
        try FileManager.default.copyItem(at: package.path, to: stagedCache)
        _ = try context.publishCache(stagedCache, source: original.binding, cacheRoot: cache)
        let cacheContext = try ScriptWidgetPackageStorageContext(libraryRoot: cache, container: container, defaults: defaults)
        let cached = try ScriptWidgetExecutionSnapshot(name: packageName, role: .cache, context: cacheContext)
        let request = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName, scriptParameter: "cache",
            executionScope: ScriptWidgetDirectActionRequest.scope(cached.binding))
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: library, source: packageName, destination: ".evicted-source", expectedReceipt: original.binding.receipt))
        try ScriptWidgetDirectActionExecutor(manager: manager, cacheRoot: cache, reloadWidgets: {}).execute(request)
        XCTAssertEqual(defaults.string(forKey: cached.storageNamespace + "action-result"), ":widget:cache")
        let wrong = root.appendingPathComponent("wrong-cache")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ScriptWidgetDirectActionExecutor(manager: manager, cacheRoot: wrong, reloadWidgets: {}).execute(request))
    }

    func testSerializedActionRejectsModifiedScopeMissingStateAndInvalidParameters() throws {
        let (_, action) = try actionFixture()
        let binding = try XCTUnwrap(action.executionSnapshot).binding
        let scope = ScriptWidgetDirectActionRequest.scope(binding)
        let executor = ScriptWidgetDirectActionExecutor(manager: manager, reloadWidgets: { XCTFail("Rejected request must not reload") })
        for function in ["update\n", "update();bad()", String(repeating: "x", count: 65), ""] {
            XCTAssertThrowsError(try executor.execute(.init(functionName: function, packageName: packageName, scriptParameter: "", executionScope: scope)))
        }
        for parameter in [String(repeating: "x", count: 16 * 1024 + 1)] {
            XCTAssertThrowsError(try executor.execute(.init(functionName: "update", packageName: packageName, scriptParameter: parameter, executionScope: scope)))
        }
        let data = try XCTUnwrap(scope.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var variants: [[String: Any]] = []
        var invalid = object; invalid["extra"] = "ignored?"; variants.append(invalid)
        invalid = object; invalid["ownerID"] = UUID().uuidString.lowercased(); variants.append(invalid)
        invalid = object; invalid["location"] = String(repeating: "b", count: 64); variants.append(invalid)
        invalid = object; invalid["role"] = "unknown"; variants.append(invalid)
        invalid = object; invalid["receipt"] = ["device": true, "inode": 1]; variants.append(invalid)
        invalid = object; invalid["name"] = "../other"; variants.append(invalid)
        for value in variants {
            let token = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            XCTAssertThrowsError(try executor.execute(.init(functionName: "update", packageName: packageName, scriptParameter: "", executionScope: token)))
        }
        XCTAssertNil(defaults.object(forKey: "ScriptWidgetStorage.v2:" + binding.ownerID + ":action-result"))
    }

    func testSerializedActionCannotFollowSameNameReinstallation() throws {
        let (_, action) = try actionFixture()
        let old = try XCTUnwrap(action.executionSnapshot)
        let request = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName, scriptParameter: "",
            executionScope: ScriptWidgetDirectActionRequest.scope(old.binding))
        XCTAssertTrue(manager.deleteScript(packageName: packageName))
        XCTAssertTrue(manager.createScript(content: "function update(){ $storage.setString('wrong','1'); }", recommendPackageName: packageName, imageCopyPath: nil).0)
        XCTAssertNil(package.readManifest(), "Old editor descriptors cannot adopt a replacement installation")
        package = manager.getScriptPackage(packageName: packageName)
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        let fresh = try capture()
        XCTAssertThrowsError(try ScriptWidgetDirectActionExecutor(manager: manager, reloadWidgets: {}).execute(request))
        XCTAssertNil(defaults.object(forKey: fresh.storageNamespace + "wrong"))
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testUnboundReadonlyPreviewHasNoExecutableActionSelector() throws {
        let (_, action) = try actionFixture()
        let readonly = ScriptWidgetPackage(path: package.path, readonly: true)
        let intent = ButtonActionAppIntent(functionName: "update", package: readonly)
        XCTAssertThrowsError(try intent.request.validate())
        let renderer = ScriptWidgetElementContext(runtime: nil, debugMode: true, scriptName: packageName, scriptParameter: "", package: readonly)
        XCTAssertFalse(renderer.canExecuteActions)
        let bound = try XCTUnwrap(action.executionSnapshot)
        let live = ScriptWidgetElementContext(runtime: runtime(bound), debugMode: false, scriptName: packageName, scriptParameter: "", package: package)
        XCTAssertTrue(live.canExecuteActions)
    }
}

extension NativeSnapshotExecutionTests {
    @available(iOS 17.0, macOS 14.0, *)
    func testUnsavedEntryPreviewCannotDispatchInstalledFunctionFromOlderFile() throws {
        _ = try actionFixture()
        let unsaved = try capture("function update(){ throw new Error('unsaved'); } $render(<text>preview</text>);")
        XCTAssertTrue(unsaved.hasUnsavedEntry)
        let renderer = ScriptWidgetElementContext(runtime: runtime(unsaved), debugMode: false, scriptName: packageName, scriptParameter: "", package: package)
        XCTAssertFalse(renderer.canExecuteActions)
        let intent = ButtonActionAppIntent(functionName: "update", package: unsaved.package, executionSnapshot: unsaved)
        XCTAssertThrowsError(try intent.request.validate())
        let saved = try capture()
        XCTAssertFalse(saved.hasUnsavedEntry)
        XCTAssertNoThrow(try ButtonActionAppIntent(functionName: "update", package: saved.package, executionSnapshot: saved).request.validate())
    }
}

extension NativeSnapshotExecutionTests {
    func testLegacyHostExecutesStatelessNamedFunctionFromNativeLibrarySelector() throws {
        XCTAssertTrue(package.writeMainFile(content: "function update(){ if($getenv('widget-param') !== 'legacy') throw new Error('parameter lost'); } $render(<text>ready</text>);").0)
        let host = ScriptManager(isBuild: true, scriptDirectoryOverride: library)
        var reloads = 0
        let request = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName, scriptParameter: "legacy", executionScope: "")
        try ScriptWidgetDirectActionExecutor(manager: host, reloadWidgets: { reloads += 1 }).execute(request)
        XCTAssertEqual(reloads, 1)
    }
}

extension NativeSnapshotExecutionTests {
    /// File mode is explicitly injected, just as the forthcoming startup cutover
    /// will do. Existing legacy-mode regressions continue to run independently.
    private func useFileBackend() throws -> ScriptWidgetFileStorageBackend {
        let backend = try ScriptWidgetFileStorageBackend(container: container, legacy: defaults)
        _ = try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [packageName], inventoryIsComplete: true, container: container, defaults: backend)
        context = try ScriptWidgetPackageStorageContext(libraryRoot: library, container: container, defaults: backend)
        try context.bindInventoriedSource(name: packageName)
        manager = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context)
        return backend
    }

    func testFileBackendMigratesOriginalsAndReopensNativeIdentityWithoutPreferenceMetadata() throws {
        let key = "script." + packageName + ".count"
        defaults.set("7", forKey: key)
        let oldIndex = defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey)
        let backend = try useFileBackend()
        let prefix = try capture().storageNamespace
        XCTAssertEqual(try backend.readValue(forKey: prefix + "count") as? String, "7")
        XCTAssertEqual(defaults.string(forKey: key), "7")
        XCTAssertEqual(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey), oldIndex)
        XCTAssertNil(defaults.object(forKey: prefix + "count"))
        XCTAssertThrowsError(try backend.writeValue("changed", forKey: key))
        XCTAssertThrowsError(try backend.removeValue(forKey: key))
        let reopened = try ScriptWidgetFileStorageBackend(container: container, legacy: defaults)
        XCTAssertEqual(try ScriptWidgetStorageNamespaces.namespace(for: packageName, container: container, defaults: reopened), prefix)
        XCTAssertEqual(try reopened.readValue(forKey: prefix + "count") as? String, "7")
        XCTAssertEqual(try render("$render(<text>{$storage.getString('count')}</text>);"), "7")
    }

    func testFileRuntimeStringJSONCASKeysAndProjectionUseOneNamespace() throws {
        let backend = try useFileBackend()
        let source = """
        const old = $storage.getString('count');
        const next = String(Number(old || '0') + 1);
        if (!$storage.compareAndSetString('count', old, next)) throw new Error('CAS failed');
        if (!$storage.setJSON('json', {value: next})) throw new Error('JSON failed');
        if (!$storage.compareAndSetJSON('json', {value: next}, {value: 'done'})) throw new Error('JSON CAS failed');
        if ($storage.compareAndSetString('count', old, 'stale')) throw new Error('stale write accepted');
        $render(<text>{next + ':' + $storage.getJSON('json').value + ':' + $storage.keys().join(',')}</text>);
        """
        func execute(_ source: String, projection: Bool = false) throws -> String {
            try prepareFunctionalTranspile(source)
            return try render(source, projection: projection)
        }
        XCTAssertEqual(try execute(source), "1:done:count,json")
        XCTAssertEqual(try execute(source), "2:done:count,json")
        XCTAssertEqual(try execute("$render(<text>{String($storage.clear()) + ':' + $storage.getString('count')}</text>);", projection: true), "false:2")
        XCTAssertEqual(try execute("$storage.remove('json'); $render(<text>{$storage.keys().join(',')}</text>);"), "count")
        XCTAssertEqual(try execute("$storage.clear(); $render(<text>{String($storage.keys().length)}</text>);"), "0")
        XCTAssertTrue(try backend.values(in: capture().storageNamespace).isEmpty)
        let prefix = try capture().storageNamespace
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(prefix) })
    }

    func testFileRecordsAndRuntimeShareConfigAndDetectConcurrentRestore() throws {
        _ = try useFileBackend()
        let store = try ScriptWidgetRecordStore(executionSnapshot: recordSnapshot())
        let before = try store.read()
        let next = try store.settingConfiguration(["goal": 12, "glassML": 300], in: before)
        try store.apply(next, expected: before)
        XCTAssertEqual(try render("$render(<text>{String(JSON.parse($storage.getString('recordTemplate.config.v1')).values.goal)}</text>);"), "12")
        let replacement = try store.settingConfiguration(["goal": 15, "glassML": 300], in: next)
        XCTAssertEqual(try render("$storage.setString('recordTemplate.config.v1', JSON.stringify({version:1,kind:'hydration',values:{goal:9,glassML:250}})); $render(<text>saved</text>);"), "saved")
        XCTAssertThrowsError(try store.apply(replacement, expected: next)) {
            XCTAssertEqual($0 as? ScriptWidgetRecordError, .conflict)
        }
        XCTAssertEqual(try store.configuration(in: store.read())["goal"] as? Int, 9)
    }

    func testFileTransactionRejectsLateInvalidValueWithoutPartialConfigWrite() throws {
        let backend = try useFileBackend(), prefix = try capture().storageNamespace
        XCTAssertTrue(ScriptWidgetAtomicPreferences.mutate(container: container, defaults: backend, namespace: prefix) { staged in
            try staged.writeValue("old", forKey: prefix + "config")
            try staged.writeValue("before", forKey: prefix + "history")
            return true
        })
        XCTAssertFalse(ScriptWidgetAtomicPreferences.mutate(container: container, defaults: backend, namespace: prefix) { staged in
            try staged.writeValue("new", forKey: prefix + "config")
            try staged.writeValue(Data(count: ScriptWidgetAtomicPreferences.maximumValueBytes + 1), forKey: prefix + "history")
            return true
        })
        XCTAssertEqual(try backend.readValue(forKey: prefix + "config") as? String, "old")
        XCTAssertEqual(try backend.readValue(forKey: prefix + "history") as? String, "before")
        XCTAssertFalse(ScriptWidgetAtomicPreferences.mutate(container: container, defaults: backend, namespace: prefix) { staged in
            try staged.writeValue("new", forKey: prefix + "config")
            return false
        })
        XCTAssertEqual(try backend.readValue(forKey: prefix + "config") as? String, "old")
    }

    func testCorruptFileRecordsRaiseRuntimeErrorAndCannotBeOverwrittenAsEmpty() throws {
        _ = try useFileBackend()
        let snapshot = try recordSnapshot()
        let file = container.appendingPathComponent(ScriptWidgetStorageFiles.directoryName).appendingPathComponent("records")
            .appendingPathComponent(snapshot.binding.ownerID + ".bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("corrupt-preserve".utf8)
        try original.write(to: file)
        let captured = try capture("$render(<text>{$storage.getString('count')}</text>);")
        let result = runtime(captured).executeJSXSyncForWidget(captured.source)
        XCTAssertTrue(result.1?.displayMessage.contains("storage:unavailable") == true, result.1?.displayMessage ?? "missing error")
        XCTAssertEqual(try render("$render(<text>{String($storage.setString('count', 'new'))}</text>);"), "false")
        XCTAssertThrowsError(try ScriptWidgetRecordStore(executionSnapshot: snapshot).read())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFileControlAndDeclaredActionReadWriteTheSameBackend() throws {
        let backend = try useFileBackend()
        let (catalog, _) = try actionFixture()
        let pair = try XCTUnwrap(catalog.controls(type: .toggle).first)
        let resolved = try pair.0.preparedForExecution()
        let prefix = try XCTUnwrap(resolved.executionSnapshot).storageNamespace
        let executor = ScriptWidgetActionExecutor(catalog: catalog, reloadWidgets: {})
        try executor.setToggleValue(true, resolved: resolved, stateKey: "focus.enabled", source: .control).get()
        XCTAssertTrue(try ScriptWidgetActionExecutor.toggleValue(resolved: resolved, stateKey: "focus.enabled"))
        XCTAssertEqual(try backend.readValue(forKey: prefix + "action-result") as? String, "true:control:")
        XCTAssertNil(defaults.object(forKey: prefix + "focus.enabled"))
        try ScriptWidgetStorageNamespaces.retire(name: packageName, container: container, defaults: backend)
        XCTAssertThrowsError(try ScriptWidgetActionExecutor.toggleValue(resolved: resolved, stateKey: "focus.enabled"))
        XCTAssertThrowsError(try executor.setToggleValue(false, resolved: resolved, stateKey: "focus.enabled", source: .control).get())
    }
}

extension NativeSnapshotExecutionTests {
    func testFileManagerRenameDeleteAndReinstallPreserveOldRecordsWithoutReusingOwner() throws {
        let backend = try useFileBackend()
        let old = try capture()
        XCTAssertEqual(try render("$storage.setString('kept', 'record'); $render(<text>saved</text>);"), "saved")
        let name = "Renamed-" + UUID().uuidString
        let renamed = manager.renameScript(srcPackageName: packageName, destPackageName: name)
        XCTAssertTrue(renamed.0, renamed.1)
        let next = try ScriptWidgetExecutionSnapshot(name: name, role: .source, context: context)
        XCTAssertEqual(next.storageNamespace, old.storageNamespace)
        XCTAssertThrowsError(try old.validateIdentity())
        XCTAssertEqual(try backend.readValue(forKey: next.storageNamespace + "kept") as? String, "record")
        XCTAssertNil(try backend.readValue(forKey: ScriptWidgetStorageNamespaces.relocationKey))
        XCTAssertTrue(manager.deleteScript(packageName: name))
        XCTAssertThrowsError(try next.validateIdentity())
        XCTAssertEqual(try backend.readValue(forKey: next.storageNamespace + "kept") as? String, "record")
        XCTAssertTrue(manager.createScript(content: "$render(<text>fresh</text>);", recommendPackageName: name, imageCopyPath: nil).0)
        let fresh = try ScriptWidgetExecutionSnapshot(name: name, role: .source, context: context)
        XCTAssertNotEqual(fresh.storageNamespace, old.storageNamespace)
        XCTAssertNil(try backend.readValue(forKey: fresh.storageNamespace + "kept"))
        packageName = name; package = manager.getScriptPackage(packageName: name)
    }

    func testFileCorruptIdentityNeverFallsBackToAnExistingPreferenceRegistry() throws {
        let backend = try useFileBackend()
        let old = try capture()
        let invalid = Data("invalid-preserve".utf8)
        XCTAssertNotNil(defaults.data(forKey: ScriptWidgetStorageNamespaces.registryKey))
        try backend.writeValue(invalid, forKey: ScriptWidgetStorageNamespaces.registryKey)
        XCTAssertThrowsError(try old.validateIdentity())
        XCTAssertThrowsError(try capture())
        XCTAssertThrowsError(try ScriptWidgetStorageNamespaces.bootstrap(existingNames: [packageName], inventoryIsComplete: true, container: container, defaults: backend))
        XCTAssertEqual(try backend.readValue(forKey: ScriptWidgetStorageNamespaces.registryKey) as? Data, invalid)
        XCTAssertThrowsError(try backend.writeValue("unknown", forKey: "untrusted.metadata"))
        XCTAssertNil(defaults.object(forKey: "untrusted.metadata"))
    }
}


extension NativeSnapshotExecutionTests {
    func testRepeatedFileRendersReleaseExecutionResourcesAtAutoreleaseBoundaries() throws {
        _ = try useFileBackend()
        for _ in 0..<(ScriptWidgetExecutionFiles.maximumActiveSnapshots * 2) {
            weak var resources: ScriptWidgetExecutionFiles?
            weak var execution: ScriptWidgetRuntime?
            weak var state: ScriptWidgetRunningState?
            try autoreleasepool {
                let snapshot = try capture("$render(<text>ready</text>);")
                resources = snapshot.package.executionFiles
                let engine = runtime(snapshot)
                execution = engine; state = engine.runningState
                let result = engine.executeJSXSyncForWidget(snapshot.source)
                XCTAssertNil(result.1, result.1?.displayMessage ?? "")
                XCTAssertEqual(text(try XCTUnwrap(result.0)), "ready")
            }
            // Synchronous completion can wake just before the producer's
            // final native stack frame unwinds. Bound that unwind allowance;
            // a retained VM cycle cannot satisfy this condition.
            let deadline = Date().addingTimeInterval(1)
            while resources != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertNil(resources, "Completed render must release its execution lease after delivery (runtime released: \(execution == nil), state released: \(state == nil))")
            if resources != nil { return }
        }
    }
}

final class RuntimeElementManagedTagTests: XCTestCase {
    func testExportedTagSurvivesGCAndMutationWithoutRetainingItsVirtualMachine() throws {
        var retained: ScriptWidgetRuntimeElement?
        weak var machine: JSVirtualMachine?
        try autoreleasepool {
            let context = try XCTUnwrap(JSContext())
            machine = context.virtualMachine
            context["$element"] = ScriptWidgetRuntimeElement.self
            context.evaluateScript("var node = $element.createElement('text', {}, ['ready']);")
            let element = try XCTUnwrap(context.objectForKeyedSubscript("node")?.toObject() as? ScriptWidgetRuntimeElement)
            retained = element
            JSGarbageCollect(context.jsGlobalContextRef)
            XCTAssertEqual(element.tagAsString(), "text")
            context.evaluateScript("node.tag = function(props) { return props.value + 1; };")
            JSGarbageCollect(context.jsGlobalContextRef)
            XCTAssertEqual(element.tag.call(withArguments: [["value": 41]])?.toInt32(), 42)
            context.evaluateScript("node.tag = 'vstack';")
            JSGarbageCollect(context.jsGlobalContextRef)
            XCTAssertEqual(element.tagAsString(), "vstack")
            XCTAssertNil(context.exception)
        }
        XCTAssertNil(machine, "A retained native element must not root its former JavaScript VM")
        XCTAssertEqual(retained?.tagAsString(), "vstack", "Native rendering keeps the resolved string tag after the VM is released")
    }
}

extension NativeSnapshotExecutionTests {
    private func useLibraryProfile() throws -> ScriptWidgetStorageProfiles {
        let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: defaults)
        context = try profiles.activate(root: library, isUsingICloud: false)
        manager = ScriptManager(isBuild: true, scriptDirectoryOverride: library, storageContext: context)
        return profiles
    }

    func testProfileSwitchRejectsCapturedRuntimeBeforeReadingOrWritingAnotherLibrary() throws {
        let profiles = try useLibraryProfile()
        XCTAssertEqual(try render("$storage.setString('count', 'A'); $render(<text>saved</text>);"), "saved")
        let old = try capture("$storage.setString('count', 'stale'); $render(<text>unexpected</text>);")
        let previous = runtime(old)
        let other = root.appendingPathComponent("other-library")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package.path, to: other.appendingPathComponent(packageName))
        let second = try profiles.activate(root: other, isUsingICloud: false, allowSwitch: true)
        let next = try ScriptWidgetExecutionSnapshot(name: packageName, role: .source, context: second,
            entryOverride: "$render(<text>{$storage.getString('count') || 'empty'}</text>);")
        let result = ScriptWidgetRuntime(package: next.package, environments: [:], executionSnapshot: next).executeJSXSyncForWidget(next.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "empty")
        let stopped = previous.executeJSXSyncForWidget(old.source)
        XCTAssertTrue(stopped.1?.displayMessage.contains("identity_changed") == true)
        XCTAssertEqual(try old.context.defaults.readValue(forKey: old.storageNamespace + "count") as? String, "A")
        XCTAssertNil(try next.context.defaults.readValue(forKey: next.storageNamespace + "count"))
        context = try profiles.activate(root: library, isUsingICloud: false, allowSwitch: true)
        XCTAssertEqual(try render("$render(<text>{$storage.getString('count')}</text>);"), "A")
        XCTAssertThrowsError(try old.validateIdentity())
    }

    func testDirectActionHostReconstructionCannotCrossLibraryProfilesWithIdenticalPublicIDs() throws {
        let profiles = try useLibraryProfile()
        let (_, action) = try actionFixture()
        let old = try XCTUnwrap(action.executionSnapshot)
        let request = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName,
            scriptParameter: "profile", executionScope: ScriptWidgetDirectActionRequest.scope(old.binding))
        let other = root.appendingPathComponent("other-library")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package.path, to: other.appendingPathComponent(packageName))
        let second = try profiles.activate(root: other, isUsingICloud: false, allowSwitch: true)
        let host = ScriptManager(isBuild: true, scriptDirectoryOverride: other, storageContext: second)
        XCTAssertThrowsError(try ScriptWidgetDirectActionExecutor(manager: host, reloadWidgets: {}).execute(request))
        let current = try ScriptWidgetExecutionSnapshot(name: packageName, role: .source, context: second)
        XCTAssertEqual(current.package.readManifest()?.id, old.package.readManifest()?.id)
        let fresh = ScriptWidgetDirectActionRequest(functionName: "update", packageName: packageName,
            scriptParameter: "profile", executionScope: ScriptWidgetDirectActionRequest.scope(current.binding))
        let received = try JSONDecoder().decode(ScriptWidgetDirectActionRequest.self, from: JSONEncoder().encode(fresh))
        let reconstructed = try ScriptWidgetStorageProfiles(container: container, legacy: defaults).currentContext()
        let receiver = ScriptManager(isBuild: true, scriptDirectoryOverride: other, storageContext: reconstructed)
        try ScriptWidgetDirectActionExecutor(manager: receiver, reloadWidgets: {}).execute(received)
        XCTAssertEqual(try current.context.defaults.readValue(forKey: current.storageNamespace + "action-result") as? String, ":widget:profile")
        XCTAssertNil(try old.context.defaults.readValue(forKey: old.storageNamespace + "action-result"))
    }
}

final class StorageCutoverBridgeTests: XCTestCase {
    private var root: URL!, library: URL!, container: URL!, package: ScriptWidgetPackage!
    private var suite: String!, defaults: UserDefaults!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CutoverBridge-" + UUID().uuidString)
        library = root.appendingPathComponent("library"); container = root.appendingPathComponent("container")
        for url in [library!, container!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let path = library.appendingPathComponent("Cutover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        package = ScriptWidgetPackage(path: path, readonly: false)
        XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: "$render(<text>ready</text>);").0)
        var manifest = WidgetPackageManifest.newProject(name: package.name); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertTrue(package.writeFile(relativePath: "record-template.json", content: #"{"formatVersion":1,"kind":"hydration"}"#).0)
        suite = "app.scriptwidget.cutover-bridge." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("real", forKey: "script.\(package.name).count")
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if let build = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: build, relative: package.name) }
        try FileManager.default.removeItem(at: root)
    }
    private func engine(readonly: Bool = false) -> ScriptWidgetRuntime {
        let runtime = ScriptWidgetRuntime(package: ScriptWidgetPackage(path: package.path, readonly: readonly), environments: [:])
        runtime.runningState?.storageDefaultsForTesting = defaults
        runtime.runningState?.storageContainerForTesting = container
        return runtime
    }
    private func text(_ root: ScriptWidgetRuntimeElement) -> String {
        (root.getChildren().compactMap { $0 as? String } + root.childrenAsElements().map(text)).joined()
    }

    func testReadonlyPreviewHasLocalRecordsAndCannotReadOrChangeRealPreferences() throws {
        let source = """
        const before = $storage.getString('count');
        const saved = $storage.setString('count', 'preview');
        $render(<text>{before + ':' + String(saved) + ':' + $storage.getString('count')}</text>);
        """
        let result = engine(readonly: true).executeJSXSyncForWidget(source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), ":true:preview")
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).count"), "real")
        let fresh = engine(readonly: true).executeJSXSyncForWidget("$render(<text>{'new:' + $storage.getString('count')}</text>);")
        XCTAssertNil(fresh.1, fresh.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(fresh.0)), "new:")
    }

    func testReadyProfileStopsPreviouslyCreatedUnboundRuntimeBeforeLegacyAccess() throws {
        let legacyRuntime = engine()
        let profiles = try ScriptWidgetStorageProfiles(container: container, legacy: defaults)
        _ = try profiles.activate(root: library, isUsingICloud: false)
        let result = legacyRuntime.executeJSXSyncForWidget("const old = $storage.getString('count'); $storage.setString('count','stale'); $render(<text>{old}</text>);")
        XCTAssertTrue(result.1?.displayMessage.contains("package:migration_required") == true, result.1?.displayMessage ?? "missing migration error")
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).count"), "real")
    }

    func testAlreadyOpenLegacyRecordSheetCannotReadOrRestoreAfterCutover() throws {
        let records = try ScriptWidgetRecordStore(package: package, container: container, defaults: defaults)
        let before = try records.read()
        let next = try records.settingConfiguration(["goal": 12, "glassML": 300], in: before)
        _ = try ScriptWidgetStorageProfiles(container: container, legacy: defaults).activate(root: library, isUsingICloud: false)
        XCTAssertThrowsError(try records.read())
        XCTAssertThrowsError(try records.apply(next, expected: before))
        XCTAssertNil(defaults.object(forKey: "script.\(package.name).recordTemplate.config.v1"))
    }
}


extension StorageCutoverBridgeTests {
    func testReadonlyPreviewCannotLoadOrOverwriteInstalledCompiledArtifacts() throws {
        let source = "$render(<text>installed</text>);"
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: package, source: source, javaScript: "installed-code"))
        let preview = ScriptWidgetPackage(path: package.path, readonly: true)
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.load(package: preview, source: source))
        XCTAssertFalse(ScriptWidgetCompiledArtifactStore.save(package: preview, source: "preview", javaScript: "preview-code"))
        XCTAssertEqual(ScriptWidgetCompiledArtifactStore.load(package: package, source: source)?.javaScript, "installed-code")
    }
}

extension StorageCutoverBridgeTests {
    func testPreviewCASJSONUnicodeKeysAndClearRemainIsolatedAfterMigration() throws {
        _ = try ScriptWidgetStorageProfiles(container: container, legacy: defaults).activate(root: library, isUsingICloud: false)
        let source = """
        const first = $storage.compareAndSetString('value', '', 'one');
        const stale = $storage.compareAndSetString('value', '', 'wrong');
        const json = $storage.compareAndSetJSON('json', {}, {n: 1});
        const second = $storage.compareAndSetJSON('json', {n: 1}, {n: 2});
        $storage.setString('é', 'NFC'); $storage.setString('e\\u0301', 'NFD');
        const distinct = $storage.getString('é') + ':' + $storage.getString('e\\u0301');
        const count = $storage.keys().length;
        $storage.remove('value');
        const cleared = $storage.clear();
        $render(<text>{[first,stale,json,second,distinct,count,cleared,$storage.keys().length].join('|')}</text>);
        """
        let result = engine(readonly: true).executeJSXSyncForWidget(source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "true|false|true|true|NFC:NFD|4|true|0")
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).count"), "real")
    }

    func testPreviewEnforcesWholeNamespaceBudgetWithoutTouchingRealRecords() throws {
        let source = """
        const value = 'x'.repeat(262144);
        for(let i=0;i<8;i++) if(!$storage.setString('key'+i,value)) throw new Error('within budget');
        const rejected = $storage.setString('overflow', 'x');
        $render(<text>{String(rejected) + ':' + $storage.keys().length + ':' + $storage.getString('key0').length}</text>);
        """
        let result = engine(readonly: true).executeJSXSyncForWidget(source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "false:8:262144")
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).count"), "real")
    }

    func testPreparingStateRejectsAllUnboundRecordMutationsAndPreservesOriginals() throws {
        enum Stop: Error { case requested }
        XCTAssertThrowsError(try ScriptWidgetStorageProfiles(container: container, legacy: defaults).activate(root: library, isUsingICloud: false) { step in
            if step == "preparing" { throw Stop.requested }
        })
        let source = """
        const rejected = [$storage.setString('count','lost'),$storage.setJSON('json',{n:1}),
          $storage.compareAndSetString('count','real','lost'),$storage.compareAndSetJSON('json',{}, {n:2}),
          $storage.remove('count'),$storage.clear()];
        $render(<text>{String(rejected.every(value => value === false))}</text>);
        """
        // Exercise the storage boundary itself, independently of the runtime's
        // earlier whole-execution migration preflight.
        let runtime = engine()
        let js = try XCTUnwrap(JSContext())
        js.scriptWidgetRunningState = runtime.runningState
        js["$storage"] = ScriptWidgetRuntimeStorage.self
        js.evaluateScript(source.replacingOccurrences(of: "$render(<text>{String(rejected.every(value => value === false))}</text>);", with: "var allRejected = rejected.every(value => value === false);"))
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.objectForKeyedSubscript("allRejected")?.toBool(), true)
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).count"), "real")
        XCTAssertNil(defaults.object(forKey: "script.\(package.name).json"))
    }
}

extension StorageCutoverBridgeTests {
    func testMigrationBlocksUnboundAsyncProducerAndDropsAnAlreadyStartedPayload() throws {
        let runtime = engine(), js = try XCTUnwrap(JSContext())
        js.scriptWidgetRunningState = runtime.runningState
        js.evaluateScript("var received=[]; function success(v){received.push('ok');} function failure(v){received.push(String(v));}")
        let success = try XCTUnwrap(js.objectForKeyedSubscript("success")), failure = try XCTUnwrap(js.objectForKeyedSubscript("failure"))
        var pending: JSValue?
        let started = ScriptWidgetRuntimePromise { resolve, _ in pending = resolve }
        started.then(success, failure)
        XCTAssertNotNil(pending)
        _ = try ScriptWidgetStorageProfiles(container: container, legacy: defaults).activate(root: library, isUsingICloud: false)
        pending?.call(withArguments: ["late private fixture"])
        let state = try XCTUnwrap(runtime.runningState)
        state.executionSession.callbackQueue.sync {}
        XCTAssertEqual(js.objectForKeyedSubscript("received")?.toArray() as? [String], ["[execution_identity_changed] Reload the widget before continuing"])
        XCTAssertEqual(state.executionSession.cancellation, .superseded)
        var produced = false
        let blocked = ScriptWidgetRuntimePromise { _, _ in produced = true }
        blocked.then(success, failure)
        XCTAssertFalse(produced)
    }
}

extension StorageCutoverBridgeTests {
    func testPreviewKeysPreserveLeadingCombiningScalars() throws {
        let source = """
        const key = String.fromCharCode(769) + 'entry';
        const saved = $storage.setString(key, 'ok');
        const listed = $storage.keys()[0];
        const same = listed === key;
        const value = $storage.getString(listed);
        $storage.remove(listed);
        $render(<text>{[saved,value,same,$storage.keys().length].join(':')}</text>);
        """
        let result = engine(readonly: true).executeJSXSyncForWidget(source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "true:ok:true:0")
    }
}

extension NativeSnapshotExecutionTests {
    func testFileBridgeKeysPreserveLeadingCombiningScalars() throws {
        _ = try useFileBackend()
        XCTAssertEqual(try render("""
            const key = String.fromCharCode(769) + 'entry';
            const saved = $storage.setString(key, 'ok');
            const listed = $storage.keys()[0];
            const same = listed === key;
            const value = $storage.getString(key);
            $storage.remove(key);
            $render(<text>{[saved,value,same,$storage.keys().length].join(':')}</text>);
            """), "true:ok:true:0")
    }
}

extension StorageCutoverBridgeTests {
    func testPreviewStorageDoesNotGrantAnUndeclaredPackagePermission() throws {
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        let result = engine(readonly: true).executeJSXSyncForWidget("$storage.setString('count','lost'); $render(<text>unexpected</text>);")
        XCTAssertTrue(result.1?.displayMessage.contains("permission_denied") == true)
        XCTAssertEqual(defaults.string(forKey: "script.\(package.name).count"), "real")
    }
}

final class LibrarySessionExecutionTests: XCTestCase {
    private var root: URL!, library: URL!, other: URL!, container: URL!
    private var suite: String!, defaults: UserDefaults!, profiles: ScriptWidgetStorageProfiles!
    private var packageName: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySession-" + UUID().uuidString)
        library = root.appendingPathComponent("library"); other = root.appendingPathComponent("other"); container = root.appendingPathComponent("container")
        for url in [library!, other!, container!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        packageName = "Session-" + UUID().uuidString
        for parent in [library!, other!] {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(packageName), withIntermediateDirectories: true)
            try Data("$render(<text>{'count:' + $storage.getString('count')}</text>);".utf8).write(to: parent.appendingPathComponent(packageName).appendingPathComponent("main.jsx"))
        }
        suite = "app.scriptwidget.library-session." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("7", forKey: "script.\(packageName!).count")
        profiles = try ScriptWidgetStorageProfiles(container: container, legacy: defaults)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if let cache = ScriptManager.getSandboxBuildDirectoryURL() { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: packageName) }
        try FileManager.default.removeItem(at: root)
    }
    private func start() throws -> ScriptWidgetLibrarySession { try .activate(profiles: profiles, root: library, isUsingICloud: false) }

    private func host(cacheOnly: Bool = false) throws -> ScriptWidgetHostExecution {
        try ScriptWidgetHostExecution.load(name: packageName, cacheOnly: cacheOnly, container: container) {
            XCTFail("An activated rendering host must never ask the legacy manager for a package")
            return ScriptWidgetPackage(path: self.library.appendingPathComponent(self.packageName), readonly: true)
        }
    }

    func testICloudSessionEstablishesProcessAccessBeforeReadingSelectedSource() throws {
        let original = try profiles.activate(root: library, isUsingICloud: true)
        let owner = try original.boundDirectory(name: packageName, role: .source).ownerID
        let inaccessible = root.appendingPathComponent("awaiting-container-access")
        try FileManager.default.moveItem(at: library, to: inaccessible)
        var calls = 0
        let session = try ScriptWidgetLibrarySession(profiles: profiles, prepareICloudAccess: {
            calls += 1
            // Model access becoming available only after the process requests
            // its container. The directory identity and user bytes stay intact.
            do { try FileManager.default.moveItem(at: inaccessible, to: self.library) }
            catch { XCTFail("Could not establish fixture access: \(error)") }
        })
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(session.sourceManager)
        XCTAssertEqual(session.selection.profile.path, library.resolvingSymlinksInPath().path)
        let captured = try session.capture(name: packageName)
        XCTAssertEqual(captured.binding.ownerID, owner)
        XCTAssertEqual(captured.binding.role, ScriptWidgetStorageDirectoryRole.source)
        XCTAssertEqual(try render(captured), "count:7")
    }

    func testLocalSessionDoesNotRequestICloudAccess() throws {
        _ = try start()
        let session = try ScriptWidgetLibrarySession(profiles: profiles, prepareICloudAccess: {
            XCTFail("A local library must not initialize iCloud access")
        })
        XCTAssertEqual(try render(session.capture(name: packageName)), "count:7")
    }

    func testICloudAccessAttemptRetainsAuthorizedCacheWhenSourceIsOffline() throws {
        _ = try profiles.activate(root: library, isUsingICloud: true)
        let initial = try ScriptWidgetLibrarySession(profiles: profiles, prepareICloudAccess: {})
        let original = try initial.capture(name: packageName)
        _ = try build(initial)
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("offline-library"))
        var calls = 0
        let session = try ScriptWidgetLibrarySession(profiles: profiles, prepareICloudAccess: { calls += 1 })
        XCTAssertEqual(calls, 1)
        XCTAssertNil(session.sourceManager)
        XCTAssertEqual(session.selection, initial.selection)
        let cached = try session.capture(name: packageName)
        XCTAssertEqual(cached.binding.role, ScriptWidgetStorageDirectoryRole.cache)
        XCTAssertEqual(cached.binding.ownerID, original.binding.ownerID)
        XCTAssertEqual(try render(cached), "count:7")
    }

    @MainActor
    func testICloudAccessInitializationRunsOffMainThreadAndFinishesBeforeReturning() {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            func finish() { lock.lock(); finished = true; lock.unlock() }
            func read() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
        }
        let state = State()
        ScriptWidgetICloudContainerAccess.establish {
            XCTAssertFalse(Thread.isMainThread)
            state.finish()
        }
        XCTAssertTrue(state.read())
    }

    func testLiveActivityIdentitySurvivesRenameButCannotFollowReinstallationOrAnotherLibrary() throws {
        let session=try start(),manager=try XCTUnwrap(session.sourceManager)
        let (binding,first)=try ScriptWidgetLiveActivityBinding.capture(name:packageName,cacheOnly:false,container:container)
        XCTAssertEqual(binding.ownerID,first.snapshot?.binding.ownerID)
        let renamed="Activity-renamed-"+UUID().uuidString
        XCTAssertTrue(manager.renameScript(srcPackageName:packageName,destPackageName:renamed).0)
        XCTAssertEqual(try binding.currentName(container:container),renamed)
        XCTAssertEqual(try binding.load(cacheOnly:false,container:container).snapshot?.binding.ownerID,binding.ownerID)
        XCTAssertTrue(manager.deleteScript(packageName:renamed))
        XCTAssertTrue(manager.createScript(content:"$render(<text>replacement</text>);",recommendPackageName:renamed,imageCopyPath:nil).0)
        XCTAssertThrowsError(try binding.load(cacheOnly:false,container:container)){XCTAssertEqual($0 as? ScriptWidgetLiveActivityBindingError,.installationRetired)}
        let other=root.appendingPathComponent("another-library");try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        _=try ScriptWidgetLibrarySession.activate(profiles:profiles,root:other,isUsingICloud:false,allowSwitch:true)
        XCTAssertThrowsError(try binding.currentName(container:container)){XCTAssertEqual($0 as? ScriptWidgetLiveActivityBindingError,.differentLibrary)}
        let malformed=try JSONDecoder().decode(ScriptWidgetLiveActivityBinding.self,from:Data(#"{"formatVersion":2,"profileID":"bad","ownerID":"bad"}"#.utf8))
        XCTAssertFalse(malformed.isValid)
        XCTAssertThrowsError(try malformed.currentName(container:container))
    }

    @MainActor
    func testWallpaperImportDraftCannotWriteIntoReinstalledOrSwitchedInstallation() throws {
        let session=try start(),manager=try XCTUnwrap(session.sourceManager)
        let installed=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Wallpaper Match"));XCTAssertTrue(installed.0,installed.1)
        let package=manager.getScriptPackage(packageName:installed.1),captured=try session.capture(name:installed.1)
        let model=ScriptWidgetRecordsModel(package:package,store:try ScriptWidgetRecordStore(executionSnapshot:captured))
        let context=try XCTUnwrap(CGContext(data:nil,width:20,height:20,bitsPerComponent:8,bytesPerRow:80,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:0.8,alpha:1));context.fill(CGRect(x:0,y:0,width:20,height:20))
        let image=try XCTUnwrap(context.makeImage())
        XCTAssertTrue(model.addWallpaperCrop(image,family:"small",appearance:"light",label:"Before removal"))
        XCTAssertTrue(manager.deleteScript(packageName:installed.1))
        let replaced=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Wallpaper Match"));XCTAssertTrue(replaced.0,replaced.1);XCTAssertEqual(replaced.1,installed.1)
        XCTAssertFalse(model.addWallpaperCrop(image,family:"small",appearance:"light",label:"Stale import"))
        let fresh=manager.getScriptPackage(packageName:replaced.1)
        XCTAssertTrue(fresh.getImageList().isEmpty)
        let current=try ScriptWidgetRecordStore(executionSnapshot:session.capture(name:replaced.1))
        let freshModel=ScriptWidgetRecordsModel(package:fresh,store:current)
        _=try ScriptWidgetLibrarySession.activate(profiles:profiles,root:other,isUsingICloud:false,allowSwitch:true)
        XCTAssertFalse(freshModel.addWallpaperCrop(image,family:"small",appearance:"dark",label:"Other library"))
        XCTAssertTrue(fresh.getImageList().isEmpty)
    }

    func testInstalledCompanionsPersistIdempotentCareAndSupportUndoWithBackups() throws {
        let session=try start(),manager=try XCTUnwrap(session.sourceManager)
        for (name,actionID) in [("Plant Care","waterPlant"),("Pocket Pet","feedPet")] {
            let installed=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/"+name));XCTAssertTrue(installed.0,installed.1)
            let catalog=try ScriptWidgetHostExecution.actionCatalog(container:container){ScriptWidgetActionCatalog(packages:[])}
            let action=try XCTUnwrap(catalog.actions().first(where:{$0.package.name==installed.1 && $0.action.id==actionID}))
            let executor=ScriptWidgetActionExecutor(catalog:catalog,reloadWidgets:{})
            try executor.execute(identifier:action.identifier,source:.widget).get()
            let store=try ScriptWidgetRecordStore(executionSnapshot:session.capture(name:installed.1)),first=try store.read()
            try executor.execute(identifier:action.identifier,source:.control).get()
            XCTAssertEqual(try store.read(),first)
            XCTAssertEqual(try store.rows(in:first).count,1)
            XCTAssertEqual(try store.previewRestore(store.backup(first)).snapshot,first)
            let projected=try session.capture(name:installed.1)
            let future=try XCTUnwrap(Calendar.current.date(byAdding:.day,value:3,to:Date()))
            let runtime=ScriptWidgetRuntime(package:projected.package,environments:["widget-size":"medium","widget-param":"","timeline-date":ISO8601DateFormatter().string(from:future),"timeline-is-projection":"true"],executionSnapshot:projected)
            let rendered=runtime.executeJSXSyncForWidget(projected.source)
            XCTAssertNil(rendered.1,rendered.1?.displayMessage ?? "")
            let tree=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(rendered.0))
            XCTAssertTrue(tree.contains(name=="Plant Care" ? "Care due" : "Ready to reconnect"))
            XCTAssertEqual(try store.read(),first)
            let undo=try XCTUnwrap(catalog.actions().first(where:{$0.package.name==installed.1 && $0.action.id=="undoRecord"}))
            try executor.execute(identifier:undo.identifier,source:.shortcut).get()
            XCTAssertTrue(try store.rows(in:store.read()).isEmpty)
            let fresh=try ScriptWidgetLibrarySession(profiles:ScriptWidgetStorageProfiles(container:container,legacy:defaults))
            XCTAssertTrue(try ScriptWidgetRecordStore(executionSnapshot:fresh.capture(name:installed.1)).rows(in:store.read()).isEmpty)
        }
    }

    func testInstalledRecordTemplatesExposeTheSameDeclaredActionsToWidgetsControlsAndShortcuts() throws {
        func step<T>(_ name: String, _ operation: () throws -> T) throws -> T {
            try XCTContext.runActivity(named: name) { _ in
                do { return try operation() }
                catch { XCTFail("\(name) failed with \(type(of: error)): \(error)"); throw error }
            }
        }
        let session=try step("Activate isolated library") { try start() },manager=try XCTUnwrap(session.sourceManager)
        let examples=[("Hydration Goal","addGlass","250 mL"),("Mood Check-in","moodFour","Good"),("Packing Checklist","toggleOne","Passport"),("Habit Streak Tracker","checkIn","✓"),("Habit Heatmap","checkInRead","✓")]
        for (name,actionID,expected) in examples {
            try autoreleasepool {
            let installed=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/"+name));XCTAssertTrue(installed.0,installed.1)
            let catalog=try step("Load catalog for \(name)") { try ScriptWidgetHostExecution.actionCatalog(container:container){ScriptWidgetActionCatalog(packages:[])} }
            let resolved=try XCTUnwrap(catalog.actions().first(where:{$0.package.name==installed.1 && $0.action.id==actionID}))
            let control=try XCTUnwrap(catalog.controls(type:.button).first(where:{$0.0.identifier==resolved.identifier}))
            XCTAssertEqual(control.1.actionID,actionID)
            let executor=ScriptWidgetActionExecutor(catalog:catalog,reloadWidgets:{})
            try step("Widget action for \(name)") { try executor.execute(identifier:resolved.identifier,source:.widget).get() }
            let store=try step("Capture record store for \(name)") { try ScriptWidgetRecordStore(executionSnapshot:session.capture(name:installed.1)) }
            XCTAssertTrue(try step("Read records for \(name)") { try store.rows(in:store.read()) }.contains(where:{$0.value==expected}),name)
            if name=="Hydration Goal" {
                try step("Hydration control action") { try executor.execute(identifier:resolved.identifier,source:.control).get() }
                try step("Hydration shortcut action") { try executor.execute(identifier:resolved.identifier,source:.shortcut).get() }
                XCTAssertEqual(try step("Read hydration after control and shortcut") { try store.rows(in:store.read()) }.first?.value,"750 mL")
            }
            }
        }
    }

    func testInstalledLocalSwitchSharesExplicitToggleStateAcrossAllSystemSurfaces() throws {
        let session=try start(),manager=try XCTUnwrap(session.sourceManager)
        let installed=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Control Switch"));XCTAssertTrue(installed.0,installed.1)
        let catalog=try ScriptWidgetHostExecution.actionCatalog(container:container){ScriptWidgetActionCatalog(packages:[])}
        let pair=try XCTUnwrap(catalog.controls(type:.toggle).first(where:{$0.0.package.name==installed.1})),resolved=try pair.0.preparedForExecution()
        let snapshot=try XCTUnwrap(resolved.executionSnapshot)
        var refreshes=0
        let executor=ScriptWidgetActionExecutor(catalog:catalog,reloadWidgets:{refreshes+=1})
        for source in [ScriptWidgetActionSource.widget,.control] {
            try executor.setToggleValue(true,resolved:resolved,stateKey:"switch.enabled",source:source).get()
            XCTAssertEqual(try snapshot.context.defaults.readValue(forKey:snapshot.storageNamespace+"switch.enabled") as? String,"true")
            XCTAssertTrue(try ScriptWidgetActionExecutor.toggleValue(resolved:resolved,stateKey:"switch.enabled"))
        }
        let off=try XCTUnwrap(catalog.actions().first(where:{$0.package.name==installed.1 && $0.action.id=="disableFlag"}))
        try executor.execute(identifier:off.identifier,source:.shortcut).get()
        XCTAssertFalse(try ScriptWidgetActionExecutor.toggleValue(resolved:resolved,stateKey:"switch.enabled"))
        XCTAssertEqual(refreshes,3)
        let reopened=try ScriptWidgetLibrarySession(profiles:ScriptWidgetStorageProfiles(container:container,legacy:defaults))
        let fresh=try reopened.capture(name:installed.1)
        XCTAssertEqual(try fresh.context.defaults.readValue(forKey:fresh.storageNamespace+"switch.enabled") as? String,"false")
        XCTAssertTrue(manager.deleteScript(packageName:installed.1))
        let replacement=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Control Switch"));XCTAssertTrue(replacement.0,replacement.1)
        XCTAssertThrowsError(try executor.execute(identifier:resolved.identifier,source:.shortcut).get())
        let replacementSnapshot=try reopened.capture(name:replacement.1)
        XCTAssertNil(try replacementSnapshot.context.defaults.readValue(forKey:replacementSnapshot.storageNamespace+"switch.enabled"))
    }

    func testInstalledRepositoryUsesRealHTTPBridgeAndReopensCachedCountsWithoutCredentials() throws {
        let session=try start(),manager=try XCTUnwrap(session.sourceManager)
        let installed=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/GitHub Repo Stats"))
        XCTAssertTrue(installed.0,installed.1)
        let first=try session.capture(name:installed.1),store=try ScriptWidgetRecordStore(executionSnapshot:first)
        try store.apply(store.settingConfiguration(["repository":"apple/swift","accent":"green"],in:store.read()),expected:store.read())
        var calls=0
        NativeIdentityURLProtocol.set("api.github.com") { item in
            calls += 1
            XCTAssertEqual(item.request.url?.path,"/repos/apple/swift")
            XCTAssertNil(item.request.value(forHTTPHeaderField:"Authorization"))
            item.respond(#"{"full_name":"apple/swift","private":false,"stargazers_count":70000,"forks_count":1200,"open_issues_count":18}"#,headers:["Content-Type":"application/json","Cache-Control":"public, max-age=3600"])
        }
        defer{NativeIdentityURLProtocol.set("api.github.com",handler:nil)}
        func execute(_ snapshot:ScriptWidgetExecutionSnapshot) throws -> String {
            let captured=try ScriptWidgetExecutionSnapshot(name:snapshot.binding.name,role:snapshot.binding.role,context:snapshot.context,entryOverride:"Date.now=()=>1767269700000;\n"+snapshot.source)
            let runtime=ScriptWidgetRuntime(package:captured.package,environments:["widget-size":"medium"],executionSnapshot:captured)
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[NativeIdentityURLProtocol.self]
            runtime.runningState?.fetchManagerForTesting=ScriptWidgetFetchManager(configuration:configuration)
            let result=runtime.executeJSXSyncForWidget(captured.source)
            XCTAssertNil(result.1,result.1?.displayMessage ?? "")
            return text(try XCTUnwrap(result.0))
        }
        XCTAssertTrue(try execute(first).contains("70000"));XCTAssertEqual(calls,1)
        let reopened=try ScriptWidgetLibrarySession(profiles:ScriptWidgetStorageProfiles(container:container,legacy:defaults))
        XCTAssertTrue(try execute(reopened.capture(name:installed.1)).contains("Saved counts"));XCTAssertEqual(calls,1)
        XCTAssertNotNil(try first.context.defaults.readValue(forKey:first.storageNamespace+"github.stats.v1"))
        XCTAssertFalse(String(decoding:try store.backup(store.read()),as:UTF8.self).contains("github.stats.v1"))
    }

    func testInstalledWeatherPersistsResponseAwareCacheThroughRealHTTPBridgeWithoutPrivateNetworkAccess() throws {
        let body=try WeatherTemplateFixtures.body(),session=try start(),manager=try XCTUnwrap(session.sourceManager)
        let installed=manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Local Weather (Location)"))
        XCTAssertTrue(installed.0,installed.1)
        let first=try session.capture(name:installed.1),store=try ScriptWidgetRecordStore(executionSnapshot:first)
        try store.apply(store.settingConfiguration(["city":"London","latitude":51.5,"longitude":-0.12,"useLocation":false,"unit":"c"],in:store.read()),expected:store.read())
        var calls=0
        NativeIdentityURLProtocol.set("api.met.no") { item in
            calls += 1
            XCTAssertEqual(item.request.value(forHTTPHeaderField:"User-Agent"),"ScriptWidget/1.3 (https://github.com/everettjf/scriptwidget)")
            item.respond(body,headers:["Content-Type":"application/json","Expires":"Thu, 01 Jan 2026 13:00:00 GMT","Last-Modified":"Thu, 01 Jan 2026 12:00:00 GMT"])
        }
        defer{NativeIdentityURLProtocol.set("api.met.no",handler:nil)}
        func execute(_ snapshot: ScriptWidgetExecutionSnapshot) throws -> String {
            let captured=try ScriptWidgetExecutionSnapshot(name:snapshot.binding.name,role:snapshot.binding.role,context:snapshot.context,
                entryOverride:"Date.now=()=>1767269700000;Math.random=()=>0;\n"+snapshot.source)
            try prepareFunctionalTranspile(captured.source)
            try prepareFunctionalTranspile(try XCTUnwrap(captured.package.readFile(relativePath:"lib/weather.js").0), wrapMain:false)
            let runtime=ScriptWidgetRuntime(package:captured.package,environments:["widget-size":"medium"],executionSnapshot:captured)
            // This test covers HTTP/cache persistence, not the simulator's
            // location daemon. Even a manually configured city checks location
            // availability so it can discard revoked location cache entries.
            let locationChecked = expectation(description: "Weather uses isolated location availability")
            runtime.validationHostInstaller = { context in
                let unavailable: @convention(block) () -> Bool = {
                    locationChecked.fulfill()
                    return false
                }
                context["__weatherLocationUnavailable"] = unsafeBitCast(unavailable, to: JSValue.self)
                context.evaluateScript("""
                    globalThis.$location = Object.freeze({
                        isAvailable: __weatherLocationUnavailable,
                        authorizationStatus: () => 'unavailable',
                        isAuthorizedForWidgetUpdates: () => false,
                        current: () => { throw new Error('Manual weather must not request location'); }
                    });
                    delete globalThis.__weatherLocationUnavailable;
                    """)
            }
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[NativeIdentityURLProtocol.self]
            let transport = ScriptWidgetFetchManager(configuration: configuration)
            // Exercise persistence through the real bridge, without timing cold
            // CFNetwork/URLProtocol startup as widget execution on a CI simulator.
            // This separate fixture never touches the forecast or its call count.
            let warmHost = "native-identity-weather-" + UUID().uuidString.lowercased() + ".example.com"
            NativeIdentityURLProtocol.set(warmHost) { $0.respond("ready") }
            defer { NativeIdentityURLProtocol.set(warmHost, handler: nil) }
            let ready = expectation(description: "Mock HTTP transport is ready")
            let warmup = transport.makeTask(httpMethod: "GET", url: try XCTUnwrap(URL(string: "https://" + warmHost)), params: nil) { data, _, error in
                XCTAssertNil(error)
                XCTAssertEqual(data, Data("ready".utf8))
                ready.fulfill()
            }
            warmup.resume()
            guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
                warmup.cancel()
                XCTFail("Mock HTTP transport did not become ready")
                throw URLError(.timedOut)
            }
            runtime.runningState?.fetchManagerForTesting = transport
            let result=runtime.executeJSXSyncForWidget(captured.source)
            XCTAssertEqual(XCTWaiter.wait(for: [locationChecked], timeout: 0), .completed)
            let trace = ScriptWidgetRuntimeTrace.recentSnapshots().last
            XCTAssertNil(result.1, "\(result.1?.displayMessage ?? ""); HTTP calls: \(calls); phases: \(trace?.durations ?? [:]); counters: \(trace?.counters ?? [:])")
            return text(try XCTUnwrap(result.0))
        }
        XCTAssertTrue(try execute(first).contains("18°C"));XCTAssertEqual(calls,1)
        let reopened=try ScriptWidgetLibrarySession(profiles:ScriptWidgetStorageProfiles(container:container,legacy:defaults))
        XCTAssertTrue(try execute(reopened.capture(name:installed.1)).contains("Saved forecast"));XCTAssertEqual(calls,1)
        let cache=try XCTUnwrap(first.context.defaults.readValue(forKey:first.storageNamespace+"weather.met.v1") as? String)
        XCTAssertTrue(cache.contains("manual:51.50,-0.12"))
        XCTAssertFalse(String(decoding:try store.backup(store.read()),as:UTF8.self).contains("weather.met.v1"))
    }

    func testInstalledPhotoCardKeepsAssetsAndSettingsAcrossCacheAndReopenWithoutReinstallInheritance() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let installed = manager.createScript(fromTemplate: ScriptWidgetPackage(bundle:"Script",relativePath:"template/Photo Card"))
        XCTAssertTrue(installed.0,installed.1)
        let package = manager.getScriptPackage(packageName:installed.1)
        let canvas = try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red:0.3,green:0.6,blue:0.4,alpha:1)); canvas.fill(CGRect(x:0,y:0,width:64,height:64))
        let image = try XCTUnwrap(canvas.makeImage()), photo = try XCTUnwrap(package.savePhotoImage(image))
        let captured = try session.capture(name:installed.1), store = try ScriptWidgetRecordStore(executionSnapshot:captured)
        let values: [String:Any] = ["title":"Offline moments","caption":"Kept in my widget","layout":"single","photos":[photo]]
        try store.apply(store.settingConfiguration(values,in:store.read()),expected:store.read())
        XCTAssertGreaterThan(manager.precachePackageFiles(package),0)
        let cached = try session.capture(name:installed.1,cacheOnly:true)
        let resource = try XCTUnwrap(cached.package.getImage(photo))
        XCTAssertNotNil(ScriptWidgetImagePipeline.image(at:resource.path))
        XCTAssertTrue(try render(cached).contains("Offline moments"))
        let reopened = try ScriptWidgetLibrarySession(profiles:ScriptWidgetStorageProfiles(container:container,legacy:defaults))
        let next = try reopened.capture(name:installed.1)
        XCTAssertEqual(try ScriptWidgetRecordStore(executionSnapshot:next).configuration(in:store.read())["photos"] as? [String],[photo])
        XCTAssertNotNil(next.package.getImage(photo))
        XCTAssertTrue(manager.deleteScript(packageName:installed.1))
        let replacement = manager.createScript(fromTemplate:ScriptWidgetPackage(bundle:"Script",relativePath:"template/Photo Card"))
        XCTAssertTrue(replacement.0,replacement.1); XCTAssertEqual(replacement.1,installed.1)
        XCTAssertTrue(package.getImageList().isEmpty); XCTAssertNil(package.getImage(photo)); XCTAssertNil(package.savePhotoImage(image))
        XCTAssertThrowsError(try store.read())
        let fresh = try session.capture(name:replacement.1)
        let freshStore = try ScriptWidgetRecordStore(executionSnapshot:fresh)
        XCTAssertEqual(try freshStore.configuration(in:freshStore.read())["photos"] as? [String],[])
        XCTAssertNil(fresh.package.getImage(photo))
    }

    func testExplicitLibraryRefreshAdoptsExternalPackagesWithoutInheritingLegacyRecords() throws {
        let service = applicationService(), first = try service.open()
        let existing = try first.capture(name: packageName)
        let name = "External-" + UUID().uuidString
        let path = library.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("$render(<text>{$storage.getString('count') || 'empty'}</text>);".utf8).write(to: path.appendingPathComponent("main.jsx"))
        defaults.set("unrelated legacy value", forKey: "script.\(name).count")
        XCTAssertThrowsError(try first.capture(name: name))
        let lease = ScriptWidgetEditorPresence.register()
        XCTAssertThrowsError(try service.refresh())
        ScriptWidgetEditorPresence.unregister(lease)
        let refreshed = try service.refresh()
        XCTAssertNotEqual(first.selection.activationID, refreshed.selection.activationID)
        XCTAssertEqual(try refreshed.capture(name: packageName).binding.ownerID, existing.binding.ownerID)
        XCTAssertEqual(try render(refreshed.capture(name: packageName)), "count:7")
        XCTAssertEqual(try render(refreshed.capture(name: name)), "empty")
        XCTAssertEqual(defaults.string(forKey: "script.\(name).count"), "unrelated legacy value")
        XCTAssertThrowsError(try existing.validateIdentity())
    }

    func testBrowserEditingLibraryDiscoversNewNamesWithoutRetargetingOldNames() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let browser = try ScriptWidgetEditingLibrary(manager: manager)
        let name = "Added-" + UUID().uuidString
        XCTAssertTrue(manager.createScript(content: "$render(<text>added</text>);", recommendPackageName: name, imageCopyPath: nil).0)
        let discovered = try XCTUnwrap(browser.package(named: name))
        XCTAssertTrue(discovered.writeFile(relativePath: "source/helper.js", content: "export default 1;").0)
        XCTAssertEqual(browser.packages.count, 2)
        XCTAssertTrue(manager.deleteScript(packageName: name))
        XCTAssertTrue(manager.createScript(content: "$render(<text>replacement</text>);", recommendPackageName: name, imageCopyPath: nil).0)
        XCTAssertNil(browser.package(named: name))
        XCTAssertFalse(discovered.writeMainFile(content: "old draft").0)
    }

    func testBrowserEditingLibraryCannotRetargetAfterSameNameReinstallation() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let browser = try ScriptWidgetEditingLibrary(manager: manager)
        let draft = try XCTUnwrap(browser.package(named: packageName))
        XCTAssertEqual(browser.packages.count, 1)
        XCTAssertTrue(draft.writeFile(relativePath: "notes.txt", content: "browser draft").0)
        XCTAssertTrue(manager.deleteScript(packageName: packageName))
        XCTAssertTrue(manager.createScript(content: "$render(<text>new</text>);", recommendPackageName: packageName, imageCopyPath: nil).0)
        XCTAssertNil(browser.package(named: packageName))
        XCTAssertTrue(browser.packages.isEmpty)
        XCTAssertFalse(draft.writeMainFile(content: "stale browser buffer").0)
        XCTAssertNotNil(try ScriptWidgetEditingLibrary(manager: manager).package(named: packageName))
    }

    func testBrowserEditingLibraryInvalidatesAcrossLibrarySwitchAndLeaseBlocksSwitch() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let browser = try ScriptWidgetEditingLibrary(manager: manager)
        let draft = try XCTUnwrap(browser.package(named: packageName))
        let service = applicationService()
        let destination = try XCTUnwrap(service.choices().first { $0.root == other })
        let lease = ScriptWidgetEditorPresence.register()
        XCTAssertThrowsError(try service.select(destination))
        XCTAssertNotNil(browser.package(named: packageName))
        ScriptWidgetEditorPresence.unregister(lease)
        let switched = try service.select(destination)
        XCTAssertNil(browser.package(named: packageName))
        XCTAssertFalse(draft.writeMainFile(content: "stale").0)
        XCTAssertNotNil(try ScriptWidgetEditingLibrary(manager: XCTUnwrap(switched.sourceManager)).package(named: packageName))
    }

    func testNativeRuntimeFallsBackToOwnedCompiledOutputAfterInvalidSource() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let first = try session.capture(name: packageName)
        XCTAssertEqual(try render(first), "count:7")
        XCTAssertNotNil(ScriptWidgetCompiledArtifactStore.load(package: first.package, source: first.source))
        XCTAssertTrue(manager.getScriptPackage(packageName: packageName).writeMainFile(content: "const broken = <;").0)
        let broken = try session.capture(name: packageName)
        XCTAssertEqual(try render(broken), "count:7")
    }

    func testNativeCompiledCachePersistsAcrossCapturesAndRejectsRetiredOwnersAndLibrarySwitches() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let first = try session.capture(name: packageName)
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: first.package, source: first.source, javaScript: "$render('compiled');"))
        let second = try session.capture(name: packageName)
        XCTAssertEqual(ScriptWidgetCompiledArtifactStore.load(package: second.package, source: first.source)?.javaScript, "$render('compiled');")
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.load(package: second.package, source: "changed"))
        XCTAssertEqual(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: second.package)?.javaScript, "$render('compiled');")
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.artifactDirectory(package: second.package))
        XCTAssertTrue(manager.deleteScript(packageName: packageName))
        XCTAssertTrue(manager.createScript(content: first.source, recommendPackageName: packageName, imageCopyPath: nil).0)
        let replacement = try session.capture(name: packageName)
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: first.package))
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: replacement.package))
        XCTAssertFalse(ScriptWidgetCompiledArtifactStore.save(package: first.package, source: first.source, javaScript: "stale"))
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: replacement.package, source: replacement.source, javaScript: "fresh"))
        _ = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: replacement.package))
    }

    func testNativeCompiledCacheRejectsChangedManifestPolicyAndUnsavedEntry() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let original = try session.capture(name: packageName)
        XCTAssertTrue(ScriptWidgetCompiledArtifactStore.save(package: original.package, source: original.source, javaScript: "legacy"))
        let manifest = WidgetPackageManifest.newProject(name: packageName)
        try JSONEncoder().encode(manifest).write(to: manager.getScriptPackage(packageName: packageName).path.appendingPathComponent("widget.json"))
        let changed = try session.capture(name: packageName)
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: changed.package))
        let draft = try ScriptWidgetExecutionSnapshot(name: packageName, role: .source, context: changed.context, entryOverride: "$render(<text>draft</text>);")
        XCTAssertFalse(ScriptWidgetCompiledArtifactStore.save(package: draft.package, source: draft.source, javaScript: "draft"))
    }

    func testOldEditorDescriptorCannotWriteOrExecuteAfterSameNameReinstallation() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let old = manager.getScriptPackage(packageName: packageName)
        let captured = try session.capture(name: packageName)
        XCTAssertTrue(manager.deleteScript(packageName: packageName))
        let created = manager.createScript(content: "$render(<text>new install</text>);", recommendPackageName: packageName, imageCopyPath: nil)
        XCTAssertTrue(created.0, created.1)
        let fresh = manager.getScriptPackage(packageName: packageName)
        let current = try session.capture(name: packageName)
        XCTAssertNotEqual(current.binding.ownerID, captured.binding.ownerID)
        XCTAssertFalse(old.writeMainFile(content: "$render(<text>old editor overwrite</text>);").0)
        XCTAssertNil(old.readMainFile().0)
        let runtime = ScriptWidgetRuntime(package: old, environments: [:])
        let result = runtime.executeJSXSyncForWidget("$storage.setString('old-editor','wrong'); $render(<text>wrong instance</text>);")
        XCTAssertNotNil(result.1)
        XCTAssertEqual(fresh.readMainFile().0, "$render(<text>new install</text>);")
        XCTAssertNil(try current.context.defaults.readValue(forKey: current.storageNamespace + "old-editor"))
    }

    private func applicationService(initial: URL? = nil, cloud: Bool = false) -> ScriptWidgetApplicationLibraryService {
        .init(profiles: profiles, initialRoot: initial ?? library, initialIsUsingICloud: cloud, alternatives: [
            .init(id: "local", root: library, isUsingICloud: false, title: "On This Device", isAvailable: true),
            .init(id: "icloud", root: other, isUsingICloud: true, title: "iCloud Drive", isAvailable: true)
        ])
    }

    func testApplicationOpenUpgradesOnceAndKeepsSelectedLibraryAcrossDefaultChanges() throws {
        let first = try applicationService().open()
        let snapshot = try first.capture(name: packageName)
        XCTAssertEqual(try render(snapshot), "count:7")
        let second = try applicationService(initial: other, cloud: true).open()
        XCTAssertEqual(first.selection, second.selection)
        XCTAssertEqual(second.sourceManager?.scriptDirectory.path, library.path)
        XCTAssertNoThrow(try snapshot.validateIdentity())
        XCTAssertEqual(defaults.string(forKey: "script.\(packageName!).count"), "7")
    }

    func testAutomaticRecoveryRegistersLateFilesWithoutChangingHistoricalOwnerOrRecords() throws {
        let service = applicationService(), first = try service.open()
        let historical = try first.capture(name: packageName)
        let late = library.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
        XCTAssertNil(try service.refreshRestoredPackages(), "An incomplete download must remain retryable")
        try Data("$render(<text>restored</text>);".utf8).write(to: late.appendingPathComponent("main.jsx"))
        XCTAssertThrowsError(try first.capture(name: "Restored"))
        let recovered = try XCTUnwrap(service.refreshRestoredPackages())
        XCTAssertEqual(try render(recovered.capture(name: "Restored")), "restored")
        let current = try recovered.capture(name: packageName)
        XCTAssertEqual(current.binding.ownerID, historical.binding.ownerID)
        XCTAssertEqual(current.storageNamespace, historical.storageNamespace)
        XCTAssertEqual(try render(current), "count:7")
        XCTAssertEqual(defaults.string(forKey: "script.\(packageName!).count"), "7")
        XCTAssertNil(try service.refreshRestoredPackages(), "An unchanged library must not rotate its activation")
        XCTAssertEqual(try service.open().selection, recovered.selection)
    }

    func testAutomaticRecoveryRetriesPartialDownloadsEvenAfterOtherPackagesWereRegistered() throws {
        let service = applicationService()
        _ = try service.open()
        let pending = library.appendingPathComponent("Pending")
        let ready = library.appendingPathComponent("Ready")
        for path in [pending, ready] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: pending.appendingPathComponent(".widget.json.icloud"))
        try Data("$render(<text>ready</text>);".utf8).write(to: ready.appendingPathComponent("main.jsx"))
        let first = try XCTUnwrap(service.refreshRestoredPackages())
        XCTAssertEqual(try render(first.capture(name: "Ready")), "ready")
        XCTAssertThrowsError(try first.capture(name: "Pending"))
        XCTAssertNil(try service.refreshRestoredPackages())
        try FileManager.default.removeItem(at: pending.appendingPathComponent(".widget.json.icloud"))
        try Data("$render(<text>downloaded</text>);".utf8).write(to: pending.appendingPathComponent("main.jsx"))
        let next = try XCTUnwrap(service.refreshRestoredPackages())
        XCTAssertEqual(try render(next.capture(name: "Pending")), "downloaded")
        XCTAssertEqual(try render(next.capture(name: packageName)), "count:7")
    }

    func testAutomaticRecoveryWaitsForNestedResourcesAndSkipsSymlinkPackages() throws {
        let service = applicationService()
        _ = try service.open()
        let pending = library.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: pending.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data("$render(<text>nested</text>);".utf8).write(to: pending.appendingPathComponent("main.jsx"))
        let placeholder = pending.appendingPathComponent("images/.photo.png.icloud")
        try Data().write(to: placeholder)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Linked"), withDestinationURL: other.appendingPathComponent(packageName))
        XCTAssertNil(try service.refreshRestoredPackages())
        try FileManager.default.removeItem(at: placeholder)
        try Data([1, 2, 3]).write(to: pending.appendingPathComponent("images/photo.png"))
        let recovered = try XCTUnwrap(service.refreshRestoredPackages())
        XCTAssertEqual(try render(recovered.capture(name: "Nested")), "nested")
        XCTAssertThrowsError(try recovered.capture(name: "Linked"))
        XCTAssertEqual(try render(recovered.capture(name: packageName)), "count:7")
    }

    func testAutomaticRecoveryWaitsForEditorsAndRejectsMalformedRestoredManifest() throws {
        let service = applicationService(), first = try service.open()
        let late = library.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
        try Data("$render(<text>restored</text>);".utf8).write(to: late.appendingPathComponent("main.jsx"))
        let lease = ScriptWidgetEditorPresence.register()
        defer { ScriptWidgetEditorPresence.unregister(lease) }
        XCTAssertThrowsError(try service.refreshRestoredPackages())
        XCTAssertEqual(try service.open().selection, first.selection)
        XCTAssertEqual(try render(first.capture(name: packageName)), "count:7")
        ScriptWidgetEditorPresence.unregister(lease)
        try Data("{invalid".utf8).write(to: late.appendingPathComponent("widget.json"))
        XCTAssertNil(try service.refreshRestoredPackages())
        XCTAssertEqual(try service.open().selection, first.selection)
        try FileManager.default.removeItem(at: late.appendingPathComponent("widget.json"))
        XCTAssertNotNil(try service.refreshRestoredPackages())
    }

    func testAutomaticRecoveryNeverGivesSameNameReplacementHistoricalRecords() throws {
        let service = applicationService(), first = try service.open()
        let historical = try first.capture(name: packageName)
        let original = library.appendingPathComponent(packageName)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("original-package"))
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("$render(<text>{'count:' + $storage.getString('count')}</text>);".utf8).write(to: original.appendingPathComponent("main.jsx"))
        let recovered = try XCTUnwrap(service.refreshRestoredPackages())
        let replacement = try recovered.capture(name: packageName)
        XCTAssertNotEqual(replacement.binding.ownerID, historical.binding.ownerID)
        XCTAssertEqual(try render(replacement), "count:")
        XCTAssertEqual(try replacement.context.defaults.readValue(forKey: historical.storageNamespace + "count") as? String, "7")
        XCTAssertEqual(defaults.string(forKey: "script.\(packageName!).count"), "7")
        XCTAssertThrowsError(try historical.validateIdentity())
    }

    @MainActor
    func testLaunchModelAutomaticallyPublishesRestoredPackages() async throws {
        let service = applicationService()
        let model = ScriptWidgetLibraryLaunchModel(cacheOnOpen: false, factory: { service })
        await model.open()
        let previous = model.selectionID
        let late = library.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
        try Data("$render(<text>restored</text>);".utf8).write(to: late.appendingPathComponent("main.jsx"))
        await model.refreshRestoredPackages()
        XCTAssertTrue(model.isReady)
        XCTAssertNil(model.message)
        XCTAssertNotEqual(model.selectionID, previous)
        XCTAssertEqual(try render(service.open().capture(name: "Restored")), "restored")
        let current = model.selectionID
        await model.refreshRestoredPackages()
        XCTAssertEqual(model.selectionID, current)
    }

    func testConcurrentApplicationOpenersKeepOneActivationIdentity() async throws {
        let service = applicationService()
        async let first = Task.detached { try service.open().selection }.value
        async let second = Task.detached { try service.open().selection }.value
        let selections = try await (first, second)
        XCTAssertEqual(selections.0, selections.1)
        XCTAssertEqual(try profiles.profiles().count, 1)
    }

    func testApplicationOpenResumesPreparingAtOriginalRoot() throws {
        enum Interrupted: Error { case requested }
        XCTAssertThrowsError(try profiles.activate(root: library, isUsingICloud: false) { stage in
            if stage == "preparing" { throw Interrupted.requested }
        })
        let opened = try applicationService(initial: other, cloud: true).open()
        XCTAssertEqual(opened.sourceManager?.scriptDirectory.path, library.path)
        XCTAssertEqual(try render(opened.capture(name: packageName)), "count:7")
    }

    func testApplicationOpenKeepsOfflineSelectionAndDoesNotCreateMissingRoot() throws {
        let first = try applicationService().open(); _ = try build(first)
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("disconnected"))
        let reopened = try applicationService(initial: other, cloud: true).open()
        XCTAssertEqual(first.selection, reopened.selection)
        XCTAssertNil(reopened.sourceManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertEqual(try render(reopened.capture(name: packageName)), "count:7")
    }

    func testLibraryChoiceWaitsForAllEditorsAndRejectsChangedSelectors() throws {
        let service = applicationService(), first = try service.open()
        let choice = try XCTUnwrap(service.choices().first { $0.id == "icloud" })
        let lease = ScriptWidgetEditorPresence.register()
        defer { ScriptWidgetEditorPresence.unregister(lease) }
        XCTAssertEqual(try service.open().selection, first.selection, "Ordinary opening does not invalidate an editor")
        XCTAssertThrowsError(try service.select(choice))
        XCTAssertNoThrow(try first.sourceManager?.storageContext?.validateLibraryRoot())
        ScriptWidgetEditorPresence.unregister(lease)
        let forged = ScriptWidgetLibraryChoice(id: choice.id, root: root.appendingPathComponent("untrusted"), isUsingICloud: true, title: choice.title, isAvailable: true)
        XCTAssertThrowsError(try service.select(forged))
        let second = try service.select(choice)
        XCTAssertNotEqual(first.selection.activationID, second.selection.activationID)
        XCTAssertEqual(second.sourceManager?.scriptDirectory.path, other.path)
        XCTAssertThrowsError(try first.sourceManager?.storageContext?.validateLibraryRoot())
        XCTAssertEqual(try render(second.capture(name: packageName)), "count:")
    }

    func testInitialApplicationUpgradeWaitsForExistingEditorAndExpiredPrecacheDoesNotPublish() throws {
        let service = applicationService(), lease = ScriptWidgetEditorPresence.register()
        defer { ScriptWidgetEditorPresence.unregister(lease) }
        XCTAssertThrowsError(try service.open())
        XCTAssertTrue(try profiles.profiles().isEmpty)
        ScriptWidgetEditorPresence.unregister(lease)
        let session = try service.open(), manager = try XCTUnwrap(session.sourceManager)
        XCTAssertEqual(manager.precachePackageFiles(manager.getScriptPackage(packageName: packageName), until: .distantPast), 0)
        XCTAssertTrue(session.cacheManager.listScripts().isEmpty)
    }

    @MainActor
    func testLaunchModelKeepsContentWhenSwitchBlockedAndReusesReadySelection() async throws {
        let service = applicationService()
        let model = ScriptWidgetLibraryLaunchModel(cacheOnOpen: false, factory: { service })
        await model.open()
        XCTAssertTrue(model.isReady)
        let selection = model.selectionID
        await model.loadChoices()
        let choice = try XCTUnwrap(model.choices.first { $0.id == "icloud" })
        let lease = ScriptWidgetEditorPresence.register()
        defer { ScriptWidgetEditorPresence.unregister(lease) }
        let blocked = await model.choose(choice)
        XCTAssertFalse(blocked)
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.selectionID, selection)
        XCTAssertTrue(model.message?.contains("Close all widget editors") == true)
        ScriptWidgetEditorPresence.unregister(lease)
        let changed = await model.choose(choice)
        XCTAssertTrue(changed)
        XCTAssertNotEqual(model.selectionID, selection)
        let next = model.selectionID
        await model.open()
        XCTAssertEqual(model.selectionID, next)
    }

    @MainActor
    func testExportLibraryOpeningInterfaceSnapshots() async throws {
        #if os(macOS)
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_LIBRARY_UI_SNAPSHOTS"] else {
            throw XCTSkip("Set SCRIPTWIDGET_LIBRARY_UI_SNAPSHOTS for native library interface captures")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func save<V: View>(_ content: V, name: String, nativeList: Bool = false) throws {
            if !nativeList {
                let renderer = ImageRenderer(content: content.frame(width: 600, height: 560).background(Color.white).environment(\.colorScheme, .light))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                return
            }
            let hosting = NSHostingView(rootView: content.frame(width: 600, height: 560).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting; window.orderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            defer { window.close() }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let service = applicationService()
        let model = ScriptWidgetLibraryLaunchModel(cacheOnOpen: false, factory: { service })
        await model.open(); await model.loadChoices()
        try save(ScriptWidgetLibrarySelectionView(model: model), name: "library-picker", nativeList: true)
        let session = try service.open(); _ = try build(session)
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("offline-source"))
        await model.open()
        XCTAssertTrue(model.isOffline)
        try save(ScriptWidgetLibraryLaunchView(model: model) { Text("Library ready") }, name: "library-offline")
        let failed = ScriptWidgetLibraryLaunchModel(cacheOnOpen: false, factory: { throw ScriptWidgetLibraryOpeningError.storageUnavailable })
        await failed.open()
        try save(ScriptWidgetLibraryLaunchView(model: failed) { Text("Library ready") }, name: "library-unavailable")
        #else
        throw XCTSkip("Native library interface captures run on macOS")
        #endif
    }

    func testInstalledSnapshotRetainsPersonalDataPermissionDespiteReadonlyExecutionFiles() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName)
        manifest.permissions = [.health, .calendar, .location, .storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        let snapshot = try session.capture(name: packageName)
        let state = ScriptWidgetRunningState(package: snapshot.package, executionSnapshot: snapshot)
        XCTAssertNil(state.previewStorage)
        XCTAssertTrue(ScriptWidgetHealthAccessPolicy.permits(state))
        let context = try XCTUnwrap(JSContext()); context.scriptWidgetRunningState = state
        let probe: @convention(block) () -> Bool = { ScriptWidgetRuntimeCalendar.permittedState() != nil }
        context["probe"] = unsafeBitCast(probe, to: JSValue.self)
        XCTAssertTrue(try XCTUnwrap(context.evaluateScript("probe()")).toBool())
    }

    func testManagedPrecachePublishesCompleteBoundPackageIncludingOpaqueResources() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        for name in ["lib", "assets"] { try FileManager.default.createDirectory(at: package.path.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("export const value = 42;".utf8).write(to: package.path.appendingPathComponent("lib/helper.js"))
        try Data("opaque resource".utf8).write(to: package.path.appendingPathComponent("assets/sample.bin"))
        XCTAssertEqual(manager.precachePackageFiles(package), 3)
        let cached = try session.capture(name: packageName, cacheOnly: true)
        XCTAssertEqual(cached.binding.role, .cache)
        XCTAssertEqual(cached.package.readFile(relativePath: "lib/helper.js").0, "export const value = 42;")
        XCTAssertEqual(cached.package.readFile(relativePath: "assets/sample.bin").0, "opaque resource")
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("offline-source"))
        XCTAssertEqual(try render(ScriptWidgetLibrarySession(profiles: profiles).capture(name: packageName)), "count:7")
    }

    func testManagedPrecacheFailureKeepsPreviousCompleteCache() throws {
        let session = try start(), package = try build(session)
        let manager = try XCTUnwrap(session.sourceManager)
        let before = try session.capture(name: packageName, cacheOnly: true)
        try Data("{bad".utf8).write(to: package.manifestPath)
        XCTAssertEqual(manager.precachePackageFiles(package), 0)
        let cached = try ScriptWidgetExecutionSnapshot(name: packageName, role: .cache, context: XCTUnwrap(session.cacheManager.storageContext))
        XCTAssertEqual(cached.source, before.source)
        XCTAssertEqual(cached.storageNamespace, before.storageNamespace)
        XCTAssertThrowsError(try session.capture(name: packageName))
    }

    func testStaleAndUnavailableManagersDoNotPrecacheOldSources() throws {
        let first = try start(), manager = try XCTUnwrap(first.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        _ = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertEqual(manager.precachePackageFiles(package), 0)
        let unavailable = ScriptManager(isBuild: false, unavailableReason: "Unavailable")
        XCTAssertEqual(unavailable.precachePackageFiles(package), 0)
        XCTAssertTrue(first.cacheManager.listScripts().isEmpty)
    }

    private func applicationManager(cache: Bool = false) -> ScriptManager {
        ScriptWidgetLibraryManagers.resolve(isBuild: cache, container: container) {
            XCTFail("An activated application must not fall back to its legacy manager")
            return ScriptManager(isBuild: cache, unavailableReason: "Unexpected legacy fallback")
        }
    }

    func testApplicationManagerResolverUsesLegacyOnlyBeforeNativeActivation() throws {
        var calls = 0
        let before = ScriptWidgetLibraryManagers.resolve(isBuild: false, container: container) {
            calls += 1
            return ScriptManager(isBuild: false, scriptDirectoryOverride: self.library)
        }
        XCTAssertNil(before.storageContext)
        XCTAssertEqual(calls, 1)
        let session = try start(); _ = try build(session)
        let source = applicationManager(), cache = applicationManager(cache: true)
        XCTAssertEqual(source.scriptDirectory.path, library.path)
        XCTAssertEqual(cache.scriptDirectory, session.cacheRoot)
        XCTAssertEqual(source.storageRole, .source)
        XCTAssertEqual(cache.storageRole, .cache)
        XCTAssertNotNil(source.getScriptPackage(packageName: packageName).managedScope)
        XCTAssertNil(source.unavailableReason)
    }

    func testOfflineApplicationManagerCannotRecreateSourceOrMutateCachedPackages() throws {
        let session = try start(); _ = try build(session)
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("offline"))
        let source = applicationManager(), cache = applicationManager(cache: true)
        XCTAssertNotNil(source.unavailableReason)
        XCTAssertTrue(source.listScripts().isEmpty)
        XCTAssertTrue(source.getScriptPackage(packageName: packageName).readonly)
        XCTAssertFalse(source.saveScript(packageName: packageName, content: "must not save", imageCopyPath: nil).0)
        XCTAssertFalse(source.createScript(content: "must not create", recommendPackageName: "New", imageCopyPath: nil).0)
        let unwanted = root.appendingPathComponent("must-not-create")
        source.makeSureDirectoryExist(path: unwanted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwanted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(cache.getScriptPackage(packageName: packageName).writeMainFile(content: "must not edit cache").0)
        XCTAssertEqual(try render(XCTUnwrap(host().snapshot)), "count:7")
    }

    func testMalformedProfileReturnsUnavailableApplicationManagersWithoutLegacyFallback() throws {
        _ = try start()
        let files = try ScriptWidgetStorageFiles(container: container)
        try files.writeMetadata(key: ScriptWidgetStorageProfiles.indexKey, data: Data("invalid index".utf8))
        for cache in [false, true] {
            let manager = applicationManager(cache: cache)
            XCTAssertNotNil(manager.unavailableReason)
            XCTAssertTrue(manager.listScripts().isEmpty)
            XCTAssertFalse(manager.saveScript(packageName: packageName, content: "wrong root", imageCopyPath: nil).0)
        }
    }

    private func actionPackage(_ session: ScriptWidgetLibrarySession) throws -> ScriptWidgetPackage {
        let package = try XCTUnwrap(session.sourceManager).getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName)
        manifest.permissions = [.storage]
        manifest.actions = [.init(id: "update", title: "Update", systemImage: "checkmark", function: "update")]
        manifest.controls = [.init(id: "enabled", type: .toggle, title: "Enabled", subtitle: nil, systemImage: "checkmark", action: nil, actionID: "update", stateKey: "enabled")]
        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertTrue(package.writeMainFile(content: "function update(){ $storage.setString('count','9'); } $render(<text>ready</text>);").0)
        _ = try build(session)
        return package
    }

    private func nativeCatalog() throws -> ScriptWidgetActionCatalog {
        try ScriptWidgetHostExecution.actionCatalog(container: container) {
            XCTFail("Activated action catalogue must never use legacy discovery")
            return ScriptWidgetActionCatalog(packages: [])
        }
    }

    func testActionAndControlCataloguePrepareBoundCacheAndUpdateOwnedToggle() throws {
        let session = try start(), package = try actionPackage(session)
        let sourceAction = try XCTUnwrap(nativeCatalog().actions().first)
        let source = try sourceAction.preparedForExecution()
        XCTAssertEqual(source.executionSnapshot?.binding.role, .source)
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("main.jsx"))
        try Data().write(to: package.path.appendingPathComponent(".main.jsx.icloud"))
        let catalog = try nativeCatalog()
        let control = try XCTUnwrap(catalog.controls(type: .toggle).first)
        let prepared = try control.0.preparedForExecution()
        XCTAssertEqual(prepared.executionSnapshot?.binding.role, .cache)
        XCTAssertEqual(source.ownerID, prepared.ownerID)
        XCTAssertFalse(try ScriptWidgetActionExecutor.toggleValue(resolved: control.0, stateKey: "enabled"))
        let executor = ScriptWidgetActionExecutor(catalog: catalog, reloadWidgets: {})
        if case .failure(let error) = executor.setToggleValue(true, resolved: control.0, stateKey: "enabled", source: .control) { XCTFail(String(describing: error)) }
        XCTAssertTrue(try ScriptWidgetActionExecutor.toggleValue(resolved: control.0, stateKey: "enabled"))
        let snapshot = try XCTUnwrap(prepared.executionSnapshot)
        XCTAssertEqual(try snapshot.context.defaults.readValue(forKey: snapshot.storageNamespace + "count") as? String, "9")
        XCTAssertEqual(defaults.string(forKey: "script.\(packageName!).count"), "7")
    }

    func testCachedCatalogueCannotPrepareAfterSourcePolicyRevocationOrLibrarySwitch() throws {
        let session = try start(), package = try actionPackage(session)
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("main.jsx"))
        try Data().write(to: package.path.appendingPathComponent(".main.jsx.icloud"))
        let catalog = try nativeCatalog()
        let action = try XCTUnwrap(catalog.actions().first)
        XCTAssertNotNil(try action.preparedForExecution().executionSnapshot)
        var manifest = try XCTUnwrap(package.readManifest())
        manifest.permissions = []
        manifest.controls = nil
        // Model a synced manifest arriving while its entry remains evicted.
        try JSONEncoder().encode(manifest).write(to: package.manifestPath)
        XCTAssertThrowsError(try action.preparedForExecution())
        XCTAssertThrowsError(try ScriptWidgetActionExecutor.toggleValue(resolved: action, stateKey: "enabled"))
        XCTAssertTrue(try nativeCatalog().actions().isEmpty)
        _ = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertThrowsError(try action.preparedForExecution())
    }

    func testConfigurationNamesUseActiveOwnersAndOfflineCacheWithoutLegacyFallback() throws {
        let session = try start(); _ = try build(session)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Unowned"), withIntermediateDirectories: true)
        func names() throws -> [String] {
            try ScriptWidgetHostExecution.availableNames(container: container) {
                XCTFail("Active library options must not query the legacy manager")
                return ["Legacy"]
            }
        }
        XCTAssertEqual(try names(), [packageName])
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("offline-source"))
        XCTAssertEqual(try names(), [packageName])
        let second = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertNotNil(second.sourceManager)
        XCTAssertEqual(try names(), [packageName])
        XCTAssertTrue(second.cacheManager.listScripts().isEmpty)
    }

    func testProductionActionReceiverMatchesSourceAndCacheSelectorsAndRejectsOldLibrary() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        XCTAssertTrue(package.writeMainFile(content: "function update(){ $storage.setString('count', String(Number($storage.getString('count') || '0') + 1)); } $render(<text>ready</text>);").0)
        _ = try build(session)
        var reloads = 0
        func request(_ snapshot: ScriptWidgetExecutionSnapshot) -> ScriptWidgetDirectActionRequest {
            .init(functionName: "update", packageName: packageName, scriptParameter: "", executionScope: ScriptWidgetDirectActionRequest.scope(snapshot.binding))
        }
        func execute(_ request: ScriptWidgetDirectActionRequest) throws {
            try ScriptWidgetDirectActionExecutor.executeHost(request, load: { selected, cached in
                XCTAssertEqual(selected, self.packageName)
                return try self.host(cacheOnly: cached)
            }, reloadWidgets: { reloads += 1 })
        }
        let source = try XCTUnwrap(host().snapshot), cache = try XCTUnwrap(host(cacheOnly: true).snapshot)
        try execute(request(source))
        try execute(request(cache))
        XCTAssertEqual(try source.context.defaults.readValue(forKey: source.storageNamespace + "count") as? String, "9")
        XCTAssertEqual(reloads, 2)
        XCTAssertThrowsError(try execute(.init(functionName: "update", packageName: packageName, scriptParameter: "", executionScope: "")))
        _ = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertThrowsError(try execute(request(source)))
        XCTAssertThrowsError(try execute(request(cache)))
        XCTAssertEqual(reloads, 2)
    }

    func testRenderingHostCapturesSourceAndResourcesBeforeExecution() throws {
        let session = try start(), package = try build(session)
        let resource = package.path.appendingPathComponent("note.txt")
        try Data("captured resource".utf8).write(to: resource)
        let execution = try host()
        let snapshot = try XCTUnwrap(execution.snapshot)
        XCTAssertEqual(snapshot.binding.role, .source)
        try Data("$render(<text>changed after capture</text>);".utf8).write(to: package.path.appendingPathComponent("main.jsx"))
        try Data("changed resource".utf8).write(to: resource)
        XCTAssertEqual(execution.package.readFile(relativePath: "note.txt").0, "captured resource")
        XCTAssertEqual(try render(snapshot), "count:7")
        XCTAssertEqual(execution.source, snapshot.source)
    }

    func testRenderingHostLoadsCompleteCacheForEvictedSourceAndActivity() throws {
        let session = try start(), package = try build(session)
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("main.jsx"))
        try Data().write(to: package.path.appendingPathComponent(".main.jsx.icloud"))
        let widget = try XCTUnwrap(host().snapshot)
        let activity = try XCTUnwrap(host(cacheOnly: true).snapshot)
        XCTAssertEqual(widget.binding.role, .cache)
        XCTAssertEqual(widget.storageNamespace, activity.storageNamespace)
        XCTAssertEqual(try render(widget), "count:7")
        XCTAssertEqual(try render(activity), "count:7")
    }

    func testActivityCacheCannotRestoreRevokedSourcePermissions() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName)
        manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        _ = try build(session)
        XCTAssertNotNil(try host(cacheOnly: true).snapshot)
        manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertThrowsError(try host(cacheOnly: true))
    }

    func testRenderingHostBeforeActivationKeepsLegacyAndDoesNotMigrate() throws {
        let execution = try ScriptWidgetHostExecution.load(name: packageName, container: container) {
            ScriptWidgetPackage(path: self.library.appendingPathComponent(self.packageName), readonly: true)
        }
        XCTAssertNil(execution.snapshot)
        XCTAssertTrue(execution.source.contains("$storage.getString"))
        XCTAssertTrue(try profiles.profiles().isEmpty)
    }

    func testRenderingHostRejectsPreparingLibraryWithoutLegacyFallback() throws {
        enum Interrupted: Error { case activation }
        XCTAssertThrowsError(try profiles.activate(root: library, isUsingICloud: false) { step in
            if step == "preparing" { throw Interrupted.activation }
        })
        XCTAssertFalse(try profiles.profiles().isEmpty)
        XCTAssertThrowsError(try host())
        XCTAssertNotNil(applicationManager().unavailableReason)
        XCTAssertNotNil(applicationManager(cache: true).unavailableReason)
        XCTAssertThrowsError(try ScriptWidgetHostExecution.availableNames(container: container) {
            XCTFail("Preparing library must not publish legacy options")
            return []
        })
    }

    func testWidgetBuildAcceptsOnlyActiveProfileCacheInTheSharedContainer() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        XCTAssertNoThrow(try manager.validateWidgetCache(session.cacheRoot, sharedContainer: container))
        XCTAssertThrowsError(try manager.validateWidgetCache(container.appendingPathComponent("__Build"), sharedContainer: container))
        XCTAssertThrowsError(try manager.validateWidgetCache(library, sharedContainer: container))
        XCTAssertThrowsError(try manager.validateWidgetCache(session.cacheRoot, sharedContainer: other))
        let replacement = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertThrowsError(try manager.validateWidgetCache(session.cacheRoot, sharedContainer: container))
        XCTAssertNoThrow(try replacement.sourceManager?.validateWidgetCache(replacement.cacheRoot, sharedContainer: container))
    }
    private func build(_ session: ScriptWidgetLibrarySession) throws -> ScriptWidgetPackage {
        let manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        let built = manager.buildScriptPackage(package: package)
        XCTAssertTrue(built.0, built.1)
        return package
    }
    private func text(_ element: ScriptWidgetRuntimeElement) -> String {
        (element.getChildren().compactMap { $0 as? String } + element.childrenAsElements().map(text)).joined()
    }
    private func render(_ snapshot: ScriptWidgetExecutionSnapshot) throws -> String {
        let result = ScriptWidgetRuntime(package: snapshot.package, environments: [:], executionSnapshot: snapshot).executeJSXSyncForWidget(snapshot.source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        return text(try XCTUnwrap(result.0))
    }

    func testOpenRequiresReadyActivationAndDoesNotBootstrapFromWidgetHost() throws {
        XCTAssertThrowsError(try ScriptWidgetLibrarySession(profiles: profiles))
        XCTAssertTrue(try profiles.profiles().isEmpty)
        let session = try start()
        XCTAssertNotNil(session.sourceManager)
        XCTAssertTrue(session.cacheManager.isBuild)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.cacheRoot.path))
    }

    func testManagedRuntimeCapturesEditorInputAndUsesOwnedRecordsWithoutExplicitSnapshot() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        XCTAssertNotNil(package.managedScope)
        let runtime = ScriptWidgetRuntime(package: package, environments: [:])
        let source = "const old=$storage.getString('count'); $storage.compareAndSetString('count',old,'8'); $render(<text>{old + ':' + $storage.getString('count')}</text>);"
        let result = runtime.executeJSXSyncForWidget(source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "7:8")
        let captured = try XCTUnwrap(runtime.runningState?.executionSnapshot)
        XCTAssertTrue(captured.hasUnsavedEntry)
        XCTAssertNotNil(captured.package.executionFiles)
        XCTAssertEqual(try captured.context.defaults.readValue(forKey: captured.storageNamespace + "count") as? String, "8")
        XCTAssertEqual(defaults.string(forKey: "script.\(packageName!).count"), "7")
        XCTAssertNil(ScriptWidgetCompiledArtifactStore.artifactDirectory(package: package))
    }

    func testManagerListsKeepManagedScopeForEditorAndAsyncPaths() async throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        XCTAssertNotNil(manager.listScripts().first?.package.managedScope)
        let rows = await manager.asyncListScripts()
        XCTAssertNotNil(rows.first?.package.managedScope)
    }

    func testMissingEntryUsesWholeBoundCacheWithoutChangingNamespace() throws {
        let session = try start(), package = try build(session)
        XCTAssertFalse(session.cacheManager.getScriptPackage(packageName: packageName).writeMainFile(content: "cache must not be edited").0)
        let source = try session.capture(name: packageName)
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("main.jsx"))
        try Data().write(to: package.path.appendingPathComponent(".main.jsx.icloud"))
        XCTAssertNil(package.readMainFile().0, "Managed source reads never mix in individual legacy cache files")
        let cached = try session.capture(name: packageName)
        XCTAssertEqual(cached.binding.role, .cache)
        XCTAssertEqual(cached.storageNamespace, source.storageNamespace)
        XCTAssertEqual(try render(cached), "count:7")
    }

    func testMissingSourceRootCanOpenExistingCacheWithoutRecreatingTheLibrary() throws {
        let session = try start(); _ = try build(session)
        let before = try session.capture(name: packageName)
        let preserved = root.appendingPathComponent("preserved-library")
        try FileManager.default.moveItem(at: library, to: preserved)
        let reopened = try ScriptWidgetLibrarySession(profiles: profiles)
        XCTAssertNil(reopened.sourceManager)
        let cached = try reopened.capture(name: packageName)
        XCTAssertEqual(cached.storageNamespace, before.storageNamespace)
        XCTAssertEqual(try render(cached), "count:7")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testMalformedManifestNeverFallsBackToCachedPermissions() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        _ = try build(session)
        try Data("{bad".utf8).write(to: package.manifestPath)
        try Data().write(to: package.path.appendingPathComponent(".resource.png.icloud"))
        XCTAssertThrowsError(try session.capture(name: packageName))
    }

    func testChangedManifestCannotBorrowTheCachedPermissionPolicy() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        _ = try build(session)
        manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        try FileManager.default.removeItem(at: package.path.appendingPathComponent("main.jsx"))
        try Data().write(to: package.path.appendingPathComponent(".main.jsx.icloud"))
        XCTAssertThrowsError(try session.capture(name: packageName))
    }

    func testReplacedSourceAndPresentInvalidEntryDoNotSelectAnOldCache() throws {
        let session = try start(), package = try build(session)
        try Data([0xff, 0xfe]).write(to: package.path.appendingPathComponent("main.jsx"))
        XCTAssertThrowsError(try session.capture(name: packageName))
        try FileManager.default.moveItem(at: package.path, to: root.appendingPathComponent("original-package"))
        try FileManager.default.createDirectory(at: package.path, withIntermediateDirectories: true)
        try Data().write(to: package.path.appendingPathComponent(".main.jsx.icloud"))
        XCTAssertThrowsError(try session.capture(name: packageName))
    }

    func testSameNamedLibrariesHavePrivateCachesAndStaleEditorCannotWrite() throws {
        let first = try start(), package = try build(first)
        let original = try Data(contentsOf: package.path.appendingPathComponent("main.jsx"))
        let second = try ScriptWidgetLibrarySession.activate(profiles: profiles, root: other, isUsingICloud: false, allowSwitch: true)
        XCTAssertNotEqual(first.cacheRoot, second.cacheRoot)
        XCTAssertFalse(first.sourceManager!.saveScript(packageName: packageName, content: "stale manager", imageCopyPath: nil).0)
        XCTAssertFalse(package.writeMainFile(content: "stale editor").0)
        XCTAssertEqual(try Data(contentsOf: package.path.appendingPathComponent("main.jsx")), original)
        XCTAssertTrue(first.sourceManager?.listScripts().isEmpty == true)
        XCTAssertThrowsError(try first.capture(name: packageName))
        XCTAssertThrowsError(try first.cacheManager.storageContext?.validateLibraryRoot())
        let secondPackage = try build(second)
        XCTAssertNotNil(secondPackage.managedScope)
        let cached = try second.capture(name: packageName, cacheOnly: true)
        XCTAssertEqual(try render(cached), "count:")
    }
}

final class IsolatedPersonalDataPreviewTests: XCTestCase {
    private var root: URL!, package: ScriptWidgetPackage!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        package = ScriptWidgetPackage(path: root)
        XCTAssertTrue(package.writeMainFile(content: "$render(<text>preview</text>);").0)
        var manifest = WidgetPackageManifest.newProject(name: package.name)
        manifest.permissions = [.health, .calendar, .location, .storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func text(_ element: ScriptWidgetRuntimeElement) -> String {
        (element.getChildren().compactMap { $0 as? String } + element.childrenAsElements().map(text)).joined()
    }

    func testReadonlyPreviewDeniesAllPersonalDataQueriesBeforeSystemAccess() throws {
        let runtime = ScriptWidgetRuntime(package: ScriptWidgetPackage(path: root, readonly: true), environments: [:])
        let result = runtime.executeJSXSyncForWidget("""
            const statuses = [$calendar.authorizationStatus(), $health.authorizationStatus(), $location.authorizationStatus()];
            let denied = 0;
            for (const call of [() => $calendar.requestAuthorization(), () => $calendar.calendars(), () => $calendar.events(),
                () => $health.requestAuthorization(), () => $health.stepCountToday(), () => $health.activeEnergyToday(), () => $health.heartRateLatest(),
                () => $location.requestAuthorization(), () => $location.current()]) {
                try { await call(); } catch (e) { if (String(e).includes('[permission_denied]')) denied++; }
            }
            $render(<text>{statuses.join(':') + ':' + denied + ':' + [$calendar.isAvailable(), $health.isAvailable(), $location.isAvailable(), $location.isAuthorizedForWidgetUpdates()].join(',')}</text>);
            """)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "unavailable:unavailable:unavailable:9:false,false,false,false")
        XCTAssertEqual(runtime.runningState?.executionSession.totalDataQueries, 0)
    }

    func testPackageTwoHealthQueriesRequireDeclaredHealthPermission() throws {
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = [.storage]
        XCTAssertTrue(package.writeManifest(manifest).0)
        let runtime = ScriptWidgetRuntime(package: package, environments: [:])
        runtime.runningState?.storageContainerForTesting = root
        let result = runtime.executeJSXSyncForWidget("""
            let denied = 0;
            for (const call of [() => $health.requestAuthorization(), () => $health.stepCountToday(), () => $health.activeEnergyToday(), () => $health.heartRateLatest()]) {
                try { await call(); } catch(e) { if (String(e).includes('[permission_denied]')) denied++; }
            }
            $render(<text>{$health.authorizationStatus() + ':' + denied}</text>);
            """)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        XCTAssertEqual(text(try XCTUnwrap(result.0)), "undeclared:4")
        XCTAssertEqual(runtime.runningState?.executionSession.totalDataQueries, 0)
    }

    func testAITrialRunsUseFreshIsolatedStorage() async throws {
        let bridge = AgentRuntimeBridge.shared
        let sandbox = try bridge.makeSandboxPackage(prefix: "isolated-records")
        defer { bridge.cleanupSandboxPackage(sandbox) }
        let first = await bridge.run(jsx: "$storage.setString('preview','first'); $render(<text>{$storage.getString('preview')}</text>);", in: sandbox, size: .medium)
        XCTAssertNil(first.error)
        XCTAssertEqual(text(try XCTUnwrap(first.element)), "first")
        let second = await bridge.run(jsx: "$render(<text>{'next:' + $storage.getString('preview')}</text>);", in: sandbox, size: .medium)
        XCTAssertNil(second.error)
        XCTAssertEqual(text(try XCTUnwrap(second.element)), "next:")
    }

    func testReadonlyPreviewCannotAcquireCalendarQueryState() throws {
        let context = try XCTUnwrap(JSContext())
        context.scriptWidgetRunningState = ScriptWidgetRunningState(package: ScriptWidgetPackage(path: root, readonly: true))
        let probe: @convention(block) () -> Bool = { ScriptWidgetRuntimeCalendar.permittedState() != nil }
        context["probe"] = unsafeBitCast(probe, to: JSValue.self)
        XCTAssertFalse(try XCTUnwrap(context.evaluateScript("probe()")).toBool())
    }
}

private final class RemindersFixtureProvider: ScriptWidgetRemindersProviding {
    var writes = 0
    var onMutate: (() -> Void)?
    func mutate(_ request: ScriptWidgetReminderMutation, beforeCommit: () throws -> Void) throws -> String {
        if let id = request.id, id != request.listID { throw ScriptWidgetRemindersError.invalid("Reminder is outside the selected list") }
        onMutate?(); try beforeCommit(); writes += 1
        return request.id ?? "created-" + request.requestID
    }

    var status = "authorized"
    var onFetch: (() -> Void)?
    var fetches = 0
    var onStatus: (() -> Void)?
    func authorizationStatus() -> String { onStatus?(); return status }
    func sources() -> [ScriptWidgetCalendarSource] { [.init(id: "personal", title: "Personal"), .init(id: "work", title: "private-list")] }
    func fetch(_ query: ScriptWidgetRemindersQuery, ids: [String], session: ScriptWidgetExecutionSession,
               completion: @escaping (Result<(items: [ScriptWidgetReminderItem], truncated: Bool), Error>) -> Void) {
        fetches += 1; onFetch?()
        completion(.success((["personal", "work"].map { id in
            .init(id: id, listID: id, title: id == "work" ? "private-reminder" : "Read a chapter", due: ISO8601DateFormatter().string(from: query.window.start.addingTimeInterval(3600)), hasTime: true, completed: false, completedAt: nil, priority: 0)
        }, false)))
    }
}

extension RuntimeExecutionTests {
    private func remindersRuntime(_ f: (root: URL, package: ScriptWidgetPackage, defaults: UserDefaults, suite: String), provider: RemindersFixtureProvider, declared: Bool = true, environments: [String: String] = ["widget-size": "medium"]) throws -> ScriptWidgetRuntime {
        var manifest = try XCTUnwrap(f.package.readManifest())
        manifest.permissions = declared ? [.reminders] : []
        try JSONEncoder().encode(manifest).write(to: f.package.path.appendingPathComponent("widget.json"))
        let runtime = ScriptWidgetRuntime(package: f.package, environments: environments)
        runtime.runningState?.storageContainerForTesting = f.root
        runtime.runningState?.storageDefaultsForTesting = f.defaults
        runtime.runningState?.remindersProviderForTesting = provider
        return runtime
    }

    func testRemindersReadFiltersListsCachesAndRejectsOutsideScope() throws {
        let f = try calendarSelectionFixture(), provider = RemindersFixtureProvider()
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: f.root, kind: .reminders)
        let result = try remindersRuntime(f, provider: provider).executeJSXSyncForWidget("""
            const options={start:'2026-02-03T00:00:00Z',end:'2026-02-04T00:00:00Z'};
            const lists=await $reminders.lists(),first=await $reminders.items(options),cache=await $reminders.items(options);
            let blocked=false;try{await $reminders.items({...options,listIDs:['work']});}catch(e){blocked=String(e).includes('invalid_options');}
            $render(<text>{JSON.stringify({lists,first,source:cache.source,blocked})}</text>);
        """)
        XCTAssertNil(result.1); let xml = result.0.map { collectText($0) } ?? ""
        XCTAssertTrue(xml.contains("Read a chapter")); XCTAssertTrue(xml.contains("cache")); XCTAssertTrue(xml.contains("true"))
        XCTAssertFalse(xml.contains("private-reminder")); XCTAssertFalse(xml.contains("private-list")); XCTAssertEqual(provider.fetches, 1)
    }

    func testRemindersRevocationAndScopeChangesFenceResponsesAndPurgeCaches() throws {
        for revoke in [false, true] {
            let f = try calendarSelectionFixture(), provider = RemindersFixtureProvider()
            defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
            let runtime = try remindersRuntime(f, provider: provider)
            provider.onFetch = {
                if revoke { provider.status = "denied" }
                else { try? ScriptWidgetCalendarSelection(calendarIDs: []).save(container: f.root, kind: .reminders) }
            }
            let result = runtime.executeJSXSyncForWidget("try{const r=await $reminders.items();$render(<text>{JSON.stringify(r)}</text>);}catch(e){$render(<text>{String(e)}</text>);}")
            XCTAssertNil(result.1); let xml = result.0.map { collectText($0) } ?? ""
            XCTAssertTrue(xml.contains("permission_denied")); XCTAssertFalse(xml.contains("Read a chapter"))
            XCTAssertFalse(f.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ScriptWidget.RemindersCache.") })
        }
    }

    func testRemindersUndeclaredNoListsAndInvalidOptionsNeverQueryProvider() throws {
        let f = try calendarSelectionFixture(), provider = RemindersFixtureProvider()
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        let undeclared = try remindersRuntime(f, provider: provider, declared: false).executeJSXSyncForWidget("let denied=0;for(const call of [()=>$reminders.items(),()=>$reminders.lists(),()=>$reminders.requestAuthorization()])try{await call();}catch(e){if(String(e).includes('permission_denied'))denied++;}$render(<text>{$reminders.authorizationStatus()+':'+denied}</text>);")
        XCTAssertNil(undeclared.1); XCTAssertTrue(undeclared.0.map { collectText($0).contains("undeclared:3") } == true)
        try ScriptWidgetCalendarSelection(calendarIDs: []).save(container: f.root, kind: .reminders)
        let none = try remindersRuntime(f, provider: provider).executeJSXSyncForWidget("const lists=await $reminders.lists();let denied=false;try{await $reminders.items();}catch(e){denied=String(e).includes('permission_denied');}$render(<text>{lists.length+':'+denied}</text>);")
        XCTAssertNil(none.1); XCTAssertTrue(none.0.map { collectText($0).contains("0:true") } == true)
        XCTAssertEqual(provider.fetches, 0)
    }
}


extension RuntimeExecutionTests {
    func testRemindersProjectionUsesSnapshotAndRechecksScopeBeforeCachedDelivery() throws {
        let f = try calendarSelectionFixture(), provider = RemindersFixtureProvider()
        defer { f.defaults.removePersistentDomain(forName: f.suite); try? FileManager.default.removeItem(at: f.root) }
        let source = "const r=await $reminders.items({start:'2026-02-03T00:00:00Z',end:'2026-02-04T00:00:00Z'});$render(<text>{JSON.stringify(r)}</text>);"
        XCTAssertNil(try remindersRuntime(f, provider: provider).executeJSXSyncForWidget(source).1)
        let env = ["widget-size": "medium", "timeline-date": "2026-02-03T12:00:00Z", "timeline-is-projection": "true"]
        let projected = try remindersRuntime(f, provider: provider, environments: env).executeJSXSyncForWidget(source)
        XCTAssertNil(projected.1); XCTAssertTrue(collectText(try XCTUnwrap(projected.0)).contains("cache")); XCTAssertEqual(provider.fetches, 1)
        var checks = 0
        provider.onStatus = {
            checks += 1
            if checks == 2 { try? ScriptWidgetCalendarSelection(calendarIDs: []).save(container: f.root, kind: .reminders) }
        }
        let guarded = try remindersRuntime(f, provider: provider, environments: env).executeJSXSyncForWidget("try{" + source + "}catch(e){$render(<text>{String(e)}</text>);}")
        XCTAssertNil(guarded.1); let text = collectText(try XCTUnwrap(guarded.0))
        XCTAssertTrue(text.contains("permission_denied")); XCTAssertFalse(text.contains("Read a chapter")); XCTAssertEqual(provider.fetches, 1)
        XCTAssertFalse(f.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ScriptWidget.RemindersCache.") })
    }
}


extension LibrarySessionExecutionTests {
    func testReminderActionWaitsForAsyncWriteAndReplaysDurably() throws {
        let session = try start(), manager = try XCTUnwrap(session.sourceManager)
        let package = manager.getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName)
        manifest.permissions = [.storage, .reminders, .remindersWrite]; manifest.minimumRuntimeVersion = "1.4"
        XCTAssertTrue(package.writeManifest(manifest).0)
        let source = """
        $render(<text>Entry feedback must not finish the action</text>);
        async function finishReminder() {
          const r = await $reminders.setCompleted({requestID:'550e8400-e29b-41d4-a716-446655440000',listID:'personal',id:'personal',completed:true});
          $storage.setString('write-result',r.id+':'+r.replayed);
          $render(<text>Done</text>);
        }
        """
        XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
        let provider = RemindersFixtureProvider()
        for replayed in [false, true] {
            let captured = try session.capture(name: packageName)
            let runtime = ScriptWidgetRuntime(package: captured.package, environments: ["widget-size": "action"], executionSnapshot: captured, isUserInitiatedAction: true)
            runtime.runningState?.remindersProviderForTesting = provider
            XCTAssertNil(runtime.executeJSXSyncForFunction(source, "finishReminder").1)
            XCTAssertEqual(try captured.context.defaults.readValue(forKey: captured.storageNamespace + "write-result") as? String, "personal:\(replayed)")
        }
        XCTAssertEqual(provider.writes, 1)
    }
    func testReminderWriteRejectsRenderingAndWrongList() throws {
        let session = try start(), package = try XCTUnwrap(session.sourceManager).getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName)
        manifest.permissions = [.storage, .reminders, .remindersWrite]; manifest.minimumRuntimeVersion = "1.4"
        XCTAssertTrue(package.writeManifest(manifest).0)
        let source = """
        async function createReminder() {
          try { await $reminders.create({requestID:'550e8400-e29b-41d4-a716-446655440001',listID:'work',title:'Read'}); }
          catch(e) { $storage.setString('write-error',String(e)); }
          $render(<text>Checked</text>);
        }
        """
        XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
        let provider = RemindersFixtureProvider()
        try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: container, kind: .reminders)
        for nativeAction in [false, true] {
            let captured = try session.capture(name: packageName)
            let runtime = ScriptWidgetRuntime(package: captured.package, environments: ["widget-size": "action", "action-id": "fake"], executionSnapshot: captured, isUserInitiatedAction: nativeAction)
            runtime.runningState?.remindersProviderForTesting = provider
            XCTAssertNil(runtime.executeJSXSyncForFunction(source, "createReminder").1)
            XCTAssertTrue((try captured.context.defaults.readValue(forKey: captured.storageNamespace + "write-error") as? String)?.contains("permission_denied") == true)
        }
        XCTAssertEqual(provider.writes, 0)
    }

    func testReminderWriteRequiresPermissionAndRechecksRevocationBeforeCommit() throws {
        let session = try start(), package = try XCTUnwrap(session.sourceManager).getScriptPackage(packageName: packageName)
        try ScriptWidgetCalendarSelection(calendarIDs: ["personal"]).save(container: container, kind: .reminders)
        let source = """
        async function createReminder() {
          try { await $reminders.create({requestID:'550e8400-e29b-41d4-a716-446655440002',listID:'personal',title:'Read'}); }
          catch(e) { $storage.setString('write-error',String(e)); }
        }
        """
        for declared in [false, true] {
            var manifest = WidgetPackageManifest.newProject(name: packageName)
            manifest.permissions = declared ? [.storage, .reminders, .remindersWrite] : [.storage, .reminders]
            manifest.minimumRuntimeVersion = "1.4"
            XCTAssertTrue(package.writeManifest(manifest).0)
            XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
            let captured = try session.capture(name: packageName), provider = RemindersFixtureProvider()
            if declared { provider.onMutate = { provider.status = "denied" } }
            let runtime = ScriptWidgetRuntime(package: captured.package, environments: ["widget-size": "action"], executionSnapshot: captured, isUserInitiatedAction: true)
            runtime.runningState?.remindersProviderForTesting = provider
            XCTAssertNil(runtime.executeJSXSyncForFunction(source, "createReminder").1)
            let error = try captured.context.defaults.readValue(forKey: captured.storageNamespace + "write-error") as? String
            XCTAssertTrue(error?.contains("permission_denied") == true, error ?? "missing error")
            XCTAssertEqual(provider.writes, 0)
        }
    }
}

private final class PhotosFixtureProvider: ScriptWidgetPhotosProviding {
    var authorization = "authorized"
    var reads = 0
    var removed = false
    var cloudOnly = false
    var sampleJPEG: Data?
    var onThumbnail: (() -> Void)?
    let ref = ScriptWidgetPhotoReference(id: "asset/one", revision: 100, width: 10, height: 10)
    func status() -> String { authorization }
    func references(selection: ScriptWidgetPhotoSelection, query: ScriptWidgetPhotoQuery) throws -> [ScriptWidgetPhotoReference] {
        removed || query.offset > 0 ? [] : [ref]
    }
    func thumbnail(_ reference: ScriptWidgetPhotoReference, deadline: Date) -> ScriptWidgetPhotoBytes? {
        reads += 1; onThumbnail?()
        if cloudOnly { return nil }
        if let sampleJPEG { return .init(reference: reference, jpeg: sampleJPEG) }
        #if os(macOS)
        let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<10 { for y in 0..<10 { representation.setColor(.green, atX: x, y: y) } }
        let data = representation.representation(using: .jpeg, properties: [:])!
        #else
        let data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).jpegData(withCompressionQuality: 0.6) { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        #endif
        return .init(reference: reference, jpeg: data)
    }
}

extension LibrarySessionExecutionTests {
    private func photoPackage() throws -> (ScriptWidgetLibrarySession, ScriptWidgetPackage) {
        let session = try start(), package = try XCTUnwrap(session.sourceManager).getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName); manifest.permissions = [.photos]; manifest.minimumRuntimeVersion = "1.4"
        XCTAssertTrue(package.writeManifest(manifest).0)
        try ScriptWidgetPhotoSelection(assetIDs: ["asset/one"], albumIDs: []).save(container: container, replacing: .empty)
        return (session, package)
    }
    private func photos(_ session: ScriptWidgetLibrarySession, _ provider: PhotosFixtureProvider, projection: Bool = false, options: String = "{}") throws -> String {
        let source = "try{const r=await $photos.items(\(options));$render(<text>{JSON.stringify(r)}</text>);}catch(e){$render(<text>{String(e)}</text>);}"
        let package = try XCTUnwrap(session.sourceManager).getScriptPackage(packageName: packageName)
        XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
        let captured = try session.capture(name: packageName)
        let runtime = ScriptWidgetRuntime(package: captured.package, environments: ["widget-size": "medium", "timeline-is-projection": projection ? "true" : "false"], executionSnapshot: captured)
        runtime.runningState?.photosProviderForTesting = provider
        let result = runtime.executeJSXSyncForWidget(source)
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        func text(_ element: ScriptWidgetRuntimeElement) -> String { (element.getChildren().compactMap { $0 as? String } + element.childrenAsElements().map(text)).joined() }
        return text(try XCTUnwrap(result.0))
    }
    func testPhotosReadBoundedThumbnailsAndReuseSnapshotForFutureEntries() throws {
        let (session, _) = try photoPackage(), provider = PhotosFixtureProvider()
        XCTAssertTrue(try photos(session, provider).contains("data:image/jpeg;base64,")); XCTAssertEqual(provider.reads, 1)
        let future = try photos(session, provider, projection: true)
        XCTAssertTrue(future.contains("cache")); XCTAssertEqual(provider.reads, 1)
        provider.removed = true
        XCTAssertTrue(try photos(session, provider, projection: true).contains("cache_miss"))
        XCTAssertFalse(try photos(session, provider).contains("data:image"))
    }
    func testPhotosLimitedAccessCloudOnlyAndRevocationDoNotExposeOldData() throws {
        let (session, _) = try photoPackage(), provider = PhotosFixtureProvider()
        provider.authorization = "limited"
        XCTAssertTrue(try photos(session, provider).contains("data:image"))
        provider.authorization = "denied"
        XCTAssertTrue(try photos(session, provider).contains("permission_denied"))
        provider.authorization = "limited"; provider.cloudOnly = true
        let unavailable = try photos(session, provider, options: "{maxAgeSeconds:0}")
        XCTAssertTrue(unavailable.contains("unavailableCount")); XCTAssertFalse(unavailable.contains("data:image"))
    }
    func testPhotosRejectUndeclaredScopeAndMidQuerySelectionChange() throws {
        let (session, package) = try photoPackage(), provider = PhotosFixtureProvider()
        provider.onThumbnail = { try? ScriptWidgetPhotoSelection.empty.save(container: self.container, replacing: .init(assetIDs: ["asset/one"], albumIDs: [])) }
        let changed = try photos(session, provider)
        XCTAssertTrue(changed.contains("scope_changed")); XCTAssertFalse(changed.contains("data:image"))
        var manifest = try XCTUnwrap(package.readManifest()); manifest.permissions = []
        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertTrue(try photos(session, provider).contains("permission_denied"))
        XCTAssertEqual(provider.reads, 1)
    }
}


#if os(iOS)
extension LibrarySessionExecutionTests {
    @MainActor
    func testExportPhotosTemplateFixtureSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_PHOTOS"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_PHOTOS for native Photos snapshots") }
        let output = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: base.appendingPathComponent("Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/Photo Album Rotator/main.jsx"), encoding: .utf8)
        let jpeg = try Data(contentsOf: base.appendingPathComponent("Web/preview-engine/test/fixtures/photo-landscape.jpg"))
        let (session, package) = try photoPackage()
        XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
        for mode in ["ready", "cloud", "denied"] {
            let provider = PhotosFixtureProvider(); provider.sampleJPEG = jpeg
            provider.cloudOnly = mode == "cloud"; provider.authorization = mode == "denied" ? "denied" : "limited"
            for (family, size) in [("small", CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
                let captured = try session.capture(name: packageName)
                let runtime = ScriptWidgetRuntime(package: captured.package, environments: ["widget-size":family], executionSnapshot: captured)
                runtime.runningState?.photosProviderForTesting = provider
                // Force a fresh snapshot between synthetic states.
                provider.onThumbnail = nil
                let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
                XCTAssertNil(result.1)
                let element = try XCTUnwrap(result.0)
                let context = ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Photos fixture",scriptParameter:"",package:captured.package,containerBackgroundElement:element)
                let renderer = ImageRenderer(content: BrowserPreviewSnapshotView(element:element,context:context,size:size).environment(\.colorScheme,.light))
                renderer.scale = 2
                try XCTUnwrap(renderer.uiImage?.pngData()).write(to:output.appendingPathComponent("\(mode)-\(family).png"))
            }
            // A permission loss invalidates the last owner's snapshot before
            // the next independent synthetic scenario.
            provider.authorization = "denied"; _ = try photos(session, provider)
            XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
        }
    }
}
#endif


#if os(iOS)
extension LibrarySessionExecutionTests {
    func testPhotoKitBridgeWithDisposableSeededSimulator() async throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_PHOTOS_SIMULATOR_PROBE"] == "1" else { throw XCTSkip("Run the dedicated Photos simulator probe with public sample artwork") }
        XCTAssertEqual(ScriptWidgetRuntimePhotos.systemAuthorizationStatus(), "authorized")
        XCTAssertEqual(ProcessInfo.processInfo.environment["SCRIPTWIDGET_PHOTOS_PROBE_DEVICE"], ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
        let available = PHAsset.fetchAssets(with: ScriptWidgetPhotosSystemProvider.options(limit: 64))
        var seeded: [PHAsset] = []
        available.enumerateObjects { candidate, _, _ in
            if PHAssetResource.assetResources(for: candidate).contains(where: { $0.originalFilename == "photo-landscape.jpg" }) { seeded.append(candidate) }
        }
        let asset = try XCTUnwrap(seeded.first, "Seed the dedicated simulator with the public sample JPEG")
        XCTAssertEqual(seeded.count, 1); XCTAssertEqual(asset.pixelWidth, 384); XCTAssertEqual(asset.pixelHeight, 256)
        let preview = await Task.detached {
            ScriptWidgetPhotosSystemProvider().thumbnail(.init(id: asset.localIdentifier, revision: 0, width: asset.pixelWidth, height: asset.pixelHeight), deadline: Date().addingTimeInterval(2), maximumSize: 128)
        }.value
        XCTAssertTrue(try XCTUnwrap(preview).valid)
        let (session, package) = try photoPackage()
        let selection = ScriptWidgetPhotoSelection(assetIDs: [asset.localIdentifier], albumIDs: [])
        try selection.save(container: container, replacing: .init(assetIDs: ["asset/one"], albumIDs: []))
        let source = """
        const result = await $photos.items({limit:1,maxAgeSeconds:0});
        $render(<text>{JSON.stringify({count:result.items.length,missing:result.unavailableCount,jpeg:result.items[0]?.image.startsWith('data:image/jpeg;base64,')})}</text>);
        """
        XCTAssertTrue(package.writeFile(relativePath: "main.jsx", content: source).0)
        let captured = try session.capture(name: packageName)
        let runtime = ScriptWidgetRuntime(package: captured.package, environments: ["widget-size":"medium"], executionSnapshot: captured)
        let result = await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
        XCTAssertNil(result.1, result.1?.displayMessage ?? "")
        let text = try XCTUnwrap(result.0).getChildren().compactMap { $0 as? String }.joined()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any])
        XCTAssertEqual(object["count"] as? Int, 1); XCTAssertEqual(object["missing"] as? Int, 0); XCTAssertEqual(object["jpeg"] as? Bool, true)
    }
}
#endif

private final class ExpandedHealthFixtureProvider: ScriptWidgetExpandedHealthProviding {
    var available = true
    var calls = 0
    var empty = false
    var failing = false
    var onFetch: (() -> Void)?
    func isAvailable() -> Bool { available }
    func fetch(_ query: ScriptWidgetHealthReadQuery, session: ScriptWidgetExecutionSession, completion: @escaping (Result<ScriptWidgetHealthReadout, Error>) -> Void) {
        calls += 1
        if failing { completion(.failure(ScriptWidgetHealthReadError.queryFailed)); return }
        let result: ScriptWidgetHealthReadout
        switch query.kind {
        case .sleepSummary:
            result = .sleep(empty ? [] : [
                .init(start:query.end.addingTimeInterval(-8*3600),end:query.end.addingTimeInterval(-3.5*3600),stage:.core,source:"fixture"),
                .init(start:query.end.addingTimeInterval(-3.5*3600),end:query.end.addingTimeInterval(-2*3600),stage:.deep,source:"fixture"),
                .init(start:query.end.addingTimeInterval(-2*3600),end:query.end.addingTimeInterval(-1800),stage:.rem,source:"fixture")],truncated:false)
        case .activitySummary:
            result = .activity(empty ? nil : .init(moveMode:"activeEnergy",move:480,moveGoal:600,exercise:26,exerciseGoal:30,stand:9,standGoal:12))
        case .workouts:
            result = .workouts(empty ? [] : [.init(id:"550e8400-e29b-41d4-a716-446655440000",activity:"running",start:query.end.addingTimeInterval(-3600),end:query.end.addingTimeInterval(-900),duration:2700,energyKcal:285,distanceMeters:5200)],truncated:false)
        }
        onFetch?(); completion(.success(result))
    }
}
extension LibrarySessionExecutionTests {
    private func expandedHealth(_ provider: ExpandedHealthFixtureProvider, code: String, permissions: [WidgetPackagePermission] = [.health], environments: [String:String] = [:]) throws -> String {
        try autoreleasepool {
        let session = try start(), package = try XCTUnwrap(session.sourceManager).getScriptPackage(packageName: packageName)
        var manifest = WidgetPackageManifest.newProject(name: packageName); manifest.permissions = permissions; manifest.minimumRuntimeVersion = "1.4"
        XCTAssertTrue(package.writeManifest(manifest).0);XCTAssertTrue(package.writeFile(relativePath:"main.jsx",content:code).0)
        let captured = try session.capture(name:packageName)
        let runtime = ScriptWidgetRuntime(package:captured.package,environments:environments,executionSnapshot:captured)
        runtime.runningState?.expandedHealthProviderForTesting = provider
        let result = runtime.executeJSXSyncForWidget(code)
        XCTAssertNil(result.1,result.1?.displayMessage ?? "")
        func text(_ element: ScriptWidgetRuntimeElement) -> String { (element.getChildren().compactMap{$0 as? String}+element.childrenAsElements().map(text)).joined() }
        return text(try XCTUnwrap(result.0))
        }
    }
    func testExpandedHealthUsesRealBridgeForAllThreeTypedReadoutsWithoutSavingReadings() throws {
        let provider=ExpandedHealthFixtureProvider()
        let output=try expandedHealth(provider,code:"const sleep=await $health.sleepSummary(),activity=await $health.activitySummary(),workouts=await $health.workouts();$render(<text>{JSON.stringify({sleep,activity,workouts,status:$health.authorizationStatus()})}</text>);")
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
        XCTAssertEqual((object["sleep"] as? [String:Any])?["totalSleepSeconds"] as? Double,27000)
        XCTAssertEqual((object["activity"] as? [String:Any])?["hasSamples"] as? Bool,true)
        XCTAssertEqual(((object["workouts"] as? [String:Any])?["items"] as? [[String:Any]])?.count,1)
        XCTAssertEqual(object["status"] as? String,"notDisclosed");XCTAssertEqual(provider.calls,3)
        let session=try ScriptWidgetLibrarySession(profiles:profiles),captured=try session.capture(name:packageName)
        let records = try captured.context.defaults.values(in:captured.storageNamespace)
        XCTAssertEqual(records.map { $0.0 }, [captured.storageNamespace + "count"])
        XCTAssertEqual(records.first?.1 as? String, "7")
    }
    func testExpandedHealthRejectsMissingPermissionFutureAndLiveActivityBeforeProviderCalls() throws {
        let source="let errors=[];for(const name of ['sleepSummary','activitySummary','workouts']){try{await $health[name]();}catch(e){errors.push(String(e));}}$render(<text>{errors.join('|')}</text>);"
        let provider=ExpandedHealthFixtureProvider()
        XCTAssertTrue(try expandedHealth(provider,code:source,permissions:[]).contains("permission_denied"))
        for env in [["timeline-is-projection":"true"],["widget-size":"live-activity"]] {
            XCTAssertTrue(try expandedHealth(provider,code:source,environments:env).contains("timeline_read_only"))
        }
        XCTAssertEqual(provider.calls,0)
    }
    func testExpandedHealthRechecksAvailabilityAndSharesTheQueryBudget() throws {
        let provider=ExpandedHealthFixtureProvider()
        provider.onFetch={provider.available=false}
        XCTAssertTrue(try expandedHealth(provider,code:"try{await $health.sleepSummary();$render(<text>bad</text>);}catch(e){$render(<text>{String(e)}</text>);}").contains("unavailable"))
        provider.available=true;provider.onFetch=nil;provider.calls=0
        let output=try expandedHealth(provider,code:"let error='';try{for(let i=0;i<9;i++)await $health.activitySummary();}catch(e){error=String(e);}$render(<text>{error}</text>);")
        XCTAssertTrue(output.contains("query_limit"));XCTAssertEqual(provider.calls,8)
    }
    func testBasicHealthCannotReadOrPromptFromLiveActivityPresentations() throws {
        let output=try expandedHealth(ExpandedHealthFixtureProvider(),code:"let count=0;for(const name of ['requestAuthorization','stepCountToday','activeEnergyToday','heartRateLatest']){try{await $health[name]();}catch(e){if(String(e).includes('timeline_read_only'))count++;}}$render(<text>{String(count)}</text>);",environments:["widget-size":"live-activity"])
        XCTAssertEqual(output,"4")
    }
}

extension LibrarySessionExecutionTests {
    private func healthOverviewPackage() throws -> (ScriptWidgetLibrarySession, ScriptWidgetPackage, String) {
        let session=try start(),package=try XCTUnwrap(session.sourceManager).getScriptPackage(packageName:packageName)
        let template=ScriptWidgetPackage(bundle:"Script",relativePath:"template/Health Overview")
        let source=try XCTUnwrap(template.readMainFile().0)
        var manifest=WidgetPackageManifest.newProject(name:packageName);manifest.permissions=[.health];manifest.minimumRuntimeVersion="1.4";manifest.supportedFamilies=WidgetPackageFamily.allCases
        XCTAssertTrue(package.writeManifest(manifest).0);XCTAssertTrue(package.writeFile(relativePath:"main.jsx",content:source).0)
        return (session,package,source)
    }
    private func healthFixture(_ state: String) -> ExpandedHealthFixtureProvider {
        let provider=ExpandedHealthFixtureProvider();provider.empty=state=="empty";provider.available=state != "unavailable";provider.failing=state=="error";return provider
    }
    func testExpandedHealthTemplateNativeAndWebCanonicalTrees() throws {
        let (session,_,source)=try healthOverviewPackage()
        var trees:[String:String]=[:]
        for state in ["ready","empty","unavailable","error"] { for mode in ["overview","sleep","activity","workouts"] { for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
            weak var resources: ScriptWidgetExecutionFiles?
            try autoreleasepool {
                let snapshot=try session.capture(name:packageName),runtime=ScriptWidgetRuntime(package:snapshot.package,environments:["widget-size":family,"widget-param":mode],executionSnapshot:snapshot,isDarkMode:false)
                resources=snapshot.package.executionFiles
                runtime.runningState?.expandedHealthProviderForTesting=healthFixture(state)
                let result=runtime.executeJSXSyncForWidget(source)
                XCTAssertNil(result.1,"\(state)/\(mode)/\(family): \(result.1?.displayMessage ?? "")")
                trees["\(state)/\(mode)/\(family)"]=ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(result.0))
            }
            let deadline=Date().addingTimeInterval(1)
            while resources != nil && Date()<deadline { Thread.sleep(forTimeInterval:0.001) }
            XCTAssertNil(resources,"Each completed fixture render must release its snapshot lease")
        } } }
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output=root.appendingPathComponent("Web/preview-engine/test/parity/health-overview-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_HEALTH_OVERVIEW_PARITY"]=="1" {
            let data=try JSONSerialization.data(withJSONObject:["generator":"Native managed JavaScriptCore with deterministic Health provider; no real readings", "trees":trees],options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
            try data.write(to:output,options:.atomic)
        } else {
            let expected=try XCTUnwrap((try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])?["trees"] as? [String:String])
            XCTAssertEqual(trees,expected)
        }
    }
    #if os(iOS)
    @MainActor
    func testExportExpandedHealthNativeSnapshots() async throws {
        guard let directory=ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_EXPANDED_HEALTH"] else { throw XCTSkip("Set SCRIPTWIDGET_EXPORT_EXPANDED_HEALTH for isolated native Health captures") }
        let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let (session,_,source)=try healthOverviewPackage()
        for state in ["ready","empty","unavailable","error"] { for mode in ["overview","sleep","activity","workouts"] where state=="ready" || mode=="overview" { for (family,size) in [("small",CGSize(width:158,height:158)),("medium",CGSize(width:338,height:158)),("large",CGSize(width:338,height:354))] {
            let snapshot=try session.capture(name:packageName),runtime=ScriptWidgetRuntime(package:snapshot.package,environments:["widget-size":family,"widget-param":mode],executionSnapshot:snapshot,isDarkMode:false)
            runtime.runningState?.expandedHealthProviderForTesting=healthFixture(state)
            let result=await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
            XCTAssertNil(result.1)
            let element=try XCTUnwrap(result.0),context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:"Health fixture",scriptParameter:mode,package:snapshot.package,containerBackgroundElement:element)
            let renderer=ImageRenderer(content:BrowserPreviewSnapshotView(element:element,context:context,size:size).environment(\.colorScheme,.light));renderer.scale=2
            try XCTUnwrap(renderer.uiImage?.pngData()).write(to:output.appendingPathComponent("\(state)-\(mode)-\(family).png"))
        } } }
    }
    #endif
}
