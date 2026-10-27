//
//  ScriptWidgetElementTagVStack.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/18.
//

import Foundation
import SwiftUI

class ScriptWidgetElementTagStack {
    ///--------------------------------------------------------------------------------------------------------

    static func buildViewVStack(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        if let column = ScriptWidgetRectangleColumn.make(element, context: context) { return AnyView(column) }
        return buildGeneralViewVStack(element, context)
    }

    static func buildGeneralViewVStack(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        return AnyView(Self.buildVStack(
            element: element,
            context: context
        ))
    }
    
    @ViewBuilder private static func buildVStack(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        VStack (alignment: Self.getHorizontalAlignment(element) , spacing: Self.getSpacing(element)) {
            ForEach(element.childrenAsElements()) { item -> AnyView in
                return ScriptWidgetElementView.buildView(element: item, context: context)
            }
        }
        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
    }
    ///--------------------------------------------------------------------------------------------------------

    static func buildViewHStack(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        return AnyView(Self.buildHStack(element: element, context: context))
    }
    
    @ViewBuilder private static func buildHStack(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        HStack (alignment: Self.getVerticalAlignment(element), spacing: Self.getSpacing(element)) {
            ForEach(element.childrenAsElements()) { item -> AnyView in
                return ScriptWidgetElementView.buildView(element: item, context: context)
            }
        }
        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
    }
    ///--------------------------------------------------------------------------------------------------------

    static func getVerticalAlignment(_ element: ScriptWidgetRuntimeElement) -> VerticalAlignment {
        guard let alignment = element.getPropString("alignment") else { return .center }
        
        switch alignment {
        case "top": return .top
        case "bottom": return .bottom
        case "center": return .center
        case "firstTextBaseline": return .firstTextBaseline
        case "lastTextBaseline": return .lastTextBaseline
        default: return .center
        }
    }
    
    static func getHorizontalAlignment(_ element: ScriptWidgetRuntimeElement) -> HorizontalAlignment {
        guard let alignment = element.getPropString("alignment") else { return .center }
        
        switch alignment {
        case "leading": return .leading
        case "trailing": return .trailing
        case "center": return .center
        default: return .center
        }
    }
    
    static func getSpacing(_ element: ScriptWidgetRuntimeElement) -> CGFloat? {
        guard let spacing = element.getPropDouble("spacing") else { return nil }
        return CGFloat(spacing)
    }
}

/// Flatten only noninteractive, fixed-size solid cells. Other stacks retain
/// their normal view hierarchy and all authored modifiers.
struct ScriptWidgetRectangleColumn: View {
    let cells: [ScriptWidgetElementTagRectangle.CompactStyle]
    let spacing: CGFloat
    var height: CGFloat { cells.reduce(0) { $0 + $1.height } + CGFloat(cells.count - 1) * spacing }

    static func make(_ element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> Self? {
        guard !context.debugMode, Set(element.getProps().keys).isSubset(of: [AnyHashable("spacing")]),
              let spacing = element.getPropDouble("spacing"), spacing.isFinite, spacing >= 0 else { return nil }
        let children = element.childrenAsElements()
        guard (2...16).contains(children.count), children.allSatisfy({ $0.tagAsString() == "rect" }) else { return nil }
        let cells = children.compactMap { ScriptWidgetElementTagRectangle.compactStyle($0, debugMode: false) }
        guard cells.count == children.count, let first = cells.first,
              first.width > 0, first.width <= 32, cells.allSatisfy({ $0.width == first.width && $0.height > 0 && $0.height <= 32 }) else { return nil }
        let result = Self(cells: cells, spacing: CGFloat(spacing))
        return result.height <= 1024 ? result : nil
    }

    var body: some View {
        Canvas { context, _ in
            var y: CGFloat = 0
            for cell in cells {
                let rect = CGRect(x: 0, y: y, width: cell.width, height: cell.height)
                var drawing = context
                if let corner = cell.clippingCorner {
                    drawing.clip(to: RoundedRectangle(cornerRadius: corner).path(in: rect))
                }
                let path = cell.corner.map { RoundedRectangle(cornerRadius: $0).path(in: rect) } ?? Path(rect)
                drawing.fill(path, with: .color(cell.color))
                y += cell.height + spacing
            }
        }
        .frame(width: cells[0].width, height: height)
        .widgetAccentable(false)
    }
}
