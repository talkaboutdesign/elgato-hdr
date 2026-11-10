import XCTest
@testable import StudioKit

final class TimelineTests: XCTestCase {
    func testBoundariesAndEmpty() {
        let all = TimeMap(segments: [], sourceDurationMs: 1000)
        XCTAssertEqual(all.durationMs, 1000); XCTAssertEqual(all.source(fromTimeline: -1), 0)
        XCTAssertEqual(all.source(fromTimeline: 2000), 1000)
        let map = TimeMap(segments: [Segment(startMs: 100, endMs: 300), Segment(startMs: 500, endMs: 800), Segment(startMs: 900, endMs: 1000)], sourceDurationMs: 1000)
        XCTAssertEqual(map.durationMs, 600)
        XCTAssertEqual(map.source(fromTimeline: 199), 299); XCTAssertEqual(map.source(fromTimeline: 200), 500)
        XCTAssertEqual(map.source(fromTimeline: 500), 900); XCTAssertEqual(map.source(fromTimeline: 600), 1000)
        XCTAssertNil(map.timeline(fromSource: 300)); XCTAssertNil(map.timeline(fromSource: 400))
        XCTAssertEqual(map.timeline(fromSource: 500), 200); XCTAssertEqual(map.timeline(fromSource: 1000), 600)
        XCTAssertEqual(map.cutPoints(), [200, 500])
    }
    func testEditingAndNormalization() {
        var map = TimeMap(segments: [], sourceDurationMs: 1000)
        map.split(atSourceMs: 500); XCTAssertEqual(map.segments.count, 2); XCTAssertEqual(map.cutPoints(), [])
        map.split(atSourceMs: 501); XCTAssertEqual(map.segments.count, 2)
        map.remove(sourceRange: Segment(startMs: 200, endMs: 400))
        map.remove(sourceRange: Segment(startMs: 400, endMs: 600))
        XCTAssertEqual(map.segments, [Segment(startMs: 0, endMs: 200), Segment(startMs: 600, endMs: 1000)])
        map.restore(sourceRange: Segment(startMs: 200, endMs: 600)); XCTAssertEqual(map.durationMs, 1000)
        XCTAssertEqual(map.segments.count, 1)
        XCTAssertFalse(map.remove(sourceRange: Segment(startMs: 0, endMs: 1000))); XCTAssertEqual(map.durationMs, 1000)
        XCTAssertEqual(TimeMap(segments: map.storedSegments, sourceDurationMs: 1000).durationMs, 1000)
        map.restore(sourceRange: Segment(startMs: 10, endMs: 20)); XCTAssertEqual(map.durationMs, 1000)
        map.restore(sourceRange: Segment(startMs: -100, endMs: 2000)); XCTAssertEqual(map.durationMs, 1000)
    }
    func testEveryFrameAcrossManyCuts() {
        for fps in [30.0, 59.94, 60, 120] {
            let f = 1000 / fps
            let ranges = (0..<80).map { Segment(startMs: Double($0 * 47) * f, endMs: Double($0 * 47 + 30) * f) }
            let map = TimeMap(segments: ranges, sourceDurationMs: 4000 * f, frameMs: f)
            for t in 0..<2400 {
                let source = (t / 30) * 47 + t % 30
                XCTAssertEqual(map.source(fromTimeline: Double(t) * f) / f, Double(source), accuracy: 1e-7)
                XCTAssertEqual(map.timeline(fromSource: Double(source) * f)! / f, Double(t), accuracy: 1e-7)
            }
            for (i, cut) in map.cutPoints().enumerated() { XCTAssertEqual(cut / f, Double((i+1)*30), accuracy: 1e-7) }
        }
    }
    func testTrimClipsAndRestoresOuterMaterial() {
        let original = Timeline(segments: [Segment(startMs: 100, endMs: 400), Segment(startMs: 600, endMs: 900)])
        let clipped = original.trimming(startMs: 200, endMs: 800, sourceDurationMs: 1000, frameMs: 10)
        XCTAssertEqual(clipped.segments, [Segment(startMs: 200, endMs: 400), Segment(startMs: 600, endMs: 800)])
        let widened = clipped.trimming(startMs: 0, endMs: 1000, sourceDurationMs: 1000, frameMs: 10)
        XCTAssertEqual(widened.segments, [Segment(startMs: 0, endMs: 400), Segment(startMs: 600, endMs: 1000)])
        XCTAssertEqual(clipped.trimming(startMs: 500, endMs: 550, sourceDurationMs: 1000, frameMs: 10), clipped)
        var one = TimeMap(segments: [], sourceDurationMs: 100, frameMs: 10)
        XCTAssertFalse(one.remove(sourceRange: Segment(startMs: 0, endMs: 95)))
        XCTAssertTrue(one.remove(sourceRange: Segment(startMs: 0, endMs: 90)))
        XCTAssertEqual(one.durationMs, 10)
        var empty = TimeMap(segments: [], sourceDurationMs: 0)
        empty.split(atSourceMs: 0)
        XCTAssertFalse(empty.remove(sourceRange: Segment(startMs: 0, endMs: 100)))
        XCTAssertEqual(empty.storedSegments, [])
    }
    func testInvalidAndOverlappingRanges() {
        var map = TimeMap(segments: [Segment(startMs: .nan, endMs: 5), Segment(startMs: 800, endMs: 100), Segment(startMs: -10, endMs: 500), Segment(startMs: 200, endMs: 700), Segment(startMs: 700, endMs: 710)], sourceDurationMs: 1000)
        map.normalize(); XCTAssertEqual(map.segments, [Segment(startMs: 0, endMs: 710)])
    }
    func testMigrationAndRoundTrips() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for file in ["v1-trim", "v1-events"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"))
            let p = try decoder.decode(Project.self, from: Data(contentsOf: url))
            XCTAssertEqual(p.version, 2); XCTAssertFalse(p.scenes.isEmpty); XCTAssertFalse(p.timeline.sceneSpans.isEmpty)
            if file == "v1-trim" { XCTAssertEqual(p.timeline.segments, [Segment(startMs: 500, endMs: 1500)]) }
            else {
                XCTAssertEqual(p.timeline.sceneSpans.count, 2); XCTAssertEqual(p.timeline.zooms.count, 1)
                XCTAssertEqual(p.timeline.zooms[0].scale, 2); XCTAssertEqual(p.timeline.zooms[0].focusX, 0.8)
                XCTAssertEqual(p.timeline.markers.count, 1)
            }
            XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)), p)
        }
        var p = Project(name: "Bounds", createdAt: Date())
        p.timeline.segments = [Segment(startMs: 100, endMs: 300), Segment(startMs: 700, endMs: 900)]
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.trimStartMs, 100); XCTAssertEqual(decoded.trimEndMs, 900)
        XCTAssertEqual(decoded.timeline, p.timeline)
        let partial = try JSONDecoder().decode(Timeline.self, from: Data("{\"zooms\":[{\"startMs\":100,\"endMs\":900}]}".utf8))
        XCTAssertEqual(partial.zooms.first?.scale, 1.8)
    }
}
