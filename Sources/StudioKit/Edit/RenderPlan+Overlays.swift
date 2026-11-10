// Image and text layers in the editor preview, the library's thumbnails and hover frames, and every export. They come
// from the same `OverlayTextureCache` and asset lookup (project `Assets/` first) as the live picture, and take part in
// transitions exactly as live: the plan lists overlays through the live engine's own `overlayLayers`, so a layer
// fades, morphs by id, or cross-fades to changed content the same way.
//
// Tokens in an edit: `{timer}` is the time on the edited timeline (the position in the exported video, so cuts and a
// trimmed start do not show), not the time in the recording; `{time}` is the wall clock when that moment was recorded.
import CoreGraphics
import Foundation

/// Where a plan's overlays come from and whether a frame waits for them.
struct OverlaySource {
    var assets: [URL]           // `AssetStore.searchPaths(project:)`
    var recordedAt: Date        // wall clock at source time 0
    /// Exports, thumbnails and hover frames wait until every texture exists, so no frame lacks an overlay. The
    /// preview never waits: a layer whose texture is still being made shows a frame or two late.
    var wait = true
}

extension RenderPlan {
    /// The image and text layers that can be in the picture at `t`, as the live engine lists them mid-transition
    /// (outgoing layers whose content changes get their own id, so their texture stays theirs).
    func overlayLayers(atTimelineMs t: Double) -> [Layer] {
        guard let (state, ns) = liveState(atSourceMs: map.source(fromTimeline: t)) else { return [] }
        return state.overlayLayers(canvas: canvas, atNs: ns)
    }

    /// Token values at `t`: `{timer}` counts the edited timeline, `{time}` is the recording's clock at that moment.
    func tokens(atTimelineMs t: Double) -> OverlayTokens {
        let s = map.source(fromTimeline: t)
        let edited = (cuts ?? map).timelineClamped(fromSource: s)
        return OverlayTokens(now: (overlay?.recordedAt ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(s / 1000), elapsed: edited / 1000)
    }

    /// Textures and source sizes of the overlays drawn at `t`, to merge with the game and camera.
    func overlays(atTimelineMs t: Double, cache: OverlayTextureCache = .shared) -> OverlayFrame {
        guard let o = overlay else { return OverlayFrame() }
        let layers = overlayLayers(atTimelineMs: t)
        guard !layers.isEmpty else { return OverlayFrame() }
        return cache.overlays(for: Composition(layers: layers), canvas: canvasSize, assets: o.assets, tokens: tokens(atTimelineMs: t),
                              wait: o.wait, consumer: o.wait ? .export : .preview)
    }

    /// Scenes the timeline can show: those its spans name, or the first when it has none.
    var shownScenes: [Scene] {
        let used = Set(timeline.sceneSpans.map(\.sceneID))
        let shown = scenes.filter { used.contains($0.id) }
        return shown.isEmpty ? Array(scenes.prefix(1)) : shown
    }

    /// Decodes and rasterizes every overlay the plan can draw before the first frame is asked for (an export calls
    /// this before its reader starts). Text with `{timer}` or `{time}` changes as it plays; its later values are made
    /// as they come up, with the frame waiting for them.
    func prewarmOverlays(cache: OverlayTextureCache = .shared) {
        guard let o = overlay else { return }
        let layers = shownScenes.flatMap { $0.composition(canvas).layers }.filter(\.isOverlay)
        guard !layers.isEmpty else { return }
        _ = cache.overlays(for: Composition(layers: layers), canvas: canvasSize, assets: o.assets, tokens: tokens(atTimelineMs: 0),
                           wait: true, consumer: .export)
    }
}

extension TimeMap {
    /// Timeline time at source `s`; inside a removed section, the time of the cut it collapses to.
    func timelineClamped(fromSource s: Double) -> Double {
        var t = 0.0
        for r in segments {
            if s < r.startMs { return t }
            if s < r.endMs { return t + s - r.startMs }
            t += r.endMs - r.startMs
        }
        return t
    }
}

/// An image layer whose file is in neither the project's `Assets/` nor the application support folder.
struct MissingAsset: Equatable, Hashable {
    var file: String
    var layer: String       // the layer's name, usually the original file name
    var scene: String
}

extension AssetStore {
    /// Image layers of `scenes` (either canvas) whose file cannot be found. They are left out of the picture; an
    /// export still runs.
    static func missing(in scenes: [Scene], searchPaths: [URL]) -> [MissingAsset] {
        var out: [MissingAsset] = [], seen = Set<String>()
        for s in scenes {
            for l in s.wide.layers + s.vertical.layers where l.source.type == "image" {
                guard let f = l.source.file, seen.insert("\(s.id)/\(f)").inserted, locate(f, in: searchPaths) == nil else { continue }
                out.append(MissingAsset(file: f, layer: l.name.isEmpty ? f : l.name, scene: s.name))
            }
        }
        return out
    }
}
