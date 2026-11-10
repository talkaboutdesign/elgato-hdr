import AppKit
import Foundation

/// The live scene collection as the editor sees it: read by "Add from Live Scenes", added to by "Save as Live Scene".
/// The app connects it to its scenes at launch; tests replace it.
struct LiveSceneLibrary {
    var scenes: () -> [Scene] = { [] }
    /// Adds a scene to the live collection without switching to it.
    var add: (Scene) -> Void = { _ in }
    /// Where live scenes' images live.
    var assets: URL = AssetStore.appSupportAssets
    static var shared = LiveSceneLibrary()
}

// Editing any layer of the scene at the playhead, with the same picture interaction (`LayerInteraction`) and the same
// layer list and inspector as the live Scene tab. Edits change the project's copy of the scene, never the live one,
// and go through `update`, so each is an undo step (a drag, scroll or nudge burst is one).
extension EditorModel: LayerEditing {
    var editedComposition: Composition { activeScene?.composition(canvas) ?? Composition() }
    var editedCanvas: Canvas { canvas }
    var editedSceneName: String { activeScene?.name ?? "Scene" }
    var editedSceneID: UUID? { activeScene?.id }
    /// The selected layer, while the scene at the playhead has it on this canvas.
    var selectedLayerID: UUID? {
        guard case .layer(let id) = selection, editedComposition.layers.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    var layerActions: SceneActions { sceneLayerActions }
    var assetSearchPaths: [URL] { AssetStore.searchPaths(project: doc.dir) }
    /// The game (always recorded) and the camera (when recorded) while the scene on this canvas lacks them: a scene
    /// converted from a single-source layout has no other way to show the missing one.
    var tokenHelp: String { LayerTokenHelp.editor }
    var addableSources: [String] {
        let types = Set(editedComposition.layers.map(\.source.type))
        return (types.contains("game") ? [] : ["game"]) + (hasCamera && !types.contains("camera") ? ["camera"] : [])
    }
    var projectAssets: URL { doc.dir.appendingPathComponent("Assets", isDirectory: true) }

    /// The actions the shared views and the picture call; scene-collection actions do not apply to a recording.
    func makeLayerActions() -> SceneActions {
        var a = SceneActions()
        a.selectLayer = { [weak self] in self?.selectLayer($0) }
        a.editLayer = { [weak self] id, f in self?.editLayer(id, f) }
        a.moveLayer = { [weak self] id, i in self?.editComposition("Reorder Layers") { $0.move(id, to: i) } }
        a.addLayer = { [weak self] in self?.addLayer($0) }
        a.deleteLayer = { [weak self] in self?.deleteLayer($0) }
        a.addImage = { [weak self] url, point in self?.addImageLayer(from: url, at: point) }
        a.replaceImage = { [weak self] in self?.replaceImage($0) }
        a.addPreset = { [weak self] in self?.addPreset($0) }
        a.editText = { [weak self] in self?.editText($0) }
        a.copyLayoutToOtherCanvas = { [weak self] in self?.copyLayoutToOtherCanvas() }
        a.setCrop = { [weak self] in self?.setCrop($0) }
        // Playback would move the playhead into another scene while the layer is held: a manipulation pauses it.
        a.beginGesture = { [weak self] in self?.pauseForLayerEdit(); self?.beginGesture() }
        a.endGesture = { [weak self] in self?.endGesture(named: $0) }
        return a
    }

    // MARK: Editing the scene at the playhead

    func pauseForLayerEdit() {
        if playing || player.rate != 0 || reverseTimer != nil { pause() }
    }

    /// Edits the scene at the playhead on the shown canvas. A scene migrated from a fixed layout becomes a scene of
    /// layers at its first layer edit (its layout controls give way to the layer list). False when nothing changed.
    @discardableResult
    func editComposition(_ name: String, _ f: (inout Composition) -> Void) -> Bool {
        guard let i = activeSceneIndex else { return false }
        let c = canvas
        var changed = false
        update(name) { p in
            guard i < p.scenes.count else { return }
            var comp = p.scenes[i].composition(c)
            let before = comp
            f(&comp)
            guard comp != before else { return }
            comp.legacyLayout = nil
            if c == .wide { p.scenes[i].wide = comp } else { p.scenes[i].vertical = comp }
            changed = true
        }
        return changed
    }

    func editLayer(_ id: UUID, _ f: (inout Layer) -> Void) {
        editComposition("Change Layer") { c in if let j = c.layers.firstIndex(where: { $0.id == id }) { f(&c.layers[j]) } }
    }

    func selectLayer(_ id: UUID?) {
        if cropLayerID != nil && cropLayerID != id { cropLayerID = nil }
        let next: TimelineSelection = id.map { .layer($0) } ?? .none
        if selection != next { selection = next }
    }

    func addLayer(_ type: String) {
        let made = type == "game" || type == "camera" ? Layer.recordedSource(type, canvas: canvas, mirror: project.cameraMirror)
                                                      : Layer.added(type, canvas: canvas, to: editedComposition, mirror: project.cameraMirror)
        guard let l = made,
              editComposition("Add Layer", { $0.add(l) }) else { NSSound.beep(); return }
        selectLayer(l.id)
        if type == "text" { editText(l.id) }
    }

    /// Game and camera are hidden rather than deleted, as live.
    func deleteLayer(_ id: UUID) {
        guard let l = editedComposition.layers.first(where: { $0.id == id }) else { return }
        editComposition(l.isGameOrCamera ? "Hide Layer" : "Delete Layer") { $0.delete(id) }
        if !l.isGameOrCamera { selectLayer(nil) }
    }

    func addPreset(_ p: LayerPreset) {
        let size = canvas.size(.hd)
        var result: Result<UUID, LayerPreset.PresetError>?
        editComposition("Add \(p.name)") { result = p.apply(to: &$0, canvas: size) }
        switch result {
        case .success(let id)?: selectLayer(id); if p == .nameTag { editText(id) }
        case .failure?: showToast(EditorToast(text: "“\(editedSceneName)” has no camera", detail: "Add the frame to a scene that shows the camera.", style: .warning))
        case nil: break
        }
    }

    func editText(_ id: UUID) { selectLayer(id); focusTextLayerID = id }

    func setCrop(_ id: UUID?) {
        guard cropLayerID != id else { return }
        if let id = id { selectLayer(id) }
        cropLayerID = id
        if id != nil { showToast(EditorToast(text: "Crop mode", detail: "Drag to move the picture inside its frame, scroll to zoom. Esc or double-click to finish.")) }
    }

    func copyLayoutToOtherCanvas() {
        guard let i = activeSceneIndex else { return }
        let from = canvas, to: Canvas = from == .wide ? .vertical : .wide
        let converted = project.scenes[i].composition(from).converted(from: from.size(.hd), to: to.size(.hd))
        update("Copy Layout") { p in
            guard i < p.scenes.count else { return }
            var c = converted; c.legacyLayout = nil
            if to == .wide { p.scenes[i].wide = c } else { p.scenes[i].vertical = c }
        }
        showToast(EditorToast(text: "Copied the \(from.label) layout to \(to.label)", detail: "Switch the canvas to \(to.label) to fine-tune it.", style: .success))
    }

    // MARK: Images

    /// Imports `url` (or a file the user picks) into the project's own `Assets/` and adds it to the scene at the
    /// playhead, centred at `point` (canvas pixels) or in the middle.
    func addImageLayer(from url: URL?, at point: CGPoint?) {
        let target = activeScene?.id, c = canvas
        let place = { [weak self] (chosen: URL) -> Void in
            self?.importImage(chosen) { name, native in
                guard let self = self, self.activeScene?.id == target, self.canvas == c else { NSSound.beep(); return }
                let l = Layer(name: chosen.deletingPathExtension().lastPathComponent, source: LayerSource(type: "image", file: name),
                              frame: Layer.imageFrame(native: native, canvas: c.size(.hd), at: point))
                guard self.editComposition("Add Image", { $0.layers.append(l) }) else { return }
                self.selectLayer(l.id)
                log("editor: added image \(name) to \(self.editedSceneName) (\(c.label))")
            }
        }
        if let url = url { place(url) } else { chooseImage(prompt: "Add", place) }
    }

    func replaceImage(_ id: UUID) {
        let size = canvas.size(.hd)
        chooseImage(prompt: "Replace") { [weak self] chosen in
            self?.importImage(chosen) { name, native in
                self?.editComposition("Replace Image") { c in
                    guard let i = c.layers.firstIndex(where: { $0.id == id }) else { return }
                    c.layers[i] = c.layers[i].replacingImage(name, native: native, canvas: size)
                }
            }
        }
    }

    private func chooseImage(prompt: String, _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AssetStore.supportedTypes
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = prompt; panel.message = "Choose a PNG, JPEG, HEIC, TIFF or GIF (its first frame)."
        let finish = { (r: NSApplication.ModalResponse) in if r == .OK, let url = panel.url { done(url) } }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Copies the file into the project's `Assets/` off the main thread, then hands back its asset name and size.
    private func importImage(_ url: URL, _ done: @escaping (String, CGSize) -> Void) {
        let dir = projectAssets
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AssetStore.importImage(url, into: dir) }
            let size = OverlayImage.size(of: url)
            DispatchQueue.main.async {
                switch (result, size) {
                case (.success(let name), let s?) where s.width > 0 && s.height > 0: done(name, s)
                default:
                    self?.showToast(EditorToast(text: "Can’t use “\(url.lastPathComponent)”", detail: "Images can be PNG, JPEG, HEIC, TIFF or GIF.", style: .warning))
                }
            }
        }
    }

    // MARK: Live scenes

    /// Copies the scene at the playhead (or `id`) into the live collection, with its images. Never replaces a live
    /// scene: a name or id already there gets a new one.
    func saveSceneToLive(_ id: UUID? = nil) {
        guard var scene = id.flatMap({ id in project.scenes.first { $0.id == id } }) ?? activeScene else { return }
        let lib = LiveSceneLibrary.shared, live = lib.scenes()
        if live.contains(where: { $0.id == scene.id }) { scene.id = UUID() }
        let names = Set(live.map(\.name))
        if names.contains(scene.name) {
            var n = 2
            while names.contains("\(scene.name) \(n)") { n += 1 }
            scene.name = "\(scene.name) \(n)"
        }
        for c in Canvas.allCases { var comp = scene.composition(c); comp.legacyLayout = nil; if c == .wide { scene.wide = comp } else { scene.vertical = comp } }
        let files = AssetStore.referencedFiles([scene]), paths = assetSearchPaths, saved = scene
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let missing = AssetStore.bundle(files, into: lib.assets, from: paths)
            DispatchQueue.main.async {
                lib.add(saved)
                log("editor: saved scene \(saved.name) to the live scenes (\(files.count - missing.count) of \(files.count) image(s))")
                self?.showToast(EditorToast(text: "Saved “\(saved.name)” to your live scenes",
                                            detail: missing.isEmpty ? "It is in the scene strip now." : "\(missing.count) image(s) could not be found and stay blank.",
                                            style: missing.isEmpty ? .success : .warning))
            }
        }
    }

    /// Live scenes this project does not have yet (by id), for "Add from Live Scenes".
    var liveScenesToAdd: [Scene] {
        LiveSceneLibrary.shared.scenes().filter { s in !project.scenes.contains { $0.id == s.id } }
    }

    /// Copies a live scene into the project (its images into the project's `Assets/`) and shows it: from the playhead
    /// on, or for the selected scene span.
    func addLiveScene(_ scene: Scene, for run: SceneRun? = nil) {
        let files = AssetStore.referencedFiles([scene]), dir = projectAssets, from = [LiveSceneLibrary.shared.assets]
        DispatchQueue.global(qos: .utility).async { AssetStore.bundle(files, into: dir, from: from) }
        let t = playheadMs
        var spanID: UUID?
        update("Add \(scene.name)") { p in
            if !p.scenes.contains(where: { $0.id == scene.id }) { p.scenes.append(scene) }
            if let run = run {
                TimelineEdits.setScene(&p, run: run, sceneID: scene.id)
                spanID = run.span?.id ?? TimelineEdits.sortedSpans(p).first?.id
            } else {
                spanID = TimelineEdits.insertSceneChange(&p, sceneID: scene.id, atMs: t)
            }
        }
        if let id = spanID { selection = .scene(id) }
        log("editor: added live scene \(scene.name) to \(project.name)")
    }

    // MARK: Picture

    /// Sources as the preview draws the playhead's frame: the game, the camera where the recording has one, and the
    /// sizes of the scene's overlays, so the picture's handles sit where its layers are.
    func stageSources() -> [SourceKey: SourceInfo] {
        var s: [SourceKey: SourceInfo] = [.game: SourceInfo(size: gameSize)]
        if let cam = cameraSize { if cameraShown(atMs: playheadMs) { s[.camera] = SourceInfo(size: cam) } }
        else if hasCamera { s[.camera] = SourceInfo(size: CGSize(width: 1280, height: 720)) }   // until the layers have loaded
        let overlays = editedComposition.layers.filter(\.isOverlay)
        if !overlays.isEmpty { s.merge(OverlayTextureCache.shared.sourceSizes(for: overlays, canvas: canvas.size(.hd), assets: assetSearchPaths)) { own, _ in own } }
        return s
    }

    /// Right-click on a layer in the preview.
    func layerMenu(_ id: UUID?) -> NSMenu? {
        guard let id = id, let l = editedComposition.layers.first(where: { $0.id == id }) else { return nil }
        let m = NSMenu(title: l.displayName)
        func add(_ title: String, _ f: @escaping () -> Void) { m.addItem(ClosureMenuItem(title: title, action: f)) }
        if l.isGameOrCamera { add("Crop…") { [weak self] in self?.setCrop(id) } }
        if l.source.type != "text" && l.source.type != "color" { add(l.fit ? "Fill Frame" : "Fit Inside Frame") { [weak self] in self?.editLayer(id) { $0.fit.toggle() } } }
        if l.source.type == "text" { add("Edit Text") { [weak self] in self?.editText(id) } }
        m.addItem(.separator())
        add("Bring to Front") { [weak self] in self?.editComposition("Reorder Layers") { $0.move(id, to: Int.max) } }
        add("Send to Back") { [weak self] in self?.editComposition("Reorder Layers") { $0.move(id, to: 0) } }
        m.addItem(.separator())
        add(l.isGameOrCamera ? "Hide" : "Delete") { [weak self] in self?.deleteLayer(id) }
        m.addItem(.separator())
        add("Save Scene as Live Scene") { [weak self] in self?.saveSceneToLive() }
        return m
    }

    /// The window showing this editor (its own or the library's).
    var window: NSWindow? {
        if let w = EditorWindows.shared.window(for: self) { return w }
        if LibraryNavigation.shared.editor === self { return LibraryNavigation.shared.window }
        return nil
    }
}
