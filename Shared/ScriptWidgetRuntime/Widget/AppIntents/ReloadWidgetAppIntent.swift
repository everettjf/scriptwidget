//
//  ReloadWidgetAppIntent.swift
//  ScriptWidget
//
//  Created by ScriptWidget contributors.
//

import Foundation
import AppIntents
import WidgetKit

struct ReloadWidgetAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh ScriptWidget"
    static var description = IntentDescription("Refresh ScriptWidget timelines.")
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .widgetKitExtension }
    #endif

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "ScriptWidget")
        return .result()
    }
}
