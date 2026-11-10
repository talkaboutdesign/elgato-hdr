import AppKit
import CoreVideo
import SwiftUI

/// Main-thread scene state that the UI does not read: storage, the renderer's live state, menu, keys, event log.
final class SceneRuntime {
    let store = SceneStore()
    var live = LiveSceneState(scene: SceneTemplate.gameOnly.scene())
    let menu = NSMenu(title: "Scenes")
    var menuStructure = ""
    var keyMonitor: Any?
    var spaceHeld = false
    let thumbnailer = SceneThumbnailer()
    var thumbnailTimer: Timer?
    /// The collection when the current drag or slider began; its edits become one undo step at the end.
    var gestureStart: SceneCollection?
    var eventLog: SessionEventLog?
    var pendingProjectSave: DispatchWorkItem?
    /// View › Show Clean Game Picture in Focus Mode (persisted, on by default).
    var cleanGameInFocus = WindowPicture.setting()
    var cleanGameItem: NSMenuItem?
    /// `{timer}` origin and asset folders, copied into the renderer.
    var overlayContext = LiveOverlayContext()
}

// Scenes: switching with transitions, editing the active scene, punch-in, the Scenes menu and the event log.
// The collection lives in `state.scenes` (what the UI reads); the renderer gets a `LiveSceneState` copy.
extension AppDelegate {
    var scenes: SceneModel { state.scenes }

    // MARK: Setup

    func setUpScenes() {
        let m = scenes, rt = sceneRuntime
        if let c = rt.store.load() { m.collection = c }
        else {
            // First launch with scenes: the facecam window placed before scenes existed becomes Gameplay's.
            m.collection = .defaults(placement: livePlacement, mirror: cameraMirror)
            rt.store.flush(m.collection)
            log("scenes: created the default scenes in \(rt.store.url.path)")
        }
        m.canvas = Canvas(rawValue: UserDefaults.standard.string(forKey: "sceneCanvas") ?? "") ?? .wide
        let amount = UserDefaults.standard.double(forKey: "punchInZoom")
        m.punchAmount = PunchIn.range.contains(amount) ? amount : 1.6
        rt.live = LiveSceneState(scene: m.collection.active)
        installSceneActions()
        view.scenes = m
        view.sources = { [weak self] in self?.liveSources() ?? [:] }
        view.contextMenu = { [weak self] id in self?.pictureMenu(layer: id) }
        installSceneKeys()
        startThumbnails()
        scheduleSceneTorture()
        scheduleSceneScript()
        startOverlayClock()
        #if DEBUG
        startSceneDebug()
        #endif
        trackChanges({ [weak self] in self?.state.focusMode ?? false }) { [weak self] focus in self?.view.editingEnabled = !focus; self?.pushScene() }
        sceneDidChange(save: false)
        log("scenes: \(m.collection.scenes.count) scenes, active \(m.active.name), canvas \(m.canvas.label), transition \(m.collection.transition.style.rawValue) \(String(format: "%.0f", m.collection.transition.durationMs)) ms")
    }

    func installSceneActions() {
        var a = SceneActions()
        a.switchTo = { [weak self] in self?.switchScene(to: $0) }
        a.add = { [weak self] in self?.addScene($0) }
        a.duplicate = { [weak self] in self?.duplicateScene($0) }
        a.delete = { [weak self] in self?.deleteScene($0) }
        a.rename = { [weak self] in self?.renameScene($0, $1) }
        a.move = { [weak self] in self?.moveScene($0, to: $1) }
        a.updateFromCurrent = { [weak self] in self?.updateSceneFromCurrent($0) }
        a.setCanvas = { [weak self] in self?.setCanvas($0) }
        a.setTransition = { [weak self] in self?.setTransition($0) }
        a.setPunchAmount = { [weak self] in self?.setPunchAmount($0) }
        a.togglePunchIn = { [weak self] in self?.togglePunchIn() }
        a.selectLayer = { [weak self] in self?.selectLayer($0) }
        a.editLayer = { [weak self] id, f in self?.editLayer(id, f) }
        a.moveLayer = { [weak self] in self?.moveLayer($0, to: $1) }
        a.addLayer = { [weak self] in self?.addLayer($0) }
        a.deleteLayer = { [weak self] in self?.deleteLayer($0) }
        a.addImage = { [weak self] url, point in self?.addImageLayer(from: url, at: point) }
        a.replaceImage = { [weak self] in self?.replaceImage($0) }
        a.addPreset = { [weak self] in self?.addPreset($0) }
        a.editText = { [weak self] in self?.editText($0) }
        a.copyLayoutToOtherCanvas = { [weak self] in self?.copyLayoutToOtherCanvas() }
        a.setCrop = { [weak self] in self?.setCrop($0) }
        a.beginGesture = { [weak self] in self?.beginSceneGesture() }
        a.endGesture = { [weak self] in self?.endSceneGesture($0) }
        scenes.actions = a
    }

    /// Everything that follows a change: the renderer, the picture overlay, the facecam placement the Camera menu
    /// shows, the menu, and (debounced) scenes.json.
    func sceneDidChange(save: Bool = true) {
        let m = scenes, rt = sceneRuntime
        m.collection.normalize()
        if rt.live.to.id != m.collection.activeID || rt.live.to != m.active { rt.live.to = m.active }
        if let id = m.selectedLayerID, !m.composition.layers.contains(where: { $0.id == id }) { m.selectedLayerID = nil }
        if let id = m.cropLayerID, id != m.selectedLayerID { m.cropLayerID = nil }
        pushScene()
        view.canvasAspect = m.canvas == .wide ? CGSize(width: 16, height: 9) : CGSize(width: 9, height: 16)
        view.refreshOverlay()
        syncPlacementFromScene()
        populateScenesMenu()
        if save { rt.store.scheduleSave(m.collection) }
    }

    func pushScene() {
        guard let r = renderer else { return }
        if r.gameSnapshot !== sceneRuntime.thumbnailer.snapshot { r.gameSnapshot = sceneRuntime.thumbnailer.snapshot }
        r.cleanGame = WindowPicture.clean(setting: sceneRuntime.cleanGameInFocus, focusMode: state.focusMode)
        if r.overlayContext != sceneRuntime.overlayContext { r.overlayContext = sceneRuntime.overlayContext }
        r.scene = sceneRuntime.live
        r.viewCanvas = scenes.canvas
    }

    /// Pixel sizes of the sources that currently have frames, for resolving layers outside the renderer.
    func liveSources() -> [SourceKey: SourceInfo] {
        var s: [SourceKey: SourceInfo] = [.game: SourceInfo(size: view.gameSize)]
        if camera.cameraOn, let pb = camera.latest { s[.camera] = SourceInfo(size: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))) }
        else { s[.camera] = SourceInfo(size: CGSize(width: 1280, height: 720)) }   // lay out an absent camera as 16:9
        return s
    }

    // MARK: Switching

    @objc func switchSceneFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { switchScene(to: id) } }
    @objc func nextScene() { stepScene(1) }
    @objc func previousScene() { stepScene(-1) }
    func stepScene(_ d: Int) {
        let c = scenes.collection
        guard let i = c.activeIndex, c.scenes.count > 1 else { return }
        switchScene(to: c.scenes[(i + d + c.scenes.count) % c.scenes.count].id)
    }

    func switchScene(to id: UUID) {
        let m = scenes, rt = sceneRuntime
        guard let scene = m.collection[id], id != m.collection.activeID else { return }
        var tr = m.collection.transition
        if DS.Motion.reduceMotion && tr.style != .cut { tr = SceneTransition(style: .fade, durationMs: 150) }
        let t = nowNs()
        rt.live = rt.live.switching(to: scene, atNs: t, transition: tr, sources: switchSources())
        // Keep editing the same source if the new scene has it (the camera stays selected across scenes).
        let kind = m.selectedLayer?.source.type
        m.collection.activeID = id
        m.selectedLayerID = kind.flatMap { k in k == "game" || k == "camera" ? scene.composition(m.canvas).layers.first { $0.source.type == k }?.id : nil }
        m.cropLayerID = nil
        m.transition = TransitionMark(id: id, start: Date(), duration: tr.style == .cut ? 0 : tr.durationMs / 1000)
        logSessionEvent { $0.event("scene", atNs: t, sceneID: id) }
        log("scenes: switched to \(scene.name) (\(tr.style.rawValue), \(String(format: "%.0f", tr.durationMs)) ms)")
        sceneDidChange()
    }

    // MARK: Collection

    func addScene(_ t: SceneTemplate) {
        let m = scenes
        var s = t.scene(placement: livePlacement, mirror: cameraMirror)
        s.name = m.collection.uniqueName(t.name)
        insertScene(s, undo: "Add Scene")
    }
    func duplicateScene(_ id: UUID) {
        let m = scenes
        guard var s = m.collection[id] else { return }
        s.id = UUID(); s.name = m.collection.uniqueName(s.name + " Copy")
        insertScene(s, undo: "Duplicate Scene")
    }
    private func insertScene(_ s: Scene, undo: String) {
        let m = scenes, before = m.collection
        let at = (m.collection.activeIndex ?? m.collection.scenes.count - 1) + 1
        m.collection.scenes.insert(s, at: at)
        registerSceneUndo(undo, before: before)
        sceneDidChange()
        switchScene(to: s.id)
    }
    func deleteScene(_ id: UUID) {
        let m = scenes
        guard m.collection.scenes.count > 1, let i = m.collection.index(of: id) else {
            toast("A collection needs at least one scene", style: .warning); return
        }
        let before = m.collection, name = m.collection.scenes[i].name
        if id == m.collection.activeID { switchScene(to: m.collection.scenes[i == 0 ? 1 : i - 1].id) }
        m.collection.scenes.removeAll { $0.id == id }
        registerSceneUndo("Delete Scene", before: before)
        sceneDidChange()
        toast("Deleted “\(name)”", detail: "Edit › Undo (⌘Z) brings it back.")
    }
    func renameScene(_ id: UUID, _ name: String) {
        let m = scenes, n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        m.renamingSceneID = nil
        guard !n.isEmpty, let i = m.collection.index(of: id), m.collection.scenes[i].name != n else { return }
        let before = m.collection
        m.collection.scenes[i].name = n
        registerSceneUndo("Rename Scene", before: before)
        sceneDidChange()
    }
    func moveScene(_ id: UUID, to index: Int) {
        let m = scenes
        guard let i = m.collection.index(of: id) else { return }
        let to = min(max(index, 0), m.collection.scenes.count - 1)
        guard to != i else { return }
        let s = m.collection.scenes.remove(at: i)
        m.collection.scenes.insert(s, at: to)
        sceneDidChange()
    }
    func updateSceneFromCurrent(_ id: UUID) {
        let m = scenes
        guard let i = m.collection.index(of: id), id != m.collection.activeID else { return }
        let before = m.collection
        m.collection.scenes[i].wide = m.active.wide; m.collection.scenes[i].vertical = m.active.vertical
        registerSceneUndo("Update Scene", before: before)
        sceneDidChange()
        toast("Updated “\(m.collection.scenes[i].name)”", detail: "It now has the layout of “\(m.active.name)”.", style: .success)
    }

    func setTransition(_ t: SceneTransition) {
        var t = t
        t.durationMs = min(max(t.durationMs, SceneTransition.durationRange.lowerBound), SceneTransition.durationRange.upperBound)
        guard t != scenes.collection.transition else { return }
        scenes.collection.transition = t
        sceneDidChange()
    }
    @objc func setTransitionStyle(_ sender: NSMenuItem) {
        guard let s = SceneTransition.Style(rawValue: sender.representedObject as? String ?? "") else { return }
        var t = scenes.collection.transition; t.style = s; setTransition(t)
    }

    func setCanvas(_ c: Canvas) {
        guard scenes.canvas != c else { return }
        scenes.canvas = c
        UserDefaults.standard.set(c.rawValue, forKey: "sceneCanvas")
        scenes.selectedLayerID = nil; scenes.cropLayerID = nil
        log("scenes: showing the \(c.label) canvas")
        sceneDidChange(save: false)
    }
    @objc func showWideCanvas() { setCanvas(.wide) }
    @objc func showVerticalCanvas() { setCanvas(.vertical) }

    // MARK: Editing the active scene

    /// Edits the active scene on the shown canvas; the picture changes at once, without a transition.
    func editComposition(undo: String? = nil, _ edit: (inout Composition) -> Void) {
        let m = scenes
        guard let i = m.collection.activeIndex else { return }
        let before = m.collection
        var s = m.collection.scenes[i]
        if m.canvas == .wide { edit(&s.wide) } else { edit(&s.vertical) }
        guard s != m.collection.scenes[i] else { return }
        m.collection.scenes[i] = s
        if let name = undo, sceneRuntime.gestureStart == nil { registerSceneUndo(name, before: before) }
        sceneDidChange()
    }

    func editLayer(_ id: UUID, _ f: (inout Layer) -> Void) {
        editComposition(undo: "Change Layer") { c in if let j = c.layers.firstIndex(where: { $0.id == id }) { f(&c.layers[j]) } }
    }

    func selectLayer(_ id: UUID?) {
        guard scenes.selectedLayerID != id else { return }
        scenes.selectedLayerID = id
        if scenes.cropLayerID != id { scenes.cropLayerID = nil }
        view.refreshOverlay()
    }

    func moveLayer(_ id: UUID, to index: Int) {
        editComposition(undo: "Reorder Layers") { c in
            guard let i = c.layers.firstIndex(where: { $0.id == id }) else { return }
            let l = c.layers.remove(at: i)
            c.layers.insert(l, at: min(max(index, 0), c.layers.count))
        }
    }

    func addLayer(_ type: String) {
        let size = scenes.canvasSize
        var l: Layer
        switch type {
        case "camera":
            var p = CameraPlacement(); p.shadow = true
            l = Layer(name: "Camera", source: .camera, frame: NRect(p.rect(in: size), in: size), roundness: p.roundness, shadow: true, mirror: cameraMirror)
        case "game":
            // A second game layer starts as a window, so it is visible over the first.
            let has = scenes.composition.layers.contains { $0.source.type == "game" }
            l = Layer(name: "Game", source: .game, frame: has ? NRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5) : .full)
            if has { l.roundness = 0.06; l.shadow = true }
        case "color":
            l = Layer(name: "Backdrop", source: LayerSource(type: "color", color: [0.11, 0.12, 0.16, 1]))
        case "text":
            // Unnamed, so the layer list shows what it says.
            let v = scenes.canvas == .vertical
            l = Layer(source: LayerSource(type: "text", text: TextSpec(string: "Your text", weight: "bold")),
                      frame: v ? NRect(x: 0.1, y: 0.45, w: 0.8, h: 0.06) : NRect(x: 0.25, y: 0.43, w: 0.5, h: 0.12))
        default: return
        }
        let id = l.id
        editComposition(undo: "Add Layer") { c in if type == "color" { c.layers.insert(l, at: 0) } else { c.layers.append(l) } }
        selectLayer(id)
        if type == "text" { editText(id) }
    }

    /// Game and camera are hidden rather than deleted: scenes keep their place in the stack.
    func deleteLayer(_ id: UUID) {
        guard let l = scenes.composition.layers.first(where: { $0.id == id }) else { return }
        if l.isGameOrCamera { editComposition(undo: "Hide Layer") { c in if let j = c.layers.firstIndex(where: { $0.id == id }) { c.layers[j].visible = false } }; return }
        editComposition(undo: "Delete Layer") { c in c.layers.removeAll { $0.id == id } }
    }

    func copyLayoutToOtherCanvas() {
        let m = scenes, from = m.canvas, to: Canvas = from == .wide ? .vertical : .wide
        guard let i = m.collection.activeIndex else { return }
        let before = m.collection
        let converted = m.active.composition(from).converted(from: from.size(.hd), to: to.size(.hd))
        if to == .wide { m.collection.scenes[i].wide = converted } else { m.collection.scenes[i].vertical = converted }
        registerSceneUndo("Copy Layout", before: before)
        sceneDidChange()
        toast("Copied the \(from.label) layout to \(to.label)", detail: "Switch the canvas to \(to.label) to fine-tune it.", style: .success)
    }

    func setCrop(_ id: UUID?) {
        guard scenes.cropLayerID != id else { return }
        scenes.cropLayerID = id
        if let id = id {
            scenes.selectedLayerID = id
            toast("Crop mode", detail: "Drag to move the picture inside its frame, scroll to zoom. Esc or double-click to finish.")
        }
        view.refreshOverlay()
    }

    // MARK: Undo

    func beginSceneGesture() { if sceneRuntime.gestureStart == nil { sceneRuntime.gestureStart = scenes.collection } }
    func endSceneGesture(_ name: String) {
        guard let before = sceneRuntime.gestureStart else { return }
        sceneRuntime.gestureStart = nil
        if before != scenes.collection { registerSceneUndo(name, before: before) }
    }

    /// Undo restores the scenes as they were, but never switches the live scene: that is a live action, not an edit.
    func registerSceneUndo(_ name: String, before: SceneCollection) {
        guard let um = window.undoManager else { return }
        let after = scenes.collection
        um.registerUndo(withTarget: self) { d in
            d.restoreScenes(before)
            d.registerSceneUndo(name, before: after)
        }
        um.setActionName(name)
    }
    private func restoreScenes(_ c: SceneCollection) {
        let m = scenes, active = m.collection.activeID
        m.collection.scenes = c.scenes; m.collection.transition = c.transition
        if m.collection.index(of: active) == nil, let first = m.collection.scenes.first { switchScene(to: first.id) }
        sceneDidChange()
    }

    // MARK: Camera menu bridge

    /// The Camera menu and the sidebar's camera controls edit the active scene's camera layer on the shown canvas,
    /// through the same `CameraPlacement` they always used.
    func applyCameraPlacement(_ p: CameraPlacement) {
        let size = scenes.canvasSize
        guard scenes.composition.layers.contains(where: { $0.source.type == "camera" }) else {
            toast("“\(scenes.active.name)” has no camera", detail: "Add a camera layer in the sidebar's Scene tab.", style: .warning)
            return
        }
        editComposition(undo: "Change Camera") { c in
            guard let j = c.layers.lastIndex(where: { $0.source.type == "camera" }) else { return }
            c.layers[j].frame = NRect(p.rect(in: size), in: size)
            c.layers[j].roundness = p.roundness; c.layers[j].border = p.border; c.layers[j].shadow = p.shadow
            c.layers[j].visible = true
        }
    }

    /// Mirroring belongs to the camera, not to a layout: every camera layer in every scene follows it.
    func applyCameraMirror(_ on: Bool) {
        let m = scenes
        for i in m.collection.scenes.indices {
            for c in Canvas.allCases {
                var comp = m.collection.scenes[i].composition(c)
                for j in comp.layers.indices where comp.layers[j].source.type == "camera" { comp.layers[j].mirror = on }
                if c == .wide { m.collection.scenes[i].wide = comp } else { m.collection.scenes[i].vertical = comp }
            }
        }
        sceneDidChange()
    }

    /// `livePlacement` (what the Camera menu and the camera controls show) follows the active camera layer.
    func syncPlacementFromScene() {
        let size = scenes.canvasSize
        guard let k = scenes.composition.layers.last(where: { $0.source.type == "camera" }) else { return }
        let p = CameraPlacement(frame: k.frame, canvas: size, roundness: k.roundness, border: k.border, shadow: k.shadow)
        if p != livePlacement { livePlacement = p }
    }

    // MARK: Punch-in

    @objc func togglePunchIn() { setPunchIn(!scenes.punchedIn) }

    func setPunchIn(_ on: Bool) {
        let m = scenes, rt = sceneRuntime, t = nowNs()
        var p = rt.live.punchIn ?? PunchIn()
        guard p.engaged != on else { return }
        p.amount = m.punchAmount; p.durationMs = DS.Motion.reduceMotion ? 150 : 380
        p.set(engaged: on, atNs: t)
        rt.live.punchIn = p
        m.punchedIn = on
        pushScene()
        populateScenesMenu()
        let focus = gameCropCentre()
        logSessionEvent { on ? $0.event("zoomIn", atNs: t, zoom: p.amount, focus: focus) : $0.event("zoomOut", atNs: t) }
        log(on ? String(format: "scenes: punch-in %.1f×", p.amount) : "scenes: punch-in released")
    }

    func setPunchAmount(_ v: Double) {
        let v = min(max(v, PunchIn.range.lowerBound), PunchIn.range.upperBound)
        scenes.punchAmount = v
        UserDefaults.standard.set(v, forKey: "punchInZoom")
        if var p = sceneRuntime.live.punchIn, p.engaged {
            // Re-aim from the current scale so the change glides.
            let t = nowNs(); p.fromScale = p.scale(atNs: t); p.startNs = t; p.amount = v
            sceneRuntime.live.punchIn = p; pushScene()
        }
    }

    /// Arrow keys while zoomed in: move the focus by a tenth of the source.
    func movePunchFocus(dx: CGFloat, dy: CGFloat) {
        guard var p = sceneRuntime.live.punchIn, p.engaged else { return }
        let t = nowNs(), c = gameCropCentre() ?? CGPoint(x: 0.5, y: 0.5)
        let from = p.focusPoint(atNs: t, centre: c)
        p.moveFocus(to: CGPoint(x: from.x + dx, y: from.y + dy), atNs: t, centre: c)
        sceneRuntime.live.punchIn = p
        pushScene()
    }

    /// Centre of the game layer's crop in the active scene, normalized to the source.
    func gameCropCentre() -> CGPoint? {
        let r = SceneResolver.resolve(scenes.composition, canvas: scenes.canvasSize, sources: liveSources())
        return r.first { $0.key == .game }.map { CGPoint(x: $0.src.midX, y: $0.src.midY) }
    }

    @objc func addMarker() {
        let t = nowNs()
        guard recorder != nil else { toast("Markers are saved while recording", detail: "Start a recording, then press ⌃M at a moment you want to find later."); return }
        logSessionEvent { $0.event("marker", atNs: t) }
        let ms = sceneRuntime.eventLog?.tMs(atNs: t) ?? 0
        toast("Marker added", detail: "At \(StudioFormat.elapsed(ms / 1000)) in this recording.", style: .success)
    }

    // MARK: Keys

    /// ⌃⇧Space zooms in while held (menus cannot see key-up); arrow keys move the zoom's focus while zoomed in.
    func installSceneKeys() {
        guard sceneRuntime.keyMonitor == nil else { return }
        sceneRuntime.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in self?.handleSceneKey(e) ?? e }
    }

    private func handleSceneKey(_ e: NSEvent) -> NSEvent? {
        let rt = sceneRuntime
        let a = SceneKeys.action(keyCode: e.keyCode, keyDown: e.type == .keyDown, isRepeat: e.type == .keyDown && e.isARepeat,
                                 mods: e.modifierFlags, textFocused: SceneKeys.textFocused(NSApp.keyWindow?.firstResponder),
                                 punchedIn: scenes.punchedIn, spaceHeld: rt.spaceHeld)
        switch a {
        case nil: return e
        case .consume: return nil
        case .punchIn(let on): rt.spaceHeld = on; setPunchIn(on); return nil
        case .moveFocus(let dx, let dy): movePunchFocus(dx: dx, dy: dy); return nil
        }
    }

    /// ⌃Z and ⌃⇧← / ⌃⇧→ stay with a text field that has keyboard focus. Every other item behaves as without this.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let a = item.action, [#selector(togglePunchIn), #selector(nextScene), #selector(previousScene)].contains(a) else { return true }
        return !SceneKeys.textFocused(NSApp.keyWindow?.firstResponder)
    }

    // MARK: Clean game picture

    /// For the View menu: in focus mode the window shows the whole game alone, in its own aspect.
    func makeCleanGameItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Show Clean Game Picture in Focus Mode", action: #selector(toggleCleanGameView), keyEquivalent: "")
        it.target = self; it.state = sceneRuntime.cleanGameInFocus ? .on : .off
        it.toolTip = "In focus mode, show the whole game in its own aspect, without the camera, overlays, crop or zoom. The stream and recordings still show the scene."
        sceneRuntime.cleanGameItem = it
        return it
    }
    @objc func toggleCleanGameView() {
        let rt = sceneRuntime
        rt.cleanGameInFocus.toggle()
        UserDefaults.standard.set(rt.cleanGameInFocus, forKey: WindowPicture.defaultsKey)
        rt.cleanGameItem?.state = rt.cleanGameInFocus ? .on : .off
        pushScene()
        log("view: clean game picture in focus mode \(rt.cleanGameInFocus ? "on" : "off")")
    }

    // MARK: Menu

    func addScenesMenu(to main: NSMenu) {
        let item = NSMenuItem()
        item.submenu = sceneRuntime.menu
        main.addItem(item)
        populateScenesMenu()
    }

    /// Kept current on every change rather than on open, so ⌃1…⌃9 always match the strip. Items are rebuilt only
    /// when scenes are added, removed, renamed or reordered; otherwise check marks and titles change in place.
    func populateScenesMenu() {
        let m = sceneRuntime.menu, c = scenes.collection
        let structure = c.scenes.map { "\($0.id)\t\($0.name)" }.joined(separator: "\n")
        if structure != sceneRuntime.menuStructure || m.numberOfItems == 0 {
            sceneRuntime.menuStructure = structure
            m.removeAllItems()
            func add(_ title: String, _ sel: Selector?, _ key: String = "", tag: Int = 0, obj: Any? = nil) -> NSMenuItem {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
                it.keyEquivalentModifierMask = [.control]; it.target = sel == nil ? nil : self
                it.tag = tag; it.representedObject = obj
                m.addItem(it); return it
            }
            for (i, s) in c.scenes.enumerated() { _ = add(s.name, #selector(switchSceneFromMenu(_:)), i < 9 ? "\(i + 1)" : "", obj: s.id) }
            m.addItem(.separator())
            // ⌃← / ⌃→ alone belong to Mission Control.
            add("Next Scene", #selector(nextScene), String(UnicodeScalar(NSRightArrowFunctionKey)!)).keyEquivalentModifierMask = SceneKeys.stepModifiers
            add("Previous Scene", #selector(previousScene), String(UnicodeScalar(NSLeftArrowFunctionKey)!)).keyEquivalentModifierMask = SceneKeys.stepModifiers
            m.addItem(.separator())
            let tm = NSMenu(title: "Transition")
            for st in SceneTransition.Style.allCases {
                let it = NSMenuItem(title: st.label, action: #selector(setTransitionStyle(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = st.rawValue
                tm.addItem(it)
            }
            add("Transition", nil).submenu = tm
            m.addItem(.separator())
            _ = add("Zoom In on Game", #selector(togglePunchIn), "z", tag: 1)
            add("Hold \(SceneKeys.holdLabel) to zoom while held", nil).isEnabled = false
            _ = add("Add Marker", #selector(addMarker), "m")
            m.addItem(.separator())
            _ = add("16:9 Canvas", #selector(showWideCanvas), tag: 2)
            _ = add("9:16 Canvas", #selector(showVerticalCanvas), tag: 3)
        }
        for it in m.items {
            if let id = it.representedObject as? UUID { it.state = id == c.activeID ? .on : .off }
            switch it.tag {
            case 1: it.title = scenes.punchedIn ? "Zoom Out" : "Zoom In on Game"; it.state = scenes.punchedIn ? .on : .off
            case 2: it.state = scenes.canvas == .wide ? .on : .off
            case 3: it.state = scenes.canvas == .vertical ? .on : .off
            default: break
            }
            for t in it.submenu?.items ?? [] { t.state = (t.representedObject as? String) == c.transition.style.rawValue ? .on : .off }
        }
    }

    /// Right-click on the picture: the layer under the pointer, or the scene list.
    func pictureMenu(layer id: UUID?) -> NSMenu? {
        guard let id = id, let l = scenes.composition.layers.first(where: { $0.id == id }) else {
            let m = NSMenu(title: "Scenes")
            for (i, s) in scenes.collection.scenes.enumerated() {
                let it = NSMenuItem(title: s.name, action: #selector(switchSceneFromMenu(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
                it.keyEquivalentModifierMask = [.control]; it.target = self; it.representedObject = s.id
                it.state = s.id == scenes.collection.activeID ? .on : .off
                m.addItem(it)
            }
            return m
        }
        let m = NSMenu(title: l.displayName)
        func add(_ title: String, _ f: @escaping () -> Void) { m.addItem(ClosureMenuItem(title: title, action: f)) }
        if l.isGameOrCamera { add("Crop…") { [weak self] in self?.setCrop(id) } }
        add(l.fit ? "Fill Frame" : "Fit Inside Frame") { [weak self] in self?.editLayer(id) { $0.fit.toggle() } }
        m.addItem(.separator())
        add("Bring to Front") { [weak self] in self?.moveLayer(id, to: Int.max) }
        add("Send to Back") { [weak self] in self?.moveLayer(id, to: 0) }
        m.addItem(.separator())
        add(l.isGameOrCamera ? "Hide" : "Delete") { [weak self] in self?.deleteLayer(id) }
        if l.source.type == "camera" {
            m.addItem(.separator())
            let it = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
            it.submenu = makeCameraMenu(title: "Camera")
            m.addItem(it)
        }
        return m
    }

    // MARK: Event log (recording)

    /// At the start of a recording: the whole collection, the active scene at 0, and the fixed layouts the current
    /// editor reads, taken from that scene.
    func beginSceneLog(_ proj: inout Project, startNs: UInt64) {
        let m = scenes, el = SessionEventLog(startNs: startNs)
        proj.scenes = m.collection.scenes
        proj.events = [el.event("scene", atNs: startNs, sceneID: m.collection.activeID)]
        if m.punchedIn { proj.events.append(el.event("zoomIn", atNs: startNs, zoom: m.punchAmount, focus: gameCropCentre())) }
        proj.wide = CanvasLayout(approximating: m.active.wide, canvas: Canvas.wide.size(.hd), fallback: .wideDefault)
        proj.vertical = CanvasLayout(approximating: m.active.vertical, canvas: Canvas.vertical.size(.hd), fallback: .verticalDefault)
        sceneRuntime.eventLog = el
    }

    /// Appends an event while recording; project.json is rewritten at most every 5 s (and at stop).
    func logSessionEvent(_ make: (SessionEventLog) -> SessionEvent) {
        let rt = sceneRuntime
        guard let doc = recDoc, var l = rt.eventLog else { return }
        let e = make(l)
        // A scene added after the start is stored when it is first switched to, so every event's scene exists.
        if let id = e.sceneID, !doc.project.scenes.contains(where: { $0.id == id }), let sc = scenes.collection[id] {
            doc.project.scenes.append(sc)
            bundleOverlayAssets([sc], into: doc.dir)
        }
        doc.project.events.append(e)
        log("event: \(e.type) at \(String(format: "%.1f", e.tMs)) ms")
        let now = nowNs(), wait = l.saveDelay(atNs: now)
        if wait == 0 {
            rt.pendingProjectSave?.cancel(); rt.pendingProjectSave = nil
            doc.save(); l.didSave(atNs: now); rt.eventLog = l
            log("events: project.json saved with \(doc.project.events.count) events")
        } else if rt.pendingProjectSave == nil {
            let work = DispatchWorkItem { [weak self, weak doc] in
                guard let self = self, let doc = doc, self.recDoc === doc, var l = self.sceneRuntime.eventLog else { return }
                self.sceneRuntime.pendingProjectSave = nil
                doc.save(); l.didSave(atNs: nowNs()); self.sceneRuntime.eventLog = l
                log("events: project.json saved with \(doc.project.events.count) events")
            }
            rt.pendingProjectSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(wait)), execute: work)
        }
    }

    /// At stop: finalize writes the project with every event, so a pending throttled save is dropped.
    func endSceneLog() {
        sceneRuntime.pendingProjectSave?.cancel(); sceneRuntime.pendingProjectSave = nil
        sceneRuntime.eventLog = nil
    }

    // MARK: Torture test

    /// `--scene-torture`: 20 switches in 10 seconds, cycling through the scenes, once the picture is live. Compare the
    /// pacing lines (drops, slips) and the latency line with a run without it.
    func scheduleSceneTorture() {
        guard CommandLine.arguments.contains("--scene-torture") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self else { return }
            log("scene-torture: start, 20 switches in 10 s")
            for i in 0..<20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self] in
                    self?.nextScene()
                    if i == 19 { log("scene-torture: done") }
                }
            }
        }
    }

    /// `--scene-script "6:next,11:scene=Gameplay,14:punch"`: live actions at fixed seconds after launch, for checking
    /// what the stream and recordings show. Actions: `next`, `prev`, `scene=<name or 1-based index>`, `punch` (toggle
    /// the live zoom), `marker`, `canvas=wide|vertical`. Each logs its host time, to match against the stream's
    /// "stream time 0" line.
    func scheduleSceneScript() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scene-script"), i + 1 < args.count else { return }
        for step in args[i + 1].split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let at = Double(parts[0]), at >= 0 else { log("scene-script: ignored \(step)"); continue }
            let action = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self = self else { return }
                log("scene-script: \(action) at host \(nowNs()) ns")
                let c = self.scenes.collection
                switch action {
                case "next": self.nextScene()
                case "prev": self.previousScene()
                case "punch": self.togglePunchIn()
                case "marker": self.addMarker()
                case "canvas=wide": self.setCanvas(.wide)
                case "canvas=vertical": self.setCanvas(.vertical)
                default:
                    guard action.hasPrefix("scene=") else { log("scene-script: unknown action \(action)"); return }
                    let name = String(action.dropFirst(6))
                    let target = c.scenes.first { $0.name == name } ?? Int(name).flatMap { n in c.scenes.indices.contains(n - 1) ? c.scenes[n - 1] : nil }
                    if let t = target { self.switchScene(to: t.id) } else { log("scene-script: no scene \(name)") }
                }
            }
        }
    }

    // MARK: Thumbnails

    /// Twice a second, off the reader thread: each scene rendered small through the same compositor.
    func startThumbnails() {
        guard sceneRuntime.thumbnailTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.renderThumbnails() }
        RunLoop.main.add(t, forMode: .common)
        sceneRuntime.thumbnailTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.renderThumbnails() }
    }

    func renderThumbnails() {
        let m = scenes
        guard !state.focusMode, window?.isMiniaturized != true else { return }
        var list = m.collection.scenes
        if m.galleryOpen { list += m.templates.map(\.scene) }
        let canvas = m.canvas
        sceneRuntime.thumbnailer.render(scenes: list, canvas: canvas, hasGame: renderer?.latestGameFrame != nil,
                                        camera: camera.cameraOn ? camera.latest : nil, context: sceneRuntime.overlayContext) { [weak self] images in
            guard let self = self else { return }
            let th = self.scenes.thumbnails
            if th.canvas != canvas { th.canvas = canvas }
            th.images = images
        }
    }
}
