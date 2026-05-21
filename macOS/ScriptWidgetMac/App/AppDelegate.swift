//
//  AppDelegate.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/14.
//

import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("did finish launching")
        // Monaco editor is now served via a WKURLSchemeHandler — no
        // local HTTP server needed.
    }
    
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
