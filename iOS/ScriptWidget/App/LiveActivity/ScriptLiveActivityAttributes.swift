//
//  ScriptActivityAttributes.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/9/17.
//

import SwiftUI
import Foundation
import ActivityKit


struct ScriptLiveActivityAttributes: ActivityAttributes {
    public typealias ScriptLiveActivityState = ContentState
    
    public struct ContentState: Codable, Hashable {
        var scriptState: String
        var updatedAt: Date

        init(scriptState: String = "", updatedAt: Date = Date()) {
            self.scriptState = scriptState
            self.updatedAt = updatedAt
        }
    }
    
    var scriptName: String
    var scriptParameter: String
}
