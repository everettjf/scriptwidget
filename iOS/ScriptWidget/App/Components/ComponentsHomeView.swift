//
//  ComponentsHomeView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/9/9.
//

import SwiftUI

struct ComponentsHomeView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isTabBarVisible = true

    var body: some View {
        NavigationStack {
            BundleScriptListView(
                navigationTitle: "Components",
                inlineTitle: false,
                dataObject: BundleScriptDataObject(bundleName: "Script", bundleDirectory: "component")) {
                    showTabBar(false)
                } onNextDisappear: {
                    showTabBar(true)
                }
        }
        .toolbar(horizontalSizeClass == .regular || isTabBarVisible ? .visible : .hidden, for: .tabBar)
    }
    
    func showTabBar(_ visible: Bool) {
        isTabBarVisible = visible
    }
}

#Preview("Components") {
    ComponentsHomeView()
}
