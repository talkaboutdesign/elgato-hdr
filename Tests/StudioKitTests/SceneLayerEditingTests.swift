import XCTest
@testable import StudioKit

/// The inspector's layout controls and the preview's direct manipulation edit the layers of the scene at the
/// playhead. A scene made from a template has no fixed layout; it used to be rebuilt from the project's default
/// layout (choosing Fit on a game-only Gameplay scene gave it a camera).
final class SceneLayerEditingTests: XCTestCase {
    let stage = CGSize(width: 1000, height: 562.5)

    func testTemplateSceneLayersAreEditedInPlace() throws {
        let m = makeEditorModel(layers: true)
        let defaultScene = m.project.scenes[0]
        m.seek(0)
        m.addSceneChange(try XCTUnwrap(m.sceneChoices.first { $0.name == "Gameplay" }))
        XCTAssertEqual(m.activeScene?.name, "Gameplay")
        let before = try XCTUnwrap(m.activeScene).wide
        XCTAssertEqual(before.layers.map(\.source.type), ["game"])
        XCTAssertNil(before.legacyLayout)
        XCTAssertEqual(m.sceneControls, .init(legacy: false, game: true, camera: false), "no camera or layout-kind controls for a game-only scene")

        // The fixed-layout path must leave a layer scene alone.
        var l = m.layout; l.fit = true; m.layout = l
        XCTAssertEqual(m.activeScene?.wide, before, "a template scene is never rebuilt from the project's default layout")

        m.sceneLayerBinding(.game, \.fit, "Game Fit", fallback: false).wrappedValue = true
        let game = try XCTUnwrap(m.activeScene).wide.layers
        XCTAssertEqual(game.map(\.source.type), ["game"], "Fit keeps the scene's own layers")
        XCTAssertEqual(game[0].id, before.layers[0].id)
        XCTAssertTrue(game[0].fit)
        XCTAssertEqual(m.undoTitle, "Undo Game Fit")
        m.sceneLayerBinding(.game, \.zoom, "Game Zoom", fallback: 1).wrappedValue = 2
        m.panSceneGame(from: (0.5, 0.5), translation: CGSize(width: 100, height: 0), stage: stage)
        let g = try XCTUnwrap(m.sceneLayer(.game))
        XCTAssertEqual(g.zoom, 2)
        XCTAssertLessThan(g.panX, 0.5, "dragging right shows more of the left of the picture")
        XCTAssertEqual(g.panY, 0.5)
        XCTAssertEqual(m.project.scenes.first { $0.id == defaultScene.id }, defaultScene, "other scenes untouched")
    }

    func testCameraLayerOfATemplateSceneMovesAndResizes() throws {
        let m = makeEditorModel(layers: true)
        m.seek(5)
        m.addSceneChange(try XCTUnwrap(m.sceneChoices.first { $0.name == "Picture in Picture" }))
        XCTAssertEqual(m.sceneControls, .init(legacy: false, game: true, camera: true))
        let layers = try XCTUnwrap(m.activeScene).wide.layers
        let cam = try XCTUnwrap(m.sceneLayer(.camera)).frame
        m.moveSceneCamera(from: cam, translation: CGSize(width: -100, height: 50), stage: stage)
        let moved = try XCTUnwrap(m.sceneLayer(.camera)).frame
        XCTAssertEqual(moved.x, max(0, cam.x - 0.1), accuracy: 1e-9)
        XCTAssertEqual(moved.y, min(1 - cam.h, cam.y + 50 / 562.5), accuracy: 1e-9)
        XCTAssertEqual(moved.w, cam.w); XCTAssertEqual(moved.h, cam.h)
        let centre = CGPoint(x: (moved.x + moved.w / 2) * 1000, y: (moved.y + moved.h / 2) * 562.5)
        m.resizeSceneCamera(from: moved, corner: CGPoint(x: centre.x + moved.w * 1000 * 0.4, y: centre.y), stage: stage)
        let small = try XCTUnwrap(m.sceneLayer(.camera)).frame
        XCTAssertEqual(small.w, moved.w * 0.8, accuracy: 1e-9)
        XCTAssertEqual(small.h, moved.h * 0.8, accuracy: 1e-9)
        XCTAssertEqual(small.x + small.w / 2, moved.x + moved.w / 2, accuracy: 1e-9, "resizes around its centre")
        m.sceneLayerBinding(.camera, \.roundness, "Camera Corners", fallback: 0).wrappedValue = 0.3
        let after = try XCTUnwrap(m.activeScene).wide.layers
        XCTAssertEqual(after.map(\.id), layers.map(\.id), "same layers, edited in place")
        XCTAssertEqual(after.last?.roundness, 0.3)
    }

    func testMigratedLayoutSceneKeepsTheLayoutControls() throws {
        let m = makeEditorModel(layers: true)
        XCTAssertEqual(m.sceneControls, .init(legacy: true, game: true, camera: true))
        let original = m.project.scenes[0].wide
        var l = m.layout; l.kind = .stacked; m.layout = l
        XCTAssertEqual(m.project.scenes[0].wide.layers.map(\.source.type), ["camera", "game"])
        XCTAssertEqual(m.project.scenes[0].wide.legacyLayout?.kind, .stacked)
        XCTAssertEqual(m.project.wide.kind, .stacked, "the project's layout follows its default scene")
        m.undo()
        XCTAssertEqual(m.project.scenes[0].wide, original)
    }
}
