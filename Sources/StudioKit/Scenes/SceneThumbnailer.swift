import AppKit
import CoreVideo
import Metal

/// Renders small pictures of scenes for the strip through the one compositor, from the game frame the renderer copies
/// into `snapshot` and the latest camera buffer (retained, so it cannot change). Works on its own low-priority queue
/// and command queue so it never delays the reader thread or a presentation; a pass is skipped while the previous one
/// is still running, and while there is a game but no finished copy of it.
final class SceneThumbnailer {
    let snapshot = GameSnapshot()
    static let size = CGSize(width: 160, height: 90)
    private let queue = DispatchQueue(label: "scene-thumbnails", qos: .utility)
    private let commands: MTLCommandQueue?
    private let lock = NSLock()
    private var busy = false
    private var targets: [MTLTexture] = []
    private var targetCanvas = Canvas.wide

    init() { commands = MetalCore.shared.device.makeCommandQueue() }

    /// `done` runs on the main thread with an image per scene id (SDR, BT.709).
    /// `hasGame`: the renderer has drawn game frames, so a pass without the snapshot would show none.
    /// `context`: overlays are drawn as the live picture draws them; one not rasterized yet appears in the next pass.
    func render(scenes: [Scene], canvas: Canvas, hasGame: Bool, camera: CVPixelBuffer?, context: LiveOverlayContext = LiveOverlayContext(),
                done: @escaping ([UUID: CGImage]) -> Void) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true; lock.unlock()
        queue.async { [self] in
            let game = snapshot.beginRead()
            defer { if game != nil { snapshot.endRead() } }
            guard game != nil || !hasGame else { lock.lock(); busy = false; lock.unlock(); return }
            let images = draw(scenes, canvas, game, camera, context)
            lock.lock(); busy = false; lock.unlock()
            DispatchQueue.main.async { done(images) }
        }
    }

    private func draw(_ scenes: [Scene], _ canvas: Canvas, _ game: LiveGameFrame?, _ camera: CVPixelBuffer?, _ context: LiveOverlayContext) -> [UUID: CGImage] {
        let core = MetalCore.shared
        guard let commands = commands, let cb = commands.makeCommandBuffer() else { return [:] }
        let size = canvas == .wide ? Self.size : CGSize(width: Self.size.height, height: Self.size.width)
        if targetCanvas != canvas { targets = []; targetCanvas = canvas }
        while targets.count < scenes.count {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            guard let t = core.device.makeTexture(descriptor: d) else { return [:] }
            targets.append(t)
        }
        var sources: [SourceKey: SourceInfo] = [:], textures: [SourceKey: LayerTextures.Kind] = [:]
        if let g = game {
            sources[.game] = SourceInfo(size: g.size)
            textures[.game] = .biplanar(y: g.y, c: g.c, bits: 10, transfer: g.transfer, bt709: g.transfer == 2)
        }
        var keep: [CVMetalTexture] = []
        if let pb = camera, let p = core.planes(pb) {
            keep = p.2
            sources[.camera] = SourceInfo(size: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
            textures[.camera] = .biplanar(y: p.0, c: p.1, bits: p.3, transfer: 2, bt709: true)
        }
        let tokens = context.tokens(atNs: nowNs())
        for (i, s) in scenes.enumerated() {
            let comp = s.composition(canvas)
            let o = OverlayTextureCache.shared.overlays(for: comp, canvas: size, assets: context.assets, tokens: tokens, consumer: .thumbnails)
            let all = sources.merging(o.sources) { own, _ in own }
            core.encodeLayers(cb, target: targets[i], canvas: size, background: comp.backgroundColor, outTransfer: 2,
                              layers: DrawLayer.pair(SceneResolver.resolve(comp, canvas: size, sources: all), textures.merging(o.textures) { own, _ in own }))
        }
        cb.commit(); cb.waitUntilCompleted()
        _ = keep
        var out: [UUID: CGImage] = [:]
        for (i, s) in scenes.enumerated() { out[s.id] = Self.image(targets[i]) }
        return out
    }

    static func image(_ t: MTLTexture) -> CGImage? {
        let w = t.width, h = t.height, row = w * 4
        var bytes = [UInt8](repeating: 0, count: row * h)
        bytes.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
