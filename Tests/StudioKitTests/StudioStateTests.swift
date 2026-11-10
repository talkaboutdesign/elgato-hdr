import XCTest
@testable import StudioKit

final class StudioStateTests: XCTestCase {
    func testElapsed() {
        XCTAssertEqual(StudioFormat.elapsed(0), "00:00")
        XCTAssertEqual(StudioFormat.elapsed(65.9), "01:05")
        XCTAssertEqual(StudioFormat.elapsed(3599), "59:59")
        XCTAssertEqual(StudioFormat.elapsed(3725), "1:02:05")
        XCTAssertEqual(StudioFormat.elapsed(-3), "00:00")
        XCTAssertEqual(StudioFormat.elapsed(.nan), "00:00")
    }

    func testSignalStrings() {
        XCTAssertEqual(StudioFormat.signal(width: 2560, height: 1440, fps: 59.94, color: .pq), "2560×1440 · 60 fps · HDR10")
        XCTAssertEqual(StudioFormat.shortSignal(width: 2560, height: 1440, fps: 60, color: .pq), "1440p60 HDR")
        XCTAssertEqual(StudioFormat.shortSignal(width: 3840, height: 2160, fps: 30, color: .hlg), "4K30 HLG")
        XCTAssertEqual(StudioFormat.shortSignal(width: 2560, height: 1080, fps: 60, color: .sdr), "2560×1080p60 SDR")
        XCTAssertEqual(StudioFormat.signal(width: 0, height: 0, fps: 60, color: .pq), "")
    }

    func testNominalFps() {
        XCTAssertEqual(StudioFormat.nominalFps(measured: 60.6, nominal: 60), 60)
        XCTAssertEqual(StudioFormat.nominalFps(measured: 59.4, nominal: 60), 60)
        XCTAssertEqual(StudioFormat.nominalFps(measured: 30.1, nominal: 60), 30.1)   // card fell back to another rate
    }

    func testParseStats() throws {
        let s = try XCTUnwrap(StudioFormat.parseStats("2560x1440 10-bit  59.9 fps  •  22 ms to screen"))
        XCTAssertEqual(s.fps, 59.9, accuracy: 0.001); XCTAssertEqual(s.latencyMs, 22)
        XCTAssertNil(StudioFormat.parseStats("2560x1440 P010"))
        XCTAssertNil(StudioFormat.parseStats("stream ended"))
    }

    func testMeterScale() {
        XCTAssertEqual(StudioFormat.dbfs(1), 0)
        XCTAssertEqual(StudioFormat.dbfs(0), -60)
        XCTAssertEqual(StudioFormat.dbfs(0.1), -20, accuracy: 0.01)
        XCTAssertEqual(StudioFormat.meterFraction(1), 1)
        XCTAssertEqual(StudioFormat.meterFraction(0), 0)
        XCTAssertEqual(StudioFormat.meterFraction(0.1), 2.0 / 3, accuracy: 0.001)
    }

    func testApplyStatsAndPill() {
        let s = StudioState()
        XCTAssertEqual(s.pillText, "Connecting…")
        s.applyStats(width: 2560, height: 1440, fps: 60, latencyMs: 21.6, demo: false)
        XCTAssertEqual(s.connection, .live)
        XCTAssertEqual(s.signal, "2560×1440 · 60 fps · HDR10")
        XCTAssertEqual(s.pillText, "1440p60 HDR · 22 ms")
        s.applyStats(width: 2560, height: 1440, fps: 60, latencyMs: 0, demo: true)
        XCTAssertEqual(s.pillText, "Demo source · 1440p60 HDR")
        s.connection = .noSignal("")
        XCTAssertEqual(s.pillText, "No signal")
        s.connection = .noSignal("The stream ended")
        XCTAssertEqual(s.pillText, "No signal · The stream ended")
    }

    func testCameraShape() {
        var p = CameraPlacement()
        XCTAssertEqual(CameraShape(p), .rounded)
        CameraShape.circle.apply(to: &p)
        XCTAssertEqual(CameraShape(p), .circle); XCTAssertEqual(p.aspect, .square)
        CameraShape.square.apply(to: &p)
        XCTAssertEqual(CameraShape(p), .square)
        p.aspect = .wide; CameraShape.rounded.apply(to: &p)
        XCTAssertEqual(CameraShape(p), .rounded); XCTAssertEqual(p.aspect, .wide)
    }
}
