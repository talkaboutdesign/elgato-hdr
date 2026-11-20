import Foundation

/// What the inspector shows and ⌫ acts on.
enum TimelineSelection: Equatable {
    case none
    case section(CutSection)
    case scene(UUID?)       // a scene span; nil is the run before the first scene change
    case zoom(UUID)
    case marker(UUID)
    case layer(UUID)        // a layer of the scene at the playhead, picked in the preview or the layer list
}

enum LaneKind: Hashable { case ruler, scenes, zoom, video, gameAudio, micAudio }

/// Vertical arrangement of the lanes; drawing and hit-testing both read it.
struct TimelineLayout: Equatable {
    struct Lane: Equatable { let kind: LaneKind; let y: Double; let height: Double; let title: String; let symbol: String }
    let lanes: [Lane]
    let height: Double
    static let spacing = 4.0

    static func make(hasMic: Bool) -> TimelineLayout {
        var specs: [(LaneKind, Double, String, String)] = [
            (.ruler, 26, "", ""), (.scenes, 26, "Scenes", "rectangle.3.group"), (.zoom, 24, "Zoom", "plus.magnifyingglass"),
            (.video, 52, "Video", "film"), (.gameAudio, 32, "Game", "gamecontroller"),
        ]
        if hasMic { specs.append((.micAudio, 32, "Mic", "mic")) }
        var y = 0.0, lanes: [Lane] = []
        for (k, h, t, s) in specs { lanes.append(Lane(kind: k, y: y, height: h, title: t, symbol: s)); y += h + (k == .ruler ? 2 : spacing) }
        return TimelineLayout(lanes: lanes, height: y + 2)
    }
    func lane(_ k: LaneKind) -> Lane? { lanes.first { $0.kind == k } }
    func lane(atY y: Double) -> Lane? {
        lanes.first { y >= $0.y - Self.spacing / 2 && y < $0.y + $0.height + Self.spacing / 2 } ?? (y < 0 ? lanes.first : lanes.last)
    }
}

/// The thing under the pointer.
enum TimelineHit: Equatable {
    case ruler
    case marker(UUID)
    case sceneChange(UUID)              // the draggable start of a scene span
    case sceneRun(UUID?)
    case zoomEdge(UUID, leading: Bool)
    case zoom(UUID)
    case cut(CutBoundary)
    case seam(CutSection)               // the notch of a cut whose removed footage is hidden: the removed section
    case section(CutSection)
    case lane(LaneKind)
}

enum TimelineHitTest {
    static let edgeSlop = 5.0
    static let notchSlop = 7.0

    static func hit(x: Double, y: Double, layout: TimelineLayout, axis: TimelineAxis, project p: Project, selection: TimelineSelection) -> TimelineHit {
        guard let lane = layout.lane(atY: y) else { return .ruler }
        let t = axis.time(atX: x) * 1000
        func near(_ ms: Double, _ slop: Double = edgeSlop) -> Bool { abs(axis.x(ms / 1000) - x) <= slop }
        switch lane.kind {
        case .ruler:
            // Flags hang to the right of their time, in the lower half of the ruler.
            if y > lane.y + lane.height * 0.35,
               let m = p.timeline.markers.filter({ let mx = axis.x($0.tMs / 1000); return x >= mx - 4 && x <= mx + 12 })
                    .min(by: { abs(axis.x($0.tMs / 1000) - x) < abs(axis.x($1.tMs / 1000) - x) }) {
                return .marker(m.id)
            }
            return .ruler
        case .scenes:
            // A change whose span is all hidden footage is not drawn; the next visible one owns the seam.
            let shown = Set(TimelineEdits.sceneRuns(p).filter { !axis.pieces($0.startMs / 1000, $0.endMs / 1000).isEmpty }.compactMap { $0.span?.id })
            let changes = TimelineEdits.sortedSpans(p).filter { $0.startMs > 0 && shown.contains($0.id) && near($0.startMs) }
            if let c = changes.min(by: { abs(axis.x($0.startMs / 1000) - x) < abs(axis.x($1.startMs / 1000) - x) }) { return .sceneChange(c.id) }
            if let run = TimelineEdits.sceneRun(at: t, in: p) { return .sceneRun(run.span?.id) }
            return .lane(.scenes)
        case .zoom:
            // The selected block's handles win where two blocks touch.
            var zooms = p.timeline.zooms.filter { !axis.pieces($0.startMs / 1000, $0.endMs / 1000).isEmpty }
            if case .zoom(let id) = selection, let i = zooms.firstIndex(where: { $0.id == id }) { zooms.insert(zooms.remove(at: i), at: 0) }
            for z in zooms {
                let x0 = axis.x(z.startMs / 1000), x1 = axis.x(z.endMs / 1000)
                let slop = min(edgeSlop + 1, max(2, (x1 - x0) / 3))
                if abs(x - x0) <= slop { return .zoomEdge(z.id, leading: true) }
                if abs(x - x1) <= slop { return .zoomEdge(z.id, leading: false) }
            }
            if let z = zooms.first(where: { t >= $0.startMs && t < $0.endMs }) { return .zoom(z.id) }
            return .lane(.zoom)
        case .video:
            if y < lane.y + TimelineStyle.notchSize.height * 1.2 + 3,
               let seam = axis.visibleSeams().min(by: { abs($0.x - x) < abs($1.x - x) }), abs(seam.x - x) <= notchSlop,
               let s = TimelineEdits.sections(p).first(where: { !$0.kept && abs($0.startMs - seam.range.lowerBound * 1000) < 0.5 }) {
                return .seam(s)
            }
            // At a seam the end of the section on the left and the start of the one on the right share an x: the
            // side of the seam the pointer is on picks the edge.
            func distance(_ b: CutBoundary) -> Double {
                let bx: Double = axis.x(b.ms / 1000), d: Double = abs(bx - x)
                let atEnd: Bool = bx >= axis.contentWidth - axis.offset - 0.5, atStart: Bool = bx <= 0.5 - axis.offset
                let sideOK: Bool
                if b.left != nil && b.right != nil { sideOK = true }
                else if b.right == nil { sideOK = x < bx || atEnd }     // the end of the section on the left
                else { sideOK = x >= bx || atStart }                    // the start of the section on the right
                return sideOK ? d : d + edgeSlop * 4
            }
            let b = TimelineEdits.boundaries(p).filter { near($0.ms) }
            if let best = b.min(by: { distance($0) < distance($1) }) { return .cut(best) }
            if let s = TimelineEdits.section(at: t, in: p) {
                // Hidden removed footage has no width: the end of the timeline belongs to the last kept section.
                if !s.kept, axis.isCollapsed(t / 1000) || t / 1000 >= axis.duration - 1e-9,
                   let k = TimelineEdits.sections(p).last(where: { $0.kept && $0.endMs <= t + 0.5 }) { return .section(k) }
                return .section(s)
            }
            return .lane(.video)
        case .gameAudio, .micAudio:
            return .lane(lane.kind)
        }
    }
}
