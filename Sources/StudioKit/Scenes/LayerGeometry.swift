// Geometry for arranging layers on the picture: snapping with guides, resizing from handles, and carrying a layout
// across to the other canvas. Pure, in canvas pixels with the origin top-left, so the view only converts points.
import CoreGraphics
import Foundation

/// A guide line drawn while something is snapped: vertical lines sit at x = `position`, horizontal at y.
struct SnapGuide: Equatable {
    enum Axis: Equatable { case vertical, horizontal }
    var axis: Axis
    var position: CGFloat
    var from: CGFloat, to: CGFloat
}

struct LayerSnapper {
    let canvas: CGSize
    /// Frames of the other visible layers.
    let others: [CGRect]
    /// Distance within which an edge or centre snaps, in canvas pixels.
    let threshold: CGFloat

    /// The 4% inset the camera presets have always used (`CameraPlacement.anchors`).
    var margin: CGFloat { min(canvas.width, canvas.height) * 0.04 }

    struct Target { var value: CGFloat; var span: (CGFloat, CGFloat)? }   // span: the other layer's extent
    private func targets(_ axis: SnapGuide.Axis) -> [Target] {
        let len = axis == .vertical ? canvas.width : canvas.height
        var t = [0, margin, len / 2, len - margin, len].map { Target(value: $0, span: nil) }
        for o in others {
            let span = axis == .vertical ? (o.minY, o.maxY) : (o.minX, o.maxX)
            for v in axis == .vertical ? [o.minX, o.midX, o.maxX] : [o.minY, o.midY, o.maxY] { t.append(Target(value: v, span: span)) }
        }
        return t
    }

    /// The nearest target to any of `features` within the threshold, and the offset that lands on it.
    func best(_ features: [CGFloat], _ axis: SnapGuide.Axis) -> (offset: CGFloat, target: Target)? {
        var found: (offset: CGFloat, target: Target)?
        for f in features {
            for t in targets(axis) where abs(t.value - f) <= threshold && abs(t.value - f) < abs(found?.offset ?? .infinity) { found = (t.value - f, t) }
        }
        return found
    }

    /// The guide for a snap, spanning the canvas or both layers involved.
    func guide(_ t: Target, _ axis: SnapGuide.Axis, for r: CGRect) -> SnapGuide {
        let lo: CGFloat = axis == .vertical ? r.minY : r.minX, hi: CGFloat = axis == .vertical ? r.maxY : r.maxX
        let full: CGFloat = axis == .vertical ? canvas.height : canvas.width
        guard let span = t.span else { return SnapGuide(axis: axis, position: t.value, from: 0, to: full) }
        return SnapGuide(axis: axis, position: t.value, from: min(span.0, lo), to: max(span.1, hi))
    }

    /// Moves `r` so its nearest edge or centre lands on a target, per axis.
    func snapMove(_ r: CGRect) -> (CGRect, [SnapGuide]) {
        var out = r, hits: [(Target, SnapGuide.Axis)] = []
        if let b = best([r.minX, r.midX, r.maxX], .vertical) { out.origin.x += b.offset; hits.append((b.target, .vertical)) }
        if let b = best([r.minY, r.midY, r.maxY], .horizontal) { out.origin.y += b.offset; hits.append((b.target, .horizontal)) }
        return (out, hits.map { guide($0.0, $0.1, for: out) })
    }
}

/// The eight handles of a selected layer, clockwise from the top-left corner.
enum LayerHandle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var isCorner: Bool { rawValue % 2 == 0 }
    /// -1, 0 or 1 per axis: which way the handle sits from the centre.
    var dir: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (-1, -1); case .top: (0, -1); case .topRight: (1, -1); case .right: (1, 0)
        case .bottomRight: (1, 1); case .bottom: (0, 1); case .bottomLeft: (-1, 1); case .left: (-1, 0)
        }
    }
    func point(in r: CGRect) -> CGPoint { CGPoint(x: r.midX + dir.x * r.width / 2, y: r.midY + dir.y * r.height / 2) }
}

enum LayerResize {
    static let minSide: CGFloat = 24

    /// The frame after dragging `handle` of `r` to `p`. The opposite side stays put. Corners keep the aspect unless
    /// `free`; an edge keeps it too when `keepAspectOnEdges` (game and camera: the other side grows about its centre).
    /// Snapping applies to the edges that move.
    static func resize(_ r: CGRect, handle: LayerHandle, to p: CGPoint, free: Bool, keepAspectOnEdges: Bool,
                       snapper: LayerSnapper?) -> (CGRect, [SnapGuide]) {
        let d = handle.dir, aspect = r.width / max(r.height, 1)
        let ax = d.x < 0 ? r.maxX : r.minX, ay = d.y < 0 ? r.maxY : r.minY   // the fixed sides
        let keep = handle.isCorner ? !free : keepAspectOnEdges
        // Pointer, snapped on the axes this handle moves. With a locked aspect a corner's size follows one axis, so
        // only the closer snap counts.
        var px = p.x, py = p.y
        var sx = d.x != 0 ? snapper?.best([px], .vertical) : nil, sy = d.y != 0 ? snapper?.best([py], .horizontal) : nil
        if keep && handle.isCorner, let a = sx, let b = sy { if abs(a.offset) <= abs(b.offset) { sy = nil } else { sx = nil } }
        px += sx?.offset ?? 0; py += sy?.offset ?? 0
        var w = d.x != 0 ? max(minSide, (px - ax) * d.x) : r.width
        var h = d.y != 0 ? max(minSide, (py - ay) * d.y) : r.height
        if keep {
            if handle.isCorner {
                // Follow the snapped axis, else whichever the pointer leads with.
                if sx != nil || (sy == nil && w / aspect >= h) { h = w / aspect } else { w = h * aspect }
            } else if d.x != 0 { h = w / aspect } else { w = h * aspect }
            if w < minSide || h < minSide { let k = minSide / min(w, h); w *= k; h *= k }
        }
        let x = d.x < 0 ? ax - w : d.x > 0 ? ax : r.midX - w / 2
        let y = d.y < 0 ? ay - h : d.y > 0 ? ay : r.midY - h / 2
        let out = CGRect(x: x, y: y, width: w, height: h)
        var guides: [SnapGuide] = []
        if let s = snapper {
            if let a = sx, abs((d.x < 0 ? out.minX : out.maxX) - a.target.value) < 0.5 { guides.append(s.guide(a.target, .vertical, for: out)) }
            if let b = sy, abs((d.y < 0 ? out.minY : out.maxY) - b.target.value) < 0.5 { guides.append(s.guide(b.target, .horizontal, for: out)) }
        }
        return (out, guides)
    }
}

/// The inspector's pixel fields. Text that is not a finite number is rejected and values are clamped to the
/// field's range, so nothing typed (`nan`, `inf`, `1e300`) reaches a frame or an `Int` conversion that traps.
enum PixelField: CaseIterable {
    case x, y, width, height

    /// Positions may leave the canvas by up to its size; sizes run from the resize minimum to four canvases.
    func range(canvas c: CGSize) -> ClosedRange<CGFloat> {
        switch self {
        case .x: -c.width...c.width
        case .y: -c.height...c.height
        case .width: LayerResize.minSide...max(LayerResize.minSide, 4 * c.width)
        case .height: LayerResize.minSide...max(LayerResize.minSide, 4 * c.height)
        }
    }
    func parse(_ text: String, canvas: CGSize) -> CGFloat? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        let r = range(canvas: canvas)
        return min(max(CGFloat(v), r.lowerBound), r.upperBound)
    }
    /// Whole pixels; anything non-finite or absurd shows as a dash rather than trapping.
    static func format(_ v: CGFloat) -> String {
        guard v.isFinite, abs(v) < 1e9 else { return "–" }
        return String(Int(v.rounded()))
    }
}

extension Composition {
    /// The same layout on another canvas. Full-canvas layers stay full; a layer spanning one axis keeps spanning it;
    /// other layers keep their normalized centre and their shape in pixels, scaled with the shorter canvas side, and
    /// stay inside the canvas.
    func converted(from a: CGSize, to b: CGSize) -> Composition {
        var c = self
        let k = min(b.width, b.height) / min(a.width, a.height)
        for i in c.layers.indices {
            let f = c.layers[i].frame
            if f == .full { continue }
            let r = f.rect(in: a)
            let spanX = f.x <= 0.001 && f.w >= 0.999, spanY = f.y <= 0.001 && f.h >= 0.999
            var w = spanX ? b.width : r.width * k, h = spanY ? b.height : r.height * k
            if !spanX && !spanY { let fit = min(1, b.width / w, b.height / h); w *= fit; h *= fit }
            w = min(w, b.width); h = min(h, b.height)
            let cx = min(max(CGFloat(f.x + f.w / 2) * b.width, w / 2), b.width - w / 2)
            let cy = min(max(CGFloat(f.y + f.h / 2) * b.height, h / 2), b.height - h / 2)
            c.layers[i].frame = NRect(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), in: b)
        }
        return c
    }
}
