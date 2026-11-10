import XCTest
import AppKit
@testable import StudioKit

/// A picture gesture belongs to the scene and canvas it started in, pauses the editor's playback, and never shares an
/// undo step with a scroll or nudge burst before it.
final class LayerGestureTests: XCTestCase {
    let size = Canvas.wide.size(.hd)

    /// Scene A from 0 and its duplicate B (same layer ids, the title elsewhere) from 5 s.
    func twoScenes() -> (EditorModel, Scene, Scene) {
        let m = makeEditorModel()
        let title = Layer(name: "Title", source: LayerSource(type: "text", text: TextSpec(string: "Hello")), frame: NRect(x: 0.1, y: 0.1, w: 0.3, h: 0.1))
        let a = Scene(name: "A", wide: Composition(layers: [Layer(name: "Game", source: .game), title]))
        var b = a; b.id = UUID(); b.name = "B"
        b.wide.layers[1].frame = NRect(x: 0.5, y: 0.7, w: 0.3, h: 0.1)
        m.update("Setup") { $0.scenes = [a, b]; $0.timeline.sceneSpans = [SceneSpan(startMs: 0, sceneID: a.id), SceneSpan(startMs: 5000, sceneID: b.id)] }
        m.undoManager.removeAllActions(); m.refreshUndoState()
        return (m, a, b)
    }
    func canvas(_ m: EditorModel) -> LayerCanvas { LayerCanvas(m, sources: m.stageSources(), pointsPerPixel: 0.5) }

    /// The review's case: a drag starts while playing, the playhead crosses into the duplicated scene. Starting the
    /// drag pauses playback; if the scene at the playhead changes anyway, the drag ends there and B is untouched.
    func testDragPausesPlaybackAndStaysOnItsScene() throws {
        let (m, a, b) = twoScenes()
        m.playing = true
        let i = LayerInteraction(), act = m.layerActions
        XCTAssertEqual(i.mouseDown(at: CGPoint(x: 300, y: 150), clickCount: 1, canvas: canvas(m), actions: act), .grabbing)
        XCTAssertFalse(m.playing, "a manipulation on the picture pauses playback")
        i.mouseDragged(to: CGPoint(x: 340, y: 150), option: true, shift: false, canvas: canvas(m), actions: act)
        XCTAssertEqual(m.project.scenes[0].wide.layers[1].frame.rect(in: size).minX, 192 + 40, accuracy: 0.01)
        m.time = 6                                         // the picture now shows B
        XCTAssertEqual(m.editedSceneID, b.id)
        i.mouseDragged(to: CGPoint(x: 600, y: 400), option: true, shift: false, canvas: canvas(m), actions: act)
        XCTAssertNil(i.drag, "the drag ended with its scene")
        XCTAssertEqual(m.project.scenes[1], b, "the duplicate is never moved with A's geometry")
        XCTAssertEqual(m.project.scenes[0].wide.layers[1].frame.rect(in: size).minX, 192 + 40, accuracy: 0.01)
        XCTAssertFalse(i.mouseUp(actions: act))
        XCTAssertEqual(m.undoTitle, "Undo Move Layer")
        m.undo()
        XCTAssertEqual(m.project.scenes[0], a)
        XCTAssertFalse(m.canUndo, "one step")

        // The same for the canvas: switching to 9:16 mid-drag ends it.
        m.time = 1
        _ = i.mouseDown(at: CGPoint(x: 300, y: 150), clickCount: 1, canvas: canvas(m), actions: act)
        XCTAssertNotNil(i.drag)
        m.canvas = .vertical
        i.mouseDragged(to: CGPoint(x: 340, y: 150), option: true, shift: false, canvas: canvas(m), actions: act)
        XCTAssertNil(i.drag)
        XCTAssertEqual(m.project.scenes[0].vertical, a.vertical)
    }

    /// A nudge burst's step is still open (its timer waits for a pause) when a drag starts: the nudge closes at once and
    /// the drag is its own single step, even if the drag outlasts the nudge's pause.
    func testPendingNudgeClosesBeforeADrag() throws {
        let (m, a, _) = twoScenes()
        let i = LayerInteraction(), act = m.layerActions
        i.pause = 0.1
        let id = a.wide.layers[1].id
        m.selectLayer(id)
        XCTAssertTrue(i.key(.right, shift: false, canvas: canvas(m), actions: act))
        let nudged = m.project.scenes[0]
        XCTAssertEqual(i.mouseDown(at: CGPoint(x: 300, y: 150), clickCount: 1, canvas: canvas(m), actions: act), .grabbing)
        i.mouseDragged(to: CGPoint(x: 320, y: 150), option: true, shift: false, canvas: canvas(m), actions: act)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))     // longer than the nudge's pause
        i.mouseDragged(to: CGPoint(x: 360, y: 150), option: true, shift: false, canvas: canvas(m), actions: act)
        i.mouseUp(actions: act)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(m.project.scenes[0].wide.layers[1].frame.rect(in: size).minX, 192 + 1 + 60, accuracy: 0.01)
        XCTAssertEqual(m.undoTitle, "Undo Move Layer")
        m.undo()
        XCTAssertEqual(m.project.scenes[0], nudged, "the whole drag was one step")
        XCTAssertEqual(m.undoTitle, "Undo Nudge Layer")
        m.undo()
        XCTAssertEqual(m.project.scenes[0], a)
        XCTAssertFalse(m.canUndo)
    }

    /// The live window gets the same calls as before, plus the nudge's end moved ahead of the drag's start; with no
    /// burst open a drag is unchanged, and a scroll burst still closes on its own after the pause.
    func testLiveCallSequence() throws {
        let text = Layer(name: "T", source: LayerSource(type: "text", text: TextSpec()), frame: NRect(x: 0.25, y: 0.25, w: 0.25, h: 0.25))
        var comp = Composition(layers: [text])
        var calls: [String] = []
        var act = SceneActions()
        act.selectLayer = { _ in calls.append("select") }
        act.editLayer = { _, f in f(&comp.layers[0]) }
        act.beginGesture = { calls.append("begin") }; act.endGesture = { calls.append("end \($0)") }
        let ctx = LayerContext(sceneID: UUID(), canvas: .wide)
        func c() -> LayerCanvas { LayerCanvas(layers: comp.layers, size: size, sources: [:], selectedID: text.id, cropID: nil, pointsPerPixel: 1, context: ctx) }
        let i = LayerInteraction(); i.pause = 0.1
        _ = i.mouseDown(at: CGPoint(x: 600, y: 400), clickCount: 1, canvas: c(), actions: act)
        i.mouseDragged(to: CGPoint(x: 610, y: 400), option: true, shift: false, canvas: c(), actions: act)
        i.mouseUp(actions: act)
        XCTAssertEqual(calls, ["select", "begin", "end Move Layer"])
        calls = []
        _ = i.key(.left, shift: false, canvas: c(), actions: act)
        _ = i.mouseDown(at: CGPoint(x: 600, y: 400), clickCount: 1, canvas: c(), actions: act)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        i.mouseUp(actions: act)
        XCTAssertEqual(calls, ["begin", "end Nudge Layer", "select", "begin", "end Move Layer"])
        calls = []
        XCTAssertTrue(i.scroll(at: CGPoint(x: 600, y: 400), deltaY: 2, precise: true, canvas: c(), actions: act))
        XCTAssertTrue(i.scroll(at: CGPoint(x: 600, y: 400), deltaY: 2, precise: true, canvas: c(), actions: act))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(calls, ["begin", "begin", "end Resize Layer"])
    }
}
