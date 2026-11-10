import Foundation
import AVFoundation
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
    private var inUnderrun = false
    private var previousGain: Float?
    private var previousMute: Float = 1
    private var appliedDelay = 0.0
    private var fadePosition: Double?
    private var fadeRemaining = 0
    private var mapOrigin = 0.0
    private var meanX = 0.0, meanY = 0.0, variance = 0.0, covariance = 0.0
    private var mapRate = 1.0
    private var observations = 0
    private var rejected = 0
    private let pcmLock = NSLock()
    private let pcmList = AudioBufferList.allocate(maximumBuffers: 2)
    private let pcmScratch = UnsafeMutablePointer<Float>.allocate(capacity: 192000)
    var rejectedBuffers: Int { locked { rejected } }
    var readPosition: Double? { locked { reading } }
    func resetReadState() { locked { reading = nil; fadePosition = nil; fadeRemaining = 0; filteredError = 0 } }


    init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate; capacity = Int(sampleRate * 2)
        scratch = .allocate(capacity: capacity * 2)
        ring = .allocate(capacity: capacity * 2); ring.initialize(repeating: 0, count: capacity * 2)
        lock.initialize(to: os_unfair_lock_s())
    }
    deinit { pcmList.unsafeMutablePointer.deallocate(); pcmScratch.deallocate(); scratch.deallocate(); ring.deallocate(); lock.deinitialize(count: 1); lock.deallocate() }
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
            let x = Double(written + Int64(frames) - 1)
            if observations == 0 { mapOrigin = Double(endHostNs) - x * 1e9 / sampleRate }
            let y = (Double(endHostNs) - mapOrigin) * sampleRate / 1e9
            let predicted = meanY + (x - meanX) / mapRate
            // Timestamp noise is bounded at ±8 ms. A larger positive residual is lost PCM,
            // not clock drift; insert time into the ring before updating the clock estimate.
            let missing = observations > 0 ? max(0, Int(((y - predicted) * mapRate).rounded())) : 0
            let gap = missing > Int(sampleRate * 0.020) ? missing : 0
            if gap > 0 {
                for i in 0..<min(gap, capacity) {
                    let index = Int((written + Int64(i)) % Int64(capacity)) * 2
                    ring[index] = 0; ring[index + 1] = 0
                }
                written += Int64(gap)
            }
            let adjustedX = Double(written + Int64(frames) - 1)
            // Exponentially weighted regression locks quickly, then averages several seconds
            // of arrival jitter without interpreting it as a sample-clock change.
            let weight = max(1 / Double(observations + 1), 1 - exp(-Double(frames) / sampleRate / 5))
            let dx = adjustedX - meanX, dy = y - meanY
            variance = (1 - weight) * (variance + weight * dx * dx)
            covariance = (1 - weight) * (covariance + weight * dx * dy)
            meanX += weight * dx; meanY += weight * dy; observations += 1
            if variance > sampleRate * sampleRate && covariance > 0 {
                mapRate = min(1.005, max(0.995, variance / covariance))
            }
            if firstNs == nil { firstNs = UInt64(max(0, Double(endHostNs) - Double(frames - 1) / sampleRate * 1e9)) }
            for i in max(0, frames - capacity)..<frames {
                let index = Int((written + Int64(i)) % Int64(capacity)) * 2
                ring[index] = sample(i, 0); ring[index + 1] = sample(i, 1)
            }
            written += Int64(frames); newestNs = endHostNs
        }
    }

    func push(_ sampleBuffer: CMSampleBuffer, endHostNs: UInt64) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 48000,
              format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2,
              format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { locked { rejected += 1 }; return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= 96000 else { locked { rejected += 1 }; return }
        pcmLock.lock(); defer { pcmLock.unlock() }
        let channels = Int(format.mChannelsPerFrame)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && channels == 2
        let list = pcmList
        list.unsafeMutablePointer.pointee.mNumberBuffers = planar ? 2 : 1
        list[0] = AudioBuffer(mNumberChannels: planar ? 1 : UInt32(channels), mDataByteSize: UInt32(frames * (planar ? 1 : channels) * 4), mData: pcmScratch)
        if planar { list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pcmScratch + 96000) }
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: list.unsafeMutablePointer) == noErr else { locked { rejected += 1 }; return }
        append(frames: frames, endHostNs: endHostNs) { i, c in
            self.pcmScratch[planar ? i + c * 96000 : i * channels + (channels == 1 ? 0 : c)]
        }
    }

    // Render into preallocated scratch under the input lock. No callback or I/O holds it.
    func mix(into output: UnsafeMutablePointer<Float>, frames: Int, startHostNs: UInt64) {
        guard frames > 0, frames <= capacity else { return }
        let settings: (Float, Float, Float, Float, Double, Double?, Int, Double, Int)? = locked {
            guard written > 0 else { measured = Meter(); return nil }
            let hostFrame = (Double(startHostNs) - mapOrigin) * sampleRate / 1e9
            let wanted = meanX + (hostFrame - meanY) * mapRate - delay * sampleRate / 1000
            if reading == nil { reading = wanted; appliedDelay = delay; filteredError = 0 }
            if delay != appliedDelay {
                fadePosition = reading
                reading! -= (delay - appliedDelay) * sampleRate / 1000
                appliedDelay = delay; fadeRemaining = Int(sampleRate * 0.015)
            }
            var position = reading!
            let error = wanted - position
            if abs(error) > sampleRate * 0.150 {
                position = wanted; filteredError = 0; jumps += 1
            } else {
                filteredError += (1 - exp(-Double(frames) / sampleRate / 2)) * (error - filteredError)
            }
            ratio = min(1.005, max(0.995, mapRate + filteredError / (sampleRate * 2)))
            let oldest = Double(max(0, written - Int64(capacity)))
            let last = position + Double(frames - 1) * ratio
            guard position >= oldest - 0.0001, ceil(last - 0.0001) < Double(written) else {
                if !inUnderrun { misses += 1 }; inUnderrun = true
                reading = nil; measured = Meter(); return nil
            }
            inUnderrun = false
            let first = Int64(floor(max(oldest, min(position, fadeRemaining > 0 ? fadePosition! : position))))
            let end = min(written - 1, Int64(ceil(max(last, fadeRemaining > 0 ? fadePosition! + Double(frames) * ratio : last))))
            let count = Int(end - first + 1), offset = Int(first % Int64(capacity))
            guard count > 0 && count <= capacity else { return nil }
            let head = min(count, capacity - offset)
            scratch.update(from: ring + offset * 2, count: head * 2)
            if head < count { (scratch + head * 2).update(from: ring, count: (count - head) * 2) }
            let fade = fadeRemaining > 0 ? fadePosition! - Double(first) : nil
            let remaining = fadeRemaining
            if fadeRemaining > 0 { fadePosition! += Double(frames) * ratio; fadeRemaining = max(0, fadeRemaining - frames) }
            reading = position + Double(frames) * ratio
            let old = previousGain ?? level, oldMute = previousGain == nil ? (mute ? Float(0) : 1) : previousMute
            previousGain = level; previousMute = mute ? 0 : 1
            return (old, level, oldMute, previousMute, max(0, position - Double(first)), fade, remaining, ratio, count)
        }
        guard let (old, gain, oldMute, mute, position, fade, remaining, step, count) = settings else { return }
        var peak: Float = 0; var squares = 0.0
        for i in 0..<frames {
            let t = Float(i + 1) / Float(frames)
            let p = position + Double(i) * step
            let a = min(Int(p), count - 1), b = min(a + 1, count - 1), fraction = Float(p - floor(p))
            let blend = Float(max(0, remaining - i)) / Float(Int(sampleRate * 0.015))
            let fp = max(0, (fade ?? 0) + Double(i) * step)
            let fa = min(Int(fp), count - 1), fb = min(fa + 1, count - 1), ff = Float(fp - floor(fp))
            for c in 0..<2 {
                let fresh = scratch[a * 2 + c] + (scratch[b * 2 + c] - scratch[a * 2 + c]) * fraction
                let prior = blend > 0 ? scratch[fa * 2 + c] + (scratch[fb * 2 + c] - scratch[fa * 2 + c]) * ff : 0
                let v = (fresh * (1 - blend) + prior * blend) * (old + (gain - old) * t)
                peak = max(peak, abs(v)); squares += Double(v * v)
                output[i * 2 + c] += v * (oldMute + (mute - oldMute) * t)
            }
        }
        locked { measured = Meter(peak: peak, rms: Float(sqrt(squares / Double(frames * 2)))) }
    }
}
