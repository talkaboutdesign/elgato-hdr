import Foundation

// Pure edits on a Project in source milliseconds, shared by the editor's commands, timeline drags and tests.
// Times are snapped to source frames so a cut never lands between two frames.

/// A stretch of the recording between two cut points. Removed sections stay on screen, hatched.
struct CutSection: Equatable, Hashable {
    var startMs: Double
    var endMs: Double
    var kept: Bool
    var range: Segment { Segment(startMs: startMs, endMs: endMs) }
}

/// A draggable edge between two sections. `left`/`right` index the kept segment on that side (nil: removed).
struct CutBoundary: Equatable {
    var ms: Double
    var left: Int?
    var right: Int?
}

/// A span of the scene track. The run before the first scene change has no span of its own (`span == nil`) and
/// shows the project's first scene, exactly as `RenderPlan` resolves it.
struct SceneRun: Equatable {
    var span: SceneSpan?
    var sceneID: UUID?
    var startMs: Double
    var endMs: Double
}

/// What the scene picker offers: the project's scenes, then templates that are not in the project yet.
struct SceneChoice: Equatable, Identifiable {
    var name: String
    var sceneID: UUID?
    var template: LayoutKind?
    var id: String { sceneID?.uuidString ?? "template-\(name)" }
}

enum TimelineEdits {
    static func frameMs(_ p: Project) -> Double { 1000 / max(1, p.fps) }
    static func snapToFrame(_ ms: Double, _ p: Project) -> Double {
        let f = frameMs(p)
        return min(p.durationMs, max(0, (ms / f).rounded() * f))
    }

    // MARK: Cuts

    /// Kept ranges as stored, split points between touching ranges included. A legacy trim counts as one range.
    static func kept(_ p: Project) -> [Segment] {
        TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs, frameMs: frameMs(p), splitPoints: p.timeline.splitPoints).segments
    }

    /// Everything kept and unsplit is stored as `[]`; trim fields follow the kept bounds.
    static func store(_ segments: [Segment], in p: inout Project) {
        let d = p.durationMs
        let map = TimeMap(segments: segments.isEmpty ? [Segment(startMs: 0, endMs: 0)] : segments, sourceDurationMs: d, frameMs: frameMs(p), splitPoints: p.timeline.splitPoints)
        let clean = map.storedSegments
        let whole = clean.count == 1 && clean[0].startMs <= 0 && clean[0].endMs >= d
        p.timeline.splitPoints = map.splitPoints
        p.timeline.segments = whole ? [] : clean
        p.trimStartMs = p.timeline.segments.first?.startMs ?? 0
        p.trimEndMs = p.timeline.segments.last?.endMs ?? 0
    }

    /// The whole recording as alternating kept and removed sections.
    static func sections(_ p: Project) -> [CutSection] {
        var out: [CutSection] = [], t = 0.0
        for s in kept(p) {
            if s.startMs > t { out.append(CutSection(startMs: t, endMs: s.startMs, kept: false)) }
            out.append(CutSection(startMs: s.startMs, endMs: s.endMs, kept: true))
            t = s.endMs
        }
        if t < p.durationMs { out.append(CutSection(startMs: t, endMs: p.durationMs, kept: false)) }
        return out
    }
    static func section(at ms: Double, in p: Project) -> CutSection? {
        let all = sections(p)
        return all.first { ms >= $0.startMs && ms < $0.endMs } ?? (ms >= p.durationMs ? all.last : nil)
    }
    static func removedRanges(_ p: Project) -> [Segment] { sections(p).filter { !$0.kept }.map(\.range) }
    static func isKept(_ ms: Double, in p: Project) -> Bool { kept(p).contains { ms >= $0.startMs && ms < $0.endMs } }

    @discardableResult
    static func split(_ p: inout Project, atMs ms: Double) -> Bool {
        var map = TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs, frameMs: frameMs(p), splitPoints: p.timeline.splitPoints)
        let before = map.segments
        map.split(atSourceMs: snapToFrame(ms, p))
        guard map.segments != before else { return false }
        p.timeline.splitPoints = map.splitPoints
        store(map.segments, in: &p)
        return true
    }

    static func remove(_ p: inout Project, section s: CutSection) {
        var map = TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs, frameMs: frameMs(p), splitPoints: p.timeline.splitPoints)
        guard map.remove(sourceRange: s.range) else { return }
        p.timeline.splitPoints = map.splitPoints
        store(map.storedSegments, in: &p)
    }
    static func restore(_ p: inout Project, section s: CutSection) {
        var map = TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs, frameMs: frameMs(p), splitPoints: p.timeline.splitPoints)
        map.restore(sourceRange: s.range)
        p.timeline.splitPoints = map.splitPoints
        store(map.storedSegments, in: &p)
    }
    static func trim(_ p: inout Project, start: Double, end: Double) {
        p.timeline.segments = p.editSegments
        p.timeline = p.timeline.trimming(startMs: start, endMs: end, sourceDurationMs: p.durationMs, frameMs: frameMs(p))
        store(p.timeline.segments, in: &p)
    }
    static func setIn(_ p: inout Project, atMs ms: Double) { trim(&p, start: ms, end: kept(p).last?.endMs ?? p.durationMs) }
    static func setOut(_ p: inout Project, atMs ms: Double) { trim(&p, start: kept(p).first?.startMs ?? 0, end: ms) }
    static func clearInOut(_ p: inout Project) { trim(&p, start: 0, end: p.durationMs) }

    static func boundaries(_ p: Project) -> [CutBoundary] {
        let segs = kept(p), d = p.durationMs
        var out: [CutBoundary] = []
        for (i, s) in segs.enumerated() {
            if s.startMs > 0, !(i > 0 && segs[i - 1].endMs == s.startMs) {
                out.append(CutBoundary(ms: s.startMs, left: nil, right: i))
            }
            if s.endMs < d {
                let touching = i + 1 < segs.count && segs[i + 1].startMs == s.endMs
                out.append(CutBoundary(ms: s.endMs, left: i, right: touching ? i + 1 : nil))
            }
        }
        return out
    }

    /// Drags one boundary. `original` is the kept list when the drag began, so the result never accumulates error.
    static func move(_ b: CutBoundary, to ms: Double, original: [Segment], in p: inout Project) {
        var segs = original
        let f = frameMs(p)
        var lo = 0.0, hi = p.durationMs
        if let l = b.left { lo = segs[l].startMs + f } else if let r = b.right, r > 0 { lo = segs[r - 1].endMs }
        if let r = b.right { hi = segs[r].endMs - f } else if let l = b.left, l + 1 < segs.count { hi = segs[l + 1].startMs }
        guard hi >= lo else { return }
        let t = min(hi, max(lo, snapToFrame(ms, p)))
        if let l = b.left { segs[l].endMs = t }
        if let r = b.right { segs[r].startMs = t }
        p.timeline.splitPoints.removeAll { abs($0 - b.ms) < 0.001 }
        if b.left != nil && b.right != nil { p.timeline.splitPoints.append(t) }
        store(segs, in: &p)
    }

    // MARK: Scenes

    static let templates: [(name: String, kind: LayoutKind, camera: Bool)] = [
        ("Gameplay", .screenOnly, false), ("Camera Focus", .cameraOnly, true), ("Split", .stacked, true), ("Picture in Picture", .pip, true),
    ]

    static func sortedSpans(_ p: Project) -> [SceneSpan] {
        p.timeline.sceneSpans.filter { s in p.scenes.contains { $0.id == s.sceneID } }.sorted { $0.startMs < $1.startMs }
    }

    static func sceneRuns(_ p: Project) -> [SceneRun] {
        let spans = sortedSpans(p), d = p.durationMs
        var out: [SceneRun] = []
        if spans.first.map({ $0.startMs > 0 }) ?? true {
            out.append(SceneRun(span: nil, sceneID: p.scenes.first?.id, startMs: 0, endMs: spans.first?.startMs ?? d))
        }
        for (i, s) in spans.enumerated() {
            out.append(SceneRun(span: s, sceneID: s.sceneID, startMs: s.startMs, endMs: i + 1 < spans.count ? spans[i + 1].startMs : d))
        }
        return out.filter { $0.endMs > $0.startMs || $0.span != nil }
    }
    static func sceneRun(at ms: Double, in p: Project) -> SceneRun? {
        let runs = sceneRuns(p)
        return runs.last { $0.startMs <= ms } ?? runs.first
    }
    static func sceneName(_ id: UUID?, in p: Project) -> String { p.scenes.first { $0.id == id }?.name ?? "Default" }

    /// Stable order, so ⌃1…⌃9 keep meaning the same scene: the project's own scenes, then the templates in a fixed
    /// order (a template already added to the project stands for that scene).
    static func sceneChoices(_ p: Project, hasCamera: Bool) -> [SceneChoice] {
        let names = Set(templates.map(\.name))
        var out = p.scenes.filter { !names.contains($0.name) }.map { SceneChoice(name: $0.name, sceneID: $0.id, template: nil) }
        if out.isEmpty && p.scenes.isEmpty { out = [SceneChoice(name: "Default", sceneID: nil, template: nil)] }
        for t in templates {
            if let s = p.scenes.first(where: { $0.name == t.name }) { out.append(SceneChoice(name: s.name, sceneID: s.id, template: nil)) }
            else if hasCamera || !t.camera { out.append(SceneChoice(name: t.name, sceneID: nil, template: t.kind)) }
        }
        return out
    }

    /// A template becomes a project scene built from the project's own layouts (framing, camera placement).
    static func materialize(_ c: SceneChoice, in p: inout Project, hasCamera: Bool) -> UUID {
        if let id = c.sceneID { return id }
        guard let kind = c.template else { return p.scenes[0].id }
        if let existing = p.scenes.first(where: { $0.name == c.name }) { return existing.id }
        var w = p.wide, v = p.vertical
        w.kind = kind; v.kind = kind
        let scene = Scene(name: c.name,
                          wide: .from(layout: w, canvas: Canvas.wide.size(.hd), hasCamera: hasCamera, mirror: p.cameraMirror),
                          vertical: .from(layout: v, canvas: Canvas.vertical.size(.hd), hasCamera: hasCamera, mirror: p.cameraMirror))
        p.scenes.append(scene)
        return scene.id
    }

    /// A scene change at `ms`. Replaces a change already there; does nothing if that scene is already showing.
    @discardableResult
    static func insertSceneChange(_ p: inout Project, sceneID: UUID, atMs ms: Double) -> UUID? {
        let t = snapToFrame(ms, p), f = frameMs(p)
        if p.timeline.sceneSpans.isEmpty || sortedSpans(p).isEmpty {
            p.timeline.sceneSpans = [SceneSpan(startMs: 0, sceneID: p.scenes[0].id)]
        }
        if let i = p.timeline.sceneSpans.firstIndex(where: { abs($0.startMs - t) < f / 2 }) {
            p.timeline.sceneSpans[i].sceneID = sceneID
            return p.timeline.sceneSpans[i].id
        }
        if sceneRun(at: t, in: p)?.sceneID == sceneID { return nil }
        let span = SceneSpan(startMs: t, sceneID: sceneID)
        p.timeline.sceneSpans.append(span)
        p.timeline.sceneSpans.sort { $0.startMs < $1.startMs }
        return span.id
    }

    /// Sets the scene of a run; the leading run gets a span of its own at zero.
    static func setScene(_ p: inout Project, run: SceneRun, sceneID: UUID) {
        if let span = run.span, let i = p.timeline.sceneSpans.firstIndex(where: { $0.id == span.id }) {
            p.timeline.sceneSpans[i].sceneID = sceneID
        } else {
            p.timeline.sceneSpans.insert(SceneSpan(startMs: 0, sceneID: sceneID), at: 0)
        }
    }

    static func setTransition(_ p: inout Project, spanID: UUID, _ t: SceneTransition) {
        if let i = p.timeline.sceneSpans.firstIndex(where: { $0.id == spanID }) { p.timeline.sceneSpans[i].transition = t }
    }

    /// Retimes a scene change between its neighbours (at least two frames from each).
    static func moveSceneChange(_ p: inout Project, spanID: UUID, toMs ms: Double) {
        let spans = sortedSpans(p)
        guard let k = spans.firstIndex(where: { $0.id == spanID }), spans[k].startMs > 0 || k > 0,
              let i = p.timeline.sceneSpans.firstIndex(where: { $0.id == spanID }) else { return }
        let f = frameMs(p) * 2
        let lo = k > 0 ? spans[k - 1].startMs + f : f
        let hi = k + 1 < spans.count ? spans[k + 1].startMs - f : p.durationMs - f
        guard hi >= lo else { return }
        p.timeline.sceneSpans[i].startMs = min(hi, max(lo, snapToFrame(ms, p)))
    }

    static func removeSceneChange(_ p: inout Project, spanID: UUID) {
        p.timeline.sceneSpans.removeAll { $0.id == spanID }
    }

    // MARK: Zoom blocks

    static let defaultZoomMs = 3000.0, minZoomMs = 300.0

    /// A block at `ms`; inside an existing block it returns that one. Never overlaps the next block.
    static func addZoom(_ p: inout Project, atMs ms: Double, lengthMs: Double = defaultZoomMs) -> UUID? {
        let t = snapToFrame(ms, p)
        if let z = p.timeline.zooms.first(where: { t >= $0.startMs && t < $0.endMs }) { return z.id }
        let next = p.timeline.zooms.filter { $0.startMs > t }.map(\.startMs).min() ?? p.durationMs
        var start = t, end = min(next, t + lengthMs)
        if end - start < minZoomMs {
            let prev = p.timeline.zooms.filter { $0.endMs <= t }.map(\.endMs).max() ?? 0
            start = max(prev, end - lengthMs); end = min(next, max(end, start + minZoomMs))
        }
        guard end - start >= minZoomMs else { return nil }
        let z = ZoomBlock(startMs: start, endMs: end)
        p.timeline.zooms.append(z)
        p.timeline.zooms.sort { $0.startMs < $1.startMs }
        return z.id
    }

    /// Room a block may occupy without overlapping its neighbours.
    static func zoomRoom(_ p: Project, id: UUID) -> (lo: Double, hi: Double) {
        guard let z = p.timeline.zooms.first(where: { $0.id == id }) else { return (0, p.durationMs) }
        let others = p.timeline.zooms.filter { $0.id != id }
        let lo = others.filter { $0.endMs <= z.startMs + 0.001 }.map(\.endMs).max() ?? 0
        let hi = others.filter { $0.startMs >= z.endMs - 0.001 }.map(\.startMs).min() ?? p.durationMs
        return (lo, hi)
    }

    /// Moves a block, keeping its length, from where it was when the drag began.
    static func moveZoom(_ p: inout Project, id: UUID, original: ZoomBlock, byMs delta: Double, room: (lo: Double, hi: Double)) {
        guard let i = p.timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
        let len = original.endMs - original.startMs
        let start = min(room.hi - len, max(room.lo, snapToFrame(original.startMs + delta, p)))
        p.timeline.zooms[i].startMs = start
        p.timeline.zooms[i].endMs = start + len
    }

    static func resizeZoom(_ p: inout Project, id: UUID, leading: Bool, toMs ms: Double, room: (lo: Double, hi: Double)) {
        guard let i = p.timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
        let z = p.timeline.zooms[i], t = snapToFrame(ms, p)
        if leading { p.timeline.zooms[i].startMs = min(z.endMs - minZoomMs, max(room.lo, t)) }
        else { p.timeline.zooms[i].endMs = max(z.startMs + minZoomMs, min(room.hi, t)) }
    }

    // MARK: Markers

    @discardableResult
    static func addMarker(_ p: inout Project, atMs ms: Double) -> UUID {
        let t = snapToFrame(ms, p)
        if let m = p.timeline.markers.first(where: { abs($0.tMs - t) < frameMs(p) / 2 }) { return m.id }
        let m = Marker(tMs: t)
        p.timeline.markers.append(m)
        p.timeline.markers.sort { $0.tMs < $1.tMs }
        return m.id
    }
    static func nextMarker(after ms: Double, in p: Project) -> Marker? {
        p.timeline.markers.filter { $0.tMs > ms + 0.5 }.min { $0.tMs < $1.tMs }
    }
    static func previousMarker(before ms: Double, in p: Project) -> Marker? {
        p.timeline.markers.filter { $0.tMs < ms - 0.5 }.max { $0.tMs < $1.tMs }
    }
    static func markerTitle(_ m: Marker, in p: Project) -> String {
        if !m.label.isEmpty { return m.label }
        let i = p.timeline.markers.sorted { $0.tMs < $1.tMs }.firstIndex { $0.id == m.id } ?? 0
        return "Marker \(i + 1)"
    }

    /// "Make short from marker": 30 seconds around it become the exported range, keeping cuts inside it.
    static func makeShort(_ p: inout Project, aroundMs ms: Double, lengthMs: Double = 30_000) {
        var a = max(0, ms - lengthMs / 2), b = min(p.durationMs, a + lengthMs)
        a = max(0, b - lengthMs)
        setIn(&p, atMs: a); setOut(&p, atMs: b)
    }

    /// Edit points for ↑/↓ navigation and snapping: cuts, scene changes, zoom edges, markers.
    static func editPoints(_ p: Project) -> [Double] {
        var pts = boundaries(p).map(\.ms)
        pts += sortedSpans(p).map(\.startMs)
        pts += p.timeline.zooms.flatMap { [$0.startMs, $0.endMs] }
        pts += p.timeline.markers.map(\.tMs)
        return Array(Set(pts)).sorted()
    }
}

/// Pulls a dragged time onto the nearest candidate within a tolerance.
enum Snapping {
    static func snap(_ t: Double, to candidates: [Double], tolerance: Double) -> (value: Double, target: Double?) {
        guard let best = candidates.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= tolerance else { return (t, nil) }
        return (best, best)
    }
}
