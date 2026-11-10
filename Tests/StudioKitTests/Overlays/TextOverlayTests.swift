import Metal
import XCTest
@testable import StudioKit

/// Text goldens must hold on other Macs and macOS versions, whose system font may lay glyphs out a little differently.
/// So exact pixels are only compared where no glyph is involved (the plate, the compositing of a given bitmap); text
/// itself is checked through layout properties (plate geometry, alignment, line count) and through coverage averaged
/// over 16x16-pixel blocks against a recorded golden (see `testCoverageGolden` for the tolerance).
final class TextOverlayTests: XCTestCase {
    typealias S = OverlayTestSupport

    // MARK: Model and tokens

    func testDecodesLenientlyAndRoundTrips() throws {
        let empty = try JSONDecoder().decode(TextSpec.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, TextSpec())
        let partial = try JSONDecoder().decode(TextSpec.self, from: Data(#"{"string":"Hi","plate":[0,0,0,0.5],"weight":7,"future":true}"#.utf8))
        XCTAssertEqual(partial.string, "Hi")
        XCTAssertEqual(partial.plate, [0, 0, 0, 0.5])
        XCTAssertEqual(partial.weight, "semibold", "a wrongly typed field falls back")
        // Layers saved while TextSpec was an empty placeholder still load.
        let layer = try JSONDecoder().decode(Layer.self, from: Data(#"{"source":{"type":"text","text":{}}}"#.utf8))
        XCTAssertEqual(layer.source.text, TextSpec())
        var spec = TextSpec(); spec.string = "Name"; spec.fontName = "Avenir-Heavy"; spec.alignment = "left"; spec.plate = [0.1, 0.2, 0.3, 1]; spec.shadow = false
        XCTAssertEqual(try JSONDecoder().decode(TextSpec.self, from: JSONEncoder().encode(spec)), spec)
    }

    func testTokens() {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        let date = ISO8601DateFormatter().date(from: "2026-11-09T18:05:59Z")!     // 19:05 in Berlin
        var t = OverlayTokens(now: date, elapsed: nil, timeZone: tz)
        XCTAssertEqual(t.replace("Back at {time}"), "Back at 19:05")
        XCTAssertEqual(t.replace("{timer}"), "0:00")
        t.elapsed = 65.9; XCTAssertEqual(t.replace("Live {timer}"), "Live 1:05")
        t.elapsed = 3600 * 2 + 61; XCTAssertEqual(t.replace("{timer} / {time}"), "2:01:01 / 19:05")
        XCTAssertEqual(t.replace("{times} {TIME} plain"), "{times} {TIME} plain")
        XCTAssertTrue(OverlayTokens.contains("a {timer}"))
        XCTAssertFalse(OverlayTokens.contains("no tokens"))
    }

    // MARK: Layout

    func render(_ spec: TextSpec, _ w: Int, _ h: Int) throws -> OverlayBitmap {
        try XCTUnwrap(TextRasterizer.render(spec, string: spec.string, width: w, height: h))
    }
    func plateSpec(_ string: String, alignment: String) -> TextSpec {
        TextSpec(string: string, color: [1, 1, 1, 1], alignment: alignment, plate: [0, 0, 1, 1], plateRadius: 0.5, platePadding: 0.35, shadow: false)
    }

    /// Single line on a plate: the plate takes the box's full height, hugs the text horizontally and sits left, centred
    /// or right; its corners are round. Geometry is checked on the bitmap against the layout, and against the box.
    func testPlateGeometryAndAlignment() throws {
        let W = 600, H = 80
        for alignment in ["left", "center", "right"] {
            let spec = plateSpec("Name Tag", alignment: alignment)
            let l = TextRasterizer.layout(spec, string: spec.string, size: CGSize(width: W, height: H))
            let plate = try XCTUnwrap(l.plate)
            XCTAssertEqual(plate.height, CGFloat(H), accuracy: 1, alignment)
            XCTAssertLessThan(plate.width, CGFloat(W) * 0.9, "hugs the text")
            XCTAssertEqual(plate.height - l.block.height, 2 * 0.35 * l.fontSize, accuracy: 0.01)
            let b = try render(spec, W, H)
            // Opaque blue: the plate where no glyph covers it.
            let drawn = try XCTUnwrap(b.bounds { bl, _, r, a in a > 200 && bl > 200 && r < 40 })
            XCTAssertEqual(drawn.minX, plate.minX, accuracy: 1.5, alignment); XCTAssertEqual(drawn.maxX, plate.maxX, accuracy: 1.5, alignment)
            XCTAssertEqual(drawn.minY, plate.minY, accuracy: 1.5, alignment); XCTAssertEqual(drawn.maxY, plate.maxY, accuracy: 1.5, alignment)
            switch alignment {
            case "left": XCTAssertEqual(plate.minX, 0, accuracy: 0.5)
            case "right": XCTAssertEqual(plate.maxX, CGFloat(W), accuracy: 0.5)
            default: XCTAssertEqual(plate.midX, CGFloat(W) / 2, accuracy: 1)
            }
            // Radius 0.5 of the height: a pill. The corner pixel is empty, the middle of the left edge is not.
            XCTAssertLessThan(b.alpha(Int(plate.minX) + 1, Int(plate.minY) + 1), 0.1, alignment)
            XCTAssertGreaterThan(b.alpha(Int(plate.minX) + 1, Int(plate.midY)), 0.9, alignment)
            // White ink lies inside the block (glyphs may overhang their advance a little).
            let ink = try XCTUnwrap(b.bounds { bl, g, r, a in a > 200 && r > 200 && g > 200 && bl > 200 })
            XCTAssertGreaterThanOrEqual(ink.minX, l.block.minX - 0.1 * l.fontSize, alignment)
            XCTAssertLessThanOrEqual(ink.maxX, l.block.maxX + 0.1 * l.fontSize, alignment)
            XCTAssertGreaterThanOrEqual(ink.minY, l.block.minY, alignment)
            XCTAssertLessThanOrEqual(ink.maxY, l.block.maxY, alignment)
        }
    }

    /// Without a plate the text block aligns inside the box; the ink follows it.
    func testAlignmentWithoutPlate() throws {
        let W = 800, H = 100
        var inks: [String: CGRect] = [:]
        for alignment in ["left", "center", "right"] {
            let spec = TextSpec(string: "Be right back", alignment: alignment, shadow: false)
            let l = TextRasterizer.layout(spec, string: spec.string, size: CGSize(width: W, height: H))
            XCTAssertNil(l.plate)
            XCTAssertEqual(l.block.height, CGFloat(H), accuracy: 1, "height-limited single line fills the box height")
            let ink = try XCTUnwrap(try render(spec, W, H).bounds { _, _, _, a in a > 128 })
            inks[alignment] = ink
            let tolerance = 0.1 * l.fontSize      // side bearings
            switch alignment {
            case "left": XCTAssertEqual(ink.minX, 0, accuracy: tolerance)
            case "right": XCTAssertEqual(ink.maxX, CGFloat(W), accuracy: tolerance)
            default: XCTAssertEqual(ink.midX, CGFloat(W) / 2, accuracy: tolerance)
            }
        }
        // Same font size whatever the alignment: the ink is the same width, only moved.
        XCTAssertEqual(inks["left"]!.width, inks["right"]!.width, accuracy: 1)
        XCTAssertEqual(inks["left"]!.width, inks["center"]!.width, accuracy: 1)
    }

    /// A line too wide for the box shrinks the font instead of wrapping.
    func testWideLineFitsTheWidth() throws {
        let spec = plateSpec("A rather long line of text", alignment: "center")
        let l = TextRasterizer.layout(spec, string: spec.string, size: CGSize(width: 300, height: 200))
        let plate = try XCTUnwrap(l.plate)
        XCTAssertEqual(l.lines.count, 1)
        XCTAssertLessThanOrEqual(plate.width, 300.5)
        XCTAssertGreaterThan(plate.width, 290, "the largest size that fits")
        XCTAssertLessThan(plate.height, 100)
        XCTAssertEqual(plate.midY, 100, accuracy: 1, "centred vertically")
    }

    /// Line breaks make lines; each is aligned on its own and the block is centred in the box.
    func testMultiLine() throws {
        let W = 400, H = 300
        let spec = TextSpec(string: "One\nTwo\nThree", alignment: "center", shadow: false)
        let l = TextRasterizer.layout(spec, string: spec.string, size: CGSize(width: W, height: H))
        XCTAssertEqual(l.lines.count, 3)
        XCTAssertLessThanOrEqual(l.block.height, CGFloat(H) + 0.5)
        let single = TextRasterizer.layout(TextSpec(string: "One", shadow: false), string: "One", size: CGSize(width: W, height: H))
        XCTAssertLessThan(l.fontSize, single.fontSize * 0.5, "three lines share the height")
        // Rows with ink form three bands, evenly spaced, each centred horizontally.
        let b = try render(spec, W, H)
        var bands: [ClosedRange<Int>] = []
        for y in 0..<H where (0..<W).contains(where: { b.alpha($0, y) > 0.5 }) {
            if let last = bands.last, last.upperBound == y - 1 { bands[bands.count - 1] = last.lowerBound...y } else { bands.append(y...y) }
        }
        XCTAssertEqual(bands.count, 3, "\(bands)")
        guard bands.count == 3 else { return }
        let baselines = bands.map { CGFloat($0.upperBound) }    // no descenders in these words
        XCTAssertEqual(baselines[1] - baselines[0], baselines[2] - baselines[1], accuracy: 1.5)
        for band in bands {     // whole band: a "T" has ink at its top only on the left
            let xs = band.flatMap { y in (0..<W).filter { b.alpha($0, y) > 0.5 } }
            XCTAssertEqual(CGFloat(xs.min()! + xs.max()!) / 2, CGFloat(W) / 2, accuracy: 0.08 * l.fontSize)
        }
    }

    /// A font this Mac does not have falls back to the system font; the spec keeps the name.
    func testMissingFontFallsBack() throws {
        var missing = TextSpec(string: "Fallback", shadow: false); missing.fontName = "NoSuchFont-ElgatoHDR"
        let system = TextSpec(string: "Fallback", shadow: false)
        XCTAssertEqual(try render(missing, 300, 60).pixels, try render(system, 300, 60).pixels)
        XCTAssertEqual(missing.fontName, "NoSuchFont-ElgatoHDR")
    }

    // MARK: Goldens

    /// Coverage golden: alpha averaged over 16x16 blocks of a 512x128 title with shadow, compared by mean absolute
    /// difference. Measured on this machine, moving the text by one pixel changes that mean by 0.007 and rendering it
    /// 3 % smaller by 0.016 (one block by 0.22); a regular instead of a bold weight changes it by 0.037, left instead
    /// of centred alignment by 0.16. Accepting a mean below 0.025 (and no block beyond 0.35) tolerates the glyph and
    /// metric revisions a system font gets between macOS versions while still catching layout and weight mistakes.
    func testCoverageGolden() throws {
        let spec = TextSpec(string: "Soon", weight: "bold", alignment: "center", shadow: true)
        let blocks = try render(spec, 512, 128).blockCoverage(16)
        if S.recording { try S.check(blocks, "overlay-text-coverage"); return }
        let golden = try S.golden("overlay-text-coverage")
        XCTAssertEqual(blocks.count, golden.count)
        let diffs = zip(blocks, golden).map { abs($0 - $1) }
        let mad = diffs.reduce(0, +) / Float(diffs.count)
        XCTAssertLessThan(mad, 0.025, "mean absolute coverage difference")
        XCTAssertLessThan(diffs.max() ?? 0, 0.35, "largest block difference")
        // The golden is not trivially satisfied: the same text left-aligned is far off.
        var left = spec; left.alignment = "left"
        let other = try render(left, 512, 128).blockCoverage(16)
        XCTAssertGreaterThan(zip(other, golden).map { abs($0 - $1) }.reduce(0, +) / Float(diffs.count), 0.1)
    }

    /// A text layer through the whole path a call site takes (cache, resolver, `encodeLayers`) over the game. In SDR
    /// output every pixel of the layer must equal the CPU blend of the rasterized bitmap over the game alone, so the
    /// shader's `.rgba` path is checked exactly without depending on glyph shapes. In PQ the plate, away from the
    /// glyphs, must equal a colour layer of the same colour.
    func testTextLayerCompositesExactly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let canvas = CGSize(width: 320, height: 180)
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        var spec = plateSpec("Live {timer}", alignment: "left"); spec.plate = [0.9, 0.3, 0.1, 0.8]; spec.shadow = true
        let frame = NRect(x: 0.1, y: 0.7, w: 0.6, h: 0.2)                     // 32,126 192x36: whole pixels
        let text = Layer(source: LayerSource(type: "text", text: spec), frame: frame)
        let comp = Composition(layers: [Layer(source: .game), text])
        let tokens = OverlayTokens(now: Date(), elapsed: 42)
        let base = S.renderScene(Composition(layers: [Layer(source: .game)]), canvas: canvas, transfer: 2, cache: cache, assets: []).pixels
        let (sdr, layers) = S.renderScene(comp, canvas: canvas, transfer: 2, cache: cache, assets: [], tokens: tokens)
        XCTAssertEqual(layers.count, 2)
        let bitmap = try XCTUnwrap(TextRasterizer.render(spec, string: "Live 0:42", width: 192, height: 36))
        var worst: Float = 0
        for y in 0..<36 { for x in 0..<192 {
            let p = bitmap.pixel(x, y), a = Float(p.a) / 255
            let premultiplied: [Float] = [Float(p.r), Float(p.g), Float(p.b)]
            let straight: [Float] = premultiplied.map { (v: Float) -> Float in a > 0 ? min(1, v / 255 / a) : 0 }
            let i = ((126 + y) * 320 + 32 + x) * 4
            for c in 0..<3 {
                let expected: Float = base[i + c] * (1 - a) + straight[c] * a
                worst = max(worst, abs(sdr[i + c] - expected))
            }
        } }
        XCTAssertLessThan(worst, 0.004, "GPU composite matches the bitmap blended over the game")
        XCTAssertEqual(sdr[(10 * 320 + 10) * 4], base[(10 * 320 + 10) * 4], "outside the layer")

        let l = TextRasterizer.layout(spec, string: "Live 0:42", size: CGSize(width: 192, height: 36))
        let plate = try XCTUnwrap(l.plate)
        let probe = (x: 32 + Int(plate.minX + plate.height / 2), y: 126 + Int(plate.minY + 1))  // padding band above the glyphs
        let colour = Composition(layers: [Layer(source: .game), Layer(source: LayerSource(type: "color", color: spec.plate), frame: frame)])
        for transfer: Int32 in [0, 1] {
            let pq = S.renderScene(comp, canvas: canvas, transfer: transfer, cache: cache, assets: [], tokens: tokens).pixels
            let ref = S.renderScene(colour, canvas: canvas, transfer: transfer, cache: cache, assets: []).pixels
            let i = (probe.y * 320 + probe.x) * 4
            for c in 0..<3 { XCTAssertEqual(pq[i + c], ref[i + c], accuracy: 0.004, "plate in transfer \(transfer), channel \(c)") }
        }
    }

    // MARK: Cache behaviour

    /// A `{timer}` layer re-rasterizes when the second changes, but keeps showing the previous texture meanwhile, so
    /// it never blinks; an unchanged layer is never rasterized twice.
    func testTokenLayerUpdatesWithoutBlinking() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let layer = Layer(source: LayerSource(type: "text", text: TextSpec(string: "{timer}")), frame: NRect(x: 0, y: 0, w: 0.5, h: 0.2))
        let comp = Composition(layers: [layer]), canvas = CGSize(width: 640, height: 360)
        XCTAssertNil(cache.overlays(for: comp, canvas: canvas, assets: [], tokens: OverlayTokens(elapsed: 1)).textures[.layer(layer.id)])
        cache.drain()
        guard case let .rgba(first)? = cache.overlays(for: comp, canvas: canvas, assets: [], tokens: OverlayTokens(elapsed: 1.5)).textures[.layer(layer.id)]
        else { return XCTFail("ready after the queue ran") }
        XCTAssertEqual(first.width, 320); XCTAssertEqual(first.height, 72)
        guard case let .rgba(stale)? = cache.overlays(for: comp, canvas: canvas, assets: [], tokens: OverlayTokens(elapsed: 2)).textures[.layer(layer.id)]
        else { return XCTFail("previous texture while the new second rasterizes") }
        XCTAssertTrue(stale === first)
        cache.drain()
        guard case let .rgba(next)? = cache.overlays(for: comp, canvas: canvas, assets: [], tokens: OverlayTokens(elapsed: 2)).textures[.layer(layer.id)]
        else { return XCTFail() }
        XCTAssertFalse(next === first)
        XCTAssertEqual(cache.rasterCount, 2)
    }
}
