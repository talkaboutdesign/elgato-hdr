import XCTest
import AVFoundation
@testable import StudioKit

/// A recording's first game frame lands a little after time 0 (about 0.13 s). Until then the preview and every export
/// hold that first frame rather than showing no game; the recorded files are not changed.
final class FirstFrameHoldTests: XCTestCase {
    func project() async throws -> ProjectDoc {
        try TimelineExportTests().requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FirstFrame-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let doc = try await GeneratedMedia.project(at: dir, fps: 30, seconds: 2)
        // As the recorder writes it: the session (and the audio) from 0, the first video frame at 0.13 s.
        try FileManager.default.removeItem(at: doc.url("game.mov"))
        try await GeneratedMedia.write(doc.url("game.mov"), frameDuration: 1.0 / 30, videoSeconds: 2, audioSeconds: 2.2, videoDelaySeconds: 0.13)
        // A white background, so a frame without the game (the first frame is black) is unmistakable.
        let game = Scene(name: "Game", wide: Composition(background: [1, 1, 1, 1], layers: [Layer(source: .game)]),
                         vertical: Composition(background: [1, 1, 1, 1], layers: [Layer(source: .game)]))
        doc.project.scenes = [game]; doc.project.timeline = Timeline(sceneSpans: [SceneSpan(startMs: 0, sceneID: game.id)])
        doc.project.camera = nil
        doc.save()
        return doc
    }

    func testPreviewAndExportHoldTheFirstGameFrame() async throws {
        let doc = try await project()
        let tracks = try await AVURLAsset(url: doc.url("game.mov")).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let segments = try await track.load(.segments)
        let firstMs = try XCTUnwrap(segments.first { !$0.isEmpty }).timeMapping.target.start.seconds * 1000
        XCTAssertEqual(firstMs, 130, accuracy: 1, "the fixture's first frame is late, as a recording's is")
        var report: [String] = []
        for ignoreCuts in [true, false] {                     // the preview plays the uncut source; exports the kept ranges
            let built = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr, ignoreCuts: ignoreCuts)
            let problems = try await CompositionBuilder.validate(built)
            XCTAssertEqual(problems, [])
            let atFirst = RawCompositionFrames.codes(try RawCompositionFrames.frame(built.asset, video: built.video, ms: 130, hdr: false))
            for ms in [0.0, 50, 100] {
                let held = RawCompositionFrames.codes(try RawCompositionFrames.frame(built.asset, video: built.video, ms: ms, hdr: false))
                let worst = zip(held, atFirst).map { abs($0 - $1) }.max() ?? 255
                report.append(String(format: "%@ %.0f ms: max diff %.0f", ignoreCuts ? "preview" : "export", ms, worst))
                XCTAssertLessThanOrEqual(worst, 1, "\(ignoreCuts ? "preview" : "export") at \(ms) ms shows the first game frame")
            }
            let duration = try await built.asset.load(.duration).seconds
            XCTAssertEqual(duration, 2.13, accuracy: 0.04, "nothing shifted")
        }
        // The frame after the first is untouched (the hold does not push the recording later).
        let built = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr)
        let second = RawCompositionFrames.codes(try RawCompositionFrames.frame(built.asset, video: built.video, ms: 130 + 1000.0 / 30 + 5, hdr: false))
        let first = RawCompositionFrames.codes(try RawCompositionFrames.frame(built.asset, video: built.video, ms: 130, hdr: false))
        XCTAssertGreaterThan(zip(second, first).map { abs($0 - $1) }.max() ?? 0, 3, "frame 1 follows frame 0 at its own time")
        print("First-frame hold: " + report.joined(separator: "; "))
    }
}
