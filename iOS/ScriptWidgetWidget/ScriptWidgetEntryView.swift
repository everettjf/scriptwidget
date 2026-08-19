//
//  ScriptWidgetEntryView.swift
//  ScriptWidgetWidget
//
//  Created by zhufeng on 2023/10/7.
//

import Foundation
import WidgetKit
import SwiftUI
import Intents
import Combine


struct ScriptWidgetWidgetEntryView : View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    var entry: ScriptWidgetTimelineProvider.Entry
    
    init(entry: ScriptWidgetTimelineProvider.Entry) {
        self.entry = entry
    }

    @ViewBuilder
    var body: some View {
        if self.entry.isPreview {
            ScriptWidgetPlaceholderView(widgetFamily: self.widgetFamily)
                .containerBackground(.background, for: .widget)
        } else {
            ScriptWidgetWidgetElementRootView(widgetFamily: self.widgetFamily, renderingMode: widgetRenderingMode, entry: self.entry)
        }
    }
}


struct ScriptWidgetWidget_Previews: PreviewProvider {
    static var previews: some View {
        let entry = ScriptWidgetTimelineEntry(isPreview:false ,date: Date(), configuration: ScriptWidgetAppIntent())
        
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemSmall))
            .previewDisplayName("systemSmall")
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemMedium))
            .previewDisplayName("systemMedium")
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemLarge))
            .previewDisplayName("systemLarge")
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .systemExtraLarge))
            .previewDisplayName("systemExtraLarge")
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .accessoryInline))
            .previewDisplayName("accessoryInline")
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .accessoryCircular))
            .previewDisplayName("accessoryCircular")
        ScriptWidgetWidgetEntryView(entry: entry)
            .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
            .previewDisplayName("accessoryRectangular")
    }
}
