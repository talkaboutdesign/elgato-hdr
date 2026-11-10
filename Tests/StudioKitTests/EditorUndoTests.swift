import XCTest
@testable import StudioKit

/// A project folder without media: the model's preview build fails quietly, every edit path still runs.
func makeEditorModel(durationMs: Double = 10_000, fps: Double = 60) -> EditorModel {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Editor-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var p = Project(name: "Test", createdAt: Date(timeIntervalSince1970: 0))
    p.durationMs = durationMs; p.fps = fps; p.width = 1920; p.height = 1080
    let doc = ProjectDoc(dir: dir, project: p)
    doc.save()
    let m = EditorModel(doc: doc)
    m.duration = durationMs / 1000
    return m
}

final class EditorUndoTests: XCTestCase {
    func testEachEditIsOneStepAndRedoRestores() {
        let m = makeEditorModel()
        let original = m.project
        m.update("Game Volume") { $0.game.volume = 0.5 }
        m.update("Mirror") { $0.cameraMirror = true }
        XCTAssertTrue(m.canUndo); XCTAssertFalse(m.canRedo)
        XCTAssertEqual(m.undoTitle, "Undo Mirror")
        m.undo()
        XCTAssertFalse(m.project.cameraMirror); XCTAssertEqual(m.project.game.volume, 0.5)
        m.undo()
        XCTAssertEqual(m.project, original)
        XCTAssertFalse(m.canUndo); XCTAssertTrue(m.canRedo)
        m.redo(); m.redo()
        XCTAssertEqual(m.project.game.volume, 0.5); XCTAssertTrue(m.project.cameraMirror)
        XCTAssertEqual(m.doc.project, m.project, "the document follows undo and redo")
    }

    func testGestureCoalescesIntoOneStep() {
        let m = makeEditorModel()
        let before = m.project.game.volume
        m.update("Mirror") { $0.cameraMirror = true }
        m.beginGesture()
        for v in stride(from: 0.1, through: 1.5, by: 0.1) { m.update("Game Volume") { $0.game.volume = v } }
        m.endGesture()
        XCTAssertEqual(m.undoTitle, "Undo Game Volume")
        m.undo()
        XCTAssertEqual(m.project.game.volume, before, "one undo reverts the whole drag")
        XCTAssertTrue(m.project.cameraMirror, "and nothing before it")
        m.redo()
        XCTAssertEqual(m.project.game.volume, 1.5, accuracy: 1e-9)
    }

    func testEmptyGestureAndNoOpEditsLeaveNoStep() {
        let m = makeEditorModel()
        m.beginGesture(); m.endGesture()
        m.update { $0.game.volume = $0.game.volume }
        XCTAssertFalse(m.canUndo)
    }

    func testNewEditClearsRedo() {
        let m = makeEditorModel()
        m.update { $0.game.volume = 0.3 }
        m.undo()
        XCTAssertTrue(m.canRedo)
        m.update { $0.game.volume = 0.7 }
        XCTAssertFalse(m.canRedo)
    }
}
