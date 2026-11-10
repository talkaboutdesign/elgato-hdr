// Arranging a scene's layers directly on a picture, for the live window and the editor preview alike: click selects
// the topmost layer, drag moves it (snapping to the canvas, its margins and other layers, with guides; ⌥ turns
// snapping off), handles resize it, scroll or pinch resizes about the centre, arrow keys nudge, ⌫ deletes (game and
// camera are hidden), double-click crops (or, on text, edits it in the inspector). Geometry is worked out in pixels
// of the 1080p canvas, so a 1 px nudge is a pixel of the output. Views only convert points and draw.
import CoreGraphics
import Foundation

/// Main thread. What a picture editor edits (one composition on one canvas) and where its edits go: the live scene
/// collection (`SceneModel`) or a project's copy of a scene (`EditorModel`).
protocol LayerEditing: AnyObject {
    var editedComposition: Composition { get }
    var editedCanvas: Canvas { get }
    var editedSceneName: String { get }
    /// The scene `editedComposition` belongs to. A gesture is bound to the scene and canvas it started in.
    var editedSceneID: UUID? { get }
    var selectedLayerID: UUID? { get }
    var cropLayerID: UUID? { get }
    /// A text layer whose inspector field should take keyboard focus once shown.
    var focusTextLayerID: UUID? { get set }
    var addLayerOpen: Bool { get set }
    var layerActions: SceneActions { get }
    /// Folders an image layer's file is looked up in, in order.
    var assetSearchPaths: [URL] { get }
    /// The live Scene tab also adds game and camera layers; a recording's scenes only get overlays.
    var addsSourceLayers: Bool { get }
}

extension LayerEditing {
    var editedCanvasSize: CGSize { editedCanvas.size(.hd) }
    var selectedEditedLayer: Layer? { selectedLayerID.flatMap { id in editedComposition.layers.first { $0.id == id } } }
}

extension SceneModel: LayerEditing {
    var editedComposition: Composition { composition }
    var editedCanvas: Canvas { canvas }
    var editedSceneName: String { active.name }
    var editedSceneID: UUID? { active.id }
    var layerActions: SceneActions { actions }
    var assetSearchPaths: [URL] { AssetStore.searchPaths(project: nil) }
    var addsSourceLayers: Bool { true }
}

/// Which scene and canvas a picture shows. Duplicated scenes share layer ids, so a layer id alone does not say which
/// scene an edit is meant for.
struct LayerContext: Hashable { var sceneID: UUID?; var canvas: Canvas }

/// The layers as the picture shows them, in canvas pixels (origin top-left), for one pointer or key event.
struct LayerCanvas {
    let layers: [Layer]
    let size: CGSize
    let sources: [SourceKey: SourceInfo]
    let selectedID: UUID?, cropID: UUID?
    /// View points per canvas pixel, so handle and snap distances stay constant on screen.
    let pointsPerPixel: CGFloat
    /// A game layer the resolver draws over the whole canvas instead of its frame (`SceneResolver.pinnedGame`).
    let pinnedID: UUID?
    /// The scene and canvas these layers belong to (nil: not known, never ends a gesture).
    let context: LayerContext?

    init(layers: [Layer], size: CGSize, sources: [SourceKey: SourceInfo], selectedID: UUID?, cropID: UUID?, pointsPerPixel: CGFloat,
         context: LayerContext? = nil) {
        self.layers = layers; self.size = size; self.sources = sources; self.selectedID = selectedID; self.cropID = cropID
        self.context = context
        self.pointsPerPixel = pointsPerPixel > 0 && pointsPerPixel.isFinite ? pointsPerPixel : 1
        pinnedID = SceneResolver.pinnedGame(Composition(layers: layers), sources: sources)
    }
    init(_ e: LayerEditing, sources: [SourceKey: SourceInfo], pointsPerPixel: CGFloat) {
        self.init(layers: e.editedComposition.layers, size: e.editedCanvasSize, sources: sources, selectedID: e.selectedLayerID,
                  cropID: e.cropLayerID, pointsPerPixel: pointsPerPixel, context: LayerContext(sceneID: e.editedSceneID, canvas: e.editedCanvas))
    }

    func layer(_ id: UUID?) -> Layer? { id.flatMap { id in layers.first { $0.id == id } } }
    var selected: Layer? { layer(selectedID) }

    /// Where a layer is drawn, before fit: its frame, or the whole canvas for a pinned game. Selection, handles and
    /// hit-testing use this, so they sit on what the picture shows.
    func rect(_ l: Layer) -> CGRect { l.id == pinnedID ? CGRect(origin: .zero, size: size) : l.frame.rect(in: size) }
    /// A rule, not its frame, places this layer: it can be selected and cropped, but not moved or resized.
    func isPinned(_ l: Layer) -> Bool { l.id == pinnedID }
    /// The drawn area, including a camera's outer ring.
    func bounds(_ l: Layer) -> CGRect {
        let pad = l.source.type == "camera" ? l.frameWidth * min(size.width, size.height) : 0
        return rect(l).insetBy(dx: -pad, dy: -pad)
    }
    /// The topmost pickable layer under `p` (`LayerPicking.isPickable`).
    func hit(_ p: CGPoint) -> Layer? { layers.last { LayerPicking.isPickable($0) && bounds($0).contains(p) } }
    func handle(at p: CGPoint) -> LayerHandle? {
        guard let l = selected, l.visible, cropID == nil, !isPinned(l) else { return nil }
        let r = rect(l), slop = 7 / pointsPerPixel
        return LayerHandle.allCases.first { h in let q = h.point(in: r); return abs(q.x - p.x) <= slop && abs(q.y - p.y) <= slop }
    }
    func snapFrames(excluding id: UUID) -> [CGRect] { layers.filter { LayerPicking.isPickable($0) && $0.id != id }.map(bounds) }
    /// The layer as drawn alone (visible, opaque), for crop geometry.
    func resolved(_ l: Layer) -> ResolvedLayer? {
        var one = l; one.visible = true; one.opacity = 1
        if isPinned(l) { one.frame = .full }
        return SceneResolver.resolve(Composition(layers: [one]), canvas: size, sources: sources).first
    }
    /// Where the whole source would be with the current crop (crop mode), in canvas pixels.
    func sourceExtent(_ l: Layer) -> CGRect? {
        guard let r = resolved(l), r.src.width > 0, r.src.height > 0 else { return nil }
        let w = r.dst.width / r.src.width, h = r.dst.height / r.src.height
        let x0 = l.mirror ? 1 - r.src.maxX : r.src.minX
        return CGRect(x: r.dst.minX - x0 * w, y: r.dst.minY - r.src.minY * h, width: w, height: h)
    }
    /// Keeps a moved frame inside the canvas when it fits.
    func clamp(_ r: CGRect) -> CGRect {
        var r = r
        if r.width <= size.width { r.origin.x = min(max(r.minX, 0), size.width - r.width) }
        if r.height <= size.height { r.origin.y = min(max(r.minY, 0), size.height - r.height) }
        return r
    }
}

/// The pointer and keyboard rules. One per picture view; edits go through `SceneActions`, gestures become one undo
/// step each (drags on release, scroll, pinch and nudges once they pause).
final class LayerInteraction {
    enum Drag {
        case move(UUID, start: CGRect, grab: CGPoint)
        case resize(UUID, start: CGRect, handle: LayerHandle)
        case pan(UUID, start: CGPoint, panX: Double, panY: Double)
    }
    enum PointerResult: Equatable { case none, grabbing, resizing }
    private(set) var drag: Drag?
    private(set) var guides: [SnapGuide] = []
    /// Where the current drag started: a drag ends as soon as the picture shows another scene or canvas, so its
    /// start rectangle is never applied to a different scene's layer of the same id.
    private var dragContext: LayerContext?
    /// The open scroll, pinch or nudge step: its timer, name, actions and where it started.
    private var gestureEnd: DispatchWorkItem?
    private var openContinuous: (name: String, actions: SceneActions, context: LayerContext?)?
    /// How long scroll, pinch and nudges wait for more before closing their undo step.
    var pause: TimeInterval = 0.4

    func cancel() { drag = nil; guides = []; dragContext = nil }

    /// The layer being resized, for the size read-out.
    var resizingID: UUID? { if case .resize(let id, _, _)? = drag { return id }; return nil }

    func mouseDown(at p: CGPoint, clickCount: Int, canvas c: LayerCanvas, actions a: SceneActions) -> PointerResult {
        // A scroll or nudge step still waiting for its pause closes now: its timer must not end this drag's step.
        settleContinuous()
        dragContext = c.context
        if let crop = c.layer(c.cropID) {
            if c.rect(crop).contains(p) {
                if clickCount == 2 { a.setCrop(nil); return .none }
                a.beginGesture()
                drag = .pan(crop.id, start: p, panX: crop.panX, panY: crop.panY); return .grabbing
            }
            a.setCrop(nil)
        }
        if let h = c.handle(at: p), let s = c.selected {
            a.beginGesture(); drag = .resize(s.id, start: c.rect(s), handle: h); return .resizing
        }
        guard let l = c.hit(p) else { a.selectLayer(nil); return .none }
        if clickCount == 2, l.isGameOrCamera { a.setCrop(l.id); return .none }
        if clickCount == 2, l.source.type == "text" { a.editText(l.id); return .none }
        a.selectLayer(l.id)
        guard !c.isPinned(l) else { return .none }
        let r = c.rect(l)
        a.beginGesture()
        drag = .move(l.id, start: r, grab: CGPoint(x: p.x - r.minX, y: p.y - r.minY))
        return .grabbing
    }

    func mouseDragged(to p: CGPoint, option: Bool, shift: Bool, canvas c: LayerCanvas, actions a: SceneActions) {
        guard let d = drag else { return }
        if c.context != dragContext { mouseUp(actions: a); return }
        let snap = !option, size = c.size
        func snapper(excluding id: UUID) -> LayerSnapper? {
            snap ? LayerSnapper(canvas: size, others: c.snapFrames(excluding: id), threshold: 6 / c.pointsPerPixel) : nil
        }
        switch d {
        case .move(let id, let start, let grab):
            var r = start; r.origin = CGPoint(x: p.x - grab.x, y: p.y - grab.y)
            var g: [SnapGuide] = []
            var pad: CGFloat = 0
            if let moving = c.layer(id), moving.source.type == "camera" { pad = CGFloat(moving.frameWidth) * min(size.width, size.height) }
            r = r.insetBy(dx: -pad, dy: -pad)
            if let s = snapper(excluding: id) { (r, g) = s.snapMove(r) }
            r = c.clamp(r).insetBy(dx: pad, dy: pad)
            guides = g
            let frame = NRect(r, in: size)
            a.editLayer(id) { $0.frame = frame }
        case .resize(let id, let start, let handle):
            guard let l = c.layer(id) else { return }
            let (r, g) = LayerResize.resize(start, handle: handle, to: p, free: shift, keepAspectOnEdges: l.isGameOrCamera && !option, snapper: snapper(excluding: id))
            guides = g
            let frame = NRect(r, in: size)
            a.editLayer(id) { $0.frame = frame }
        case .pan(let id, let start, let panX, let panY):
            guard let l = c.layer(id), let r = c.resolved(l), r.dst.width > 0, r.dst.height > 0 else { return }
            // Drag the picture: the source moves with the pointer, so the crop centre moves against it.
            let dx = (p.x - start.x) / r.dst.width * r.src.width * (l.mirror ? -1 : 1), dy = (p.y - start.y) / r.dst.height * r.src.height
            let x = min(max(panX - Double(dx), Double(r.src.width / 2)), 1 - Double(r.src.width / 2))
            let y = min(max(panY - Double(dy), Double(r.src.height / 2)), 1 - Double(r.src.height / 2))
            a.editLayer(id) { $0.panX = x; $0.panY = y }
        }
    }

    /// Ends a drag; true when one was in progress (the view resets its cursor).
    @discardableResult
    func mouseUp(actions a: SceneActions) -> Bool {
        guard let d = drag else { return false }
        drag = nil; guides = []; dragContext = nil
        switch d {
        case .move: a.endGesture("Move Layer")
        case .resize: a.endGesture("Resize Layer")
        case .pan: a.endGesture("Crop Layer")
        }
        return true
    }

    /// Scroll over the selected layer: resizes it about its centre, or zooms the source in crop mode. False when the
    /// pointer is not over it (the view passes the event on).
    func scroll(at p: CGPoint, deltaY: CGFloat, precise: Bool, canvas c: LayerCanvas, actions a: SceneActions) -> Bool {
        guard let l = c.selected, l.visible, c.rect(l).contains(p) else { return false }
        let k = exp(deltaY * (precise ? 0.004 : 0.04))
        if c.cropID == l.id { zoomCrop(l, by: Double(k), canvas: c, actions: a) } else { scaleSelected(k, canvas: c, actions: a) }
        return true
    }
    func magnify(_ m: CGFloat, canvas c: LayerCanvas, actions a: SceneActions) {
        guard let l = c.selected else { return }
        if c.cropID == l.id { zoomCrop(l, by: 1 + Double(m), canvas: c, actions: a) } else { scaleSelected(1 + m, canvas: c, actions: a) }
    }
    private func zoomCrop(_ l: Layer, by k: Double, canvas c: LayerCanvas, actions a: SceneActions) {
        continuousEdit("Crop Layer", c, a)
        a.editLayer(l.id) { $0.zoom = min(5, max(1, $0.zoom * k)) }
    }

    /// Resizes the selected layer about its centre by `factor`, keeping its aspect.
    func scaleSelected(_ factor: CGFloat, canvas c: LayerCanvas, actions a: SceneActions) {
        guard let l = c.selected, !c.isPinned(l) else { return }
        let r = c.rect(l), aspect = r.width / max(r.height, 1)
        var w = r.width * factor, h = w / aspect
        let k = min(1, c.size.width / w, c.size.height / h); w *= k; h *= k
        if min(w, h) < LayerResize.minSide { let s = LayerResize.minSide / min(w, h); w *= s; h *= s }
        let frame = NRect(c.clamp(CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)), in: c.size)
        continuousEdit("Resize Layer", c, a)
        a.editLayer(l.id) { $0.frame = frame }
    }

    enum Key: Equatable { case left, right, up, down, delete, escape }
    static func key(code: UInt16) -> Key? {
        switch code {
        case 123: .left; case 124: .right; case 125: .down; case 126: .up
        case 51, 117: .delete            // delete, forward delete
        case 53: .escape
        default: nil
        }
    }

    /// Arrow keys nudge by 1 px (⇧: 10 px) or pan the source in crop mode, ⌫ deletes, Esc leaves crop mode or
    /// deselects. False when there is no selection (the key goes elsewhere).
    func key(_ k: Key, shift: Bool, canvas c: LayerCanvas, actions a: SceneActions) -> Bool {
        guard let l = c.selected else { return false }
        let step: CGFloat = shift ? 10 : 1
        var d = CGPoint.zero
        switch k {
        case .left: d.x = -step
        case .right: d.x = step
        case .down: d.y = step
        case .up: d.y = -step
        case .delete: a.deleteLayer(l.id); return true
        case .escape: if c.cropID != nil { a.setCrop(nil) } else { a.selectLayer(nil) }; return true
        }
        if c.cropID == l.id, let r = c.resolved(l), r.dst.width > 0 {
            continuousEdit("Crop Layer", c, a)
            let dx = Double(d.x / r.dst.width * r.src.width), dy = Double(d.y / r.dst.height * r.src.height)
            a.editLayer(l.id) { $0.panX -= dx; $0.panY -= dy }
        } else if !c.isPinned(l) {
            continuousEdit("Nudge Layer", c, a)
            let frame = NRect(c.rect(l).offsetBy(dx: d.x, dy: d.y), in: c.size)
            a.editLayer(l.id) { $0.frame = frame }
        }
        return true
    }

    /// Scroll and pinch arrive as many small events: they become one undo step once they pause. A burst that moves
    /// to another scene or canvas closes the step it had and starts another.
    private func continuousEdit(_ name: String, _ c: LayerCanvas, _ a: SceneActions) {
        if let open = openContinuous, open.context != c.context { settleContinuous() }
        a.beginGesture()
        gestureEnd?.cancel()
        openContinuous = (name, a, c.context)
        let w = DispatchWorkItem { [weak self] in self?.settleContinuous() }
        gestureEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: w)
    }

    /// Closes the open scroll, pinch or nudge step at once (its timer is cancelled).
    func settleContinuous() {
        gestureEnd?.cancel(); gestureEnd = nil
        guard let open = openContinuous else { return }
        openContinuous = nil
        open.actions.endGesture(open.name)
    }
}
