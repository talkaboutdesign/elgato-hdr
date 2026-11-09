import Foundation
import Network
@testable import StudioKit

final class FakeRTMPServer {
    final class Session {
        let connection: NWConnection
        let number: Int
        var buffer = Data()
        var stage = 0
        var parser = RTMPDechunker()
        var paused = false
        var reading = false
        init(_ c: NWConnection, _ n: Int) { connection = c; number = n }
    }
    let queue = DispatchQueue(label: "rtmp.fake.server")
    private let listener: NWListener
    private var sessions: [Session] = []
    private var recorded: [(Int, RTMPMessage)] = []
    var reject = false
    var rejectSession = 0
    var rejectOptional = false
    var malformedConnect = false
    private var sentBytes: UInt64 = 3073
    var wireBytes: UInt64 { queue.sync { sentBytes } }
    var onMessage: ((Int, RTMPMessage) -> Void)?
    var messages: [(Int, RTMPMessage)] { queue.sync { recorded } }
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            let s = Session(c, self.sessions.count + 1); self.sessions.append(s)
            c.start(queue: self.queue); self.receive(s)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else { throw RTMPError.malformed }
    }
    func stop() { queue.sync { listener.cancel(); sessions.forEach { $0.connection.cancel() } } }
    func closeLatest() { queue.async { self.sessions.last?.connection.cancel() } }
    func pauseLatest() { queue.sync { sessions.last?.paused = true } }

    func resumeLatest() { queue.async { if let s = self.sessions.last { s.paused = false; if !s.reading { self.receive(s) } } } }

    private func send(_ s: Session, _ message: RTMPMessage) {
        let bytes = chunks(for: message, chunkSize: 128)
        sentBytes += UInt64(bytes.count)
        s.connection.send(content: bytes, completion: .contentProcessed { _ in })
    }
    func sendControl(type: UInt8, payload: Data) {
        queue.async { if let s = self.sessions.last { self.send(s, RTMPMessage(chunkStreamId: 2, type: type, payload: payload)) } }
    }
    private func command(_ s: Session, _ values: [AMFValue], stream: UInt32 = 0) {
        send(s, RTMPMessage(chunkStreamId: 3, type: 20, streamId: stream, payload: AMF0.encode(values)))
    }
    private func receive(_ s: Session) {
        guard !s.paused else { return }
        s.reading = true
        s.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            s.reading = false
            do {
                if let data {
                    if s.stage < 2 {
                        s.buffer.append(data)
                        if s.stage == 0, s.buffer.count >= 1537 {
                            let c1 = s.buffer.subdata(in: 1..<1537)
                            s.buffer.removeFirst(1537)
                            let s1 = Data(repeating: 0x42, count: 1536)
                            s.connection.send(content: Data([3]) + s1 + c1, completion: .contentProcessed { _ in })
                            s.stage = 1
                        }
                        if s.stage == 1, s.buffer.count >= 1536 {
                            s.buffer.removeFirst(1536); s.stage = 2
                            try self.consume(s, Data(s.buffer)); s.buffer = Data()
                        }
                    } else { try self.consume(s, data) }
                }
                if !done && error == nil { self.receive(s) }
            } catch { s.connection.cancel() }
        }
    }
    private func consume(_ s: Session, _ data: Data) throws {
        for m in try s.parser.append(data) {
            recorded.append((s.number, m))
            if m.type == 20 {
                let v = try AMF0.decode(m.payload)
                switch v.first?.string {
                case "releaseStream", "FCPublish":
                    if rejectOptional { command(s, [.string("_error"), v[1], .null, .string("Method not found")]) }
                case "connect":
                    if malformedConnect { send(s, RTMPMessage(chunkStreamId: 3, type: 20, payload: AMF0.encode([.string("_result"), .number(1)]) + Data([0x10]))); break }
                    command(s, [.string("_result"), .number(1), .null, .object(["code": .string("NetConnection.Connect.Success")])])
                case "createStream": command(s, [.string("_result"), .number(4), .null, .number(1)])
                case "publish":
                    command(s, [.string("onStatus"), .number(0), .null, .object([
                        "code": .string((reject || s.number == rejectSession) ? "NetStream.Publish.BadName" : "NetStream.Publish.Start"),
                        "description": .string((reject || s.number == rejectSession) ? "Invalid secret-test-key" : "Started")
                    ])], stream: 1)
                default: break
                }
            }
            onMessage?(s.number, m)
        }
    }
}
