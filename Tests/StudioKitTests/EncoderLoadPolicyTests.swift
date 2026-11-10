import XCTest
@testable import StudioKit

final class EncoderLoadPolicyTests: XCTestCase {
    func testStepsOrderAndStickyRecovery() {
        for preference in EncoderOverloadPolicy.allCases {
            var policy = EncoderLoadPolicy(preference: preference)
            let first: Canvas = preference == .horizontalFirst ? .wide : .vertical
            let other: Canvas = first == .wide ? .vertical : .wide
            for _ in 0..<2 { XCTAssertNil(policy.sample(rejections: [.wide: 2, .vertical: 3])) }
            XCTAssertEqual(policy.sample(rejections: [.wide: 2, .vertical: 3]), preference == .never ? nil : first)
            for _ in 0..<2 { XCTAssertNil(policy.sample(rejections: [.wide: 2, .vertical: 3])) }
            XCTAssertEqual(policy.sample(rejections: [.wide: 2, .vertical: 3]), preference == .never ? nil : other)
            for _ in 0..<60 { XCTAssertNil(policy.sample(rejections: [.wide: 0, .vertical: 0])) }
            XCTAssertEqual(policy.reduced.count, preference == .never ? 0 : 2)
            policy.loadChanged()
            XCTAssertTrue(policy.reduced.isEmpty)
            for _ in 0..<2 { XCTAssertNil(policy.sample(rejections: [.wide: 3])) }
            XCTAssertEqual(policy.sample(rejections: [.wide: 3]), preference == .never ? nil : .wide)
            for _ in 0..<60 { XCTAssertNil(policy.sample(rejections: [.wide: 0])) }
            XCTAssertEqual(policy.reduced.contains(.wide), preference != .never)
        }
    }
    func testConsecutiveSecondsAndUpfrontRule() {
        var policy = EncoderLoadPolicy()
        for count in [2, 2, 1, 2, 2] { XCTAssertNil(policy.sample(rejections: [.wide: count])) }
        XCTAssertEqual(policy.sample(rejections: [.wide: 2]), .wide)
        for recording in [false, true] { for lanes in [1, 2] { for resolution in [720, 1080] { for fps in [30, 60] {
            let actual = EncoderLoadPolicy.initialLane(recording: recording, sourcePixelsPerSecond: 2560 * 1440 * 60, lanes: lanes, resolution: resolution, fps: fps, preference: .verticalFirst)
            XCTAssertEqual(actual, recording && lanes == 2 && resolution == 1080 && fps == 60 ? .vertical : nil)
        } } } }
        XCTAssertNil(EncoderLoadPolicy.initialLane(recording: true, sourcePixelsPerSecond: 1920 * 1080 * 60, lanes: 2, resolution: 1080, fps: 60, preference: .verticalFirst))
    }
    func testRateDivisorSelectsHalfAndRestoresRealTimestamps() {
        var phase = FramePhase(), timestamps: [UInt64] = []
        for divisor in [1, 2, 1] {
            phase.setRateDivisor(divisor)
            let start = timestamps.last.map { $0 + 100_000_000 } ?? 1_000_000_000
            let selected = (0..<120).map { start + UInt64(Double($0) * 1e9 / 60) }.filter { phase.accept($0, fps: 60) }
            XCTAssertEqual(selected.count, 120 / divisor)
            timestamps += selected
        }
        XCTAssertTrue(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 < $1 })
    }
    func testGoLiveSummaryDescribesBothLanesAndReduction() {
        let state = StreamingState()
        state.destinations = [Destination(service: .custom), Destination(service: .custom), Destination(service: .custom, canvas: .vertical)]
        state.recording = true; state.sourcePixelsPerSecond = 2560 * 1440 * 60
        XCTAssertEqual(state.goLiveSummary, "Streaming horizontal and vertical · 3 destinations · about 18.5 Mbps upload · vertical at 30 fps while recording")
        state.settings.overloadPolicy = .never
        XCTAssertFalse(state.goLiveSummary.contains("30 fps"))
    }
    func testLenientPreferenceDecode() throws {
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8)).overloadPolicy, .verticalFirst)
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"overloadPolicy":"unknown"}"#.utf8)).overloadPolicy, .verticalFirst)
        var settings = StreamSettings(); settings.overloadPolicy = .never
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
