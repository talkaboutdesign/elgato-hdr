import Accelerate
import AVFoundation
import Foundation
import Observation
import QuartzCore

/// Peak envelope of one audio layer: a min/max pair per 10 ms, plus coarser levels that halve the count, so drawing
/// costs about one pair per point at any zoom.
struct Waveform {
    static let binMs = 10.0
    let levels: [[Float]]       // interleaved min, max
    let peak: Float

    /// Min and max over a source-time range (milliseconds, in the file's own time).
    func range(_ fromMs: Double, _ toMs: Double) -> (Float, Float) {
        let bins = max(1, (toMs - fromMs) / Self.binMs)
        let level = min(levels.count - 1, max(0, Int(log2(bins))))
        let span = Self.binMs * Double(1 << level)
        let data = levels[level], n = data.count / 2
        guard n > 0 else { return (0, 0) }
        let i0 = max(0, min(n - 1, Int(fromMs / span))), i1 = max(i0, min(n - 1, Int((toMs / span).rounded(.up)) - 1))
        var lo: Float = 0, hi: Float = 0
        for i in i0...i1 { lo = min(lo, data[2 * i]); hi = max(hi, data[2 * i + 1]) }
        return (lo, hi)
    }

    init(base: [Float]) {
        var levels = [base], cur = base
        while cur.count / 2 > 1 {
            let n = cur.count / 2, m = (n + 1) / 2
            var next = [Float](repeating: 0, count: m * 2)
            for j in 0..<m {
                let a = 2 * j, b = min(2 * j + 1, n - 1)
                next[2 * j] = min(cur[2 * a], cur[2 * b]); next[2 * j + 1] = max(cur[2 * a + 1], cur[2 * b + 1])
            }
            levels.append(next); cur = next
        }
        self.levels = levels
        var p: Float = 0
        for v in base { p = max(p, abs(v)) }
        peak = p
    }
}

/// Reads each audio layer once in the background into a `Waveform` and keeps it in `.cache/` next to the
/// thumbnails, keyed by the file's size and date.
@Observable
final class WaveformCache {
    var game: Waveform?
    var mic: Waveform?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let doc: ProjectDoc
    @ObservationIgnored private let opened = CACurrentMediaTime()

    init(doc: ProjectDoc) { self.doc = doc }

    func load(game: Bool, mic: Bool) {
        let dir = doc.dir.appendingPathComponent(".cache", isDirectory: true), label = doc.dir.lastPathComponent, opened = self.opened
        var jobs: [(String, URL)] = []
        if game { jobs.append(("game", doc.url(doc.project.game.file))) }
        if mic, let m = doc.project.mic { jobs.append(("mic", doc.url(m.file))) }
        for (name, url) in jobs {
            tasks.append(Task.detached(priority: .utility) { [weak self] in
                let cache = dir.appendingPathComponent("waveform-\(name).bin")
                var w = Self.readCache(cache, source: url)
                if w == nil, let base = await Self.analyze(url) { Self.writeCache(base, to: cache, source: url); w = Waveform(base: base) }
                guard !Task.isCancelled, let w = w else { return }
                await self?.deliver(name, w, opened: opened, label: label)
            })
        }
    }

    func cancel() { tasks.forEach { $0.cancel() }; tasks = [] }

    @MainActor private func deliver(_ name: String, _ w: Waveform, opened: CFTimeInterval, label: String) {
        if name == "game" { game = w } else { mic = w }
        log(String(format: "editor: %@ waveform ready %.0f ms after opening (%@)", name, (CACurrentMediaTime() - opened) * 1000, label))
    }

    /// One pass over the first audio track, mixed to mono: min and max per 10 ms.
    static func analyze(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let t = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 48_000.0
        let out = AVAssetReaderTrackOutput(track: t, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        let perBin = Int(rate * Waveform.binMs / 1000)
        var result: [Float] = [], carry: [Float] = []
        carry.reserveCapacity(perBin)
        func flush(_ v: UnsafeBufferPointer<Float>) {
            var lo: Float = 0, hi: Float = 0
            vDSP_minv(v.baseAddress!, 1, &lo, vDSP_Length(v.count))
            vDSP_maxv(v.baseAddress!, 1, &hi, vDSP_Length(v.count))
            result.append(min(0, lo)); result.append(max(0, hi))
        }
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0, pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let raw = pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            raw.withMemoryRebound(to: Float.self, capacity: count) { f in
                var i = 0
                if !carry.isEmpty {
                    let take = min(perBin - carry.count, count)
                    carry.append(contentsOf: UnsafeBufferPointer(start: f, count: take)); i = take
                    if carry.count == perBin { carry.withUnsafeBufferPointer(flush); carry.removeAll(keepingCapacity: true) }
                }
                while i + perBin <= count { flush(UnsafeBufferPointer(start: f + i, count: perBin)); i += perBin }
                if i < count { carry.append(contentsOf: UnsafeBufferPointer(start: f + i, count: count - i)) }
            }
        }
        if !carry.isEmpty { carry.withUnsafeBufferPointer(flush) }
        return reader.status == .completed ? result : nil
    }

    private static func stamp(_ url: URL) -> (UInt64, Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.uint64Value, let date = a[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    private static let magic: UInt32 = 0x31_57_48_45   // "EHW1"

    static func readCache(_ url: URL, source: URL) -> Waveform? {
        guard let (size, date) = stamp(source), let d = try? Data(contentsOf: url), d.count >= 24 else { return nil }
        return d.withUnsafeBytes { raw -> Waveform? in
            guard raw.load(fromByteOffset: 0, as: UInt32.self) == magic,
                  raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self) == size,
                  raw.loadUnaligned(fromByteOffset: 12, as: Double.self) == date else { return nil }
            let n = Int(raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
            guard d.count == 24 + n * 4 else { return nil }
            let floats = (0..<n).map { raw.loadUnaligned(fromByteOffset: 24 + $0 * 4, as: Float.self) }
            return Waveform(base: floats)
        }
    }

    static func writeCache(_ base: [Float], to url: URL, source: URL) {
        guard let (size, date) = stamp(source) else { return }
        var d = Data()
        withUnsafeBytes(of: magic) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: size) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: date) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(base.count)) { d.append(contentsOf: $0) }
        base.withUnsafeBytes { d.append(contentsOf: $0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}
