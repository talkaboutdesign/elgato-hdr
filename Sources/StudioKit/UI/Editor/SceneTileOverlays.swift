// Image and text layers drawn with their real content in the editor's scene tiles, so scenes that differ only in
// overlays look different. Textures come from the same `OverlayTextureCache` as every other picture, looked up without
// waiting: a tile shows the layer's placeholder until its texture is ready, then redraws.
import CoreGraphics
import Foundation
import Metal
import Observation

@Observable
final class SceneTileOverlays {
    static let shared = SceneTileOverlays()

    /// Bumped once the cache has made what a tile was missing; tiles read it so they redraw.
    private(set) var revision = 0
    @ObservationIgnored private var refreshQueued = false
    /// Pictures per texture, dropped with their texture (an address can be reused by a later texture).
    @ObservationIgnored private let images = NSMapTable<AnyObject, CGImage>.weakToStrongObjects()
    @ObservationIgnored let cache: OverlayTextureCache

    init(cache: OverlayTextureCache = .shared) { self.cache = cache }

    /// Source sizes and pictures of the overlays of `c` drawn on a tile of `canvas` pixels. A layer whose texture is
    /// not ready yet is left out of `images` (the tile draws its placeholder) and a redraw is queued.
    func overlays(for c: Composition, canvas: CGSize, assets: [URL], tokens: OverlayTokens) -> (sources: [SourceKey: SourceInfo], images: [UUID: CGImage]) {
        let layers = c.layers.filter(\.isOverlay)
        guard !layers.isEmpty else { return ([:], [:]) }
        let o = cache.overlays(for: Composition(layers: layers), canvas: canvas, assets: assets, tokens: tokens, consumer: .thumbnails)
        if o.pending { refreshWhenReady() }
        var out: [UUID: CGImage] = [:]
        for (key, kind) in o.textures {
            guard case .layer(let id) = key, case .rgba(let t) = kind, let img = image(t) else { continue }
            out[id] = img
        }
        // Layers not ready keep the sizes the placeholder is laid out with.
        var sources = cache.sourceSizes(for: layers, canvas: canvas, assets: assets)
        sources.merge(o.sources) { _, ready in ready }
        return (sources, out)
    }

    private func refreshWhenReady() {
        DispatchQueue.main.async { [self] in
            guard !refreshQueued else { return }
            refreshQueued = true
            DispatchQueue.global(qos: .utility).async { [self] in
                cache.drain()
                DispatchQueue.main.async { [self] in refreshQueued = false; revision += 1 }
            }
        }
    }

    /// The texture's pixels as a premultiplied BGRA sRGB image; kept per texture. Main thread.
    private func image(_ t: MTLTexture) -> CGImage? {
        if let hit = images.object(forKey: t) { return hit }
        guard t.storageMode != .private, t.pixelFormat == .bgra8Unorm else { return nil }
        let row = t.width * 4
        var bytes = [UInt8](repeating: 0, count: row * t.height)
        bytes.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: t.width, height: t.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        images.setObject(img, forKey: t)
        return img
    }
}
