//
//  CreateGuideView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/1/3.
//

import SwiftUI

private let defaultNewWidgetSource = """
const family = $getenv("widget-size");

$render(
  <vstack frame="max" padding="16" spacing="8">
    <text font="caption" color="#68728A">NEW WIDGET</text>
    <text font="title" fontWeight="bold">Hello, ScriptWidget!</text>
    <text font="caption" color="#68728A">Family: {family}</text>
  </vstack>
);
"""


class CreateGuideDataObject: ObservableObject {
    @Published var models = [ScriptModel]()

    init() {
        DispatchQueue.global().async { [self] in
            let items = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "template")
                .sorted { left, right in
                    if left.isFeatured != right.isFeatured { return left.isFeatured }
                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            DispatchQueue.main.async {
                self.models = items
            }
        }
    }
}


struct CreateGuideView: View {
    @StateObject private var dataObject = CreateGuideDataObject()

    @Environment(\.dismiss) private var dismiss

    @State private var showingAIGenerate = false
    @State private var showingAIConfigAlert = false
    @State private var showingGallery = false
    @State private var selectedCategory: ScriptCategory? = nil
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quickStartRows
                        .padding(.horizontal)

                    if !searchText.isEmpty {
                        // Hide category chips while searching
                    } else {
                        categoryChips
                    }

                    if filteredModels.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start with a template")
                                .font(.title3.weight(.semibold))
                            Text("Every template is ready to preview and customize.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(filteredModels) { item in
                                NavigationLink(destination: editorDestination(for: item)) {
                                    TemplateCardView(model: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                    }
                }
                .padding(.top, 8)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search templates")
            .navigationTitle("New Widget")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        dismiss()
                    }) {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .navigationDestination(isPresented: $showingAIGenerate) {
                AIGenerateView()
            }
            .sheet(isPresented: $showingGallery) {
                ScriptWidgetGalleryView()
            }
            .alert("Configure AI First", isPresented: $showingAIConfigAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("AI generation uses Apple Private Cloud Compute by default. You can add another provider in Settings → AI.")
            }
        }
    }

    // MARK: - Derived state

    private var filteredModels: [ScriptModel] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return dataObject.models.filter { model in
            if !q.isEmpty {
                let haystack = ([model.name, model.summary ?? ""] + model.tags).joined(separator: " ").lowercased()
                return haystack.contains(q)
            }
            guard let selected = selectedCategory else { return true }
            return model.category == selected
        }
    }

    // MARK: - Subviews

    private var quickStartRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Other ways to start")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { creationShortcuts }
                VStack(spacing: 10) { creationShortcuts }
            }
        }
    }

    @ViewBuilder
    private var creationShortcuts: some View {
        CreationShortcutButton(
            title: "Generate with AI",
            detail: "Describe an idea",
            systemImage: "sparkles",
            color: .purple
        ) {
            if AISettingsStore.shared.load().isConfigured {
                showingAIGenerate = true
            } else {
                showingAIConfigAlert = true
            }
        }

        CreationShortcutButton(
            title: "Blank Widget",
            detail: "Start from code",
            systemImage: "doc.badge.plus",
            color: .blue,
            action: createBlankWidget
        )

        CreationShortcutButton(
            title: "Gallery",
            detail: "Browse community picks",
            systemImage: "square.grid.2x2",
            color: .indigo
        ) {
            showingGallery = true
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryChip(title: "All",
                             systemImage: "square.grid.2x2",
                             color: .gray,
                             selected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(ScriptCategory.allCases) { cat in
                    CategoryChip(title: cat.displayName,
                                 systemImage: cat.systemImage,
                                 color: cat.accentColor,
                                 selected: selectedCategory == cat) {
                        selectedCategory = (selectedCategory == cat) ? nil : cat
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No templates match").font(.headline)
            Text("Try another keyword or category.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func editorDestination(for item: ScriptModel) -> some View {
        ScriptCodeEditorView(mode: .creator, scriptModel: item, actionCreate: {
            guard let content = item.package.readMainFile().0 else { return }
            let imageCopyPath = item.package.imagePath
            _ = sharedScriptManager.createScript(content: content, recommendPackageName: item.name, imageCopyPath: imageCopyPath)
            NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptCreateNotification, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: {
                dismiss()
            })
        })
    }

    private func createBlankWidget() {
        let packageName = sharedScriptManager.getValidPackageName(recommendPackageName: "A New Widget")
        let result = sharedScriptManager.createScript(
            content: defaultNewWidgetSource,
            recommendPackageName: packageName,
            imageCopyPath: nil
        )
        guard result.0 else { return }
        NotificationCenter.default.post(name: ScriptWidgetHomeViewDataObject.scriptCreateNotification, object: nil)
        dismiss()
    }
}

private struct CreationShortcutButton: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: .rect(cornerRadius: StudioDesign.controlCornerRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioCard(padding: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Category chip

struct CategoryChip: View {
    let title: String
    let systemImage: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? .white : color)
            .background(selected ? color : color.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Template card

struct TemplateCardView: View {
    let model: ScriptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Preview area
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(cardBackground)

                if let url = model.package.previewImageURL(),
                   let uiImage = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: model.iconSystemName)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(accentColor)
                }

                if model.isFeatured {
                    VStack {
                        HStack {
                            Label("Featured", systemImage: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: .capsule)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(7)
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let summary = model.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let difficulty = model.difficulty {
                    DifficultyBadge(difficulty: difficulty)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .padding(6)
            .background(Color(.systemBackground), in: .rect(cornerRadius: StudioDesign.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: StudioDesign.cardCornerRadius)
                    .stroke(StudioDesign.separator, lineWidth: 0.5)
            }
    }

    private var accentColor: Color {
        model.category?.accentColor ?? .accentColor
    }

    private var cardBackground: LinearGradient {
        LinearGradient(colors: [accentColor.opacity(0.18), accentColor.opacity(0.06)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct DifficultyBadge: View {
    let difficulty: ScriptDifficulty

    var body: some View {
        Text(difficulty.displayName)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var color: Color {
        switch difficulty {
        case .beginner: return .green
        case .medium:   return .orange
        case .advanced: return .red
        }
    }
}

#Preview("New Widget") {
    CreateGuideView()
}
