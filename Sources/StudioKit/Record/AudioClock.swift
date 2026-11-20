import Foundation

/// Keeps a sample-counted audio track on the recording's host clock.
///
/// A writer places audio by counting samples (`start + written / rate`), but the samples come from a device with its
/// own clock and arrive in chunks stamped with host time. `place` compares where the next chunk would land with where
/// its arrival says it belongs, and returns how to adjust the chunk so the count keeps following the host clock.
///
/// What it tracks: the long-term rate difference between the two clocks, tens of parts per million for a healthy
/// device, not the error of any one chunk. USB arrival times jitter by several milliseconds and occasionally stall
/// and catch up in a burst; reacting to that would wobble the pitch. So the per-chunk error is smoothed over seconds
/// (each chunk's pull on the average is clamped, so a stall barely moves it), ignored inside a dead band, and corrected
/// at a rate proportional to it but capped far below audibility. A real gap (lost chunks) shows as an offset that every
/// chunk agrees on for a quarter of a second; that is filled with silence, or cut, in one step instead of being slewed
/// for minutes.
struct AudioClock {
    /// How to write one chunk, applied in this order.
    struct Step: Equatable {
        /// Samples to discard from the front of the chunk: before the recording started, or audio running ahead.
        var discard = 0
        /// Silence to write before the chunk: audio fell behind because samples were lost.
        var silence = 0
        /// Samples to add inside the chunk (audio slightly behind: its clock is slower than the host's).
        var insert = 0
        /// Samples to take out of the chunk (audio slightly ahead: its clock is faster than the host's).
        var remove = 0
    }

    /// Arrival-time smoothing. 5 s averages USB jitter of ±8 ms down to about 0.2 ms while lagging a 100 ppm drift by
    /// only 0.5 ms.
    static let smoothing = 5.0
    /// One chunk moves the average by at most this much error, so a stall that delays a few chunks by 100 ms is
    /// not mistaken for drift.
    static let pullLimit = 0.010
    /// Correction starts once the smoothed error passes `startBand` and stops inside `stopBand`: well above the
    /// residual jitter, well below anything audible as lip sync (about 45 ms).
    static let startBand = 0.002, stopBand = 0.0005
    /// The correction rate is the error divided by this, so a steady drift is followed with a sub-millisecond lag.
    static let response = 8.0
    /// Ceiling for the correction rate: 1000 ppm is 1.7 cents of pitch, below what can be heard; a 1% slew is a step.
    static let maxRate = 0.001
    /// An offset that every chunk agrees on for `gapConfirm` of audio and that is larger than `gapThreshold` is a gap.
    /// A USB stall delays chunks and then delivers them in a burst, so its error falls back within one burst (the
    /// helper queues at most 128 ms); lost samples keep the offset. Below the threshold, slewing at `maxRate` takes at
    /// most half a minute.
    static let gapThreshold = 0.030, gapConfirm = 0.25
    /// The first chunk's arrival latency sets where the track starts; the first seconds measure how far that chunk was
    /// from the typical latency, and up to `maxBias` of it is accepted as the reference instead of being corrected.
    static let warmup = 4.0, maxBias = 0.010

    let rate: Double
    /// Recording seconds of the first sample written; nil until the first chunk.
    private(set) var start: Double?
    /// Samples written so far, corrections included.
    private(set) var written: Int64 = 0
    /// For the log: net samples added by slewing (negative: removed), silence written, samples cut, gaps handled.
    private(set) var slewed = 0, filled = 0, cut = 0, gaps = 0
    private var smoothed = 0.0, bias = 0.0, observed = 0.0
    private var correcting = false, locked = false
    private var owed = 0.0
    private var pendingSilence = 0, pendingDiscard = 0
    private var runFrames = 0, runSign = 0, run: [Double] = []

    init(rate: Double = 48000) { self.rate = rate }

    /// Where the next sample goes, in recording seconds.
    var next: Double { (start ?? 0) + Double(written) / rate }

    /// The writer could not take a chunk it was given (backpressure). Its time is filled with silence before the next.
    mutating func lost(frames: Int) { if start != nil { pendingSilence += frames } }

    /// The plan for a chunk of `frames` samples whose last sample arrived at `end` (recording seconds). The caller
    /// writes exactly what the step says; `written` is advanced accordingly.
    mutating func place(frames n: Int, end: Double) -> Step {
        var step = Step()
        guard n > 0 else { return step }
        let arrivedStart = end - Double(n) / rate
        guard let start else {
            // Samples that precede the recording start are trimmed; the track starts with the first one kept.
            step.discard = arrivedStart < 0 ? min(n, Int((-arrivedStart * rate).rounded(.up))) : 0
            guard step.discard < n else { return step }
            self.start = arrivedStart + Double(step.discard) / rate
            written = Int64(n - step.discard)
            return step
        }
        step.silence = pendingSilence; filled += pendingSilence; written += Int64(pendingSilence); pendingSilence = 0
        let duration = Double(n) / rate
        observed += duration
        // Positive: fewer samples written than time has passed, audio is behind.
        let behind = arrivedStart - (start + Double(written) / rate)
        let offset = behind - bias, deviation = offset - smoothed

        if abs(deviation) > Self.gapThreshold {
            // Outside any jitter: a stall (the following chunks come back) or a gap (they stay). Not averaged.
            let sign = deviation > 0 ? 1 : -1
            if sign != runSign { runSign = sign; runFrames = 0; run = [] }
            runFrames += n; run.append(abs(deviation))
            if Double(runFrames) / rate >= Self.gapConfirm {
                // The median: each chunk's error still carries its own arrival jitter.
                let samples = Int((run.sorted()[run.count / 2] * rate).rounded())
                if sign > 0 { step.silence += samples; filled += samples; written += Int64(samples) }
                else { pendingDiscard += samples; cut += samples }
                gaps += 1; runSign = 0; runFrames = 0; run = []
            }
        } else if !locked {
            // Warm-up: a plain running mean, then the first chunk's distance from it becomes the reference.
            runSign = 0; runFrames = 0
            smoothed += duration / observed * deviation
            if observed >= Self.warmup {
                let b = max(-Self.maxBias, min(Self.maxBias, smoothed))
                bias += b; smoothed -= b; locked = true
            }
        } else {
            runSign = 0; runFrames = 0
            smoothed += (1 - exp(-duration / Self.smoothing)) * max(-Self.pullLimit, min(Self.pullLimit, deviation))
            if !correcting && abs(smoothed) > Self.startBand { correcting = true }
            if correcting && abs(smoothed) < Self.stopBand { correcting = false; owed = 0 }
            if correcting {
                owed += max(-Self.maxRate, min(Self.maxRate, smoothed / Self.response)) * Double(n)
                let whole = Int(owed)            // toward zero: the fraction carries to the next chunk
                owed -= Double(whole)
                if whole > 0 { step.insert = whole } else { step.remove = -whole }
            }
        }
        step.discard = min(n, pendingDiscard); pendingDiscard -= step.discard
        let kept = n - step.discard
        step.insert = min(step.insert, kept / 4); step.remove = min(step.remove, kept / 4)
        slewed += step.insert - step.remove
        written += Int64(kept + step.insert - step.remove)
        return step
    }
}

extension AudioClock.Step {
    var isEmpty: Bool { self == AudioClock.Step() }

    /// The chunk rewritten by this step. `frames` holds interleaved samples, `channels` per frame. An added sample is
    /// the average of its neighbours and a removed pair becomes their average, spread evenly over the chunk, so a
    /// correction is a fraction of a sample's slope instead of a jump.
    func apply<T>(to frames: UnsafeBufferPointer<T>, channels: Int, zero: T, mid: (T, T) -> T) -> [T] {
        let n = frames.count / channels
        let body = discard < n ? discard..<n : n..<n
        let k = body.count
        var out: [T] = []
        out.reserveCapacity((silence + k + insert) * channels)
        out.append(contentsOf: repeatElement(zero, count: silence * channels))
        func frame(_ i: Int, _ c: Int) -> T { frames[(body.lowerBound + i) * channels + c] }
        // Where the j-th adjustment lands: evenly spaced at least two frames apart (`AudioClock` keeps either count
        // to a quarter of the chunk), never on the last frame, which has no right neighbour.
        let count = insert > 0 ? insert : remove
        var marks = Set<Int>()
        for j in 0..<count { marks.insert((j + 1) * k / (count + 1)) }
        var i = 0
        while i < k {
            if insert > 0, marks.contains(i) {
                for c in 0..<channels { out.append(frame(i, c)) }
                for c in 0..<channels { out.append(mid(frame(i, c), frame(i + 1, c))) }
                i += 1
            } else if remove > 0, marks.contains(i) {
                for c in 0..<channels { out.append(mid(frame(i, c), frame(i + 1, c))) }
                i += 2
            } else {
                for c in 0..<channels { out.append(frame(i, c)) }
                i += 1
            }
        }
        return out
    }
}
