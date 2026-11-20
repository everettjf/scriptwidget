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

/// `<list>`: on Android a vertical stack that scrolls inside the widget. A
/// widget cannot scroll here, so the rows are drawn from the top at their own
/// heights, with the list's `spacing` between them, and a row that does not
/// fit completely is not drawn. The list takes the room it is offered, as on
/// Android, and reads the same attributes: `spacing` and the general ones.
struct ScriptWidgetElementTagList {
    /// As many rows as Android lays out.
    static let maximumRows = 100

    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let rows = Array(element.childrenAsElements().prefix(maximumRows))
        let spacing = element.getPropDouble("spacing").flatMap { $0.isFinite ? CGFloat(max(0, $0)) : nil } ?? 0
        return AnyView(
            ScriptWidgetFittingRows(spacing: spacing) {
                ForEach(rows) { item -> AnyView in
                    return ScriptWidgetElementView.buildView(element: item, context: context)
                }
            }
            .clipped()
            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

/// Stacks rows from the top, leading-aligned, each at its natural height.
struct ScriptWidgetFittingRows: Layout {
    let spacing: CGFloat

    /// Where a row that does not fit is put: out of sight, so that it is
    /// neither drawn nor tappable over the views below the list.
    static let hiddenOffset: CGFloat = 100_000

    private static func offered(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = Self.offered(proposal.width), height = Self.offered(proposal.height)
        if let width, let height { return CGSize(width: width, height: height) }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        return CGSize(
            width: width ?? sizes.reduce(0) { max($0, $1.width) },
            height: height ?? sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, sizes.count - 1))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        var cursor: CGFloat = 0
        var fits = true
        for (index, row) in subviews.enumerated() {
            if index > 0 { cursor += spacing }
            let height = row.sizeThatFits(rowProposal).height
            // The first row is always drawn; the clip cuts it off if it is taller than the list.
            if index > 0, cursor + height > bounds.height + 0.01 { fits = false }
            row.place(at: CGPoint(x: bounds.minX, y: bounds.minY + cursor + (fits ? 0 : Self.hiddenOffset)), anchor: .topLeading, proposal: rowProposal)
            cursor += height
        }
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
