//
//  Script.swift
//  ScriptWidgetWidget
//
//  Created by zhufeng on 2023/10/7.
//

import Foundation
import AppIntents

struct ScriptWidgetAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Script"
    static var description = IntentDescription("Choose script that will execute")

    @Parameter(title: "Script", optionsProvider: AvailableScriptOptionsProvider())
    var Script: String?

    struct AvailableScriptOptionsProvider: DynamicOptionsProvider {
        func results() async throws -> [String] {
            let items = sharedScriptManager.listScripts()
            let scripts = items.map { $0.name }
            return scripts
        }
    }

    @Parameter(title: "Frequency")
    var Frequency: AppConfigFrequency?

    @Parameter(title: "Parameter")
    var Parameter: String?

    static var parameterSummary: some ParameterSummary {
        Summary()
    }

}
