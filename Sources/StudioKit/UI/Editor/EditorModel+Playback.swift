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

    func step(frames n: Int) {
        if playing { pause() }
        seek(time + Double(n) * frameDuration)
    }
    func jump(seconds s: Double) {
        if playing { pause() }
        seek(time + s)
    }

    /// Moves the playhead. The model shows the target at once; the player follows with at most one seek in flight.
    func seek(_ s: Double, quantize: Bool = true) {
        let d = duration > 0 ? duration : project.durationMs / 1000
        var t = min(max(0, s), max(0, d - frameDuration * 0.5))
        if quantize { t = (t / frameDuration).rounded() * frameDuration }
        time = t
        var a = axis; a.reveal(t)
        if a != axis { axis = a }
        requestSeek(CMTime(seconds: t, preferredTimescale: 60000))
    }

    func requestSeek(_ target: CMTime) {
        if seekInFlight { pendingSeek = target; return }
        guard player.currentItem != nil else { return }
        seekInFlight = true
        let started = CACurrentMediaTime()
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let took = CACurrentMediaTime() - started
                self.seekStats.add(took)
                if self.scrubbing { self.scrubStats.add(took) }
                self.seekInFlight = false
                if let next = self.pendingSeek { self.pendingSeek = nil; self.requestSeek(next) }
            }
        }
    }

    func beginScrub() { scrubbing = true; if playing { pause() }; scrubStats = SeekStats() }
    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        if scrubStats.count > 2 { log("scrub: \(scrubStats.summary)") }
    }
}
