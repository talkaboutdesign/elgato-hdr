// CPU side of overlays: decoded images and rasterized text as premultiplied BGRA sRGB bitmaps, the exact bytes the
// `.rgba` path of `layerFrag` expects (it un-premultiplies and treats the values as SDR code values).
import CoreGraphics
import Foundation
import ImageIO

/// Premultiplied BGRA, sRGB code values, top row first (what a `CGBitmapContext` holds in memory; Metal's texture
/// origin is top-left too, so the bytes upload unchanged).
struct OverlayBitmap {
    var width: Int, height: Int
    var pixels: [UInt8]
    var bytesPerRow: Int { width * 4 }
    var size: CGSize { CGSize(width: width, height: height) }

    /// Runs `draw` in a cleared context whose user space has CoreGraphics' usual bottom-left origin.
    static func draw(width: Int, height: Int, _ draw: (CGContext) -> Void) -> OverlayBitmap? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        guard let data = ctx.data else { return nil }
        return OverlayBitmap(width: width, height: height, pixels: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)))
    }

    /// Premultiplied b, g, r, a of the pixel in column x, row y (row 0 at the top).
    func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
}

enum OverlayImage {
    /// Pixel size with EXIF orientation applied, read from the header only.
    static func size(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let rotated = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// First frame, oriented, scaled so its long side is at most `maxPixel` (never up), converted to sRGB.
    static func decode(_ url: URL, maxPixel: Int) -> OverlayBitmap? {
        guard let native = size(of: url),
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let limit = min(max(1, maxPixel), Int(max(native.width, native.height)))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return OverlayBitmap.draw(width: img.width, height: img.height) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }
}
