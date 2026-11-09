import XCTest
@testable import StudioKit

final class RTMPWireTests: XCTestCase {
    private func hex(_ s: String) -> Data { Data(s.split(separator: " ").map { UInt8($0, radix: 16)! }) }

    func testAMFGoldenTypes() throws {
        let cases: [(AMFValue, String)] = [
            (.number(1), "00 3f f0 00 00 00 00 00 00"), (.boolean(true), "01 01"),
            (.boolean(false), "01 00"), (.string("é"), "02 00 02 c3 a9"),
            (.object(["x": .null]), "03 00 01 78 05 00 00 09"), (.null, "05"), (.undefined, "06"),
            (.ecmaArray(["x": .boolean(true)]), "08 00 00 00 01 00 01 78 01 01 00 00 09"),
            (.strictArray([.null, .string("a")]), "0a 00 00 00 02 05 02 00 01 61")
        ]
        for (value, bytes) in cases {
            XCTAssertEqual(AMF0.encode([value]), hex(bytes))
            XCTAssertEqual(try AMF0.decode(hex(bytes)), [value])
        }
        XCTAssertThrowsError(try AMF0.decode(hex("02 00 05 61")))
        XCTAssertThrowsError(try AMF0.decode(hex("ff")))
    }

    func testConnectGolden() throws {
        let values: [AMFValue] = [.string("connect"), .number(1), .object([
            "app": .string("live"), "flashVer": .string("FMLE/3.0 (compatible; ElgatoHDR)"),
            "tcUrl": .string("rtmp://host:1935/live"), "type": .string("nonprivate")
        ])]
        let expected = hex("""
        02 00 07 63 6f 6e 6e 65 63 74 00 3f f0 00 00 00 00 00 00 03
        00 03 61 70 70 02 00 04 6c 69 76 65
        00 08 66 6c 61 73 68 56 65 72 02 00 20 46 4d 4c 45 2f 33 2e 30 20 28 63 6f 6d 70 61 74 69 62 6c 65 3b 20 45 6c 67 61 74 6f 48 44 52 29
        00 05 74 63 55 72 6c 02 00 15 72 74 6d 70 3a 2f 2f 68 6f 73 74 3a 31 39 33 35 2f 6c 69 76 65
        00 04 74 79 70 65 02 00 0a 6e 6f 6e 70 72 69 76 61 74 65 00 00 09
        """.replacingOccurrences(of: "\n", with: " "))
        XCTAssertEqual(AMF0.encode(values), expected)
        XCTAssertEqual(try AMF0.decode(expected), values)
    }

    func testChunkLengthsAndSingleByteFeeds() throws {
        for count in [0, 127, 128, 129, 4096] {
            let message = RTMPMessage(chunkStreamId: 6, timestamp: 123, type: 9, streamId: 0x12345678, payload: Data(repeating: 42, count: count))
            let wire = chunks(for: message, chunkSize: 128)
            XCTAssertEqual(Array(wire.prefix(12)), [6, 0, 0, 123, UInt8(count >> 16), UInt8((count >> 8) & 255), UInt8(count & 255), 9, 0x78, 0x56, 0x34, 0x12])
            let parser = RTMPDechunker()
            var result: [RTMPMessage] = []
            for byte in wire { result += try parser.append(Data([byte])) }
            XCTAssertEqual(result, [message])
        }
    }
    func testExtendedTimestamp() throws {
        for timestamp: UInt32 in [0xFFFFFF, 0x1000000, 0xFEDCBA98] {
            let m = RTMPMessage(chunkStreamId: 6, timestamp: timestamp, type: 9, streamId: 1, payload: Data(repeating: 7, count: 300))
            let wire = chunks(for: m, chunkSize: 128)
            var extended = Data(); extended.rtmpBE(UInt64(timestamp), 4)
            XCTAssertEqual(wire.subdata(in: 12..<16), extended)
            XCTAssertEqual(wire[144], 0xC6)
            XCTAssertEqual(wire.subdata(in: 145..<149), extended)
            XCTAssertEqual(try RTMPDechunker().append(wire), [m])
        }
    }
    func testInterleavingAndChunkSizeChange() throws {
        let a = RTMPMessage(chunkStreamId: 6, type: 9, payload: Data(repeating: 1, count: 200))
        let b = RTMPMessage(chunkStreamId: 4, type: 8, payload: Data([2]))
        let aWire = chunks(for: a, chunkSize: 128)
        let parser = RTMPDechunker()
        XCTAssertEqual(try parser.append(aWire.prefix(140) + chunks(for: b, chunkSize: 128)), [b])
        let size = RTMPMessage(chunkStreamId: 2, type: 1, payload: Data([0, 0, 0, 64]))
        let tail = Data([0xC6]) + Data(repeating: 1, count: 64) + Data([0xC6]) + Data(repeating: 1, count: 8)
        XCTAssertEqual(try parser.append(chunks(for: size, chunkSize: 128) + tail), [size, a])
        XCTAssertEqual(parser.chunkSize, 64)
    }
    func testCompressedHeadersAndExtendedDelta() throws {
        let initial = RTMPMessage(chunkStreamId: 7, timestamp: 10, type: 8, streamId: 3, payload: Data([1]))
        let wire = chunks(for: initial, chunkSize: 128) + hex("47 00 00 05 00 00 01 09 02 87 00 00 07 03 c7 04")
        let result = try RTMPDechunker().append(wire)
        XCTAssertEqual(result.map(\.timestamp), [10, 15, 22, 29])
        XCTAssertEqual(result.map(\.type), [8, 9, 9, 9])
        XCTAssertEqual(result.map(\.streamId), [3, 3, 3, 3])
        let extended = chunks(for: initial, chunkSize: 128) + hex("87 ff ff ff 01 00 00 00 02 c7 01 00 00 00 03")
        XCTAssertEqual(try RTMPDechunker().append(extended).map(\.timestamp), [10, 0x100000A, 0x200000A])
    }
    func testMalformedChunkControlsAndAbort() throws {
        for body in [Data([0]), Data([0, 0, 0, 0]), Data([0x80, 0, 0, 0])] {
            let message = RTMPMessage(chunkStreamId: 2, type: 1, payload: body)
            XCTAssertThrowsError(try RTMPDechunker().append(chunks(for: message, chunkSize: 128)))
        }
        let parser = RTMPDechunker()
        let partial = RTMPMessage(chunkStreamId: 6, type: 9, payload: Data(repeating: 1, count: 200))
        XCTAssertEqual(try parser.append(chunks(for: partial, chunkSize: 128).prefix(140)), [])
        let abort = RTMPMessage(chunkStreamId: 2, type: 2, payload: Data([0, 0, 0, 6]))
        let next = RTMPMessage(chunkStreamId: 6, type: 9, payload: Data([2]))
        XCTAssertEqual(try parser.append(chunks(for: abort, chunkSize: 128) + chunks(for: next, chunkSize: 128)), [abort, next])
    }
    func testFLVGolden() {
        XCTAssertEqual(FLVTags.videoConfig(sps: hex("67 64 00 1f"), pps: hex("68 aa")), hex("17 00 00 00 00 01 64 00 1f ff e1 00 04 67 64 00 1f 01 00 02 68 aa"))
        XCTAssertEqual(FLVTags.video(hex("00 00 00 01 65"), ptsNs: 50_000_000, dtsNs: 10_000_000, keyframe: true), hex("17 01 00 00 28 00 00 00 01 65"))
        XCTAssertEqual(FLVTags.video(hex("aa"), ptsNs: 0, dtsNs: 2_000_000, keyframe: false), hex("27 01 ff ff fe aa"))
        XCTAssertEqual(FLVTags.audioConfig(hex("11 90")), hex("af 00 11 90"))
        XCTAssertEqual(FLVTags.audio(hex("01 02")), hex("af 01 01 02"))
        XCTAssertNil(FLVTags.videoConfig(sps: Data(), pps: Data()))
    }
    func testEndpoints() {
        let plain = StreamEndpoint(url: "rtmp://host/app")!
        XCTAssertEqual(plain.port, 1935); XCTAssertEqual(plain.tcUrl, "rtmp://host:1935/app")
        let tls = StreamEndpoint(url: "rtmps://host:443/app/")!
        XCTAssertEqual(tls.scheme, "rtmps"); XCTAssertEqual(tls.app, "app"); XCTAssertEqual(tls.port, 443)
        XCTAssertEqual(StreamEndpoint(url: "rtmp://host/live2?backup=1")?.app, "live2?backup=1")
        for s in ["https://host/app", "rtmp://host", "rtmp://host/", "rtmp://host:0/app", "rtmp://user:pass@host/app"] { XCTAssertNil(StreamEndpoint(url: s)) }
    }
}
