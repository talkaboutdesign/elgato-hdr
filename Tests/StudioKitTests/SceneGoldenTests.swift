import XCTest
import Metal
@testable import StudioKit

/// Transitions rendered through the compositor, with the golden-test sources and grid of `CompositorGoldenTests`.
final class SceneGoldenTests: XCTestCase {
    static let canvas = CGSize(width: 128, height: 72)
    var recording: Bool { ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" }

    func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ data: Data, _ row: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .renderTarget]
        let t = MetalCore.shared.device.makeTexture(descriptor: d)!
        data.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: row) }
        return t
    }
    /// 64x36 10-bit game bars and 32x32 8-bit camera bars, as in `CompositorGoldenTests`.
    func textures() -> [SourceKey: LayerTextures.Kind] {
        let y10 = (0..<64*36).map { UInt16([128, 400, 700, 900][($0 % 64) / 16]) << 6 }
        let c10 = (0..<32*18*2).map { UInt16([400, 600, 512, 512][($0 / 16) % 4]) << 6 }
        let y8 = (0..<32*32).map { UInt8([32, 100, 180, 230][($0 % 32) / 8]) }
        let c8 = (0..<16*16*2).map { UInt8([90, 180, 128, 128][($0 / 8) % 4]) }
        return [.game: .biplanar(y: texture(.r16Unorm, 64, 36, y10.withUnsafeBytes { Data($0) }, 128), c: texture(.rg16Unorm, 32, 18, c10.withUnsafeBytes { Data($0) }, 128), bits: 10, transfer: 0, bt709: false),
                .camera: .biplanar(y: texture(.r8Unorm, 32, 32, Data(y8), 32), c: texture(.rg8Unorm, 16, 16, Data(c8), 32), bits: 8, transfer: 2, bt709: true)]
    }
    let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 64, height: 36)), .camera: SourceInfo(size: CGSize(width: 32, height: 32))]

    /// Renders into a 128x72 half-float target and samples a 16x9 grid of pixel centres.
    func render(_ frame: SceneFrame, _ tex: [SourceKey: LayerTextures.Kind], transfer: Int32) -> [Float] {
        let target = texture(.rgba16Float, 128, 72, Data(count: 128 * 72 * 8), 128 * 8)
        let cb = MetalCore.shared.queue.makeCommandBuffer()!
        MetalCore.shared.encodeLayers(cb, target: target, canvas: Self.canvas, background: frame.background, outTransfer: transfer, layers: DrawLayer.pair(frame.layers, tex))
        cb.commit(); cb.waitUntilCompleted()
        var raw = [UInt16](repeating: 0, count: 128 * 72 * 4)
        raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 128 * 8, from: MTLRegionMake2D(0, 0, 128, 72), mipmapLevel: 0) }
        var grid: [Float] = []
        for y in 0..<9 { for x in 0..<16 { for c in 0..<4 { grid.append(Float(Float16(bitPattern: raw[((y * 8 + 4) * 128 + x * 8 + 4) * 4 + c]))) } } }
        return grid
    }

    func check(_ grid: [Float], _ name: String) throws {
        if recording {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            try enc.encode(grid).write(to: dir.appendingPathComponent(name + ".json"))
        } else {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/golden"))
            let expected = try JSONDecoder().decode([Float].self, from: Data(contentsOf: url))
            XCTAssertEqual(grid.count, expected.count)
            for (i, pair) in zip(grid, expected).enumerated() { XCTAssertEqual(pair.0, pair.1, accuracy: 0.002, "\(name) channel \(i)") }
        }
    }

    /// Gameplay -> Camera Focus, morph at 50% progress, in PQ, HLG and SDR. Progress 0 and 1 must render exactly the
    /// two scenes, so the golden pins only the in-between picture.
    func testMorphGolden() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let c = SceneCollection.defaults(), gameplay = c.scenes[0], focus = c.scenes[2]
        let duration = 400.0, t0: UInt64 = 5_000_000_000
        var lo = 0.0, hi = duration
        for _ in 0..<60 { let m = (lo + hi) / 2; if SceneEasing.spring(m, duration: duration) < 0.5 { lo = m } else { hi = m } }
        let half = t0 + UInt64((lo * 1e6).rounded())
        let st = LiveSceneState(scene: gameplay).switching(to: focus, atNs: t0, transition: SceneTransition(style: .morph, durationMs: duration))
        XCTAssertEqual(st.progress(atNs: half), 0.5, accuracy: 1e-6)
        let tex = textures()
        func scene(_ s: Scene) -> SceneFrame { SceneFrame(background: s.wide.backgroundColor, layers: SceneResolver.resolve(s.wide, canvas: Self.canvas, sources: sources)) }
        for transfer: Int32 in 0...2 {
            let start = render(st.frame(canvas: .wide, size: Self.canvas, sources: sources, atNs: t0), tex, transfer: transfer)
            let mid = render(st.frame(canvas: .wide, size: Self.canvas, sources: sources, atNs: half), tex, transfer: transfer)
            let end = render(st.frame(canvas: .wide, size: Self.canvas, sources: sources, atNs: t0 + UInt64(duration * 1e6)), tex, transfer: transfer)
            XCTAssertEqual(start, render(scene(gameplay), tex, transfer: transfer), "progress 0 is Gameplay")
            XCTAssertEqual(end, render(scene(focus), tex, transfer: transfer), "progress 1 is Camera Focus")
            XCTAssertNotEqual(mid, start); XCTAssertNotEqual(mid, end)
            try check(mid, "morph-gameplay-focus-50-\(transfer)")
        }
    }
}
