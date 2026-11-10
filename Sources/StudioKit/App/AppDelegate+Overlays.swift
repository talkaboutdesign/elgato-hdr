// Image and text layers on the app side: the `{timer}` clock the renderers read, asset bundling into recordings, and
// the source sizes overlays need when a switch freezes the picture.
import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    /// `{timer}` counts from the stream's start while live, otherwise from the recording's first frame, otherwise
    /// shows 0:00. Follows the stream and recording state.
    func startOverlayClock() {
        let streaming = state.streaming, studio = state
        trackChanges({ (streaming.liveSince, studio.recording) }) { [weak self] _ in self?.updateOverlayClock() }
    }

    func updateOverlayClock() {
        var c = sceneRuntime.overlayContext
        if let since = state.streaming.liveSince {
            let ago = UInt64(max(0, Date().timeIntervalSince(since)) * 1e9), now = nowNs()
            c.timerStartNs = now > ago ? now - ago : now
        } else if let log = sceneRuntime.eventLog {
            c.timerStartNs = log.startNs
        } else { c.timerStartNs = nil }
        guard c != sceneRuntime.overlayContext else { return }
        sceneRuntime.overlayContext = c
        pushScene()
        log("overlays: {timer} \(state.streaming.liveSince != nil ? "counts stream time" : sceneRuntime.eventLog != nil ? "counts recording time" : "shows 0:00")")
    }

    /// Sources for freezing the picture at a switch: the live frames plus the overlays of the shown scenes, so an
    /// image or text layer stays in a transition that is interrupted.
    func switchSources() -> [SourceKey: SourceInfo] {
        var s = liveSources()
        let assets = sceneRuntime.overlayContext.assets
        for canvas in Canvas.allCases {
            let layers = sceneRuntime.live.overlayLayers(canvas: canvas, atNs: nowNs())
            guard !layers.isEmpty else { continue }
            s.merge(OverlayTextureCache.shared.sourceSizes(for: layers, canvas: canvas.size(.hd), assets: assets)) { own, _ in own }
        }
        return s
    }

    /// A recording stays self-contained: the images its scenes use are hard-linked (or copied) into its `Assets/`
    /// folder. Off the main thread; a copy across volumes can take a moment.
    func bundleOverlayAssets(_ scenes: [Scene], into dir: URL) {
        let names = AssetStore.referencedFiles(scenes)
        guard !names.isEmpty else { return }
        let assets = dir.appendingPathComponent("Assets", isDirectory: true), paths = sceneRuntime.overlayContext.assets
        DispatchQueue.global(qos: .utility).async {
            let missing = AssetStore.bundle(names, into: assets, from: paths)
            log("overlays: bundled \(names.count - missing.count) of \(names.count) image(s) into \(dir.lastPathComponent)/Assets" + (missing.isEmpty ? "" : ", missing \(missing.sorted())"))
        }
    }

    // MARK: Adding and editing overlay layers

    /// Imports `url` (or a file the user picks) into the asset folder and adds it to the scene being edited, centred
    /// at `point` (canvas pixels) or in the middle, at most 40% of the canvas and never larger than the image.
    func addImageLayer(from url: URL?, at point: CGPoint?) {
        var displayName = url?.deletingPathExtension().lastPathComponent ?? "Image"
        let completion = scenes.captureImageImport { [weak self] sceneID, targetCanvas, canvas, name, native in
            guard let self = self else { return }
            let k = min(1, canvas.width * 0.4 / max(native.width, 1), canvas.height * 0.4 / max(native.height, 1))
            let w = max(LayerResize.minSide, (native.width * k).rounded()), h = max(LayerResize.minSide, (native.height * k).rounded())
            let c = point ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let r = CGRect(x: min(max(c.x - w / 2, 0), max(0, canvas.width - w)), y: min(max(c.y - h / 2, 0), max(0, canvas.height - h)), width: w, height: h)
            let l = Layer(name: displayName, source: LayerSource(type: "image", file: name), frame: NRect(r, in: canvas))
            guard self.editComposition(sceneID: sceneID, canvas: targetCanvas, undo: "Add Image", { $0.layers.append(l) }) else { return }
            if self.scenes.collection.activeID == sceneID && self.scenes.canvas == targetCanvas { self.selectLayer(l.id) }
            log("overlays: added image \(name) (\(Int(native.width))×\(Int(native.height))) at \(NSStringFromRect(r))")
        }
        if let url { importImage(url, completion) }
        else { chooseImage(prompt: "Add") { [weak self] chosen in
            displayName = chosen.deletingPathExtension().lastPathComponent
            self?.importImage(chosen, completion)
        } }
    }

    /// A new file for an image layer: same place and width, height from the new image's aspect.
    func replaceImage(_ id: UUID) {
        let completion = scenes.captureImageImport { [weak self] sceneID, targetCanvas, canvas, name, native in
                guard let self = self else { return }
                self.editComposition(sceneID: sceneID, canvas: targetCanvas, undo: "Replace Image") { c in
                    guard let i = c.layers.firstIndex(where: { $0.id == id }) else { return }
                    var r = c.layers[i].frame.rect(in: canvas)
                    r.size.height = (r.width * native.height / max(native.width, 1)).rounded()
                    c.layers[i].source.file = name; c.layers[i].frame = NRect(r, in: canvas)
                }
        }
        chooseImage(prompt: "Replace") { [weak self] in self?.importImage($0, completion) }
    }

    func addPreset(_ p: LayerPreset) {
        var added: UUID?
        var failed = false
        let size = scenes.canvasSize
        editComposition(undo: "Add \(p.name)") { c in
            switch p.apply(to: &c, canvas: size) {
            case .success(let id): added = id
            case .failure: failed = true
            }
        }
        if failed { toast("“\(scenes.active.name)” has no camera", detail: "Add a camera layer first, then the frame goes around it.", style: .warning); return }
        if let id = added { selectLayer(id); if p == .nameTag { editText(id) } }
    }

    /// Selects a text layer and puts the cursor in the inspector's text field, showing the Scene tab if needed.
    func editText(_ id: UUID) {
        selectLayer(id)
        UserDefaults.standard.set(SidebarTab.scene.rawValue, forKey: "sidebarTab")
        if !state.focusMode { studio.setSidebar(visible: true, animated: true) }
        scenes.focusTextLayerID = id
    }

    private func chooseImage(prompt: String, _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AssetStore.supportedTypes
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = prompt; panel.message = "Choose a PNG, JPEG, HEIC, TIFF or GIF (its first frame)."
        panel.beginSheetModal(for: window) { r in if r == .OK, let url = panel.url { done(url) } }
    }

    /// Copies the file into the asset folder off the main thread, then hands back its asset name and pixel size.
    private func importImage(_ url: URL, _ done: @escaping (String, CGSize) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AssetStore.importImage(url) }
            let size = OverlayImage.size(of: url)
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch (result, size) {
                case (.success(let name), let s?) where s.width > 0 && s.height > 0: done(name, s)
                default:
                    self.toast("Can’t use “\(url.lastPathComponent)”", detail: "Images can be PNG, JPEG, HEIC, TIFF or GIF.", style: .warning)
                    log("overlays: import of \(url.lastPathComponent) failed")
                }
            }
        }
    }
}
