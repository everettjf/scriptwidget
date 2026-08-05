//
//  ScriptWidgetElementTagGif.swift
//  ScriptWidget
//
//  Created by eevv on 12/29/24.
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import SDWebImageSwiftUI
#endif

#if !os(macOS)
struct DynamicGifArcView: Shape {
    var arcStartAngle: Double
    var arcEndAngle: Double
    var arcRadius: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: arcRadius,
                    startAngle: .degrees(arcStartAngle),
                    endAngle: .degrees(arcEndAngle),
                    clockwise: false)
        return path
    }
}
#else
struct DynamicGifView: View {
    let gifPath: URL

    var body: some View {
        if let image = NSImage(contentsOf: gifPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text("GIF unavailable")
        }
    }
}
#endif

#if !os(macOS)
struct DynamicGifView: View {
    var gifPath: URL
    var body: some View {
        if let gifData = NSData(contentsOfFile: gifPath.path(percentEncoded: false)) {

            let data = UIImage.sd_image(withGIFData: gifData as Data)
            if let gifImage = data {
                if let gifImages = gifImage.images, gifImages.count > 0 {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let height = proxy.size.height
                        let arcWidth = max(width, height)
                        let arcRadius = arcWidth * arcWidth
                        let angle = 360.0 / Double(gifImages.count)
                        let duration = gifImage.duration
                        ZStack {
                            ForEach(1...gifImages.count, id: \.self) { index in
                                Image(uiImage: gifImages[index-1])
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: width, height: height)
                                    .mask(
                                        DynamicGifArcView(arcStartAngle: angle * Double(index - 1),
                                                          arcEndAngle: angle * Double(index),
                                                          arcRadius: arcRadius)
                                        .stroke(style: .init(lineWidth: arcWidth, lineCap: .square, lineJoin: .miter))
                                        .frame(width: width, height: height)
                                        .clockHandRotationEffect(period: .custom(duration / 2))
                                        .offset(y: arcRadius) // ⚠️ 需要先进行旋转，再设置offset
                                    )
                            }
                        }
                        .frame(width: width, height: height)
                    }
                } else {
                    Text("gif invalid")
                }
            } else {
                Text("failed parse gif")
            }
        } else {
            Text("failed read gif")
        }
    }
}
#endif



class ScriptWidgetElementTagGif {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {

        if let file = element.getPropString("file") {
            if let path = context.package.getGifFile(file) {
                return AnyView(
                    DynamicGifView(gifPath: path)
                        .modifier(ScriptWidgetAttributeImageModifier(element, context))
                        .modifier(ScriptWidgetAttributeFontModifier(element))
                        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                )
            } else {
                return AnyView(
                    Text("file not found")
                        .modifier(ScriptWidgetAttributeImageModifier(element, context))
                        .modifier(ScriptWidgetAttributeFontModifier(element))
                        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                )
            }
        }

        // default
        return AnyView(
            Text("file not specified")
                .modifier(ScriptWidgetAttributeImageModifier(element, context))
                .modifier(ScriptWidgetAttributeFontModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}
