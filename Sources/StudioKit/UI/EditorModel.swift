import AppKit
import AVFoundation
import SwiftUI

// MARK: - Editor model

struct ExportState {
    var progress = 0.0
    var running = false
    var url: URL?
    var error: String?
}

final class EditorModel: ObservableObject {
    let doc: ProjectDoc
    @Published var project: Project
    @Published var canvas: Canvas = .wide { didSet { if canvas != oldValue { rebuild() } } }
    @Published var range: ExportRange { didSet { if range != oldValue { rebuild() } } }
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var exportCanvases: Set<Canvas> = [.wide, .vertical]
    @Published var resolution: ExportResolution = .hd
    @Published var fps: ExportFPS = .source
    @Published var exports: [Canvas: ExportState] = [:]
    @Published var loadError: String?
    let player = AVPlayer()
    private var built: BuiltComposition?
    private var timeObserver: Any?
    private var saveWork: DispatchWorkItem?
    private var buildGen = 0
    private var exporters: [Exporter] = []
    private var dirty = false

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
        saveNow()
        if dirty { Task { await doc.writeThumbnail(); await MainActor.run { Library.shared.objectWillChange.send() } } }
    }

    // Edits

    func update(_ f: (inout Project) -> Void) {
        let old = project
        var p = project; f(&p)
        guard p != old else { return }
        // Existing layout controls edit the default scene while plan 31 supplies scene selection.
        if p.wide != old.wide || p.vertical != old.vertical {
            if !p.scenes.isEmpty {
                let template = p.defaultScene
                if p.wide != old.wide { p.scenes[0].wide = template.wide }
                if p.vertical != old.vertical { p.scenes[0].vertical = template.vertical }
            }
        }
        project = p
        doc.project = p
        dirty = true
        scheduleSave()
        if p.game != old.game || p.camera != old.camera || p.mic != old.mic || p.timeline.segments != old.timeline.segments { rebuild() }
        else if p.wide != old.wide || p.vertical != old.vertical || p.cameraMirror != old.cameraMirror || p.scenes != old.scenes || p.timeline != old.timeline { restyle() }
        if p.trimStartMs != old.trimStartMs || p.trimEndMs != old.trimEndMs { applyTrim() }
    }

    var layout: CanvasLayout {
        get { project.layout(canvas) }
        set { let c = canvas; update { $0.setLayout(c, newValue) } }
    }
    func binding<T>(_ kp: WritableKeyPath<CanvasLayout, T>) -> Binding<T> {
        Binding(get: { self.layout[keyPath: kp] }, set: { v in var l = self.layout; l[keyPath: kp] = v; self.layout = l })
    }
    func projectBinding<T>(_ kp: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { self.project[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    func saveNow() { saveWork?.cancel(); saveWork = nil; doc.project = project; doc.save() }

    // Preview

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
                    item.videoComposition = b.video
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
    func setIn() { let t = time; update { $0.trimStartMs = t * 1000; if $0.trimEndMs > 0 && $0.trimEndMs <= $0.trimStartMs { $0.trimEndMs = 0 } } }
    func setOut() { let t = time; update { $0.trimEndMs = t * 1000; if $0.trimStartMs >= $0.trimEndMs { $0.trimStartMs = 0 } } }

    func split() {
        update { p in
            var map = TimeMap(segments: p.editSegments, sourceDurationMs: p.durationMs, frameMs: 1000 / max(1, p.fps))
            let frameMs = 1000 / max(1, p.fps)
            map.split(atSourceMs: (time * 1000 / frameMs).rounded() * frameMs)
            p.timeline.segments = map.storedSegments
        }
    }
    func deleteSection() {
        update { p in
            // In/Out selects the range to remove; it must not first restrict the kept ranges to that selection.
            var map = TimeMap(segments: p.timeline.segments, sourceDurationMs: p.durationMs, frameMs: 1000 / max(1, p.fps))
            map.remove(sourceRange: Segment(startMs: trimStart * 1000, endMs: trimEnd * 1000))
            p.timeline.segments = map.storedSegments
            p.trimStartMs = 0; p.trimEndMs = 0
        }
    }
    func addZoom() { let s = time * 1000; update { $0.timeline.zooms.append(ZoomBlock(startMs: s, endMs: min($0.durationMs, s + 3000))) } }

    // Export

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
                        self.update { $0.lastExport[j.canvas.rawValue] = url.lastPathComponent }
                        self.saveNow()
                    }
                } catch {
                    await MainActor.run { self.exports[j.canvas] = ExportState(running: false, error: ex.cancelled ? "Cancelled" : error.localizedDescription) }
                }
            }
            await MainActor.run { self.exporters.removeAll(); Library.shared.objectWillChange.send() }
        }
    }
    func cancelExports() { exporters.forEach { $0.cancel() } }
}

