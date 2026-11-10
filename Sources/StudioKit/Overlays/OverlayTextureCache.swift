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
    /// Something is still being decoded or rasterized: a layer was left out or shows its previous texture. A paused
    /// editor preview redraws once the cache has caught up (a missing file never counts).
    var pending = false
}

final class OverlayTextureCache {
    static let shared = OverlayTextureCache(device: MetalCore.shared.device)

    let device: MTLDevice
    let queue = DispatchQueue(label: "overlay-raster", qos: .userInitiated)
    /// Entries unused this long are released; a `{timer}` layer leaves one stale texture per second behind.
    var maxIdle: TimeInterval = 10
    /// A failed decode (missing or broken file) is retried after this long, e.g. once a project's assets are copied.
    var retryAfter: TimeInterval = 2

    /// Who draws a texture. Each keeps its own last texture per layer to show while a replacement is made, so the
    /// window never borrows the thumbnails' tiny one (or the stream's) for a frame when `{timer}` ticks.
    enum Consumer: Int { case any, window, wideOutput, verticalOutput, thumbnails, preview, export
        static func output(_ c: Canvas) -> Consumer { c == .wide ? .wideOutput : .verticalOutput }
    }

    /// The work for one pending entry, created under `lock` together with the entry, so a blocking caller that finds
    /// the entry pending waits for exactly that work (never for "whatever was queued when I looked", which can be
    /// nothing yet: the starter enqueues after unlocking). `result` is written before `done` is left.
    private final class Job<T> {
        let done = DispatchGroup()
        var result: T?
        init() { done.enter() }
        func finish(_ r: T) { result = r; done.leave() }
    }
    private enum State { case pending(Job<MTLTexture?>), ready(MTLTexture), failed }
    private struct LatestKey: Hashable { var id: UUID; var consumer: Consumer }
    private enum Key: Hashable { case image(URL, maxPixel: Int), text(TextSpec, String, Int, Int) }
    private struct ImageRef: Hashable { var name: String; var paths: [URL] }
    private struct Entry<T> { var state: T; var settled = 0.0; var used = 0.0 }
    private enum Info { case pending(Job<Info>), ready(URL, CGSize), failed }

    private let lock = NSLock()
    private var textures: [Key: Entry<State>] = [:]
    private var images: [ImageRef: Entry<Info>] = [:]
    /// The texture last returned for a layer: shown while its replacement (new `{timer}` second, new size) is made,
    /// so a changing layer never blinks.
    private var latest: [LatestKey: Entry<MTLTexture>] = [:]
    private var lastPurge = 0.0
    private(set) var rasterCount = 0         // decodes and rasterizations so far, for tests
    /// Bytes held by ready textures (`latest` only adds references to them). Above `byteBudget` the least recently
    /// used are released at once, whatever their idle age: a long export with many big `{timer}` layers stays bounded.
    var byteBudget = 256 << 20
    private(set) var residentBytes = 0
    private(set) var peakResidentBytes = 0

    init(device: MTLDevice) { self.device = device }

    // MARK: Entry point for the render call sites

    /// Textures and source sizes for every visible image and text layer of `c` drawn on a canvas of `canvas` pixels.
    /// `assets`: asset folders in lookup order (`AssetStore.searchPaths(project:)`). With `wait` the call blocks until
    /// everything is decoded; never pass it on the reader or display thread.
    func overlays(for c: Composition, canvas: CGSize, assets: [URL], tokens: OverlayTokens = OverlayTokens(), wait: Bool = false,
                  consumer: Consumer = .any) -> OverlayFrame {
        var out = OverlayFrame()
        for l in c.layers where l.visible && l.opacity > 0 {
            let key = SourceKey.layer(l.id)
            switch l.source.type {
            case "text":
                let (t, ready) = lookup(l, pixelSize: l.frame.rect(in: canvas).size, assets: assets, tokens: tokens, wait: wait, consumer: consumer)
                if !ready { out.pending = true }
                guard let t else { continue }
                out.sources[key] = SourceInfo(size: CGSize(width: t.width, height: t.height))
                out.textures[key] = .rgba(t)
            case "image":
                guard let file = l.source.file else { continue }
                let info = imageInfo(file, assets, wait: wait)
                guard case let .ready(_, native)? = info else { if info == nil { out.pending = true }; continue }
                guard let r = SceneResolver.resolve(Composition(layers: [l]), canvas: canvas, sources: [key: SourceInfo(size: native)]).first,
                      r.src.width > 0, r.src.height > 0 else { continue }
                // Output pixels the whole image would span, so a zoomed crop is decoded sharp enough.
                let span = CGSize(width: r.dst.width / r.src.width, height: r.dst.height / r.src.height)
                let (t, ready) = lookup(l, pixelSize: span, assets: assets, tokens: tokens, wait: wait, consumer: consumer)
                if !ready { out.pending = true }
                guard let t else { continue }
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
    func texture(for layer: Layer, pixelSize: CGSize, assets: [URL], tokens: OverlayTokens = OverlayTokens(), wait: Bool = false,
                 consumer: Consumer = .any) -> MTLTexture? {
        lookup(layer, pixelSize: pixelSize, assets: assets, tokens: tokens, wait: wait, consumer: consumer).texture
    }

    /// `ready` is false while the exact texture is still being made (the layer's previous one, or nothing, stands in).
    private func lookup(_ layer: Layer, pixelSize: CGSize, assets: [URL], tokens: OverlayTokens, wait: Bool,
                        consumer: Consumer) -> (texture: MTLTexture?, ready: Bool) {
        let mine = LatestKey(id: layer.id, consumer: consumer)
        let key: Key
        switch layer.source.type {
        case "text":
            let spec = layer.source.text ?? TextSpec()
            var w = max(1, Int(pixelSize.width.rounded())), h = max(1, Int(pixelSize.height.rounded()))
            if max(w, h) > 4096 { let k = 4096.0 / Double(max(w, h)); w = max(1, Int(Double(w) * k)); h = max(1, Int(Double(h) * k)) }
            key = .text(spec, tokens.replace(spec.string), w, h)
        case "image":
            guard let file = layer.source.file else { return (nil, true) }
            let info = imageInfo(file, assets, wait: wait)
            guard case let .ready(url, native)? = info else { return (fallback(mine), info != nil) }
            let need = max(pixelSize.width / max(native.width, 1), pixelSize.height / max(native.height, 1)) * max(native.width, native.height)
            var bucket = 64
            while CGFloat(bucket) < need && bucket < 4096 { bucket *= 2 }
            key = .image(url, maxPixel: min(bucket, Int(max(native.width, native.height))))
        default: return (nil, true)
        }
        switch lookup(key, wait: wait) {
        case .ready(let t):
            lock.lock(); latest[mine] = Entry(state: t, used: now()); lock.unlock()
            return (t, true)
        case .failed: return (fallback(mine), true)
        case .pending: return (fallback(mine), false)
        }
    }

    /// Source sizes of image and text layers for laying them out without drawing (a frozen transition picture):
    /// an image's own size once known, a text layer's box on `canvas`. Never waits; unknown images are left out.
    func sourceSizes(for layers: [Layer], canvas: CGSize, assets: [URL]) -> [SourceKey: SourceInfo] {
        var out: [SourceKey: SourceInfo] = [:]
        for l in layers where l.visible && l.opacity > 0 {
            switch l.source.type {
            case "text": out[.layer(l.id)] = SourceInfo(size: l.frame.rect(in: canvas).size)
            case "image":
                if let file = l.source.file, case let .ready(_, native)? = imageInfo(file, assets, wait: false) { out[.layer(l.id)] = SourceInfo(size: native) }
            default: break
            }
        }
        return out
    }

    /// Blocks until everything queued so far is done. Not on `queue` itself.
    func drain() { dispatchPrecondition(condition: .notOnQueue(queue)); queue.sync {} }

    // MARK: Internals

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func fallback(_ key: LatestKey) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let e = latest[key] else { return nil }
        latest[key]?.used = now()
        return e.state
    }

    private func lookup(_ key: Key, wait: Bool) -> State {
        let t = now()
        lock.lock()
        purge(t)
        var job: Job<MTLTexture?>?, start = false
        switch textures[key]?.state {
        case .ready(let tex)?: textures[key]?.used = t; lock.unlock(); return .ready(tex)
        case .pending(let j)?: job = j
        case .failed?: start = t - textures[key]!.settled > retryAfter
            if !start { lock.unlock(); return .failed }
        case nil: start = true
        }
        if start { let j = Job<MTLTexture?>(); job = j; textures[key] = Entry(state: .pending(j), used: t) }
        lock.unlock()
        if start, let j = job {
            queue.async { [weak self] in
                guard let self = self else { j.finish(nil); return }
                let tex = self.make(key)
                self.lock.lock()
                let used = self.textures[key]?.used ?? self.now()
                self.textures[key] = Entry(state: tex.map(State.ready) ?? .failed, settled: self.now(), used: used)
                if let tex { self.residentBytes += Self.bytes(tex); self.trim(keeping: key); self.peakResidentBytes = max(self.peakResidentBytes, self.residentBytes) }
                self.rasterCount += 1
                self.lock.unlock()
                j.finish(tex)
            }
        }
        guard let j = job else { return .failed }
        guard wait else { return .pending(j) }
        dispatchPrecondition(condition: .notOnQueue(queue))
        j.done.wait()
        guard let tex = j.result ?? nil else { return .failed }
        lock.lock()
        if case .ready(let mine)? = textures[key]?.state, mine === tex { textures[key]?.used = now() }
        lock.unlock()
        return .ready(tex)
    }

    private func imageInfo(_ name: String, _ paths: [URL], wait: Bool) -> Info? {
        let ref = ImageRef(name: name, paths: paths), t = now()
        lock.lock()
        var job: Job<Info>?, start = false
        switch images[ref]?.state {
        case .ready?: images[ref]?.used = t; let s = images[ref]?.state; lock.unlock(); return s
        case .pending(let j)?: job = j
        case .failed?: start = t - images[ref]!.settled > retryAfter
            if !start { lock.unlock(); return .failed }
        case nil: start = true
        }
        if start { let j = Job<Info>(); job = j; images[ref] = Entry(state: .pending(j), used: t) }
        lock.unlock()
        if start, let j = job {
            queue.async { [weak self] in
                guard let self = self else { j.finish(.failed); return }
                self.assertOnQueue()
                let info: Info = AssetStore.locate(name, in: paths).flatMap { url in OverlayImage.size(of: url).map { .ready(url, $0) } } ?? .failed
                self.lock.lock(); self.images[ref] = Entry(state: info, settled: self.now(), used: self.now()); self.lock.unlock()
                j.finish(info)
            }
        }
        guard wait, let j = job else { return nil }
        dispatchPrecondition(condition: .notOnQueue(queue))
        j.done.wait()
        return j.result ?? .failed
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

    private static func bytes(_ t: MTLTexture) -> Int { t.width * t.height * 4 }

    /// Releases ready textures, least recently used first, until `residentBytes` fits `byteBudget`. `keeping` (the
    /// texture just made, about to be drawn) is never released. Call with `lock` held.
    private func trim(keeping: Key) {
        guard residentBytes > byteBudget else { return }
        let ready = textures.compactMap { k, e -> (Key, Double, MTLTexture)? in
            if k != keeping, case .ready(let t) = e.state { return (k, e.used, t) }; return nil
        }.sorted { $0.1 < $1.1 }
        for (k, _, t) in ready where residentBytes > byteBudget {
            textures[k] = nil
            residentBytes -= Self.bytes(t)
            // A layer's stand-in must not keep an evicted texture alive past the budget either.
            latest = latest.filter { $0.value.state !== t }
        }
    }

    /// Call with `lock` held. At most once a second, so a frame's lookups stay a dictionary access.
    private func purge(_ t: Double) {
        guard t - lastPurge > 1 else { return }
        lastPurge = t
        textures = textures.filter {
            if case .pending = $0.value.state { return true }
            if t - $0.value.used < maxIdle { return true }
            if case .ready(let tex) = $0.value.state { residentBytes -= Self.bytes(tex) }
            return false
        }
        images = images.filter { if case .pending = $0.value.state { return true }; return t - $0.value.used < maxIdle }
        latest = latest.filter { t - $0.value.used < maxIdle }
    }
}
