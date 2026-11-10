// Image and text layers on the app side: the `{timer}` clock the renderers read, asset bundling into recordings, and
// the source sizes overlays need when a switch freezes the picture.
import AppKit

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
}
