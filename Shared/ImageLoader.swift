import Foundation
import CoreGraphics
import ImageIO

/// Decodes full-size or screen-size images for the viewer. Read-only.
enum ImageLoader {
    static let maxDimension = 16_384

    private static func usesImageIO(_ item: MediaItem) -> Bool {
        item.group == .image || item.group == .raw || item.fileExtension == "psd"
    }

    private static func isPDF(_ item: MediaItem) -> Bool {
        item.fileExtension == "pdf" || item.fileExtension == "ai"
    }

    /// Pixel size as displayed (orientation applied). Nil for video.
    static func pixelSize(of item: MediaItem) -> CGSize? {
        if usesImageIO(item) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, options),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        if isPDF(item) {
            guard let page = CGPDFDocument(item.url as CFURL)?.page(at: 1) else { return nil }
            let size = pageSize(page)
            return CGSize(width: size.width * 2, height: size.height * 2)
        }
        return nil
    }

    /// Decodes the item. `maxPixel` limits the longest edge; nil means full resolution.
    static func load(_ item: MediaItem, maxPixel: Int?) -> CGImage? {
        if usesImageIO(item) {
            if let image = decode(item.url, maxPixel: maxPixel) { return image }
        } else if isPDF(item) {
            if let image = renderPDF(item.url, maxPixel: maxPixel) { return image }
        }
        guard item.group != .video else { return nil }
        return ThumbnailPipeline.quickLookThumbnail(url: item.url, maxPixel: min(maxPixel ?? 2048, 2048))
    }

    private static func decode(_ url: URL, maxPixel: Int?) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        var limit = maxDimension
        if let maxPixel { limit = min(maxPixel, maxDimension) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func pageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let quarterTurned = (page.rotationAngle / 90) % 2 != 0
        return quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
    }

    private static func renderPDF(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        let size = pageSize(page)
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        var scale: CGFloat = 2
        if let maxPixel { scale = CGFloat(maxPixel) / longest }
        scale = min(scale, 8192 / longest)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let target = CGRect(origin: .zero, size: size)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
