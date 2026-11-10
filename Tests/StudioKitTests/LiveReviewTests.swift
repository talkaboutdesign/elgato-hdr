import XCTest
import CoreGraphics
@testable import StudioKit

final class LiveReviewTests: XCTestCase {
    func testAdmissionAbsorbsMeasuredCallbackBurst() {
        var a = EncodeAdmission()
        for _ in 0..<64 { XCTAssertTrue(a.admit()); a.queued -= 1 }
        XCTAssertFalse(a.admit())
        a.pending = 0
        XCTAssertTrue(a.admit()); XCTAssertTrue(a.admit()); XCTAssertFalse(a.admit())
    }
    func testOverlayVisibilityAndContentThroughTransition() {
        let l = Layer.text("Old", name: "Label", frame: .full)
        var hidden = l; hidden.visible = false
        let a = Scene(name: "A", wide: Composition(layers: [l]))
        let b = Scene(name: "B", wide: Composition(layers: [hidden]))
        let state = LiveSceneState(scene: a).switching(to: b, atNs: 1, transition: SceneTransition(), sources: [:])
        let retained = state.overlayLayers(canvas: .wide, atNs: 1_000_001)
        XCTAssertEqual(retained.first?.source.text?.string, "Old")
        XCTAssertEqual(retained.first?.visible, true)
        let sources: [SourceKey: SourceInfo] = [.layer(l.id): SourceInfo(size: CGSize(width: 100, height: 100))]
        let layers = state.layers(canvas: .wide, size: CGSize(width: 100, height: 100), sources: sources, atNs: 1_000_001)
        XCTAssertEqual(layers.count, 1); XCTAssertGreaterThan(layers.first?.opacity ?? 0, 0.9)
        var transparent = hidden; transparent.visible = true; transparent.opacity = 0
        let zero = Scene(name: "Zero", wide: Composition(layers: [transparent]))
        let fading = LiveSceneState(scene: a).switching(to: zero, atNs: 1, transition: SceneTransition(), sources: sources)
        XCTAssertEqual(fading.overlayLayers(canvas: .wide, atNs: 1_000_001).first?.opacity, 1)
        XCTAssertTrue(fading.overlayLayers(canvas: .wide, atNs: 500_000_001).isEmpty)
        let reverse = LiveSceneState(scene: b).switching(to: a, atNs: 1, transition: SceneTransition(), sources: sources)
        XCTAssertTrue(reverse.overlayLayers(canvas: .wide, atNs: 1_000_001)[0].visible)
        var changed = l; changed.source.text?.string = "New"
        let c = Scene(name: "C", wide: Composition(layers: [changed]))
        let swap = LiveSceneState(scene: a).switching(to: c, atNs: 1, transition: SceneTransition(), sources: sources)
        XCTAssertEqual(swap.overlayLayers(canvas: .wide, atNs: 1_000_001)[0].source.text?.string, "Old")
        XCTAssertEqual(swap.overlayLayers(canvas: .wide, atNs: 300_000_001)[0].source.text?.string, "New")
    }
    func testCameraPresetIsOwnedByCamera() throws {
        let cam = Layer(source: .camera, frame: NRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4), roundness: 0.5)
        var c = Composition(layers: [cam])
        let id = try LayerPreset.cameraFrame.apply(to: &c, canvas: CGSize(width: 1920, height: 1080)).get()
        XCTAssertEqual(id, cam.id); XCTAssertEqual(c.layers.count, 1)
        c.layers[c.layers.count - 1].visible = false
        XCTAssertTrue(SceneResolver.resolve(c, canvas: CGSize(width: 1920, height: 1080), sources: [.camera: SourceInfo(size: CGSize(width: 100, height: 100))]).isEmpty)
    }
    func testRecordedTransitionFieldsSurviveDecode() throws {
        let json = #"{"tMs":20,"type":"scene","transitionStyle":"fade","transitionDurationMs":720}"#
        let e = try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        XCTAssertEqual(obj["transitionStyle"] as? String, "fade")
        XCTAssertEqual(obj["transitionDurationMs"] as? Double, 720)
    }
}

extension LiveReviewTests {
    func testCameraRingGoldenAndMigration() throws {
        let size = CGSize(width: 100, height: 100)
        var camera = Layer(source: .camera, frame: NRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4), roundness: 0.5)
        camera.frameWidth = 0.05; camera.frameColor = [1, 0, 0, 1]
        let sources: [SourceKey: SourceInfo] = [.camera: SourceInfo(size: size)]
        let white = OverlayTestSupport.texture(.rgba8Unorm, 1, 1, Data([255,255,255,255]), 4)
        func render(_ l: Layer) -> [Float] {
            let resolved = SceneResolver.resolve(Composition(layers: [l]), canvas: size, sources: sources)
            return OverlayTestSupport.render(canvas: size, transfer: 2, layers: DrawLayer.pair(resolved, [.camera: .rgba(white)]))
        }
        let pixels = render(camera)
        // Analytic circle golden: opaque white camera of radius 20, red outer ring out to radius 25.
        for y in 0..<100 { for x in 0..<100 {
            let d = hypot(Double(x) + 0.5 - 50, Double(y) + 0.5 - 50)
            if abs(d - 20) < 1 || abs(d - 25) < 1 { continue }
            let i = (y * 100 + x) * 4
            XCTAssertEqual(pixels[i], d < 25 ? 1 : 0, accuracy: 0.002)
            XCTAssertEqual(pixels[i+1], d < 20 ? 1 : 0, accuracy: 0.002)
        } }
        camera.visible = false
        XCTAssertTrue(render(camera).enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 })
        let canvas = Canvas.wide.size(.hd)
        camera.visible = true; camera.frameWidth = 0
        let r = camera.frame.rect(in: canvas), pad = (canvas.height * 0.009).rounded(), outer = r.insetBy(dx: -pad, dy: -pad)
        let radius = (0.5 * min(r.width, r.height) + pad) / min(outer.width, outer.height)
        let ring = Layer.color(ScreenStyle.blue, name: "Camera Frame", frame: NRect(outer, in: canvas), roundness: radius)
        let scene = Scene(name: "Legacy", wide: Composition(layers: [ring, camera]))
        let migrated = try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(scene))
        XCTAssertEqual(migrated.wide.layers.count, 1)
        XCTAssertEqual(migrated.wide.layers[0].frameWidth * canvas.height, pad, accuracy: 0.001)
        var changed = scene; changed.wide.layers[0].frame.x += 0.1
        XCTAssertEqual(try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(changed)).wide.layers.count, 2)
    }
    func testRecordedDefaultsAndEffectiveTransition() throws {
        var p = Project(name: "Capture", createdAt: Date())
        p.sceneTransition = SceneTransition(style: .morph, durationMs: 720)
        p.events = [SessionEventLog(startNs: 0).event("scene", atNs: 100, transition: SceneTransition(style: .fade, durationMs: 150))]
        let reloaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(reloaded.sceneTransition, p.sceneTransition)
        XCTAssertEqual(reloaded.events[0].transitionStyle, .fade)
        XCTAssertEqual(reloaded.events[0].transitionDurationMs, 150)
        let old = try JSONDecoder().decode(SessionEvent.self, from: Data(#"{"type":"scene"}"#.utf8))
        XCTAssertNil(old.transitionStyle); XCTAssertNil(old.transitionDurationMs)
    }
}

extension LiveReviewTests {
    func testImportCompletionTargetsCapturedSceneAndCanvas() {
        let a = Scene(name: "A"), b = Scene(name: "B")
        var c = SceneCollection(scenes: [a, b], activeID: a.id)
        let destination = c.activeID, canvas = Canvas.wide
        // The user switches scene and canvas while the file is copied.
        c.activeID = b.id
        let image = Layer(source: LayerSource(type: "image", file: "imported.png"))
        XCTAssertTrue(c.edit(sceneID: destination, canvas: canvas) { $0.layers.append(image) })
        XCTAssertEqual(c.scenes[0].wide.layers, [image])
        XCTAssertTrue(c.scenes[0].vertical.layers.isEmpty)
        XCTAssertTrue(c.scenes[1].wide.layers.isEmpty)
        c.scenes.removeFirst()
        XCTAssertFalse(c.edit(sceneID: destination, canvas: canvas) { $0.layers.append(image) })
        XCTAssertTrue(c.scenes[0].wide.layers.isEmpty)
    }
    func testLatencyPercentilesAndBoundedHistogram() {
        var h = EncodeLatency()
        for i in 1...100 { h.add(Double(i)) }
        XCTAssertEqual(h.percentile(0.50), 50)
        XCTAssertEqual(h.percentile(0.95), 95)
        XCTAssertEqual(h.percentile(0.99), 99)
        h.add(5000)
        XCTAssertEqual(h.maxMs, 5000)
    }
}
