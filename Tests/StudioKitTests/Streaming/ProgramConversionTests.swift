import XCTest
import CoreVideo
import Metal
@testable import StudioKit

final class ProgramConversionTests: XCTestCase {
    func testNV12GoldenAgainstBGRA() throws {
        let size = CGSize(width: 16, height: 16)
        let colors: [[Double]] = [[0,0,0,1], [1,1,1,1], [1,0,0,1], [0,1,0,1], [0,0,1,1], [0.2,0.7,0.4,1]]
        // Odd-width patches exercise chroma averaging across boundaries, not just uniform primary colours.
        let layers = (0..<256).map { index -> Layer in
            let x = index % 16, y = index / 16
            return Layer.color(colors[(x + 3 * y + y / 2) % colors.count], name: "", frame: NRect(x: Double(x)/16, y: Double(y)/16, w: 1.0/16, h: 1.0/16))
        }
        let comp = Composition(layers: layers), core = MetalCore.shared
        let y = OverlayTestSupport.texture(.r16Unorm, 16, 16, Data(count: 512), 32)
        let c = OverlayTestSupport.texture(.rg16Unorm, 8, 8, Data(count: 256), 32)
        func render(_ nv12: Bool) throws -> [[UInt8]] {
            let output = ProgramOutput(canvas: .wide, size: size, fps: 60, nv12: nv12)
            output.picture = { size, sources, _ in LivePicture(frame: SceneFrame(background: comp.backgroundColor, layers: SceneResolver.resolve(comp, canvas: size, sources: sources))) }
            let gate = DispatchSemaphore(value: 0)
            var bytes: [[UInt8]] = []
            output.onFrame = { pb, _ in
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
                if nv12 { XCTAssertEqual(CVBufferCopyAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, nil) as? String, kCVImageBufferChromaLocation_Center as String) }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                for plane in 0..<(nv12 ? 2 : 1) {
                    let base = nv12 ? CVPixelBufferGetBaseAddressOfPlane(pb, plane)! : CVPixelBufferGetBaseAddress(pb)!
                    let stride = nv12 ? CVPixelBufferGetBytesPerRowOfPlane(pb, plane) : CVPixelBufferGetBytesPerRow(pb)
                    let width = nv12 ? 16 : 64, height = plane == 1 ? 8 : 16
                    var data: [UInt8] = []
                    for row in 0..<height { data += Array(UnsafeBufferPointer(start: base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width)) }
                    bytes.append(data)
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly); gate.signal()
            }
            output.start()
            output.gameFrame(y: y, c: c, size: size, colorMode: .sdr, camera: nil, hostNs: nowNs())
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success); output.stop()
            _ = core
            return bytes
        }
        let rgb = try render(false)[0], nv = try render(true)
        func color(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (y * 16 + x) * 4
            return SIMD3(Double(rgb[i + 2]), Double(rgb[i + 1]), Double(rgb[i])) / 255
        }
        func luma(_ v: SIMD3<Double>) -> Double { v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722 }
        for y in 0..<16 { for x in 0..<16 {
            XCTAssertEqual(Double(nv[0][y * 16 + x]), 16 + 219 * luma(color(x, y)), accuracy: 1)
        } }
        for y in 0..<8 { for x in 0..<8 {
            let v = (color(2*x, 2*y) + color(2*x+1, 2*y) + color(2*x, 2*y+1) + color(2*x+1, 2*y+1)) / 4
            let i = y * 16 + x * 2, yy = luma(v)
            XCTAssertEqual(Double(nv[1][i]), 128 + 224 * (v.z - yy) / 1.8556, accuracy: 1)
            XCTAssertEqual(Double(nv[1][i+1]), 128 + 224 * (v.x - yy) / 1.5748, accuracy: 1)
        } }
    }
}

extension ProgramConversionTests {
    func testPoolRetainsEveryEncoderLease() {
        let size = CGSize(width: 16, height: 16)
        let output = ProgramOutput(canvas: .wide, size: size, fps: 60)
        XCTAssertTrue(output.isReady)
        let y = OverlayTestSupport.texture(.r16Unorm, 16, 16, Data(count: 512), 32)
        let c = OverlayTestSupport.texture(.rg16Unorm, 8, 8, Data(count: 256), 32)
        let gate = DispatchSemaphore(value: 0)
        var releases: [() -> Void] = [], identities = Set<ObjectIdentifier>()
        output.onLeasedFrame = { pb, _, release in
            identities.insert(ObjectIdentifier(pb)); releases.append(release); gate.signal()
        }
        let start = nowNs()
        output.start()
        for n in 0..<(EncodeAdmission.inFlightLimit + 2) {
            output.gameFrame(y: y, c: c, size: size, colorMode: .sdr, camera: nil, hostNs: start + UInt64(n) * 17_000_000)
            XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        }
        XCTAssertEqual(identities.count, 18)
        output.gameFrame(y: y, c: c, size: size, colorMode: .sdr, camera: nil, hostNs: start + 66 * 17_000_000)
        XCTAssertEqual(output.takeStats().capacity, 1)
        releases.removeLast()()
        output.gameFrame(y: y, c: c, size: size, colorMode: .sdr, camera: nil, hostNs: start + 67 * 17_000_000)
        XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        output.stop(); releases.forEach { $0() }
    }
}

extension ProgramConversionTests {
    func testReleaseReaderCost() throws {
        guard ProcessInfo.processInfo.environment["EHDR_MEASURE_READER"] == "1" else { throw XCTSkip("Opt-in release reader measurement") }
        let core = MetalCore.shared
        let y = OverlayTestSupport.texture(.r16Unorm, 2560, 1440, Data(count: 2560 * 1440 * 2), 2560 * 2)
        let c = OverlayTestSupport.texture(.rg16Unorm, 1280, 720, Data(count: 1280 * 720 * 4), 1280 * 4)
        var camera: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &camera), kCVReturnSuccess)
        let scene = SceneCollection.defaults().active
        let gate = DispatchSemaphore(value: 0)
        let outputs = Canvas.allCases.map { canvas -> ProgramOutput in
            let output = ProgramOutput(canvas: canvas, size: canvas.size(.hd), fps: 60)
            output.picture = { size, sources, _ in LivePicture(frame: SceneFrame(background: SIMD4(0, 0, 0, 1), layers: SceneResolver.resolve(scene.composition(canvas), canvas: size, sources: sources))) }
            output.onFrame = { _, _ in gate.signal() }; output.start(); return output
        }
        var elapsed = 0.0
        for frame in 0..<600 {
            let start = nowNs()
            for output in outputs { output.gameFrame(y: y, c: c, size: CGSize(width: 2560, height: 1440), colorMode: .sdr, camera: camera, hostNs: start) }
            let end = nowNs()
            if frame >= 60 { elapsed += Double(end - start) / 1000 }
            for _ in outputs { XCTAssertEqual(gate.wait(timeout: .now() + 2), .success) }
            let duration = Double(nowNs() - start) / 1e9
            Thread.sleep(forTimeInterval: max(0, 1.0 / 60 - duration))
        }
        for output in outputs { output.stop(); XCTAssertEqual(output.takeStats().dropped, 0) }
        print(String(format: "RELEASE reader cost: two 1080p60 NV12 lanes + camera = %.1f µs/frame (540 samples)", elapsed / 540))
        _ = core
    }
}
