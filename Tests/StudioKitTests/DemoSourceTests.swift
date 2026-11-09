import XCTest
@testable import StudioKit

final class DemoSourceTests: XCTestCase {
    func testProtocol() throws {
        let source = DemoSource(width:320,height:180,fps:30); source.start(); defer { source.stop() }
        // Video is stamped when the frame is ready and audio with its nominal end time, so only each stream is monotonic.
        var previousTime: [UInt8: UInt64] = [:]
        var sequences: [UInt8: UInt32] = [:]
        var videos = 0
        for _ in 0..<10 {
            var h = [UInt8](repeating:0,count:32)
            XCTAssertTrue(h.withUnsafeMutableBytes { readFully(source.readFD,$0.baseAddress!,32) })
            XCTAssertEqual(Array(h.prefix(3)),[0x55,0x56,0x43])
            func u32(_ o:Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(h[o+$1]) << ($1*8) } }
            let t = (0..<8).reduce(UInt64(0)) { $0 | UInt64(h[20+$1]) << ($1*8) }
            XCTAssertGreaterThanOrEqual(t,previousTime[h[3]] ?? 0); previousTime[h[3]] = t
            if let prev = sequences[h[3]] { XCTAssertGreaterThan(u32(28),prev) }; sequences[h[3]] = u32(28)
            if h[3] == 0x53 {
                videos += 1; XCTAssertEqual(u32(4),320); XCTAssertEqual(u32(8),180); XCTAssertEqual(u32(16),320*180*3)
            } else {
                XCTAssertEqual(h[3],0x41); XCTAssertEqual(u32(4),48000); XCTAssertEqual(u32(8),2); XCTAssertEqual(u32(12),16); XCTAssertEqual(u32(16),1920)
                var audio = [UInt8](repeating:0,count:Int(u32(16)))
                XCTAssertTrue(audio.withUnsafeMutableBytes { readFully(source.readFD,$0.baseAddress!,1920) })
            }
        }
        XCTAssertGreaterThan(videos,0)
    }
}
