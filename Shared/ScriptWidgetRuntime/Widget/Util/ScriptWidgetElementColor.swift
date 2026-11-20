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
        default: color = ScriptWidgetMaterialPalette.color(named: name)
        }
        return color
    }
}

/// Android takes the `material.<role>` colors from the wallpaper. There is no
/// such palette here, so every role is a fixed color: the baseline Material 3
/// scheme, light and dark. A widget written for Android then keeps readable
/// colors. Windows, Linux and the browser preview draw the same table
/// (`fixedMaterialColors` in Web/preview-engine/src/render/props.js);
/// AndroidTagFallbackTests.testBrowserPreviewHasTheSamePalette compares the two.
enum ScriptWidgetMaterialPalette {
    static let prefix = "material."

    /// Role, light RGB, dark RGB. The roles are those of Android's ThemeColors, in its order.
    /// The values were compared one by one with androidx.compose.material3.tokens
    /// (ColorLightTokens, ColorDarkTokens and PaletteTokens, "VERSION: v0_210") at
    /// https://github.com/androidx/androidx/tree/e4f55394b8035b5eb550f17ec130243c7cb9f64d/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/tokens
    static let roles: [(name: String, light: UInt32, dark: UInt32)] = [
        ("primary", 0x6750A4, 0xD0BCFF), ("onPrimary", 0xFFFFFF, 0x381E72),
        ("primaryContainer", 0xEADDFF, 0x4F378B), ("onPrimaryContainer", 0x21005D, 0xEADDFF),
        ("secondary", 0x625B71, 0xCCC2DC), ("onSecondary", 0xFFFFFF, 0x332D41),
        ("secondaryContainer", 0xE8DEF8, 0x4A4458), ("onSecondaryContainer", 0x1D192B, 0xE8DEF8),
        ("tertiary", 0x7D5260, 0xEFB8C8), ("onTertiary", 0xFFFFFF, 0x492532),
        ("tertiaryContainer", 0xFFD8E4, 0x633B48), ("onTertiaryContainer", 0x31111D, 0xFFD8E4),
        ("background", 0xFEF7FF, 0x141218), ("onBackground", 0x1D1B20, 0xE6E0E9),
        ("surface", 0xFEF7FF, 0x141218), ("onSurface", 0x1D1B20, 0xE6E0E9),
        ("surfaceVariant", 0xE7E0EC, 0x49454F), ("onSurfaceVariant", 0x49454F, 0xCAC4D0),
        ("surfaceContainerLowest", 0xFFFFFF, 0x0F0D13), ("surfaceContainerLow", 0xF7F2FA, 0x1D1B20),
        ("surfaceContainer", 0xF3EDF7, 0x211F26), ("surfaceContainerHigh", 0xECE6F0, 0x2B2930),
        ("surfaceContainerHighest", 0xE6E0E9, 0x36343B),
        ("outline", 0x79747E, 0x938F99), ("outlineVariant", 0xCAC4D0, 0x49454F),
    ]

    private static let table: [String: (light: UInt32, dark: UInt32)] = Dictionary(uniqueKeysWithValues: roles.map { ($0.name, (light: $0.light, dark: $0.dark)) })

    /// The color of `material.<role>`, which follows light and dark mode; nil
    /// for a name without the prefix or a role that does not exist.
    static func color(named name: String) -> Color? {
        guard name.hasPrefix(prefix), let entry = table[String(name.dropFirst(prefix.count))] else { return nil }
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            platformColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? entry.dark : entry.light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            platformColor(traits.userInterfaceStyle == .dark ? entry.dark : entry.light)
        })
        #endif
    }

    #if os(macOS)
    private static func platformColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
    #else
    private static func platformColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
    #endif
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
