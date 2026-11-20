import AppKit
import AVFoundation
import QuartzCore

// Transport: play, shuttle, frame steps and scrubbing. The preview item is the whole recording (source time), so
// playback skips removed sections itself: a boundary observer at each kept range's end jumps to the next one.
extension EditorModel {
    var keptSeconds: [(start: Double, end: Double)] { TimelineEdits.kept(project).map { ($0.startMs / 1000, $0.endMs / 1000) } }

    func playerTimeChanged(_ t: Double) {
        let rate = player.rate
        if rate == 0 && reverseTimer == nil {
            if playing { playing = false }
            if shuttleRate != 0 { shuttleRate = 0 }
            // A paused player reports the seeks it is working through; the playhead shows the target instead.
            if !seekInFlight && pendingSeek == nil && !scrubbing && abs(time - t) > 0.0005 { time = t }
            return
        }
        guard reverseTimer == nil else { return }
        if !playing { playing = true }
        if rate > 0, let jump = nextKeptStart(from: t) {
            if jump.isNaN { stopAtEnd(); return }
            player.seek(to: CMTime(seconds: jump, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            time = jump
        } else {
            time = t
        }
        var a = axis; a.reveal(time)
        if a != axis { axis = a }
    }

    /// Where forward playback continues from `t`: nil while inside a kept range, NaN after the last one.
    private func nextKeptStart(from t: Double) -> Double? {
        let kept = keptSeconds, eps = frameDuration * 0.25
        if kept.contains(where: { t >= $0.start - eps && t < $0.end - eps }) { return nil }
        return kept.first { $0.start > t - eps }?.start ?? .nan
    }

    private func stopAtEnd() {
        player.pause(); playing = false; shuttleRate = 0
        if let end = keptSeconds.last?.end { seek(end - frameDuration) }
    }

    /// Playback limits and the jump points between kept ranges; called when cuts change.
    func applyPlaybackBounds() {
        guard let item = player.currentItem else { return }
        let kept = keptSeconds
        item.forwardPlaybackEndTime = kept.last.map { CMTime(seconds: $0.end, preferredTimescale: 60000) } ?? .invalid
        item.reversePlaybackEndTime = kept.first.map { CMTime(seconds: $0.start, preferredTimescale: 60000) } ?? .invalid
        if let o = boundaryObserver { player.removeTimeObserver(o); boundaryObserver = nil }
        let ends = kept.dropLast().map { NSValue(time: CMTime(seconds: $0.end, preferredTimescale: 60000)) }
        guard !ends.isEmpty else { return }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: ends, queue: .main) { [weak self] in
            guard let self = self, self.player.rate > 0 else { return }
            self.playerTimeChanged(self.player.currentTime().seconds + self.frameDuration * 0.5)
        }
    }

    func togglePlay() {
        if playing || player.rate != 0 || reverseTimer != nil { pause(); return }
        play(rate: 1)
    }

    func pause() {
        stopReverse()
        player.pause()
        playing = false; shuttleRate = 0
        seek(time)   // land on a whole frame
    }

    func play(rate: Float) {
        stopReverse()
        let kept = keptSeconds
        guard let first = kept.first, let last = kept.last else { NSSound.beep(); return }
        if rate > 0 {
            // From the end, start over; from inside a removed section, start at the next kept frame.
            if time >= last.end - frameDuration { seek(first.start) }
            else if let next = nextKeptStart(from: time) { seek(next.isNaN ? first.start : next) }
        }
        player.playImmediately(atRate: rate)
        playing = true; shuttleRate = rate
    }

    /// J and L: each press doubles the speed in that direction (1×, 2×, 4×); K stops.
    func shuttle(forward: Bool) {
        let r = shuttleRate
        let next: Float = forward ? (r <= 0 ? 1 : min(4, r * 2)) : (r >= 0 ? -1 : max(-4, r * 2))
        if next < 0 && !(player.currentItem?.canPlayReverse ?? false) { reverse(rate: Double(-next)); return }
        play(rate: next)
    }

    /// Reverse shuttle by seeking backwards when the item cannot play in reverse.
    private func reverse(rate: Double) {
        player.pause()
        stopReverse()
        playing = true; shuttleRate = Float(-rate)
        let started = CACurrentMediaTime(), from = time
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let target = from - (CACurrentMediaTime() - started) * rate
            let floor = self.keptSeconds.first?.start ?? 0
            if target <= floor { self.stopReverse(); self.playing = false; self.shuttleRate = 0; self.seek(floor); return }
            self.seek(target, quantize: false)
        }
        RunLoop.main.add(t, forMode: .common)
        reverseTimer = t
    }
    private func stopReverse() { reverseTimer?.invalidate(); reverseTimer = nil }

    /// Where the playhead may rest. While removed footage is hidden it never rests inside it: a time there moves to
    /// the first kept frame after the cut (`forward`) or the last one before it, and past either end of the kept
    /// footage to its first or last frame. With removed footage shown, any time.
    func keptPlayhead(_ t: Double, forward: Bool) -> Double {
        let kept = keptSeconds, eps = 1e-6
        guard hideRemoved, let first = kept.first, let last = kept.last else { return t }
        func lastFrame(_ r: (start: Double, end: Double)) -> Double { max(r.start, r.end - frameDuration) }
        if kept.contains(where: { t >= $0.start - eps && t < $0.end - eps }) { return t }
        if t < first.start { return first.start }
        if t >= last.end - eps { return lastFrame(last) }
        if forward, let next = kept.first(where: { $0.start > t }) { return next.start }
        if let prev = kept.last(where: { $0.end <= t + eps }) { return lastFrame(prev) }
        return first.start
    }

    /// ←/→ step through the decoder (no keyframe round trip); the time observer reports the new frame. Across a
    /// seam the decoder would walk into removed footage, so that step seeks to the other side instead.
    func step(frames n: Int) {
        if playing { pause() }
        let next = min(max(0, time + Double(n) * frameDuration), duration)
        if hideRemoved && keptPlayhead(next, forward: n > 0) != next { seek(next); return }
        if let item = player.currentItem, !seekInFlight, pendingSeek == nil, n > 0 ? item.canStepForward : item.canStepBackward {
            let target = min(max(0, time + Double(n) * frameDuration), duration)
            time = (target / frameDuration).rounded() * frameDuration
            var a = axis; a.reveal(time)
            if a != axis { axis = a }
            item.step(byCount: n)
        } else {
            seek(time + Double(n) * frameDuration)
        }
    }
    /// ⇧←/⇧→: a second of the timeline, which is a second of kept footage while removed footage is hidden.
    func jump(seconds s: Double) {
        if playing { pause() }
        guard hideRemoved else { seek(time + s); return }
        let map = TimeMap(segments: TimelineEdits.kept(project), sourceDurationMs: project.durationMs, frameMs: frameDuration * 1000)
        let e = shownSeconds(time) + s
        seek(e >= map.durationMs / 1000 ? duration : map.source(fromTimeline: max(0, e) * 1000) / 1000)
    }

    /// Moves the playhead. The model shows the target at once; the player follows with at most one seek in flight.
    /// `fast` (while scrubbing) lets the player show the nearest keyframe: recordings have a two-second GOP with
    /// B-frames, so an exact seek decodes up to 120 frames. When the pointer rests or lets go, an exact seek lands on
    /// the frame.
    func seek(_ s: Double, quantize: Bool = true, fast: Bool = false) {
        let d = duration > 0 ? duration : project.durationMs / 1000
        var t = min(max(0, s), max(0, d - frameDuration * 0.5))
        if quantize { t = (t / frameDuration).rounded() * frameDuration }
        t = keptPlayhead(t, forward: t >= time)
        time = t
        var a = axis; a.reveal(t)
        if a != axis { axis = a }
        settleWork?.cancel(); settleWork = nil
        requestSeek(CMTime(seconds: t, preferredTimescale: 60000), fast: fast)
        if fast {
            let w = DispatchWorkItem { [weak self] in self?.settle() }
            settleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        }
    }

    /// The exact frame at the playhead, after fast seeks.
    func settle() {
        settleWork?.cancel(); settleWork = nil
        requestSeek(CMTime(seconds: time, preferredTimescale: 60000), fast: false)
    }

    func requestSeek(_ target: CMTime, fast: Bool = false) {
        if seekInFlight { pendingSeek = target; pendingFast = fast; return }
        guard player.currentItem != nil else { return }
        seekInFlight = true
        let started = CACurrentMediaTime()
        let tolerance: CMTime = fast ? .positiveInfinity : .zero
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let took = CACurrentMediaTime() - started
                self.seekStats.add(took)
                if self.scrubbing || self.settling { fast ? self.scrubStats.add(took) : self.exactStats.add(took) }
                self.seekInFlight = false
                if let next = self.pendingSeek { self.pendingSeek = nil; self.requestSeek(next, fast: self.pendingFast) }
                else if !fast { self.settling = false }
            }
        }
    }

    func beginScrub() { scrubbing = true; if playing { pause() }; scrubStats = SeekStats(); exactStats = SeekStats() }
    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        settling = true
        settle()
        if scrubStats.count > 2 { log("scrub: \(scrubStats.summary) while dragging (keyframe-tolerant)") }
    }
}
