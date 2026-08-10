import AppIntents
import Foundation
import WidgetKit

private enum ScriptWidgetControlCatalog {
    static func controls(type: WidgetPackageControlType) -> [(package: ScriptWidgetPackage, control: WidgetPackageControl)] {
        sharedScriptManager.listScripts().flatMap { model in
            let manifest = model.package.effectiveManifest()
            return (manifest.controls ?? [])
                .filter { $0.type == type }
                .map { (model.package, $0) }
        }
    }

    static func resolve(id: String, type: WidgetPackageControlType) -> (ScriptWidgetPackage, WidgetPackageControl)? {
        controls(type: type).first { entityID(package: $0.package, control: $0.control) == id }
    }

    static func entityID(package: ScriptWidgetPackage, control: WidgetPackageControl) -> String {
        "\(package.name)::\(control.id)"
    }

    static func storageValue(package: ScriptWidgetPackage, key: String) -> Bool {
        let defaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard
        let value = defaults.object(forKey: "script.\(package.name).\(key)")
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return string == "true" || string == "1" }
        return false
    }

    static func setStorageValue(_ value: Bool, package: ScriptWidgetPackage, key: String) {
        let defaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard
        defaults.set(value ? "true" : "false", forKey: "script.\(package.name).\(key)")
    }

    static func runAction(package: ScriptWidgetPackage, control: WidgetPackageControl, value: Bool? = nil) {
        guard let source = package.readMainFileResult().content else { return }
        var environments = [
            "widget-size": "control",
            "widget-param": "",
            "control-id": control.id,
        ]
        if let value { environments["control-value"] = value ? "true" : "false" }
        let runtime = ScriptWidgetRuntime(package: package, environments: environments)
        _ = runtime.executeJSXSyncForFunction(source, control.action)
    }
}

struct ScriptWidgetButtonControlEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget Button"
    static var defaultQuery = ScriptWidgetButtonControlQuery()

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }
}

struct ScriptWidgetButtonControlQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScriptWidgetButtonControlEntity] {
        identifiers.compactMap { id in
            guard let (_, control) = ScriptWidgetControlCatalog.resolve(id: id, type: .button) else { return nil }
            return .init(
                id: id,
                title: control.title,
                subtitle: control.subtitle,
                systemImage: control.systemImage
            )
        }
    }

    func suggestedEntities() async throws -> [ScriptWidgetButtonControlEntity] {
        ScriptWidgetControlCatalog.controls(type: .button).map { package, control in
            .init(
                id: ScriptWidgetControlCatalog.entityID(package: package, control: control),
                title: control.title,
                subtitle: control.subtitle,
                systemImage: control.systemImage
            )
        }
    }
}

struct ScriptWidgetToggleControlEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget Toggle"
    static var defaultQuery = ScriptWidgetToggleControlQuery()

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }
}

struct ScriptWidgetToggleControlQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScriptWidgetToggleControlEntity] {
        identifiers.compactMap { id in
            guard let (_, control) = ScriptWidgetControlCatalog.resolve(id: id, type: .toggle) else { return nil }
            return .init(id: id, title: control.title, subtitle: control.subtitle, systemImage: control.systemImage)
        }
    }

    func suggestedEntities() async throws -> [ScriptWidgetToggleControlEntity] {
        ScriptWidgetControlCatalog.controls(type: .toggle).map { package, control in
            .init(
                id: ScriptWidgetControlCatalog.entityID(package: package, control: control),
                title: control.title,
                subtitle: control.subtitle,
                systemImage: control.systemImage
            )
        }
    }
}

struct SelectScriptWidgetButtonIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Select Widget Button"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Button") var control: ScriptWidgetButtonControlEntity?

    init() {}
}

struct SelectScriptWidgetToggleIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Select Widget Toggle"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Toggle") var control: ScriptWidgetToggleControlEntity?

    init() {}
}

struct ScriptWidgetButtonControlValue {
    let id: String
    let title: String
    let systemImage: String
}

struct ScriptWidgetToggleControlValue {
    let id: String
    let title: String
    let systemImage: String
    let isOn: Bool
}

struct ScriptWidgetButtonControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectScriptWidgetButtonIntent) -> ScriptWidgetButtonControlValue {
        let control = configuration.control
        return .init(id: control?.id ?? "", title: control?.title ?? "ScriptWidget", systemImage: control?.systemImage ?? "play.fill")
    }

    func currentValue(configuration: SelectScriptWidgetButtonIntent) async throws -> ScriptWidgetButtonControlValue {
        previewValue(configuration: configuration)
    }
}

struct ScriptWidgetToggleControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectScriptWidgetToggleIntent) -> ScriptWidgetToggleControlValue {
        let control = configuration.control
        return .init(id: control?.id ?? "", title: control?.title ?? "ScriptWidget", systemImage: control?.systemImage ?? "switch.2", isOn: false)
    }

    func currentValue(configuration: SelectScriptWidgetToggleIntent) async throws -> ScriptWidgetToggleControlValue {
        let preview = previewValue(configuration: configuration)
        guard let (package, control) = ScriptWidgetControlCatalog.resolve(id: preview.id, type: .toggle),
              let stateKey = control.stateKey else { return preview }
        return .init(
            id: preview.id,
            title: control.title,
            systemImage: control.systemImage,
            isOn: ScriptWidgetControlCatalog.storageValue(package: package, key: stateKey)
        )
    }
}

struct RunScriptWidgetControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Widget Control"
    static var isDiscoverable: Bool { false }
    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .widgetKitExtension }
    #endif

    @Parameter(title: "Control ID") var controlID: String

    init() {}
    init(controlID: String) { self.controlID = controlID }

    func perform() async throws -> some IntentResult {
        guard let (package, control) = ScriptWidgetControlCatalog.resolve(id: controlID, type: .button) else { return .result() }
        ScriptWidgetControlCatalog.runAction(package: package, control: control)
        ControlCenter.shared.reloadControls(ofKind: "ScriptWidget.Button")
        return .result()
    }
}

struct SetScriptWidgetControlValueIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Widget Control Value"
    static var isDiscoverable: Bool { false }
    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .widgetKitExtension }
    #endif

    @Parameter(title: "Enabled") var value: Bool
    @Parameter(title: "Control ID") var controlID: String

    init() {}
    init(controlID: String) { self.controlID = controlID }

    func perform() async throws -> some IntentResult {
        guard let (package, control) = ScriptWidgetControlCatalog.resolve(id: controlID, type: .toggle),
              let stateKey = control.stateKey else { return .result() }
        ScriptWidgetControlCatalog.setStorageValue(value, package: package, key: stateKey)
        ScriptWidgetControlCatalog.runAction(package: package, control: control, value: value)
        ControlCenter.shared.reloadControls(ofKind: "ScriptWidget.Toggle")
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        return .result()
    }
}
