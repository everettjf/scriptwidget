//
//  AIGenerateView.swift
//  ScriptWidget
//
//  Prompt input → agent loop → review. The session object lives for
//  the duration of this view (including nested refines).
//

import SwiftUI

struct AIGenerateView: View {
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var session = AIGenerateSession()

    @State private var prompt: String = ""
    @State private var showReview = false
    @State private var profiles: [AIProfile] = []
    @State private var activeProfileID: String = ""

    private let placeholderPrompt = "e.g. Show the current weather for my location, with a minimalist dark background."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 6) {
                    Text("Describe your widget")
                        .font(.headline)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $prompt)
                            .frame(minHeight: 120)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(10)
                        if prompt.isEmpty {
                            Text(placeholderPrompt)
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                }

                examplesSection

                if profiles.count > 1 {
                    HStack {
                        Text("Profile")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $activeProfileID) {
                            ForEach(profiles) { profile in
                                Text(profile.name.isEmpty ? "Unnamed" : profile.name).tag(profile.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: activeProfileID) { newValue in
                            AISettingsStore.shared.setActiveProfile(id: newValue)
                        }
                    }
                }

                Picker("Size", selection: $session.size) {
                    ForEach(AIWidgetSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    session.start(userDescription: prompt)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text(session.isRunning ? "Generating..." : "Generate")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if session.isRunning || hasOutcome {
                    AIGenerateProgressView(session: session)
                }
            }
            .padding()
        }
        .navigationTitle("Generate")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadProfiles)
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changedNotification)) { _ in
            loadProfiles()
        }
        .onChange(of: session.phase) { newPhase in
            if case .done = newPhase {
                showReview = true
            } else if case .exhausted = newPhase {
                showReview = true
            }
        }
        .background(
            NavigationLink(isActive: $showReview) {
                AIReviewView(session: session) {
                    presentationMode.wrappedValue.dismiss()
                }
            } label: { EmptyView() }
            .hidden()
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Widget Generator")
                    .font(.title3.weight(.semibold))
                Text("Describe what you want; the AI will iterate until the widget runs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func loadProfiles() {
        profiles = AISettingsStore.shared.loadProfiles()
        activeProfileID = AISettingsStore.shared.loadActiveProfileID()
    }

    private var hasOutcome: Bool {
        switch session.phase {
        case .idle: return false
        default: return true
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try an example")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AIExamplePrompts.all) { example in
                        Button {
                            prompt = example.prompt
                            session.size = example.size
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: example.symbol)
                                Text(example.title)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
