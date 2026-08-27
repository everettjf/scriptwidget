//
//  ButtonOfficalSite.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/24.
//

import SwiftUI

struct ButtonOfficalSite: View {
    var body: some View {
        Button(action: {
            NSWorkspace.shared.open(URL(string: "https://xnu.app/scriptwidget")!)
        }) {
            Label("ScriptWidget Help", systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
        }
        .help("Open ScriptWidget help")
    }
}

#Preview("Help Button") {
    ButtonOfficalSite()
}
