import Metal
import XCTest
@testable import StudioKit

/// Scene thumbnails read a private copy of the game frame, not the live textures the capture helper (shared memory)
/// or the Smooth ring overwrite later.
final class GameSnapshotTests: XCTestCase {
    let core = MetalCore.shared
    let w = 64, h = 36
    let t0: UInt64 = 1_000_000_000_000

    func plane(_ f: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        return core.device.makeTexture(descriptor: d)!
    }
    /// Fills the source as the helper would: luma `y` everywhere, neutral chroma.
    func fill(_ y: MTLTexture, _ c: MTLTexture, luma: UInt16) {
        let ys = [UInt16](repeating: luma, count: w * h), cs = [UInt16](repeating: 0x8000, count: w * h / 2)
        ys.withUnsafeBytes { y.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 2) }
        cs.withUnsafeBytes { c.replace(region: MTLRegionMake2D(0, 0, w / 2, h / 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 2) }
    }
    /// Captures until the copy is ready (the first call allocates on a utility queue).
    func captureReady(_ s: GameSnapshot, _ y: MTLTexture, _ c: MTLTexture, at t: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            s.capture(y: y, c: c, transfer: 2, on: core.queue, atNs: t)
            if s.beginRead() != nil { s.endRead(); return }
            usleep(1000)
        }
        XCTFail("snapshot never became ready", file: file, line: line)
    }
    /// Green of the centre pixel of the one thumbnail, or nil if the pass was skipped.
    func thumbnailLevel(_ th: SceneThumbnailer) -> UInt8? {
        let done = expectation(description: "thumbnail")
        var level: UInt8?
        th.render(scenes: [SceneTemplate.gameOnly.scene()], canvas: .wide, hasGame: true, camera: nil) { images in
            if let img = images.values.first, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
                level = p[(img.height / 2) * img.bytesPerRow + (img.width / 2) * 4 + 1]
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return level
    }

    func testThumbnailReadsTheCopyNotTheLiveSlot() throws {
        let th = SceneThumbnailer(), snap = th.snapshot
        let y = plane(.r16Unorm, w, h), c = plane(.rg16Unorm, w / 2, h / 2)
        let dark: UInt16 = 0x3000, bright: UInt16 = 0xE000
        fill(y, c, luma: dark)
        captureReady(snap, y, c, at: t0)
        let copied = try XCTUnwrap(thumbnailLevel(th))
        // The helper refills the slot (or the ring wraps) before the next thumbnail pass.
        fill(y, c, luma: bright)
        let after = try XCTUnwrap(thumbnailLevel(th))
        XCTAssertEqual(after, copied, "the thumbnail must show the frame that was copied, not the slot's new contents")
        // Within half a second of the last copy, another frame is not copied (no cost on other frames)...
        snap.capture(y: y, c: c, transfer: 2, on: core.queue, atNs: t0 + 200_000_000)
        core.queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }
        XCTAssertEqual(try XCTUnwrap(thumbnailLevel(th)), copied)
        // ...and once it is due, the next frame is.
        captureReady(snap, y, c, at: t0 + 600_000_000)
        let fresh = try XCTUnwrap(thumbnailLevel(th))
        XCTAssertGreaterThan(Int(fresh), Int(copied) + 60, "bright frame after the next copy")
    }

    func testCopyAndThumbnailExcludeEachOther() throws {
        let th = SceneThumbnailer(), snap = th.snapshot
        let y = plane(.r16Unorm, w, h), c = plane(.rg16Unorm, w / 2, h / 2)
        fill(y, c, luma: 0x3000)
        captureReady(snap, y, c, at: t0)
        // A thumbnail pass is reading: a due copy does not overwrite the texture under it.
        let reading = try XCTUnwrap(snap.beginRead())
        fill(y, c, luma: 0xE000)
        snap.capture(y: y, c: c, transfer: 2, on: core.queue, atNs: t0 + 600_000_000)
        snap.endRead()
        let level = try XCTUnwrap(thumbnailLevel(th))
        XCTAssertLessThan(level, 128, "still the dark copy")
        XCTAssertEqual(reading.size, CGSize(width: w, height: h))
    }

    /// A pass with a game but no finished copy draws nothing (and calls nothing back).
    func testPassIsSkippedWithoutACopy() {
        let th = SceneThumbnailer()
        let skipped = expectation(description: "skipped"); skipped.isInverted = true
        th.render(scenes: [SceneTemplate.gameOnly.scene()], canvas: .wide, hasGame: true, camera: nil) { _ in skipped.fulfill() }
        wait(for: [skipped], timeout: 0.5)
        // Without a game at all, scenes still render (the camera and colours).
        let drawn = expectation(description: "drawn")
        th.render(scenes: [SceneTemplate.gameOnly.scene()], canvas: .wide, hasGame: false, camera: nil) { _ in drawn.fulfill() }
        wait(for: [drawn], timeout: 5)
    }
}
