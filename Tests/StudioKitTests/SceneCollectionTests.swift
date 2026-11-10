import XCTest
@testable import StudioKit

final class SceneCollectionTests: XCTestCase {
    let wide = Canvas.wide.size(.hd), tall = Canvas.vertical.size(.hd)
    let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 2560, height: 1440)), .camera: SourceInfo(size: CGSize(width: 1280, height: 720))]

    func layer(_ c: Composition, _ type: String) -> Layer? { c.layers.first { $0.source.type == type } }

    func testDefaultScenes() throws {
        let c = SceneCollection.defaults()
        XCTAssertEqual(c.scenes.map(\.name), ["Gameplay", "Game Only", "Camera Focus", "Just Camera"])
        XCTAssertEqual(c.activeID, c.scenes[0].id)
        let gameplay = c.scenes[0], focus = c.scenes[2]
        // Gameplay 16:9: full game, rounded camera with a shadow in the bottom-right, above the game.
        XCTAssertEqual(gameplay.wide.layers.map(\.source.type), ["game", "camera"])
        let cam = try XCTUnwrap(layer(gameplay.wide, "camera"))
        XCTAssertGreaterThan(cam.frame.x, 0.5); XCTAssertGreaterThan(cam.frame.y, 0.5)
        XCTAssertTrue(cam.shadow); XCTAssertGreaterThan(cam.roundness, 0)
        // Gameplay 9:16 is today's vertical default: camera on top at 36%, game below.
        XCTAssertEqual(gameplay.vertical, Composition.from(layout: .verticalDefault, canvas: tall, hasCamera: true, mirror: false).withIDs(of: gameplay.vertical))
        XCTAssertEqual(try XCTUnwrap(layer(gameplay.vertical, "camera")).frame.h, (1920 * 0.36).rounded() / 1920, accuracy: 1e-9)
        // Game Only: one full-frame game on both canvases, cropped to fill.
        for comp in [c.scenes[1].wide, c.scenes[1].vertical] {
            XCTAssertEqual(comp.layers.count, 1); XCTAssertEqual(comp.layers[0].frame, .full); XCTAssertFalse(comp.layers[0].fit)
        }
        // Camera Focus 16:9: camera full, game window in the bottom-right at 34% of the width, rounded.
        XCTAssertEqual(focus.wide.layers.map(\.source.type), ["camera", "game"])
        let g = try XCTUnwrap(layer(focus.wide, "game"))
        XCTAssertEqual(g.frame.w, 0.34, accuracy: 0.001)
        XCTAssertEqual(g.frame.w * wide.width / (g.frame.h * wide.height), 16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(1 - g.frame.x - g.frame.w, 0.04 * wide.height / wide.width, accuracy: 0.001, "right snap margin")
        XCTAssertGreaterThan(g.roundness, 0)
        // 9:16: the game window spans the width inside the margins, at the bottom.
        let vg = try XCTUnwrap(layer(focus.vertical, "game"))
        XCTAssertEqual(vg.frame.x, 0.04, accuracy: 0.001); XCTAssertEqual(vg.frame.x + vg.frame.w, 0.96, accuracy: 0.001)
        XCTAssertEqual(vg.frame.y + vg.frame.h, 1 - 0.04 * tall.width / tall.height, accuracy: 0.001)
        XCTAssertEqual(c.scenes[3].wide.layers.map(\.source.type), ["camera"])
        XCTAssertEqual(c.scenes[3].vertical.layers.map(\.source.type), ["camera"])
        // Every template resolves inside its canvas.
        for t in SceneTemplate.allCases {
            let s = t.scene()
            for (canvas, size) in [(Canvas.wide, wide), (.vertical, tall)] {
                for l in SceneResolver.resolve(s.composition(canvas), canvas: size, sources: sources) {
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(l.dst), "\(t) \(canvas)")
                }
            }
        }
    }

    /// The single live placement from before scenes becomes Gameplay's camera window.
    func testMigratesLivePlacement() throws {
        var p = CameraPlacement(x: 0.2, y: 0.3, size: 0.5, aspect: .classic, roundness: 0.5); p.border = true; p.shadow = false
        let c = SceneCollection.defaults(placement: p, mirror: true)
        let cam = try XCTUnwrap(layer(c.scenes[0].wide, "camera"))
        XCTAssertEqual(cam.frame, NRect(p.rect(in: wide), in: wide))
        XCTAssertEqual(cam.roundness, 0.5); XCTAssertTrue(cam.border); XCTAssertFalse(cam.shadow); XCTAssertTrue(cam.mirror)
        // And back: the placement read from the layer is the one that went in.
        let back = CameraPlacement(frame: cam.frame, canvas: wide, roundness: cam.roundness, border: cam.border, shadow: cam.shadow)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        XCTAssertEqual(back.size, p.size, accuracy: 1e-9); XCTAssertEqual(back.aspect, p.aspect)
        for s in c.scenes { for l in s.wide.layers + s.vertical.layers where l.source.type == "camera" { XCTAssertTrue(l.mirror) } }
    }

    func testStoreRoundTripAndDebounce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scenes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SceneStore(url: dir.appendingPathComponent("scenes.json"))
        XCTAssertNil(store.load())
        var c = SceneCollection.defaults()
        c.transition = SceneTransition(style: .fade, durationMs: 500)
        c.activeID = c.scenes[2].id
        store.scheduleSave(c, delay: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "saving waits for the debounce")
        let saved = expectation(description: "saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { saved.fulfill() }
        wait(for: [saved], timeout: 2)
        XCTAssertEqual(SceneStore(url: store.url).load(), c)
        c.scenes[1].name = "Renamed"
        store.flush(c)
        XCTAssertEqual(SceneStore(url: store.url).load()?.scenes[1].name, "Renamed")
    }

    /// Missing keys fall back, a dangling active id and an empty list are repaired.
    func testLenientDecoding() throws {
        let empty = try JSONDecoder().decode(SceneCollection.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.scenes.count, 4)
        XCTAssertEqual(empty.activeID, empty.scenes[0].id)
        XCTAssertEqual(empty.transition, SceneTransition())
        let s = SceneTemplate.gameOnly.scene()
        let json = try JSONEncoder().encode(SceneCollection(scenes: [s], activeID: UUID()))
        let dangling = try JSONDecoder().decode(SceneCollection.self, from: json)
        XCTAssertEqual(dangling.activeID, s.id)
        let partial = try JSONDecoder().decode(SceneCollection.self, from: Data(#"{"scenes":[{"name":"X"}],"transition":{"style":"fade"}}"#.utf8))
        XCTAssertEqual(partial.scenes.map(\.name), ["X"]); XCTAssertEqual(partial.transition.style, .fade); XCTAssertEqual(partial.transition.durationMs, 380)
    }

    func testUniqueName() {
        var c = SceneCollection.defaults()
        XCTAssertEqual(c.uniqueName("Intro"), "Intro")
        XCTAssertEqual(c.uniqueName("Gameplay"), "Gameplay 2")
        c.scenes.append(Scene(name: "Gameplay 2"))
        XCTAssertEqual(c.uniqueName("Gameplay"), "Gameplay 3")
    }

    /// Recordings keep writing `wide` and `vertical` for the current editor, from the scene active at the start.
    func testLayoutApproximation() throws {
        let c = SceneCollection.defaults(placement: CameraPlacement(x: 0.2, y: 0.25, size: 0.3, aspect: .wide, roundness: 0.1))
        let gp = CanvasLayout(approximating: c.scenes[0].wide, canvas: wide, fallback: .wideDefault)
        XCTAssertEqual(gp.kind, .pip)
        XCTAssertEqual(gp.camera.x, 0.2, accuracy: 1e-6); XCTAssertEqual(gp.camera.size, 0.3, accuracy: 1e-6); XCTAssertEqual(gp.camera.aspect, .wide)
        let v = CanvasLayout(approximating: c.scenes[0].vertical, canvas: tall, fallback: .verticalDefault)
        XCTAssertEqual(v.kind, .stacked); XCTAssertEqual(v.split, (1920 * 0.36).rounded() / 1920, accuracy: 1e-9)
        XCTAssertEqual(CanvasLayout(approximating: c.scenes[1].wide, canvas: wide, fallback: .wideDefault).kind, .screenOnly)
        XCTAssertEqual(CanvasLayout(approximating: c.scenes[2].wide, canvas: wide, fallback: .wideDefault).kind, .cameraOnly)
        XCTAssertEqual(CanvasLayout(approximating: c.scenes[3].vertical, canvas: tall, fallback: .verticalDefault).kind, .cameraOnly)
        // The approximated layout resolves to the scene's own rectangles where a fixed layout can express it.
        let scene = SceneResolver.resolve(c.scenes[0].wide, canvas: wide, sources: sources)
        let fixed = SceneResolver.resolve(Composition.from(layout: gp, canvas: wide, hasCamera: true, mirror: false), canvas: wide, sources: sources)
        XCTAssertEqual(scene.map(\.dst), fixed.map(\.dst))
    }

    func testProjectEventsAreLenientAndAdditive() throws {
        let v1 = #"{"name":"Old","createdAt":"2026-10-01T10:00:00Z","game":{"file":"game.mov"}}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let old = try dec.decode(Project.self, from: Data(v1.utf8))
        XCTAssertEqual(old.scenes, []); XCTAssertEqual(old.events, [])
        var p = old
        p.scenes = SceneCollection.defaults().scenes
        p.events = [SessionEvent(tMs: 0, type: "scene", sceneID: p.scenes[0].id),
                    SessionEvent(tMs: 1500, type: "zoomIn", zoom: 1.6, focusX: 0.5, focusY: 0.4),
                    SessionEvent(tMs: 2500, type: "zoomOut"), SessionEvent(tMs: 3000, type: "marker")]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let back = try dec.decode(Project.self, from: enc.encode(p))
        XCTAssertEqual(back, p)
        let odd = try dec.decode(SessionEvent.self, from: Data(#"{"type":"marker","future":1}"#.utf8))
        XCTAssertEqual(odd, SessionEvent(tMs: 0, type: "marker"))
    }
}

extension Composition {
    /// Copies layer ids from `other` (same order) so compositions built separately compare equal.
    func withIDs(of other: Composition) -> Composition {
        var c = self
        for i in c.layers.indices where i < other.layers.count { c.layers[i].id = other.layers[i].id }
        return c
    }
}
