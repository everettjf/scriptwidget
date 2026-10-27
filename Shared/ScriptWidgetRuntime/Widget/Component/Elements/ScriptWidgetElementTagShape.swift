//
//  ScriptWidgetElementTagShape.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/3/16.
//

import SwiftUI

struct AnyShape: Shape, @unchecked Sendable {
    init<S: Shape>(_ wrapped: S) {
        _path = { rect in
            wrapped.path(in: rect)
        }
    }
    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
    private let _path: (CGRect) -> Path
}

extension Shape {
    func applyShapeTrim(_ element: ScriptWidgetRuntimeElement) -> some Shape {
        var from: CGFloat?
        var to: CGFloat = 1.0
        
        if let trimValue = element.getPropDouble("trim") {
            from = CGFloat(trimValue)
        } else if let trimValue = element.getPropString("trim") {
            let parts = trimValue.components(separatedBy: ",")
            if parts.count == 1 {
                if let dvalue = Double(trimValue) {
                    if dvalue <= 1.0 && dvalue >= 0.0 {
                        from = CGFloat(dvalue)
                    }
                }
            } else if parts.count == 2 {
                if let one = Double(parts[0]), let two = Double(parts[1]) {
                    from = CGFloat(one)
                    to = CGFloat(two)
                }
            } else {
                // nothing
            }
        }
        
        
        
        if let from = from {
            return AnyShape(self.trim(from: from, to: to))
        }
        return AnyShape(self)
    }
    
    func applyShapeStroke(_ element: ScriptWidgetRuntimeElement) -> some Shape {
        var strokeLineWidth: CGFloat?
        if let strokeValue = element.getPropString("stroke") {
            if let value = Double(strokeValue) {
                strokeLineWidth = CGFloat(value)
            }
        }
        if let stoke = strokeLineWidth {
            return AnyShape(self.stroke(lineWidth: stoke))
        }
        return AnyShape(self)
    }
    
    func applyShapeAttribute(_ element: ScriptWidgetRuntimeElement) -> some Shape {
        return self
            .applyShapeTrim(element)
            .applyShapeStroke(element)
    }
}


class ScriptWidgetElementTagRectangle {
    struct CompactStyle {
        let width: CGFloat
        let height: CGFloat
        let color: Color
        let corner: CGFloat?
        let clippingCorner: CGFloat?

        @ViewBuilder private var framedShape: some View {
            if let corner {
                RoundedRectangle(cornerRadius: corner).foregroundColor(color)
                    .frame(width: width, height: height)
            } else {
                Rectangle().foregroundColor(color).frame(width: width, height: height)
            }
        }
        @ViewBuilder var view: some View {
            // Preserve the existing shape + outer corner clip, including the
            // distinction between string and numeric corner properties.
            if let clippingCorner { framedShape.cornerRadius(clippingCorner).widgetAccentable(false) }
            else { framedShape.widgetAccentable(false) }
        }
    }

    static func compactStyle(_ element: ScriptWidgetRuntimeElement, debugMode: Bool) -> CompactStyle? {
        // Dense heatmaps otherwise build the full conditional modifier chain
        // for every cell, exhausting WidgetKit's 30 MB process limit.
        let allowed: Set<AnyHashable> = ["frame", "color", "corner"]
        guard !debugMode, Set(element.getProps().keys).isSubset(of: allowed),
              let value = element.getPropString("color"),
              let color = ScriptWidgetAttributeColor(value).color else { return nil }
        let frame = ScriptWidgetAttributeFrameModifier(element)
        guard frame.frameMode == .width_height_alignment,
              frame.width.isFinite, frame.height.isFinite, frame.width >= 0, frame.height >= 0 else { return nil }
        let corner = element.getPropString("corner").flatMap { Double($0) }.map { CGFloat($0) }
        if let corner, !corner.isFinite || corner < 0 { return nil }
        let clippingCorner = element.getPropDouble("corner").map { CGFloat($0) }
        if let clippingCorner, !clippingCorner.isFinite || clippingCorner < 0 { return nil }
        return .init(width: frame.width, height: frame.height, color: color, corner: corner, clippingCorner: clippingCorner)
    }

    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        if let style = compactStyle(element, debugMode: context.debugMode) { return AnyView(style.view) }
        return buildGeneralView(element, context)
    }

    static func buildGeneralView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
        var cornerRadius: CGFloat?
        if let cornerValue = element.getPropString("corner") {
            if let cornerDouble = Double(cornerValue) {
                cornerRadius = CGFloat(cornerDouble)
            }
        }
        
        if let cornerRadius = cornerRadius {
            return AnyView(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .applyShapeAttribute(element)
                    .modifier(ScriptWidgetAttributeForegroundModifier(element))
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            )
        } else {
            return AnyView(
                Rectangle()
                    .applyShapeAttribute(element)
                    .modifier(ScriptWidgetAttributeForegroundModifier(element))
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            )
        }
        
    }
}


class ScriptWidgetElementTagCapsule {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
        return AnyView(
            Capsule()
                .applyShapeAttribute(element)
                .modifier(ScriptWidgetAttributeForegroundModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}



class ScriptWidgetElementTagEllipse {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
        return AnyView(
            Ellipse()
                .applyShapeAttribute(element)
                .modifier(ScriptWidgetAttributeForegroundModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}


class ScriptWidgetElementTagCircle {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
        return AnyView(
            Circle()
                .applyShapeAttribute(element)
                .modifier(ScriptWidgetAttributeForegroundModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}


struct ScriptWidgetElementTagShape: View {
    var body: some View {
        VStack {
            Rectangle()
                .gradientForegroundColors(colors: [Color.red,Color.green])
                .frame(width: 100, height:100)
            Rectangle()
                .trim(from: 0.2, to: 1.0)
                .stroke(lineWidth: 5)
                .frame(width: 100, height:100)
            
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .gradientForegroundColors(colors: [Color.red,Color.green])
                .frame(width: 100, height: 100)
            
            Capsule()
                .trim(from: 0.2, to: 1.0)
                .stroke(lineWidth: 5)
                .gradientForegroundColors(colors: [Color.red,Color.green])
                .frame(width: 100, height: 50)
            
            Ellipse()
                .trim(from: 0.1, to: 1)
                .stroke(lineWidth: 5)
                .fill(Color.blue)
                .frame(width: 100, height: 50)
            
            Circle()
                .trim(from: 0.2, to: 1.0)
                .stroke(lineWidth: 5)
                .fill(Color.orange)
                .frame(width: 100, height: 50)
                .rotationEffect(Angle(degrees: 90))
                .rotation3DEffect(Angle(degrees: 180), axis: (x: 1, y: 0, z: 0))
                .shadow(color: Color(#colorLiteral(red: 0.5568627715, green: 0.3529411852, blue: 0.9686274529, alpha: 1)).opacity(0.3), radius: 3, x: 0, y: 3)
            
            Circle()
                .fill(Color.orange)
                .frame(width: 100, height: 50)
        }
    }
}

struct ScriptWidgetElementTagShape_Previews: PreviewProvider {
    static var previews: some View {
        ScriptWidgetElementTagShape()
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
