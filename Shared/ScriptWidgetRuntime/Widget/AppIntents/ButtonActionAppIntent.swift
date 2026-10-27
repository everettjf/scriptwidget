import AppIntents
import Foundation
import CoreFoundation
import WidgetKit

enum ScriptWidgetSystemRefresh {
    static func request() {
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        #if os(iOS)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "ScriptWidget.Toggle")
            ControlCenter.shared.reloadControls(ofKind: "ScriptWidget.Button")
        }
        #endif
    }
}

enum ScriptWidgetActionSource: String {
    case widget
    case control
    case shortcut
}

struct ResolvedScriptWidgetAction {
    let package: ScriptWidgetPackage
    let manifest: WidgetPackageManifest
    let action: WidgetPackageAction
    var executionSnapshot: ScriptWidgetExecutionSnapshot? = nil
    var nativeBinding: ScriptWidgetStorageDirectoryBinding? = nil
    var nativeContext: ScriptWidgetPackageStorageContext? = nil
    var nativeCapture: ((ScriptWidgetStorageDirectoryBinding) throws -> ScriptWidgetExecutionSnapshot)? = nil
    var ownerID: String? { executionSnapshot?.binding.ownerID ?? nativeBinding?.ownerID }

    var installationName: String { executionSnapshot?.binding.name ?? nativeBinding?.name ?? package.name }
    func controlSubtitle(_ control: WidgetPackageControl) -> String {
        guard let subtitle=control.subtitle,!subtitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return installationName }
        return installationName+" · "+subtitle
    }

    var identifier: String { Self.identifier(packageID: manifest.id, actionID: action.id, ownerID: ownerID) }

    func preparedForExecution() throws -> Self {
        try validateIdentity()
        guard executionSnapshot == nil, let nativeBinding, let nativeContext else { return self }
        let snapshot = try nativeCapture?(nativeBinding)
            ?? ScriptWidgetExecutionSnapshot(name: nativeBinding.name, role: nativeBinding.role, context: nativeContext)
        guard snapshot.binding == nativeBinding else { throw ScriptWidgetActionExecutionError.actionNotFound }
        let prepared = Self(package: snapshot.package, manifest: manifest, action: action, executionSnapshot: snapshot)
        try prepared.validateIdentity()
        return prepared
    }

    func validateIdentity() throws {
        guard let snapshot = executionSnapshot else {
            if let nativeBinding, let nativeContext {
                guard try nativeContext.boundDirectory(name: nativeBinding.name, role: nativeBinding.role) == nativeBinding,
                      manifest == package.readManifest() else { throw ScriptWidgetActionExecutionError.actionNotFound }
            } else if nativeBinding != nil || nativeContext != nil { throw ScriptWidgetActionExecutionError.actionNotFound }
            return
        }
        try snapshot.validateIdentity()
        guard package.path == snapshot.package.path, manifest == snapshot.package.readManifest() else {
            throw ScriptWidgetActionExecutionError.actionNotFound
        }
        let catalog = ScriptWidgetActionCatalog(packages: [snapshot.package], executionSnapshots: [snapshot])
        let declared = catalog.actions().contains { $0.action == action }
        let control = [WidgetPackageControlType.button, .toggle].contains { type in
            catalog.controls(type: type).contains { $0.0.action == action }
        }
        guard declared || control else { throw ScriptWidgetActionExecutionError.actionNotFound }
    }

    static func identifier(packageID: String, actionID: String, ownerID: String? = nil) -> String {
        let base = "\(packageID)::\(actionID)"
        return ownerID.map { base + "::" + $0 } ?? base
    }
}

struct ScriptWidgetActionCatalog {
    let packages: [ScriptWidgetPackage]
    var storageContext: ScriptWidgetPackageStorageContext? = nil
    var executionSnapshots: [ScriptWidgetExecutionSnapshot] = []
    var nativeCapture: ((ScriptWidgetStorageDirectoryBinding) throws -> ScriptWidgetExecutionSnapshot)? = nil

    static var live: ScriptWidgetActionCatalog {
        (try? ScriptWidgetHostExecution.actionCatalog()) ?? ScriptWidgetActionCatalog(packages: [])
    }

    private func entries() -> [(ScriptWidgetPackage, WidgetPackageManifest, ScriptWidgetExecutionSnapshot?, ScriptWidgetStorageDirectoryBinding?, ScriptWidgetPackageStorageContext?)] {
        packages.compactMap { original in
            // An explicitly supplied catalogue context retains its source
            // contract. Mixed source/cache discovery uses each native scope.
            let context = storageContext ?? original.managedScope?.context
            let role: ScriptWidgetStorageDirectoryRole = storageContext == nil ? (original.managedScope?.role ?? .source) : .source
            let snapshot: ScriptWidgetExecutionSnapshot?
            let binding: ScriptWidgetStorageDirectoryBinding?
            if let captured = executionSnapshots.first(where: { $0.package.path == original.path }) {
                guard (try? captured.validateIdentity()) != nil else { return nil }
                snapshot = captured
                binding = nil
            } else if let context {
                guard original.path.standardizedFileURL == context.libraryRoot.appendingPathComponent(original.name),
                      let captured = try? context.boundDirectory(name: original.name, role: role) else { return nil }
                snapshot = nil
                binding = captured
            } else { snapshot = nil; binding = nil }
            let package = snapshot?.package ?? original
            guard let manifest = package.readManifest(),
                  WidgetPackageManifestValidator.validate(manifest, package: package).isValid else { return nil }
            if let binding, let context,
               (try? context.boundDirectory(name: original.name, role: role)) != binding { return nil }
            return (package, manifest, snapshot, binding, context)
        }
    }

    func actions() -> [ResolvedScriptWidgetAction] {
        entries().flatMap { package, manifest, snapshot, binding, context in
            (manifest.actions ?? []).map {
                ResolvedScriptWidgetAction(package: package, manifest: manifest, action: $0, executionSnapshot: snapshot, nativeBinding: binding, nativeContext: binding == nil ? nil : context, nativeCapture: nativeCapture)
            }
        }.sorted {
            if $0.manifest.name == $1.manifest.name { return $0.action.title < $1.action.title }
            return $0.manifest.name < $1.manifest.name
        }
    }

    func resolve(identifier: String) -> ResolvedScriptWidgetAction? {
        let matches = actions().filter { $0.identifier == identifier }
        return matches.count == 1 ? matches[0] : nil
    }

    func resolve(package: ScriptWidgetPackage, actionID: String) -> ResolvedScriptWidgetAction? {
        let matches = actions().filter {
            $0.package.name == package.name && $0.action.id.caseInsensitiveCompare(actionID) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func controls(type: WidgetPackageControlType) -> [(ResolvedScriptWidgetAction, WidgetPackageControl)] {
        entries().flatMap { package, manifest, snapshot, binding, context -> [(ResolvedScriptWidgetAction, WidgetPackageControl)] in
            (manifest.controls ?? []).compactMap { control in
                guard control.type == type else { return nil }
                let action: WidgetPackageAction
                if let id = control.actionID, let declared = manifest.actions?.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
                    action = declared
                } else if let function = control.action {
                    action = WidgetPackageAction(id: control.id, title: control.title, description: control.subtitle, systemImage: control.systemImage, function: function)
                } else { return nil }
                return (ResolvedScriptWidgetAction(package: package, manifest: manifest, action: action, executionSnapshot: snapshot, nativeBinding: binding, nativeContext: binding == nil ? nil : context, nativeCapture: nativeCapture), control)
            }
        }
    }

    static func controlIdentifier(_ resolved: ResolvedScriptWidgetAction, _ control: WidgetPackageControl) -> String {
        ResolvedScriptWidgetAction.identifier(packageID: resolved.manifest.id, actionID: control.id, ownerID: resolved.ownerID)
    }

    func resolveControl(identifier: String, type: WidgetPackageControlType) -> (ResolvedScriptWidgetAction, WidgetPackageControl)? {
        let matches = controls(type: type).filter { resolved, control in
            identifier == Self.controlIdentifier(resolved, control) ||
                (resolved.ownerID == nil && identifier == "\(resolved.package.name)::\(control.id)")
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension ScriptWidgetHostExecution {
    static func actionCatalog() throws -> ScriptWidgetActionCatalog {
        try actionCatalog(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")) {
            ScriptWidgetActionCatalog(packages: sharedScriptManager.listScripts().map(\.package), storageContext: sharedScriptManager.storageContext)
        }
    }

    static func actionCatalog(container: URL?, legacy: () -> ScriptWidgetActionCatalog) throws -> ScriptWidgetActionCatalog {
        if let session = try activeSession(container: container) {
            // Validate one complete package at a time, retaining only native
            // descriptors in the catalogue. Resources are captured again at use.
            let packages = try names(in: session).compactMap { name -> ScriptWidgetPackage? in
                guard let captured = try? session.capture(name: name) else { return nil }
                return ScriptWidgetPackage(path: captured.context.libraryRoot.appendingPathComponent(name), readonly: false,
                    managedScope: .init(context: captured.context, role: captured.binding.role, binding: captured.binding))
            }
            try session.validate()
            return ScriptWidgetActionCatalog(packages: packages, nativeCapture: { binding in
                let captured = try session.capture(name: binding.name, cacheOnly: binding.role == .cache)
                guard captured.binding == binding else { throw ScriptWidgetStorageNamespaceError.conflict }
                return captured
            })
        }
        try ScriptWidgetStorageProfiles.validateLegacyExecution(container: container)
        let catalog = legacy()
        try ScriptWidgetStorageProfiles.validateLegacyExecution(container: container)
        return catalog
    }

}

enum ScriptWidgetActionExecutionError: LocalizedError, Equatable {
    case actionNotFound
    case invalidRequest
    case sourceMissing
    case storageDenied
    case invalidStateKey
    case storageUnavailable
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "This widget action is invalid or exceeds its limits. Reload the widget and try again."
        case .actionNotFound: return "The ScriptWidget action is no longer available."
        case .sourceMissing: return "The ScriptWidget action source file is unavailable."
        case .storageDenied: return "This action did not declare the storage permission."
        case .invalidStateKey: return "The action uses an invalid storage key."
        case .storageUnavailable: return "Widget storage is busy or unavailable. Please try again."
        case .runtime(let message): return "The ScriptWidget action failed: \(message)"
        }
    }
}

struct ScriptWidgetActionExecutor {
    let catalog: ScriptWidgetActionCatalog
    var runAction: (ResolvedScriptWidgetAction, [String: String]) -> ScriptWidgetActionExecutionError? = { resolved, environments in
        guard let script = resolved.executionSnapshot?.source ?? resolved.package.readFile(relativePath: resolved.manifest.entry).0 else { return .sourceMissing }
        let runtime = ScriptWidgetRuntime(package: resolved.package, environments: environments, executionSnapshot: resolved.executionSnapshot, isUserInitiatedAction: true)
        let (_, error) = runtime.executeJSXSyncForFunction(script, resolved.action.function)
        return error.map { .runtime(String(describing: $0)) }
    }
    var reloadWidgets: () -> Void = {
        ScriptWidgetSystemRefresh.request()
    }
    var defaults: UserDefaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard
    var storageContainer: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget")

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
        let prepared: ResolvedScriptWidgetAction
        do { prepared = try resolved.preparedForExecution() }
        catch { return .failure(.actionNotFound) }
        let resolved = prepared
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

    static func toggleValue(resolved: ResolvedScriptWidgetAction, stateKey: String) throws -> Bool {
        let resolved = try resolved.preparedForExecution()
        guard resolved.manifest.permissions.contains(.storage) else { throw ScriptWidgetActionExecutionError.storageDenied }
        guard !stateKey.isEmpty, stateKey.utf8.count <= ScriptWidgetRuntimeStorage.maximumKeyBytes,
              stateKey.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw ScriptWidgetActionExecutionError.invalidStateKey
        }
        let snapshot = resolved.executionSnapshot
        let defaults: any ScriptWidgetStorageBackend = snapshot?.context.defaults ?? ScriptWidgetLegacyStorageBackend(UserDefaults(suiteName: "group.everettjf.scriptwidget") ?? .standard,
            container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget"))
        func read() throws -> Bool {
            try resolved.validateIdentity()
            guard defaults.synchronize() else { throw ScriptWidgetActionExecutionError.storageUnavailable }
            let prefix = snapshot?.storageNamespace ?? "script.\(resolved.package.name)."
            let value = try defaults.readValue(forKey: prefix + stateKey)
            if let bool = value as? Bool { return bool }
            if let string = value as? String { return string == "true" || string == "1" }
            return false
        }
        if let snapshot {
            guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: snapshot.context.container,
                namespace: snapshot.storageNamespace, operation: { Result { try read() } }) else {
                throw ScriptWidgetActionExecutionError.storageUnavailable
            }
            return try result.get()
        }
        return try read()
    }

    func setToggleValue(
        _ value: Bool,
        resolved: ResolvedScriptWidgetAction,
        stateKey: String,
        source: ScriptWidgetActionSource,
        contextID: String? = nil
    ) -> Result<Void, ScriptWidgetActionExecutionError> {
        let prepared: ResolvedScriptWidgetAction
        do { prepared = try resolved.preparedForExecution() }
        catch { return .failure(.actionNotFound) }
        let resolved = prepared
        guard resolved.manifest.permissions.contains(.storage) else { return .failure(.storageDenied) }
        guard !stateKey.isEmpty,
              stateKey.utf8.count <= ScriptWidgetRuntimeStorage.maximumKeyBytes,
              stateKey.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            return .failure(.invalidStateKey)
        }
        let snapshot = resolved.executionSnapshot
        let namespace = snapshot?.storageNamespace ?? "script.\(resolved.package.name)."
        let container = snapshot?.context.container ?? storageContainer
        let backend: any ScriptWidgetStorageBackend = snapshot?.context.defaults ?? ScriptWidgetLegacyStorageBackend(defaults, container: container)
        guard ScriptWidgetRuntimeStorage.mutate(namespace: namespace, defaults: backend, container: container, operation: { store in
            if snapshot != nil {
                guard (try? resolved.validateIdentity()) != nil,
                      (try? ScriptWidgetStorageNamespaces.fitsBudget(namespace: namespace, defaults: store, replacing: [stateKey: value ? "true" : "false"])) == true else { return false }
            }
            try store.writeValue(value ? "true" : "false", forKey: namespace + stateKey)
            return true
        }) else { return .failure(.storageUnavailable) }
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
        subtitle = resolved.installationName
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

#if os(iOS)
// System permissions such as AlarmKit belong to the app, not the widget
// extension. Match the direct-button intent on iOS 17–26 as well as iOS 27.
@available(iOS 17.0, *)
extension RunScriptWidgetActionIntent: LiveActivityIntent {}
@available(iOS 17.0, *)
extension SetScriptWidgetActionValueIntent: LiveActivityIntent {}
#endif

#if os(macOS)
private typealias ScriptWidgetActionIntentProtocol = AppIntent
#else
@available(iOS 17.0, *)
private typealias ScriptWidgetActionIntentProtocol = LiveActivityIntent
#endif

/// Serialized values are selectors, never grants. The receiving host chooses
/// native roots and checks the current directory binding before capturing code.
struct ScriptWidgetDirectActionRequest: Codable, Equatable, Sendable {
    let functionName: String
    let packageName: String
    let scriptParameter: String
    let executionScope: String

    func validate() throws {
        guard ScriptWidgetPackageName.isValid(packageName), scriptParameter.utf8.count <= 16 * 1024,
              functionName.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,63}$", options: .regularExpression) == functionName.startIndex..<functionName.endIndex,
              executionScope.utf8.count <= 4096 else { throw ScriptWidgetActionExecutionError.invalidRequest }
    }

    static func scope(_ binding: ScriptWidgetStorageDirectoryBinding) -> String {
        guard let data = try? JSONEncoder().encode(binding), let text = String(data: data, encoding: .utf8) else { return "invalid" }
        return text
    }

    func binding() throws -> ScriptWidgetStorageDirectoryBinding? {
        try validate()
        if executionScope.isEmpty { return nil }
        guard let data = executionScope.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["name", "ownerID", "role", "location", "receipt"],
              object["name"] as? String == packageName,
              let owner = object["ownerID"] as? String, UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              let location = object["location"] as? String, location.utf8.count == 64,
              location.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let role = object["role"] as? String, ScriptWidgetStorageDirectoryRole(rawValue: role) != nil,
              let receipt = object["receipt"] as? [String: Any], Set(receipt.keys) == ["device", "inode"],
              receipt.values.allSatisfy({ raw in
                  guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                  return UInt64(number.stringValue) != nil
              }), let inode = receipt["inode"] as? NSNumber, inode.uint64Value > 0,
              let result = try? JSONDecoder().decode(ScriptWidgetStorageDirectoryBinding.self, from: JSONSerialization.data(withJSONObject: object)) else {
            throw ScriptWidgetActionExecutionError.invalidRequest
        }
        return result
    }

    var environments: [String: String] {
        ["widget-size": "function", "widget-param": scriptParameter, "action-source": ScriptWidgetActionSource.widget.rawValue]
    }
}

struct ScriptWidgetDirectActionExecutor {
    let manager: ScriptManager
    var cacheRoot: URL? = nil
    var reloadWidgets: () -> Void = { ScriptWidgetSystemRefresh.request() }

    /// Production receiver: choose the current native library before matching
    /// the serialized selector. The selector cannot choose a filesystem root.
    static func executeHost(_ request: ScriptWidgetDirectActionRequest,
                            load: (String, Bool) throws -> ScriptWidgetHostExecution = { try ScriptWidgetHostExecution.load(name: $0, cacheOnly: $1) },
                            reloadWidgets: () -> Void = { ScriptWidgetSystemRefresh.request() }) throws {
        let expected = try request.binding()
        let execution = try load(request.packageName, expected?.role == .cache)
        guard execution.snapshot?.binding == expected else { throw ScriptWidgetActionExecutionError.actionNotFound }
        if let snapshot = execution.snapshot { try snapshot.validateIdentity() }
        let runtime = ScriptWidgetRuntime(package: execution.package, environments: request.environments, executionSnapshot: execution.snapshot)
        let (_, error) = runtime.executeJSXSyncForFunction(execution.source, request.functionName)
        if let error { throw ScriptWidgetActionExecutionError.runtime(String(describing: error)) }
        reloadWidgets()
    }

    func execute(_ request: ScriptWidgetDirectActionRequest) throws {
        let expected = try request.binding()
        let package: ScriptWidgetPackage
        let snapshot: ScriptWidgetExecutionSnapshot?
        if let expected {
            guard let source = manager.storageContext,
                  source.libraryRoot == manager.scriptDirectory.standardizedFileURL.resolvingSymlinksInPath() else { throw ScriptWidgetActionExecutionError.actionNotFound }
            let context: ScriptWidgetPackageStorageContext
            if expected.role == .source { context = source }
            else {
                guard let cache = cacheRoot ?? manager.buildDirectoryOverride ?? ScriptManager.getSandboxBuildDirectoryURL() else {
                    throw ScriptWidgetActionExecutionError.sourceMissing
                }
                try source.requireSeparateCacheRoot(cache)
                context = try source.contextForCacheRoot(cache)
            }
            guard context.locationIdentifier == expected.location,
                  try context.boundDirectory(name: request.packageName, role: expected.role) == expected else {
                throw ScriptWidgetActionExecutionError.actionNotFound
            }
            let captured = try ScriptWidgetExecutionSnapshot(name: request.packageName, role: expected.role, context: context)
            guard captured.binding == expected else { throw ScriptWidgetActionExecutionError.actionNotFound }
            snapshot = captured
            package = captured.package
        } else {
            guard manager.storageContext == nil else { throw ScriptWidgetActionExecutionError.actionNotFound }
            package = manager.getScriptPackage(packageName: request.packageName)
            guard !package.readonly, package.path.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == manager.scriptDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ScriptWidgetActionExecutionError.actionNotFound
            }
            snapshot = nil
        }
        guard let source = snapshot?.source ?? package.readMainFileResult().content else { throw ScriptWidgetActionExecutionError.sourceMissing }
        let runtime = ScriptWidgetRuntime(package: package, environments: request.environments, executionSnapshot: snapshot)
        let (_, error) = runtime.executeJSXSyncForFunction(source, request.functionName)
        if let error { throw ScriptWidgetActionExecutionError.runtime(String(describing: error)) }
        reloadWidgets()
    }
}

/// Undiscoverable compatibility action. Only String parameters cross the OS
/// boundary; native package/context objects are reconstructed at the receiver.
@available(iOS 17.0, *)
struct ButtonActionAppIntent: ScriptWidgetActionIntentProtocol {
    @Parameter(title: "Function") var functionName: String
    @Parameter(title: "Widget") var packageName: String
    @Parameter(title: "Widget Parameter") var scriptParameter: String
    @Parameter(title: "Execution Scope") var executionScope: String

    static var title: LocalizedStringResource = "Run Widget Action"
    static var description = IntentDescription("Run a legacy action from a ScriptWidget package.")
    static var isDiscoverable: Bool { false }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .main }
    #endif

    init() {
        functionName = ""; packageName = ""; scriptParameter = ""; executionScope = ""
    }

    init(functionName: String, package: ScriptWidgetPackage, scriptParameter: String = "", executionSnapshot: ScriptWidgetExecutionSnapshot? = nil) {
        self.functionName = functionName
        self.packageName = executionSnapshot?.hasUnsavedEntry == true ? "" : (executionSnapshot?.binding.name ?? (package.readonly ? "" : package.name))
        self.scriptParameter = scriptParameter
        self.executionScope = executionSnapshot.map { ScriptWidgetDirectActionRequest.scope($0.binding) } ?? ""
    }

    var request: ScriptWidgetDirectActionRequest {
        .init(functionName: functionName, packageName: packageName, scriptParameter: scriptParameter, executionScope: executionScope)
    }
    var actionEnvironments: [String: String] { request.environments }

    func perform() async throws -> some IntentResult {
        try ScriptWidgetDirectActionExecutor.executeHost(request)
        return .result()
    }
}
