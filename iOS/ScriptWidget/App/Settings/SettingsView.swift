//
//  SettingsView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/6.
//

import SwiftUI
import WidgetKit
import HealthKit
import CoreLocation
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingStorageReview = false
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
    
    var body: some View {
        content
            .sheet(isPresented: $showingStorageReview) { ScriptWidgetStorageUpgradeView() }
            .alert("Notification", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
    }

    var content: some View {
        NavigationStack {
            Form {
                Section {
                    if #available(iOS 16.2,*) {
                        NavigationLink(destination:ScriptLiveActivityManagementView()) { Label("Live Activities",systemImage:"lock.rectangle") }
                    }
                    NavigationLink(destination: ScriptWidgetActionDirectoryView()) {
                        Label("Widget Actions",systemImage:"play.square")
                    }
                    NavigationLink(destination: SettingTemplatesView()) {
                        Label("Templates", systemImage: "rectangle.stack")
                    }
                    NavigationLink(destination: SettingAIView()) {
                        Label("AI Providers", systemImage: "sparkles")
                    }
                } header: {
                    Text("Studio")
                }

                Section {
                    Button {
                        WidgetCenter.shared.reloadAllTimelines()
                        showAlert("All widget timelines were refreshed.")
                    } label: {
                        Label("Refresh All Widgets", systemImage: "arrow.clockwise")
                    }
                    NavigationLink(destination: ExportView()) {
                        Label("Export Scripts", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink(destination: ImportView()) {
                        Label("Import Scripts", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Refresh after editing scripts outside the app or when a widget appears stale.")
                }

                if sharedScriptManager.storageContext != nil {
                    Section("Records") {
                        Button("Review Older Records") { showingStorageReview = true }
                    }
                }
                Section("iCloud") { SettingsICloudView() }
                Section("Services") {
                    NavigationLink(destination: ScriptWidgetServiceAccountsView()) { Label("Service Accounts", systemImage: "person.crop.circle.badge.checkmark") }
                }
                Section("Calendar") { CalendarAccessSettingsView() }
                Section("Reminders") { RemindersAccessSettingsView() }
                Section("Photos") { PhotosAccessSettingsView() }
                Section("Music") { ScriptWidgetMusicAccessSettingsView() }
                Section("Health") { SettingsHealthView() }
                Section("Location") { SettingsLocationView() }

                ScriptWidgetDiagnosticSettingsSection()

                Section("Application") {
                    AtomSproutFeedbackEmailButton(appName: "ScriptWidget")
                    NavigationLink(destination: AppIconsView()) {
                        Label("App Icon", systemImage: "app.badge")
                    }
                    SettingsLinkRowView(name: "Website", label: "", urlString: "https://atomsprout.com/scriptwidget")
                    SettingsLinkRowView(name: "Discord", label: "", urlString: "https://discord.gg/eGzEaP6TzR")
                    SettingsLinkRowView(name: "Developer", label: "everettjf", urlString: "https://twitter.com/everettjf")
                    SettingsTextRowView(name: "Version", content: AppHelper.getAppVersion())
                }

                Section("More Apps") {
                    SettingsLinkRowView(name: "BSSID SCAN", label: "App Store", urlString: "https://apps.apple.com/us/app/bssid-scan/id1442586100")
                    SettingsLinkRowView(name: "Dayvella", label: "App Store", urlString: "https://apps.apple.com/app/id6753280745")
                    SettingsLinkRowView(name: "Remote Keyboard", label: "App Store", urlString: "https://apps.apple.com/us/app/remote-keyboard/id1474458879")
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudioDesign.groupedBackground)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview("Settings") {
    SettingsView()
}

#Preview("Settings · Dark") {
    SettingsView()
        .preferredColorScheme(.dark)
}

private struct SettingsStatusView<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: .rect(cornerRadius: StudioDesign.controlCornerRadius))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct SettingsHealthView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorizationState: ScriptWidgetHealthReviewState = .checking

    private var title: String {
        switch authorizationState {
        case .checking: "Checking Health Setup…"
        case .unavailable: "Health Unavailable"
        case .reviewRequired: "Review Health Access"
        case .reviewCompleted: "Health Review Completed"
        case .failed: "Health Setup Could Not Be Checked"
        }
    }

    private var detail: String {
        switch authorizationState {
        case .checking: "Checking whether the Health permission review is needed."
        case .unavailable: "Health data is not available on this device."
        case .reviewRequired: "Choose which Health data to share for steps, heart rate, sleep, activity rings and workout summaries."
        case .reviewCompleted: "Health keeps individual read permissions private. Empty results can mean no records or data you chose not to share. Review access in Health if needed."
        case .failed: "Try reviewing Health access again or check ScriptWidget in the Health app."
        }
    }

    @State private var isRequesting = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    private let healthStore = HKHealthStore()

    var body: some View {
        SettingsStatusView(
            title: title,
            detail: detail,
            systemImage: "heart",
            color: authorizationState == .unavailable ? .secondary : .blue
        ) {
            HStack(spacing: 8) {
                if authorizationState == .reviewRequired || authorizationState == .failed {
                    Button {
                        requestAuthorization()
                    } label: {
                        Text(isRequesting ? "Reviewing…" : "Review Access")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRequesting)
                }

                if authorizationState == .reviewCompleted || authorizationState == .failed {
                    Button {
                        openHealthApp()
                    } label: {
                        Text("Open Health")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { refreshAuthorizationState() }
        }
        .alert("Health", isPresented: $showingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }

        isRequesting = true
        let readTypes = healthReadTypes()
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { _, error in
            DispatchQueue.main.async {
                isRequesting = false
                if let error = error {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
                refreshAuthorizationState()
            }
        }
    }

    private func refreshAuthorizationState() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }

        let readTypes = healthReadTypes()
        guard !readTypes.isEmpty else {
            authorizationState = .unavailable
            return
        }
        authorizationState = .checking

        if #available(iOS 12.0, *) {
            healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
                DispatchQueue.main.async {
                    if let error = error {
                        alertMessage = error.localizedDescription
                        showingAlert = true
                        authorizationState = .failed
                        return
                    }

                    switch status {
                    case .shouldRequest:
                        authorizationState = ScriptWidgetHealthReviewState.evaluate(available: true, shouldRequest: true)
                    case .unnecessary:
                        authorizationState = ScriptWidgetHealthReviewState.evaluate(available: true, shouldRequest: false)
                    case .unknown:
                        authorizationState = .reviewRequired
                    @unknown default:
                        authorizationState = .reviewRequired
                    }
                }
            }
        } else {
            authorizationState = .reviewRequired
        }
    }

    private func healthReadTypes() -> Set<HKObjectType> {
        ScriptWidgetRuntimeHealth.authorizationReadTypes
    }

    private func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url)
    }
}

private struct SettingsLocationView: View {
    private enum LocationAuthorizationState {
        case checking
        case disabled
        case notDetermined
        case restricted
        case denied
        case authorizedWhenInUse
        case authorizedAlways

        var title: String {
            switch self {
            case .checking:
                return "Checking..."
            case .disabled:
                return "Location Disabled"
            case .notDetermined:
                return "Not Authorized"
            case .restricted:
                return "Restricted"
            case .denied:
                return "Access Denied"
            case .authorizedWhenInUse:
                return "Authorized (When In Use)"
            case .authorizedAlways:
                return "Authorized (Always)"
            }
        }

        var detail: String {
            switch self {
            case .checking:
                return "Checking Location permissions."
            case .disabled:
                return "Location services are disabled on this device."
            case .notDetermined:
                return "Tap Authorize to request access for location."
            case .restricted:
                return "Location access is restricted by system policy."
            case .denied:
                return "Access is denied. Enable ScriptWidget in Settings."
            case .authorizedWhenInUse:
                return "Location access is ready for scripts and widgets."
            case .authorizedAlways:
                return "Location access is ready for scripts and widgets."
            }
        }

        var shouldShowAuthorizeButton: Bool {
            switch self {
            case .notDetermined:
                return true
            case .checking, .disabled, .restricted, .denied, .authorizedWhenInUse, .authorizedAlways:
                return false
            }
        }

        var shouldShowOpenSettingsButton: Bool {
            switch self {
            case .restricted, .denied:
                return true
            case .checking, .disabled, .notDetermined, .authorizedWhenInUse, .authorizedAlways:
                return false
            }
        }

        var systemImage: String {
            switch self {
            case .checking: "hourglass"
            case .disabled: "location.slash"
            case .notDetermined: "location"
            case .restricted, .denied: "exclamationmark.shield"
            case .authorizedWhenInUse, .authorizedAlways: "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .checking, .disabled: .secondary
            case .notDetermined: .blue
            case .restricted, .denied: .red
            case .authorizedWhenInUse, .authorizedAlways: .green
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = SettingsLocationManager()

    var body: some View {
        SettingsStatusView(
            title: manager.state.title,
            detail: manager.state.detail,
            systemImage: manager.state.systemImage,
            color: manager.state.color
        ) {
            HStack(spacing: 8) {
                if manager.state.shouldShowAuthorizeButton {
                    Button {
                        manager.requestAuthorization()
                    } label: {
                        Text(manager.isRequesting ? "Authorizing..." : "Authorize")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(manager.isRequesting)
                }

                if manager.state.shouldShowOpenSettingsButton {
                    Button {
                        openSettings()
                    } label: {
                        Text("Open Settings")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            manager.refresh()
        }
        .task(id: scenePhase) {
            if scenePhase == .active { manager.refresh() }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private final class SettingsLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
        @Published var state: LocationAuthorizationState = .checking
        @Published var isRequesting = false

        private let locationManager = CLLocationManager()
        private var hasRequestedLocation = false

        override init() {
            super.init()
            locationManager.delegate = self
        }

        func refresh() {
            DispatchQueue.global(qos: .utility).async {
                ScriptWidgetRuntimeLocation.refreshAuthorizationState()
            }
            hasRequestedLocation = false
            state = makeState()
            if state == .authorizedAlways || state == .authorizedWhenInUse {
                requestLocationIfNeeded()
            }
        }

        func requestAuthorization() {
            guard CLLocationManager.locationServicesEnabled() else {
                state = .disabled
                return
            }
            isRequesting = true
            locationManager.requestWhenInUseAuthorization()
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            handleAuthorizationChange(status: manager.authorizationStatus)
        }

        func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            handleAuthorizationChange(status: status)
        }

        private func handleAuthorizationChange(status: CLAuthorizationStatus) {
            DispatchQueue.global(qos: .utility).async {
                ScriptWidgetRuntimeLocation.refreshAuthorizationState()
            }
            if status != .authorizedAlways && status != .authorizedWhenInUse { hasRequestedLocation = false }
            state = makeState(status: status)
            if status != .notDetermined {
                isRequesting = false
            }
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                requestLocationIfNeeded()
            }
        }

        private func makeState() -> LocationAuthorizationState {
            return makeState(status: locationManager.authorizationStatus)
        }

        private func makeState(status: CLAuthorizationStatus) -> LocationAuthorizationState {
            guard CLLocationManager.locationServicesEnabled() else {
                return .disabled
            }
            switch status {
            case .notDetermined:
                return .notDetermined
            case .restricted:
                return .restricted
            case .denied:
                return .denied
            case .authorizedAlways:
                return .authorizedAlways
            case .authorizedWhenInUse:
                return .authorizedWhenInUse
            @unknown default:
                return .notDetermined
            }
        }

        private func requestLocationIfNeeded() {
            guard !hasRequestedLocation else { return }
            hasRequestedLocation = true
            locationManager.requestLocation()
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last else { return }
            ScriptWidgetRuntimeLocation.cacheLocation(
                location,
                accuracyAuthorization: ScriptWidgetRuntimeLocation.accuracyAuthorizationString(manager)
            )
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            // Avoid logging system errors that may contain location details.
            hasRequestedLocation = false
        }
    }
}
