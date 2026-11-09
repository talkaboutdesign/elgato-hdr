import Foundation
import os.lock

struct Meter { var peak: Float = 0; var rms: Float = 0 }

final class MixerInput {
    private let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
    private let ring: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let capacity: Int
    let sampleRate: Double
    private var written: Int64 = 0
    private var newestNs: UInt64 = 0
    private var firstNs: UInt64?
    private var level: Float = 1
    private var mute = false
    private var delay: Double = 0
    private var reading: Double?
    private var filteredError = 0.0
    private var ratio = 1.0
    private var misses = 0
    private var jumps = 0
    private var measured = Meter()

    init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate; capacity = Int(sampleRate * 2)
        scratch = .allocate(capacity: capacity * 2)
        ring = .allocate(capacity: capacity * 2); ring.initialize(repeating: 0, count: capacity * 2)
        lock.initialize(to: os_unfair_lock_s())
    }
    deinit { scratch.deallocate(); ring.deallocate(); lock.deinitialize(count: 1); lock.deallocate() }
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return body()
    }
    var gain: Float { get { locked { level } } set { locked { level = newValue.isFinite ? min(4, max(0, newValue)) : 0 } } }
    var muted: Bool { get { locked { mute } } set { locked { mute = newValue } } }
    var delayMs: Double { get { locked { delay } } set { locked { delay = newValue.isFinite ? min(1000, max(0, newValue)) : 0 } } }
    var meter: Meter { locked { measured } }
    var underruns: Int { locked { misses } }
    var hardCorrections: Int { locked { jumps } }
    var driftPPM: Double { locked { (ratio - 1) * 1e6 } }
    var startNs: UInt64? { locked { firstNs } }

    func push(_ samples: UnsafePointer<Float>, frames: Int, endHostNs: UInt64) {
        append(frames: frames, endHostNs: endHostNs) { samples[$0 * 2 + $1] }
    }
    func pushFloatMono(_ samples: UnsafePointer<Float>, frames: Int, endHostNs: UInt64) {
        append(frames: frames, endHostNs: endHostNs) { i, _ in samples[i] }
    }
    func pushInt16Stereo(_ bytes: UnsafeRawPointer, byteCount: Int, endHostNs: UInt64) {
        append(frames: byteCount / 4, endHostNs: endHostNs) { i, c in
            Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: (i * 2 + c) * 2, as: Int16.self))) / 32768
        }
    }
    private func append(frames: Int, endHostNs: UInt64, sample: (Int, Int) -> Float) {
        guard frames > 0 else { return }
        locked {
            // A gap in capture is not a long stretch of contiguous audio. Discard stale history.
            let expected = Double(frames) / sampleRate * 1e9
            if written > 0 && abs(Double(endHostNs) - Double(newestNs) - expected) > 150e6 {
                written = 0; reading = nil; firstNs = nil; filteredError = 0; ratio = 1
            }
            if firstNs == nil { firstNs = UInt64(max(0, Double(endHostNs) - Double(frames - 1) / sampleRate * 1e9)) }
            for i in max(0, frames - capacity)..<frames {
                let index = Int((written + Int64(i)) % Int64(capacity)) * 2
                ring[index] = sample(i, 0); ring[index + 1] = sample(i, 1)
            }
            written += Int64(frames); newestNs = endHostNs
        }
    }

    // Rendering is serialized by AudioMixer. Copy only the required ring span under the
    // input lock, so the capture thread never waits on mixing, meters or a callback.
    func mix(into output: UnsafeMutablePointer<Float>, frames: Int, startHostNs: UInt64) {
        let snapshot: (fraction: Double, ratio: Double, amplitude: Float, count: Int)? = locked {
            guard written > 0 else { misses += 1; measured = Meter(); return nil }
            let wanted = Double(written - 1) - (Double(newestNs) - Double(startHostNs) + delay * 1e6) * sampleRate / 1e9
            if reading == nil { reading = wanted; filteredError = 0; ratio = 1 }
            var position = reading!
            let error = wanted - position
            if abs(error) > sampleRate * 0.150 {
                position = wanted; filteredError = 0; jumps += 1
            } else {
                let alpha = 1 - exp(-Double(frames) / sampleRate / 2)
                filteredError += alpha * (error - filteredError)
                if abs(filteredError) < 1e-10 { filteredError = 0 }
            }
            ratio = 1 + min(0.005, max(-0.005, filteredError / (sampleRate * 2)))
            let oldest = Double(max(0, written - Int64(capacity)))
            let last = position + Double(frames - 1) * ratio
            guard position >= oldest - 0.0001, ceil(last - 0.0001) < Double(written), frames <= capacity - 2 else {
                misses += 1; reading = nil; measured = Meter(); return nil
            }
            position = max(oldest, position)
            let first = Int64(floor(position))
            let count = Int(min(Int64(ceil(last)), written - 1) - first + 1)
            guard count > 0 && count <= capacity else { misses += 1; reading = nil; measured = Meter(); return nil }
            let offset = Int(first % Int64(capacity))
            let head = min(count, capacity - offset)
            scratch.update(from: ring + offset * 2, count: head * 2)
            if head < count { (scratch + head * 2).update(from: ring, count: (count - head) * 2) }
            reading = position + Double(frames) * ratio
            return (position - Double(first), ratio, mute ? 0 : level, count)
        }
        guard let snapshot else { return }
        var peak: Float = 0; var squares = 0.0
        for i in 0..<frames {
            let p = snapshot.fraction + Double(i) * snapshot.ratio
            let base = min(Int(p), snapshot.count - 1); let fraction = Float(p - floor(p))
            let a = base * 2; let b = min(base + 1, snapshot.count - 1) * 2
            // Linear interpolation is adequate for the tiny (at most 0.5%) clock corrections.
            for c in 0..<2 {
                let value = (scratch[a + c] + (scratch[b + c] - scratch[a + c]) * fraction) * snapshot.amplitude
                output[i * 2 + c] += value
                peak = max(peak, abs(value)); squares += Double(value * value)
            }
        }
        let rms = Float(sqrt(squares / Double(frames * 2)))
        locked { measured = Meter(peak: peak, rms: rms < 1e-15 ? 0 : rms) }
    }
}
