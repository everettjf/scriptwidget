//
//  ScriptLiveActivityWidget.swift
//  ScriptWidgetWidget
//
//  Created by everettjf on 2022/9/17.
//

import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 16.1, *)
struct ScriptLiveActivityWidget: Widget {
    
    
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScriptLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            createIsland(context: context)
        }
        .contentMarginsDisabled()
    }
    
    func createIsland(context: ActivityViewContext<ScriptLiveActivityAttributes>) -> DynamicIsland {
        
        let creator = ScriptDynamicIslandCreator(scriptName: context.attributes.scriptName, scriptParameter: context.attributes.scriptParameter)

        creator.runScriptSync()
        
        let context = ScriptWidgetElementContext(runtime: creator.runtime, debugMode: false, scriptName: context.attributes.scriptName, scriptParameter: context.attributes.scriptParameter, package: creator.package)
        
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                if let element = creator.rootElement.expanded.leading {
                    ScriptWidgetElementView(element: element, context: context)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                if let element = creator.rootElement.expanded.trailing {
                    ScriptWidgetElementView(element: element, context: context)
                }
            }
            DynamicIslandExpandedRegion(.center) {
                if let element = creator.rootElement.expanded.center {
                    ScriptWidgetElementView(element: element, context: context)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                if let element = creator.rootElement.expanded.bottom {
                    ScriptWidgetElementView(element: element, context: context)
                }
            }
        } compactLeading: {
            ScriptWidgetElementView(element: creator.rootElement.compactLeading, context: context)
        } compactTrailing: {
            ScriptWidgetElementView(element: creator.rootElement.compactTrailing, context: context)
        } minimal: {
            ScriptWidgetElementView(element: creator.rootElement.minimal, context: context)
        }
//        .keylineTint(.cyan)
    }
}


struct ScriptLiveActivityRootView: View {
    @ObservedObject var data : ScriptLiveActivityDataObject
    
    let scriptName: String
    let scriptParameter: String
    
    init(scriptName: String, scriptParameter: String) {
        self.scriptName = scriptName
        self.scriptParameter = scriptParameter
        self.data = ScriptLiveActivityDataObject(scriptName: scriptName, scriptParameter: scriptParameter)
        self.data.runScriptSync()
    }
    
    var body: some View {
        ScriptWidgetElementView(
            element: data.rootElement,
            context: ScriptWidgetElementContext(
                runtime: data.runtime,
                debugMode: false,
                scriptName: scriptName,
                scriptParameter: scriptParameter,
                package: data.package
            )
        )
    }
    
    
}


@available(iOSApplicationExtension 16.1, *)
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<ScriptLiveActivityAttributes>
    
    var body: some View {
        ScriptLiveActivityRootView(scriptName: context.attributes.scriptName, scriptParameter: context.attributes.scriptParameter)
//        .activitySystemActionForegroundColor(.indigo)
//        .activityBackgroundTint(.cyan)
    }
}
