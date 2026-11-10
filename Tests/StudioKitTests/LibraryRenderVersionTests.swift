import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import StudioKit

/// The library's pictures made by an older composite (before overlays were drawn) are made again: hover frames by
/// their cache fingerprint, `thumbnail.jpg` by the render version stored next to it.
final class LibraryRenderVersionTests: XCTestCase {
    static let logo = NRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4)

    /// A finished 2 s project whose only scene has a big red image over the game.
    func project() async throws -> ProjectDoc {
        try TimelineExportTests().requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RenderVersion-" + UUID().uuidString)
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
        return doc
    }

    /// A solid green JPEG: what an old cache holds (any picture without the overlay).
    func writeGreen(_ url: URL, width: Int = 640, height: Int = 360) throws {
        let c = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        c.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
    }

    func centre(_ img: CGImage) -> [Double] {
        TimelineExportTests.Pixels(img).rgb(img.width / 2, img.height / 2)
    }
    func isRed(_ rgb: [Double]) -> Bool { rgb[0] > 200 && rgb[1] < 60 && rgb[2] < 60 }

    func testOldHoverFramesAreNotServed() async throws {
        let doc = try await project()
        let p = doc.project
        // Frames cached by a build before the render version existed: its fingerprint had no version.
        let old = ScrubFrames.fingerprint(p, renderVersion: nil)
        XCTAssertNotEqual(old, ScrubFrames.fingerprint(p))
        let oldDir = doc.dir.appendingPathComponent(".cache/scrub/\(old)")
        for t in ScrubFrames.times(p) { try writeGreen(oldDir.appendingPathComponent("\(Int(t)).jpg")) }
        let frames = await ScrubFrames.load(doc, project: p)
        XCTAssertEqual(frames.count, 5)
        for f in frames { XCTAssertTrue(isRed(centre(f)), "the overlay, not the old cached frame: \(centre(f))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path), "older entries are deleted")
    }

    func testStaleThumbnailIsRemadeOnce() async throws {
        let doc = try await project()
        try writeGreen(doc.thumbnailURL)                            // a thumbnail from before overlays, no version file
        XCTAssertFalse(doc.thumbnailIsCurrent)
        let remade = await doc.refreshStaleThumbnail()
        XCTAssertTrue(remade)
        let thumb = try XCTUnwrap(CGImageSourceCreateWithURL(doc.thumbnailURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertTrue(isRed(centre(thumb)), "made by the current composite: \(centre(thumb))")
        XCTAssertEqual(try String(contentsOf: doc.thumbnailVersionURL, encoding: .utf8), "\(ProjectDoc.renderVersion)\n")
        XCTAssertTrue(doc.thumbnailIsCurrent)
        let again = await doc.refreshStaleThumbnail()
        XCTAssertFalse(again, "a current thumbnail is left alone")
        // An older version number counts as stale too.
        try "1\n".write(to: doc.thumbnailVersionURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(doc.thumbnailIsCurrent)
    }
}
