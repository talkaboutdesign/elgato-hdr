import AppKit
import SwiftUI

/// One transparent AppKit view over the lanes takes every pointer event: clicks and drags (hit-tested against the
/// model), scroll and pinch, cursors and context menus. SwiftUI gestures on each drawn item would not scale.
struct TimelineInput: NSViewRepresentable {
    let model: EditorModel
    let layout: TimelineLayout

    func makeNSView(context: Context) -> TimelineInputView {
        let v = TimelineInputView()
        v.interaction = TimelineInteraction(model: model, layout: layout)
        return v
    }
    func updateNSView(_ v: TimelineInputView, context: Context) {
        if v.interaction?.layout != layout { v.interaction?.layout = layout }
    }
}

final class TimelineInputView: NSView {
    var interaction: TimelineInteraction?
    private var cursor = NSCursor.arrow

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Timeline" }
    override func accessibilityHelp() -> String? { "Click to move the playhead or select; drag edges to trim. Keyboard Shortcuts lists every action." }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) { interaction?.mouseDown(at: point(e), clickCount: e.clickCount, flags: e.modifierFlags); setCursor() }
    override func mouseDragged(with e: NSEvent) { interaction?.mouseDragged(to: point(e), flags: e.modifierFlags); setCursor() }
    override func mouseUp(with e: NSEvent) { interaction?.mouseUp(at: point(e)); interaction?.mouseMoved(to: point(e)); setCursor() }
    override func mouseMoved(with e: NSEvent) { interaction?.mouseMoved(to: point(e)); setCursor() }
    override func mouseExited(with e: NSEvent) { interaction?.mouseExited(); cursor = .arrow; cursor.set() }
    override func cursorUpdate(with e: NSEvent) { cursor.set() }
    override func scrollWheel(with e: NSEvent) {
        let precise = e.hasPreciseScrollingDeltas
        let k: CGFloat = precise ? 1 : 10
        interaction?.scroll(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k, at: point(e), zoom: e.modifierFlags.contains(.command))
    }
    override func magnify(with e: NSEvent) { interaction?.magnify(by: e.magnification, at: point(e)) }
    override func smartMagnify(with e: NSEvent) { interaction?.smartMagnify(at: point(e)) }
    override func menu(for e: NSEvent) -> NSMenu? { interaction?.menu(at: point(e)) }

    private func setCursor() {
        let c = interaction?.cursor ?? .arrow
        if c != cursor { cursor = c }
        cursor.set()
    }
}

/// Pointer logic over the model; pure enough to drive from the debug harness.
final class TimelineInteraction {
    weak var model: EditorModel?
    var layout: TimelineLayout
    private(set) var cursor = NSCursor.arrow

    private enum Drag {
        case none
        case pending(TimelineHit, start: CGPoint, time: Double)
        case scrub
        case marker(UUID, original: Double, grab: Double)
        case sceneChange(UUID)
        case zoomMove(UUID, original: ZoomBlock, grab: Double, room: (lo: Double, hi: Double))
        case zoomEdge(UUID, leading: Bool, room: (lo: Double, hi: Double))
        case cut(CutBoundary, original: [Segment])
    }
    private var drag = Drag.none
    static let dragThreshold = 3.0
    static let snapPoints = 8.0

    init(model: EditorModel, layout: TimelineLayout) { self.model = model; self.layout = layout }

    private func hit(_ p: CGPoint) -> TimelineHit? {
        guard let m = model else { return nil }
        return TimelineHitTest.hit(x: p.x, y: p.y, layout: layout, axis: m.axis, project: m.project, selection: m.selection)
    }

    // MARK: Clicks and drags

    func mouseDown(at p: CGPoint, clickCount: Int, flags: NSEvent.ModifierFlags) {
        guard let m = model, let h = hit(p) else { return }
        let t = m.axis.time(atX: p.x)
        m.hover = h
        switch h {
        case .ruler:
            m.beginScrub(); scrub(to: p, flags: flags); drag = .scrub
        case .marker(let id):
            m.select(.marker(id))
            if clickCount == 2, let mk = m.marker(id) { m.seek(mk.tMs / 1000) }
            drag = .pending(h, start: p, time: t)
        case .sceneChange(let id):
            m.selection = .scene(id); drag = .pending(h, start: p, time: t)
        case .sceneRun(let id):
            m.select(.scene(id)); drag = .none
        case .zoomEdge(let id, _), .zoom(let id):
            m.select(.zoom(id)); drag = .pending(h, start: p, time: t)
        case .cut:
            drag = .pending(h, start: p, time: t)
        case .section(let s):
            m.selection = .section(s); m.beginScrub(); m.seek(t); drag = .pending(h, start: p, time: t)
        case .lane:
            m.selection = .none; m.beginScrub(); m.seek(t); drag = .scrub
        }
        updateCursor(h, dragging: false)
    }

    func mouseDragged(to p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let m = model else { return }
        if case .pending(let h, let start, let t0) = drag {
            guard hypot(p.x - start.x, p.y - start.y) >= Self.dragThreshold else { return }
            beginDrag(h, at: t0)
        }
        let snapOn = !flags.contains(.option)
        let t = m.axis.time(atX: p.x)
        switch drag {
        case .none, .pending: return
        case .scrub: scrub(to: p, flags: flags)
        case .marker(let id, let original, let grab):
            let target = snapped((original + (t - grab) * 1000), excluding: [original], on: snapOn)
            m.update("Move Marker") { pr in
                if let i = pr.timeline.markers.firstIndex(where: { $0.id == id }) { pr.timeline.markers[i].tMs = TimelineEdits.snapToFrame(target, pr) }
            }
        case .sceneChange(let id):
            let own = m.project.timeline.sceneSpans.first { $0.id == id }?.startMs ?? -1
            let target = snapped(t * 1000, excluding: [own], on: snapOn)
            m.update("Move Scene Change") { TimelineEdits.moveSceneChange(&$0, spanID: id, toMs: target) }
        case .zoomMove(let id, let original, let grab, let room):
            let delta = (t - grab) * 1000
            // Snap whichever edge is closer to a snap point.
            let a = snapped(original.startMs + delta, excluding: [original.startMs, original.endMs], on: snapOn)
            let b = snapped(original.endMs + delta, excluding: [original.startMs, original.endMs], on: snapOn)
            let da = a - (original.startMs + delta), db = b - (original.endMs + delta)
            let adj = (da != 0 && (db == 0 || abs(da) <= abs(db))) ? da : db
            if da == 0 && db == 0 { m.snapGuide = nil } else { m.snapGuide = (adj == da ? a : b) / 1000 }
            m.update("Move Zoom") { TimelineEdits.moveZoom(&$0, id: id, original: original, byMs: delta + adj, room: room) }
        case .zoomEdge(let id, let leading, let room):
            let z = m.zoomBlock(id)
            let target = snapped(t * 1000, excluding: [z?.startMs ?? -1, z?.endMs ?? -1], on: snapOn)
            m.update("Resize Zoom") { TimelineEdits.resizeZoom(&$0, id: id, leading: leading, toMs: target, room: room) }
            if let z = m.zoomBlock(id), !m.playing { m.seek((leading ? z.startMs : z.endMs) / 1000) }
        case .cut(let b, let original):
            let target = snapped(t * 1000, excluding: [b.ms], on: snapOn)
            m.update("Trim") { TimelineEdits.move(b, to: target, original: original, in: &$0) }
            m.seek(TimelineEdits.snapToFrame(target, m.project) / 1000)
        }
    }

    private func beginDrag(_ h: TimelineHit, at t0: Double) {
        guard let m = model else { return }
        if m.editsLocked {
            // Exporting: looking around (scrubbing) is fine, edits wait.
            if case .section = h { drag = .scrub } else { drag = .none; NSSound.beep() }
            return
        }
        switch h {
        case .marker(let id):
            guard let mk = m.marker(id) else { drag = .none; return }
            m.beginGesture(); drag = .marker(id, original: mk.tMs, grab: t0)
        case .sceneChange(let id):
            m.beginGesture(); drag = .sceneChange(id)
        case .zoom(let id):
            guard let z = m.zoomBlock(id) else { drag = .none; return }
            m.beginGesture(); drag = .zoomMove(id, original: z, grab: t0, room: TimelineEdits.zoomRoom(m.project, id: id))
        case .zoomEdge(let id, let leading):
            m.beginGesture(); drag = .zoomEdge(id, leading: leading, room: TimelineEdits.zoomRoom(m.project, id: id))
        case .cut(let b):
            m.beginGesture(); m.beginScrub(); drag = .cut(b, original: TimelineEdits.kept(m.project))
        case .section:
            drag = .scrub
        default:
            drag = .none
        }
        updateCursor(h, dragging: true)
    }

    func mouseUp(at p: CGPoint) {
        guard let m = model else { return }
        switch drag {
        case .scrub, .pending(.section, _, _): m.endScrub()
        case .cut: m.endScrub(); m.endGesture()
        case .marker, .sceneChange, .zoomMove, .zoomEdge: m.endGesture()
        default: break
        }
        if case .pending = drag, m.scrubbing { m.endScrub() }
        drag = .none
        m.snapGuide = nil
    }

    func mouseMoved(to p: CGPoint) {
        guard let m = model, case .none = drag else { return }
        let h = hit(p)
        if m.hover != h { m.hover = h }
        updateCursor(h, dragging: false)
    }
    func mouseExited() { guard case .none = drag else { return }; model?.hover = nil; cursor = .arrow }

    private func updateCursor(_ h: TimelineHit?, dragging: Bool) {
        switch h {
        case .cut, .sceneChange, .zoomEdge: cursor = .resizeLeftRight
        case .zoom: cursor = dragging ? .closedHand : .openHand
        case .marker: cursor = dragging ? .closedHand : .pointingHand
        default: cursor = .arrow
        }
    }

    private func scrub(to p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let m = model else { return }
        let t = m.axis.time(atX: p.x) * 1000
        // Scrubbing lands exactly on cuts and markers when it passes close to them.
        let s = flags.contains(.option) ? t : snapped(t, excluding: [], on: true, points: 5, includePlayhead: false)
        m.seek(s / 1000)
    }

    /// Snaps a time (ms) to the playhead, markers, cuts, scene changes and zoom edges within a few points.
    private func snapped(_ ms: Double, excluding: [Double], on: Bool, points: Double = snapPoints, includePlayhead: Bool = true) -> Double {
        guard let m = model else { return ms }
        guard on else { m.snapGuide = nil; return ms }
        var candidates = TimelineEdits.editPoints(m.project)
        if includePlayhead { candidates.append(m.playheadMs) }
        candidates.removeAll { c in excluding.contains { abs($0 - c) < 0.5 } }
        let tol = points / max(m.axis.pps, 0.0001) * 1000
        let r = Snapping.snap(ms, to: candidates, tolerance: tol)
        m.snapGuide = r.target.map { $0 / 1000 }
        return r.value
    }

    // MARK: Scroll and zoom

    func scroll(dx: CGFloat, dy: CGFloat, at p: CGPoint, zoom: Bool) {
        guard let m = model else { return }
        var a = m.axis
        if zoom { a.zoom(by: exp(Double(dy) * 0.012), anchorX: p.x) }
        else { a.pan(by: -Double(abs(dx) >= abs(dy) ? dx : dy)) }
        if a != m.axis { m.axis = a }
    }
    func magnify(by f: CGFloat, at p: CGPoint) {
        guard let m = model else { return }
        var a = m.axis
        a.zoom(by: 1 + Double(f), anchorX: p.x)
        m.axis = a
    }
    func smartMagnify(at p: CGPoint) {
        guard let m = model else { return }
        var a = m.axis
        if a.isZoomedIn { a.fit() } else { a.zoom(by: 6, anchorX: p.x) }
        m.axis = a
    }

    // MARK: Context menu

    func menu(at p: CGPoint) -> NSMenu? {
        guard let m = model, let h = hit(p) else { return nil }
        let t = m.axis.time(atX: p.x)
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action); item.isEnabled = enabled && !m.editsLocked; menu.addItem(item)
        }
        func sceneItems(_ id: UUID?) {
            m.selection = .scene(id)
            if let run = m.selectedSceneRun() {
                let sub = NSMenu()
                for c in m.sceneChoices {
                    let it = ClosureMenuItem(title: c.name) { m.setScene(c, for: run) }
                    it.state = c.sceneID != nil && c.sceneID == run.sceneID ? .on : .off
                    sub.addItem(it)
                }
                let parent = NSMenuItem(title: "Scene", action: nil, keyEquivalent: ""); parent.submenu = sub; parent.isEnabled = !m.editsLocked
                menu.addItem(parent)
            }
            let changes = NSMenu()
            for c in m.sceneChoices { changes.addItem(ClosureMenuItem(title: c.name) { m.seek(t); m.addSceneChange(c) }) }
            let change = NSMenuItem(title: "Change Scene Here", action: nil, keyEquivalent: ""); change.submenu = changes; change.isEnabled = !m.editsLocked
            menu.addItem(change)
            if id != nil { add("Delete Scene Change") { m.selection = .scene(id); m.deleteSelection() } }
        }
        switch h {
        case .section(let s):
            m.selection = .section(s)
            add(s.kept ? "Remove Section" : "Restore Section") { m.deleteSelection() }
            add("Split Here") { m.seek(t); m.split() }
        case .cut(let b):
            add("Split Here") { m.seek(b.ms / 1000); m.split() }
        case .sceneRun(let id): sceneItems(id)
        case .sceneChange(let id): sceneItems(id)
        case .zoom(let id), .zoomEdge(let id, _):
            m.select(.zoom(id))
            add("Delete Zoom") { m.selection = .zoom(id); m.deleteSelection() }
        case .marker(let id):
            m.selection = .marker(id)
            add("Make Short from Marker") { m.makeShort(from: id) }
            add("Delete Marker") { m.selection = .marker(id); m.deleteSelection() }
        case .ruler, .lane:
            add("Add Marker Here") { m.seek(t); m.addMarker() }
            add("Add Zoom Here") { m.seek(t); m.addZoom() }
            add("Split Here") { m.seek(t); m.split() }
        }
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
