import XCTest
import AVFoundation
import VideoToolbox
@testable import StudioKit

/// The completion of a stopped recording must report failures, not "saved".
final class RecordingOutcomeTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("Outcome-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testOutcomeFromProject() {
        var p = Project(name: "Capture 1", createdAt: Date()); p.state = "complete"; p.mic = LayerInfo(file: "mic.mov")
        let saved = RecordingOutcome(project: p, gameError: nil)
        XCTAssertEqual(saved, .saved(name: "Capture 1", layers: ["game", "mic"]))
        XCTAssertEqual(saved.logLine, "saved Capture 1 [game + mic]")
        XCTAssertEqual(saved.toast.style, .success); XCTAssertEqual(saved.toast.detail, "Capture 1 · game, mic")

        p.state = "damaged"
        let damaged = RecordingOutcome(project: p, gameError: nil)
        guard case .failed = damaged else { return XCTFail("damaged project reported as \(damaged)") }
        XCTAssertEqual(damaged.toast.style, .error)
        XCTAssertTrue(damaged.logLine.hasPrefix("recording failed: "))

        p.state = "complete"   // fragments made it readable, but the writer failed
        guard case .failed = RecordingOutcome(project: p, gameError: "disk full") else { return XCTFail() }
    }

    /// A game writer cancelled mid-recording: finish reports a failure, finalize runs, the outcome is a failure.
    func testCancelledGameWriterReportsFailure() async throws {
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard status == noErr, let e = encoder else { throw XCTSkip("No hardware HEVC encoder (\(status))") }
        VTCompressionSessionInvalidate(e)

        let zero: UInt64 = 1_000_000_000
        let r = try Recorder(url: dir.appendingPathComponent("game.mov"), width: 640, height: 360, fps: 30, colorMode: .pq, startNs: zero)
        for frame in 0..<15 {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
            let ns: UInt64 = zero + UInt64(Double(frame) * 1e9 / 30)
            r.appendVideo(try XCTUnwrap(out), ns: ns)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        r.queue.sync { r.writer.cancelWriting() }
        let msg: String = await withCheckedContinuation { c in r.finish { c.resume(returning: $0) } }
        XCTAssertNotEqual(r.writer.status, .completed)
        let gameError = RecordingOutcome.writerError(r.writer, message: msg)   // as in finishRecording
        XCTAssertNotNil(gameError)

        var p = Project(name: "Cancelled", createdAt: Date()); p.state = "recording"
        let doc = ProjectDoc(dir: dir, project: p); doc.save()
        await withCheckedContinuation { c in doc.finalize { c.resume() } }
        let outcome = RecordingOutcome(project: doc.project, gameError: gameError)
        guard case .failed(let reason) = outcome else { return XCTFail("cancelled writer reported as \(outcome)") }
        XCTAssertTrue(reason.contains("Cancelled"), reason)
        XCTAssertEqual(outcome.toast.text, "Recording failed")
    }
}
