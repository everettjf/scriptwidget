//
//  ScriptWidgetWidget.swift
//  ScriptWidgetWidget
//
//  Created by everettjf on 2020/10/4.
//

import WidgetKit
import SwiftUI
import Intents
import Combine

struct ScriptWidgetMainWidget: Widget {

    private var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [
            .systemSmall, .systemMedium, .systemLarge,
            .systemExtraLarge,
            .accessoryInline, .accessoryCircular, .accessoryRectangular,
        ]
        #if compiler(>=6.4)
            if #available(iOSApplicationExtension 27.0, *) {
                families.append(.systemExtraLargePortrait)
            }
        #endif
        return families
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScriptWidget", intent: ScriptWidgetAppIntent.self, provider: ScriptWidgetTimelineProvider()) { entry in
            ScriptWidgetWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("ScriptWidget")
        .description("Build widgets with JavaScript")
        .supportedFamilies(supportedFamilies)
        .contentMarginsDisabled()
    }
    
    init() {
        let _ = sharedAppState
    }
}

@main
struct ScriptWidgets: WidgetBundle {
    var body: some Widget {
        ScriptWidgetMainWidget()
        ScriptLiveActivityWidget()
        ScriptWidgetButtonControlWidget()
        ScriptWidgetControlWidget()
    }
}
