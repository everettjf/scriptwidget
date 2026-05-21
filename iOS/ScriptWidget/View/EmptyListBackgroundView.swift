//
//  EmptyListBackgroundView.swift
//  ScriptWidget
//
//  Onboarding shown on first launch when no widgets exist yet.
//

import SwiftUI

class OnboardingFeaturedDataObject: ObservableObject {
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

struct EmptyListBackgroundView: View {
    @StateObject private var data = OnboardingFeaturedDataObject()
    @State private var showCreate = false
    @State private var selectedFeatured: ScriptModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                    .padding(.top, 20)

                howItWorks

                if !data.featured.isEmpty {
                    featuredSection
                }

                Divider().padding(.vertical, 4)

                browseAll
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .fullScreenCover(isPresented: $showCreate) {
            CreateGuideView()
        }
        .sheet(item: $selectedFeatured) { item in
            NavigationView {
                ScriptCodeEditorView(mode: .creator, scriptModel: item, actionCreate: {
                    guard let content = item.package.readMainFile().0 else { return }
                    let imageCopyPath = item.package.imagePath
                    _ = sharedScriptManager.createScript(
                        content: content,
                        recommendPackageName: item.name,
                        imageCopyPath: imageCopyPath
                    )
                    NotificationCenter.default.post(
                        name: ScriptWidgetHomeViewDataObject.scriptCreateNotification,
                        object: nil
                    )
                    selectedFeatured = nil
                })
            }
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles.square.filled.on.square")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .blue],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
            Text("Build widgets with JavaScript")
                .font(.title2).bold()
            Text("Pick a template, preview it instantly, then add it to your Home Screen. No Xcode required.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                OnboardingStep(number: 1,
                               icon: "square.grid.2x2.fill",
                               title: "Pick",
                               detail: "Choose a ready template.")
                OnboardingStep(number: 2,
                               icon: "play.rectangle.fill",
                               title: "Preview",
                               detail: "Live preview in the editor.")
                OnboardingStep(number: 3,
                               icon: "rectangle.stack.badge.plus",
                               title: "Install",
                               detail: "Add to Home Screen.")
            }
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start with one of these")
                .font(.headline)
            VStack(spacing: 10) {
                ForEach(data.featured.prefix(4)) { item in
                    Button {
                        selectedFeatured = item
                    } label: {
                        FeaturedRow(model: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var browseAll: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showCreate = true
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text("Browse all templates")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Text("Or tap \(Image(systemName: "plus.square")) in the top-right to create from scratch or with AI.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Step card

struct OnboardingStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            Text("\(number). \(title)")
                .font(.subheadline).bold()
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Featured row

struct FeaturedRow: View {
    let model: ScriptModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [accent.opacity(0.25), accent.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 50, height: 50)
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
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var accent: Color {
        model.category?.accentColor ?? .accentColor
    }
}

struct EmptyListBackgroundView_Previews: PreviewProvider {
    static var previews: some View {
        EmptyListBackgroundView()
    }
}
