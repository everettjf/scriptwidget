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
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
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
