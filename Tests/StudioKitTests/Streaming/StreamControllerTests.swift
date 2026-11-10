import XCTest
@testable import StudioKit

/// The Go Live controller against fake RTMP servers and a fake session (no Metal, no encoder): destination health,
/// rejection without retry, recovery, starting and stopping single destinations while live.
final class StreamControllerTests: XCTestCase {
    final class FakeSession: StreamSessionDriving {
        var onStats: ((StreamSession.Stats) -> Void)?
        var onError: ((String) -> Void)?
        private(set) var lanes: [(Canvas, [RTMPPublisher])] = []
        private(set) var stopped = false
        let outputs: [StreamSession.Output]
        init(_ outputs: [StreamSession.Output]) { self.outputs = outputs }
        var activeCanvases: [Canvas] { lanes.map(\.0) }
        func publishers(_ canvas: Canvas) -> [RTMPPublisher] { lanes.first { $0.0 == canvas }?.1 ?? [] }
        func start() -> Bool { for o in outputs { lanes.append((o.canvas, o.publishers)); o.publishers.forEach { $0.start() } }; return true }
        func stop() { lanes.flatMap(\.1).forEach { $0.stop() }; lanes = []; stopped = true }
        func addPublisher(_ p: RTMPPublisher, to output: StreamSession.Output) -> Bool {
            if let i = lanes.firstIndex(where: { $0.0 == output.canvas }) { lanes[i].1.append(p) } else { lanes.append((output.canvas, [p])) }
            p.start(); return true
        }
        func removePublisher(_ p: RTMPPublisher) {
            for i in lanes.indices { lanes[i].1.removeAll { $0 === p } }
            lanes.removeAll { $0.1.isEmpty }; p.stop()
        }
    }

    private var dir: URL!
    private var toasts: [String] = []
    private var sessions: [FakeSession] = []
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehdr-controller-\(UUID().uuidString)")
        toasts = []; sessions = []
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func controller(_ destinations: [Destination]) throws -> StreamController {
        let store = DestinationStore(url: dir.appendingPathComponent("streaming.json"))
        try store.save(StreamingConfig(destinations: destinations))
        // Unused here (keyOverride), but never the user's Keychain service.
        let c = StreamController(state: StreamingState(), store: store, keychain: KeychainStore(service: "dev.max.elgato-hdr.stream-key.tests.\(UUID().uuidString)"))
        c.keyOverride = "secret-test-key"
        c.makeSession = { [unowned self] outputs, _ in let s = FakeSession(outputs); self.sessions.append(s); return s }
        c.toast = { [unowned self] text, _, _ in self.toasts.append(text) }
        return c
    }
    private func local(_ name: String, _ server: FakeRTMPServer, _ canvas: Canvas = .wide) -> Destination {
        Destination(service: .custom, name: name, url: "rtmp://127.0.0.1:\(server.port)/live", canvas: canvas)
    }
    @discardableResult private func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    /// Acceptance 4: a rejected key shows "Stream key rejected" and is not retried; the other destination stays live.
    func testRejectedKeyFailsWithoutRetryAndOthersStayLive() throws {
        let good = try FakeRTMPServer(), bad = try FakeRTMPServer(); bad.reject = true
        defer { good.stop(); bad.stop() }
        let g = local("Good", good), r = local("Rejecting", bad)
        let c = try controller([g, r])
        c.goLive()
        XCTAssertEqual(c.state.phase, .connecting)
        XCTAssertTrue(spin(5) { c.state.health(g.id).status == .live && c.state.health(r.id).status != .connecting })
        XCTAssertEqual(c.state.health(r.id).status, .failed("Stream key rejected"))
        XCTAssertNotNil(c.state.liveSince)
        XCTAssertTrue(toasts.contains("Rejecting: stream key rejected"), "\(toasts)")
        spin(2.5) { false }
        XCTAssertEqual(c.state.health(r.id).status, .failed("Stream key rejected"), "a rejected key is not retried")
        XCTAssertEqual(Set(bad.messages.map(\.0)), [1], "only one connection to the rejecting server")
        XCTAssertEqual(c.state.health(g.id).status, .live)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.publishers(.wide).count, 1, "the failed publisher left the session")
        XCTAssertFalse(c.state.health(r.id).detail?.contains("secret-test-key") ?? false)
        print("Rejected destination: status=\(c.state.health(r.id).status) detail=\(c.state.health(r.id).detail ?? "-") toasts=\(toasts)")

        // Turning the last live destination off ends the stream; the failed card keeps its reason.
        c.setEnabled(g.id, false)
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertTrue(session.stopped)
        XCTAssertEqual(c.state.health(r.id).status, .failed("Stream key rejected"))
        XCTAssertEqual(c.state.health(g.id).status, .off)
        XCTAssertTrue(toasts.contains("Stream ended: every destination is off"))
    }

    func testEveryDestinationFailingEndsTheSession() throws {
        let bad = try FakeRTMPServer(); bad.reject = true
        defer { bad.stop() }
        let c = try controller([local("One", bad), local("Two", bad, .vertical)])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.phase == .idle && !sessions.isEmpty })
        XCTAssertTrue(sessions[0].stopped)
        XCTAssertTrue(toasts.contains("Stream ended: no destination could stay connected"), "\(toasts)")
        XCTAssertTrue(c.state.destinations.allSatisfy { c.state.health($0.id).status == .failed("Stream key rejected") })
    }

    func testReconnectsAndStartsAndStopsSingleDestinationsWhileLive() throws {
        let one = try FakeRTMPServer(), two = try FakeRTMPServer()
        defer { one.stop(); two.stop() }
        var a = local("Wide", one), v = local("Vertical", two, .vertical)
        v.enabled = false
        let c = try controller([a, v])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.health(a.id).status == .live })
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.activeCanvases, [.wide])
        XCTAssertEqual(c.state.health(v.id).status, .off)

        // The server drops the connection: reconnecting, then live again on its own.
        one.closeLatest()
        XCTAssertTrue(spin(3) { if case .reconnecting = c.state.health(a.id).status { return true }; return false })
        XCTAssertTrue(spin(6) { c.state.health(a.id).status == .live })
        XCTAssertTrue(toasts.contains("Wide is live again"), "\(toasts)")

        // Turning a destination on while live adds it to the running session with its own canvas.
        c.setEnabled(v.id, true)
        XCTAssertTrue(spin(5) { c.state.health(v.id).status == .live })
        XCTAssertEqual(session.activeCanvases, [.wide, .vertical])
        c.setEnabled(v.id, false)
        XCTAssertEqual(session.activeCanvases, [.wide])
        XCTAssertEqual(c.state.health(v.id).status, .off)
        XCTAssertEqual(c.state.phase.isLive, true)

        // Settings persist; the stream keeps the settings it started with.
        var s = c.state.settings; s.videoKbps = 4000
        c.updateSettings(s)
        XCTAssertEqual(c.state.liveSettings?.videoKbps, 6000)
        XCTAssertEqual(DestinationStore(url: dir.appendingPathComponent("streaming.json")).load().settings.videoKbps, 4000)
        a.enabled = true
        c.endStream()
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertTrue(c.state.health.isEmpty)
        XCTAssertTrue(session.stopped)
    }

    func testGoLiveWithNothingEnabledOnlyExplains() throws {
        var d = Destination(service: .twitch); d.enabled = false
        let c = try controller([d])
        c.goLive()
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(toasts, ["Turn on a destination to go live"])
    }

    func testConnectionTest() throws {
        let good = try FakeRTMPServer(), bad = try FakeRTMPServer(); bad.reject = true
        defer { good.stop(); bad.stop() }
        let c = try controller([])
        var results: [ConnectionTestResult] = []
        c.testConnection(local("Good", good), key: "k") { results.append($0) }
        c.testConnection(local("Bad", bad), key: "secret-test-key") { results.append($0) }
        c.testConnection(Destination(service: .custom, url: "rtmp://127.0.0.1:1/live"), key: "k") { results.append($0) }
        c.testConnection(Destination(service: .custom, url: "http://x"), key: "k") { results.append($0) }
        XCTAssertTrue(spin(10) { results.count == 4 })
        XCTAssertTrue(results.contains(.connected))
        XCTAssertTrue(results.contains { if case .failed("Publish", let m) = $0 { return m.hasPrefix("Stream key rejected") && !m.contains("secret-test-key") }; return false }, "\(results)")
        XCTAssertTrue(results.contains { if case .failed("Connect", let m) = $0 { return m.contains("refused") }; return false }, "\(results)")
        XCTAssertTrue(results.contains { if case .failed("URL", _) = $0 { return true }; return false })
        print("Test connection results: \(results)")
    }
}

private extension StreamUIState {
    var isLive: Bool { if case .live = self { return true }; return false }
}

/// Manual harness for acceptance check 4 in the real app: `EHDR_FAKE_RTMP_REJECT_PORT=1940 swift test --filter
/// RejectingServerHarness` serves a FakeRTMPServer that rejects every key for 60 s. Skipped otherwise.
final class RejectingServerHarness: XCTestCase {
    func testServeRejectingServer() throws {
        guard let port = ProcessInfo.processInfo.environment["EHDR_FAKE_RTMP_REJECT_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("manual harness: set EHDR_FAKE_RTMP_REJECT_PORT")
        }
        let server = try FakeRTMPServer(port: port); server.reject = true
        defer { server.stop() }
        print("rejecting RTMP server on 127.0.0.1:\(port)")
        RunLoop.main.run(until: Date().addingTimeInterval(60))
        print("connections: \(Set(server.messages.map(\.0)).count)")
    }
}

extension StreamControllerTests {
    func testDeletingTheLastLiveDestinationEndsAsUserStopped() throws {
        let server = try FakeRTMPServer(); defer { server.stop() }
        let d = local("Only", server)
        let c = try controller([d])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.health(d.id).status == .live })
        c.delete(d.id)
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertTrue(toasts.contains("Stream ended: every destination is off"), "\(toasts)")
        XCTAssertTrue(c.state.destinations.isEmpty)
    }
}
