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
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
    
    var body: some View {
        content
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

                Section("iCloud") { SettingsICloudView() }
                Section("Health") { SettingsHealthView() }
                Section("Location") { SettingsLocationView() }

                Section("Application") {
                    NavigationLink(destination: AppIconsView()) {
                        Label("App Icon", systemImage: "app.badge")
                    }
                    SettingsLinkRowView(name: "Website", label: "", urlString: "https://xnu.app/scriptwidget")
                    SettingsLinkRowView(name: "Discord", label: "", urlString: "https://discord.gg/eGzEaP6TzR")
                    SettingsLinkRowView(name: "Developer", label: "everettjf", urlString: "https://twitter.com/everettjf")
                    SettingsTextRowView(name: "Version", content: AppHelper.getAppVersion())
                }

                Section("More Apps") {
                    SettingsLinkRowView(name: "BSSID SCAN", label: "App Store", urlString: "https://apps.apple.com/us/app/bssid-scan/id1442586100")
                    SettingsLinkRowView(name: "CountMyDays", label: "App Store", urlString: "https://apps.apple.com/us/app/countmydays-days-counter/id6753280745")
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
    private enum HealthAuthorizationState {
        case checking
        case unavailable
        case notDetermined
        case denied
        case partial
        case authorized

        var title: String {
            switch self {
            case .checking:
                return "Checking..."
            case .unavailable:
                return "Health Unavailable"
            case .notDetermined:
                return "Not Authorized"
            case .denied:
                return "Access Denied"
            case .partial:
                return "Partially Authorized"
            case .authorized:
                return "Authorized"
            }
        }

        var detail: String {
            switch self {
            case .checking:
                return "Checking Health permissions."
            case .unavailable:
                return "Health data is not available on this device."
            case .notDetermined:
                return "Tap Authorize to request access for steps, active energy, and heart rate."
            case .denied:
                return "Access is denied. Enable ScriptWidget in the Health app."
            case .partial:
                return "Some Health data types are not authorized. You can enable more in the Health app."
            case .authorized:
                return "Health access is ready for widgets and scripts."
            }
        }

        var shouldShowAuthorizeButton: Bool {
            switch self {
            case .notDetermined, .denied, .partial:
                return true
            case .checking, .unavailable, .authorized:
                return false
            }
        }

        var shouldShowOpenHealthButton: Bool {
            switch self {
            case .denied, .partial:
                return true
            case .checking, .unavailable, .notDetermined, .authorized:
                return false
            }
        }

        var systemImage: String {
            switch self {
            case .checking: "hourglass"
            case .unavailable: "heart.slash"
            case .notDetermined: "heart"
            case .denied: "exclamationmark.shield"
            case .partial: "heart.circle"
            case .authorized: "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .checking, .unavailable: .secondary
            case .notDetermined: .blue
            case .denied: .red
            case .partial: .orange
            case .authorized: .green
            }
        }
    }

    @State private var authorizationState: HealthAuthorizationState = .checking
    @State private var isRequesting = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    private let healthStore = HKHealthStore()

    var body: some View {
        SettingsStatusView(
            title: authorizationState.title,
            detail: authorizationState.detail,
            systemImage: authorizationState.systemImage,
            color: authorizationState.color
        ) {
            HStack(spacing: 8) {
                if authorizationState.shouldShowAuthorizeButton {
                    Button {
                        requestAuthorization()
                    } label: {
                        Text(isRequesting ? "Authorizing..." : "Authorize")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRequesting)
                }

                if authorizationState.shouldShowOpenHealthButton {
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
        .onAppear {
            refreshAuthorizationState()
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
                    }

                    switch status {
                    case .shouldRequest:
                        authorizationState = .notDetermined
                    case .unnecessary:
                        probeReadAuthorization(readTypes)
                    case .unknown:
                        authorizationState = .notDetermined
                    @unknown default:
                        authorizationState = .notDetermined
                    }
                }
            }
        } else {
            authorizationState = .notDetermined
        }
    }

    private func probeReadAuthorization(_ readTypes: Set<HKObjectType>) {
        let sampleTypes = readTypes.compactMap { $0 as? HKSampleType }
        guard !sampleTypes.isEmpty else {
            authorizationState = .unavailable
            return
        }

        let group = DispatchGroup()
        var authorizedCount = 0
        var deniedCount = 0
        var undeterminedCount = 0

        for sampleType in sampleTypes {
            group.enter()
            let query = HKSampleQuery(sampleType: sampleType, predicate: nil, limit: 1, sortDescriptors: nil) { _, _, error in
                DispatchQueue.main.async {
                    if let error = error as? HKError {
                        switch error.code {
                        case .errorAuthorizationDenied:
                            deniedCount += 1
                        case .errorAuthorizationNotDetermined:
                            undeterminedCount += 1
                        default:
                            authorizedCount += 1
                        }
                    } else {
                        authorizedCount += 1
                    }
                    group.leave()
                }
            }
            healthStore.execute(query)
        }

        group.notify(queue: .main) {
            if undeterminedCount > 0 {
                authorizationState = .notDetermined
            } else if deniedCount > 0 && authorizedCount > 0 {
                authorizationState = .partial
            } else if deniedCount > 0 {
                authorizationState = .denied
            } else {
                authorizationState = .authorized
            }
        }
    }

    private func healthReadTypes() -> Set<HKObjectType> {
        var readTypes = Set<HKObjectType>()
        if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
            readTypes.insert(stepType)
        }
        if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            readTypes.insert(energyType)
        }
        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            readTypes.insert(heartRateType)
        }
        return readTypes
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
            print("settings location error: \(error)")
        }
    }
}
