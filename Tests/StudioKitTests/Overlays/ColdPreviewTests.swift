import XCTest
import AVFoundation
@testable import StudioKit

/// The editor preview with a cold overlay cache (nothing made yet, as when a project is opened first): a paused
/// preview first goes out without the overlay, then redraws with it once the texture is ready. The parity test renders
/// the export first, which warms the shared cache, so it could not see this.
final class ColdPreviewTests: XCTestCase {
    static let logo = NRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4)

    func testPausedPreviewRedrawsWithTheOverlayFromAColdCache() async throws {
        try TimelineExportTests().requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ColdPreview-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let doc = try await GeneratedMedia.project(at: dir, fps: 30, seconds: 2)
        let png = dir.appendingPathComponent("red.png")
        try OverlayTestSupport.writePNG(png, width: 64, height: 36, rgba: (0..<64 * 36).flatMap { _ in [255, 0, 0, 255] as [UInt8] })
        let name = try AssetStore.importImage(png, into: dir.appendingPathComponent("Assets"))
        let scene = Scene(name: "Logo", wide: Composition(layers: [Layer(source: .game), Layer(source: LayerSource(type: "image", file: name), frame: Self.logo)]))
        doc.project.scenes = [scene]
        doc.project.timeline = Timeline(sceneSpans: [SceneSpan(startMs: 0, sceneID: scene.id)])
        doc.project.state = "complete"
        doc.save()

        let cold = OverlayTextureCache(device: MetalCore.shared.device)
        let (m, frames) = await MainActor.run { () -> (EditorModel, PreviewFrames) in
            let m = EditorModel(doc: doc, overlayCache: cold)
            return (m, PreviewFrames(m))
        }
        defer { DispatchQueue.main.async { m.close() } }
        let result = await frames.run(timeout: 15)
        print("Cold preview: \(result.redraws) redraw(s) for late overlays, \(result.frames) frame(s) seen, overlay in frame \(result.firstRed.map(String.init) ?? "none")")
        XCTAssertNotNil(result.instructionUsesCold, "the preview's frames were composed")
        XCTAssertEqual(result.instructionUsesCold, true, "the preview looks textures up in the cold cache")
        // Nothing edits the project here: every new preview revision after loading is a redraw for a late overlay,
        // which the compositor asks for only when a frame went out without one.
        XCTAssertGreaterThanOrEqual(result.redraws, 1, "a frame went out before the texture existed and asked for a redraw")
        XCTAssertNotNil(result.firstRed, "the paused preview redrew with the overlay once it was ready")
        XCTAssertFalse(m.playing)
        XCTAssertGreaterThan(cold.rasterCount, 0)
    }
}

/// Watches the preview's own player item with a video output: the frames a paused preview shows.
@MainActor
final class PreviewFrames {
    let model: EditorModel
    init(_ m: EditorModel) { model = m }

    struct Result { var frames = 0; var firstHadOverlay: Bool?; var firstRed: Int?; var redraws = 0; var instructionUsesCold: Bool? }

    nonisolated func run(timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.poll(deadline: Date().addingTimeInterval(timeout), c) } }
        }
    }

    private var output: AVPlayerItemVideoOutput?
    private var result = Result()
    private var revisionAtLoad: Int?

    private func poll(deadline: Date, _ c: CheckedContinuation<Result, Never>) {
        if output == nil, let item = model.player.currentItem {
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(o); output = o
            revisionAtLoad = model.previewRevision
            result.instructionUsesCold = (item.videoComposition?.instructions.first as? CompositionInstruction)?.plan.overlay?.cache === model.overlayCache
        }
        if let o = output, let item = model.player.currentItem {
            let t = item.currentTime()
            if o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                result.frames += 1
                let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
                let r = ColdPreviewTests.logo.rect(in: size).insetBy(dx: size.width * 0.05, dy: size.height * 0.05)
                let red = OverlayExportTests.count(pb, in: r, rgb: [255, 0, 0], tolerance: 16) > Int(r.width / 2 * r.height / 2) * 9 / 10
                if result.firstHadOverlay == nil { result.firstHadOverlay = red }
                if red && result.firstRed == nil { result.firstRed = result.frames }
            }
        }
        if let base = revisionAtLoad { result.redraws = model.previewRevision - base }
        if result.firstRed != nil || Date() > deadline { c.resume(returning: result); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { MainActor.assumeIsolated { self.poll(deadline: deadline, c) } }
    }
}
