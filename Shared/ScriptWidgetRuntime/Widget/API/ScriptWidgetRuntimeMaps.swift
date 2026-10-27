import Foundation
import JavaScriptCore
import MapKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ScriptWidgetMapOptions {
    let coordinate: CLLocationCoordinate2D
    let radius: Double
    init(_ options: [String: Any], fields: Set<String>) throws {
        try ScriptWidgetSystemOptions.fields(options, fields.union(["latitude", "longitude", "radiusMeters"]))
        coordinate = .init(latitude: try ScriptWidgetSystemOptions.number(options["latitude"], range: -90...90), longitude: try ScriptWidgetSystemOptions.number(options["longitude"], range: -180...180))
        radius = try ScriptWidgetSystemOptions.number(options["radiusMeters"] ?? 2000, range: 100...50000)
    }
    var region: MKCoordinateRegion { .init(center: coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2) }
}
@objc protocol ScriptWidgetRuntimeMapsExports: JSExport {
    static func search(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func geocode(_ address: String) -> ScriptWidgetRuntimePromise
    static func reverseGeocode(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func snapshot(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeMaps: NSObject, ScriptWidgetRuntimeMapsExports {
    static func search(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        lookup { request in
            let value = try ScriptWidgetMapOptions(options ?? [:], fields: ["query"])
            request.naturalLanguageQuery = try ScriptWidgetSystemOptions.text(options?["query"], maximum: 256); request.region = value.region
        }
    }
    static func geocode(_ address: String) -> ScriptWidgetRuntimePromise {
        if #available(iOS 26.0, macOS 26.0, *) { return modernGeocode(address: address) }
        return lookup { request in request.naturalLanguageQuery = try ScriptWidgetSystemOptions.text(address, maximum: 256); request.resultTypes = .address }
    }
    private static func lookup(_ configure: @escaping (MKLocalSearch.Request) throws -> Void) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.maps) { context, finish in
            DispatchQueue.main.async {
                do {
                    try context.validate()
                    let request = MKLocalSearch.Request(); try configure(request)
                    let search = MKLocalSearch(request: request)
                    let cancellation = ScriptWidgetQueryCancellation(session: context.state.executionSession)
                    guard cancellation.install({ search.cancel() }) else { throw ScriptWidgetSystemServiceError.unavailable }
                    search.start { response, error in
                        cancellation.complete()
                        guard error == nil, let response else { finish(.failure(ScriptWidgetSystemServiceError.unavailable)); return }
                        let rows = response.mapItems.prefix(5).map(mapItem)
                        finish(.success(rows))
                    }
                } catch { finish(.failure(error)) }
            }
        }
    }
    static func reverseGeocode(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.maps) { context, finish in
            let value = try ScriptWidgetMapOptions(options ?? [:], fields: [])
            if #available(iOS 26.0, macOS 26.0, *) {
                DispatchQueue.main.async {
                    do {
                        try context.validate()
                        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude)) else { throw ScriptWidgetSystemServiceError.invalidOptions }
                        let cancellation = ScriptWidgetQueryCancellation(session: context.state.executionSession)
                        guard cancellation.install({ request.cancel() }) else { throw ScriptWidgetSystemServiceError.unavailable }
                        request.getMapItems { items, error in
                            cancellation.complete()
                            guard error == nil else { finish(.failure(ScriptWidgetSystemServiceError.unavailable)); return }
                            finish(.success((items ?? []).prefix(5).map(mapItem)))
                        }
                    } catch { finish(.failure(error)) }
                }
                return
            }
            let geocoder = CLGeocoder()
            let cancellation = ScriptWidgetQueryCancellation(session: context.state.executionSession)
            guard cancellation.install({ geocoder.cancelGeocode() }) else { throw ScriptWidgetSystemServiceError.unavailable }
            geocoder.reverseGeocodeLocation(CLLocation(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude)) { places, error in
                cancellation.complete()
                guard error == nil else { finish(.failure(ScriptWidgetSystemServiceError.unavailable)); return }
                finish(.success((places ?? []).prefix(5).map { place in
                    ["name": String((place.name ?? "").prefix(256)), "address": String([place.name, place.locality, place.administrativeArea, place.country].compactMap { $0 }.joined(separator: ", ").prefix(512)), "latitude": place.location?.coordinate.latitude ?? value.coordinate.latitude, "longitude": place.location?.coordinate.longitude ?? value.coordinate.longitude] as [String: Any]
                }))
            }
        }
    }
    private static func mapItem(_ item: MKMapItem) -> [String: Any] {
        let coordinate: CLLocationCoordinate2D
        let address: String
        if #available(iOS 26.0, macOS 26.0, *) { coordinate = item.location.coordinate; address = item.address?.fullAddress ?? "" }
        else { coordinate = item.placemark.coordinate; address = item.placemark.title ?? "" }
        return ["name": String((item.name ?? "").prefix(256)), "address": String(address.prefix(512)), "latitude": coordinate.latitude, "longitude": coordinate.longitude]
    }
    @available(iOS 26.0, macOS 26.0, *)
    private static func modernGeocode(address: String) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.maps) { context, finish in
            let text = try ScriptWidgetSystemOptions.text(address, maximum: 256)
            DispatchQueue.main.async {
                do {
                    try context.validate()
                    guard let request = MKGeocodingRequest(addressString: text) else { throw ScriptWidgetSystemServiceError.invalidOptions }
                    let cancellation = ScriptWidgetQueryCancellation(session: context.state.executionSession)
                    guard cancellation.install({ request.cancel() }) else { throw ScriptWidgetSystemServiceError.unavailable }
                    request.getMapItems { items, error in
                        cancellation.complete()
                        guard error == nil else { finish(.failure(ScriptWidgetSystemServiceError.unavailable)); return }
                        finish(.success((items ?? []).prefix(5).map(mapItem)))
                    }
                } catch { finish(.failure(error)) }
            }
        }
    }
    static func snapshot(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.maps) { context, finish in
            let value = try ScriptWidgetMapOptions(options ?? [:], fields: ["size"])
            let size = try ScriptWidgetSystemOptions.number(options?["size"] ?? 256, range: 128...512)
            guard size.rounded() == size else { throw ScriptWidgetSystemServiceError.invalidOptions }
            DispatchQueue.main.async {
                do {
                    try context.validate()
                    let config = MKMapSnapshotter.Options(); config.region = value.region; config.size = .init(width: size, height: size)
                    #if os(iOS)
                    config.scale = 1
                    #endif
                    let snapshotter = MKMapSnapshotter(options: config)
                    let cancellation = ScriptWidgetQueryCancellation(session: context.state.executionSession)
                    guard cancellation.install({ snapshotter.cancel() }) else { throw ScriptWidgetSystemServiceError.unavailable }
                    snapshotter.start { result, error in
                        cancellation.complete()
                        guard error == nil, let result else { finish(.failure(ScriptWidgetSystemServiceError.unavailable)); return }
                        #if os(macOS)
                        let bytes = result.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                        #else
                        let bytes = result.image.jpegData(compressionQuality: 0.7)
                        #endif
                        guard let bytes, bytes.count <= 262144 else { finish(.failure(ScriptWidgetSystemServiceError.limitExceeded)); return }
                        finish(.success(["image": "data:image/jpeg;base64," + bytes.base64EncodedString(), "width": size, "height": size, "provider": "Apple Maps"]))
                    }
                } catch { finish(.failure(error)) }
            }
        }
    }
}
