import AppKit
import Metal
import QuartzCore

/// The live view. Besides hosting the Metal layer it lets you arrange the active scene's layers directly on the
/// picture: click selects the topmost layer, drag moves it (snapping to the canvas, its margins and other layers,
/// with guides; ⌥ turns snapping off), handles resize it, scroll or pinch resizes about the centre, arrow keys nudge,
/// ⌫ deletes (game and camera are hidden), double-click crops. Geometry is worked out in pixels of the 1080p canvas,
/// so a 1 px nudge is a pixel of the output.
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    private let hover = CAShapeLayer(), selection = CAShapeLayer(), handles = CAShapeLayer(), guides = CAShapeLayer(), cropExtent = CAShapeLayer()
    private let readout = CATextLayer()
    /// Aspect of the canvas the window shows: 16:9 or 9:16, letterboxed in the view.
    var canvasAspect = CGSize(width: 16, height: 9) { didSet { if canvasAspect != oldValue { refreshOverlay() } } }
    /// Pixel size of the game frames, for laying out layers outside the renderer.
    var gameSize = CGSize(width: 1920, height: 1080)
    weak var scenes: SceneModel?
    var sources: (() -> [SourceKey: SourceInfo])?
    /// Right-click: the menu for the layer under the pointer (nil: none).
    var contextMenu: ((UUID?) -> NSMenu?)?
    /// Pointer moved over the picture: the studio window shows its auto-hiding status pill.
    var onMouseActivity: (() -> Void)?
    /// Off in focus mode: the picture is for watching then.
    var editingEnabled = true { didSet { if editingEnabled != oldValue { if !editingEnabled { drag = nil; guideList = [] }; refreshOverlay() } } }

    private enum Drag {
        case move(UUID, start: CGRect, grab: CGPoint)
        case resize(UUID, start: CGRect, handle: LayerHandle)
        case pan(UUID, start: CGPoint, panX: Double, panY: Double)
    }
    private var drag: Drag?
    private var hoverID: UUID?
    private var guideList: [SnapGuide] = []
    private var gestureEnd: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer = metalLayer; layerContentsRedrawPolicy = .never
        let accent = NSColor.controlAccentColor.cgColor
        for l in [hover, selection, handles, guides, cropExtent] { l.fillColor = nil; l.isHidden = true; l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]; metalLayer.addSublayer(l) }
        hover.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor; hover.lineWidth = 1
        selection.strokeColor = accent; selection.lineWidth = 1.5
        for l in [hover, selection] { l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = 0.5; l.shadowRadius = 1.5; l.shadowOffset = .zero }
        handles.fillColor = NSColor.white.cgColor; handles.strokeColor = accent; handles.lineWidth = 1
        handles.shadowColor = NSColor.black.cgColor; handles.shadowOpacity = 0.35; handles.shadowRadius = 1.5; handles.shadowOffset = CGSize(width: 0, height: -0.5)
        guides.strokeColor = NSColor.systemPink.cgColor; guides.lineWidth = 1
        cropExtent.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor; cropExtent.lineWidth = 1; cropExtent.lineDashPattern = [5, 4]
        cropExtent.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        readout.fontSize = 11; readout.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        readout.foregroundColor = NSColor.white.cgColor; readout.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        readout.cornerRadius = 5; readout.alignmentMode = .center; readout.isHidden = true
        readout.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        metalLayer.addSublayer(readout)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); updateDrawableSize(); refreshOverlay() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); updateDrawableSize()
        readout.contentsScale = window?.backingScaleFactor ?? 2
    }
    func updateDrawableSize() {
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Coordinates

    /// The canvas inside the view (points, AppKit coordinates).
    var videoRect: CGRect {
        guard canvasAspect.width > 0, canvasAspect.height > 0 else { return bounds }
        let s = min(bounds.width / canvasAspect.width, bounds.height / canvasAspect.height)
        let w = canvasAspect.width * s, h = canvasAspect.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
    /// Canvas pixels the geometry works in (1920×1080 or 1080×1920).
    private var ref: CGSize { scenes?.canvasSize ?? Canvas.wide.size(.hd) }
    /// View point -> canvas pixel, top-left origin.
    private func canvasPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil), v = videoRect
        return CGPoint(x: (p.x - v.minX) / v.width * ref.width, y: (v.maxY - p.y) / v.height * ref.height)
    }
    /// Canvas pixels -> view rect (AppKit coordinates).
    private func viewRect(_ r: CGRect) -> CGRect {
        let v = videoRect, kx = v.width / ref.width, ky = v.height / ref.height
        return CGRect(x: v.minX + r.minX * kx, y: v.maxY - r.maxY * ky, width: r.width * kx, height: r.height * ky)
    }
    /// View points per canvas pixel.
    private var pointsPerPixel: CGFloat { videoRect.width / ref.width }

    private var layers: [Layer] { scenes?.composition.layers ?? [] }
    private func layer(_ id: UUID?) -> Layer? { id.flatMap { id in layers.first { $0.id == id } } }
    private func rect(_ l: Layer) -> CGRect { l.frame.rect(in: ref) }
    /// Topmost visible, non-transparent layer under `p`.
    private func hit(_ p: CGPoint) -> Layer? { LayerPicking.hit(layers, at: p, canvas: ref) }
    private func handle(at p: CGPoint) -> LayerHandle? {
        guard let l = layer(scenes?.selectedLayerID), l.visible, scenes?.cropLayerID == nil else { return nil }
        let r = rect(l), slop = 7 / pointsPerPixel
        return LayerHandle.allCases.first { h in let q = h.point(in: r); return abs(q.x - p.x) <= slop && abs(q.y - p.y) <= slop }
    }

    // MARK: Overlay

    func refreshOverlay() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for l in [hover, selection, handles, guides, cropExtent] as [CALayer] { l.frame = bounds }
        guard editingEnabled, let m = scenes else { [hover, selection, handles, guides, cropExtent, readout].forEach { $0.isHidden = true }; return }
        func outline(_ l: Layer) -> CGPath {
            let r = viewRect(rect(l)), rad = min(0.5, max(0, l.roundness)) * min(r.width, r.height)
            return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        }
        if let h = layer(hoverID), h.visible, h.id != m.selectedLayerID, drag == nil { hover.path = outline(h); hover.isHidden = false } else { hover.isHidden = true }
        if let s = m.selectedLayer, s.visible {
            selection.path = outline(s); selection.isHidden = false
            let cropping = m.cropLayerID == s.id
            selection.lineDashPattern = cropping ? [6, 4] : nil
            if cropping {
                handles.isHidden = true
                cropExtent.path = sourceExtent(s).map { CGPath(rect: $0, transform: nil) }; cropExtent.isHidden = cropExtent.path == nil
            } else {
                let p = CGMutablePath(), r = viewRect(rect(s))
                for h in LayerHandle.allCases { let q = h.point(in: r); p.addRect(CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)) }
                handles.path = p; handles.isHidden = false; cropExtent.isHidden = true
            }
        } else { selection.isHidden = true; handles.isHidden = true; cropExtent.isHidden = true }
        if guideList.isEmpty { guides.isHidden = true } else {
            let p = CGMutablePath()
            for g in guideList {
                let a = g.axis == .vertical ? CGPoint(x: g.position, y: g.from) : CGPoint(x: g.from, y: g.position)
                let b = g.axis == .vertical ? CGPoint(x: g.position, y: g.to) : CGPoint(x: g.to, y: g.position)
                let r = viewRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                p.move(to: CGPoint(x: r.minX.rounded() + 0.5, y: r.minY.rounded() + 0.5)); p.addLine(to: CGPoint(x: r.maxX.rounded() + 0.5, y: r.maxY.rounded() + 0.5))
            }
            guides.path = p; guides.isHidden = false
        }
        updateReadout()
    }

    /// Where the whole source would be with the current crop, in view coordinates (crop mode).
    private func sourceExtent(_ l: Layer) -> CGRect? {
        guard let r = resolved(l), r.src.width > 0, r.src.height > 0 else { return nil }
        let w = r.dst.width / r.src.width, h = r.dst.height / r.src.height
        let x0 = l.mirror ? 1 - r.src.maxX : r.src.minX
        return viewRect(CGRect(x: r.dst.minX - x0 * w, y: r.dst.minY - r.src.minY * h, width: w, height: h))
    }
    private func resolved(_ l: Layer) -> ResolvedLayer? {
        var c = Composition(); c.layers = [l]; c.layers[0].visible = true; c.layers[0].opacity = 1
        return SceneResolver.resolve(c, canvas: ref, sources: sources?() ?? [:]).first
    }

    private func updateReadout() {
        guard case .resize(let id, _, _)? = drag, let l = layer(id) else { readout.isHidden = true; return }
        let r = rect(l)
        readout.string = "\(PixelField.format(r.width)) × \(PixelField.format(r.height))"
        let v = viewRect(r), w: CGFloat = 86, h: CGFloat = 18
        readout.frame = CGRect(x: (v.midX - w / 2).rounded(), y: max(videoRect.minY + 4, v.minY - h - 8).rounded(), width: w, height: h)
        readout.contentsScale = window?.backingScaleFactor ?? 2
        readout.isHidden = false
    }

    // MARK: Mouse

    override func mouseEntered(with e: NSEvent) { onMouseActivity?() }
    override func mouseMoved(with e: NSEvent) {
        onMouseActivity?()
        guard editingEnabled, scenes != nil else { return }
        let p = canvasPoint(e), h = hit(p)
        if h?.id != hoverID { hoverID = h?.id; refreshOverlay() }
        let hd = handle(at: p)
        let tip = hd.map { $0.help(gameOrCamera: scenes?.selectedLayer?.isGameOrCamera ?? false) }
        if toolTip != tip { toolTip = tip }
        if let hd = hd { cursor(for: hd).set() }
        else if let h = h, h.id == scenes?.selectedLayerID || scenes?.cropLayerID == h.id { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }
    override func mouseExited(with e: NSEvent) { if hoverID != nil { hoverID = nil; refreshOverlay() }; NSCursor.arrow.set() }

    private func cursor(for h: LayerHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let all: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
            return NSCursor.frameResize(position: all[h.rawValue], directions: .all)
        }
        return h.dir.x == 0 ? .resizeUpDown : h.dir.y == 0 ? .resizeLeftRight : .crosshair
    }

    override func mouseDown(with e: NSEvent) {
        guard editingEnabled, let m = scenes else { super.mouseDown(with: e); return }
        window?.makeFirstResponder(self)
        let p = canvasPoint(e)
        if let crop = layer(m.cropLayerID) {
            if rect(crop).contains(p) {
                if e.clickCount == 2 { m.actions.setCrop(nil); return }
                m.actions.beginGesture()
                drag = .pan(crop.id, start: p, panX: crop.panX, panY: crop.panY); NSCursor.closedHand.set(); return
            }
            m.actions.setCrop(nil)
        }
        if let h = handle(at: p), let s = m.selectedLayer {
            m.actions.beginGesture(); drag = .resize(s.id, start: rect(s), handle: h); return
        }
        guard let l = hit(p) else { m.actions.selectLayer(nil); return }
        if e.clickCount == 2, l.isGameOrCamera { m.actions.setCrop(l.id); return }
        m.actions.selectLayer(l.id)
        let r = rect(l)
        m.actions.beginGesture()
        drag = .move(l.id, start: r, grab: CGPoint(x: p.x - r.minX, y: p.y - r.minY))
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag, let m = scenes else { return }
        let p = canvasPoint(e), canvas = CGRect(origin: .zero, size: ref)
        let snap = !e.modifierFlags.contains(.option)
        func snapper(excluding id: UUID) -> LayerSnapper? {
            snap ? LayerSnapper(canvas: ref, others: LayerPicking.snapFrames(layers, excluding: id, canvas: ref), threshold: 6 / pointsPerPixel) : nil
        }
        switch d {
        case .move(let id, let start, let grab):
            var r = start; r.origin = CGPoint(x: p.x - grab.x, y: p.y - grab.y)
            var g: [SnapGuide] = []
            if let s = snapper(excluding: id) { (r, g) = s.snapMove(r) }
            r = clamp(r, canvas)
            guideList = g
            m.actions.editLayer(id) { $0.frame = NRect(r, in: self.ref) }
        case .resize(let id, let start, let handle):
            guard let l = layer(id) else { return }
            let (r, g) = LayerResize.resize(start, handle: handle, to: p, free: e.modifierFlags.contains(.shift),
                                            keepAspectOnEdges: l.isGameOrCamera && !e.modifierFlags.contains(.option), snapper: snapper(excluding: id))
            guideList = g
            m.actions.editLayer(id) { $0.frame = NRect(r, in: self.ref) }
        case .pan(let id, let start, let panX, let panY):
            guard let l = layer(id), let r = resolved(l), r.dst.width > 0, r.dst.height > 0 else { return }
            // Drag the picture: the source moves with the pointer, so the crop centre moves against it.
            let dx = (p.x - start.x) / r.dst.width * r.src.width * (l.mirror ? -1 : 1), dy = (p.y - start.y) / r.dst.height * r.src.height
            let x = min(max(panX - Double(dx), Double(r.src.width / 2)), 1 - Double(r.src.width / 2))
            let y = min(max(panY - Double(dy), Double(r.src.height / 2)), 1 - Double(r.src.height / 2))
            m.actions.editLayer(id) { $0.panX = x; $0.panY = y }
        }
        refreshOverlay()
    }

    /// Keeps a moved frame inside the canvas when it fits.
    private func clamp(_ r: CGRect, _ c: CGRect) -> CGRect {
        var r = r
        if r.width <= c.width { r.origin.x = min(max(r.minX, c.minX), c.maxX - r.width) }
        if r.height <= c.height { r.origin.y = min(max(r.minY, c.minY), c.maxY - r.height) }
        return r
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = drag else { return }
        drag = nil; guideList = []
        switch d {
        case .move: scenes?.actions.endGesture("Move Layer"); NSCursor.openHand.set()
        case .resize: scenes?.actions.endGesture("Resize Layer")
        case .pan: scenes?.actions.endGesture("Crop Layer"); NSCursor.openHand.set()
        }
        refreshOverlay()
    }

    /// Scroll and pinch arrive as many small events: they become one undo step once they pause.
    private func continuousEdit(_ name: String) {
        scenes?.actions.beginGesture()
        gestureEnd?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scenes?.actions.endGesture(name) }
        gestureEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Resizes the selected layer about its centre by `factor`, keeping its aspect.
    private func scaleSelected(_ factor: CGFloat) {
        guard let m = scenes, let l = m.selectedLayer else { return }
        let r = rect(l), aspect = r.width / max(r.height, 1)
        var w = r.width * factor, h = w / aspect
        let k = min(1, ref.width / w, ref.height / h); w *= k; h *= k
        if min(w, h) < LayerResize.minSide { let s = LayerResize.minSide / min(w, h); w *= s; h *= s }
        let n = clamp(CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), CGRect(origin: .zero, size: ref))
        continuousEdit("Resize Layer")
        m.actions.editLayer(l.id) { $0.frame = NRect(n, in: self.ref) }
        refreshOverlay()
    }

    override func scrollWheel(with e: NSEvent) {
        guard editingEnabled, let m = scenes, let l = m.selectedLayer, l.visible, rect(l).contains(canvasPoint(e)) else { super.scrollWheel(with: e); return }
        let k = exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04))
        if m.cropLayerID == l.id {
            continuousEdit("Crop Layer")
            m.actions.editLayer(l.id) { $0.zoom = min(5, max(1, $0.zoom * Double(k))) }
            refreshOverlay()
        } else { scaleSelected(k) }
    }
    override func magnify(with e: NSEvent) {
        guard editingEnabled, let m = scenes, let l = m.selectedLayer else { return }
        if m.cropLayerID == l.id {
            continuousEdit("Crop Layer")
            m.actions.editLayer(l.id) { $0.zoom = min(5, max(1, $0.zoom * (1 + Double(e.magnification)))) }
            refreshOverlay()
        } else { scaleSelected(1 + e.magnification) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard editingEnabled, let m = scenes else { return super.menu(for: event) }
        let l = hit(canvasPoint(event))
        if let l = l { m.actions.selectLayer(l.id) }
        return contextMenu?(l?.id) ?? super.menu(for: event)
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        guard editingEnabled, let m = scenes, let l = m.selectedLayer else { super.keyDown(with: e); return }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { super.keyDown(with: e); return }
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        var d = CGPoint.zero
        switch e.keyCode {
        case 123: d.x = -step
        case 124: d.x = step
        case 125: d.y = step
        case 126: d.y = -step
        case 51, 117: m.actions.deleteLayer(l.id); return            // delete, forward delete
        case 53: if m.cropLayerID != nil { m.actions.setCrop(nil) } else { m.actions.selectLayer(nil) }; return   // escape
        default: super.keyDown(with: e); return
        }
        if m.cropLayerID == l.id, let r = resolved(l), r.dst.width > 0 {
            continuousEdit("Crop Layer")
            m.actions.editLayer(l.id) { $0.panX -= Double(d.x / r.dst.width * r.src.width); $0.panY -= Double(d.y / r.dst.height * r.src.height) }
        } else {
            continuousEdit("Nudge Layer")
            let r = rect(l).offsetBy(dx: d.x, dy: d.y)
            m.actions.editLayer(l.id) { $0.frame = NRect(r, in: self.ref) }
        }
        refreshOverlay()
    }
}
