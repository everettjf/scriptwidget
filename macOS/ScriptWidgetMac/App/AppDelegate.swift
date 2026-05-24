//
//  AppDelegate.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/14.
//

import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("did finish launching")
        // Monaco editor is now served via a WKURLSchemeHandler — no
        // local HTTP server needed.
        precacheScripts()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        precacheScripts()
    }

    /// Proactively cache scripts locally while iCloud is reachable so widgets
    /// keep rendering if iCloud Drive later becomes unavailable (issue #6).
    private func precacheScripts() {
        DispatchQueue.global(qos: .utility).async {
            sharedScriptManager.precacheAllScripts()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
