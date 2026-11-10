import XCTest
import AVFoundation
import CoreVideo
import ImageIO
@testable import StudioKit

/// Image and text layers in the editor's compositor: exports, thumbnails and the preview draw them through the live
/// texture cache, transitions treat them as live does, and a missing image never fails an export.
final class OverlayExportTests: XCTestCase {
    static let imageFrame = NRect(x: 0.05, y: 0.1, w: 0.15, h: 0.15 * 16 / 9)
    static let textFrame = NRect(x: 0.55, y: 0.78, w: 0.4, h: 0.12)
    static let plate: [Double] = [0, 0, 1, 1]

    /// A 2 s, 30 fps SDR recording; scene "Overlays" has a red image and a `{timer}` text on a blue plate, scene
    /// "Moved" has the image elsewhere (morph by id) and different text (a cross-fade), switched to at 1.0 s.
    func project(missingImage: Bool = false) async throws -> (ProjectDoc, Layer, Layer) {
        try TimelineExportTests().requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OverlayExport-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let doc = try await GeneratedMedia.project(at: dir, fps: 30, seconds: 2)
        let png = dir.appendingPathComponent("red.png")
        try OverlayTestSupport.writePNG(png, width: 64, height: 64, rgba: (0..<64 * 64).flatMap { _ in [255, 0, 0, 255] as [UInt8] })
        // Imported into the project's own Assets/ only: the lookup must find it there.
        let name = missingImage ? "00000000deadbeef.png" : try AssetStore.importImage(png, into: dir.appendingPathComponent("Assets"))
        let image = Layer(name: "Logo", source: LayerSource(type: "image", file: name), frame: Self.imageFrame)
        let text = Layer(name: "Clock", source: LayerSource(type: "text", text: TextSpec(string: "{timer}", weight: "bold", plate: Self.plate)), frame: Self.textFrame)
        var moved = image; moved.frame.x = 0.75
        var other = text; other.source.text?.string = "LIVE"
        let game = Layer(name: "Game", source: .game)
        let a = Scene(name: "Overlays", wide: Composition(layers: [game, image, text]), vertical: Composition(layers: [game, image, text]))
        let b = Scene(name: "Moved", wide: Composition(layers: [game, moved, other]), vertical: Composition(layers: [game, moved, other]))
        doc.project.scenes = [a, b]
        doc.project.timeline = Timeline(sceneSpans: [SceneSpan(startMs: 0, sceneID: a.id), SceneSpan(startMs: 1000, sceneID: b.id, transition: SceneTransition(style: .morph, durationMs: 400))])
        doc.save()
        return (doc, image, text)
    }

    static func bgra(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Double] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb)
        return (0..<4).map { Double(row[x * 4 + $0]) }
    }
    /// Mean absolute difference over a rectangle of two BGRA buffers of the same size.
    static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in r: CGRect) -> Double {
        var total = 0.0, n = 0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) { for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) {
            for (p, q) in zip(bgra(a, x, y).prefix(3), bgra(b, x, y).prefix(3)) { total += abs(p - q); n += 1 }
        } }
        return total / Double(max(1, n))
    }
    /// Pixels in `r` within `tolerance` of an RGB colour.
    static func count(_ pb: CVPixelBuffer, in r: CGRect, rgb: [Double], tolerance: Double) -> Int {
        var n = 0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) { for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) {
            let p = bgra(pb, x, y)
            if abs(p[2] - rgb[0]) <= tolerance && abs(p[1] - rgb[1]) <= tolerance && abs(p[0] - rgb[2]) <= tolerance { n += 1 }
        } }
        return n
    }

    /// The export has both overlays; each region matches the compositor's own frame (the reference) after encoding,
    /// shows the image's red and the text's white on its blue plate, and the image moved after the morph.
    func testExportDrawsImageAndTextLayers() async throws {
        let (doc, _, _) = try await project()
        let url = try await Exporter(doc: doc, job: ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source)).run { _ in }
        let built = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr)
        let size = Canvas.wide.size(.hd)
        let img = Self.imageFrame.rect(in: size), txt = Self.textFrame.rect(in: size)
        let inner = img.insetBy(dx: img.width * 0.2, dy: img.height * 0.2)
        let decoded = try RawCompositionFrames.frame(AVURLAsset(url: url), ms: 500, hdr: false)
        let reference = try RawCompositionFrames.frame(built.asset, video: built.video, ms: 500, hdr: false)
        XCTAssertLessThan(Self.difference(decoded, reference, in: img), 4, "image region against the compositor's frame")
        XCTAssertLessThan(Self.difference(decoded, reference, in: txt), 6, "text region against the compositor's frame")
        let total = Int(inner.width / 2) * Int(inner.height / 2)
        XCTAssertGreaterThan(Self.count(decoded, in: inner, rgb: [255, 0, 0], tolerance: 12), total * 9 / 10, "the image is in the export")
        XCTAssertGreaterThan(Self.count(decoded, in: txt, rgb: [0, 0, 255], tolerance: 24), 500, "the text's plate")
        XCTAssertGreaterThan(Self.count(decoded, in: txt, rgb: [255, 255, 255], tolerance: 24), 200, "the text's letters")
        // After the morph the image sits at x 0.75 and its old place shows the game.
        let after = try RawCompositionFrames.frame(AVURLAsset(url: url), ms: 1700, hdr: false)
        XCTAssertLessThan(Self.count(after, in: inner, rgb: [255, 0, 0], tolerance: 12), total / 20)
        let moved = inner.offsetBy(dx: (0.75 - Self.imageFrame.x) * size.width, dy: 0)
        XCTAssertGreaterThan(Self.count(after, in: moved, rgb: [255, 0, 0], tolerance: 12), total * 9 / 10)
        // The library's card and hover frames come from the same composition: the thumbnail has the image too.
        doc.project.timeline.markers = [Marker(tMs: 500)]
        await doc.writeThumbnail()
        let thumb = try XCTUnwrap(CGImageSourceCreateWithURL(doc.thumbnailURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let px = TimelineExportTests.Pixels(thumb), k = Double(thumb.width) / size.width
        let rgb = px.rgb(Int(img.midX * k), Int(img.midY * k))
        XCTAssertGreaterThan(rgb[0], 200); XCTAssertLessThan(rgb[1], 50); XCTAssertLessThan(rgb[2], 50)
    }

    /// A layer whose image file is gone is left out; the export finishes and reports it.
    func testMissingAssetIsSkippedNotFatal() async throws {
        let (doc, _, _) = try await project(missingImage: true)
        let missing = AssetStore.missing(in: doc.project.scenes, searchPaths: AssetStore.searchPaths(project: doc.dir))
        XCTAssertEqual(missing, [MissingAsset(file: "00000000deadbeef.png", layer: "Logo", scene: "Overlays"),
                                 MissingAsset(file: "00000000deadbeef.png", layer: "Logo", scene: "Moved")])
        let exporter = Exporter(doc: doc, job: ExportJob(canvas: .vertical, resolution: .hd, range: .sdr, fps: .source))
        let url = try await exporter.run { _ in }
        XCTAssertEqual(exporter.missingAssets.count, 2)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        let size = Canvas.vertical.size(.hd), txt = Self.textFrame.rect(in: size)
        let frame = try RawCompositionFrames.frame(AVURLAsset(url: url), ms: 500, hdr: false)
        XCTAssertGreaterThan(Self.count(frame, in: txt, rgb: [0, 0, 255], tolerance: 24), 200, "the other overlays still draw")
        let img = Self.imageFrame.rect(in: size)
        XCTAssertEqual(Self.count(frame, in: img, rgb: [255, 0, 0], tolerance: 40), 0)
    }

    /// Through a morph that moves the image and cross-fades changed text, after a cut: the editor preview (uncut
    /// source, overlays that never block) and the export draw the same frames, `{timer}` included.
    func testPreviewMatchesExportWithOverlaysAcrossATransition() async throws {
        let (doc, _, _) = try await project()
        doc.project.timeline.segments = [Segment(startMs: 0, endMs: 400), Segment(startMs: 600, endMs: 2000)]
        let export = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr)
        let previewBuilt = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr, ignoreCuts: true)
        let preview = CompositionBuilder.videoComposition(doc.project, canvas: .wide, size: Canvas.wide.size(.hd), built: previewBuilt, waitForOverlays: false)
        var report: [String] = []
        // Timeline times: before the switch, through the morph (switch at source 1000 = timeline 800), after it.
        for t in [300.0, 800, 900, 1000, 1100, 1300, 1500] {
            let s = export.map.source(fromTimeline: t)
            let e = RawCompositionFrames.codes(try RawCompositionFrames.frame(export.asset, video: export.video, ms: t, hdr: false))
            // The export made every texture this frame needs; the preview finds them ready, as it would a frame later.
            let p = RawCompositionFrames.codes(try RawCompositionFrames.frame(previewBuilt.asset, video: preview, ms: s, hdr: false))
            let worst = zip(e, p).map { abs($0 - $1) }.max() ?? 0
            report.append(String(format: "t=%.0f (source %.0f): max diff %.0f", t, s, worst))
            XCTAssertLessThanOrEqual(worst, 1, "preview and export at timeline \(t) ms")
        }
        print("Overlays across a morph, preview vs export: " + report.joined(separator: "; "))
        // `{timer}` is time on the edited timeline in both: the cut's 200 ms do not count.
        let ep = try XCTUnwrap((export.video.instructions.first as? CompositionInstruction)?.plan)
        let pp = try XCTUnwrap((preview.instructions.first as? CompositionInstruction)?.plan)
        XCTAssertEqual(ep.tokens(atTimelineMs: 1500).elapsed ?? -1, 1.5, accuracy: 1e-3)
        XCTAssertEqual(pp.tokens(atTimelineMs: 1700).elapsed ?? -1, 1.5, accuracy: 1e-3)
        XCTAssertEqual(pp.tokens(atTimelineMs: 500).elapsed ?? -1, 0.4, accuracy: 1e-3, "inside the removed section: the cut's time")
        XCTAssertEqual(ep.tokens(atTimelineMs: 1500).replace("{timer}"), "0:01")
        // `{time}` is the recording's clock at that source moment.
        let start = doc.project.recordedAt ?? doc.project.createdAt
        XCTAssertEqual(ep.tokens(atTimelineMs: 1500).now.timeIntervalSince(start), 1.7, accuracy: 1e-3)
    }

    /// The preview's frames say when an overlay was not ready yet, so a paused preview can redraw; a missing file
    /// is not "pending" (it would redraw forever).
    func testPendingOverlaysAreReportedOnlyWhileBeingMade() throws {
        let dir = try OverlayTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try OverlayTestSupport.writePNG(dir.appendingPathComponent("a.png"), width: 8, height: 8, rgba: [UInt8](repeating: 200, count: 256))
        let cache = OverlayTextureCache(device: MetalCore.shared.device)
        let comp = Composition(layers: [Layer(source: LayerSource(type: "image", file: "a.png"), frame: NRect(x: 0, y: 0, w: 0.2, h: 0.2)),
                                        Layer(source: LayerSource(type: "text", text: TextSpec(string: "Hi")), frame: NRect(x: 0.3, y: 0.3, w: 0.3, h: 0.1))])
        let canvas = CGSize(width: 640, height: 360)
        XCTAssertTrue(cache.overlays(for: comp, canvas: canvas, assets: [dir]).pending)
        cache.drain(); _ = cache.overlays(for: comp, canvas: canvas, assets: [dir]); cache.drain()
        let ready = cache.overlays(for: comp, canvas: canvas, assets: [dir])
        XCTAssertFalse(ready.pending); XCTAssertEqual(ready.textures.count, 2)
        let missing = Composition(layers: [Layer(source: LayerSource(type: "image", file: "gone.png"))])
        XCTAssertTrue(cache.overlays(for: missing, canvas: canvas, assets: [dir]).pending, "not looked for yet")
        cache.drain()
        XCTAssertFalse(cache.overlays(for: missing, canvas: canvas, assets: [dir]).pending, "known missing")
    }
}
