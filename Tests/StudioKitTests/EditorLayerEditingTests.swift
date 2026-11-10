import XCTest
import AppKit
@testable import StudioKit

/// Picking and editing any layer of the scene at the playhead in the editor preview, with the live window's rules
/// (one `LayerInteraction` for both), into the project's copy of the scene with undo.
final class EditorLayerEditingTests: XCTestCase {
    let size = Canvas.wide.size(.hd)

    /// A layer scene with the game, a camera window and a text layer, shown from 0.
    func model(camera: Bool = true) -> (EditorModel, Scene) {
        let m = makeEditorModel(layers: camera)
        let text = Layer(name: "Title", source: LayerSource(type: "text", text: TextSpec(string: "Hello")), frame: NRect(x: 0.1, y: 0.1, w: 0.3, h: 0.1))
        let cam = Layer(name: "Camera", source: .camera, frame: NRect(x: 0.7, y: 0.6, w: 0.25, h: 0.3))
        let game = Layer(name: "Game", source: .game, frame: NRect(x: 0, y: 0, w: 0.6, h: 0.6))
        let scene = Scene(name: "Show", wide: Composition(layers: [game, cam, text]), vertical: Composition(layers: [Layer(name: "Game", source: .game)]))
        m.update("Setup") { $0.scenes = [scene]; $0.timeline.sceneSpans = [SceneSpan(startMs: 0, sceneID: scene.id)] }
        m.undoManager.removeAllActions(); m.refreshUndoState()
        return (m, scene)
    }
    func canvas(_ m: EditorModel) -> LayerCanvas { LayerCanvas(m, sources: m.stageSources(), pointsPerPixel: 0.5) }

    func testPickMoveWithSnappingAndOneUndoStep() throws {
        let (m, scene) = model()
        let i = LayerInteraction(), a = m.layerActions
        // Topmost layer under the pointer: the text, over the game.
        XCTAssertEqual(i.mouseDown(at: CGPoint(x: 300, y: 150), clickCount: 1, canvas: canvas(m), actions: a), .grabbing)
        XCTAssertEqual(m.selection, .layer(scene.wide.layers[2].id))
        XCTAssertEqual(m.selectedEditedLayer?.displayName, "Title")
        // Drag so the text's left edge lands 4 px from the canvas centre: it snaps there, with a guide.
        for x in stride(from: 300.0, through: 300 + 960 - 192 - 4 + 0, by: 40) { i.mouseDragged(to: CGPoint(x: x, y: 150), option: false, shift: false, canvas: canvas(m), actions: a) }
        i.mouseDragged(to: CGPoint(x: 300 + 960 - 192 - 4, y: 150), option: false, shift: false, canvas: canvas(m), actions: a)
        let moved = try XCTUnwrap(m.selectedEditedLayer).frame.rect(in: size)
        XCTAssertEqual(moved.minX, 960, accuracy: 0.01, "snapped to the centre line")
        XCTAssertTrue(i.guides.contains { $0.axis == .vertical && $0.position == 960 })
        i.mouseUp(actions: a)
        XCTAssertEqual(m.undoTitle, "Undo Move Layer", "the whole drag is one step")
        m.undo()
        XCTAssertEqual(m.project.scenes[0], scene)
        m.redo()
        XCTAssertEqual(m.selectedEditedLayer?.frame.rect(in: size).minX ?? 0, 960, accuracy: 0.01)
        // ⌥ turns snapping off.
        _ = i.mouseDown(at: CGPoint(x: 1000, y: 150), clickCount: 1, canvas: canvas(m), actions: a)
        i.mouseDragged(to: CGPoint(x: 1004, y: 150), option: true, shift: false, canvas: canvas(m), actions: a)
        i.mouseUp(actions: a)
        XCTAssertEqual(m.selectedEditedLayer?.frame.rect(in: size).minX ?? 0, 964, accuracy: 0.01)
        XCTAssertNil(LiveSceneLibrary.shared.scenes().first, "nothing reaches the live scenes")
    }

    func testHandlesResizeKeysNudgeAndDelete() throws {
        let (m, scene) = model()
        let i = LayerInteraction(), a = m.layerActions
        i.pause = 0
        m.selectLayer(scene.wide.layers[1].id)   // the camera
        let r = scene.wide.layers[1].frame.rect(in: size)
        let c = canvas(m)
        XCTAssertEqual(c.handle(at: CGPoint(x: r.maxX + 3, y: r.maxY - 2)), .bottomRight)
        XCTAssertEqual(i.mouseDown(at: CGPoint(x: r.maxX, y: r.maxY), clickCount: 1, canvas: c, actions: a), .resizing)
        i.mouseDragged(to: CGPoint(x: r.maxX - 100, y: r.maxY - 60), option: false, shift: false, canvas: canvas(m), actions: a)
        i.mouseUp(actions: a)
        let small = try XCTUnwrap(m.selectedEditedLayer).frame.rect(in: size)
        XCTAssertEqual(small.origin.x, r.origin.x, accuracy: 0.01); XCTAssertEqual(small.width / small.height, r.width / r.height, accuracy: 0.001)
        XCTAssertEqual(m.undoTitle, "Undo Resize Layer")
        // Arrow keys nudge a pixel, ⇧ ten; a burst is one step once it pauses.
        XCTAssertTrue(i.key(.right, shift: false, canvas: canvas(m), actions: a))
        XCTAssertTrue(i.key(.down, shift: true, canvas: canvas(m), actions: a))
        let nudged = try XCTUnwrap(m.selectedEditedLayer).frame.rect(in: size)
        XCTAssertEqual(nudged.minX - small.minX, 1, accuracy: 0.01); XCTAssertEqual(nudged.minY - small.minY, 10, accuracy: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(m.undoTitle, "Undo Nudge Layer")
        m.undo()
        XCTAssertEqual(m.selectedEditedLayer?.frame.rect(in: size).minX ?? 0, small.minX, accuracy: 0.01)
        // ⌫: the camera is hidden, not deleted; text is deleted. Through the timeline's Delete too.
        XCTAssertTrue(i.key(.delete, shift: false, canvas: canvas(m), actions: a))
        XCTAssertEqual(m.editedComposition.layers.count, 3); XCTAssertFalse(m.editedComposition.layers[1].visible)
        m.selectLayer(scene.wide.layers[2].id)
        m.deleteSelection()
        XCTAssertEqual(m.editedComposition.layers.map(\.displayName), ["Game", "Camera"])
        XCTAssertEqual(m.selection, .none)
        // Esc deselects.
        m.selectLayer(scene.wide.layers[0].id)
        XCTAssertTrue(i.key(.escape, shift: false, canvas: canvas(m), actions: a))
        XCTAssertEqual(m.selection, .none)
    }

    /// Without camera frames the scene's main game fills the picture: handles and hit-testing follow what is drawn.
    func testPinnedGameUsesTheResolvedFrame() throws {
        let (m, scene) = model(camera: false)
        let c = canvas(m)
        XCTAssertEqual(c.pinnedID, scene.wide.layers[0].id)
        // Outside the game's own frame (0.6 × 0.6) but inside the canvas: still the game.
        let p = CGPoint(x: 1500, y: 300)
        XCTAssertEqual(c.hit(p)?.id, scene.wide.layers[0].id)
        let i = LayerInteraction(), a = m.layerActions
        XCTAssertEqual(i.mouseDown(at: p, clickCount: 1, canvas: c, actions: a), .none, "selected, but a rule places it: no move")
        XCTAssertEqual(m.selection, .layer(scene.wide.layers[0].id))
        XCTAssertNil(canvas(m).handle(at: CGPoint(x: 1920, y: 1080)))
        XCTAssertEqual(canvas(m).rect(m.selectedEditedLayer!), CGRect(origin: .zero, size: size))
        // Double-click crops it, which works on the drawn frame.
        _ = i.mouseDown(at: p, clickCount: 2, canvas: canvas(m), actions: a)
        XCTAssertEqual(m.cropLayerID, scene.wide.layers[0].id)
    }

    func testAddListReorderHideAndCanvases() throws {
        let (m, scene) = model()
        m.layerActions.addLayer("text")
        let added = try XCTUnwrap(m.selectedEditedLayer)
        XCTAssertEqual(added.source.text?.string, "Your text"); XCTAssertEqual(m.focusTextLayerID, added.id)
        XCTAssertEqual(m.undoTitle, "Undo Add Layer")
        m.layerActions.addLayer("color")
        XCTAssertEqual(m.editedComposition.layers.first?.source.type, "color", "a backdrop goes to the bottom")
        m.layerActions.moveLayer(scene.wide.layers[2].id, Int.max)
        XCTAssertEqual(m.editedComposition.layers.last?.id, scene.wide.layers[2].id)
        m.layerActions.editLayer(scene.wide.layers[0].id) { $0.visible = false }
        XCTAssertFalse(m.editedComposition.layers.first { $0.id == scene.wide.layers[0].id }!.visible)
        XCTAssertEqual(m.project.scenes[0].vertical, scene.vertical, "the other canvas is untouched")
        // Switching canvas drops a picked layer: each canvas has its own.
        m.selectLayer(added.id)
        m.canvas = .vertical
        XCTAssertEqual(m.selection, .none)
        XCTAssertEqual(m.editedComposition.layers.count, 1)
        while m.canUndo { m.undo() }
        XCTAssertEqual(m.project.scenes[0], scene)
    }

    /// A migrated fixed-layout scene becomes a layer scene at its first layer edit.
    func testLegacySceneBecomesLayersOnEdit() throws {
        let m = makeEditorModel(layers: true)
        XCTAssertTrue(m.sceneControls.legacy)
        let cam = try XCTUnwrap(m.editedComposition.layers.first { $0.source.type == "camera" })
        m.layerActions.editLayer(cam.id) { $0.roundness = 0.5 }
        XCTAssertNil(m.editedComposition.legacyLayout)
        XCTAssertFalse(m.sceneControls.legacy)
        XCTAssertEqual(m.editedComposition.layers.first { $0.id == cam.id }?.roundness, 0.5)
    }

    func testSaveAsLiveSceneAndAddFromLiveScenes() throws {
        let saved = expectation(description: "saved")
        var live = SceneCollection.defaults().scenes
        let previous = LiveSceneLibrary.shared
        defer { LiveSceneLibrary.shared = previous }
        let liveAssets = try OverlayTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: liveAssets) }
        LiveSceneLibrary.shared = LiveSceneLibrary(scenes: { live }, add: { live.append($0); saved.fulfill() }, assets: liveAssets)
        let (m, scene) = model()
        // An image this recording has in its own Assets.
        let png = m.doc.dir.appendingPathComponent("logo.png")
        try OverlayTestSupport.writePNG(png, width: 4, height: 4, rgba: [UInt8](repeating: 255, count: 64))
        let name = try AssetStore.importImage(png, into: m.projectAssets)
        m.layerActions.editLayer(scene.wide.layers[2].id) { $0.source = LayerSource(type: "image", file: name) }
        m.saveSceneToLive()
        wait(for: [saved], timeout: 5)
        let copy = try XCTUnwrap(live.last)
        XCTAssertEqual(copy.name, "Show"); XCTAssertEqual(copy.id, scene.id, "a scene the live set lacks keeps its id")
        XCTAssertEqual(copy.wide.layers.map(\.source), m.project.scenes[0].wide.layers.map(\.source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveAssets.appendingPathComponent(name).path), "its image is in the live assets")
        // Saving again never replaces it: new id, new name.
        let again = expectation(description: "again"); LiveSceneLibrary.shared.add = { live.append($0); again.fulfill() }
        m.saveSceneToLive()
        wait(for: [again], timeout: 5)
        XCTAssertEqual(live.last?.name, "Show 2"); XCTAssertNotEqual(live.last?.id, scene.id)

        // Add from Live Scenes: the ones the recording lacks, copied in and changed to at the playhead.
        XCTAssertFalse(m.liveScenesToAdd.contains { $0.id == scene.id })
        let gameplay = try XCTUnwrap(m.liveScenesToAdd.first { $0.name == "Gameplay" })
        m.seek(4)
        m.addLiveScene(gameplay)
        XCTAssertTrue(m.project.scenes.contains(gameplay))
        XCTAssertEqual(m.project.timeline.sceneSpans.last?.startMs ?? 0, 4000, accuracy: 0.001)
        XCTAssertEqual(TimelineEdits.sceneRun(at: 4001, in: m.project)?.sceneID, gameplay.id)
        m.seek(4.5)
        XCTAssertEqual(m.activeScene?.id, gameplay.id)
        XCTAssertEqual(m.undoTitle, "Undo Add Gameplay")
        m.undo()
        XCTAssertFalse(m.project.scenes.contains(gameplay))
    }

    /// The live window runs the same controller through `MetalView`'s own event handling: a drag on the picture moves
    /// the layer under it in the live scene.
    func testLiveWindowDragStillMovesTheLayer() throws {
        let sm = SceneModel()
        let text = Layer(name: "T", source: LayerSource(type: "text", text: TextSpec()), frame: NRect(x: 0.25, y: 0.25, w: 0.25, h: 0.25))
        sm.collection = SceneCollection(scenes: [Scene(name: "A", wide: Composition(layers: [text]))], activeID: UUID())
        sm.collection.normalize()
        var calls: [String] = []
        var a = SceneActions()
        a.selectLayer = { sm.selectedLayerID = $0; calls.append("select") }
        a.editLayer = { id, f in _ = sm.collection.edit(sceneID: sm.collection.activeID, canvas: .wide) { c in if let j = c.layers.firstIndex(where: { $0.id == id }) { f(&c.layers[j]) } } }
        a.beginGesture = { calls.append("begin") }; a.endGesture = { calls.append("end \($0)") }
        sm.actions = a
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.borderless], backing: .buffered, defer: true)
        let v = MetalView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        window.contentView = v
        v.scenes = sm
        func event(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // View points: the canvas fills the view at half scale, origin bottom-left.
        // Canvas (600, 400) to (700, 440).
        v.mouseDown(with: event(.leftMouseDown, 300, 540 - 200))
        v.mouseDragged(with: event(.leftMouseDragged, 350, 540 - 220))
        v.mouseUp(with: event(.leftMouseUp, 350, 540 - 220))
        XCTAssertEqual(sm.selectedLayerID, text.id)
        let r = try XCTUnwrap(sm.selectedLayer).frame.rect(in: size)
        XCTAssertEqual(r.minX, 480 + 100, accuracy: 0.01); XCTAssertEqual(r.minY, 270 + 40, accuracy: 0.01)
        XCTAssertEqual(calls, ["select", "begin", "end Move Layer"])
    }
}
