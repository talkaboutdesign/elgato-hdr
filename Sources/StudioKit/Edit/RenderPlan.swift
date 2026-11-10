import Foundation
import CoreGraphics

/// Value snapshot: AVFoundation may evaluate it concurrently with edits on the main thread.
struct RenderPlan {
    var scenes: [Scene]; var timeline: Timeline; var map: TimeMap
    var canvas: Canvas; var canvasSize: CGSize
    var sources: [SourceKey: SourceInfo]; var mirrorCamera: Bool
    /// Where the cuts are, in source time. `map` only says which source time a composition time shows: the editor
    /// preview plays the uncut source (identity map) but must end a transition at a cut exactly as the export does.
    var cuts: TimeMap? = nil

    var cameraRanges: [Segment]? = nil
    /// Where this plan's image and text layers come from; nil draws none (`RenderPlan+Overlays`).
    var overlay: OverlaySource? = nil

    static func joinedCameraRanges(_ ranges: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for range in ranges.sorted(by: { $0.startMs < $1.startMs }) {
            if let last = out.last, range.startMs <= last.endMs + 0.01 {
                out[out.count - 1].endMs = max(last.endMs, range.endMs)
            } else { out.append(range) }
        }
        return out
    }

    /// Spans whose scene the plan has, in time order.
    var orderedSpans: [SceneSpan] {
        timeline.sceneSpans.filter { span in scenes.contains { $0.id == span.sceneID } }.sorted { $0.startMs < $1.startMs }
    }

    /// The live engine's state that shows source time `s`, and the host time to evaluate it at (source milliseconds as
    /// nanoseconds). Each switch is replayed onto the one before it: when a span starts while the previous span's
    /// transition is still running, that state is evaluated at the new span's start and frozen as its starting picture,
    /// the same snapshot the live engine takes, so rapid switching replays without a jump. The chain goes back at most
    /// as many spans as start within the longest transition before this one. A transition never runs across a cut.
    func liveState(atSourceMs s: Double) -> (state: LiveSceneState, ns: UInt64)? {
        let spans = orderedSpans
        func scene(_ span: SceneSpan) -> Scene { scenes.first { $0.id == span.sceneID }! }
        guard let i = spans.lastIndex(where: { $0.startMs <= s }) else {
            return scenes.first.map { (LiveSceneState(scene: $0), Self.hostNs(s)) }
        }
        let gaps = cuts ?? map
        if spans[i].transition.durationMs <= 0 || gaps.crossedCut(from: spans[i].startMs, through: s) {
            return (LiveSceneState(scene: scene(spans[i])), Self.hostNs(s))
        }
        let longest = spans.map { $0.transition.style == .cut ? 0 : $0.transition.durationMs }.max() ?? 0
        let limit = spans[..<i].filter { $0.startMs > spans[i].startMs - longest }.count
        func state(_ j: Int, depth: Int) -> LiveSceneState {
            let to = scene(spans[j])
            guard j > 0 else { return LiveSceneState(scene: to) }
            let prev = spans[j - 1]
            let running = depth > 0 && j > 1 && prev.transition.style != .cut && prev.transition.durationMs > 0
                && spans[j].startMs - prev.startMs < prev.transition.durationMs && !gaps.crossedCut(from: prev.startMs, through: spans[j].startMs)
            let base = running ? state(j - 1, depth: depth - 1) : LiveSceneState(scene: scene(prev))
            return base.switching(to: to, atNs: Self.hostNs(spans[j].startMs), transition: spans[j].transition, sources: sources)
        }
        return (state(i, depth: limit), Self.hostNs(s))
    }
    static func hostNs(_ ms: Double) -> UInt64 { UInt64((max(0, ms) * 1e6).rounded()) }

    func layers(atTimelineMs t: Double) -> [ResolvedLayer] {
        guard let ranges = cameraRanges, sources[.camera] != nil else { return evaluatedLayers(atTimelineMs: t) }
        var absent = self; absent.sources.removeValue(forKey: .camera); absent.cameraRanges = nil
        let gameOnly = absent.evaluatedLayers(atTimelineMs: t)
        guard let range = Self.joinedCameraRanges(ranges).first(where: { t >= $0.startMs && t < $0.endMs }) else { return gameOnly }
        let fadeIn = range.startMs > 0 ? min(1, (t - range.startMs) / 150) : 1
        let fadeOut = range.endMs < map.durationMs - 1 ? min(1, (range.endMs - t) / 150) : 1
        let weight = max(0, min(fadeIn, fadeOut))
        let picture = evaluatedLayers(atTimelineMs: t)
        guard weight < 1 else { return picture }
        return SceneBlend(canvas: CGRect(origin: .zero, size: canvasSize)).mix(gameOnly, picture, e: weight, match: false)
    }

    private func evaluatedLayers(atTimelineMs t: Double) -> [ResolvedLayer] {
        let s = map.source(fromTimeline: t)
        guard let (state, ns) = liveState(atSourceMs: s) else { return [] }
        var layers = state.layers(canvas: canvas, size: canvasSize, sources: sources, atNs: ns)
        for i in layers.indices where layers[i].key == .camera { layers[i].mirror = layers[i].mirror || mirrorCamera }
        // Overlapping blocks: the one zoomed in furthest at this moment wins.
        guard let z = timeline.zooms.max(by: { $0.scale(at: s) < $1.scale(at: s) }) else { return layers }
        if z.live {
            // A punch-in recorded live: the live engine's own spring and framing.
            z.punchIn(at: s)?.apply(to: &layers, atNs: Self.hostNs(s))
            return layers
        }
        let scale = z.scale(at: s)
        guard scale.isFinite, scale > 1 else { return layers }
        for i in layers.indices where layers[i].key == .game {
            let crop = layers[i].src
            let w = crop.width / scale, h = crop.height / scale
            // Map the source-space focus into the current crop, then shrink around that pivot. At scale one
            // this is exactly the original crop, including when the focus is near a source edge.
            let fx = min(crop.maxX, max(crop.minX, z.focusX)), fy = min(crop.maxY, max(crop.minY, z.focusY))
            let x = fx + (crop.minX - fx) / scale
            let y = fy + (crop.minY - fy) / scale
            layers[i].src = CGRect(x: min(1-w, max(0, x)), y: min(1-h, max(0, y)), width: w, height: h)
        }
        return layers
    }
    func background(atTimelineMs t: Double) -> SIMD4<Float> {
        guard let (state, ns) = liveState(atSourceMs: map.source(fromTimeline: t)) else { return SIMD4(0, 0, 0, 1) }
        return state.frame(canvas: canvas, size: canvasSize, sources: sources, atNs: ns).background
    }
    private static func ease(_ t: Double) -> Double { SceneEasing.spring(t, duration: 1) }

    static func transitionLayers(from: Scene?, to: Scene, transition: SceneTransition, progress: Double,
                                 canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo]) -> [ResolvedLayer] {
        transitionState(from: from, to: to, transition: transition)
            .layers(canvas: canvas, size: size, sources: sources, atNs: transitionNs(progress, transition))
    }

    /// The live engine's state for a span: switched at host time 0, so `transitionNs` is the time into the switch.
    static func transitionState(from: Scene?, to: Scene, transition: SceneTransition) -> LiveSceneState {
        var state = LiveSceneState(scene: to)
        state.from = from; state.transition = transition
        return state
    }
    static func transitionNs(_ progress: Double, _ transition: SceneTransition) -> UInt64 {
        UInt64(max(0, progress * max(0, transition.durationMs) * 1e6).rounded())
    }
}
