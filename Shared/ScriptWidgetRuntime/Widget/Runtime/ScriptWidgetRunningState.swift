//
//  ScriptWidgetRunningState.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/4/7.
//
//  Per-execution state — package handle and console logger — that the
//  JS runtime APIs (`$file`, `$console`) need to reach. The state hangs
//  off the owning `JSContext` via an associated object; JSExport
//  callbacks find it by way of `JSContext.current()`. There is no
//  global; concurrent runtimes do not see each other's state.
//

import Foundation
import JavaScriptCore


class ScriptWidgetConsoleLogger {
    var logs: [String] = []

    func addLog(_ log: String) {
        DispatchQueue.main.async {
            self.logs.append(log)
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}


class ScriptWidgetRunningState {

    var logger: ScriptWidgetConsoleLogger
    var package: ScriptWidgetPackage

    init(package: ScriptWidgetPackage) {
        self.logger = ScriptWidgetConsoleLogger()
        self.package = package
    }
}

private var scriptWidgetRunningStateAssociationKey: UInt8 = 0

extension JSContext {
    /// Per-runtime running state. Read inside JSExport callbacks via
    /// `JSContext.current()?.scriptWidgetRunningState`.
    var scriptWidgetRunningState: ScriptWidgetRunningState? {
        get {
            objc_getAssociatedObject(self, &scriptWidgetRunningStateAssociationKey) as? ScriptWidgetRunningState
        }
        set {
            objc_setAssociatedObject(
                self,
                &scriptWidgetRunningStateAssociationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
