import XCTest
import QuartzCore
@testable import StudioKit

/// The Go Live controller against fake RTMP servers and a fake session (no Metal, no encoder): destination health,
/// rejection without retry, recovery, starting and stopping single destinations while live.
final class StreamControllerTests: XCTestCase {
    final class FakeSession: StreamSessionDriving {
        var onStats: ((StreamSession.Stats) -> Void)?
        var onError: ((String) -> Void)?
        var onLaneError: ((Canvas, String) -> Void)?
        var onRecovery: ((Canvas) -> Void)?
        func replaceRenderer(_ renderer: Renderer) {}
        private(set) var lanes: [(Canvas, [RTMPPublisher])] = []
        private(set) var stopped = false
        let outputs: [StreamSession.Output]
        init(_ outputs: [StreamSession.Output]) { self.outputs = outputs }
        var activeCanvases: [Canvas] { lanes.map(\.0) }
        func publishers(_ canvas: Canvas) -> [RTMPPublisher] { lanes.first { $0.0 == canvas }?.1 ?? [] }
        func start() -> Bool { for o in outputs { lanes.append((o.canvas, o.publishers)); o.publishers.forEach { $0.start() } }; return true }
        func stop() { lanes.flatMap(\.1).forEach { $0.stop() }; lanes = []; stopped = true }
        /// Canvases whose lane cannot start while live, like a hardware encoder that cannot be created.
        var failing: Set<Canvas> = []
        func addPublisher(_ p: RTMPPublisher, to output: StreamSession.Output) throws {
            if let i = lanes.firstIndex(where: { $0.0 == output.canvas }) { lanes[i].1.append(p) }
            else if failing.contains(output.canvas) { throw StreamSession.LaneFailure(description: StreamSession.encoderUnavailable) }
            else { lanes.append((output.canvas, [p])) }
            p.start()
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

    func testLaneEventsAndCountersReachState() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer()
        defer { a.stop(); b.stop() }
        let wide = local("Wide", a), tall = local("Tall", b, .vertical)
        let c = try controller([wide, tall]); c.goLive(); defer { c.endStream() }
        XCTAssertTrue(spin(5) { c.state.health(wide.id).status == .live && c.state.health(tall.id).status == .live })
        let session = try XCTUnwrap(sessions.first)
        var stats = StreamSession.Stats(canvas: .wide, fps: 60, renderMs: 1, encodeMs: 1, latencyMs: 1,
                                       renderDropped: 4, encoderDropped: 2, publishers: [])
        stats.renderSkips.contention = 3; stats.renderSkips.stale = 1; stats.renderSkips.rateSkipped = 60
        session.onStats?(stats)
        XCTAssertEqual(c.state.canvases.first?.contention, 3)
        XCTAssertEqual(c.state.canvases.first?.stale, 1)
        XCTAssertEqual(c.state.canvases.first?.rateSkipped, 60)
        XCTAssertEqual(c.state.canvases.first?.encoderDropped, 2)
        session.onRecovery?(.wide)
        XCTAssertEqual(c.state.encoderRecoveryEvents, 1)
        session.publishers(.wide).forEach { session.removePublisher($0) }
        session.onLaneError?(.wide, "H.264 recovery failed")
        XCTAssertEqual(c.state.health(wide.id).status, .failed("H.264 recovery failed"))
        XCTAssertEqual(c.state.health(tall.id).status, .live)
        XCTAssertTrue(c.isActive)
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

// MARK: - Review fixes: Keychain wait, lane-scoped failures, edits while live, toggling

extension StreamControllerTests {
    /// Holds key reads as if macOS were showing its Keychain prompt; `release` answers them.
    private func holdKeys(_ c: StreamController) -> () -> Void {
        let q = DispatchQueue(label: "test.keys"); q.suspend()
        c.keyQueue = q
        var held = true
        addTeardownBlock { if held { q.resume() } }
        return { if held { held = false; q.resume() } }
    }
    private func connections(_ server: FakeRTMPServer) -> Int { Set(server.messages.map(\.0)).count }

    /// A destination switched off while Go Live waits for the Keychain is not streamed to; one whose URL changed
    /// meanwhile streams to the new URL.
    func testGoLiveUsesTheDestinationsAsTheyAreWhenTheKeysArrive() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(), moved = try FakeRTMPServer()
        defer { a.stop(); b.stop(); moved.stop() }
        let one = local("One", a), two = local("Two", b)
        let c = try controller([one, two])
        let release = holdKeys(c)
        c.goLive()
        XCTAssertEqual(c.state.phase, .connecting)
        c.setEnabled(two.id, false)
        XCTAssertEqual(c.state.health(two.id).status, .off)
        XCTAssertTrue(c.isActive, "one destination is still on")
        c.state.destinations[0].url = "rtmp://127.0.0.1:\(moved.port)/live"
        release()
        XCTAssertTrue(spin(5) { c.state.health(one.id).status == .live })
        spin(0.5) { false }
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.outputs.flatMap(\.publishers).count, 1)
        XCTAssertEqual(connections(b), 0, "a destination turned off during the wait must not be streamed to")
        XCTAssertEqual(connections(a), 0, "the old URL is not used")
        XCTAssertEqual(connections(moved), 1)
        XCTAssertEqual(c.state.health(two.id).status, .off)
    }

    func testTurningEverythingOffOrEndingDuringTheKeyWaitCancelsGoLive() throws {
        let a = try FakeRTMPServer(); defer { a.stop() }
        let one = local("One", a)
        let c = try controller([one])
        var release = holdKeys(c)
        c.goLive()
        c.setEnabled(one.id, false)
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(toasts.contains("Go Live cancelled"), "\(toasts)")
        release()
        spin(0.5) { false }
        XCTAssertTrue(sessions.isEmpty)

        // End Stream during the wait.
        c.setEnabled(one.id, true)
        release = holdKeys(c)
        c.goLive(); c.endStream()
        XCTAssertEqual(c.state.phase, .idle)
        release()
        spin(0.5) { false }
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(connections(a), 0)
    }

    /// A second Go Live, or turning another destination on, during the wait replaces the pending start: one session
    /// with every destination that is on.
    func testSecondGoLiveDuringTheKeyWaitReplacesThePendingStart() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(); defer { a.stop(); b.stop() }
        var two = local("Two", b, .vertical); two.enabled = false
        let one = local("One", a)
        let c = try controller([one, two])
        let release = holdKeys(c)
        c.goLive()
        c.goLive()
        c.setEnabled(two.id, true)
        release()
        XCTAssertTrue(spin(5) { c.state.health(one.id).status == .live && c.state.health(two.id).status == .live })
        spin(0.5) { false }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].activeCanvases, [.wide, .vertical])
        XCTAssertEqual([connections(a), connections(b)], [1, 1])
    }

    /// Starting one destination while live follows the same rule: only its latest switch counts.
    func testSingleStartWaitingForItsKeyFollowsTheLatestSwitch() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(); defer { a.stop(); b.stop() }
        var two = local("Two", b); two.enabled = false
        let one = local("One", a)
        let c = try controller([one, two])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.health(one.id).status == .live })
        var release = holdKeys(c)
        c.setEnabled(two.id, true); c.setEnabled(two.id, false)
        release()
        spin(0.5) { false }
        XCTAssertEqual(connections(b), 0)
        XCTAssertEqual(c.state.health(two.id).status, .off)

        release = holdKeys(c)
        c.setEnabled(two.id, true); c.setEnabled(two.id, false); c.setEnabled(two.id, true)
        // The only live destination going off while the other waits for its key does not end the stream.
        c.setEnabled(one.id, false)
        XCTAssertTrue(c.isActive)
        release()
        XCTAssertTrue(spin(5) { c.state.health(two.id).status == .live })
        XCTAssertEqual(sessions[0].publishers(.wide).count, 1)
        XCTAssertEqual(connections(b), 1)
        XCTAssertEqual(sessions.count, 1)
    }

    /// Reviewer request: a destination toggled off and on repeatedly while live, with and without waiting.
    func testTogglingADestinationRepeatedlyWhileLive() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(); defer { a.stop(); b.stop() }
        let one = local("One", a), two = local("Two", b, .vertical)
        let c = try controller([one, two])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.health(one.id).status == .live && c.state.health(two.id).status == .live })
        let session = try XCTUnwrap(sessions.first)
        for round in 1...4 {
            c.setEnabled(two.id, false)
            XCTAssertEqual(c.state.health(two.id).status, .off)
            XCTAssertEqual(session.activeCanvases, [.wide], "round \(round)")
            c.setEnabled(two.id, true)
            XCTAssertTrue(spin(5) { c.state.health(two.id).status == .live }, "round \(round)")
            XCTAssertEqual(session.publishers(.vertical).count, 1, "round \(round)")
        }
        for _ in 1...5 { c.setEnabled(two.id, false); c.setEnabled(two.id, true) }
        XCTAssertTrue(spin(5) { c.state.health(two.id).status == .live })
        spin(0.5) { false }
        XCTAssertEqual(session.publishers(.vertical).count, 1, "no duplicate publishers")
        XCTAssertEqual(session.publishers(.wide).count, 1)
        XCTAssertEqual(c.state.health(one.id).status, .live, "the other destination stays live throughout")
        XCTAssertEqual(c.state.health(one.id).reconnects, 0)
        XCTAssertEqual(connections(a), 1)
        XCTAssertEqual(connections(b), 6, "Go Live, four rounds, and only the last of five quick switches")
        XCTAssertFalse(session.stopped)
    }

    /// A vertical lane that cannot start while wide is live fails that destination only.
    func testALaneThatCannotStartFailsOnlyItsDestination() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(); defer { a.stop(); b.stop() }
        var two = local("Two", b, .vertical); two.enabled = false
        let one = local("One", a)
        let c = try controller([one, two])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.health(one.id).status == .live })
        let session = try XCTUnwrap(sessions.first)
        session.failing = [.vertical]
        c.setEnabled(two.id, true)
        XCTAssertTrue(spin(5) { c.state.health(two.id).status != .connecting })
        XCTAssertEqual(c.state.health(two.id).status, .failed("Hardware H.264 encoder unavailable"))
        XCTAssertEqual(c.state.health(one.id).status, .live)
        XCTAssertFalse(session.stopped)
        XCTAssertTrue(c.isActive)
        XCTAssertTrue(toasts.contains("Two: hardware H.264 encoder unavailable"), "\(toasts)")
    }

    /// Editing a live destination's canvas applies from its next start; lane events follow the lane it runs on.
    func testLaneEventsFollowTheLaneADestinationRunsOnAfterAnEdit() throws {
        let a = try FakeRTMPServer(), b = try FakeRTMPServer(); defer { a.stop(); b.stop() }
        let wide = local("Wide", a), tall = local("Tall", b, .vertical)
        let c = try controller([wide, tall])
        c.goLive()
        XCTAssertTrue(spin(5) { c.state.health(wide.id).status == .live && c.state.health(tall.id).status == .live })
        let session = try XCTUnwrap(sessions.first)
        var edited = wide; edited.canvas = .vertical
        var saved: String?? = nil
        c.save(edited, key: nil) { saved = .some($0) }
        XCTAssertTrue(spin(5) { saved != nil }); XCTAssertNil(saved!)
        XCTAssertEqual(c.state.destinations.first { $0.id == wide.id }?.canvas, .vertical)
        XCTAssertEqual(session.publishers(.wide).count, 1, "still on its original lane until it restarts")

        // The vertical lane fails: only the destination really on it.
        session.publishers(.vertical).forEach { session.removePublisher($0) }
        session.onLaneError?(.vertical, "H.264 recovery failed")
        XCTAssertEqual(c.state.health(tall.id).status, .failed("H.264 recovery failed"))
        XCTAssertEqual(c.state.health(wide.id).status, .live)
        XCTAssertTrue(c.isActive)

        // The wide lane fails: the edited destination, which runs there, fails, and the stream ends.
        session.publishers(.wide).forEach { session.removePublisher($0) }
        session.onLaneError?(.wide, "H.264 recovery failed")
        XCTAssertEqual(c.state.health(wide.id).status, .failed("H.264 recovery failed"))
        XCTAssertFalse(c.isActive)
    }
}

/// The controller with the real StreamSession (Metal render and hardware encoders) against fake RTMP servers.
final class StreamControllerSessionTests: XCTestCase {
    private func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    /// Acceptance 4 automated: the card reads "Stream key rejected" and the server sees no retry, while a good
    /// destination keeps streaming. Then a vertical lane whose encoder cannot be created fails alone.
    func testRejectedKeyAndFailedLaneWithTheRealSession() throws {
        let good = try FakeRTMPServer(), bad = try FakeRTMPServer(), tall = try FakeRTMPServer()
        bad.reject = true
        defer { good.stop(); bad.stop(); tall.stop() }
        var frames = 0
        let lock = NSLock()
        good.onMessage = { _, m in if m.type == 9 { lock.lock(); frames += 1; lock.unlock() } }
        let goodFrames = { () -> Int in lock.lock(); defer { lock.unlock() }; return frames }
        let g = Destination(service: .custom, name: "Good", url: "rtmp://127.0.0.1:\(good.port)/live")
        let r = Destination(service: .custom, name: "Rejecting", url: "rtmp://127.0.0.1:\(bad.port)/live")
        let v = Destination(service: .custom, name: "Tall", url: "rtmp://127.0.0.1:\(tall.port)/live", canvas: .vertical, enabled: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehdr-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DestinationStore(url: dir.appendingPathComponent("streaming.json"))
        try store.save(StreamingConfig(destinations: [g, r, v], settings: { var s = StreamSettings(); s.resolution = 720; s.fps = 30; s.videoKbps = 2500; return s }()))
        let c = StreamController(state: StreamingState(), store: store, keychain: MemoryKeyStore())
        c.keyOverride = "secret-test-key"
        let demo = DemoSource(width: 64, height: 36, fps: 30)
        let renderer = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        var session: StreamSession?
        c.makeSession = { outputs, settings in
            let s = StreamSession(outputs: outputs, audioBitrate: settings.audioKbps * 1000, renderer: renderer, mixer: AudioMixer())
            session = s; return s
        }
        var toasts: [String] = []
        c.toast = { text, _, _ in toasts.append(text) }
        c.goLive(); defer { c.endStream() }
        XCTAssertTrue(spin(8) { c.state.health(g.id).status == .live && c.state.health(r.id).status != .connecting })
        XCTAssertEqual(StreamFormat.statusTitle(c.state.health(r.id).status), "Stream key rejected")
        XCTAssertTrue(toasts.contains("Rejecting: stream key rejected"), "\(toasts)")
        _ = spin(2.5) { false }
        XCTAssertEqual(c.state.health(r.id).status, .failed("Stream key rejected"), "a rejected key is not retried")
        XCTAssertEqual(Set(bad.messages.map(\.0)).count, 1, "one connection to the rejecting server")
        XCTAssertFalse((c.state.health(r.id).detail ?? "").contains("secret-test-key"))
        XCTAssertTrue(goodFrames() > 0)

        let live = try XCTUnwrap(session)
        var sessionErrors: [String] = []
        let forward = live.onError
        live.onError = { sessionErrors.append($0); forward?($0) }
        live.makeEncoder = { _ in nil }
        c.setEnabled(v.id, true)
        XCTAssertTrue(spin(5) { c.state.health(v.id).status != .connecting })
        XCTAssertEqual(c.state.health(v.id).status, .failed("Hardware H.264 encoder unavailable"))
        XCTAssertTrue(sessionErrors.isEmpty, "\(sessionErrors)")
        XCTAssertEqual(c.state.health(g.id).status, .live)
        XCTAssertEqual(live.activeCanvases, [.wide])
        let before = goodFrames()
        XCTAssertTrue(spin(4) { goodFrames() > before + 20 }, "the wide destination keeps streaming")
        XCTAssertEqual(Set(tall.messages.map(\.0)).count, 0)
        print("Real session: rejected=\(c.state.health(r.id).status) vertical=\(c.state.health(v.id).status) good frames=\(goodFrames())")
    }
}
