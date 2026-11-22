//
//  SwingAnimationModifier.swift
//  ScriptWidget
//
//  Created by eevv on 12/29/24.
//

//
//  SwingAnimationModifier.swift
//  SwingAnimation
//
//  Created by Octree on 2023/3/16.
//
//  Copyright (c) 2023 Octree <fouljz@gmail.me>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.



#if canImport(SwiftUI)
import Foundation
import SwiftUI

public struct SwingAnimationModifier: ViewModifier {
    public enum Direction: Hashable, Equatable { case horizontal, vertical }
    public let duration: CGFloat
    public let direction: Direction
    public let distance: CGFloat
    var referenceDate: Date? = nil
    #if !os(macOS)
    @Environment(\.scriptWidgetAnimationPreview) private var preview
    #endif

    @ViewBuilder public func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        if preview.date == nil, preview.elapsed == nil, WidgetKitClockHand.isAvailable {
            // On the Home Screen only WidgetKit's clock-hand effect moves. Two rotations, the
            // inner one at half the speed the other way, carry the element along a straight
            // line; a third turns it back upright.
            content.hidden().overlay(systemSwing(content: content))
        } else {
            ScriptWidgetAnimationFrame(referenceDate: referenceDate) { _, elapsed in
                let offset = ScriptWidgetAnimationPhase.swing(elapsed: elapsed, duration: Double(duration), distance: Double(distance))
                content.offset(x: direction == .horizontal ? offset : 0, y: direction == .vertical ? offset : 0)
            }
        }
        #endif
    }

    #if !os(macOS)
    private func turning<V: View>(_ view: V, _ seconds: Double) -> AnyView {
        WidgetKitClockHand.apply(view, period: .custom(seconds), timeZone: .current, anchor: .center) ?? AnyView(view)
    }

    private func systemSwing(content: Content) -> some View {
        let start: Alignment = direction == .vertical ? (distance > 0 ? .top : .bottom) : (distance > 0 ? .leading : .trailing)
        let end: Alignment = direction == .vertical ? (distance > 0 ? .bottom : .top) : (distance > 0 ? .trailing : .leading)
        let seconds = Double(duration)
        return GeometryReader { proxy in
            let size = proxy.size
            let extent = direction == .vertical ? size.height : size.width
            let length = abs(distance) + extent
            let inner = (length + extent) / 2
            ZStack(alignment: end) {
                Color.clear
                turning(
                    ZStack(alignment: start) {
                        Color.clear
                        turning(
                            ZStack(alignment: start) {
                                Color.clear
                                turning(content, seconds)
                            }
                            .frame(width: inner, height: inner),
                            -seconds / 2
                        )
                    }
                    .frame(width: length, height: length),
                    seconds
                )
            }
            .frame(width: size.width, height: size.height, alignment: start)
        }
    }
    #endif
}
public extension View {
    func swingAnimation(duration: CGFloat, direction: SwingAnimationModifier.Direction = .horizontal, distance: CGFloat, referenceDate: Date? = nil) -> some View {
        modifier(SwingAnimationModifier(duration: duration, direction: direction, distance: distance, referenceDate: referenceDate))
    }
}
#endif
