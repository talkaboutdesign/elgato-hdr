import XCTest
@testable import StudioKit

final class RTMPReviewTests: XCTestCase {
    private func publisher(_ server: FakeRTMPServer) -> RTMPPublisher {
        let p = RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://127.0.0.1:\(server.port)/live")!, streamKey: "secret-test-key", metadata: StreamMetadata(width: 320, height: 180, fps: 30, videoKbps: 4000, audioKbps: 128))
        p.setVideoConfig(sps: Data([0x67, 0x64, 0, 0x1f]), pps: Data([0x68, 0]))
        p.setAudioConfig(audioSpecificConfig: Data([0x11, 0x90]))
        return p
    }
    func testOptionalErrors() throws { try ignoredCommands(rejectOptional: true) }
    func testUnknownMalformedCommands() throws { try ignoredCommands(rejectOptional: false) }
    private func ignoredCommands(rejectOptional: Bool) throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        server.rejectOptional = rejectOptional
        let p = publisher(server); defer { p.stop() }
        let ready = expectation(description: "ready"), frame = expectation(description: "still publishing")
        ready.assertForOverFulfill = false
        p.onState = { if $0 == .publishing { ready.fulfill() } }
        server.onMessage = { _, m in if m.type == 9, m.payload.starts(with: [0x17, 1]) { frame.fulfill() } }
        p.start(); wait(for: [ready], timeout: 3)
        for tail in [Data([0x10]), Data([0x11]), Data([2, 0, 1, 255]), Data([11]) + Data(repeating: 0, count: 10)] {
            server.sendControl(type: 20, payload: AMF0.encode([.string("onBWDone"), .number(0)]) + tail)
        }
        // A ping response establishes that all preceding commands were consumed.
        let pong = expectation(description: "pong")
        server.onMessage = { _, m in
            if m.type == 4 { pong.fulfill() }
            if m.type == 9, m.payload.starts(with: [0x17, 1]) { frame.fulfill() }
        }
        server.sendControl(type: 4, payload: Data([0, 6, 0, 0, 0, 1]))
        wait(for: [pong], timeout: 3)
        p.sendVideo(Data([1]), ptsNs: 0, dtsNs: 0, keyframe: true)
        wait(for: [frame], timeout: 3); XCTAssertEqual(p.stats.reconnects, 0)
    }
    func testMalformedAwaitedReplyNamesStage() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }; server.malformedConnect = true
        let p = publisher(server); defer { p.stop() }
        let retry = expectation(description: "retry")
        p.onState = { if case .reconnecting = $0 { retry.fulfill() } }
        p.start(); wait(for: [retry], timeout: 3)
        XCTAssertEqual(p.stats.lastError, "Malformed connect response")
    }
    func testConfigDeduplicationAndTimestamps() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let p = publisher(server); defer { p.stop() }
        let ready = expectation(description: "ready"), frames = expectation(description: "three frames")
        frames.expectedFulfillmentCount = 3
        p.onState = { if $0 == .publishing { ready.fulfill() } }
        server.onMessage = { _, m in if m.type == 9, m.payload.count > 1, m.payload[1] == 1 { frames.fulfill() } }
        p.start(); wait(for: [ready], timeout: 3)
        p.sendVideo(Data([1]), ptsNs: 0, dtsNs: 0, keyframe: true)
        p.sendVideo(Data([2]), ptsNs: 100_000_000, dtsNs: 100_000_000, keyframe: false)
        p.setVideoConfig(sps: Data([0x67, 0x64, 0, 0x1f]), pps: Data([0x68, 0]))
        p.setAudioConfig(audioSpecificConfig: Data([0x11, 0x90]))
        p.sendVideo(Data([3]), ptsNs: 200_000_000, dtsNs: 200_000_000, keyframe: false)
        wait(for: [frames], timeout: 3)
        let configs = expectation(description: "changed configs"); configs.expectedFulfillmentCount = 2
        server.onMessage = { _, m in if [8, 9].contains(m.type), m.payload[1] == 0 { XCTAssertEqual(m.timestamp, 200); configs.fulfill() } }
        p.setVideoConfig(sps: Data([0x67, 0x64, 0, 0x20]), pps: Data([0x68, 0]))
        p.setAudioConfig(audioSpecificConfig: Data([0x12, 0x10]))
        wait(for: [configs], timeout: 3)
        XCTAssertEqual(server.messages.filter { [8, 9].contains($0.1.type) && $0.1.payload[1] == 0 }.count, 4)
    }
    func testBadNameAfterPublishingRetries() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }; server.rejectSession = 2
        let p = publisher(server); defer { p.stop() }
        let ready = expectation(description: "recovered")
        var sessions = 0
        p.onState = {
            if $0 == .publishing { sessions += 1; if sessions == 1 { server.closeLatest() } else { ready.fulfill() } }
            if case .failed = $0 { XCTFail("Previously published session must retry") }
        }
        p.start(); wait(for: [ready], timeout: 8); XCTAssertEqual(p.stats.reconnects, 2)
    }
    func testInvalidMutatedPortFailsCleanly() throws {
        for port in [-1, 65536, Int.max] {
            var endpoint = StreamEndpoint(url: "rtmp://localhost/live")!; endpoint.port = port
            let p = RTMPPublisher(endpoint: endpoint, streamKey: "secret", metadata: StreamMetadata(width: 1, height: 1, fps: 1, videoKbps: 1, audioKbps: 1))
            let failed = expectation(description: "invalid port")
            p.onState = { if case .failed(let reason) = $0 { XCTAssertEqual(reason, "Invalid RTMP port"); failed.fulfill() } }
            p.start(); wait(for: [failed], timeout: 2); p.stop()
        }
    }
    func testConnectionRefusedIncludesTransportDetail() throws {
        let server = try FakeRTMPServer()
        let p = publisher(server); server.stop(); defer { p.stop() }
        let retry = expectation(description: "transport failure")
        p.onState = { if case .reconnecting = $0 { retry.fulfill() } }
        p.start(); wait(for: [retry], timeout: 4)
        let reason = try XCTUnwrap(p.stats.lastError)
        XCTAssertTrue(reason.contains("TCP/TLS:")); XCTAssertTrue(reason.contains("61")); XCTAssertFalse(reason.contains("secret-test-key"))
    }
    func testConcurrentCallbackAccess() {
        let p = RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://localhost/live")!, streamKey: "secret", metadata: StreamMetadata(width: 1, height: 1, fps: 1, videoKbps: 1, audioKbps: 1))
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            p.onState = { _ in }; p.onNeedKeyframe = {}
            _ = p.onState; _ = p.onNeedKeyframe
        }
    }
    func testCallbacksCanBeReplacedAndReentered() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let p = publisher(server); defer { p.stop() }
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            p.onState = { _ in p.onState = nil }; p.onNeedKeyframe = { p.onNeedKeyframe = nil }
            _ = p.onState; _ = p.onNeedKeyframe
        }
        let ready = expectation(description: "callback outside lock")
        p.onState = { if $0 == .publishing { p.onState = nil; ready.fulfill() } }
        p.start(); wait(for: [ready], timeout: 3)
    }
    func testCongestionKeepsAudioAndRecoversOnKeyframe() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let p = publisher(server); defer { p.stop() }
        let ready = expectation(description: "ready"), requested = expectation(description: "recovery IDR")
        let audio = expectation(description: "audio through congestion"), resumed = expectation(description: "resumed IDR")
        let release = DispatchSemaphore(value: 0)
        var requests = 0
        p.onState = { if $0 == .publishing {
            ready.fulfill()
            // Queue the complete burst before send completions can race the producer on fast CI loopback.
            _ = release.wait(timeout: .now() + 5)
        } }
        p.onNeedKeyframe = {
            requests += 1
            if requests == 2 { requested.fulfill() }
        }
        p.start(); wait(for: [ready], timeout: 3)
        server.pauseLatest()
        server.onMessage = { _, m in
            if m.type == 8, m.payload == Data([0xaf, 1, 0x42]) { audio.fulfill() }
            if m.type == 9, m.payload == Data([0x17, 1, 0, 0, 0, 0x43]) { resumed.fulfill() }
        }
        p.sendVideo(Data(repeating: 0x55, count: 800_000), ptsNs: 0, dtsNs: 0, keyframe: true)
        for i in 100..<121 {
            p.sendVideo(Data([1]), ptsNs: UInt64(i) * 33_000_000, dtsNs: UInt64(i) * 33_000_000, keyframe: true)
        }
        p.sendAudio(Data([0x42]), ptsNs: 5_000_000_000)
        release.signal()
        server.resumeLatest(); wait(for: [requested, audio], timeout: 8)
        XCTAssertEqual(p.stats.droppedFrames, 21)
        let dropped = p.stats.droppedFrames
        p.sendVideo(Data([2]), ptsNs: 6_000_000_000, dtsNs: 6_000_000_000, keyframe: false)
        XCTAssertEqual(p.stats.droppedFrames, dropped + 1)
        p.sendVideo(Data([0x43]), ptsNs: 6_033_000_000, dtsNs: 6_033_000_000, keyframe: true)
        wait(for: [resumed], timeout: 3); XCTAssertEqual(p.stats.reconnects, 0)
    }
    func testPressureHysteresis() {
        var pressure = RTMPPressure()
        XCTAssertFalse(pressure.update(1772)); XCTAssertTrue(pressure.dropping)
        for pending in [1700.0, 1500, 900, 750] { XCTAssertFalse(pressure.update(pending)); XCTAssertTrue(pressure.dropping) }
        XCTAssertTrue(pressure.update(749)); XCTAssertFalse(pressure.dropping)
        XCTAssertFalse(pressure.update(700)); XCTAssertFalse(pressure.update(0))
    }
}
