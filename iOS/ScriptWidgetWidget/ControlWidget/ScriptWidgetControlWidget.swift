import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct ScriptWidgetButtonControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "ScriptWidget.Button",
            provider: ScriptWidgetButtonControlProvider()
        ) { value in
            ControlWidgetButton(action: RunScriptWidgetControlIntent(controlID: value.id)) {
                Label(value.title, systemImage: value.systemImage)
            }
        }
        .displayName("ScriptWidget Button")
        .description("Run an action declared by a ScriptWidget package.")
        .promptsForUserConfiguration()
    }
}

@available(iOSApplicationExtension 18.0, *)
struct ScriptWidgetControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "ScriptWidget.Toggle",
            provider: ScriptWidgetToggleControlProvider()
        ) { value in
            ControlWidgetToggle(
                value.title,
                isOn: value.isOn,
                action: SetScriptWidgetControlValueIntent(controlID: value.id)
            ) { isOn in
                Label(isOn ? "On" : "Off", systemImage: value.systemImage)
            }
        }
        .displayName("ScriptWidget Toggle")
        .description("Change state with an action declared by a ScriptWidget package.")
        .promptsForUserConfiguration()
    }
}
