//
//  ContentView.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/4.
//

import SwiftUI

enum StudioDesign {
    static let compactSpacing: CGFloat = 8
    static let standardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 24
    static let controlCornerRadius: CGFloat = 10
    static let cardCornerRadius: CGFloat = 14
    static let prominentCornerRadius: CGFloat = 18

    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator).opacity(0.32)
}

extension View {
    func studioCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(StudioDesign.cardBackground, in: .rect(cornerRadius: StudioDesign.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: StudioDesign.cardCornerRadius, style: .continuous)
                    .stroke(StudioDesign.separator, lineWidth: 0.5)
            }
    }
}


struct ContentView: View {
    var body: some View {
        TabView {
            ScriptWidgetHomeView()
                .tabItem {
                    Label("Studio", systemImage: "square.stack.3d.up.fill")
                }

            StudioLibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }
        }
        .tint(.indigo)
    }
}

private struct StudioLibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LibraryDestinationRow(
                        title: "Components",
                        detail: "Reusable JSX building blocks",
                        systemImage: "cube.fill",
                        tint: .indigo,
                        destination: BundleScriptListView(
                            navigationTitle: "Components",
                            inlineTitle: false,
                            dataObject: BundleScriptDataObject(bundleName: "Script", bundleDirectory: "component"),
                            onNextAppear: {},
                            onNextDisappear: {}
                        )
                    )

                    LibraryDestinationRow(
                        title: "APIs",
                        detail: "Runtime globals and native capabilities",
                        systemImage: "curlybraces.square.fill",
                        tint: .blue,
                        destination: BundleScriptListView(
                            navigationTitle: "APIs",
                            inlineTitle: false,
                            dataObject: BundleScriptDataObject(bundleName: "Script", bundleDirectory: "api"),
                            onNextAppear: {},
                            onNextDisappear: {}
                        )
                    )

                    LibraryDestinationRow(
                        title: "Templates",
                        detail: "Explore complete, working widget examples",
                        systemImage: "rectangle.stack.fill",
                        tint: .purple,
                        destination: SettingTemplatesView()
                    )
                } header: {
                    Text("Reference")
                } footer: {
                    Text("Use these resources while building widgets in Studio.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(StudioDesign.groupedBackground)
            .navigationTitle("Library")
        }
    }
}

private struct LibraryDestinationRow<Destination: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let destination: Destination

    var body: some View {
        NavigationLink {
            destination
                .toolbar(.hidden, for: .tabBar)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 5)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("iPhone") {
    ContentView()
}

#Preview("Large Type") {
    ContentView()
        .environment(\.dynamicTypeSize, .accessibility2)
}
