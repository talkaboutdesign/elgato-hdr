import XCTest
import CoreVideo
import Metal
import QuartzCore
@testable import StudioKit

/// Stream lanes draw the live scene (plan 22) for their own canvas, at the game frame's host time, so the window and
/// every stream show the same transition frame.
final class LiveSceneStreamTests: XCTestCase {
    /// A scene that fills each canvas with one colour, so a program output's pixels say which scene it drew.
    private func solid(_ name: String, wide: [Double], vertical: [Double]) -> Scene {
        func comp(_ c: [Double]) -> Composition { Composition(layers: [Layer(name: "Fill", source: LayerSource(type: "color", color: c))]) }
        return Scene(name: name, wide: comp(wide), vertical: comp(vertical))
    }

    func testLanesDrawTheLiveSceneOfTheirCanvas() throws {
        let demo = DemoSource(width: 64, height: 36, fps: 60)
        let first = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let second = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let a = solid("A", wide: [1, 0, 0, 1], vertical: [0, 1, 0, 1]), b = solid("B", wide: [0, 0, 1, 1], vertical: [1, 1, 0, 1])
        let t0 = nowNs()
        first.scene = LiveSceneState(scene: a).switching(to: b, atNs: t0, transition: SceneTransition(style: .fade, durationMs: 400), sources: [:])
        second.scene = LiveSceneState(scene: a)
        let wide = CGSize(width: 64, height: 36), tall = CGSize(width: 36, height: 64)
        let stream = StreamSession(outputs: [.init(canvas: .wide, size: wide, fps: 60, videoBitrate: 100_000, publishers: []),
                                             .init(canvas: .vertical, size: tall, fps: 60, videoBitrate: 100_000, publishers: [])],
                                   audioBitrate: 160_000, renderer: first, mixer: AudioMixer())
        XCTAssertTrue(stream.start()); defer { stream.stop() }
        let programs = first.programOutputs
        XCTAssertEqual(programs.map(\.canvas), [.wide, .vertical])
        for p in programs {
            for dt in [0, 100, 200, 600] as [UInt64] {
                let t = t0 + dt * 1_000_000
                let got = p.picture(p.size, [:], t).frame, want = first.sceneFrame(canvas: p.canvas, size: p.size, sources: [:], atNs: t)
                XCTAssertEqual(got, want, "\(p.canvas) at +\(dt) ms")
            }
            // Mid-fade both scenes are drawn; afterwards only the target.
            XCTAssertEqual(p.picture(p.size, [:], t0 + 200_000_000).frame.layers.count, 2)
            XCTAssertEqual(p.picture(p.size, [:], t0 + 600_000_000).frame.layers.map(\.color), [p.canvas == .wide ? SIMD4(0, 0, 1, 1) : SIMD4(1, 1, 0, 1)])
        }
        // After a capture restart (new renderer) the same lanes follow the new renderer's scene.
        stream.replaceRenderer(second)
        XCTAssertEqual(programs[1].picture(tall, [:], t0).frame.layers.map(\.color), [SIMD4(0, 1, 0, 1)])
    }

    /// The pixels a program output encodes follow a scene switch: before, during (a blend) and after.
    func testProgramPixelsFollowASwitch() throws {
        let core = MetalCore.shared
        let demo = DemoSource(width: 64, height: 36, fps: 60)
        let renderer = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let a = solid("A", wide: [1, 0, 0, 1], vertical: [0, 1, 0, 1]), b = solid("B", wide: [0, 0, 1, 1], vertical: [0, 0, 1, 1])
        let size = CGSize(width: 36, height: 64)
        let output = ProgramOutput(canvas: .vertical, size: size, fps: 60, nv12: false)
        output.picture = { [weak renderer] s, sources, ns in renderer?.livePicture(canvas: .vertical, size: s, sources: sources, atNs: ns) ?? LivePicture() }
        let lock = NSLock(), gate = DispatchSemaphore(value: 0)
        var pixels: [UInt64: [UInt8]] = [:]
        output.onFrame = { pb, ns in
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let row = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let p = base + 32 * row + 18 * 4
            lock.lock(); pixels[ns] = [p[2], p[1], p[0]]; lock.unlock(); gate.signal()   // BGRA -> RGB
        }
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        let t0 = nowNs() + 1_000_000_000
        renderer.scene = LiveSceneState(scene: a).switching(to: b, atNs: t0, transition: SceneTransition(style: .fade, durationMs: 400), sources: [:])
        output.start(); defer { output.stop() }
        let times: [UInt64] = [t0 - 100_000_000, t0 + 100_000_000, t0 + 600_000_000]
        for t in times {
            output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: t)
            XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        }
        lock.lock(); let got = times.map { pixels[$0] ?? [] }; lock.unlock()
        XCTAssertEqual(got[0], [0, 255, 0], "before the switch: scene A's 9:16 canvas")
        XCTAssertTrue(got[1][2] > 20 && got[1][1] > 20, "mid-fade: both scenes show, got \(got[1])")
        XCTAssertEqual(got[2], [0, 0, 255], "after: scene B")
        print("program output pixels across a fade: before \(got[0]) mid \(got[1]) after \(got[2])")
    }
}
