//
//  ScriptMetadata.swift
//  ScriptWidget
//
//  Template metadata loaded from meta.json inside a script package.
//

import Foundation
import SwiftUI

struct ScriptMetadata: Codable, Equatable {
    var description: String?
    var category: String?
    var tags: [String]?
    var difficulty: String?
    var icon: String?
    var preview: String?
    var featured: Bool?

    static let empty = ScriptMetadata()
}

enum ScriptCategory: String, CaseIterable, Identifiable {
    case starter
    case time
    case weather
    case system
    case health
    case finance
    case productivity
    case fun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .starter:      return "Starter"
        case .time:         return "Time & Date"
        case .weather:      return "Weather"
        case .system:       return "System"
        case .health:       return "Health"
        case .finance:      return "Finance"
        case .productivity: return "Productivity"
        case .fun:          return "Fun"
        }
    }

    var systemImage: String {
        switch self {
        case .starter:      return "square.dashed"
        case .time:         return "clock.fill"
        case .weather:      return "cloud.sun.fill"
        case .system:       return "cpu.fill"
        case .health:       return "heart.fill"
        case .finance:      return "chart.line.uptrend.xyaxis"
        case .productivity: return "checkmark.circle.fill"
        case .fun:          return "gamecontroller.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .starter:      return .gray
        case .time:         return .blue
        case .weather:      return .cyan
        case .system:       return .indigo
        case .health:       return .pink
        case .finance:      return .green
        case .productivity: return .orange
        case .fun:          return .purple
        }
    }
}

enum ScriptDifficulty: String, CaseIterable {
    case beginner
    case medium
    case advanced

    var displayName: String {
        switch self {
        case .beginner: return "Beginner"
        case .medium:   return "Intermediate"
        case .advanced: return "Advanced"
        }
    }
}
