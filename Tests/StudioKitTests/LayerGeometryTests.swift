import XCTest
@testable import StudioKit

final class LayerGeometryTests: XCTestCase {
    let canvas = CGSize(width: 1920, height: 1080)

    func testMoveSnapsToCentreLinesWithGuides() {
        let s = LayerSnapper(canvas: canvas, others: [], threshold: 8)
        let (r, g) = s.snapMove(CGRect(x: 960 - 100 + 5, y: 540 - 50 - 6, width: 200, height: 100))
        XCTAssertEqual(r.midX, 960); XCTAssertEqual(r.midY, 540)
        XCTAssertEqual(g, [SnapGuide(axis: .vertical, position: 960, from: 0, to: 1080), SnapGuide(axis: .horizontal, position: 540, from: 0, to: 1920)])
        // Out of reach: nothing moves, no guides.
        let far = CGRect(x: 300, y: 300, width: 200, height: 100)
        XCTAssertEqual(s.snapMove(far).0, far); XCTAssertTrue(s.snapMove(far).1.isEmpty)
    }

    func testMoveSnapsToTheMarginAndToOtherLayers() {
        let other = CGRect(x: 1200, y: 100, width: 300, height: 300)
        let s = LayerSnapper(canvas: canvas, others: [other], threshold: 8)
        XCTAssertEqual(s.margin, 1080 * 0.04)
        // Right edge near the 4% margin.
        let (r, g) = s.snapMove(CGRect(x: 1920 - 43.2 - 200 + 4, y: 700, width: 200, height: 100))
        XCTAssertEqual(r.maxX, 1920 - 43.2, accuracy: 1e-9)
        XCTAssertEqual(g.first?.position ?? 0, 1920 - 43.2, accuracy: 1e-9)
        // Left edge onto the other layer's left edge: the guide spans both layers.
        let (r2, g2) = s.snapMove(CGRect(x: 1203, y: 600, width: 100, height: 100))
        XCTAssertEqual(r2.minX, 1200)
        XCTAssertEqual(g2.first, SnapGuide(axis: .vertical, position: 1200, from: 100, to: 700))
        // The nearest target wins when two are in reach: left edge 2 px from 1200, right edge 3 px from 1350.
        let (r3, _) = s.snapMove(CGRect(x: 1198, y: 600, width: 155, height: 100))
        XCTAssertEqual(r3.minX, 1200)
    }

    func testCornerResizeKeepsAspectUnlessFree() {
        let r = CGRect(x: 100, y: 100, width: 400, height: 300)
        let (a, _) = LayerResize.resize(r, handle: .bottomRight, to: CGPoint(x: 900, y: 420), free: false, keepAspectOnEdges: true, snapper: nil)
        XCTAssertEqual(a.origin, r.origin, "the opposite corner stays")
        XCTAssertEqual(a.width / a.height, 4.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(a.width, 800, accuracy: 1e-9, "follows the axis the pointer leads with")
        let (b, _) = LayerResize.resize(r, handle: .bottomRight, to: CGPoint(x: 900, y: 420), free: true, keepAspectOnEdges: true, snapper: nil)
        XCTAssertEqual(b, CGRect(x: 100, y: 100, width: 800, height: 320))
        let (c, _) = LayerResize.resize(r, handle: .topLeft, to: CGPoint(x: 300, y: 50), free: true, keepAspectOnEdges: false, snapper: nil)
        XCTAssertEqual(c, CGRect(x: 300, y: 50, width: 200, height: 350))
        // Never inside out or smaller than the minimum.
        let (d, _) = LayerResize.resize(r, handle: .bottomRight, to: CGPoint(x: 0, y: 0), free: true, keepAspectOnEdges: false, snapper: nil)
        XCTAssertEqual(d.size, CGSize(width: LayerResize.minSide, height: LayerResize.minSide))
    }

    func testEdgeResize() {
        let r = CGRect(x: 100, y: 100, width: 400, height: 300)
        // Game and camera keep their aspect: the other side grows about its centre.
        let (a, _) = LayerResize.resize(r, handle: .right, to: CGPoint(x: 700, y: 999), free: false, keepAspectOnEdges: true, snapper: nil)
        XCTAssertEqual(a.minX, 100); XCTAssertEqual(a.width, 600); XCTAssertEqual(a.height, 450); XCTAssertEqual(a.midY, r.midY)
        // Option-drag (or other layers): only that side moves, so game and camera crop.
        let (b, _) = LayerResize.resize(r, handle: .right, to: CGPoint(x: 700, y: 999), free: false, keepAspectOnEdges: false, snapper: nil)
        XCTAssertEqual(b, CGRect(x: 100, y: 100, width: 600, height: 300))
        let (c, _) = LayerResize.resize(r, handle: .top, to: CGPoint(x: 0, y: 40), free: false, keepAspectOnEdges: false, snapper: nil)
        XCTAssertEqual(c, CGRect(x: 100, y: 40, width: 400, height: 360))
    }

    func testResizeSnapsTheMovingEdge() {
        let s = LayerSnapper(canvas: canvas, others: [], threshold: 8)
        let r = CGRect(x: 100, y: 100, width: 400, height: 300)
        let (a, g) = LayerResize.resize(r, handle: .right, to: CGPoint(x: 955, y: 0), free: false, keepAspectOnEdges: false, snapper: s)
        XCTAssertEqual(a.maxX, 960); XCTAssertEqual(g, [SnapGuide(axis: .vertical, position: 960, from: 0, to: 1080)])
        // Aspect-locked corner: the closer snap decides, its guide alone is shown.
        let (b, gb) = LayerResize.resize(r, handle: .bottomRight, to: CGPoint(x: 957, y: 700), free: false, keepAspectOnEdges: true, snapper: s)
        XCTAssertEqual(b.maxX, 960); XCTAssertEqual(b.width / b.height, 4.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(gb.map(\.axis), [.vertical])
    }

    func testConvertLayoutToTheOtherCanvas() throws {
        let wide = canvas, tall = CGSize(width: 1080, height: 1920)
        let gameplay = SceneTemplate.gameplay.scene()
        let v = gameplay.wide.converted(from: wide, to: tall)
        XCTAssertEqual(v.layers[0].frame, .full, "a full-canvas layer stays full")
        let cam = gameplay.wide.layers[1].frame.rect(in: wide), vc = v.layers[1].frame.rect(in: tall)
        XCTAssertEqual(vc.width / vc.height, cam.width / cam.height, accuracy: 1e-6, "keeps its shape in pixels")
        XCTAssertEqual(vc.width, cam.width * 1080 / 1080, accuracy: 1e-6)
        XCTAssertTrue(CGRect(origin: .zero, size: tall).contains(vc))
        // A layer spanning the width keeps spanning it; nothing leaves the canvas.
        let back = gameplay.vertical.converted(from: tall, to: wide)
        for l in back.layers {
            XCTAssertEqual(l.frame.x, 0, accuracy: 1e-9); XCTAssertEqual(l.frame.w, 1, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(l.frame.y + l.frame.h, 1 + 1e-9)
        }
    }

    func testEventLogTimingAndThrottle() {
        let start: UInt64 = 50_000_000_000
        var log = SessionEventLog(startNs: start)
        let id = UUID()
        XCTAssertEqual(log.event("scene", atNs: start, sceneID: id), SessionEvent(tMs: 0, type: "scene", sceneID: id))
        XCTAssertEqual(log.event("marker", atNs: start + 1_234_567_890).tMs, 1234.6)
        XCTAssertEqual(log.tMs(atNs: start - 5), 0, "never negative")
        let z = log.event("zoomIn", atNs: start + 2_000_000_000, zoom: 1.6, focus: CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(z.zoom, 1.6); XCTAssertEqual(z.focusX, 0.25); XCTAssertEqual(z.focusY, 0.75)
        // At most one save every 5 s.
        XCTAssertEqual(log.saveDelay(atNs: start + 1_000_000_000), 4_000_000_000)
        XCTAssertEqual(log.saveDelay(atNs: start + 5_000_000_000), 0)
        log.didSave(atNs: start + 6_000_000_000)
        XCTAssertEqual(log.saveDelay(atNs: start + 7_000_000_000), 4_000_000_000)
    }

    /// The inspector's X, Y, W and H fields: `nan`, `inf` and huge numbers used to pass `Double(...)` and trap in
    /// `Int(v.rounded())`. They are now rejected or clamped, and formatting never traps.
    func testPixelFieldsRejectNonFiniteAndClamp() {
        let c = CGSize(width: 1920, height: 1080)
        for f in PixelField.allCases {
            for bad in ["nan", "NaN", "inf", "-inf", "infinity", "", "abc", "1e400"] { XCTAssertNil(f.parse(bad, canvas: c), "\(f) \(bad)") }
            let r = f.range(canvas: c)
            XCTAssertEqual(f.parse("1e300", canvas: c), r.upperBound)
            XCTAssertEqual(f.parse("-1e300", canvas: c), r.lowerBound)
            XCTAssertEqual(f.parse(" 120 ", canvas: c), 120)
        }
        XCTAssertEqual(PixelField.width.parse("3", canvas: c), LayerResize.minSide)
        XCTAssertEqual(PixelField.x.parse("-5000", canvas: c), -1920)
        for v: CGFloat in [.nan, .infinity, -.infinity, 1e300, -1e300] { XCTAssertEqual(PixelField.format(v), "–") }
        XCTAssertEqual(PixelField.format(119.6), "120"); XCTAssertEqual(PixelField.format(-0.4), "0")
        // Every clamped value formats and lands on a finite frame.
        for f in PixelField.allCases {
            let v = f.parse("1e300", canvas: c)!
            XCTAssertNotEqual(PixelField.format(v), "–")
            XCTAssertTrue(NRect(CGRect(x: v, y: v, width: v, height: v), in: c).rect(in: c).width.isFinite)
        }
    }

    /// A transition duration that is not finite never reaches the `UInt64` conversion of the engine.
    func testTransitionDurationIsAlwaysFinite() throws {
        var st = LiveSceneState(scene: SceneCollection.defaults().scenes[0])
        for ms in [Double.nan, .infinity, -.infinity, -5, 1e300] { st.transition = SceneTransition(style: .morph, durationMs: ms); _ = st.durationNs }
        let t = try JSONDecoder().decode(SceneTransition.self, from: Data(#"{"style":"fade","durationMs":1e300}"#.utf8))
        XCTAssertEqual(t.durationMs, 10_000)
    }
}
