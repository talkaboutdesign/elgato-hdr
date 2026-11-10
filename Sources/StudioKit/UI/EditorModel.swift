import AppKit
import AVFoundation
import Observation
import SwiftUI

// MARK: - Editor model

struct ExportState {
    var progress = 0.0
    var running = false
    var url: URL?
    var error: String?
}

/// One open project. `@Observable` tracks reads per property, so the 60 Hz playhead re-renders the playhead and the
/// time read-out only, never the inspector or the timeline lanes. Main thread only.
@Observable
final class EditorModel {
    @ObservationIgnored let doc: ProjectDoc
    private(set) var project: Project
    var canvas: Canvas = .wide { didSet { if canvas != oldValue { rebuild() } } }
    var range: ExportRange { didSet { if range != oldValue { rebuild() } } }
    var time = 0.0
    var duration = 0.0
    var playing = false
    var exportCanvases: Set<Canvas> = [.wide, .vertical]
    var resolution: ExportResolution = .hd
    var fps: ExportFPS = .source
    var exports: [Canvas: ExportState] = [:]
    var loadError: String?
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"

    @ObservationIgnored let player = AVPlayer()
    /// Owned by the model rather than the window, so the history goes away with the project and the same editor can
    /// live in its own window or inside the library window. Grouping is explicit: one group per edit or gesture.
    @ObservationIgnored let undoManager: UndoManager = {
        let u = UndoManager(); u.groupsByEvent = false; u.levelsOfUndo = 200; return u
    }()
    @ObservationIgnored private var built: BuiltComposition?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var buildGen = 0
    @ObservationIgnored private var exporters: [Exporter] = []
    @ObservationIgnored private var dirty = false
    /// The project as it was when a continuous gesture (drag, slider) began; the gesture becomes one undo step.
    @ObservationIgnored private var gestureBase: Project?
    @ObservationIgnored private var gestureName = ""
    @ObservationIgnored private var rebuildAfterGesture = false

    var hasCamera: Bool { doc.hasCamera }
    var hasMic: Bool { doc.hasMic }
    var isHDRSource: Bool { project.color != .sdr }

    init(doc: ProjectDoc) {
        self.doc = doc
        project = doc.project
        range = doc.project.color == .sdr ? .sdr : .hdr
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self = self else { return }
            self.time = t.seconds
            self.playing = self.player.rate != 0
        }
        rebuild()
    }

    func close() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        endGesture()
        saveNow()
        undoManager.removeAllActions()
        if dirty { Task { await doc.writeThumbnail(); await MainActor.run { Library.shared.objectWillChange.send() } } }
    }

    // MARK: Edits and undo

    /// Every edit goes through here. Outside a gesture each call is one undo step; inside one, the whole gesture is.
    func update(_ name: String = "Edit", _ f: (inout Project) -> Void) {
        let old = project
        var p = project; f(&p)
        syncDerived(&p, from: old)
        guard p != old else { return }
        if gestureBase == nil { registerUndo(restoring: old, name: name) } else { gestureName = name }
        apply(p, from: old)
    }

    /// Starts coalescing edits into one undo step (drag began, slider grabbed).
    func beginGesture() { if gestureBase == nil { gestureBase = project; gestureName = "Edit" } }
    func endGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        if base != project { registerUndo(restoring: base, name: gestureName) }
        if rebuildAfterGesture { rebuildAfterGesture = false; rebuild() }
    }
    /// For `Slider(onEditingChanged:)`.
    func gesture(_ editing: Bool) { editing ? beginGesture() : endGesture() }

    func undo() { endGesture(); if undoManager.canUndo { undoManager.undo() }; refreshUndoState() }
    func redo() { endGesture(); if undoManager.canRedo { undoManager.redo() }; refreshUndoState() }

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

    func refreshUndoState() {
        let u = undoManager
        if canUndo != u.canUndo { canUndo = u.canUndo }
        if canRedo != u.canRedo { canRedo = u.canRedo }
        let ut = u.canUndo ? u.undoMenuItemTitle : "Undo", rt = u.canRedo ? u.redoMenuItemTitle : "Redo"
        if undoTitle != ut { undoTitle = ut }
        if redoTitle != rt { redoTitle = rt }
    }

    /// Layout controls edit the project's default scene; camera mirroring applies to every scene.
    private func syncDerived(_ p: inout Project, from old: Project) {
        if p.wide != old.wide || p.vertical != old.vertical {
            if !p.scenes.isEmpty {
                let template = p.defaultScene
                if p.wide != old.wide { p.scenes[0].wide = template.wide }
                if p.vertical != old.vertical { p.scenes[0].vertical = template.vertical }
            }
        }
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
        if p.game != old.game || p.camera != old.camera || p.mic != old.mic || p.timeline.segments != old.timeline.segments {
            // Reloading the layers mid-drag stalls the preview: the lanes follow live, the composition once at the end.
            if gestureBase != nil { rebuildAfterGesture = true } else { rebuild() }
        }
        else if p.wide != old.wide || p.vertical != old.vertical || p.cameraMirror != old.cameraMirror || p.scenes != old.scenes || p.timeline != old.timeline { restyle() }
        if p.trimStartMs != old.trimStartMs || p.trimEndMs != old.trimEndMs { applyTrim() }
    }

    var layout: CanvasLayout {
        get { project.layout(canvas) }
        set { let c = canvas; update("Layout") { $0.setLayout(c, newValue) } }
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

    // MARK: Preview

    /// Rebuilds the composition (layers, offsets, volumes) for the current canvas. The preview is untrimmed so trim
    /// handles can be dragged over the whole recording; playback is limited to the trim range.
    func rebuild() {
        buildGen += 1
        let gen = buildGen, canvas = canvas, range = range
        let keep = player.currentTime()
        Task {
            do {
                let b = try await CompositionBuilder.build(doc, canvas: canvas, resolution: .hd, range: range, ignoreCuts: true)
                await MainActor.run {
                    guard gen == self.buildGen else { return }
                    self.built = b
                    let item = AVPlayerItem(asset: b.asset)
                    // A scene or zoom edit can arrive while track loading is suspended.
                    item.videoComposition = CompositionBuilder.videoComposition(self.project, canvas: canvas, size: canvas.size(.hd), built: b)
                    item.audioMix = b.audioMix
                    self.player.replaceCurrentItem(with: item)
                    self.duration = b.duration.seconds
                    self.applyTrim()
                    self.player.seek(to: keep.isValid ? keep : CMTime(seconds: self.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    self.loadError = nil
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    /// Layout-only change: swap the render instruction; the layers stay loaded.
    private func restyle() {
        guard let b = built, let item = player.currentItem else { return }
        item.videoComposition = CompositionBuilder.videoComposition(project, canvas: canvas, size: canvas.size(.hd), built: b)
        if player.rate == 0 { player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    var trimStart: Double { project.trimStartMs / 1000 }
    var trimEnd: Double { project.trimEndMs > project.trimStartMs ? project.trimEndMs / 1000 : duration }

    private func applyTrim() {
        player.currentItem?.forwardPlaybackEndTime = project.trimEndMs > 0 ? CMTime(seconds: trimEnd, preferredTimescale: 600) : .invalid
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); playing = false; return }
        if time < trimStart - 0.01 || time >= trimEnd - 0.05 { seek(trimStart) }
        player.play(); playing = true
    }
    func seek(_ s: Double) {
        let t = min(max(0, s), duration)
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setIn() { let t = time; update("Set In") { $0.trimStartMs = t * 1000; if $0.trimEndMs > 0 && $0.trimEndMs <= $0.trimStartMs { $0.trimEndMs = 0 } } }
    func setOut() { let t = time; update("Set Out") { $0.trimEndMs = t * 1000; if $0.trimStartMs >= $0.trimEndMs { $0.trimStartMs = 0 } } }

    func split() {
        update("Split") { p in
            var map = TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs, frameMs: 1000 / max(1, p.fps))
            let frameMs = 1000 / max(1, p.fps)
            map.split(atSourceMs: (time * 1000 / frameMs).rounded() * frameMs)
            p.timeline.segments = map.storedSegments
        }
    }
    func deleteSection() {
        update("Delete Section") { p in
            // In/Out selects the range to remove; it must not first restrict the kept ranges to that selection.
            var map = TimeMap(segments: p.timeline.segments, sourceDurationMs: p.durationMs, frameMs: 1000 / max(1, p.fps))
            map.remove(sourceRange: Segment(startMs: trimStart * 1000, endMs: trimEnd * 1000))
            p.timeline.segments = map.storedSegments
            p.trimStartMs = 0; p.trimEndMs = 0
        }
    }
    func addZoom() { let s = time * 1000; update("Add Zoom") { $0.timeline.zooms.append(ZoomBlock(startMs: s, endMs: min($0.durationMs, s + 3000))) } }

    // MARK: Export

    var anyExporting: Bool { exports.values.contains { $0.running } }

    func export() {
        saveNow()
        let jobs = Canvas.allCases.filter { exportCanvases.contains($0) }
            .map { ExportJob(canvas: $0, resolution: resolution, range: isHDRSource ? range : .sdr, fps: fps) }
        guard !jobs.isEmpty else { return }
        player.pause()
        for j in jobs { exports[j.canvas] = ExportState(running: true) }
        Task {
            // One at a time: the media engines are shared, and sequential keeps each export at full speed.
            for j in jobs {
                let ex = Exporter(doc: doc, job: j)
                await MainActor.run { self.exporters.append(ex) }
                do {
                    let url = try await ex.run { p in DispatchQueue.main.async { self.exports[j.canvas]?.progress = p } }
                    await MainActor.run {
                        self.exports[j.canvas] = ExportState(progress: 1, running: false, url: url)
                        self.recordExport(j.canvas, url)
                    }
                } catch {
                    await MainActor.run { self.exports[j.canvas] = ExportState(running: false, error: ex.cancelled ? "Cancelled" : error.localizedDescription) }
                }
            }
            await MainActor.run { self.exporters.removeAll(); Library.shared.objectWillChange.send() }
        }
    }
    func cancelExports() { exporters.forEach { $0.cancel() } }

    /// Export history is bookkeeping, not an edit: it bypasses undo.
    private func recordExport(_ canvas: Canvas, _ url: URL) {
        var p = project; p.lastExport[canvas.rawValue] = url.lastPathComponent
        project = p; doc.project = p; saveNow()
    }
}
