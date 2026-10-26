import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

// Uploaded images are bounded before decoding and normalized before display.
nonisolated enum GameArtwork {
    static let maximumUpload = 8 * 1024 * 1024
    static func validFilename(_ name: String) -> Bool {
        name.hasSuffix(".png") && GameIdentity.valid(String(name.dropLast(4)))
    }
    static func normalize(_ url: URL) throws -> (name: String, data: Data) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumUpload,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000,
              let image = thumbnail(source, maximum: 1024) else {
            throw LibraryError.invalid("Choose a single PNG or JPEG up to 8 MB and 24 megapixels (maximum 8192 pixels per side).")
        }
        return try filled(image)
    }
    private static func filled(_ image: CGImage) throws -> (name: String, data: Data) {
        // Fill the HDTV card with a centered crop, keeping proportions.
        guard let canvas = CGContext(data: nil, width: 1024, height: 576, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw LibraryError.invalid("Could not prepare artwork.")
        }
        canvas.setFillColor(CGColor(red: 0.08, green: 0.15, blue: 0.27, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1024, height: 576))
        let scale = max(1024 / CGFloat(image.width), 576 / CGFloat(image.height))
        let fittedWidth = CGFloat(image.width) * scale, fittedHeight = CGFloat(image.height) * scale
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: (1024 - fittedWidth) / 2, y: (576 - fittedHeight) / 2, width: fittedWidth, height: fittedHeight))
        guard let fitted = canvas.makeImage() else { throw LibraryError.invalid("Could not prepare artwork.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw LibraryError.invalid("Could not prepare artwork.")
        }
        CGImageDestinationAddImage(destination, fitted, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("Could not read this picture.") }
        let bytes = data as Data
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (hash + ".png", bytes)
    }
    static func upgradeFittedPicture(_ url: URL) throws -> (name: String, data: Data) {
        guard let image = load(url, maximum: 1024) else { throw LibraryError.invalid("Could not read artwork.") }
        // Version 1 stored a 1024×576 image with flat blue padding baked in.
        // Remove only complete outer rows/columns matching that exact colour.
        guard image.width == 1024, image.height == 576,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let raw = context.data else { return try filled(image) }
        context.setFillColor(CGColor(red: 0.08, green: 0.15, blue: 0.27, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let background = [bytes[0], bytes[1], bytes[2], bytes[3]]
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * image.width + x) * 4
            return (0..<4).allSatisfy { bytes[offset + $0] == background[$0] }
        }
        var left = 0, right = image.width, top = 0, bottom = image.height
        while left < right && (0..<image.height).allSatisfy({ isBackground(left, $0) }) { left += 1 }
        while right > left && (0..<image.height).allSatisfy({ isBackground(right - 1, $0) }) { right -= 1 }
        while top < bottom && (left..<right).allSatisfy({ isBackground($0, top) }) { top += 1 }
        while bottom > top && (left..<right).allSatisfy({ isBackground($0, bottom - 1) }) { bottom -= 1 }
        guard left < right, top < bottom,
              let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { return try filled(image) }
        return try filled(cropped)
    }
    static func load(_ url: URL, maximum: Int = 400) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maximum: maximum)
    }
    private static func thumbnail(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
