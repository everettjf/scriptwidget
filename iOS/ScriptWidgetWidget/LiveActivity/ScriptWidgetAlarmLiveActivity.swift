import SwiftUI
import WidgetKit
import AlarmKit

/// AlarmKit countdown UI uses native dates; it never evaluates widget scripts
/// or queries external data while rendering a Live Activity.
@available(iOSApplicationExtension 26.0, *)
struct ScriptWidgetAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ScriptWidgetAlarmMetadata>.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label("ScriptWidget Timer", systemImage: "timer").font(.caption).foregroundStyle(.secondary)
                Text(context.attributes.presentation.alert.title).font(.headline)
                time(context.state.mode).font(.largeTitle.monospacedDigit())
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "timer").foregroundStyle(.teal) }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.presentation.alert.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { time(context.state.mode).font(.title.monospacedDigit()) }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.teal)
            } compactTrailing: {
                time(context.state.mode).monospacedDigit().frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
    @ViewBuilder
    private func time(_ mode: AlarmPresentationState.Mode) -> some View {
        switch mode {
        case .countdown(let value): Text(timerInterval: value.startDate...max(value.startDate, value.fireDate), countsDown: true)
        case .paused: Text("Paused")
        case .alert: Text("Time’s up")
        @unknown default: Text("Timer")
        }
    }
}
