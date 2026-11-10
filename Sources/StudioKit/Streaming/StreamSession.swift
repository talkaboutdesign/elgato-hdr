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
        /// Same order as `publishers`, so a caller can tell whose numbers are whose.
        var publisherIDs: [ObjectIdentifier] = []
        var renderSkips = ProgramOutput.Stats()
        var queueRejected = 0, inFlightRejected = 0
        var latency = EncodeLatency()
    }
    /// A lane that could not start: only the destinations of that canvas are affected.
    struct LaneFailure: Error, Equatable, CustomStringConvertible { let description: String }
    var onStats: ((Stats) -> Void)?
    /// Failures that stop everything: no audio encoder, or no lane could start.
    var onError: ((String) -> Void)?
    /// A lane failed (its encoder could not be created at start, or failed for good while live); the others run on.
    var onLaneError: ((Canvas, String) -> Void)?
    var onRecovery: ((Canvas) -> Void)?
    let mixer: AudioMixer
    var mic: MixerInput { mixer.addInput("mic") }
    private let outputs: [Output], audioBitrate: Int
    private let rendererLock = NSLock()
    private var currentRenderer: Renderer
    private var renderer: Renderer {
        get { rendererLock.lock(); defer { rendererLock.unlock() }; return currentRenderer }
        set { rendererLock.lock(); currentRenderer = newValue; rendererLock.unlock() }
    }
    /// One lane per canvas: a program render and an encoder fanned out to that canvas's publishers.
    private var lanes: [Lane] = []
    private let audioTargets = PublisherList()
    private var audio: AACEncoder?
    private var timer: DispatchSourceTimer?
    private var running = false
    /// Replaced in tests to simulate a hardware encoder that cannot be created.
    var makeEncoder: (VideoEncoder.Settings) -> VideoEncoder? = { VideoEncoder(settings: $0) }

    init(outputs: [Output], audioBitrate: Int, renderer: Renderer, mixer: AudioMixer) {
        self.outputs = outputs; self.audioBitrate = audioBitrate; self.currentRenderer = renderer; self.mixer = mixer
    }
    /// Lifecycle and stats callbacks run on main; all media callbacks stay on their producer queues.
    @discardableResult func start() -> Bool {
        guard !running else { return true }
        guard !outputs.isEmpty, mixer.sampleRate == 48000, mixer.blockFrames == 1024,
              let audio = AACEncoder(bitrate: audioBitrate) else { onError?("Cannot create AAC encoder"); return false }
        // A canvas whose encoder cannot be created fails alone; the session fails only when none can start.
        var started: [(Lane, Output)] = [], failed: [Canvas] = []
        for output in outputs {
            if let lane = makeLane(output) { started.append((lane, output)) } else { failed.append(output.canvas) }
        }
        guard !started.isEmpty else { onError?(Self.encoderUnavailable); return false }
        lanes = started.map(\.0)
        self.audio = audio
        let targets = audioTargets
        mixer.onBlock = { samples, frames, ns in
            guard frames == 1024, let packet = audio.encode(samples, startHostNs: ns) else { return }
            for publisher in targets.snapshot.items { publisher.sendAudio(packet.data, ptsNs: packet.ptsNs) }
        }
        running = true
        for (lane, output) in started { output.publishers.forEach { attach($0, to: lane) } }
        lanes.forEach { $0.program.start() }; renderer.programOutputs = lanes.map(\.program); mixer.start()
        var last = nowNs()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = nowNs(), dt = Double(now - last) / 1e9; last = now
            for lane in self.lanes {
                let p = lane.program.takeStats(), e = lane.encoder.takeStats(), n = Double(max(1, e.frames))
                let publishers = lane.publishers.snapshot.items
                self.onStats?(Stats(canvas: lane.canvas, fps: Double(e.frames) / dt,
                    renderMs: p.renderMs / Double(max(1, p.frames)), encodeMs: e.encodeMs / n, latencyMs: e.latencyMs / n,
                    renderDropped: p.dropped, encoderDropped: e.dropped, publishers: publishers.map(\.stats),
                    publisherIDs: publishers.map(ObjectIdentifier.init), renderSkips: p, queueRejected: e.queueRejected, inFlightRejected: e.inFlightRejected, latency: e.latency))
            }
        }
        self.timer = timer; timer.resume()
        for canvas in failed { onLaneError?(canvas, Self.encoderUnavailable) }
        return true
    }
    static let encoderUnavailable = "Hardware H.264 encoder unavailable"
    func replaceRenderer(_ next: Renderer) {
        renderer.programOutputs = []
        renderer = next
        if running { next.programOutputs = lanes.map(\.program) }
    }
    func stop() {
        guard running else { return }; running = false
        timer?.cancel(); timer = nil
        renderer.programOutputs = []; lanes.forEach { $0.program.stop() }
        mixer.stop(); mixer.onBlock = nil
        lanes.forEach { $0.encoder.finish() }
        for lane in lanes { lane.publishers.snapshot.items.forEach { $0.onNeedKeyframe = nil; $0.stop() } }
        lanes = []; audioTargets.removeAll(); audio = nil
    }

    /// Canvases currently rendering and encoding.
    var activeCanvases: [Canvas] { lanes.map(\.canvas) }

    /// Starts `publisher` while live. It joins the running lane for `output.canvas`, or starts a new lane with that
    /// output's size, rate and bitrate. A late joiner waits for the stream configuration and a keyframe (plan 11), so
    /// the encoder is asked for one; the destinations already live see one extra keyframe. Throws `LaneFailure` when
    /// the new lane cannot start; that concerns this publisher only, so `onError` is not called and the running lanes
    /// carry on.
    func addPublisher(_ publisher: RTMPPublisher, to output: Output) throws {
        guard running else { throw LaneFailure(description: "The stream is not running") }
        if let lane = lanes.first(where: { $0.canvas == output.canvas }) {
            attach(publisher, to: lane); lane.encoder.requestKeyframe(); return
        }
        guard let lane = makeLane(output) else { throw LaneFailure(description: Self.encoderUnavailable) }
        lanes.append(lane); attach(publisher, to: lane)
        lane.program.start(); renderer.programOutputs = lanes.map(\.program)
    }

    /// Stops `publisher`. When it was the last one of its canvas, that canvas's render and encode stop too.
    func removePublisher(_ publisher: RTMPPublisher) {
        guard let i = lanes.firstIndex(where: { $0.publishers.contains(publisher) }) else { return }
        let lane = lanes[i]
        lane.publishers.remove(publisher); audioTargets.remove(publisher)
        publisher.onNeedKeyframe = nil; publisher.stop()
        guard lane.publishers.isEmpty else { return }
        lanes.remove(at: i)
        renderer.programOutputs = lanes.map(\.program)
        lane.program.stop(); lane.encoder.finish()
    }

    func invalidateEncoderForTesting(_ canvas: Canvas, fatal: Bool = false) {
        lanes.first { $0.canvas == canvas }?.encoder.invalidateForTesting(fatal: fatal)
    }

    private func attach(_ publisher: RTMPPublisher, to lane: Lane) {
        if let audio { publisher.setAudioConfig(audioSpecificConfig: audio.audioSpecificConfig) }
        publisher.onNeedKeyframe = { [weak encoder = lane.encoder] in encoder?.requestKeyframe() }
        // Adding and reading the cached configuration under one lock: a configuration arriving in between reaches
        // the publisher through the fan-out instead.
        if let (sps, pps) = lane.publishers.add(publisher) { publisher.setVideoConfig(sps: sps, pps: pps) }
        audioTargets.add(publisher)
        publisher.start()
    }

    private func makeLane(_ output: Output) -> Lane? {
        guard let encoder = makeEncoder(.init(width: Int(output.size.width), height: Int(output.size.height), fps: output.fps, bitrate: output.videoBitrate)) else { return nil }
        #if DEBUG
        let nv12 = ProcessInfo.processInfo.environment["EHDR_STREAM_BGRA"] != "1"
        #else
        let nv12 = true
        #endif
        let program = ProgramOutput(canvas: output.canvas, size: output.size, fps: output.fps, nv12: nv12)
        guard program.isReady else { encoder.finish(); log("stream: program buffer preallocation failed"); return nil }
        program.picture = { [weak self] size, sources, ns in
            self?.renderer.livePicture(canvas: output.canvas, size: size, sources: sources, atNs: ns) ?? LivePicture()
        }
        program.camera = { [weak self] in self?.renderer.overlay.camera?.latest }
        program.onLeasedFrame = { [weak encoder] pb, ns, release in
            guard let encoder else { release(); return }; encoder.encode(pb, hostNs: ns, onComplete: release)
        }
        let lane = Lane(canvas: output.canvas, program: program, encoder: encoder)
        let publishers = lane.publishers
        encoder.onConfig = { sps, pps in publishers.setConfig(sps, pps).forEach { $0.setVideoConfig(sps: sps, pps: pps) } }
        encoder.onFrame = { bytes, ns, key in publishers.snapshot.items.forEach { $0.sendVideo(bytes, ptsNs: ns, dtsNs: ns, keyframe: key) } }
        encoder.onError = { [weak self, weak lane] status in
            DispatchQueue.main.async {
                guard let self, let lane, self.lanes.contains(where: { $0 === lane }) else { return }
                for publisher in lane.publishers.snapshot.items { self.removePublisher(publisher) }
                self.onLaneError?(lane.canvas, "H.264 recovery failed (\(status))")
            }
        }
        encoder.onRecovery = { [weak self, weak lane] in
            DispatchQueue.main.async {
                guard let self, let lane, self.lanes.contains(where: { $0 === lane }) else { return }
                self.onRecovery?(lane.canvas)
            }
        }
        return lane
    }

    private final class Lane {
        let canvas: Canvas, program: ProgramOutput, encoder: VideoEncoder
        let publishers = PublisherList()
        init(canvas: Canvas, program: ProgramOutput, encoder: VideoEncoder) { self.canvas = canvas; self.program = program; self.encoder = encoder }
    }

    /// Publishers shared between main (membership) and the encoder and mixer queues (fan-out).
    private final class PublisherList {
        private let lock = NSLock()
        private var items: [RTMPPublisher] = []
        private var config: (Data, Data)?
        var snapshot: (items: [RTMPPublisher], config: (Data, Data)?) { lock.lock(); defer { lock.unlock() }; return (items, config) }
        var isEmpty: Bool { snapshot.items.isEmpty }
        func contains(_ p: RTMPPublisher) -> Bool { snapshot.items.contains { $0 === p } }
        /// Returns the video configuration seen so far, if any.
        @discardableResult func add(_ p: RTMPPublisher) -> (Data, Data)? { lock.lock(); defer { lock.unlock() }; items.append(p); return config }
        func remove(_ p: RTMPPublisher) { lock.lock(); items.removeAll { $0 === p }; lock.unlock() }
        func removeAll() { lock.lock(); items = []; lock.unlock() }
        func setConfig(_ sps: Data, _ pps: Data) -> [RTMPPublisher] { lock.lock(); defer { lock.unlock() }; config = (sps, pps); return items }
    }
}
