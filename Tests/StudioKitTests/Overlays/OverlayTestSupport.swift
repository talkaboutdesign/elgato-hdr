import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import StudioKit

/// Rendering and fixture helpers shared by the overlay tests.
enum OverlayTestSupport {
    static var recording: Bool { ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" }

    static func tempDir(_ name: String = #function) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Writes a PNG from straight (non-premultiplied) sRGB RGBA bytes, the way image files store alpha.
    static func writePNG(_ url: URL, width: Int, height: Int, rgba: [UInt8]) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
    }

    static func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ data: Data, _ row: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .renderTarget]
        let t = MetalCore.shared.device.makeTexture(descriptor: d)!
        data.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: row) }
        return t
    }

    /// The compositor goldens' game source: 64x36 10-bit PQ bars (BT.2020).
    static func gameBars() -> LayerTextures.Kind {
        let y10 = (0..<64 * 36).map { UInt16([128, 400, 700, 900][($0 % 64) / 16]) << 6 }
        let c10 = (0..<32 * 18 * 2).map { UInt16([400, 600, 512, 512][($0 / 16) % 4]) << 6 }
        return .biplanar(y: texture(.r16Unorm, 64, 36, y10.withUnsafeBytes { Data($0) }, 128),
                         c: texture(.rg16Unorm, 32, 18, c10.withUnsafeBytes { Data($0) }, 128), bits: 10, transfer: 0, bt709: false)
    }
    static let gameSize = SourceInfo(size: CGSize(width: 64, height: 36))

    /// Renders `layers` into a canvas-sized half-float target (canvas pixels = target pixels) and returns RGBA floats.
    static func render(canvas: CGSize, background: SIMD4<Float> = SIMD4(0, 0, 0, 1), transfer: Int32, layers: [DrawLayer]) -> [Float] {
        let w = Int(canvas.width), h = Int(canvas.height)
        let target = texture(.rgba16Float, w, h, Data(count: w * h * 8), w * 8)
        let cb = MetalCore.shared.queue.makeCommandBuffer()!
        MetalCore.shared.encodeLayers(cb, target: target, canvas: canvas, background: background, outTransfer: transfer, layers: layers)
        cb.commit(); cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    /// The full scene path a call site will take: overlays from the cache (waiting for them), merged with the game.
    static func renderScene(_ comp: Composition, canvas: CGSize, transfer: Int32, cache: OverlayTextureCache, assets: [URL],
                            tokens: OverlayTokens = OverlayTokens()) -> (pixels: [Float], layers: [DrawLayer]) {
        let o = cache.overlays(for: comp, canvas: canvas, assets: assets, tokens: tokens, wait: true)
        let sources = o.sources.merging([.game: gameSize]) { a, _ in a }
        let textures = o.textures.merging([.game: gameBars()]) { a, _ in a }
        let layers = DrawLayer.pair(SceneResolver.resolve(comp, canvas: canvas, sources: sources), textures)
        return (render(canvas: canvas, background: comp.backgroundColor, transfer: transfer, layers: layers), layers)
    }

    /// Samples a 16x9 grid of pixel centres, like `CompositorGoldenTests`.
    static func grid(_ px: [Float], canvas: CGSize) -> [Float] {
        let w = Int(canvas.width), h = Int(canvas.height)
        var g: [Float] = []
        for y in 0..<9 { for x in 0..<16 {
            let i = ((y * h / 9 + h / 18) * w + x * w / 16 + w / 32) * 4
            g += px[i..<i + 4]
        } }
        return g
    }

    /// Compares with Fixtures/golden/<name>.json, or writes it when RECORD_GOLDENS=1.
    static func check(_ values: [Float], _ name: String, accuracy: Float = 0.002, file: StaticString = #filePath, line: UInt = #line) throws {
        if recording {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/golden")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            try enc.encode(values).write(to: dir.appendingPathComponent(name + ".json"))
        } else {
            let expected = try golden(name)
            XCTAssertEqual(values.count, expected.count, file: file, line: line)
            for (i, pair) in zip(values, expected).enumerated() {
                XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "\(name) value \(i)", file: file, line: line)
            }
        }
    }
    static func golden(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/golden"))
        return try JSONDecoder().decode([Float].self, from: Data(contentsOf: url))
    }
}

extension OverlayBitmap {
    func alpha(_ x: Int, _ y: Int) -> Float { Float(pixel(x, y).a) / 255 }

    /// Bounding box (top-left origin, inclusive pixels as a CGRect) of pixels that pass `test`.
    func bounds(where test: (_ b: UInt8, _ g: UInt8, _ r: UInt8, _ a: UInt8) -> Bool) -> CGRect? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<height { for x in 0..<width {
            let p = pixel(x, y)
            if test(p.b, p.g, p.r, p.a) { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
        } }
        return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Mean alpha over `block` x `block` tiles, row by row: coverage that survives sub-pixel glyph differences.
    func blockCoverage(_ block: Int) -> [Float] {
        var out: [Float] = []
        for by in 0..<height / block { for bx in 0..<width / block {
            var s: Float = 0
            for y in by * block..<(by + 1) * block { for x in bx * block..<(bx + 1) * block { s += alpha(x, y) } }
            out.append(s / Float(block * block))
        } }
        return out
    }
}
