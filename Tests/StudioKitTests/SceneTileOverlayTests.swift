import XCTest
@testable import StudioKit

/// The editor's scene tiles draw image and text layers with their real content (not a box), without waiting: a box
/// until the texture is ready, then a redraw.
final class SceneTileOverlayTests: XCTestCase {
    func testTilesShowOverlayContentOnceReady() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let dir = try OverlayTestSupport.tempDir()
        try OverlayTestSupport.writePNG(dir.appendingPathComponent("red.png"), width: 32, height: 32, rgba: (0..<32 * 32).flatMap { _ in [255, 0, 0, 255] as [UInt8] })
        let tiles = SceneTileOverlays(cache: OverlayTextureCache(device: MetalCore.shared.device))
        let image = Layer(source: LayerSource(type: "image", file: "red.png"), frame: NRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2 * 16 / 9))
        func titled(_ s: String) -> Composition {
            Composition(layers: [Layer(source: .game), image,
                                 Layer(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, source: LayerSource(type: "text", text: TextSpec(string: s, plate: [0, 0, 1, 1])), frame: NRect(x: 0.4, y: 0.6, w: 0.5, h: 0.2))])
        }
        let canvas = CGSize(width: 320, height: 180)
        let first = tiles.overlays(for: titled("One"), canvas: canvas, assets: [dir], tokens: OverlayTokens())
        XCTAssertTrue(first.images.isEmpty, "never waits: the tile draws boxes first")
        let redrawn = expectation(description: "redraw")
        let before = tiles.revision
        func poll() { if tiles.revision > before { redrawn.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll) } }
        poll()
        wait(for: [redrawn], timeout: 5)
        // The image's header was read first; its pixels come with the next pass.
        var one = tiles.overlays(for: titled("One"), canvas: canvas, assets: [dir], tokens: OverlayTokens())
        for _ in 0..<20 where one.images.count < 2 { tiles.cache.drain(); one = tiles.overlays(for: titled("One"), canvas: canvas, assets: [dir], tokens: OverlayTokens()) }
        let red = try XCTUnwrap(one.images[image.id])
        let px = TimelineExportTests.Pixels(red).rgb(red.width / 2, red.height / 2)
        XCTAssertGreaterThan(px[0], 240); XCTAssertLessThan(px[1], 10); XCTAssertLessThan(px[2], 10)
        XCTAssertEqual(one.sources[.layer(image.id)]?.size, CGSize(width: 32, height: 32))
        // Scenes that differ only in their text give different tiles.
        let textID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        _ = tiles.overlays(for: titled("Two"), canvas: canvas, assets: [dir], tokens: OverlayTokens())
        tiles.cache.drain()
        let two = tiles.overlays(for: titled("Two"), canvas: canvas, assets: [dir], tokens: OverlayTokens())
        let a = TimelineExportTests.Pixels(try XCTUnwrap(one.images[textID])), b = TimelineExportTests.Pixels(try XCTUnwrap(two.images[textID]))
        XCTAssertEqual(a.width, b.width)
        XCTAssertNotEqual(a.bytes, b.bytes)
    }
}
