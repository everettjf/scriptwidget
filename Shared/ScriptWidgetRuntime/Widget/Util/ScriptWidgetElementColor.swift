//
//  ScriptWidgetElementHelper.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/19.
//

import Foundation
import SwiftUI

extension Color {
    static var random: Color {
        return Color(
            red: .random(in: 0...1),
            green: .random(in: 0...1),
            blue: .random(in: 0...1)
        )
    }
}

struct ScriptWidgetAttributeColor {
    
    let color: Color?
    let gradient: AnyView?
    
    
    init() {
        self.color = nil
        self.gradient = nil
    }
    
    init(_ colorValue: String) {
        
        var color: Color? = nil
        var gradient: AnyView? = nil
        
        // gradient
        if colorValue.hasPrefix("gradient:") {
            gradient = (ScriptWidgetElementGradient.getGradient(colorValue) as! AnyView)
        } else {
            color = ScriptWidgetAttributeColor.getColorFromColorValue(colorValue)
        }
        
        self.color = color
        self.gradient = gradient
    }
    
    static func getThemeDynamicColor(light: Color, dark: Color) -> Color {
        if ScriptWidgetRuntimeDevice.isdarkmode() {
            return dark
        } else {
            return light
        }
    }
    
    static func getColorFromColorValue(_ colorValue: String) -> Color? {
        var color: Color? = nil

        // color string
        let parts = colorValue.split(separator: ",")
        if parts.count == 1 {
            // #ff0000
            // red
            if colorValue.hasPrefix("#") {
                color = Color(hex: colorValue)
            } else {
                color = ScriptWidgetAttributeColor.getBuiltinColorFromName(colorValue)
            }
        } else if (parts.count == 2) {
            // #ff00ff,0.5
            // red,0.5
            let colorPart = String(parts[0])
            let opacityPart = String(parts[1])
            
            var tmpColor: Color?
            if colorPart.hasPrefix("#") {
                tmpColor = Color(hex: colorPart)
            } else {
                tmpColor = ScriptWidgetAttributeColor.getBuiltinColorFromName(colorPart)
            }
            
            if let opacity = Double(opacityPart) {
                color = tmpColor?.opacity(opacity)
            } else {
                color = tmpColor
            }
        }
        return color
    }
    
    static func getBuiltinColorFromName(_ name: String) -> Color? {
        var color: Color?
        switch name {
        case "clear": color = .clear
        case "black": color = .black
        case "white": color = .white
        case "gray": color = .gray
        case "red": color = .red
        case "green": color = .green
        case "blue": color = .blue
        case "orange": color = .orange
        case "yellow": color = .yellow
        case "pink": color = .pink
        case "purple": color = .purple
        case "primary": color = .primary
        case "secondary": color = .secondary
        default: color = nil
        }
        return color
    }
}

extension Color {
    
    
    /*
     
     #ffffff
     #ffffffff
     
     RGB: RRGGBB
     ARGB: AARRGGBB
     */
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 1)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
