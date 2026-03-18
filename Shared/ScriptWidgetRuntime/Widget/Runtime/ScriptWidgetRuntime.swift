//
//  ScriptWidgetRuntime.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/11.
//

import Foundation
import JavaScriptCore
import Combine

enum ScriptWidgetError: Error {
    case undefinedRender(String)
    
    case internalError(String)
    case transformError(String)
    case scriptError(String)
    case scriptException(String)
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

class ScriptWidgetRuntime {
    
    private let runtimeContext = JSContext()!
    
    private var environments : [String:String]
    private var package : ScriptWidgetPackage
    
    init(package: ScriptWidgetPackage, environments: [String:String]) {
        self.package = package
        self.environments = environments
        // APIs like $file/$console read runtime data from sharedRunningState.
        // Ensure widget/extension runtime also initializes it.
        sharedRunningState = ScriptWidgetRunningState(package: package)
    }
    
    public func setEnvironment(_ key: String, _ value: String) {
        self.environments[key] = value
    }
    
    private func readSupportScript(_ fileName: String) -> String? {
        return ScriptManager.readBundleFile(bundle: "support", fileName: fileName)
    }
    
    private func transform(_ paramJSX: String, wrapMain: Bool, callAsynFunctionName: String = "") throws (ScriptWidgetError) -> String {
        // async/await support
        var JSX = ""
        if wrapMain {
            JSX += "async function $main() { try {"
            JSX += paramJSX
            if !callAsynFunctionName.isEmpty {
                // call function
                JSX += "await \(callAsynFunctionName)();"
            }
            JSX += "} catch(e){ console.error(e); $error(`${e}`) } }"
        } else {
            JSX = paramJSX
        }
        guard let babelContent = self.readSupportScript("core.js") else {
            throw .internalError("Babel file not found")
        }

        let transformContext = JSContext()!

        var exceptionInfo: String?
        transformContext.exceptionHandler = { context, exception in
            print("transform exception : \(exception!.toString() ?? "exception is nil")")
            exceptionInfo = exception?.toString()
        }
        transformContext.evaluateScript(babelContent)

        transformContext.evaluateScript("""
            function ScriptWidgetTransform(input) {
                var output = Babel.transform(input, { presets: ['scriptwidget'] }).code
                return output
            }
        """)

        guard let result = transformContext.objectForKeyedSubscript("ScriptWidgetTransform")?
            .call(withArguments: [JSX]) else {
            throw .transformError("Transform result is nil")
        }

        guard let jsOutput = result.toString() else {
            throw .transformError("Transform result is not string : \(result)")
        }

        // check javascript exception
        if let exceptionInfo = exceptionInfo {
            throw .scriptException(exceptionInfo)
        }

        return jsOutput
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
    
    func injectCommonFunctions() throws {
        guard let supportJS = self.readSupportScript("util.js") else {
            throw ScriptWidgetError.internalError("scriptwidget not found")
        }
                    
        // Inject ScriptWidgetRuntime JavaScript Object
        self.runtimeContext["Promise"] = ScriptWidgetRuntimePromise.self
        self.runtimeContext["fetch"] = unsafeBitCast(custom_fetch, to: JSValue.self)
        self.runtimeContext["$fetch"] = unsafeBitCast(custom_fetch, to: JSValue.self)

        self.runtimeContext["$console"] = ScriptWidgetRuntimeConsole.self
        self.runtimeContext["console"] = ScriptWidgetRuntimeConsole.self
        
        self.runtimeContext["$element"] = ScriptWidgetRuntimeElement.self
        self.runtimeContext["$device"] = ScriptWidgetRuntimeDevice.self
        self.runtimeContext["$http"] = ScriptWidgetRuntimeHttp.self
        self.runtimeContext["$file"] = ScriptWidgetRuntimeFile.self
        self.runtimeContext["$system"] = ScriptWidgetRuntimeSystem.self
        self.runtimeContext["$health"] = ScriptWidgetRuntimeHealth.self
        self.runtimeContext["$location"] = ScriptWidgetRuntimeLocation.self
        self.runtimeContext["$storage"] = ScriptWidgetRuntimeStorage.self

        let custom_getenv: @convention(block) (String)-> String = { [weak self] (key) in
            if let value = self?.environments[key] {
                return value
            }
            return ""
        }
        self.runtimeContext["$getenv"] = unsafeBitCast(custom_getenv, to: JSValue.self)
        
        let componentDefine:@convention(block) (String, JSValue) -> Void = { [weak self](name, builder) in
            print("define component : \(name) , \(type(of: builder))")
            
            if let type = self?.getTypeOfValue(builder) {
                print("builder type = \(type)")
            }
        }
        self.runtimeContext["$component"] = unsafeBitCast(componentDefine, to: JSValue.self)
        
        let importJS: @convention(block) (String) -> Bool = { [weak self] relativeFilePath in
            print("import \(relativeFilePath)")
            
            // read file
            guard let fileContent = self?.package.readFile(relativePath: relativeFilePath).0 else {
                return false
            }
            
            // transform
            do throws(ScriptWidgetError) {
                guard let script = try self?.transform(fileContent, wrapMain: false) else {
                    return false
                }
                print("import completion:")
                print("//////////////////////////////////////////////")
                print("\(script)")
                print("\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\")
                self?.runtimeContext.evaluateScript(script)
                return true
            } catch {
                print("import execute error : \(error)")
                return false
            }
        }
        self.runtimeContext["$import"] = unsafeBitCast(importJS, to: JSValue.self)
        
        // Execute support js
        self.runtimeContext.evaluateScript(supportJS)
    }
    
    func injectErrorHandlers() async throws {
        return try await withCancellingContinuation { continuation in
            self.runtimeContext.exceptionHandler = { context, exception in
                print("execute exception : \(exception?.toString() ?? "exception is nil")")
                continuation.resume(throwing: ScriptWidgetError.scriptException(exception?.toString() ?? "nil"))
            }
            
            let errorWidget: @convention(block) (String)->Void = { error in
                continuation.resume(throwing: ScriptWidgetError.scriptException(error))
            }
            self.runtimeContext["$error"] = unsafeBitCast(errorWidget, to: JSValue.self)
        }
    }
    
    func commonRunMain(_ script: String) throws {
        // moment.min.js
        if let momentJS = self.readSupportScript("moment.min.js") {
            self.runtimeContext.evaluateScript(momentJS)
        }
        
        // Execute target code
        self.runtimeContext.evaluateScript(script)
                    
        // Check render
        guard let mainEntry = self.runtimeContext.objectForKeyedSubscript("$main") else {
            throw ScriptWidgetError.internalError("$main() is not defined")
        }
        if mainEntry.isUndefined {
            throw ScriptWidgetError.undefinedRender("$main() is not defined")
        }

        // Call main
        let _ = mainEntry.call(withArguments: [])
    }
    
    func executeJsxAsyncMainWrapper<T>(inner: (String) async throws -> T, JSX: String) async throws -> T where T: Sendable {
        do {
            print("[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[")
            let transformed = try transform(JSX, wrapMain: true)
            print(transformed)
            let element = try await inner(transformed)
            print("script run finished")
            print("-------------------------------------------")
            print(element)
            print("]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]")
            return element
        } catch {
            print("failed: \(error)")
            throw error
        }
    }
}

extension ScriptWidgetRuntime {
    func executeJSXAsyncForWidget(_ JSX: String) async throws -> ScriptWidgetRuntimeElement {
        try await self.executeJsxAsyncMainWrapper(inner: self.internalExecuteJavaScriptForWidget, JSX: JSX)
    }
    
    /*
     load JavaScript and call render()

     const render = () => {
         return (
             <text>Hello SwiftWidget</text>
         )
     }
     */
    private func internalExecuteJavaScriptForWidget(_ JavaScript: String) async throws -> ScriptWidgetRuntimeElement {
        try self.injectCommonFunctions()
        
        return try await withThrowingTaskGroup { group in
            group.addTask {
                try await self.injectErrorHandlers()
                return FlowControl<ScriptWidgetRuntimeElement>.proceed
            }

            group.addTask {
                try await withCancellingContinuation { continuation in
                    let renderWidget: @convention(block) (ScriptWidgetRuntimeElement) -> Void = { rootElement in
                        print("root element = \(rootElement)")
                        continuation.resume(returning: .finish(value: rootElement))
                    }
                    self.runtimeContext["$render"] = unsafeBitCast(renderWidget, to: JSValue.self)
                }
            }

            // ignore for dynamic island
            // -begin
            group.addTask {
                try await withCancellingContinuation { continuation in
                    let renderDynamicIsland: @convention(block) (NSDictionary) -> Void = { islandInfo in
                        print("not support in normal widget rendering : islandInfo = \(islandInfo)")
                        continuation.resume(throwing: ScriptWidgetError.scriptError("$dynamic_island not support in normal widget rendering"))
                    }
                    self.runtimeContext["$dynamic_island"] = unsafeBitCast(renderDynamicIsland, to: JSValue.self)
                }
            }
            // -end

            group.addTask {
                // Make sure $render be called
                if !JavaScript.contains("$render") {
                    return .finish(value: ScriptWidgetRuntimeElement(tagString: "text", props: nil, children: ["#UI Not Found#"]))
                }

                try self.commonRunMain(JavaScript)
                return .proceed
            }

            return try await group.resultByFlowControl()!
        }
    }
}

extension ScriptWidgetRuntime {
    
    func executeJSXAsyncForDynamicIsland(_ JSX: String) async throws -> ScriptWidgetDynamicIslandRuntimeElement {
        try await self.executeJsxAsyncMainWrapper(inner: self.internalExecuteJavaScriptForDynamicIsland, JSX: JSX)
    }
    
    /*
     load JavaScript and call render()

     const render = () => {
         return (
             <text>Hello SwiftWidget</text>
         )
     }
     */
    private func internalExecuteJavaScriptForDynamicIsland(_ JavaScript: String) async throws -> ScriptWidgetDynamicIslandRuntimeElement {
        try self.injectCommonFunctions()
        
        return try await withThrowingTaskGroup { group in
            group.addTask {
                try await self.injectErrorHandlers()
                return FlowControl<ScriptWidgetDynamicIslandRuntimeElement>.proceed
            }
            
            // ignore for dynamic island
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let renderWidget:@convention(block) (ScriptWidgetRuntimeElement)->Void = { rootElement in
                        print("ignore $render for dynamic island : root element = \(rootElement)")
                        continuation.resume(throwing: ScriptWidgetError.scriptError("$render for dynamic island is not supported"))
                    }
                    self.runtimeContext["$render"] = unsafeBitCast(renderWidget, to: JSValue.self)
                }
            }
            
            // render dynamic island
            // -begin
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let renderDynamicIsland:@convention(block) (NSDictionary)->Void = { islandInfo in
                        print("not support in normal widget rendering : islandInfo = \(islandInfo)")
                        
                        guard let minimal = islandInfo["minimal"] as? ScriptWidgetRuntimeElement,
                           let compactLeading = islandInfo["compactLeading"] as? ScriptWidgetRuntimeElement,
                           let compactTrailing = islandInfo["compactTrailing"] as? ScriptWidgetRuntimeElement,
                              let expandedInfo = islandInfo["expanded"] as? NSDictionary else {
                            continuation.resume(throwing: ScriptWidgetError.scriptError("some dynamic island fields not found"))
                            return
                        }
                        
                        let expandedLeading = expandedInfo["leading"] as? ScriptWidgetRuntimeElement
                        let expandedTrailing = expandedInfo["trailing"] as? ScriptWidgetRuntimeElement
                        let expandedCenter = expandedInfo["center"] as? ScriptWidgetRuntimeElement
                        let expandedBottom = expandedInfo["bottom"] as? ScriptWidgetRuntimeElement
                        
                        let resultExpanded = ScriptWidgetDynamicIslandRuntimeElement.ExpandedElement(leading: expandedLeading, trailing: expandedTrailing, center: expandedCenter, bottom: expandedBottom)
                        
                        continuation.resume(returning: .finish(value: ScriptWidgetDynamicIslandRuntimeElement(expanded: resultExpanded, compactLeading: compactLeading, compactTrailing: compactTrailing, minimal: minimal)))
                    }
                    self.runtimeContext["$dynamic_island"] = unsafeBitCast(renderDynamicIsland, to: JSValue.self)
                }
            }
            // -end

            group.addTask {
                // Make sure $dynamic_island be called
                if !JavaScript.contains("$dynamic_island") {
                    return .finish(value: ScriptWidgetDynamicIslandRuntimeElement(text: "$dynamic_island call not found"))
                }
                
                try self.commonRunMain(JavaScript)
                return .proceed
            }
            return try await group.resultByFlowControl()!
        }
    }
    
}

extension ScriptWidgetRuntime {
    
    func executeJSXAsyncForFunction(_ JSX: String, _ functionName: String) async throws -> String {
        do {
            let JavaScript = try self.transform(JSX, wrapMain: true, callAsynFunctionName: functionName)
            print("[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[")
            print(JavaScript)
            print("-------------------------------------------")
            let element = try await self.internalExecuteJavaScriptForFunction(JavaScript)
            print(element)
            print("]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]")
            return element
        } catch {
            print("failed : \(error)")
            throw error
        }
    }
    
    /*
     load JavaScript and call function()

     const onButtonClick = () => {
        return "result string";
     }
     */
    private func internalExecuteJavaScriptForFunction(_ JavaScript: String) async throws -> String {
        try self.injectCommonFunctions()
        return try await withThrowingTaskGroup { group in
            group.addTask {
                try await self.injectErrorHandlers()
                return FlowControl<String>.proceed
            }
            
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let renderWidget: @convention(block) (ScriptWidgetRuntimeElement) ->Void = { rootElement in
                        print("not support in function calling mode = \(rootElement)")
                        continuation.resume(throwing: ScriptWidgetError.scriptError("$render is not supported in function calling mode"))
                    }
                    self.runtimeContext["$render"] = unsafeBitCast(renderWidget, to: JSValue.self)
                }
            }
            
            // ignore for dynamic island
            // -begin
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let renderDynamicIsland:@convention(block) (NSDictionary)->Void = { islandInfo in
                        print("not support in normal widget rendering : islandInfo = \(islandInfo)")
                        continuation.resume(throwing: ScriptWidgetError.scriptError("$dyanmic_island is not supported in function calling mode"))
                    }
                    self.runtimeContext["$dynamic_island"] = unsafeBitCast(renderDynamicIsland, to: JSValue.self)
                }
            }
            // -end
            
            group.addTask {
                try self.commonRunMain(JavaScript)
                return .finish(value: "")
            }
            
            return try await group.resultByFlowControl()!
        }
    }
}

enum FlowControl<T> {
    case finish(value: T)
    case proceed
}

extension ThrowingTaskGroup where Failure : Error {
    mutating func resultByFlowControl<T>() async throws -> T?
    where ChildTaskResult == FlowControl<T> {
        do {
            for try await control in self {
                switch control {
                case let .finish(element):
                    self.cancelAll()
                    return element
                case .proceed:
                    continue
                }
            }
        } catch {
            self.cancelAll()
            throw error
        }
        return nil
    }
}
