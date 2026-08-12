import AppIntents
import Foundation
import WidgetKit

enum ScriptWidgetActionSource: String {
    case widget
    case control
    case shortcut
}

struct ResolvedScriptWidgetAction {
    let package: ScriptWidgetPackage
    let manifest: WidgetPackageManifest
    let action: WidgetPackageAction

    var identifier: String { Self.identifier(packageID: manifest.id, actionID: action.id) }

    static func identifier(packageID: String, actionID: String) -> String {
        "\(packageID)::\(actionID)"
    }
}

struct ScriptWidgetActionCatalog {
    let packages: [ScriptWidgetPackage]

    static var live: ScriptWidgetActionCatalog {
        ScriptWidgetActionCatalog(packages: sharedScriptManager.listScripts().map(\.package))
    }

    func actions() -> [ResolvedScriptWidgetAction] {
        packages.flatMap { package -> [ResolvedScriptWidgetAction] in
            // A malformed present manifest must not be reinterpreted as a
            // legacy package and exposed to system surfaces.
            guard let manifest = package.readManifest(),
                  WidgetPackageManifestValidator.validate(manifest, package: package).isValid else {
                return []
            }
            return (manifest.actions ?? []).map {
                ResolvedScriptWidgetAction(package: package, manifest: manifest, action: $0)
            }
        }
        .sorted {
            if $0.manifest.name == $1.manifest.name { return $0.action.title < $1.action.title }
            return $0.manifest.name < $1.manifest.name
        }
    }

    func resolve(identifier: String) -> ResolvedScriptWidgetAction? {
        actions().first { $0.identifier == identifier }
    }

    func resolve(package: ScriptWidgetPackage, actionID: String) -> ResolvedScriptWidgetAction? {
        guard let manifest = package.readManifest(),
              WidgetPackageManifestValidator.validate(manifest, package: package).isValid,
              let action = (manifest.actions ?? []).first(where: {
                  $0.id.caseInsensitiveCompare(actionID) == .orderedSame
              }) else { return nil }
        return ResolvedScriptWidgetAction(package: package, manifest: manifest, action: action)
    }

    func resolveControl(identifier: String, type: WidgetPackageControlType) -> (ResolvedScriptWidgetAction, WidgetPackageControl)? {
        for package in packages {
            guard let manifest = package.readManifest(),
                  WidgetPackageManifestValidator.validate(manifest, package: package).isValid else { continue }
            for control in (manifest.controls ?? []) where control.type == type {
                let stableID = "\(manifest.id)::\(control.id)"
                let legacyID = "\(package.name)::\(control.id)"
                guard identifier == stableID || identifier == legacyID else { continue }
                if let actionID = control.actionID,
                   let action = resolve(package: package, actionID: actionID) {
                    return (action, control)
                }
                if let function = control.action {
                    let legacyAction = WidgetPackageAction(
                        id: control.id,
                        title: control.title,
                        description: control.subtitle,
                        systemImage: control.systemImage,
                        function: function
                    )
                    return (ResolvedScriptWidgetAction(package: package, manifest: manifest, action: legacyAction), control)
                }
            }
        }
        return nil
    }
}

enum ScriptWidgetActionExecutionError: LocalizedError, Equatable {
    case actionNotFound
    case sourceMissing
    case storageDenied
    case invalidStateKey
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .actionNotFound: return "The ScriptWidget action is no longer available."
        case .sourceMissing: return "The ScriptWidget action source file is unavailable."
        case .storageDenied: return "This action did not declare the storage permission."
        case .invalidStateKey: return "The action uses an invalid storage key."
        case .runtime(let message): return "The ScriptWidget action failed: \(message)"
        }
    }
}

struct ScriptWidgetActionExecutor {
    let catalog: ScriptWidgetActionCatalog
    var runAction: (ResolvedScriptWidgetAction, [String: String]) -> ScriptWidgetActionExecutionError? = { resolved, environments in
        guard let script = resolved.package.readFile(relativePath: resolved.manifest.entry).0 else { return .sourceMissing }
        let runtime = ScriptWidgetRuntime(package: resolved.package, environments: environments)
        let (_, error) = runtime.executeJSXSyncForFunction(script, resolved.action.function)
        return error.map { .runtime(String(describing: $0)) }
    }
    var reloadWidgets: () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
    }
    var defaults: UserDefaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard

    @discardableResult
    func execute(
        identifier: String,
        source: ScriptWidgetActionSource,
        value: Bool? = nil
    ) -> Result<Void, ScriptWidgetActionExecutionError> {
        guard let resolved = catalog.resolve(identifier: identifier) else { return .failure(.actionNotFound) }
        return execute(resolved: resolved, source: source, value: value)
    }

    @discardableResult
    func execute(
        resolved: ResolvedScriptWidgetAction,
        source: ScriptWidgetActionSource,
        value: Bool? = nil,
        contextID: String? = nil
    ) -> Result<Void, ScriptWidgetActionExecutionError> {
        var environments = [
            "widget-size": "action",
            "widget-param": "",
            "action-id": resolved.action.id,
            "action-source": source.rawValue,
        ]
        if let value { environments["action-value"] = value ? "true" : "false" }
        if source == .control {
            environments["control-id"] = contextID ?? resolved.action.id
            if let value { environments["control-value"] = value ? "true" : "false" }
        }
        if let error = runAction(resolved, environments) { return .failure(error) }
        reloadWidgets()
        return .success(())
    }

    func setToggleValue(
        _ value: Bool,
        resolved: ResolvedScriptWidgetAction,
        stateKey: String,
        source: ScriptWidgetActionSource,
        contextID: String? = nil
    ) -> Result<Void, ScriptWidgetActionExecutionError> {
        guard resolved.manifest.permissions.contains(.storage) else { return .failure(.storageDenied) }
        guard !stateKey.isEmpty,
              stateKey.utf8.count <= ScriptWidgetRuntimeStorage.maximumKeyBytes,
              stateKey.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            return .failure(.invalidStateKey)
        }
        defaults.set(value ? "true" : "false", forKey: "script.\(resolved.package.name).\(stateKey)")
        return execute(resolved: resolved, source: source, value: value, contextID: contextID)
    }
}

struct ScriptWidgetActionEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "ScriptWidget Action"
    static var defaultQuery = ScriptWidgetActionQuery()

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String

    init(resolved: ResolvedScriptWidgetAction) {
        id = resolved.identifier
        title = resolved.action.title
        subtitle = resolved.manifest.name
        systemImage = resolved.action.systemImage
    }

    init(id: String, title: String, subtitle: String, systemImage: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct ScriptWidgetActionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScriptWidgetActionEntity] {
        let catalog = ScriptWidgetActionCatalog.live
        return identifiers.compactMap { catalog.resolve(identifier: $0).map(ScriptWidgetActionEntity.init) }
    }

    func suggestedEntities() async throws -> [ScriptWidgetActionEntity] {
        ScriptWidgetActionCatalog.live.actions().map(ScriptWidgetActionEntity.init)
    }
}

struct RunScriptWidgetActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run ScriptWidget Action"
    static var description = IntentDescription("Run an action declared by an installed ScriptWidget package.")
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .main }
    #endif

    @Parameter(title: "Action") var action: ScriptWidgetActionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action)")
    }

    init() {}

    init(identifier: String) {
        if let resolved = ScriptWidgetActionCatalog.live.resolve(identifier: identifier) {
            action = ScriptWidgetActionEntity(resolved: resolved)
        } else {
            action = ScriptWidgetActionEntity(id: identifier, title: "Missing Action", subtitle: "ScriptWidget", systemImage: "exclamationmark.triangle")
        }
    }

    func perform() async throws -> some IntentResult {
        let result = ScriptWidgetActionExecutor(catalog: .live).execute(identifier: action.id, source: .shortcut)
        if case .failure(let error) = result { throw error }
        return .result()
    }
}

struct SetScriptWidgetActionValueIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set ScriptWidget Action Value"
    static var isDiscoverable: Bool { false }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .main }
    #endif

    @Parameter(title: "Enabled") var value: Bool
    @Parameter(title: "Action ID") var actionID: String
    @Parameter(title: "State Key") var stateKey: String

    init() {}
    init(actionID: String, stateKey: String) {
        self.actionID = actionID
        self.stateKey = stateKey
    }

    func perform() async throws -> some IntentResult {
        let catalog = ScriptWidgetActionCatalog.live
        guard let resolved = catalog.resolve(identifier: actionID) else { throw ScriptWidgetActionExecutionError.actionNotFound }
        let result = ScriptWidgetActionExecutor(catalog: catalog).setToggleValue(
            value,
            resolved: resolved,
            stateKey: stateKey,
            source: .widget
        )
        if case .failure(let error) = result { throw error }
        return .result()
    }
}

#if os(macOS)
private typealias ScriptWidgetActionIntentProtocol = AppIntent
#else
@available(iOS 17.0, *)
private typealias ScriptWidgetActionIntentProtocol = LiveActivityIntent
#endif

/// Compatibility intent for existing JSX `onClick` functions. These direct
/// function references intentionally remain undiscoverable to Siri/Shortcuts.
@available(iOS 17.0, *)
struct ButtonActionAppIntent: ScriptWidgetActionIntentProtocol {
    let functionName: String
    let package: ScriptWidgetPackage?

    static var title: LocalizedStringResource = "Run Widget Action"
    static var description = IntentDescription("Run a legacy action from a ScriptWidget package.")
    static var isDiscoverable: Bool { false }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .main }
    #endif

    init() {
        functionName = ""
        package = nil
    }

    init(functionName: String, package: ScriptWidgetPackage) {
        self.functionName = functionName
        self.package = package
    }

    func perform() async throws -> some IntentResult {
        guard let package,
              functionName.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,63}$", options: .regularExpression) != nil,
              let source = package.readMainFileResult().content else { return .result() }
        let runtime = ScriptWidgetRuntime(package: package, environments: [
            "widget-size": "function",
            "widget-param": "",
            "action-source": ScriptWidgetActionSource.widget.rawValue,
        ])
        let (_, error) = runtime.executeJSXSyncForFunction(source, functionName)
        if let error { throw ScriptWidgetActionExecutionError.runtime(String(describing: error)) }
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        return .result()
    }
}
