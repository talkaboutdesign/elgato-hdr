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
    /// For a layer passing in front of another: nothing for the first third, all of it by 85%, so the motion reads
    /// before the two trade places.
    static func rise(_ e: Double) -> Double { let x = min(1, max(0, (e - 0.35) / 0.5)); return x * x * (3 - 2 * x) }
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
        // A panned focus is forgotten only once a release has settled; re-engaging mid-way zooms back in where the
        // picture is, rather than recentring it at once.
        let settled = isIdle(atNs: t)
        fromScale = scale(atNs: t); startNs = t; engaged = on
        if on && settled { focus = nil; focusFrom = nil }
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
        let p: CGFloat = amount > 1 ? CGFloat(min(1, max(0, (s - 1) / (amount - 1)))) : 1
        let k = CGFloat(s)
        for i in layers.indices where layers[i].key == .game {
            let src = layers[i].src, c = CGPoint(x: src.midX, y: src.midY)
            let f = focusPoint(atNs: t, centre: c)
            let w: CGFloat = src.width / k, h: CGFloat = src.height / k
            let tx: CGFloat = c.x + (f.x - c.x) * p, ty: CGFloat = c.y + (f.y - c.y) * p
            let cx = min(max(tx, w / 2), 1 - w / 2), cy = min(max(ty, h / 2), 1 - h / 2)
            layers[i].src = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }
    }
}

/// The renderer holds one of these behind its lock and copies it for every frame. A switch replaces it with
/// `switching(to:atNs:transition:sources:)`; edits to the active scene replace `to` without restarting anything.
struct LiveSceneState {
    var from: Scene?
    var to: Scene
    var startNs: UInt64 = 0
    var transition = SceneTransition()
    var punchIn: PunchIn?
    /// When a switch interrupts a transition, the picture on screen at that instant (both canvases) is what the new
    /// one starts from. It is flattened into plain layers, so however fast switches come, a frame costs one blend.
    private(set) var snapshot: Snapshot?

    /// A picture frozen at a switch, in pixels of `reference` for each canvas.
    struct Snapshot: Equatable {
        var wide: SceneFrame, vertical: SceneFrame
        static func reference(_ c: Canvas) -> CGSize { c.size(.hd) }

        /// The frozen picture at `size`. A source that has lost its frames since the switch is left out, as the
        /// resolver does.
        func frame(_ canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo]) -> SceneFrame {
            var f = canvas == .wide ? wide : vertical
            f.layers.removeAll { $0.color == nil && sources[$0.key] == nil }
            let ref = Snapshot.reference(canvas)
            let sx: CGFloat = size.width / ref.width, sy: CGFloat = size.height / ref.height
            guard sx != 1 || sy != 1 else { return f }
            for i in f.layers.indices {
                let d = f.layers[i].dst
                f.layers[i].dst = CGRect(x: d.minX * sx, y: d.minY * sy, width: d.width * sx, height: d.height * sy)
                f.layers[i].radius *= sx; f.layers[i].border *= sx; f.layers[i].shadow *= sx
            }
            return f
        }
    }

    init(scene: Scene) { to = scene }

    var durationNs: UInt64 {
        let ms = transition.durationMs
        return transition.style == .cut || !ms.isFinite ? 0 : UInt64(min(max(0, ms), 60_000) * 1e6)
    }
    func isTransitioning(atNs t: UInt64) -> Bool { (from != nil || snapshot != nil) && t &- startNs < durationNs && t >= startNs }
    /// Eased progress at `t`: 0 before the switch, 1 once it is over.
    func progress(atNs t: UInt64) -> Double {
        guard from != nil || snapshot != nil, transition.style != .cut else { return 1 }
        guard t >= startNs else { return 0 }
        return SceneEasing.spring(Double(t - startNs) / 1e6, duration: transition.durationMs)
    }
    /// 1 while starting from a frozen picture; it never nests.
    var depth: Int { snapshot == nil ? 0 : 1 }

    /// The state after switching to `scene` at `t`. Mid-transition, the current in-between picture is frozen as the
    /// starting point so rapid switching never jumps; `sources` are the frame sizes it is resolved with.
    func switching(to scene: Scene, atNs t: UInt64, transition: SceneTransition, sources: [SourceKey: SourceInfo]) -> LiveSceneState {
        var next = LiveSceneState(scene: scene)
        next.startNs = t; next.transition = transition; next.punchIn = punchIn
        next.from = to
        if isTransitioning(atNs: t) || (t < startNs && (from != nil || snapshot != nil)) {
            func flat(_ c: Canvas) -> SceneFrame { rawFrame(canvas: c, size: Snapshot.reference(c), sources: sources, atNs: t) }
            next.snapshot = Snapshot(wide: flat(.wide), vertical: flat(.vertical))
        }
        return next
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
        if let snap = snapshot { source = snap.frame(canvas, size: size, sources: sources) }
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
    /// something opaque will cover them anyway); unmatched new layers fade in (early, if they start covered). An
    /// unmatched layer that overlaps nothing beneath it in its own picture goes to the bottom, where its depth makes
    /// no difference to that picture, so moving layers glide over it rather than through it.
    func mix(_ a: [ResolvedLayer], _ b: [ResolvedLayer], e: Double, match: Bool) -> [ResolvedLayer] {
        var oldFor = [Int?](repeating: nil, count: b.count), used = Set<Int>()
        if match {
            for (j, l) in b.enumerated() {
                if let i = a.indices.first(where: { !used.contains($0) && a[$0].key == l.key }) { used.insert(i); oldFor[j] = i }
            }
        }
        let newFor = Dictionary(uniqueKeysWithValues: oldFor.enumerated().compactMap { j, i in i.map { ($0, j) } })
        func overlaps(_ r: CGRect, _ s: CGRect) -> Bool { let x = r.intersection(s); return !x.isNull && x.width * x.height > 1 }
        func free(_ l: [ResolvedLayer], _ i: Int) -> Bool { match && !l[..<i].contains { overlaps($0.dst, l[i].dst) } }
        // Old layers not matched go after the target position of the matched layer below them (-1: bottom).
        var oldAfter: [Int: [Int]] = [:]
        var anchor = -1
        for i in a.indices {
            if let j = newFor[i] { anchor = j } else { oldAfter[free(a, i) ? -1 : anchor, default: []].append(i) }
        }
        let sunk = b.indices.filter { oldFor[$0] == nil && free(b, $0) }
        // Rising layers: matched j whose old index is below that of a matched layer it now sits above.
        var lowerCopyBefore: [Int: [Int]] = [:]   // target index of the lowest layer it rises over -> rising layers
        var rising = Set<Int>()
        for (j, i) in oldFor.enumerated() {
            guard let i = i else { continue }
            if let k = (0..<j).first(where: { oldFor[$0].map { $0 > i } ?? false }) { lowerCopyBefore[k, default: []].append(j); rising.insert(j) }
        }
        var parts: [Part] = []
        for i in oldAfter[-1] ?? [] { parts.append(.old(i)) }
        for j in sunk { parts.append(.new(j)) }
        for (j, i) in oldFor.enumerated() {
            for r in lowerCopyBefore[j] ?? [] { parts.append(.lowerCopy(oldFor[r]!, r)) }
            if let i = i { parts.append(.matched(i, j)) } else if !sunk.contains(j) { parts.append(.new(j)) }
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
                if rising.contains(j) { l.opacity *= SceneEasing.rise(e) }
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
        // A game growing from a rounded window to full screen keeps anti-aliased edges until it arrives; at progress 0
        // the picture is still exactly the old one.
        l.hardEdge = e <= 0 ? a.hardEdge : a.hardEdge && b.hardEdge
        if let x = a.color, let y = b.color { l.color = x + (y - x) * Float(e) }
        return l
    }
}
