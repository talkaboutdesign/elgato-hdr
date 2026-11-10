import XCTest
import AppKit
@testable import StudioKit

func project(durationMs: Double = 10_000, fps: Double = 50) -> Project {
    var p = Project(name: "T", createdAt: Date(timeIntervalSince1970: 0))
    p.durationMs = durationMs; p.fps = fps; p.width = 1920; p.height = 1080
    return p
}

final class TimelineAxisTests: XCTestCase {
    func testFitMappingAndInverse() {
        var a = TimelineAxis(duration: 100, width: 1000)
        XCTAssertEqual(a.pps, 10); XCTAssertEqual(a.x(50), 500); XCTAssertEqual(a.time(atX: 250), 25)
        XCTAssertFalse(a.isZoomedIn)
        a.setWidth(500)
        XCTAssertEqual(a.pps, 5, "a fitted timeline follows the width")
        XCTAssertEqual(a.time(atX: -40), 0); XCTAssertEqual(a.time(atX: 9_999), 100)
    }

    func testZoomKeepsTimeUnderAnchor() {
        var a = TimelineAxis(duration: 100, width: 1000)
        let anchor = 300.0, before = a.time(atX: anchor)
        a.zoom(by: 4, anchorX: anchor)
        XCTAssertEqual(a.pps, 40, accuracy: 1e-9)
        XCTAssertEqual(a.time(atX: anchor), before, accuracy: 1e-9)
        XCTAssertTrue(a.isZoomedIn)
        a.zoom(by: 0.01, anchorX: anchor)
        XCTAssertTrue(a.fitted, "zooming out past fit snaps back to fit"); XCTAssertEqual(a.offset, 0)
        a.zoom(by: 1e9, anchorX: 0)
        XCTAssertEqual(a.pps, TimelineAxis.maxScale)
    }

    func testPanClampsAndReveal() {
        var a = TimelineAxis(duration: 100, width: 1000)
        a.zoom(to: 100, anchorX: 0)          // 10 000 pt of content
        a.pan(by: -50); XCTAssertEqual(a.offset, 0)
        a.pan(by: 1e6); XCTAssertEqual(a.offset, 9000)
        a.offset = 0
        a.reveal(50)
        XCTAssertGreaterThanOrEqual(a.x(50), 0); XCTAssertLessThanOrEqual(a.x(50), 1000)
    }

    func testCollapsedRangesDrawAsGaps() {
        var a = TimelineAxis(duration: 100, width: 1000, collapsed: [20...40])
        let s = (1000 - TimelineAxis.gap) / 80
        XCTAssertEqual(a.pps, s, accuracy: 1e-9)
        XCTAssertEqual(a.contentX(20), 20 * s, accuracy: 1e-9)
        XCTAssertEqual(a.contentX(40), 20 * s + TimelineAxis.gap, accuracy: 1e-9)
        XCTAssertEqual(a.contentWidth, 1000, accuracy: 1e-6)
        for t in [0.0, 10, 20, 30, 40, 70, 100] { XCTAssertEqual(a.time(atContentX: a.contentX(t)), t, accuracy: 1e-6) }
        a.collapsed = []
        XCTAssertEqual(a.contentX(40), 400, accuracy: 1e-9)
    }

    func testZoomFractionAndTicks() {
        var a = TimelineAxis(duration: 300, width: 1200)
        XCTAssertEqual(a.zoomFraction, 0)
        a.setZoomFraction(1, anchorX: 0); XCTAssertEqual(a.zoomFraction, 1, accuracy: 1e-9)
        a.setZoomFraction(0.5, anchorX: 600); XCTAssertEqual(a.zoomFraction, 0.5, accuracy: 1e-9)
        a.fit()
        let (major, minor) = a.ticks()
        XCTAssertGreaterThanOrEqual(major * a.pps, 72); XCTAssertLessThan(minor, major)
    }
}

final class TimelineEditsTests: XCTestCase {
    func testSplitTwiceRemoveMiddleRestoreKeepsSplits() {
        var p = project()
        XCTAssertTrue(TimelineEdits.split(&p, atMs: 3000))
        XCTAssertTrue(TimelineEdits.split(&p, atMs: 6000))
        XCTAssertFalse(TimelineEdits.split(&p, atMs: 6005), "within a frame of an existing split")
        XCTAssertEqual(TimelineEdits.sections(p).map(\.kept), [true, true, true])
        let middle = TimelineEdits.section(at: 4500, in: p)!
        TimelineEdits.remove(&p, section: middle)
        XCTAssertEqual(p.timeline.segments, [Segment(startMs: 0, endMs: 3000), Segment(startMs: 6000, endMs: 10_000)])
        XCTAssertEqual(TimelineEdits.sections(p).map(\.kept), [true, false, true])
        TimelineEdits.split(&p, atMs: 8000)
        TimelineEdits.remove(&p, section: TimelineEdits.section(at: 1000, in: p)!)
        XCTAssertEqual(TimelineEdits.boundaries(p).filter { $0.left != nil && $0.right != nil }.map(\.ms), [8000], "removing one section keeps other splits")
        XCTAssertEqual(TimelineEdits.sections(p).map(\.kept), [false, true, true], "adjacent removed sections read as one")
        TimelineEdits.restore(&p, section: TimelineEdits.section(at: 4500, in: p)!)
        XCTAssertEqual(TimelineEdits.sections(p).map { $0.startMs }, [0, 6000, 8000], "restoring brings the range back; its edge stays a split point")
        XCTAssertEqual(p.trimStartMs, 0); XCTAssertEqual(p.trimEndMs, 10_000)
        var q = project()
        TimelineEdits.split(&q, atMs: 3000); TimelineEdits.split(&q, atMs: 6000)
        let mid = TimelineEdits.section(at: 4500, in: q)!
        TimelineEdits.remove(&q, section: mid); TimelineEdits.restore(&q, section: CutSection(startMs: 3000, endMs: 6000, kept: false))
        XCTAssertEqual(TimelineEdits.sections(q).map { $0.startMs }, [0, 3000, 6000], "remove then restore keeps both split points")
    }

    func testRemovingEverythingStoresExplicitEmptyRange() {
        var p = project()
        TimelineEdits.remove(&p, section: TimelineEdits.sections(p)[0])
        XCTAssertEqual(p.timeline.segments, [Segment(startMs: 0, endMs: 0)])
        XCTAssertTrue(TimelineEdits.kept(p).isEmpty)
        XCTAssertEqual(TimelineEdits.sections(p), [CutSection(startMs: 0, endMs: 10_000, kept: false)])
        TimelineEdits.restore(&p, section: TimelineEdits.sections(p)[0])
        XCTAssertEqual(p.timeline.segments, [], "everything kept and unsplit is stored as []")
    }

    func testInOutAndClear() {
        var p = project()
        TimelineEdits.split(&p, atMs: 5000)
        TimelineEdits.setIn(&p, atMs: 1000)
        TimelineEdits.setOut(&p, atMs: 9000)
        XCTAssertEqual(TimelineEdits.kept(p), [Segment(startMs: 1000, endMs: 5000), Segment(startMs: 5000, endMs: 9000)])
        TimelineEdits.setIn(&p, atMs: 500)
        XCTAssertEqual(TimelineEdits.kept(p).first?.startMs, 500, "an earlier in point grows the first range back")
        TimelineEdits.clearInOut(&p)
        XCTAssertEqual(TimelineEdits.kept(p), [Segment(startMs: 0, endMs: 5000), Segment(startMs: 5000, endMs: 10_000)])
        TimelineEdits.setIn(&p, atMs: 1013)
        XCTAssertEqual(TimelineEdits.kept(p).first?.startMs, 1020, "frame-snapped at 50 fps")
    }

    func testLegacyTrimIsTheStartingKeptRange() {
        var p = project()
        p.trimStartMs = 2000; p.trimEndMs = 7000
        XCTAssertEqual(TimelineEdits.sections(p).map(\.kept), [false, true, false])
        TimelineEdits.split(&p, atMs: 4000)
        XCTAssertEqual(p.timeline.segments, [Segment(startMs: 2000, endMs: 4000), Segment(startMs: 4000, endMs: 7000)])
    }

    func testTrimDragClampsToNeighbours() {
        var p = project()
        p.timeline.segments = [Segment(startMs: 0, endMs: 3000), Segment(startMs: 6000, endMs: 10_000)]
        let original = TimelineEdits.kept(p)
        let edge = TimelineEdits.boundaries(p).first { $0.ms == 3000 }!
        XCTAssertEqual(edge.left, 0); XCTAssertNil(edge.right)
        TimelineEdits.move(edge, to: 4500, original: original, in: &p)
        XCTAssertEqual(TimelineEdits.kept(p)[0].endMs, 4500)
        TimelineEdits.move(edge, to: 99_000, original: original, in: &p)
        XCTAssertEqual(TimelineEdits.kept(p)[0].endMs, 6000, "stops at the next kept range")
        TimelineEdits.move(edge, to: -5, original: original, in: &p)
        XCTAssertEqual(TimelineEdits.kept(p)[0].endMs, 20, "never shorter than a frame")
        // A split between two kept ranges moves both sides.
        var q = project()
        TimelineEdits.split(&q, atMs: 5000)
        let split = TimelineEdits.boundaries(q).first { $0.ms == 5000 }!
        TimelineEdits.move(split, to: 7000, original: TimelineEdits.kept(q), in: &q)
        XCTAssertEqual(TimelineEdits.kept(q), [Segment(startMs: 0, endMs: 7000), Segment(startMs: 7000, endMs: 10_000)])
    }

    func testSnapping() {
        XCTAssertEqual(Snapping.snap(1003, to: [1000, 2000], tolerance: 5).value, 1000)
        XCTAssertNil(Snapping.snap(1010, to: [1000, 2000], tolerance: 5).target)
        XCTAssertEqual(Snapping.snap(1998, to: [1000, 2000], tolerance: 5).target, 2000)
        XCTAssertEqual(Snapping.snap(5, to: [], tolerance: 5).value, 5)
    }

    func testSceneChangesMaterializeTemplatesAndRetime() {
        var p = project()
        XCTAssertEqual(TimelineEdits.sceneRuns(p).count, 1)
        let choices = TimelineEdits.sceneChoices(p, hasCamera: true)
        XCTAssertEqual(choices.map(\.name), ["Default", "Gameplay", "Camera Focus", "Split", "Picture in Picture"])
        let cam = TimelineEdits.materialize(choices[2], in: &p, hasCamera: true)
        XCTAssertEqual(p.scenes.map(\.name), ["Default", "Camera Focus"])
        XCTAssertEqual(TimelineEdits.sceneChoices(p, hasCamera: true)[2].sceneID, cam)
        XCTAssertEqual(p.scenes[1].wide.layers.map(\.source.type), ["camera"])
        let span = TimelineEdits.insertSceneChange(&p, sceneID: cam, atMs: 4000)!
        XCTAssertEqual(TimelineEdits.sceneRuns(p).map(\.sceneID), [p.scenes[0].id, cam])
        XCTAssertNil(TimelineEdits.insertSceneChange(&p, sceneID: cam, atMs: 6000), "already showing that scene")
        XCTAssertEqual(TimelineEdits.materialize(TimelineEdits.sceneChoices(p, hasCamera: true)[2], in: &p, hasCamera: true), cam,
                       "an existing scene is reused, not duplicated")
        TimelineEdits.moveSceneChange(&p, spanID: span, toMs: 99_000)
        XCTAssertEqual(TimelineEdits.sortedSpans(p).last?.startMs ?? 0, 10_000 - 40, accuracy: 0.001, "two frames before the end")
        TimelineEdits.removeSceneChange(&p, spanID: span)
        XCTAssertEqual(TimelineEdits.sceneRuns(p).count, 1)
        XCTAssertEqual(TimelineEdits.sceneChoices(p, hasCamera: true).map(\.name), ["Default", "Gameplay", "Camera Focus", "Split", "Picture in Picture"],
                       "materializing a template keeps the order, so ⌃n keeps its scene")
        XCTAssertEqual(TimelineEdits.sceneChoices(p, hasCamera: false).map(\.name), ["Default", "Gameplay", "Camera Focus"])
    }

    func testRenderPlanAgreesWithSceneRuns() {
        var p = project()
        let cam = TimelineEdits.materialize(TimelineEdits.sceneChoices(p, hasCamera: true)[2], in: &p, hasCamera: true)
        TimelineEdits.insertSceneChange(&p, sceneID: cam, atMs: 5000)
        p.timeline.sceneSpans[1].transition.style = .cut
        let plan = RenderPlan(scenes: p.scenes, timeline: p.timeline, map: TimeMap(segments: [], sourceDurationMs: p.durationMs), canvas: .wide,
                              canvasSize: Canvas.wide.size(.hd), sources: [.game: SourceInfo(size: CGSize(width: 1920, height: 1080)), .camera: SourceInfo(size: CGSize(width: 1280, height: 720))],
                              mirrorCamera: false)
        for t in [0.0, 4999, 5000, 9000] {
            let run = TimelineEdits.sceneRun(at: t, in: p)!
            let keys = plan.layers(atTimelineMs: t).map(\.key)
            XCTAssertEqual(keys.contains(.game), run.sceneID == p.scenes[0].id, "\(t)")
        }
    }

    func testZoomBlocksNeverOverlap() {
        var p = project()
        let a = TimelineEdits.addZoom(&p, atMs: 1000)!
        XCTAssertEqual(TimelineEdits.addZoom(&p, atMs: 2000), a, "inside a block selects it")
        let b = TimelineEdits.addZoom(&p, atMs: 5000)!
        let c = TimelineEdits.addZoom(&p, atMs: 4200)!
        XCTAssertEqual(p.timeline.zooms.first { $0.id == c }!.endMs, 5000, "shortened to the next block")
        let room = TimelineEdits.zoomRoom(p, id: b)
        XCTAssertEqual(room.lo, 5000); XCTAssertEqual(room.hi, 10_000)
        let orig = p.timeline.zooms.first { $0.id == b }!
        TimelineEdits.moveZoom(&p, id: b, original: orig, byMs: -3000, room: room)
        XCTAssertEqual(p.timeline.zooms.first { $0.id == b }!.startMs, 5000)
        TimelineEdits.moveZoom(&p, id: b, original: orig, byMs: 50_000, room: room)
        XCTAssertEqual(p.timeline.zooms.first { $0.id == b }!.endMs, 10_000)
        TimelineEdits.resizeZoom(&p, id: a, leading: false, toMs: 1100, room: TimelineEdits.zoomRoom(p, id: a))
        XCTAssertEqual(p.timeline.zooms.first { $0.id == a }!.endMs, 1000 + TimelineEdits.minZoomMs)
        var q = project(durationMs: 1000)
        XCTAssertNotNil(TimelineEdits.addZoom(&q, atMs: 900), "near the end the block moves back to fit")
        XCTAssertEqual(q.timeline.zooms[0].endMs, 1000)
    }

    func testMarkersAndShort() {
        var p = project(durationMs: 120_000)
        let m1 = TimelineEdits.addMarker(&p, atMs: 50_000)
        XCTAssertEqual(TimelineEdits.addMarker(&p, atMs: 50_005), m1)
        TimelineEdits.addMarker(&p, atMs: 10_000)
        XCTAssertEqual(TimelineEdits.nextMarker(after: 10_000, in: p)?.id, m1)
        XCTAssertEqual(TimelineEdits.previousMarker(before: 50_000, in: p)?.tMs, 10_000)
        XCTAssertNil(TimelineEdits.nextMarker(after: 50_000, in: p))
        XCTAssertEqual(TimelineEdits.markerTitle(p.timeline.markers.first { $0.id == m1 }!, in: p), "Marker 2")
        TimelineEdits.makeShort(&p, aroundMs: 50_000)
        XCTAssertEqual(TimelineEdits.kept(p), [Segment(startMs: 35_000, endMs: 65_000)])
        var q = project(durationMs: 120_000)
        TimelineEdits.makeShort(&q, aroundMs: 4000)
        XCTAssertEqual(TimelineEdits.kept(q), [Segment(startMs: 0, endMs: 30_000)], "clamped at the start")
    }
}

final class TimelineSelectionTests: XCTestCase {
    func testHitTestingPicksTheRightThing() {
        var p = project()
        TimelineEdits.split(&p, atMs: 5000)
        let zid = TimelineEdits.addZoom(&p, atMs: 2000)!
        let mid = TimelineEdits.addMarker(&p, atMs: 7000)
        let cam = TimelineEdits.materialize(TimelineEdits.sceneChoices(p, hasCamera: true)[2], in: &p, hasCamera: true)
        let span = TimelineEdits.insertSceneChange(&p, sceneID: cam, atMs: 8000)!
        let layout = TimelineLayout.make(hasMic: true)
        let axis = TimelineAxis(duration: 10, width: 1000)   // 100 pt per second
        func y(_ k: LaneKind) -> Double { layout.lane(k)!.y + layout.lane(k)!.height / 2 }
        func hit(_ x: Double, _ k: LaneKind) -> TimelineHit { TimelineHitTest.hit(x: x, y: y(k), layout: layout, axis: axis, project: p, selection: .none) }
        XCTAssertEqual(hit(502, .video), .cut(CutBoundary(ms: 5000, left: 0, right: 1)))
        XCTAssertEqual(hit(300, .video), .section(CutSection(startMs: 0, endMs: 5000, kept: true)))
        XCTAssertEqual(hit(200, .zoom), .zoomEdge(zid, leading: true))
        XCTAssertEqual(hit(350, .zoom), .zoom(zid))
        XCTAssertEqual(hit(499, .zoom), .zoomEdge(zid, leading: false))
        XCTAssertEqual(hit(900, .zoom), .lane(.zoom))
        XCTAssertEqual(hit(801, .scenes), .sceneChange(span))
        XCTAssertEqual(hit(300, .scenes), .sceneRun(TimelineEdits.sortedSpans(p).first?.id), "the first change also stores the scene at zero")
        var bare = p; bare.timeline.sceneSpans.removeAll { $0.startMs == 0 }
        XCTAssertEqual(TimelineHitTest.hit(x: 300, y: y(.scenes), layout: layout, axis: axis, project: bare, selection: .none), .sceneRun(nil),
                       "a run before the first change without a span of its own")
        XCTAssertEqual(hit(900, .scenes), .sceneRun(span))
        let ruler = layout.lane(.ruler)!
        XCTAssertEqual(TimelineHitTest.hit(x: 704, y: ruler.y + ruler.height * 0.7, layout: layout, axis: axis, project: p, selection: .none), .marker(mid))
        XCTAssertEqual(TimelineHitTest.hit(x: 300, y: ruler.y + 4, layout: layout, axis: axis, project: p, selection: .none), .ruler)
        XCTAssertEqual(hit(300, .micAudio), .lane(.micAudio))
    }

    func testSelectionFollowsEditsAndDeleteToggles() {
        let m = makeEditorModel()
        m.seek(3); m.split(); m.seek(6); m.split()
        m.seek(4.5)
        m.deleteSelection()   // nothing selected: the section under the playhead
        XCTAssertEqual(m.selection, .section(CutSection(startMs: 3000, endMs: 6000, kept: false)))
        XCTAssertEqual(TimelineEdits.sections(m.project).map(\.kept), [true, false, true])
        m.deleteSelection()   // again: restores it
        XCTAssertEqual(TimelineEdits.sections(m.project).map(\.kept), [true, true, true])
        m.addZoom()
        guard case .zoom(let id) = m.selection else { return XCTFail("adding a zoom selects it") }
        m.undo()
        XCTAssertNil(m.zoomBlock(id)); XCTAssertEqual(m.selection, .none, "undo drops a selection that no longer exists")
    }

    func testEditsLockedWhileExporting() {
        let m = makeEditorModel()
        let gate = FakeRunner.Gate()
        m.exportQueue = ExportQueue { _ in FakeRunner(gate: gate) }
        m.exportQueue.enqueue([("A", ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source))])
        XCTAssertTrue(m.editsLocked)
        let before = m.project
        m.seek(2); m.split(); m.addMarker()
        XCTAssertEqual(m.project, before, "no edits while the queue runs")
        XCTAssertFalse(m.canUndo)
        m.exportQueue.cancelAll()
    }

    func testKeyTable() {
        func cmd(_ c: String, _ code: UInt16 = 0xFFFF, _ f: NSEvent.ModifierFlags = []) -> EditorCommand? { EditorShortcut.command(chars: c, keyCode: code, flags: f) }
        XCTAssertEqual(cmd(" ", 49), .playPause)
        XCTAssertEqual(cmd("s"), .split); XCTAssertEqual(cmd("b", 11, .command), .split)
        XCTAssertEqual(cmd("", 51), .delete)
        XCTAssertEqual(cmd("M", 46, .shift), .nextMarker); XCTAssertEqual(cmd("m", 46, .option), .previousMarker)
        XCTAssertEqual(cmd("Z", 6, .shift), .fit); XCTAssertEqual(cmd("z"), .addZoom); XCTAssertEqual(cmd("z", 6, .command), .undo)
        XCTAssertEqual(cmd("", 124, [.shift, .numericPad, .function]), .jumpForward, "arrow keys carry extra flags")
        XCTAssertEqual(cmd("3", 20, .control), .sceneChange(3))
        XCTAssertEqual(cmd("l"), .shuttleForward); XCTAssertEqual(cmd("j"), .shuttleBack); XCTAssertEqual(cmd("k"), .shuttleStop)
        XCTAssertNil(cmd("q", 12, .command), "app menu keys pass through")
        XCTAssertNil(cmd("1", 18, .command), "the Input menu keeps ⌘1…⌘9")
        // Every command the timeline offers is listed in the Keyboard Shortcuts window.
        let listed = Set(EditorShortcut.all.map(\.command))
        for c: EditorCommand in [.playPause, .shuttleForward, .shuttleBack, .shuttleStop, .stepForward, .jumpForward, .nextEdit, .nextMarker, .split, .delete,
                                 .setIn, .setOut, .clearInOut, .undo, .deselect, .addZoom, .sceneChange(1), .addMarker, .zoomIn, .fit, .toggleRemoved, .export, .shortcuts] {
            XCTAssertTrue(listed.contains(c), "\(c) missing from the shortcuts list")
        }
    }
}

/// Pointer logic through `TimelineInteraction`, as the AppKit view drives it: drags land where they end and never
/// snap to the item being dragged.
final class TimelineInteractionTests: XCTestCase {
    func testDragsLandWhereReleasedAndSnapToOthers() {
        let m = makeEditorModel(durationMs: 100_000, fps: 50)   // 10 pt per second at 1000 pt
        m.setTimelineWidth(1000)
        let layout = TimelineLayout.make(hasMic: false)
        let ui = TimelineInteraction(model: m, layout: layout)
        func y(_ k: LaneKind) -> Double { layout.lane(k)!.y + layout.lane(k)!.height / 2 }
        func drag(_ k: LaneKind, _ from: Double, _ to: Double, steps: Int = 8) {
            ui.mouseDown(at: CGPoint(x: from * 10, y: y(k)), clickCount: 1, flags: [])
            for i in 1..<steps { ui.mouseDragged(to: CGPoint(x: (from + (to - from) * Double(i) / Double(steps)) * 10, y: y(k)), flags: []) }
            ui.mouseUp(at: CGPoint(x: to * 10, y: y(k)))   // the last movement arrives with the release
        }
        m.seek(20); m.split(); m.seek(40); m.split()
        m.select(.section(TimelineEdits.section(at: 30_000, in: m.project)!)); m.deleteSelection(); m.selection = .none
        drag(.video, 40, 45)
        XCTAssertEqual(TimelineEdits.kept(m.project)[1].startMs, 45_000, "a trim moves the edge to the release point, not to itself")
        XCTAssertEqual(m.undoTitle, "Undo Trim")
        m.seek(60); m.addZoom(); m.selection = .none
        drag(.zoom, 61.5, 70)
        XCTAssertEqual(m.project.timeline.zooms[0].startMs, 68_500, accuracy: 0.001, "moved by the drag distance")
        drag(.zoom, 71.5, 80)
        XCTAssertEqual(m.project.timeline.zooms[0].endMs, 80_000, accuracy: 0.001, "the end edge resizes")
        m.seek(90); m.addSceneChange(index: 2)
        drag(.video, 45, 89.4)
        XCTAssertEqual(TimelineEdits.kept(m.project)[1].startMs, 90_000, "within eight points of the scene change, a trim snaps to it")
        m.undo()
        XCTAssertEqual(TimelineEdits.kept(m.project)[1].startMs, 45_000, "a drag is one undo step")
    }
}
