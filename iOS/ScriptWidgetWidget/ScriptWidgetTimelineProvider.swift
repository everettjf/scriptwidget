//
//  ScriptWidgetTimelineProvider.swift
//  ScriptWidgetWidget
//
//  Created by zhufeng on 2023/10/7.
//

import Foundation
import WidgetKit
import SwiftUI
import Intents
import Combine

struct ScriptWidgetTimelineProvider: AppIntentTimelineProvider {
  
    func placeholder(in context: Context) -> ScriptWidgetTimelineEntry {
        ScriptWidgetTimelineEntry(isPreview: true, date: Date(), configuration: ScriptWidgetAppIntent())
    }
    
    func snapshot(for configuration: ScriptWidgetAppIntent, in context: Context) async -> ScriptWidgetTimelineEntry {
        let entry = ScriptWidgetTimelineEntry(isPreview: context.isPreview, date: Date(), configuration: configuration)
        return entry
    }

    func timeline(for configuration: ScriptWidgetAppIntent, in context: Context) async -> Timeline<ScriptWidgetTimelineEntry> {
        let offset = (configuration.Frequency ?? .hours_1).refreshOffset
        let entryDate = Calendar.current.date(byAdding: offset.component, value: offset.value, to: Date())!
        let entry = ScriptWidgetTimelineEntry(isPreview: false, date: entryDate, configuration: configuration)
        return Timeline(entries: [entry], policy: .atEnd)
    }
}

extension AppConfigFrequency {
    /// Calendar offset used to schedule the next widget refresh.
    var refreshOffset: (component: Calendar.Component, value: Int) {
        switch self {
        case .minutes_1:  return (.minute, 1)
        case .minutes_10: return (.minute, 10)
        case .minutes_30: return (.minute, 30)
        case .hours_1:    return (.hour, 1)
        case .hours_3:    return (.hour, 3)
        case .hours_6:    return (.hour, 6)
        case .hours_12:   return (.hour, 12)
        case .day_1:      return (.day, 1)
        }
    }
}

struct ScriptWidgetTimelineEntry: TimelineEntry {
    let isPreview: Bool
    let date: Date
    let configuration: ScriptWidgetAppIntent
}
