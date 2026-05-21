//
//  ScriptModel.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/10.
//

import SwiftUI

struct ScriptModel : Identifiable {

    let id = UUID()
    let package: ScriptWidgetPackage
    let metadata: ScriptMetadata?

    init(package: ScriptWidgetPackage) {
        self.package = package
        self.metadata = package.readMetadata()
    }

    var name: String {
        get {
            self.package.name
        }
    }

    var exportFileName: String {
        get {
            "\(self.package.name).swt"
        }
    }

    var summary: String? {
        metadata?.description
    }

    var category: ScriptCategory? {
        guard let raw = metadata?.category else { return nil }
        return ScriptCategory(rawValue: raw)
    }

    var tags: [String] {
        metadata?.tags ?? []
    }

    var difficulty: ScriptDifficulty? {
        guard let raw = metadata?.difficulty else { return nil }
        return ScriptDifficulty(rawValue: raw)
    }

    var iconSystemName: String {
        metadata?.icon ?? category?.systemImage ?? "doc.text.fill"
    }

    var isFeatured: Bool {
        metadata?.featured ?? false
    }
}




let globalScriptModel = ScriptModel(package: ScriptWidgetPackage(bundle: "Script", relativePath: "template/Is Friday Today"))
let globalFileModel = FileModel(name: "config.json", relativePath: "config.json", path: URL(fileURLWithPath: "config.json"))
