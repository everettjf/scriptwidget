//
//  ScriptWidgetControlAppIntent.swift
//  ScriptWidget
//
//  Created by eevv on 11/5/24.
//
import SwiftUI
import WidgetKit
import AppIntents


struct ScriptWidgetControlAppIntent: AppIntent {
  static var title: LocalizedStringResource = "ScriptWidget control app intent"
  static var description = IntentDescription("ScriptWidget control app intent description")
  static var isDiscoverable: Bool { false }
  #if compiler(>=6.4)
  @available(iOS 27.0, *)
  static var allowedExecutionTargets: ExecutionTargets { .widgetKitExtension }
  #endif

  init() {
  }

  func perform() async throws -> some IntentResult {
    print("ScriptWidget control app intent performed")
    return .result()
  }
}
