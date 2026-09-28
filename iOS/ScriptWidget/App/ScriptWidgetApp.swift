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

enum ScriptWidgetStorageAvailability {
    static var isAvailable: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-simulateUnavailableSharedStorage") {
            return false
        }
#endif
        return ScriptManager.getICloudRootDirectoryURL() != nil
            || ScriptManager.getSandboxRootDirectoryURL() != nil
    }
}

private struct ScriptWidgetLaunchView: View {
    private enum StorageState: Equatable {
        case checking, available, unavailable
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var storageState: StorageState = .checking

    var body: some View {
        Group {
            switch storageState {
            case .checking:
                ProgressView("Opening ScriptWidget…")
            case .available:
                ContentView()
            case .unavailable:
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Widget Storage Unavailable")
                        .font(.title2.bold())
                    Text("ScriptWidget couldn't open iCloud Drive or its shared storage. Your widgets are safe. Try again after checking iCloud Drive and restarting the app.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: refreshStorageState)
                        .buttonStyle(.borderedProminent)
                }
                .padding(32)
            }
        }
        .task { refreshStorageState() }
        .onChange(of: scenePhase) { phase in
            if phase == .active && storageState == .unavailable {
                refreshStorageState()
            }
        }
    }

    private func refreshStorageState() {
        storageState = ScriptWidgetStorageAvailability.isAvailable ? .available : .unavailable
    }
}

@main
struct ScriptWidgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate;

    init() {
        _ = sharedLiveActivityManager
        ScriptWidgetPrecompiler.install()
    }
    
    var body: some Scene {
        WindowGroup {
            ScriptWidgetLaunchView()
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
        guard ScriptWidgetStorageAvailability.isAvailable,
              let pushInfo = await WidgetCenter.shared.currentPushInfo,
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
