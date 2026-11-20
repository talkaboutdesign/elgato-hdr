import Foundation

/// Horizontal mapping of the timeline between source seconds and points. Collapsed ranges (removed footage, when it
/// is hidden) take `gap` points each: 0 in the editor, so kept footage butts together at a seam and the content is
/// the export's length. `shown` lets a range open part way (0 collapsed, 1 at scale) while a removal or restore
/// animates. A pure value: lanes, input handling and tests share it.
struct TimelineAxis: Equatable {
    var duration = 0.0                      // source seconds
    var width = 0.0                         // visible lane width, points
    var scale = 0.0                         // points per second when not fitted
    var fitted = true                       // follows the width: the whole edit is visible
    var offset = 0.0                        // content points scrolled off the left edge
    var collapsed: [ClosedRange<Double>] = [] { didSet { index() } }   // sorted, disjoint (touching is fine), seconds
    var gap = 0.0                           // points per collapsed range
    var shown: [Double] = [] { didSet { index() } }                     // per collapsed range, 0…1; missing means 0
    static let maxScale = 3000.0            // about 50 points per frame at 60 fps

    // Prefix sums over `collapsed`, so every mapping is a binary search: a timeline with hundreds of cuts is
    // mapped thousands of times per drawn frame.
    private(set) var opens: [Double] = []           // clamped `shown`
    private(set) var hiddenBefore: [Double] = [0]   // hidden seconds of the ranges before range i (count + 1)

    init(duration: Double = 0, width: Double = 0, scale: Double = 0, fitted: Bool = true, offset: Double = 0,
         collapsed: [ClosedRange<Double>] = [], gap: Double = 0, shown: [Double] = []) {
        self.duration = duration; self.width = width; self.scale = scale; self.fitted = fitted; self.offset = offset
        self.collapsed = collapsed; self.gap = gap; self.shown = shown
        index()
    }

    private mutating func index() {
        var o: [Double] = [], h: [Double] = [0]
        o.reserveCapacity(collapsed.count); h.reserveCapacity(collapsed.count + 1)
        for (i, r) in collapsed.enumerated() {
            let f = i < shown.count ? min(1, max(0, shown[i])) : 0
            o.append(f)
            h.append(h[i] + (r.upperBound - r.lowerBound) * (1 - f))
        }
        opens = o; hiddenBefore = h
    }
    /// Number of ranges whose start is before `t` (`strict`) or at or before it.
    private func count(startingBefore t: Double, strict: Bool = true) -> Int {
        var lo = 0, hi = collapsed.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let b = collapsed[mid].lowerBound
            if strict ? b < t : b <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    private func span(_ i: Int) -> Double { collapsed[i].upperBound - collapsed[i].lowerBound }
    /// Points range `i` takes at `s` points per second.
    private func rangeWidth(_ i: Int, _ s: Double) -> Double { gap + span(i) * s * opens[i] }
    /// Content x where range `i` starts.
    private func rangeX(_ i: Int, _ s: Double) -> Double { (collapsed[i].lowerBound - hiddenBefore[i]) * s + Double(i) * gap }

    /// Seconds that take no width (the collapsed share of each range).
    var hiddenSeconds: Double { hiddenBefore.last ?? 0 }
    /// Length of what the timeline shows at scale: the export's length when removed footage is hidden.
    var shownDuration: Double { max(0, duration - hiddenSeconds) }

    var fitScale: Double {
        let room = max(width - gap * Double(collapsed.count), 1)
        return room / max(shownDuration, 0.001)
    }
    var maxScale: Double { max(Self.maxScale, fitScale) }
    /// Points per second actually used.
    var pps: Double { fitted ? fitScale : min(maxScale, max(fitScale, scale)) }

    /// A time inside a collapsed range sits on its seam (with gap 0); the start and end of the range share it.
    func contentX(_ t: Double) -> Double {
        let s = pps, n = count(startingBefore: t)
        if n > 0, t < collapsed[n - 1].upperBound {
            let i = n - 1
            return rangeX(i, s) + (t - collapsed[i].lowerBound) / max(span(i), 1e-9) * rangeWidth(i, s)
        }
        return (min(max(t, 0), duration) - hiddenBefore[n]) * s + Double(n) * gap
    }

    /// The inverse of `contentX`. A seam gives the first kept time after it, never a time inside a removed range;
    /// a seam at the very end gives the end of the last kept footage.
    func time(atContentX x: Double) -> Double {
        let s = pps
        // The last range starting at or before x.
        var lo = 0, hi = collapsed.count
        while lo < hi { let mid = (lo + hi) / 2; if rangeX(mid, s) <= x { lo = mid + 1 } else { hi = mid } }
        guard lo > 0 else {
            // Left of a leading seam: still its kept side.
            if let r = collapsed.first, r.lowerBound <= 0, rangeWidth(0, s) < 1e-9 { return clamp(r.upperBound) }
            return clamp(x / s)
        }
        let i = lo - 1, rx = rangeX(i, s), w = rangeWidth(i, s), r = collapsed[i]
        if x < rx + w { return clamp(r.lowerBound + (x - rx) / w * span(i)) }
        if r.upperBound >= duration - 1e-9 && w < 1e-9 {
            // A trailing seam: the end of the kept footage before it (touching ranges share the seam).
            var j = i
            while j > 0, collapsed[j - 1].upperBound >= collapsed[j].lowerBound - 1e-12, rangeWidth(j - 1, s) < 1e-9 { j -= 1 }
            return clamp(collapsed[j].lowerBound)
        }
        return clamp(r.upperBound + (x - rx - w) / s)
    }

    func x(_ t: Double) -> Double { contentX(t) - offset }
    func time(atX x: Double) -> Double { time(atContentX: x + offset) }
    var contentWidth: Double { contentX(duration) }
    var visibleStart: Double { time(atX: 0) }
    var visibleEnd: Double { time(atX: width) }
    var isZoomedIn: Bool { contentWidth > width + 0.5 }
    private func clamp(_ t: Double) -> Double { min(duration, max(0, t)) }

    // MARK: Shown time (what the ruler counts)

    /// Seconds of shown footage before `t`: export time when removed footage is hidden, source time otherwise.
    func shownTime(_ t: Double) -> Double {
        let n = count(startingBefore: t)
        var h = hiddenBefore[n]
        if n > 0, t < collapsed[n - 1].upperBound {
            let i = n - 1
            h = hiddenBefore[i] + (t - collapsed[i].lowerBound) * (1 - opens[i])
        }
        return min(max(t, 0), duration) - h
    }
    /// The source time at shown time `e` (the first kept time at a seam).
    func sourceTime(shown e: Double) -> Double {
        let e = max(0, e)
        // The last range whose shown start is at or before e.
        var lo = 0, hi = collapsed.count
        while lo < hi { let mid = (lo + hi) / 2; if collapsed[mid].lowerBound - hiddenBefore[mid] <= e { lo = mid + 1 } else { hi = mid } }
        guard lo > 0 else { return min(duration, e) }
        let i = lo - 1, left = e - (collapsed[i].lowerBound - hiddenBefore[i]), part = span(i) * opens[i]
        if left < part { return collapsed[i].lowerBound + left / max(opens[i], 1e-9) }
        return min(duration, collapsed[i].upperBound + left - part)
    }

    /// Whether `t` is inside collapsed footage ([start, end) of a range, so a seam's own end time is kept).
    func isCollapsed(_ t: Double) -> Bool {
        let n = count(startingBefore: t, strict: false)
        guard n > 0 else { return false }
        return opens[n - 1] < 1e-9 && t < collapsed[n - 1].upperBound
    }

    /// The parts of [t0, t1] that take width, in source seconds: an item straddling a seam is drawn as these pieces,
    /// meeting at the seam; an item entirely inside removed footage has none.
    func pieces(_ t0: Double, _ t1: Double) -> [ClosedRange<Double>] {
        guard t1 > t0 else { return [] }
        var out: [ClosedRange<Double>] = [], a = t0
        var i = max(0, count(startingBefore: t0) - 1)
        while i < collapsed.count {
            let r = collapsed[i]; i += 1
            if opens[i - 1] >= 1e-9 || r.upperBound <= a { continue }
            if r.lowerBound >= t1 { break }
            if r.lowerBound > a { out.append(a...r.lowerBound) }
            a = max(a, r.upperBound)
            if a >= t1 { break }
        }
        if a < t1 { out.append(a...t1) }
        return out
    }
    /// Content x of every seam (each fully collapsed range), with the range.
    var seams: [(x: Double, range: ClosedRange<Double>)] {
        let s = pps
        return collapsed.indices.filter { opens[$0] < 1e-9 }.map { (i: Int) -> (x: Double, range: ClosedRange<Double>) in (x: rangeX(i, s), range: collapsed[i]) }
    }
    /// Seams on screen only (screen x), for drawing and hit testing.
    func visibleSeams(margin: Double = 12) -> [(x: Double, range: ClosedRange<Double>)] {
        let s = pps, t0 = time(atX: -margin), t1 = time(atX: width + margin)
        var out: [(x: Double, range: ClosedRange<Double>)] = []
        var i = max(0, count(startingBefore: t0) - 1)
        while i < collapsed.count, collapsed[i].lowerBound <= t1 {
            if opens[i] < 1e-9 { out.append((x: rangeX(i, s) - offset, range: collapsed[i])) }
            i += 1
        }
        return out
    }

    mutating func clampOffset() { offset = min(max(0, offset), max(0, contentWidth - width)) }

    /// Zooms to `newScale` keeping the time under `anchorX` where it is on screen.
    mutating func zoom(to newScale: Double, anchorX: Double) {
        let t = time(atX: anchorX)
        if newScale <= fitScale * 1.0001 { fitted = true; offset = 0; return }
        fitted = false
        scale = min(maxScale, newScale)
        offset = contentX(t) - anchorX
        clampOffset()
    }
    mutating func zoom(by factor: Double, anchorX: Double) { zoom(to: pps * factor, anchorX: anchorX) }
    mutating func fit() { fitted = true; offset = 0 }
    mutating func pan(by dx: Double) { offset += dx; clampOffset() }
    mutating func setWidth(_ w: Double) { width = max(0, w); clampOffset() }

    /// Zoom slider position: 0 shows everything, 1 is the closest zoom (logarithmic in between).
    var zoomFraction: Double {
        let lo = fitScale, hi = maxScale
        guard hi > lo * 1.0001 else { return 0 }
        return min(1, max(0, log(pps / lo) / log(hi / lo)))
    }
    mutating func setZoomFraction(_ f: Double, anchorX: Double) {
        let lo = fitScale, hi = maxScale
        zoom(to: lo * pow(hi / lo, min(1, max(0, f))), anchorX: anchorX)
    }

    /// Keeps `t` on screen: scrolls a page when it leaves the visible range (playback, stepping).
    mutating func reveal(_ t: Double, margin: Double = 24) {
        guard isZoomedIn else { return }
        let px = x(t)
        if px > width - margin || px < 0 { offset = contentX(t) - width * 0.12; clampOffset() }
        else if px < margin, offset > 0 { offset = contentX(t) - width * 0.5; clampOffset() }
    }

    /// Ruler spacing in shown seconds: the smallest step whose labels stay at least `minSpacing` points apart, and
    /// its subdivision.
    func ticks(minSpacing: Double = 72) -> (major: Double, minor: Double) {
        let ladder: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let s = pps
        let major = ladder.first { $0 * s >= minSpacing } ?? 14400
        let parts: Double
        switch major { case 15, 900: parts = 3; case 30, 60, 120, 1800, 3600: parts = 6; case 0.2: parts = 4; default: parts = 5 }
        return (major, major / parts)
    }

    /// The layout part way from `self` to `target` (same width, scale and offset as `target`): ranges collapsed in
    /// only one of them open or close by `progress`. Removals, restores, undo and the Show/Hide switch animate
    /// through this.
    func transition(to target: TimelineAxis, progress p: Double) -> TimelineAxis {
        var pts = Set<Double>()
        for r in collapsed + target.collapsed { pts.insert(r.lowerBound); pts.insert(r.upperBound) }
        let edges = pts.sorted()
        func state(_ a: TimelineAxis, _ mid: Double) -> Double? {
            let n = a.count(startingBefore: mid)
            return n > 0 && mid < a.collapsed[n - 1].upperBound ? a.opens[n - 1] : nil
        }
        var ranges: [ClosedRange<Double>] = [], opened: [Double] = []
        for (a, b) in zip(edges, edges.dropFirst()) where b > a {
            let mid = (a + b) / 2
            let from = state(self, mid), to = state(target, mid)
            guard from != nil || to != nil else { continue }
            ranges.append(a...b)
            opened.append((from ?? 1) + ((to ?? 1) - (from ?? 1)) * p)
        }
        return TimelineAxis(duration: target.duration, width: target.width, scale: target.scale, fitted: target.fitted,
                            offset: target.offset, collapsed: ranges, gap: target.gap, shown: opened)
    }
}
