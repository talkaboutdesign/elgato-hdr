// GPU textures for image and text layers. Decoding and rasterizing run on one background queue: a render thread only
// looks up what is ready and otherwise skips the layer for that frame (it appears a frame or two later), so the
// capture reader thread never waits on a file or on CoreText. Export passes `wait: true` to block until every overlay
// exists, so no exported frame lacks one.
import CoreGraphics
import Foundation
import Metal

/// The overlay layers of one composition, in the shape the call sites already use for game and camera: merge
/// `sources` into the sizes given to `SceneResolver.resolve` and `textures` into the map given to `DrawLayer.pair`.
/// Layers whose texture is not ready yet are in neither, so the resolver drops them.
struct OverlayFrame {
    var sources: [SourceKey: SourceInfo] = [:]
    var textures: [SourceKey: LayerTextures.Kind] = [:]
}

final class OverlayTextureCache {
    static let shared = OverlayTextureCache(device: MetalCore.shared.device)

    let device: MTLDevice
    let queue = DispatchQueue(label: "overlay-raster", qos: .userInitiated)
    /// Entries unused this long are released; a `{timer}` layer leaves one stale texture per second behind.
    var maxIdle: TimeInterval = 10
    /// A failed decode (missing or broken file) is retried after this long, e.g. once a project's assets are copied.
    var retryAfter: TimeInterval = 2

    private enum State { case pending, ready(MTLTexture), failed }
    private enum Key: Hashable { case image(URL, maxPixel: Int), text(TextSpec, String, Int, Int) }
    private struct ImageRef: Hashable { var name: String; var paths: [URL] }
    private struct Entry<T> { var state: T; var settled = 0.0; var used = 0.0 }
    private enum Info { case pending, ready(URL, CGSize), failed }

    private let lock = NSLock()
    private var textures: [Key: Entry<State>] = [:]
    private var images: [ImageRef: Entry<Info>] = [:]
    /// The texture last returned for a layer: shown while its replacement (new `{timer}` second, new size) is made,
    /// so a changing layer never blinks.
    private var latest: [UUID: Entry<MTLTexture>] = [:]
    private var lastPurge = 0.0
    private(set) var rasterCount = 0         // decodes and rasterizations so far, for tests

    init(device: MTLDevice) { self.device = device }

    // MARK: Entry point for the render call sites

    /// Textures and source sizes for every visible image and text layer of `c` drawn on a canvas of `canvas` pixels.
    /// `assets`: asset folders in lookup order (`AssetStore.searchPaths(project:)`). With `wait` the call blocks until
    /// everything is decoded; never pass it on the reader or display thread.
    func overlays(for c: Composition, canvas: CGSize, assets: [URL], tokens: OverlayTokens = OverlayTokens(), wait: Bool = false) -> OverlayFrame {
        var out = OverlayFrame()
        for l in c.layers where l.visible && l.opacity > 0 {
            let key = SourceKey.layer(l.id)
            switch l.source.type {
            case "text":
                guard let t = texture(for: l, pixelSize: l.frame.rect(in: canvas).size, assets: assets, tokens: tokens, wait: wait) else { continue }
                out.sources[key] = SourceInfo(size: CGSize(width: t.width, height: t.height))
                out.textures[key] = .rgba(t)
            case "image":
                guard let file = l.source.file, case let .ready(_, native)? = imageInfo(file, assets, wait: wait),
                      let r = SceneResolver.resolve(Composition(layers: [l]), canvas: canvas, sources: [key: SourceInfo(size: native)]).first,
                      r.src.width > 0, r.src.height > 0 else { continue }
                // Output pixels the whole image would span, so a zoomed crop is decoded sharp enough.
                let span = CGSize(width: r.dst.width / r.src.width, height: r.dst.height / r.src.height)
                guard let t = texture(for: l, pixelSize: span, assets: assets, tokens: tokens, wait: wait) else { continue }
                out.sources[key] = SourceInfo(size: native)
                out.textures[key] = .rgba(t)
            default: continue
            }
        }
        return out
    }

    // MARK: Single layer

    /// A premultiplied BGRA sRGB texture for an image or text layer drawn at `pixelSize`, or nil while it is being made
    /// (or when the file is missing). Text is rasterized at exactly that size; images are decoded to the next power of
    /// two at or above its long side, at most 4096 px and never above their own size.
    func texture(for layer: Layer, pixelSize: CGSize, assets: [URL], tokens: OverlayTokens = OverlayTokens(), wait: Bool = false) -> MTLTexture? {
        let key: Key
        switch layer.source.type {
        case "text":
            let spec = layer.source.text ?? TextSpec()
            var w = max(1, Int(pixelSize.width.rounded())), h = max(1, Int(pixelSize.height.rounded()))
            if max(w, h) > 4096 { let k = 4096.0 / Double(max(w, h)); w = max(1, Int(Double(w) * k)); h = max(1, Int(Double(h) * k)) }
            key = .text(spec, tokens.replace(spec.string), w, h)
        case "image":
            guard let file = layer.source.file, case let .ready(url, native)? = imageInfo(file, assets, wait: wait) else { return fallback(layer.id) }
            let need = max(pixelSize.width / max(native.width, 1), pixelSize.height / max(native.height, 1)) * max(native.width, native.height)
            var bucket = 64
            while CGFloat(bucket) < need && bucket < 4096 { bucket *= 2 }
            key = .image(url, maxPixel: min(bucket, Int(max(native.width, native.height))))
        default: return nil
        }
        if let t = lookup(key, wait: wait) {
            lock.lock(); latest[layer.id] = Entry(state: t, used: now()); lock.unlock()
            return t
        }
        return fallback(layer.id)
    }

    /// Blocks until everything queued so far is done. Not on `queue` itself.
    func drain() { dispatchPrecondition(condition: .notOnQueue(queue)); queue.sync {} }

    // MARK: Internals

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func fallback(_ id: UUID) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let e = latest[id] else { return nil }
        latest[id]?.used = now()
        return e.state
    }

    private func lookup(_ key: Key, wait: Bool) -> MTLTexture? {
        let t = now()
        lock.lock()
        purge(t)
        var start = false
        switch textures[key]?.state {
        case .ready(let tex)?: textures[key]?.used = t; lock.unlock(); return tex
        case .pending?: break
        case .failed?: start = t - textures[key]!.settled > retryAfter
        case nil: start = true
        }
        if start { textures[key] = Entry(state: .pending, used: t) }
        lock.unlock()
        if start {
            queue.async { [weak self] in
                guard let self = self else { return }
                let tex = self.make(key)
                self.lock.lock()
                self.textures[key] = Entry(state: tex.map(State.ready) ?? .failed, settled: self.now(), used: self.textures[key]?.used ?? self.now())
                self.rasterCount += 1
                self.lock.unlock()
            }
        }
        guard wait else { return nil }
        drain()
        lock.lock(); defer { lock.unlock() }
        if case .ready(let tex)? = textures[key]?.state { textures[key]?.used = now(); return tex }
        return nil
    }

    private func imageInfo(_ name: String, _ paths: [URL], wait: Bool) -> Info? {
        let ref = ImageRef(name: name, paths: paths), t = now()
        lock.lock()
        var start = false
        switch images[ref]?.state {
        case .ready?: images[ref]?.used = t; let s = images[ref]?.state; lock.unlock(); return s
        case .pending?: break
        case .failed?: start = t - images[ref]!.settled > retryAfter
        case nil: start = true
        }
        if start { images[ref] = Entry(state: .pending, used: t) }
        lock.unlock()
        if start {
            queue.async { [weak self] in
                guard let self = self else { return }
                self.assertOnQueue()
                let info: Info = AssetStore.locate(name, in: paths).flatMap { url in OverlayImage.size(of: url).map { .ready(url, $0) } } ?? .failed
                self.lock.lock(); self.images[ref] = Entry(state: info, settled: self.now(), used: self.now()); self.lock.unlock()
            }
        }
        guard wait else { return nil }
        drain()
        lock.lock(); defer { lock.unlock() }
        return images[ref]?.state
    }

    /// Decoding, layout and upload: only ever on `queue`.
    private func make(_ key: Key) -> MTLTexture? {
        assertOnQueue()
        let bitmap: OverlayBitmap?
        switch key {
        case let .image(url, maxPixel): bitmap = OverlayImage.decode(url, maxPixel: maxPixel)
        case let .text(spec, string, w, h): bitmap = TextRasterizer.render(spec, string: string, width: w, height: h)
        }
        guard let b = bitmap else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: b.width, height: b.height, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        b.pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, b.width, b.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: b.bytesPerRow) }
        return tex
    }

    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }

    /// Call with `lock` held. At most once a second, so a frame's lookups stay a dictionary access.
    private func purge(_ t: Double) {
        guard t - lastPurge > 1 else { return }
        lastPurge = t
        textures = textures.filter { if case .pending = $0.value.state { return true }; return t - $0.value.used < maxIdle }
        images = images.filter { if case .pending = $0.value.state { return true }; return t - $0.value.used < maxIdle }
        latest = latest.filter { t - $0.value.used < maxIdle }
    }
}
