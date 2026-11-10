// What the live picture shows at any instant: the active scene, a transition from the previous picture into it, and
// the punch-in zoom on top. Pure value types evaluated per frame, so the window, the stream outputs and (later) the
// editor's replay get identical layers for the same host time.
import CoreGraphics
import Foundation

/// One picture: background and layers, bottom first, in canvas pixels.
struct SceneFrame: Equatable {
    var background: SIMD4<Float>
    var layers: [ResolvedLayer]
}

/// Progress of a transition: a critically damped spring, `e(t) = 1 − (1 + ωt)·exp(−ωt)`, evaluated analytically.
/// ω puts `e(duration)` at 0.99; past the duration the transition is over and `e` is exactly 1.
enum SceneEasing {
    /// Root of (1 + x)·exp(−x) = 0.01.
    static let x99 = 6.638352
    static func spring(_ t: Double, duration: Double) -> Double {
        guard duration > 0, t < duration else { return 1 }
        guard t > 0 else { return 0 }
        let wt = x99 * t / duration
        return 1 - (1 + wt) * exp(-wt)
    }
    /// Stays at 1, then falls to 0 over the last quarter: for a layer that something opaque will cover by the end,
    /// so it does not thin out (and let the background through) while still visible.
    static func hold(_ e: Double) -> Double { min(1, max(0, (1 - e) / 0.25)) }
    /// The mirror image: reaches 1 within the first quarter, for a layer that starts hidden under an opaque one.
    static func early(_ e: Double) -> Double { min(1, max(0, e / 0.25)) }
}

/// Live zoom on the game layer. Engaging and releasing both spring from the scale at that moment, so pressing again
/// mid-way never jumps; moving the focus springs the same way.
struct PunchIn: Equatable {
    var amount = 1.6
    var engaged = false
    /// Normalized source point to centre on; nil centres on each game layer's own crop.
    var focus: CGPoint?
    var startNs: UInt64 = 0, fromScale = 1.0
    var focusFrom: CGPoint?, focusStartNs: UInt64 = 0
    var durationMs = 380.0
    static let range = 1.3...2.5

    var target: Double { engaged ? amount : 1 }
    func scale(atNs t: UInt64) -> Double {
        let e = SceneEasing.spring(Double(Int64(bitPattern: t &- startNs)) / 1e6, duration: durationMs)
        return fromScale + (target - fromScale) * e
    }
    /// True once a release has fully settled: the zoom has no effect any more.
    func isIdle(atNs t: UInt64) -> Bool { !engaged && abs(scale(atNs: t) - 1) < 1e-9 }

    mutating func set(engaged on: Bool, atNs t: UInt64) {
        guard on != engaged else { return }
        fromScale = scale(atNs: t); startNs = t; engaged = on
        if on { focus = nil; focusFrom = nil }
    }

    /// The focus point at `t`, given the crop centre `c` it starts from when none was set.
    func focusPoint(atNs t: UInt64, centre c: CGPoint) -> CGPoint {
        let to = focus ?? c, from = focusFrom ?? c
        let e = SceneEasing.spring(Double(Int64(bitPattern: t &- focusStartNs)) / 1e6, duration: durationMs)
        return CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
    }
    mutating func moveFocus(to p: CGPoint, atNs t: UInt64, centre c: CGPoint) {
        focusFrom = focusPoint(atNs: t, centre: c); focusStartNs = t
        focus = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    /// Crops every game layer further in around the focus. The crop centre moves towards the focus in step with the
    /// zoom, so the release glides back to the scene's own framing.
    func apply(to layers: inout [ResolvedLayer], atNs t: UInt64) {
        let s = scale(atNs: t)
        guard s > 1.0001 else { return }
        let p = amount > 1 ? min(1, max(0, (s - 1) / (amount - 1))) : 1
        for i in layers.indices where layers[i].key == .game {
            let src = layers[i].src, c = CGPoint(x: src.midX, y: src.midY)
            let f = focusPoint(atNs: t, centre: c)
            let w = src.width / s, h = src.height / s
            let cx = min(max(c.x + (f.x - c.x) * p, w / 2), 1 - w / 2), cy = min(max(c.y + (f.y - c.y) * p, h / 2), 1 - h / 2)
            layers[i].src = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }
    }
}

/// The renderer holds one of these behind its lock and copies it for every frame. A switch replaces it with
/// `switching(to:atNs:transition:)`; edits to the active scene replace `to` without restarting anything.
struct LiveSceneState {
    var from: Scene?
    var to: Scene
    var startNs: UInt64 = 0
    var transition = SceneTransition()
    var punchIn: PunchIn?
    /// When a switch interrupts a transition, the picture at that instant is what the new one starts from.
    private(set) var frozen: Frozen?

    final class Frozen {
        let state: LiveSceneState, atNs: UInt64
        init(_ state: LiveSceneState, atNs: UInt64) { self.state = state; self.atNs = atNs }
    }
    /// Frozen pictures nest when switches come faster than transitions end; past this depth the oldest is replaced
    /// by the scene it was heading to, which bounds the per-frame work.
    static let maxDepth = 3

    init(scene: Scene) { to = scene }

    var durationNs: UInt64 { transition.style == .cut ? 0 : UInt64(max(0, transition.durationMs) * 1e6) }
    func isTransitioning(atNs t: UInt64) -> Bool { (from != nil || frozen != nil) && t &- startNs < durationNs && t >= startNs }
    /// Eased progress at `t`: 0 before the switch, 1 once it is over.
    func progress(atNs t: UInt64) -> Double {
        guard from != nil || frozen != nil, transition.style != .cut else { return 1 }
        guard t >= startNs else { return 0 }
        return SceneEasing.spring(Double(t - startNs) / 1e6, duration: transition.durationMs)
    }
    var depth: Int { frozen.map { 1 + $0.state.depth } ?? 0 }

    /// The state after switching to `scene` at `t`. Mid-transition, the current in-between picture is frozen as the
    /// starting point so rapid switching never jumps.
    func switching(to scene: Scene, atNs t: UInt64, transition: SceneTransition) -> LiveSceneState {
        var next = LiveSceneState(scene: scene)
        next.startNs = t; next.transition = transition; next.punchIn = punchIn
        next.from = to
        if isTransitioning(atNs: t) || (t < startNs && (from != nil || frozen != nil)) {
            next.frozen = Frozen(trimmed(depth: LiveSceneState.maxDepth - 1), atNs: t)
        }
        return next
    }

    private func trimmed(depth: Int) -> LiveSceneState {
        var s = self
        if depth <= 0 { if let f = frozen { s.from = f.state.to }; s.frozen = nil; return s }
        if let f = frozen { s.frozen = Frozen(f.state.trimmed(depth: depth - 1), atNs: f.atNs) }
        return s
    }

    /// The picture at host time `t` for one canvas. `size` is the canvas in pixels; `sources` the pixel sizes of the
    /// sources that have frames (layers without one are left out, as `SceneResolver` does).
    func frame(canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo], atNs t: UInt64) -> SceneFrame {
        var f = rawFrame(canvas: canvas, size: size, sources: sources, atNs: t)
        punchIn?.apply(to: &f.layers, atNs: t)
        return f
    }
    func layers(canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo], atNs t: UInt64) -> [ResolvedLayer] {
        frame(canvas: canvas, size: size, sources: sources, atNs: t).layers
    }

    private func rawFrame(canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo], atNs t: UInt64) -> SceneFrame {
        let comp = to.composition(canvas)
        let target = SceneFrame(background: comp.backgroundColor, layers: SceneResolver.resolve(comp, canvas: size, sources: sources))
        let e = progress(atNs: t)
        guard e < 1 else { return target }
        let source: SceneFrame
        if let f = frozen { source = f.state.rawFrame(canvas: canvas, size: size, sources: sources, atNs: f.atNs) }
        else if let from = from {
            let c = from.composition(canvas)
            source = SceneFrame(background: c.backgroundColor, layers: SceneResolver.resolve(c, canvas: size, sources: sources))
        } else { return target }
        let bg = source.background + (target.background - source.background) * Float(e)
        let blend = SceneBlend(canvas: CGRect(origin: .zero, size: size))
        switch transition.style {
        case .cut: return target
        case .fade: return SceneFrame(background: bg, layers: blend.mix(source.layers, target.layers, e: e, match: false))
        case .morph: return SceneFrame(background: bg, layers: blend.mix(source.layers, target.layers, e: e, match: true))
        }
    }
}

/// Blends two resolved pictures. Morph matches layers that show the same source (game with game, camera with
/// camera, an overlay with the same id) and interpolates their geometry; fade matches nothing.
struct SceneBlend {
    let canvas: CGRect

    /// Opaque over the whole canvas, so nothing beneath it can show.
    func covers(_ l: ResolvedLayer) -> Bool {
        guard l.opacity >= 0.999, l.radius < 0.5, l.dst.insetBy(dx: -0.5, dy: -0.5).contains(canvas) else { return false }
        switch l.key {
        case .game, .camera: return true
        case .layer: return (l.color?.w ?? 0) >= 0.999   // images may be transparent
        }
    }

    private enum Part { case matched(Int, Int), lowerCopy(Int, Int), old(Int), new(Int) }

    /// Layers bottom first. z-order follows the target. A matched layer that rises above another matched layer is
    /// also drawn at its old depth while its copy at the new depth fades in, so it passes through instead of popping
    /// in front. Unmatched old layers stay just above the matched layer they sat above and fade out (late, if
    /// something opaque will cover them anyway); unmatched new layers fade in (early, if they start covered).
    func mix(_ a: [ResolvedLayer], _ b: [ResolvedLayer], e: Double, match: Bool) -> [ResolvedLayer] {
        var oldFor = [Int?](repeating: nil, count: b.count), used = Set<Int>()
        if match {
            for (j, l) in b.enumerated() {
                if let i = a.indices.first(where: { !used.contains($0) && a[$0].key == l.key }) { used.insert(i); oldFor[j] = i }
            }
        }
        let newFor = Dictionary(uniqueKeysWithValues: oldFor.enumerated().compactMap { j, i in i.map { ($0, j) } })
        // Old layers not matched go after the target position of the matched layer below them (-1: bottom).
        var oldAfter: [Int: [Int]] = [:]
        var anchor = -1
        for i in a.indices { if let j = newFor[i] { anchor = j } else { oldAfter[anchor, default: []].append(i) } }
        // Rising layers: matched j whose old index is below that of a matched layer it now sits above.
        var lowerCopyBefore: [Int: [Int]] = [:]   // target index of the lowest layer it rises over -> rising layers
        var rising = Set<Int>()
        for (j, i) in oldFor.enumerated() {
            guard let i = i else { continue }
            if let k = (0..<j).first(where: { oldFor[$0].map { $0 > i } ?? false }) { lowerCopyBefore[k, default: []].append(j); rising.insert(j) }
        }
        var parts: [Part] = []
        for i in oldAfter[-1] ?? [] { parts.append(.old(i)) }
        for (j, i) in oldFor.enumerated() {
            for r in lowerCopyBefore[j] ?? [] { parts.append(.lowerCopy(oldFor[r]!, r)) }
            if let i = i { parts.append(.matched(i, j)) } else { parts.append(.new(j)) }
            for o in oldAfter[j] ?? [] { parts.append(.old(o)) }
        }
        // What lies above each part, at the start (old geometry) and at the end (new geometry).
        func startLayer(_ p: Part) -> ResolvedLayer? {
            switch p {
            case .matched(let i, let j): return rising.contains(j) ? nil : a[i]   // a rising layer starts at its lower copy
            case .lowerCopy(let i, _), .old(let i): return a[i]
            case .new: return nil
            }
        }
        func endLayer(_ p: Part) -> ResolvedLayer? {
            switch p { case .matched(_, let j): return b[j]; case .new(let j): return b[j]; case .lowerCopy, .old: return nil }
        }
        var out: [ResolvedLayer] = []
        for (n, p) in parts.enumerated() {
            let above = parts[(n + 1)...]
            switch p {
            case .matched(let i, let j):
                var l = lerp(a[i], b[j], e)
                if rising.contains(j) { l.opacity *= e }
                out.append(l)
            case .lowerCopy(let i, let j):
                var l = lerp(a[i], b[j], e); l.opacity *= SceneEasing.hold(e); out.append(l)
            case .old(let i):
                var l = a[i]
                l.opacity *= above.contains { endLayer($0).map(covers) ?? false } ? SceneEasing.hold(e) : 1 - e
                out.append(l)
            case .new(let j):
                var l = b[j]
                l.opacity *= above.contains { startLayer($0).map(covers) ?? false } ? SceneEasing.early(e) : e
                out.append(l)
            }
        }
        return out.filter { $0.opacity > 0.0005 }
    }

    func lerp(_ a: ResolvedLayer, _ b: ResolvedLayer, _ e: Double) -> ResolvedLayer {
        let f = CGFloat(e)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
        func mix(_ r: CGRect, _ s: CGRect) -> CGRect {
            CGRect(x: mix(r.minX, s.minX), y: mix(r.minY, s.minY), width: mix(r.width, s.width), height: mix(r.height, s.height))
        }
        var l = b   // fields this blend does not know about come from the target
        l.dst = mix(a.dst, b.dst); l.src = mix(a.src, b.src)
        l.radius = mix(a.radius, b.radius); l.border = mix(a.border, b.border); l.shadow = mix(a.shadow, b.shadow)
        l.opacity = a.opacity + (b.opacity - a.opacity) * e
        l.mirror = e < 0.5 ? a.mirror : b.mirror
        if let x = a.color, let y = b.color { l.color = x + (y - x) * Float(e) }
        return l
    }
}
