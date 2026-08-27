//
//  ContentView.swift
//  Shared
//
//  Created by everettjf on 2022/1/14.
//

import SwiftUI

enum StudioDesign {
    static let compactSpacing: CGFloat = 8
    static let standardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 24
    static let controlCornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 12
    static let prominentCornerRadius: CGFloat = 16

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color.secondary.opacity(0.2)
}

extension View {
    func studioCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(StudioDesign.cardBackground, in: .rect(cornerRadius: StudioDesign.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: StudioDesign.cardCornerRadius, style: .continuous)
                    .stroke(StudioDesign.separator, lineWidth: 1)
            }
    }
}

struct ContentView: View {
    @StateObject private var store = SharedAppStore()
    @State private var showingSkills = false
    @State private var showingGallery = false
    @State private var showingOnboarding = false
    
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            EmptyHelloView()
                .toolbar {
                    ButtonOfficalSite()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.indigo)
        .onReceive(NotificationCenter.default.publisher(for: SkillManagerOpenRequest.notification)) { _ in
            showingSkills = true
        }
        .onReceive(NotificationCenter.default.publisher(for: GalleryOpenRequest.notification)) { _ in
            showingGallery = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MacOnboardingOpenRequest.notification)) { _ in
            MacOnboardingProgressStore().restart()
            showingOnboarding = true
        }
        .onAppear {
            if MacOnboardingProgressStore().shouldPresent {
                showingOnboarding = true
            }
        }
        .sheet(isPresented: $showingSkills) {
            SkillManagerView()
        }
        .sheet(isPresented: $showingGallery) {
            ScriptWidgetGalleryView()
        }
        .sheet(isPresented: $showingOnboarding) {
            FirstRunOnboardingView()
        }
    }
}

enum SkillManagerOpenRequest {
    static let notification = Notification.Name("SkillManagerOpenRequest")
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
