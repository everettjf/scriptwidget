import Foundation
import JavaScriptCore
import WidgetKit

@objc protocol ScriptWidgetRuntimeCloudJSONExports: JSExport {
    static func readJSON(_ name: String) -> ScriptWidgetRuntimePromise
    static func writeJSON(_ name: String, _ value: [String: Any], _ expectedRevision: String) -> ScriptWidgetRuntimePromise
    static func resolveJSON(_ name: String, _ value: [String: Any], _ expectedRevision: String) -> ScriptWidgetRuntimePromise
    static func sync() -> ScriptWidgetRuntimePromise
    static func status() -> ScriptWidgetRuntimePromise
}

@objc final class ScriptWidgetRuntimeCloudJSON: NSObject, ScriptWidgetRuntimeCloudJSONExports {
    static func readJSON(_ name: String) -> ScriptWidgetRuntimePromise { perform { try $0.read(name) } }
    static func writeJSON(_ name: String, _ value: [String: Any], _ expectedRevision: String) -> ScriptWidgetRuntimePromise {
        perform(writing: true) { try $0.write(name, value: value, expected: expectedRevision) }
    }
    static func resolveJSON(_ name: String, _ value: [String: Any], _ expectedRevision: String) -> ScriptWidgetRuntimePromise {
        perform(writing: true) { try $0.write(name, value: value, expected: expectedRevision, resolving: true) }
    }
    static func sync() -> ScriptWidgetRuntimePromise { perform(writing: true, synchronizeAfter: false) { try $0.synchronize() } }
    static func status() -> ScriptWidgetRuntimePromise { perform { try $0.status() } }

    private static func perform(writing: Bool = false, synchronizeAfter: Bool = true, operation: @escaping (ScriptWidgetCloudJSONStore) throws -> [String: Any]) -> ScriptWidgetRuntimePromise {
        let captured = JSContext.current()?.scriptWidgetRunningState
        return ScriptWidgetRuntimePromise { resolve, reject in
            guard let state = captured, state.isCurrentExecution, state.previewStorage == nil, let snapshot = state.executionSnapshot else {
                reject.call(withArguments: ["[icloud:unavailable] Install the widget and connect iCloud JSON in the app. Native CLI and template previews cannot access iCloud."])
                return
            }
            guard let manifest = state.package.readManifest(), manifest.permissions.contains(.icloud),
                  WidgetPackageManifestValidator.validate(manifest, package: state.package, checkEntryExists: false).isValid else {
                reject.call(withArguments: ["[permission_denied] Declare icloud in widget.json and connect this installation in the app."]); return
            }
            guard !state.isTimelineProjection, !state.isLiveActivityPresentation,
                  !writing || state.isUserInitiatedAction, state.executionSession.registerDataQuery() else {
                reject.call(withArguments: ["[icloud:read_only] Writes and sync require a user action; future/Live Activity presentations cannot access iCloud JSON."]); return
            }
            // The bridge copies JSON-compatible arguments; validation and bounded I/O
            // run on the native serial worker.
            // All results return through the existing guarded promise delivery.
            ScriptWidgetCloudJSONStore.queue.async {
                let result = Result {
                    let store = try ScriptWidgetCloudJSONStore(container: snapshot.context.container, owner: snapshot.binding.ownerID) {
                        guard state.isCurrentExecution else { throw ScriptWidgetCloudJSONError.identityChanged }
                    }
                    let value = try operation(store)
                    // Once a local operation has committed, a separate native
                    // job may exchange immutable revisions after JS finishes.
                    // Its authority remains the captured installation, never a
                    // newly installed package with the same display name.
                    if synchronizeAfter { ScriptWidgetCloudJSONStore.queue.async {
                        guard let background = try? ScriptWidgetCloudJSONStore(container: snapshot.context.container, owner: snapshot.binding.ownerID, validate: { try snapshot.validateIdentity() }) else { return }
                        if let result = try? background.synchronize(), (result["downloadedRevisions"] as? Int ?? 0) > 0 { WidgetCenter.shared.reloadAllTimelines() }
                    } }
                    return value
                }
                state.executionSession.callbackQueue.async {
                    guard state.isCurrentExecution else { return }
                    switch result {
                    case .success(let value): resolve.call(withArguments: [value])
                    case .failure(let error): reject.call(withArguments: [(error as? ScriptWidgetCloudJSONError)?.errorDescription ?? "[icloud:unavailable] Existing records are preserved."])
                    }
                }
            }
        }
    }
}
