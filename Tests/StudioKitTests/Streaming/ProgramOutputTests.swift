import XCTest
import CoreVideo
import Metal
@testable import StudioKit

final class ProgramOutputTests: XCTestCase {
    func testFrameSelectionAndNoSignal() throws {
        let core = MetalCore.shared
        let y = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 64, height: 36, mipmapped: false)))
        let c = try XCTUnwrap(core.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: 32, height: 18, mipmapped: false)))
        let output = ProgramOutput(canvas: .wide, size: CGSize(width: 64, height: 36), fps: 60)
        output.composition = { Composition(layers: [Layer(source: .game)]) }
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var times: [UInt64] = []
        output.onFrame = { pb, ns in
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_32BGRA)
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
}
