import Foundation

enum FLVTags {
    static func videoConfig(sps: Data, pps: Data) -> Data? {
        guard sps.count >= 4, sps.count <= 65535, !pps.isEmpty, pps.count <= 65535 else { return nil }
        let s = Array(sps)
        var out = Data([0x17, 0, 0, 0, 0, 1, s[1], s[2], s[3], 0xFF, 0xE1])
        out.rtmpBE(UInt64(sps.count), 2); out.append(sps); out.append(1)
        out.rtmpBE(UInt64(pps.count), 2); out.append(pps)
        return out
    }
    static func video(_ avcc: Data, ptsNs: UInt64, dtsNs: UInt64, keyframe: Bool) -> Data {
        let offset = ptsNs >= dtsNs ? Int64(min((ptsNs - dtsNs) / 1_000_000, 0x7FFFFF)) : -Int64(min((dtsNs - ptsNs) / 1_000_000, 0x800000))
        var out = Data([keyframe ? 0x17 : 0x27, 1])
        out.rtmpBE(UInt64(bitPattern: offset), 3); out.append(avcc)
        return out
    }
    static func audioConfig(_ asc: Data) -> Data { Data([0xAF, 0]) + asc }
    static func audio(_ aac: Data) -> Data { Data([0xAF, 1]) + aac }
}
