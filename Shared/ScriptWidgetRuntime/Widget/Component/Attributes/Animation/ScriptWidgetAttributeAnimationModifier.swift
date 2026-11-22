import Foundation
import CoreFoundation
import SwiftUI

/// Pure timing shared with the browser. Signed custom intervals retain the
/// legacy half-turn convention; all time arithmetic remains finite.
enum ScriptWidgetAnimationPhase {
    static func period(_ value: Double) -> Double {
        guard value.isFinite else { return 10 }
        return abs(value) < 0.25 ? (value < 0 ? -0.25 : 0.25) : value
    }
    static func swingDuration(_ value: Double) -> Double {
        value.isFinite && value > 0 ? min(86_400, max(0.1, value)) : 1
    }
    static func swingDistance(_ value: Double) -> Double {
        value.isFinite ? min(10_000, max(-10_000, value)) : 10
    }
    static func clockAngle(type: String, interval: Double = 10, date: Date, timeZone: TimeZone = .current) -> Double {
        guard date.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970) else { return 0 }
        if type == "clock" {
            // Divide before taking the remainder: doubling a very large valid
            // interval must not overflow. The epoch makes midnight continuous.
            return ((date.timeIntervalSinceReferenceDate + Double(timeZone.secondsFromGMT(for: date))) / period(interval)).truncatingRemainder(dividingBy: 2) * 180
        }
        let cycle: Double
        switch type {
        case "clockSecond": cycle = 60
        case "clockMinute", "clockMiniute": cycle = 3600
        case "clockHour": cycle = 43200
        default: return 0
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)) + Double(parts.nanosecond ?? 0) / 1_000_000_000
        return seconds.truncatingRemainder(dividingBy: cycle) / cycle * 360
    }
    static func swing(elapsed: Double, duration: Double, distance: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        return sin(elapsed.truncatingRemainder(dividingBy: 2 * swingDuration(duration)) / swingDuration(duration) * .pi) * swingDistance(distance)
    }
}

/// Native host/test controls, never exposed to scripts or package manifests.
struct ScriptWidgetAnimationPreview: Sendable {
    var date: Date? = nil
    var elapsed: Double? = nil
    var live: Bool? = nil
}
private struct ScriptWidgetAnimationPreviewKey: EnvironmentKey {
    static let defaultValue = ScriptWidgetAnimationPreview()
}
extension EnvironmentValues {
    var scriptWidgetAnimationPreview: ScriptWidgetAnimationPreview {
        get { self[ScriptWidgetAnimationPreviewKey.self] }
        set { self[ScriptWidgetAnimationPreviewKey.self] = newValue }
    }
}

/// Uses only public SwiftUI scheduling. The OS may freeze a widget at any
/// point; snapshots, inactive scenes and accessibility settings use rest state.
struct ScriptWidgetAnimationFrame<Content: View>: View {
    var referenceDate: Date? = nil
    @ViewBuilder let content: (Date, Double) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.scriptWidgetVisualAccessibility) private var accessibility
    @Environment(\.scriptWidgetAnimationPreview) private var preview
    @State private var start = Date()
    private var fixedDate: Date? { preview.date ?? referenceDate }
    private var live: Bool {
        fixedDate == nil && preview.elapsed == nil && !(accessibility.reduceMotion ?? reduceMotion) && !luminanceReduced &&
            (preview.live ?? (scenePhase == .active))
    }
    var body: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { frame in
                content(frame.date, max(0, frame.date.timeIntervalSince(start)))
            }
        } else {
            content(fixedDate ?? Date(), preview.elapsed.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        }
    }
}

struct ScriptWidgetAttributeAnimationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.scriptWidgetVisualAccessibility) private var preview
    let referenceDate: Date?
    let animationType: String
    let clockTimezone: TimeZone
    let clockAnchor: UnitPoint
    let clockCustomInterval: TimeInterval
    let swingDuration: CGFloat
    let swingDirection: SwingAnimationModifier.Direction
    let swingDistance: CGFloat

    private static func number(_ object: [String:Any], _ key: String) -> Double? {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
    init(_ element: ScriptWidgetRuntimeElement, referenceDate: Date? = nil) {
        self.referenceDate = referenceDate
        var type = "", zone = TimeZone.current, anchor = UnitPoint.center, interval = 10.0
        var duration = 1.0, distance = 10.0, direction = SwingAnimationModifier.Direction.horizontal
        if let value = element.getPropString("animation") {
            if value.hasPrefix("animation:") {
                do {
                    let decoded = try JSONSerialization.jsonObject(with:Data(value.dropFirst("animation:".count).utf8),options:.fragmentsAllowed)
                    let json = decoded as? [String:Any] ?? [:]
                    type = json["type"] as? String ?? ""
                    if ["clock","clockSecond","clockMinute","clockMiniute","clockHour"].contains(type) {
                        if let name = json["timezone"] as? String { zone = Self.getTimezone(timezone:name) }
                        if let name = json["anchor"] as? String { anchor = ScriptWidgetElementPoint.getPointFromPointValue(name) }
                        interval = ScriptWidgetAnimationPhase.period(Self.number(json,"interval") ?? 10)
                    } else if type == "swing" {
                        duration = ScriptWidgetAnimationPhase.swingDuration(Self.number(json,"duration") ?? 1)
                        distance = ScriptWidgetAnimationPhase.swingDistance(Self.number(json,"distance") ?? 10)
                        if let value = json["direction"] as? String { direction = value == "horizontal" ? .horizontal : .vertical }
                    }
                } catch { type = "error" }
            } else {
                let parts = value.split(separator:",")
                if parts.count == 1 { type = value }
                else if parts.count == 2, parts[0].trimmingCharacters(in:.whitespaces) == "clockCustom",
                        let number = Double(parts[1].trimmingCharacters(in:.whitespaces)), number.isFinite {
                    type = "clock"; interval = ScriptWidgetAnimationPhase.period(number)
                }
            }
        }
        animationType = type; clockTimezone = zone; clockAnchor = anchor; clockCustomInterval = interval
        swingDuration = CGFloat(duration); swingDirection = direction; swingDistance = CGFloat(distance)
    }
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if WidgetKitClockHand.isAvailable {
            // The Mac widget extension moves with WidgetKit's clock-hand effect, like iOS.
            moving(content)
        } else if ["clockSecond","clockMinute","clockMiniute","clockHour"].contains(animationType) {
            // The Mac app's previews show standard clock hands at the current time.
            content.rotationEffect(.degrees(ScriptWidgetAnimationPhase.clockAngle(type:animationType,date:referenceDate ?? Date(),timeZone:clockTimezone)),anchor:clockAnchor)
        } else { content }
        #else
        moving(content)
        #endif
    }
    @ViewBuilder private func moving(_ content: Content) -> some View {
        if ((preview.reduceMotion ?? reduceMotion) || luminanceReduced) && ["clock","swing"].contains(animationType) {
            content
        } else if animationType == "clockSecond" {
            content.clockHandRotationEffect(period:.secondHand,in:clockTimezone,anchor:clockAnchor,referenceDate:referenceDate)
        } else if animationType == "clockMinute" || animationType == "clockMiniute" {
            content.clockHandRotationEffect(period:.minuteHand,in:clockTimezone,anchor:clockAnchor,referenceDate:referenceDate)
        } else if animationType == "clockHour" {
            content.clockHandRotationEffect(period:.hourHand,in:clockTimezone,anchor:clockAnchor,referenceDate:referenceDate)
        } else if animationType == "clock" {
            content.clockHandRotationEffect(period:.custom(clockCustomInterval),in:clockTimezone,anchor:clockAnchor,referenceDate:referenceDate)
        } else if animationType == "swing" {
            content.swingAnimation(duration:swingDuration,direction:swingDirection,distance:swingDistance,referenceDate:referenceDate)
        } else if animationType == "error" { Text("animation json error") }
        else { content }
    }
    static func getTimezone(timezone: String) -> TimeZone { TimeZone(identifier:timezone) ?? .current }
}
