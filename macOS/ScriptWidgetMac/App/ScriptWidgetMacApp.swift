//
//  ScriptWidgetMacApp.swift
//  Shared
//
//  Created by everettjf on 2022/1/14.
//

import SwiftUI

@main
struct ScriptWidgetMacApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate;

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400,minHeight: 300)
                .frame(idealWidth: 800, idealHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Generate Widget with AI...") {
                    NotificationCenter.default.post(name: AIGenerateWindowView.openRequestNotification, object: nil)
                }.keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Save") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NotificationCenter.default.post(name: EditorService.saveNotification, object: nil, userInfo: nil)
                        NotificationCenter.default.post(name: PreviewService.updateNotification, object: nil, userInfo: nil)
                    }
                }.keyboardShortcut("s")

                Button("Run") {
                    NotificationCenter.default.post(name: PreviewService.updateNotification, object: nil, userInfo: nil)
                }.keyboardShortcut("r")

                Button("Open Scripts Directory") {
                    MacKitUtil.revealInFinder(sharedScriptManager.scriptDirectory.path)
                }.keyboardShortcut("o")

                Button("Update iCloud Scripts") {
                    sharedScriptManager.requestUpdateICloudScripts()
                }.keyboardShortcut("u")
            }

            CommandGroup(replacing: .help) {
                Button("Discord") {
                    NSWorkspace.shared.open(URL(string: "https://discord.gg/eGzEaP6TzR")!)
                }
                Button("Mail") {
                    NSWorkspace.shared.open(URL(string: "mailto:xnuapp@gmail.com?subject=ScriptWidgetMac_Feedback")!)
                }
                Button("Developer") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/everettjf")!)
                }
                Button("Help") {
                    NSWorkspace.shared.open(URL(string: "https://xnu.app/scriptwidget")!)
                }
                Button("More Apps") {
                    NSWorkspace.shared.open(URL(string: "https://xnu.app")!)
                }
            }
        }

        Settings {
            SettingAIView()
        }
    }
}
