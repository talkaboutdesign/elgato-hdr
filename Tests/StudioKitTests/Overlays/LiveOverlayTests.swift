import CoreVideo
import Metal
import QuartzCore
import XCTest
@testable import StudioKit

/// Image and text layers in the live picture (plan 23 step 3, live part): the window, program outputs and
/// thumbnails look textures up without waiting, transitions keep and match them by id, and `{timer}` follows the
/// stream or recording clock.
final class LiveOverlayTests: XCTestCase {
    private func text(_ s: String, id: UUID = UUID(), frame: NRect = NRect(x: 0.1, y: 0.1, w: 0.5, h: 0.2)) -> Layer {
        Layer(id: id, name: "Text", source: LayerSource(type: "text", text: TextSpec(string: s, plate: [0, 0, 1, 1])), frame: frame)
    }
    private func image(_ file: String, id: UUID = UUID(), frame: NRect) -> Layer {
        Layer(id: id, name: "Image", source: LayerSource(type: "image", file: file), frame: frame)
    }
    private func scene(_ name: String, _ layers: [Layer]) -> Scene { Scene(name: name, wide: Composition(layers: layers), vertical: Composition(layers: layers)) }
    private let morph = SceneTransition(style: .morph, durationMs: 400)

    func testOverlayLayersAcrossTransitions() {
        let shared = UUID(), img = UUID(), other = UUID()
        let a = scene("A", [Layer(source: .game), text("A", id: shared), image("x.png", id: img, frame: .full)])
        let b = scene("B", [text("B", id: shared), text("only B", id: other)])
        let c = scene("C", [Layer(source: .game)])
        let t0: UInt64 = 10_000_000_000
        let s = LiveSceneState(scene: a).switching(to: b, atNs: t0, transition: morph, sources: [:])
        let mid = s.overlayLayers(canvas: .wide, atNs: t0 + 200_000_000)
        XCTAssertEqual(Set(mid.map(\.id)).count, 4)
        XCTAssertEqual(Set(mid.compactMap { $0.source.text?.string }), ["A", "B", "only B"])
        XCTAssertEqual(mid.first { $0.id == shared }?.source.text?.string, "B", "a layer in both scenes is drawn as the target has it")
        XCTAssertEqual(Set(s.overlayLayers(canvas: .wide, atNs: t0 + 600_000_000).map(\.id)), [shared, other])
        // Interrupted: the frozen picture still holds A's and B's overlays until the new transition ends.
        let s2 = s.switching(to: c, atNs: t0 + 200_000_000, transition: morph, sources: [:])
        XCTAssertEqual(Set(s2.overlayLayers(canvas: .vertical, atNs: t0 + 300_000_000).map(\.id)), Set(mid.map(\.id)))
        XCTAssertEqual(s2.overlayLayers(canvas: .vertical, atNs: t0 + 900_000_000), [])
    }

    func testMorphMatchesOverlayLayersByID() {
        let id = UUID(), size = CGSize(width: 1920, height: 1080), t0: UInt64 = 1_000_000_000
        let sources: [SourceKey: SourceInfo] = [.layer(id): SourceInfo(size: CGSize(width: 100, height: 100))]
        let a = scene("A", [image("x.png", id: id, frame: NRect(x: 0, y: 0, w: 0.1, h: 0.1))])
        let b = scene("B", [image("x.png", id: id, frame: NRect(x: 0.5, y: 0.5, w: 0.2, h: 0.2))])
        let mid = LiveSceneState(scene: a).switching(to: b, atNs: t0, transition: morph, sources: sources)
            .frame(canvas: .wide, size: size, sources: sources, atNs: t0 + 100_000_000).layers
        XCTAssertEqual(mid.count, 1, "one layer gliding, not two cross-fading")
        let d = mid[0].dst
        XCTAssertTrue(d.minX > 0 && d.minX < 960 && d.width > 192 && d.width < 384, "\(d)")
        // A different id is not matched: the old one fades out while the new one fades in, both in place.
        var b2 = b; b2.wide.layers[0].id = UUID()
        let s2: [SourceKey: SourceInfo] = sources.merging([.layer(b2.wide.layers[0].id): SourceInfo(size: CGSize(width: 100, height: 100))]) { a, _ in a }
        let crossed = LiveSceneState(scene: a).switching(to: b2, atNs: t0, transition: morph, sources: s2)
            .frame(canvas: .wide, size: size, sources: s2, atNs: t0 + 100_000_000).layers
        XCTAssertEqual(crossed.map(\.dst), [CGRect(x: 0, y: 0, width: 192, height: 108), CGRect(x: 960, y: 540, width: 384, height: 216)])
    }

    func testTimerTokenFollowsTheClock() {
        let t: UInt64 = 10_000_000_000_000
        XCTAssertEqual(LiveOverlayContext(timerStartNs: nil).tokens(atNs: t).replace("{timer}"), "0:00")
        XCTAssertEqual(LiveOverlayContext(timerStartNs: t - 65_400_000_000).tokens(atNs: t).replace("{timer}"), "1:05")
        XCTAssertEqual(LiveOverlayContext(timerStartNs: t + 2_000_000_000).tokens(atNs: t).replace("{timer}"), "0:00", "a frame from before the start")
        XCTAssertEqual(LiveOverlayContext(timerStartNs: t - 3_725_000_000_000).tokens(atNs: t).replace("LIVE {timer}"), "LIVE 1:02:05")
    }

    /// Never waits: a text layer is left out until rasterized, then drawn at exactly its size in that picture. Each
    /// consumer keeps its own texture, so the window never shows the stream's (or a thumbnail's) raster.
    func testPictureLooksOverlaysUpWithoutWaiting() throws {
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let id = UUID(), t0: UInt64 = 50_000_000_000
        let state = LiveSceneState(scene: scene("T", [Layer(source: .game), text("{timer}", id: id)]))
        let context = LiveOverlayContext(timerStartNs: t0 - 5_000_000_000, assets: [])
        let game: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 64, height: 36))]
        func pic(_ size: CGSize, _ consumer: OverlayTextureCache.Consumer, at t: UInt64 = t0) -> LivePicture {
            state.picture(canvas: .wide, size: size, sources: game, atNs: t, context: context, consumer: consumer, cache: cache)
        }
        let stream = CGSize(width: 640, height: 360), window = CGSize(width: 1280, height: 720)
        XCTAssertEqual(pic(stream, .wideOutput).frame.layers.map(\.key), [.game], "not rasterized yet: left out")
        cache.drain()
        let ready = pic(stream, .wideOutput)
        XCTAssertEqual(ready.frame.layers.map(\.key), [.game, .layer(id)])
        guard case .rgba(let tex)? = ready.textures[.layer(id)] else { return XCTFail("no texture") }
        XCTAssertEqual([tex.width, tex.height], [320, 72])
        XCTAssertEqual(pic(window, .window).frame.layers.map(\.key), [.game], "the window waits for its own raster")
        cache.drain()
        guard case .rgba(let big)? = pic(window, .window).textures[.layer(id)] else { return XCTFail("no window texture") }
        XCTAssertEqual([big.width, big.height], [640, 144])
        // The next second: the previous raster stays up while the new one is made, per consumer.
        guard case .rgba(let held)? = pic(window, .window, at: t0 + 1_000_000_000).textures[.layer(id)] else { return XCTFail("blinked") }
        XCTAssertTrue(held === big)
    }

    /// A program output encodes the overlay once its texture exists; until then the frame goes out without it.
    func testProgramOutputDrawsImageOverlays() throws {
        let dir = try OverlayTestSupport.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("blue.png")
        let blue: [UInt8] = Array(repeating: [0, 0, 255, 255] as [UInt8], count: 64).flatMap { $0 }
        try OverlayTestSupport.writePNG(png, width: 8, height: 8, rgba: blue)
        let name = try AssetStore.importImage(png, into: dir)
        let demo = DemoSource(width: 64, height: 36, fps: 60)
        let renderer = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let fill = Layer(source: LayerSource(type: "color", color: [1, 0, 0, 1]))
        renderer.scene = LiveSceneState(scene: scene("I", [fill, image(name, frame: NRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))]))
        renderer.overlayContext = LiveOverlayContext(timerStartNs: nil, assets: [dir])
        let output = ProgramOutput(canvas: .wide, size: CGSize(width: 64, height: 36), fps: 60, nv12: false)
        output.picture = { [weak renderer] s, src, ns in renderer?.livePicture(canvas: .wide, size: s, sources: src, atNs: ns) ?? LivePicture() }
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var centre: [[UInt8]] = []
        output.onFrame = { pb, _ in
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + 18 * CVPixelBufferGetBytesPerRow(pb) + 32 * 4
            lock.lock(); centre.append([p[2], p[1], p[0]]); lock.unlock(); gate.signal()
        }
        let core = MetalCore.shared
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        output.start(); defer { output.stop() }
        let t0 = nowNs()
        output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: t0)
        XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        // Header, then decode: two trips through the overlay queue.
        OverlayTextureCache.shared.drain()
        _ = renderer.livePicture(canvas: .wide, size: CGSize(width: 64, height: 36), sources: [:], atNs: t0)
        OverlayTextureCache.shared.drain()
        output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: t0 + 17_000_000)
        XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        lock.lock(); let got = centre; lock.unlock()
        XCTAssertEqual(got, [[255, 0, 0], [0, 0, 255]], "first frame without the image, then with it")
    }

    /// What the reader thread does per game frame with a scene of game, camera, an image and two text layers: the
    /// window's picture plus a 16:9 and a 9:16 lane, each looked up and encoded (CPU side, GPU work not awaited).
    /// Printed for the pull request; the bound only catches an accidental blow-up.
    func testPerFrameCostWithOverlaysAndTwoLanes() throws {
        let dir = try OverlayTestSupport.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("logo.png")
        var rgba = [UInt8](repeating: 0, count: 512 * 256 * 4)
        for i in 0..<512 * 256 {
            let r: UInt8 = UInt8(i % 255), a: UInt8 = i % 7 == 0 ? 0 : 255
            rgba[i * 4] = r; rgba[i * 4 + 1] = 90; rgba[i * 4 + 2] = 200; rgba[i * 4 + 3] = a
        }
        try OverlayTestSupport.writePNG(png, width: 512, height: 256, rgba: rgba)
        let name = try AssetStore.importImage(png, into: dir)
        let layers = [Layer(source: .game), Layer(source: .camera, frame: NRect(x: 0.7, y: 0.65, w: 0.25, h: 0.3)),
                      image(name, frame: NRect(x: 0.03, y: 0.03, w: 0.2, h: 0.1)), text("LIVE {timer}", frame: NRect(x: 0.75, y: 0.04, w: 0.2, h: 0.06)),
                      text("Name Tag", frame: NRect(x: 0.04, y: 0.85, w: 0.3, h: 0.08))]
        let a = scene("Overlays", layers), b = scene("Other", Array(layers.reversed()))
        let t0 = nowNs()
        let context = LiveOverlayContext(timerStartNs: t0, assets: [dir])
        let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 2560, height: 1440)), .camera: SourceInfo(size: CGSize(width: 1280, height: 720))]
        let targets: [(Canvas, CGSize, OverlayTextureCache.Consumer)] = [(.wide, CGSize(width: 2880, height: 1620), .window),
                                                                         (.wide, CGSize(width: 1920, height: 1080), .wideOutput),
                                                                         (.vertical, CGSize(width: 1080, height: 1920), .verticalOutput)]
        let steady = LiveSceneState(scene: a)
        for (c, size, consumer) in targets { _ = steady.picture(canvas: c, size: size, sources: sources, atNs: t0, context: context, consumer: consumer) }
        OverlayTextureCache.shared.drain()
        for (c, size, consumer) in targets { _ = steady.picture(canvas: c, size: size, sources: sources, atNs: t0, context: context, consumer: consumer) }
        OverlayTextureCache.shared.drain()
        let core = MetalCore.shared, n = 300
        let out = targets.map { _, size, _ -> MTLTexture in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget]; d.storageMode = .private
            return core.device.makeTexture(descriptor: d)!
        }
        func measure(_ st: LiveSceneState, at t: UInt64) -> (lookup: Double, total: Double) {
            var lookupNs: UInt64 = 0, totalNs: UInt64 = 0
            for i in 0..<n {
                let begin = nowNs()
                let cb = core.queue.makeCommandBuffer()!
                for (k, (c, size, consumer)) in targets.enumerated() {
                    let l0 = nowNs()
                    let dt: UInt64 = UInt64(i) * 16_666_667 % 300_000_000
                    let pic = st.picture(canvas: c, size: size, sources: sources, atNs: t + dt, context: context, consumer: consumer)
                    lookupNs += nowNs() - l0
                    core.encodeLayers(cb, target: out[k], canvas: size, background: pic.frame.background, outTransfer: 2, layers: DrawLayer.pair(pic.frame.layers, pic.textures))
                }
                cb.commit()
                totalNs += nowNs() - begin
                if i % 30 == 29 { cb.waitUntilCompleted() }
            }
            return (Double(lookupNs) / Double(n) / 1000, Double(totalNs) / Double(n) / 1000)
        }
        let still = measure(steady, at: t0)
        let morphing = LiveSceneState(scene: b).switching(to: a, atNs: t0, transition: morph, sources: sources)
        let mid = measure(morphing, at: t0)
        print(String(format: "per-frame reader cost with game, camera, image and 2 text layers, window + 16:9 + 9:16 (µs): scene+overlay lookups %.1f, with encoding %.1f; mid-morph %.1f / %.1f", still.lookup, still.total, mid.lookup, mid.total))
        XCTAssertLessThan(still.total, 5_000)
    }
}
