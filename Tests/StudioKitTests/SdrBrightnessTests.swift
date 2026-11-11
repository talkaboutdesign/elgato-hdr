import XCTest
import Metal
@testable import StudioKit

/// Pure Swift mirror of the compositor's HDR -> SDR maths (`linearToSdr` and friends in `MetalCore.swift`).
/// Linear light is BT.2020, 1.0 = 10000 nits.
enum ToneMirror {
    typealias V = SIMD3<Double>
    static func pqToLinear(_ e: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(e, 1 / m2)
        return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }
    static func linearToPq(_ l: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(min(max(l, 0), 1), m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }
    /// Columns as the Metal `float3x3` literal lists them.
    static func m2020to709(_ v: V) -> V {
        let a = V(1.6605, -0.1246, -0.0182) * v.x
        let b = V(-0.5876, 1.1329, -0.1006) * v.y
        let c = V(-0.0728, -0.0083, 1.1187) * v.z
        return a + b + c
    }
    static func m709to2020(_ v: V) -> V {
        let a = V(0.6274, 0.0691, 0.0164) * v.x
        let b = V(0.3293, 0.9195, 0.0880) * v.y
        let c = V(0.0433, 0.0114, 0.8956) * v.z
        return a + b + c
    }
    static func sdrToLinear(_ e: V) -> V { m709to2020(V(pow(e.x, 2.4), pow(e.y, 2.4), pow(e.z, 2.4))) * 0.0203 }

    /// The shader's curve for a given SDR white.
    static func linearToSdr(_ l: V, sdrWhite: Double) -> V {
        let g: Double = 203 / sdrWhite
        var c = m2020to709(l * g / 0.0203)
        c = V(max(c.x, 0), max(c.y, 0), max(c.z, 0))
        let m = max(c.x, max(c.y, c.z))
        let k = 0.7, w: Double = 1000 / sdrWhite
        let a: Double = (1 - k) / (w - 1)
        if m > k {
            let x = min((m - k) / (w - k), 1)
            let y: Double = k + (1 - k) * x * (1 + a) / (x + a)
            c *= y / m
        }
        return encode(c)
    }
    /// The curve as it was before the setting existed (fixed 203-nit white), for comparison.
    static func formerLinearToSdr(_ l: V) -> V {
        var c = m2020to709(l / 0.0203)
        c = V(max(c.x, 0), max(c.y, 0), max(c.z, 0))
        let m = max(c.x, max(c.y, c.z))
        let k = 0.7, w: Double = 1000.0 / 203.0
        let a: Double = (1 - k) / (w - 1)
        if m > k {
            let x = min((m - k) / (w - k), 1)
            let y: Double = k + (1 - k) * x * (1 + a) / (x + a)
            c *= y / m
        }
        return encode(c)
    }
    static func encode(_ c: V) -> V {
        func f(_ v: Double) -> Double { pow(min(max(v, 0), 1), 1 / 2.4) }
        return V(f(c.x), f(c.y), f(c.z))
    }
    /// A neutral grey of `nits` in linear BT.2020.
    static func grey(_ nits: Double) -> V { V(repeating: nits / 10000) }
    /// SDR output for an HDR source (from != SDR) or an SDR source (identity: `convert` returns early).
    static func convert(_ e: V, fromSDR: Bool, sdrWhite: Double) -> V {
        fromSDR ? e : linearToSdr(V(pqToLinear(e.x), pqToLinear(e.y), pqToLinear(e.z)), sdrWhite: sdrWhite)
    }
}

final class SdrBrightnessTests: XCTestCase {
    private var suite: String!
    private var store: UserDefaults!
    override func setUp() { suite = "ehdr.tests.sdr.\(UUID().uuidString)"; store = UserDefaults(suiteName: suite)! }
    override func tearDown() { store.removePersistentDomain(forName: suite) }

    func testDefaultAndClamping() {
        XCTAssertEqual(SdrBrightness.read(store), 150)
        store.set(40, forKey: SdrBrightness.key); XCTAssertEqual(SdrBrightness.read(store), 80)
        store.set(900.0, forKey: SdrBrightness.key); XCTAssertEqual(SdrBrightness.read(store), 300)
        store.set("bright", forKey: SdrBrightness.key); XCTAssertEqual(SdrBrightness.read(store), 150)
        store.set(Float.nan, forKey: SdrBrightness.key); XCTAssertEqual(SdrBrightness.read(store), 150)
        store.set(203, forKey: SdrBrightness.key); XCTAssertEqual(SdrBrightness.read(store), 203)

        let s = SdrBrightness(store: store)
        XCTAssertEqual(s.nits, 203)
        s.nits = 10; XCTAssertEqual(s.nits, 80); XCTAssertEqual(store.float(forKey: SdrBrightness.key), 80)
        s.nits = 1000; XCTAssertEqual(s.nits, 300)
        // A private store never feeds the renderers' cached value.
        XCTAssertEqual(SdrBrightness.current, SdrBrightness.shared.nits)
    }

    func testPercentScale() {
        XCTAssertEqual(SdrBrightness.percent(nits: 150), 100, accuracy: 1e-9)
        XCTAssertEqual(SdrBrightness.percentRange.lowerBound, 50, accuracy: 1e-9)
        XCTAssertEqual(SdrBrightness.percentRange.upperBound, 187.5, accuracy: 1e-9)
        let s = SdrBrightness(store: store)
        s.percent = 200; XCTAssertEqual(s.nits, 80)
        s.percent = 100; XCTAssertEqual(s.nits, 150)
        s.percent = 75; XCTAssertEqual(s.nits, 200)
    }

    func testSdrSourcesIgnoreTheSetting() {
        for e in [0.0, 0.18, 0.5, 0.9, 1.0] {
            let v = SIMD3<Double>(e, e * 0.5, 1 - e)
            for w in [80.0, 150, 203, 300] { XCTAssertEqual(ToneMirror.convert(v, fromSDR: true, sdrWhite: w), v) }
        }
    }

    func testBelowKneeScalesLinearly() {
        // At 150, a 150-nit grey is SDR white (code 1.0) before the roll-off; with the roll-off it lands at the knee's
        // compressed value. Below the knee every value is the former linear value times 203/150.
        let g = 203.0 / 150.0
        for nits in stride(from: 1.0, through: 100, by: 3) {     // 100 nits · 203/150 / 150 < 0.7 knee
            let new = ToneMirror.linearToSdr(ToneMirror.grey(nits), sdrWhite: 150).x
            let old = ToneMirror.formerLinearToSdr(ToneMirror.grey(nits)).x
            XCTAssertEqual(pow(new, 2.4), pow(old, 2.4) * g, accuracy: 1e-9, "\(nits) nits")
        }
        // 0.7 · 150 = 105 nits is the knee: still exactly linear there, 0.7 in linear SDR.
        XCTAssertEqual(pow(ToneMirror.linearToSdr(ToneMirror.grey(105), sdrWhite: 150).x, 2.4), 0.7, accuracy: 1e-3)
        // Without the roll-off (knee above the value) 150 nits would be exactly 1.0; with it it stays just below.
        let white = ToneMirror.linearToSdr(ToneMirror.grey(150), sdrWhite: 150).x
        XCTAssertGreaterThan(white, 0.9); XCTAssertLessThan(white, 1.0)
    }

    func testMonotonicBoundedAndPeak() {
        for w in [80.0, 150, 203, 300] {
            var last = -1.0
            for i in 0...2000 {
                let nits = Double(i) * 0.6
                let v = ToneMirror.linearToSdr(ToneMirror.grey(nits), sdrWhite: w).x
                XCTAssertLessThanOrEqual(v, 1.0); XCTAssertGreaterThanOrEqual(v, last - 1e-12, "\(w) at \(nits)"); last = v
            }
            XCTAssertEqual(ToneMirror.linearToSdr(ToneMirror.grey(1000), sdrWhite: w).x, 1.0, accuracy: 1e-12)
            // Highlights compress rather than clip: just below the peak is still below white.
            XCTAssertLessThan(ToneMirror.linearToSdr(ToneMirror.grey(700), sdrWhite: w).x, 1.0)
        }
    }

    func testAt203MatchesFormerCurve() {
        for nits in [0.0, 0.5, 10, 50, 100, 142, 160, 203, 400, 999, 1000, 4000] {
            for tint in [SIMD3<Double>(1, 1, 1), SIMD3(1, 0.4, 0.2), SIMD3(0.1, 0.9, 0.3)] {
                let l = ToneMirror.grey(nits) * tint
                XCTAssertEqual(ToneMirror.linearToSdr(l, sdrWhite: 203), ToneMirror.formerLinearToSdr(l))
            }
        }
    }

    // MARK: - GPU

    private func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ bytes: UnsafeRawPointer?, _ row: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .renderTarget]
        let t = MetalCore.shared.device.makeTexture(descriptor: d)!
        if let b = bytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: b, bytesPerRow: row) }
        return t
    }
    private func gameLayer(_ size: CGSize) -> ResolvedLayer {
        ResolvedLayer(key: .game, dst: CGRect(origin: .zero, size: size), src: CGRect(x: 0, y: 0, width: 1, height: 1),
                      radius: 0, border: 0, shadow: 0, opacity: 1, mirror: false, color: nil, hardEdge: true)
    }
    /// A PQ BT.2020 10-bit frame of uniform grey, drawn to SDR at `sdrWhite`, read back as half float.
    private func renderGrey(nits: Double, sdrWhite: Float, transfer: Int32 = 0) -> Float {
        let code = UInt16((64 + 876 * ToneMirror.linearToPq(nits / 10000)).rounded())
        let y = [UInt16](repeating: code << 6, count: 16), c = [UInt16](repeating: 512 << 6, count: 8)
        let yT = y.withUnsafeBytes { texture(.r16Unorm, 4, 4, $0.baseAddress, 8) }
        let cT = c.withUnsafeBytes { texture(.rg16Unorm, 2, 2, $0.baseAddress, 8) }
        let target = texture(.rgba16Float, 4, 4, nil, 0)
        let size = CGSize(width: 4, height: 4)
        let cb = MetalCore.shared.queue.makeCommandBuffer()!
        MetalCore.shared.encodeLayers(cb, target: target, canvas: size, background: SIMD4(0, 0, 0, 1), outTransfer: 2, sdrWhiteNits: sdrWhite,
                                      layers: [DrawLayer(resolved: gameLayer(size), textures: .biplanar(y: yT, c: cT, bits: 10, transfer: transfer, bt709: false))])
        cb.commit(); cb.waitUntilCompleted()
        var raw = [UInt16](repeating: 0, count: 16 * 4)
        raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 4 * 8, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        return Float(Float16(bitPattern: raw[(1 * 4 + 1) * 4]))
    }

    /// The shader agrees with the Swift mirror, at the former 203 and at the new default 150.
    func testShaderMatchesMirror() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        for nits in [5.0, 40, 90, 150, 300, 800] {
            let code = (64 + 876 * ToneMirror.linearToPq(nits / 10000)).rounded()
            let actualNits = ToneMirror.pqToLinear((code - 64) / 876) * 10000
            for w in [203.0, 150] {
                let gpu = renderGrey(nits: nits, sdrWhite: Float(w))
                let ref = ToneMirror.linearToSdr(ToneMirror.grey(actualNits), sdrWhite: w).x
                XCTAssertEqual(Double(gpu), ref, accuracy: 0.5 / 255, "\(nits) nits at \(w)")
            }
        }
        // Brighter at 150 than at 203 below the peak; the peak itself still lands on white.
        XCTAssertGreaterThan(renderGrey(nits: 90, sdrWhite: 150), renderGrey(nits: 90, sdrWhite: 203) + 0.03)
        XCTAssertEqual(renderGrey(nits: 1000, sdrWhite: 150), 1, accuracy: 0.5 / 255)
        // HDR output is untouched by the setting.
        let hdr: (Float) -> Float = { w in
            let y = [UInt16](repeating: 500 << 6, count: 16), c = [UInt16](repeating: 512 << 6, count: 8)
            let yT = y.withUnsafeBytes { self.texture(.r16Unorm, 4, 4, $0.baseAddress, 8) }
            let cT = c.withUnsafeBytes { self.texture(.rg16Unorm, 2, 2, $0.baseAddress, 8) }
            let target = self.texture(.rgba16Float, 4, 4, nil, 0)
            let cb = MetalCore.shared.queue.makeCommandBuffer()!
            MetalCore.shared.encodeLayers(cb, target: target, canvas: CGSize(width: 4, height: 4), background: SIMD4(0, 0, 0, 1), outTransfer: 1, sdrWhiteNits: w,
                                          layers: [DrawLayer(resolved: self.gameLayer(CGSize(width: 4, height: 4)), textures: .biplanar(y: yT, c: cT, bits: 10, transfer: 0, bt709: false))])
            cb.commit(); cb.waitUntilCompleted()
            var raw = [UInt16](repeating: 0, count: 64)
            raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
            return Float(Float16(bitPattern: raw[20]))
        }
        XCTAssertEqual(hdr(80), hdr(300))
    }

    /// Real 2560x1440 PQ captures (not in the repository): `EHDR_P010_DIR=<dir> swift test --filter SdrBrightnessTests`
    /// reports mean luma, 99th percentile and code-255 share at 203 and 150 for each `*.p010` named in
    /// `EHDR_P010_FILES` (comma separated; default g20,slot0).
    func testRealFramesReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["EHDR_P010_DIR"] else { throw XCTSkip("Set EHDR_P010_DIR to measure real frames") }
        let w = 2560, h = 1440
        for name in (env["EHDR_P010_FILES"] ?? "g20,slot0").split(separator: ",") {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).p010"))
            XCTAssertEqual(data.count, w * h * 3)
            let (yT, cT) = data.withUnsafeBytes { b -> (MTLTexture, MTLTexture) in
                (texture(.r16Unorm, w, h, b.baseAddress!, w * 2), texture(.rg16Unorm, w / 2, h / 2, b.baseAddress! + w * h * 2, w * 2))
            }
            for white: Float in [203, 150] {
                let target = texture(.rgba8Unorm, w, h, nil, 0)
                let size = CGSize(width: w, height: h)
                let cb = MetalCore.shared.queue.makeCommandBuffer()!
                MetalCore.shared.encodeLayers(cb, target: target, canvas: size, background: SIMD4(0, 0, 0, 1), outTransfer: 2, sdrWhiteNits: white,
                                              layers: [DrawLayer(resolved: gameLayer(size), textures: .biplanar(y: yT, c: cT, bits: 10, transfer: 0, bt709: false))])
                cb.commit(); cb.waitUntilCompleted()
                var px = [UInt8](repeating: 0, count: w * h * 4)
                px.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
                var sum = 0.0, hist = [Int](repeating: 0, count: 256), anyMax = 0, allMax = 0
                for i in 0..<(w * h) {
                    let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
                    let yl: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    sum += yl; hist[min(255, Int(yl.rounded()))] += 1
                    if px[i * 4] == 255 || px[i * 4 + 1] == 255 || px[i * 4 + 2] == 255 { anyMax += 1 }
                    if px[i * 4] == 255 && px[i * 4 + 1] == 255 && px[i * 4 + 2] == 255 { allMax += 1 }
                }
                var acc = 0, p99 = 0
                for (v, n) in hist.enumerated() { acc += n; if acc >= (w * h * 99) / 100 { p99 = v; break } }
                let n = Double(w * h)
                print(String(format: "SDRCHECK %@ white=%.0f mean=%.4f p99=%.4f any255=%.5f%% all255=%.5f%%",
                             String(name), white, sum / n / 255, Double(p99) / 255, Double(anyMax) / n * 100, Double(allMax) / n * 100))
                XCTAssertLessThan(Double(p99), 255)
            }
        }
    }
}
