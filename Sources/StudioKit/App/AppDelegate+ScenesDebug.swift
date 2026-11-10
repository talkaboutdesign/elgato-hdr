#if DEBUG
import AppKit
import Metal

/// Development aids for scenes, for sessions that cannot look at the screen (a locked screen presents no frames and
/// `screencapture` fails):
/// `EHDR_MORPH_DUMP=<dir>` renders transitions offscreen through the compositor, frame by frame, as PNGs;
/// `EHDR_SCENE_DEMO=<dir>` drives the picture editor with synthetic mouse events and writes the studio window with
/// the picture (rendered offscreen, SDR) and its editing overlay composited in.
extension AppDelegate {
    func startSceneDebug() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["EHDR_MORPH_DUMP"] { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.dumpTransitions(to: dir) } }
        if let dir = env["EHDR_SCENE_DEMO"] { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runSceneDemo(dir) } }
        if env["EHDR_EVENT_DEMO"] != nil { runEventDemo() }
    }

    /// With `--record 15` (recording from 4 s to 19 s): three switches, one punch-in and a marker while recording.
    func runEventDemo() {
        let m = scenes
        let script: [(Double, String, () -> Void)] = [
            (6, "switch to scene 2", { m.actions.switchTo(m.collection.scenes[1].id) }),
            (8, "punch in", { self.setPunchIn(true) }),
            (10, "punch out", { self.setPunchIn(false) }),
            (11, "switch to scene 3", { m.actions.switchTo(m.collection.scenes[2].id) }),
            (13, "marker", { self.addMarker() }),
            (15, "switch to scene 1", { m.actions.switchTo(m.collection.scenes[0].id) }),
        ]
        for (t, name, f) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { log("event-demo: \(name) (recording: \(self.recorder != nil))"); f() }
        }
    }

    // MARK: Offscreen rendering

    func liveTextures() -> (sources: [SourceKey: SourceInfo], textures: [SourceKey: LayerTextures.Kind], keep: [CVMetalTexture]) {
        var sources: [SourceKey: SourceInfo] = [:], textures: [SourceKey: LayerTextures.Kind] = [:], keep: [CVMetalTexture] = []
        if let g = renderer?.latestGameFrame {
            sources[.game] = SourceInfo(size: g.size)
            textures[.game] = .biplanar(y: g.y, c: g.c, bits: 10, transfer: g.transfer, bt709: g.transfer == 2)
        }
        if camera.cameraOn, let pb = camera.latest, let p = MetalCore.shared.planes(pb) {
            keep = p.2
            sources[.camera] = SourceInfo(size: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
            textures[.camera] = .biplanar(y: p.0, c: p.1, bits: p.3, transfer: 2, bt709: true)
        }
        return (sources, textures, keep)
    }

    /// One SDR picture of `frame` at `size`.
    func renderOffscreen(_ make: ([SourceKey: SourceInfo]) -> SceneFrame, size: CGSize) -> CGImage? {
        let core = MetalCore.shared, live = liveTextures()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let t = core.device.makeTexture(descriptor: d), let cb = core.queue.makeCommandBuffer() else { return nil }
        let f = make(live.sources)
        core.encodeLayers(cb, target: t, canvas: size, background: f.background, outTransfer: 2, layers: DrawLayer.pair(f.layers, live.textures))
        cb.commit(); cb.waitUntilCompleted()
        _ = live.keep
        return SceneThumbnailer.image(t)
    }

    static func writePNG(_ img: CGImage, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Frames of a transition at evenly spaced times, through the same `LiveSceneState` the renderer uses.
    func dumpTransitions(to dir: String) {
        let c = scenes.collection, base = URL(fileURLWithPath: dir)
        guard c.scenes.count >= 4 else { return }
        let runs: [(String, Scene, Scene, Canvas, SceneTransition)] = [
            ("morph-gameplay-to-focus-wide", c.scenes[0], c.scenes[2], .wide, SceneTransition()),
            ("morph-focus-to-gameplay-wide", c.scenes[2], c.scenes[0], .wide, SceneTransition()),
            ("morph-gameplay-to-justcamera-vertical", c.scenes[0], c.scenes[3], .vertical, SceneTransition()),
            ("fade-gameplay-to-gameonly-wide", c.scenes[0], c.scenes[1], .wide, SceneTransition(style: .fade, durationMs: 380)),
        ]
        let t0: UInt64 = 1_000_000_000_000
        for (name, a, b, canvas, tr) in runs {
            let st = LiveSceneState(scene: a).switching(to: b, atNs: t0, transition: tr)
            let size = canvas == .wide ? CGSize(width: 1280, height: 720) : CGSize(width: 720, height: 1280)
            // Denser early on: the spring covers half the distance in the first quarter of the duration.
            for (i, ms) in [0.0, 25, 50, 75, 100, 150, 200, 280, tr.durationMs].enumerated() {
                let t = t0 + UInt64(ms * 1e6)
                guard let img = renderOffscreen({ st.frame(canvas: canvas, size: size, sources: $0, atNs: t) }, size: size) else { continue }
                AppDelegate.writePNG(img, base.appendingPathComponent(name).appendingPathComponent(String(format: "%d-%03.0fms-e%.2f.png", i, ms, st.progress(atNs: t))))
            }
            log("morph-dump: \(name) -> \(base.appendingPathComponent(name).path)")
        }
        // Punch-in, settled, on Gameplay.
        var p = PunchIn(); p.amount = scenes.punchAmount; p.set(engaged: true, atNs: t0)
        var st = LiveSceneState(scene: c.scenes[0]); st.punchIn = p
        if let img = renderOffscreen({ st.frame(canvas: .wide, size: CGSize(width: 1280, height: 720), sources: $0, atNs: t0 + 1_000_000_000) }, size: CGSize(width: 1280, height: 720)) {
            AppDelegate.writePNG(img, base.appendingPathComponent("punch-in-gameplay.png"))
        }
        log("morph-dump: done")
    }

    // MARK: Window composites

    /// The studio window as drawn, with the picture (rendered offscreen at the view's pixel size) and the editing
    /// overlay layers composited where the Metal view is.
    func studioComposite() -> CGImage? {
        guard let content = window.contentView?.superview ?? window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let base = rep.cgImage else { return nil }
        let scale = CGFloat(base.width) / content.bounds.width
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let vf = view.convert(view.bounds, to: content)
        let v = view.videoRect, px = CGSize(width: (v.width * scale).rounded(), height: (v.height * scale).rounded())
        let m = scenes, st = sceneRuntime.live, t = nowNs()
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: vf.minX, y: vf.minY)
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(view.bounds)
        if let pic = renderOffscreen({ st.frame(canvas: m.canvas, size: px, sources: $0, atNs: t) }, size: px) { ctx.draw(pic, in: v) }
        for l in view.metalLayer.sublayers ?? [] where !l.isHidden {
            ctx.saveGState(); ctx.translateBy(x: l.frame.minX, y: l.frame.minY); l.render(in: ctx); ctx.restoreGState()
        }
        ctx.restoreGState()
        // The views floating over the picture (status pill, toast) were painted over: draw them again on top.
        for sub in view.superview?.subviews ?? [] where sub !== view && !sub.isHidden && sub.frame.intersects(view.frame) && sub.frame.height < view.frame.height / 2 {
            guard let r = sub.bitmapImageRepForCachingDisplay(in: sub.bounds) else { continue }
            sub.cacheDisplay(in: sub.bounds, to: r)
            guard let img = r.cgImage else { continue }
            let f = sub.convert(sub.bounds, to: content)
            ctx.draw(img, in: CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale))
        }
        return ctx.makeImage()
    }

    func snapshotAll(_ dir: URL, _ name: String) {
        if let img = studioComposite() { AppDelegate.writePNG(img, dir.appendingPathComponent("\(name).png")) }
        for w in NSApp.windows where w.isVisible && w !== window && w.className.contains("Popover") {
            guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-popover.png"))
        }
        log("scene-demo: \(name)")
    }

    // MARK: Scripted editing

    /// Sends a mouse event to the picture at a canvas point (pixels of the 1080p canvas), as AppKit would.
    func pictureMouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let v = view.videoRect, ref = scenes.canvasSize
        let pt = CGPoint(x: v.minX + p.x / ref.width * v.width, y: v.maxY - p.y / ref.height * v.height)
        guard let e = NSEvent.mouseEvent(with: type, location: view.convert(pt, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: e)
        case .leftMouseDragged: view.mouseDragged(with: e)
        case .leftMouseUp: view.mouseUp(with: e)
        case .mouseMoved: view.mouseMoved(with: e)
        default: break
        }
    }

    func runSceneDemo(_ path: String) {
        let dir = URL(fileURLWithPath: path), m = scenes
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set("scene", forKey: "sidebarTab")
        func rect(_ type: String) -> CGRect? { m.composition.layers.last { $0.source.type == type }?.frame.rect(in: m.canvasSize) }
        var steps: [(Double, () -> Void)] = []
        func step(_ wait: Double, _ f: @escaping () -> Void) { steps.append((wait, f)) }
        step(1.5) {
            // The Edit menu's Undo goes to the first responder; the studio window must answer it for scene undo.
            log("scene-demo: window answers undo: \(self.window.responds(to: Selector(("undo:"))))")
            self.snapshotAll(dir, "01-strip-and-scene-tab")
        }
        step(0.1) { if let r = rect("camera") { self.pictureMouse(.mouseMoved, CGPoint(x: r.midX, y: r.midY)); self.pictureMouse(.leftMouseDown, CGPoint(x: r.midX, y: r.midY)); self.pictureMouse(.leftMouseUp, CGPoint(x: r.midX, y: r.midY)) } }
        step(1.2) { self.snapshotAll(dir, "02-camera-selected") }
        // Drag the camera towards the middle, a few pixels off, so it snaps to the centre lines.
        step(0.1) {
            guard let r = rect("camera") else { return }
            self.pictureMouse(.leftMouseDown, CGPoint(x: r.midX, y: r.midY))
            for i in 1...10 { let f = CGFloat(i) / 10; self.pictureMouse(.leftMouseDragged, CGPoint(x: r.midX + (963 - r.midX) * f, y: r.midY + (536 - r.midY) * f)) }
        }
        step(1.2) { self.snapshotAll(dir, "03-snapping-guides") }
        step(0.1) { self.pictureMouse(.leftMouseUp, CGPoint(x: 963, y: 536)) }
        // Resize from the bottom-right handle, towards the right margin.
        step(0.3) {
            guard let r = rect("camera") else { return }
            self.pictureMouse(.leftMouseDown, CGPoint(x: r.maxX, y: r.maxY))
            for i in 1...8 { self.pictureMouse(.leftMouseDragged, CGPoint(x: r.maxX + CGFloat(i) * 22, y: r.maxY + CGFloat(i) * 12)) }
        }
        step(1.2) { self.snapshotAll(dir, "04-resizing") }
        step(0.1) { if let r = rect("camera") { self.pictureMouse(.leftMouseUp, CGPoint(x: r.maxX, y: r.maxY)) } }
        step(0.2) { self.window.undoManager?.undo(); self.window.undoManager?.undo(); log("scene-demo: undo twice, camera back at \(rect("camera").map { NSStringFromRect($0) } ?? "-")") }
        step(1.0) { self.snapshotAll(dir, "05-after-undo") }
        // 9:16: select the game and drag its top edge up, with the camera above it.
        step(0.1) { m.actions.setCanvas(.vertical) }
        step(1.2) { self.snapshotAll(dir, "06-vertical-canvas") }
        step(0.1) {
            guard let r = rect("game") else { return }
            self.pictureMouse(.leftMouseDown, CGPoint(x: r.midX, y: r.midY)); self.pictureMouse(.leftMouseUp, CGPoint(x: r.midX, y: r.midY))
            self.pictureMouse(.leftMouseDown, CGPoint(x: r.midX, y: r.minY))
            for i in 1...6 { self.pictureMouse(.leftMouseDragged, CGPoint(x: r.midX, y: r.minY + CGFloat(i) * 25)) }
        }
        step(1.2) { self.snapshotAll(dir, "07-vertical-editing") }
        step(0.1) { if let r = rect("game") { self.pictureMouse(.leftMouseUp, CGPoint(x: r.midX, y: r.minY)) }; self.window.undoManager?.undo() }
        // Crop mode on the camera.
        step(0.3) { if let r = rect("camera") { self.pictureMouse(.leftMouseDown, CGPoint(x: r.midX, y: r.midY), clicks: 2) } }
        step(1.2) { self.snapshotAll(dir, "08-crop-mode") }
        step(0.1) { m.actions.setCrop(nil); m.actions.selectLayer(nil); m.actions.setCanvas(.wide) }
        // A switch, captured mid-transition, and the add-scene gallery.
        step(1.0) { m.actions.switchTo(m.collection.scenes[2].id) }
        step(0.12) { self.snapshotAll(dir, "09-switching") }
        step(1.2) { self.snapshotAll(dir, "10-camera-focus") }
        step(0.1) { m.galleryOpen = true }
        step(1.6) { self.snapshotAll(dir, "11-add-scene-gallery") }
        step(0.1) { m.galleryOpen = false; m.renamingSceneID = m.active.id }
        step(1.0) { self.snapshotAll(dir, "12-rename") }
        step(0.1) { m.renamingSceneID = nil; m.actions.switchTo(m.collection.scenes[0].id) }
        step(1.0) { log("scene-demo: done") }
        func run(_ i: Int) {
            guard i < steps.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + steps[i].0) { steps[i].1(); run(i + 1) }
        }
        run(0)
    }
}
#endif
