import AppKit
import Foundation
import QuartzCore

// Timeline commands: the keyboard, the transport buttons, context menus and the debug harness all call these.
extension EditorModel {
    var playheadMs: Double { time * 1000 }

    // MARK: Cuts

    func split() {
        let t = playheadMs
        var did = false
        update("Split") { did = TimelineEdits.split(&$0, atMs: t) }
        if !did { NSSound.beep() }
    }

    /// ⌫: removes the selected section (or brings a removed one back), or deletes the selected scene change, zoom
    /// or marker. With nothing selected it acts on the section under the playhead and selects it, so a second ⌫
    /// undoes the removal in place.
    func deleteSelection() {
        switch selection {
        case .section(let s):
            if s.kept { update("Remove Section") { TimelineEdits.remove(&$0, section: s) } }
            else { update("Restore Section") { TimelineEdits.restore(&$0, section: s) } }
            selection = .section(CutSection(startMs: s.startMs, endMs: s.endMs, kept: !s.kept))
            validateSelection()
        case .scene(let id):
            guard let id = id else { NSSound.beep(); return }
            update("Delete Scene Change") { TimelineEdits.removeSceneChange(&$0, spanID: id) }
            selection = .none
        case .zoom(let id):
            update("Delete Zoom") { $0.timeline.zooms.removeAll { $0.id == id } }
            selection = .none
        case .marker(let id):
            update("Delete Marker") { $0.timeline.markers.removeAll { $0.id == id } }
            selection = .none
        case .none:
            guard let s = TimelineEdits.section(at: playheadMs, in: project) else { return }
            selection = .section(s)
            deleteSelection()
        }
    }

    func restoreSection(_ s: CutSection) {
        update("Restore Section") { TimelineEdits.restore(&$0, section: s) }
        selection = .section(CutSection(startMs: s.startMs, endMs: s.endMs, kept: true))
        validateSelection()
    }

    func setIn() { let t = playheadMs; update("Set In") { TimelineEdits.setIn(&$0, atMs: t) } }
    func setOut() { let t = playheadMs; update("Set Out") { TimelineEdits.setOut(&$0, atMs: t) } }
    func clearInOut() { update("Clear In and Out") { TimelineEdits.clearInOut(&$0) } }

    var keptDuration: Double { TimelineEdits.kept(project).reduce(0.0) { $0 + $1.endMs - $1.startMs } / 1000 }

    // MARK: Zoom

    func addZoom() {
        guard !editsLocked else { NSSound.beep(); return }
        let t = playheadMs
        var id: UUID?
        update("Add Zoom") { id = TimelineEdits.addZoom(&$0, atMs: t) }
        if let id = id { select(.zoom(id)) } else { NSSound.beep() }
    }

    func updateZoom(_ id: UUID, _ name: String = "Zoom", _ f: (inout ZoomBlock) -> Void) {
        update(name) { p in if let i = p.timeline.zooms.firstIndex(where: { $0.id == id }) { f(&p.timeline.zooms[i]) } }
    }
    func zoomBlock(_ id: UUID) -> ZoomBlock? { project.timeline.zooms.first { $0.id == id } }

    /// The preview parks where the block is fully zoomed, so adjusting it shows the result.
    func parkOnZoom(_ id: UUID) {
        guard let z = zoomBlock(id), !playing else { return }
        let ease = min(z.easeMs, (z.endMs - z.startMs) / 2)
        let full = (z.startMs + ease) / 1000 ... max((z.startMs + ease) / 1000, (z.endMs - ease) / 1000)
        if !full.contains(time) { seek((z.startMs + z.endMs) / 2000) }
    }

    // MARK: Scenes

    var sceneChoices: [SceneChoice] { TimelineEdits.sceneChoices(project, hasCamera: hasCamera) }

    /// ⌃1…⌃9: a change to the n-th scene of the picker at the playhead.
    func addSceneChange(index n: Int) {
        let choices = sceneChoices
        guard n >= 1, n <= choices.count else { NSSound.beep(); return }
        addSceneChange(choices[n - 1])
    }
    func addSceneChange(_ c: SceneChoice) {
        let t = playheadMs, cam = hasCamera
        var id: UUID?
        update("Add Scene Change") { p in
            let scene = TimelineEdits.materialize(c, in: &p, hasCamera: cam)
            id = TimelineEdits.insertSceneChange(&p, sceneID: scene, atMs: t)
        }
        if let id = id { selection = .scene(id) } else { NSSound.beep() }
    }

    func setScene(_ c: SceneChoice, for run: SceneRun) {
        let cam = hasCamera
        var spanID = run.span?.id
        update("Change Scene") { p in
            let scene = TimelineEdits.materialize(c, in: &p, hasCamera: cam)
            TimelineEdits.setScene(&p, run: run, sceneID: scene)
            if spanID == nil { spanID = TimelineEdits.sortedSpans(p).first?.id }
        }
        selection = .scene(spanID)
        validateSelection()
    }

    func selectedSceneRun() -> SceneRun? {
        guard case .scene(let id) = selection else { return nil }
        return TimelineEdits.sceneRuns(project).first { $0.span?.id == id }
    }

    /// Selecting a scene shows it: the playhead moves into the span past its transition.
    func parkOnScene(_ run: SceneRun) {
        guard !playing, !(time * 1000 >= run.startMs && time * 1000 < run.endMs) else { return }
        let into = min(run.endMs - 1, run.startMs + (run.span?.transition.durationMs ?? 0) + 200)
        seek(max(run.startMs, into) / 1000)
    }

    // MARK: Markers

    func addMarker() {
        let t = playheadMs
        var id = UUID()
        update("Add Marker") { id = TimelineEdits.addMarker(&$0, atMs: t) }
        selection = .marker(id)
    }
    func nextMarker() {
        guard let m = TimelineEdits.nextMarker(after: playheadMs, in: project) else { NSSound.beep(); return }
        if playing { pause() }
        seek(m.tMs / 1000); selection = .marker(m.id)
    }
    func previousMarker() {
        guard let m = TimelineEdits.previousMarker(before: playheadMs, in: project) else { NSSound.beep(); return }
        if playing { pause() }
        seek(m.tMs / 1000); selection = .marker(m.id)
    }
    func renameMarker(_ id: UUID, _ name: String) {
        update("Rename Marker") { p in if let i = p.timeline.markers.firstIndex(where: { $0.id == id }) { p.timeline.markers[i].label = name } }
    }
    func marker(_ id: UUID) -> Marker? { project.timeline.markers.first { $0.id == id } }

    /// 30 seconds around the marker become the exported range and the canvas switches to vertical.
    func makeShort(from id: UUID) {
        guard let m = marker(id) else { return }
        update("Make Short") { TimelineEdits.makeShort(&$0, aroundMs: m.tMs) }
        canvas = .vertical
        selection = .none
        if let first = TimelineEdits.kept(project).first { seek(first.startMs / 1000) }
        showToast(EditorToast(text: "Short ready to export", detail: "30 seconds around \(TimelineEdits.markerTitle(m, in: project)), vertical 9:16", style: .success))
    }

    // MARK: Selection and navigation

    func select(_ s: TimelineSelection) {
        selection = s
        switch s {
        case .zoom(let id): parkOnZoom(id)
        case .scene: if let run = selectedSceneRun() { parkOnScene(run) }
        default: break
        }
    }

    /// Drops a selection whose item no longer exists; a section follows its edges after cuts change.
    func validateSelection() {
        switch selection {
        case .none: return
        case .zoom(let id): if zoomBlock(id) == nil { selection = .none }
        case .marker(let id): if marker(id) == nil { selection = .none }
        case .scene(let id):
            if !TimelineEdits.sceneRuns(project).contains(where: { $0.span?.id == id }) { selection = .none }
        case .section(let s):
            let all = TimelineEdits.sections(project)
            if all.contains(s) { return }
            let mid = (s.startMs + s.endMs) / 2
            selection = all.first { mid >= $0.startMs && mid < $0.endMs }.map { .section($0) } ?? .none
        }
    }

    /// ↑ and ↓: the previous or next cut, scene change, zoom edge or marker.
    func jumpToEdit(forward: Bool) {
        let pts = TimelineEdits.editPoints(project) + [0, project.durationMs]
        let t = playheadMs, eps = frameDuration * 500
        let target = forward ? pts.filter { $0 > t + eps }.min() : pts.filter { $0 < t - eps }.max()
        guard let ms = target else { NSSound.beep(); return }
        if playing { pause() }
        seek(ms / 1000)
    }

    // MARK: Timeline view

    func setTimelineWidth(_ w: Double) {
        guard abs(axis.width - w) > 0.5 else { return }
        var a = axis; a.setWidth(w)
        axis = a
        if !timelineReady && w > 0 {
            timelineReady = true
            log(String(format: "editor: timeline laid out %.0f ms after opening", (CACurrentMediaTime() - openedAt) * 1000))
        }
    }
    func fitTimeline() { var a = axis; a.fit(); axis = a }
    /// = and -: zoom around the playhead when it is on screen, else around the middle.
    func zoomTimeline(in zoomIn: Bool) {
        var a = axis
        let px = a.x(time)
        a.zoom(by: zoomIn ? 1.6 : 1 / 1.6, anchorX: px >= 0 && px <= a.width ? px : a.width / 2)
        axis = a
    }
    func setZoomFraction(_ f: Double) {
        var a = axis
        let px = a.x(time)
        a.setZoomFraction(f, anchorX: px >= 0 && px <= a.width ? px : a.width / 2)
        axis = a
    }

    func updateCollapsed() {
        var a = axis
        a.collapsed = hideRemoved ? TimelineEdits.removedRanges(project).map { ($0.startMs / 1000)...($0.endMs / 1000) } : []
        a.clampOffset()
        if a != axis { axis = a }
    }
}
