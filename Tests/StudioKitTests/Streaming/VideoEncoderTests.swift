import XCTest
import CoreVideo
@testable import StudioKit

final class VideoEncoderTests: XCTestCase {
    func testHardwareEncoding() throws {
        let bitrate = 2_000_000
        let encoder = try XCTUnwrap(VideoEncoder(settings: .init(width: 640, height: 360, fps: 30, bitrate: bitrate)))
        let gate = DispatchSemaphore(value: 0)
        var configured = false, keys: [Int] = [], count = 0, bytes = 0, times: [UInt64] = []
        encoder.onConfig = { sps, pps in XCTAssertFalse(sps.isEmpty); XCTAssertFalse(pps.isEmpty); configured = true }
        encoder.onError = { status in XCTFail("H.264 error \(status)"); gate.signal() }
        encoder.onFrame = { data, ns, key in
            XCTAssertTrue(configured, "Config must precede first frame")
            if key { keys.append(count) }; count += 1; bytes += data.count; times.append(ns); gate.signal()
        }
        var random: UInt32 = 1234
        for frame in 0..<120 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let pb = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pb, [])
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(pb) / 4
            for y in 0..<360 { for x in 0..<640 {
                random = random &* 1664525 &+ 1013904223
                let v = (random >> 24) & 255
                p[y * stride + x] = 0xff000000 | (v << 16) | (v << 8) | v
            } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if frame == 95 { encoder.requestKeyframe() }
            encoder.encode(pb, hostNs: 10_000_000_000 + UInt64(frame) * 1_000_000_000 / 30)
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
        }
        encoder.finish()
        XCTAssertEqual(count, 120); XCTAssertEqual(keys.first, 0)
        XCTAssertTrue(keys.contains { (59...61).contains($0) })
        XCTAssertTrue(keys.contains { (95...97).contains($0) })
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        let measured = Double(bytes * 8) / 4
        XCTAssertEqual(measured, Double(bitrate), accuracy: Double(bitrate) * 0.25)
        print("VideoEncoder: \(count) frames; keyframes=\(keys); bitrate=\(Int(measured)) target=\(bitrate)")
    }
    func testInvalidSettings() {
        XCTAssertNil(VideoEncoder(settings: .init(width: 0, height: 100, fps: 60, bitrate: 1000)))
        XCTAssertNil(VideoEncoder(settings: .init(width: 100, height: 100, fps: .nan, bitrate: 1000)))
    }
}
