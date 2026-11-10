import Foundation
import Network

final class RTMPPublisher {
    enum State: Equatable {
        case idle, connecting, publishing, reconnecting(attempt: Int, inSeconds: Double), failed(String)
    }
    struct Stats {
        var bytesSent: Int64 = 0
        var kbps: Double = 0
        var droppedFrames = 0
        var pendingMs: Double = 0
        var reconnects = 0
        var lastError: String?
    }

    private let callbackLock = NSLock()
    private var stateCallback: ((State) -> Void)?
    private var keyframeCallback: (() -> Void)?
    var onState: ((State) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return stateCallback }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; stateCallback = newValue }
    }
    var onNeedKeyframe: (() -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return keyframeCallback }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; keyframeCallback = newValue }
    }
    private let endpoint: StreamEndpoint
    private let streamKey: String
    private let metadata: StreamMetadata
    private let queue = DispatchQueue(label: "studio.rtmp.publisher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var connection: NWConnection?
    private var generation = 0
    private var active = false
    private var state: State = .idle
    private var parser = RTMPDechunker()
    private var handshake = Data()
    private var handshaking = true
    private var outChunkSize = 128
    private var streamId: UInt32 = 0
    private var transaction = 5
    private var attempt = 0
    private var timeout: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var counters = Stats()
    private var pendingBytes: Int64 = 0
    private var confirmed: [(Double, Int)] = []
    private var received: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0
    private var window: UInt64 = 0
    private var videoConfig: Data?
    private var audioConfig: Data?
    private var baseNs: UInt64?
    private var firstVideoPTS: UInt64?
    private var needsKeyframe = true
    private var pressure = RTMPPressure()
    private var lastMediaTimestamp: UInt32 = 0
    private var hasPublished = false
    private var awaited: (id: Double, stage: String)?

    init(endpoint: StreamEndpoint, streamKey: String, metadata: StreamMetadata) {
        self.endpoint = endpoint; self.streamKey = streamKey; self.metadata = metadata
        queue.setSpecific(key: queueKey, value: true)
    }

    var stats: Stats {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return snapshot() }
        return queue.sync { snapshot() }
    }

    func start() { queue.async { [self] in
        guard !active else { return }
        active = true; attempt = 0; hasPublished = false; connect()
    } }

    func stop() { queue.async { [self] in
        active = false; retry?.cancel(); timeout?.cancel()
        let closing = connection
        if streamId != 0, state == .publishing {
            transaction += 1
            command([.string("FCUnpublish"), .number(Double(transaction)), .null, .string(streamKey)])
            transaction += 1
            let payload = AMF0.encode([.string("deleteStream"), .number(Double(transaction)), .null, .number(Double(streamId))])
            let bytes = chunks(for: RTMPMessage(chunkStreamId: 3, type: 20, payload: payload), chunkSize: outChunkSize)
            // The final completion drains preceding sends; a stalled peer cannot keep stop alive forever.
            closing?.send(content: bytes, completion: .contentProcessed { _ in closing?.cancel() })
            queue.asyncAfter(deadline: .now() + 1) { closing?.cancel() }
        } else { closing?.cancel() }
        generation += 1; connection = nil; pendingBytes = 0
        transition(.idle)
    } }

    func setVideoConfig(sps: Data, pps: Data) { queue.async { [self] in
        guard let config = FLVTags.videoConfig(sps: sps, pps: pps), config != videoConfig else { return }
        videoConfig = config
        if state == .publishing {
            media(type: 9, payload: config, time: lastMediaTimestamp); needsKeyframe = true; onNeedKeyframe?()
        }
    } }
    func setAudioConfig(audioSpecificConfig: Data) { queue.async { [self] in
        let config = FLVTags.audioConfig(audioSpecificConfig)
        guard config != audioConfig else { return }
        audioConfig = config
        if state == .publishing { media(type: 8, payload: config, time: lastMediaTimestamp) }
    } }

    func sendVideo(_ avcc: Data, ptsNs: UInt64, dtsNs: UInt64, keyframe: Bool) {
        queue.async { [self] in
            guard state == .publishing, videoConfig != nil else { return }
            guard checkPressure() else { return }
            if pressure.dropping || (needsKeyframe && !keyframe) { counters.droppedFrames += 1; return }
            if needsKeyframe { needsKeyframe = false }
            if baseNs == nil {
                baseNs = dtsNs; firstVideoPTS = ptsNs
                // Timestamp 0 of what this destination receives, so a received file can be matched against the log.
                log("RTMP " + safe(endpoint.host) + ":\(endpoint.port): stream time 0 is host \(dtsNs) ns")
            }
            guard dtsNs >= baseNs! else { counters.droppedFrames += 1; return }
            media(type: 9, payload: FLVTags.video(avcc, ptsNs: ptsNs, dtsNs: dtsNs, keyframe: keyframe, baseNs: baseNs!), time: timestamp(dtsNs))
        }
    }
    func sendAudio(_ aac: Data, ptsNs: UInt64) {
        queue.async { [self] in
            guard state == .publishing, audioConfig != nil,
                  let first = firstVideoPTS, ptsNs >= first, checkPressure() else { return }
            media(type: 8, payload: FLVTags.audio(aac), time: timestamp(ptsNs))
        }
    }

    private func timestamp(_ ns: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: (ns >= (baseNs ?? ns) ? ns - (baseNs ?? ns) : 0) / 1_000_000)
    }
    private var pendingMs: Double {
        Double(pendingBytes) * 8 / Double(max(1, metadata.videoKbps + metadata.audioKbps))
    }
    private func snapshot() -> Stats {
        let now = ProcessInfo.processInfo.systemUptime
        confirmed.removeAll { $0.0 < now - 3 }
        counters.kbps = Double(confirmed.reduce(0) { $0 + $1.1 }) * 8 / 3000
        counters.pendingMs = pendingMs
        return counters
    }
    private func checkPressure() -> Bool {
        if pendingMs > 6000 { reconnect("Upload stalled"); return false }
        if pressure.update(pendingMs) { needsKeyframe = true; onNeedKeyframe?() }
        if pressure.dropping { needsKeyframe = true }
        return true
    }
    /// Removes the stream key, and anything after the application's first path component (where a key pasted into
    /// the URL would sit), from text that reaches the log or the UI, such as a server's error description.
    private func safe(_ text: String) -> String {
        var secrets = [streamKey]
        let path = endpoint.app.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if let slash = path.firstIndex(of: "/") {
            let tail = String(path[path.index(after: slash)...])
            secrets += [tail, tail.removingPercentEncoding ?? tail]
        }
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encoded.isEmpty {
                result = result.replacingOccurrences(of: encoded, with: "[redacted]")
            }
        }
        return result
    }
    private func transition(_ new: State) { state = new; onState?(new) }

    private func connect() {
        guard active else { return }
        generation += 1
        let token = generation
        parser = RTMPDechunker(); handshake = Data(); handshaking = true
        outChunkSize = 128; streamId = 0; transaction = 5; baseNs = nil; firstVideoPTS = nil
        needsKeyframe = true; pressure = RTMPPressure(); pendingBytes = 0
        lastMediaTimestamp = 0; awaited = (1, "connect")
        received = 0; lastAcknowledged = 0; window = 0
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: endpoint.scheme == "rtmps" ? NWProtocolTLS.Options() : nil, tcp: tcp)
        let host = endpoint.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let rawPort = UInt16(exactly: endpoint.port), rawPort > 0,
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            active = false; transition(.failed("Invalid RTMP port")); return
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        connection = c
        transition(.connecting)
        // Host only: a key pasted into the URL would sit in the application path.
        log("RTMP connecting to " + safe(endpoint.host))
        armTimeout("TCP/TLS")
        c.stateUpdateHandler = { [weak self] status in
            guard let self, self.generation == token, self.active else { return }
            switch status {
            case .ready:
                self.armTimeout("handshake")
                var hello = Data([3]); hello.append(Data(repeating: 0, count: 8))
                hello.append(contentsOf: (0..<1528).map { _ in UInt8.random(in: .min ... .max) })
                self.send(hello); self.receive(token)
            case .failed(let error), .waiting(let error): self.reconnect("TCP/TLS: \(error)")
            default: break
            }
        }
        c.start(queue: queue)
    }
    private func armTimeout(_ stage: String) {
        timeout?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.active else { return }
            self.reconnect(stage + " timed out")
        }
        timeout = work; queue.asyncAfter(deadline: .now() + 8, execute: work)
    }
    private func receive(_ token: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.generation == token, self.active else { return }
            do {
                if let data, !data.isEmpty {
                    self.received += UInt64(data.count)
                    if self.handshaking {
                        self.handshake.append(data)
                        if self.handshake.count >= 3073 {
                            guard self.handshake.first == 3 else { throw RTMPError.malformed }
                            self.send(self.handshake.subdata(in: 1..<1537))
                            let rest = Data(self.handshake.dropFirst(3073))
                            self.handshake = Data(); self.handshaking = false
                            self.control(1, value: 4096); self.outChunkSize = 4096
                            self.armTimeout("connect")
                            self.command([.string("connect"), .number(1), .object([
                                "app": .string(self.endpoint.app), "type": .string("nonprivate"),
                                "flashVer": .string("FMLE/3.0 (compatible; ElgatoHDR)"), "tcUrl": .string(self.endpoint.tcUrl)
                            ])])
                            try self.consume(rest)
                        }
                    } else { try self.consume(data) }
                    if self.window > 0, self.received - self.lastAcknowledged >= self.window {
                        self.control(3, value: UInt32(truncatingIfNeeded: self.received))
                        self.lastAcknowledged = self.received
                    }
                }
                guard self.generation == token, self.active else { return }
                if let error { self.reconnect("Receive: \(error)") }
                else if complete { self.reconnect("Connection closed") }
                else { self.receive(token) }
            } catch { self.reconnect("Malformed server response") }
        }
    }
    private func consume(_ data: Data) throws {
        let token = generation
        for message in try parser.append(data) {
            guard generation == token, active else { break }
            var r = RTMPReader(bytes: Array(message.payload))
            switch message.type {
            case 4:
                if try r.uint(2) == 6 {
                    let payload = try r.data(4)
                    sendMessage(RTMPMessage(chunkStreamId: 2, type: 4, payload: Data([0, 7]) + payload))
                }
            case 5: window = try r.uint(4)
            case 6:
                let size = try r.uint(4); _ = try r.uint(1)
                control(5, value: UInt32(size))
            case 20:
                do { try reply(AMF0.decode(message.payload)) }
                catch {
                    let prefix = try? AMF0.decode(message.payload, limit: 2)
                    let name = prefix?.first?.string
                    let tid = prefix.flatMap { $0.count > 1 ? $0[1].number : nil }
                    if let awaited, ((name == "_result" || name == "_error") && tid == awaited.id) || (name == "onStatus" && awaited.id == 5) {
                        reconnect("Malformed " + awaited.stage + " response")
                    }
                }
            default: break
            }
        }
    }
    private func reply(_ values: [AMFValue]) throws {
        guard let name = values.first?.string else { return }
        guard ["_result", "_error", "onStatus"].contains(name) else { return }
        let tid = values.count > 1 ? values[1].number : nil
        if name == "_error", ![1.0, 4, 5].contains(tid ?? -1) { return }
        let info = values.compactMap { $0.properties }.last ?? [:]
        let code = info["code"]?.string ?? ""
        if name == "_error" || code.contains("Rejected") ||
            (code.hasPrefix("NetStream.Publish.") && code != "NetStream.Publish.Start") ||
            (code.hasPrefix("NetConnection.Connect.") && code != "NetConnection.Connect.Success") {
            let description = safe(info["description"]?.string ?? "Server rejected publishing")
            if !hasPublished && (code.contains("BadName") || code.contains("Rejected")) {
                active = false; timeout?.cancel(); generation += 1; connection?.cancel(); connection = nil; pendingBytes = 0
                transition(.failed(description))
            } else { reconnect(description) }
            return
        }
        if name == "_result", tid == 1, streamId == 0 {
            awaited = (4, "createStream"); armTimeout("createStream")
            command([.string("releaseStream"), .number(2), .null, .string(streamKey)])
            command([.string("FCPublish"), .number(3), .null, .string(streamKey)])
            command([.string("createStream"), .number(4), .null])
        } else if name == "_result", tid == 4, values.count > 3 {
            guard let id = values[3].number, id.isFinite, id > 0, id <= Double(UInt32.max), id.rounded() == id else { throw RTMPError.malformed }
            streamId = UInt32(id); awaited = (5, "publish"); armTimeout("publish")
            command([.string("publish"), .number(5), .null, .string(streamKey), .string("live")], stream: streamId)
        } else if name == "onStatus", code == "NetStream.Publish.Start", streamId != 0, state != .publishing {
            timeout?.cancel(); attempt = 0; awaited = nil; hasPublished = true
            sendMessage(RTMPMessage(chunkStreamId: 5, type: 18, streamId: streamId, payload: AMF0.encode([
                .string("@setDataFrame"), .string("onMetaData"), .ecmaArray([
                    "width": .number(Double(metadata.width)), "height": .number(Double(metadata.height)),
                    "framerate": .number(metadata.fps), "videodatarate": .number(Double(metadata.videoKbps)),
                    "videocodecid": .number(7), "audiodatarate": .number(Double(metadata.audioKbps)),
                    "audiosamplerate": .number(48000), "audiosamplesize": .number(16), "stereo": .boolean(true),
                    "audiocodecid": .number(10), "encoder": .string("ElgatoHDR")
                ])
            ])))
            if let videoConfig { media(type: 9, payload: videoConfig, time: 0) }
            if let audioConfig { media(type: 8, payload: audioConfig, time: 0) }
            transition(.publishing); onNeedKeyframe?()
        }
    }
    private func command(_ values: [AMFValue], stream: UInt32 = 0) {
        sendMessage(RTMPMessage(chunkStreamId: stream == 0 ? 3 : 4, type: 20, streamId: stream, payload: AMF0.encode(values)))
    }
    private func control(_ type: UInt8, value: UInt32) {
        var data = Data(); data.rtmpBE(UInt64(value), 4)
        sendMessage(RTMPMessage(chunkStreamId: 2, type: type, payload: data))
    }
    private func media(type: UInt8, payload: Data, time: UInt32) {
        guard payload.count <= 0xFFFFFF else { return }
        lastMediaTimestamp = time
        sendMessage(RTMPMessage(chunkStreamId: type == 9 ? 6 : 4, timestamp: time, type: type, streamId: streamId, payload: payload))
    }
    private func sendMessage(_ message: RTMPMessage) { send(chunks(for: message, chunkSize: outChunkSize)) }
    private func send(_ data: Data) {
        guard let c = connection else { return }
        let token = generation
        pendingBytes += Int64(data.count)
        c.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == token else { return }
            self.pendingBytes -= Int64(data.count)
            if let error { self.reconnect("Send: \(error)"); return }
            _ = self.checkPressure()
            self.counters.bytesSent += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            self.confirmed.removeAll { $0.0 < now - 3 }
            self.confirmed.append((now, data.count))
        })
        if pendingMs > 6000 { reconnect("Upload stalled") }
    }
    private func reconnect(_ reason: String) {
        guard active else { return }
        timeout?.cancel(); generation += 1; connection?.cancel(); connection = nil; pendingBytes = 0
        attempt += 1; counters.reconnects += 1
        let delay = [1.0, 2, 4, 8, 15, 30][min(attempt - 1, 5)]
        counters.lastError = safe(reason)
        log("RTMP " + safe(endpoint.host) + ": " + safe(reason))
        transition(.reconnecting(attempt: attempt, inSeconds: delay))
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == token else { return }; self.connect()
        }
        retry?.cancel(); retry = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    deinit { timeout?.cancel(); retry?.cancel(); connection?.cancel() }
}

// Hysteresis prevents an IDR from reopening the gate while the upload is still backed up.
struct RTMPPressure {
    private(set) var dropping = false
    mutating func update(_ pendingMs: Double) -> Bool {
        if pendingMs > 1500 { dropping = true }
        else if dropping && pendingMs < 750 { dropping = false; return true }
        return false
    }
}
