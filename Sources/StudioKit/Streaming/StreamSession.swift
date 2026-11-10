import Foundation
import CoreGraphics

final class StreamSession {
    struct Output {
        var canvas: Canvas; var size: CGSize; var fps: Double; var videoBitrate: Int
        var publishers: [RTMPPublisher]
    }
    struct Stats {
        var canvas: Canvas; var fps: Double; var renderMs, encodeMs, latencyMs: Double
        var renderDropped, encoderDropped: Int; var publishers: [RTMPPublisher.Stats]
    }
    var onStats: ((Stats) -> Void)?
    var onError: ((String) -> Void)?
    let mixer: AudioMixer
    var mic: MixerInput { mixer.addInput("mic") }
    private let outputs: [Output], renderer: Renderer, audioBitrate: Int
    private var programs: [ProgramOutput] = [], encoders: [VideoEncoder] = []
    private var timer: DispatchSourceTimer?
    private var running = false

    init(outputs: [Output], audioBitrate: Int, renderer: Renderer, mixer: AudioMixer) {
        self.outputs = outputs; self.audioBitrate = audioBitrate; self.renderer = renderer; self.mixer = mixer
    }
    /// Lifecycle and stats callbacks run on main; all media callbacks stay on their producer queues.
    @discardableResult func start() -> Bool {
        guard !running else { return true }
        guard !outputs.isEmpty, mixer.sampleRate == 48000, mixer.blockFrames == 1024,
              let audio = AACEncoder(bitrate: audioBitrate) else { onError?("Cannot create AAC encoder"); return false }
        for output in outputs {
            guard let encoder = VideoEncoder(settings: .init(width: Int(output.size.width), height: Int(output.size.height), fps: output.fps, bitrate: output.videoBitrate)) else {
                encoders.forEach { $0.finish() }; encoders = []; programs = []
                onError?("Hardware H.264 encoder unavailable"); return false
            }
            let program = ProgramOutput(canvas: output.canvas, size: output.size, fps: output.fps)
            program.composition = { [weak renderer] in
                let overlay = renderer?.overlay ?? LiveOverlay()
                let layout = output.canvas == .wide ? CanvasLayout(kind: .pip, camera: overlay.placement) : .verticalDefault
                return Composition.from(layout: layout, canvas: output.size, hasCamera: overlay.camera?.latest != nil, mirror: overlay.mirror)
            }
            program.camera = { [weak renderer] in renderer?.overlay.camera?.latest }
            program.onFrame = { [weak encoder] pb, ns in encoder?.encode(pb, hostNs: ns) }
            encoder.onConfig = { sps, pps in output.publishers.forEach { $0.setVideoConfig(sps: sps, pps: pps) } }
            encoder.onFrame = { bytes, ns, key in output.publishers.forEach { $0.sendVideo(bytes, ptsNs: ns, dtsNs: ns, keyframe: key) } }
            encoder.onError = { [weak self] status in DispatchQueue.main.async { self?.onError?("H.264 encode failed (\(status))") } }
            for publisher in output.publishers { publisher.onNeedKeyframe = { [weak encoder] in encoder?.requestKeyframe() } }
            programs.append(program); encoders.append(encoder)
        }
        let publishers = outputs.flatMap(\.publishers)
        for publisher in publishers { publisher.setAudioConfig(audioSpecificConfig: audio.audioSpecificConfig); publisher.start() }
        mixer.onBlock = { samples, frames, ns in
            guard frames == 1024, let packet = audio.encode(samples, startHostNs: ns) else { return }
            for publisher in publishers { publisher.sendAudio(packet.data, ptsNs: packet.ptsNs) }
        }
        running = true
        programs.forEach { $0.start() }; renderer.programOutputs = programs; mixer.start()
        var last = nowNs()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = nowNs(), dt = Double(now - last) / 1e9; last = now
            for i in self.outputs.indices {
                let p = self.programs[i].takeStats(), e = self.encoders[i].takeStats(), n = Double(max(1, e.frames))
                self.onStats?(Stats(canvas: self.outputs[i].canvas, fps: Double(e.frames) / dt,
                    renderMs: p.renderMs / Double(max(1, p.frames)), encodeMs: e.encodeMs / n, latencyMs: e.latencyMs / n,
                    renderDropped: p.dropped, encoderDropped: e.dropped, publishers: self.outputs[i].publishers.map(\.stats)))
            }
        }
        self.timer = timer; timer.resume(); return true
    }
    func stop() {
        guard running else { return }; running = false
        timer?.cancel(); timer = nil
        renderer.programOutputs = []; programs.forEach { $0.stop() }
        mixer.stop(); mixer.onBlock = nil
        encoders.forEach { $0.finish() }
        outputs.flatMap(\.publishers).forEach { $0.onNeedKeyframe = nil; $0.stop() }
        encoders = []; programs = []
    }
}
