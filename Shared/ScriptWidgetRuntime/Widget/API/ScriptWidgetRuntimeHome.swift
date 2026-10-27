import Foundation
import JavaScriptCore
#if os(iOS)
import HomeKit
#endif

struct ScriptWidgetHomeChoice: Identifiable {
    let id: String
    let name: String
    let kind: String
}
#if os(iOS)
final class ScriptWidgetHomeProvider: NSObject, HMHomeManagerDelegate {
    static let shared = ScriptWidgetHomeProvider()
    private var manager: HMHomeManager!
    private var loaded = false
    private var waiters: [(Result<[ScriptWidgetHomeChoice], Error>) -> Void] = []
    override init() { super.init(); manager = HMHomeManager(); manager.delegate = self }
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { loaded = true; let callbacks = waiters; waiters = []; callbacks.forEach { $0(.success(choices())) } }
    func load(_ finish: @escaping (Result<[ScriptWidgetHomeChoice], Error>) -> Void) {
        if loaded { finish(.success(choices())) }
        else if waiters.count < 8 {
            waiters.append(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.loaded else { return }; let pending = self.waiters; self.waiters = []; pending.forEach { $0(.failure(ScriptWidgetSystemServiceError.unavailable)) }
            }
        }
        else { finish(.failure(ScriptWidgetSystemServiceError.limitExceeded)) }
    }
    private var characteristics: [(HMCharacteristic, String)] {
        var result: [(HMCharacteristic, String)] = []
        let types = [HMCharacteristicTypePowerState, HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeCurrentRelativeHumidity, HMCharacteristicTypeMotionDetected, HMCharacteristicTypeContactState]
        for home in manager.homes.prefix(8) {
            for accessory in home.accessories.prefix(64) {
                for service in accessory.services.prefix(32) {
                    for characteristic in service.characteristics.prefix(32) where types.contains(characteristic.characteristicType) {
                        result.append((characteristic, String((home.name + " · " + accessory.name + " · " + service.name).prefix(256))))
                        if result.count == 200 { return result }
                    }
                }
            }
        }
        return result
    }
    func choices() -> [ScriptWidgetHomeChoice] {
        let values = characteristics.prefix(200).map { ScriptWidgetHomeChoice(id: $0.0.uniqueIdentifier.uuidString.lowercased(), name: $0.1, kind: $0.0.characteristicType == HMCharacteristicTypePowerState ? "power" : "sensor") }
        let scenes = manager.homes.prefix(8).flatMap { home in home.actionSets.prefix(32).map { ScriptWidgetHomeChoice(id: "scene-" + $0.uniqueIdentifier.uuidString.lowercased(), name: String((home.name + " · " + $0.name).prefix(256)), kind: "scene") } }
        return Array((values + scenes).prefix(200))
    }
    func values(_ ids: [String]) throws -> [[String: Any]] {
        guard manager.authorizationStatus.contains(.authorized) else { throw ScriptWidgetSystemServiceError.permissionDenied }
        return choices().filter { ids.contains($0.id) }.map { choice in
            let characteristic = characteristics.first { $0.0.uniqueIdentifier.uuidString.lowercased() == choice.id }?.0
            let metric: String
            let unit: String
            switch characteristic?.characteristicType {
            case HMCharacteristicTypePowerState: metric = "power"; unit = "boolean"
            case HMCharacteristicTypeCurrentTemperature: metric = "temperature"; unit = "celsius"
            case HMCharacteristicTypeCurrentRelativeHumidity: metric = "humidity"; unit = "percent"
            case HMCharacteristicTypeMotionDetected: metric = "motion"; unit = "boolean"
            case HMCharacteristicTypeContactState: metric = "contactState"; unit = "enum"
            default: metric = "scene"; unit = "none"
            }
            return ["metric": metric, "unit": unit, "id": choice.id, "name": choice.name, "kind": choice.kind, "value": characteristic?.value as Any? ?? NSNull(), "isCached": true]
        }
    }
    func setPower(_ id: String, on: Bool, validate: () throws -> Void, finish: @escaping (Result<Any, Error>) -> Void) throws {
        guard manager.authorizationStatus.contains(.authorized), let characteristic = characteristics.first(where: { $0.0.uniqueIdentifier.uuidString.lowercased() == id })?.0,
              characteristic.characteristicType == HMCharacteristicTypePowerState, characteristic.properties.contains(HMCharacteristicPropertyWritable) else { throw ScriptWidgetSystemServiceError.permissionDenied }
        try validate()
        characteristic.writeValue(on) { error in finish(error == nil ? .success(["id": id, "status": "acknowledged", "value": on]) : .failure(ScriptWidgetSystemServiceError.outcomeUnknown)) }
    }
    func scene(_ id: String, validate: () throws -> Void, finish: @escaping (Result<Any, Error>) -> Void) throws {
        guard manager.authorizationStatus.contains(.authorized) else { throw ScriptWidgetSystemServiceError.permissionDenied }
        for home in manager.homes {
            if let scene = home.actionSets.first(where: { "scene-" + $0.uniqueIdentifier.uuidString.lowercased() == id }) {
                try validate()
                home.executeActionSet(scene) { error in finish(error == nil ? .success(id) : .failure(ScriptWidgetSystemServiceError.outcomeUnknown)) }; return
            }
        }
        throw ScriptWidgetSystemServiceError.permissionDenied
    }
}
#endif
@objc protocol ScriptWidgetRuntimeHomeExports: JSExport {
    static func items() -> ScriptWidgetRuntimePromise
    static func setPower(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
    static func runScene(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise
}
@objc final class ScriptWidgetRuntimeHome: NSObject, ScriptWidgetRuntimeHomeExports {
    static func items() -> ScriptWidgetRuntimePromise { perform("items", [:]) }
    static func setPower(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { perform("power", options ?? [:]) }
    static func runScene(_ options: [String: Any]?) -> ScriptWidgetRuntimePromise { perform("scene", options ?? [:]) }
    private static func perform(_ method: String, _ options: [String: Any]) -> ScriptWidgetRuntimePromise {
        ScriptWidgetSystemServices.perform(.home, writing: method != "items") { context, finish in
            #if os(iOS)
            let ids = try context.access.load().home
            if method == "items" && ids.isEmpty { finish(.success([[String: Any]]())); return }
            if method != "items" {
                try ScriptWidgetSystemOptions.fields(options, method == "scene" ? ["id", "requestID"] : ["id", "on"])
                guard let id = options["id"] as? String, ids.contains(id) else { throw ScriptWidgetSystemServiceError.permissionDenied }
            }
            if method == "scene" {
                let request = try ScriptWidgetNativeMutation(options, scope: "home", operation: "scene")
                let result = try ScriptWidgetReminderMutationLedger.perform(request, container: context.access.container, backend: context.state.executionSnapshot!.context.defaults,
                    key: context.access.privateKey("homeReceipts"), validate: context.validate) { beforeCommit in
                    try beforeCommit()
                    let box = ScriptWidgetSystemCompletionBox()
                    DispatchQueue.main.async {
                        let provider = ScriptWidgetHomeProvider.shared
                        provider.load { result in
                            do { _ = try result.get(); try provider.scene(options["id"] as! String, validate: context.validate) { result in box.finish(result.flatMap { ($0 as? String).map(Result.success) ?? .failure(ScriptWidgetSystemServiceError.unavailable) }) } }
                            catch { box.finish(.failure(error)) }
                        }
                    }
                    return try box.wait()
                }
                finish(.success(["id": options["id"]!, "status": "acknowledged", "replayed": result["replayed"] ?? false])); return
            }
            let on = method == "power" ? try ScriptWidgetSystemOptions.boolean(options["on"]) : false
            DispatchQueue.main.async {
                let provider = ScriptWidgetHomeProvider.shared
                provider.load { result in
                    do {
                        _ = try result.get(); try context.validate()
                        if method == "items" { finish(.success(try provider.values(ids))) }
                        else { try provider.setPower(options["id"] as! String, on: on, validate: context.validate, finish: finish) }
                    } catch { finish(.failure(error)) }
                }
            }
            #else
            _ = context; throw ScriptWidgetSystemServiceError.unavailable
            #endif
        }
    }
}
