//
//  ScriptWidgetRuntimeHealth.swift
//  ScriptWidget
//
//  Created by ScriptWidget contributors.
//

import Foundation
import CoreFoundation
import JavaScriptCore

/// HealthKit reveals whether a consent review is needed, not whether each
/// read type was granted. Empty/error-free queries cannot upgrade this state.
enum ScriptWidgetHealthReviewState: Equatable {
    case checking, unavailable, reviewRequired, reviewCompleted, failed

    var readAuthorization: String { "notDisclosed" }

    static func evaluate(available: Bool, shouldRequest: Bool?, failed: Bool = false) -> Self {
        guard available else { return .unavailable }
        guard !failed else { return .failed }
        guard let shouldRequest else { return .reviewRequired }
        return shouldRequest ? .reviewRequired : .reviewCompleted
    }
}

enum ScriptWidgetHealthAccessPolicy {
    static func permits(_ state: ScriptWidgetRunningState) -> Bool {
        guard state.previewStorage == nil, state.isCurrentExecution else { return false }
        guard state.package.hasManifest else { return true }
        guard let manifest = state.package.readManifest(), manifest.permissions.contains(.health) else { return false }
        return WidgetPackageManifestValidator.validate(manifest, package: state.package, checkEntryExists: false).isValid
    }
}

@objc protocol ScriptWidgetRuntimeHealthExports: JSExport {
    // Read-only HealthKit access (no write).
    static func isAvailable() -> Bool
    static func authorizationStatus() -> String
    static func requestAuthorization() -> ScriptWidgetRuntimePromise
    static func stepCountToday() -> ScriptWidgetRuntimePromise
    static func activeEnergyToday() -> ScriptWidgetRuntimePromise
    static func heartRateLatest() -> ScriptWidgetRuntimePromise
    static func sleepSummary(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func activitySummary(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func workouts(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func dailyStatistics(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
}

#if canImport(HealthKit)
import HealthKit

@objc public class ScriptWidgetRuntimeHealth: NSObject, ScriptWidgetRuntimeHealthExports {
    private static let healthStore = HKHealthStore()

    static func isAvailable() -> Bool {
        #if DEBUG
        if let state = JSContext.current()?.scriptWidgetRunningState, state.previewStorage == nil, let provider = state.expandedHealthProviderForTesting { return provider.isAvailable() }
        #endif
        guard JSContext.current()?.scriptWidgetRunningState?.previewStorage == nil else { return false }
        return HKHealthStore.isHealthDataAvailable()
    }

    static var authorizationReadTypes: Set<HKObjectType> {
        var readTypes = Set<HKObjectType>()
        if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
            readTypes.insert(stepType)
        }
        if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            readTypes.insert(energyType)
        }
        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            readTypes.insert(heartRateType)
        }
        readTypes.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        readTypes.insert(HKObjectType.activitySummaryType())
        readTypes.insert(HKObjectType.workoutType())
        for identifier in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming, .dietaryWater, .bodyMass] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { readTypes.insert(type) }
        }
        return readTypes
    }

    static func authorizationStatus() -> String {
        if let state = JSContext.current()?.scriptWidgetRunningState {
            if state.previewStorage != nil { return "unavailable" }
            if !ScriptWidgetHealthAccessPolicy.permits(state) { return "undeclared" }
        }
        return isAvailable() ? ScriptWidgetHealthReviewState.reviewCompleted.readAuthorization : "unavailable"
    }

    static func requestAuthorization() -> ScriptWidgetRuntimePromise {
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state = JSContext.current()?.scriptWidgetRunningState, state.isCurrentExecution else {
                reject.call(withArguments: ["[execution_inactive] Health execution is no longer current"])
                return
            }
            guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                reject.call(withArguments: ["[permission_denied] Install this widget and declare health in widget.json"])
                return
            }
            guard !state.isTimelineProjection && !state.isLiveActivityPresentation else {
                reject.call(withArguments: ["[timeline_read_only] Query Health in the current entry, then use a saved display snapshot"])
                return
            }
            guard state.executionSession.registerDataQuery() else {
                reject.call(withArguments: ["[query_limit] System data query limit exceeded"])
                return
            }
            guard HKHealthStore.isHealthDataAvailable() else {
                reject.call(withArguments: ["Health data not available on this device"])
                return
            }

            let readTypes = authorizationReadTypes

            #if IsWidgetTarget
            healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
                guard state.isCurrentExecution else { return }
                guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                    reject.call(withArguments: ["[permission_denied] Health access is unavailable for this execution"])
                    return
                }
                if let error = error {
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }
                switch status {
                case .unnecessary:
                    resolve.call(withArguments: [true])
                case .unknown, .shouldRequest:
                    resolve.call(withArguments: [false])
                @unknown default:
                    resolve.call(withArguments: [false])
                }
            }
            #else
            healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
                guard state.isCurrentExecution else { return }
                guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                    reject.call(withArguments: ["[permission_denied] Health access is unavailable for this execution"])
                    return
                }
                if let error = error {
                    reject.call(withArguments: [error.localizedDescription])
                } else {
                    resolve.call(withArguments: [success])
                }
            }
            #endif
        }
    }

    static func stepCountToday() -> ScriptWidgetRuntimePromise {
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state = JSContext.current()?.scriptWidgetRunningState, state.isCurrentExecution else {
                reject.call(withArguments: ["[execution_inactive] Health execution is no longer current"])
                return
            }
            guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                reject.call(withArguments: ["[permission_denied] Install this widget and declare health in widget.json"])
                return
            }
            guard !state.isTimelineProjection && !state.isLiveActivityPresentation else {
                reject.call(withArguments: ["[timeline_read_only] Query Health in the current entry, then use a saved display snapshot"])
                return
            }
            guard state.executionSession.registerDataQuery() else {
                reject.call(withArguments: ["[query_limit] System data query limit exceeded"])
                return
            }
            guard HKHealthStore.isHealthDataAvailable() else {
                reject.call(withArguments: ["[unavailable] Health data not available on this device"])
                return
            }
            guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
                reject.call(withArguments: ["Step count type unavailable"])
                return
            }

            let start = Calendar.current.startOfDay(for: Date())
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            let cancellation = ScriptWidgetQueryCancellation(session: state.executionSession)
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                cancellation.complete()
                guard state.isCurrentExecution else { return }
                guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                    reject.call(withArguments: ["[permission_denied] Health access is unavailable for this execution"])
                    return
                }
                if let error = error {
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }
                let quantity = result?.sumQuantity()
                let value = quantity?.doubleValue(for: HKUnit.count()) ?? 0
                resolve.call(withArguments: [[
                    "value": value,
                    "hasSamples": quantity != nil,
                    "unit": "count",
                    "start": isoString(start),
                    "end": isoString(Date())
                ]])
            }
            guard state.isCurrentExecution, cancellation.install({ healthStore.stop(query) }) else { return }
            healthStore.execute(query)
            if !state.isCurrentExecution { healthStore.stop(query); cancellation.complete() }
        }
    }

    static func activeEnergyToday() -> ScriptWidgetRuntimePromise {
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state = JSContext.current()?.scriptWidgetRunningState, state.isCurrentExecution else {
                reject.call(withArguments: ["[execution_inactive] Health execution is no longer current"])
                return
            }
            guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                reject.call(withArguments: ["[permission_denied] Install this widget and declare health in widget.json"])
                return
            }
            guard !state.isTimelineProjection && !state.isLiveActivityPresentation else {
                reject.call(withArguments: ["[timeline_read_only] Query Health in the current entry, then use a saved display snapshot"])
                return
            }
            guard state.executionSession.registerDataQuery() else {
                reject.call(withArguments: ["[query_limit] System data query limit exceeded"])
                return
            }
            guard HKHealthStore.isHealthDataAvailable() else {
                reject.call(withArguments: ["[unavailable] Health data not available on this device"])
                return
            }
            guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
                reject.call(withArguments: ["Active energy type unavailable"])
                return
            }

            let start = Calendar.current.startOfDay(for: Date())
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            let cancellation = ScriptWidgetQueryCancellation(session: state.executionSession)
            let query = HKStatisticsQuery(quantityType: energyType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                cancellation.complete()
                guard state.isCurrentExecution else { return }
                guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                    reject.call(withArguments: ["[permission_denied] Health access is unavailable for this execution"])
                    return
                }
                if let error = error {
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }
                let quantity = result?.sumQuantity()
                let value = quantity?.doubleValue(for: HKUnit.kilocalorie()) ?? 0
                resolve.call(withArguments: [[
                    "value": value,
                    "hasSamples": quantity != nil,
                    "unit": "kcal",
                    "start": isoString(start),
                    "end": isoString(Date())
                ]])
            }
            guard state.isCurrentExecution, cancellation.install({ healthStore.stop(query) }) else { return }
            healthStore.execute(query)
            if !state.isCurrentExecution { healthStore.stop(query); cancellation.complete() }
        }
    }

    static func heartRateLatest() -> ScriptWidgetRuntimePromise {
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state = JSContext.current()?.scriptWidgetRunningState, state.isCurrentExecution else {
                reject.call(withArguments: ["[execution_inactive] Health execution is no longer current"])
                return
            }
            guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                reject.call(withArguments: ["[permission_denied] Install this widget and declare health in widget.json"])
                return
            }
            guard !state.isTimelineProjection && !state.isLiveActivityPresentation else {
                reject.call(withArguments: ["[timeline_read_only] Query Health in the current entry, then use a saved display snapshot"])
                return
            }
            guard state.executionSession.registerDataQuery() else {
                reject.call(withArguments: ["[query_limit] System data query limit exceeded"])
                return
            }
            guard HKHealthStore.isHealthDataAvailable() else {
                reject.call(withArguments: ["[unavailable] Health data not available on this device"])
                return
            }
            guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
                reject.call(withArguments: ["Heart rate type unavailable"])
                return
            }

            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let cancellation = ScriptWidgetQueryCancellation(session: state.executionSession)
            let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                cancellation.complete()
                guard state.isCurrentExecution else { return }
                guard ScriptWidgetHealthAccessPolicy.permits(state) else {
                    reject.call(withArguments: ["[permission_denied] Health access is unavailable for this execution"])
                    return
                }
                if let error = error {
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    resolve.call(withArguments: [[
                        "value": 0,
                        "hasSamples": false,
                        "unit": "bpm",
                        "start": "",
                        "end": ""
                    ]])
                    return
                }
                let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
                let value = sample.quantity.doubleValue(for: unit)
                resolve.call(withArguments: [[
                    "value": value,
                    "hasSamples": true,
                    "unit": "bpm",
                    "start": isoString(sample.startDate),
                    "end": isoString(sample.endDate)
                ]])
            }
            guard state.isCurrentExecution, cancellation.install({ healthStore.stop(query) }) else { return }
            healthStore.execute(query)
            if !state.isCurrentExecution { healthStore.stop(query); cancellation.complete() }
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
#else
@objc public class ScriptWidgetRuntimeHealth: NSObject, ScriptWidgetRuntimeHealthExports {
    static func isAvailable() -> Bool {
        #if DEBUG
        if let state = JSContext.current()?.scriptWidgetRunningState, state.previewStorage == nil, let provider = state.expandedHealthProviderForTesting { return provider.isAvailable() }
        #endif
        return false
    }

    static func authorizationStatus() -> String {
        if let state = JSContext.current()?.scriptWidgetRunningState {
            if state.previewStorage != nil { return "unavailable" }
            if !ScriptWidgetHealthAccessPolicy.permits(state) { return "undeclared" }
        }
        return isAvailable() ? ScriptWidgetHealthReviewState.reviewCompleted.readAuthorization : "unavailable"
    }

    static func requestAuthorization() -> ScriptWidgetRuntimePromise {
        return rejectedPromise("HealthKit not available on this platform")
    }

    static func stepCountToday() -> ScriptWidgetRuntimePromise {
        return rejectedPromise("HealthKit not available on this platform")
    }

    static func activeEnergyToday() -> ScriptWidgetRuntimePromise {
        return rejectedPromise("HealthKit not available on this platform")
    }

    static func heartRateLatest() -> ScriptWidgetRuntimePromise {
        return rejectedPromise("HealthKit not available on this platform")
    }

    private static func rejectedPromise(_ message: String) -> ScriptWidgetRuntimePromise {
        return ScriptWidgetRuntimePromise { _, reject in
            if let state = JSContext.current()?.scriptWidgetRunningState, !ScriptWidgetHealthAccessPolicy.permits(state) {
                reject.call(withArguments: ["[permission_denied] Install this widget and declare health in widget.json"])
            } else if let state = JSContext.current()?.scriptWidgetRunningState, state.isTimelineProjection || state.isLiveActivityPresentation {
                reject.call(withArguments: ["[timeline_read_only] Read Health in the current entry"])
            } else { reject.call(withArguments: [message]) }
        }
    }
}
#endif

// MARK: - Bounded HealthKit summaries (Runtime 1.4)

enum ScriptWidgetHealthReadKind: String { case sleepSummary, activitySummary, workouts }
enum ScriptWidgetHealthReadError: LocalizedError {
    case invalidOptions, invalidData, unavailable, denied, queryFailed
    var errorDescription: String? {
        switch self {
        case .invalidOptions: "[invalid_options] Health queries need a valid bounded range or local date"
        case .invalidData: "[invalid_data] Health returned an invalid summary"
        case .unavailable: "[unavailable] Health data is unavailable on this device"
        case .denied: "[permission_denied] Install this widget and declare health in widget.json"
        case .queryFailed: "[query_failed] Health data could not be read. Review Health access in the app."
        }
    }
}

struct ScriptWidgetHealthReadQuery {
    let kind: ScriptWidgetHealthReadKind
    let start: Date
    let end: Date
    let limit: Int
    let calendar: Calendar
    var day: String { Self.dayString(start, calendar: calendar) }
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func parseDay(_ text: String, calendar: Calendar) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, p[0] >= 1,
              let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])), dayString(date, calendar: calendar) == text else { return nil }
        return date
    }
    static func parseDate(_ raw: Any) -> Date? {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let text = raw as? String, text.utf8.count <= 64,
              text.range(of: #"^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#, options: .regularExpression) != nil,
              parseDay(String(text.prefix(10)), calendar: utc) != nil else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    init(kind: ScriptWidgetHealthReadKind, options: [String: Any]?, now: Date = Date(), calendar: Calendar = .current) throws {
        self.kind = kind
        // HealthKit activity days and the API use a Gregorian local calendar.
        var local = Calendar(identifier: .gregorian); local.timeZone = calendar.timeZone
        self.calendar = local
        let options = options ?? [:]
        if kind == .activitySummary {
            guard Set(options.keys).isSubset(of: ["date"]) else { throw ScriptWidgetHealthReadError.invalidOptions }
            if let raw = options["date"] {
                guard let text = raw as? String, let date = Self.parseDay(text, calendar: local) else { throw ScriptWidgetHealthReadError.invalidOptions }
                start = date
            } else { start = local.startOfDay(for: now) }
            guard start <= now, let next = local.dateInterval(of: .day, for: start)?.end else { throw ScriptWidgetHealthReadError.invalidOptions }
            end = next; limit = 1
        } else {
            guard Set(options.keys).isSubset(of: kind == .workouts ? ["start", "end", "limit"] : ["start", "end"]) else { throw ScriptWidgetHealthReadError.invalidOptions }
            if let raw = options["end"] { guard let date = Self.parseDate(raw) else { throw ScriptWidgetHealthReadError.invalidOptions }; end = date } else { end = now }
            if let raw = options["start"] { guard let date = Self.parseDate(raw) else { throw ScriptWidgetHealthReadError.invalidOptions }; start = date }
            else { start = end.addingTimeInterval(kind == .sleepSummary ? -86400 : -7 * 86400) }
            let maximum = Double(kind == .sleepSummary ? 7 : 31) * 86400
            guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start, end <= now.addingTimeInterval(1), end.timeIntervalSince(start) <= maximum else { throw ScriptWidgetHealthReadError.invalidOptions }
            if let raw = options["limit"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue, (1...50).contains(number.intValue) else { throw ScriptWidgetHealthReadError.invalidOptions }
                limit = number.intValue
            } else { limit = kind == .workouts ? 5 : 256 }
        }
    }
    var bounds: [String: Any] { ["start": Self.iso(start), "end": Self.iso(end), "timeZone": calendar.timeZone.identifier] }
    static func iso(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
}

struct ScriptWidgetSleepSegment {
    enum Stage: String, CaseIterable { case inBed, unspecified, core, deep, rem, awake }
    let start: Date
    let end: Date
    let stage: Stage
    let source: String
}
struct ScriptWidgetActivityDay {
    let moveMode: String
    let move: Double
    let moveGoal: Double
    let exercise: Double
    let exerciseGoal: Double?
    let stand: Double
    let standGoal: Double?
    var valid: Bool {
        ["activeEnergy", "moveTime"].contains(moveMode) && [move, moveGoal, exercise, stand].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1e9 }
            && [exerciseGoal, standGoal].allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0 && $0! <= 1e9) }
    }
    var object: [String: Any] {
        ["moveMode": moveMode, "move": ["value": move, "goal": moveGoal, "unit": moveMode == "moveTime" ? "min" : "kcal"],
         "exercise": ["value": exercise, "goal": exerciseGoal as Any? ?? NSNull(), "unit": "min"],
         "stand": ["value": stand, "goal": standGoal as Any? ?? NSNull(), "unit": "count"]]
    }
}
struct ScriptWidgetHealthWorkout {
    let id: String
    let activity: String
    let start: Date
    let end: Date
    let duration: Double
    let energyKcal: Double?
    let distanceMeters: Double?
    func valid(in query: ScriptWidgetHealthReadQuery) -> Bool {
        UUID(uuidString: id) != nil && Self.activities.contains(activity) && start >= query.start && end <= query.end && end > start
            && duration.isFinite && duration >= 0 && duration <= end.timeIntervalSince(start) + 0.001
            && [energyKcal, distanceMeters].allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0 && $0! <= 1e9) }
    }
    static let activities: Set<String> = ["walking", "running", "cycling", "swimming", "hiking", "yoga", "strength", "rowing", "elliptical", "pilates", "dance", "other"]
    var object: [String: Any] { ["id": id, "activity": activity, "start": ScriptWidgetHealthReadQuery.iso(start), "end": ScriptWidgetHealthReadQuery.iso(end), "duration": duration, "energyKcal": energyKcal as Any? ?? NSNull(), "distanceMeters": distanceMeters as Any? ?? NSNull()] }
}

enum ScriptWidgetHealthReadout {
    case sleep([ScriptWidgetSleepSegment], truncated: Bool)
    case activity(ScriptWidgetActivityDay?)
    case workouts([ScriptWidgetHealthWorkout], truncated: Bool)
    func object(for query: ScriptWidgetHealthReadQuery) throws -> [String: Any] {
        switch (query.kind, self) {
        case let (.sleepSummary, .sleep(segments, truncated)):
            guard segments.count <= 256, segments.allSatisfy({ $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start && $0.source.utf8.count <= 256 }) else { throw ScriptWidgetHealthReadError.invalidData }
            let included = segments.filter { $0.start < query.end && $0.end > query.start }
            let edges = Set(included.flatMap { [max(query.start, $0.start), min(query.end, $0.end)] }).sorted()
            var seconds = Dictionary(uniqueKeysWithValues: ScriptWidgetSleepSegment.Stage.allCases.map { ($0, 0.0) })
            var conflictSeconds = 0.0
            // In-bed is an independent union. Competing detailed stages are
            // resolved once per instant, never added across duplicate sources.
            let priority: [ScriptWidgetSleepSegment.Stage] = [.awake, .rem, .deep, .core, .unspecified]
            for (a, b) in zip(edges, edges.dropFirst()) where b > a {
                let stages = Set(included.filter { $0.start < b && $0.end > a }.map(\.stage))
                let span = b.timeIntervalSince(a)
                if stages.contains(.inBed) { seconds[.inBed, default: 0] += span }
                let active = priority.filter { stages.contains($0) }
                if let selected = active.first { seconds[selected, default: 0] += span }
                if active.count > 1 { conflictSeconds += span }
            }
            var result = query.bounds
            result["hasSamples"] = !included.isEmpty; result["truncated"] = truncated
            result["sourceCount"] = Set(included.map(\.source)).count
            result["inBedSeconds"] = seconds[.inBed]!; result["awakeSeconds"] = seconds[.awake]!
            result["stages"] = Dictionary(uniqueKeysWithValues: [ScriptWidgetSleepSegment.Stage.unspecified, .core, .deep, .rem].map { ($0.rawValue, seconds[$0]!) })
            result["totalSleepSeconds"] = [ScriptWidgetSleepSegment.Stage.unspecified, .core, .deep, .rem].reduce(0) { $0 + seconds[$1]! }
            result["conflictSeconds"] = conflictSeconds
            result["aggregation"] = "union-awake-rem-deep-core-unspecified"
            return result
        case let (.activitySummary, .activity(day)):
            guard day?.valid != false else { throw ScriptWidgetHealthReadError.invalidData }
            var result = day?.object ?? ["moveMode": "activeEnergy", "move": ["value": 0, "goal": NSNull(), "unit": "kcal"], "exercise": ["value": 0, "goal": NSNull(), "unit": "min"], "stand": ["value": 0, "goal": NSNull(), "unit": "count"]]
            result["date"] = query.day; result["timeZone"] = query.calendar.timeZone.identifier; result["hasSamples"] = day != nil
            return result
        case let (.workouts, .workouts(items, truncated)):
            guard items.count <= query.limit, Set(items.map(\.id)).count == items.count, items.allSatisfy({ $0.valid(in: query) }) else { throw ScriptWidgetHealthReadError.invalidData }
            var result = query.bounds; result["hasSamples"] = !items.isEmpty; result["truncated"] = truncated
            result["items"] = items.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }.map(\.object)
            return result
        default: throw ScriptWidgetHealthReadError.invalidData
        }
    }
}

protocol ScriptWidgetExpandedHealthProviding: AnyObject {
    func isAvailable() -> Bool
    func fetch(_ query: ScriptWidgetHealthReadQuery, session: ScriptWidgetExecutionSession, completion: @escaping (Result<ScriptWidgetHealthReadout, Error>) -> Void)
}

final class ScriptWidgetExpandedHealthSystemProvider: ScriptWidgetExpandedHealthProviding {
    #if canImport(HealthKit)
    private let store = HKHealthStore()
    func isAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }
    func fetch(_ query: ScriptWidgetHealthReadQuery, session: ScriptWidgetExecutionSession, completion: @escaping (Result<ScriptWidgetHealthReadout, Error>) -> Void) {
        let cancellation = ScriptWidgetQueryCancellation(session: session)
        let predicate = HKQuery.predicateForSamples(withStart: query.start, end: query.end,
            options: query.kind == .workouts ? [.strictStartDate, .strictEndDate] : [])
        let request: HKQuery
        switch query.kind {
        case .sleepSummary:
            let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
            request = HKSampleQuery(sampleType: type, predicate: predicate, limit: 257, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                cancellation.complete(); guard session.isActive else { return }
                guard error == nil else { completion(.failure(ScriptWidgetHealthReadError.queryFailed)); return }
                let rows = samples ?? []
                var segments: [ScriptWidgetSleepSegment] = []
                for row in rows.prefix(256) {
                    guard let sample = row as? HKCategorySample else { completion(.failure(ScriptWidgetHealthReadError.invalidData)); return }
                    let stage: ScriptWidgetSleepSegment.Stage
                    switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                    case .inBed: stage = .inBed
                    case .awake: stage = .awake
                    case .asleepCore: stage = .core
                    case .asleepDeep: stage = .deep
                    case .asleepREM: stage = .rem
                    case .asleepUnspecified: stage = .unspecified
                    default: continue
                    }
                    segments.append(.init(start: sample.startDate, end: sample.endDate, stage: stage, source: sample.sourceRevision.source.bundleIdentifier))
                }
                completion(.success(.sleep(segments, truncated: rows.count > 256)))
            }
        case .activitySummary:
            var components = query.calendar.dateComponents([.era, .year, .month, .day], from: query.start)
            components.calendar = query.calendar; components.timeZone = query.calendar.timeZone
            request = HKActivitySummaryQuery(predicate: HKQuery.predicateForActivitySummary(with: components)) { _, summaries, error in
                cancellation.complete(); guard session.isActive else { return }
                guard error == nil else { completion(.failure(ScriptWidgetHealthReadError.queryFailed)); return }
                guard let summary = summaries?.first else { completion(.success(.activity(nil))); return }
                let day = summary.dateComponents(for: query.calendar)
                let wanted = query.calendar.dateComponents([.year, .month, .day], from: query.start)
                guard day.year == wanted.year, day.month == wanted.month, day.day == wanted.day else { completion(.failure(ScriptWidgetHealthReadError.invalidData)); return }
                let moveTime = summary.activityMoveMode == .appleMoveTime
                completion(.success(.activity(.init(moveMode: moveTime ? "moveTime" : "activeEnergy",
                    move: moveTime ? summary.appleMoveTime.doubleValue(for: .minute()) : summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                    moveGoal: moveTime ? summary.appleMoveTimeGoal.doubleValue(for: .minute()) : summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
                    exercise: summary.appleExerciseTime.doubleValue(for: .minute()), exerciseGoal: summary.exerciseTimeGoal?.doubleValue(for: .minute()),
                    stand: summary.appleStandHours.doubleValue(for: .count()), standGoal: summary.standHoursGoal?.doubleValue(for: .count())))))
            }
        case .workouts:
            request = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: query.limit + 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                cancellation.complete(); guard session.isActive else { return }
                guard error == nil else { completion(.failure(ScriptWidgetHealthReadError.queryFailed)); return }
                let rows = samples ?? []
                var items: [ScriptWidgetHealthWorkout] = []
                for row in rows.prefix(query.limit) {
                    guard let workout = row as? HKWorkout else { completion(.failure(ScriptWidgetHealthReadError.invalidData)); return }
                    let activity: String
                    let distanceType: HKQuantityTypeIdentifier?
                    switch workout.workoutActivityType {
                    case .walking: activity = "walking"; distanceType = .distanceWalkingRunning
                    case .running: activity = "running"; distanceType = .distanceWalkingRunning
                    case .cycling: activity = "cycling"; distanceType = .distanceCycling
                    case .swimming: activity = "swimming"; distanceType = .distanceSwimming
                    case .hiking: activity = "hiking"; distanceType = .distanceWalkingRunning
                    case .yoga: activity = "yoga"; distanceType = nil
                    case .traditionalStrengthTraining, .functionalStrengthTraining: activity = "strength"; distanceType = nil
                    case .rowing: activity = "rowing"; distanceType = nil
                    case .elliptical: activity = "elliptical"; distanceType = nil
                    case .pilates: activity = "pilates"; distanceType = nil
                    case .dance: activity = "dance"; distanceType = nil
                    default: activity = "other"; distanceType = nil
                    }
                    let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
                    let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
                    let distance = distanceType.flatMap { HKObjectType.quantityType(forIdentifier: $0) }.flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
                    items.append(.init(id: workout.uuid.uuidString.lowercased(), activity: activity, start: workout.startDate, end: workout.endDate, duration: workout.duration, energyKcal: energy, distanceMeters: distance))
                }
                completion(.success(.workouts(items, truncated: rows.count > query.limit)))
            }
        }
        guard session.isActive, cancellation.install({ self.store.stop(request) }) else { return }
        store.execute(request)
        if !session.isActive { store.stop(request); cancellation.complete() }
    }
    #else
    func isAvailable() -> Bool { false }
    func fetch(_ query: ScriptWidgetHealthReadQuery, session: ScriptWidgetExecutionSession, completion: @escaping (Result<ScriptWidgetHealthReadout, Error>) -> Void) { completion(.failure(ScriptWidgetHealthReadError.unavailable)) }
    #endif
}

extension ScriptWidgetRuntimeHealth {
    @objc static func sleepSummary(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { expandedRead(.sleepSummary, options) }
    @objc static func activitySummary(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { expandedRead(.activitySummary, options) }
    @objc static func workouts(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { expandedRead(.workouts, options) }
    private static func expandedRead(_ kind: ScriptWidgetHealthReadKind, _ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        let state = JSContext.current()?.scriptWidgetRunningState
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state, state.executionSnapshot != nil, state.package.hasManifest, ScriptWidgetHealthAccessPolicy.permits(state) else { reject.call(withArguments: [ScriptWidgetHealthReadError.denied.localizedDescription]); return }
            guard !state.isTimelineProjection, !state.isLiveActivityPresentation else { reject.call(withArguments: ["[timeline_read_only] Read Health in the current app/widget entry"]); return }
            let query: ScriptWidgetHealthReadQuery
            do { query = try .init(kind: kind, options: options) } catch { reject.call(withArguments: [ScriptWidgetHealthReadError.invalidOptions.localizedDescription]); return }
            guard state.executionSession.registerDataQuery() else { reject.call(withArguments: ["[query_limit] Too many system data queries"]); return }
            let provider: any ScriptWidgetExpandedHealthProviding
            #if DEBUG
            provider = state.expandedHealthProviderForTesting ?? ScriptWidgetExpandedHealthSystemProvider()
            #else
            provider = ScriptWidgetExpandedHealthSystemProvider()
            #endif
            guard provider.isAvailable() else { reject.call(withArguments: [ScriptWidgetHealthReadError.unavailable.localizedDescription]); return }
            provider.fetch(query, session: state.executionSession) { result in
                state.executionSession.callbackQueue.async {
                    guard state.isCurrentExecution else { return }
                    guard ScriptWidgetHealthAccessPolicy.permits(state), state.package.hasManifest else { reject.call(withArguments: [ScriptWidgetHealthReadError.denied.localizedDescription]); return }
                    guard provider.isAvailable() else { reject.call(withArguments: [ScriptWidgetHealthReadError.unavailable.localizedDescription]); return }
                    do { resolve.call(withArguments: [try result.get().object(for: query)]) }
                    catch { reject.call(withArguments: [(error as? ScriptWidgetHealthReadError)?.localizedDescription ?? ScriptWidgetHealthReadError.queryFailed.localizedDescription]) }
                }
            }
        }
    }
}

extension ScriptWidgetRuntimeHealth { @objc static func dailyStatistics(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { ScriptWidgetRuntimeHealthHistory.read(options ?? [:]) } }
