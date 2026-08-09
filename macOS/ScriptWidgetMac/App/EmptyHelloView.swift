//
//  EmptyHelloView.swift
//  ScriptWidgetMac
//
//  Onboarding / landing pane shown when no widget is selected.
//

import SwiftUI
import AppKit

class MacOnboardingFeaturedDataObject: ObservableObject {
    @Published var featured: [ScriptModel] = []

    init() {
        DispatchQueue.global().async { [weak self] in
            let all = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "template")
            let picked = all.filter { $0.isFeatured }
            DispatchQueue.main.async {
                self?.featured = picked
            }
        }
    }
}

struct EmptyHelloView: View {
    @StateObject private var data = MacOnboardingFeaturedDataObject()
    @State private var showCreate = false
    @State private var showWidgetGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                howItWorks
                if !data.featured.isEmpty {
                    featured
                }
                createRow
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, minHeight: 400)
        .sheet(isPresented: $showCreate) {
            CreateGuideView()
        }
        .sheet(isPresented: $showWidgetGuide) {
            MacWidgetSetupGuideView()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityLabel("ScriptWidget app icon")
            Text("Build widgets with JavaScript")
                .font(.title).bold()
            Text("Pick a template, preview it instantly on your desktop, then add it anywhere widgets go.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.headline)
            HStack(alignment: .top, spacing: 14) {
                MacOnboardingStep(number: 1, icon: "square.grid.2x2.fill", title: "Pick", detail: "Choose a ready template.")
                MacOnboardingStep(number: 2, icon: "play.rectangle.fill", title: "Preview", detail: "Live preview in the editor.")
                MacOnboardingStep(number: 3, icon: "rectangle.stack.badge.plus", title: "Install", detail: "Add to Notification Center or Mac home.")
            }
        }
    }

    private var featured: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start with one of these")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(data.featured) { item in
                    Button {
                        createFromTemplate(item)
                    } label: {
                        MacFeaturedRow(model: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var createRow: some View {
        HStack(spacing: 10) {
            Button {
                showCreate = true
            } label: {
                Label("Browse all templates", systemImage: "square.grid.2x2")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Button {
                NotificationCenter.default.post(
                    name: AIGenerateWindowView.openRequestNotification,
                    object: nil
                )
            } label: {
                Label("Generate with AI", systemImage: "sparkles")
            }
            .controlSize(.large)

            Button {
                showWidgetGuide = true
            } label: {
                Label("Add to Desktop", systemImage: "rectangle.stack.badge.plus")
            }
            .controlSize(.large)
        }
    }

    private func createFromTemplate(_ item: ScriptModel) {
        guard let content = item.package.readMainFile().0 else { return }
        let result = sharedScriptManager.createScript(
            content: content,
            recommendPackageName: item.name,
            imageCopyPath: item.package.imagePath
        )
        if result.0 {
            NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
        } else {
            MacKitUtil.alertWarn(title: "Create failed", message: result.1)
        }
    }
}

struct MacWidgetSetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add ScriptWidget to your Mac")
                        .font(.title2.bold())
                    Text("Place a script on the desktop or in Notification Center.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MacWidgetSetupStep(number: 1, icon: "desktopcomputer", title: "Open the widget gallery", detail: "Control-click the desktop and choose Edit Widgets, or open Notification Center and choose Edit Widgets.")
                    MacWidgetSetupStep(number: 2, icon: "magnifyingglass", title: "Find ScriptWidget", detail: "Search for ScriptWidget, pick a size, then drag it onto the desktop or Notification Center.")
                    MacWidgetSetupStep(number: 3, icon: "slider.horizontal.3", title: "Choose your script", detail: "Control-click the widget, choose Edit ScriptWidget, then select a script, parameter, and refresh frequency.")
                    MacWidgetSetupStep(number: 4, icon: "icloud", title: "Share across devices", detail: "Keep ScriptWidget open long enough for iCloud to download scripts before selecting them in a widget.")

                    HStack(spacing: 12) {
                        Button {
                            MacKitUtil.revealInFinder(sharedScriptManager.scriptDirectory.path)
                        } label: {
                            Label("Open Scripts Folder", systemImage: "folder")
                        }

                        Button {
                            sharedScriptManager.requestUpdateICloudScripts()
                        } label: {
                            Label("Sync iCloud Scripts", systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    .controlSize(.large)
                }
                .padding(24)
            }
        }
        .frame(width: 620, height: 540)
    }
}

private struct MacWidgetSetupStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(number). \(title)")
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MacOnboardingStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            Text("\(number). \(title)")
                .font(.subheadline).bold()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MacFeaturedRow: View {
    let model: ScriptModel

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [accent.opacity(0.25), accent.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 52, height: 52)
                Image(systemName: model.iconSystemName)
                    .font(.system(size: 22))
                    .foregroundColor(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                if let summary = model.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(accent.opacity(isHovered ? 1.0 : 0.5))
        }
        .padding(12)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? accent.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var accent: Color {
        model.category?.accentColor ?? .accentColor
    }
}

struct EmptyHelloView_Previews: PreviewProvider {
    static var previews: some View {
        EmptyHelloView()
    }
}
