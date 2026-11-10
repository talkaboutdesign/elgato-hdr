import XCTest
@testable import StudioKit

/// Focus mode's clean game picture: the whole game alone, letterboxed in its own aspect; the scene everywhere else.
final class WindowPictureTests: XCTestCase {
    let ultrawide = CGSize(width: 2560, height: 1080)
    let display = CGSize(width: 3024, height: 1964)   // 14" MacBook Pro, full screen
    let t0: UInt64 = 1_000_000_000_000
    var sources: [SourceKey: SourceInfo] { [.game: SourceInfo(size: ultrawide), .camera: SourceInfo(size: CGSize(width: 1280, height: 720))] }

    /// Gameplay with the camera, the game cropped and zoomed, and the punch-in engaged: everything the clean view drops.
    func busyScene() -> LiveSceneState {
        var gameplay = SceneCollection.defaults().scenes[0]
        if let i = gameplay.wide.layers.firstIndex(where: { $0.source.type == "game" }) {
            gameplay.wide.layers[i].zoom = 1.5; gameplay.wide.layers[i].panX = 0.3; gameplay.wide.layers[i].mirror = true
        }
        var st = LiveSceneState(scene: gameplay)
        var p = PunchIn(); p.set(engaged: true, atNs: t0); st.punchIn = p
        return st
    }

    func testCleanIsTheWholeGameAloneInItsAspect() {
        let pic = WindowPicture.picture(clean: true, scene: busyScene(), canvas: .wide, game: ultrawide, drawable: display, sources: sources, atNs: t0 + 2_000_000_000)
        XCTAssertEqual(pic.frame.layers.count, 1, "no camera, overlays or second copies")
        let g = pic.frame.layers[0]
        XCTAssertEqual(g.key, .game)
        XCTAssertEqual(g.src, CGRect(x: 0, y: 0, width: 1, height: 1), "no crop, zoom or punch-in")
        XCTAssertEqual(g.dst, CGRect(origin: .zero, size: pic.size))
        XCTAssertEqual(g.radius, 0); XCTAssertEqual(g.border, 0); XCTAssertEqual(g.shadow, 0); XCTAssertEqual(g.opacity, 1)
        XCTAssertFalse(g.mirror); XCTAssertTrue(g.hardEdge)
        // Letterboxed in 64:27 across the display's width, whole pixels.
        XCTAssertEqual(pic.size.width, display.width)
        XCTAssertEqual(pic.size.height, (display.width * 1080 / 2560).rounded())
        XCTAssertEqual(pic.frame.background, SIMD4(0, 0, 0, 1))
        // A tall window pillarboxes instead.
        let tall = WindowPicture.picture(clean: true, scene: busyScene(), canvas: .vertical, game: ultrawide, drawable: CGSize(width: 1000, height: 2000), sources: sources, atNs: t0)
        XCTAssertEqual(tall.size, CGSize(width: 1000, height: (1000 * 1080 / 2560.0).rounded()))
    }

    func testOtherwiseTheScene() {
        let st = busyScene(), t = t0 + 2_000_000_000
        let pic = WindowPicture.picture(clean: false, scene: st, canvas: .wide, game: ultrawide, drawable: display, sources: sources, atNs: t)
        XCTAssertEqual(pic.size, CGSize(width: 3024, height: 1701), "16:9 canvas in the window")
        XCTAssertEqual(pic.frame, st.frame(canvas: .wide, size: pic.size, sources: sources, atNs: t))
        XCTAssertTrue(pic.frame.layers.contains { $0.key == .camera })
        let v = WindowPicture.picture(clean: false, scene: st, canvas: .vertical, game: ultrawide, drawable: display, sources: sources, atNs: t)
        XCTAssertEqual(v.size, CGSize(width: (1964 * 9 / 16.0).rounded(), height: 1964))
    }

    func testOnlyInFocusModeAndPersisted() throws {
        XCTAssertTrue(WindowPicture.clean(setting: true, focusMode: true))
        XCTAssertFalse(WindowPicture.clean(setting: true, focusMode: false), "the window outside focus mode shows the scene")
        XCTAssertFalse(WindowPicture.clean(setting: false, focusMode: true))
        let suite = "dev.max.elgato-hdr.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(WindowPicture.setting(d), "on by default")
        d.set(false, forKey: WindowPicture.defaultsKey)
        XCTAssertFalse(WindowPicture.setting(d))
    }
}
