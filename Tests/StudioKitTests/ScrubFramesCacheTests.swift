import XCTest
@testable import StudioKit

/// Library hover frames are cached per render state: a visual edit shows new frames, and old ones are dropped.
final class ScrubFramesCacheTests: XCTestCase {
    func testHoverFramesFollowVisualEdits() async throws {
        try TimelineExportTests().requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Scrub-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await GeneratedMedia.project(at: dir, fps: 60, seconds: 2)
        doc.project.state = "complete"
        let p = doc.project
        let before = await ScrubFrames.load(doc, project: p)
        XCTAssertEqual(before.count, 5)
        var edited = p
        edited.scenes[0].wide = Composition(background: [0.9, 0.2, 0.1, 1], layers: [Layer(source: .game, frame: NRect(x: 0, y: 0, w: 0.5, h: 0.5))])
        edited.scenes[0].wide.legacyLayout = nil
        XCTAssertNotEqual(ScrubFrames.fingerprint(edited), ScrubFrames.fingerprint(p))
        XCTAssertEqual(ScrubFrames.fingerprint(edited), ScrubFrames.fingerprint(edited), "stable")
        let after = await ScrubFrames.load(doc, project: edited)
        XCTAssertEqual(after.count, 5)
        let a = TimelineExportTests.Pixels(before[2]), b = TimelineExportTests.Pixels(after[2])
        XCTAssertGreaterThan(a.difference(b), 20, "the edited scene's frames, not the cached ones from before the edit")
        let folders = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".cache/scrub").path)
        XCTAssertEqual(folders, [ScrubFrames.fingerprint(edited)], "frames of the earlier state are deleted")
        let again = await ScrubFrames.load(doc, project: edited)
        XCTAssertEqual(TimelineExportTests.Pixels(again[2]).difference(b), 0, "unchanged state is served from the cache")
    }
}
