//
//  ScriptWidgetRuntime.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/11.
//

import Foundation
import JavaScriptCore
import Combine
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// Immutable bundled support scripts are shared within a process. Keeping this
/// cache small avoids repeatedly allocating the 57 KiB compatibility library,
/// while deliberately excluding Babel's multi-megabyte bundle from permanent
/// memory unless a cache miss actually requires compilation.
enum ScriptWidgetSupportScriptCache {
    private static let cache = NSCache<NSString, NSString>()

    static func read(_ fileName: String, loader: () -> String?) -> String? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached as String
        }
        guard let value = loader() else { return nil }
        if fileName != "core.js" {
            cache.setObject(value as NSString, forKey: fileName as NSString, cost: value.utf8.count)
            cache.totalCostLimit = 512 * 1_024
            cache.countLimit = 8
        }
        return value
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}

enum ScriptWidgetMemoryPressure {
    private static let lock = NSLock()
    private static var installed = false
    private static var observer: NSObjectProtocol?

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
#if os(iOS)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            releaseCaches()
        }
#endif
    }

    static func releaseCaches() {
        ScriptWidgetSupportScriptCache.removeAll()
        ScriptWidgetTranspileCache.removeAllMemory()
        ScriptWidgetImagePipeline.removeAll()
    }
}


enum ScriptWidgetRuntimeContract {
    static let apiVersion = ScriptWidgetBuildContract.nativeRuntimeAPIVersion
    static let maximumSourceBytes = 512 * 1_024
    static let maximumTranspiledBytes = 2 * 1_024 * 1_024
    static let executionTimeout: DispatchTimeInterval = .seconds(5)
    /// Checked before/after trusted Babel parsing and during AST traversal.
    /// Public JavaScriptCore APIs cannot preempt a native parser/built-in call.
    static let compileTimeout: TimeInterval = 10
    static let maximumElementNodes = 1_000
    static let maximumMaterialBackgrounds = 4
    static let maximumElementDepth = 64
    static let maximumPropsPerElement = 128

    static let globalAPIs = [
        "$alarms", "$calendar", "$component", "$console", "$contacts",
        "$device", "$documents", "$dynamic_island", "$element", "$error",
        "$fetch", "$file", "$getenv", "$health", "$home",
        "$http", "$icloud", "$import", "$location", "$maps",
        "$music", "$notifications", "$photos", "$reminders", "$render",
        "$runtime", "$services", "$storage", "$system", "$weather",
        "$xml", "console", "fetch"
    ]

    static func validateSource(_ source: String) -> ScriptWidgetError? {
        validateByteCount(source.utf8.count, maximum: maximumSourceBytes, label: "Source")
    }

    static func validateTranspiled(_ source: String) -> ScriptWidgetError? {
        validateByteCount(source.utf8.count, maximum: maximumTranspiledBytes, label: "Transpiled script")
    }

    private static func validateByteCount(_ count: Int, maximum: Int, label: String) -> ScriptWidgetError? {
        guard count <= maximum else {
            return .resourceLimit("\(label) exceeds the \(maximum)-byte runtime memory budget")
        }
        return nil
    }

    static var javascriptDescriptor: [String: Any] {
        [
            "apiVersion": apiVersion,
            "limits": [
                "sourceBytes": maximumSourceBytes,
                "transpiledBytes": maximumTranspiledBytes,
                "executionMilliseconds": 5_000,
                "elementNodes": maximumElementNodes,
                "elementDepth": maximumElementDepth,
                "propsPerElement": maximumPropsPerElement,
                "systemDataQueries": ScriptWidgetExecutionSession.maximumDataQueries,
            ],
        ]
    }

    static func validateElementTree(_ root: ScriptWidgetRuntimeElement) -> ScriptWidgetError? {
        var count = 0
        var materials = 0
        var activePath: Set<ObjectIdentifier> = []

        func visit(_ element: ScriptWidgetRuntimeElement, depth: Int) -> ScriptWidgetError? {
            guard depth <= maximumElementDepth else {
                return .resourceLimit("Element tree exceeds the maximum depth of \(maximumElementDepth)")
            }
            count += 1
            if element.tagAsString()?.lowercased() != "spacer", ScriptWidgetBackgroundMaterial.isEnabled(element.getPropString("backgroundMaterial")) {
                materials += 1
                guard materials <= maximumMaterialBackgrounds else {
                    return .resourceLimit("Element tree exceeds the \(maximumMaterialBackgrounds)-material background limit")
                }
            }
            guard count <= maximumElementNodes else {
                return .resourceLimit("Element tree exceeds the \(maximumElementNodes)-node limit")
            }
            guard element.getProps().count <= maximumPropsPerElement else {
                return .resourceLimit("Element has more than \(maximumPropsPerElement) properties")
            }
            let identifier = ObjectIdentifier(element)
            guard activePath.insert(identifier).inserted else {
                return .resourceLimit("Element tree contains a cycle")
            }
            defer { activePath.remove(identifier) }
            for child in element.childrenAsElements() {
                if let error = visit(child, depth: depth + 1) { return error }
            }
            return nil
        }

        return visit(root, depth: 1)
    }
}

/// A bounded XML-to-object bridge for scripts. XML input is untrusted even when
/// it comes from a declared network host or a package resource.
private final class ScriptWidgetXMLParser: NSObject, XMLParserDelegate {
    private static let maximumInputBytes = 256 * 1_024
    private static let maximumNodes = 2_048
    private static let maximumDepth = 32
    private static let maximumTextBytes = 256 * 1_024

    private final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        var object: [String: Any] {
            ["name": name, "attributes": attributes, "text": text,
             "children": children.map(\.object)]
        }
    }

    private var stack: [Node] = []
    private var root: Node?
    private var nodeCount = 0
    private var textBytes = 0
    private var failure: String?

    static func parse(_ source: String) -> String {
        guard source.utf8.count <= maximumInputBytes else {
            return response(error: "XML exceeds the 256 KiB input limit")
        }
        // DTDs and entities are unnecessary for widget data feeds. Reject them
        // before libxml sees the input, in addition to disabling resolution.
        guard source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              source.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            return response(error: "XML DTDs and entity declarations are not supported")
        }
        let delegate = ScriptWidgetXMLParser()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.allowedExternalEntityURLs = []
        guard parser.parse(), delegate.failure == nil, let root = delegate.root else {
            return response(error: delegate.failure ?? "Invalid XML")
        }
        return response(value: root.object)
    }

    private static func response(value: [String: Any]? = nil, error: String? = nil) -> String {
        var payload: [String: Any] = ["ok": error == nil]
        if let value { payload["value"] = value }
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"Invalid XML\"}"
        }
        return string
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        nodeCount += 1
        guard nodeCount <= Self.maximumNodes, stack.count < Self.maximumDepth else {
            failure = "XML exceeds the node or depth limit"
            parser.abortParsing()
            return
        }
        let node = Node(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) }
        else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBytes += string.utf8.count
        guard textBytes <= Self.maximumTextBytes else {
            failure = "XML exceeds the text limit"
            parser.abortParsing()
            return
        }
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            failure = "Invalid XML"
            parser.abortParsing()
            return
        }
        self.parser(parser, foundCharacters: text)
    }
}

extension JSContext {
    subscript(key: String) -> Any {
        get {
            return self.objectForKeyedSubscript(key)!
        }
        set {
            self.setObject(newValue, forKeyedSubscript: key as NSCopying & NSObjectProtocol)
        }
    }
}

/*
 
 // $dynamic_island is for dynamic island
 // on iPhone 14 Pro/ProMax and iOS16.1+
 // $dynamic_island({
 //     expanded: {
 //         leading: <text>leading</text>,
 //         trailing: <text>trailing</text>,
 //         center: <text>center</text>,
 //         bottom: <text>bottom</text>,
 //     },
 //     compactLeading: <text>compactLeading</text>,
 //     compactTrailing: <text>compactTrailing</text>,
 //     minimal: <text>minimal</text>,
 // });

 */


struct ScriptWidgetDynamicIslandRuntimeElement {
    struct ExpandedElement {
        public let leading: ScriptWidgetRuntimeElement?
        public let trailing: ScriptWidgetRuntimeElement?
        public let center: ScriptWidgetRuntimeElement?
        public let bottom: ScriptWidgetRuntimeElement?
    }
    
    public let expanded: ExpandedElement
    public let compactLeading: ScriptWidgetRuntimeElement
    public let compactTrailing: ScriptWidgetRuntimeElement
    public let minimal: ScriptWidgetRuntimeElement
    
    init(expanded: ExpandedElement, compactLeading: ScriptWidgetRuntimeElement, compactTrailing: ScriptWidgetRuntimeElement, minimal: ScriptWidgetRuntimeElement) {
        self.expanded = expanded
        self.compactLeading = compactLeading
        self.compactTrailing = compactTrailing
        self.minimal = minimal
    }
    
    init(text: String) {
        let textElement = ScriptWidgetRuntimeElement(tagString: "text", props: ["font":"footnote"], children: [text])
        self.expanded = ExpandedElement(leading: nil, trailing: nil, center: textElement, bottom: nil)
        self.compactLeading = textElement
        self.compactTrailing = textElement
        self.minimal = textElement
    }
}

enum ScriptWidgetCompiler {
    /// Bump whenever the wrapper or Babel preset changes. Keeping this value in
    /// the manifest lets Widget processes validate compiled output without
    /// reading and hashing the 2.7 MiB Babel bundle on every cold launch.
    static let fingerprint = ScriptWidgetBuildContract.compilerFingerprint

    static func wrappedSource(_ source: String, callFunction: String = "") -> String {
        var result = "async function $main() { try {"
        result += source
        if !callFunction.isEmpty { result += "await \(callFunction)();" }
        result += "} catch(e){ console.error(e); $error(`${e}`) } }"
        return result
    }

    static func compile(
        _ source: String,
        babelContent: String,
        timeLimit: TimeInterval = ScriptWidgetRuntimeContract.compileTimeout
    ) -> Result<String, ScriptWidgetError> {
        guard let context = JSContext() else {
            return .failure(.internalError("Unable to create compiler context"))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeLimit))
        let withinDeadline: @convention(block) () -> Bool = { ContinuousClock.now < deadline }
        context["__scriptWidgetCompileActive"] = unsafeBitCast(withinDeadline, to: JSValue.self)
        guard withinDeadline() else {
            return .failure(.resourceLimit("Compilation exceeded its time limit"))
        }
        var exceptionInfo: String?
        context.exceptionHandler = { _, exception in
            exceptionInfo = ScriptWidgetRuntime.describeException(exception)
        }
        context.evaluateScript(babelContent)
        context.evaluateScript("""
            function ScriptWidgetTransform(input) {
                const guardName = '__scriptWidgetCheckExecution';
                const plugin = function({ types: t }) {
                    const check = () => t.expressionStatement(t.callExpression(t.identifier(guardName), []));
                    const guardBody = path => {
                        path.ensureBlock();
                        path.get('body').unshiftContainer('body', check());
                    };
                    return { visitor: {
                        // Reserve the guard name in ALL scopes, including catch
                        // parameters, imports and destructuring. No dynamic with scope.
                        Program(path) {
                            path.traverse({
                                Identifier(identifier) {
                                    if (!__scriptWidgetCompileActive()) throw new Error('Compilation time limit exceeded');
                                    if (identifier.node.name === guardName) {
                                        throw new Error('Reserved runtime identifier: ' + guardName);
                                    }
                                },
                                WithStatement(statement) {
                                    throw new Error('with statements are unsupported');
                                }
                            });
                        },
                        'Loop|Function': { exit: guardBody },
                        CatchClause: { exit(path) { path.get('body').unshiftContainer('body', check()); } },
                        TryStatement: { exit(path) {
                            if (path.node.finalizer) path.get('finalizer').unshiftContainer('body', check());
                        } }
                    } };
                };
                return Babel.transform(input, { presets: ['scriptwidget'], plugins: [plugin] }).code;
            }
            """)
        let transformed = context.objectForKeyedSubscript("ScriptWidgetTransform")?
            .call(withArguments: [source])
        if !withinDeadline() {
            return .failure(.resourceLimit("Compilation exceeded the \(Int(timeLimit))-second time limit"))
        }
        guard let output = transformed?.toString() else {
            return .failure(.transformError(exceptionInfo ?? "Transform result is nil"))
        }
        if let exceptionInfo { return .failure(.scriptException(exceptionInfo)) }
        if let error = ScriptWidgetRuntimeContract.validateTranspiled(output) { return .failure(error) }
        return .success(output)
    }
}

enum ScriptWidgetPrecompiler {
    private static let queue = DispatchQueue(label: "scriptwidget.precompiler", qos: .utility)

    static func install() {
        ScriptWidgetPrecompileCoordinator.install { package, source in
            schedule(package: package, source: source)
        }
    }

    static func schedule(package: ScriptWidgetPackage, source: String) {
        queue.async {
            _ = compileNow(package: package, source: source)
        }
    }

    @discardableResult
    static func compileNow(package: ScriptWidgetPackage, source: String) -> Result<ScriptWidgetCompiledArtifact, ScriptWidgetError> {
        if let existing = ScriptWidgetCompiledArtifactStore.load(package: package, source: source) {
            return .success(existing)
        }
        guard let babel = ScriptManager.readBundleFile(bundle: "support", fileName: "core.js") else {
            return .failure(.internalError("Babel file not found"))
        }
        let wrapped = ScriptWidgetCompiler.wrappedSource(source)
        switch ScriptWidgetCompiler.compile(wrapped, babelContent: babel) {
        case .failure(let error):
            // The previous valid artifact is deliberately preserved.
            return .failure(error)
        case .success(let output):
            guard ScriptWidgetCompiledArtifactStore.save(package: package, source: source, javaScript: output),
                  let artifact = ScriptWidgetCompiledArtifactStore.load(package: package, source: source) else {
                return .failure(.internalError("Unable to persist compiled artifact"))
            }
            return .success(artifact)
        }
    }
}


class ScriptWidgetRuntime {
    /// Native validation hosts may replace system-data APIs before user code runs.
    /// Never exposed to JavaScript; normal apps and extensions leave this nil.
    var validationHostInstaller: ((JSContext) -> Void)?
    
    private let runtimeContext = JSContext()!
    private let publisherLane = ScriptWidgetPublisherLane()
    
    private var environments : [String:String]
    private var package : ScriptWidgetPackage
    private var performanceTrace: ScriptWidgetRuntimeTrace?
    
    init(package: ScriptWidgetPackage, environments: [String:String], executionSnapshot: ScriptWidgetExecutionSnapshot? = nil, isDarkMode: Bool? = nil, isUserInitiatedAction: Bool = false) {
        let executionPackage = executionSnapshot?.package ?? package
        self.package = executionPackage
        var resolvedEnvironment = environments
        if environments["timeline-date"] == nil, let schedule = executionPackage.readManifest()?.timeline, schedule.isValid {
            let now = Date()
            let plan = ScriptWidgetTimelinePlan(schedule: schedule, now: now, fallbackReload: now.addingTimeInterval(3_600))
            resolvedEnvironment = plan.entries[0].environments(timeZone: plan.timeZone).merging(environments) { _, explicit in explicit }
        }
        self.environments = resolvedEnvironment
        // APIs like $file/$console read per-execution state from the
        // owning JSContext.
        // Capture appearance before JavaScript moves to a worker queue.
        let runningState = ScriptWidgetRunningState(
            package: executionPackage, isDarkMode: isDarkMode ?? ScriptWidgetRuntimeDevice.systemIsDarkMode,
            isTimelineProjection: resolvedEnvironment["timeline-is-projection"] == "true",
            isLiveActivityPresentation: ["live-activity","dynamic-island"].contains(resolvedEnvironment["widget-size"] ?? ""), executionSnapshot: executionSnapshot, isUserInitiatedAction: isUserInitiatedAction
        )
        runtimeContext.scriptWidgetRunningState = runningState
        ScriptWidgetExecutionGuard.install(on: runtimeContext, session: runningState.executionSession)
        ScriptWidgetMemoryPressure.install()
        ScriptWidgetPrecompiler.install()
    }

    /// Per-execution state attached to this runtime's JSContext. Use
    /// after `executeJSXSyncForWidget` to read captured logs.
    var runningState: ScriptWidgetRunningState? {
        runtimeContext.scriptWidgetRunningState
    }

    func cancel(_ reason: ScriptWidgetExecutionCancellation = .explicit) {
        runningState?.executionSession.cancel(reason)
    }
    
    /// Display-only fixed date used by scheduled native renders. This does not
    /// grant execution authority or change query permissions.
    var presentationDate: Date? {
        guard let text = environments["timeline-date"], text.utf8.count <= 128 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    public func setEnvironment(_ key: String, _ value: String) {
        self.environments[key] = value
    }
    
    private func readSupportScript(_ fileName: String) -> String? {
        return ScriptWidgetSupportScriptCache.read(fileName) {
            ScriptManager.readBundleFile(bundle: "support", fileName: fileName)
        }
    }

    private func evaluateCompatibilityLibraries(for javaScript: String) {
        guard ScriptWidgetCompiledArtifactStore.inferredLibraries(source: javaScript).contains("moment"),
              let momentJS = readSupportScript("moment.min.js") else {
            performanceTrace?.increment("library.moment.skipped")
            return
        }
        performanceTrace?.measure("library.moment.evaluate") {
            runtimeContext.evaluateScript(momentJS)
        }
        performanceTrace?.increment("library.moment.loaded")
    }

    private func installBaseAPIs() {
        performanceTrace?.measure("runtime.api.install") {
            runtimeContext["Promise"] = ScriptWidgetRuntimePromise.self
            runtimeContext["fetch"] = unsafeBitCast(custom_fetch, to: JSValue.self)
            runtimeContext["$fetch"] = unsafeBitCast(custom_fetch, to: JSValue.self)
            runtimeContext["$console"] = ScriptWidgetRuntimeConsole.self
            runtimeContext["console"] = ScriptWidgetRuntimeConsole.self
            runtimeContext["$element"] = ScriptWidgetRuntimeElement.self
            runtimeContext["$device"] = ScriptWidgetRuntimeDevice.self
            runtimeContext["$http"] = ScriptWidgetRuntimeHttp.self
            runtimeContext["$file"] = ScriptWidgetRuntimeFile.self
            runtimeContext["$icloud"] = ScriptWidgetRuntimeCloudJSON.self
            runtimeContext["$notifications"] = ScriptWidgetRuntimeNotifications.self
            runtimeContext["$maps"] = ScriptWidgetRuntimeMaps.self
            runtimeContext["$weather"] = ScriptWidgetRuntimeWeather.self
            runtimeContext["$alarms"] = ScriptWidgetRuntimeAlarms.self
            runtimeContext["$documents"] = ScriptWidgetRuntimeDocuments.self
            runtimeContext["$contacts"] = ScriptWidgetRuntimeContacts.self
            runtimeContext["$home"] = ScriptWidgetRuntimeHome.self
            runtimeContext["$system"] = ScriptWidgetRuntimeSystem.self
            runtimeContext["$calendar"] = ScriptWidgetRuntimeCalendar.self
            runtimeContext["$photos"] = ScriptWidgetRuntimePhotos.self
            runtimeContext["$services"] = ScriptWidgetRuntimeServices.self
            runtimeContext["$music"] = ScriptWidgetRuntimeMusic.self
            runtimeContext["$reminders"] = ScriptWidgetRuntimeReminders.self
            runtimeContext["$health"] = ScriptWidgetRuntimeHealth.self
            runtimeContext["$location"] = ScriptWidgetRuntimeLocation.self
            runtimeContext["$storage"] = ScriptWidgetRuntimeStorage.self
            runtimeContext["$runtime"] = ScriptWidgetRuntimeContract.javascriptDescriptor
            runtimeContext["$dataSource"] = ScriptWidgetRuntimeDataSource.self

            let parseXML: @convention(block) (String) -> String = { source in
                ScriptWidgetXMLParser.parse(source)
            }
            runtimeContext["$xml_parse"] = unsafeBitCast(parseXML, to: JSValue.self)

            let environment = environments
            let getenv: @convention(block) (String) -> String = { key in environment[key] ?? "" }
            runtimeContext["$getenv"] = unsafeBitCast(getenv, to: JSValue.self)
            validationHostInstaller?(runtimeContext)
        }
    }
    
    private func packagePreflightError() -> ScriptWidgetError? {
        do { try runningState?.validateExecutionSnapshot() }
        catch {
            if runningState?.executionSnapshot == nil, (error as? ScriptWidgetStorageNamespaceError) == .inventoryRequired {
                return .scriptError("[package:migration_required] Open ScriptWidget to reload this widget's execution identity.")
            }
            return .scriptError("[package:identity_changed] The execution package changed or is unavailable. Reload it before running again.")
        }
        guard package.hasManifest else { return nil }
        guard let manifest = package.readManifest() else { return .scriptError("[package:invalid_manifest] widget.json is invalid.") }
        let report = WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false)
        guard let issue = report.errors.first else { return nil }
        return .scriptError("[package:\(issue.code)] Review widget.json and update ScriptWidget if required.")
    }

    private func transform(_ paramJSX: String, wrapMain: Bool, callAsynFunctionName: String = "") -> AnyPublisher<String, ScriptWidgetError> {
        if wrapMain {
            do {
                try runningState?.captureManagedEntry(paramJSX)
                if let captured = runningState?.executionSnapshot { package = captured.package }
            } catch {
                return Fail(error: .scriptError("[package:identity_changed] The managed package could not be captured. Reload it before running again.")).eraseToAnyPublisher()
            }
        }
        if let error = packagePreflightError() { return Fail(error: error).eraseToAnyPublisher() }
        if wrapMain, let captured = runningState?.executionSnapshot, paramJSX != captured.source {
            return Fail(error: .scriptError("[package:source_changed] Run the captured entry or explicitly capture an editor override.")).eraseToAnyPublisher()
        }
        if let error = ScriptWidgetRuntimeContract.validateSource(paramJSX) {
            return Fail(error: error).eraseToAnyPublisher()
        }
        let JSX = wrapMain
            ? ScriptWidgetCompiler.wrappedSource(paramJSX, callFunction: callAsynFunctionName)
            : paramJSX
        return Future<String, ScriptWidgetError> { promise in
            let sourceHashStart = ContinuousClock.now

            if wrapMain, callAsynFunctionName.isEmpty,
               let artifact = ScriptWidgetCompiledArtifactStore.load(package: self.package, source: paramJSX) {
                self.performanceTrace?.increment("compiled.artifact.hit")
                self.performanceTrace?.increment("source.bytes", by: paramJSX.utf8.count)
                self.performanceTrace?.increment("transpiled.bytes", by: artifact.javaScript.utf8.count)
                promise(.success(artifact.javaScript))
                return
            }
            self.performanceTrace?.increment("compiled.artifact.miss")

            // Babel transform output is deterministic for a given input + bundle,
            // so reuse a cached result instead of re-running Babel on every widget
            // refresh (widget processes are short-lived, hence the disk backing).
            let cacheKey = ScriptWidgetTranspileCache.key(for: JSX, babelFingerprint: ScriptWidgetCompiler.fingerprint)
            self.performanceTrace?.increment("source.bytes", by: JSX.utf8.count)
            self.performanceTrace?.increment("source.hash.nanoseconds", by: Int(sourceHashStart.duration(to: .now).components.attoseconds / 1_000_000_000))
            let cachedOutput = self.performanceTrace?.measure("transpile.cache.lookup", {
                ScriptWidgetTranspileCache.get(cacheKey)
            }) ?? ScriptWidgetTranspileCache.get(cacheKey)
            if let cached = cachedOutput {
                self.performanceTrace?.increment("transpile.cache.memory-or-disk-hit")
                if wrapMain, callAsynFunctionName.isEmpty {
                    _ = ScriptWidgetCompiledArtifactStore.save(package: self.package, source: paramJSX, javaScript: cached)
                }
                promise(.success(cached))
                return
            }
            self.performanceTrace?.increment("transpile.cache.miss")

            guard let babelContent = self.performanceTrace?.measure("compiler.bundle.read", {
                self.readSupportScript("core.js")
            }) ?? self.readSupportScript("core.js") else {
                promise(.failure(.internalError("Babel file not found")))
                return
            }

            let compileResult = self.performanceTrace?.measure("transpile.execute", {
                ScriptWidgetCompiler.compile(JSX, babelContent: babelContent)
            }) ?? ScriptWidgetCompiler.compile(JSX, babelContent: babelContent)
            guard case .success(let jsOutput) = compileResult else {
                if wrapMain, callAsynFunctionName.isEmpty,
                   let fallback = ScriptWidgetCompiledArtifactStore.loadLastKnownGood(package: self.package) {
                    self.performanceTrace?.increment("compiled.artifact.last-known-good")
                    promise(.success(fallback.javaScript))
                } else if case .failure(let error) = compileResult {
                    promise(.failure(error))
                }
                return
            }

            // success
            self.performanceTrace?.increment("transpiled.bytes", by: jsOutput.utf8.count)
            ScriptWidgetTranspileCache.set(cacheKey, jsOutput)
            if wrapMain, callAsynFunctionName.isEmpty {
                _ = ScriptWidgetCompiledArtifactStore.save(package: self.package, source: paramJSX, javaScript: jsOutput)
            }
            promise(.success(jsOutput))
        }
        .eraseToAnyPublisher()
    }
    
    public func getTypeOfValue(_ value: JSValue) -> String {
        guard let caller = self.runtimeContext.objectForKeyedSubscript("$type_of_object") else {
            return ""
        }
        
        guard let result = caller.call(withArguments: [value]) else {
            return ""
        }

        if !result.isString {
            return ""
        }

        return result.toString()
    }

    /// Builds a human-readable description of a JavaScriptCore exception,
    /// appending line/column and the JS stack trace when available so users
    /// can locate the failing line instead of seeing a bare message.
    static func describeException(_ exception: JSValue?) -> String {
        guard let exception = exception else { return "unknown error" }
        var message = exception.toString() ?? "unknown error"

        func field(_ name: String) -> String? {
            guard let value = exception.objectForKeyedSubscript(name),
                  !value.isUndefined, !value.isNull else { return nil }
            let string = value.toString()
            return (string?.isEmpty == false) ? string : nil
        }

        if let line = field("line") {
            if let column = field("column") {
                message += " (line \(line), column \(column))"
            } else {
                message += " (line \(line))"
            }
        }
        if let stack = field("stack") {
            message += "\n" + stack
        }
        return message
    }
}

extension ScriptWidgetRuntime {

    private func resolveWidgetElementTree(_ root: ScriptWidgetRuntimeElement) -> Result<ScriptWidgetRuntimeElement, ScriptWidgetError> {
        var activePath = Set<ObjectIdentifier>()

        func singleFragmentElement(_ values: [Any]) -> ScriptWidgetRuntimeElement? {
            var flattened: [Any] = []
            func append(_ value: Any) {
                if let nested = value as? [Any] {
                    nested.forEach(append)
                } else {
                    flattened.append(value)
                }
            }
            values.forEach(append)
            guard flattened.count == 1 else { return nil }
            return flattened[0] as? ScriptWidgetRuntimeElement
        }

        func resolve(_ element: ScriptWidgetRuntimeElement, depth: Int, unwrapFragment: Bool) -> Result<ScriptWidgetRuntimeElement, ScriptWidgetError> {
            guard depth <= ScriptWidgetRuntimeContract.maximumElementDepth else {
                return .failure(.resourceLimit("Element tree exceeds the maximum depth of \(ScriptWidgetRuntimeContract.maximumElementDepth)"))
            }

            var current = element
            var insertedIdentifiers: [ObjectIdentifier] = []
            defer { insertedIdentifiers.forEach { activePath.remove($0) } }

            for _ in 0..<ScriptWidgetRuntimeContract.maximumElementDepth {
                let identifier = ObjectIdentifier(current)
                guard activePath.insert(identifier).inserted else {
                    return .failure(.resourceLimit("Element tree contains a component cycle"))
                }
                insertedIdentifiers.append(identifier)

                guard current.tagAsString() == nil,
                      getTypeOfValue(current.tag) == "function" else {
                    break
                }

                var argument = current.getProps()
                argument["children"] = current.getChildren()
                guard let resultValue = current.tag.call(withArguments: [argument]),
                      resultValue.isObject,
                      let resolved = resultValue.toObject() as? ScriptWidgetRuntimeElement else {
                    return .failure(.scriptError("Custom component must return a ScriptWidget element"))
                }
                current = resolved
            }

            guard current.tagAsString() != nil else {
                return .failure(.resourceLimit("Component resolution exceeds the maximum depth"))
            }

            if unwrapFragment,
               current.tagAsString() == "Fragment",
               let child = singleFragmentElement(current.getChildren()) {
                return resolve(child, depth: depth, unwrapFragment: true)
            }

            func resolveChild(_ child: Any) -> Result<Any, ScriptWidgetError> {
                if let childElement = child as? ScriptWidgetRuntimeElement {
                    return resolve(childElement, depth: depth + 1, unwrapFragment: false).map { $0 as Any }
                }
                if let nested = child as? [Any] {
                    var resolvedChildren: [Any] = []
                    for nestedChild in nested {
                        switch resolveChild(nestedChild) {
                        case .success(let value): resolvedChildren.append(value)
                        case .failure(let error): return .failure(error)
                        }
                    }
                    return .success(resolvedChildren)
                }
                return .success(child)
            }

            var resolvedChildren: [Any] = []
            for child in current.getChildren() {
                switch resolveChild(child) {
                case .success(let value): resolvedChildren.append(value)
                case .failure(let error): return .failure(error)
                }
            }
            current.children = resolvedChildren
            return .success(current)
        }

        return resolve(root, depth: 1, unwrapFragment: true)
    }
    
    func executeJSXSyncForWidget(_ JSX: String) -> (ScriptWidgetRuntimeElement? , ScriptWidgetError?) {
        let trace = ScriptWidgetRuntimeTrace(operation: "widget")
        performanceTrace = trace
        defer {
            runningState?.executionSession.finish()
            trace.finish()
            performanceTrace = nil
        }
        // A synchronous host can occupy the main thread while JSC runs on the
        // publisher lane. Capture its installed identity and Music snapshot
        // before waiting; never enqueue a Music read behind that same wait.
        if Thread.isMainThread, let state = runningState,
           state.package.readManifest()?.permissions.contains(.music) == true {
            do {
                try state.captureManagedEntry(JSX)
                if let captured = state.executionSnapshot { package = captured.package }
            } catch {
                return (nil, .scriptError("[package:identity_changed] Reload the managed widget before running again."))
            }
            if let error = packagePreflightError() { return (nil, error) }
            ScriptWidgetRuntimeMusic.prepareForSynchronousHost(state)
        }
        let result = ScriptWidgetSynchronousResult<ScriptWidgetRuntimeElement>(publisherLane: publisherLane)
        publisherLane.queue.async {
            let token = self.internalExecuteJSXForWidget(JSX)
                .sink(receiveCompletion: { result.finish($0) }, receiveValue: { result.receive($0) })
            result.install(token)
        }
        return result.wait(until: .now() + ScriptWidgetRuntimeContract.executionTimeout) {
            self.runningState?.executionSession.cancel(.timeout)
        }
    }
    
    private func internalExecuteJSXForWidget(_ JSX: String) -> AnyPublisher<ScriptWidgetRuntimeElement, ScriptWidgetError> {
        return transform(JSX, wrapMain: true)
            .flatMap { JavaScript -> AnyPublisher<ScriptWidgetRuntimeElement, ScriptWidgetError> in
                return self.internalExecuteJavaScriptForWidget(JavaScript)
            }
            .eraseToAnyPublisher()
    }
    
    /*
     load JavaScript and call render()

     const render = () => {
         return (
             <text>Hello SwiftWidget</text>
         )
     }
     */
    private func internalExecuteJavaScriptForWidget(_ JavaScript: String) -> AnyPublisher<ScriptWidgetRuntimeElement, ScriptWidgetError> {
        return Future<ScriptWidgetRuntimeElement, ScriptWidgetError> { [self] rawPromise in
            let promise = publisherLane.fulfill(rawPromise)
            guard let supportJS = self.readSupportScript("util.js") else {
                promise(.failure(.internalError("scriptwidget not found")))
                return
            }
                        
            self.installBaseAPIs()

            let semaphore = DispatchSemaphore(value: 0)
            var resultElement: ScriptWidgetRuntimeElement?
            var rootResolutionError: ScriptWidgetError?
            
            let renderWidget:@convention(block) (ScriptWidgetRuntimeElement)->Void = { [weak self] rootElement in
                guard let self else { semaphore.signal(); return }
                switch self.resolveWidgetElementTree(rootElement) {
                case .success(let resolved):
                    resultElement = resolved
                case .failure(let error):
                    rootResolutionError = error
                }
                semaphore.signal()
            }
            self.runtimeContext["$render"] = unsafeBitCast(renderWidget, to: JSValue.self)
            
            // ignore for dynamic island
            // -begin
            let renderDynamicIsland:@convention(block) (NSDictionary)->Void = { islandInfo in
                print("not support in normal widget rendering : islandInfo = \(islandInfo)")
                semaphore.signal()
            }
            self.runtimeContext["$dynamic_island"] = unsafeBitCast(renderDynamicIsland, to: JSValue.self)
            // -end
            
            let componentDefine:@convention(block) (String, JSValue) -> Void = { [weak self](name, builder) in
                print("define component : \(name) , \(type(of: builder))")
                
                if let type = self?.getTypeOfValue(builder) {
                    print("builder type = \(type)")
                }
            }
            self.runtimeContext["$component"] = unsafeBitCast(componentDefine, to: JSValue.self)

            var exceptionInfo: String?
            self.runtimeContext.exceptionHandler = { context, exception in
                let described = ScriptWidgetRuntime.describeException(exception)
                SWLog.error("execute exception : \(described)")
                exceptionInfo = described
                semaphore.signal()
            }
            
            let errorWidget:@convention(block) (String)->Void = { error in
                exceptionInfo = error;
                semaphore.signal()
            }
            self.runtimeContext["$error"] = unsafeBitCast(errorWidget, to: JSValue.self)
            
            
            let importJS:@convention(block) (String) -> Bool = { [weak self] relativeFilePath in
                print("import \(relativeFilePath)")
                
                
                // read file
                guard let fileContent = self?.package.readFile(relativePath: relativeFilePath).0 else {
                    return false
                }
                
                // transform
                var executeResult = true
                let _ = self?.transform(fileContent, wrapMain: false)
                    .sink(receiveCompletion: { completion in
                        print("import completion : \(completion)")
                        switch completion {
                        case .failure(let error):
                            print("import execute error : \(error)")
                            executeResult = false
                        case .finished:
                            print("import execute finished")
                        }
                    }, receiveValue: { JavaScriptContent in
                        // execute
                        self?.runtimeContext.evaluateScript(JavaScriptContent)
                    })
                
                return executeResult
            }
            self.runtimeContext["$import"] = unsafeBitCast(importJS, to: JSValue.self)
            
            // Execute support js
            self.performanceTrace?.measure("runtime.support.evaluate") {
                self.runtimeContext.evaluateScript(supportJS)
            }
            
            self.evaluateCompatibilityLibraries(for: JavaScript)

            // Execute target code
            self.performanceTrace?.measure("runtime.user.evaluate") {
                self.runtimeContext.evaluateScript(JavaScript)
            }
                        
            // Check render
            guard let mainEntry = self.runtimeContext.objectForKeyedSubscript("$main") else {
                promise(.failure(.internalError("$main() is not defined")))
                return
            }
            if mainEntry.isUndefined {
                promise(.failure(.undefinedRender("$main() is not defined")))
                return
            }

            // Call main
            let _ = mainEntry.call(withArguments: [])
            
            
            // Make sure $render be called
            if !JavaScript.contains("$render") {
                resultElement = ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#UI Not Found#"])
                semaphore.signal()
            }

            DispatchQueue.global().async {
                guard semaphore.wait(timeout: .now() + ScriptWidgetRuntimeContract.executionTimeout) == .success else {
                    promise(.failure(.resourceLimit("Script exceeded the 5-second execution limit")))
                    return
                }
                // The context retains its render block and result cell. Drop
                // the cell before publishing native elements with JSValue tags.
                let renderedElement = resultElement
                resultElement = nil
                // check javascript exception
                if let exceptionInfo = exceptionInfo {
                    promise(.failure(.scriptException(exceptionInfo)))
                    return
                }
                if let rootResolutionError {
                    promise(.failure(rootResolutionError))
                    return
                }
                
                guard let element = renderedElement else {
                    promise(.failure(.scriptError("Transform result is not Element : \(String(describing: resultElement))")))
                    return
                }
                if let validationError = ScriptWidgetRuntimeContract.validateElementTree(element) {
                    promise(.failure(validationError))
                    return
                }
                
                // success
                promise(.success(element))
            }
        }
        .eraseToAnyPublisher()
    }
    
    
}

extension ScriptWidgetRuntime {
    
    func executeJSXSyncForDynamicIsland(_ JSX: String) -> (ScriptWidgetDynamicIslandRuntimeElement? , ScriptWidgetError?) {
        let trace = ScriptWidgetRuntimeTrace(operation: "dynamic-island")
        performanceTrace = trace
        defer {
            runningState?.executionSession.finish()
            trace.finish()
            performanceTrace = nil
        }
        let result = ScriptWidgetSynchronousResult<ScriptWidgetDynamicIslandRuntimeElement>(publisherLane: publisherLane)
        publisherLane.queue.async {
            let token = self.internalExecuteJSXForDynamicIsland(JSX)
                .sink(receiveCompletion: { result.finish($0) }, receiveValue: { result.receive($0) })
            result.install(token)
        }
        return result.wait(until: .now() + ScriptWidgetRuntimeContract.executionTimeout) {
            self.runningState?.executionSession.cancel(.timeout)
        }
    }
    
    private func internalExecuteJSXForDynamicIsland(_ JSX: String) -> AnyPublisher<ScriptWidgetDynamicIslandRuntimeElement, ScriptWidgetError> {
        return transform(JSX, wrapMain: true)
            .flatMap { JavaScript -> AnyPublisher<ScriptWidgetDynamicIslandRuntimeElement, ScriptWidgetError> in
                return self.internalExecuteJavaScriptForDynamicIsland(JavaScript)
            }
            .eraseToAnyPublisher()
    }
    
    /*
     load JavaScript and call render()

     const render = () => {
         return (
             <text>Hello SwiftWidget</text>
         )
     }
     */
    private func internalExecuteJavaScriptForDynamicIsland(_ JavaScript: String) -> AnyPublisher<ScriptWidgetDynamicIslandRuntimeElement, ScriptWidgetError> {
        return Future<ScriptWidgetDynamicIslandRuntimeElement, ScriptWidgetError> { [self] rawPromise in
            let promise = publisherLane.fulfill(rawPromise)
            guard let supportJS = self.readSupportScript("util.js") else {
                promise(.failure(.internalError("scriptwidget not found")))
                return
            }
                        
            self.installBaseAPIs()
            
            let semaphore = DispatchSemaphore(value: 0)
            var resultElement: ScriptWidgetDynamicIslandRuntimeElement?
            var componentResolutionError: ScriptWidgetError?
            
            // ignore for dynamic island
            let renderWidget:@convention(block) (ScriptWidgetRuntimeElement)->Void = { rootElement in
                semaphore.signal()
            }
            self.runtimeContext["$render"] = unsafeBitCast(renderWidget, to: JSValue.self)
            
            // ignore for dynamic island
            // -begin
            let renderDynamicIsland:@convention(block) (NSDictionary)->Void = { [weak self] islandInfo in
                guard let self else { semaphore.signal(); return }
                print("not support in normal widget rendering : islandInfo = \(islandInfo)")
                
                guard let minimal = islandInfo["minimal"] as? ScriptWidgetRuntimeElement,
                   let compactLeading = islandInfo["compactLeading"] as? ScriptWidgetRuntimeElement,
                   let compactTrailing = islandInfo["compactTrailing"] as? ScriptWidgetRuntimeElement,
                      let expandedInfo = islandInfo["expanded"] as? NSDictionary else {
                    print("some dynamic island fields not found")
                    semaphore.signal()
                    return
                }
                
                func resolveRequired(_ element: ScriptWidgetRuntimeElement) -> ScriptWidgetRuntimeElement? {
                    switch self.resolveWidgetElementTree(element) {
                    case .success(let resolved): return resolved
                    case .failure(let error):
                        componentResolutionError = error
                        return nil
                    }
                }

                func resolveOptional(_ element: ScriptWidgetRuntimeElement?) -> ScriptWidgetRuntimeElement? {
                    guard let element else { return nil }
                    return resolveRequired(element)
                }

                guard let resolvedMinimal = resolveRequired(minimal),
                      let resolvedCompactLeading = resolveRequired(compactLeading),
                      let resolvedCompactTrailing = resolveRequired(compactTrailing) else {
                    semaphore.signal()
                    return
                }

                let expandedLeading = resolveOptional(expandedInfo["leading"] as? ScriptWidgetRuntimeElement)
                let expandedTrailing = resolveOptional(expandedInfo["trailing"] as? ScriptWidgetRuntimeElement)
                let expandedCenter = resolveOptional(expandedInfo["center"] as? ScriptWidgetRuntimeElement)
                let expandedBottom = resolveOptional(expandedInfo["bottom"] as? ScriptWidgetRuntimeElement)

                guard componentResolutionError == nil else {
                    semaphore.signal()
                    return
                }
                
                let resultExpanded = ScriptWidgetDynamicIslandRuntimeElement.ExpandedElement(leading: expandedLeading, trailing: expandedTrailing, center: expandedCenter, bottom: expandedBottom)
                
                resultElement = ScriptWidgetDynamicIslandRuntimeElement(
                    expanded: resultExpanded,
                    compactLeading: resolvedCompactLeading,
                    compactTrailing: resolvedCompactTrailing,
                    minimal: resolvedMinimal
                )
                
                semaphore.signal()
            }
            self.runtimeContext["$dynamic_island"] = unsafeBitCast(renderDynamicIsland, to: JSValue.self)
            // -end
            
            let componentDefine:@convention(block) (String, JSValue) -> Void = { [weak self](name, builder) in
                print("define component : \(name) , \(type(of: builder))")
                
                if let type = self?.getTypeOfValue(builder) {
                    print("builder type = \(type)")
                }
            }
            self.runtimeContext["$component"] = unsafeBitCast(componentDefine, to: JSValue.self)

            var exceptionInfo: String?
            self.runtimeContext.exceptionHandler = { context, exception in
                let described = ScriptWidgetRuntime.describeException(exception)
                SWLog.error("execute exception : \(described)")
                exceptionInfo = described
                semaphore.signal()
            }
            
            let errorWidget:@convention(block) (String)->Void = { error in
                exceptionInfo = error;
                semaphore.signal()
            }
            self.runtimeContext["$error"] = unsafeBitCast(errorWidget, to: JSValue.self)
            
            
            let importJS:@convention(block) (String) -> Bool = { [weak self] relativeFilePath in
                print("import \(relativeFilePath)")
                
                
                // read file
                guard let fileContent = self?.package.readFile(relativePath: relativeFilePath).0 else {
                    return false
                }
                
                // transform
                var executeResult = true
                let _ = self?.transform(fileContent, wrapMain: false)
                    .sink(receiveCompletion: { completion in
                        print("import completion : \(completion)")
                        switch completion {
                        case .failure(let error):
                            print("import execute error : \(error)")
                            executeResult = false
                        case .finished:
                            print("import execute finished")
                        }
                    }, receiveValue: { JavaScriptContent in
                        // execute
                        self?.runtimeContext.evaluateScript(JavaScriptContent)
                    })
                
                return executeResult
            }
            self.runtimeContext["$import"] = unsafeBitCast(importJS, to: JSValue.self)
            
            // Execute support js
            self.performanceTrace?.measure("runtime.support.evaluate") {
                self.runtimeContext.evaluateScript(supportJS)
            }
            
            self.evaluateCompatibilityLibraries(for: JavaScript)

            // Execute target code
            self.performanceTrace?.measure("runtime.user.evaluate") {
                self.runtimeContext.evaluateScript(JavaScript)
            }
                        
            // Check render
            guard let mainEntry = self.runtimeContext.objectForKeyedSubscript("$main") else {
                promise(.failure(.internalError("$main() is not defined")))
                return
            }
            if mainEntry.isUndefined {
                promise(.failure(.undefinedRender("$main() is not defined")))
                return
            }

            // Call main
            let _ = mainEntry.call(withArguments: [])
            
            
            // Make sure $dynamic_island be called
            if !JavaScript.contains("$dynamic_island") {
                resultElement = ScriptWidgetDynamicIslandRuntimeElement(text: "$dynamic_island call not found")
                semaphore.signal()
            }

            DispatchQueue.global().async {
                guard semaphore.wait(timeout: .now() + ScriptWidgetRuntimeContract.executionTimeout) == .success else {
                    promise(.failure(.resourceLimit("Script exceeded the 5-second execution limit")))
                    return
                }
                // The context retains its render block and result cell. Drop
                // the cell before publishing native elements with JSValue tags.
                let renderedElement = resultElement
                resultElement = nil
                // check javascript exception
                if let exceptionInfo = exceptionInfo {
                    promise(.failure(.scriptException(exceptionInfo)))
                    return
                }
                if let componentResolutionError {
                    promise(.failure(componentResolutionError))
                    return
                }
                
                guard let element = renderedElement else {
                    promise(.failure(.scriptError("Transform result is not Element : \(String(describing: resultElement))")))
                    return
                }
                let roots = [
                    element.expanded.leading,
                    element.expanded.trailing,
                    element.expanded.center,
                    element.expanded.bottom,
                    element.compactLeading,
                    element.compactTrailing,
                    element.minimal,
                ].compactMap { $0 }
                if let validationError = roots.compactMap({ ScriptWidgetRuntimeContract.validateElementTree($0) }).first {
                    promise(.failure(validationError))
                    return
                }
                
                // success
                promise(.success(element))
            }
        }
        .eraseToAnyPublisher()
    }
    
}

extension ScriptWidgetRuntime {
    
    func executeJSXSyncForFunction(_ JSX: String, _ functionName: String) -> (String? , ScriptWidgetError?) {
        let trace = ScriptWidgetRuntimeTrace(operation: "function")
        performanceTrace = trace
        defer {
            runningState?.executionSession.finish()
            trace.finish()
            performanceTrace = nil
        }
        let result = ScriptWidgetSynchronousResult<String>(publisherLane: publisherLane)
        publisherLane.queue.async {
            let token = self.internalExecuteJSXForFunction(JSX, functionName)
                .sink(receiveCompletion: { result.finish($0) }, receiveValue: { result.receive($0) })
            result.install(token)
        }
        return result.wait(until: .now() + ScriptWidgetRuntimeContract.executionTimeout) {
            self.runningState?.executionSession.cancel(.timeout)
        }
    }
    
    private func internalExecuteJSXForFunction(_ JSX: String, _ functionName: String) -> AnyPublisher<String, ScriptWidgetError> {
        return transform(JSX, wrapMain: true, callAsynFunctionName: functionName)
            .flatMap { JavaScript -> AnyPublisher<String, ScriptWidgetError> in
                return self.internalExecuteJavaScriptForFunction(JavaScript)
            }
            .eraseToAnyPublisher()
    }
    
    /*
     load JavaScript and call function()

     const onButtonClick = () => {
        return "result string";
     }
     */
    private func internalExecuteJavaScriptForFunction(_ JavaScript: String) -> AnyPublisher<String, ScriptWidgetError> {
        return Future<String, ScriptWidgetError> { [self] rawPromise in
            let promise = publisherLane.fulfill(rawPromise)
            guard let supportJS = self.readSupportScript("util.js") else {
                promise(.failure(.internalError("scriptwidget not found")))
                return
            }
                        
            self.installBaseAPIs()
            
            let semaphore = DispatchSemaphore(value: 0)
            
            // Rendering is feedback, not completion: the declared action may
            // still be awaiting a system write after the entry rendered.
            let renderWidget:@convention(block) (ScriptWidgetRuntimeElement)->Void = { _ in }
            self.runtimeContext["$render"] = unsafeBitCast(renderWidget, to: JSValue.self)
            
            // ignore for dynamic island
            // -begin
            let renderDynamicIsland:@convention(block) (NSDictionary)->Void = { _ in }
            self.runtimeContext["$dynamic_island"] = unsafeBitCast(renderDynamicIsland, to: JSValue.self)
            // -end
            
            
            var exceptionInfo: String?
            self.runtimeContext.exceptionHandler = { context, exception in
                let described = ScriptWidgetRuntime.describeException(exception)
                SWLog.error("execute exception : \(described)")
                exceptionInfo = described
                semaphore.signal()
            }
            
            let errorWidget:@convention(block) (String)->Void = { error in
                exceptionInfo = error;
                semaphore.signal()
            }
            self.runtimeContext["$error"] = unsafeBitCast(errorWidget, to: JSValue.self)
            
            
            let importJS:@convention(block) (String) -> Bool = { [weak self] relativeFilePath in
                print("import \(relativeFilePath)")
                
                
                // read file
                guard let fileContent = self?.package.readFile(relativePath: relativeFilePath).0 else {
                    return false
                }
                
                // transform
                var executeResult = true
                let _ = self?.transform(fileContent, wrapMain: false)
                    .sink(receiveCompletion: { completion in
                        print("import completion : \(completion)")
                        switch completion {
                        case .failure(let error):
                            print("import execute error : \(error)")
                            executeResult = false
                        case .finished:
                            print("import execute finished")
                        }
                    }, receiveValue: { JavaScriptContent in
                        // execute
                        self?.runtimeContext.evaluateScript(JavaScriptContent)
                    })
                
                return executeResult
            }
            self.runtimeContext["$import"] = unsafeBitCast(importJS, to: JSValue.self)
            
            // Execute support js
            self.performanceTrace?.measure("runtime.support.evaluate") {
                self.runtimeContext.evaluateScript(supportJS)
            }
            
            self.evaluateCompatibilityLibraries(for: JavaScript)

            // Execute target code
            self.performanceTrace?.measure("runtime.user.evaluate") {
                self.runtimeContext.evaluateScript(JavaScript)
            }
                        
            // Check render
            guard let mainEntry = self.runtimeContext.objectForKeyedSubscript("$main") else {
                promise(.failure(.internalError("$main() is not defined")))
                return
            }
            if mainEntry.isUndefined {
                promise(.failure(.undefinedRender("$main() is not defined")))
                return
            }

            // Call main
            let complete: @convention(block) (JSValue) -> Void = { _ in semaphore.signal() }
            let failed: @convention(block) (JSValue) -> Void = { error in
                exceptionInfo = error.toString() ?? "Action failed"
                semaphore.signal()
            }
            guard let mainResult = mainEntry.call(withArguments: []),
                  let then = mainResult.objectForKeyedSubscript("then"), !then.isUndefined else {
                promise(.failure(.internalError("The action entry did not return an asynchronous result")))
                return
            }
            mainResult.invokeMethod("then", withArguments: [unsafeBitCast(complete, to: JSValue.self), unsafeBitCast(failed, to: JSValue.self)])

            DispatchQueue.global().async {
                guard semaphore.wait(timeout: .now() + ScriptWidgetRuntimeContract.executionTimeout) == .success else {
                    promise(.failure(.resourceLimit("Script exceeded the 5-second execution limit")))
                    return
                }
                // check javascript exception
                if let exceptionInfo = exceptionInfo {
                    promise(.failure(.scriptException(exceptionInfo)))
                    return
                }
                
                // success
                promise(.success(""))
            }
        }
        .eraseToAnyPublisher()
    }


}

/// Caches Babel(JSX) transpile output keyed by source content.
///
/// The transpiler is by far the most expensive step of a widget refresh and its
/// output is a pure function of (source, Babel bundle, preset). Widget extension
/// processes are short-lived, so the cache is also persisted to the shared app
/// group container to survive across refreshes.
enum ScriptWidgetTranspileCache {
    private static let appGroupIdentifier = "group.everettjf.scriptwidget"
    // Bump when the transform output format changes in a way unrelated to the
    // Babel bundle bytes (e.g. how `transform()` wraps the source).
    private static let formatVersion = "1"

    private static let queue = DispatchQueue(label: "scriptwidget.transpilecache")
    private static let memory = NSCache<NSString, NSString>()
    private static var babelFingerprintCache: String?
    static let maximumDiskBytes = 32 * 1_024 * 1_024
    static let maximumDiskEntries = 256

    static var memoryCostLimit: Int {
        get { memory.totalCostLimit }
        set { memory.totalCostLimit = max(0, newValue) }
    }

    static var memoryCountLimit: Int {
        get { memory.countLimit }
        set { memory.countLimit = max(0, newValue) }
    }

    private static func configureMemoryIfNeeded() {
        if memory.totalCostLimit == 0 { memory.totalCostLimit = 4 * 1_024 * 1_024 }
        if memory.countLimit == 0 { memory.countLimit = 16 }
    }

    private static let directory: URL? = {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let dir = base.appendingPathComponent("__TranspileCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Fingerprint of the Babel bundle, computed once per process. A different
    /// bundle (shipped in an app update) produces a different fingerprint and
    /// therefore different cache keys, so stale entries are never reused.
    static func fingerprint(of babelContent: String) -> String {
        if let cached = queue.sync(execute: { babelFingerprintCache }) {
            return cached
        }
        let digest = SHA256.hash(data: Data(babelContent.utf8))
        let value = digest.map { String(format: "%02x", $0) }.joined()
        queue.sync { babelFingerprintCache = value }
        return value
    }

    static func key(for source: String, babelFingerprint: String) -> String {
        let combined = "\(formatVersion)|\(babelFingerprint)|\(source)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func get(_ key: String) -> String? {
        configureMemoryIfNeeded()
        if let value = memory.object(forKey: key as NSString) {
            return value as String
        }
        guard let file = directory?.appendingPathComponent(key),
              let data = try? Data(contentsOf: file),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        memory.setObject(value as NSString, forKey: key as NSString, cost: value.utf8.count)
        return value
    }

    static func set(_ key: String, _ value: String) {
        configureMemoryIfNeeded()
        memory.setObject(value as NSString, forKey: key as NSString, cost: value.utf8.count)
        guard let file = directory?.appendingPathComponent(key) else { return }
        try? Data(value.utf8).write(to: file, options: .atomic)
        trim(directory: file.deletingLastPathComponent(), maximumBytes: maximumDiskBytes, maximumEntries: maximumDiskEntries)
    }

    static func removeAllMemory() {
        memory.removeAllObjects()
    }

    /// LRU-style bounded disk storage. This is deliberately synchronous with a
    /// cache write so a widget extension cannot leave unbounded state behind if
    /// it is suspended immediately afterwards.
    static func trim(directory: URL, maximumBytes: Int, maximumEntries: Int) {
        guard maximumBytes >= 0, maximumEntries >= 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        var entries = urls.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, max(0, values.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        while entries.count > maximumEntries || total > maximumBytes {
            let oldest = entries.removeLast()
            if (try? FileManager.default.removeItem(at: oldest.0)) != nil {
                total -= oldest.2
            }
        }
    }
}
