import XCTest
@testable import StudioKit

final class RTMPPublisherTests: XCTestCase {
    private func publisher(_ server: FakeRTMPServer, kbps: Int = 4000) -> RTMPPublisher {
        let p = RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://127.0.0.1:\(server.port)/live")!, streamKey: "secret-test-key", metadata: StreamMetadata(width: 320, height: 180, fps: 30, videoKbps: kbps, audioKbps: 128))
        p.setVideoConfig(sps: Data([0x67, 0x64, 0, 0x1f]), pps: Data([0x68, 0]))
        p.setAudioConfig(audioSpecificConfig: Data([0x11, 0x90]))
        return p
    }
    func testHappyPathGatingControlAndStop() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let p = publisher(server); defer { p.stop() }
        let publishing = expectation(description: "publishing")
        let frame = expectation(description: "frame")
        let pong = expectation(description: "pong")
        let ack = expectation(description: "ack")
        let stopped = expectation(description: "deleteStream")
        server.onMessage = { _, m in
            if m.type == 9, m.payload.starts(with: [0x17, 1]) { frame.fulfill() }
            if m.type == 4, m.payload == Data([0, 7, 1, 2, 3, 4]) { pong.fulfill() }
            if m.type == 3 { ack.fulfill() }
            if m.type == 20, (try? AMF0.decode(m.payload).first?.string) == "deleteStream" { stopped.fulfill() }
        }
        p.onState = { if $0 == .publishing { publishing.fulfill() } }
        p.sendVideo(Data([1]), ptsNs: 0, dtsNs: 0, keyframe: true)
        p.start(); wait(for: [publishing], timeout: 3)
        server.sendControl(type: 5, payload: Data([0, 0, 0x10, 0]))
        server.sendControl(type: 4, payload: Data([0, 6, 1, 2, 3, 4]))
        p.sendAudio(Data([1]), ptsNs: 10)
        p.sendVideo(Data([2]), ptsNs: 1_000_000, dtsNs: 1_000_000, keyframe: false)
        p.sendVideo(Data([3]), ptsNs: 9_000_000_000, dtsNs: 9_000_000_000, keyframe: true)
        p.sendAudio(Data([4]), ptsNs: 8_000_000_000)
        p.sendAudio(Data(repeating: 5, count: 5000), ptsNs: 9_020_000_000)
        // The acknowledgement window counts incoming wire bytes, including ignored commands.
        server.sendControl(type: 4, payload: Data([0, 0]) + Data(repeating: 0, count: 5000))
        wait(for: [frame, pong, ack], timeout: 3)
        p.stop(); wait(for: [stopped], timeout: 3)
        let media = server.messages.map(\.1).filter { [18, 9, 8].contains($0.type) }
        XCTAssertEqual(media.prefix(3).map(\.type), [18, 9, 8])
        let videos = media.filter { $0.type == 9 }
        XCTAssertEqual(videos.count, 2); XCTAssertEqual(videos.last?.timestamp, 0)
        let audios = media.filter { $0.type == 8 }
        XCTAssertEqual(audios.count, 2); XCTAssertEqual(audios.last?.timestamp, 20)
        XCTAssertEqual(p.stats.droppedFrames, 1); XCTAssertGreaterThan(p.stats.bytesSent, 0)
    }
    func testBadNameFailsWithoutRetryAndRedactsKey() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }; server.reject = true
        let p = publisher(server); defer { p.stop() }
        let failed = expectation(description: "failed")
        let retry = expectation(description: "no retry"); retry.isInverted = true
        p.onState = {
            if case .failed(let reason) = $0 { XCTAssertFalse(reason.contains("secret-test-key")); XCTAssertTrue(reason.contains("[redacted]")); failed.fulfill() }
            if case .reconnecting = $0 { retry.fulfill() }
        }
        p.start(); wait(for: [failed], timeout: 3); wait(for: [retry], timeout: 1.2)
        XCTAssertEqual(p.stats.reconnects, 0)
    }
    func testReconnectResetsTimestamps() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let p = publisher(server); defer { p.stop() }
        let frames = expectation(description: "two sessions"); frames.expectedFulfillmentCount = 2
        let reconnect = expectation(description: "reconnect")
        server.onMessage = { n, m in
            if m.type == 9, m.payload.starts(with: [0x17, 1]) {
                XCTAssertEqual(m.timestamp, 0); frames.fulfill()
                if n == 1 { server.closeLatest() }
            }
        }
        var session = 0
        p.onState = {
            if $0 == .publishing { session += 1; let t = UInt64(session) * 10_000_000_000; p.sendVideo(Data([1]), ptsNs: t, dtsNs: t, keyframe: true) }
            if case .reconnecting(let attempt, let seconds) = $0 { XCTAssertEqual(attempt, 1); XCTAssertEqual(seconds, 1); reconnect.fulfill() }
        }
        p.start(); wait(for: [frames, reconnect], timeout: 6)
        XCTAssertEqual(p.stats.reconnects, 1)
    }
    func testStoppedReaderDropsAndRecovers() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let p = publisher(server, kbps: 8000); defer { p.stop() }
        let started = expectation(description: "started")
        let recovered = expectation(description: "recovered frame")
        server.onMessage = { n, m in
            if n == 2, m.type == 9, m.payload.starts(with: [0x17, 1]) {
                XCTAssertEqual(m.timestamp, 0); recovered.fulfill()
            }
        }
        let dropping = expectation(description: "keyframe requested after pressure")
        var sessions = 0, requests = 0
        p.onState = {
            if $0 == .publishing { sessions += 1; if sessions == 1 { started.fulfill() } else { p.sendVideo(Data([1]), ptsNs: 99_000_000_000, dtsNs: 99_000_000_000, keyframe: true) } }
        }
        p.onNeedKeyframe = { requests += 1; if requests == 2 { dropping.fulfill() } }
        p.start(); wait(for: [started], timeout: 3)
        server.pauseLatest()
        let large = Data(repeating: 0x55, count: 1_000_000)
        // Queue enough bytes to exceed the socket's send buffer without relying on link speed.
        for i in 0..<80 {
            p.sendVideo(large, ptsNs: UInt64(i) * 33_000_000, dtsNs: UInt64(i) * 33_000_000, keyframe: i % 5 == 0)
            p.sendAudio(Data(repeating: 1, count: 100_000), ptsNs: UInt64(i) * 33_000_000)
            Thread.sleep(forTimeInterval: 0.005)
        }
        wait(for: [dropping, recovered], timeout: 8)
        XCTAssertGreaterThan(p.stats.droppedFrames, 0); XCTAssertGreaterThan(p.stats.reconnects, 0)
    }
}
