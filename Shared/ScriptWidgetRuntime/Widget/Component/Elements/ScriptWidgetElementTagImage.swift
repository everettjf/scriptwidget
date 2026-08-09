//
//  ScriptWidgetElementTagImage.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/11/2.
//

import Foundation
import SwiftUI
import ImageIO

#if os(macOS)
typealias ScriptWidgetPlatformImage = NSImage
#else
typealias ScriptWidgetPlatformImage = UIImage
#endif

enum ScriptWidgetImagePipeline {
    static let maximumInputBytes = 8 * 1_024 * 1_024
    static let maximumPixelCount = 16_000_000
    static let defaultMaximumPixelSize = 1_024
    static let cacheCostLimit = 24 * 1_024 * 1_024

    private static let cache: NSCache<NSString, ScriptWidgetPlatformImage> = {
        let value = NSCache<NSString, ScriptWidgetPlatformImage>()
        value.totalCostLimit = cacheCostLimit
        value.countLimit = 32
        return value
    }()

    static func image(at url: URL, maximumPixelSize: Int = defaultMaximumPixelSize) -> ScriptWidgetPlatformImage? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= maximumInputBytes else { return nil }
        let key = "\(url.path)|\(maximumPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = downsample(source: source, maximumPixelSize: maximumPixelSize) else { return nil }
        cache.setObject(image, forKey: key, cost: decodedCost(image))
        return image
    }

    static func image(data: Data, cacheKey: String? = nil, maximumPixelSize: Int = defaultMaximumPixelSize) -> ScriptWidgetPlatformImage? {
        guard data.count <= maximumInputBytes else { return nil }
        let key = cacheKey.map { "\($0)|\(maximumPixelSize)" as NSString }
        if let key, let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = downsample(source: source, maximumPixelSize: maximumPixelSize) else { return nil }
        if let key { cache.setObject(image, forKey: key, cost: decodedCost(image)) }
        return image
    }

    static func removeAll() { cache.removeAllObjects() }

    private static func downsample(source: CGImageSource, maximumPixelSize: Int) -> ScriptWidgetPlatformImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= maximumPixelCount / max(1, height.intValue) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
#if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
#else
        return UIImage(cgImage: cgImage)
#endif
    }

    private static func decodedCost(_ image: ScriptWidgetPlatformImage) -> Int {
#if os(macOS)
        guard let representation = image.representations.first else { return 0 }
        return representation.pixelsWide * representation.pixelsHigh * 4
#else
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
#endif
    }
}


struct FileSyncImage: View {
    let fileUrl: URL
#if os(macOS)
    private var fileImage: NSImage?
#else
    private var fileImage: UIImage?
#endif
    init(fileUrl: URL) {
        self.fileUrl = fileUrl
        self.fileImage = ScriptWidgetImagePipeline.image(at: fileUrl)
    }
    
    var body: some View {
        if let fileImage = self.fileImage {
#if os(macOS)
            Image(nsImage: fileImage)
                .resizable()
#else
            Image(uiImage: fileImage)
                .resizable()
#endif
        } else {
            Image(systemName: "questionmark.circle")
        }
    }
}



struct WebSyncImage: View {
    let webUrl: URL

    var body: some View {
        AsyncImage(url: webUrl) { phase in
            switch phase {
            case .empty:
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            case .success(let image):
                image.resizable()
            case .failure:
                Image(systemName: "questionmark.circle")
            @unknown default:
                Image(systemName: "questionmark.circle")
            }
        }
    }
}



class ScriptWidgetElementTagImage {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
        // systemName : SF Symbols
        if let systemName = element.getPropString("systemName") {
            return AnyView(
                Image(systemName: systemName)
                    .modifier(ScriptWidgetAttributeImageModifier(element, context))
                    .modifier(ScriptWidgetAttributeFontModifier(element))
                    .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
            )
        }
        
        // name or id
        if let imageName = element.getPropString("name", or: "id") {
            // first try local image
            if let image = context.package.getImage(imageName) {
                return AnyView(
                    FileSyncImage(fileUrl: image.path)
                        .modifier(ScriptWidgetAttributeImageModifier(element, context))
                        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                )
            }
        }
        
        // url or src
        if let imageUrlString = element.getPropString("url", or: "src") {
            /*
             <image
             url="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4
             //8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5ErkJggg=="
             />
             
             supports:
             data:image/jpeg;base64,
             data:image/png;base64,
             */
            let base64imagePngPrefix = "data:image/png;base64,"
            let base64imageJpegPrefix = "data:image/jpeg;base64,"
            if imageUrlString.starts(with: base64imagePngPrefix) {
                // image base64 url
                let prefixIndex = imageUrlString.index(imageUrlString.startIndex, offsetBy: base64imagePngPrefix.count)
                let base64String = String(imageUrlString.suffix(from: prefixIndex))
                if base64String.utf8.count <= (ScriptWidgetImagePipeline.maximumInputBytes * 4 / 3 + 4),
                   let base64Data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) {
#if os(macOS)
                    if let image = ScriptWidgetImagePipeline.image(data: base64Data, cacheKey: imageUrlString){
                        return AnyView(Image(nsImage: image)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#else
                    if let image = ScriptWidgetImagePipeline.image(data: base64Data, cacheKey: imageUrlString){
                        return AnyView(Image(uiImage: image)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#endif
                }
            } else if imageUrlString.starts(with: base64imageJpegPrefix) {
                // image base64 url
                let prefixIndex = imageUrlString.index(imageUrlString.startIndex, offsetBy: base64imageJpegPrefix.count)
                let base64String = String(imageUrlString.suffix(from: prefixIndex))
                if base64String.utf8.count <= (ScriptWidgetImagePipeline.maximumInputBytes * 4 / 3 + 4),
                   let base64Data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) {
#if os(macOS)
                    if let image = ScriptWidgetImagePipeline.image(data: base64Data, cacheKey: imageUrlString){
                        return AnyView(Image(nsImage: image)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#else
                    if let image = ScriptWidgetImagePipeline.image(data: base64Data, cacheKey: imageUrlString){
                        return AnyView(Image(uiImage: image)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#endif
                }
            } else {
                // normal url
                if let imageUrl = URL(string: imageUrlString) {
                    return AnyView(
                        WebSyncImage(webUrl: imageUrl)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                    )
                }
            }
        }
        
        // default
        return AnyView(
            Image(systemName: "questionmark.circle")
                .modifier(ScriptWidgetAttributeImageModifier(element, context))
                .modifier(ScriptWidgetAttributeFontModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}
