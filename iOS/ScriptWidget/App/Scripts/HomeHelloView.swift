//
//  HomeHelloView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/2/27.
//

import SwiftUI

struct HomeHelloView: View {
    @State private var isShowingWidgetGuide = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.07), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.tint.opacity(0.12))
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Your Widget Workspace")
                        .font(.title2.bold())
                    Text("Select a script to edit code, manage assets, and preview every supported widget size.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                HStack(spacing: 18) {
                    WorkspaceCapability(icon: "chevron.left.forwardslash.chevron.right", title: "Code")
                    WorkspaceCapability(icon: "play.rectangle", title: "Preview")
                    WorkspaceCapability(icon: "photo.on.rectangle", title: "Assets")
                }

                Button {
                    isShowingWidgetGuide = true
                } label: {
                    Label("How to Add a Widget", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingWidgetGuide) {
            WidgetSetupGuideView()
        }
    }
}

private struct WorkspaceCapability: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
    }
}

struct WidgetSetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Put ScriptWidget on your Home Screen")
                            .font(.title2.bold())
                        Text("Your scripts become available inside one configurable ScriptWidget widget.")
                            .foregroundStyle(.secondary)
                    }

                    WidgetSetupStep(number: 1, icon: "hand.tap", title: "Open the widget gallery", detail: "Touch and hold an empty area on the Home Screen, tap Edit, then tap Add Widget.")
                    WidgetSetupStep(number: 2, icon: "magnifyingglass", title: "Find ScriptWidget", detail: "Search for ScriptWidget, choose a size, and add it to the Home Screen.")
                    WidgetSetupStep(number: 3, icon: "slider.horizontal.3", title: "Choose your script", detail: "Touch and hold the new widget, tap Edit Widget, then select the script and refresh frequency.")
                    WidgetSetupStep(number: 4, icon: "arrow.clockwise", title: "Keep it fresh", detail: "After editing code, return to ScriptWidget and pull to refresh. WidgetKit may schedule updates to protect battery life.")

                    Label("Tip: create separate widget instances for different scripts and parameters.", systemImage: "lightbulb.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 12))
                }
                .padding()
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Add Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct WidgetSetupStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.14))
                Image(systemName: icon)
                    .foregroundStyle(.tint)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Workspace") {
    HomeHelloView()
}

#Preview("Workspace · Large Type") {
    HomeHelloView()
        .environment(\.dynamicTypeSize, .accessibility2)
}
