//
//  ScriptWidgetElementTagExtras.swift
//  ScriptWidget
//
//  Created by ScriptWidget contributors.
//

import Foundation
import SwiftUI

fileprivate func textFromElement(_ element: ScriptWidgetRuntimeElement) -> String {
    var text = ""
    if let children = element.children {
        for child in children {
            if let value = child as? String {
                text.append(value)
            } else if let value = child as? NSNumber {
                text.append("\(value)")
            } else {
                text.append("#ErrorChildType#")
            }
        }
    }
    return text
}

class ScriptWidgetElementTagDivider {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let thickness = CGFloat(element.getPropDouble("thickness") ?? 1)
        let axis = element.getPropString("axis") ?? "horizontal"
        let colorValue = element.getPropString("color") ?? "secondary"
        let color = ScriptWidgetAttributeColor(colorValue).color ?? Color.secondary

        if axis == "vertical" {
            return AnyView(
                Rectangle()
                    .fill(color)
                    .frame(width: thickness)
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            )
        }

        return AnyView(
            Rectangle()
                .fill(color)
                .frame(height: thickness)
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagLine {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let thickness = CGFloat(element.getPropDouble("thickness") ?? 2)
        let length = CGFloat(element.getPropDouble("length") ?? 48)
        let axis = element.getPropString("axis") ?? "horizontal"
        let colorValue = element.getPropString("color") ?? "secondary"
        let color = ScriptWidgetAttributeColor(colorValue).color ?? Color.secondary

        if axis == "vertical" {
            return AnyView(
                Rectangle()
                    .fill(color)
                    .frame(width: thickness, height: length)
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            )
        }

        return AnyView(
            Rectangle()
                .fill(color)
                .frame(width: length, height: thickness)
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagRoundedRect {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let radius = CGFloat(element.getPropDouble("radius") ?? 12)
        let colorValue = element.getPropString("color") ?? "#e2e8f0"
        let color = ScriptWidgetAttributeColor(colorValue).color ?? Color.gray

        return AnyView(
            RoundedRectangle(cornerRadius: radius)
                .fill(color)
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagIcon {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let systemName = element.getPropString("systemName") ?? "questionmark.circle"
        let size = element.getPropDouble("size")

        let base = Image(systemName: systemName)
        let iconView: AnyView
        if let size = size {
            iconView = AnyView(base.font(.system(size: CGFloat(size))))
        } else {
            iconView = AnyView(base)
        }

        return AnyView(
            iconView
                .modifier(ScriptWidgetAttributeForegroundModifier(element))
                .modifier(ScriptWidgetAttributeFontModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagLabel {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let title = element.getPropString("title") ?? textFromElement(element)
        let systemName = element.getPropString("systemName") ?? "circle.fill"

        return AnyView(
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemName)
            }
            .modifier(ScriptWidgetAttributeForegroundModifier(element))
            .modifier(ScriptWidgetAttributeFontModifier(element))
            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagProgress {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let value = max(element.getPropDouble("value") ?? 0, 0)
        let total = max(element.getPropDouble("total") ?? 1, 0.000_001)
        let progress = min(value / total, 1)
        let label = element.getPropString("label") ?? ""
        let style = element.getPropString("style") ?? "linear"
        let tintColor = ScriptWidgetAttributeColor(element.getPropString("color") ?? "#3b82f6").color ?? .blue
        let trackColor = element.getPropString("trackColor")
            .flatMap { ScriptWidgetAttributeColor($0).color }
            ?? Color.white.opacity(0.15)
        let thickness = CGFloat(element.getPropDouble("thickness") ?? 6)

        if style == "circular" {
            let size = CGFloat(element.getPropDouble("frame") ?? 32)
            let ring = ZStack {
                Circle().stroke(trackColor, lineWidth: thickness)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tintColor, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if !label.isEmpty {
                    Text(label).font(.caption2)
                }
            }
            .frame(width: size, height: size)
            return AnyView(ring.modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
        } else {
            let bar = VStack(alignment: .leading, spacing: label.isEmpty ? 0 : 4) {
                if !label.isEmpty {
                    Text(label).font(.caption2)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(trackColor)
                        Capsule()
                            .fill(tintColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: thickness)
            }
            return AnyView(bar.modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
        }
    }
}

class ScriptWidgetElementTagRing {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let value = min(max(element.getPropDouble("value") ?? 0, 0), 1)
        let thickness = CGFloat(element.getPropDouble("thickness") ?? 8)
        let colorValue = element.getPropString("color") ?? "#3b82f6"
        let trackValue = element.getPropString("trackColor") ?? "#e2e8f0"
        let color = ScriptWidgetAttributeColor(colorValue).color ?? Color.blue
        let trackColor = ScriptWidgetAttributeColor(trackValue).color ?? Color.gray.opacity(0.2)

        let ringView = ZStack {
            Circle()
                .stroke(trackColor, lineWidth: thickness)
            Circle()
                .trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }

        return AnyView(
            ringView
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagBadge {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let text = element.getPropString("text") ?? textFromElement(element)
        let radius = CGFloat(element.getPropDouble("radius") ?? 6)
        let hasBackground = element.getPropString("background") != nil
        let defaultBackground = ScriptWidgetAttributeColor("#0f172a").color ?? Color.black
        let defaultColor = ScriptWidgetAttributeColor("#e2e8f0").color ?? Color.white
        let colorValue = element.getPropString("color")
        let color = colorValue != nil ? ScriptWidgetAttributeColor(colorValue!).color : defaultColor

        let base = Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(color)
        let content: AnyView
        if hasBackground {
            content = AnyView(base)
        } else {
            content = AnyView(base.background(defaultBackground))
        }

        return AnyView(
            content
                .cornerRadius(radius)
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagChip {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let text = element.getPropString("text") ?? textFromElement(element)
        let radius = CGFloat(element.getPropDouble("radius") ?? 14)
        let hasBackground = element.getPropString("background") != nil
        let defaultBackground = ScriptWidgetAttributeColor("#f1f5f9").color ?? Color.gray.opacity(0.2)
        let defaultColor = ScriptWidgetAttributeColor("#0f172a").color ?? Color.black
        let borderValue = element.getPropString("borderColor") ?? "#cbd5f5"
        let borderColor = ScriptWidgetAttributeColor(borderValue).color ?? Color.gray
        let colorValue = element.getPropString("color")
        let color = colorValue != nil ? ScriptWidgetAttributeColor(colorValue!).color : defaultColor

        let base = Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(color)
        let content: AnyView
        if hasBackground {
            content = AnyView(base)
        } else {
            content = AnyView(base.background(defaultBackground))
        }

        return AnyView(
            content
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(borderColor, lineWidth: 1))
                .cornerRadius(radius)
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}

class ScriptWidgetElementTagStat {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let title = element.getPropString("title") ?? "Title"
        let value = element.getPropString("value") ?? "0"
        let subtitle = element.getPropString("subtitle") ?? ""
        let valueColor = ScriptWidgetAttributeColor(element.getPropString("color") ?? "#0f172a").color ?? Color.black
        let mutedColor = ScriptWidgetAttributeColor(element.getPropString("mutedColor") ?? "#64748b").color ?? Color.gray

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(mutedColor)
                Text(value)
                    .font(.title3)
                    .foregroundColor(valueColor)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(mutedColor)
                }
            }
            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}
