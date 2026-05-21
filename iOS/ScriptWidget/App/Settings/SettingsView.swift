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
    
    @Environment(\.presentationMode) var presentationMode
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
    
    var body: some View {
        content
            .alert(isPresented: $showingAlert) {
                Alert(title: Text("Notification"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
    }

    var content: some View {
        NavigationView {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    
                    GroupBox (label: SettingsLabelView(title: "ScriptWidget", image: "info.circle")) {
                        NavigationLink(destination: SettingTemplatesView()) {
                            SettingsTextRowView(name: "Templates", content: "")
                        }
                    }

                    GroupBox (label: SettingsLabelView(title: "AI", image: "sparkles")) {
                        NavigationLink(destination: SettingAIView()) {
                            SettingsTextRowView(name: "AI Generate", content: "")
                        }
                    }


                    GroupBox (label: SettingsLabelView(title: "Refresh", image: "paintbrush")) {
                        Divider().padding(.vertical, 4)

                        HStack {
                            Text("Force all widgets to re-run their JavaScript code. This is useful after you've made changes to the code.")
                                .padding(.vertical, 8)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                            
                            Spacer()
                            
                            Button {
                                WidgetCenter.shared.reloadAllTimelines()
                                
                                showAlert("Widgets are refreshed :)")
                            } label: {
                                Image(systemName: "paintbrush")
                                    .font(.caption)
                                Text("Refresh")
                                    .font(.caption)
                                    .width(50)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    
                    GroupBox (label: SettingsLabelView(title: "Export & Import", image: "info.circle")) {
                        
                        NavigationLink(destination: ExportView()) {
                            SettingsTextRowView(name: "Export", content: "")
                        }
                        NavigationLink(destination: ImportView()) {
                            SettingsTextRowView(name: "Import", content: "")
                        }
                    }
                    
                    
                    GroupBox (label: SettingsLabelView(title: "iCloud", image: "icloud")) {
                        Divider().padding(.vertical, 4)
                        
                        SettingsICloudView()
                    }

                    GroupBox (label: SettingsLabelView(title: "Health", image: "heart")) {
                        Divider().padding(.vertical, 4)

                        SettingsHealthView()
                    }

                    GroupBox (label: SettingsLabelView(title: "Location", image: "location")) {
                        Divider().padding(.vertical, 4)

                        SettingsLocationView()
                    }
                    
                    GroupBox (label: SettingsLabelView(title: "Application", image: "appclip")) {
                        
                        NavigationLink(destination: AppIconsView()) {
                            SettingsTextRowView(name: "App Icons", content: "")
                        }
                        SettingsLinkRowView(name: "Website", label: "https://xnu.app/scriptwidget", urlString: "https://xnu.app/scriptwidget")
                        SettingsLinkRowView(name: "Discord", label: "", urlString: "https://discord.gg/eGzEaP6TzR")
                        SettingsLinkRowView(name: "Developer", label: "everettjf", urlString: "https://twitter.com/everettjf")
                        SettingsLinkRowView(name: "Special Thanks", label: "Reina", urlString: "https://github.com/Reinachan")
                        SettingsTextRowView(name: "Version", content: AppHelper.getAppVersion())
                        SettingsLinkRowView(name: "More Apps", label: "https://xnu.app", urlString: "https://xnu.app")
                    }
                    
                }
                .navigationBarTitle(Text("Settings"), displayMode: .large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            Label("Close", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .padding()
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .preferredColorScheme(.dark)
            .previewDevice("iPhone 12 Pro")
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
    }

    @State private var authorizationState: HealthAuthorizationState = .checking
    @State private var isRequesting = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    private let healthStore = HKHealthStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(authorizationState.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.top, 4)

            Text(authorizationState.detail)
                .font(.footnote)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                if authorizationState.shouldShowAuthorizeButton {
                    Button {
                        requestAuthorization()
                    } label: {
                        Text(isRequesting ? "Authorizing..." : "Authorize")
                            .font(.caption)
                            .frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRequesting)
                }

                if authorizationState.shouldShowOpenHealthButton {
                    Button {
                        openHealthApp()
                    } label: {
                        Text("Open Health")
                            .font(.caption)
                            .frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
        }
        .onAppear {
            refreshAuthorizationState()
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("Health"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
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
    }

    @StateObject private var manager = SettingsLocationManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manager.state.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.top, 4)

            Text(manager.state.detail)
                .font(.footnote)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                if manager.state.shouldShowAuthorizeButton {
                    Button {
                        manager.requestAuthorization()
                    } label: {
                        Text(manager.isRequesting ? "Authorizing..." : "Authorize")
                            .font(.caption)
                            .frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isRequesting)
                }

                if manager.state.shouldShowOpenSettingsButton {
                    Button {
                        openSettings()
                    } label: {
                        Text("Open Settings")
                            .font(.caption)
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
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
