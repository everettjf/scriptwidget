//
//  ScriptWidgetAttributeAnimationModifier.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/3/15.
//

import SwiftUI
#if IsWidgetTarget
import SwiftyJSON

/*

 animation:<json>

 let animationSecond = {
 type: "clockSecond",  // clockMinute , clockHour
 timezone: "current",
 anchor: "center"
 }


 let animationCustom = {
 type: "clockCustom",
 interval: 10, // 10 seconds
 timezone: "current",
 anchor: "center"
 }
 */


//
//@available(iOS 14.0, macOS 11, *)
//@available(tvOS, unavailable)
//@available(watchOS, unavailable)
////public struct _ClockHandRotationEffect : SwiftUI.ViewModifier, SwiftUI._ArchivableViewModifier {
//public struct _ClockHandRotationEffect{
//  public enum Period {
//    case hourHand
//    case minuteHand
//    case secondHand
//    case custom(Foundation.TimeInterval)
//  }
////  public init(from decoder: Swift.Decoder) throws
////  public func encode(to encoder: Swift.Encoder) throws
////  @_Concurrency.MainActor(unsafe) public func body(content: WidgetKit._ClockHandRotationEffect.Content) -> some SwiftUI.View
//
////  public typealias Body = @_opaqueReturnTypeOf("$s9WidgetKit24_ClockHandRotationEffectV4body7contentQr7SwiftUI21_ViewModifier_ContentVyACG_tF", 0) __
//}
//extension SwiftUI.View {
//  @available(iOS 14.0, macOS 11, *)
//  @available(tvOS, unavailable)
//  @available(watchOS, unavailable)
//  public func _clockHandRotationEffect(_ period:_ClockHandRotationEffect.Period, in timeZone: Foundation.TimeZone, anchor: SwiftUI.UnitPoint = .center) -> some SwiftUI.View
//
//}


struct ScriptWidgetAttributeAnimationModifier: ViewModifier {

    let animationType: String

    // original clock animation
    let clockTimezone: TimeZone
    let clockAnchor: UnitPoint
    let clockCustomInterval: TimeInterval

    // swing animation
    let swingDuration: CGFloat
    let swingDirection: SwingAnimationModifier.Direction
    let swingDistance: CGFloat


    init(_ element: ScriptWidgetRuntimeElement) {

        var animationType = ""

        var clockTimezone: TimeZone = .current
        var clockAnchor: UnitPoint = .center
        var clockCustomInterval: TimeInterval = 10

        var swingDuration: CGFloat = 1
        var swingDirection: SwingAnimationModifier.Direction = .horizontal
        var swingDistance: CGFloat = 10


        if let animationTypeValue = element.getPropString("animation") {

            if animationTypeValue.starts(with: "animation:") {
                // json support
                let jsonString = animationTypeValue.dropFirst("animation:".count)
                if let jsonData = jsonString.data(using: .utf8)  {
                    do {
                        let json = try JSON(data: jsonData)

                        let type = json["type"].stringValue
                        animationType = type

                        /*
                         let animationDefinition = {
                           type: "clock",
                           timezone: "current", // "America/New_York" , "America/Los_Angeles" ,  "Asia/Shanghai"
                           anchor: "center",
                           interval: 30,
                         }
                         */
                        if animationType == "clock" {
                            if let timezoneValue = json["timezone"].string {
                                clockTimezone = ScriptWidgetAttributeAnimationModifier.getTimezone(timezone: timezoneValue)
                            }
                            if let anchorValue = json["anchor"].string {
                                clockAnchor = ScriptWidgetElementPoint.getPointFromPointValue(anchorValue)
                            }
                            if let intervalValue = json["interval"].double {
                                clockCustomInterval = Self.normalizedInterval(intervalValue)
                            }
                        }

                        /*
                         let animationHorizontalDefinition = {
                           type: "swing",
                           duration: 2,
                           direction: "horizontal", // "horizontal", "vertical"
                           distance: 100,
                         }
                         */
                        if animationType == "swing" {
                            if let duration = json["duration"].double {
                                swingDuration = CGFloat(duration)
                            }
                            if let direction = json["direction"].string {
                                if direction == "horizontal" {
                                    swingDirection = .horizontal
                                } else {
                                    swingDirection = .vertical
                                }
                            }
                            if let distance = json["distance"].double {
                                swingDistance = CGFloat(distance)
                            }
                        }
                    } catch {
                        print("animation json parse error : \(error)")
                        animationType = "error"
                    }
                }
            } else {
                // quick format
                let parts = animationTypeValue.split(separator: ",")
                if parts.count == 1 {
                    // clockSecond
                    // clockMiniute
                    // clockHour
                    animationType = animationTypeValue
                } else if parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespaces) == "clockCustom",
                          let interval = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    animationType = "clock"
                    clockCustomInterval = Self.normalizedInterval(interval)
                }
            }
        }

        self.animationType = animationType

        self.clockTimezone = clockTimezone
        self.clockAnchor = clockAnchor
        self.clockCustomInterval = clockCustomInterval

        self.swingDuration = swingDuration
        self.swingDirection = swingDirection
        self.swingDistance = swingDistance
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if animationType == "clockSecond" {
            content
                .clockHandRotationEffect(period: .secondHand, in: self.clockTimezone, anchor: self.clockAnchor)
        } else if animationType == "clockMinute" || animationType == "clockMiniute" {
            content
                .clockHandRotationEffect(period: .minuteHand, in: self.clockTimezone, anchor: self.clockAnchor)
        } else if animationType == "clockHour" {
            content
                .clockHandRotationEffect(period: .hourHand, in: self.clockTimezone, anchor: self.clockAnchor)
        } else if animationType == "clock" {
            content
                .clockHandRotationEffect(period: .custom(self.clockCustomInterval), in: self.clockTimezone, anchor: self.clockAnchor)
        } else if animationType == "swing" {
            content
                .swingAnimation(duration: self.swingDuration, direction: self.swingDirection, distance: self.swingDistance)
        } else if animationType == "error" {
            Text("animation json error")
        } else {
            content
        }
    }


    static func getTimezone(timezone: String) -> TimeZone {
        if timezone == "current" {
            return .current
        }

        if let timezone = TimeZone(identifier: timezone) {
            return timezone
        }

        // default
        return .current
    }

    /// WidgetKit accepts signed custom periods. A negative value reverses the
    /// rotation, which makes epicycles and counter-rotating systems possible.
    private static func normalizedInterval(_ interval: Double) -> TimeInterval {
        guard interval.isFinite else {
            return 10
        }

        if abs(interval) < 0.25 {
            return interval < 0 ? -0.25 : 0.25
        }
        return TimeInterval(interval)
    }
}

#else

struct ScriptWidgetAttributeAnimationModifier: ViewModifier {

    init(_ element: ScriptWidgetRuntimeElement) {
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content
    }
}

#endif
