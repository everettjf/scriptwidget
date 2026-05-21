//
//  CreateGuideView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/1/3.
//

import SwiftUI


class CreateGuideDataObject: ObservableObject {
    @Published var models = [ScriptModel]()

    init() {
        DispatchQueue.global().async { [self] in
            let items = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "template")
            DispatchQueue.main.async {
                self.models = items
            }
        }
    }
}


struct CreateGuideView: View {
    @ObservedObject var dataObject = CreateGuideDataObject()

    @Environment(\.presentationMode) var presentationMode

    @State private var showingAIGenerate = false
    @State private var showingAIConfigAlert = false
    @State private var selectedCategory: ScriptCategory? = nil
    @State private var searchText: String = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    aiRow
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
            .navigationBarTitle(Text("New Widget"), displayMode: .large)
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
            .background(
                NavigationLink(isActive: $showingAIGenerate) {
                    AIGenerateView()
                } label: { EmptyView() }
                .hidden()
            )
            .alert("Configure AI First", isPresented: $showingAIConfigAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Open Settings → AI to add your OpenAI API key, then come back to generate with AI.")
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

    private var aiRow: some View {
        Button {
            if AISettingsStore.shared.load().isConfigured {
                showingAIGenerate = true
            } else {
                showingAIConfigAlert = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate with AI")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Describe your widget and let the AI build it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No templates match").font(.headline)
            Text("Try another keyword or category.")
                .font(.subheadline)
                .foregroundColor(.secondary)
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
                self.presentationMode.wrappedValue.dismiss()
            })
        })
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
            .foregroundColor(selected ? .white : color)
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
                        .foregroundColor(accentColor)
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let summary = model.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
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
            .foregroundColor(color)
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

struct CreateGuideView_Previews: PreviewProvider {
    static var previews: some View {
        CreateGuideView()
    }
}
