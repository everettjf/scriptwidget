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
        ContentUnavailableView {
            Label("Select a Widget", systemImage: "square.grid.2x2")
        } description: {
            Text("Choose a script to edit and preview, or learn how to place it on your Home Screen.")
        } actions: {
            Button("How to Add a Widget") {
                isShowingWidgetGuide = true
            }
            .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $isShowingWidgetGuide) {
            WidgetSetupGuideView()
        }
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

struct HomeHelloView_Previews: PreviewProvider {
    static var previews: some View {
        HomeHelloView()
    }
}
