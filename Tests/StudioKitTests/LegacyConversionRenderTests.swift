import XCTest
import Metal
@testable import StudioKit

/// A scene migrated from a fixed layout becomes a scene of layers at its first layer edit. The picture must not
/// change: for each of the four layout kinds, on both canvases, the frame rendered before and after the conversion
/// is the same within the compositor goldens' 0.002.
final class LegacyConversionRenderTests: XCTestCase {
    let golden = SceneGoldenTests()

    func render(_ p: Project, canvas: Canvas, size: CGSize, tex: [SourceKey: LayerTextures.Kind]) -> [Float] {
        let plan = RenderPlan(scenes: p.scenes, timeline: p.timeline, map: TimeMap(segments: [], sourceDurationMs: p.durationMs),
                              canvas: canvas, canvasSize: size, sources: golden.sources, mirrorCamera: p.cameraMirror)
        return OverlayTestSupport.render(canvas: size, background: plan.background(atTimelineMs: 500), transfer: 2,
                                         layers: DrawLayer.pair(plan.layers(atTimelineMs: 500), tex))
    }

    func testConversionKeepsThePicture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let tex = golden.textures()
        var report: [String] = []
        for kind in LayoutKind.allCases {
            for canvas in Canvas.allCases {
                let m = makeEditorModel(layers: true)
                // An older project: no scenes, its fixed layouts in `wide` and `vertical`, migrated on load.
                var layout = m.project.layout(canvas); layout.kind = kind
                if kind == .pip { layout.camera.roundness = 0.3; layout.camera.border = true; layout.camera.shadow = true }
                m.update("Setup") { p in
                    if canvas == .wide { p.wide = layout } else { p.vertical = layout }
                    p.scenes = [p.defaultScene]; p.timeline.sceneSpans = [SceneSpan(startMs: 0, sceneID: p.scenes[0].id)]
                }
                m.canvas = canvas
                XCTAssertNotNil(m.editedComposition.legacyLayout, "\(kind) \(canvas)")
                let size = canvas == .wide ? CGSize(width: 128, height: 72) : CGSize(width: 72, height: 128)
                let before = render(m.project, canvas: canvas, size: size, tex: tex)
                // Any layer edit converts it; renaming changes nothing drawn.
                let first = try XCTUnwrap(m.editedComposition.layers.first)
                m.editLayer(first.id) { $0.name = "Renamed" }
                XCTAssertNil(m.editedComposition.legacyLayout, "\(kind) \(canvas) converted")
                let after = render(m.project, canvas: canvas, size: size, tex: tex)
                let worst = zip(before, after).map { abs($0 - $1) }.max() ?? 1
                report.append("\(kind.rawValue)/\(canvas.rawValue) \(worst)")
                XCTAssertLessThanOrEqual(worst, 0.002, "\(kind) on \(canvas)")
                // Not a blank picture: the sources are drawn.
                XCTAssertGreaterThan(Set(after.enumerated().filter { $0.offset % 4 == 0 }.map { ($0.element * 50).rounded() }).count, 3, "\(kind) \(canvas)")
            }
        }
        print("Legacy conversion, max difference per kind and canvas: " + report.joined(separator: ", "))
    }
}
