import XCTest
@testable import StudioKit

final class DestinationTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehdr-destinations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPresetsAndDefaults() {
        let twitch = Destination(service: .twitch)
        XCTAssertEqual(twitch.name, "Twitch")
        XCTAssertEqual(twitch.url, "rtmps://ingest.global-contribute.live-video.net:443/app")
        XCTAssertEqual(twitch.endpoint?.tcUrl, "rtmps://ingest.global-contribute.live-video.net:443/app")
        XCTAssertEqual(Destination(service: .youtube, canvas: .vertical).name, "YouTube Shorts")
        XCTAssertEqual(Destination(service: .youtube).endpoint?.app, "live2")
        XCTAssertEqual(Destination(service: .kick).url, "")
        XCTAssertNil(Destination(service: .custom).endpoint)
        for s in Destination.Service.allCases where s != .custom { XCTAssertNotNil(s.preset.helpURL) }
    }

    func testLenientDecoding() throws {
        let json = """
        {"destinations":[
          {"service":"youtube","url":"rtmps://a.rtmps.youtube.com:443/live2","canvas":"vertical"},
          {"service":"myspace","name":"Old","url":"rtmp://x/live","enabled":false,"extra":1},
          {"id":"not-a-uuid","canvas":"square"},
          42
        ],"settings":{"resolution":900,"fps":24,"videoKbps":"fast","audioKbps":999,"micDelayMs":40}}
        """
        let c = try JSONDecoder().decode(StreamingConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.destinations.count, 3, "an entry that is not an object is skipped, the others survive")
        XCTAssertEqual(c.destinations[0].service, .youtube)
        XCTAssertEqual(c.destinations[0].name, "YouTube Shorts")
        XCTAssertEqual(c.destinations[0].canvas, .vertical)
        XCTAssertTrue(c.destinations[0].enabled)
        XCTAssertEqual(c.destinations[1].service, .custom)
        XCTAssertEqual(c.destinations[1].name, "Old")
        XCTAssertFalse(c.destinations[1].enabled)
        XCTAssertEqual(c.destinations[2].canvas, .wide)
        XCTAssertEqual(c.settings.resolution, 1080)
        XCTAssertEqual(c.settings.fps, 60)
        XCTAssertEqual(c.settings.videoKbps, 6000)
        XCTAssertEqual(c.settings.audioKbps, 320)
        XCTAssertEqual(c.settings.micDelayMs, 40)
        XCTAssertEqual(try JSONDecoder().decode(StreamingConfig.self, from: Data("{}".utf8)), StreamingConfig())
    }

    func testStoreRoundTripAndDamagedFile() throws {
        let store = DestinationStore(url: dir.appendingPathComponent("sub/streaming.json"))
        XCTAssertEqual(store.load(), StreamingConfig())
        var config = StreamingConfig(destinations: [Destination(service: .twitch), Destination(service: .custom, name: "Home", url: "rtmp://10.0.0.2/live", canvas: .vertical, enabled: false)])
        config.settings.videoKbps = 4500; config.settings.resolution = 720
        try store.save(config)
        XCTAssertEqual(store.load(), config)
        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), StreamingConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub/streaming.damaged.json").path))
    }

    func testURLHelpers() {
        XCTAssertEqual(Destination.normalizedURL(" rtmps://fa723fc1b171.global-contribute.live-video.net:443 ", service: .kick),
                       "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app")
        XCTAssertEqual(Destination.normalizedURL("rtmp://host", service: .custom), "rtmp://host")
        let split = Destination.splitKey(from: "rtmps://a.rtmps.youtube.com:443/live2/abcd-efgh-ijkl", service: .youtube)
        XCTAssertEqual(split?.url, "rtmps://a.rtmps.youtube.com:443/live2")
        XCTAssertEqual(split?.key, "abcd-efgh-ijkl")
        XCTAssertEqual(Destination.splitKey(from: "rtmps://ingest.global-contribute.live-video.net/app/live_123_abc", service: .twitch)?.key, "live_123_abc")
        XCTAssertNil(Destination.splitKey(from: "rtmps://a.rtmps.youtube.com:443/live2", service: .youtube))
        XCTAssertNil(Destination.splitKey(from: "rtmp://host/live/name", service: .custom), "a custom server's path may have several components")
        XCTAssertNil(Destination.urlProblem("rtmp://127.0.0.1:1935/live", service: .custom))
        XCTAssertNotNil(Destination.urlProblem("", service: .kick))
        XCTAssertNotNil(Destination.urlProblem("https://twitch.tv", service: .twitch))
        XCTAssertNotNil(Destination.urlProblem("rtmp://host", service: .custom))
    }

    func testPlannerGroupsByCanvas() {
        let a = Destination(service: .twitch), b = Destination(service: .custom, url: "rtmp://h/live")
        let v = Destination(service: .youtube, canvas: .vertical), off = Destination(service: .kick, url: "rtmps://k/app", canvas: .vertical, enabled: false)
        var s = StreamSettings()
        var groups = StreamPlanner.groups(destinations: [v, a, off, b], settings: s)
        XCTAssertEqual(groups.map(\.canvas), [.wide, .vertical])
        XCTAssertEqual(groups[0].destinations.map(\.id), [a.id, b.id])
        XCTAssertEqual(groups[0].size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(groups[1].size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(groups[1].destinations.map(\.id), [v.id])
        XCTAssertEqual(groups[0].videoBitrate, 6_000_000)
        XCTAssertEqual(StreamPlanner.uploadSummary(enabled: 3, settings: s), "3 destinations · about 18.5 Mbps upload")
        XCTAssertEqual(StreamPlanner.uploadSummary(enabled: 1, settings: s), "1 destination · about 6.2 Mbps upload")
        s.resolution = 720; s.fps = 30
        groups = StreamPlanner.groups(destinations: [a, v], settings: s)
        XCTAssertEqual(groups.map(\.size), [CGSize(width: 1280, height: 720), CGSize(width: 720, height: 1280)])
        XCTAssertEqual(groups[0].fps, 30)
        XCTAssertTrue(StreamPlanner.groups(destinations: [off], settings: s).isEmpty)
        // Destinations whose publisher cannot be built are left out; an output with none is dropped.
        let outputs = StreamPlanner.plan(destinations: [a, b, v], settings: s) { d in
            d.id == v.id ? nil : RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://127.0.0.1/live")!, streamKey: "k", metadata: StreamPlanner.metadata(d.canvas, settings: s))
        }
        XCTAssertEqual(outputs.map(\.canvas), [.wide]); XCTAssertEqual(outputs[0].publishers.count, 2)
        let m = StreamPlanner.metadata(.vertical, settings: s)
        XCTAssertEqual([m.width, m.height, m.videoKbps, m.audioKbps], [720, 1280, 6000, 160])
    }

    func testDropTrackerAndErrorText() {
        var t = DropTracker()
        XCTAssertFalse(t.update(dropped: 0, pendingMs: 0))
        XCTAssertFalse(t.update(dropped: 3, pendingMs: 0))
        XCTAssertFalse(t.update(dropped: 3, pendingMs: 0))
        XCTAssertFalse(t.update(dropped: 9, pendingMs: 0))
        XCTAssertTrue(t.update(dropped: 12, pendingMs: 0), "new drops in three of five reports")
        for _ in 0..<4 { XCTAssertTrue(t.update(dropped: 12, pendingMs: 0)) }
        XCTAssertFalse(t.update(dropped: 12, pendingMs: 0), "five clean reports clear it")
        var p = DropTracker()
        for _ in 0..<2 { _ = p.update(dropped: 0, pendingMs: 2000) }
        XCTAssertTrue(p.update(dropped: 0, pendingMs: 2000), "a backlog counts as dropping")
        XCTAssertEqual(StreamErrorText.describe("TCP/TLS: POSIXErrorCode(rawValue: 61): Connection refused").stage, "Connect")
        XCTAssertTrue(StreamErrorText.describe("TCP/TLS: POSIXErrorCode(rawValue: 61): Connection refused").message.contains("refused"))
        XCTAssertEqual(StreamErrorText.describe("TCP/TLS: -9836: bad protocol version").stage, "Secure connection")
        XCTAssertEqual(StreamErrorText.describe("handshake timed out").stage, "Handshake")
        XCTAssertEqual(StreamErrorText.describe("publish timed out").stage, "Publish")
        XCTAssertTrue(StreamErrorText.describe("Connection closed").message.contains("stream key"))
    }
}

/// Keychain tests use their own service name and delete what they create. A keychain that would ask the user (no
/// one is there to answer in CI or an agent session) skips the test instead of hanging it.
final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "dev.max.elgato-hdr.stream-key.tests.\(UUID().uuidString)")
    private var accounts: [String] = []
    override func tearDown() { for a in accounts { try? store.delete(a) } }

    /// Runs `body` on another thread so a pending access prompt cannot hang the test runner.
    private func guarded<T>(_ what: String, _ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { result = Result { try body() }; done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else {
            throw XCTSkip("Keychain \(what) did not return within 10 s (probably waiting for a user prompt); skipped")
        }
        do { return try result!.get() }
        catch KeychainStore.Failure.accessDenied { throw XCTSkip("Keychain \(what) needs user interaction here; skipped") }
        // CI runners may have no usable login keychain (errSecNoSuchKeychain, errSecNotAvailable, missing entitlement).
        catch KeychainStore.Failure.unexpected(let status) { throw XCTSkip("Keychain \(what) unavailable here (OSStatus \(status)); skipped") }
    }

    func testSetGetUpdateDelete() throws {
        let account = UUID().uuidString; accounts.append(account)
        XCTAssertNil(try guarded("read") { try self.store.get(account) })
        try guarded("write") { try self.store.set("live_123_secret", for: account) }
        XCTAssertEqual(try guarded("read") { try self.store.get(account) }, "live_123_secret")
        XCTAssertTrue(store.contains(account))
        try guarded("update") { try self.store.set("second-key", for: account) }
        XCTAssertEqual(try guarded("read") { try self.store.get(account) }, "second-key")
        try guarded("delete") { try self.store.delete(account) }
        XCTAssertNil(try guarded("read") { try self.store.get(account) })
        XCTAssertFalse(store.contains(account))
        try guarded("delete") { try self.store.delete(account) }   // deleting nothing is fine
    }

    /// Saving through the controller puts the key in the Keychain and nowhere in streaming.json; deleting the
    /// destination deletes its key.
    func testControllerKeepsKeysOutOfTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehdr-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileStore = DestinationStore(url: dir.appendingPathComponent("streaming.json"))
        let controller = StreamController(state: StreamingState(), store: fileStore, keychain: store)
        let d = Destination(service: .twitch)
        accounts.append(d.id.uuidString)
        let saved = expectation(description: "saved")
        var error: String? = "not called"
        controller.save(d, key: "live_987_topsecret") { error = $0; saved.fulfill() }
        if XCTWaiter.wait(for: [saved], timeout: 10) != .completed { throw XCTSkip("Keychain write did not return within 10 s; skipped") }
        if let error, error.contains("Keychain") { throw XCTSkip("Keychain write refused here: \(error)") }
        XCTAssertNil(error)
        let json = try String(contentsOf: fileStore.url, encoding: .utf8)
        XCTAssertTrue(json.contains(d.id.uuidString)); XCTAssertFalse(json.contains("topsecret"))
        XCTAssertEqual(try guarded("read") { try self.store.get(d.id.uuidString) }, "live_987_topsecret")
        controller.delete(d.id)
        let gone = expectation(description: "key deleted")
        controller.keyQueue.async { gone.fulfill() }
        if XCTWaiter.wait(for: [gone], timeout: 10) != .completed { throw XCTSkip("Keychain delete did not return within 10 s; skipped") }
        XCTAssertNil(try guarded("read") { try self.store.get(d.id.uuidString) })
        XCTAssertTrue(controller.state.destinations.isEmpty)
    }
}
