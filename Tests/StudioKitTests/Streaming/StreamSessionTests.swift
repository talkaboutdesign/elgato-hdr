import XCTest
import QuartzCore
@testable import StudioKit

/// Publishers joining and leaving a running session (plan 21, step 2), against local fake RTMP servers. Without a
/// capture source the program outputs render their no-signal frames, which is enough to drive the encoders.
final class StreamSessionTests: XCTestCase {
    final class Tally {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        private(set) var firstVideo: String?
        func add(_ k: String) { lock.lock(); values[k, default: 0] += 1; lock.unlock() }
        func video(_ k: String) { lock.lock(); if firstVideo == nil { firstVideo = k }; values[k, default: 0] += 1; lock.unlock() }
        subscript(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[k] ?? 0 }
        var first: String? { lock.lock(); defer { lock.unlock() }; return firstVideo }
    }
    private func watch(_ server: FakeRTMPServer, _ tally: Tally, keyframe: XCTestExpectation? = nil, deleted: XCTestExpectation? = nil) {
        server.onMessage = { _, m in
            if m.type == 9 {
                if m.payload.starts(with: [0x17, 0]) { tally.video("config") }
                else if m.payload.starts(with: [0x17, 1]) { tally.video("key"); keyframe?.fulfill() }
                else { tally.video("delta") }
            }
            if m.type == 20, (try? AMF0.decode(m.payload).first?.string) == "deleteStream" { deleted?.fulfill() }
        }
    }
    private func publisher(_ server: FakeRTMPServer, _ size: CGSize) -> RTMPPublisher {
        RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://127.0.0.1:\(server.port)/live")!, streamKey: "k",
                      metadata: StreamMetadata(width: Int(size.width), height: Int(size.height), fps: 30, videoKbps: 500, audioKbps: 128))
    }
    private func spin(until deadline: TimeInterval, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end { if done() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    func testAddAndRemovePublishersWhileLive() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(), c = try FakeRTMPServer()
        defer { a.stop(); b.stop(); c.stop() }
        let ta = Tally(), tb = Tally(), tc = Tally()
        let aKey = expectation(description: "A keyframe"), aDeleted = expectation(description: "A deleteStream")
        aKey.assertForOverFulfill = false
        let bKey = expectation(description: "B keyframe"); bKey.assertForOverFulfill = false
        let cKey = expectation(description: "C keyframe"); cKey.assertForOverFulfill = false
        watch(a, ta, keyframe: aKey, deleted: aDeleted); watch(b, tb, keyframe: bKey); watch(c, tc, keyframe: cKey)

        let demo = DemoSource(width: 64, height: 36, fps: 30)
        let renderer = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let wideSize = CGSize(width: 320, height: 180), tallSize = CGSize(width: 180, height: 320)
        let pa = publisher(a, wideSize), pb = publisher(b, wideSize), pc = publisher(c, tallSize)
        let wide = StreamSession.Output(canvas: .wide, size: wideSize, fps: 30, videoBitrate: 500_000, publishers: [pa])
        let session = StreamSession(outputs: [wide], audioBitrate: 128_000, renderer: renderer, mixer: AudioMixer())
        var errors: [String] = []
        session.onError = { errors.append($0) }
        var statsIDs: Set<ObjectIdentifier> = []
        session.onStats = { s in s.publisherIDs.forEach { statsIDs.insert($0) }; XCTAssertEqual(s.publisherIDs.count, s.publishers.count) }
        XCTAssertTrue(session.start()); defer { session.stop() }
        wait(for: [aKey], timeout: 8)

        // A second wide destination joins the running encoder: configuration first, then a keyframe.
        XCTAssertTrue(session.addPublisher(pb, to: wide))
        XCTAssertEqual(session.activeCanvases, [.wide])
        wait(for: [bKey], timeout: 8)
        XCTAssertEqual(tb.first, "config", "a late joiner must see the AVC configuration before any frame")

        // A vertical destination starts a second lane; removing it stops that lane again.
        let vertical = StreamSession.Output(canvas: .vertical, size: tallSize, fps: 30, videoBitrate: 500_000, publishers: [])
        XCTAssertTrue(session.addPublisher(pc, to: vertical))
        XCTAssertEqual(session.activeCanvases, [.wide, .vertical])
        wait(for: [cKey], timeout: 8)
        XCTAssertEqual(tc.first, "config")
        XCTAssertEqual(renderer.programOutputs.count, 2)
        session.removePublisher(pc)
        XCTAssertEqual(session.activeCanvases, [.wide])
        XCTAssertEqual(renderer.programOutputs.count, 1)

        // Removing the first publisher leaves the other one streaming.
        session.removePublisher(pa)
        wait(for: [aDeleted], timeout: 4)
        let before = tb["delta"] + tb["key"]
        XCTAssertTrue(spin(until: 4) { tb["delta"] + tb["key"] >= before + 30 }, "B keeps receiving frames after A leaves")
        let aAfter = ta["delta"] + ta["key"]
        XCTAssertTrue(spin(until: 1.5) { false } == false)
        XCTAssertEqual(ta["delta"] + ta["key"], aAfter, "A receives nothing after it was removed")
        XCTAssertTrue(statsIDs.contains(ObjectIdentifier(pb)))

        session.removePublisher(pb)
        XCTAssertEqual(session.activeCanvases, [])
        XCTAssertTrue(renderer.programOutputs.isEmpty)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        print("StreamSession add/remove: A frames=\(aAfter) B frames=\(tb["delta"] + tb["key"]) (keys \(tb["key"])) C frames=\(tc["delta"] + tc["key"])")
    }

    func testLaneRecoveryAndFatalFailureIsolation() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer()
        defer { a.stop(); b.stop() }
        let ta = Tally(), tb = Tally()
        watch(a, ta); watch(b, tb)
        let demo = DemoSource(width: 64, height: 64, fps: 30)
        let renderer = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let size = CGSize(width: 320, height: 180)
        let session = StreamSession(outputs: [
            .init(canvas: .wide, size: size, fps: 30, videoBitrate: 500_000, publishers: [publisher(a, size)]),
            .init(canvas: .vertical, size: size, fps: 30, videoBitrate: 500_000, publishers: [publisher(b, size)])
        ], audioBitrate: 128_000, renderer: renderer, mixer: AudioMixer())
        var recovered: [Canvas] = [], failed: [Canvas] = []
        session.onRecovery = { recovered.append($0) }
        session.onLaneError = { canvas, reason in failed.append(canvas); XCTAssertTrue(reason.contains("recovery failed")) }
        XCTAssertTrue(session.start()); defer { session.stop() }
        XCTAssertTrue(spin(until: 5) { ta["key"] > 0 && tb["key"] > 0 })
        let keys = ta["key"]
        session.invalidateEncoderForTesting(.wide)
        XCTAssertTrue(spin(until: 5) { recovered == [.wide] && ta["key"] > keys })
        session.invalidateEncoderForTesting(.wide, fatal: true)
        XCTAssertTrue(spin(until: 5) { failed == [.wide] })
        XCTAssertEqual(session.activeCanvases, [.vertical])
        XCTAssertEqual(renderer.programOutputs.count, 1)
        let before = tb["delta"]
        XCTAssertTrue(spin(until: 3) { tb["delta"] > before + 20 })
    }

    func testRendererSwapKeepsProgramAndNoSignalAlive() throws {
        let demo = DemoSource(width: 64, height: 64, fps: 60)
        let first = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let second = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let stream = StreamSession(outputs: [.init(canvas: .wide, size: CGSize(width: 64, height: 64), fps: 60,
            videoBitrate: 100_000, publishers: []),
            .init(canvas: .vertical, size: CGSize(width: 64, height: 64), fps: 60,
                  videoBitrate: 100_000, publishers: [])], audioBitrate: 160_000, renderer: first, mixer: AudioMixer())
        XCTAssertTrue(stream.start())
        let programs = first.programOutputs
        XCTAssertEqual(programs.count, 2)
        let program = try XCTUnwrap(programs.first)
        let gate = DispatchSemaphore(value: 0)
        program.onFrame = { _, _ in gate.signal() }
        stream.replaceRenderer(second)
        XCTAssertTrue(first.programOutputs.isEmpty)
        XCTAssertTrue(second.programOutputs.first === program)
        XCTAssertTrue(second.programOutputs.last === programs.last)
        XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        stream.stop()
        XCTAssertTrue(second.programOutputs.isEmpty)
    }
}
