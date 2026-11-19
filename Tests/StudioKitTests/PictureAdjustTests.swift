import XCTest
import AVFoundation
import Metal
@testable import StudioKit

final class PictureAdjustTests: XCTestCase {
    typealias V = SIMD3<Double>
    private var suite: String!
    private var store: UserDefaults!
    private var savedGrades = PictureGrades()
    override func setUp() {
        suite = "ehdr.tests.picture.\(UUID().uuidString)"; store = UserDefaults(suiteName: suite)!
        // Renders that omit `grades:` read the in-process cache: keep it neutral here, whatever the test host stores.
        savedGrades = PictureAdjust.current; PictureAdjust.current = PictureGrades()
    }
    override func tearDown() { store.removePersistentDomain(forName: suite); PictureAdjust.current = savedGrades }

    // MARK: - Model

    func testDefaultsAreNeutral() {
        XCTAssertTrue(PictureGrade().isNeutral)
        XCTAssertEqual(PictureAdjust.read(store), PictureGrades())
        XCTAssertTrue(PictureAdjust(store: store).grades.isNeutral)
        XCTAssertFalse(PictureGrade(exposure: 0.1).isNeutral)
        XCTAssertFalse(PictureGrade(saturation: 99).isNeutral)
    }

    func testClamping() {
        let g = PictureGrade(exposure: 5, contrast: -300, highlights: 101, shadows: -101, saturation: 250, temperature: 1e9, tint: -1e9).clamped()
        XCTAssertEqual(g, PictureGrade(exposure: 2, contrast: -100, highlights: 100, shadows: -100, saturation: 200, temperature: 100, tint: -100))
        XCTAssertEqual(PictureGrade(saturation: -5).clamped().saturation, 0)
        let bad = PictureGrade(exposure: .nan, contrast: .infinity, highlights: -.infinity, shadows: .nan, saturation: .nan, temperature: .nan, tint: .nan)
        XCTAssertEqual(bad.clamped(), PictureGrade())

        let a = PictureAdjust(store: store)
        a.set(.game, PictureGrade(exposure: 9, saturation: .nan))
        XCTAssertEqual(a.grade(.game), PictureGrade(exposure: 2))
        XCTAssertEqual(PictureAdjust.read(store).game, PictureGrade(exposure: 2))
        XCTAssertTrue(a.grade(.camera).isNeutral)
    }

    func testRoundTripAndReset() throws {
        let g = PictureGrade(exposure: -1.3, contrast: 20, highlights: -45, shadows: 60, saturation: 130, temperature: 15, tint: -8)
        XCTAssertEqual(try JSONDecoder().decode(PictureGrade.self, from: JSONEncoder().encode(g)), g)
        let a = PictureAdjust(store: store)
        a.set(.camera, g)
        XCTAssertEqual(PictureAdjust(store: store).grade(.camera), g)
        XCTAssertNotNil(store.data(forKey: "pictureGradeCamera")); XCTAssertNil(store.object(forKey: "pictureGradeGame"))
        a.reset(.camera)
        XCTAssertTrue(a.grade(.camera).isNeutral); XCTAssertTrue(PictureAdjust.read(store).camera.isNeutral)
    }

    func testLenientDecode() {
        func stored(_ json: String) -> PictureGrade {
            store.set(Data(json.utf8), forKey: "pictureGradeGame")
            return PictureAdjust.read(store).game
        }
        XCTAssertEqual(stored(#"{"exposure": 1.5}"#), PictureGrade(exposure: 1.5))                           // missing fields
        XCTAssertEqual(stored(#"{"contrast": "lots", "tint": 12, "future": true}"#), PictureGrade(tint: 12))   // unreadable field
        XCTAssertEqual(stored(#"{"exposure": 7, "saturation": -40, "shadows": 1e300}"#), PictureGrade(exposure: 2, shadows: 100, saturation: 0))
        XCTAssertEqual(stored(#"{"exposure": NaN}"#), PictureGrade())                                         // not JSON
        XCTAssertEqual(stored("garbage"), PictureGrade())
        store.set("warm", forKey: "pictureGradeGame"); XCTAssertEqual(PictureAdjust.read(store).game, PictureGrade())
        store.set(3, forKey: "pictureGradeGame"); XCTAssertEqual(PictureAdjust.read(store).game, PictureGrade())
        store.removeObject(forKey: "pictureGradeGame"); XCTAssertEqual(PictureAdjust.read(store).game, PictureGrade())
    }

    func testPrivateStoreDoesNotPublish() {
        let before = PictureAdjust.current
        let a = PictureAdjust(store: store)
        a.set(.game, PictureGrade(exposure: 1)); a.set(.camera, PictureGrade(tint: 50))
        XCTAssertEqual(PictureAdjust.current, before)
    }

    func testUniforms() {
        let n = PictureGrade().uniforms
        XCTAssertEqual(n.gain, SIMD4<Float>(1, 1, 1, 1)); XCTAssertEqual(n.tone, SIMD4<Float>(0, 0, 1, 0))
        // White balance keeps a neutral grey's luminance; exposure scales it.
        for (t, tint) in [(100.0, 0.0), (-100, 0), (0, 100), (0, -100), (60, -40)] {
            let u = PictureGrade(exposure: 1, temperature: t, tint: tint).uniforms
            let luma = 0.2627 * Double(u.gain.x) + 0.6780 * Double(u.gain.y) + 0.0593 * Double(u.gain.z)
            XCTAssertEqual(luma, 2, accuracy: 1e-5)
            XCTAssertEqual(u.tone.w, 1)
        }
        let warm = PictureGrade(temperature: 50).uniforms.gain
        XCTAssertGreaterThan(warm.x, warm.z)
        let u = PictureGrade(contrast: 100, highlights: -100, shadows: 50, saturation: 0).uniforms
        XCTAssertEqual(u.gain.w, 1.5, accuracy: 1e-6); XCTAssertEqual(u.tone.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(u.tone.y, -1.5, accuracy: 1e-6); XCTAssertEqual(u.tone.z, 0)
        XCTAssertEqual(PictureGrade(contrast: -100).uniforms.gain.w, 1 / 1.5, accuracy: 1e-6)
    }

    func testUniformLayoutMatchesShader() {
        // Metal `LayerU`: nine float4/int4 fields before the grade, then two more.
        XCTAssertEqual(MemoryLayout<LayerParams>.offset(of: \LayerParams.gradeGain), 144)
        XCTAssertEqual(MemoryLayout<LayerParams>.offset(of: \LayerParams.gradeTone), 160)
        XCTAssertEqual(MemoryLayout<LayerParams>.stride, 176)
    }

    // MARK: - GPU helpers

    private var core: MetalCore { MetalCore.shared }
    private func requireMetal() throws { guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") } }

    private func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ bytes: UnsafeRawPointer?, _ row: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .renderTarget]
        let t = core.device.makeTexture(descriptor: d)!
        if let b = bytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: b, bytesPerRow: row) }
        return t
    }

    enum Source { case pq, sdr }
    /// A 4x4 video frame of one colour, given as SDR BT.709 code values (gamma 2.4). The PQ frame carries the same
    /// light (SDR white at 203 nits) in BT.2020, 10-bit; the SDR frame is the camera's 8-bit BT.709.
    private func patch(_ code: V, _ source: Source, width: Int = 4, ramp: ((Int) -> V)? = nil) -> LayerTextures.Kind {
        let w = width, h = 2
        func colour(_ x: Int) -> V { ramp?(x) ?? code }
        switch source {
        case .pq:
            var y = [UInt16](repeating: 0, count: w * h), c = [UInt16](repeating: 0, count: w)
            func enc(_ x: Int) -> (Double, Double, Double) {
                let l = ToneMirror.m709to2020(V(pow(colour(x).x, 2.4), pow(colour(x).y, 2.4), pow(colour(x).z, 2.4))) * 0.0203
                let e = V(ToneMirror.linearToPq(l.x), ToneMirror.linearToPq(l.y), ToneMirror.linearToPq(l.z))
                let Y: Double = 0.2627 * e.x + 0.6780 * e.y + 0.0593 * e.z
                return (Y, (e.z - Y) / 1.8814, (e.x - Y) / 1.4746)
            }
            for x in 0..<w { let (Y, _, _) = enc(x); for r in 0..<h { y[r * w + x] = UInt16((64 + 876 * Y).rounded()) << 6 } }
            for x in 0..<(w / 2) {
                let (_, cb, cr) = enc(x * 2)
                c[x * 2] = UInt16((512 + 896 * cb).rounded()) << 6; c[x * 2 + 1] = UInt16((512 + 896 * cr).rounded()) << 6
            }
            let yT = y.withUnsafeBytes { texture(.r16Unorm, w, h, $0.baseAddress, w * 2) }
            let cT = c.withUnsafeBytes { texture(.rg16Unorm, w / 2, 1, $0.baseAddress, w * 2) }
            return .biplanar(y: yT, c: cT, bits: 10, transfer: 0, bt709: false)
        case .sdr:
            var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w)
            func enc(_ x: Int) -> (Double, Double, Double) {
                let e = colour(x)
                let Y: Double = 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z
                return (Y, (e.z - Y) / 1.8556, (e.x - Y) / 1.5748)
            }
            for x in 0..<w { let (Y, _, _) = enc(x); for r in 0..<h { y[r * w + x] = UInt8((16 + 219 * Y).rounded()) } }
            for x in 0..<(w / 2) {
                let (_, cb, cr) = enc(x * 2)
                c[x * 2] = UInt8((128 + 224 * cb).rounded()); c[x * 2 + 1] = UInt8((128 + 224 * cr).rounded())
            }
            let yT = y.withUnsafeBytes { texture(.r8Unorm, w, h, $0.baseAddress, w) }
            let cT = c.withUnsafeBytes { texture(.rg8Unorm, w / 2, 1, $0.baseAddress, w) }
            return .biplanar(y: yT, c: cT, bits: 8, transfer: 2, bt709: true)
        }
    }

    private func layer(_ key: SourceKey, _ rect: CGRect) -> ResolvedLayer {
        ResolvedLayer(key: key, dst: rect, src: CGRect(x: 0, y: 0, width: 1, height: 1),
                      radius: 0, border: 0, shadow: 0, opacity: 1, mirror: false, color: nil, hardEdge: true)
    }

    /// Draws `layers` on a `size` canvas; returns the target's raw bytes. `grades` nil omits the parameter.
    private func render(_ layers: [DrawLayer], size: CGSize, out: Int32, grades: PictureGrades?, format: MTLPixelFormat = .rgba16Float) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height), bpp = format == .rgba16Float ? 8 : 4
        let target = texture(format, w, h, nil, 0)
        let cb = core.queue.makeCommandBuffer()!
        if let g = grades {
            core.encodeLayers(cb, target: target, canvas: size, background: SIMD4(0, 0, 0, 1), outTransfer: out, sdrWhiteNits: 203, grades: g, layers: layers)
        } else {
            core.encodeLayers(cb, target: target, canvas: size, background: SIMD4(0, 0, 0, 1), outTransfer: out, sdrWhiteNits: 203, layers: layers)
        }
        cb.commit(); cb.waitUntilCompleted()
        var raw = [UInt8](repeating: 0, count: w * h * bpp)
        raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w * bpp, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        return raw
    }
    private func halfs(_ raw: [UInt8]) -> [Float] {
        raw.withUnsafeBytes { b in b.bindMemory(to: UInt16.self).map { Float(Float16(bitPattern: $0)) } }
    }

    /// The output-encoded colour of a uniform game patch.
    private func encoded(_ code: V, _ source: Source, out: Int32, _ grade: PictureGrade) -> V {
        let size = CGSize(width: 4, height: 2), key: SourceKey = source == .pq ? .game : .camera
        let g = source == .pq ? PictureGrades(game: grade) : PictureGrades(camera: grade)
        let px = halfs(render([DrawLayer(resolved: layer(key, CGRect(origin: .zero, size: size)), textures: patch(code, source))], size: size, out: out, grades: g))
        let i = (0 * 4 + 1) * 4
        return V(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }
    /// Linear light of an output colour: BT.709 relative to SDR white for SDR output, BT.2020 nits/10000 for PQ.
    private func linear(_ e: V, out: Int32) -> V {
        out == 2 ? V(pow(e.x, 2.4), pow(e.y, 2.4), pow(e.z, 2.4)) : V(ToneMirror.pqToLinear(e.x), ToneMirror.pqToLinear(e.y), ToneMirror.pqToLinear(e.z))
    }
    private func luma(_ l: V, out: Int32) -> Double {
        out == 2 ? 0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z : 0.2627 * l.x + 0.6780 * l.y + 0.0593 * l.z
    }

    /// PQ game into SDR and into PQ output, and the SDR camera into SDR output (the stream).
    private let paths: [(Source, Int32, String)] = [(.pq, 2, "PQ->SDR"), (.pq, 0, "PQ->PQ"), (.sdr, 2, "SDR->SDR")]
    private let grey = V(0.46, 0.46, 0.46), colour = V(0.75, 0.45, 0.25)
    private let dark = V(0.2, 0.2, 0.2), bright = V(0.85, 0.85, 0.85), darkColour = V(0.25, 0.15, 0.1), brightColour = V(0.9, 0.75, 0.6)

    // MARK: - Neutral

    func testNeutralRendersAreByteIdentical() throws {
        try requireMetal()
        let size = CGSize(width: 16, height: 8)
        for (source, out, name) in paths {
            let key: SourceKey = source == .pq ? .game : .camera
            let layers = [DrawLayer(resolved: layer(key, CGRect(x: 2, y: 1, width: 12, height: 6)), textures: patch(colour, source, width: 16, ramp: { x in V(Double(x) / 15, 0.5, 1 - Double(x) / 15) }))]
            let plain = render(layers, size: size, out: out, grades: nil)
            XCTAssertEqual(render(layers, size: size, out: out, grades: PictureGrades()), plain, name)
            XCTAssertEqual(render(layers, size: size, out: out, grades: nil, format: .rgba8Unorm), render(layers, size: size, out: out, grades: PictureGrades(), format: .rgba8Unorm), name)
        }
        // The neutral output is still the ungraded conversion (`convert`), as the Swift mirror computes it.
        let e = encoded(grey, .pq, out: 2, PictureGrade())
        let l = ToneMirror.m709to2020(V(repeating: pow(0.46, 2.4))) * 0.0203
        XCTAssertEqual(e.x, ToneMirror.linearToSdr(l, sdrWhite: 203).x, accuracy: 1.5 / 255)
        XCTAssertEqual(encoded(grey, .sdr, out: 2, PictureGrade()).x, 0.46, accuracy: 1 / 255)
    }

    // MARK: - Direction

    func testExposure() throws {
        try requireMetal()
        for (source, out, name) in paths { for c in [grey, colour] {
            let base = luma(linear(encoded(c, source, out: out, PictureGrade()), out: out), out: out)
            let up = luma(linear(encoded(c, source, out: out, PictureGrade(exposure: 1)), out: out), out: out)
            let down = luma(linear(encoded(c, source, out: out, PictureGrade(exposure: -1)), out: out), out: out)
            XCTAssertGreaterThan(up, base * 1.3, "\(name) \(c)"); XCTAssertLessThan(down, base * 0.7, "\(name) \(c)")
        } }
        // PQ to PQ has no roll-off: +1 EV is exactly twice the light.
        let base = luma(linear(encoded(grey, .pq, out: 0, PictureGrade()), out: 0), out: 0)
        let up = luma(linear(encoded(grey, .pq, out: 0, PictureGrade(exposure: 1)), out: 0), out: 0)
        XCTAssertEqual(up / base, 2, accuracy: 0.02)
    }

    private func ratio(_ c: V, _ source: Source, _ out: Int32, _ g: PictureGrade) -> Double {
        luma(linear(encoded(c, source, out: out, g), out: out), out: out) / luma(linear(encoded(c, source, out: out, PictureGrade()), out: out), out: out)
    }

    func testContrastShadowsHighlights() throws {
        try requireMetal()
        for (source, out, name) in paths {
            for (d, b) in [(dark, bright), (darkColour, brightColour)] {
                let msg = "\(name) \(d) / \(b)"
                XCTAssertLessThan(ratio(d, source, out, PictureGrade(contrast: 60)), 0.95, msg)
                XCTAssertGreaterThan(ratio(b, source, out, PictureGrade(contrast: 60)), 1.03, msg)
                let sd = ratio(d, source, out, PictureGrade(shadows: 80)), sb = ratio(b, source, out, PictureGrade(shadows: 80))
                XCTAssertGreaterThan(sd, 1.3, msg); XCTAssertGreaterThan(log(sd), 2 * log(max(sb, 1)), msg)
                let hd = ratio(d, source, out, PictureGrade(highlights: -80)), hb = ratio(b, source, out, PictureGrade(highlights: -80))
                XCTAssertLessThan(hb, 0.8, msg); XCTAssertLessThan(log(hb), 2 * log(min(hd, 1)), msg)
            }
        }
        // The pivot, 18% of SDR white, does not move with contrast (PQ output, no roll-off).
        let pivot = V(repeating: pow(0.18, 1 / 2.4))
        for k in [-100.0, 100] { XCTAssertEqual(ratio(pivot, .pq, 0, PictureGrade(contrast: k)), 1, accuracy: 0.03) }
    }

    func testSaturationTemperatureTint() throws {
        try requireMetal()
        let step = [Int32(2): 1.0 / 255, 0: 1.0 / 1023]
        func chroma(_ e: V) -> Double { max(e.x, max(e.y, e.z)) - min(e.x, min(e.y, e.z)) }
        for (source, out, name) in paths {
            for c in [grey, colour] {
                let msg = "\(name) \(c)"
                let mono = encoded(c, source, out: out, PictureGrade(saturation: 0))
                XCTAssertEqual(mono.x, mono.y, accuracy: step[out]!, msg); XCTAssertEqual(mono.y, mono.z, accuracy: step[out]!, msg)
                let n = linear(encoded(c, source, out: out, PictureGrade()), out: out)
                let warm = linear(encoded(c, source, out: out, PictureGrade(temperature: 60)), out: out)
                XCTAssertGreaterThan(warm.x / warm.z, n.x / n.z * 1.1, msg)
                let magenta = linear(encoded(c, source, out: out, PictureGrade(tint: 60)), out: out)
                XCTAssertLessThan(magenta.y / (magenta.x + magenta.z), n.y / (n.x + n.z) * 0.95, msg)
            }
            XCTAssertGreaterThan(chroma(encoded(colour, source, out: out, PictureGrade(saturation: 200))),
                                 chroma(encoded(colour, source, out: out, PictureGrade())) * 1.2, name)
        }
    }

    // MARK: - Continuity and monotonicity

    func testNearlyNeutralIsContinuousForSdrToSdr() throws {
        try requireMetal()
        let size = CGSize(width: 4, height: 2)
        for c in [V(0.9, 0.9, 0.9), V(0.9, 0.8, 0.7), V(0.95, 0.2, 0.9)] {
            let layers = [DrawLayer(resolved: layer(.camera, CGRect(origin: .zero, size: size)), textures: patch(c, .sdr))]
            let a = render(layers, size: size, out: 2, grades: PictureGrades(), format: .rgba8Unorm)
            let b = render(layers, size: size, out: 2, grades: PictureGrades(camera: PictureGrade(exposure: 0.01)), format: .rgba8Unorm)
            let diff = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(diff, 1, "\(c)")
        }
    }

    func testGreyRampStaysMonotonic() throws {
        try requireMetal()
        let size = CGSize(width: 64, height: 2)
        for (source, out, name) in paths {
            let key: SourceKey = source == .pq ? .game : .camera
            let ramp = patch(grey, source, width: 64, ramp: { x in V(repeating: Double(x) / 63) })
            for (s, h, k) in [(100.0, 100.0, 100.0), (100, -100, 100), (-100, 100, 100), (-100, -100, 100),
                              (100, 100, -100), (100, -100, -100), (-100, 100, -100), (-100, -100, -100)] {
                let g = PictureGrade(contrast: k, highlights: h, shadows: s)
                let grades = source == .pq ? PictureGrades(game: g) : PictureGrades(camera: g)
                let px = halfs(render([DrawLayer(resolved: layer(key, CGRect(origin: .zero, size: size)), textures: ramp)], size: size, out: out, grades: grades))
                var last: Float = -1
                for x in 0..<64 {
                    let v = px[x * 4 + 1]
                    XCTAssertGreaterThanOrEqual(v, last, "\(name) shadows \(s) highlights \(h) contrast \(k) at \(x)")
                    last = v
                }
            }
        }
    }

    // MARK: - Scope

    func testOnlyVideoLayersOfTheirSourceAreGraded() throws {
        try requireMetal()
        let size = CGSize(width: 32, height: 16)
        let px = [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map { i, _ in UInt8(i % 4 == 3 ? 255 : (i * 37) % 200) }
        let image = px.withUnsafeBytes { texture(.rgba8Unorm, 8, 8, $0.baseAddress, 32) }
        var colourLayer = layer(.layer(UUID()), CGRect(x: 8, y: 0, width: 8, height: 8)); colourLayer.color = SIMD4(0.8, 0.3, 0.2, 1)
        let gameRect = CGRect(x: 0, y: 0, width: 8, height: 8)
        for out: Int32 in [2, 0] {
            let layers = [
                DrawLayer(resolved: layer(.game, gameRect), textures: patch(colour, .pq)),
                DrawLayer(resolved: colourLayer, textures: .none),
                DrawLayer(resolved: layer(.layer(UUID()), CGRect(x: 16, y: 0, width: 8, height: 8)), textures: .rgba(image)),
                DrawLayer(resolved: layer(.camera, CGRect(x: 24, y: 0, width: 8, height: 8)), textures: patch(colour, .sdr)),
            ]
            let strong = PictureGrades(game: PictureGrade(exposure: 1.5, contrast: 80, highlights: -60, shadows: 70, saturation: 30, temperature: 80, tint: -50))
            let a = halfs(render(layers, size: size, out: out, grades: PictureGrades()))
            let b = halfs(render(layers, size: size, out: out, grades: strong))
            var gameChanged = false
            for y in 0..<16 { for x in 0..<32 { for c in 0..<4 {
                let i = (y * 32 + x) * 4 + c
                if gameRect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { gameChanged = gameChanged || a[i] != b[i] }
                else { XCTAssertEqual(a[i], b[i], "out \(out) at \(x),\(y)") }
            } } }
            XCTAssertTrue(gameChanged)
        }
    }

    // MARK: - Cost

    /// GPU time of one 2560x1440 PQ game layer into the 10-bit window format, neutral and graded:
    /// `EHDR_MEASURE_GRADE=1 swift test --filter PictureAdjustTests/testGradeCost`.
    func testGradeCost() throws {
        try requireMetal()
        guard ProcessInfo.processInfo.environment["EHDR_MEASURE_GRADE"] != nil else { throw XCTSkip("Set EHDR_MEASURE_GRADE=1 to measure") }
        let w = 2560, h = 1440, size = CGSize(width: w, height: h)
        let y = (0..<(w * h)).map { (i: Int) -> UInt16 in UInt16(64 + (i % w) * 876 / w) << 6 }
        let c = (0..<(w * h / 2)).map { (i: Int) -> UInt16 in UInt16(400 + (i % 97) * 2) << 6 }
        let yT = y.withUnsafeBytes { texture(.r16Unorm, w, h, $0.baseAddress, w * 2) }
        let cT = c.withUnsafeBytes { texture(.rg16Unorm, w / 2, h / 2, $0.baseAddress, w * 2) }
        let target = texture(.rgb10a2Unorm, w, h, nil, 0)
        let layers = [DrawLayer(resolved: layer(.game, CGRect(origin: .zero, size: size)), textures: .biplanar(y: yT, c: cT, bits: 10, transfer: 0, bt709: false))]
        let strong = PictureGrades(game: PictureGrade(exposure: 0.6, contrast: 25, highlights: -40, shadows: 35, saturation: 140, temperature: 30, tint: 10))
        func median(_ g: PictureGrades, out: Int32) -> Double {
            var times: [Double] = []
            for _ in 0..<120 {
                let cb = core.queue.makeCommandBuffer()!
                core.encodeLayers(cb, target: target, canvas: size, background: SIMD4(0, 0, 0, 1), outTransfer: out, sdrWhiteNits: 150, grades: g, layers: layers)
                cb.commit(); cb.waitUntilCompleted()
                times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return times.sorted()[times.count / 2]
        }
        for out: Int32 in [0, 2] {
            _ = median(PictureGrades(), out: out)   // warm up
            let n = median(PictureGrades(), out: out), g = median(strong, out: out)
            print(String(format: "GRADECOST out=%d neutral %.3f ms graded %.3f ms (+%.3f)", out, n, g, g - n))
        }
    }

    // MARK: - Export fixity

    func testExportKeepsTheGradesItStartedWith() async throws {
        try requireMetal()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PictureAdjust-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["game", "camera"] {
            let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/migration-media"))
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name + ".mov"))
        }
        let doc = ProjectDoc(dir: dir, project: Project(name: "Grades", createdAt: Date()))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        doc.project = try decoder.decode(Project.self, from: Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "minimal", withExtension: "json", subdirectory: "Fixtures"))))
        let size = Canvas.wide.size(.hd)
        let built = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr)
        func codes(_ video: AVVideoComposition) throws -> [Double] { RawCompositionFrames.codes(try RawCompositionFrames.frame(built.asset, video: video, ms: 0, hdr: false)) }

        let strong = PictureGrades(game: PictureGrade(exposure: 1, saturation: 0), camera: PictureGrade(temperature: 80))
        let neutral = try codes(CompositionBuilder.videoComposition(doc.project, canvas: .wide, size: size, built: built))
        let export = CompositionBuilder.videoComposition(doc.project, canvas: .wide, size: size, built: built)
        let preview = CompositionBuilder.videoComposition(doc.project, canvas: .wide, size: size, built: built, waitForOverlays: false)
        XCTAssertEqual((export.instructions.first as? CompositionInstruction)?.grades, PictureGrades())
        XCTAssertNil((preview.instructions.first as? CompositionInstruction)?.grades)
        PictureAdjust.current = strong
        XCTAssertEqual(try codes(export), neutral, "an export started before the change keeps its grades")
        XCTAssertNotEqual(try codes(preview), neutral, "the preview follows the live setting")
        XCTAssertEqual(try codes(CompositionBuilder.videoComposition(doc.project, canvas: .wide, size: size, built: built)), try codes(preview))
    }
}
