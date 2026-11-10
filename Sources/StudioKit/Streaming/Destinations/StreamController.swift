// Runs Go Live: reads the keys, plans one output per canvas, starts the session, and turns publisher states and
// statistics into StreamingState. Destinations start, stop, fail and recover independently; the session ends only
// when none is left. Everything here runs on the main thread except Keychain access.
import Foundation

/// What the controller needs from a stream session; StreamSession in the app, a fake in tests.
protocol StreamSessionDriving: AnyObject {
    var onStats: ((StreamSession.Stats) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onLaneError: ((Canvas, String) -> Void)? { get set }
    var onRecovery: ((Canvas) -> Void)? { get set }
    func replaceRenderer(_ renderer: Renderer)
    var activeCanvases: [Canvas] { get }
    func start() -> Bool
    func stop()
    /// Throws `StreamSession.LaneFailure` when this publisher's lane cannot start; the other lanes are unaffected.
    func addPublisher(_ publisher: RTMPPublisher, to output: StreamSession.Output) throws
    func removePublisher(_ publisher: RTMPPublisher)
}
extension StreamSession: StreamSessionDriving {}

final class StreamController {
    let state: StreamingState
    private let store: DestinationStore
    private let keychain: StreamKeyStore
    /// `--go-live-for` with `EHDR_STREAM_KEY` (the self-test script): one key for every destination, no Keychain.
    var keyOverride: String?
    /// Builds the session for the planned outputs; nil when streaming is unavailable (no capture renderer yet).
    var makeSession: ([StreamSession.Output], StreamSettings) -> StreamSessionDriving? = { _, _ in nil }
    var makePublisher: (Destination, StreamEndpoint, String, StreamSettings) -> RTMPPublisher = { d, endpoint, key, settings in
        RTMPPublisher(endpoint: endpoint, streamKey: key, metadata: StreamPlanner.metadata(d.canvas, settings: settings))
    }
    var toast: (String, String?, Toast.Style) -> Void = { _, _, _ in }
    var onMicDelay: (Double) -> Void = { _ in }
    /// Runs Keychain calls; they can block on a macOS access prompt, so never on main in the app.
    var keyQueue = DispatchQueue(label: "studio.stream.keys", qos: .userInitiated)

    private var session: StreamSessionDriving?
    private var runtimes: [UUID: Runtime] = [:]
    private var anyFailed = false
    /// Bumped by every Go Live and every stop: key reads started under an older value are ignored.
    private var generation = 0
    /// The Go Live whose keys are being read (the session does not exist yet); nil otherwise.
    private var pendingStart: Int?
    /// Destinations starting on their own while live, with the token of their latest key read: turning one off,
    /// or on again, makes an earlier read stale.
    private var pendingSingle: [UUID: Int] = [:]
    private var singleToken = 0
    private var testers: [ObjectIdentifier: ConnectionTester] = [:]

    private final class Runtime {
        let publisher: RTMPPublisher
        /// The lane it really runs on. Editing the destination's canvas while live applies from its next start, so
        /// lane events go by this, not by the destination's current canvas.
        let canvas: Canvas
        var everLive = false
        var drops = DropTracker()
        init(_ p: RTMPPublisher, canvas: Canvas) { publisher = p; self.canvas = canvas }
    }

    init(state: StreamingState, store: DestinationStore = DestinationStore(), keychain: StreamKeyStore = KeychainStore()) {
        self.state = state; self.store = store; self.keychain = keychain
        let config = store.load()
        state.destinations = config.destinations; state.settings = config.settings
        refreshKeyStatus()
    }

    var isActive: Bool { session != nil || pendingStart != nil }

    func replaceRenderer(_ renderer: Renderer) { session?.replaceRenderer(renderer) }

    // MARK: Configuration

    /// Saves `destination` and, when given, its key. A stream key pasted into the URL never reaches `streaming.json`
    /// or StreamingState: for a known service it moves to the Keychain here (refused if a different key was typed);
    /// for a custom server, whose path may legitimately have several components, `keepPath` says the user chose to
    /// keep it, otherwise the save is refused until they choose.
    func save(_ destination: Destination, key: String?, keepPath: Bool = false, done: @escaping (String?) -> Void) {
        var d = destination
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.name.isEmpty { done("Give the destination a name."); return }
        let newKey: String?
        switch Destination.separatingKey(url: d.url, key: key, service: d.service, keepPath: keepPath) {
        case .failure(let problem): done(problem.description); return
        case .success(let separated): d.url = separated.url; newKey = separated.key
        }
        if let problem = Destination.urlProblem(d.url, service: d.service) { done(problem); return }
        let isNew = !state.destinations.contains { $0.id == d.id }
        if isNew, d.service != .custom, newKey == nil { done("Paste the stream key."); return }
        let keychain = keychain
        keyQueue.async { [weak self] in
            var error: String?
            if let newKey {
                do { try keychain.set(newKey, for: d.id.uuidString) } catch let f as KeychainStore.Failure { error = f.message } catch { }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { done(error); return }
                if newKey != nil { self.state.keyStored.insert(d.id) }
                if let i = self.state.destinations.firstIndex(where: { $0.id == d.id }) {
                    let old = self.state.destinations[i]
                    self.state.destinations[i] = d
                    // A live destination keeps its connection, canvas and key until it next starts (the sheet says so).
                    if old.enabled != d.enabled { self.setEnabled(d.id, d.enabled, persist: false) }
                } else {
                    self.state.destinations.append(d)
                    if self.isActive && d.enabled { self.turnedOn(d.id) }
                }
                self.persist(); done(nil)
            }
        }
    }

    func delete(_ id: UUID) {
        let name = state.destinations.first { $0.id == id }?.name
        state.destinations.removeAll { $0.id == id }
        if isActive { stopDestination(id, name: name) }
        state.health[id] = nil; state.keyStored.remove(id)
        persist()
        let keychain = keychain
        keyQueue.async { try? keychain.delete(id.uuidString) }
    }

    func setEnabled(_ id: UUID, _ on: Bool, persist save: Bool = true) {
        if let i = state.destinations.firstIndex(where: { $0.id == id }), state.destinations[i].enabled != on {
            state.destinations[i].enabled = on
        }
        if save { persist() }
        guard isActive else { return }
        if on { turnedOn(id) } else { stopDestination(id, name: state.destinations.first { $0.id == id }?.name) }
    }

    func updateSettings(_ settings: StreamSettings) {
        let s = settings.sanitized
        guard s != state.settings else { return }
        if s.micDelayMs != state.settings.micDelayMs { onMicDelay(s.micDelayMs) }
        state.settings = s; persist()
    }

    private func persist() {
        do { try store.save(StreamingConfig(destinations: state.destinations, settings: state.settings)) }
        catch { log("streaming: could not save \(store.url.lastPathComponent): \(error.localizedDescription)") }
    }

    func refreshKeyStatus() {
        let ids = state.destinations.map(\.id), keychain = keychain
        keyQueue.async { [weak self] in
            let stored = Set(ids.filter { keychain.contains($0.uuidString) })
            DispatchQueue.main.async { self?.state.keyStored = stored }
        }
    }

    // MARK: Going live

    /// Starts every enabled destination. Pressed again while the keys are still being read (macOS may be asking for
    /// the Keychain password), it replaces that pending start with one for the destinations enabled now.
    func goLive() {
        guard session == nil else { return }
        let enabled = state.destinations.filter(\.enabled)
        guard !enabled.isEmpty else {
            if pendingStart != nil { cancelPendingStart(); return }
            toast(state.destinations.isEmpty ? "Add a destination to go live" : "Turn on a destination to go live", nil, .info); return
        }
        if pendingStart != nil { log("stream: Go Live again while reading keys; the earlier start is replaced") }
        let settings = state.settings
        generation += 1
        let token = generation
        pendingStart = token
        state.phase = .connecting; state.liveSettings = settings; state.canvases = []; anyFailed = false
        for d in enabled { state.health[d.id] = DestinationHealth(status: .connecting) }
        for d in state.destinations where !d.enabled { state.health[d.id] = nil }
        log("stream: going live to \(enabled.count) destination(s) at \(settings.resolution)p\(settings.fps) \(settings.videoKbps) kbps")
        // A Keychain read waits silently while macOS shows its access prompt (after a rebuild of an ad-hoc signed app).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.pendingStart == token else { return }
            self.toast("Waiting for Keychain access", "macOS may be asking for your password to read the stream keys.", .warning)
        }
        readKeys(enabled) { [weak self] keys in
            guard let self, self.pendingStart == token, self.generation == token, self.session == nil else { return }
            self.pendingStart = nil
            // The list may have changed during the read: only destinations still there and still on go live, with
            // their current URL and canvas. One turned on meanwhile replaced this start, so every one has a key read.
            let live = self.state.destinations.filter { $0.enabled && keys[$0.id] != nil }
            guard !live.isEmpty else {
                self.finish(reason: "every destination was turned off")
                self.toast("Go Live cancelled", "Every destination was turned off.", .info); return
            }
            var publishers: [UUID: RTMPPublisher] = [:]
            for d in live {
                switch keys[d.id] ?? .failure("No stream key saved") {
                case .success(let key):
                    guard let endpoint = d.endpoint else { self.fail(d, "The server URL is not valid", detail: nil); continue }
                    publishers[d.id] = self.makePublisher(d, endpoint, key, settings)
                case .failure(let message): self.fail(d, message.description, detail: nil)
                }
            }
            let outputs = StreamPlanner.plan(destinations: live, settings: settings) { publishers[$0.id] }
            guard !outputs.isEmpty else { self.finish(reason: nil); return }
            guard let session = self.makeSession(outputs, settings) else {
                self.toast("Streaming is not available yet", "Wait for the picture to appear, then try again.", .warning)
                self.finish(reason: nil); return
            }
            for d in live { if let p = publishers[d.id] { self.watch(p, for: d.id, canvas: d.canvas) } }
            session.onStats = { [weak self] in self?.apply($0) }
            session.onError = { [weak self] message in self?.sessionFailed(message) }
            session.onLaneError = { [weak self] canvas, message in self?.laneFailed(canvas, message) }
            session.onRecovery = { [weak self] canvas in
                guard let self else { return }
                self.state.encoderRecoveryEvents += 1
                self.toast("\(canvas.label) encoder recovered", nil, .info)
                log("stream \(canvas.rawValue): encoder recovered")
            }
            self.session = session
            guard session.start() else { self.session = nil; self.finish(reason: nil); return }
        }
    }

    /// Every destination on that lane failed with it; the destinations on the other lane keep streaming.
    private func laneFailed(_ canvas: Canvas, _ message: String) {
        for (id, r) in runtimes where r.canvas == canvas {
            runtimes[id] = nil
            r.publisher.onState = nil
            if let d = state.destinations.first(where: { $0.id == id }) { fail(d, message, detail: nil) }
        }
        state.canvases.removeAll { $0.canvas == canvas }
        checkEnded()
    }

    private func cancelPendingStart() {
        finish(reason: "every destination was turned off")
        toast("Go Live cancelled", "Every destination was turned off.", .info)
    }

    func endStream() {
        guard isActive else { return }
        finish(reason: nil)
        toast("Stream ended", nil, .info)
    }

    func retry(_ id: UUID) {
        guard isActive, runtimes[id] == nil, state.destinations.contains(where: { $0.id == id }) else { return }
        turnedOn(id)
    }

    // MARK: Connection test

    /// Tests `destination` with `key`, or its saved key. The URL is separated from a pasted key exactly as on save.
    func testConnection(_ destination: Destination, key: String?, keepPath: Bool = false, done: @escaping (ConnectionTestResult) -> Void) {
        let url: String, typed: String?
        switch Destination.separatingKey(url: destination.url, key: key, service: destination.service, keepPath: keepPath) {
        case .failure(let problem): done(.failed(stage: "URL", message: problem.description)); return
        case .success(let separated): url = separated.url; typed = separated.key
        }
        guard let endpoint = StreamEndpoint(url: url) else {
            done(.failed(stage: "URL", message: Destination.urlProblem(url, service: destination.service) ?? "The URL is not valid.")); return
        }
        let settings = state.settings
        let run: (String) -> Void = { [weak self] key in
            let tester = ConnectionTester()
            let id = ObjectIdentifier(tester)
            self?.testers[id] = tester
            tester.run(endpoint: endpoint, key: key, metadata: StreamPlanner.metadata(destination.canvas, settings: settings)) { result in
                self?.testers[id] = nil
                log("stream: test connection to \(destination.name) (\(endpoint.host)): \(result == .connected ? "connected" : "failed")")
                done(result)
            }
        }
        if let typed { run(typed); return }
        readKeys([destination]) { keys in
            switch keys[destination.id] ?? .failure("No stream key saved") {
            case .success(let key): run(key)
            case .failure(let message): done(.failed(stage: "Stream key", message: message.description))
            }
        }
    }

    // MARK: Per-destination control

    /// A destination was turned on, added or retried while streaming or while Go Live reads keys.
    private func turnedOn(_ id: UUID) {
        if session == nil { goLive() } else if runtimes[id] == nil { startDestination(id) }
    }

    private func startDestination(_ id: UUID) {
        guard let d = state.destinations.first(where: { $0.id == id }), let settings = state.liveSettings, session != nil else { return }
        state.health[id] = DestinationHealth(status: .connecting)
        singleToken += 1
        let token = generation, attempt = singleToken
        pendingSingle[id] = attempt
        readKeys([d]) { [weak self] keys in
            // Only the latest start of this destination counts; turning it off meanwhile cancelled it.
            guard let self, self.generation == token, self.pendingSingle[id] == attempt else { return }
            self.pendingSingle[id] = nil
            guard let session = self.session, self.runtimes[id] == nil,
                  let d = self.state.destinations.first(where: { $0.id == id }), d.enabled else { self.checkEnded(); return }
            switch keys[id] ?? .failure("No stream key saved") {
            case .failure(let message): self.fail(d, message.description, detail: nil); self.checkEnded()
            case .success(let key):
                guard let endpoint = d.endpoint else { self.fail(d, "The server URL is not valid", detail: nil); self.checkEnded(); return }
                let p = self.makePublisher(d, endpoint, key, settings)
                self.watch(p, for: id, canvas: d.canvas)
                let group = StreamPlanner.Group(canvas: d.canvas, size: settings.size(d.canvas), fps: Double(settings.fps),
                                                videoBitrate: settings.videoKbps * 1000, destinations: [d])
                do { try session.addPublisher(p, to: StreamPlanner.output(for: group, publishers: [])) } catch {
                    // Only this destination: the lanes already running carry on.
                    p.onState = nil; self.runtimes[id] = nil
                    self.fail(d, (error as? StreamSession.LaneFailure)?.description ?? "Could not start the encoder", detail: nil)
                    self.checkEnded()
                }
            }
        }
    }

    /// The user turned a destination off or deleted it.
    private func stopDestination(_ id: UUID, name: String?) {
        guard runtimes[id] != nil || pendingSingle[id] != nil || state.health(id).status != .off else { return }
        pendingSingle[id] = nil
        if let r = runtimes.removeValue(forKey: id) { r.publisher.onState = nil; session?.removePublisher(r.publisher) }
        state.health[id] = nil
        if let name { log("stream: \(name) stopped") }
        if session == nil, pendingStart != nil, !state.destinations.contains(where: \.enabled) { cancelPendingStart(); return }
        checkEnded(userStopped: true)
    }

    private func watch(_ publisher: RTMPPublisher, for id: UUID, canvas: Canvas) {
        runtimes[id] = Runtime(publisher, canvas: canvas)
        publisher.onState = { [weak self, weak publisher] st in
            // On the publisher's queue, where its stats can be read without blocking.
            let error = { () -> String? in if case .reconnecting = st { return publisher?.stats.lastError }; return nil }()
            DispatchQueue.main.async {
                guard let self, let publisher, self.runtimes[id]?.publisher === publisher else { return }
                self.publisherChanged(id, st, error: error)
            }
        }
    }

    private func publisherChanged(_ id: UUID, _ st: RTMPPublisher.State, error: String?) {
        guard let r = runtimes[id], let d = state.destinations.first(where: { $0.id == id }) else { return }
        var h = state.health(id)
        switch st {
        case .idle: return
        case .connecting:
            if !r.everLive { h.status = .connecting }
        case .publishing:
            if case .reconnecting = h.status { toast("\(d.name) is live again", nil, .success) }
            r.everLive = true
            h.status = .live; h.detail = nil
            if h.liveSince == nil { h.liveSince = Date() }
            log("stream: \(d.name) live")
            if state.phase == .connecting { state.phase = .live(since: Date()) }
        case .reconnecting(let attempt, _):
            // A connection that was live and then closed is a network or server problem, not a key problem.
            let closed = (error ?? "").lowercased().hasPrefix("connection closed")
            let text = r.everLive && closed ? "The server closed the connection." : StreamErrorText.describe(error).message
            if attempt == 1 { toast("\(d.name): \(r.everLive ? "connection lost, reconnecting" : "cannot connect, retrying")", text, .warning) }
            h.status = .reconnecting(attempt: attempt); h.detail = text
            log("stream: \(d.name) reconnecting (attempt \(attempt))")
        case .failed(let message):
            runtimes[id] = nil
            r.publisher.onState = nil
            session?.removePublisher(r.publisher)
            state.health[id] = h
            fail(d, message == "Invalid RTMP port" ? "Invalid port in the server URL" : "Stream key rejected", detail: message)
            checkEnded()
            return
        }
        state.health[id] = h
    }

    /// Marks a destination failed for good (until retried) and says so.
    private func fail(_ d: Destination, _ reason: String, detail: String?) {
        anyFailed = true
        var h = state.health(d.id)
        h.status = .failed(reason); h.detail = detail; h.kbps = 0; h.slowUpload = false
        state.health[d.id] = h
        toast("\(d.name): \(reason.prefix(1).lowercased() + reason.dropFirst())", detail, .error)
        log("stream: \(d.name) failed: \(reason)")
    }

    private func checkEnded(userStopped: Bool = false) {
        guard session != nil, runtimes.isEmpty, pendingSingle.isEmpty else { return }
        let reason = userStopped ? "Stream ended: every destination is off" : "Stream ended: no destination could stay connected"
        finish(reason: reason)
        toast(reason, nil, userStopped ? .info : .error)
    }

    private func sessionFailed(_ message: String) {
        log("stream: \(message)")
        guard isActive else { return }
        finish(reason: message)
        toast("Stream ended", message, .error)
    }

    /// Stops everything; failed cards keep their reason so the user can see what happened.
    private func finish(reason: String?) {
        generation += 1
        pendingStart = nil; pendingSingle = [:]
        let s = session; session = nil
        for r in runtimes.values { r.publisher.onState = nil }
        runtimes = [:]
        s?.stop()
        state.phase = .idle; state.liveSettings = nil; state.canvases = []
        for (id, h) in state.health { if case .failed = h.status { continue }; state.health[id] = nil }
        if let reason { log("stream: ended (\(reason))") } else { log("stream: ended") }
    }

    private func apply(_ stats: StreamSession.Stats) {
        guard let session else { return }
        let c = CanvasHealth(canvas: stats.canvas, fps: stats.fps, renderMs: stats.renderMs, encodeMs: stats.encodeMs,
                             dropped: stats.renderDropped + stats.encoderDropped,
                             rateSkipped: stats.renderSkips.rateSkipped, contention: stats.renderSkips.contention,
                             capacity: stats.renderSkips.capacity, stale: stats.renderSkips.stale, gpu: stats.renderSkips.gpu,
                             inactive: stats.renderSkips.inactive, encoderDropped: stats.encoderDropped)
        var canvases = state.canvases.filter { $0.canvas != stats.canvas && session.activeCanvases.contains($0.canvas) }
        canvases.append(c); canvases.sort { $0.canvas == .wide && $1.canvas == .vertical }
        if state.canvases != canvases { state.canvases = canvases }
        log(String(format: "stream %@: %.1f fps render %.3f ms encode %.3f ms dropped render=%d encoder=%d", stats.canvas.rawValue,
                   stats.fps, stats.renderMs, stats.encodeMs, stats.renderDropped, stats.encoderDropped))
        for (oid, p) in zip(stats.publisherIDs, stats.publishers) {
            guard let (id, r) = runtimes.first(where: { ObjectIdentifier($0.value.publisher) == oid }) else { continue }
            var h = state.health(id)
            h.kbps = p.kbps; h.dropped = p.droppedFrames; h.reconnects = p.reconnects
            h.slowUpload = r.drops.update(dropped: p.droppedFrames, pendingMs: p.pendingMs) && h.status == .live
            if state.health[id] != h { state.health[id] = h }
            let name = state.destinations.first { $0.id == id }?.name ?? "?"
            log(String(format: "stream upload %@: %.0f kbps pendingMs=%.2f dropped=%d reconnects=%d", name, p.kbps, p.pendingMs, p.droppedFrames, p.reconnects))
        }
    }

    // MARK: Keys

    private func readKeys(_ destinations: [Destination], done: @escaping ([UUID: Result<String, KeyError>]) -> Void) {
        let override = keyOverride, keychain = keychain
        keyQueue.async {
            var out: [UUID: Result<String, KeyError>] = [:]
            for d in destinations {
                if let override { out[d.id] = .success(override); continue }
                do {
                    if let key = try keychain.get(d.id.uuidString), !key.isEmpty { out[d.id] = .success(key) }
                    else if d.service == .custom { out[d.id] = .success("") }
                    else { out[d.id] = .failure("No stream key saved. Edit the destination to add it") }
                } catch let f as KeychainStore.Failure {
                    out[d.id] = .failure(KeyError(f == .accessDenied ? "Keychain access was denied. Enter the stream key again" : f.message))
                } catch { out[d.id] = .failure("Keychain error") }
            }
            DispatchQueue.main.async { done(out) }
        }
    }
}

struct KeyError: Error, ExpressibleByStringLiteral, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
    init(stringLiteral s: String) { description = s }
}
