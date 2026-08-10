//
//  PreviewWidgetSize.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/15.
//

import Foundation
import Observation

enum StudioPreviewFamily: Int, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge
    case extraLargePortrait

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        case .extraLargePortrait: return "Extra Large Portrait"
        }
    }

    var runtimeValue: String {
        switch self {
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        case .extraLarge: return "extraLarge"
        case .extraLargePortrait: return "extraLargePortrait"
        }
    }

    var size: CGSize { PreviewWidgetSize.size(rawValue) }
}

enum StudioPreviewCanvasMode: String, CaseIterable, Identifiable {
    case single
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Single"
        case .all: return "All Sizes"
        }
    }
}

enum StudioPreviewRenderingMode: String, CaseIterable, Identifiable {
    case fullColor
    case accented
    case vibrant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullColor: return "Full Color"
        case .accented: return "Accented"
        case .vibrant: return "Vibrant"
        }
    }

    var runtimeValue: String { rawValue }
}

@MainActor
@Observable
final class StudioWidgetConfiguration {
    var family: StudioPreviewFamily = .small
    var canvasMode: StudioPreviewCanvasMode = .single
    var renderingMode: StudioPreviewRenderingMode = .fullColor
    var parameter = ""
    var debugMode = false
}

class PreviewWidgetSize {
    static let small: CGSize = .init(width: 169, height: 169)
    static let medium: CGSize = .init(width: 360, height: 169)
    static let large: CGSize = .init(width: 360, height: 376)
    static let extraLarge: CGSize = .init(width: 720, height: 338)
    static let extraLargePortrait: CGSize = .init(width: 360, height: 668)
    
    static func size(_ size: Int) -> CGSize {
        StudioPreviewFamily(rawValue: size)?.size ?? small
    }
}
