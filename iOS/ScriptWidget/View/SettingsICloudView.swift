//
//  SettingsICloudView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/27.
//

import SwiftUI

struct SettingsICloudView: View {
    @State private var migrationMessage: String?
    private var isICloudAvailable: Bool {
        sharedScriptManager.isICloudAvaliable()
    }

    private var sandboxFileCount: Int {
        ScriptManager.getSandboxFileCount()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.standardSpacing) {
            Label(isICloudAvailable ? "iCloud Drive Available" : "Using Local Storage",
                  systemImage: isICloudAvailable ? "icloud.fill" : "internaldrive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isICloudAvailable ? Color.accentColor : Color.secondary)

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isICloudAvailable && sandboxFileCount > 0 {
                CountDownButton(text: "Move \(sandboxFileCount) Local File\(sandboxFileCount == 1 ? "" : "s")", waitSeconds: 2) {
                    migrationMessage = ScriptManager.moveSandboxFilesToICloud()
                        ? "Local files moved to iCloud."
                        : "Some files could not be moved. Remaining local files have been kept. Try again when iCloud is available."
                }
                .buttonStyle(.borderedProminent)
            }

            if let migrationMessage {
                Text(migrationMessage).font(.footnote).foregroundStyle(.secondary)
            }

            if isICloudAvailable {
                CountDownButton(text: "Sync from iCloud", waitSeconds: 10) {
                    sharedScriptManager.requestUpdateICloudScripts()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
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

#Preview("iCloud Settings") {
    SettingsICloudView()
        .padding()
}

#Preview("iCloud Settings · Dark") {
    SettingsICloudView()
        .padding()
        .preferredColorScheme(.dark)
}
