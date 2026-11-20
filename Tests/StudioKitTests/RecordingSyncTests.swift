import XCTest
import AVFoundation
import VideoToolbox
@testable import StudioKit

/// Drives the real writers with synthetic timestamps (not real time) and checks the files they leave.
final class RecordingSyncTests: XCTestCase {
    let zero: UInt64 = 1_000_000_000
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingSync-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func requireHEVC() throws {
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 256, height: 144, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard status == noErr, let encoder = encoder else { throw XCTSkip("No hardware HEVC encoder (\(status))") }
        VTCompressionSessionInvalidate(encoder)
    }

    /// Track start and end in seconds, as AVFoundation reads them.
    func trackRange(_ url: URL, _ type: AVMediaType) async throws -> (Double, Double) {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: type)
        let track = try XCTUnwrap(tracks.first)
        let r = try await track.load(.timeRange)
        return (r.start.seconds, r.end.seconds)
    }

    /// Presentation times (seconds) where the decoded audio first crosses `threshold` after each of `after`.
    func clicks(_ url: URL, after: [Double], threshold: Float = 0.3) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var found: [Double] = [], pending = after.sorted()
        while let sb = out.copyNextSampleBuffer(), !pending.isEmpty {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0, pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let raw = pointer else { continue }
            let count = length / 4
            raw.withMemoryRebound(to: Float.self, capacity: count) { f in
                for i in 0..<count where !pending.isEmpty {
                    let t = pts + Double(i) / 48000
                    if t > pending[0] && abs(f[i]) > threshold { found.append(t); pending.removeFirst() }
                }
            }
        }
        reader.cancelReading()
        return found
    }

    /// A capture card whose sample clock runs `ppm` fast against the host, delivered in 768-frame chunks (two 8 ms USB
    /// transfers, as `uvc_capture.c` flushes) stamped on arrival with up to `jitterMs` of extra latency. `lose` drops
    /// samples from the stream (USB packets that never arrive). Clicks are short full-scale bursts at host seconds.
    struct Card {
        var ppm = 0.0, jitterMs = 0.0, chunk = 768
        var lose: [(atSeconds: Double, samples: Int)] = []
        var clicks: [Double] = []
        var rng = SplitMix(seed: 7)
        var produced = 0             // device samples produced so far
        /// Next chunk: interleaved s16 stereo and its arrival time in host seconds.
        mutating func next() -> (Data, Double) {
            let rate = 48000 * (1 + ppm / 1e6)
            var d = Data(count: chunk * 4)
            d.withUnsafeMutableBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<chunk {
                    let t = Double(produced + i) / rate
                    let click = clicks.contains { t >= $0 && t < $0 + 0.002 }
                    let v: Int16 = click ? 30000 : Int16(sin(t * 2 * .pi * 220) * 1000)
                    s[i * 2] = v; s[i * 2 + 1] = v
                }
            }
            produced += chunk
            let end = Double(produced) / rate + rng.uniform() * jitterMs / 1000
            for l in lose where Double(produced) / rate >= l.atSeconds && Double(produced - chunk) / rate < l.atSeconds { produced += l.samples }
            return (d, end)
        }
    }

    /// Feeds `seconds` of 30 fps video and `card` audio to a real `Recorder`, in timestamp order, as fast as the
    /// writer accepts it (waiting for readiness instead of sleeping, so nothing is dropped for being early).
    func record(_ url: URL, seconds: Double, card: Card) throws -> Recorder {
        var card = card
        let r = try Recorder(url: url, width: 256, height: 144, fps: 30, colorMode: .sdr, startNs: zero)
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 256, kCVPixelBufferHeightKey as String: 144,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &pool)
        var frame = 0
        var (chunk, chunkEnd) = card.next()
        func ns(_ s: Double) -> UInt64 { zero + UInt64(max(0, s) * 1e9) }
        let deadline = Date().addingTimeInterval(seconds + 120)
        func waitReady() {
            while !(r.video.isReadyForMoreMediaData && r.audio.isReadyForMoreMediaData) {
                if Date() > deadline { XCTFail("writer never became ready"); return }
                usleep(200)
            }
        }
        // Both stop at `seconds`, as a recording stops both at once: the last frame ends there, the last chunk within one
        // chunk of it.
        while true {
            let frameT = Double(frame) / 30
            let videoDone = frameT >= seconds - 0.001, audioDone = chunkEnd > seconds
            if videoDone && audioDone { break }
            if !videoDone && (audioDone || frameT <= chunkEnd) {
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
                waitReady()
                r.appendVideo(pb!, ns: ns(frameT + 0.0005)); r.queue.sync {}
                frame += 1
            } else {
                waitReady()
                r.appendAudio(chunk, ns: ns(chunkEnd)); r.queue.sync {}
                (chunk, chunkEnd) = card.next()
            }
        }
        return r
    }

    func finish(_ r: Recorder) async -> String { await withCheckedContinuation { c in r.finish { c.resume(returning: $0) } } }

    /// The regression for the runaway: a capture card with a sound clock and 3 ms of lost audio early on. The old slew
    /// dropped samples in the direction that made it worse, at 1% of every chunk, for the rest of the recording.
    func testGameAudioStaysOnTheVideoClockAfterASmallLoss() async throws {
        try requireHEVC()
        let url = dir.appendingPathComponent("game.mov")
        var card = Card(jitterMs: 2)
        card.lose = [(atSeconds: 5, samples: 144)]
        card.clicks = [2, 30, 58]
        let r = try record(url, seconds: 60, card: card)
        let msg = await finish(r)
        let video = try await trackRange(url, .video), audio = try await trackRange(url, .audio)
        XCTAssertEqual(audio.1, video.1, accuracy: 0.020, "audio ends \(audio.1), video \(video.1): \(msg)")
        let found = try await clicks(url, after: [1.9, 29.9, 57.9])
        XCTAssertEqual(found.count, 3)
        for (want, got) in zip([2.0, 30, 58], found) { XCTAssertEqual(got, want, accuracy: 0.010, "click placed at \(want) s") }
    }

    /// Ten minutes of a capture card 100 ppm fast with up to 8 ms of arrival latency and half a second of lost audio
    /// half way: the tracks end together and clicks land where they were made.
    func testLongRecordingWithDriftJitterAndAGap() async throws {
        try requireHEVC()
        let url = dir.appendingPathComponent("game.mov")
        var card = Card(ppm: 100, jitterMs: 8)
        card.lose = [(atSeconds: 300, samples: 24000)]
        card.clicks = [10, 299, 590]
        let r = try record(url, seconds: 600, card: card)
        let msg = await finish(r)
        let video = try await trackRange(url, .video), audio = try await trackRange(url, .audio)
        XCTAssertEqual(audio.1, video.1, accuracy: 0.020, "audio ends \(audio.1), video \(video.1): \(msg)")
        XCTAssertEqual(r.audioClock.gaps, 1, msg)
        let found = try await clicks(url, after: [9.9, 298.9, 589.9])
        XCTAssertEqual(found.count, 3)
        for (want, got) in zip([10.0, 299, 590], found) { XCTAssertEqual(got, want, accuracy: 0.010, "click placed at \(want) s") }
    }

    /// The mic layer: 1024-sample buffers stamped with their first sample's host time, and a 0.5 s hole in delivery
    /// (what the Studio Display microphone did every ten minutes). The voice after the hole stays where it was said.
    func testMicLayerKeepsItsPlaceAcrossAHole() async throws {
        let url = dir.appendingPathComponent("mic.mov")
        let mic = try LayerWriter(micURL: url, startNs: zero)
        let clicksAt = [5.0, 30.0, 58.0]
        var produced = 0, rng = SplitMix(seed: 3)
        while Double(produced) / 48000 < 60 {
            let t0 = Double(produced) / 48000
            if t0 >= 20 && t0 < 20.5 { produced += 1024; continue }      // nothing delivered for half a second
            let samples = (0..<1024).map { i -> Float in
                let t = Double(produced + i) / 48000
                return clicksAt.contains { t >= $0 && t < $0 + 0.002 } ? 0.9 : Float(sin(t * 2 * .pi * 300) * 0.05)
            }
            let sb = try XCTUnwrap(LayerWriter.sampleBuffer(samples, pts: .zero))
            let wait = Date().addingTimeInterval(10)
            while !mic.input.isReadyForMoreMediaData && Date() < wait { usleep(200) }
            mic.appendAudio(sb, ns: zero + UInt64((t0 + rng.uniform() * 0.002) * 1e9)); mic.queue.sync {}
            produced += 1024
        }
        let ok = await withCheckedContinuation { c in mic.finish { c.resume(returning: $0) } }
        XCTAssertTrue(ok)
        let range = try await trackRange(url, .audio)
        XCTAssertEqual(range.1, Double(produced) / 48000, accuracy: 0.020)
        XCTAssertEqual(mic.clock.gaps, 1)
        let found = try await clicks(url, after: clicksAt.map { $0 - 0.1 })
        XCTAssertEqual(found.count, 3)
        for (want, got) in zip(clicksAt, found) { XCTAssertEqual(got, want, accuracy: 0.010, "click said at \(want) s") }
    }
}

/// Deterministic generator for jitter in tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
