//
//  ScriptWidgetElementTagButton.swift
//  ScriptWidget
//
//  Created by zhufeng on 2023/10/7.
//
import Foundation
import SwiftUI
import SwiftyJSON

class ScriptWidgetElementTagButton {

    private enum ButtonAction {
        case reload
        case declared(String)
        case callFunction(String)
    }
    
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        return AnyView(Self.buildButton(
            element: element,
            context: context
        ))
    }
    
    @ViewBuilder private static func buildButton(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            if !context.canExecuteActions {
                Button(action: {}) { buttonLabel(element: element, context: context) }
                    .disabled(true)
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            } else {
                let action = getButtonAction(element)
                switch action {
                case .reload:
                    Button(intent: ReloadWidgetAppIntent()) {
                        buttonLabel(element: element, context: context)
                    }
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                case .declared(let actionID):
                    if let resolved = context.actionCatalog.resolve(package: context.package, actionID: actionID) {
                        Button(intent: RunScriptWidgetActionIntent(resolved: resolved)) {
                            buttonLabel(element: element, context: context)
                        }
                        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                    } else {
                        Button(action: {}) {
                            buttonLabel(element: element, context: context)
                        }
                        .disabled(true)
                        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                    }
                case .callFunction(let functionName):
                    Button(intent: ButtonActionAppIntent(functionName: functionName, package: context.package, scriptParameter: context.scriptParameter, executionSnapshot: context.executionSnapshot)) {
                        buttonLabel(element: element, context: context)
                    }
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                }
            }
        } else {
            Button(action: {}) {
                buttonLabel(element: element, context: context)
            }
            .disabled(true)
            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        }
    }

    @ViewBuilder private static func buttonLabel(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        ForEach(element.childrenAsElements()) { item -> AnyView in
            ScriptWidgetElementView.buildView(element: item, context: context)
        }
    }
    
    private static func getButtonAction(_ element: ScriptWidgetRuntimeElement) -> ButtonAction {
        if let action = element.getPropString("action")?.lowercased(), action == "reload" {
            return .reload
        }
        if let actionID = element.getPropString("actionID"), !actionID.isEmpty {
            return .declared(actionID)
        }
        let functionName = element.getPropString("onClick") ?? ""
        return .callFunction(functionName)
    }
    
}
