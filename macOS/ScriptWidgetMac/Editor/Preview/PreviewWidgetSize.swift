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

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var runtimeValue: String { title.lowercased() }

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

@MainActor
@Observable
final class StudioWidgetConfiguration {
    var family: StudioPreviewFamily = .small
    var canvasMode: StudioPreviewCanvasMode = .single
    var parameter = ""
    var debugMode = false
}

class PreviewWidgetSize {
    static let small: CGSize = .init(width: 169, height: 169)
    static let medium: CGSize = .init(width: 360, height: 169)
    static let large: CGSize = .init(width: 360, height: 376)
    
    static func size(_ size: Int) -> CGSize {
        StudioPreviewFamily(rawValue: size)?.size ?? small
    }
}
