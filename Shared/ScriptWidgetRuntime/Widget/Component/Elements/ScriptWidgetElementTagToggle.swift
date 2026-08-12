//
//  ScriptWidgetElementTagToggle.swift
//  ScriptWidget
//
//  Created by zhufeng on 2023/10/8.
//

import Foundation
import SwiftUI
import SwiftyJSON

class ScriptWidgetElementTagToggle {
    
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        return AnyView(Self.buildToggle(
            element: element,
            context: context
        ))
    }
    
    @ViewBuilder private static func buildToggle(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            if let actionID = element.getPropString("actionID"),
               let stateKey = element.getPropString("stateKey"),
               let resolved = ScriptWidgetActionCatalog(packages: [context.package]).resolve(package: context.package, actionID: actionID) {
                Toggle(
                    isOn: self.getToggleValue(element),
                    intent: SetScriptWidgetActionValueIntent(actionID: resolved.identifier, stateKey: stateKey)
                ) {
                    toggleLabel(element: element, context: context)
                }
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            } else if element.getPropString("actionID") != nil || element.getPropString("stateKey") != nil {
                Toggle(isOn: .constant(self.getToggleValue(element))) {
                    toggleLabel(element: element, context: context)
                }
                .disabled(true)
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            } else {
                Toggle(isOn: self.getToggleValue(element), intent: ButtonActionAppIntent(functionName: Self.getToggleActionFunctionName(element), package: context.package)) {
                    toggleLabel(element: element, context: context)
                }
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            }
        } else {
            Toggle(isOn: .constant(self.getToggleValue(element))) {
                toggleLabel(element: element, context: context)
            }
            .disabled(true)
            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        }
    }

    @ViewBuilder private static func toggleLabel(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        ForEach(element.childrenAsElements()) { item -> AnyView in
            ScriptWidgetElementView.buildView(element: item, context: context)
        }
    }
    
    static func getToggleActionFunctionName(_ element: ScriptWidgetRuntimeElement) -> String {
        guard let functionName = element.getPropString("onClick") else { return "" }
        return functionName
    }
    
    static func getToggleValue(_ element: ScriptWidgetRuntimeElement) -> Bool {
        return element.getPropBool("on") ?? false
    }
    
}
