import Foundation

enum RTMPError: Error { case malformed, truncated }

enum AMFValue: Equatable {
    case number(Double), boolean(Bool), string(String), object([String: AMFValue])
    case null, undefined, ecmaArray([String: AMFValue]), strictArray([AMFValue])

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var properties: [String: AMFValue]? {
        switch self { case .object(let o), .ecmaArray(let o): return o; default: return nil }
    }
}

extension Data {
    mutating func rtmpBE(_ value: UInt64, _ count: Int) {
        for i in (0..<count).reversed() { append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
}

struct RTMPReader {
    let bytes: [UInt8]
    var offset = 0
    var remaining: Int { bytes.count - offset }
    mutating func uint(_ count: Int) throws -> UInt64 {
        guard remaining >= count else { throw RTMPError.truncated }
        var value: UInt64 = 0
        for _ in 0..<count { value = value << 8 | UInt64(bytes[offset]); offset += 1 }
        return value
    }
    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw RTMPError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }
    mutating func string(_ count: Int) throws -> String {
        guard let s = String(data: try data(count), encoding: .utf8) else { throw RTMPError.malformed }
        return s
    }
}

enum AMF0 {
    static func encode(_ values: [AMFValue]) -> Data {
        var out = Data()
        func stringBody(_ s: String) {
            let bytes = Data(s.utf8)
            out.rtmpBE(UInt64(bytes.count), 2); out.append(bytes)
        }
        func objectBody(_ o: [String: AMFValue]) {
            for key in o.keys.sorted() { stringBody(key); value(o[key]!) }
            out.append(contentsOf: [0, 0, 9])
        }
        func value(_ v: AMFValue) {
            switch v {
            case .number(let n): out.append(0); out.rtmpBE(n.bitPattern, 8)
            case .boolean(let b): out.append(contentsOf: [1, b ? 1 : 0])
            case .string(let s): out.append(2); stringBody(s)
            case .object(let o): out.append(3); objectBody(o)
            case .null: out.append(5)
            case .undefined: out.append(6)
            case .ecmaArray(let o): out.append(8); out.rtmpBE(UInt64(o.count), 4); objectBody(o)
            case .strictArray(let a): out.append(10); out.rtmpBE(UInt64(a.count), 4); a.forEach(value)
            }
        }
        values.forEach(value)
        return out
    }

    static func decode(_ data: Data) throws -> [AMFValue] {
        var r = RTMPReader(bytes: Array(data))
        func object(_ depth: Int) throws -> [String: AMFValue] {
            var result: [String: AMFValue] = [:]
            while true {
                let length = Int(try r.uint(2))
                if length == 0, r.remaining > 0, r.bytes[r.offset] == 9 { r.offset += 1; return result }
                let key = try r.string(length)
                result[key] = try value(depth + 1)
            }
        }
        func value(_ depth: Int) throws -> AMFValue {
            guard depth < 64 else { throw RTMPError.malformed }
            switch try r.uint(1) {
            case 0: return .number(Double(bitPattern: try r.uint(8)))
            case 1: return .boolean(try r.uint(1) != 0)
            case 2: return .string(try r.string(Int(r.uint(2))))
            case 3: return .object(try object(depth))
            case 5: return .null
            case 6: return .undefined
            case 8: _ = try r.uint(4); return .ecmaArray(try object(depth))
            case 10:
                let count = Int(try r.uint(4))
                guard count <= r.remaining else { throw RTMPError.truncated }
                var values: [AMFValue] = []
                for _ in 0..<count { values.append(try value(depth + 1)) }
                return .strictArray(values)
            default: throw RTMPError.malformed
            }
        }
        var values: [AMFValue] = []
        while r.remaining > 0 { values.append(try value(0)) }
        return values
    }
}
