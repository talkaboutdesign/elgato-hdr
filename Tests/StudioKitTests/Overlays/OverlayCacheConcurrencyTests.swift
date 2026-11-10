import Metal
import XCTest
@testable import StudioKit

/// Blocking lookups (`wait: true`, the export path) from several threads at once, and the cache's byte budget.
final class OverlayCacheConcurrencyTests: XCTestCase {
    private typealias S = OverlayTestSupport

    /// Eight threads look up the same 2,000 text layers and 500 image headers in the same order, each waiting. Every
    /// lookup must come back with its texture or size: a caller that finds another caller's entry still pending has to
    /// wait for that entry's own work, not for whatever happened to be queued when it looked.
    func testConcurrentBlockingLookupsNeverMiss() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let dir = try S.tempDir()
        try S.writePNG(dir.appendingPathComponent("logo.png"), width: 16, height: 8, rgba: [UInt8](repeating: 200, count: 16 * 8 * 4))
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let texts = (0..<2000).map { Layer(source: LayerSource(type: "text", text: TextSpec(string: "#\($0)")), frame: NRect(x: 0, y: 0, w: 0.1, h: 0.05)) }
        let image = Layer(source: LayerSource(type: "image", file: "logo.png"), frame: NRect(x: 0, y: 0, w: 0.1, h: 0.1))
        // A distinct (unused) second folder per lookup makes each a new header read of the same file.
        let paths = (0..<500).map { [dir, dir.appendingPathComponent("unused-\($0)")] }
        let threads = 8
        let canvas = CGSize(width: 640, height: 360)
        let tally = NSLock()
        var missed = 0, total = 0
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var miss = 0, count = 0
            for (i, l) in texts.enumerated() {
                if cache.overlays(for: Composition(layers: [l]), canvas: canvas, assets: [], wait: true).textures[.layer(l.id)] == nil { miss += 1 }
                count += 1
                if i < paths.count {
                    let o = cache.overlays(for: Composition(layers: [image]), canvas: canvas, assets: paths[i], wait: true)
                    if o.sources[.layer(image.id)] == nil || o.textures[.layer(image.id)] == nil { miss += 1 }
                    count += 1
                }
            }
            tally.lock(); missed += miss; total += count; tally.unlock()
        }
        print("Concurrent blocking overlay lookups: \(total) lookups from \(threads) threads, \(missed) missing")
        XCTAssertEqual(total, 20_000)
        XCTAssertEqual(missed, 0)
    }

    /// Above the byte budget the least recently used textures go at once, not only after `maxIdle`: a `{timer}`
    /// layer that leaves one big texture per second behind stays within the budget, and a texture still in use stays.
    func testByteBudgetEvictsLeastRecentlyUsed() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        cache.maxIdle = 3600                                    // only the budget may release anything here
        let size = CGSize(width: 512, height: 256), each = 512 * 256 * 4
        cache.byteBudget = each * 4
        let keep = Layer(source: LayerSource(type: "text", text: TextSpec(string: "Keep me")))
        let keepTexture = try XCTUnwrap(cache.texture(for: keep, pixelSize: size, assets: [], wait: true))
        let timer = Layer(source: LayerSource(type: "text", text: TextSpec(string: "{timer}")))
        for second in 0..<20 {
            XCTAssertNotNil(cache.texture(for: timer, pixelSize: size, assets: [], tokens: OverlayTokens(elapsed: Double(second)), wait: true))
            XCTAssertLessThanOrEqual(cache.residentBytes, cache.byteBudget, "second \(second)")
            // The still-shown layer is used every frame, so it is never the least recently used.
            XCTAssertTrue(cache.texture(for: keep, pixelSize: size, assets: [], wait: true) === keepTexture, "second \(second)")
        }
        XCTAssertEqual(cache.rasterCount, 21)
        XCTAssertLessThanOrEqual(cache.peakResidentBytes, cache.byteBudget)
        // An evicted value is made again on demand, so a blocking lookup still gets it.
        XCTAssertNotNil(cache.texture(for: timer, pixelSize: size, assets: [], tokens: OverlayTokens(elapsed: 0), wait: true))
        XCTAssertEqual(cache.rasterCount, 22)
    }
}
