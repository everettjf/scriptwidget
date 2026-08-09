//
//  ScriptWidgetRunningState.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/4/7.
//
//  Per-execution state — package handle and console logger — that the
//  JS runtime APIs (`$file`, `$console`) need to reach. The state hangs
//  off the owning `JSContext` via an associated object; JSExport
//  callbacks find it by way of `JSContext.current()`. There is no
//  global; concurrent runtimes do not see each other's state.
//

import Foundation
import JavaScriptCore

enum ScriptWidgetExecutionCancellation: String, Equatable {
    case timeout
    case superseded
    case explicit
    case completed
}

final class ScriptWidgetExecutionSession {
    static let maximumConcurrentNetworkRequests = 8
    static let maximumTotalNetworkRequests = 32

    let id = UUID()
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]
    private(set) var totalNetworkRequests = 0
    private(set) var cancellation: ScriptWidgetExecutionCancellation?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellation == nil
    }

    func register(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard cancellation == nil,
              tasks.count < Self.maximumConcurrentNetworkRequests,
              totalNetworkRequests < Self.maximumTotalNetworkRequests else { return false }
        tasks[ObjectIdentifier(task)] = task
        totalNetworkRequests += 1
        return true
    }

    func complete(_ task: URLSessionTask) {
        lock.lock()
        tasks.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    func cancel(_ reason: ScriptWidgetExecutionCancellation) {
        lock.lock()
        guard cancellation == nil else {
            lock.unlock()
            return
        }
        cancellation = reason
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }

    func finish() {
        cancel(.completed)
    }
}


class ScriptWidgetConsoleLogger {
    static let maximumEntries = 500
    static let maximumEntryBytes = 8 * 1_024
    var logs: [String] = []

    func addLog(_ log: String) {
        let bounded = String(decoding: log.utf8.prefix(Self.maximumEntryBytes), as: UTF8.self)
        DispatchQueue.main.async {
            self.logs.append(bounded)
            if self.logs.count > Self.maximumEntries {
                self.logs.removeFirst(self.logs.count - Self.maximumEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}


class ScriptWidgetRunningState {

    var logger: ScriptWidgetConsoleLogger
    var package: ScriptWidgetPackage
    let executionSession: ScriptWidgetExecutionSession

    var storageNamespace: String { "script.\(package.name)." }

    init(package: ScriptWidgetPackage) {
        self.logger = ScriptWidgetConsoleLogger()
        self.package = package
        self.executionSession = ScriptWidgetExecutionSession()
    }
}

private var scriptWidgetRunningStateAssociationKey: UInt8 = 0

extension JSContext {
    /// Per-runtime running state. Read inside JSExport callbacks via
    /// `JSContext.current()?.scriptWidgetRunningState`.
    var scriptWidgetRunningState: ScriptWidgetRunningState? {
        get {
            objc_getAssociatedObject(self, &scriptWidgetRunningStateAssociationKey) as? ScriptWidgetRunningState
        }
        set {
            objc_setAssociatedObject(
                self,
                &scriptWidgetRunningStateAssociationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
