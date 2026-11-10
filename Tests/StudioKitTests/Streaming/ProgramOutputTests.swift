import XCTest
import CoreVideo
import Metal
@testable import StudioKit

class ProgramOutputTests: XCTestCase {
    var nv12: Bool { false }
    func testPhaseTracking() {
        for (source, target, jitter, late, expected) in [
            (60.0, 60.0, 1_000_000.0, 4_000_000.0, 2400),
            (60, 60, 3_000_000, 4_000_000, 2400),
            (59.94, 60, 0, 0, 2400), (120, 60, 0, 0, 1200),
            (30, 60, 0, 0, 2400), (60, 30, 0, 0, 1200)
        ] {
            var phase = FramePhase(), kept: [UInt64] = []
            for frame in 0..<2400 {
                let offset = frame == 0 ? late : (frame % 2 == 0 ? jitter : -jitter)
                let ns = UInt64(10e9 + Double(frame) * 1e9 / source + offset)
                if phase.accept(ns, fps: target) { kept.append(ns) }
            }
            XCTAssertEqual(kept.count, expected, "\(source) → \(target), jitter \(jitter)")
            XCTAssertTrue(zip(kept, kept.dropFirst()).allSatisfy { $0 < $1 })
            print("phase: \(source) -> \(target), jitter=\(jitter), kept=\(kept.count)/2400")
        }
    }
    func testContentionAndStalePassAreCounted() throws {
        let core = MetalCore.shared
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        let output = ProgramOutput(canvas: .wide, size: CGSize(width: 64, height: 36), fps: 60, nv12: nv12)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), submitted = DispatchSemaphore(value: 0)
        output.picture = { _, _, _ in entered.signal(); _ = release.wait(timeout: .now() + 2); return LivePicture() }
        output.start()
        let base = nowNs()
        DispatchQueue.global().async {
            output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: base, isCurrent: { false })
            submitted.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: base + 17_000_000)
        release.signal()
        XCTAssertEqual(submitted.wait(timeout: .now() + 2), .success)
        let barrier = try XCTUnwrap(core.queue.makeCommandBuffer()); barrier.commit(); barrier.waitUntilCompleted()
        Thread.sleep(forTimeInterval: 0.02)
        output.stop()
        let stats = output.takeStats()
        XCTAssertEqual(stats.contention, 1); XCTAssertEqual(stats.stale, 1)
        XCTAssertEqual(stats.frames, 0); XCTAssertEqual(stats.dropped, 2)
    }
    func testFrameSelectionAndNoSignal() throws {
        let core = MetalCore.shared
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        let output = ProgramOutput(canvas: .wide, size: CGSize(width: 64, height: 36), fps: 60, nv12: nv12)
        output.picture = { size, sources, _ in
            LivePicture(frame: SceneFrame(background: SIMD4(0, 0, 0, 1), layers: SceneResolver.resolve(Composition(layers: [Layer(source: .game)]), canvas: size, sources: sources)))
        }
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var times: [UInt64] = []
        output.onFrame = { pb, ns in
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), self.nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
            XCTAssertEqual(CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) as? String, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            lock.lock(); times.append(ns); lock.unlock(); gate.signal()
        }
        output.start()
        let base = nowNs() - 2_000_000_000
        for frame in 0..<180 {
            output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .pq, camera: nil,
                             hostNs: base + UInt64(frame) * 1_000_000_000 / 120)
            if frame % 2 == 0 { XCTAssertEqual(gate.wait(timeout: .now() + 2), .success) }
        }
        lock.lock(); let selected = times; lock.unlock()
        XCTAssertEqual(selected.count, 90)
        XCTAssertTrue(zip(selected, selected.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(gate.wait(timeout: .now() + 1), .success, "No signal must render without any window drawable")
        output.stop()
        let stats = output.takeStats()
        XCTAssertEqual(stats.dropped, 0)
        print("ProgramOutput: 180 frames at 120 fps -> \(selected.count) at 60 fps; no-signal frame delivered; dropped=\(stats.dropped)")
    }
    func testJitterAndSlowSourceNeverDuplicate() throws {
        let core = MetalCore.shared
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        for rate in [30, 60] {
            let output = ProgramOutput(canvas: .wide, size: CGSize(width: 64, height: 36), fps: 60, nv12: nv12)
            let gate = DispatchSemaphore(value: 0)
            var timestamps: [UInt64] = []
            output.onFrame = { _, ns in timestamps.append(ns); gate.signal() }
            output.start()
            let base = nowNs()
            for frame in 0..<60 {
                let jitter: UInt64 = frame % 2 == 0 ? 0 : 500_000
                let ns = base + UInt64(frame) * 1_000_000_000 / UInt64(rate) + jitter
                output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: ns)
                XCTAssertEqual(gate.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(timestamps.last, ns)
            }
            output.stop()
            XCTAssertEqual(timestamps.count, 60)
        }
    }

}

final class NV12ProgramOutputTests: ProgramOutputTests { override var nv12: Bool { true } }

extension ProgramOutputTests {
    func testLiveRateDivisorHalvesAndRestores() throws {
        let core = MetalCore.shared
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        let output = ProgramOutput(canvas: .wide, size: CGSize(width: 64, height: 36), fps: 60, nv12: nv12)
        let gate = DispatchSemaphore(value: 0)
        var timestamps: [UInt64] = []
        output.onFrame = { _, ns in timestamps.append(ns); gate.signal() }
        output.setRateDivisor(2)
        output.start()
        let base = nowNs()
        for (segment, divisor) in [2, 1, 2, 1].enumerated() {
            if segment > 0 { output.setRateDivisor(divisor) }
            let before = timestamps.count
            for n in 0..<120 {
                let ns = base + UInt64(segment * 120 + n) * 1_000_000_000 / 60
                output.gameFrame(y: y, c: c, size: CGSize(width: 64, height: 36), colorMode: .sdr, camera: nil, hostNs: ns)
                if n % divisor == 0 {
                    XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
                    XCTAssertEqual(timestamps.last, ns)
                }
            }
            XCTAssertEqual(timestamps.count - before, 120 / divisor)
        }
        output.stop()
        XCTAssertEqual(output.takeStats().dropped, 0)
        XCTAssertTrue(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(output.fps, 60, "Metadata remains at the configured rate")
    }
}
