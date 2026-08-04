//
//  ContentView.swift
//  Shared
//
//  Created by everettjf on 2022/1/14.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = SharedAppStore()
    
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
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
