//
//  ScriptWidgetMacApp.swift
//  Shared
//
//  Created by everettjf on 2022/1/14.
//

import SwiftUI
import AppKit

@main
struct ScriptWidgetMacApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate;

    var body: some Scene {
        WindowGroup {
            if let outputDirectory = BatchPreviewConfiguration.outputDirectory {
                BatchPreviewView(outputDirectory: outputDirectory)
            } else {
                ContentView()
                    .frame(minWidth: 760, minHeight: 520)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Generate Widget with AI...") {
                    NotificationCenter.default.post(name: AIGenerateWindowView.openRequestNotification, object: nil)
                }.keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Save") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NotificationCenter.default.post(name: EditorService.saveNotification, object: nil, userInfo: nil)
                        NotificationCenter.default.post(name: PreviewService.updateNotification, object: nil, userInfo: nil)
                    }
                }.keyboardShortcut("s")

                Button("Run") {
                    NotificationCenter.default.post(name: PreviewService.updateNotification, object: nil, userInfo: nil)
                }.keyboardShortcut("r")

                Button("Open Scripts Directory") {
                    MacKitUtil.revealInFinder(sharedScriptManager.scriptDirectory.path)
                }.keyboardShortcut("o")

                Button("Update iCloud Scripts") {
                    sharedScriptManager.requestUpdateICloudScripts()
                }.keyboardShortcut("u")
            }

            CommandGroup(replacing: .help) {
                Button("Discord") {
                    NSWorkspace.shared.open(URL(string: "https://discord.gg/eGzEaP6TzR")!)
                }
                Button("Mail") {
                    NSWorkspace.shared.open(URL(string: "mailto:xnuapp@gmail.com?subject=ScriptWidgetMac_Feedback")!)
                }
                Button("Developer") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/everettjf")!)
                }
                Button("Help") {
                    NSWorkspace.shared.open(URL(string: "https://xnu.app/scriptwidget")!)
                }
                Button("More Apps") {
                    NSWorkspace.shared.open(URL(string: "https://xnu.app")!)
                }
            }
        }

        Settings {
            ScriptWidgetMacSettingsView()
        }
    }
}

private enum BatchPreviewConfiguration {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--render-template-previews"),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flagIndex + 1], isDirectory: true)
    }
}

private struct BatchPreviewView: View {
    let outputDirectory: URL
    @State private var status = "Preparing template previews…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(status)
                .font(.headline)
            Text(outputDirectory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(32)
        .frame(width: 520, height: 180)
        .task {
            await renderAllTemplates()
        }
    }

    @MainActor
    private func renderAllTemplates() async {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let models = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "template")
            var failures: [String] = []

            for (index, model) in models.enumerated() {
                status = "Rendering \(index + 1) of \(models.count): \(model.name)"
                await Task.yield()

                let sizeType = preferredSizeType(for: model)
                let output = ScriptCodeRunnerDataObject.render(
                    package: model.package,
                    widgetSizeType: sizeType,
                    scriptParameter: ""
                )
                if let error = output.errorMessage {
                    failures.append("\(model.name): \(error.replacingOccurrences(of: "\n", with: " "))")
                }

                let size = PreviewWidgetSize.size(sizeType)
                let view = ScriptWidgetElementView(
                    element: output.rootElement,
                    context: ScriptWidgetElementContext(
                        runtime: output.runtime,
                        debugMode: false,
                        scriptName: model.name,
                        scriptParameter: "",
                        package: model.package
                    )
                )
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: 12))

                guard let image = view.snapshot() else {
                    failures.append("\(model.name): snapshot failed")
                    continue
                }
                let filename = model.name.replacingOccurrences(of: "/", with: "-") + ".png"
                MacKitUtil.saveImage(image, atUrl: outputDirectory.appendingPathComponent(filename))
            }

            let report = failures.isEmpty ? "OK\n" : failures.joined(separator: "\n") + "\n"
            try report.write(
                to: outputDirectory.appendingPathComponent("render-report.txt"),
                atomically: true,
                encoding: .utf8
            )
            status = failures.isEmpty ? "Rendered \(models.count) templates" : "Rendered with \(failures.count) failures"
        } catch {
            status = "Batch render failed: \(error.localizedDescription)"
        }

        try? await Task.sleep(for: .milliseconds(500))
        NSApplication.shared.terminate(nil)
    }

    private func preferredSizeType(for model: ScriptModel) -> Int {
        let largeTemplates: Set<String> = [
            "Daily Command Center", "Family Command Board", "Monthly Budget Planner",
            "Travel Day Dashboard", "Wellness Dashboard"
        ]
        if largeTemplates.contains(model.name) { return 2 }

        let mediumTemplates: Set<String> = [
            "Animation Clock", "Battery & Brightness", "Datetime Current", "Datetime Timezone",
            "Device Battery Percent", "Health Steps Ring", "Live Activity Demo", "Local Weather (Location)",
            "Location Snapshot", "Meeting Countdown", "New Episode Tracker", "Open Link",
            "Packing Checklist", "Personal Dashboard", "Plant Care", "Pomodoro Focus",
            "Quick Launcher", "Reading Goal", "Savings Goal", "Shape", "Sleep Schedule",
            "Study Tracker", "Sunrise & Sunset", "System Insights", "System Status Panel",
            "Text Today Week", "Weekly Planner"
        ]
        if mediumTemplates.contains(model.name) { return 1 }
        return 0
    }
}

private struct ScriptWidgetMacSettingsView: View {
    var body: some View {
        TabView {
            SettingAIView()
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }

            Form {
                Section("More Apps") {
                    Link(destination: URL(string: "https://apps.apple.com/us/app/myjsondiff/id6742816661")!) {
                        Label("MyJSONDiff", systemImage: "curlybraces")
                    }
                    Link(destination: URL(string: "https://apps.apple.com/us/app/startmyapp-fast-app-launch/id6753610893")!) {
                        Label("StartMyApp", systemImage: "bolt")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 520, minHeight: 320)
            .tabItem {
                Label("More Apps", systemImage: "square.grid.2x2")
            }
        }
    }
}
