import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

// MARK: - Audio playback

/// All AVAudioEngine / player-node mutation happens on `engineQueue`. The main thread never touches
/// AVFAudio teardown, so an output-device change cannot block it (and thus cannot freeze the display).
final class AudioPlayer {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let engineQueue = DispatchQueue(label: "audio-engine")
    var queuedFrames: Int = 0
    let maxQueuedFrames = 48000 * 150 / 1000   // trim above 150 ms of backlog
    let lock = NSLock()
    var _muted = false
    var muted: Bool {
        get { _muted }
        set { _muted = newValue; let v: Float = newValue ? 0 : 1; engineQueue.async { [self] in engine.mainMixerNode.outputVolume = v } }
    }
    var running = false
    var rebuildGen = 0
    var pushed = 0, dropped = 0; var lastStat = Date()

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // queue nil => block runs on the notifying thread; we only redispatch, so it never blocks anyone.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.rebuild(reason: "device/format change")
        }
    }

    /// Bring the engine up (idempotent). Runs on engineQueue.
    private func startLocked() {
        if running && engine.isRunning { return }
        do {
            try engine.start()
            if !player.isPlaying { player.play() }
            engine.mainMixerNode.outputVolume = _muted ? 0 : 1
            running = true
        } catch { log("audio engine start failed: \(error)"); running = false }
    }
    func ensureStarted() { engineQueue.async { [self] in startLocked() } }

    /// Rebuild the graph for the new output device. Never called on the main thread's critical path.
    func rebuild(reason: String) {
        rebuildGen += 1; let gen = rebuildGen
        engineQueue.async { [self] in
            guard gen == rebuildGen else { return }   // collapse a burst of change notifications
            player.stop(); engine.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            lock.lock(); queuedFrames = 0; lock.unlock()
            startLocked()
            log("audio engine rebuilt (\(reason)) on \(engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
        }
    }

    func stop() { engineQueue.async { [self] in player.stop(); engine.stop(); running = false } }

    /// Interleaved signed 16-bit stereo, 48 kHz. Called on the reader thread.
    func push(_ bytes: UnsafeRawPointer, _ count: Int) {
        ensureStarted()
        let frames = count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        lock.lock(); let backlog = queuedFrames; lock.unlock()
        pushed += 1
        if Date().timeIntervalSince(lastStat) >= 5 { log(String(format: "audio: %d chunks, %d dropped, backlog %.0f ms", pushed, dropped, Double(backlog) / 48.0)); lastStat = Date() }
        if backlog > maxQueuedFrames { dropped += 1; return }
        buf.frameLength = AVAudioFrameCount(frames)
        let src = bytes.assumingMemoryBound(to: Int16.self)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        let scale: Float = 1.0 / 32768.0
        for i in 0..<frames { l[i] = Float(Int16(littleEndian: src[2*i])) * scale; r[i] = Float(Int16(littleEndian: src[2*i+1])) * scale }
        // Schedule on engineQueue so buffer scheduling never races with a rebuild's stop/reconnect.
        engineQueue.async { [self] in
            guard running, engine.isRunning else { return }
            lock.lock(); queuedFrames += frames; lock.unlock()
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock(); self.queuedFrames -= frames; self.lock.unlock()   // counter only; no transport calls
            }
        }
    }
}

