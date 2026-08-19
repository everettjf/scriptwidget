//
//  ScriptWidgetAttributeBackgroundModifier.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/18.
//

import Foundation
import SwiftUI


struct ScriptWidgetAttributeBackgroundModifier: ViewModifier {
    
    let color: ScriptWidgetAttributeColor
    let usesContainerBackground: Bool
    
    init(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) {
        usesContainerBackground = context.usesContainerBackground(for: element)
        if let backgroundValue = element.getPropString("background")  {
            color = ScriptWidgetAttributeColor(backgroundValue)
        } else {
            color = ScriptWidgetAttributeColor()
        }
    }
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if usesContainerBackground {
            content
        } else if let backgroundColor = self.color.color {
            content.background(backgroundColor)
        } else if let gradient = self.color.gradient {
            content.background(gradient)
        } else {
            content
        }
    }
    
}

struct ScriptWidgetContainerBackgroundModifier: ViewModifier {
    let background: ScriptWidgetAttributeColor

    init(_ element: ScriptWidgetRuntimeElement) {
        if let backgroundValue = element.getPropString("background") {
            background = ScriptWidgetAttributeColor(backgroundValue)
        } else {
            background = ScriptWidgetAttributeColor()
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            if let backgroundColor = background.color {
                content.containerBackground(for: .widget) {
                    backgroundColor
                }
            } else if let gradient = background.gradient {
                content.containerBackground(for: .widget) {
                    gradient
                }
            } else {
                content.containerBackground(.background, for: .widget)
            }
        } else if let backgroundColor = background.color {
            content.background(backgroundColor)
        } else if let gradient = background.gradient {
            content.background(gradient)
        } else {
            content
        }
    }
}
