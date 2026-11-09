import Foundation

final class AudioMixer {
    let sampleRate: Double
    let blockFrames: Int
    private let latencyNs: UInt64
    private let buffer: UnsafeMutablePointer<Float>
    private let state = NSRecursiveLock()
    private let queue = DispatchQueue(label: "studio.audio.mixer", qos: .userInteractive)
    private var inputs: [String: MixerInput] = [:]
    private var timer: DispatchSourceTimer?
    private var epoch: UInt64?
    private var rendered: UInt64 = 0
    private var level: Float = 1
    private var measured = Meter()
    private var callback: ((UnsafePointer<Float>, Int, UInt64) -> Void)?

    init(sampleRate: Double = 48000, blockFrames: Int = 1024, targetLatencyMs: Double = 60) {
        precondition(sampleRate.isFinite && sampleRate > 0 && blockFrames > 0)
        precondition(targetLatencyMs.isFinite && targetLatencyMs >= 0)
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
            let input = MixerInput(sampleRate: sampleRate); inputs[id] = input; return input
        }
    }
    func render(upTo hostNs: UInt64) {
        locked {
            guard hostNs >= latencyNs else { return }
            if epoch == nil {
                for input in inputs.values {
                    if let start = input.startNs { epoch = min(epoch ?? start, start) }
                }
            }
            guard let epoch else { return }
            let deadline = hostNs - latencyNs
            while true {
                let start = epoch + UInt64(Double(rendered) * 1e9 / sampleRate)
                let end = epoch + UInt64(Double(rendered + UInt64(blockFrames)) * 1e9 / sampleRate)
                guard end <= deadline else { break }
                buffer.update(repeating: 0, count: blockFrames * 2)
                for input in inputs.values { input.mix(into: buffer, frames: blockFrames, startHostNs: start) }
                var peak: Float = 0; var squares: Double = 0
                let knee: Float = 0.89125094
                for i in 0..<blockFrames * 2 {
                    let x = buffer[i] * level; let magnitude = abs(x)
                    let excess = max(0, magnitude - knee)
                    let y = magnitude <= knee ? x : (x < 0 ? -1 : 1) * (knee + excess / (1 + excess / (1 - knee)))
                    buffer[i] = y; peak = max(peak, abs(y)); squares += Double(y * y)
                }
                measured = Meter(peak: peak, rms: Float(sqrt(squares / Double(blockFrames * 2))))
                if measured.rms < 1e-15 { measured.rms = 0 }
                rendered += UInt64(blockFrames)
                callback?(UnsafePointer(buffer), blockFrames, start)
            }
        }
    }
    func start() {
        locked {
            guard timer == nil else { return }
            if epoch == nil { epoch = nowNs() }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.render(upTo: nowNs()) }
            timer = source; source.resume()
        }
    }
    func stop() { locked { timer?.cancel(); timer = nil } }
}
