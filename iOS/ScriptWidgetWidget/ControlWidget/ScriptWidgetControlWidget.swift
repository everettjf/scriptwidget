//
//  ScriptWidgetControlWidget.swift
//  ScriptWidgetWidget

import Foundation
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct ScriptWidgetControlWidget: ControlWidget {
  var body: some ControlWidgetConfiguration {
//    StaticControlConfiguration(kind: "ScriptWidget") {
//      ControlWidgetButton(action: ScriptWidgetControlAppIntent()) {
//        Label("Click Script Widget", systemImage: "gamecontroller")
//      }
//    }
      

      AppIntentControlConfiguration(
        kind: "ScriptWidget",
        provider: ConfigurableProvider()
      ) { timerState in
        ControlWidgetToggle(
          timerState.timer.name,
          isOn: timerState.isRunning,
          action: ToggleTimerIntent(timer: timerState.timer),
          valueLabel: { isOn in
            Label(isOn ? "Running" : "Stopped", systemImage: "timer")
          }
        )
      }
      .displayName("Productivity Timer")
      .description("Start and stop a productivity timer.")
      .promptsForUserConfiguration()
  }
}
