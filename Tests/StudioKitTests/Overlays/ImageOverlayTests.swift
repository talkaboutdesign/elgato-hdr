import Metal
import XCTest
@testable import StudioKit

final class ImageOverlayTests: XCTestCase {
    typealias S = OverlayTestSupport

    /// 32x18 straight-alpha sRGB quadrants: top-left red at alpha 128, top-right opaque dark green, bottom-left fully
    /// transparent, bottom-right blue at alpha 64.
    static let quadrants: [UInt8] = (0..<32 * 18).flatMap { i -> [UInt8] in
        let right = i % 32 >= 16, bottom = i / 32 >= 9
        switch (right, bottom) {
        case (false, false): return [255, 0, 0, 128]
        case (true, false): return [0, 64, 0, 255]
        case (false, true): return [0, 0, 0, 0]
        case (true, true): return [0, 0, 255, 64]
        }
    }

    func testImportDeduplicatesAndRefusesOtherFiles() throws {
        let dir = try S.tempDir(), store = dir.appendingPathComponent("Assets")
        let png = dir.appendingPathComponent("logo.png")
        try S.writePNG(png, width: 32, height: 18, rgba: Self.quadrants)
        let name = try AssetStore.importImage(png, into: store)
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertEqual(name.count, 16 + 4)
        XCTAssertEqual(try AssetStore.importImage(png, into: store), name, "same bytes, same file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [name])

        let txt = dir.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: txt)
        XCTAssertThrowsError(try AssetStore.importImage(txt, into: store))
    }

    func testLookupOrderAndBundling() throws {
        let dir = try S.tempDir()
        let project = dir.appendingPathComponent("Project"), support = dir.appendingPathComponent("Support")
        let png = dir.appendingPathComponent("a.png")
        try S.writePNG(png, width: 32, height: 18, rgba: Self.quadrants)
        let name = try AssetStore.importImage(png, into: support)
        let paths = AssetStore.searchPaths(project: project).dropLast() + [support]
        XCTAssertEqual(AssetStore.locate(name, in: Array(paths))?.deletingLastPathComponent().lastPathComponent, "Support")
        for bad in ["../\(name)", "/etc/hosts", ".hidden", "", "a/b.png"] { XCTAssertNil(AssetStore.locate(bad, in: Array(paths)), bad) }

        var scene = Scene(name: "S")
        scene.wide.layers = [Layer(source: LayerSource(type: "image", file: name)), Layer(source: .game)]
        scene.vertical.layers = [Layer(source: LayerSource(type: "image", file: "missing.png"))]
        let files = AssetStore.referencedFiles([scene])
        XCTAssertEqual(files, [name, "missing.png"])
        XCTAssertEqual(AssetStore.bundle(files, into: project.appendingPathComponent("Assets"), from: [support]), ["missing.png"])
        XCTAssertEqual(AssetStore.locate(name, in: Array(paths))?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Project",
                       "project Assets/ comes first")
        // The project keeps working once the application support copy is gone.
        try FileManager.default.removeItem(at: support)
        XCTAssertNotNil(AssetStore.locate(name, in: Array(paths)))
    }

    func testDecodeNeverUpscalesAndRespectsTheLimit() throws {
        let dir = try S.tempDir(), png = dir.appendingPathComponent("wide.png")
        try S.writePNG(png, width: 300, height: 100, rgba: [UInt8](repeating: 255, count: 300 * 100 * 4))
        XCTAssertEqual(OverlayImage.size(of: png), CGSize(width: 300, height: 100))
        XCTAssertEqual(OverlayImage.decode(png, maxPixel: 4096)?.size, CGSize(width: 300, height: 100))
        let small = try XCTUnwrap(OverlayImage.decode(png, maxPixel: 64))
        XCTAssertEqual(small.width, 64)
        XCTAssertEqual(small.height, 21, accuracy: 1)

        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let layer = Layer(source: LayerSource(type: "image", file: "wide.png"))
        // Drawn 100 px wide: decoded at the next power of two, 128.
        XCTAssertEqual(cache.texture(for: layer, pixelSize: CGSize(width: 100, height: 33), assets: [dir], wait: true)?.width, 128)
        XCTAssertEqual(cache.texture(for: layer, pixelSize: CGSize(width: 3000, height: 1000), assets: [dir], wait: true)?.width, 300)
    }

    /// Without `wait` the first lookup only queues the decode; the frame skips the layer and a later one has it.
    func testLookupNeverBlocksAndCaches() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let dir = try S.tempDir()
        try S.writePNG(dir.appendingPathComponent("q.png"), width: 32, height: 18, rgba: Self.quadrants)
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let layer = Layer(source: LayerSource(type: "image", file: "q.png"), frame: NRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))
        let comp = Composition(layers: [Layer(source: .game), layer])
        let canvas = CGSize(width: 128, height: 72)
        XCTAssertTrue(cache.overlays(for: comp, canvas: canvas, assets: [dir]).textures.isEmpty, "header not read yet")
        cache.drain()
        XCTAssertTrue(cache.overlays(for: comp, canvas: canvas, assets: [dir]).textures.isEmpty, "decode queued")
        cache.drain()
        let o = cache.overlays(for: comp, canvas: canvas, assets: [dir])
        XCTAssertNotNil(o.textures[.layer(layer.id)])
        XCTAssertEqual(o.sources[.layer(layer.id)]?.size, CGSize(width: 32, height: 18))
        for _ in 0..<5 { _ = cache.overlays(for: comp, canvas: canvas, assets: [dir]) }
        cache.drain()
        XCTAssertEqual(cache.rasterCount, 1)

        let missing = Composition(layers: [Layer(source: LayerSource(type: "image", file: "nope.png"))])
        XCTAssertTrue(cache.overlays(for: missing, canvas: canvas, assets: [dir], wait: true).textures.isEmpty)
    }

    /// The plan's step 1 golden: a PNG with partial alpha over the game, in PQ, HLG and SDR output, through the whole
    /// path (file, decode, cache, resolver, `encodeLayers`). Image pixels involve no fonts, so the tolerance is the
    /// compositor goldens' 0.002.
    func testPNGOverGameGolden() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let dir = try S.tempDir()
        let name = try AssetStore.importImage({ let u = dir.appendingPathComponent("in.png"); try S.writePNG(u, width: 32, height: 18, rgba: Self.quadrants); return u }(), into: dir)
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let canvas = CGSize(width: 128, height: 72)
        let comp = Composition(layers: [Layer(source: .game),
                                        Layer(name: "Logo", source: LayerSource(type: "image", file: name), frame: NRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))])
        let game = Composition(layers: [Layer(source: .game)])
        var sdr: [Float] = [], base: [Float] = []
        for transfer: Int32 in 0...2 {
            let (px, layers) = S.renderScene(comp, canvas: canvas, transfer: transfer, cache: cache, assets: [dir])
            XCTAssertEqual(layers.count, 2)
            let grid = S.grid(px, canvas: canvas)
            try S.check(grid, "overlay-image-\(transfer)")
            if transfer == 2 { sdr = grid; base = S.grid(S.renderScene(game, canvas: canvas, transfer: 2, cache: cache, assets: [dir]).pixels, canvas: canvas) }
        }
        // SDR output passes colours through, so straight-alpha blends can be checked by hand at grid points (x, y).
        // The image covers grid columns 4…11 and rows 2…6; row 4 straddles the quadrants' seam.
        func px(_ g: [Float], _ x: Int, _ y: Int) -> [Float] { Array(g[(y * 16 + x) * 4..<(y * 16 + x) * 4 + 3]) }
        func over(_ x: Int, _ y: Int, _ c: [Float], _ a: Float) -> [Float] { zip(px(base, x, y), c).map { (g: Float, v: Float) -> Float in g * (1 - a) + v * a } }
        func near(_ a: [Float], _ b: [Float], _ what: String) { for (u, v) in zip(a, b) { XCTAssertEqual(u, v, accuracy: 0.003, what) } }
        near(px(sdr, 5, 2), over(5, 2, [1, 0, 0], Float(128.0 / 255)), "red at half alpha over game")
        near(px(sdr, 10, 3), [0, Float(64.0 / 255), 0], "opaque dark green")
        near(px(sdr, 5, 6), px(base, 5, 6), "transparent quadrant shows the game")
        near(px(sdr, 10, 6), over(10, 6, [0, 0, 1], Float(64.0 / 255)), "blue at quarter alpha over game")
        near(px(sdr, 1, 1), px(base, 1, 1), "game outside the image")
    }
}
