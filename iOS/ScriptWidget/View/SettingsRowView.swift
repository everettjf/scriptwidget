//
//  SettingsRowView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/6.
//

import SwiftUI

struct SettingsLinkRowView: View {
    
    let name: String
    
    // link mode
    var label: String
    var urlString: String
    
    var body: some View {
        Link(destination: URL(string: urlString)!) {
            HStack {
                Text(LocalizedStringKey(name))
                Spacer()
                if !label.isEmpty {
                    Text(LocalizedStringKey(label))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsTextRowView: View {
    
    let name: String
    
    var content: String
    
    var body: some View {
        HStack {
            Text(LocalizedStringKey(name))
            Spacer()
            Text(content)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsRowView_Previews: PreviewProvider {
    static var previews: some View {
        
        SettingsLinkRowView(name: "Website", label: "Pale Blue Dot", urlString: "https://everettjf.github.io")
            .preferredColorScheme(.dark)
            .previewLayout(.fixed(width: 375, height: 60))
            .padding()
    }
}
