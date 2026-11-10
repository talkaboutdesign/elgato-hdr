import XCTest
import CoreGraphics
import CoreVideo
@testable import StudioKit

final class LiveReviewTests: XCTestCase {
    func testAdmissionAbsorbsMeasuredCallbackBurst() throws {
        var admission = EncodeAdmission()
        // Nine submissions remain outstanding until the callback burst drains them together.
        for _ in 0..<9 { XCTAssertTrue(admission.admit()); admission.queued -= 1 }
        XCTAssertEqual(admission.pending, 9)
        for _ in 0..<9 { admission.pending -= 1 }
        XCTAssertEqual(admission.pending, 0)
        for _ in 0..<16 { XCTAssertTrue(admission.admit()); admission.queued -= 1 }
        XCTAssertFalse(admission.admit())

        let encoder = try XCTUnwrap(VideoEncoder(settings: .init(width: 64, height: 64, fps: 60, bitrate: 500_000)))
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        encoder.enqueueForTesting { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let callbacks = expectation(description: "Every lease released once"); callbacks.expectedFulfillmentCount = 9
        for n in 0..<9 { encoder.encode(buffer, hostNs: 1_000_000_000 + UInt64(n) * 17_000_000) { callbacks.fulfill() } }
        XCTAssertEqual(encoder.takeStats().queueRejected, 7)
        release.signal(); encoder.finish()
        wait(for: [callbacks], timeout: 5)
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
        let versions = swap.overlayLayers(canvas: .wide, atNs: 100_000_001)
        XCTAssertEqual(Set(versions.compactMap { $0.source.text?.string }), ["Old", "New"])
        XCTAssertEqual(Set(versions.map(\.id)).count, 2)
        let both = Dictionary(uniqueKeysWithValues: versions.map { (SourceKey.layer($0.id), SourceInfo(size: CGSize(width: 100, height: 100))) })
        let blended = swap.layers(canvas: .wide, size: CGSize(width: 100, height: 100), sources: both, atNs: 100_000_001)
        XCTAssertEqual(blended.count, 2)
        XCTAssertNotEqual(blended[0].key, blended[1].key)
        XCTAssertTrue(blended.allSatisfy { $0.opacity > 0 && $0.opacity < 1 })
        XCTAssertEqual(blended.map(\.opacity).reduce(0, +), 1, accuracy: 0.001)
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
        for roundness in [0.0, 0.17, 0.5] { for opacity in [0.25, 1.0] {
            camera.roundness = roundness; camera.opacity = opacity
            let pixels = render(camera), radius = 40 * roundness
            for y in 0..<100 { for x in 0..<100 {
                let qx = abs(Double(x) + 0.5 - 50) - (20 - radius)
                let qy = abs(Double(y) + 0.5 - 50) - (20 - radius)
                let d = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
                let i = (y * 100 + x) * 4
                XCTAssertEqual(pixels[i], Float(min(1, max(0, 5.5 - d)) * opacity), accuracy: 0.002)
                XCTAssertEqual(pixels[i+1], Float(min(1, max(0, 0.5 - d)) * opacity), accuracy: 0.002)
            } }
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
        for opacity in [0.0, 0.5, 1.0] {
            var hidden = scene
            hidden.wide.layers[1].visible = false
            hidden.wide.layers[1].opacity = opacity
            XCTAssertEqual(try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(hidden)).wide.layers.count, 2)
        }
        var translucent = scene; translucent.wide.layers[1].opacity = 0.5
        XCTAssertEqual(try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(translucent)).wide.layers.count, 2)
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
        let model = SceneModel()
        model.collection = SceneCollection(scenes: [a, b], activeID: a.id)
        model.canvas = .wide
        var applied = false
        let completion = model.captureImageImport { id, canvas, size, name, _ in
            XCTAssertEqual(id, a.id); XCTAssertEqual(canvas, .wide); XCTAssertEqual(size, Canvas.wide.size(.hd))
            applied = model.collection.edit(sceneID: id, canvas: canvas) { $0.layers.append(Layer(source: LayerSource(type: "image", file: name))) }
        }
        model.collection.activeID = b.id; model.canvas = .vertical
        completion("imported.png", CGSize(width: 40, height: 20))
        XCTAssertTrue(applied)
        XCTAssertEqual(model.collection.scenes[0].wide.layers.first?.source.file, "imported.png")
        XCTAssertTrue(model.collection.scenes[0].vertical.layers.isEmpty)
        XCTAssertTrue(model.collection.scenes[1].wide.layers.isEmpty)
        model.collection.scenes.removeFirst()
        completion("deleted.png", CGSize(width: 40, height: 20))
        XCTAssertFalse(applied)
        XCTAssertTrue(model.collection.scenes[0].wide.layers.isEmpty)
    }

    func testLatencyPercentilesAndBoundedHistogram() {
        var h = EncodeLatency()
        for i in 1...100 { h.add(Double(i)) }
        XCTAssertEqual(h.percentile(0.50), 50)
        XCTAssertEqual(h.percentile(0.95), 95)
        XCTAssertEqual(h.percentile(0.99), 99)
        h.add(5000)
        XCTAssertEqual(h.maxMs, 5000)
        XCTAssertEqual(h.percentile(1), 5000)
    }
}

extension LiveReviewTests {
    func testFrameBoundsAndMorphColour() throws {
        let size = CGSize(width: 100, height: 100)
        var camera = Layer(source: .camera, frame: NRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4))
        let sources: [SourceKey: SourceInfo] = [.camera: SourceInfo(size: size)]
        let old = try XCTUnwrap(SceneResolver.resolve(Composition(layers: [camera]), canvas: size, sources: sources).first)
        camera.frameWidth = 0.05; camera.frameColor = [1, 0, 0, 1]
        XCTAssertEqual(LayerPicking.hit([camera], at: CGPoint(x: 27, y: 50), canvas: size)?.id, camera.id)
        XCTAssertEqual(LayerPicking.snapFrames([camera], excluding: UUID(), canvas: size), [CGRect(x: 25, y: 25, width: 50, height: 50)])
        let next = try XCTUnwrap(SceneResolver.resolve(Composition(layers: [camera]), canvas: size, sources: sources).first)
        let mid = SceneBlend(canvas: CGRect(origin: .zero, size: size)).lerp(old, next, 0.5)
        XCTAssertEqual(mid.frameWidth, 2.5)
        XCTAssertEqual(mid.frameColor, SIMD4(1, 0, 0, 1))
    }
}
