//
//  ScriptWidgetElementTagImage.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/11/2.
//

import Foundation
import SwiftUI
import ImageIO
import WidgetKit

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

    /// WidgetKit archives a view shortly after its timeline entry is delivered;
    /// an AsyncImage completion is therefore not guaranteed to be observed. For
    /// remote images, resolve bounded bytes before constructing the Image while
    /// retaining the same downsampling and memory-cache path as local images.
    static func synchronousRemoteImage(
        at url: URL,
        timeout: TimeInterval = 2.5,
        fetch: ((URL, TimeInterval) -> Data?)? = nil
    ) -> ScriptWidgetPlatformImage? {
        guard ScriptWidgetFetchPolicy.validationError(for: url) == nil else { return nil }
        let cacheKey = "remote|\(url.absoluteString)"
        if let cached = cache.object(forKey: "\(cacheKey)|\(defaultMaximumPixelSize)" as NSString) {
            return cached
        }
        let boundedTimeout = min(3, max(0.25, timeout))
        let data: Data?
        if let fetch {
            data = fetch(url, boundedTimeout)
        } else {
            data = synchronouslyFetchBoundedData(at: url, timeout: boundedTimeout)
        }
        guard let data, data.count <= ScriptWidgetFetchManager.maximumResponseBytes else { return nil }
        return image(data: data, cacheKey: cacheKey)
    }

    static func removeAll() { cache.removeAllObjects() }

    private static func synchronouslyFetchBoundedData(at url: URL, timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Data?
        let task = sharedFetchManager.makeTask(
            httpMethod: "GET",
            url: url,
            params: ["timeoutInterval": timeout]
        ) { data, _, error in
            lock.lock()
            if error == nil { result = data }
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 0.25) == .success else {
            task.cancel()
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

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


struct ScriptWidgetAccentedImage: View {
    let image: Image
    let mode: String?

    @ViewBuilder var body: some View {
        if #available(iOS 18.0, macOS 15.0, *), let mode {
            switch mode {
            case "accented": image.widgetAccentedRenderingMode(.accented)
            case "desaturated": image.widgetAccentedRenderingMode(.desaturated)
            case "accentedDesaturated": image.widgetAccentedRenderingMode(.accentedDesaturated)
            case "fullColor": image.widgetAccentedRenderingMode(.fullColor)
            default: image
            }
        } else {
            image
        }
    }
}

struct FileSyncImage: View {
    let fileUrl: URL
    let accentedRenderingMode: String?
#if os(macOS)
    private var fileImage: NSImage?
#else
    private var fileImage: UIImage?
#endif
    init(fileUrl: URL, accentedRenderingMode: String?) {
        self.fileUrl = fileUrl
        self.accentedRenderingMode = accentedRenderingMode
        self.fileImage = ScriptWidgetImagePipeline.image(at: fileUrl)
    }
    
    var body: some View {
        if let fileImage = self.fileImage {
#if os(macOS)
            ScriptWidgetAccentedImage(image: Image(nsImage: fileImage).resizable(), mode: accentedRenderingMode)
#else
            ScriptWidgetAccentedImage(image: Image(uiImage: fileImage).resizable(), mode: accentedRenderingMode)
#endif
        } else {
            ScriptWidgetAccentedImage(image: Image(systemName: "questionmark.circle"), mode: accentedRenderingMode)
        }
    }
}



struct WebSyncImage: View {
    let webUrl: URL
    let accentedRenderingMode: String?
#if os(macOS)
    private let image: NSImage?
#else
    private let image: UIImage?
#endif

    init(webUrl: URL, accentedRenderingMode: String?) {
        self.webUrl = webUrl
        self.accentedRenderingMode = accentedRenderingMode
        self.image = ScriptWidgetImagePipeline.synchronousRemoteImage(at: webUrl)
    }

    var body: some View {
        if let image {
#if os(macOS)
            ScriptWidgetAccentedImage(image: Image(nsImage: image).resizable(), mode: accentedRenderingMode)
#else
            ScriptWidgetAccentedImage(image: Image(uiImage: image).resizable(), mode: accentedRenderingMode)
#endif
        } else {
            ScriptWidgetAccentedImage(image: Image(systemName: "questionmark.circle"), mode: accentedRenderingMode)
        }
    }
}



class ScriptWidgetElementTagImage {
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        let accentedRenderingMode = element.getPropString("accentedRenderingMode")
        
        // systemName : SF Symbols
        if let systemName = element.getPropString("systemName") {
            return AnyView(
                ScriptWidgetAccentedImage(image: Image(systemName: systemName), mode: accentedRenderingMode)
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
                    FileSyncImage(fileUrl: image.path, accentedRenderingMode: accentedRenderingMode)
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
                        return AnyView(ScriptWidgetAccentedImage(image: Image(nsImage: image), mode: accentedRenderingMode)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#else
                    if let image = ScriptWidgetImagePipeline.image(data: base64Data, cacheKey: imageUrlString){
                        return AnyView(ScriptWidgetAccentedImage(image: Image(uiImage: image), mode: accentedRenderingMode)
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
                        return AnyView(ScriptWidgetAccentedImage(image: Image(nsImage: image), mode: accentedRenderingMode)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#else
                    if let image = ScriptWidgetImagePipeline.image(data: base64Data, cacheKey: imageUrlString){
                        return AnyView(ScriptWidgetAccentedImage(image: Image(uiImage: image), mode: accentedRenderingMode)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context)))
                    }
#endif
                }
            } else {
                // normal url
                if let imageUrl = URL(string: imageUrlString) {
                    return AnyView(
                        WebSyncImage(webUrl: imageUrl, accentedRenderingMode: accentedRenderingMode)
                            .modifier(ScriptWidgetAttributeImageModifier(element, context))
                            .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
                    )
                }
            }
        }
        
        // default
        return AnyView(
            ScriptWidgetAccentedImage(image: Image(systemName: "questionmark.circle"), mode: accentedRenderingMode)
                .modifier(ScriptWidgetAttributeImageModifier(element, context))
                .modifier(ScriptWidgetAttributeFontModifier(element))
                .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
        )
    }
}
