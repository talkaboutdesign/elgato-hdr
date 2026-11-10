import AppKit
import AVFoundation

// MARK: - Composition (editor preview and export share it)

struct BuiltComposition {
    let map: TimeMap                 // composition time -> source time (uncut for the editor preview)
    let asset: AVMutableComposition
    var video: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime             // read back from the assembled composition
    let screenSize: CGSize
    let cameraSize: CGSize?
    let frameDuration: CMTime
    let outTransfer: Int32
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID   // kCMPersistentTrackID_Invalid without a camera layer
    let sourceDurationMs: Double     // the game video's end
    let sourceFrameMs: Double
    var assets: [URL] = []           // where the project's overlay images are looked up, project `Assets/` first
}

enum CompositionBuilder {

    /// Every composition time is a whole number of ticks of this timescale. 120000 holds the frame boundaries of
    /// 24, 25, 30, 48, 50, 60, 100, 120 and 240 fps and their NTSC (×1000/1001) variants exactly.
    static let ticks: CMTimeScale = 120_000

    /// One source frame in ticks.
    static func frameTicks(rate: Double) -> Int64 {
        let r = rate > 0 && rate.isFinite ? rate : 60
        let ntsc = r * 1.001
        if abs(r - r.rounded()) > 0.005 && abs(ntsc - ntsc.rounded()) < 0.005 {
            return Int64((Double(ticks) * 1001 / (ntsc.rounded() * 1000)).rounded())
        }
        return max(1, Int64((Double(ticks) / r.rounded()).rounded()))
    }

    /// The kept ranges in source milliseconds, snapped to source frames. Export assembles exactly these; the preview
    /// (which plays the uncut source) uses them to know where the cuts are.
    static func editMap(_ p: Project, sourceDurationMs: Double, frameMs: Double) -> TimeMap {
        let segments = p.editSegments.map { r in
            Segment(startMs: (r.startMs / frameMs).rounded() * frameMs, endMs: (r.endMs / frameMs).rounded() * frameMs)
        }
        var map = TimeMap(segments: segments, sourceDurationMs: sourceDurationMs, frameMs: frameMs)
        map.normalize()
        return map
    }

    static func build(_ doc: ProjectDoc, canvas: Canvas, resolution: ExportResolution, range: ExportRange, fps: ExportFPS = .source, ignoreCuts: Bool = false) async throws -> BuiltComposition {
        let p = doc.project
        let comp = AVMutableComposition()
        let game = AVURLAsset(url: doc.url(p.game.file))
        guard let gv = try await game.loadTracks(withMediaType: .video).first else { throw err("game layer has no video") }
        let screenSize = try await gv.load(.naturalSize)
        let frameRate = try await gv.load(.nominalFrameRate)
        let gameRange = try await gv.load(.timeRange)
        // Video tracks first so audio can't take their IDs; the IDs actually assigned are what the compositor uses.
        let sv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let camTrack = p.camera != nil && doc.hasCamera ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let sourceRate = frameRate > 0 ? Double(frameRate) : max(1, p.fps)
        let frame = frameTicks(rate: sourceRate)
        let frameMs = Double(frame) * 1000 / Double(ticks)
        // All timing below is integer ticks: a range's length and the next insertion point come from the same
        // numbers, so the assembled tracks end exactly where the summed kept ranges do.
        let sourceEnd = CMTimeConvertScale(gameRange.end, timescale: ticks, method: .roundTowardZero).value
        let sourceMs = Double(sourceEnd) * 1000 / Double(ticks)
        let cuts = editMap(p, sourceDurationMs: sourceMs, frameMs: frameMs)
        let map = ignoreCuts ? TimeMap(segments: [], sourceDurationMs: sourceMs, frameMs: frameMs) : cuts
        let kept: [(start: Int64, end: Int64)] = map.segments.compactMap { s in
            let start = min(sourceEnd, max(0, Int64((s.startMs / frameMs).rounded()) * frame))
            let end = abs(s.endMs - sourceMs) < frameMs / 2 ? sourceEnd : min(sourceEnd, Int64((s.endMs / frameMs).rounded()) * frame)
            return end > start ? (start, end) : nil
        }
        guard !kept.isEmpty, map.durationMs > 0 else { throw err("No kept video remains") }
        try await insert(gv, into: sv, offsetMs: 0, kept: kept, holdFirstFrame: frame)
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let ga = try await game.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try await insert(ga, into: t, offsetMs: 0, kept: kept)
            if t.segments.isEmpty { comp.removeTrack(t) } else { mixParams.append(audioParameters(t, volume: p.game.volume, map: map)) }
        }
        var cameraSize: CGSize?
        if let cam = p.camera, doc.hasCamera {
            let a = AVURLAsset(url: doc.url(cam.file))
            if let cv = try await a.loadTracks(withMediaType: .video).first, let t = camTrack {
                try await insert(cv, into: t, offsetMs: cam.offsetMs, kept: kept)
                if !t.segments.isEmpty { cameraSize = try await cv.load(.naturalSize) }
            }
        }
        if let mic = p.mic, doc.hasMic {
            let a = AVURLAsset(url: doc.url(mic.file))
            if let mt = try await a.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try await insert(mt, into: t, offsetMs: mic.offsetMs, kept: kept)
                if t.segments.isEmpty { comp.removeTrack(t) } else { mixParams.append(audioParameters(t, volume: mic.volume, map: map)) }
            }
        }
        var cameraTrackID = kCMPersistentTrackID_Invalid
        if let t = camTrack { if cameraSize == nil || t.segments.isEmpty { comp.removeTrack(t); cameraSize = nil } else { cameraTrackID = t.trackID } }
        // The instruction covers what was assembled, not a recomputation of it.
        let duration = comp.duration

        let outputFrame = fps == .source ? frame : max(frame, frameTicks(rate: Double(fps.rawValue)))
        let frameDuration = CMTime(value: outputFrame, timescale: ticks)
        let gameTransfer = p.color.transfer
        let outTransfer: Int32 = range == .sdr || gameTransfer == 2 ? 2 : gameTransfer
        let mix = AVMutableAudioMix(); mix.inputParameters = mixParams
        var built = BuiltComposition(map: map, asset: comp, video: AVMutableVideoComposition(), audioMix: mixParams.isEmpty ? nil : mix, duration: duration,
                                     screenSize: screenSize, cameraSize: cameraSize,
                                     frameDuration: frameDuration, outTransfer: outTransfer, screenTrack: sv.trackID, cameraTrack: cameraTrackID,
                                     sourceDurationMs: sourceMs, sourceFrameMs: frameMs, assets: AssetStore.searchPaths(project: doc.dir))
        built.video = videoComposition(p, canvas: canvas, size: canvas.size(resolution), built: built)
        return built
    }

    /// The render description alone: cheap to rebuild whenever the layout changes. Exports, thumbnails and hover
    /// frames wait for overlay textures; the editor preview passes `waitForOverlays: false` and is told through
    /// `onOverlaysPending` (on the compositor's queue) when a frame went out before an overlay was ready.
    static func videoComposition(_ p: Project, canvas: Canvas, size: CGSize, built: BuiltComposition, waitForOverlays: Bool = true,
                                 onOverlaysPending: (() -> Void)? = nil) -> AVMutableVideoComposition {
        let out = built.outTransfer
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = out == 2 ? SDRLayerCompositor.self : HDRLayerCompositor.self
        vc.renderSize = size
        vc.frameDuration = built.frameDuration
        // No colour properties on purpose: setting them makes AVFoundation convert every source into that space before
        // the compositor sees it. The compositor converts each layer itself and tags its output buffers.
        var sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: built.screenSize)]
        if let size = built.cameraSize { sources[.camera] = SourceInfo(size: size) }
        // Cuts come from the project being rendered, not the assembled asset: the preview plays the uncut source but
        // finishes a transition at a cut exactly as the export does, and follows cut edits without a rebuild.
        var plan = RenderPlan(scenes: p.scenes.isEmpty ? [p.defaultScene] : p.scenes, timeline: p.timeline, map: built.map,
                              canvas: canvas, canvasSize: size, sources: sources, mirrorCamera: p.cameraMirror,
                              cuts: editMap(p, sourceDurationMs: built.sourceDurationMs, frameMs: built.sourceFrameMs))
        plan.overlay = OverlaySource(assets: built.assets.isEmpty ? AssetStore.searchPaths(project: nil) : built.assets,
                                     recordedAt: p.recordedAt ?? p.createdAt, wait: waitForOverlays)
        if let track = built.asset.track(withTrackID: built.cameraTrack) {
            plan.cameraRanges = track.segments.filter { !$0.isEmpty }.map {
                Segment(startMs: $0.timeMapping.target.start.seconds * 1000, endMs: $0.timeMapping.target.end.seconds * 1000)
            }
        }
        vc.instructions = [CompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: built.duration), screenTrack: built.screenTrack,
                                                  cameraTrack: built.cameraTrack, plan: plan,
                                                  outTransfer: out, screenTransfer: p.color.transfer, screenSize: built.screenSize, cameraSize: built.cameraSize,
                                                  onOverlaysPending: onOverlaysPending)]
        return vc
    }

    static func time(_ ms: Double) -> CMTime { CMTime(seconds: ms / 1000, preferredTimescale: 60000) }

    /// Each kept range (ticks) takes what the layer has of it, shifted by the layer's offset; the gaps stay empty and
    /// the next range starts exactly where this one ended. `holdFirstFrame` (one source frame, in ticks): the game's
    /// first frame lands a little after 0 (about 0.13 s into a recording), so a kept range that starts before it shows
    /// that frame, held, until then; no game picture at 0:00 otherwise. Only the composition changes, never the file.
    private static func insert(_ src: AVAssetTrack, into t: AVMutableCompositionTrack, offsetMs: Double, kept: [(start: Int64, end: Int64)],
                               holdFirstFrame frame: Int64? = nil) async throws {
        let available = try await src.load(.timeRange)
        let first = CMTimeConvertScale(available.start, timescale: ticks, method: .roundAwayFromZero).value
        let last = CMTimeConvertScale(available.end, timescale: ticks, method: .roundTowardZero).value
        let offset = Int64((offsetMs * Double(ticks) / 1000).rounded())
        func tick(_ v: Int64) -> CMTime { CMTime(value: v, timescale: ticks) }
        // Where the first sample is shown: the track can begin with an empty edit rather than at that sample.
        var media = first
        if frame != nil, let m = try await src.load(.segments).first(where: { !$0.isEmpty }) {
            media = max(first, CMTimeConvertScale(m.timeMapping.target.start, timescale: ticks, method: .roundAwayFromZero).value)
        }
        var at: Int64 = 0
        for r in kept {
            let want = r.start - offset
            var start = max(want, first)
            let end = min(r.end - offset, last)
            if let frame, start < media, end > media {
                let still = min(frame, end - media), pos = at + start - want
                try t.insertTimeRange(CMTimeRange(start: tick(media), duration: tick(still)), of: src, at: tick(pos))
                t.scaleTimeRange(CMTimeRange(start: tick(pos), duration: tick(still)), toDuration: tick(media - start))
                start = media
            }
            if end > start { try t.insertTimeRange(CMTimeRange(start: tick(start), end: tick(end)), of: src, at: tick(at + start - want)) }
            at += r.end - r.start
        }
    }
    private static func audioParameters(_ track: AVMutableCompositionTrack, volume: Double, map: TimeMap) -> AVMutableAudioMixInputParameters {
        let p = AVMutableAudioMixInputParameters(track: track), v = Float(volume)
        p.setVolume(v, at: .zero)
        let points = map.cutPoints()
        for (i, cut) in points.enumerated() {
            let before = i == 0 ? 0 : points[i-1]
            let after = i+1 == points.count ? map.durationMs : points[i+1]
            let down = min(6, (cut-before)/2), up = min(6, (after-cut)/2)
            p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: time(cut-down), end: time(cut)))
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: time(cut), end: time(cut+up)))
        }
        return p
    }

    /// AVFoundation's own check of the render description against the assembled tracks; empty when valid.
    static func validate(_ b: BuiltComposition) async throws -> [String] {
        final class Collector: NSObject, AVVideoCompositionValidationHandling {
            private let lock = NSLock()
            private(set) var problems: [String] = []
            func add(_ s: String) { lock.lock(); problems.append(s); lock.unlock() }
            func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool { add("invalid value for \(key)"); return true }
            func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange r: CMTimeRange) -> Bool {
                add("empty range \(r.start.value)/\(r.start.timescale) + \(r.duration.value)/\(r.duration.timescale)"); return true
            }
            func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn i: any AVVideoCompositionInstructionProtocol) -> Bool {
                add("invalid instruction range \(i.timeRange.start.seconds) + \(i.timeRange.duration.seconds)"); return true
            }
            func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn i: any AVVideoCompositionInstructionProtocol,
                                  layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool { add("invalid track id"); return true }
        }
        let c = Collector()
        let range = CMTimeRange(start: .zero, duration: b.asset.duration)
        let ok = try await b.video.isValid(for: b.asset, timeRange: range, validationDelegate: c)
        return ok && c.problems.isEmpty ? [] : (c.problems.isEmpty ? ["invalid"] : c.problems)
    }

    static func err(_ s: String) -> NSError { NSError(domain: "Project", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

