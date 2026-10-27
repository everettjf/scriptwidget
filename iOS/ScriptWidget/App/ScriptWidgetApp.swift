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

private struct ScriptWidgetLegacyLaunchView: View {
    let onReady: () async -> Void
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
                ContentView().task { await onReady() }
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
        .modifier(CalendarAccessPresentationModifier())
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification),
                   NotificationCenter.default.publisher(for: .NSCalendarDayChanged))) { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .task {
            refreshStorageState()
            DispatchQueue.global(qos: .utility).async {
                ScriptWidgetRuntimeLocation.refreshAuthorizationState()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                DispatchQueue.global(qos: .utility).async {
                    ScriptWidgetRuntimeLocation.refreshAuthorizationState()
                }
                if storageState == .unavailable { refreshStorageState() }
            }
        }
    }

    private func refreshStorageState() {
        storageState = ScriptWidgetStorageAvailability.isAvailable ? .available : .unavailable
    }
}

private struct ScriptWidgetLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    let onReady: () async -> Void
    var body: some View {
        Group {
            if ScriptWidgetApplicationTestHost.isActive || ScriptWidgetApplicationTestHost.simulatesUnavailableStorage {
                ScriptWidgetLegacyLaunchView(onReady: onReady)
            } else {
                ScriptWidgetLibraryLaunchView(model: .shared) {
                    ContentView().task { await onReady() }
                }
                .modifier(CalendarAccessPresentationModifier())
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
                    .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification),
                           NotificationCenter.default.publisher(for: .NSCalendarDayChanged))) { _ in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .task {
                    DispatchQueue.global(qos: .utility).async { ScriptWidgetRuntimeLocation.refreshAuthorizationState() }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        DispatchQueue.global(qos: .utility).async { ScriptWidgetRuntimeLocation.refreshAuthorizationState() }
                    }
                }
            }
        }
    }
}

@main
struct ScriptWidgetApp: App {
    @State private var showingLinkFailure = false
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate;

    init() {
        ScriptWidgetSystemServices.startLifecycle()
        if #available(iOS 16.2,*) { _ = sharedLiveActivityManager }
        ScriptWidgetPrecompiler.install()
    }
    
    var body: some Scene {
        WindowGroup {
            ScriptWidgetLaunchView(onReady: {
                    if #available(iOS 16.2,*) { await sharedLiveActivityManager.reconcile() }
                    if #available(iOS 26.0, *) {
                        await registerWidgetPushSubscriptions()
                    }
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-WebStudioAutoStart") {
                        WebStudioServer.shared.start()
                    }
#endif
                })
                .alert("Couldn’t Open Link",isPresented:$showingLinkFailure) {
                    Button("OK",role:.cancel) {}
                } message: {
                    Text("Check the link and make sure its target app is installed. You can test saved launcher links in Records & Configuration.")
                }
                .onOpenURL(perform: { url in
                    if url.scheme?.lowercased()=="scriptwidget" {
                        guard let host=url.host() else { return }
                        dealWithSelfScheme(host:host,url:url)
                        return
                    }
                    DeepLinkManager.openDeepLink(url:url,completion: { accepted in
                        if !accepted { DispatchQueue.main.async { showingLinkFailure=true } }
                    })
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
