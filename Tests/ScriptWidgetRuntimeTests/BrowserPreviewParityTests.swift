//
//  BrowserPreviewParityTests.swift
//  ScriptWidgetRuntimeTests
//
//  Emits the canonical resolved-element-tree JSON that the browser preview
//  engine (Web/preview-engine) must reproduce byte for byte. Run with
//  TEST_RUNNER_SCRIPTWIDGET_UPDATE_PARITY=1 to rewrite
//  Web/preview-engine/test/parity/native-trees.json, then run
//  `npm test` in Web/preview-engine to compare.
//

import Foundation
import JavaScriptCore
import XCTest
import ZipArchive
@testable import ScriptWidget

/// Canonical tree JSON shared with `encodeElement` in Web/preview-engine/src/kernel.js.
/// Numbers are formatted by JavaScriptCore's Number#toString so both hosts
/// use the ECMAScript algorithm; keys are sorted by UTF-16 code units.
enum ScriptWidgetElementTreeJSON {
    private static let numberContext = JSContext()!

    static func encode(_ element: ScriptWidgetRuntimeElement) -> String {
        let tag = element.tagAsString().map(string) ?? #"{"$function":true}"#
        let props = element.props.map(dictionary) ?? "null"
        let children = element.children.map { "[" + $0.map(value).joined(separator: ",") + "]" } ?? "null"
        return #"{"$element":"# + tag + #","props":"# + props + #","children":"# + children + "}"
    }

    static func value(_ value: Any) -> String {
        switch value {
        case let element as ScriptWidgetRuntimeElement: return encode(element)
        case is NSNull: return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return self.number(number.doubleValue)
        case let text as String: return string(text)
        case let date as Date: return #"{"$date":"# + number(date.timeIntervalSince1970 * 1000) + "}"
        case let array as [Any]: return "[" + array.map(self.value).joined(separator: ",") + "]"
        case let map as [AnyHashable: Any]: return #"{"$dict":"# + dictionary(map) + "}"
        default: return #"{"$unknown":"# + string(String(describing: type(of: value))) + "}"
        }
    }

    static func dictionary(_ map: [AnyHashable: Any]) -> String {
        let keys = map.keys.map { "\($0.base)" }
        let sorted = keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        var lookup: [String: Any] = [:]
        for (key, item) in map { lookup["\(key.base)"] = item }
        return "{" + sorted.map { string($0) + ":" + value(lookup[$0]!) }.joined(separator: ",") + "}"
    }

    static func number(_ double: Double) -> String {
        if double.isNaN { return #"{"$number":"NaN"}"# }
        if double == .infinity { return #"{"$number":"Infinity"}"# }
        if double == -.infinity { return #"{"$number":"-Infinity"}"# }
        if double == 0, double.sign == .minus { return #"{"$number":"-0"}"# }
        return JSValue(double: double, in: numberContext).toString()
    }

    /// JSON.stringify string escaping, including lone-surrogate escapes.
    static func string(_ text: String) -> String {
        var result = "\""
        let units = Array(text.utf16)
        var index = 0
        func hex(_ unit: UInt16) -> String {
            let digits = String(unit, radix: 16)
            return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
        }
        while index < units.count {
            let unit = units[index]
            switch unit {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0..<0x20: result += hex(unit)
            case 0xD800...0xDBFF:
                if index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) {
                    result += String(utf16CodeUnits: [unit, units[index + 1]], count: 2)
                    index += 1
                } else {
                    result += hex(unit)
                }
            case 0xDC00...0xDFFF: result += hex(unit)
            default: result += String(utf16CodeUnits: [unit], count: 1)
            }
            index += 1
        }
        return result + "\""
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// Device profiles parsed from Web/preview-engine/src/render/profiles.js so
/// the native and web snapshots always use the same widget sizes.
enum BrowserPreviewSnapshotProfile {
    struct Render {
        let profile: String
        let family: String
        let size: CGSize
        /// Snapshot name suffix; the default profile keeps the historical names.
        var suffix: String { profile == defaultProfile ? "@\(family)" : "@\(family)~\(profile)" }
    }

    static let defaultProfile = "iphone-393"

    /// Every profile and family, skipping sizes another profile already
    /// renders (iPad small equals the 430-point iPhone small) and accessory
    /// families outside the default profile (they share one size).
    static func renders(profilesSource: String) -> [Render] {
        func pairs(_ text: String) -> [(String, CGSize)] {
            let regex = try! NSRegularExpression(pattern: #"(\w+): \[(\d+), (\d+)\]"#)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                let value = { (index: Int) in String(text[Range(match.range(at: index), in: text)!]) }
                return (value(1), CGSize(width: Double(value(2))!, height: Double(value(3))!))
            }
        }
        let accessoryLine = profilesSource.components(separatedBy: "\n").first { $0.hasPrefix("const accessories") } ?? ""
        let accessories = pairs(accessoryLine)
        let profileRegex = try! NSRegularExpression(pattern: #"\"?([\w-]+)\"?: \{ label: [^\n]*"#)
        var result: [Render] = []
        var seen = Set<String>()
        for match in profileRegex.matches(in: profilesSource, range: NSRange(profilesSource.startIndex..., in: profilesSource)) {
            let line = String(profilesSource[Range(match.range, in: profilesSource)!])
            let profile = String(profilesSource[Range(match.range(at: 1), in: profilesSource)!])
            // Native snapshots come from the iOS simulator; macOS has its own app.
            guard !line.contains("platform: \"macos\"") else { continue }
            var families = pairs(line)
            if line.contains("...accessories") && profile == defaultProfile { families += accessories }
            for (family, size) in families {
                let key = "\(family) \(Int(size.width))x\(Int(size.height))"
                guard seen.insert(key).inserted else { continue }
                result.append(Render(profile: profile, family: family, size: size))
            }
        }
        return result
    }
}

/// Mirrors ScriptWidgetWidgetElementRootView: the root element's background
/// becomes the widget container background and the root view is centered.
struct BrowserPreviewSnapshotView: View {
    let element: ScriptWidgetRuntimeElement
    let context: ScriptWidgetElementContext
    let size: CGSize

    var body: some View {
        let background = element.getPropString("background").map(ScriptWidgetAttributeColor.init) ?? ScriptWidgetAttributeColor()
        ZStack {
            if let color = background.color { color } else if let gradient = background.gradient { gradient } else { Color(uiColor: .systemBackground) }
            ScriptWidgetElementView(element: element, context: context)
        }
        .frame(width: size.width, height: size.height)
    }
}
#endif

final class BrowserPreviewParityTests: XCTestCase {
    private var preferenceFixtures: [(name: String, directory: URL)] = []

    override func tearDown() {
        for fixture in preferenceFixtures {
            UserDefaults(suiteName: fixture.name)?.removePersistentDomain(forName: fixture.name)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        preferenceFixtures.removeAll()
        super.tearDown()
    }

    /// Match Web's fresh storage per execution without reading or modifying
    /// earlier runs' app-group records (including old automatic counters).
    private func isolateStorage(of runtime: ScriptWidgetRuntime) throws {
        #if DEBUG
        let name = "app.scriptwidget.parity.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ParityStorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        preferenceFixtures.append((name, directory))
        runtime.runningState?.storageDefaultsForTesting = defaults
        runtime.runningState?.storageContainerForTesting = directory
        #else
        throw XCTSkip("Corpus execution requires the DEBUG isolated storage backend")
        #endif
    }
    func testCorpusStorageStartsFreshWithoutClearingEarlierRuns() throws {
        let package = ScriptWidgetPackage(path: FileManager.default.temporaryDirectory.appendingPathComponent("IsolatedCorpus-\(UUID().uuidString)"), readonly: true)
        let first = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium", "widget-param": ""])
        try isolateStorage(of: first)
        let saved = first.executeJSXSyncForWidget("$storage.setString('probe','saved'); $render(<text>{$storage.getString('probe')}</text>);")
        XCTAssertNil(saved.1)
        XCTAssertEqual(try XCTUnwrap(saved.0).getChildren().first as? String, "saved")
        let second = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium", "widget-param": ""])
        try isolateStorage(of: second)
        let empty = second.executeJSXSyncForWidget("$render(<text>{$storage.getString('probe')}</text>);")
        XCTAssertNil(empty.1)
        XCTAssertEqual(try XCTUnwrap(empty.0).getChildren().first as? String, "")
        #if DEBUG
        XCTAssertNotEqual(first.runningState?.storageContainerForTesting, second.runningState?.storageContainerForTesting)
        XCTAssertFalse(first.runningState?.storageDefaultsForTesting === second.runningState?.storageDefaultsForTesting)
        #endif
    }

    #if os(iOS)
    /// Writes native PNGs for the corpus, Web/preview-engine/test/render/cases.json,
    /// and test/catalog/catalog.json
    /// to Web/preview-engine/dist/native-snapshots when
    /// TEST_RUNNER_SCRIPTWIDGET_EXPORT_SNAPSHOTS=1.
    @MainActor
    func testExportNativeSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_EXPORT_SNAPSHOTS=1 to export native snapshots")
        }
        let output = Self.repositoryRoot.appendingPathComponent("Web/preview-engine/dist/native-snapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var prelude = try String(contentsOf: Self.parityDirectory.appendingPathComponent("prelude.js"), encoding: .utf8)
        // Keep the real appearance captured under each job's trait collection;
        // the shared tree-parity fixture deliberately fixes it to light.
        prelude = prelude.replacingOccurrences(of: "isdarkmode: function () { return false; },", with: "isdarkmode: $device.isdarkmode,")
        // Screenshot-only fixture data, isolated from the app's persistent storage.
        if let fixturePath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_FIXTURE"], !fixturePath.isEmpty {
            prelude += "\n" + (try String(contentsOfFile: fixturePath, encoding: .utf8)) + "\n"
        }
        let profilesSource = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Web/preview-engine/src/render/profiles.js"), encoding: .utf8)
        let allRenders = BrowserPreviewSnapshotProfile.renders(profilesSource: profilesSource)
        // SCRIPTWIDGET_EXPORT_PROFILES=all exports every size; the default is
        // the 393-point iPhone small, medium, and large.
        let everySize = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_PROFILES"] == "all"
        let renders = everySize ? allRenders : allRenders.filter { $0.profile == BrowserPreviewSnapshotProfile.defaultProfile && ["small", "medium", "large"].contains($0.family) }
        let selected = Set((ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_PACKAGES"] ?? "").split(separator: "|").map(String.init))
        var jobs: [(name: String, render: BrowserPreviewSnapshotProfile.Render, source: String, package: ScriptWidgetPackage, dark: Bool)] = []
        for (name, directory) in try Self.corpusPackages() {
            if !selected.isEmpty && !selected.contains(name) { continue }
            let package = ScriptWidgetPackage(path: directory, readonly: true)
            guard let source = package.readMainFile().0, !Self.usesLiveData(source) else { continue }
            let appearances = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_APPEARANCES"] == "all" ? [false, true] : [false]
            for render in renders {
                for dark in appearances {
                    jobs.append(("\(name)\(render.suffix)\(dark ? "--dark" : "")", render, prelude + source, package, dark))
                }
            }
        }
        let casesURL = Self.repositoryRoot.appendingPathComponent("Web/preview-engine/test/render/cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as? [[String: Any]])
        let scratch = ScriptWidgetPackage(path: FileManager.default.temporaryDirectory, readonly: true)
        for item in cases where selected.isEmpty {
            let family = item["size"] as? String ?? "medium"
            let profile = item["profile"] as? String ?? BrowserPreviewSnapshotProfile.defaultProfile
            guard let render = allRenders.first(where: { $0.profile == profile && $0.family == family }) else { continue }
            jobs.append(("case/\(item["name"] as? String ?? "")\(render.suffix)", render, prelude + (item["source"] as? String ?? ""), scratch, item["dark"] as? Bool ?? false))
        }
        // The component catalog (test/catalog/catalog.json), one size per item.
        let catalogURL = Self.repositoryRoot.appendingPathComponent("Web/preview-engine/test/catalog/catalog.json")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [[String: Any]])
        for item in catalog where selected.isEmpty {
            let family = item["size"] as? String ?? "medium"
            guard let render = allRenders.first(where: { $0.profile == BrowserPreviewSnapshotProfile.defaultProfile && $0.family == family }) else { continue }
            jobs.append(("catalog/\(item["id"] as? String ?? "")\(render.suffix)", render, prelude + (item["source"] as? String ?? ""), scratch, item["dark"] as? Bool ?? false))
        }
        // Absolute <date> styles use the parity prelude's fixed clock.
        ScriptWidgetRenderClock.fixedNow = Date(timeIntervalSince1970: 1_767_268_800)
        defer { ScriptWidgetRenderClock.fixedNow = nil }
        let filter = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_FILTER"] ?? ""
        for job in jobs where filter.isEmpty || job.name.hasPrefix(filter) {
            var runtime: ScriptWidgetRuntime!
            UITraitCollection(userInterfaceStyle: job.dark ? .dark : .light).performAsCurrent {
                runtime = ScriptWidgetRuntime(package: job.package, environments: ["widget-size": job.render.family, "widget-param": ""])
            }
            try isolateStorage(of: runtime)
            let result = await Task.detached { runtime.executeJSXSyncForWidget(job.source) }.value
            guard let element = result.0 else { continue }
            let context = ScriptWidgetElementContext(runtime: runtime, debugMode: false, scriptName: job.name, scriptParameter: "",
                                                     package: job.package, containerBackgroundElement: element)
            let data: Data
            if ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_HOSTED_CONTROLS"] == "1" {
                // ImageRenderer cannot capture UIKit-backed controls reliably.
                // Use the actual hosted hierarchy for native control QA.
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: job.render.size)
                let controller = UIHostingController(rootView: BrowserPreviewSnapshotView(element: element, context: context, size: job.render.size)
                    .environment(\.colorScheme, job.dark ? .dark : .light).ignoresSafeArea())
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true; previous?.makeKey() }
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                data = try XCTUnwrap(rendered.pngData())
            } else {
                let renderer = ImageRenderer(content: BrowserPreviewSnapshotView(element: element, context: context, size: job.render.size)
                    .environment(\.colorScheme, job.dark ? .dark : .light))
                // Optional high-resolution native captures for App Store artwork.
                let requestedScale = Double(ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_SCALE"] ?? "2") ?? 2
                renderer.scale = CGFloat(min(4, max(1, requestedScale)))
                guard let rendered = renderer.uiImage?.pngData() else { continue }
                data = rendered
            }
            let fileName = job.name.replacingOccurrences(of: "/", with: "__").replacingOccurrences(of: " ", with: "_") + ".png"
            try data.write(to: output.appendingPathComponent(fileName), options: .atomic)
        }
    }
    #endif


    #if os(iOS)
    /// Prints Label row sizes next to HStacks of the same icon and title
    /// aligned at center and at the first text baseline, when
    /// TEST_RUNNER_SCRIPTWIDGET_PRINT_LABELS=1 (renderer calibration).
    @MainActor
    func testPrintLabelMetrics() throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_PRINT_LABELS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_PRINT_LABELS=1 to print label metrics")
        }
        func size(_ view: some View) -> CGSize {
            UIHostingController(rootView: view.fixedSize()).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        }
        for font in [("body", Font.body), ("caption", Font.caption), ("headline", Font.headline), ("size17", Font.system(size: 17))] {
            for name in ["sunrise.fill", "battery.100", "star.fill", "calendar", "heart.fill", "alarm", "clock", "bolt.fill"] {
                let label = size(Label("Battery", systemImage: name).font(font.1))
                let centered = size(HStack(alignment: .center) { Image(systemName: name); Text("Battery") }.font(font.1))
                let baseline = size(HStack(alignment: .firstTextBaseline) { Image(systemName: name); Text("Battery") }.font(font.1))
                let icon = size(Image(systemName: name).font(font.1))
                print("LABEL \(font.0) \(name) label \(label.width)x\(label.height) centered \(centered.width)x\(centered.height) baseline \(baseline.width)x\(baseline.height) icon \(icon.width)x\(icon.height)")
            }
        }
    }
    #endif

    #if os(iOS)
    /// Prints SwiftUI's first text baseline for sizes and text styles when
    /// TEST_RUNNER_SCRIPTWIDGET_PRINT_BASELINES=1 (renderer calibration).
    @MainActor
    func testPrintTextBaselines() throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_PRINT_BASELINES"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_PRINT_BASELINES=1 to print text baselines")
        }
        // The ink bottom of "H" at 8x is the baseline (H has no descender).
        func baseline(_ font: Font) -> (CGFloat, CGFloat) {
            let renderer = ImageRenderer(content: Text("H").font(font).fixedSize())
            renderer.scale = 8
            guard let image = renderer.cgImage else { return (0, 0) }
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var bottom = 0
            for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 { bottom = max(bottom, y + 1) } }
            return (CGFloat(bottom) / 8, CGFloat(height) / 8)
        }
        var lines: [String] = []
        for size in 6...80 { let (b, h) = baseline(.system(size: CGFloat(size))); lines.append("size \(size) \(b) \(h)") }
        let styles: [(String, Font)] = [("largeTitle", .largeTitle), ("title", .title), ("title2", .title2), ("title3", .title3), ("headline", .headline), ("body", .body), ("callout", .callout), ("subheadline", .subheadline), ("footnote", .footnote), ("caption", .caption), ("caption2", .caption2)]
        for (name, font) in styles { let (b, h) = baseline(font); lines.append("style \(name) \(b) \(h)") }
        let output = Self.repositoryRoot.appendingPathComponent("Web/preview-engine/dist/native-baselines.txt")
        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    /// Writes the default VStack spacing between a shape and text (both
    /// orders) for sizes 1...80 and every text style to
    /// dist/native-spacing.json when TEST_RUNNER_SCRIPTWIDGET_PRINT_SPACING=1.
    @MainActor
    func testPrintTextSpacing() throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_PRINT_SPACING"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SCRIPTWIDGET_PRINT_SPACING=1 to measure spacing")
        }
        // Stack heights minus their parts give the default spacing.
        // Rendered at 8x to read the spacing to an eighth of a point.
        func height<V: View>(_ view: V) -> Double {
            let renderer = ImageRenderer(content: view.fixedSize())
            renderer.scale = 8
            return Double(renderer.cgImage?.height ?? 0) / 8
        }
        func gaps(_ font: Font) -> [Double] {
            let text = height(Text("Hxg").font(font))
            let shapeAbove = height(VStack { Rectangle().frame(width: 20, height: 4); Text("Hxg").font(font) }) - text - 4
            let textAbove = height(VStack { Text("Hxg").font(font); Rectangle().frame(width: 20, height: 4) }) - text - 4
            return [shapeAbove, textAbove]
        }
        var sizes: [[Double]] = []
        for size in 1...80 { sizes.append(gaps(.system(size: CGFloat(size)))) }
        let styles: [(String, Font)] = [("largeTitle", .largeTitle), ("title", .title), ("title2", .title2), ("title3", .title3), ("headline", .headline), ("body", .body), ("callout", .callout), ("subheadline", .subheadline), ("footnote", .footnote), ("caption", .caption), ("caption2", .caption2)]
        func width<V: View>(_ view: V) -> Double {
            let renderer = ImageRenderer(content: view.fixedSize())
            renderer.scale = 8
            return Double(renderer.cgImage?.width ?? 0) / 8
        }
        // Other pairings at a few sizes: [size, image above text, text above
        // image, image above shape, HStack text-text, image-text, shape-text,
        // shape above image, image above image].
        var pairs: [[Double]] = []
        for size in [10, 13, 17, 22, 28, 34] as [CGFloat] {
            let font = Font.system(size: size)
            let text = Text("Hxg").font(font), image = Image(systemName: "star.fill").font(font)
            let shape = Rectangle().frame(width: 20, height: 4)
            let th = height(text), ih = height(image), tw = width(text), iw = width(image)
            pairs.append([Double(size),
                          height(VStack { image; text }) - ih - th,
                          height(VStack { text; image }) - ih - th,
                          height(VStack { image; shape }) - ih - 4,
                          width(HStack { text; text }) - 2 * tw,
                          width(HStack { image; text }) - iw - tw,
                          width(HStack { Rectangle().frame(width: 20, height: 4); text }) - 20 - tw,
                          height(VStack { shape; image }) - ih - 4,
                          height(VStack { image; image }) - 2 * ih])
        }
        // Line pitch: the height a second line adds, for sizes and styles.
        func pitch(_ font: Font) -> Double { height(Text("Hxg\nHxg").font(font)) - height(Text("Hxg").font(font)) }
        let pitches: [String: Any] = ["sizes": (1...80).map { pitch(.system(size: CGFloat($0))) }, "styles": Dictionary(uniqueKeysWithValues: styles.map { ($0.0, pitch($0.1)) })]
        let json: [String: Any] = ["sizes": sizes, "pairs": pairs, "pitches": pitches, "styles": Dictionary(uniqueKeysWithValues: styles.map { ($0.0, gaps($0.1)) })]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: Self.repositoryRoot.appendingPathComponent("Web/preview-engine/dist/native-spacing.json"))
    }
    #endif

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let parityDirectory = repositoryRoot.appendingPathComponent("Web/preview-engine/test/parity")

    /// Package directories shared with Web/preview-engine/test/parity/corpus.js.
    static func corpusPackages() throws -> [(name: String, directory: URL)] {
        let roots = [
            ("api", "Shared/ScriptWidgetRuntime/Resource/Script.bundle/api"),
            ("component", "Shared/ScriptWidgetRuntime/Resource/Script.bundle/component"),
            ("template", "Shared/ScriptWidgetRuntime/Resource/Script.bundle/template"),
            ("gallery", "Gallery/widgets"),
        ]
        var result: [(String, URL)] = []
        for (prefix, relative) in roots {
            let root = repositoryRoot.appendingPathComponent(relative)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
            for name in names {
                let directory = root.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("main.jsx").path) else { continue }
                result.append(("\(prefix)/\(name)", directory))
            }
        }
        return result
    }

    static func usesLiveData(_ source: String) -> Bool {
        // Scheduled templates use dedicated fixed-date/slot parity fixtures.
        source.contains("$getenv(\"timeline-date\")") || source.contains("fetch(") || source.contains("$http.") || source.contains("$location.") ||
            source.contains("$health.") || source.contains("$calendar.") || source.contains("$reminders.") || source.contains("$photos.") || source.contains("$services.") || source.contains("$music.") || source.contains("$dataSource.") || source.contains("$icloud.") || source.contains("cloudHydration.")
    }

    private func errorKind(_ error: ScriptWidgetError) -> String {
        switch error {
        case .undefinedRender: return "undefinedRender"
        case .internalError: return "internalError"
        case .transformError: return "transformError"
        case .scriptError: return "scriptError"
        case .scriptException: return "scriptException"
        case .resourceLimit: return "resourceLimit"
        }
    }

    /// Web/preview-engine writes this .swt with the Studio export code; iPhone
    /// must accept it with the same preflight, extraction, and validation.
    func testWebExportedPackageImportsNatively() throws {
        try skipUnlessRepositoryCheckout(Self.repositoryRoot)
        let archive = Self.repositoryRoot.appendingPathComponent("Web/preview-engine/test/fixtures/web-export.swt")
        XCTAssertNil(ScriptPackageArchivePreflight.validate(archive))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("web-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertTrue(SSZipArchive.unzipFile(atPath: archive.path, toDestination: destination.path))
        let root = destination.appendingPathComponent("Web Export Fixture")
        let package = ScriptWidgetPackage(path: root, readonly: true)
        let manifest = try XCTUnwrap(package.readManifest())
        XCTAssertEqual(manifest.id, "web.export.fixture")
        XCTAssertTrue(WidgetPackageManifestValidator.validate(manifest, package: package).isValid)
        XCTAssertNotNil(package.getImage("dot"))
        let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": "small", "widget-param": ""])
        let (element, error) = runtime.executeJSXSyncForWidget(try XCTUnwrap(package.readMainFile().0))
        XCTAssertNil(error)
        XCTAssertEqual(element?.tagAsString(), "vstack")
    }

    func testFontWeightAndDesignPropertiesAreRead() {
        let legacy = ScriptWidgetRuntimeElement(tagString: "text", props: ["font": "title", "weight": "bold", "fontDesign": "rounded"], children: ["x"])
        XCTAssertEqual(ScriptWidgetAttributeFontModifier(legacy).weight, .bold)
        XCTAssertEqual(ScriptWidgetAttributeFontModifier(legacy).design, .rounded)
        let both = ScriptWidgetRuntimeElement(tagString: "text", props: ["weight": "bold", "fontWeight": "light"], children: ["x"])
        XCTAssertEqual(ScriptWidgetAttributeFontModifier(both).weight, .light)
        let gaugeLabel = ScriptWidgetRuntimeElement(tagString: "gauge", props: ["fontWeight": "bold"], children: [])
        XCTAssertNil(ScriptWidgetAttributeFontModifier(gaugeLabel, fontField: "labelFont").weight)
        XCTAssertNil(ScriptWidgetAttributeFontModifier(ScriptWidgetRuntimeElement(tagString: "text", props: ["fontWeight": "huge"], children: [])).weight)
    }

    func testCanonicalEncodingMatchesJavaScriptSemantics() {
        XCTAssertEqual(ScriptWidgetElementTreeJSON.number(1), "1")
        XCTAssertEqual(ScriptWidgetElementTreeJSON.number(0.1 + 0.2), "0.30000000000000004")
        XCTAssertEqual(ScriptWidgetElementTreeJSON.number(1e21), "1e+21")
        XCTAssertEqual(ScriptWidgetElementTreeJSON.number(1e-7), "1e-7")
        XCTAssertEqual(ScriptWidgetElementTreeJSON.number(-0.0), #"{"$number":"-0"}"#)
        XCTAssertEqual(ScriptWidgetElementTreeJSON.string("a\"\\\n\u{1}é😀"), #""a\"\\\n\u0001é😀""#)
    }

    func testBridgeSemanticsProbe() throws {
        let source = """
        $render(<vstack a={1} b={1.5} c={true} d="x" e={null} f={undefined} g={() => 1} h={[1, undefined, null]} i={{ x: 1 }} j={new Date(0)}>
          {"s"}{1}{true}{null}{undefined}{[["n", [2]]]}
        </vstack>);
        """
        let runtime = ScriptWidgetRuntime(package: ScriptWidgetPackage(path: FileManager.default.temporaryDirectory, readonly: true),
                                          environments: ["widget-size": "medium", "widget-param": ""])
        let (element, error) = runtime.executeJSXSyncForWidget(source)
        XCTAssertNil(error)
        let json = ScriptWidgetElementTreeJSON.encode(try XCTUnwrap(element))
        XCTAssertEqual(json, #"{"$element":"vstack","props":{"a":1,"b":1.5,"c":true,"d":"x","e":null,"g":{"$dict":{}},"h":[1,null,null],"i":{"$dict":{"x":1}},"j":{"$date":0}},"children":["s",1,true,null,null,[["n",[2]]]]}"#)
    }

    func testCorpusTreesMatchCheckedInParityFile() throws {
        try skipUnlessRepositoryCheckout(Self.repositoryRoot)
        let prelude = try String(contentsOf: Self.parityDirectory.appendingPathComponent("prelude.js"), encoding: .utf8)
        var entries: [String: Any] = [:]
        for (name, directory) in try Self.corpusPackages() {
            let package = ScriptWidgetPackage(path: directory, readonly: true)
            let source = try XCTUnwrap(package.readMainFile().0, "missing source for \(name)")
            if Self.usesLiveData(source) {
                entries[name] = ["skipped": "live-data"]
                continue
            }
            let runtime = ScriptWidgetRuntime(package: package, environments: ["widget-size": "medium", "widget-param": ""])
            try isolateStorage(of: runtime)
            let (element, error) = runtime.executeJSXSyncForWidget(prelude + source)
            if let error {
                entries[name] = ["error": errorKind(error)]
            } else if let element {
                entries[name] = ["tree": ScriptWidgetElementTreeJSON.encode(element)]
            } else {
                entries[name] = ["error": "none"]
            }
        }
        let context = JSContext()!
        let document: [String: Any] = [
            "generator": "BrowserPreviewParityTests.swift",
            "compilerFingerprint": ScriptWidgetBuildContract.compilerFingerprint,
            "runtimeAPIVersion": ScriptWidgetRuntimeContract.apiVersion,
            "timeZone": TimeZone.current.identifier,
            "javaScriptLocale": context.evaluateScript("Intl.DateTimeFormat().resolvedOptions().locale")?.toString() ?? "",
            "entries": entries,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let output = Self.parityDirectory.appendingPathComponent("native-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_UPDATE_PARITY"] == "1" {
            try data.write(to: output, options: .atomic)
            return
        }
        guard let existing = try? Data(contentsOf: output) else {
            throw XCTSkip("Run with TEST_RUNNER_SCRIPTWIDGET_UPDATE_PARITY=1 to create native-trees.json")
        }
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: existing) as? [String: Any])
        // JavaScriptCore reads the process time zone once, so date-formatting
        // templates are only comparable on a machine in the recorded zone.
        guard recorded["timeZone"] as? String == TimeZone.current.identifier else {
            throw XCTSkip("native-trees.json was recorded in \(recorded["timeZone"] ?? "?"); this machine uses \(TimeZone.current.identifier)")
        }
        let currentEntries = current["entries"] as? [String: Any] ?? [:]
        let recordedEntries = recorded["entries"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(currentEntries.keys), Set(recordedEntries.keys))
        for name in currentEntries.keys.sorted() {
            XCTAssertEqual(NSDictionary(dictionary: currentEntries[name] as? [String: Any] ?? [:]),
                           NSDictionary(dictionary: recordedEntries[name] as? [String: Any] ?? [:]),
                           "Native tree changed for \(name). Regenerate native-trees.json only after reviewing the difference.")
        }
    }
}
