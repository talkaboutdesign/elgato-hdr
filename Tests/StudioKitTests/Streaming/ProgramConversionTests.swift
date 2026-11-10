import XCTest
import CoreVideo
import Metal
@testable import StudioKit

final class ProgramConversionTests: XCTestCase {
    func testNV12GoldenAgainstBGRA() throws {
        let size = CGSize(width: 16, height: 16)
        let colors: [[Double]] = [[0,0,0,1], [1,1,1,1], [1,0,0,1], [0,1,0,1], [0,0,1,1], [0.2,0.7,0.4,1]]
        // Odd-width patches exercise chroma averaging across boundaries, not just uniform primary colours.
        let layers = (0..<16).map { x in Layer.color(colors[x % colors.count], name: "", frame: NRect(x: Double(x)/16, y: 0, w: 1.0/16, h: 1)) }
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
        XCTAssertEqual(identities.count, 66)
        output.gameFrame(y: y, c: c, size: size, colorMode: .sdr, camera: nil, hostNs: start + 66 * 17_000_000)
        XCTAssertEqual(output.takeStats().capacity, 1)
        releases.removeLast()()
        output.gameFrame(y: y, c: c, size: size, colorMode: .sdr, camera: nil, hostNs: start + 67 * 17_000_000)
        XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        output.stop(); releases.forEach { $0() }
    }
}
