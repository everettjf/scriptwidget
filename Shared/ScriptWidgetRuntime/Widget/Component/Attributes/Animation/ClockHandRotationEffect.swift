//
//  ClockHandRotationEffect.swift
//  ScriptWidget
//
//  Adapted from ClockHandKit by giljihun.
//  https://github.com/giljihun/ClockHandKit
//  Copyright (c) 2026 giljihun. Licensed under the MIT License.
//

#if !os(macOS)
import Foundation
import OSLog
import SwiftUI

@available(iOS 14.0, *)
private let clockHandLog = Logger(
    subsystem: "com.everettjf.scriptwidget",
    category: "clock-hand-runtime-bridge"
)

@available(iOS 14.0, *)
enum ClockHandPeriod {
    case hourHand
    case minuteHand
    case secondHand
    case custom(Double)
}

private struct ClockHandData: Encodable {
    let period: PeriodPayload
    let timeZone: TimeZonePayload
    let anchor: AnchorPayload

    enum PeriodPayload: Encodable {
        case hourHand
        case minuteHand
        case secondHand
        case custom(Double)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hourHand:
                try container.encode(EmptyPayload(), forKey: .hourHand)
            case .minuteHand:
                try container.encode(EmptyPayload(), forKey: .minuteHand)
            case .secondHand:
                try container.encode(EmptyPayload(), forKey: .secondHand)
            case .custom(let value):
                var nested = container.nestedContainer(keyedBy: CustomKeys.self, forKey: .custom)
                try nested.encode(value, forKey: .value)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case hourHand
            case minuteHand
            case secondHand
            case custom
        }

        private enum CustomKeys: String, CodingKey {
            case value = "_0"
        }
    }

    struct EmptyPayload: Encodable {}

    struct TimeZonePayload: Encodable {
        let identifier: String
    }

    struct AnchorPayload: Encodable {
        let x: Double
        let y: Double
    }
}

@available(iOS 14.0, *)
private func applyClockHandModifier<V: View>(
    to view: V,
    period: ClockHandPeriod,
    timeZone: TimeZone,
    anchor: UnitPoint
) -> AnyView {
    guard let effectType = _typeByName("9WidgetKit24_ClockHandRotationEffectV") else {
        clockHandLog.error("WidgetKit clock-hand effect type is unavailable")
        return AnyView(view)
    }
    guard let decodableType = effectType as? any Decodable.Type else {
        clockHandLog.error("WidgetKit clock-hand effect is not Decodable")
        return AnyView(view)
    }

    let periodPayload: ClockHandData.PeriodPayload
    switch period {
    case .hourHand:
        periodPayload = .hourHand
    case .minuteHand:
        periodPayload = .minuteHand
    case .secondHand:
        periodPayload = .secondHand
    case .custom(let seconds):
        periodPayload = .custom(seconds)
    }

    let payload = ClockHandData(
        period: periodPayload,
        timeZone: .init(identifier: timeZone.identifier),
        anchor: .init(x: Double(anchor.x), y: Double(anchor.y))
    )

    do {
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(decodableType, from: data)
        guard let modifier = decoded as? any ViewModifier else {
            clockHandLog.error("WidgetKit clock-hand effect is not a ViewModifier")
            return AnyView(view)
        }
        return AnyView(applyModifier(view, modifier: modifier))
    } catch {
        clockHandLog.error("Unable to construct WidgetKit clock-hand effect: \(error.localizedDescription, privacy: .public)")
        return AnyView(view)
    }
}

@available(iOS 14.0, *)
private func applyModifier<V: View, M: ViewModifier>(
    _ view: V,
    modifier: M
) -> some View {
    view.modifier(modifier)
}

@available(iOS 14.0, *)
extension View {
    func clockHandRotationEffect(
        period: ClockHandPeriod,
        in timeZone: TimeZone = .current,
        anchor: UnitPoint = .center
    ) -> some View {
        applyClockHandModifier(to: self, period: period, timeZone: timeZone, anchor: anchor)
    }
}
#endif
