//
//  EmptyListBackgroundView.swift
//  ScriptWidgetMac
//
//  Compact empty state shown inside the sidebar when no widgets exist.
//

import SwiftUI

struct EmptyListBackgroundView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("No widgets yet")
                .font(.subheadline).bold()
            Text("Use New Widget in the toolbar to browse templates or generate with AI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

#Preview("Empty Sidebar") {
    EmptyListBackgroundView()
        .padding()
}
