import Foundation
import JavaScriptCore

struct ScriptWidgetWeatherOptions {
    let latitude: Double
    let longitude: Double
    let hours: Int
    init(_ options: [String: Any]) throws {
        try ScriptWidgetSystemOptions.fields(options, ["latitude", "longitude", "hours"])
        latitude = (try ScriptWidgetSystemOptions.number(options["latitude"], range: -90...90) * 100).rounded() / 100
        longitude = (try ScriptWidgetSystemOptions.number(options["longitude"], range: -180...180) * 100).rounded() / 100
        let count = try ScriptWidgetSystemOptions.number(options["hours"] ?? 24, range: 1...48)
        guard count.rounded() == count else { throw ScriptWidgetSystemServiceError.invalidOptions }; hours = Int(count)
    }
    var url: URL { URL(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=\(latitude)&lon=\(longitude)")! }
    static func normalize(_ data: Data, options: Self, now: Date = Date()) throws -> [String: Any] {
        guard data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let properties = root["properties"] as? [String: Any], let series = properties["timeseries"] as? [[String: Any]], series.count <= 300 else { throw ScriptWidgetSystemServiceError.unavailable }
        var rows: [[String: Any]] = []
        for item in series {
            guard let time = item["time"] as? String, let date = (try? ScriptWidgetSystemOptions.date(time)), date >= now.addingTimeInterval(-3600),
                  let values = item["data"] as? [String: Any], let instant = values["instant"] as? [String: Any], let details = instant["details"] as? [String: Any] else { continue }
            let temperature = try ScriptWidgetSystemOptions.number(details["air_temperature"], range: -150...100)
            let wind = try ScriptWidgetSystemOptions.number(details["wind_speed"], range: 0...200)
            let next = values["next_1_hours"] as? [String: Any]
            let precipitation = (next?["details"] as? [String: Any])?["precipitation_amount"]
            let symbol = (next?["summary"] as? [String: Any])?["symbol_code"] as? String
            rows.append(["time": time, "temperatureC": temperature, "windMetersPerSecond": wind,
                         "precipitationMM": try precipitation.map { try ScriptWidgetSystemOptions.number($0, range: 0...1000) } as Any? ?? NSNull(), "condition": symbol.map { String($0.prefix(64)) } as Any? ?? NSNull()])
            if rows.count == options.hours { break }
        }
        guard !rows.isEmpty else { throw ScriptWidgetSystemServiceError.unavailable }
        return ["provider": "MET Norway", "attribution": ["text": "Weather data from MET Norway", "url": "https://www.met.no/en/free-meteorological-data/Download-services"], "latitude": options.latitude, "longitude": options.longitude,
                "fetchedAt": ISO8601DateFormatter().string(from: now), "isStale": false, "hours": rows]
    }
}
@objc protocol ScriptWidgetRuntimeWeatherExports: JSExport {
    static func forecast(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeWeather: NSObject, ScriptWidgetRuntimeWeatherExports {
    static func forecast(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.weather) { context, finish in
            let value = try ScriptWidgetWeatherOptions(options ?? [:])
            guard ScriptWidgetNetworkPolicy.packageAllows(value.url, package: context.state.package) else { throw ScriptWidgetSystemServiceError.permissionDenied }
            let key = context.access.privateKey("weatherCache")
            let backend = context.state.executionSnapshot!.context.defaults
            var cached: [String: Any]?
            if let data = try backend.readValue(forKey: key) as? Data, data.count <= 128 * 1024,
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["latitude"] as? Double == value.latitude, object["longitude"] as? Double == value.longitude,
               let stamp = object["fetchedAt"] as? String, let date = (try? ScriptWidgetSystemOptions.date(stamp)),
               Date().timeIntervalSince(date) >= 0, Date().timeIntervalSince(date) <= 6 * 3600,
               let hours = object["hours"] as? [[String: Any]], hours.count >= value.hours {
                var result = object; result["hours"] = Array(hours.prefix(value.hours)); result["isStale"] = Date().timeIntervalSince(date) >= 3600
                cached = result
                if result["isStale"] as? Bool == false { finish(.success(result)); return }
            }
            var task: URLSessionDataTask!
            task = context.state.fetchManager.makeTask(httpMethod: "GET", url: value.url, params: ["headers": ["User-Agent": "ScriptWidget/27.1 https://github.com/everettjf/scriptwidget"], "timeoutInterval": 3], redirectValidator: { ScriptWidgetNetworkPolicy.allowsRedirect($0, state: context.state) }) { data, response, error in
                context.state.executionSession.complete(task)
                do {
                    try context.validate()
                    guard ScriptWidgetNetworkPolicy.packageAllows(value.url, package: context.state.package), error == nil,
                          (response as? HTTPURLResponse)?.statusCode == 200, let data else { throw ScriptWidgetSystemServiceError.unavailable }
                    let normalized = try ScriptWidgetWeatherOptions.normalize(data, options: value)
                    let encoded = try JSONSerialization.data(withJSONObject: normalized)
                    guard encoded.count <= 128 * 1024 else { throw ScriptWidgetSystemServiceError.limitExceeded }
                    try backend.writeValue(encoded, forKey: key)
                    finish(.success(normalized))
                } catch { finish(cached.map(Result.success) ?? .failure(error)) }
            }
            guard context.state.executionSession.register(task) else { task.cancel(); throw ScriptWidgetSystemServiceError.queryLimit }
            task.resume()
        }
    }
}
