import Foundation

/// Horizontal mapping of the timeline between source seconds and points. With "Hide removed" on, every removed range
/// is drawn as a fixed-width gap instead of at scale. A pure value: lanes, input handling and tests share it.
struct TimelineAxis: Equatable {
    var duration = 0.0                      // source seconds
    var width = 0.0                         // visible lane width, points
    var scale = 0.0                         // points per second when not fitted
    var fitted = true                       // follows the width: the whole recording is visible
    var offset = 0.0                        // content points scrolled off the left edge
    var collapsed: [ClosedRange<Double>] = []   // sorted, disjoint, seconds
    static let gap = 8.0
    static let maxScale = 3000.0            // about 50 points per frame at 60 fps

    var fitScale: Double {
        let hidden = collapsed.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let kept = max(duration - hidden, 0.001)
        let room = max(width - Self.gap * Double(collapsed.count), 1)
        return room / kept
    }
    var maxScale: Double { max(Self.maxScale, fitScale) }
    /// Points per second actually used.
    var pps: Double { fitted ? fitScale : min(maxScale, max(fitScale, scale)) }

    func contentX(_ t: Double) -> Double {
        let s = pps
        var x = 0.0, last = 0.0
        for r in collapsed {
            if t <= r.lowerBound { break }
            x += (r.lowerBound - last) * s
            if t < r.upperBound { return x + (t - r.lowerBound) / max(r.upperBound - r.lowerBound, 1e-9) * Self.gap }
            x += Self.gap; last = r.upperBound
        }
        return x + (min(max(t, last), duration) - last) * s
    }

    func time(atContentX x: Double) -> Double {
        let s = pps
        var cx = 0.0, last = 0.0
        for r in collapsed {
            let kept = (r.lowerBound - last) * s
            if x < cx + kept { return clamp(last + (x - cx) / s) }
            cx += kept
            if x < cx + Self.gap { return clamp(r.lowerBound + (x - cx) / Self.gap * (r.upperBound - r.lowerBound)) }
            cx += Self.gap; last = r.upperBound
        }
        return clamp(last + (x - cx) / s)
    }

    func x(_ t: Double) -> Double { contentX(t) - offset }
    func time(atX x: Double) -> Double { time(atContentX: x + offset) }
    var contentWidth: Double { contentX(duration) }
    var visibleStart: Double { time(atX: 0) }
    var visibleEnd: Double { time(atX: width) }
    var isZoomedIn: Bool { contentWidth > width + 0.5 }
    private func clamp(_ t: Double) -> Double { min(duration, max(0, t)) }

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

    /// Ruler spacing: the smallest step whose labels stay at least `minSpacing` points apart, and its subdivision.
    func ticks(minSpacing: Double = 72) -> (major: Double, minor: Double) {
        let ladder: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let s = pps
        let major = ladder.first { $0 * s >= minSpacing } ?? 14400
        let parts: Double
        switch major { case 15, 900: parts = 3; case 30, 60, 120, 1800, 3600: parts = 6; case 0.2: parts = 4; default: parts = 5 }
        return (major, major / parts)
    }
}
