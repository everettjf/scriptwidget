//
//  ScriptWidgetRootView.swift
//  ScriptWidgetWidget
//
//  Created by zhufeng on 2023/10/7.
//

import Foundation
import WidgetKit
import SwiftUI
import Intents
import Combine


struct ScriptWidgetWidgetElementRootView: View {
    private let data: ScriptWidgetDataObject
    let widgetFamily: WidgetFamily
    let scriptName: String
    let scriptParameter: String

    init(widgetFamily: WidgetFamily, entry: ScriptWidgetTimelineProvider.Entry) {
        self.widgetFamily = widgetFamily
        self.scriptName = entry.configuration.Script ?? ""
        self.scriptParameter = entry.configuration.Parameter ?? ""
        
        self.data = ScriptWidgetDataObject(scriptName: self.scriptName, scriptParameter: self.scriptParameter, widgetFamily: self.widgetFamily)
        NSLog("!! will run script sync")
        self.data.runScriptSync()
    }
    
    @ViewBuilder
    var body: some View {
        ScriptWidgetElementView(
            element: data.rootElement,
            context: ScriptWidgetElementContext(
                runtime: data.runtime,
                debugMode: false,
                scriptName: self.scriptName,
                scriptParameter: self.scriptParameter,
                package: data.package
            )
        )
    }
}
