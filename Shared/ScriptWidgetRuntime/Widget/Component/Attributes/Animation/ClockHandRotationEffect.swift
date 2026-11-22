// Clock-hand rotation for widget elements.
// Inside the widget extension it uses WidgetKit's own clock-hand effect, the only way a
// Home Screen widget keeps moving: WidgetKit does not run TimelineView there. The effect
// is looked up by name, so when a system release removes it the public SwiftUI path below
// is used instead. The app, tests and fixed-date previews always use the public path.
// iOS and macOS WidgetKit both have the effect, in the same format.
// Bridge attribution: giljihun, ClockHandKit, MIT license (ClockHandKit-LICENSE.txt).
import Foundation
import OSLog
import SwiftUI

enum ClockHandPeriod {
    case hourHand, minuteHand, secondHand
    case custom(Double)
    var type: String {
        switch self {
        case .hourHand: "clockHour"
        case .minuteHand: "clockMinute"
        case .secondHand: "clockSecond"
        case .custom: "clock"
        }
    }
    var interval: Double { if case let .custom(value) = self { return value }; return 10 }
}

/// WidgetKit's clock-hand effect, which the system animates on the Home Screen.
enum WidgetKitClockHand {
    private static let log = Logger(subsystem: "com.everettjf.scriptwidget", category: "clock-hand")
    /// True in the widget extension, where WidgetKit draws the elements.
    static let isWidgetExtension = Bundle.main.bundleURL.pathExtension == "appex"
    private static let effectType: (any Decodable.Type)? = {
        guard isWidgetExtension else { return nil }
        guard let type = _typeByName("9WidgetKit24_ClockHandRotationEffectV") as? any Decodable.Type else {
            log.error("WidgetKit clock-hand effect is unavailable")
            return nil
        }
        log.info("WidgetKit clock-hand effect found")
        return type
    }()
    /// Whether the effect can be used here: in the widget extension, when this system has it.
    static var isAvailable: Bool { effectType != nil }

    /// The ways systems have written the effect, newest first. iOS 26 and later decode the
    /// period as the seconds of one full turn and the anchor as `[x, y]`; earlier systems
    /// used a `{"custom": {"_0": n}}` style period and an `{"x", "y"}` anchor. A custom
    /// interval `n` has always been half a turn. The first form that decodes is remembered.
    private static let forms: [(ClockHandPeriod, UnitPoint) -> (Any, Any)] = [
        { period, anchor in (fullTurnSeconds(period), [Double(anchor.x), Double(anchor.y)]) },
        { period, anchor in (enumPeriod(period), [Double(anchor.x), Double(anchor.y)]) },
        { period, anchor in (enumPeriod(period), ["x": Double(anchor.x), "y": Double(anchor.y)]) },
    ]
    nonisolated(unsafe) private static var workingForm: Int? = nil
    nonisolated(unsafe) private static var loggedFailure = false

    private static func fullTurnSeconds(_ period: ClockHandPeriod) -> Double {
        switch period {
        case .hourHand: 43_200
        case .minuteHand: 3_600
        case .secondHand: 60
        case .custom(let seconds): 2 * seconds
        }
    }
    private static func enumPeriod(_ period: ClockHandPeriod) -> [String: Any] {
        switch period {
        case .hourHand: ["hourHand": [String: Any]()]
        case .minuteHand: ["minuteHand": [String: Any]()]
        case .secondHand: ["secondHand": [String: Any]()]
        case .custom(let seconds): ["custom": ["_0": seconds]]
        }
    }

    /// The view with WidgetKit's effect, or nil when it cannot be built.
    static func apply<V: View>(_ view: V, period: ClockHandPeriod, timeZone: TimeZone, anchor: UnitPoint) -> AnyView? {
        guard let effectType else { return nil }
        var lastError: Error? = nil
        for form in workingForm.map({ [$0] }) ?? Array(forms.indices) {
            let (periodJSON, anchorJSON) = forms[form](period, anchor)
            let payload: [String: Any] = [
                "period": periodJSON,
                "timeZone": ["identifier": timeZone.identifier],
                "anchor": anchorJSON,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try JSONDecoder().decode(effectType, from: data)
                guard let modifier = decoded as? any ViewModifier else {
                    log.error("WidgetKit clock-hand effect is not a ViewModifier")
                    return nil
                }
                workingForm = form
                return AnyView(modified(view, modifier))
            } catch {
                lastError = error
            }
        }
        if !loggedFailure, let lastError {
            loggedFailure = true
            log.error("WidgetKit clock-hand effect could not be built: \(String(describing: lastError), privacy: .public)")
        }
        return nil
    }
    private static func modified<V: View, M: ViewModifier>(_ view: V, _ modifier: M) -> some View {
        view.modifier(modifier)
    }
}

/// Uses WidgetKit's effect when it is live in the widget extension, otherwise public SwiftUI.
private struct ClockHandRotation<Content: View>: View {
    let content: Content
    let period: ClockHandPeriod
    let timeZone: TimeZone
    let anchor: UnitPoint
    let referenceDate: Date?
    @Environment(\.scriptWidgetAnimationPreview) private var preview
    var body: some View {
        if preview.date == nil, preview.elapsed == nil,
           let system = WidgetKitClockHand.apply(content, period: period, timeZone: timeZone, anchor: anchor) {
            system
        } else {
            ScriptWidgetAnimationFrame(referenceDate: referenceDate) { date, _ in
                content.rotationEffect(.degrees(ScriptWidgetAnimationPhase.clockAngle(type: period.type, interval: period.interval, date: date, timeZone: timeZone)), anchor: anchor)
            }
        }
    }
}

extension View {
    func clockHandRotationEffect(period: ClockHandPeriod, in timeZone: TimeZone = .current, anchor: UnitPoint = .center, referenceDate: Date? = nil) -> some View {
        ClockHandRotation(content: self, period: period, timeZone: timeZone, anchor: anchor, referenceDate: referenceDate)
    }
}
