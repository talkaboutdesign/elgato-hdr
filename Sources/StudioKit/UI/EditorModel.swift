import AppKit
import AVFoundation
import Observation
import QuartzCore
import SwiftUI

// MARK: - Editor model

/// One open project. `@Observable` tracks reads per property, so the 60 Hz playhead re-renders the playhead and the
/// time read-out only, never the inspector or the timeline lanes. Main thread only.
@Observable
final class EditorModel {
    @ObservationIgnored let doc: ProjectDoc
    private(set) var project: Project
    var canvas: Canvas = .wide { didSet { if canvas != oldValue { rebuild() } } }
    /// Preview colour: HDR for HDR sources unless the user previews the SDR (Shorts) look.
    var range: ExportRange { didSet { if range != oldValue { rebuild() } } }
    var time = 0.0                  // playhead, source seconds (the preview is untrimmed: player time is source time)
    var duration = 0.0
    var playing = false
    var shuttleRate: Float = 0
    var loadError: String?
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
    // timeline
    var selection: TimelineSelection = .none
    var axis = TimelineAxis()
    var hideRemoved = false { didSet { if hideRemoved != oldValue { updateCollapsed() } } }
    var hover: TimelineHit?
    var snapGuide: Double?          // seconds; shown while a drag sits on a snap point
    var toast: EditorToast?
    var timelineReady = false
    var previewRevision = 0         // bumped when the preview's composition changes

    @ObservationIgnored let player = AVPlayer()
    /// Owned by the model rather than the window, so the history goes away with the project and the same editor can
    /// live in its own window or inside the library window. Grouping is explicit: one group per edit or gesture.
    @ObservationIgnored let undoManager: UndoManager = {
        let u = UndoManager(); u.groupsByEvent = false; u.levelsOfUndo = 200; return u
    }()
    /// Text fields (names) keep their own typing history: AppKit's field editor registers undo without opening a
    /// group, which the explicitly grouped project history above would reject.
    @ObservationIgnored let textUndoManager = UndoManager()
    @ObservationIgnored let filmstrip: FilmstripCache
    @ObservationIgnored let waveforms: WaveformCache
    @ObservationIgnored var exportQueue: ExportQueue!
    @ObservationIgnored let openedAt = CACurrentMediaTime()
    @ObservationIgnored private var built: BuiltComposition?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored var boundaryObserver: Any?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var buildGen = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var restylePending = false
    @ObservationIgnored private var closed = false
    /// The project as it was when a continuous gesture (drag, slider) began; the gesture becomes one undo step.
    @ObservationIgnored private var gestureBase: Project?
    @ObservationIgnored private var gestureName = ""
    @ObservationIgnored private var rebuildAfterGesture = false
    // seeking: one seek in flight, only the latest target remembered
    @ObservationIgnored var seekInFlight = false
    @ObservationIgnored var pendingSeek: CMTime?
    @ObservationIgnored var seekStats = SeekStats()
    @ObservationIgnored var scrubStats = SeekStats()
    @ObservationIgnored var exactStats = SeekStats()
    @ObservationIgnored var pendingFast = false
    @ObservationIgnored var settling = false
    @ObservationIgnored var settleWork: DispatchWorkItem?
    @ObservationIgnored var scrubbing = false
    @ObservationIgnored var reverseTimer: Timer?

    var hasCamera: Bool { doc.hasCamera }
    var hasMic: Bool { doc.hasMic }
    var isHDRSource: Bool { project.color != .sdr }
    var editsLocked: Bool { exportQueue?.isRunning ?? false }
    var frameDuration: Double { 1 / max(1, project.fps) }

    init(doc: ProjectDoc) {
        self.doc = doc
        project = doc.project
        range = doc.project.color == .sdr ? .sdr : .hdr
        filmstrip = FilmstripCache(doc: doc)
        waveforms = WaveformCache(doc: doc)
        duration = doc.project.durationMs / 1000
        axis.duration = duration
        exportQueue = ExportQueue { [weak doc] job in
            guard let doc = doc else { throw CompositionBuilder.err("project closed") }
            return Exporter(doc: doc, job: job)
        }
        exportQueue.onFinished = { [weak self] item in self?.exportFinished(item) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            self?.playerTimeChanged(t.seconds)
        }
        rebuild()
        waveforms.load(game: true, mic: doc.hasMic)
    }

    func close() {
        guard !closed else { return }
        closed = true
        player.pause()
        reverseTimer?.invalidate()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let o = boundaryObserver { player.removeTimeObserver(o); boundaryObserver = nil }
        exportQueue.cancelAll()
        filmstrip.cancel(); waveforms.cancel()
        endGesture()
        saveNow()
        undoManager.removeAllActions()
        if seekStats.count > 0 { log("editor: \(seekStats.summary) over the session") }
        if dirty { Task { await doc.writeThumbnail(); await MainActor.run { Library.shared.objectWillChange.send() } } }
    }

    // MARK: Edits and undo

    /// Every edit goes through here. Outside a gesture each call is one undo step; inside one, the whole gesture is.
    /// While an export queue runs, the project is frozen: queued jobs export what was there when they were queued.
    func update(_ name: String = "Edit", _ f: (inout Project) -> Void) {
        guard !editsLocked else { NSSound.beep(); return }
        let old = project
        var p = project; f(&p)
        syncDerived(&p, from: old)
        guard p != old else { return }
        if gestureBase == nil { registerUndo(restoring: old, name: name) } else { gestureName = name }
        apply(p, from: old)
    }

    /// A timeline drag update: the edit applied to the timeline as it was when the gesture began, never on top of the
    /// previous update, so intermediate positions cannot leave anything behind (a dragged split stays one split).
    func updateDrag(_ name: String, _ f: (inout Project) -> Void) {
        let base = gestureBase
        update(name) { p in
            if let b = base { p.timeline = b.timeline; p.trimStartMs = b.trimStartMs; p.trimEndMs = b.trimEndMs }
            f(&p)
        }
    }

    /// Starts coalescing edits into one undo step (drag began, slider grabbed).
    func beginGesture() { if gestureBase == nil { gestureBase = project; gestureName = "Edit" } }
    func endGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        if base != project { registerUndo(restoring: base, name: gestureName) }
        if rebuildAfterGesture { rebuildAfterGesture = false; rebuild() }
    }
    var inGesture: Bool { gestureBase != nil }
    /// For `Slider(onEditingChanged:)`.
    func gesture(_ editing: Bool) { editing ? beginGesture() : endGesture() }

    func undo() { guard !editsLocked else { return }; endGesture(); if undoManager.canUndo { undoManager.undo() }; refreshUndoState() }
    func redo() { guard !editsLocked else { return }; endGesture(); if undoManager.canRedo { undoManager.redo() }; refreshUndoState() }

    private func registerUndo(restoring old: Project, name: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.revert(to: old, name: name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        refreshUndoState()
    }

    /// Undo and redo swap whole project values; registering the current one here becomes the opposite step.
    private func revert(to p: Project, name: String) {
        let current = project
        undoManager.registerUndo(withTarget: self) { $0.revert(to: current, name: name) }
        undoManager.setActionName(name)
        var restored = p
        restored.lastExport = current.lastExport   // export history is not an edit
        apply(restored, from: current)
        DispatchQueue.main.async { [weak self] in self?.refreshUndoState() }
    }

    /// What a window hosting this editor answers for ⌘Z: the project, or the focused text field's own history.
    func undoManager(for window: NSWindow) -> UndoManager? {
        if window.firstResponder is NSText { return textUndoManager }
        return editsLocked ? nil : undoManager
    }

    func refreshUndoState() {
        let u = undoManager
        let can = u.canUndo && !editsLocked, canR = u.canRedo && !editsLocked
        if canUndo != can { canUndo = can }
        if canRedo != canR { canRedo = canR }
        let ut = u.canUndo ? u.undoMenuItemTitle : "Undo", rt = u.canRedo ? u.redoMenuItemTitle : "Redo"
        if undoTitle != ut { undoTitle = ut }
        if redoTitle != rt { redoTitle = rt }
    }

    /// Camera mirroring applies to every scene. (Layout controls edit the active scene directly: `layout`.)
    private func syncDerived(_ p: inout Project, from old: Project) {
        if p.timeline.segments == old.timeline.segments && (p.trimStartMs != old.trimStartMs || p.trimEndMs != old.trimEndMs) {
            p.timeline = old.timeline.trimming(startMs: p.trimStartMs, endMs: p.trimmedRange.1, sourceDurationMs: p.durationMs, frameMs: 1000 / max(1, p.fps))
        }
        if let first = p.timeline.segments.first, let last = p.timeline.segments.last { p.trimStartMs = first.startMs; p.trimEndMs = last.endMs }
        if p.cameraMirror != old.cameraMirror {
            for i in p.scenes.indices {
                for j in p.scenes[i].wide.layers.indices where p.scenes[i].wide.layers[j].source.type == "camera" { p.scenes[i].wide.layers[j].mirror = p.cameraMirror }
                for j in p.scenes[i].vertical.layers.indices where p.scenes[i].vertical.layers[j].source.type == "camera" { p.scenes[i].vertical.layers[j].mirror = p.cameraMirror }
            }
        }
    }

    private func apply(_ p: Project, from old: Project) {
        project = p
        doc.project = p
        dirty = true
        scheduleSave()
        // The preview plays the uncut source, so only layer changes reload the composition. Its render instruction
        // knows the cuts (a transition ends at a cut, as in the export), so a cut edit swaps the instruction.
        if p.game != old.game || p.camera != old.camera || p.mic != old.mic {
            // Reloading the layers mid-drag stalls the preview: the lanes follow live, the composition once at the end.
            if gestureBase != nil { rebuildAfterGesture = true } else { rebuild() }
        } else if p.wide != old.wide || p.vertical != old.vertical || p.cameraMirror != old.cameraMirror || p.scenes != old.scenes
                    || p.timeline.sceneSpans != old.timeline.sceneSpans || p.timeline.zooms != old.timeline.zooms
                    || p.editSegments != old.editSegments {
            restyle()
        }
        if p.editSegments != old.editSegments || p.durationMs != old.durationMs {
            applyPlaybackBounds()
            updateCollapsed()
        }
        validateSelection()
    }

    /// The fixed layout of the active scene when it was migrated from one (`sceneControls.legacy`). Setting it
    /// regenerates that scene's layers from the layout; on any other scene it does nothing: a scene built from layers
    /// is edited through `updateSceneLayer` and is never replaced by the project's default layout.
    var layout: CanvasLayout {
        get { activeScene?.composition(canvas).legacyLayout ?? project.layout(canvas) }
        set {
            let c = canvas
            guard let i = activeSceneIndex else { update("Layout") { $0.setLayout(c, newValue) }; return }
            guard let current = project.scenes[i].composition(c).legacyLayout, current != newValue else { return }
            update("Layout") { p in
                var comp = Composition.from(layout: newValue, canvas: c.size(.hd), hasCamera: true, mirror: p.cameraMirror)
                comp.legacyLayout = newValue
                comp.background = p.scenes[i].composition(c).background
                if c == .wide { p.scenes[i].wide = comp } else { p.scenes[i].vertical = comp }
                // The project's own layouts follow, for templates made later and for older app versions.
                p.setLayout(c, newValue)
            }
        }
    }
    func binding<T>(_ kp: WritableKeyPath<CanvasLayout, T>) -> Binding<T> {
        Binding(get: { self.layout[keyPath: kp] }, set: { v in var l = self.layout; l[keyPath: kp] = v; self.layout = l })
    }
    func projectBinding<T>(_ kp: WritableKeyPath<Project, T>, _ name: String = "Edit") -> Binding<T> {
        Binding(get: { self.project[keyPath: kp] }, set: { v in self.update(name) { $0[keyPath: kp] = v } })
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    func saveNow() { saveWork?.cancel(); saveWork = nil; doc.project = project; doc.save() }

    /// Bookkeeping that is not an edit (export history): no undo step, allowed while exporting.
    func setSilently(_ f: (inout Project) -> Void) {
        var p = project; f(&p)
        guard p != project else { return }
        project = p; doc.project = p; saveNow()
    }

    // MARK: Preview

    /// Rebuilds the composition (layers, offsets, volumes) for the current canvas. The preview is untrimmed, so
    /// player time is source time and removed sections can still be scrubbed; playback skips them.
    func rebuild() {
        buildGen += 1
        let gen = buildGen, canvas = canvas, range = range
        let started = CACurrentMediaTime()
        Task {
            do {
                let b = try await CompositionBuilder.build(doc, canvas: canvas, resolution: .hd, range: range, ignoreCuts: true)
                await MainActor.run {
                    guard gen == self.buildGen, !self.closed else { return }
                    self.built = b
                    let item = AVPlayerItem(asset: b.asset)
                    // A scene or zoom edit can arrive while track loading is suspended.
                    item.videoComposition = CompositionBuilder.videoComposition(self.project, canvas: canvas, size: canvas.size(.hd), built: b)
                    item.audioMix = b.audioMix
                    self.player.replaceCurrentItem(with: item)
                    self.previewRevision += 1
                    let d = b.duration.seconds
                    if abs(d - self.duration) > 0.0005 { self.duration = d }
                    if self.axis.duration != d { self.axis.duration = d; self.axis.clampOffset() }
                    self.applyPlaybackBounds()
                    // The playhead is the model's: it may have moved while the layers loaded (Make Short seeks, then
                    // switches canvas). A first load starts at the first kept frame.
                    let start = TimelineEdits.kept(self.project).first.map { $0.startMs / 1000 } ?? 0
                    if gen == 1 && self.time == 0 { self.time = start }
                    self.requestSeek(CMTime(seconds: self.time, preferredTimescale: 60000))
                    self.loadError = nil
                    if gen == 1 { log(String(format: "editor: preview ready in %.0f ms (%@)", (CACurrentMediaTime() - started) * 1000, self.doc.dir.lastPathComponent)) }
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    /// Layout-only change: swap the render instruction, at most once per run-loop pass while dragging.
    private func restyle() {
        guard !restylePending else { return }
        restylePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.restylePending = false
            guard let b = self.built, let item = self.player.currentItem else { return }
            item.videoComposition = CompositionBuilder.videoComposition(self.project, canvas: self.canvas, size: self.canvas.size(.hd), built: b)
            self.previewRevision += 1
            if self.player.rate == 0 { self.requestSeek(CMTime(seconds: self.time, preferredTimescale: 60000)) }
        }
    }

    /// A RenderPlan at the playhead's canvas, for overlays that must line up with the rendered picture.
    func renderPlan(size: CGSize) -> RenderPlan {
        var sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: gameSize)]
        if let c = built?.cameraSize { sources[.camera] = SourceInfo(size: c) }
        let sourceMs = built?.sourceDurationMs ?? project.durationMs, frameMs = built?.sourceFrameMs ?? 1000 / max(1, project.fps)
        var plan = RenderPlan(scenes: project.scenes.isEmpty ? [project.defaultScene] : project.scenes, timeline: project.timeline,
                          map: TimeMap(segments: [], sourceDurationMs: sourceMs, frameMs: frameMs), canvas: canvas, canvasSize: size,
                          sources: sources, mirrorCamera: project.cameraMirror,
                          cuts: CompositionBuilder.editMap(project, sourceDurationMs: sourceMs, frameMs: frameMs))
        if let built, let track = built.asset.track(withTrackID: built.cameraTrack) {
            plan.cameraRanges = track.segments.filter { !$0.isEmpty }.map {
                Segment(startMs: $0.timeMapping.target.start.seconds * 1000, endMs: $0.timeMapping.target.end.seconds * 1000)
            }
        }
        return plan
    }
    var gameSize: CGSize { built?.screenSize ?? (project.width > 0 ? CGSize(width: project.width, height: project.height) : CGSize(width: 1920, height: 1080)) }

    // MARK: Messages

    func showToast(_ t: EditorToast, seconds: Double = 4) {
        withAnimation(DS.Motion.gentle) { toast = t }
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.toast?.id == t.id else { return }
            withAnimation(DS.Motion.gentle) { self.toast = nil }
        }
    }
}

/// Transient message at the bottom of the preview. An export result carries its file for Show in Finder and drag.
struct EditorToast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var detail: String? = nil
    var style: Toast.Style = .info
    var file: URL? = nil
}

/// Seek latency, logged so scrubbing responsiveness can be checked without a screen.
struct SeekStats {
    var count = 0, total = 0.0, worst = 0.0
    mutating func add(_ s: Double) { count += 1; total += s; worst = max(worst, s) }
    var average: Double { count > 0 ? total / Double(count) : 0 }
    var summary: String { String(format: "%d seeks, average %.1f ms, worst %.1f ms", count, average * 1000, worst * 1000) }
}
