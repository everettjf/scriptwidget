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

enum ScriptWidgetError: Error {
    case undefinedRender(String)

    case internalError(String)
    case transformError(String)
    case scriptError(String)
    case scriptException(String)
    case resourceLimit(String)

    /// The underlying message, used both for logging and for surfacing the
    /// failure to the user in the widget/preview instead of a blank view.
    var displayMessage: String {
        switch self {
        case .undefinedRender(let msg),
             .internalError(let msg),
             .transformError(let msg),
             .scriptError(let msg),
             .scriptException(let msg),
             .resourceLimit(let msg):
            return msg
        }
    }

    var category: String {
        switch self {
        case .undefinedRender: return "Render"
        case .internalError: return "Internal"
        case .transformError: return "Syntax"
        case .scriptError, .scriptException: return "Runtime"
        case .resourceLimit: return "Resource Limit"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .undefinedRender: return "Call $render(...) once from the main script."
        case .internalError: return "Retry. If this persists, export the package and report the diagnostic."
        case .transformError: return "Check the highlighted JSX syntax and property values."
        case .scriptError, .scriptException: return "Use the reported line and stack trace to inspect the script."
        case .resourceLimit: return "Reduce source size, imported work, network data, or execution time."
        }
    }

    var diagnosticMessage: String { "[\(category)] \(displayMessage)\n\(recoverySuggestion)" }
}

enum ScriptWidgetRuntimeContract {
    static let apiVersion = "1.0"
    static let maximumSourceBytes = 512 * 1_024
    static let maximumTranspiledBytes = 2 * 1_024 * 1_024
    static let executionTimeout: DispatchTimeInterval = .seconds(5)
    static let maximumElementNodes = 1_000
    static let maximumElementDepth = 64
    static let maximumPropsPerElement = 128

    static let globalAPIs = [
        "$component", "$console", "$device", "$dynamic_island", "$element",
        "$error", "$fetch", "$file", "$getenv", "$health", "$http", "$import",
        "$location", "$render", "$runtime", "$storage", "$system", "console", "fetch",
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
            ],
        ]
    }

    static func validateElementTree(_ root: ScriptWidgetRuntimeElement) -> ScriptWidgetError? {
        var count = 0
        var activePath: Set<ObjectIdentifier> = []

        func visit(_ element: ScriptWidgetRuntimeElement, depth: Int) -> ScriptWidgetError? {
            guard depth <= maximumElementDepth else {
                return .resourceLimit("Element tree exceeds the maximum depth of \(maximumElementDepth)")
            }
            count += 1
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

    static func compile(_ source: String, babelContent: String) -> Result<String, ScriptWidgetError> {
        guard let context = JSContext() else {
            return .failure(.internalError("Unable to create compiler context"))
        }
        var exceptionInfo: String?
        context.exceptionHandler = { _, exception in
            exceptionInfo = ScriptWidgetRuntime.describeException(exception)
        }
        context.evaluateScript(babelContent)
        context.evaluateScript("""
            function ScriptWidgetTransform(input) {
                return Babel.transform(input, { presets: ['scriptwidget'] }).code
            }
            """)
        guard let output = context.objectForKeyedSubscript("ScriptWidgetTransform")?
            .call(withArguments: [source])?.toString() else {
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
    
    private let runtimeContext = JSContext()!
    
    private var environments : [String:String]
    private var package : ScriptWidgetPackage
    private var performanceTrace: ScriptWidgetRuntimeTrace?
    
    init(package: ScriptWidgetPackage, environments: [String:String]) {
        self.package = package
        self.environments = environments
        // APIs like $file/$console read per-execution state from the
        // owning JSContext.
        runtimeContext.scriptWidgetRunningState = ScriptWidgetRunningState(package: package)
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
            runtimeContext["$system"] = ScriptWidgetRuntimeSystem.self
            runtimeContext["$health"] = ScriptWidgetRuntimeHealth.self
            runtimeContext["$location"] = ScriptWidgetRuntimeLocation.self
            runtimeContext["$storage"] = ScriptWidgetRuntimeStorage.self
            runtimeContext["$runtime"] = ScriptWidgetRuntimeContract.javascriptDescriptor
            runtimeContext["$dataSource"] = ScriptWidgetRuntimeDataSource.self

            let environment = environments
            let getenv: @convention(block) (String) -> String = { key in environment[key] ?? "" }
            runtimeContext["$getenv"] = unsafeBitCast(getenv, to: JSValue.self)
        }
    }
    
    private func transform(_ paramJSX: String, wrapMain: Bool, callAsynFunctionName: String = "") -> AnyPublisher<String, ScriptWidgetError> {
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
        var resultError: ScriptWidgetError?
        var resultElement: ScriptWidgetRuntimeElement?
        
        let sem = DispatchSemaphore(value: 0)
        var cancellables: [AnyCancellable] = []

        DispatchQueue.global().async {

            let cancelable = self.internalExecuteJSXForWidget(JSX)
                .sink { (completion) in
                    switch completion {
                    case .finished:
                        sem.signal()
                        
                    case .failure(let error):
                        SWLog.error("widget execution failed: \(error)")
                        resultError = error
                        
                        sem.signal()
                    }
                } receiveValue: { (element) in
                    resultElement = element
                }
            cancellables.append(cancelable)
        }
        
        guard sem.wait(timeout: .now() + ScriptWidgetRuntimeContract.executionTimeout) == .success else {
            runningState?.executionSession.cancel(.timeout)
            cancellables.removeAll()
            return (nil, .resourceLimit("Script exceeded the 5-second execution limit"))
        }
        
        return (resultElement, resultError)
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
        return Future<ScriptWidgetRuntimeElement, ScriptWidgetError> { [self] promise in
            guard let supportJS = self.readSupportScript("util.js") else {
                promise(.failure(.internalError("scriptwidget not found")))
                return
            }
                        
            self.installBaseAPIs()

            let semaphore = DispatchSemaphore(value: 0)
            var resultElement: ScriptWidgetRuntimeElement?
            var rootResolutionError: ScriptWidgetError?
            
            let renderWidget:@convention(block) (ScriptWidgetRuntimeElement)->Void = { rootElement in
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
                // check javascript exception
                if let exceptionInfo = exceptionInfo {
                    promise(.failure(.scriptException(exceptionInfo)))
                    return
                }
                if let rootResolutionError {
                    promise(.failure(rootResolutionError))
                    return
                }
                
                guard let element = resultElement else {
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
        var resultError: ScriptWidgetError?
        var resultElement: ScriptWidgetDynamicIslandRuntimeElement?
        
        let sem = DispatchSemaphore(value: 0)
        var cancellables: [AnyCancellable] = []

        DispatchQueue.global().async {
            
            let cancelable = self.internalExecuteJSXForDynamicIsland(JSX)
                .sink { (completion) in
                    switch completion {
                    case .finished:
                        print("script run finished")
                        
                        sem.signal()
                        
                    case .failure(let error):
                        print("failed : \(error)")
                        resultError = error
                        
                        sem.signal()
                    }
                } receiveValue: { (element) in
                    resultElement = element
                }
            cancellables.append(cancelable)
        }
        
        guard sem.wait(timeout: .now() + ScriptWidgetRuntimeContract.executionTimeout) == .success else {
            runningState?.executionSession.cancel(.timeout)
            cancellables.removeAll()
            return (nil, .resourceLimit("Script exceeded the 5-second execution limit"))
        }
        
        return (resultElement, resultError)
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
        return Future<ScriptWidgetDynamicIslandRuntimeElement, ScriptWidgetError> { [self] promise in
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
            let renderDynamicIsland:@convention(block) (NSDictionary)->Void = { islandInfo in
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
                // check javascript exception
                if let exceptionInfo = exceptionInfo {
                    promise(.failure(.scriptException(exceptionInfo)))
                    return
                }
                if let componentResolutionError {
                    promise(.failure(componentResolutionError))
                    return
                }
                
                guard let element = resultElement else {
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
        var resultError: ScriptWidgetError?
        var resultElement: String?
        
        let sem = DispatchSemaphore(value: 0)
        var cancellables: [AnyCancellable] = []

        DispatchQueue.global().async {
            
            let cancelable = self.internalExecuteJSXForFunction(JSX, functionName)
                .sink { (completion) in
                    switch completion {
                    case .finished:
                        sem.signal()
                        
                    case .failure(let error):
                        SWLog.error("function execution failed: \(error)")
                        resultError = error
                        
                        sem.signal()
                    }
                } receiveValue: { (element) in
                    resultElement = element
                }
            cancellables.append(cancelable)
        }
        
        guard sem.wait(timeout: .now() + ScriptWidgetRuntimeContract.executionTimeout) == .success else {
            runningState?.executionSession.cancel(.timeout)
            cancellables.removeAll()
            return (nil, .resourceLimit("Script exceeded the 5-second execution limit"))
        }
        
        return (resultElement, resultError)
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
        return Future<String, ScriptWidgetError> { [self] promise in
            guard let supportJS = self.readSupportScript("util.js") else {
                promise(.failure(.internalError("scriptwidget not found")))
                return
            }
                        
            self.installBaseAPIs()
            
            let semaphore = DispatchSemaphore(value: 0)
            
            let renderWidget:@convention(block) (ScriptWidgetRuntimeElement)->Void = { rootElement in
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
