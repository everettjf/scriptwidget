//
//  SwiftWidgetRuntimeDevice.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/15.
//

import Foundation
import JavaScriptCore

#if os(macOS)
import AppKit
import IOKit.ps
#else
import UIKit
#endif

@objc protocol ScriptWidgetRuntimeDeviceExports: JSExport {
    static func screen() -> [AnyHashable: Any]!
    static func language() -> String
    static func model() -> String
    static func name() -> String
    static func battery() -> [AnyHashable: Any]!
    static func systemVersion() -> String
    static func isdarkmode() -> Bool
    static func totalDiskSpace() -> Int64
    static func freeDiskSpace() -> Int64
}

@objc public class ScriptWidgetRuntimeDevice: NSObject, ScriptWidgetRuntimeDeviceExports {
    
    static func totalDiskSpace() -> Int64 {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory() as String)
            let space = (systemAttributes[FileAttributeKey.systemSize] as? NSNumber)?.int64Value
            return space ?? 0
        } catch {
            return 0
        }
    }
    
    static func freeDiskSpace() -> Int64 {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory() as String)
            let freeSpace = (systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber)?.int64Value
            return freeSpace ?? 0
        } catch {
            return 0
        }
    }
    
#if os(macOS)
    
    
    static func isdarkmode() -> Bool {
        return true
    }
    
    static func screen() -> [AnyHashable : Any]! {
        let bounds = NSScreen.main!.frame.size
        return [
            "scale" : 0.5,
            "width" : bounds.width,
            "height": bounds.height,
        ]
    }
    
    static func language() -> String {
        return Locale.current.language.languageCode?.identifier ?? ""
    }
    
    static func model() -> String {
        return "model"
    }
    
    static func name() -> String {
        return "name"
    }
    
    static func battery() -> [AnyHashable : Any]! {
        var level: Float = 0
        var state = "unknown"
        
        // Take a snapshot of all the power source info
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        // Pull out a list of power sources
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        // For each power source...
        for ps in sources {
            // Fetch the information for a given power source out of our snapshot
            let info = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as! [String: AnyObject]

            // Pull out the name and capacity
            if let name = info[kIOPSNameKey] as? String,
                let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int,
            let sourcestate = info[kIOPSPowerSourceStateKey] as? String {
                print("\(name): \(capacity) of \(max) , sourcestate \(sourcestate)")
                if (max > 0) {
                    level = Float(capacity) / Float(max);
                }
                if sourcestate == kIOPSACPowerValue {
                    state = "charging"
                } else if sourcestate == kIOPSBatteryPowerValue {
                    state = "default"
                } else if sourcestate == kIOPSOffLineValue {
                    state = "unplugged"
                } else {
                    state = "default"
                }
                break;
            }
        }
        
        return [
            "level" : level,
            "state" : state
        ]
    }
    
    static func systemVersion() -> String {
        return "1.0"
    }
#else
    
    
    static func isdarkmode() -> Bool {
        return UITraitCollection.current.userInterfaceStyle == .dark
    }
    
    static func screen() -> [AnyHashable : Any]! {
        let bounds = UIScreen.main.bounds
        return [
            "scale" : UIScreen.main.scale,
            "width" : bounds.width,
            "height": bounds.height,
        ]
    }
    
    static func language() -> String {
        return Locale.current.language.languageCode?.identifier ?? ""
    }
    
    static func model() -> String {
        return UIDevice.current.model
    }
    
    static func name() -> String {
        return UIDevice.current.name
    }
    
    static func battery() -> [AnyHashable : Any]! {
        var level = UIDevice.current.batteryLevel
        if level < 0 {
            level = 0
        }
        
        var state = "unknown"
        switch UIDevice.current.batteryState {
        case .unknown: state = "unknown"
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "default"
        }
        
        return [
            "level" : level,
            "state" : state
        ]
    }
    
    static func systemVersion() -> String {
        return UIDevice.current.systemVersion
    }
#endif
}
