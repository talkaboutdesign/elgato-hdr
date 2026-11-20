import XCTest
import AppKit
@testable import StudioKit

// Plan 43: removed footage leaves the timeline. The axis lays kept footage end to end (gap 0) with a seam at each
// cut, read-outs count export time, ⌫ closes the gap, and the playhead never rests inside removed footage.

/// Kept 10–30 and 40–90 of 100 s: a leading cut, two touching ranges in the middle, a trailing cut.
private func seamAxis(width: Double = 1000) -> TimelineAxis {
    TimelineAxis(duration: 100, width: width, collapsed: [0...10, 30...35, 35...40, 90...100])
}

final class TimelineSeamAxisTests: XCTestCase {
    func testGapZeroMapsRemovedFootageToItsSeam() {
        let a = seamAxis()
        let s = 1000.0 / 70
        XCTAssertEqual(a.pps, s, accuracy: 1e-9, "fit fits the kept footage")
        XCTAssertEqual(a.contentWidth, 70 * s, accuracy: 1e-6)
        XCTAssertEqual(a.contentWidth, 1000, accuracy: 1e-6)
        XCTAssertEqual(a.shownDuration, 70, accuracy: 1e-9)
        for t in [10.0, 12, 29.9, 40, 41.5, 89.9] {
            XCTAssertEqual(a.time(atContentX: a.contentX(t)), t, accuracy: 1e-9, "kept \(t) round trips")
        }
        // Leading cut: its seam is at the start, and maps to the first kept time.
        XCTAssertEqual(a.contentX(0), 0, accuracy: 1e-9); XCTAssertEqual(a.contentX(5), 0, accuracy: 1e-9)
        XCTAssertEqual(a.time(atContentX: 0), 10, accuracy: 1e-9)
        // Middle cut (two touching ranges): every removed time is on the seam; the seam gives the first kept time after.
        let seam = 20 * s
        for t in [30.0, 31, 34.99, 35, 37, 39.999] { XCTAssertEqual(a.contentX(t), seam, accuracy: 1e-9, "\(t)") }
        XCTAssertEqual(a.contentX(40), seam, accuracy: 1e-9)
        XCTAssertEqual(a.time(atContentX: seam), 40, accuracy: 1e-9)
        XCTAssertEqual(a.time(atContentX: seam - 1e-6), 30, accuracy: 1e-6)
        // Trailing cut: the seam is the end; it and anything past it give the end of the kept footage.
        XCTAssertEqual(a.contentX(95), a.contentWidth, accuracy: 1e-9)
        XCTAssertEqual(a.time(atContentX: a.contentWidth), 90, accuracy: 1e-9)
        XCTAssertEqual(a.time(atContentX: a.contentWidth + 50), 90, accuracy: 1e-9)
        for x in stride(from: 0.0, through: 1000, by: 0.37) {
            XCTAssertFalse(a.isCollapsed(a.time(atContentX: x)), "x \(x) never maps inside removed footage")
        }
        XCTAssertEqual(a.seams.count, 4)
        XCTAssertEqual(a.seams.map { $0.x }, [0, seam, seam, 1000].map { $0 }, "touching ranges share a seam")
    }

    func testShownTimeCountsKeptFootage() {
        let a = seamAxis()
        XCTAssertEqual(a.shownTime(5), 0); XCTAssertEqual(a.shownTime(10), 0); XCTAssertEqual(a.shownTime(25), 15)
        XCTAssertEqual(a.shownTime(33), 20); XCTAssertEqual(a.shownTime(45), 25); XCTAssertEqual(a.shownTime(100), 70)
        XCTAssertEqual(a.sourceTime(shown: 0), 10); XCTAssertEqual(a.sourceTime(shown: 20), 40, "a seam gives the kept side after it")
        XCTAssertEqual(a.sourceTime(shown: 25), 45); XCTAssertEqual(a.sourceTime(shown: 70), 100)
        for e in stride(from: 0.0, to: 70, by: 0.7) { XCTAssertEqual(a.shownTime(a.sourceTime(shown: e)), e, accuracy: 1e-9) }
        // Ruler ticks are a fixed step of shown time apart: evenly spaced on screen, across seams too.
        let minor = a.ticks().minor
        let xs = (0...Int(70 / minor)).map { a.contentX(a.sourceTime(shown: Double($0) * minor)) }
        for (p, q) in zip(xs, xs.dropFirst()) { XCTAssertEqual(q - p, minor * a.pps, accuracy: 1e-6) }
    }

    func testZoomAndRevealAcrossSeams() {
        var a = seamAxis()
        let anchor = 300.0, before = a.time(atX: anchor)
        a.zoom(by: 5, anchorX: anchor)
        XCTAssertEqual(a.time(atX: anchor), before, accuracy: 1e-9, "zoom keeps the time under the pointer")
        XCTAssertEqual(a.contentWidth, 70 * a.pps, accuracy: 1e-6)
        a.reveal(85)
        XCTAssertGreaterThanOrEqual(a.x(85), 0); XCTAssertLessThanOrEqual(a.x(85), a.width)
        a.reveal(12)
        XCTAssertGreaterThanOrEqual(a.x(12), 0); XCTAssertLessThanOrEqual(a.x(12), a.width)
        a.fit()
        XCTAssertEqual(a.contentWidth, a.width, accuracy: 1e-6)
    }

    /// Items straddling a cut are drawn as their kept pieces, meeting at the seam; items inside one are not drawn.
    func testPiecesOfItemsAroundCuts() {
        let a = TimelineAxis(duration: 100, width: 1000, collapsed: [20...30, 50...60])
        XCTAssertEqual(a.pieces(10, 70), [10...20, 30...50, 60...70])
        XCTAssertEqual(a.pieces(22, 28), [], "a span inside removed footage has no pieces")
        XCTAssertEqual(a.pieces(25, 40), [30...40])
        XCTAssertEqual(a.pieces(0, 100).count, 3)
        let p = a.pieces(10, 70)
        XCTAssertEqual(a.x(p[0].upperBound), a.x(p[1].lowerBound), accuracy: 1e-9, "pieces meet at the seam")
        XCTAssertEqual(TimelineAxis(duration: 100, width: 1000).pieces(10, 70), [10...70], "nothing hidden: one piece")
    }

    func testNoThumbnailOrWaveformColumnStraddlesASeam() {
        var a = TimelineAxis(duration: 120, width: 1200, collapsed: [20.06...31.5, 50...60.3, 110...120])
        for zoom in [1.0, 3, 17] {
            a.fit(); a.zoom(by: zoom, anchorX: 400)
            let interval = FilmstripCache.interval(pps: a.pps)
            let slots = FilmstripCache.slots(a, interval: interval)
            XCTAssertFalse(slots.isEmpty)
            for s in slots {
                XCTAssertTrue(a.pieces(s.t0, s.t1) == [s.t0...s.t1], "slot \(s) lies in one piece of kept footage")
                XCTAssertFalse(a.isCollapsed(Double(s.key) / 1000), "slot \(s) shows a kept frame")
                XCTAssertGreaterThanOrEqual(Double(s.key) / 1000, s.t0 - Double(s.interval) / 1000)
                XCTAssertGreaterThanOrEqual(s.key, s.from)
            }
            for piece in a.pieces(a.visibleStart, a.visibleEnd) {
                for c in AudioLane.columns(a, piece, width: a.width) {
                    XCTAssertTrue(c.t0 >= piece.lowerBound - 1e-9 && c.t1 <= piece.upperBound + 1e-9, "column \(c) stays in its piece")
                }
            }
        }
    }

    /// The indexed mapping agrees with walking the ranges one by one, for many cuts, gaps and part-open ranges.
    func testIndexedMappingMatchesALinearWalk() {
        func naiveX(_ a: TimelineAxis, _ t: Double) -> Double {
            let s = a.pps
            var x = 0.0, last = 0.0
            for (i, r) in a.collapsed.enumerated() {
                if t <= r.lowerBound { break }
                x += (r.lowerBound - last) * s
                let w = a.gap + (r.upperBound - r.lowerBound) * s * (i < a.shown.count ? a.shown[i] : 0)
                if t < r.upperBound { return x + (t - r.lowerBound) / (r.upperBound - r.lowerBound) * w }
                x += w; last = r.upperBound
            }
            return x + (min(max(t, last), a.duration) - last) * s
        }
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<40 {
            var ranges: [ClosedRange<Double>] = [], t = 0.0
            while t < 590 {
                t += Double.random(in: 0.05...6, using: &rng)
                let len = Double.random(in: 0.02...4, using: &rng)
                if t + len < 600 { ranges.append(t...(t + len)) }
                t += len + (Bool.random(using: &rng) ? 0 : 0.5)   // some ranges touch
            }
            if trial % 3 == 0 { ranges.insert(0...0.02, at: 0); ranges[0] = 0...min(0.04, ranges.count > 1 ? ranges[1].lowerBound : 0.04) }
            let shown = trial % 2 == 0 ? [] : ranges.map { _ in Bool.random(using: &rng) ? 0 : Double.random(in: 0...1, using: &rng) }
            var a = TimelineAxis(duration: 600, width: 1400, collapsed: ranges, gap: trial % 4 == 1 ? 3 : 0, shown: shown)
            a.zoom(by: Double.random(in: 1...30, using: &rng), anchorX: 500)
            for _ in 0..<400 {
                let q = Double.random(in: -5...605, using: &rng)
                XCTAssertEqual(a.contentX(q), naiveX(a, q), accuracy: 1e-6, "trial \(trial) t \(q)")
                let x = a.contentX(q)
                XCTAssertEqual(a.contentX(a.time(atContentX: x)), x, accuracy: 1e-6, "x round trips")
                XCTAssertEqual(a.shownTime(a.sourceTime(shown: a.shownTime(q))), a.shownTime(q), accuracy: 1e-6)
            }
            if a.gap == 0 { XCTAssertEqual(a.contentWidth, a.shownDuration * a.pps, accuracy: 1e-6) }
        }
    }

    func testTransitionOpensAndClosesRanges() {
        let from = TimelineAxis(duration: 100, width: 1000, collapsed: [20...30])
        let to = TimelineAxis(duration: 100, width: 1000, collapsed: [20...30, 50...60])
        let start = from.transition(to: to, progress: 0), end = from.transition(to: to, progress: 1)
        for t in [10.0, 25, 40, 55, 70, 100] {
            XCTAssertEqual(start.contentX(t), from.contentX(t), accuracy: 1e-6, "progress 0 is the old layout")
            XCTAssertEqual(end.contentX(t), to.contentX(t), accuracy: 1e-6, "progress 1 is the new layout")
        }
        let mid = from.transition(to: to, progress: 0.5)
        XCTAssertEqual(mid.contentX(60) - mid.contentX(50), 5 * mid.pps, accuracy: 1e-6, "the closing range is half open")
        let merged = to.transition(to: TimelineAxis(duration: 100, width: 1000, collapsed: [20...60]), progress: 0)
        XCTAssertEqual(merged.contentX(70), to.contentX(70), accuracy: 1e-6, "a merge starts from the old layout")
    }
}

/// A 60 s project at 50 fps with three cuts, a leading one first: kept 5–20, 25–40, 45–60.
private func threeCuts(_ m: EditorModel) {
    m.update { $0.timeline.segments = [Segment(startMs: 5000, endMs: 20_000), Segment(startMs: 25_000, endMs: 40_000), Segment(startMs: 45_000, endMs: 60_000)] }
}

final class ExportTimeReadoutTests: XCTestCase {
    func testReadoutsCountKeptFootage() {
        let m = makeEditorModel(durationMs: 60_000, fps: 50)
        m.setTimelineWidth(900)
        threeCuts(m)
        XCTAssertTrue(m.hideRemoved, "removed footage is hidden by default")
        XCTAssertEqual(m.shownDuration, 45, accuracy: 1e-9, "the duration read-out is the export's length")
        XCTAssertEqual(m.axis.shownDuration, 45, accuracy: 1e-9, "so is the ruler's")
        XCTAssertEqual(m.axis.contentWidth, 900, accuracy: 1e-6)
        let map = TimeMap(segments: TimelineEdits.kept(m.project), sourceDurationMs: 60_000, frameMs: 20)
        for s in [5.0, 6, 19.98, 25, 30, 39.98, 45, 46, 59.98] {
            XCTAssertEqual(m.shownSeconds(s), map.timeline(fromSource: s * 1000)! / 1000, accuracy: 1e-9, "\(s) as exported")
            XCTAssertEqual(m.axis.shownTime(s), m.shownSeconds(s), accuracy: 1e-9, "ruler and read-outs agree at \(s)")
        }
        XCTAssertEqual(m.shownSeconds(2), 0, "the leading cut reads as the start")
        XCTAssertEqual(m.shownSeconds(22), 15, "inside a cut: the cut point")
        XCTAssertEqual(formatTimecode(m.shownSeconds(30), fps: 50), "0:20.00", "15 s kept before the second cut, then 5")
        XCTAssertEqual(formatTimecode(m.shownSeconds(46), fps: 50), "0:31.00")
        m.hideRemoved = false
        XCTAssertEqual(m.shownSeconds(30), 30, "Show removed reads the recording's clock")
        XCTAssertEqual(m.shownDuration, 60, accuracy: 1e-9)
        XCTAssertEqual(m.axis.shownDuration, 60, accuracy: 1e-9)
        XCTAssertEqual(m.axis.contentX(22), 22 * 15, accuracy: 1e-6, "at scale, hatched")
    }
}

final class RippleDeleteTests: XCTestCase {
    func testDeleteClosesTheGapAndUndoBringsSelectionAndPlayheadBack() {
        let m = makeEditorModel(durationMs: 10_000, fps: 50)
        m.setTimelineWidth(1000)
        m.seek(3); m.split(); m.seek(6); m.split()
        let middle = CutSection(startMs: 3000, endMs: 6000, kept: true)
        m.select(.section(middle)); m.seek(4.5)
        m.deleteSelection()
        XCTAssertEqual(TimelineEdits.sections(m.project).map(\.kept), [true, false, true])
        XCTAssertEqual(m.selection, .none, "the selection clears")
        XCTAssertEqual(m.time, 6, accuracy: 1e-9, "the playhead lands on the first kept frame after the cut")
        XCTAssertEqual(m.shownSeconds(m.time), 3, accuracy: 1e-9)
        XCTAssertEqual(m.axis.contentWidth, 1000, accuracy: 1e-6, "a fitted timeline stays fitted")
        XCTAssertEqual(m.axis.collapsed, [3...6])
        XCTAssertEqual(m.axis.x(3), m.axis.x(6), accuracy: 1e-9, "the gap is closed")
        XCTAssertEqual(m.undoTitle, "Undo Remove Section")
        m.undo()
        XCTAssertEqual(TimelineEdits.sections(m.project).map(\.kept), [true, true, true])
        XCTAssertEqual(m.selection, .section(middle), "undo restores the selection")
        XCTAssertEqual(m.time, 4.5, accuracy: 1e-9, "and the playhead")
        XCTAssertEqual(m.axis.collapsed, [], "and re-opens the gap")
        m.redo()
        XCTAssertEqual(m.selection, .none); XCTAssertEqual(m.time, 6, accuracy: 1e-9)
        XCTAssertEqual(m.axis.collapsed, [3...6])

        // Removing the last section: the playhead goes to the last kept frame.
        m.undo()
        m.select(.section(CutSection(startMs: 6000, endMs: 10_000, kept: true))); m.seek(8)
        m.deleteSelection()
        XCTAssertEqual(m.time, 5.98, accuracy: 1e-9, "nothing follows: the last kept frame")
        XCTAssertEqual(m.shownDuration, 6, accuracy: 1e-9)
    }

    func testRemovalAnimatesFromTheOldLayout() throws {
        try XCTSkipIf(DS.Motion.reduceMotion, "Reduce Motion: the layout changes without animating")
        let m = makeEditorModel(durationMs: 10_000, fps: 50)
        m.setTimelineWidth(1000)
        m.seek(3); m.split(); m.seek(6); m.split()
        let before = m.axis
        m.select(.section(CutSection(startMs: 3000, endMs: 6000, kept: true))); m.deleteSelection()
        let drawn = try XCTUnwrap(m.animatedAxis, "the gap closes over a short animation")
        XCTAssertEqual(drawn.contentX(6), before.contentX(6), accuracy: 1e-6, "it starts where the footage was")
        XCTAssertNotEqual(m.axis.contentX(6), before.contentX(6), "hit testing already uses the closed layout")
    }

    func testDeleteInShowRemovedKeepsTheOldBehaviour() {
        let m = makeEditorModel(durationMs: 10_000, fps: 50)
        m.hideRemoved = false
        m.seek(3); m.split(); m.seek(6); m.split()
        m.seek(4.5)
        m.deleteSelection()
        XCTAssertEqual(m.selection, .section(CutSection(startMs: 3000, endMs: 6000, kept: false)))
        XCTAssertEqual(m.time, 4.5, accuracy: 1e-9, "nothing moves in the hatched view")
        XCTAssertEqual(m.axis.collapsed, [])
    }
}

final class RippleSeamTests: XCTestCase {
    private func setUpSeam() -> (EditorModel, TimelineInteraction, TimelineLayout, Double) {
        let m = makeEditorModel(durationMs: 10_000, fps: 50)
        m.setTimelineWidth(1000)
        m.seek(3); m.split(); m.seek(6); m.split()
        m.select(.section(CutSection(startMs: 3000, endMs: 6000, kept: true))); m.deleteSelection()
        m.seek(0.5)
        let layout = TimelineLayout.make(hasMic: false)
        return (m, TimelineInteraction(model: m, layout: layout), layout, m.axis.x(3))
    }

    func testSeamNotchSelectsAndDeleteRestores() {
        let (m, ui, layout, seamX) = setUpSeam()
        let video = layout.lane(.video)!
        let removed = CutSection(startMs: 3000, endMs: 6000, kept: false)
        func hit(_ x: Double, _ y: Double) -> TimelineHit { TimelineHitTest.hit(x: x, y: y, layout: layout, axis: m.axis, project: m.project, selection: m.selection) }
        XCTAssertEqual(hit(seamX, video.y + 3), .seam(removed))
        XCTAssertEqual(hit(seamX + 4, video.y + 4), .seam(removed))
        XCTAssertEqual(TimelineInteraction.removedText(removed), "3.0 s removed")
        XCTAssertEqual(hit(seamX - 2, video.y + video.height / 2), .cut(CutBoundary(ms: 3000, left: 0, right: nil)), "just left: the left section's end")
        XCTAssertEqual(hit(seamX + 2, video.y + video.height / 2), .cut(CutBoundary(ms: 6000, left: nil, right: 1)), "just right: the right section's start")
        XCTAssertEqual(hit(seamX + 40, video.y + video.height / 2), .section(CutSection(startMs: 6000, endMs: 10_000, kept: true)))
        XCTAssertEqual(hit(999.9, video.y + video.height / 2), .section(CutSection(startMs: 6000, endMs: 10_000, kept: true)))
        ui.mouseDown(at: CGPoint(x: seamX, y: video.y + 3), clickCount: 1, flags: [])
        ui.mouseUp(at: CGPoint(x: seamX, y: video.y + 3))
        XCTAssertEqual(m.selection, .section(removed), "clicking the notch selects the removed section")
        m.deleteSelection()
        XCTAssertEqual(TimelineEdits.sections(m.project).map(\.kept), [true, true, true], "⌫ on a seam restores it")
        XCTAssertEqual(m.selection, .section(CutSection(startMs: 3000, endMs: 6000, kept: true)), "and selects it")
        XCTAssertEqual(m.axis.collapsed, [])
    }

    func testLeadingAndTrailingCutsHaveSeamsAtTheEnds() {
        let m = makeEditorModel(durationMs: 10_000, fps: 50)
        m.setTimelineWidth(1000)
        m.update { $0.timeline.segments = [Segment(startMs: 2000, endMs: 8000)] }
        let layout = TimelineLayout.make(hasMic: false)
        let video = layout.lane(.video)!
        XCTAssertEqual(m.axis.seams.map { $0.x }, [0, 1000])
        func hit(_ x: Double, _ y: Double) -> TimelineHit { TimelineHitTest.hit(x: x, y: y, layout: layout, axis: m.axis, project: m.project, selection: .none) }
        XCTAssertEqual(hit(1, video.y + 3), .seam(CutSection(startMs: 0, endMs: 2000, kept: false)))
        XCTAssertEqual(hit(999, video.y + 3), .seam(CutSection(startMs: 8000, endMs: 10_000, kept: false)))
        XCTAssertEqual(hit(2, video.y + 30), .cut(CutBoundary(ms: 2000, left: nil, right: 0)))
        XCTAssertEqual(hit(998, video.y + 30), .cut(CutBoundary(ms: 8000, left: 0, right: nil)))
    }

    /// The two coinciding edges at a seam each trim their own section; the layout holds still during the drag and
    /// lays out once on release.
    func testTrimmingEachEdgeAtASeam() {
        let (m, ui, layout, seamX) = setUpSeam()
        let y = layout.lane(.video)!.y + layout.lane(.video)!.height / 2
        func drag(_ from: Double, _ to: Double, check: (() -> Void)? = nil) {
            ui.mouseDown(at: CGPoint(x: from, y: y), clickCount: 1, flags: [])
            for i in 1...8 {
                ui.mouseDragged(to: CGPoint(x: from + (to - from) * Double(i) / 8, y: y), flags: [])
                if i == 4 { check?() }
            }
            ui.mouseUp(at: CGPoint(x: to, y: y))
        }
        let frozen = m.axis
        // Left of the seam, rightwards: the left section's end brings back a second of removed footage.
        // Grabbed 2 points left of the edge, released a second of footage (at the frozen scale) to its right.
        let pps = m.axis.pps
        drag(seamX - 2, seamX + pps) {
            XCTAssertNotNil(m.trimGhost, "the edge is drawn where it is dragged")
            XCTAssertEqual(m.axis, frozen, "the layout holds still under the pointer")
        }
        XCTAssertNil(m.trimGhost)
        XCTAssertEqual(TimelineEdits.kept(m.project).map(\.endMs).first ?? 0, 4000, accuracy: 20)
        XCTAssertEqual(TimelineEdits.kept(m.project)[1].startMs, 6000, "the right section is untouched")
        XCTAssertEqual(m.axis.collapsed.count, 1)
        XCTAssertEqual(m.axis.collapsed[0].lowerBound, 4, accuracy: 0.02, "laid out again on release")
        XCTAssertEqual(m.undoTitle, "Undo Trim")
        // Right of the seam, leftwards: the right section's start brings back half a second.
        let seam2 = m.axis.x(m.axis.collapsed[0].lowerBound)
        drag(seam2 + 2, seam2 - m.axis.pps / 2)
        XCTAssertEqual(TimelineEdits.kept(m.project)[1].startMs, 5500, accuracy: 20)
        XCTAssertEqual(TimelineEdits.kept(m.project)[0].endMs, 4000, accuracy: 20, "the left section is untouched")
        // Left of the seam, leftwards: removes more.
        let seam3 = m.axis.x(m.axis.collapsed[0].lowerBound)
        drag(seam3 - 2, seam3 - m.axis.pps * 1.5)
        XCTAssertEqual(TimelineEdits.kept(m.project)[0].endMs, 2500, accuracy: 20)
        m.undo(); m.undo(); m.undo()
        XCTAssertEqual(TimelineEdits.kept(m.project).map { [$0.startMs, $0.endMs] }, [[0, 3000], [6000, 10_000]], "each drag is one undo step")
    }
}

final class KeptPlayheadTests: XCTestCase {
    func testPlayheadNeverRestsInsideRemovedFootage() {
        let m = makeEditorModel(durationMs: 10_000, fps: 50)
        m.setTimelineWidth(1000)
        m.update { $0.timeline.segments = [Segment(startMs: 1000, endMs: 3000), Segment(startMs: 6000, endMs: 8000)] }
        let removed = TimelineEdits.removedRanges(m.project)
        func inside(_ t: Double) -> Bool { removed.contains { t * 1000 >= $0.startMs - 1e-6 && t * 1000 < $0.endMs - 1e-6 } }
        for i in 0...200 {
            m.seek(Double(i) * 0.05)
            XCTAssertFalse(inside(m.time), "seek \(Double(i) * 0.05) rests at \(m.time)")
        }
        m.seek(2.98)
        m.step(frames: 1); XCTAssertEqual(m.time, 6, accuracy: 1e-9, "a step across a seam: last kept frame before it to the first after")
        m.step(frames: -1); XCTAssertEqual(m.time, 2.98, accuracy: 1e-9)
        m.seek(0); XCTAssertEqual(m.time, 1, accuracy: 1e-9, "before the leading cut: the first kept frame")
        m.seek(9.5); XCTAssertEqual(m.time, 7.98, accuracy: 1e-9, "after the trailing cut: the last kept frame")
        m.seek(2.5); m.jump(seconds: 1)
        XCTAssertEqual(m.time, 6.5, accuracy: 1e-9, "a second of the timeline is a second of kept footage")
        m.jump(seconds: -1); XCTAssertEqual(m.time, 2.5, accuracy: 1e-9)
        for _ in 0..<300 { m.step(frames: 1); XCTAssertFalse(inside(m.time)) }
        // Scrubbing the ruler and clicking a lane.
        let layout = TimelineLayout.make(hasMic: false)
        let ui = TimelineInteraction(model: m, layout: layout)
        for x in stride(from: -10.0, through: 1010, by: 7) {
            ui.mouseDown(at: CGPoint(x: x, y: 4), clickCount: 1, flags: [.option]); ui.mouseUp(at: CGPoint(x: x, y: 4))
            XCTAssertFalse(inside(m.time), "ruler click at \(x) rests at \(m.time)")
        }
        // Jumps: edit points and markers inside removed footage land on the kept side.
        m.update { TimelineEdits.addMarker(&$0, atMs: 4500) }
        m.seek(1.5)
        m.jumpToEdit(forward: true); XCTAssertEqual(m.time, 6, accuracy: 1e-9, "the cut's two edges are one stop, on the kept side")
        m.jumpToEdit(forward: false); XCTAssertEqual(m.time, 2.98, accuracy: 1e-9)
        m.seek(1.5); m.nextMarker()
        XCTAssertEqual(m.time, 1.5, accuracy: 1e-9, "a marker in removed footage is not a stop")
        m.update { TimelineEdits.addMarker(&$0, atMs: 7000) }
        m.nextMarker(); XCTAssertEqual(m.time, 7, accuracy: 1e-9)
    }
}

final class ShowRemovedPreferenceTests: XCTestCase {
    func testDefaultHiddenAndPersisted() {
        let d = editorTestDefaults()
        let m = makeEditorModel(defaults: d)
        XCTAssertTrue(m.hideRemoved, "absent means hidden")
        XCTAssertNil(d.object(forKey: EditorModel.showRemovedKey))
        m.hideRemoved = false
        XCTAssertTrue(d.bool(forKey: "editorShowRemoved"))
        XCTAssertFalse(makeEditorModel(defaults: d).hideRemoved, "the next editor opens with removed footage shown")
        m.perform(.toggleRemoved)
        XCTAssertTrue(m.hideRemoved)
        XCTAssertNil(d.object(forKey: "editorShowRemoved"), "hiding again leaves the default")
        XCTAssertTrue(makeEditorModel(defaults: d).hideRemoved)
    }

    func testShortcutAndTooltipWording() {
        XCTAssertEqual(EditorShortcut.all.first { $0.command == .toggleRemoved }?.title, "Show removed footage, or hide it again")
        XCTAssertTrue(SectionInspector.keptNote(hideRemoved: true).contains("leaves the timeline"))
        XCTAssertFalse(SectionInspector.keptNote(hideRemoved: true).contains("hatched"), "the default view does not hatch")
        XCTAssertTrue(SectionInspector.keptNote(hideRemoved: false).contains("hatched"))
    }
}

/// Not a check: `EHDR_MAKE_FIXTURE=<folder> EHDR_FIXTURE_SECONDS=90 swift test --filter LongFixtureMaker` writes a
/// longer fixture recording (real time) for harness runs; the bundled `--make-fixture` one is two seconds.
final class LongFixtureMaker: XCTestCase {
    func testMakeLongFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["EHDR_MAKE_FIXTURE"] else { throw XCTSkip("set EHDR_MAKE_FIXTURE to write one") }
        let seconds = Int(env["EHDR_FIXTURE_SECONDS"] ?? "") ?? 60
        _ = try await FixtureProject.make(at: URL(fileURLWithPath: dir), frameCount: seconds * 60)
    }
}
