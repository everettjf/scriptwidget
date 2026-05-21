//
//  CreateGuideView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/18.
//

import SwiftUI
import AppKit

let defaultCreateScriptContent = """

//
// ScriptWidget
// https://xnu.app/scriptwidget
//
//

// widget-size : large,medium,small
const widget_size = $getenv("widget-size");

// parameter
const widget_param = $getenv("widget-param");

$render(
  <vstack frame="max">
    <text font="title">Hello New Widget</text>
    <text font="caption">{widget_size}</text>
    <text font="caption">{widget_param}</text>
  </vstack>
);

"""

class MacCreateGuideDataObject: ObservableObject {
    @Published var models: [ScriptModel] = []

    init() {
        DispatchQueue.global().async { [weak self] in
            let items = ScriptManager.listBundleScripts(bundle: "Script", relativePath: "template")
            DispatchQueue.main.async {
                self?.models = items
            }
        }
    }
}

struct CreateGuideView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var dataObject = MacCreateGuideDataObject()

    @State private var selectedCategory: ScriptCategory? = nil
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    aiAndBlankRow

                    if searchText.isEmpty {
                        categoryChips
                    }

                    if filteredModels.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                            ForEach(filteredModels) { item in
                                MacTemplateCardView(model: item) {
                                    createFromTemplate(item)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 540, idealHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("New Widget")
                .font(.title2).bold()

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search templates", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 180)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var aiAndBlankRow: some View {
        HStack(spacing: 12) {
            aiCard
            blankCard
        }
    }

    private var aiCard: some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(
                    name: AIGenerateWindowView.openRequestNotification,
                    object: nil
                )
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [.purple, .blue],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate with AI").font(.headline)
                    Text("Describe your widget and let the AI build it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var blankCard: some View {
        Button {
            createBlank()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blank Widget").font(.headline)
                    Text("Start from an empty template.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MacCategoryChip(title: "All",
                                systemImage: "square.grid.2x2",
                                color: .gray,
                                selected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(ScriptCategory.allCases) { cat in
                    MacCategoryChip(title: cat.displayName,
                                    systemImage: cat.systemImage,
                                    color: cat.accentColor,
                                    selected: selectedCategory == cat) {
                        selectedCategory = (selectedCategory == cat) ? nil : cat
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No templates match").font(.headline)
            Text("Try another keyword or category.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

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

    private func createFromTemplate(_ item: ScriptModel) {
        guard let content = item.package.readMainFile().0 else {
            MacKitUtil.alertWarn(title: "Failed to read template", message: "Please retry or relaunch the app.")
            return
        }
        let result = sharedScriptManager.createScript(
            content: content,
            recommendPackageName: item.name,
            imageCopyPath: item.package.imagePath
        )
        if !result.0 {
            MacKitUtil.alertWarn(title: "Create failed", message: result.1)
            return
        }
        NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
        dismiss()
    }

    private func createBlank() {
        let scriptName = ScriptManager(isBuild: false).getValidPackageName(recommendPackageName: "A New Widget")
        let result = sharedScriptManager.createScript(
            content: defaultCreateScriptContent,
            recommendPackageName: scriptName,
            imageCopyPath: nil
        )
        if !result.0 {
            MacKitUtil.alertWarn(title: "Create failed", message: "Please retry or relaunch app :)\nError : \(result.1)")
            return
        }
        NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
        dismiss()
    }
}

// MARK: - Mac template card

struct MacTemplateCardView: View {
    let model: ScriptModel
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(cardBackground)

                    if let url = model.package.previewImageURL(),
                       let nsImage = NSImage(contentsOfFile: url.path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: model.iconSystemName)
                            .font(.system(size: 30))
                            .foregroundColor(accentColor)
                    }
                }
                .frame(height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let summary = model.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let difficulty = model.difficulty {
                        MacDifficultyBadge(difficulty: difficulty)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(8)
            .background(Color(nsColor: NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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

struct MacCategoryChip: View {
    let title: String
    let systemImage: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.caption)
                Text(title).font(.subheadline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(selected ? .white : color)
            .background(selected ? color : color.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MacDifficultyBadge: View {
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
