import XCTest
import AVFoundation
import CoreVideo
@testable import StudioKit

/// Small recordings written as fast as the encoder takes them, at any frame rate. Frame times are nanoseconds,
/// rounded the way the recorder rounds them, so 59.94 fps frames do not sit on any small timescale.
enum GeneratedMedia {
    static func write(_ url: URL, frameDuration: Double? = nil, videoSeconds: Double = 0, audioSeconds: Double? = nil, startSeconds: Double = 0) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var video: (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)?
        if frameDuration != nil {
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
            i.expectsMediaDataInRealTime = false
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
            writer.add(i); video = (i, a)
        }
        var audio: AVAssetWriterInput?
        if audioSeconds != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            i.expectsMediaDataInRealTime = false
            writer.add(i); audio = i
        }
        guard writer.startWriting() else { throw writer.error ?? CompositionBuilder.err("fixture writer") }
        let start = CMTime(value: Int64((startSeconds * 1e9).rounded()), timescale: 1_000_000_000)
        writer.startSession(atSourceTime: start)
        // Each input pulls its own samples when the writer asks (it interleaves the tracks itself).
        let group = DispatchGroup()
        var failure: Error?
        let lock = NSLock()
        func fail(_ e: Error) { lock.lock(); if failure == nil { failure = e }; lock.unlock() }
        if let (i, a) = video, let fd = frameDuration {
            let frames = Int((videoSeconds / fd).rounded())
            var n = 0
            group.enter()
            i.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture-video")) {
                while i.isReadyForMoreMediaData && n < frames {
                    var pb: CVPixelBuffer?
                    if let pool = a.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
                    guard let buffer = pb else { fail(CompositionBuilder.err("pixel buffer")); n = frames; break }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    memset(CVPixelBufferGetBaseAddress(buffer), Int32(n * 7 % 255), CVPixelBufferGetDataSize(buffer))
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    let t = CMTime(value: Int64(((startSeconds + Double(n) * fd) * 1e9).rounded()), timescale: 1_000_000_000)
                    if !a.append(buffer, withPresentationTime: t) { fail(writer.error ?? CompositionBuilder.err("append video")); n = frames; break }
                    n += 1
                }
                if n >= frames { i.markAsFinished(); group.leave() }
            }
        }
        if let i = audio, let seconds = audioSeconds {
            let total = Int(seconds * 48000), chunk = 1024
            var sample = 0
            group.enter()
            i.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture-audio")) {
                while i.isReadyForMoreMediaData && sample < total {
                    var shifted: CMSampleBuffer?
                    if let sb = CameraCapture.demoAudio(sample: sample, count: min(chunk, total - sample)) {
                        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                                        presentationTimeStamp: CMTimeAdd(start, CMTime(value: Int64(sample), timescale: 48000)), decodeTimeStamp: .invalid)
                        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted)
                    }
                    guard let s = shifted, i.append(s) else { fail(writer.error ?? CompositionBuilder.err("append audio")); sample = total; break }
                    sample += chunk
                }
                if sample >= total { i.markAsFinished(); group.leave() }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }
        if let e = failure { throw e }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompositionBuilder.err("fixture finish") }
    }

    /// A project with game (video and audio), camera and mic layers of slightly different lengths and starts.
    static func project(at dir: URL, fps: Double, seconds: Double = 3) async throws -> ProjectDoc {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = fps == 59.94 ? 1001.0 / 60000 : 1 / fps
        try await write(dir.appendingPathComponent("game.mov"), frameDuration: fd, videoSeconds: seconds, audioSeconds: seconds + 0.013)
        try await write(dir.appendingPathComponent("camera.mov"), frameDuration: 1 / 30, videoSeconds: seconds - 0.4, startSeconds: 0.000_000_001)
        try await write(dir.appendingPathComponent("mic.mov"), audioSeconds: seconds - 0.25)
        let track = try await AVURLAsset(url: dir.appendingPathComponent("game.mov")).loadTracks(withMediaType: .video).first!
        let range = try await track.load(.timeRange)
        var p = Project(name: dir.lastPathComponent, createdAt: Date())
        p.width = 320; p.height = 180; p.fps = fps; p.colorMode = ColorMode.sdr.rawValue
        p.durationMs = range.end.seconds * 1000
        p.camera = LayerInfo(file: "camera.mov"); p.mic = LayerInfo(file: "mic.mov")
        return ProjectDoc(dir: dir, project: p)
    }
}

/// Independently rounded endpoints left a 1/60000 s tail outside the instruction and every export failed
/// with -11841. The composition timing must be exact for any cut set, frame rate and layer offset.
final class CompositionTimingTests: XCTestCase {
    static func randomCuts(_ rng: inout SeededRandom, durationMs d: Double, toEnd: Bool) -> [Segment] {
        let n = Int.random(in: 1...4, using: &rng)
        var points = (0..<(2 * n)).map { _ in Double.random(in: 0...d, using: &rng) }.sorted()
        if toEnd { points[points.count - 1] = d }
        return stride(from: 0, to: points.count, by: 2).map { Segment(startMs: points[$0], endMs: points[$0 + 1]) }.filter { $0.endMs - $0.startMs > 40 }
    }

    func testRandomCutsValidateAndExportAtEveryFrameRate() async throws {
        try TimelineExportTests().requireHardware()
        var rng = SeededRandom(state: 31)
        var checked = 0, exported = 0
        for fps in [30, 59.94, 60, 120] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Timing-\(fps)-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let doc = try await GeneratedMedia.project(at: dir, fps: fps)
            XCTAssertTrue(doc.hasCamera && doc.hasMic)
            for k in 0..<12 {
                var segments = Self.randomCuts(&rng, durationMs: doc.project.durationMs, toEnd: k % 3 == 0)
                if segments.isEmpty { segments = [Segment(startMs: 100, endMs: doc.project.durationMs)] }
                doc.project.timeline.segments = segments
                doc.project.camera?.offsetMs = (Double.random(in: -700...700, using: &rng) * 3).rounded() / 3
                doc.project.mic?.offsetMs = (Double.random(in: -700...700, using: &rng) * 7).rounded() / 7
                let label = "\(fps) fps, cuts \(segments.map { "\($0.startMs)-\($0.endMs)" }), camera \(doc.project.camera!.offsetMs), mic \(doc.project.mic!.offsetMs)"
                for canvas in Canvas.allCases {
                    let b = try await CompositionBuilder.build(doc, canvas: canvas, resolution: .hd, range: .sdr)
                    let problems = try await CompositionBuilder.validate(b)
                    XCTAssertEqual(problems, [], label)
                    let instructions = b.video.instructions
                    XCTAssertEqual(instructions.first?.timeRange.start, .zero, label)
                    XCTAssertEqual(instructions.last.map { CMTimeRangeGetEnd($0.timeRange) }, b.asset.duration, "the instruction ends exactly where the composition does: \(label)")
                    XCTAssertEqual(b.duration, b.asset.duration, label)
                    checked += 1
                }
                if k < 2 {
                    let out = dir.appendingPathComponent("export-\(k).mp4")
                    let job = ExportJob(canvas: k == 0 ? .wide : .vertical, resolution: .hd, range: .sdr, fps: .source)
                    do {
                        let url = try await Exporter(doc: doc, job: job, output: out).run { _ in }
                        let d = try await AVURLAsset(url: url).load(.duration)
                        let kept = TimelineEdits.kept(doc.project).reduce(0) { $0 + $1.endMs - $1.startMs }
                        XCTAssertEqual(d.seconds * 1000, kept, accuracy: 1000 / fps + 1, label)
                        exported += 1
                    } catch { XCTFail("export failed: \(error.localizedDescription) — \(label)") }
                }
            }
        }
        print("Composition timing: \(checked) compositions validated, \(exported) exported, at 30/59.94/60/120 fps")
    }
}
