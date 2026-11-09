import Foundation

struct RTMPMessage: Equatable {
    var chunkStreamId: Int
    var timestamp: UInt32 = 0
    var type: UInt8
    var streamId: UInt32 = 0
    var payload: Data
}

func chunks(for message: RTMPMessage, chunkSize: Int) -> Data {
    precondition(chunkSize > 0 && (2...65599).contains(message.chunkStreamId))
    precondition(message.payload.count <= 0xFFFFFF)
    var out = Data()
    func basic(_ fmt: UInt8) {
        let id = message.chunkStreamId
        if id < 64 { out.append(fmt << 6 | UInt8(id)) }
        else if id < 320 { out.append(fmt << 6); out.append(UInt8(id - 64)) }
        else { out.append(fmt << 6 | 1); out.append(UInt8(truncatingIfNeeded: id - 64)); out.append(UInt8((id - 64) >> 8)) }
    }
    let extended = message.timestamp >= 0xFFFFFF
    var offset = 0
    repeat {
        basic(offset == 0 ? 0 : 3)
        if offset == 0 {
            out.rtmpBE(UInt64(min(message.timestamp, 0xFFFFFF)), 3)
            out.rtmpBE(UInt64(message.payload.count), 3); out.append(message.type)
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: message.streamId >> (8 * i))) }
        }
        if extended { out.rtmpBE(UInt64(message.timestamp), 4) }
        let end = min(offset + chunkSize, message.payload.count)
        out.append(message.payload.subdata(in: offset..<end)); offset = end
    } while offset < message.payload.count
    return out
}

/// A header and its chunk body commit together, so arbitrary TCP splits cannot corrupt history.
final class RTMPDechunker {
    private struct Stream {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var type: UInt8 = 0
        var streamId: UInt32 = 0
        var extended = false
        var payload = Data()
    }
    private var buffer = Data()
    private var streams: [Int: Stream] = [:]
    private(set) var chunkSize = 128
    private var bufferedPayloadBytes = 0

    func append(_ data: Data) throws -> [RTMPMessage] {
        buffer.append(data)
        var r = RTMPReader(bytes: Array(buffer))
        var messages: [RTMPMessage] = []
        while r.remaining > 0 {
            let start = r.offset
            do {
                let basic = Int(try r.uint(1)), fmt = basic >> 6
                var id = basic & 63
                if id == 0 { id = Int(try r.uint(1)) + 64 }
                else if id == 1 { let lo = Int(try r.uint(1)); id = lo + Int(try r.uint(1)) * 256 + 64 }
                guard fmt == 0 || streams[id] != nil else { throw RTMPError.malformed }
                var s = streams[id] ?? Stream()
                let continuing = !s.payload.isEmpty
                guard !continuing || fmt == 3 else { throw RTMPError.malformed }
                if fmt <= 2 {
                    let t = UInt32(try r.uint(3))
                    s.extended = t == 0xFFFFFF
                    if fmt <= 1 { s.length = Int(try r.uint(3)); s.type = UInt8(try r.uint(1)) }
                    if fmt == 0 {
                        let raw = try r.data(4)
                        s.streamId = raw.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
                    }
                    let time = s.extended ? UInt32(try r.uint(4)) : t
                    if fmt == 0 { s.timestamp = time; s.delta = time }
                    else { s.delta = time; s.timestamp = s.timestamp &+ time }
                } else {
                    if s.extended { _ = try r.uint(4) }
                    if !continuing { s.timestamp = s.timestamp &+ s.delta }
                }
                let part = try r.data(min(chunkSize, s.length - s.payload.count))
                guard bufferedPayloadBytes + part.count <= 64 * 1024 * 1024 else { throw RTMPError.malformed }
                bufferedPayloadBytes += part.count
                s.payload.append(part)
                if s.payload.count == s.length {
                    let message = RTMPMessage(chunkStreamId: id, timestamp: s.timestamp, type: s.type, streamId: s.streamId, payload: s.payload)
                    messages.append(message)
                    bufferedPayloadBytes -= s.payload.count
                    s.payload = Data()
                    if message.type == 1 {
                        guard message.payload.count == 4 else { throw RTMPError.malformed }
                        var control = RTMPReader(bytes: Array(message.payload))
                        let size = Int(try control.uint(4))
                        guard size > 0, size <= 0x7FFFFFFF else { throw RTMPError.malformed }
                        chunkSize = size
                    } else if message.type == 2 {
                        guard message.payload.count == 4 else { throw RTMPError.malformed }
                        var control = RTMPReader(bytes: Array(message.payload))
                        let aborted = Int(try control.uint(4))
                        if let previous = streams[aborted] { bufferedPayloadBytes -= previous.payload.count; streams[aborted]?.payload = Data() }
                    }
                }
                streams[id] = s
            } catch RTMPError.truncated {
                r.offset = start; break
            }
        }
        buffer = Data(buffer.dropFirst(r.offset))
        return messages
    }
}
