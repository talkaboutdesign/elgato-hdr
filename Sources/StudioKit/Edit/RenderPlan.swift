import Foundation
import CoreGraphics

/// Value snapshot: AVFoundation may evaluate it concurrently with edits on the main thread.
struct RenderPlan {
    var scenes: [Scene]; var timeline: Timeline; var map: TimeMap
    var canvas: Canvas; var canvasSize: CGSize
    var sources: [SourceKey: SourceInfo]; var mirrorCamera: Bool

    private func selection(at t: Double) -> (Scene?, Scene?, SceneTransition, Double) {
        let s = map.source(fromTimeline: t)
        let spans = timeline.sceneSpans.filter { span in scenes.contains { $0.id == span.sceneID } }.sorted { $0.startMs < $1.startMs }
        guard let i = spans.lastIndex(where: { $0.startMs <= s }) else { return (nil, scenes.first, SceneTransition(style: .cut), 1) }
        let span = spans[i]
        let to = scenes.first { $0.id == span.sceneID }
        let from = i > 0 ? scenes.first { $0.id == spans[i-1].sceneID } : scenes.first
        let done = span.transition.durationMs <= 0 || map.crossedCut(from: span.startMs, through: s)
        let progress = done ? 1 : min(1, max(0, (s - span.startMs) / span.transition.durationMs))
        return (from, to, span.transition, progress)
    }
    func layers(atTimelineMs t: Double) -> [ResolvedLayer] {
        let (from, to, transition, progress) = selection(at: t)
        guard let to = to else { return [] }
        var layers = Self.transitionLayers(from: from, to: to, transition: transition, progress: progress,
                                           canvas: canvas, size: canvasSize, sources: sources)
        let s = map.source(fromTimeline: t)
        let block = timeline.zooms.max { $0.weight(at: s) < $1.weight(at: s) }
        for i in layers.indices {
            if layers[i].key == .camera { layers[i].mirror = layers[i].mirror || mirrorCamera }
            guard layers[i].key == .game, let z = block else { continue }
            let weight = z.weight(at: s), scale = 1 + (max(1, z.scale) - 1) * weight
            guard scale.isFinite, scale > 1 else { continue }
            let crop = layers[i].src
            let w = crop.width / scale, h = crop.height / scale
            // Focus is in source coordinates, clamped to the current crop. Interpolating the crop centre avoids
            // a jump at weight zero, and preserves the same focus in differently cropped canvases.
            let fx = min(crop.maxX, max(crop.minX, z.focusX)), fy = min(crop.maxY, max(crop.minY, z.focusY))
            let x = crop.midX + (fx - crop.midX) * weight - w/2
            let y = crop.midY + (fy - crop.midY) * weight - h/2
            layers[i].src = CGRect(x: min(1-w, max(0, x)), y: min(1-h, max(0, y)), width: w, height: h)
        }
        return layers
    }
    func background(atTimelineMs t: Double) -> SIMD4<Float> {
        let (from, to, transition, progress) = selection(at: t)
        let b = to?.composition(canvas).backgroundColor ?? SIMD4(0, 0, 0, 1)
        guard transition.style != .cut, progress < 1, let from = from else { return b }
        let a = from.composition(canvas).backgroundColor, e = Float(Self.ease(progress))
        return a + (b-a)*e
    }
    private static func ease(_ t: Double) -> Double { t >= 1 ? 1 : 1 - (1 + 6.638*t)*exp(-6.638*t) }

    /// Plan 22 is not present yet. This boundary takes resolved inputs at a normalized progress so its morph
    /// evaluator can replace the fade fallback without changing timeline or compositor callers.
    static func transitionLayers(from: Scene?, to: Scene, transition: SceneTransition, progress: Double,
                                 canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo]) -> [ResolvedLayer] {
        let target = SceneResolver.resolve(to.composition(canvas), canvas: size, sources: sources)
        guard let from = from, transition.style != .cut, progress < 1, from.id != to.id else { return target }
        let e = ease(max(0, progress))
        let old = SceneResolver.resolve(from.composition(canvas), canvas: size, sources: sources)
        return old.map { var l = $0; l.opacity *= 1-e; return l } + target.map { var l = $0; l.opacity *= e; return l }
    }
}
