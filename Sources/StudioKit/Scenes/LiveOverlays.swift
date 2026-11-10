// Image and text layers in the live picture. The window, every program output and the scene thumbnails look their
// textures up in `OverlayTextureCache` without waiting: a layer whose texture is not ready is left out of that frame
// and appears a frame or two later, so no render thread ever waits on a file or on CoreText.
import CoreGraphics
import Foundation

/// What a renderer draws for one frame: the live scene's picture and the textures of its image and text layers (game
/// and camera textures are added by whoever draws).
struct LivePicture {
    var frame = SceneFrame(background: SIMD4(0, 0, 0, 1), layers: [])
    var textures: [SourceKey: LayerTextures.Kind] = [:]
}

/// Main-thread facts the overlays need on render threads: where `{timer}` counts from, and the asset folders. The
/// renderer holds a copy behind its lock.
struct LiveOverlayContext: Equatable {
    /// Host time `{timer}` counts from: the stream's start while live, else the recording's, else nil (0:00).
    var timerStartNs: UInt64?
    var assets: [URL] = AssetStore.searchPaths(project: nil)

    /// Token values for a frame captured at `t`, so the window and every stream show the same `{timer}`.
    func tokens(atNs t: UInt64) -> OverlayTokens {
        OverlayTokens(now: Date(), elapsed: timerStartNs.map { Double(Int64(bitPattern: t &- $0)) / 1e9 })
    }
}

extension Layer {
    /// Image and text: layers whose pixels come from `OverlayTextureCache`.
    var isOverlay: Bool { source.type == "image" || source.type == "text" }
}

extension LiveSceneState {
    /// Source sizes and textures of the overlay layers drawn at `t` on `canvas`, for a picture `size` pixels big
    /// (text is rasterized at exactly the size it is drawn). Never waits.
    func overlays(canvas: Canvas, size: CGSize, atNs t: UInt64, context: LiveOverlayContext,
                  consumer: OverlayTextureCache.Consumer, cache: OverlayTextureCache = .shared) -> OverlayFrame {
        let layers = overlayLayers(canvas: canvas, atNs: t)
        guard !layers.isEmpty else { return OverlayFrame() }
        return cache.overlays(for: Composition(layers: layers), canvas: size, assets: context.assets,
                              tokens: context.tokens(atNs: t), wait: false, consumer: consumer)
    }

    /// The whole picture for one canvas: scene, transition, punch-in and the overlays that are ready.
    func picture(canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo], atNs t: UInt64, context: LiveOverlayContext,
                 consumer: OverlayTextureCache.Consumer, cache: OverlayTextureCache = .shared) -> LivePicture {
        let o = overlays(canvas: canvas, size: size, atNs: t, context: context, consumer: consumer, cache: cache)
        guard !o.sources.isEmpty else { return LivePicture(frame: frame(canvas: canvas, size: size, sources: sources, atNs: t)) }
        let all = sources.merging(o.sources) { own, _ in own }
        return LivePicture(frame: frame(canvas: canvas, size: size, sources: all, atNs: t), textures: o.textures)
    }
}
