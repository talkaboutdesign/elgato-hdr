import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore


/// The live view. Besides hosting the Metal layer it lets you place the facecam directly: drag to move (snaps to
/// corners and edges), drag a corner or scroll/pinch to resize.
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    let outline = CAShapeLayer()
    var videoSize = CGSize(width: 16, height: 9)
    /// Current facecam placement, or nil when no camera is shown.
    var placement: (() -> CameraPlacement?)?
    var onPlacement: ((CameraPlacement) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private enum Drag { case move(CGPoint, CameraPlacement), resize(CameraPlacement) }
    private var drag: Drag?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer = metalLayer; layerContentsRedrawPolicy = .never
        outline.fillColor = nil; outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1.5; outline.lineDashPattern = [6, 4]; outline.isHidden = true
        outline.shadowColor = NSColor.black.cgColor; outline.shadowOpacity = 0.6; outline.shadowRadius = 2; outline.shadowOffset = .zero
        metalLayer.addSublayer(outline)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateDrawableSize(); updateOutline() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
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

    /// The game picture inside the view (points, AppKit coordinates).
    var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let s = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * s, h = videoSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
    /// View point -> canvas point (top-left origin, in points).
    private func canvasPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil), v = videoRect
        return CGPoint(x: p.x - v.minX, y: v.maxY - p.y)
    }
    private func camRect() -> CGRect? { placement?().map { $0.rect(in: videoRect.size) } }
    private func cornerHit(_ p: CGPoint, _ r: CGRect) -> Bool {
        let k: CGFloat = 14
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .contains { abs($0.x - p.x) < k && abs($0.y - p.y) < k }
    }

    func updateOutline() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard (hovering || drag != nil), let pl = placement?(), let r = camRect() else { outline.isHidden = true; return }
        let v = videoRect
        let viewRect = CGRect(x: v.minX + r.minX, y: v.maxY - r.maxY, width: r.width, height: r.height)
        let rad = pl.radius(for: r)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: viewRect.insetBy(dx: -3, dy: -3), cornerWidth: rad + 3, cornerHeight: rad + 3, transform: nil)
        outline.isHidden = false
    }

    override func mouseMoved(with e: NSEvent) {
        let p = canvasPoint(e)
        let r = camRect()
        let inside = r.map { $0.insetBy(dx: -8, dy: -8).contains(p) } ?? false
        if inside != hovering { hovering = inside; updateOutline() }
        if let r = r, cornerHit(p, r) { NSCursor.crosshair.set() } else if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with e: NSEvent) { hovering = false; updateOutline(); NSCursor.arrow.set() }

    override func mouseDown(with e: NSEvent) {
        let p = canvasPoint(e)
        guard let pl = placement?(), let r = camRect() else { super.mouseDown(with: e); return }
        if e.clickCount == 2, r.contains(p) { return }
        if cornerHit(p, r) { drag = .resize(pl) }
        else if r.insetBy(dx: -8, dy: -8).contains(p) { drag = .move(CGPoint(x: p.x - r.midX, y: p.y - r.midY), pl); NSCursor.closedHand.set() }
        else { super.mouseDown(with: e) }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let p = canvasPoint(e), canvas = videoRect.size
        switch d {
        case .move(let grab, var pl):
            pl.move(to: CGPoint(x: p.x - grab.x, y: p.y - grab.y), canvas: canvas, snap: !e.modifierFlags.contains(.option))
            onPlacement?(pl)
        case .resize(var pl):
            let r = pl.rect(in: canvas)
            // Window size follows the pointer's distance from the centre (keeps the centre fixed).
            let a = pl.aspect.value
            let halfShort = max(abs(p.x - r.midX) / (a >= 1 ? a : 1), abs(p.y - r.midY) * (a >= 1 ? 1 : a))
            pl.size = min(1, max(0.08, Double(2 * halfShort / min(canvas.width, canvas.height))))
            onPlacement?(pl)
        }
        updateOutline()
    }
    override func mouseUp(with e: NSEvent) { if drag != nil { drag = nil; NSCursor.openHand.set(); updateOutline() } }

    override func scrollWheel(with e: NSEvent) {
        guard var pl = placement?(), let r = camRect(), r.contains(canvasPoint(e)) else { super.scrollWheel(with: e); return }
        pl.size = min(1, max(0.08, pl.size * exp(Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04))))
        onPlacement?(pl); updateOutline()
    }
    override func magnify(with e: NSEvent) {
        guard var pl = placement?() else { return }
        pl.size = min(1, max(0.08, pl.size * (1 + Double(e.magnification))))
        onPlacement?(pl); updateOutline()
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }
}

