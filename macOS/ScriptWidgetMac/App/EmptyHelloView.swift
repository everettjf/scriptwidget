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
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles.square.filled.on.square")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .blue],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
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
