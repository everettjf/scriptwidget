import Foundation
import XCTest
import WebKit
import SwiftUI
import Darwin
import WidgetKit
@testable import ScriptWidget
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class VisualLayoutEditorTests: XCTestCase {
    private let source = """
    // Keep my code
    const day='Monday';
    $render(
      <vstack spacing="8" alignment="leading" padding="16">
        <text font="caption">A fresh start</text>
        <text font="title2">Calm morning</text>
        <text>{day}</text>
      </vstack>
    );
    """
    @MainActor private func evaluate(_ web: WKWebView, _ expression: String) async throws -> Any? {
        // Bridge handlers return Promises. callAsyncJavaScript explicitly waits
        // for those results instead of trying to serialize a JS Promise.
        try await web.callAsyncJavaScript("return await eval(expression);", arguments: ["expression": expression], in: nil, contentWorld: .page)
    }
    @MainActor private func wait(_ web: WKWebView, _ expression: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? await evaluate(web, expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let diagnostic = (try? await evaluate(web, "JSON.stringify({ready:document.readyState,url:location.protocol,focused:document.hasFocus(),activeElement:document.activeElement?.className,content:document.querySelector('.cm-content')?.textContent,errors:window.__editorErrors,assets:[...document.scripts].map(script=>script.src.split('/').pop()),handlers:Object.keys(window.__nativeHandlers||{})})")) as? String ?? "unavailable"
        XCTFail("Timed out waiting for native editor condition: \(expression); \(diagnostic)")
        throw NSError(domain: "VisualLayoutEditorTests", code: 1)
    }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
    @MainActor private func editor() async throws -> WKWebView {
        _ = try XCTUnwrap(Bundle.main.url(forResource: "StudioEditor", withExtension: "bundle"))
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(StudioEditorBundleSchemeHandler(), forURLScheme: StudioEditorBundleSchemeHandler.scheme)
        configuration.userContentController.addUserScript(.init(source: """
        window.__editorErrors=[];addEventListener('error',event=>window.__editorErrors.push(String(event.message||event.target?.src||'resource error')),true);addEventListener('unhandledrejection',event=>window.__editorErrors.push(String(event.reason)));
        window.__nativeCalls=[];window.__nativeHandlers={};
        window.WKWebViewJavascriptBridge={
          registerHandler(name,handler){window.__nativeHandlers[name]=handler;},
          callHandler(name,data,callback){window.__nativeCalls.push({name,data});if(callback)callback({result:'ok'});}
        };
        window.__nativeCall=(name,data={})=>new Promise(resolve=>window.__nativeHandlers[name](data,resolve));
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0,y: 0,width: 850,height: 650), configuration: configuration)
        web.load(URLRequest(url: StudioEditorBundleSchemeHandler.indexURL))
        try await wait(web, "!!document.querySelector('.sw-layout-toggle') && !!window.__nativeHandlers['document.open']")
        return web
    }
    @MainActor private func open(_ web: WKWebView, source: String, id: String = "fixture/main.jsx", readOnly: Bool = false, resources: [String] = []) async throws {
        let data = try json(["documentID":id,"payload":["content":source,"version":0,"readOnly":readOnly,"resources":resources]])
        _ = try await evaluate(web, "window.__nativeCall('document.open',\(data))")
    }
    @MainActor private func content(_ web: WKWebView) async throws -> String {
        let response = try await evaluate(web, "window.__nativeCall('editor.getState')") as? [String:Any]
        return try XCTUnwrap(response?["content"] as? String)
    }
    @MainActor func testAsyncFormattingCannotChangeAFileOpenedWhileFormatting() async throws {
        let web = try await editor()
        try await open(web, source: source)
        let next = "const answer=42;$render(<text>Leave the next file untouched</text>);"
        let data = try json(["documentID": "next/main.jsx", "payload": ["content": next, "version": 0]])
        _ = try await evaluate(web, "(async()=>{const formatting=window.__nativeCall('editor.format');await window.__nativeCall('document.open',\(data));await formatting;})()")
        let current = try await content(web)
        XCTAssertEqual(current, next)
    }
    @MainActor func testAsyncFormattingCannotOverwriteManualEdits() async throws {
        let web = try await editor()
        try await open(web, source: source)
        let manual = "$render(<text>Manual change during formatting</text>);"
        _ = try await evaluate(web, "(async()=>{const formatting=window.__nativeCall('editor.format');document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));await formatting;})()")
        let current = try await content(web)
        XCTAssertEqual(current, manual)
    }
    @MainActor func testNativeBundledEditorLayoutChangesSaveThroughTheBridgeAndUndoWithoutLosingCode() async throws {
        let web = try await editor(); try await open(web, source: source)
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click();[...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent.includes('Calm morning')).click();document.querySelector('input[aria-label=\"Layer text\"]').value='Make today yours';[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Apply text').click();")
        let changed = try await content(web)
        XCTAssertEqual(changed, source.replacingOccurrences(of: "Calm morning", with: "{\"Make today yours\"}"))
        try await wait(web, "window.__nativeCalls.some(call=>call.name==='document.save' && call.data.payload.content.includes('Make today yours'))")
        let saveID = try await evaluate(web, "window.__nativeCalls.find(call=>call.name==='document.save').data.documentID") as? String
        XCTAssertEqual(saveID, "fixture/main.jsx")
        _ = try await evaluate(web, "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Undo').click()")
        let undone = try await content(web); XCTAssertEqual(undone, source)
        _ = try await evaluate(web, "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Redo').click()")
        let redone = try await content(web); XCTAssertEqual(redone, changed)
    }
    @MainActor func testNativeReadOnlyAndDocumentSwitchCannotOverwriteOrUndoIntoAnotherFile() async throws {
        let web = try await editor(); try await open(web, source: source)
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click();document.querySelectorAll('.sw-layout-layer')[0].click();[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Add text').click();")
        let changed = try await content(web); XCTAssertNotEqual(changed, source)
        let other = "$render(<text>Second file</text>);"
        try await open(web, source: other, id: "fixture/other.jsx", readOnly: true)
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click()")
        let undoDisabled = try await evaluate(web, "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Undo').disabled") as? Bool
        XCTAssertEqual(undoDisabled, true)
        let textInput = try await evaluate(web, "!!document.querySelector('input[aria-label=\"Layer text\"]')") as? Bool
        XCTAssertEqual(textInput, false)
        _ = try await evaluate(web, "window.__nativeCall('document.setReadOnly',{payload:{readOnly:false}})")
        let undoStillDisabled = try await evaluate(web, "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Undo').disabled") as? Bool
        XCTAssertEqual(undoStillDisabled,true)
        let retained = try await content(web); XCTAssertEqual(retained, other)
    }
    @MainActor func testRetiredLayoutFormsCannotEditAnotherFileWithIdenticalSource() async throws {
        let web = try await editor(); try await open(web, source: source)
        _ = try await evaluate(web, """
        document.querySelector('.sw-layout-toggle').click();
        [...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent.includes('Calm morning')).click();
        const input=document.querySelector('input[aria-label="Layer text"]');
        input.value='Retired text'; window.retiredTextForm=input.closest('form');
        window.retiredPropertyForm=document.querySelector('select[aria-label="Layout property"]').closest('form');
        document.querySelector('[aria-label="Layout property value"]').value='#ff0000';
        """)
        try await open(web, source: source, id: "fixture/identical.jsx")
        _ = try await evaluate(web, "window.retiredTextForm.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));window.retiredPropertyForm.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));")
        let retained = try await content(web); XCTAssertEqual(retained, source)
    }
    @MainActor func testRetiredAssetsAndUndoCannotChangeTheCurrentFile() async throws {
        let web = try await editor(); try await open(web, source: source)
        let buttons = "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==="
        _ = try await evaluate(web, buttons + "'Assets').click();window.retiredAsset=" + buttons + "'Insert Pebble friend');void 0;")
        try await open(web, source: source, id: "fixture/identical.jsx")
        _ = try await evaluate(web, "window.retiredAsset.click()")
        let retained = try await content(web); XCTAssertEqual(retained, source)
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click();document.querySelectorAll('.sw-layout-layer')[0].click();" + buttons + "'Add text').click();window.retiredUndo=" + buttons + "'Undo');void 0;")
        let edited = try await content(web)
        try await open(web, source: edited, id: "fixture/third.jsx")
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click();document.querySelectorAll('.sw-layout-layer')[0].click();" + buttons + "'Add spacer').click();")
        let third = try await content(web); XCTAssertNotEqual(third, edited)
        _ = try await evaluate(web, "window.retiredUndo.click()")
        let afterUndo = try await content(web); XCTAssertEqual(afterUndo, third)
    }
    @MainActor func testRetiredThemeFormCannotEditAnotherFileWithIdenticalSource() async throws {
        let web = try await editor(); try await open(web, source: source)
        let buttons = "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==="
        _ = try await evaluate(web, buttons + "'Theme').click();" + buttons + "'Connect layout to Meadow theme').click();")
        let themed = try await content(web)
        _ = try await evaluate(web, "const input=document.querySelector('input[aria-label=\"Theme background\"]');input.value='#ff0000';window.retiredThemeForm=input.closest('form');void 0;")
        try await open(web, source: themed, id: "fixture/identical-themed.jsx")
        _ = try await evaluate(web, "window.retiredThemeForm.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        let retained = try await content(web); XCTAssertEqual(retained, themed)
    }
    @MainActor func testControlsRetiredByPanelRerenderCannotEditTheSameDocument() async throws {
        let web = try await editor(); try await open(web, source: source)
        _ = try await evaluate(web, """
        document.querySelector('.sw-layout-toggle').click();
        [...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent.includes('Calm morning')).click();
        const input=document.querySelector('input[aria-label="Layer text"]');input.value='Retired text';window.retiredForm=input.closest('form');
        [...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Assets').click();
        window.retiredAsset=[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Insert Pebble friend');
        [...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Theme').click();
        window.retiredForm.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));window.retiredAsset.click();
        """)
        let retained = try await content(web); XCTAssertEqual(retained, source)
    }
    @MainActor func testDelayedNativeReplacementCannotSaveIntoAnotherDocument() async throws {
        try await assertDelayedNativeReplacement(returnToFirst: false)
    }
    @MainActor func testDelayedNativeReplacementCannotOverwriteAReopenedDocument() async throws {
        try await assertDelayedNativeReplacement(returnToFirst: true)
    }
    @MainActor func testDelayedNativeReplacementPreservesNewerEditsInTheSameDocument() async throws {
        try await assertDelayedNativeReplacement(returnToFirst: true, stayOnFirst: true)
    }
    @MainActor private func assertDelayedNativeReplacement(returnToFirst: Bool, stayOnFirst: Bool = false) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("NativeReplace-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = scratch.appendingPathComponent("First"), second = scratch.appendingPathComponent("Second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try source.write(to: directory.appendingPathComponent("main.jsx"), atomically: true, encoding: .utf8)
        }
        let firstModel = ScriptModel(package: ScriptWidgetPackage(path: first, readonly: false))
        let secondModel = ScriptModel(package: ScriptWidgetPackage(path: second, readonly: false))
        let secondID = second.appendingPathComponent("main.jsx").standardizedFileURL.path
        #if os(macOS)
        let web = EditorInternalWebView()
        web.frame = CGRect(x: 0, y: 0, width: 850, height: 650)
        web.loadEditorIfNeeded()
        web.updateDocument(firstModel, relativePath: "main.jsx")
        #else
        let web = MirrorEditorInternalView()
        web.frame = CGRect(x: 0, y: 0, width: 850, height: 650)
        web.updateDocument(action: MirrorEditorScriptView(model: firstModel, filePath: first.appendingPathComponent("main.jsx")).createActionProvider())
        #endif
        defer { web.stopLoading() }
        try await wait(web, "document.querySelector('.cm-content')?.textContent.includes('Calm morning') === true")
        let snapshot = try await nativeSnapshot(web, documentID: first.appendingPathComponent("main.jsx").standardizedFileURL.path)
        // Hold only the real JS acknowledgement. Document reads/saves/resources
        // still travel through the production bridge and package writer.
        _ = try await evaluate(web, """
        const bridge=window.WKWebViewJavascriptBridge,fetch=bridge._fetchQueue,receive=bridge._handleMessageFromiOS;
        window.__releaseReplacement=false;
        bridge._fetchQueue=()=>{
          const passed=[];
          for(const message of JSON.parse(fetch())){
            if(message.handlerName==='document.replace'&&message.responseID)window.__heldReplacement=message;
            else passed.push(message);
          }
          if(window.__releaseReplacement&&window.__heldReplacement){passed.unshift(window.__heldReplacement);window.__heldReplacement=null;}
          return JSON.stringify(passed);
        };
        bridge._handleMessageFromiOS=json=>{
          const message=JSON.parse(json);
          if(message.handlerName==='document.open'){window.__openedDocumentID=message.data.documentID;window.__openedSessionID=message.data.sessionID;}
          return receive(json);
        };void 0;
        """)
        let replacement = "$render(<text>Replacement intended for First only</text>);"
        #if os(macOS)
        EditorService.replaceDocument(with: replacement, snapshot: snapshot) { _ in }
        #else
        MirrorEditorService.replaceDocument(with: replacement, snapshot: snapshot) { _ in }
        #endif
        try await wait(web, "!!window.__heldReplacement")
        if !stayOnFirst {
            #if os(macOS)
            web.updateDocument(secondModel, relativePath: "main.jsx")
            #else
            web.updateDocument(action: MirrorEditorScriptView(model: secondModel, filePath: second.appendingPathComponent("main.jsx")).createActionProvider())
            #endif
            try await wait(web, "window.__openedDocumentID === \(try json(secondID)) && document.querySelector('.cm-content').textContent.includes('Calm morning')")
        }
        var finalID = secondID, finalURL = second.appendingPathComponent("main.jsx"), expected = source
        if returnToFirst {
            finalID = first.appendingPathComponent("main.jsx").standardizedFileURL.path
            finalURL = first.appendingPathComponent("main.jsx")
            if !stayOnFirst {
                #if os(macOS)
                web.updateDocument(firstModel, relativePath: "main.jsx")
                #else
                web.updateDocument(action: MirrorEditorScriptView(model: firstModel, filePath: finalURL).createActionProvider())
                #endif
                try await wait(web, "window.__openedDocumentID === \(try json(finalID))")
            }
            expected = "$render(<text>New manual edit after reopening First</text>);"
            _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(expected)));void 0;")
            let deadline = Date().addingTimeInterval(15)
            while (try? String(contentsOf: finalURL, encoding: .utf8)) != expected && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(try String(contentsOf: finalURL, encoding: .utf8), expected, "The actual native save path must persist the manual edit before releasing the stale reply")
        }
        _ = try await evaluate(web, """
        window.__releaseReplacement=true;
        window.WKWebViewJavascriptBridge.callHandler('document.resources',{documentID:\(try json(finalID)),sessionID:window.__openedSessionID || \(try json(snapshot.sessionID!))},response=>{window.__nativeBarrier=response.result==='ok';});
        """)
        try await wait(web, "window.__nativeBarrier===true")
        XCTAssertEqual(try String(contentsOf: finalURL, encoding: .utf8), expected)
    }
    #if os(macOS)
    private typealias NativeEditor = EditorInternalWebView
    private typealias NativeService = EditorService
    #else
    private typealias NativeEditor = MirrorEditorInternalView
    private typealias NativeService = MirrorEditorService
    #endif
    @MainActor private func nativeSnapshot(_ web: NativeEditor, documentID: String) async throws -> StudioDocumentSnapshot {
        let snapshot: StudioDocumentSnapshot? = await withCheckedContinuation { continuation in
            NativeService.requestSnapshot(target: StudioEditorTarget(editorID: web.editorID, documentID: documentID)) {
                continuation.resume(returning: $0)
            }
        }
        return try XCTUnwrap(snapshot)
    }
    #if os(macOS)
    @MainActor func testPreviewControlsFitTheMinimumPanelWidth() async throws {
        let (root, model, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        for width: CGFloat in [300, 360, 900] {
            for mode in StudioPreviewCanvasMode.allCases {
                let configuration = StudioWidgetConfiguration()
                configuration.family = .extraLargePortrait
                configuration.canvasMode = mode
                let host = NSHostingController(rootView: PreviewView(scriptModel: model, configuration: configuration))
                let proposed = NSSize(width: width, height: 650)
                let fitting = host.sizeThatFits(in: proposed)
                XCTAssertTrue(fitting.width.isFinite && fitting.width > 0 && fitting.width <= width + 1,
                              "\(mode) preview requires \(fitting.width) points for a \(width)-point panel")
            }
        }
    }
    @MainActor func testWorkspaceFileListIncludesFilesUnderACanonicalRoot() throws {
        let (root, model, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = model.package.path.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "export const title='Nested';".write(to: folder.appendingPathComponent("helper.js"), atomically: true, encoding: .utf8)
        let data = FileListDataObject(scriptModel: model)
        XCTAssertEqual(Set(data.nodes.map(\.relativePath)), ["main.jsx", "Sources"])
        XCTAssertEqual(data.nodes.first { $0.name == "Sources" }?.children?.map(\.relativePath), ["Sources/helper.js"])
    }
    @MainActor func testWorkspaceFileListRejectsLinksAndReleasesItsObserver() throws {
        let (root, model, other) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: model.package.path.appendingPathComponent("Loop"), withDestinationURL: model.package.path)
        try FileManager.default.createSymbolicLink(at: model.package.path.appendingPathComponent("Outside"), withDestinationURL: other.package.path)
        try FileManager.default.createSymbolicLink(at: model.package.path.appendingPathComponent("linked.jsx"), withDestinationURL: other.package.path.appendingPathComponent("main.jsx"))
        var data: FileListDataObject? = FileListDataObject(scriptModel: model)
        XCTAssertEqual(data?.nodes.map(\.relativePath), ["main.jsx"])
        weak var released = data
        data = nil
        XCTAssertNil(released, "Closing/replacing the workspace must release its file-list observer")
    }
    @MainActor private final class WorkspaceLayoutState: ObservableObject {
        @Published var vertical = true
    }
    private struct WorkspaceLayoutFixture: View {
        let model: ScriptModel
        let editorID = UUID()
        @ObservedObject var layout: WorkspaceLayoutState
        @State private var selectedPath = "main.jsx"
        @State private var configuration = StudioWidgetConfiguration()
        var body: some View {
            EditorWorkspaceContent(scriptModel: model, selectedFilePath: $selectedPath,
                                   widgetConfiguration: configuration, editorID: editorID,
                                   panelLayoutModeVertical: layout.vertical)
        }
    }
    @MainActor func testWorkspaceLayoutSwitchPreservesPendingEdits() async throws {
        let (root, model, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = WorkspaceLayoutState()
        let host = NSHostingController(rootView: WorkspaceLayoutFixture(model: model, layout: layout)
            .frame(width: 1280, height: 850))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Workspace acceptance fixture"
        host.view.frame = window.contentView!.bounds
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func editor() -> EditorInternalWebView? {
            window.contentView.flatMap { descendants($0).compactMap { $0 as? EditorInternalWebView }.first }
        }
        // A visible CodeMirror document can precede a usable native snapshot
        // during asynchronous host registration/handoff. Establish the actual
        // bridge precondition before injecting edits; keep all handoff and
        // persisted-content assertions below strict.
        func snapshotWhenReady(_ web: EditorInternalWebView, documentID: String) async throws -> StudioDocumentSnapshot {
            let deadline = Date().addingTimeInterval(15)
            var snapshot: StudioDocumentSnapshot?
            repeat {
                snapshot = await withCheckedContinuation { continuation in
                    EditorService.requestSnapshot(target: StudioEditorTarget(editorID: web.editorID, documentID: documentID)) {
                        continuation.resume(returning: $0)
                    }
                }
                if snapshot != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline
            return try XCTUnwrap(snapshot, "The current workspace host must provide a native snapshot before editing")
        }
        let deadline = Date().addingTimeInterval(15)
        while editor() == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let original = try XCTUnwrap(editor())
        try await wait(original, "document.querySelector('.cm-content')?.textContent.includes('Calm morning')===true")
        var current = original
        for index in 0..<4 {
            let marker = "Pending edit across workspace layout \(index)"
            let fileURL = model.package.path.appendingPathComponent("main.jsx")
            let before = try await snapshotWhenReady(current, documentID: fileURL.standardizedFileURL.path)
            let inserted = "// \(marker)\n"
            let manual = (before.content as NSString).replacingCharacters(
                in: NSRange(location: before.selection.lowerBound, length: before.selection.count), with: inserted)
            let message = try json(["handlerName": StudioProtocol.editorInsert, "data": [
                "documentID": try XCTUnwrap(before.documentID), "sessionID": try XCTUnwrap(before.sessionID),
                "payload": ["content": inserted]
            ]])
            // Exercise a real CodeMirror input transaction through the existing
            // insert command, without depending on WindowServer keyboard focus.
            // Hold edit/autosave delivery so only the closing host's final
            // snapshot can preserve this pending edit across the replacement.
            _ = try await evaluate(current, """
            const bridge=window.WKWebViewJavascriptBridge,fetch=bridge._fetchQueue.bind(bridge);
            bridge._fetchQueue=()=>JSON.stringify(JSON.parse(fetch()).filter(message=>!['document.changed','document.save'].includes(message.handlerName)));
            bridge._handleMessageFromiOS(\(try json(message)));void 0;
            """)
            try await wait(current, "document.querySelector('.cm-content')?.textContent.includes(\(try json(marker)))===true")
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before.content,
                           "The edit must still be pending when SwiftUI replaces the host")
            layout.vertical.toggle()
            let switchDeadline = Date().addingTimeInterval(15)
            while (editor() == nil || editor() === current) && Date() < switchDeadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let replacement = try XCTUnwrap(editor())
            XCTAssertFalse(replacement === current, "Exercise the actual SwiftUI split-layout replacement")
            try await wait(replacement, "document.querySelector('.cm-content')?.textContent.includes(\(try json(marker)))===true")
            try await waitForFile(model.package.path.appendingPathComponent("main.jsx"), manual)
            if index < 2, let output = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_WORKSPACE_LAYOUT"] {
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                try image.write(to: URL(fileURLWithPath: output).appendingPathComponent("workspace-\(layout.vertical ? "beside" : "below").png"))
            }
            current = replacement
        }
        if let directory = ProcessInfo.processInfo.environment["SCRIPTWIDGET_INSPECT_WORKSPACE"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try String(ProcessInfo.processInfo.processIdentifier).write(to: output.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(45)
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("resume").path) && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    #endif
    @MainActor private func applyNative(_ code: String, snapshot: StudioDocumentSnapshot) async -> StudioDocumentApplyResult {
        await withCheckedContinuation { continuation in
            NativeService.replaceDocument(with: code, snapshot: snapshot) { continuation.resume(returning: $0) }
        }
    }
    @MainActor private func nativeEditor(_ model: ScriptModel) async throws -> NativeEditor {
        let web = NativeEditor()
        web.frame = CGRect(x: 0, y: 0, width: 850, height: 650)
        #if os(macOS)
        web.loadEditorIfNeeded()
        #endif
        openNative(web, model)
        try await wait(web, "document.querySelector('.cm-content')?.textContent.includes('Calm morning')===true")
        return web
    }
    @MainActor private func openNative(_ web: NativeEditor, _ model: ScriptModel) {
        #if os(macOS)
        web.updateDocument(model, relativePath: "main.jsx")
        #else
        web.updateDocument(action: MirrorEditorScriptView(model: model, filePath: model.package.path.appendingPathComponent("main.jsx")).createActionProvider())
        #endif
    }
    @MainActor func testReplacementHostStartsBeforeTheOldHostIsDismantled() async throws {
        let (root, model, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let editorID = UUID()
        let old = NativeEditor(editorID: editorID)
        old.frame = CGRect(x: 0, y: 0, width: 850, height: 650)
        #if os(macOS)
        old.loadEditorIfNeeded()
        #endif
        openNative(old, model)
        try await wait(old, "document.querySelector('.cm-content')?.textContent.includes('Calm morning')===true")
        // Hold ordinary edit/autosave delivery so this ordering does not
        // depend on the draft debounce; final snapshot replies still pass.
        _ = try await evaluate(old, "const bridge=window.WKWebViewJavascriptBridge,fetch=bridge._fetchQueue.bind(bridge);bridge._fetchQueue=()=>JSON.stringify(JSON.parse(fetch()).filter(message=>!['document.changed','document.save'].includes(message.handlerName)));void 0;")
        let manual = "$render(<text>Input before the replacement host exists</text>);"
        _ = try await evaluate(old, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));void 0;")
        // SwiftUI is permitted to create the new representable before calling
        // dismantle on the old one. Keep that ordering deterministic here.
        let replacement = NativeEditor(editorID: editorID)
        replacement.frame = old.frame
        #if os(macOS)
        replacement.loadEditorIfNeeded()
        #endif
        openNative(replacement, model)
        defer { replacement.invalidate(); old.invalidate() }
        try await wait(replacement, "document.querySelector('.cm-content')?.textContent.includes('$render')===true")
        old.invalidate()
        let snapshot = try await nativeSnapshot(replacement, documentID: model.package.path.appendingPathComponent("main.jsx").standardizedFileURL.path)
        XCTAssertEqual(snapshot.content, manual, "The replacement must join the handoff even when it is created first")
        try await waitForFile(model.package.path.appendingPathComponent("main.jsx"), manual)
    }
    @MainActor private func waitForFile(_ url: URL, _ text: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while (try? String(contentsOf: url, encoding: .utf8)) != text && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }
    private func nativeModels() throws -> (URL, ScriptModel, ScriptModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeScope-" + UUID().uuidString)
        let models = try ["First", "Second"].map { name -> ScriptModel in
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try source.write(to: directory.appendingPathComponent("main.jsx"), atomically: true, encoding: .utf8)
            return ScriptModel(package: ScriptWidgetPackage(path: directory, readonly: false))
        }
        return (root, models[0], models[1])
    }
    @MainActor func testNativeReplacementOnlyChangesItsIntendedEditor() async throws {
        let (root, first, second) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await nativeEditor(first), b = try await nativeEditor(second)
        defer { a.stopLoading(); b.stopLoading() }
        let proposal = "$render(<text>Only the first editor requested this</text>);"
        let snapshot = try await nativeSnapshot(a, documentID: first.package.path.appendingPathComponent("main.jsx").standardizedFileURL.path)
        let result = await applyNative(proposal, snapshot: snapshot)
        XCTAssertEqual(result, .saved)
        try await waitForFile(first.package.path.appendingPathComponent("main.jsx"), proposal)
        let other = try await evaluate(b, "document.querySelector('.cm-content').textContent") as? String
        XCTAssertFalse(other?.contains("Only the first editor") == true)
        XCTAssertEqual(try String(contentsOf: second.package.path.appendingPathComponent("main.jsx"), encoding: .utf8), source)
    }
    @MainActor func testDismantlingNativeEditorPreservesTheLatestPendingEdit() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let url = first.package.path.appendingPathComponent("main.jsx")
        let manual = "$render(<text>Latest edit before leaving the editor</text>);"
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));void 0;")
        // SwiftUI may dismantle the representable before the asynchronous
        // onDisappear save reply arrives. Use the production teardown path.
        NativeService.save(target: StudioEditorTarget(editorID: web.editorID, documentID: url.standardizedFileURL.path)) { _ in }
        #if os(macOS)
        EditorWebView.dismantleNSView(web, coordinator: ())
        #else
        MirrorEditorScriptView.dismantleUIView(web, coordinator: ())
        #endif
        let reopened = NativeEditor()
        defer { reopened.stopLoading() }
        reopened.frame = CGRect(x: 0, y: 0, width: 850, height: 650)
        #if os(macOS)
        reopened.loadEditorIfNeeded()
        #endif
        openNative(reopened, first)
        try await wait(reopened, "(document.querySelector('.cm-content')?.textContent.length??0)>0")
        let snapshot = try await nativeSnapshot(reopened, documentID: url.standardizedFileURL.path)
        XCTAssertEqual(snapshot.content, manual)
        try await waitForFile(url, manual)
        try await wait(reopened, "document.querySelector('#save-status').textContent==='Saved'")
    }
    @MainActor func testClosingNativeEditorWritesBeforeAnyReopening() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let manual = "$render(<text>Saved when the editor closes</text>);"
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));void 0;")
        web.invalidate()
        try await waitForFile(first.package.path.appendingPathComponent("main.jsx"), manual)
    }
    @MainActor func testClosingNativeEditorCannotOverwriteAnExternalEdit() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let url = first.package.path.appendingPathComponent("main.jsx")
        let manual = "$render(<text>Pending edit in the closing view</text>);"
        let external = "$render(<text>New content from another writer</text>);"
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));void 0;")
        try external.write(to: url, atomically: true, encoding: .utf8)
        web.invalidate()
        await withCheckedContinuation { continuation in
            StudioDocumentHandoff.afterClosing(url.standardizedFileURL.path) { continuation.resume() }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), external)
    }
    @MainActor func testNativeSaveWithoutAnAcknowledgementStillWrites() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let url = first.package.path.appendingPathComponent("main.jsx")
        let snapshot = try await nativeSnapshot(web, documentID: url.standardizedFileURL.path)
        let saved = "$render(<text>Saved without a callback</text>);"
        let envelope = try json(["documentID": snapshot.documentID!, "sessionID": snapshot.sessionID!, "payload": ["content": saved, "version": snapshot.version]])
        _ = try await evaluate(web, "window.WKWebViewJavascriptBridge.callHandler('document.save',\(envelope));void 0;")
        try await waitForFile(url, saved)
    }
    @MainActor func testImmediateNativeFileSwitchFlushesOutgoingEdits() async throws {
        let (root, first, second) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let firstURL = first.package.path.appendingPathComponent("main.jsx")
        let secondURL = second.package.path.appendingPathComponent("main.jsx")
        _ = try await evaluate(web, "const receive=window.WKWebViewJavascriptBridge._handleMessageFromiOS;window.WKWebViewJavascriptBridge._handleMessageFromiOS=json=>{const message=JSON.parse(json);if(message.handlerName==='document.open')window.__switchedID=message.data.documentID;return receive(json);};void 0;")
        let manual = "$render(<text>Edited just before switching files</text>);"
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));void 0;")
        openNative(web, second)
        try await wait(web, "window.__switchedID===\(try json(secondURL.standardizedFileURL.path))")
        try await waitForFile(firstURL, manual)
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), source)
    }
    @MainActor func testNativeReadOnlyDocumentCanSwitchWithoutWriting() async throws {
        let (root, first, second) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let readonly = ScriptModel(package: ScriptWidgetPackage(path: first.package.path, readonly: true))
        let web = try await nativeEditor(readonly)
        defer { web.stopLoading() }
        try source.replacingOccurrences(of: "Calm morning", with: "Second file opened").write(to: second.package.path.appendingPathComponent("main.jsx"), atomically: true, encoding: .utf8)
        openNative(web, second)
        try await wait(web, "document.querySelector('.cm-content')?.textContent.includes('Second file opened')===true")
        XCTAssertEqual(try String(contentsOf: first.package.path.appendingPathComponent("main.jsx"), encoding: .utf8), source)
    }
    @MainActor func testNativeProposalTargetsOneOfTwoWindowsOnTheSameFile() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await nativeEditor(first), b = try await nativeEditor(first)
        defer { a.stopLoading(); b.stopLoading() }
        let snapshot = try await nativeSnapshot(a, documentID: first.package.path.appendingPathComponent("main.jsx").standardizedFileURL.path)
        let result = await applyNative("$render(<text>Only window A</text>);", snapshot: snapshot)
        XCTAssertEqual(result, .saved)
        let other = try await evaluate(b, "document.querySelector('.cm-content').textContent") as? String
        XCTAssertFalse(other?.contains("Only window A") == true)
    }
    @MainActor func testNativeProposalRejectsCodeEditedAfterSnapshot() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let url = first.package.path.appendingPathComponent("main.jsx")
        let snapshot = try await nativeSnapshot(web, documentID: url.standardizedFileURL.path)
        let manual = "$render(<text>Keep my newer manual edit</text>);"
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(manual)));void 0;")
        let result = await applyNative("$render(<text>Stale proposal</text>);", snapshot: snapshot)
        XCTAssertEqual(result, .conflict)
        try await waitForFile(url, manual)
    }
    @MainActor func testNativeProposalReportsActualWriterFailure() async throws {
        let (root, first, _) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let url = first.package.path.appendingPathComponent("main.jsx")
        let snapshot = try await nativeSnapshot(web, documentID: url.standardizedFileURL.path)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let result = await applyNative("$render(<text>Not saved</text>);", snapshot: snapshot)
        XCTAssertEqual(result, .saveFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor func testQueuedAutosaveCannotOverwriteAReopenedNativeFile() async throws {
        try await assertQueuedNativeAutosave(reopen: true)
    }
    @MainActor func testQueuedAutosaveCannotOverwriteNewerEditsInTheSameOpening() async throws {
        try await assertQueuedNativeAutosave(reopen: false)
    }
    @MainActor private func assertQueuedNativeAutosave(reopen: Bool) async throws {
        let (root, first, second) = try nativeModels()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = try await nativeEditor(first)
        defer { web.stopLoading() }
        let id = first.package.path.appendingPathComponent("main.jsx").standardizedFileURL.path
        let initial = try await nativeSnapshot(web, documentID: id)
        _ = try await evaluate(web, """
        const bridge=window.WKWebViewJavascriptBridge,fetch=bridge._fetchQueue,receive=bridge._handleMessageFromiOS;
        window.__openedDocumentID=\(try json(id));window.__openedSessionID=\(try json(initial.sessionID!));
        window.__holdNextSave=true;window.__releaseSave=false;
        bridge._fetchQueue=()=>{
          const passed=[];
          for(const message of JSON.parse(fetch())){
            if(window.__holdNextSave&&message.handlerName==='document.save'&&!message.responseID){window.__heldSave=message;window.__holdNextSave=false;}
            else passed.push(message);
          }
          if(window.__releaseSave&&window.__heldSave){passed.unshift(window.__heldSave);window.__heldSave=null;}
          return JSON.stringify(passed);
        };
        bridge._handleMessageFromiOS=json=>{
          const message=JSON.parse(json);
          if(message.handlerName==='document.open'){window.__openedDocumentID=message.data.documentID;window.__openedSessionID=message.data.sessionID;}
          return receive(json);
        };void 0;
        """)
        let old = "$render(<text>Old queued autosave</text>);", newer = "$render(<text>New edit after reopening</text>);"
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(old)));void 0;")
        try await wait(web, "!!window.__heldSave")
        if reopen {
            openNative(web, second)
            try await wait(web, "document.querySelector('.cm-content').textContent.includes('Calm morning')")
            openNative(web, first)
            try await wait(web, "window.__openedDocumentID===\(try json(id))")
        }
        _ = try await evaluate(web, "document.querySelector('.cm-content').focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(try json(newer)));void 0;")
        try await waitForFile(first.package.path.appendingPathComponent("main.jsx"), newer)
        _ = try await evaluate(web, "window.__releaseSave=true;window.WKWebViewJavascriptBridge.callHandler('document.resources',{documentID:\(try json(id)),sessionID:window.__openedSessionID},response=>{window.__saveBarrier=response.result==='ok';});")
        try await wait(web, "window.__saveBarrier===true")
        XCTAssertEqual(try String(contentsOf: first.package.path.appendingPathComponent("main.jsx"), encoding: .utf8), newer)
        let status = try await evaluate(web, "document.getElementById('save-status').textContent") as? String
        XCTAssertEqual(status, "Saved")
    }
    @MainActor func testNativeUnsupportedRootsKeepSourceAndShowTheCodeBoundary() async throws {
        let web = try await editor(), code = "const widget=<text>Do not rewrite</text>;$render(widget);"
        try await open(web, source: code)
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click()")
        let notice = try await evaluate(web, "document.querySelector('.sw-layout-body').textContent") as? String
        XCTAssertTrue(notice?.contains("direct $render") == true)
        let retained = try await content(web); XCTAssertEqual(retained,code)
    }
    @MainActor func testLayoutStarterEditsRenderWithNativeJavaScriptCore() async throws {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: "template", withExtension: nil, subdirectory: "Script.bundle")).appendingPathComponent("Layout Starter")
        let before = try String(contentsOf: directory.appendingPathComponent("main.jsx"), encoding: .utf8)
        let web = try await editor(); try await open(web, source: before, id: "layout-starter/main.jsx")
        _ = try await evaluate(web, "document.querySelector('.sw-layout-toggle').click();[...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent.includes('Make today yours')).click();document.querySelector('input[aria-label=\"Layer text\"]').value='A calmer day';[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Apply text').click();[...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent==='<vstack>').click();document.querySelector('select[aria-label=\"Layout property\"]').value='alignment';document.querySelector('select[aria-label=\"Layout property\"]').dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('select[aria-label=\"Layout property value\"]').value='trailing';[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==='Apply').click();")
        let after = try await content(web)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutRuntime-" + UUID().uuidString)
        let suite = "app.scriptwidget.layout-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: scratch) }
        var examples: [String:[String:String]] = [:]
        for (phase, source) in [("before", before), ("after", after)] {
            let engine = ScriptWidgetRuntime(package: ScriptWidgetPackage(path: directory, readonly: true), environments: ["widget-size":"medium"], isDarkMode: false)
            engine.runningState?.storageDefaultsForTesting = defaults
            engine.runningState?.storageContainerForTesting = scratch
            let result = engine.executeJSXSyncForWidget(source)
            XCTAssertNil(result.1, result.1?.displayMessage ?? "")
            let root = try XCTUnwrap(result.0)
            examples[phase] = ["source":source,"tree":ScriptWidgetElementTreeJSON.encode(root)]
            if let output = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LAYOUT_WIDGETS"] {
                let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let context = ScriptWidgetElementContext(runtime: engine,debugMode: false,scriptName: "Layout Starter",scriptParameter: "",package: try XCTUnwrap(engine.runningState).package)
                let renderer = ImageRenderer(content: ScriptWidgetElementView(element: root,context: context).frame(width:329,height:155).background(Color.white).environment(\.colorScheme,.light))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                #if os(macOS)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
                #else
                let png = try XCTUnwrap(UIImage(cgImage:image).pngData())
                #endif
                try png.write(to:folder.appendingPathComponent(phase+".png"))
            }
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repository.appendingPathComponent("Web/preview-engine/test/parity/layout-edit-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LAYOUT_TREES"] == "1" {
            try JSONSerialization.data(withJSONObject:["formatVersion":1,"examples":examples],options:[.prettyPrinted,.sortedKeys]).write(to:path)
        } else {
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
            XCTAssertEqual(stored["examples"] as? [String:[String:String]],examples)
        }
    }
    @MainActor func testNativeThemeEditsSaveUndoAndRenderEveryPreset() async throws {
        let web = try await editor(); try await open(web, source: source)
        let directory = try XCTUnwrap(Bundle.main.url(forResource: "template", withExtension: nil, subdirectory: "Script.bundle")).appendingPathComponent("Layout Starter")
        let button = "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==="
        _ = try await evaluate(web, button + "'Theme').click();" + button + "'Connect layout to Meadow theme').click();")
        let connected = try await content(web)
        XCTAssertTrue(connected.contains("const widgetTheme"))
        XCTAssertTrue(connected.contains("{day}"))
        try await wait(web, "window.__nativeCalls.some(call=>call.name==='document.save' && call.data.payload.content.includes('const widgetTheme'))")
        _ = try await evaluate(web, button + "'Undo').click()")
        let undone = try await content(web); XCTAssertEqual(undone, source)
        _ = try await evaluate(web, button + "'Redo').click()")
        let redone = try await content(web); XCTAssertEqual(redone, connected)
        var examples: [String:[String:String]] = [:]
        for preset in ["Meadow", "Paper", "Peach", "Midnight"] {
            _ = try await evaluate(web, button + "'\(preset)').click()")
            let code = try await content(web)
            let engine = ScriptWidgetRuntime(package: ScriptWidgetPackage(path: directory, readonly: true), environments: ["widget-size":"medium"], isDarkMode: false)
            let result = engine.executeJSXSyncForWidget(code)
            XCTAssertNil(result.1, result.1?.displayMessage ?? "")
            let root = try XCTUnwrap(result.0)
            examples[preset] = ["source":code,"tree":ScriptWidgetElementTreeJSON.encode(root)]
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Web/preview-engine/test/parity/theme-edit-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_THEME_TREES"] == "1" {
            try JSONSerialization.data(withJSONObject:["formatVersion":1,"examples":examples],options:[.prettyPrinted,.sortedKeys]).write(to:fixture)
        } else {
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any])
            XCTAssertEqual(stored["examples"] as? [String:[String:String]],examples)
        }
        try await open(web, source: redone, id: "fixture/readonly.jsx", readOnly: true)
        _ = try await evaluate(web, button + "'Theme').click()")
        let disabled = try await evaluate(web, "document.querySelector('input[aria-label=\"Theme background\"]').disabled") as? Bool
        XCTAssertEqual(disabled, true)
        _ = try await evaluate(web, button + "'Midnight').click()")
        let unchanged = try await content(web); XCTAssertEqual(unchanged, redone)
    }
    @MainActor func testNativeLayoutScreenshot() async throws {
        let assetsPath = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_ASSETS_EDITOR"]
        guard let path = assetsPath ?? ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_LAYOUT_EDITOR"] else { throw XCTSkip("Opt in to native bundled editor screenshot") }
        let web = try await editor(); try await open(web, source: source)
        if assetsPath != nil {
            _ = try await evaluate(web,"window.__nativeCall('editor.setTheme',{payload:{theme:'light'}});[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Theme').click();[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Connect layout to Meadow theme').click();[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Assets').click();[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Insert Pebble friend').click();")
        } else {
            _ = try await evaluate(web, "window.__nativeCall('editor.setTheme',{payload:{theme:'light'}});document.querySelector('.sw-layout-toggle').click();[...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent.includes('Calm morning')).click()")
        }
        #if os(macOS)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderBack(nil); defer { window.orderOut(nil) }
        #endif
        try await Task.sleep(nanoseconds: 300_000_000)
        let snapshot = try await web.takeSnapshot(configuration: nil)
        #if os(macOS)
        let representation = try XCTUnwrap(snapshot.tiffRepresentation)
        let image = try XCTUnwrap(NSBitmapImageRep(data: representation))
        let png = try XCTUnwrap(image.representation(using: .png,properties: [:]))
        #else
        let png = try XCTUnwrap(snapshot.pngData())
        #endif
        try png.write(to: URL(fileURLWithPath: path))
    }
    func testPublicMaterialPoliciesAndFourRegionBudget() throws {
        XCTAssertEqual(ScriptWidgetRuntimeContract.maximumMaterialBackgrounds,4)
        for style in ScriptWidgetBackgroundMaterial.allCases { XCTAssertTrue(ScriptWidgetBackgroundMaterial.isEnabled(style.rawValue)) }
        XCTAssertFalse(ScriptWidgetBackgroundMaterial.isEnabled("none")); XCTAssertFalse(ScriptWidgetBackgroundMaterial.isEnabled("glass"))
        XCTAssertNil(ScriptWidgetVisualAccessibility().reduceTransparency); XCTAssertNil(ScriptWidgetVisualAccessibility().reduceMotion)
        XCTAssertTrue(ScriptWidgetBackgroundMaterial.usesMaterial(reduceTransparency:false,renderingMode:.fullColor))
        for mode in [WidgetRenderingMode.fullColor,.accented,.vibrant] {
            XCTAssertFalse(ScriptWidgetBackgroundMaterial.usesMaterial(reduceTransparency:true,renderingMode:mode))
        }
        XCTAssertFalse(ScriptWidgetBackgroundMaterial.usesMaterial(reduceTransparency:false,renderingMode:.accented))
        XCTAssertFalse(ScriptWidgetBackgroundMaterial.usesMaterial(reduceTransparency:false,renderingMode:.vibrant))
        let directory = try XCTUnwrap(Bundle.main.url(forResource:"template",withExtension:nil,subdirectory:"Script.bundle")).appendingPathComponent("Material Study")
        for (value,count,limited) in [("thin",4,false),("thin",5,true),("none",5,false),("unknown",5,false)] {
            let engine = ScriptWidgetRuntime(package:ScriptWidgetPackage(path:directory,readonly:true),environments:["widget-size":"medium"])
            let code = "$render(<vstack>" + String(repeating:"<text backgroundMaterial=\"\(value)\">A</text>",count:count) + "</vstack>);"
            let result = engine.executeJSXSyncForWidget(code)
            if limited { XCTAssertTrue(result.1?.displayMessage.contains("4-material") == true); XCTAssertNil(result.0) }
            else { XCTAssertNil(result.1); XCTAssertNotNil(result.0) }
        }
    }
    func testStaticDepthRejectsNonfiniteOrZeroAxesAndNormalizesLargeFiniteValues() throws {
        for value in ["nan,1,0,0","inf,1,0,0","5,inf,0,0","5,0,nan,0","5,0,0,0","5,bad,0,1","5,1,0","5,1,0,0,2"] { XCTAssertNil(ScriptWidgetRotation3D(value),value) }
        let valid = try XCTUnwrap(ScriptWidgetRotation3D("365, 0, 2, 0"))
        XCTAssertEqual(valid.degree,5); XCTAssertEqual(valid.x,0); XCTAssertEqual(valid.y,1); XCTAssertEqual(valid.z,0)
        let large = try XCTUnwrap(ScriptWidgetRotation3D("5,1e308,-1e308,0"))
        XCTAssertEqual(large.x,1); XCTAssertEqual(large.y,-1); XCTAssertEqual(large.z,0)
    }
    @MainActor func testPublicMaterialHostedRenderBaselineRecordsTimeAndFootprint() throws {
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to:&info) { pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
            return status == KERN_SUCCESS ? info.phys_footprint : 0
        }
        let directory = try XCTUnwrap(Bundle.main.url(forResource:"template",withExtension:nil,subdirectory:"Script.bundle")).appendingPathComponent("Material Study")
        let package = ScriptWidgetPackage(path:directory,readonly:true)
        let panel = "<vstack frame=\"62,62\" backgroundMaterial=\"thin\" background=\"#FAFFFC\" corner=\"12\"><text font=\"caption\">Calm</text></vstack>"
        let source = "$render(<hstack spacing=\"8\" background=\"#D3EBDD\">"+String(repeating:panel,count:4)+"</hstack>);"
        var samples:[[String:Any]] = []
        @MainActor func render(_ code: String, reduced: Bool) throws -> UInt64 {
            try autoreleasepool {
                let engine = ScriptWidgetRuntime(package:package,environments:["widget-size":"medium"],isDarkMode:false)
                let result = engine.executeJSXSyncForWidget(code); XCTAssertNil(result.1)
                let context = ScriptWidgetElementContext(runtime:engine,debugMode:false,scriptName:"Material budget",scriptParameter:"",package:package)
                let renderer = ImageRenderer(content:ScriptWidgetElementView(element:try XCTUnwrap(result.0),context:context).frame(width:329,height:155).environment(\.scriptWidgetVisualAccessibility,.init(reduceTransparency:reduced,reduceMotion:reduced)))
                let image = try XCTUnwrap(renderer.cgImage); XCTAssertEqual(image.width,329); XCTAssertEqual(image.height,155)
                return footprint()
            }
        }
        let cold = footprint()
        _ = try render(source.replacingOccurrences(of:"backgroundMaterial=\"thin\"",with:"backgroundMaterial=\"none\""),reduced:false)
        let afterPlain = footprint()
        _ = try render(source,reduced:false); _ = try render(source,reduced:true)
        let afterWarmup = footprint()
        for reduced in [false,true] {
            let baseline = footprint(), started = Date(); var peak = baseline
            for _ in 0..<5 {
                peak = max(peak,try render(source,reduced:reduced),footprint())
            }
            samples.append(["reduced":reduced,"frames":5,"regionsPerFrame":4,"seconds":Date().timeIntervalSince(started),"baselineFootprint":baseline,"peakSampledFootprint":peak,"deltaBytes":peak >= baseline ? peak-baseline : 0])
        }
        let data = try JSONSerialization.data(withJSONObject:["scope":"Hosted app/test JSC + ImageRenderer with plain/material/fallback warmup; not WidgetKit extension or physical-device memory acceptance","coldFootprint":cold,"afterPlainWarmup":afterPlain,"afterAllWarmup":afterWarmup,"samples":samples],options:[.prettyPrinted,.sortedKeys])
        let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json"); attachment.name = "public-material-hosted-baseline"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_MATERIAL_BENCHMARK"] { try data.write(to:URL(fileURLWithPath:path)) }
    }
    @MainActor func testMaterialStudyCanonicalTreesAndStaticAccessibilityCaptures() async throws {
        let directory = try XCTUnwrap(Bundle.main.url(forResource:"template",withExtension:nil,subdirectory:"Script.bundle")).appendingPathComponent("Material Study")
        let source = try String(contentsOf:directory.appendingPathComponent("main.jsx"),encoding:.utf8)
        let package = ScriptWidgetPackage(path:directory,readonly:true)
        var examples:[String:[String:String]] = [:]
        for family in ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"] {
            for mode in ["fullColor","accented","vibrant"] {
                for dark in [false,true] {
                    let key = family+"-"+mode+"-"+(dark ? "dark" : "light")
                    let engine = ScriptWidgetRuntime(package:package,environments:["widget-size":family,"widget-rendering-mode":mode],isDarkMode:dark)
                    let result = engine.executeJSXSyncForWidget(source)
                    XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                    let root = try XCTUnwrap(result.0)
                    examples[key] = ["tree":ScriptWidgetElementTreeJSON.encode(root)]
                    if family == "medium", mode == "fullColor", let output = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_MATERIAL_WIDGETS"] {
                        let folder = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                        for reduced in [false,true] {
                            let context = ScriptWidgetElementContext(runtime:engine,debugMode:false,scriptName:"Material Study",scriptParameter:"",package:package)
                            let renderer = ImageRenderer(content:ScriptWidgetElementView(element:root,context:context).frame(width:329,height:155).background(dark ? Color.black : Color.white).environment(\.colorScheme,dark ? .dark : .light).environment(\.scriptWidgetVisualAccessibility,.init(reduceTransparency:reduced,reduceMotion:reduced)))
                            renderer.scale = 2
                            let image = try XCTUnwrap(renderer.cgImage)
                            #if os(macOS)
                            let png = try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
                            #else
                            let png = try XCTUnwrap(UIImage(cgImage:image).pngData())
                            #endif
                            try png.write(to:folder.appendingPathComponent(key+(reduced ? "-reduced" : "")+".png"))
                        }
                    }
                }
            }
        }
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Web/preview-engine/test/parity/material-study-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_MATERIAL_TREES"] == "1" {
            try JSONSerialization.data(withJSONObject:["formatVersion":1,"source":source,"examples":examples],options:[.prettyPrinted,.sortedKeys]).write(to:fixture)
        } else {
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any])
            XCTAssertEqual(stored["source"] as? String,source)
            XCTAssertEqual(stored["examples"] as? [String:[String:String]],examples)
        }
    }
    @MainActor func testNativeMaterialPropertyEditingPreservesSourceAndHistory() async throws {
        let directory = try XCTUnwrap(Bundle.main.url(forResource:"template",withExtension:nil,subdirectory:"Script.bundle")).appendingPathComponent("Material Study")
        let code = try String(contentsOf:directory.appendingPathComponent("main.jsx"),encoding:.utf8)
        let web = try await editor(); try await open(web,source:code,id:"material-study/main.jsx")
        _ = try await evaluate(web,"document.querySelector('.sw-layout-toggle').click();[...document.querySelectorAll('.sw-layout-layer')].find(row=>row.textContent==='<vstack>').click();const choose=document.querySelector('select[aria-label=\"Layout property\"]');choose.value='backgroundMaterial';choose.dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('select[aria-label=\"Layout property value\"]').value='regular';[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Apply').click();")
        let changed = try await content(web)
        XCTAssertEqual(changed,code.replacingOccurrences(of:"backgroundMaterial=\"thin\"",with:"backgroundMaterial={\"regular\"}"))
        _ = try await evaluate(web,"[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Undo').click()")
        let undone = try await content(web); XCTAssertEqual(undone,code)
        _ = try await evaluate(web,"[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Redo').click()")
        let redone = try await content(web); XCTAssertEqual(redone,changed)
    }
    @MainActor func testNativeAssetsInsertUndoAndRenderOriginalsAndPackageImages() async throws {
        let web = try await editor()
        let code = "// Keep my source\n$render(<hstack frame=\"max\" spacing=\"12\" padding=\"12\" background=\"#F2FAF5\"><vstack spacing=\"4\"><text font=\"headline\">Make it yours</text><text font=\"caption\">Your shapes. Your colors.</text></vstack></hstack>);"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AssetRuntime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("image"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try code.write(to: scratch.appendingPathComponent("main.jsx"), atomically: true, encoding: .utf8)
        let image = ImageRenderer(content: LinearGradient(colors: [.green,.blue],startPoint:.topLeading,endPoint:.bottomTrailing).frame(width:96,height:64))
        let cgImage = try XCTUnwrap(image.cgImage)
        #if os(macOS)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage:cgImage).representation(using:.png,properties:[:]))
        #else
        let png = try XCTUnwrap(UIImage(cgImage:cgImage).pngData())
        #endif
        try png.write(to:scratch.appendingPathComponent("image/Sample.png"))
        if let output = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_ASSET_WIDGETS"] {
            let directory = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try png.write(to:directory.appendingPathComponent("Sample.png"))
        }
        let package = ScriptWidgetPackage(path:scratch,readonly:true)
        XCTAssertEqual(package.editorImageResources(),["image/Sample.png"])
        let button = "[...document.querySelectorAll('.sw-layout button')].find(button=>button.textContent==="
        var examples: [String:[String:String]] = [:]
        for themed in [false,true] {
            for (kind,title) in [("bloom","Bloom mark"),("leaf","Leaf mark"),("pebble","Pebble friend"),("photo","package image")] {
                let key = (themed ? "themed-" : "literal-") + kind
                try await open(web,source:code,id:key,resources:package.editorImageResources())
                if themed { _ = try await evaluate(web,button+"'Theme').click();"+button+"'Connect layout to Meadow theme').click();") }
                let before = try await content(web)
                _ = try await evaluate(web,button+"'Assets').click();"+button+"'Insert \(title)').click();")
                let after = try await content(web); XCTAssertNotEqual(after,before)
                try await wait(web,"window.__nativeCalls.some(call=>call.name==='document.save' && call.data.documentID===\(try json(key)))")
                _ = try await evaluate(web,button+"'Undo').click()")
                let undone = try await content(web); XCTAssertEqual(undone,before)
                _ = try await evaluate(web,button+"'Redo').click()")
                let redone = try await content(web); XCTAssertEqual(redone,after)
                let engine = ScriptWidgetRuntime(package:package,environments:["widget-size":"medium"],isDarkMode:false)
                let result = engine.executeJSXSyncForWidget(after)
                XCTAssertNil(result.1,result.1?.displayMessage ?? "")
                let root = try XCTUnwrap(result.0)
                examples[key] = ["source":after,"tree":ScriptWidgetElementTreeJSON.encode(root)]
                if let output = ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_ASSET_WIDGETS"] {
                    let directory = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    let context = ScriptWidgetElementContext(runtime:engine,debugMode:false,scriptName:"Original assets",scriptParameter:"",package:package)
                    let renderer = ImageRenderer(content:ScriptWidgetElementView(element:root,context:context).frame(width:329,height:155).background(Color.white).environment(\.colorScheme,.light)); renderer.scale = 2
                    let captured = try XCTUnwrap(renderer.cgImage)
                    #if os(macOS)
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage:captured).representation(using:.png,properties:[:]))
                    #else
                    let data = try XCTUnwrap(UIImage(cgImage:captured).pngData())
                    #endif
                    try data.write(to:directory.appendingPathComponent(key+".png"))
                }
            }
        }
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Web/preview-engine/test/parity/asset-edit-trees.json")
        if ProcessInfo.processInfo.environment["SCRIPTWIDGET_EXPORT_ASSET_TREES"] == "1" {
            try JSONSerialization.data(withJSONObject:["formatVersion":1,"original":code,"examples":examples],options:[.prettyPrinted,.sortedKeys]).write(to:fixture)
        } else {
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? [String:Any])
            XCTAssertEqual(stored["examples"] as? [String:[String:String]],examples)
        }
    }
    @MainActor func testNativeResourceRefreshRejectsLateOrWrongDocumentRepliesAndReadOnlyWrites() async throws {
        let web = try await editor()
        try await open(web,source:source,id:"first",resources:["image/First.png"])
        _ = try await evaluate(web,"window.__originalCall=window.WKWebViewJavascriptBridge.callHandler;window.WKWebViewJavascriptBridge.callHandler=(name,data,callback)=>{if(name==='document.resources')window.__pendingResources=callback;else window.__originalCall(name,data,callback);};[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Assets').click();[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Refresh images').click();")
        try await open(web,source:source,id:"second")
        _ = try await evaluate(web,"[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Assets').click();window.__pendingResources({result:'ok',documentID:'first',resources:['image/First.png']});")
        try await Task.sleep(nanoseconds:100_000_000)
        let empty = try await evaluate(web,"document.querySelector('select[aria-label=\"Package image\"]').options.length") as? Int
        XCTAssertEqual(empty,0)
        _ = try await evaluate(web,"[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Refresh images').click();window.__pendingResources({result:'ok',documentID:'first',resources:['image/Wrong.png']});")
        try await wait(web,"!document.querySelector('.sw-layout-error').hidden")
        let stillEmpty = try await evaluate(web,"document.querySelector('select[aria-label=\"Package image\"]').options.length") as? Int
        XCTAssertEqual(stillEmpty,0)
        _ = try await evaluate(web,"[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Refresh images').click();window.__pendingResources({result:'ok',documentID:'second',resources:['image/Current.png','../private.png']});")
        try await wait(web,"document.querySelector('select[aria-label=\"Package image\"]').value==='image/Current.png'")
        let before = try await content(web); XCTAssertEqual(before,source)
        try await open(web,source:source,id:"readonly",readOnly:true,resources:["image/Current.png"])
        _ = try await evaluate(web,"[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Assets').click();[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Insert Pebble friend').dispatchEvent(new MouseEvent('click'));")
        let unchanged = try await content(web); XCTAssertEqual(unchanged,source)
    }
    @MainActor func testNativeResourceRefreshLatestRequestWinsAndStaleFailuresStaySilent() async throws {
        let web = try await editor()
        try await open(web, source: source, id: "refresh-order")
        _ = try await evaluate(web, "window.__resourceReplies=[];window.__originalCall=window.WKWebViewJavascriptBridge.callHandler;window.WKWebViewJavascriptBridge.callHandler=(name,data,callback)=>{if(name==='document.resources')window.__resourceReplies.push(callback);else window.__originalCall(name,data,callback);};[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Assets').click();")
        let refresh = "[...document.querySelectorAll('.sw-layout button')].find(b=>b.textContent==='Refresh images').click();"
        _ = try await evaluate(web, refresh + refresh + "window.__resourceReplies[1]({result:'ok',documentID:'refresh-order',resources:['image/New.png']});")
        try await wait(web, "document.querySelector('select[aria-label=\"Package image\"]').value==='image/New.png'")
        _ = try await evaluate(web, "window.__resourceReplies[0]({result:'ok',documentID:'refresh-order',resources:['image/Old.png']});")
        try await Task.sleep(nanoseconds: 100_000_000)
        let newest = try await evaluate(web, "document.querySelector('select[aria-label=\"Package image\"]').value") as? String
        XCTAssertEqual(newest, "image/New.png")
        _ = try await evaluate(web, refresh + refresh + "window.__resourceReplies[3]({result:'ok',documentID:'refresh-order',resources:['image/Latest.png']});")
        try await wait(web, "document.querySelector('select[aria-label=\"Package image\"]').value==='image/Latest.png'")
        _ = try await evaluate(web, "window.__resourceReplies[2]({result:'failed'});")
        try await Task.sleep(nanoseconds: 100_000_000)
        let hidden = try await evaluate(web, "document.querySelector('.sw-layout-error').hidden") as? Bool
        XCTAssertEqual(hidden, true)
        let unchanged = try await content(web)
        XCTAssertEqual(unchanged, source)
    }
    func testStudioImageResourcesRejectLinksDirectoriesUnsupportedTypesAndBoundTheList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AssetList-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("image"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let package = ScriptWidgetPackage(path:root,readonly:true)
        let image = root.appendingPathComponent("image")
        for name in ["Safe.png","Photo.JPG","skip.heic","skip.svg","skip.txt","a..b.png"," leading.png"] { try Data([1,2,3]).write(to:image.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at:image.appendingPathComponent("directory.png"),withIntermediateDirectories:true)
        try Data([4,5]).write(to:root.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at:image.appendingPathComponent("linked.png"),withDestinationURL:root.appendingPathComponent("outside.png"))
        try FileManager.default.linkItem(at:root.appendingPathComponent("outside.png"),to:image.appendingPathComponent("hardlink.png"))
        XCTAssertEqual(package.editorImageResources(),["image/Photo.JPG","image/Safe.png"])
        XCTAssertNil(ScriptWidgetPackageFiles.list(root:root,relative:"image",maximumCount:3))
        for index in 0..<260 { try Data([1]).write(to:image.appendingPathComponent("bounded-\(index).png")) }
        XCTAssertEqual(package.editorImageResources().count,256)
    }
    @MainActor func testBundleResourcesAreBoundedTypedAndCannotEscapeTheEditorRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("EditorResources-" + UUID().uuidString)
        let root = base.appendingPathComponent("bundle"), outside = base.appendingPathComponent("bundle-sibling")
        for folder in [root.appendingPathComponent("assets"),outside] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
        defer { try? FileManager.default.removeItem(at:base) }
        try Data("<html>Editor</html>".utf8).write(to:root.appendingPathComponent("index.html"))
        try Data("export const editor=true;".utf8).write(to:root.appendingPathComponent("assets/editor.js"))
        try Data("outside".utf8).write(to:outside.appendingPathComponent("secret.js"))
        try Data("private metadata".utf8).write(to:root.appendingPathComponent("Info.plist"))
        let handler = StudioEditorBundleSchemeHandler(root:root)
        func request(_ path: String) -> URLRequest { URLRequest(url:URL(string:StudioEditorBundleSchemeHandler.origin+path)!) }
        let html = try handler.resource(for:request("/index.html"))
        XCTAssertEqual(html.mime,"text/html; charset=utf-8"); XCTAssertEqual(String(decoding:html.data,as:UTF8.self),"<html>Editor</html>")
        XCTAssertEqual(try handler.resource(for:request("/assets/editor.js")).mime,"application/javascript; charset=utf-8")
        for path in ["/../bundle-sibling/secret.js","/%2e%2e/bundle-sibling/secret.js","/assets/%2e%2e/%2e%2e/bundle-sibling/secret.js","/assets%2F..%2F..%2Fbundle-sibling%2Fsecret.js","/assets%2Feditor.js","/%252e%252e/secret.js","/assets%5ceditor.js","/assets/%00editor.js","//index.html","/Info.plist","/assets","/index.html?token=fixture","/index.html#fragment"] {
            XCTAssertThrowsError(try handler.resource(for:request(path)),path)
        }
        for raw in ["https://studio/index.html","scriptwidget-editor://other/index.html","scriptwidget-editor://user:pass@studio/index.html","scriptwidget-editor://studio:80/index.html"] {
            XCTAssertThrowsError(try handler.resource(for:URLRequest(url:URL(string:raw)!)))
        }
        var post = request("/index.html"); post.httpMethod="POST"; XCTAssertThrowsError(try handler.resource(for:post))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("assets/linked.js"),withDestinationURL:outside.appendingPathComponent("secret.js"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("linked"),withDestinationURL:outside)
        XCTAssertThrowsError(try handler.resource(for:request("/assets/linked.js"))); XCTAssertThrowsError(try handler.resource(for:request("/linked/secret.js")))
        try FileManager.default.linkItem(at:outside.appendingPathComponent("secret.js"),to:root.appendingPathComponent("assets/hardlink.js"))
        XCTAssertThrowsError(try handler.resource(for:request("/assets/hardlink.js")))
        let oversized = root.appendingPathComponent("assets/large.js")
        XCTAssertTrue(FileManager.default.createFile(atPath:oversized.path,contents:nil))
        let file = try FileHandle(forWritingTo:oversized); try file.truncate(atOffset:UInt64(StudioEditorBundleSchemeHandler.maximumResourceBytes+1)); try file.close()
        XCTAssertThrowsError(try handler.resource(for:request("/assets/large.js")))
        XCTAssertThrowsError(try StudioEditorBundleSchemeHandler(root:nil).resource(for:request("/index.html")))
    }
}
