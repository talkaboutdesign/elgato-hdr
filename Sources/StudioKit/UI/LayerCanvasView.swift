import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// A picture whose layers can be arranged on it: the live window (`MetalView`) and the editor preview
/// (`EditorStageView`) both are one. It draws the hover outline, the selection with its eight handles, snap guides,
/// the crop extent and the size read-out over whatever its host layer shows, and turns pointer and key events into
/// `LayerInteraction` calls in canvas pixels. Image files dropped on it become image layers at the drop point.
class LayerCanvasView: NSView {
    /// The layer the picture is drawn into; the overlay layers sit on it.
    let host: CALayer
    private let hover = CAShapeLayer(), selection = CAShapeLayer(), handles = CAShapeLayer(), guideLayer = CAShapeLayer(), cropExtent = CAShapeLayer()
    private let dropTarget = CAShapeLayer()
    private let readout = CATextLayer()
    let interaction = LayerInteraction()
    /// What is being edited; nil shows the picture alone.
    weak var editing: (any LayerEditing)? { didSet { refreshOverlay() } }
    /// Pixel sizes of the sources that have frames, for laying layers out the way the picture does.
    var sources: (() -> [SourceKey: SourceInfo])?
    /// Aspect of the canvas shown: 16:9 or 9:16, letterboxed in the view.
    var canvasAspect = CGSize(width: 16, height: 9) { didSet { if canvasAspect != oldValue { refreshOverlay() } } }
    /// Right-click: the menu for the layer under the pointer (nil: none).
    var contextMenu: ((UUID?) -> NSMenu?)?
    /// The pointer moved over the picture.
    var onMouseActivity: (() -> Void)?
    /// Off while the picture is only for watching (focus mode, an export running).
    var editingEnabled = true { didSet { if editingEnabled != oldValue { if !editingEnabled { interaction.cancel() }; refreshOverlay() } } }
    private var hoverID: UUID?

    init(frame: NSRect, host: CALayer) {
        self.host = host
        super.init(frame: frame)
        wantsLayer = true; layer = host; layerContentsRedrawPolicy = .never
        let accent = NSColor.controlAccentColor.cgColor
        for l in [hover, selection, handles, guideLayer, cropExtent] { l.fillColor = nil; l.isHidden = true; l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]; host.addSublayer(l) }
        hover.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor; hover.lineWidth = 1
        selection.strokeColor = accent; selection.lineWidth = 1.5
        for l in [hover, selection] { l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = 0.5; l.shadowRadius = 1.5; l.shadowOffset = .zero }
        handles.fillColor = NSColor.white.cgColor; handles.strokeColor = accent; handles.lineWidth = 1
        handles.shadowColor = NSColor.black.cgColor; handles.shadowOpacity = 0.35; handles.shadowRadius = 1.5; handles.shadowOffset = CGSize(width: 0, height: -0.5)
        guideLayer.strokeColor = NSColor.systemPink.cgColor; guideLayer.lineWidth = 1
        cropExtent.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor; cropExtent.lineWidth = 1; cropExtent.lineDashPattern = [5, 4]
        cropExtent.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        readout.fontSize = 11; readout.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        readout.foregroundColor = NSColor.white.cgColor; readout.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        readout.cornerRadius = 5; readout.alignmentMode = .center; readout.isHidden = true
        readout.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        host.addSublayer(readout)
        dropTarget.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor; dropTarget.strokeColor = accent
        dropTarget.lineWidth = 2; dropTarget.lineDashPattern = [8, 5]; dropTarget.isHidden = true
        dropTarget.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        host.addSublayer(dropTarget)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); refreshOverlay() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); readout.contentsScale = window?.backingScaleFactor ?? 2 }
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
    var ref: CGSize { editing?.editedCanvasSize ?? Canvas.wide.size(.hd) }
    /// View point -> canvas pixel, top-left origin.
    func canvasPoint(_ e: NSEvent) -> CGPoint { canvasPoint(view: convert(e.locationInWindow, from: nil)) }
    func canvasPoint(view p: CGPoint) -> CGPoint {
        let v = videoRect
        return CGPoint(x: (p.x - v.minX) / v.width * ref.width, y: (v.maxY - p.y) / v.height * ref.height)
    }
    /// Canvas pixels -> view rect (AppKit coordinates).
    func viewRect(_ r: CGRect) -> CGRect {
        let v = videoRect, kx = v.width / ref.width, ky = v.height / ref.height
        return CGRect(x: v.minX + r.minX * kx, y: v.maxY - r.maxY * ky, width: r.width * kx, height: r.height * ky)
    }
    /// The layers as drawn, for this event.
    var canvas: LayerCanvas? {
        guard let e = editing else { return nil }
        return LayerCanvas(e, sources: sources?() ?? [:], pointsPerPixel: videoRect.width / ref.width)
    }

    // MARK: Overlay

    func refreshOverlay() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for l in [hover, selection, handles, guideLayer, cropExtent] as [CALayer] { l.frame = bounds }
        guard editingEnabled, let c = canvas else { [hover, selection, handles, guideLayer, cropExtent, readout].forEach { $0.isHidden = true }; return }
        func outline(_ l: Layer) -> CGPath {
            let r = viewRect(c.bounds(l)), inner = viewRect(c.rect(l))
            let pad = (r.width - inner.width) / 2
            let rad = min(0.5, max(0, l.roundness)) * min(inner.width, inner.height) + pad
            return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        }
        if let h = c.layer(hoverID), h.visible, h.id != c.selectedID, interaction.drag == nil { hover.path = outline(h); hover.isHidden = false } else { hover.isHidden = true }
        if let s = c.selected, s.visible {
            selection.path = outline(s); selection.isHidden = false
            let cropping = c.cropID == s.id
            selection.lineDashPattern = cropping ? [6, 4] : nil
            if cropping {
                handles.isHidden = true
                cropExtent.path = c.sourceExtent(s).map { CGPath(rect: viewRect($0), transform: nil) }; cropExtent.isHidden = cropExtent.path == nil
            } else if c.isPinned(s) {
                handles.isHidden = true; cropExtent.isHidden = true
            } else {
                let p = CGMutablePath(), r = viewRect(c.rect(s))
                for h in LayerHandle.allCases { let q = h.point(in: r); p.addRect(CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)) }
                handles.path = p; handles.isHidden = false; cropExtent.isHidden = true
            }
        } else { selection.isHidden = true; handles.isHidden = true; cropExtent.isHidden = true }
        let guides = interaction.guides
        if guides.isEmpty { guideLayer.isHidden = true } else {
            let p = CGMutablePath()
            for g in guides {
                let a = g.axis == .vertical ? CGPoint(x: g.position, y: g.from) : CGPoint(x: g.from, y: g.position)
                let b = g.axis == .vertical ? CGPoint(x: g.position, y: g.to) : CGPoint(x: g.to, y: g.position)
                let r = viewRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                p.move(to: CGPoint(x: r.minX.rounded() + 0.5, y: r.minY.rounded() + 0.5)); p.addLine(to: CGPoint(x: r.maxX.rounded() + 0.5, y: r.maxY.rounded() + 0.5))
            }
            guideLayer.path = p; guideLayer.isHidden = false
        }
        updateReadout(c)
    }

    private func updateReadout(_ c: LayerCanvas) {
        guard let l = c.layer(interaction.resizingID) else { readout.isHidden = true; return }
        let r = c.rect(l)
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
        guard editingEnabled, let c = canvas else { return }
        let p = canvasPoint(e), h = c.hit(p)
        if h?.id != hoverID { hoverID = h?.id; refreshOverlay() }
        let hd = c.handle(at: p)
        let tip = hd.map { $0.help(gameOrCamera: c.selected?.isGameOrCamera ?? false) }
        if toolTip != tip { toolTip = tip }
        if let hd = hd { cursor(for: hd).set() }
        else if let h = h, (h.id == c.selectedID && !c.isPinned(h)) || c.cropID == h.id { NSCursor.openHand.set() }
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
        guard editingEnabled, let ed = editing, let c = canvas else { super.mouseDown(with: e); return }
        window?.makeFirstResponder(self)
        let r = interaction.mouseDown(at: canvasPoint(e), clickCount: e.clickCount, canvas: c, actions: ed.layerActions)
        if r == .grabbing { NSCursor.closedHand.set() }
        refreshOverlay()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let ed = editing, let c = canvas, interaction.drag != nil else { return }
        interaction.mouseDragged(to: canvasPoint(e), option: e.modifierFlags.contains(.option), shift: e.modifierFlags.contains(.shift), canvas: c, actions: ed.layerActions)
        refreshOverlay()
    }

    override func mouseUp(with e: NSEvent) {
        guard let ed = editing else { return }
        let wasResizing = interaction.resizingID != nil
        guard interaction.mouseUp(actions: ed.layerActions) else { return }
        if !wasResizing { NSCursor.openHand.set() }
        refreshOverlay()
    }

    override func scrollWheel(with e: NSEvent) {
        guard editingEnabled, let ed = editing, let c = canvas,
              interaction.scroll(at: canvasPoint(e), deltaY: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas, canvas: c, actions: ed.layerActions)
        else { super.scrollWheel(with: e); return }
        refreshOverlay()
    }
    override func magnify(with e: NSEvent) {
        guard editingEnabled, let ed = editing, let c = canvas else { return }
        interaction.magnify(e.magnification, canvas: c, actions: ed.layerActions)
        refreshOverlay()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard editingEnabled, let ed = editing, let c = canvas else { return super.menu(for: event) }
        let l = c.hit(canvasPoint(event))
        if let l = l { ed.layerActions.selectLayer(l.id) }
        return contextMenu?(l?.id) ?? super.menu(for: event)
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) { if !handleLayerKey(e) { super.keyDown(with: e) } }

    /// Arrow keys, ⌫ and Esc for the selected layer; false when the key is not for it.
    func handleLayerKey(_ e: NSEvent) -> Bool {
        guard editingEnabled, let ed = editing, let c = canvas, c.selected != nil,
              e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let k = LayerInteraction.key(code: e.keyCode) else { return false }
        let handled = interaction.key(k, shift: e.modifierFlags.contains(.shift), canvas: c, actions: ed.layerActions)
        refreshOverlay()
        return handled
    }

    // MARK: Dropping image files

    /// Image files among the dragged items, in the formats the asset store takes.
    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { u in UTType(filenameExtension: u.pathExtension).map { t in AssetStore.supportedTypes.contains { t.conforms(to: $0) } } ?? false }
    }
    private func showDropTarget(_ on: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dropTarget.frame = bounds
        dropTarget.path = CGPath(rect: videoRect.insetBy(dx: 3, dy: 3), transform: nil)
        dropTarget.isHidden = !on
        CATransaction.commit()
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard editingEnabled, editing != nil, !imageURLs(info).isEmpty else { return [] }
        showDropTarget(true); return .copy
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { editingEnabled && !dropTarget.isHidden ? .copy : [] }
    override func draggingExited(_ info: NSDraggingInfo?) { showDropTarget(false) }
    override func draggingEnded(_ info: NSDraggingInfo) { showDropTarget(false) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        let urls = imageURLs(info)
        guard editingEnabled, let ed = editing, !urls.isEmpty else { return false }
        dropImages(urls, at: convert(info.draggingLocation, from: nil), actions: ed.layerActions)
        return true
    }
    /// Each file becomes a layer at the drop point (view coordinates); several are fanned out a little.
    func dropImages(_ urls: [URL], at viewPoint: CGPoint, actions: SceneActions) {
        let p = canvasPoint(view: viewPoint)
        for (i, u) in urls.prefix(8).enumerated() { actions.addImage(u, CGPoint(x: p.x + CGFloat(i) * 40, y: p.y + CGFloat(i) * 40)) }
    }
}
