import AppIntents
import Foundation
import WidgetKit

private enum ScriptWidgetControlCatalog {
    static func controls(type: WidgetPackageControlType) -> [(package: ScriptWidgetPackage, control: WidgetPackageControl)] {
        ScriptWidgetActionCatalog.live.packages.flatMap { package -> [(package: ScriptWidgetPackage, control: WidgetPackageControl)] in
            guard let manifest = package.readManifest(),
                  WidgetPackageManifestValidator.validate(manifest, package: package).isValid else { return [] }
            return (manifest.controls ?? [])
                .filter { $0.type == type }
                .map { (package, $0) }
        }
    }

    static func resolve(id: String, type: WidgetPackageControlType) -> (ScriptWidgetPackage, WidgetPackageControl)? {
        guard let (_, control) = ScriptWidgetActionCatalog.live.resolveControl(identifier: id, type: type) else { return nil }
        return controls(type: type).first {
            $0.control.id == control.id && (entityID(package: $0.package, control: $0.control) == id || legacyEntityID(package: $0.package, control: $0.control) == id)
        }
    }

    static func entityID(package: ScriptWidgetPackage, control: WidgetPackageControl) -> String {
        let manifest = package.readManifest() ?? package.effectiveManifest()
        return "\(manifest.id)::\(control.id)"
    }

    static func legacyEntityID(package: ScriptWidgetPackage, control: WidgetPackageControl) -> String {
        "\(package.name)::\(control.id)"
    }

    static func storageValue(package: ScriptWidgetPackage, key: String) -> Bool {
        let defaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard
        let value = defaults.object(forKey: "script.\(package.name).\(key)")
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return string == "true" || string == "1" }
        return false
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
        guard let (resolved, control) = ScriptWidgetActionCatalog.live.resolveControl(identifier: controlID, type: .button) else {
            throw ScriptWidgetActionExecutionError.actionNotFound
        }
        let result = ScriptWidgetActionExecutor(catalog: .live).execute(
            resolved: resolved,
            source: .control,
            contextID: control.id
        )
        if case .failure(let error) = result { throw error }
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
        guard let (resolved, control) = ScriptWidgetActionCatalog.live.resolveControl(identifier: controlID, type: .toggle),
              let stateKey = control.stateKey else { return .result() }
        let result = ScriptWidgetActionExecutor(catalog: .live).setToggleValue(
            value,
            resolved: resolved,
            stateKey: stateKey,
            source: .control,
            contextID: control.id
        )
        if case .failure(let error) = result { throw error }
        ControlCenter.shared.reloadControls(ofKind: "ScriptWidget.Toggle")
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        return .result()
    }
}
