import XCTest
@testable import StudioKit

/// A project folder without media: the model's preview build fails quietly, every edit path still runs.
/// `layers` adds (empty) camera and mic files, as the fixture recording has, so the camera scenes are offered.
func makeEditorModel(durationMs: Double = 10_000, fps: Double = 60, name: String = "Test", layers: Bool = false) -> EditorModel {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Editor-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var p = Project(name: name, createdAt: Date(timeIntervalSince1970: 0))
    p.durationMs = durationMs; p.fps = fps; p.width = 1920; p.height = 1080
    if layers {
        p.camera = LayerInfo(file: "camera.mov"); p.mic = LayerInfo(file: "mic.mov")
        for f in ["camera.mov", "mic.mov"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data()) }
    }
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

/// Acceptance 3: split twice, delete the middle, add a zoom, add a scene change, undo everything, redo everything.
/// The debug harness runs the same steps in the app (`EHDR_EDITOR_SCRIPT`, see the pull request) on the fixture
/// project; both must produce `Fixtures/editor-script-expected.json`.
final class EditorScriptTests: XCTestCase {
    static let steps = "seek 0.5; split; seek 1.0; split; select section 0.75; delete; seek 0.25; zoom; seek 1.5; scene 3; undoall; redoall"

    /// UUIDs become placeholders in order of appearance; createdAt is the recording's own.
    static func normalize(_ json: String) -> String {
        var map: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
        // Ignore only explicitly known additive defaults; non-default values still fail the fixture comparison.
        func canonical(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(canonical) }
            guard var object = value as? [String: Any] else { return value }
            if object["frameWidth"] as? Double == 0 { object.removeValue(forKey: "frameWidth") }
            if object["frameColor"] as? [Double] == [0.42, 0.49, 1, 1] { object.removeValue(forKey: "frameColor") }
            if object["live"] as? Bool == false { object.removeValue(forKey: "live") }
            if object["liveZooms"] as? Bool == false { object.removeValue(forKey: "liveZooms") }
            if let transition = object["sceneTransition"] as? [String: Any],
               transition["style"] as? String == "morph", transition["durationMs"] as? Double == 380 {
                object.removeValue(forKey: "sceneTransition")
            }
            return object.mapValues(canonical)
        }
        let data = try! JSONSerialization.data(withJSONObject: canonical(try! JSONSerialization.jsonObject(with: Data(json.utf8))), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let json = String(decoding: data, as: UTF8.self)
        var out = json
        for m in re.matches(in: json, range: NSRange(json.startIndex..., in: json)) {
            let id = String(json[Range(m.range, in: json)!])
            if map[id] == nil { map[id] = "UUID-\(map.count + 1)" }
        }
        for (id, ph) in map { out = out.replacingOccurrences(of: id, with: ph) }
        let created = try! NSRegularExpression(pattern: "\"createdAt\" : \"[^\"]*\"")
        return created.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\"createdAt\" : \"…\"")
    }

    func testScriptedPassMatchesFixture() throws {
        let m = makeEditorModel(durationMs: 2000, fps: 60, name: "Fixture", layers: true)
        let original = m.project
        for step in Self.steps.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = step.split(separator: " ").map(String.init)
            let n = Double(parts.last ?? "") ?? 0
            switch parts[0] {
            case "seek": m.seek(n)
            case "split": m.split()
            case "select": m.select(.section(TimelineEdits.section(at: n * 1000, in: m.project)!))
            case "delete": m.deleteSelection()
            case "zoom": m.addZoom()
            case "scene": m.addSceneChange(index: Int(n))
            case "undoall": while m.canUndo { m.undo() }
            case "redoall": while m.canRedo { m.redo() }
            default: XCTFail(step)
            }
            if parts[0] == "undoall" { XCTAssertEqual(m.project, original, "undo everything returns to the start") }
        }
        XCTAssertEqual(TimelineEdits.sections(m.project).map(\.kept), [true, false, true])
        XCTAssertEqual(m.project.timeline.zooms.count, 1); XCTAssertEqual(TimelineEdits.sortedSpans(m.project).count, 2)
        m.saveNow()
        let saved = try String(contentsOf: m.doc.dir.appendingPathComponent("project.json"), encoding: .utf8)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "editor-script-expected", withExtension: "json", subdirectory: "Fixtures"))
        if let path = ProcessInfo.processInfo.environment["EHDR_RECORD_FIXTURE"] { try Self.normalize(saved).write(toFile: path, atomically: true, encoding: .utf8) }
        XCTAssertEqual(Self.normalize(saved), Self.normalize(try String(contentsOf: url, encoding: .utf8)))
    }
}
