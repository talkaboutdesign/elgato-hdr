import XCTest
@testable import StudioKit

final class RenderPlanTests: XCTestCase {
    func plan(_ canvas: Canvas = .wide) -> RenderPlan {
        let game = Composition(layers: [Layer(source: .game)]), camera = Composition(layers: [Layer(source: .camera)])
        let a = Scene(name: "Game", wide: game, vertical: game), b = Scene(name: "Camera", wide: camera, vertical: camera)
        let timeline = Timeline(sceneSpans: [SceneSpan(startMs: 0, sceneID: a.id), SceneSpan(startMs: 1000, sceneID: b.id, transition: SceneTransition(style: .fade, durationMs: 1000))])
        return RenderPlan(scenes: [a, b], timeline: timeline, map: TimeMap(segments: [], sourceDurationMs: 4000), canvas: canvas, canvasSize: canvas.size(.hd), sources: [.game: SourceInfo(size: CGSize(width: 1920, height: 1080)), .camera: SourceInfo(size: CGSize(width: 1280, height: 720))], mirrorCamera: false)
    }
    func testSceneAndTransitions() {
        for c in Canvas.allCases {
            var p = plan(c)
            XCTAssertEqual(p.layers(atTimelineMs: 999).map(\.key), [.game])
            let start = p.layers(atTimelineMs: 1000), middle = p.layers(atTimelineMs: 1500)
            XCTAssertEqual(start[0].opacity, 1); XCTAssertEqual(start[1].opacity, 0)
            XCTAssertGreaterThan(middle[1].opacity, 0); XCTAssertLessThan(middle[1].opacity, 1)
            XCTAssertEqual(middle[0].opacity + middle[1].opacity, 1, accuracy: 0.0001)
            XCTAssertEqual(p.layers(atTimelineMs: 2000).map(\.key), [.camera])
            p.timeline.sceneSpans[1].transition.style = .cut
            XCTAssertEqual(p.layers(atTimelineMs: 1000).map(\.key), [.camera])
        }
    }
    func testNoTransitionAcrossCut() {
        var p = plan()
        p.map = TimeMap(segments: [Segment(startMs: 0, endMs: 1100), Segment(startMs: 1300, endMs: 4000)], sourceDurationMs: 4000)
        XCTAssertEqual(p.layers(atTimelineMs: 1100).map(\.key), [.camera])
        p.map = TimeMap(segments: [Segment(startMs: 1300, endMs: 4000)], sourceDurationMs: 4000)
        XCTAssertEqual(p.layers(atTimelineMs: 0).map(\.key), [.camera])
    }
    func testZoomWeightsFocusOverlapAndCanvases() {
        let z = ZoomBlock(startMs: 0, endMs: 1000, scale: 2, focusX: 0.99, focusY: 0.99, easeMs: 200)
        XCTAssertEqual(z.weight(at: 0), 0); XCTAssertEqual(z.weight(at: 100), 0.5)
        XCTAssertEqual(z.weight(at: 500), 1); XCTAssertEqual(z.weight(at: 900), 0.5); XCTAssertEqual(z.weight(at: 1000), 0)
        for c in Canvas.allCases {
            var p = plan(c); p.timeline.zooms = [z]
            let original = p.layers(atTimelineMs: 0)[0].src
            let crop = p.layers(atTimelineMs: 500)[0].src
            XCTAssertEqual(crop.width, original.width / 2, accuracy: 0.0001)
            let pivot = min(original.maxX, max(original.minX, z.focusX))
            XCTAssertEqual(crop.minX, pivot + (original.minX - pivot) / 2, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(crop.minX, 0); XCTAssertLessThanOrEqual(crop.maxX, 1)
            XCTAssertGreaterThanOrEqual(crop.minY, 0); XCTAssertLessThanOrEqual(crop.maxY, 1)
            p.timeline.zooms.append(ZoomBlock(startMs: 490, endMs: 1000, scale: 4))
            XCTAssertEqual(p.layers(atTimelineMs: 500)[0].src, crop)
        }
    }
    func testFirstSpanStartsImmediatelyAndMissingCameraFillsFrame() {
        var p = plan()
        p.timeline.sceneSpans = [SceneSpan(startMs: 0, sceneID: p.scenes[1].id)]
        XCTAssertEqual(p.layers(atTimelineMs: 0).map(\.key), [.camera])
        var project = Project(name: "Missing camera", createdAt: Date())
        project.wide.kind = .stacked
        p.scenes = [project.defaultScene]; p.timeline.sceneSpans = []
        p.sources.removeValue(forKey: .camera)
        XCTAssertEqual(p.layers(atTimelineMs: 0).first?.dst, CGRect(origin: .zero, size: p.canvasSize))
    }
}
