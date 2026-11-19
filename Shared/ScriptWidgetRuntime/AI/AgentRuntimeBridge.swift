//
//  AgentRuntimeBridge.swift
//  ScriptWidget
//
//  Adapts the synchronous ScriptWidgetRuntime.executeJSXSyncForWidget to
//  an async interface and persists the generated JSX to a one-shot temp
//  package (so $file / $import won't explode). Each execution gets its
//  own ScriptWidgetRuntime — running state hangs off that runtime's
//  JSContext, so concurrent runs (e.g. agent loop in the background
//  while the editor preview is also running) don't trample each other.
//

import Foundation

enum AgentRuntimeBridgeError: LocalizedError {
    case tempPackageCreationFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .tempPackageCreationFailed(let s): return "Failed to create sandbox package: \(s)"
        case .writeFailed(let s): return "Failed to write JSX: \(s)"
        }
    }
}

struct AgentRunResult {
    let element: ScriptWidgetRuntimeElement?
    let error: ScriptWidgetError?
    let logs: [String]

    var didSucceed: Bool {
        guard error == nil else { return false }
        guard let element = element else { return false }
        if let tag = element.tagAsString() {
            // Fallback sentinels emitted by the runtime when $render is
            // missing or the script blew up before reaching it.
            if element.children?.contains(where: { value in
                if let s = value as? String {
                    return s == "#UI Not Found#" || s == "#Failed#" || s == "#Loading#"
                }
                return false
            }) ?? false {
                return false
            }
            // Valid widgets start with a layout container or a
            // recognized tag; empty tag strings are suspicious.
            if tag.isEmpty { return false }
        }
        // Heuristic: if the only console output was an [error], treat as failed.
        if logs.contains(where: { $0.hasPrefix("[error]") || $0.lowercased().contains("uncaught") }) {
            return false
        }
        return true
    }
}

final class AgentRuntimeBridge {
    static let shared = AgentRuntimeBridge()

    private let runQueue = DispatchQueue(
        label: "scriptwidget.ai.runtime",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let sessionRoot: URL

    private init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScriptWidgetAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.sessionRoot = base
    }

    func makeSandboxPackage(prefix: String = "session") throws -> ScriptWidgetPackage {
        let dir = sessionRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AgentRuntimeBridgeError.tempPackageCreationFailed(error.localizedDescription)
        }
        return ScriptWidgetPackage(path: dir, readonly: false)
    }

    /// Copies a widget's own files into a sandbox package, so that code which
    /// imports or reads them runs as it would in the widget. Regular files
    /// only, no links, nothing from the build cache, within fixed limits.
    /// Returns false when the widget is too large to copy; nothing is half-copied
    /// silently in that case, the caller is told.
    @discardableResult
    func seed(_ package: ScriptWidgetPackage, from source: URL) -> Bool {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return false }
        let root = source.standardizedFileURL.path
        var files: [(relative: String, url: URL)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            if values.isSymbolicLink == true { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            if relative.split(separator: "/").first.map({ $0.lowercased() == "__build" }) == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
            files.append((relative, url))
            guard files.count <= Self.seedMaximumFiles, total <= Self.seedMaximumBytes else { return false }
        }
        for file in files {
            guard let data = try? Data(contentsOf: file.url),
                  ScriptWidgetPackageFiles.write(data, root: package.path, relative: file.relative) else { return false }
        }
        return true
    }

    static let seedMaximumFiles = 300
    static let seedMaximumBytes = 20 * 1_048_576

    func cleanupSandboxPackage(_ package: ScriptWidgetPackage) {
        try? FileManager.default.removeItem(at: package.path)
    }

    /// Runs the code in the sandbox package. With a manifest, the package is a
    /// Package 2.0 one and the code gets exactly the permissions written there,
    /// as it would once saved; without, it is a legacy package.
    func run(
        jsx: String, in package: ScriptWidgetPackage, size: AIWidgetSize, manifest: WidgetPackageManifest? = nil
    ) async -> AgentRunResult {
        return await withCheckedContinuation { continuation in
            runQueue.async {
                if let manifest {
                    // A seeded copy may carry the widget's own widget.json; this one replaces it.
                    guard let data = try? JSONEncoder().encode(manifest),
                          ScriptWidgetPackageFiles.write(data, root: package.path, relative: "widget.json") else {
                        continuation.resume(returning: AgentRunResult(
                            element: nil, error: .internalError("Failed to write widget.json"), logs: []
                        ))
                        return
                    }
                }
                // Persist the JSX so packages that read themselves or
                // register support files still work.
                let writeResult = package.writeMainFile(content: jsx)
                if !writeResult.0 {
                    continuation.resume(returning: AgentRunResult(
                        element: nil,
                        error: .internalError("Failed to write main.jsx: \(writeResult.1)"),
                        logs: []
                    ))
                    return
                }

                let preview = ScriptWidgetPackage(path: package.path, readonly: true)
                let runtime = ScriptWidgetRuntime(package: preview, environments: [
                    "widget-size": size.rawValue,
                    "widget-param": "",
                    "widget-rendering-mode": "fullColor",
                ])

                let (element, err) = runtime.executeJSXSyncForWidget(jsx)
                let logs = runtime.runningState?.logger.logs ?? []
                continuation.resume(returning: AgentRunResult(element: element, error: err, logs: logs))
            }
        }
    }
}

extension ScriptWidgetError {
    var summaryForPrompt: String {
        switch self {
        case .undefinedRender(let m): return "undefinedRender: \(m)"
        case .internalError(let m):   return "internalError: \(m)"
        case .transformError(let m):  return "transformError: \(m)"
        case .scriptError(let m):     return "scriptError: \(m)"
        case .scriptException(let m): return "scriptException: \(m)"
        case .resourceLimit(let m):   return "resourceLimit: \(m)"
        }
    }
}
