import Foundation

final class AudioMixer {
    let sampleRate: Double
    let blockFrames: Int
    private let latencyNs: UInt64
    private let buffer: UnsafeMutablePointer<Float>
    private let state = NSRecursiveLock()
    private let queue: DispatchQueue
    private let renderLock = NSRecursiveLock()
    private var ordered: [MixerInput] = []
    private var previousLevel: Float?
    private var generation = 0
    private var skipped = 0
    var skippedBlocks: Int { locked { skipped } }
    private var inputs: [String: MixerInput] = [:]
    private var timer: DispatchSourceTimer?
    private var epoch: UInt64?
    private var rendered: UInt64 = 0
    private var level: Float = 1
    private var measured = Meter()
    private var callback: ((UnsafePointer<Float>, Int, UInt64) -> Void)?

    init(sampleRate: Double = 48000, blockFrames: Int = 1024, targetLatencyMs: Double = 60, queue: DispatchQueue = DispatchQueue(label: "studio.audio.mixer", qos: .userInteractive)) {
        precondition(sampleRate.isFinite && sampleRate > 0 && blockFrames > 0)
        precondition(targetLatencyMs.isFinite && targetLatencyMs >= 0)
        self.queue = queue
        self.sampleRate = sampleRate; self.blockFrames = blockFrames
        latencyNs = UInt64(targetLatencyMs * 1e6)
        buffer = .allocate(capacity: blockFrames * 2); buffer.initialize(repeating: 0, count: blockFrames * 2)
    }
    deinit { timer?.cancel(); buffer.deallocate() }
    private func locked<T>(_ body: () -> T) -> T { state.lock(); defer { state.unlock() }; return body() }
    var masterGain: Float { get { locked { level } } set { locked { level = newValue.isFinite ? max(0, newValue) : 0 } } }
    var masterMeter: Meter { locked { measured } }
    /// Runs on the rendering thread. The pointer is valid only during the callback.
    var onBlock: ((UnsafePointer<Float>, Int, UInt64) -> Void)? {
        get { locked { callback } } set { locked { callback = newValue } }
    }
    func addInput(_ id: String) -> MixerInput {
        locked {
            if let existing = inputs[id] { return existing }
            let input = MixerInput(sampleRate: sampleRate); inputs[id] = input; ordered.append(input); return input
        }
    }
    func render(upTo hostNs: UInt64) { render(upTo: hostNs, generation: nil) }
    func render(upTo hostNs: UInt64, generation expected: Int?) {
        renderLock.lock(); defer { renderLock.unlock() }
        for _ in 0..<8 {
            let snapshot: ([MixerInput], Float, ((UnsafePointer<Float>, Int, UInt64) -> Void)?, UInt64)? = locked {
                if let expected, timer == nil || expected != generation { return nil }
                guard hostNs >= latencyNs else { return nil }
                if epoch == nil {
                    for input in ordered { if let start = input.startNs { epoch = min(epoch ?? start, start) } }
                }
                guard let base = epoch else { return nil }
                let deadline = hostNs - latencyNs
                guard deadline >= base else { return nil }
                let due = UInt64(Double(deadline - base) * sampleRate / 1e9 + 0.0001)
                if due > rendered + UInt64(8 * blockFrames) {
                    let blocks = (due - rendered) / UInt64(blockFrames) - 8
                    rendered += blocks * UInt64(blockFrames); skipped += Int(blocks)
                    for input in ordered { input.resetReadState() }
                }
                guard rendered + UInt64(blockFrames) <= due else { return nil }
                let start = base + UInt64(Double(rendered) * 1e9 / sampleRate)
                rendered += UInt64(blockFrames)
                return (ordered, level, callback, start)
            }
            guard let (inputs, gain, callback, start) = snapshot else { return }
            buffer.update(repeating: 0, count: blockFrames * 2)
            for input in inputs { input.mix(into: buffer, frames: blockFrames, startHostNs: start) }
            var peak: Float = 0; var squares: Double = 0
            let knee: Float = 0.89125094, old = previousLevel ?? gain
            for i in 0..<blockFrames * 2 {
                let ramp = old + (gain - old) * Float(i / 2 + 1) / Float(blockFrames)
                let x = buffer[i] * ramp; let magnitude = abs(x)
                let excess = max(0, magnitude - knee)
                let y = magnitude <= knee ? x : (x < 0 ? -1 : 1) * (knee + excess / (1 + excess / (1 - knee)))
                buffer[i] = y; peak = max(peak, abs(y)); squares += Double(y * y)
            }
            previousLevel = gain
            locked { measured = Meter(peak: peak, rms: Float(sqrt(squares / Double(blockFrames * 2)))) }
            callback?(UnsafePointer(buffer), blockFrames, start)
        }
    }
    func start() {
        renderLock.lock(); defer { renderLock.unlock() }
        locked {
            guard timer == nil else { return }
            epoch = nowNs() - min(nowNs(), latencyNs); rendered = 0
            for input in ordered { input.resetReadState() }
            generation += 1; let token = generation
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.render(upTo: nowNs(), generation: token) }
            timer = source; source.resume()
        }
    }
    func stop() { locked { timer?.cancel(); timer = nil; generation += 1 } }
}
