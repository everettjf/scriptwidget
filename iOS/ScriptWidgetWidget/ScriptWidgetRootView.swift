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

    init(widgetFamily: WidgetFamily, renderingMode: WidgetRenderingMode, entry: ScriptWidgetTimelineProvider.Entry) {
        self.widgetFamily = widgetFamily
        self.scriptName = entry.configuration.Script ?? ""
        self.scriptParameter = entry.configuration.Parameter ?? ""
        
        let renderingModeValue: String
        switch renderingMode {
        case .accented: renderingModeValue = "accented"
        case .vibrant: renderingModeValue = "vibrant"
        default: renderingModeValue = "fullColor"
        }
        self.data = ScriptWidgetDataObject(
            scriptName: self.scriptName,
            scriptParameter: self.scriptParameter,
            widgetFamily: self.widgetFamily,
            widgetRenderingMode: renderingModeValue
        )
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
