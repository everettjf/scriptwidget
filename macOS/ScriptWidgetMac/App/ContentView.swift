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
        .sheet(isPresented: $showingSkills) {
            SkillManagerView()
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
