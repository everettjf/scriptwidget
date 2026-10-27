import Foundation
import JavaScriptCore
#if canImport(HealthKit)
import HealthKit
#endif

struct ScriptWidgetHealthHistoryOptions {
    let metric: String
    let days: Int
    static let metrics: Set<String> = ["steps", "activeEnergy", "walkingDistance", "water", "bodyMass", "heartRate"]
    init(_ options: [String: Any]) throws {
        try ScriptWidgetSystemOptions.fields(options, ["metric", "days"])
        metric = try ScriptWidgetSystemOptions.text(options["metric"], maximum: 32)
        let n = try ScriptWidgetSystemOptions.number(options["days"] ?? 7, range: 1...31)
        guard Self.metrics.contains(metric), n.rounded() == n else { throw ScriptWidgetSystemServiceError.invalidOptions }; days = Int(n)
    }
}

enum ScriptWidgetRuntimeHealthHistory {
    static func read(_ options: [String: Any]) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.health, grant: false) { context, finish in
            let value = try ScriptWidgetHealthHistoryOptions(options)
            #if canImport(HealthKit) && !os(macOS)
            guard HKHealthStore.isHealthDataAvailable() else { throw ScriptWidgetSystemServiceError.unavailable }
            let identifier: HKQuantityTypeIdentifier
            let unit: HKUnit
            let aggregation: HKStatisticsOptions
            switch value.metric {
            case "steps": identifier = .stepCount; unit = .count(); aggregation = .cumulativeSum
            case "activeEnergy": identifier = .activeEnergyBurned; unit = .kilocalorie(); aggregation = .cumulativeSum
            case "walkingDistance": identifier = .distanceWalkingRunning; unit = .meter(); aggregation = .cumulativeSum
            case "water": identifier = .dietaryWater; unit = .literUnit(with: .milli); aggregation = .cumulativeSum
            case "bodyMass": identifier = .bodyMass; unit = .gramUnit(with: .kilo); aggregation = .discreteAverage
            default: identifier = .heartRate; unit = HKUnit.count().unitDivided(by: .minute()); aggregation = .discreteAverage
            }
            let store = HKHealthStore()
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let today = calendar.startOfDay(for: Date())
            let start = calendar.date(byAdding: .day, value: 1 - value.days, to: today)!
            let end = Date()
            let query = HKStatisticsCollectionQuery(quantityType: HKObjectType.quantityType(forIdentifier: identifier)!, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end), options: aggregation, anchorDate: start, intervalComponents: DateComponents(day: 1))
            let cancellation = ScriptWidgetQueryCancellation(session: context.state.executionSession)
            query.initialResultsHandler = { _, collection, error in
                cancellation.complete()
                guard error == nil, let collection else { finish(.failure(ScriptWidgetSystemServiceError.unavailable)); return }
                var rows: [[String: Any]] = []
                collection.enumerateStatistics(from: start, to: end) { stat, _ in
                    let quantity = aggregation == .cumulativeSum ? stat.sumQuantity() : stat.averageQuantity()
                    let n = quantity?.doubleValue(for: unit)
                    let parts = calendar.dateComponents([.year, .month, .day], from: stat.startDate)
                    rows.append(["date": String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), "value": n.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } as Any? ?? NSNull(), "hasSamples": n != nil])
                }
                guard rows.count <= value.days else { finish(.failure(ScriptWidgetSystemServiceError.limitExceeded)); return }
                finish(.success(["metric": value.metric, "unit": unit.unitString, "aggregation": aggregation == .cumulativeSum ? "sum" : "average", "timeZone": calendar.timeZone.identifier, "items": rows]))
            }
            guard cancellation.install({ store.stop(query) }) else { throw ScriptWidgetSystemServiceError.unavailable }
            store.execute(query)
            #else
            _ = context; _ = value; throw ScriptWidgetSystemServiceError.unavailable
            #endif
        }
    }
}
