import XCTest
import AVFoundation
@testable import StudioKit

/// Recordings made before plan 44: detecting squeezed game audio, storing the correction, composing with it.
final class GameAudioRepairTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("GameAudioRepair-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func decode(_ json: String) throws -> Project {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Project.self, from: Data(json.utf8))
    }

    func testOldProjectsHaveNoCorrectionAndNoClockMark() throws {
        let p = try decode(#"{"name": "Old", "durationMs": 1000}"#)
        XCTAssertNil(p.gameAudioSync)
        XCTAssertFalse(p.audioClock)
    }

    func testCorrectionRoundTrips() throws {
        var p = Project(name: "Fixed", createdAt: Date(timeIntervalSince1970: 0))
        p.audioClock = true
        p.gameAudioSync = AudioTimeMap(points: [[0.06, 0.06], [38, 38], [2913.8, 2940.27]])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let back = try decode(String(decoding: try enc.encode(p), as: UTF8.self))
        XCTAssertEqual(back.gameAudioSync, p.gameAudioSync)
        XCTAssertTrue(back.audioClock)
        // Fields absent when there is nothing to say, so older versions see the file they know.
        let plain = String(decoding: try enc.encode(Project(name: "Plain", createdAt: Date())), as: UTF8.self)
        XCTAssertFalse(plain.contains("gameAudioSync")); XCTAssertFalse(plain.contains("audioClock"))
    }

    func testGarbageCorrectionsAreDropped() throws {
        for bad in [#""points""#, #"{"points": "x"}"#, #"{"points": [[0, 0]]}"#, #"{"points": [[0, 0], [5, 4], [4, 6]]}"#,
                    #"{"points": [[0, 0, 1], [5, 5]]}"#, #"{"points": [[0, 0], [5, 5], [6, 5]]}"#, #"{}"#, "42", "null"] {
            let p = try decode(#"{"name": "Bad", "durationMs": 1000, "gameAudioSync": \#(bad), "audioClock": "yes"}"#)
            XCTAssertNil(p.gameAudioSync, bad)
            XCTAssertFalse(p.audioClock)
            XCTAssertEqual(p.durationMs, 1000)
        }
    }

    /// The two recordings this was measured on, with their real track ranges.
    func testMapsForTheMeasuredRecordings() throws {
        let late = try XCTUnwrap(GameAudioRepair.map(video: 0.133333...2466.266667, audio: 0.096667...2445.600667))
        XCTAssertEqual(late.points.count, 3)
        XCTAssertEqual(late.points[1][1], 198.9, accuracy: 0.5)           // the runaway began about 3:19 in
        XCTAssertEqual(late.recording(at: 100), 100, accuracy: 1e-9)
        XCTAssertEqual(late.recording(at: 2445.600667), 2466.266667, accuracy: 1e-9)
        let early = try XCTUnwrap(GameAudioRepair.map(video: 0.066667...2940.266667, audio: 0.064646...2913.813979))
        XCTAssertEqual(early.points[1][1], 38.0, accuracy: 0.5)
        // After the break the audio runs 1/(1 - 7/768) times slower, to the frame.
        XCTAssertEqual((early.points[2][1] - early.points[1][1]) / (early.points[2][0] - early.points[1][0]), 768.0 / 761, accuracy: 1e-6)
        XCTAssertEqual(early.audio(at: early.recording(at: 1234.5)), 1234.5, accuracy: 1e-9)
    }

    func testStretchedAudioAndSmallDifferences() throws {
        // Audio 2% long over a minute: more than the runaway could add, so spread from the start.
        let long = try XCTUnwrap(GameAudioRepair.map(video: 0...60, audio: 0...61.2))
        XCTAssertEqual(long.points, [[0, 0], [61.2, 60]])
        // 0.5% long: the repeats began 33 s before the end.
        let late = try XCTUnwrap(GameAudioRepair.map(video: 0...60, audio: 0...60.3))
        XCTAssertEqual(late.points[1][0], 60 - 0.3 * 768 / 7, accuracy: 1e-9)
        // 0.1% or less is left alone.
        XCTAssertNil(GameAudioRepair.map(video: 0...600, audio: 0...599.5))
        XCTAssertNil(GameAudioRepair.map(video: 0...600, audio: 0.02...600.01))
    }

    /// A game.mov whose audio is 1% short (clicks at 1, 5 and 9 s of recording sit at 0.99, 4.95 and 8.91 s in the
    /// file): detected on open, stored, and composed to an audio track as long as the video with the clicks in place.
    func testShortGameAudioComposesToTheVideoLength() async throws {
        let url = dir.appendingPathComponent("game.mov")
        try await writeMovie(url, videoSeconds: 10, audioSeconds: 9.9, clicksInFile: [0.99, 4.95, 8.91])
        var project = Project(name: "Short", createdAt: Date())
        project.fps = 30; project.colorMode = ColorMode.sdr.rawValue; project.durationMs = 10_000
        let m = await GameAudioRepair.detect(project, game: url)
        XCTAssertEqual(m?.points, [[0, 0], [9.9, 10]])
        project.gameAudioSync = m
        let doc = ProjectDoc(dir: dir, project: project); doc.save()
        XCTAssertEqual(ProjectDoc.load(dir)?.project.gameAudioSync, m)
        // Once stored (or for a recording made with the fix) it is not checked again.
        let again = await GameAudioRepair.detect(project, game: url)
        XCTAssertNil(again)

        let built = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr)
        let audio = try XCTUnwrap(built.asset.tracks(withMediaType: .audio).first)
        XCTAssertEqual(audio.timeRange.end.seconds, 10, accuracy: 1.0 / 30)
        let found = try readClicks(built, after: [0.9, 4.9, 8.9])
        XCTAssertEqual(found.count, 3)
        for (want, got) in zip([1.0, 5, 9], found) { XCTAssertEqual(got, want, accuracy: 0.010, "click at \(want) s") }
    }

    // MARK: Fixture

    func writeMovie(_ url: URL, videoSeconds: Double, audioSeconds: Double, clicksInFile: [Double]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1])
        writer.add(video); writer.add(audio)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var frame = 0, sample = 0
        let frames = Int(videoSeconds * 30), samples = Int(audioSeconds * 48000)
        // Feed whichever input is ready, earlier timestamp first: the writer interleaves and can hold one input back
        // until the other catches up, so waiting on one input alone can deadlock. Each finishes as soon as it is done.
        let deadline = Date().addingTimeInterval(60)
        var videoDone = false, audioDone = false
        while !(videoDone && audioDone) {
            guard Date() < deadline else { XCTFail("fixture writer stalled at frame \(frame), sample \(sample)"); break }
            if !videoDone && frame == frames { video.markAsFinished(); videoDone = true }
            if !audioDone && sample == samples { audio.markAsFinished(); audioDone = true }
            let videoFirst = !videoDone && (audioDone || Double(frame) / 30 <= Double(sample) / 48000)
            if !videoDone && video.isReadyForMoreMediaData && (videoFirst || !audio.isReadyForMoreMediaData) {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, 160, 96, kCVPixelFormatType_32BGRA, nil, &pb)
                XCTAssertTrue(adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
                frame += 1
            } else if !audioDone && audio.isReadyForMoreMediaData {
                let n = min(1024, samples - sample)
                let chunk = (0..<n).map { i -> Float in
                    let t = Double(sample + i) / 48000
                    return clicksInFile.contains { t >= $0 && t < $0 + 0.02 } ? Float(sin(t * 2 * .pi * 1000) * 0.9) : 0
                }
                XCTAssertTrue(audio.append(try XCTUnwrap(LayerWriter.sampleBuffer(chunk, pts: CMTime(value: CMTimeValue(sample), timescale: 48000)))))
                sample += n
            } else { usleep(500) }
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    /// Where the composed audio (mix and time-pitch as the exporter renders it) first passes 0.3 after each time.
    func readClicks(_ built: BuiltComposition, after: [Double]) throws -> [Double] {
        let reader = try AVAssetReader(asset: built.asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: built.asset.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000])
        out.audioMix = built.audioMix
        out.audioTimePitchAlgorithm = CompositionBuilder.timePitch
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var found: [Double] = [], pending = after
        while let sb = out.copyNextSampleBuffer(), !pending.isEmpty {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let count = CMBlockBufferGetDataLength(block) / 4
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            for i in 0..<count where !pending.isEmpty {
                let t = pts + Double(i) / 48000
                if t > pending[0] && abs(samples[i]) > 0.3 { found.append(t); pending.removeFirst() }
            }
        }
        reader.cancelReading()
        return found
    }
}
