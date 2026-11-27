//
//  AppDelegate.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/14.
//

import Foundation
import AppKit

enum DesktopToolDestination: String, CaseIterable, Identifiable {
    case launcher, system, music, translation, appearance

    var id: Self { self }

    var title: String {
        switch self {
        case .launcher: "Launcher"
        case .system: "System"
        case .music: "Music"
        case .translation: "Translate"
        case .appearance: "Appearance"
        }
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "scriptwidget",
              parts.percentEncodedHost == "desktop-tools",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.first == "/" else { return nil }
        self.init(rawValue: String(parts.percentEncodedPath.dropFirst()))
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openDesktopTool: (DesktopToolDestination) -> Void = { _ in }
    @MainActor static var hasFloatingPet: () -> Bool = { false }

    var openWidgetURL: (URL) -> Bool = { url in
        NSWorkspace.shared.open(url)
    }

    var reportUnavailableLink: () -> Void = {
        let alert=NSAlert();alert.messageText="Couldn’t Open Link"
        alert.informativeText="Check the link and make sure its target app is installed. Test saved launcher links in Records & Configuration."
        alert.addButton(withTitle:"OK");alert.runModal()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let destination = DesktopToolDestination(url: url) {
                Self.openDesktopTool(destination)
                continue
            }
            guard let scheme = url.scheme?.lowercased(),
                  scheme != kDeepLinkDefaultScheme,
                  scheme != "scriptwidget" else { continue }
            if !openWidgetURL(url) { reportUnavailableLink() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("did finish launching")
        // The embedded editor is served via a WKURLSchemeHandler — no
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
        !Self.hasFloatingPet()
    }
}
