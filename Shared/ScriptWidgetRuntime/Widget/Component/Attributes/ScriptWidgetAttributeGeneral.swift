//
//  ScriptWidgetAttributeGeneral.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/21.
//

import Foundation
import SwiftUI

struct ScriptWidgetAttributeGeneralModifier: ViewModifier {
    
    let element: ScriptWidgetRuntimeElement
    let context: ScriptWidgetElementContext

    init(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) {
        self.element = element
        self.context = context
    }
    
    func body(content: Content) -> some View {
        content
            // Padding is part of a component's painted content. Applying it
            // after the background grows the view outside its fill and leaves
            // a light halo around otherwise full-bleed widget cards.
            .modifier(ScriptWidgetAttributePaddingModifier(element))
            .modifier(ScriptWidgetAttributeFrameModifier(element))
            .modifier(ScriptWidgetAttributeBackgroundModifier(element))
            .modifier(ScriptWidgetAttributeCornerRadiusModifier(element))
            .modifier(ScriptWidgetAttributeClippedModifier(element))
            .modifier(ScriptWidgetAttributeOpacityModifier(element))
            .modifier(ScriptWidgetAttributeRotationEffectModifier(element))
            .modifier(ScriptWidgetAttributeRotation3DEffectModifier(element))
            .modifier(ScriptWidgetAttributeShadowModifier(element))
            .modifier(ScriptWidgetAttributeDebugModeModifier(Color.random, context))
    }
    
}
