//
//  ScriptWidgetRuntimeDiagnostics.swift
//  ScriptWidget
//
//  Process-local logging and bounded performance telemetry for runtime
//  execution. Kept separate from the JavaScriptCore execution pipeline so
//  diagnostics can evolve without increasing the runtime coordinator's scope.
//

import Foundation
import os
import Darwin

enum SWLog {
    private static let logger = Logger(subsystem: "everettjf.scriptwidget", category: "runtime")
    static func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

/// Lightweight, process-local performance telemetry for the script pipeline.
/// The signposts are visible in Instruments while the bounded snapshots make
/// deterministic performance assertions possible in XCTest without parsing a
/// trace file.
final class ScriptWidgetRuntimeTrace {
    struct Snapshot: Equatable {
        let operation: String
        let durations: [String: Double]
        let counters: [String: Int]
    }

    private static let signpostLog = OSLog(subsystem: "everettjf.scriptwidget", category: "runtime.performance")
    private static let snapshotsLock = NSLock()
    private static var snapshots: [Snapshot] = []
    private static let maximumSnapshots = 100

    private let operation: String
    private let startedAt = ContinuousClock.now
    private var durations: [String: Double] = [:]
    private var counters: [String: Int] = [:]
    private let lock = NSLock()

    init(operation: String) {
        self.operation = operation
        if let resident = Self.residentMemoryBytes() { counters["resident.start.bytes"] = resident }
        os_signpost(.begin, log: Self.signpostLog, name: "RuntimeExecution", "%{public}@", operation as NSString)
    }

    @discardableResult
    func measure<T>(_ phase: String, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        os_signpost(.begin, log: Self.signpostLog, name: "RuntimePhase", "%{public}@", phase as NSString)
        defer {
            let elapsed = Self.milliseconds(start.duration(to: .now))
            lock.lock()
            durations[phase, default: 0] += elapsed
            lock.unlock()
            os_signpost(.end, log: Self.signpostLog, name: "RuntimePhase", "%{public}@ %.3f ms", phase as NSString, elapsed)
        }
        return try work()
    }

    func increment(_ counter: String, by value: Int = 1) {
        lock.lock()
        counters[counter, default: 0] += value
        lock.unlock()
    }

    func finish() {
        lock.lock()
        durations["total"] = Self.milliseconds(startedAt.duration(to: .now))
        if let resident = Self.residentMemoryBytes() { counters["resident.end.bytes"] = resident }
        let snapshot = Snapshot(operation: operation, durations: durations, counters: counters)
        lock.unlock()

        Self.snapshotsLock.lock()
        Self.snapshots.append(snapshot)
        if Self.snapshots.count > Self.maximumSnapshots {
            Self.snapshots.removeFirst(Self.snapshots.count - Self.maximumSnapshots)
        }
        Self.snapshotsLock.unlock()
        os_signpost(.end, log: Self.signpostLog, name: "RuntimeExecution", "%{public}@", operation as NSString)
    }

    static func recentSnapshots() -> [Snapshot] {
        snapshotsLock.lock()
        defer { snapshotsLock.unlock() }
        return snapshots
    }

    static func resetForTesting() {
        snapshotsLock.lock()
        snapshots.removeAll(keepingCapacity: true)
        snapshotsLock.unlock()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func residentMemoryBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : nil
    }
}
