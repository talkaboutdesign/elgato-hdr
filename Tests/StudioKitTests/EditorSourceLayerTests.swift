import XCTest
@testable import StudioKit

/// A scene converted from a single-source layout lacks the other source; the editor's add palette offers it back,
/// placed as the live templates place it.
final class EditorSourceLayerTests: XCTestCase {
    /// A recording with a camera whose only scene is a legacy layout of `kind` on both canvases.
    func model(_ kind: LayoutKind, camera: Bool = true) -> EditorModel {
        let m = makeEditorModel(layers: camera)
        let wide = Composition.from(layout: CanvasLayout(kind: kind), canvas: Canvas.wide.size(.hd), hasCamera: camera, mirror: false)
        let tall = Composition.from(layout: CanvasLayout(kind: kind), canvas: Canvas.vertical.size(.hd), hasCamera: camera, mirror: false)
        var w = wide, v = tall
        w.legacyLayout = CanvasLayout(kind: kind); v.legacyLayout = CanvasLayout(kind: kind)
        let scene = Scene(name: "Default", wide: w, vertical: v)
        m.update("Setup") { $0.scenes = [scene]; $0.timeline.sceneSpans = [SceneSpan(startMs: 0, sceneID: scene.id)] }
        m.undoManager.removeAllActions(); m.refreshUndoState()
        return m
    }

    func template(_ t: SceneTemplate, _ type: String, _ c: Canvas) -> Layer {
        SceneTemplate.scene(t)(placement: CameraPlacement(), mirror: false).composition(c).layers.first { $0.source.type == type }!
    }

    func testGameOnlySceneGetsItsCameraBack() throws {
        for c in Canvas.allCases {
            let m = model(.screenOnly)
            m.canvas = c
            // Converting it to layers (any layer edit) used to leave no way to the camera.
            let game = try XCTUnwrap(m.editedComposition.layers.first)
            m.layerActions.editLayer(game.id) { $0.roundness = 0.1 }
            XCTAssertNil(m.editedComposition.legacyLayout)
            XCTAssertEqual(m.addableSources, ["camera"], c.label)
            m.layerActions.addLayer("camera")
            let cam = try XCTUnwrap(m.editedComposition.layers.first { $0.source.type == "camera" })
            let expected = template(.gameplay, "camera", c)
            XCTAssertEqual(cam.frame, expected.frame, "placed as in Gameplay on \(c.label)")
            XCTAssertEqual(cam.roundness, expected.roundness); XCTAssertEqual(cam.shadow, expected.shadow)
            XCTAssertNotEqual(cam.id, expected.id)
            XCTAssertEqual(m.editedComposition.layers.last?.id, cam.id, "on top of the game")
            XCTAssertEqual(m.selection, .layer(cam.id))
            XCTAssertEqual(m.addableSources, [])
            XCTAssertEqual(m.undoTitle, "Undo Add Layer")
        }
    }

    func testCameraOnlySceneGetsTheGameBack() throws {
        for c in Canvas.allCases {
            let m = model(.cameraOnly)
            m.canvas = c
            XCTAssertEqual(m.addableSources, ["game"], c.label)
            m.layerActions.addLayer("game")
            let game = try XCTUnwrap(m.editedComposition.layers.first { $0.source.type == "game" })
            XCTAssertEqual(game.frame, template(.cameraFocus, "game", c).frame, "placed as in Camera Focus on \(c.label)")
            XCTAssertNil(m.editedComposition.legacyLayout)
            XCTAssertEqual(m.addableSources, [])
        }
    }

    /// No camera recorded: nothing to offer for it. A scene with both sources offers neither.
    func testOnlyRecordedAndMissingSourcesAreOffered() {
        XCTAssertEqual(model(.screenOnly, camera: false).addableSources, [])
        XCTAssertEqual(model(.pip).addableSources, [])
        XCTAssertEqual(SceneModel().addableSources, ["game", "camera"], "live: both, as before")
    }
}
