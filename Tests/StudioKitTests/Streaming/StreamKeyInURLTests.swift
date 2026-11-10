import XCTest
@testable import StudioKit

/// Stream keys in memory, so key handling is tested without depending on a usable keychain.
final class MemoryKeyStore: StreamKeyStore {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func set(_ key: String, for account: String) { lock.lock(); items[account] = key; lock.unlock() }
    func get(_ account: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[account] }
    func delete(_ account: String) { lock.lock(); items[account] = nil; lock.unlock() }
    func contains(_ account: String) -> Bool { get(account) != nil }
}

/// A stream key pasted at the end of the server URL ("URL + key") goes to the key store on every save and test
/// path, and never to `streaming.json`, the log, or a `Destination` value.
final class StreamKeyInURLTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ehdr-keyinurl-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { _ = LogTap.shared.stop(); try? FileManager.default.removeItem(at: dir) }

    @discardableResult private func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }
    private func save(_ c: StreamController, _ d: Destination, key: String?, keepPath: Bool = false) -> String? {
        var result: String??
        c.save(d, key: key, keepPath: keepPath) { result = .some($0) }
        XCTAssertTrue(spin(5) { result != nil }, "save did not answer")
        return result ?? "no answer"
    }

    func testEverySavePathKeepsAPastedKeyOutOfTheFileLogAndState() throws {
        let secret = "live_424242_synthetic\(UUID().uuidString.prefix(8))"
        let keys = MemoryKeyStore()
        let store = DestinationStore(url: dir.appendingPathComponent("streaming.json"))
        let youtube = Destination(service: .youtube)
        try store.save(StreamingConfig(destinations: [youtube]))
        keys.set("old-key", for: youtube.id.uuidString)
        let c = StreamController(state: StreamingState(), store: store, keychain: keys)
        LogTap.shared.start()

        // New Twitch destination, the key only in the URL: it moves to the key store.
        let twitch = Destination(service: .twitch, url: "rtmps://ingest.global-contribute.live-video.net:443/app/\(secret)")
        XCTAssertNil(save(c, twitch, key: nil))
        XCTAssertEqual(c.state.destinations.first { $0.id == twitch.id }?.url, "rtmps://ingest.global-contribute.live-video.net:443/app")
        XCTAssertEqual(keys.get(twitch.id.uuidString), secret)
        XCTAssertTrue(c.state.keyStored.contains(twitch.id))

        // Editing: an empty key field and a key in the URL replace the stored key.
        var edited = youtube; edited.url = "rtmps://a.rtmps.youtube.com:443/live2/\(secret)"
        XCTAssertNil(save(c, edited, key: nil))
        XCTAssertEqual(c.state.destinations.first { $0.id == youtube.id }?.url, "rtmps://a.rtmps.youtube.com:443/live2")
        XCTAssertEqual(keys.get(youtube.id.uuidString), secret)

        // The same key typed and in the URL is fine; a different typed key is refused and nothing changes.
        XCTAssertNil(save(c, edited, key: secret))
        keys.set("old-key", for: youtube.id.uuidString)
        let before = try String(contentsOf: store.url, encoding: .utf8)
        let refused = save(c, edited, key: "another-key")
        XCTAssertTrue(refused?.contains("differs") ?? false, "\(refused ?? "nil")")
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), before)
        XCTAssertEqual(keys.get(youtube.id.uuidString), "old-key")
        XCTAssertEqual(c.state.destinations.first { $0.id == youtube.id }?.url, "rtmps://a.rtmps.youtube.com:443/live2")

        // Twitch's key may carry a query; it belongs to the key, and the stored URL has none.
        var bandwidth = twitch; bandwidth.url = twitch.url + "?bandwidthtest=true"
        XCTAssertNil(save(c, bandwidth, key: nil))
        XCTAssertEqual(keys.get(twitch.id.uuidString), secret + "?bandwidthtest=true")
        XCTAssertEqual(c.state.destinations.first { $0.id == twitch.id }?.url, "rtmps://ingest.global-contribute.live-video.net:443/app")

        // A custom server needs an explicit choice: refused without it, kept as typed with it.
        let custom = Destination(service: .custom, name: "Home", url: "rtmp://10.0.0.2/live/\(secret)")
        XCTAssertTrue(save(c, custom, key: nil)?.contains("may be your stream key") ?? false)
        XCTAssertFalse(c.state.destinations.contains { $0.id == custom.id })
        var moved = custom; moved.url = "rtmp://10.0.0.2/live"
        XCTAssertNil(save(c, moved, key: secret), "the sheet's “Move It to the Key Field”")
        XCTAssertEqual(keys.get(custom.id.uuidString), secret)
        let wowza = Destination(service: .custom, name: "Wowza", url: "rtmp://10.0.0.3/app/_definst_")
        XCTAssertNil(save(c, wowza, key: "k", keepPath: true))
        XCTAssertEqual(c.state.destinations.first { $0.id == wowza.id }?.url, "rtmp://10.0.0.3/app/_definst_")

        let lines = LogTap.shared.stop()
        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains(secret.suffix(8)), json)
        XCTAssertFalse(lines.contains { $0.contains(secret.suffix(8)) }, "\(lines)")
        XCTAssertFalse(String(describing: c.state.destinations).contains(secret.suffix(8)))
        XCTAssertFalse(String(describing: store.load()).contains(secret.suffix(8)))
        print("Saved destinations: \(c.state.destinations.map { "\($0.service.rawValue) \($0.url)" })")
    }

    /// "Test connection" separates the key the same way: the server sees the application and the key apart.
    func testConnectionTestSplitsAPastedKey() throws {
        let secret = "synthetic-\(UUID().uuidString.prefix(8))"
        let server = try FakeRTMPServer(); defer { server.stop() }
        let c = StreamController(state: StreamingState(), store: DestinationStore(url: dir.appendingPathComponent("streaming.json")), keychain: MemoryKeyStore())
        LogTap.shared.start()
        var results: [ConnectionTestResult] = []
        let d = Destination(service: .youtube, url: "rtmp://127.0.0.1:\(server.port)/live2/\(secret)")
        c.testConnection(d, key: nil) { results.append($0) }
        c.testConnection(d, key: "different") { results.append($0) }
        c.testConnection(Destination(service: .custom, url: "rtmp://127.0.0.1:\(server.port)/live/\(secret)"), key: nil) { results.append($0) }
        XCTAssertTrue(spin(10) { results.count == 3 })
        let lines = LogTap.shared.stop()
        XCTAssertTrue(results.contains(.connected), "\(results)")
        XCTAssertTrue(results.contains { if case .failed("URL", let m) = $0 { return m.contains("differs") }; return false }, "\(results)")
        XCTAssertTrue(results.contains { if case .failed("URL", let m) = $0 { return m.contains("may be your stream key") }; return false }, "\(results)")
        let commands = server.messages.filter { $0.1.type == 20 }.compactMap { try? AMF0.decode($0.1.payload) }
        let app = commands.first { $0.first?.string == "connect" }?.compactMap(\.properties).first?["app"]?.string
        let published = commands.first { $0.first?.string == "publish" }.flatMap { $0.count > 3 ? $0[3].string : nil }
        XCTAssertEqual(app, "live2")
        XCTAssertEqual(published, secret)
        XCTAssertFalse(lines.contains { $0.contains(secret) }, "\(lines)")
    }

    /// The publisher logs the host only, and redacts a path that a mistaken URL carried, even in the server's words.
    func testPublisherNeverLogsTheApplicationPath() throws {
        let secret = "PATHSECRET-\(UUID().uuidString.prefix(8))"
        let server = try FakeRTMPServer(); server.reject = true; server.rejectDescription = "No such stream live/\(secret)"
        defer { server.stop() }
        let p = RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://127.0.0.1:\(server.port)/live/\(secret)")!, streamKey: "abc123",
                              metadata: StreamMetadata(width: 320, height: 180, fps: 30, videoKbps: 500, audioKbps: 128))
        LogTap.shared.start()
        var failure: String?
        p.onState = { st in if case .failed(let m) = st { DispatchQueue.main.async { failure = m } } }
        p.start(); defer { p.stop() }
        XCTAssertTrue(spin(5) { failure != nil })
        let lines = LogTap.shared.stop()
        XCTAssertTrue(lines.contains("RTMP connecting to 127.0.0.1"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains(secret) }, "\(lines)")
        XCTAssertEqual(failure, "No such stream live/[redacted]")
    }
}
