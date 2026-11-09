import AppKit
import AVFoundation

// MARK: - Composition (editor preview and export share it)

struct BuiltComposition {
    let asset: AVMutableComposition
    var video: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
    let screenSize: CGSize
    let cameraSize: CGSize?
    let frameDuration: CMTime
    let outTransfer: Int32
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID   // kCMPersistentTrackID_Invalid without a camera layer
}

enum CompositionBuilder {

    static func build(_ doc: ProjectDoc, canvas: Canvas, resolution: ExportResolution, range: ExportRange, fps: ExportFPS = .source, trimmed: Bool = true) async throws -> BuiltComposition {
        let p = doc.project
        let comp = AVMutableComposition()
        let game = AVURLAsset(url: doc.url(p.game.file))
        guard let gv = try await game.loadTracks(withMediaType: .video).first else { throw err("game layer has no video") }
        let gameDur = try await game.load(.duration)
        let screenSize = try await gv.load(.naturalSize)
        let frameRate = try await gv.load(.nominalFrameRate)
        // Video tracks first so audio can't take their IDs; the IDs actually assigned are what the compositor uses.
        let sv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let camTrack = p.camera != nil && doc.hasCamera ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        try sv.insertTimeRange(CMTimeRange(start: .zero, duration: gameDur), of: gv, at: .zero)
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let ga = try await game.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try t.insertTimeRange(CMTimeRange(start: .zero, duration: gameDur), of: ga, at: .zero)
            let m = AVMutableAudioMixInputParameters(track: t); m.setVolume(Float(p.game.volume), at: .zero); mixParams.append(m)
        }
        var cameraSize: CGSize?
        if let cam = p.camera, doc.hasCamera {
            let a = AVURLAsset(url: doc.url(cam.file))
            if let cv = try await a.loadTracks(withMediaType: .video).first, let t = camTrack {
                try insert(cv, duration: try await a.load(.duration), into: t, offsetMs: cam.offsetMs, limit: gameDur)
                if !t.segments.isEmpty { cameraSize = try await cv.load(.naturalSize) }
            }
        }
        if let mic = p.mic, doc.hasMic {
            let a = AVURLAsset(url: doc.url(mic.file))
            if let mt = try await a.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try insert(mt, duration: try await a.load(.duration), into: t, offsetMs: mic.offsetMs, limit: gameDur)
                let m = AVMutableAudioMixInputParameters(track: t); m.setVolume(Float(mic.volume), at: .zero); mixParams.append(m)
            }
        }
        // Trim: drop everything outside [start, end) on every layer at once.
        var cameraTrackID = kCMPersistentTrackID_Invalid
        if let t = camTrack { if cameraSize == nil || t.segments.isEmpty { comp.removeTrack(t); cameraSize = nil } else { cameraTrackID = t.trackID } }
        var duration = gameDur
        if trimmed {
            let (s, e) = p.trimmedRange
            let end = CMTime(seconds: e / 1000, preferredTimescale: 600)
            if e > 0, end < gameDur { comp.removeTimeRange(CMTimeRange(start: end, end: gameDur)) }
            if s > 0 { comp.removeTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: s / 1000, preferredTimescale: 600))) }
            duration = comp.duration
        }

        let sourceFps = max(1, (frameRate > 0 ? Double(frameRate) : p.fps).rounded())
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps == .source ? sourceFps : min(sourceFps, Double(fps.rawValue))))
        let gameTransfer = p.color.transfer
        let outTransfer: Int32 = range == .sdr || gameTransfer == 2 ? 2 : gameTransfer
        let mix = AVMutableAudioMix(); mix.inputParameters = mixParams
        var built = BuiltComposition(asset: comp, video: AVMutableVideoComposition(), audioMix: mixParams.isEmpty ? nil : mix, duration: duration,
                                     screenSize: screenSize, cameraSize: cameraSize,
                                     frameDuration: frameDuration, outTransfer: outTransfer, screenTrack: sv.trackID, cameraTrack: cameraTrackID)
        built.video = videoComposition(p, canvas: canvas, size: canvas.size(resolution), built: built)
        return built
    }

    /// The render description alone: cheap to rebuild whenever the layout changes.
    static func videoComposition(_ p: Project, canvas: Canvas, size: CGSize, built: BuiltComposition) -> AVMutableVideoComposition {
        let out = built.outTransfer
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = out == 2 ? SDRLayerCompositor.self : HDRLayerCompositor.self
        vc.renderSize = size
        vc.frameDuration = built.frameDuration
        // No colour properties on purpose: setting them makes AVFoundation convert every source into that space before
        // the compositor sees it. The compositor converts each layer itself and tags its output buffers.
        vc.instructions = [CompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: built.duration), screenTrack: built.screenTrack,
                                                  cameraTrack: built.cameraTrack, composition: .from(layout: p.layout(canvas), canvas: size, hasCamera: built.cameraSize != nil, mirror: p.cameraMirror),
                                                  canvas: size, outTransfer: out, screenTransfer: p.color.transfer, screenSize: built.screenSize, cameraSize: built.cameraSize)]
        return vc
    }

    /// Inserts a layer shifted by its sync offset, clipped to the game's length.
    private static func insert(_ src: AVAssetTrack, duration dur: CMTime, into t: AVMutableCompositionTrack, offsetMs: Double, limit: CMTime) throws {
        let off = CMTime(seconds: offsetMs / 1000, preferredTimescale: 48000)
        var srcStart = CMTime.zero, at = off
        if off < .zero { srcStart = CMTimeAbsoluteValue(off); at = .zero }
        let len = CMTimeMinimum(dur - srcStart, limit - at)
        guard len > .zero else { return }
        try t.insertTimeRange(CMTimeRange(start: srcStart, duration: len), of: src, at: at)
    }

    static func err(_ s: String) -> NSError { NSError(domain: "Project", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

