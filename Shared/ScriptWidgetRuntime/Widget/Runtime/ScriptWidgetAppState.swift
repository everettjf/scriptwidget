//
//  ScriptWidgetGlobalState.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/11/2.
//

import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

class ScriptWidgetAppState {
    
    init() {
        #if os(macOS)
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }
}

let sharedAppState = ScriptWidgetAppState()
