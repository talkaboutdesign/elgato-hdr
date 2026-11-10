import XCTest
import AVFoundation
@testable import StudioKit

/// Acceptance 4: a YouTube and a Shorts preset in one queue, through the real exporter, each file checked the way
/// plan 30 checks timeline exports (duration after cuts, the frames either side of each cut, the zoom, the scene
/// change and agreement with the preview composition).
final class ExportQueueIntegrationTests: XCTestCase {
    func testYouTubeAndShortsInOneQueue() async throws {
        let t = TimelineExportTests()
        try t.requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await SharedRecording.shared.copy(to: dir, frames: 180)
        let game = Composition(layers: [Layer(source: .game, fit: true)])
        let pip = Composition(layers: [Layer(source: .game, fit: true), Layer(source: .camera, frame: NRect(x: 0.65, y: 0.1, w: 0.3, h: 0.3))])
        let a = Scene(name: "Game", wide: game, vertical: game), b = Scene(name: "Camera", wide: pip, vertical: pip)
        doc.project.scenes = [a, b]
        doc.project.timeline = Timeline(segments: [Segment(startMs: 0, endMs: 500), Segment(startMs: 750, endMs: 1750), Segment(startMs: 2000, endMs: 3000)],
            sceneSpans: [SceneSpan(startMs: 0, sceneID: a.id), SceneSpan(startMs: 2200, sceneID: b.id, transition: SceneTransition(style: .fade, durationMs: 100))],
            zooms: [ZoomBlock(startMs: 1000, endMs: 1666.6666667, scale: 1.8, focusX: 0.43, focusY: 0.79, easeMs: 100)])

        let queue = await MainActor.run { ExportQueue { job in Exporter(doc: doc, job: job) } }
        let started = Date()
        let finished: [ExportQueue.Item] = await withCheckedContinuation { c in
            DispatchQueue.main.async {
                var done: [ExportQueue.Item] = []
                queue.onFinished = { done.append($0) }
                queue.onDrained = { c.resume(returning: done) }
                let p = doc.project, custom = ExportPreset.Custom()
                queue.enqueue(ExportPreset.youtube.jobs(for: p, custom: custom).map { ("YouTube", $0) }
                              + ExportPreset.shorts.jobs(for: p, custom: custom).map { ("Shorts", $0) })
            }
        }
        XCTAssertEqual(finished.map(\.title), ["YouTube", "Shorts"], "run in queue order")
        for item in finished {
            guard case .done(let url) = item.state else { XCTFail("\(item.title): \(item.state)"); continue }
            let job = item.job
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 2.5, accuracy: 1 / 60, "\(item.title) keeps 2.5 s after cuts")
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size, job.canvas.size(job.resolution))
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), job.range == .hdr ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264)
            let fps = try await track.load(.nominalFrameRate)
            XCTAssertEqual(Double(fps), 60, accuracy: 0.5)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audio.isEmpty)

            let built = try await CompositionBuilder.build(doc, canvas: job.canvas, resolution: job.resolution, range: job.range, fps: job.fps)
            let export = t.generator(asset), preview = t.generator(built.asset, video: built.video)
            let gameRect = LayoutMath.fitRect(CGSize(width: 1920, height: 1080), in: CGRect(origin: .zero, size: job.canvas.size(job.resolution)))
            var codes: [Int] = []
            for frame in [29, 30, 89, 91] { let px = try await t.pixels(export, frame); codes.append(px.strip(in: gameRect)) }
            XCTAssertEqual(codes, [29, 45, 104, 121], "\(item.title): the frames either side of each cut")
            let normal = try await t.pixels(export, 25), zoom = try await t.pixels(export, 70)
            let roi = CGRect(x: gameRect.minX + gameRect.width * 0.2, y: gameRect.minY + gameRect.height * 0.55, width: gameRect.width * 0.5, height: gameRect.height * 0.35)
            let small = normal.squarePixels(in: roi), large = zoom.squarePixels(in: roi)
            XCTAssertGreaterThan(large, small * 2, "\(item.title): the zoom block zooms")
            let s = job.canvas.size(job.resolution), cameraRect = CGRect(x: s.width * 0.7, y: s.height * 0.15, width: s.width * 0.2, height: s.height * 0.2)
            let before = try await t.pixels(export, 100), after = try await t.pixels(export, 140)
            XCTAssertGreaterThan(before.difference(after, in: cameraRect), 10, "\(item.title): the scene change shows the camera")
            var worst = 0.0
            for frame in [10, 30, 70, 110, 140] {
                let p = try await t.pixels(preview, frame), e = try await t.pixels(export, frame)
                worst = max(worst, p.difference(e))
            }
            XCTAssertLessThanOrEqual(worst, 3, "\(item.title): export matches the preview composition")
            print(String(format: "Queue export %@ (%@): %@, %.3f s, cut strip %@, square %d -> %d, preview/export mean RGB error %.3f/255",
                         item.title, ExportPreset.describe(job), url.lastPathComponent, duration.seconds, String(describing: codes), small, large, worst))
        }
        print(String(format: "Queue of %d exports finished in %.2f s", finished.count, Date().timeIntervalSince(started)))
    }
}
