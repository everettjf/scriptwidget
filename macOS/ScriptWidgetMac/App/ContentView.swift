//
//  ContentView.swift
//  Shared
//
//  Created by everettjf on 2022/1/14.
//

import SwiftUI

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
