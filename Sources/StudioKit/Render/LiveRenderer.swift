import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

// MARK: - Live renderer (P010 -> PQ/HLG/709 RGB, zero-copy from shared memory, facecam composited on top)

/// The facecam the live view draws. The layout lives in the scene (`LiveSceneState`); `placement` and `mirror`
/// mirror the active scene's camera layer for code that has not moved to `Renderer.sceneFrame` yet.
struct LiveOverlay {
    var camera: CameraCapture?
    var placement = CameraPlacement()
    var mirror = false
}

struct LiveGameFrame { let y: MTLTexture, c: MTLTexture; let size: CGSize; let transfer: Int32 }

final class Renderer: NSObject {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let layer: CAMetalLayer
    private var _overlay = LiveOverlay()
    var overlay: LiveOverlay { get { lock.lock(); defer { lock.unlock() }; return _overlay } set { lock.lock(); _overlay = newValue; lock.unlock() } }
    var slotBuffers: [MTLBuffer] = []
    var shmTextures: [Int: (MTLTexture, MTLTexture)] = [:]   // key: slot<<40 | w<<20 | h
    var colorMode: ColorMode = .pq { didSet { applyColor() } }
    var presentation: Presentation = .smooth { didSet { layer.displaySyncEnabled = presentation != .immediate; resetPacing() } }

    // Game mode: frames drawn on arrival with vsync; dropped only if three drawables are already waiting for the screen.
    var gameQueued = 0

    // App-owned texture ring: frames are blitted here on arrival so shared-memory slots can be reused freely.
    static let ringSize = 8
    var ring: [(MTLTexture, MTLTexture)] = []
    var ringW = 0, ringH = 0, ringNext = 0
    struct Queued { let ring: Int; let target: Double; let arrival: Double }
    var pending: [Queued] = []
    let lock = NSLock()

    // Scenes: the main thread replaces these; the reader thread, the display link and program outputs copy them under
    // `lock`, once per frame. Nothing here touches the scene collection.
    private var _scene = LiveSceneState(scene: SceneTemplate.gameOnly.scene())
    private var _viewCanvas = Canvas.wide
    private var _lastGame: LiveGameFrame?
    var scene: LiveSceneState { get { lock.lock(); defer { lock.unlock() }; return _scene } set { lock.lock(); _scene = newValue; lock.unlock() } }
    /// Which canvas the window shows (and the user edits).
    var viewCanvas: Canvas { get { lock.lock(); defer { lock.unlock() }; return _viewCanvas } set { lock.lock(); _viewCanvas = newValue; lock.unlock() } }

    // Pacing: fixed vsync grid, k refreshes per source frame, lead budget for jitter.
    var displayLink: CADisplayLink?
    var refresh = 1.0 / 60
    var grid0 = 0.0, nextTarget = 0.0, period = 0.0, lastArrival = 0.0
    var lastTarget = 0.0, slips = 0, pacingDrops = 0
    let minLead = 0.030, leadTarget = 0.034

    // stats
    var latSum = 0.0, latMax = 0.0, latN = 0, lastPresented = 0.0
    var hist = [Int](repeating: 0, count: 6)
    var arrHist = [Int](repeating: 0, count: 6)   // |arrival delta - period| in 4 ms buckets
    var lastTick = 0.0, tickGaps = 0

    init?(layer: CAMetalLayer, shm: UnsafeMutableRawPointer, demoSource: DemoSource? = nil) {
        let core = MetalCore.shared
        let dev = core.device
        device = dev; queue = core.queue; self.layer = layer
        for blend in [false, true] { _ = core.pipeline("layerFrag", .rgb10a2Unorm, blend: blend) }   // compile up front, not on the first frame
        for i in 0..<shmSlots {
            guard let b = dev.makeBuffer(bytesNoCopy: shm + i * shmSlotBytes, length: shmSlotBytes, options: .storageModeShared, deallocator: demoSource.map { source in { _, _ in _ = source } }) else { log("no-copy buffer failed"); return nil }
            slotBuffers.append(b)
        }
        super.init()
        layer.device = dev
        layer.pixelFormat = .rgb10a2Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.backgroundColor = NSColor.black.cgColor
        applyColor()
    }

    func attachDisplayLink(view: NSView) {
        displayLink?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func applyColor() {
        switch colorMode {
        case .pq:
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            layer.wantsExtendedDynamicRangeContent = true
            layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 10000)
        case .hlg:
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            layer.wantsExtendedDynamicRangeContent = true
            layer.edrMetadata = CAEDRMetadata.hlg
        case .sdr:
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            layer.wantsExtendedDynamicRangeContent = false
            layer.edrMetadata = nil
        }
    }

    func shmTextures(slot: Int, w: Int, h: Int) -> (MTLTexture, MTLTexture)? {
        let key = slot << 40 | w << 20 | h
        if let t = shmTextures[key] { return t }
        let yd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
        yd.usage = .shaderRead; yd.storageMode = .shared
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: w / 2, height: h / 2, mipmapped: false)
        cd.usage = .shaderRead; cd.storageMode = .shared
        guard let y = slotBuffers[slot].makeTexture(descriptor: yd, offset: 0, bytesPerRow: w * 2),
              let c = slotBuffers[slot].makeTexture(descriptor: cd, offset: w * h * 2, bytesPerRow: w * 2) else { return nil }
        shmTextures[key] = (y, c); return (y, c)
    }

    /// Reader thread, the only writer of `ring`, `ringW` and `ringH`; it reads them without the lock. `tick` reads them
    /// on the main thread, so the new ring is built outside the lock and swapped in under it together with its size.
    /// A partial ring (allocation failed) stops `submit` until the next frame retries.
    func ensureRing(w: Int, h: Int) {
        if ringW == w && ringH == h && ring.count == Renderer.ringSize { return }
        var fresh: [(MTLTexture, MTLTexture)] = []
        for _ in 0..<Renderer.ringSize {
            let yd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
            yd.usage = .shaderRead; yd.storageMode = .private
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: w / 2, height: h / 2, mipmapped: false)
            cd.usage = .shaderRead; cd.storageMode = .private
            guard let y = device.makeTexture(descriptor: yd), let c = device.makeTexture(descriptor: cd) else { break }
            fresh.append((y, c))
        }
        lock.lock(); ring = fresh; ringW = w; ringH = h; pending.removeAll(); lock.unlock()
        ringNext = 0
    }

    func resetPacing() { lock.lock(); grid0 = 0; nextTarget = 0; lastTarget = 0; period = 0; lastArrival = 0; pending.removeAll(); gameQueued = 0; lock.unlock() }

    /// Reader thread: copy the shared-memory slot into the ring on the GPU and schedule it. Never blocks on drawables.
    func submit(slot: Int, w: Int, h: Int, arrivalNs: UInt64) {
        guard let (sy, sc) = shmTextures(slot: slot, w: w, h: h) else { return }
        let a = Double(arrivalNs) / 1e9
        if presentation == .immediate { drawNow(y: sy, c: sc, w: w, h: h, arrival: a); return }
        if presentation == .game { gameSubmit(y: sy, c: sc, w: w, h: h, arrival: a); return }
        ensureRing(w: w, h: h)
        guard ring.count == Renderer.ringSize, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        let idx = ringNext; ringNext = (ringNext + 1) % Renderer.ringSize
        blit.copy(from: sy, to: ring[idx].0); blit.copy(from: sc, to: ring[idx].1)
        blit.endEncoding(); cb.commit()

        lock.lock(); defer { lock.unlock() }
        if lastArrival > 0 { let d = a - lastArrival; if d > 0.002 && d < 0.5 { if period > 0 { arrHist[min(5, Int(abs(d - period) / 0.004))] += 1 }; period = period == 0 ? d : period * 0.9 + d * 0.1 } }
        lastArrival = a
        // Schedule from THIS frame's arrival, snapped to the vsync grid. Arrival jitter is <4 ms, so a direct
        // snap gives an even cadence with no accumulator that can run away. Monotonic guard keeps frames on
        // distinct vsyncs; if the schedule ever falls too far behind wall time, it re-bases on arrival.
        var t: Double
        if grid0 == 0 {
            t = a
        } else {
            t = grid0 + ((a + leadTarget - grid0) / refresh).rounded() * refresh
            if t <= lastTarget + refresh * 0.5 { t = lastTarget + refresh; slips += 1 }   // collision: next vsync
            if t < a { t = grid0 + ((a + leadTarget - grid0) / refresh).rounded(.up) * refresh }  // never in the past
        }
        lastTarget = t
        pending.append(Queued(ring: idx, target: t, arrival: a))
        while pending.count > Renderer.ringSize - 2 { pending.removeFirst(); pacingDrops += 1 }
    }

    /// Game mode, reader thread. Presented handlers only adjust the counter: they run under a Core Animation lock,
    /// and arrive a refresh or two late, so they must not gate or trigger drawing.
    func gameSubmit(y: MTLTexture, c: MTLTexture, w: Int, h: Int, arrival: Double) {
        lock.lock()
        if gameQueued >= 3 { pacingDrops += 1; lock.unlock(); return }
        gameQueued += 1
        lock.unlock()
        let ok = drawNow(y: y, c: c, w: w, h: h, arrival: arrival, onPresented: { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.gameQueued = max(0, self.gameQueued - 1); self.lock.unlock()
        })
        if !ok { lock.lock(); gameQueued = max(0, gameQueued - 1); lock.unlock() }
    }

    /// Display link (main thread), once per vsync: present the frame due at this vsync, if any.
    @objc func tick(_ link: CADisplayLink) {
        let T = link.targetTimestamp
        lock.lock()
        if lastTick > 0 && T - lastTick > refresh * 1.5 { tickGaps += 1 }; lastTick = T
        refresh = max(1.0 / 240, link.targetTimestamp - link.timestamp)
        if grid0 == 0 { grid0 = T }
        if presentation == .game { lock.unlock(); return }
        var chosen: Queued? = nil
        while let f = pending.first, f.target <= T + refresh * 0.5 {
            if chosen != nil { pacingDrops += 1 }
            chosen = f; pending.removeFirst()
        }
        // The reader thread may swap in a new ring at any time: take the textures and their size together.
        let frame = chosen.flatMap { f in f.ring < ring.count ? (ring[f.ring], ringW, ringH, f.arrival) : nil }
        lock.unlock()
        guard let (tex, w, h, arrival) = frame else { return }
        drawNow(y: tex.0, c: tex.1, w: w, h: h, arrival: arrival)
    }

    @discardableResult
    func drawNow(y yT: MTLTexture, c cT: MTLTexture, w gw: Int, h gh: Int, arrival: Double, onPresented: (() -> Void)? = nil) -> Bool {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let live = drawState(y: yT, c: cT, w: gw, h: gh)
        let (w, h) = live.canvas == .wide ? (16, 9) : (9, 16)   // the letterbox fits the canvas, not the game
        let scale = min(dw / Double(w), dh / Double(h))
        // Whole pixels: layer edges are anti-aliased, so a letterbox at a half-pixel offset would blend the game's
        // outermost rows with the background. Aligned, the game also takes encodeLayers' opaque path.
        let vw = (Double(w) * scale).rounded(), vh = (Double(h) * scale).rounded()
        // Game passes through untouched in its own encoding; only the facecam is converted into it.
        let ov = live.overlay, transfer = colorMode.transfer
        var sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: gw, height: gh))]
        var textures: [SourceKey: LayerTextures.Kind] = [.game: .biplanar(y: yT, c: cT, bits: 10, transfer: transfer, bt709: transfer == 2)]
        var keep: [CVMetalTexture] = []
        if let pb = ov.camera?.latest, let p = MetalCore.shared.planes(pb) {
            keep = p.2
            sources[.camera] = SourceInfo(size: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
            textures[.camera] = .biplanar(y: p.0, c: p.1, bits: p.3, transfer: 2, bt709: true)
        }
        let canvas = CGSize(width: vw, height: vh)
        // The frame's capture time, as program outputs use it, so window and stream show the same transition frame.
        let frame = live.scene.frame(canvas: live.canvas, size: canvas, sources: sources, atNs: UInt64(max(0, arrival) * 1e9))
        MetalCore.shared.encodeLayers(cb, target: drawable.texture,
                                      viewport: MTLViewport(originX: ((dw - vw) / 2).rounded(.down), originY: ((dh - vh) / 2).rounded(.down), width: vw, height: vh, znear: 0, zfar: 1),
                                      canvas: canvas, background: frame.background, outTransfer: transfer,
                                      layers: DrawLayer.pair(frame.layers, textures))
        if !keep.isEmpty { cb.addCompletedHandler { _ in _ = keep } }
        drawable.addPresentedHandler { [weak self] d in
            defer { onPresented?() }
            guard let self = self, d.presentedTime > 0 else { return }
            self.lock.lock()
            let lat = d.presentedTime - arrival
            self.latSum += lat; self.latMax = max(self.latMax, lat); self.latN += 1
            if self.lastPresented > 0 { let r = Int(((d.presentedTime - self.lastPresented) / self.refresh).rounded()); self.hist[min(max(r, 0), 5)] += 1 }
            self.lastPresented = d.presentedTime
            self.lock.unlock()
        }
        cb.present(drawable)
        cb.commit()
        return true
    }

    /// One lock for everything a frame reads; also remembers the frame for scene thumbnails.
    private func drawState(y: MTLTexture, c: MTLTexture, w: Int, h: Int) -> (overlay: LiveOverlay, scene: LiveSceneState, canvas: Canvas) {
        lock.lock(); defer { lock.unlock() }
        _lastGame = LiveGameFrame(y: y, c: c, size: CGSize(width: w, height: h), transfer: colorMode.transfer)
        return (_overlay, _scene, _viewCanvas)
    }

    /// The live scene's picture for any canvas at host time `atNs`. Program outputs (plan 20) call this from their own
    /// queue with the game frame's host time and their own canvas size, so the stream shows the same scene and the
    /// same transition frame as the window. `sources` are the pixel sizes of the sources that have a frame. Cheap
    /// (a locked copy, then pure maths), never blocks.
    func sceneFrame(canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo], atNs: UInt64) -> SceneFrame {
        scene.frame(canvas: canvas, size: size, sources: sources, atNs: atNs)
    }

    /// The game frame drawn last, for thumbnails. In Smooth mode it is a ring texture and otherwise shared memory, so
    /// a later frame may overwrite it while a thumbnail reads it; that only ever tears a 160-pixel thumbnail.
    var latestGameFrame: LiveGameFrame? { lock.lock(); defer { lock.unlock() }; return _lastGame }

    func takeStats() -> (avgMs: Double, maxMs: Double, n: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (latN > 0 ? latSum / Double(latN) * 1000 : 0, latMax * 1000, latN)
        log(String(format: "pacing [%@] (refresh units 0..5+): %@  k=%d period=%.2f ms refresh=%.2f ms slips=%d drops=%d queue=%d  arrival-jitter(4ms buckets)=%@ tickGaps=%d", presentation.rawValue, hist.description, period > 0 ? Int((period / refresh).rounded()) : 0, period * 1000, refresh * 1000, slips, pacingDrops, pending.count, arrHist.description, tickGaps))
        slips = 0; pacingDrops = 0; arrHist = [Int](repeating: 0, count: 6); tickGaps = 0
        latSum = 0; latMax = 0; latN = 0; hist = [Int](repeating: 0, count: 6)
        return r
    }
}
