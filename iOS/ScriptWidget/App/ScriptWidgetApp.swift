//
//  ScriptWidgetApp.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/4.
//

import SwiftUI
import WidgetKit
import AppIntents

struct ScriptWidgetAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunScriptWidgetActionIntent(),
            phrases: [
                "Run \(\.$action) in \(.applicationName)",
                "Use \(\.$action) with \(.applicationName)",
            ],
            shortTitle: "Run Widget Action",
            systemImageName: "play.square"
        )
    }
}

@main
struct ScriptWidgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate;

    init() {
        ScriptWidgetPrecompiler.install()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    if #available(iOS 26.0, *) {
                        await registerWidgetPushSubscriptions()
                    }
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-WebStudioAutoStart") {
                        WebStudioServer.shared.start()
                    }
#endif
                }
                .onOpenURL(perform: { url in
                    print("onOpenURL \(url)")
                    
                    guard let host = url.host() else {
                        return
                    }
                    
                    if let scheme = url.scheme {
                        if scheme == "scriptwidget" {
                            dealWithSelfScheme(host: host, url: url)
                            return
                        }
                    }
                    
                    if host == "xnu.app/scriptwidget" {
                        print("ignore open url for : xnu.app/scriptwidget")
                        UIApplication.shared.open(url)
                        return
                    }
                    
                    DeepLinkManager.openDeepLink(url: url)
                })
        }
    }

    @available(iOS 26.0, *)
    private func registerWidgetPushSubscriptions() async {
        guard let pushInfo = await WidgetCenter.shared.currentPushInfo,
              let widgets = try? await WidgetCenter.shared.currentConfigurations() else { return }
        let packageNames = Set(widgets.compactMap {
            $0.widgetConfigurationIntent(of: ScriptWidgetAppIntent.self)?.Script
        })
        for packageName in packageNames {
            ScriptWidgetPushRegistration.register(
                token: pushInfo.token,
                package: sharedScriptManager.getScriptPackage(packageName: packageName)
            )
        }
    }
    
    
    func dealWithSelfScheme(host: String, url: URL) {
        if host == "reload-all" {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
