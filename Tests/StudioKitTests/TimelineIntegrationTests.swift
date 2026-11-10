import XCTest
@testable import StudioKit

final class TimelineIntegrationTests: XCTestCase {
    func testVersionTwoEventsImportOnceAndPersistSceneIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = Project(name: "Events", createdAt: Date())
        let id = p.defaultScene.id
        XCTAssertEqual(id, p.defaultScene.id)
        p.durationMs = 3000
        p.events = [SessionEvent(tMs: 0, type: "scene", sceneID: id),
                    SessionEvent(tMs: 500, type: "zoomIn", zoom: 2),
                    SessionEvent(tMs: 1500, type: "zoomOut"), SessionEvent(tMs: 2000, type: "marker")]
        ProjectDoc(dir: dir, project: p).save()
        let first = try XCTUnwrap(ProjectDoc.load(dir))
        XCTAssertEqual(first.project.scenes.first?.id, id)
        XCTAssertEqual(first.project.timeline.sceneSpans.first?.sceneID, id)
        XCTAssertEqual(first.project.timeline.zooms.first?.endMs, 1500)
        XCTAssertEqual(first.project.timeline.markers.first?.tMs, 2000)
        XCTAssertTrue(first.project.eventsImported)
        first.project.timeline.markers = []; first.project.timeline.zooms = []; first.save()
        let second = try XCTUnwrap(ProjectDoc.load(dir))
        XCTAssertTrue(second.project.timeline.markers.isEmpty)
        XCTAssertTrue(second.project.timeline.zooms.isEmpty)
        XCTAssertEqual(second.project.scenes.first?.id, id)
    }
    func testLegacyEmptyScenesPersistAndImportPreservesEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"version":2,"name":"Old recording","scenes":[],"durationMs":3000,"events":[{"type":"marker","tMs":1000}],"timeline":{"markers":[{"tMs":2000,"label":"edited"}]}}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        let first = try XCTUnwrap(ProjectDoc.load(dir)), second = try XCTUnwrap(ProjectDoc.load(dir))
        XCTAssertEqual(first.project.scenes.count, 1)
        XCTAssertEqual(first.project.scenes, second.project.scenes)
        XCTAssertEqual(second.project.timeline.markers.map(\.label), ["edited"])
    }
    func testSplitsSurviveRemovalPersistenceRestorationAndTrim() throws {
        var p = Project(name: "Splits", createdAt: Date()); p.durationMs = 3000
        TimelineEdits.split(&p, atMs: 1000); TimelineEdits.split(&p, atMs: 2000)
        TimelineEdits.remove(&p, section: CutSection(startMs: 1000, endMs: 2000, kept: true))
        p = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        TimelineEdits.restore(&p, section: CutSection(startMs: 1000, endMs: 2000, kept: false))
        XCTAssertEqual(TimelineEdits.kept(p).count, 3)
        TimelineEdits.setIn(&p, atMs: 500); TimelineEdits.clearInOut(&p)
        XCTAssertEqual(TimelineEdits.kept(p).count, 3)
        let map = TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs)
        XCTAssertEqual(map.durationMs, 3000); XCTAssertTrue(map.cutPoints().isEmpty)
    }
}
