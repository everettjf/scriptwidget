//
//  SettingsICloudView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/27.
//

import SwiftUI

struct SettingsICloudView: View {
    private var isICloudAvailable: Bool {
        sharedScriptManager.isICloudAvaliable()
    }

    private var sandboxFileCount: Int {
        ScriptManager.getSandboxFileCount()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isICloudAvailable ? "iCloud Drive Available" : "Using Local Storage",
                  systemImage: isICloudAvailable ? "icloud.fill" : "internaldrive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isICloudAvailable ? Color.accentColor : Color.secondary)

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isICloudAvailable && sandboxFileCount > 0 {
                CountDownButton(text: "Move \(sandboxFileCount) Local File\(sandboxFileCount == 1 ? "" : "s")", waitSeconds: 2) {
                    _ = ScriptManager.moveSandboxFilesToICloud()
                }
            }

            if isICloudAvailable {
                CountDownButton(text: "Sync from iCloud", waitSeconds: 10) {
                    sharedScriptManager.requestUpdateICloudScripts()
                }
            }
        }
    }

    private var statusMessage: String {
        guard isICloudAvailable else {
            return "Scripts are stored inside ScriptWidget. Enable iCloud Drive to edit and manage them from the Files app."
        }
        if sandboxFileCount > 0 {
            return "iCloud Drive is ready. Move your remaining local files to keep the complete library available across devices."
        }
        return "Scripts are stored in iCloud Drive and can be opened from the Files app. Sync after editing them on another device."
    }
}

struct SettingsICloudView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsICloudView()
            .previewLayout(.sizeThatFits)
            .preferredColorScheme(.light)
        
        SettingsICloudView()
            .previewLayout(.sizeThatFits)
            .preferredColorScheme(.dark)
        
    }
}
