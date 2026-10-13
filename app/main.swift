// Elgato HDR — slim native macOS viewer/recorder for the Elgato 4K X hidden P010 (10-bit HDR) mode.
// Low-latency build: frames arrive in shared memory from the root helper, are rendered by Metal straight from
// that memory (no copies), and presented without waiting for vsync.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

let socketPath = "/tmp/elgato-uvc.sock"
let shmName = "/elgato-uvc-frames"
let shmSlots = 3
let shmSlotBytes = 24883200

enum ColorMode: String { case pq, hlg, sdr }
/// smooth: frames paced onto an even vsync grid (adds a ~34 ms cushion). game: drawn on arrival, shown at the next
/// vsync (no tearing). immediate: drawn on arrival without vsync (lowest latency, can tear in full screen).
enum Presentation: String { case smooth, game, immediate }
struct Mode { let name: String; let frame: Int; let fps: Double }
let modes: [Mode] = [
    Mode(name: "4K 30", frame: 5, fps: 30),
    Mode(name: "1440p 60", frame: 4, fps: 60),
    Mode(name: "2560×1080 60", frame: 3, fps: 60),
    Mode(name: "1080p 120", frame: 2, fps: 120),
    Mode(name: "1080p 60", frame: 2, fps: 60),
    Mode(name: "1080p 30", frame: 2, fps: 30),
    Mode(name: "720p 120", frame: 1, fps: 120),
]

/// Also kept in ~/Library/Logs/Elgato HDR.log so a normal (Finder) launch can be diagnosed.
let logFile: FileHandle? = {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Elgato HDR.log")
    if (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map({ $0 > 5_000_000 }) ?? true {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: url); h?.seekToEndOfFile(); return h
}()
func log(_ s: String) {
    let d = (s + "\n").data(using: .utf8)!
    FileHandle.standardError.write(d); logFile?.write(d)
}

func readFully(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Bool {
    var got = 0
    while got < n {
        let r = read(fd, p + got, n - got)
        if r == 0 { return false }
        if r < 0 { if errno == EINTR { continue }; return false }
        got += r
    }
    return true
}

// MARK: - Helper process management

func connectHelper() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, socketPath, 103) }
    }
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if r != 0 { close(fd); return -1 }
    var sz: Int32 = 1 << 20
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func spawnHelperWithAdminPrompt() -> Bool {
    guard let helper = Bundle.main.url(forResource: "uvc_capture", withExtension: nil, subdirectory: nil)?.path
        ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("uvc_capture").path else { return false }
    let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let shell = "\(quoted) --serve \(socketPath) --idle 20 >/dev/null 2>>/tmp/elgato-uvc.log &"
    let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err = err { log("admin launch failed: \(err)"); return false }
    return true
}

func mapSharedFrames() -> UnsafeMutableRawPointer? {
    // shm_open is variadic (unavailable to Swift); without O_CREAT the mode argument is ignored, so a 2-arg call is safe.
    typealias ShmOpen2 = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "shm_open") else { return nil }
    let shmOpen = unsafeBitCast(sym, to: ShmOpen2.self)
    let fd = shmOpen(shmName, O_RDWR)
    if fd < 0 { return nil }
    defer { close(fd) }
    let total = shmSlots * shmSlotBytes
    let p = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    return p == MAP_FAILED ? nil : p
}

// MARK: - Live renderer (P010 -> PQ/HLG/709 RGB, zero-copy from shared memory, facecam composited on top)

/// What the live view draws over the game: the facecam window as positioned by the user.
struct LiveOverlay {
    var camera: CameraCapture?
    var placement = CameraPlacement()
    var mirror = false
}

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

    init?(layer: CAMetalLayer, shm: UnsafeMutableRawPointer) {
        let core = MetalCore.shared
        let dev = core.device
        device = dev; queue = core.queue; self.layer = layer
        _ = core.pipeline("compositeFrag", .rgb10a2Unorm)   // compile up front, not on the first frame
        for i in 0..<shmSlots {
            guard let b = dev.makeBuffer(bytesNoCopy: shm + i * shmSlotBytes, length: shmSlotBytes, options: .storageModeShared, deallocator: nil) else { log("no-copy buffer failed"); return nil }
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

    func ensureRing(w: Int, h: Int) {
        if ringW == w && ringH == h && ring.count == Renderer.ringSize { return }
        ring = []
        for _ in 0..<Renderer.ringSize {
            let yd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
            yd.usage = .shaderRead; yd.storageMode = .private
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: w / 2, height: h / 2, mipmapped: false)
            cd.usage = .shaderRead; cd.storageMode = .private
            guard let y = device.makeTexture(descriptor: yd), let c = device.makeTexture(descriptor: cd) else { return }
            ring.append((y, c))
        }
        ringW = w; ringH = h; ringNext = 0
        lock.lock(); pending.removeAll(); lock.unlock()
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
        lock.unlock()
        guard let f = chosen, f.ring < ring.count else { return }
        drawNow(y: ring[f.ring].0, c: ring[f.ring].1, w: ringW, h: ringH, arrival: f.arrival)
    }

    @discardableResult
    func drawNow(y yT: MTLTexture, c cT: MTLTexture, w: Int, h: Int, arrival: Double, onPresented: (() -> Void)? = nil) -> Bool {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let scale = min(dw / Double(w), dh / Double(h))
        let vw = Double(w) * scale, vh = Double(h) * scale
        // Game passes through untouched in its own encoding; only the facecam is converted into it.
        let ov = overlay
        var cam: (MTLTexture, MTLTexture)?, camSize: CGSize?, keep: [CVMetalTexture] = [], camBits: Int32 = 8
        if let pb = ov.camera?.latest, let p = MetalCore.shared.planes(pb) {
            cam = (p.0, p.1); keep = p.2; camBits = p.3
            camSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        }
        var params = LayoutMath.params(layout: CanvasLayout(kind: .pip, camera: ov.placement), canvas: CGSize(width: vw, height: vh),
                                       screen: CGSize(width: w, height: h), camera: camSize, mirror: ov.mirror,
                                       screenTransfer: colorMode.transfer, outTransfer: colorMode.transfer)
        params.fmt.z = 10; params.fmt.w = camBits
        MetalCore.shared.encodeComposite(cb, target: drawable.texture,
                                         viewport: MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2, width: vw, height: vh, znear: 0, zfar: 1),
                                         screen: (yT, cT), camera: cam, params: params)
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

    func takeStats() -> (avgMs: Double, maxMs: Double, n: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (latN > 0 ? latSum / Double(latN) * 1000 : 0, latMax * 1000, latN)
        log(String(format: "pacing [%@] (refresh units 0..5+): %@  k=%d period=%.2f ms refresh=%.2f ms slips=%d drops=%d queue=%d  arrival-jitter(4ms buckets)=%@ tickGaps=%d", presentation.rawValue, hist.description, period > 0 ? Int((period / refresh).rounded()) : 0, period * 1000, refresh * 1000, slips, pacingDrops, pending.count, arrHist.description, tickGaps))
        slips = 0; pacingDrops = 0; arrHist = [Int](repeating: 0, count: 6); tickGaps = 0
        latSum = 0; latMax = 0; latN = 0; hist = [Int](repeating: 0, count: 6)
        return r
    }
}

/// The live view. Besides hosting the Metal layer it lets you place the facecam directly: drag to move (snaps to
/// corners and edges), drag a corner or scroll/pinch to resize.
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    let outline = CAShapeLayer()
    var videoSize = CGSize(width: 16, height: 9)
    /// Current facecam placement, or nil when no camera is shown.
    var placement: (() -> CameraPlacement?)?
    var onPlacement: ((CameraPlacement) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private enum Drag { case move(CGPoint, CameraPlacement), resize(CameraPlacement) }
    private var drag: Drag?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer = metalLayer; layerContentsRedrawPolicy = .never
        outline.fillColor = nil; outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1.5; outline.lineDashPattern = [6, 4]; outline.isHidden = true
        outline.shadowColor = NSColor.black.cgColor; outline.shadowOpacity = 0.6; outline.shadowRadius = 2; outline.shadowOffset = .zero
        metalLayer.addSublayer(outline)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateDrawableSize(); updateOutline() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    func updateDrawableSize() {
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// The game picture inside the view (points, AppKit coordinates).
    var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let s = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * s, h = videoSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
    /// View point -> canvas point (top-left origin, in points).
    private func canvasPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil), v = videoRect
        return CGPoint(x: p.x - v.minX, y: v.maxY - p.y)
    }
    private func camRect() -> CGRect? { placement?().map { $0.rect(in: videoRect.size) } }
    private func cornerHit(_ p: CGPoint, _ r: CGRect) -> Bool {
        let k: CGFloat = 14
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .contains { abs($0.x - p.x) < k && abs($0.y - p.y) < k }
    }

    func updateOutline() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard (hovering || drag != nil), let pl = placement?(), let r = camRect() else { outline.isHidden = true; return }
        let v = videoRect
        let viewRect = CGRect(x: v.minX + r.minX, y: v.maxY - r.maxY, width: r.width, height: r.height)
        let rad = pl.radius(for: r)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: viewRect.insetBy(dx: -3, dy: -3), cornerWidth: rad + 3, cornerHeight: rad + 3, transform: nil)
        outline.isHidden = false
    }

    override func mouseMoved(with e: NSEvent) {
        let p = canvasPoint(e)
        let r = camRect()
        let inside = r.map { $0.insetBy(dx: -8, dy: -8).contains(p) } ?? false
        if inside != hovering { hovering = inside; updateOutline() }
        if let r = r, cornerHit(p, r) { NSCursor.crosshair.set() } else if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with e: NSEvent) { hovering = false; updateOutline(); NSCursor.arrow.set() }

    override func mouseDown(with e: NSEvent) {
        let p = canvasPoint(e)
        guard let pl = placement?(), let r = camRect() else { super.mouseDown(with: e); return }
        if e.clickCount == 2, r.contains(p) { return }
        if cornerHit(p, r) { drag = .resize(pl) }
        else if r.insetBy(dx: -8, dy: -8).contains(p) { drag = .move(CGPoint(x: p.x - r.midX, y: p.y - r.midY), pl); NSCursor.closedHand.set() }
        else { super.mouseDown(with: e) }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let p = canvasPoint(e), canvas = videoRect.size
        switch d {
        case .move(let grab, var pl):
            pl.move(to: CGPoint(x: p.x - grab.x, y: p.y - grab.y), canvas: canvas, snap: !e.modifierFlags.contains(.option))
            onPlacement?(pl)
        case .resize(var pl):
            let r = pl.rect(in: canvas)
            // Window size follows the pointer's distance from the centre (keeps the centre fixed).
            let a = pl.aspect.value
            let halfShort = max(abs(p.x - r.midX) / (a >= 1 ? a : 1), abs(p.y - r.midY) * (a >= 1 ? 1 : a))
            pl.size = min(1, max(0.08, Double(2 * halfShort / min(canvas.width, canvas.height))))
            onPlacement?(pl)
        }
        updateOutline()
    }
    override func mouseUp(with e: NSEvent) { if drag != nil { drag = nil; NSCursor.openHand.set(); updateOutline() } }

    override func scrollWheel(with e: NSEvent) {
        guard var pl = placement?(), let r = camRect(), r.contains(canvasPoint(e)) else { super.scrollWheel(with: e); return }
        pl.size = min(1, max(0.08, pl.size * exp(Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04))))
        onPlacement?(pl); updateOutline()
    }
    override func magnify(with e: NSEvent) {
        guard var pl = placement?() else { return }
        pl.size = min(1, max(0.08, pl.size * (1 + Double(e.magnification))))
        onPlacement?(pl); updateOutline()
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }
}

// MARK: - Audio playback

/// All AVAudioEngine / player-node mutation happens on `engineQueue`. The main thread never touches
/// AVFAudio teardown, so an output-device change cannot block it (and thus cannot freeze the display).
final class AudioPlayer {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let engineQueue = DispatchQueue(label: "audio-engine")
    var queuedFrames: Int = 0
    let maxQueuedFrames = 48000 * 150 / 1000   // trim above 150 ms of backlog
    let lock = NSLock()
    var _muted = false
    var muted: Bool {
        get { _muted }
        set { _muted = newValue; let v: Float = newValue ? 0 : 1; engineQueue.async { [self] in engine.mainMixerNode.outputVolume = v } }
    }
    var running = false
    var rebuildGen = 0
    var pushed = 0, dropped = 0; var lastStat = Date()

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // queue nil => block runs on the notifying thread; we only redispatch, so it never blocks anyone.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.rebuild(reason: "device/format change")
        }
    }

    /// Bring the engine up (idempotent). Runs on engineQueue.
    private func startLocked() {
        if running && engine.isRunning { return }
        do {
            try engine.start()
            if !player.isPlaying { player.play() }
            engine.mainMixerNode.outputVolume = _muted ? 0 : 1
            running = true
        } catch { log("audio engine start failed: \(error)"); running = false }
    }
    func ensureStarted() { engineQueue.async { [self] in startLocked() } }

    /// Rebuild the graph for the new output device. Never called on the main thread's critical path.
    func rebuild(reason: String) {
        rebuildGen += 1; let gen = rebuildGen
        engineQueue.async { [self] in
            guard gen == rebuildGen else { return }   // collapse a burst of change notifications
            player.stop(); engine.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            lock.lock(); queuedFrames = 0; lock.unlock()
            startLocked()
            log("audio engine rebuilt (\(reason)) on \(engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
        }
    }

    func stop() { engineQueue.async { [self] in player.stop(); engine.stop(); running = false } }

    /// Interleaved signed 16-bit stereo, 48 kHz. Called on the reader thread.
    func push(_ bytes: UnsafeRawPointer, _ count: Int) {
        ensureStarted()
        let frames = count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        lock.lock(); let backlog = queuedFrames; lock.unlock()
        pushed += 1
        if Date().timeIntervalSince(lastStat) >= 5 { log(String(format: "audio: %d chunks, %d dropped, backlog %.0f ms", pushed, dropped, Double(backlog) / 48.0)); lastStat = Date() }
        if backlog > maxQueuedFrames { dropped += 1; return }
        buf.frameLength = AVAudioFrameCount(frames)
        let src = bytes.assumingMemoryBound(to: Int16.self)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        let scale: Float = 1.0 / 32768.0
        for i in 0..<frames { l[i] = Float(Int16(littleEndian: src[2*i])) * scale; r[i] = Float(Int16(littleEndian: src[2*i+1])) * scale }
        // Schedule on engineQueue so buffer scheduling never races with a rebuild's stop/reconnect.
        engineQueue.async { [self] in
            guard running, engine.isRunning else { return }
            lock.lock(); queuedFrames += frames; lock.unlock()
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock(); self.queuedFrames -= frames; self.lock.unlock()   // counter only; no transport calls
            }
        }
    }
}

// MARK: - HDR recording (HEVC Main10 + HDR10 metadata, AAC audio)

final class Recorder {
    let url: URL
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: AVAssetWriterInput
    let audioFormat: CMAudioFormatDescription
    let queue = DispatchQueue(label: "recorder")
    let startNs: UInt64
    var sessionStarted = false
    var audioAnchor: Double = -1     // seconds (recording time) of the first audio sample written
    var audioSamplesWritten: Int64 = 0
    var videoFrames = 0, droppedVideo = 0, dupFrames = 0, gapFrames = 0
    var finished = false
    let fps: Double
    let frameDur: Int64          // in 60000 units
    var lastIndex: Int64 = -1
    var slewSamples = 0

    static func hdr10Metadata() -> (Data, Data) {
        // Mastering display (SEI order G,B,R then white point; 0.00002 units), luminance 1000 / 0.005 nits (0.0001 units)
        var m = Data()
        func u16(_ v: UInt16) { m.append(UInt8(v >> 8)); m.append(UInt8(v & 0xff)) }
        func u32(_ v: UInt32) { m.append(UInt8(v >> 24)); m.append(UInt8((v >> 16) & 0xff)); m.append(UInt8((v >> 8) & 0xff)); m.append(UInt8(v & 0xff)) }
        u16(13250); u16(34500); u16(7500); u16(3000); u16(34000); u16(16000); u16(15635); u16(16450); u32(10_000_000); u32(50)
        var c = Data(); c.append(contentsOf: [UInt8(1000 >> 8), UInt8(1000 & 0xff), UInt8(400 >> 8), UInt8(400 & 0xff)])
        return (m, c)
    }

    init(url: URL, width: Int, height: Int, fps: Double, colorMode: ColorMode, startNs: UInt64) throws {
        self.url = url; self.startNs = startNs
        self.fps = fps
        frameDur = Int64((60000.0 / fps).rounded())   // 30 -> 2000, 29.97 -> 2002, 60 -> 1000, 120 -> 500
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let (prim, tf, mat): (String, String, String)
        switch colorMode {
        case .pq:  (prim, tf, mat) = (AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunction_SMPTE_ST_2084_PQ, AVVideoYCbCrMatrix_ITU_R_2020)
        case .hlg: (prim, tf, mat) = (AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrix_ITU_R_2020)
        case .sdr: (prim, tf, mat) = (AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2)
        }
        let bitrate = max(8_000_000, Int(Double(width * height) * fps * 0.15))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if colorMode == .pq {
            let (m, c) = Recorder.hdr10Metadata()
            compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = m
            compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = c
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: prim, AVVideoTransferFunctionKey: tf, AVVideoYCbCrMatrixKey: mat],
            AVVideoCompressionPropertiesKey: compression,
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
        audio.expectsMediaDataInRealTime = true
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        audioFormat = fd!
        guard writer.canAdd(video), writer.canAdd(audio) else { throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot add inputs"]) }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Recorder", code: 2) }
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
        log("recording -> \(url.path) \(width)x\(height) @ \(fps) HEVC10 \(bitrate / 1_000_000) Mbps \(colorMode)")
    }

    func time(_ ns: UInt64) -> Double { ns > startNs ? Double(ns - startNs) / 1e9 : 0 }

    func appendVideo(_ pb: CVPixelBuffer, ns: UInt64) {
        let t = time(ns)
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            // Snap arrival time to the nominal frame grid: removes USB arrival jitter, keeps holes for dropped frames.
            let index = Int64((t * fps).rounded())
            if index <= lastIndex { dupFrames += 1; return }
            if lastIndex >= 0 && index > lastIndex + 1 { gapFrames += Int(index - lastIndex - 1) }
            guard video.isReadyForMoreMediaData else { droppedVideo += 1; return }
            let pts = CMTime(value: index * frameDur, timescale: 60000)
            if adaptor.append(pb, withPresentationTime: pts) { videoFrames += 1; lastIndex = index }
            else { log("video append failed: \(writer.error?.localizedDescription ?? "?")"); droppedVideo += 1 }
        }
    }

    /// Interleaved s16 stereo 48 kHz chunk; `ns` is the time the chunk ended.
    func appendAudio(_ data: Data, ns: UInt64) {
        let frames = data.count / 4
        guard frames > 0 else { return }
        let endT = time(ns), dur = Double(frames) / 48000.0
        queue.async { [self] in
            guard !finished, writer.status == .writing, audio.isReadyForMoreMediaData else { return }
            var d = data, n = frames
            if audioAnchor < 0 {
                var startT = endT - dur
                if startT < 0 { // trim samples that precede the recording start
                    let skip = min(n, Int(-startT * 48000)); d = d.subdata(in: skip * 4 ..< d.count); n -= skip; startT = 0
                }
                guard n > 0 else { return }
                audioAnchor = startT; audioSamplesWritten = 0
            }
            let pts = audioAnchor + Double(audioSamplesWritten) / 48000.0
            // Slew instead of jumping: if the sample clock drifts from arrival time, drop or repeat a few samples
            // spread across this chunk (max 1%), keeping audio continuous and locked to the video clock.
            let expected = endT - Double(n) / 48000.0
            let err = expected - pts                       // > 0: audio is behind (need to drop samples)
            if abs(err) > 0.002 {
                let want = Int((err * 48000).rounded())
                let maxAdj = max(1, n / 100)
                let adj = max(-maxAdj, min(maxAdj, want))
                if adj != 0 {
                    var out = Data(capacity: (n + abs(adj)) * 4)
                    let stride = n / abs(adj)
                    var i = 0, k = 0
                    while i < n {
                        let frame = d.subdata(in: i * 4 ..< i * 4 + 4)
                        if (i + 1) % stride == 0 && k < abs(adj) { k += 1; if adj > 0 { i += 1; continue } else { out.append(frame) } }
                        out.append(frame); i += 1
                    }
                    d = out; n = out.count / 4; slewSamples += adj
                }
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: d.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: d.count, flags: 0, blockBufferOut: &block) == noErr, let bb = block else { return }
            d.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: d.count) }
            var sb: CMSampleBuffer?
            let ptsTime = CMTime(value: CMTimeValue((pts * 48000).rounded()), timescale: 48000)
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: audioFormat, sampleCount: n, presentationTimeStamp: ptsTime, packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let s = sb else { return }
            if audio.append(s) { audioSamplesWritten += Int64(n) } else { log("audio append failed: \(writer.error?.localizedDescription ?? "?")") }
        }
    }

    func finish(_ completion: @escaping (String) -> Void) {
        queue.async { [self] in
            finished = true
            guard writer.status == .writing else { completion("recording failed: \(writer.error?.localizedDescription ?? "unknown")"); return }
            video.markAsFinished(); audio.markAsFinished()
            let frames = videoFrames, dropped = droppedVideo, url = url
            writer.finishWriting {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                completion(String(format: "saved %@ (%d frames, %d dropped, %d gaps, %d dups, audio slew %d samples, %.1f MB)", url.lastPathComponent, frames, dropped, self.gapFrames, self.dupFrames, self.slewSamples, Double(size) / 1e6))
            }
        }
    }
}


// MARK: - Stream session (socket headers + audio, frames via shared memory)

final class Session {
    let fd: Int32
    let renderer: Renderer
    let shm: UnsafeMutableRawPointer
    var w = 0, h = 0, frames = 0
    var lastReport = Date()
    var onInfo: ((String) -> Void)?
    var stopped = false
    var audio: AudioPlayer?
    var recorder: Recorder?
    var lastFrameNs: UInt64 = 0
    var latestSeq: UInt32 = 0
    var audioScratch = [UInt8](repeating: 0, count: 1 << 16)
    var pool: CVPixelBufferPool?
    let copyQueue = DispatchQueue(label: "record-copy")
    var tWait = 0.0, tDraw = 0.0, tDrawMax = 0.0

    init(fd: Int32, renderer: Renderer, shm: UnsafeMutableRawPointer) { self.fd = fd; self.renderer = renderer; self.shm = shm }
    func stop() { stopped = true; shutdown(fd, SHUT_RDWR); close(fd) }

    func makePool(w: Int, h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    /// Copy a shared-memory slot into a pixel buffer for the encoder (only while recording).
    func copyForRecording(slot: Int, seq: UInt32, w: Int, h: Int, ns: UInt64, colorMode: ColorMode) {
        guard let rec = recorder else { return }
        copyQueue.async { [self] in
            if pool == nil { makePool(w: w, h: h) }
            var pbOpt: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!, [kCVPixelBufferPoolAllocationThresholdKey as String: 16] as CFDictionary, &pbOpt)
            guard let pb = pbOpt else { return }
            let src = shm + slot * shmSlotBytes
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let row = w * 2
            if ys == row { memcpy(y, src, row * h) } else { for r in 0..<h { memcpy(y + r * ys, src + r * row, row) } }
            let csrc = src + row * h
            if cs == row { memcpy(c, csrc, row * (h / 2)) } else { for r in 0..<(h / 2) { memcpy(c + r * cs, csrc + r * row, row) } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if latestSeq &- seq >= UInt32(shmSlots) { return } // slot was overwritten mid-copy; drop
            let (prim, tf, mat): (CFString, CFString, CFString)
            switch colorMode {
            case .pq:  (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            case .hlg: (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            case .sdr: (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
            rec.appendVideo(pb, ns: ns)
        }
    }

    func run() {
        var hdr = [UInt8](repeating: 0, count: 32)
        while !stopped {
            let t0 = CFAbsoluteTimeGetCurrent()
            guard hdr.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, 32) }) else { break }
            tWait += CFAbsoluteTimeGetCurrent() - t0
            guard hdr[0] == 0x55, hdr[1] == 0x56, hdr[2] == 0x43 else { log("bad stream magic"); break }
            func u32(_ o: Int) -> Int { Int(hdr[o]) | Int(hdr[o+1]) << 8 | Int(hdr[o+2]) << 16 | Int(hdr[o+3]) << 24 }
            let a = u32(4), b = u32(8), size = u32(16), seq = UInt32(truncatingIfNeeded: u32(28))
            let tNs = hdr[20..<28].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            switch hdr[3] {
            case 0x41: // "UVCA" audio chunk
                if size > audioScratch.count { audioScratch = [UInt8](repeating: 0, count: size) }
                guard audioScratch.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, size) }) else { return finish() }
                if a == 48000, b == 2, u32(12) == 16 {
                    if let rec = recorder { rec.appendAudio(Data(audioScratch[0..<size]), ns: tNs) }
                    audioScratch.withUnsafeBytes { audio?.push($0.baseAddress!, size) }
                }
            case 0x53: // "UVCS" frame in shared memory slot seq % 3
                guard size == a * b * 3, size <= shmSlotBytes else { log("unexpected frame size"); return finish() }
                if a != w || b != h { w = a; h = b; pool = nil; onInfo?("\(w)x\(h) P010") }
                latestSeq = seq; lastFrameNs = tNs
                let slot = Int(seq % UInt32(shmSlots))
                let t1 = CFAbsoluteTimeGetCurrent()
                renderer.submit(slot: slot, w: w, h: h, arrivalNs: tNs)
                let dd = CFAbsoluteTimeGetCurrent() - t1; tDraw += dd; tDrawMax = max(tDrawMax, dd)
                if recorder != nil { copyForRecording(slot: slot, seq: seq, w: w, h: h, ns: tNs, colorMode: renderer.colorMode) }
                frames += 1
            case 0x46: // "UVCF" inline frame: helper without shared memory; skip payload
                var junk = [UInt8](repeating: 0, count: size)
                guard junk.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, size) }) else { return finish() }
                if frames == 0 { log("helper is streaming inline frames (old helper?)"); onInfo?("helper too old: restart helper") }
            default: log("unknown chunk"); return finish()
            }
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 1 {
                let dt = now.timeIntervalSince(lastReport)
                let fps = Double(frames) / dt
                let (avg, mx, n) = renderer.takeStats()
                log(String(format: "video: %.1f fps  helper->screen %.1f ms avg / %.1f max (%d)  wait %.0f ms  draw %.1f ms/frame (max %.1f)", fps, avg, mx, n, tWait * 1000, frames > 0 ? tDraw * 1000 / Double(frames) : 0, tDrawMax * 1000))
                onInfo?(String(format: "%dx%d 10-bit  %.1f fps  •  %.0f ms to screen", w, h, fps, avg))
                frames = 0; lastReport = now; tWait = 0; tDraw = 0; tDrawMax = 0
            }
        }
        finish()
    }
    func finish() { if !stopped { close(fd); onInfo?("stream ended") } }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: MetalView!
    var renderer: Renderer!
    var shm: UnsafeMutableRawPointer?
    var session: Session?
    var modeIndex = min(max(UserDefaults.standard.integer(forKey: "mode"), 0), modes.count - 1)   // also accepts `-mode N` on the command line
    var colorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "color") ?? "pq") ?? .pq
    var presentation = Presentation(rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "lowLatency") ? .immediate : .smooth)
    var modeItems: [NSMenuItem] = [], colorItems: [NSMenuItem] = []
    let audio = AudioPlayer()
    var muteItem: NSMenuItem!, recordItem: NSMenuItem!
    var presentationItems: [NSMenuItem] = []
    var recorder: Recorder?
    var recStart = Date()
    var recTimer: Timer?
    var measuredFps: Double = 30
    var lastInfo = ""

    // Facecam + microphone layers
    let camera = CameraCapture()
    var cameraMenu = NSMenu(title: "Camera")
    var cameraID = UserDefaults.standard.string(forKey: "cameraID")
    var micID = UserDefaults.standard.string(forKey: "micID")
    var cameraMirror = UserDefaults.standard.bool(forKey: "cameraMirror")
    var livePlacement: CameraPlacement = {
        if let d = UserDefaults.standard.data(forKey: "livePlacement"), let p = try? JSONDecoder().decode(CameraPlacement.self, from: d) { return p }
        return CameraPlacement()
    }()
    var recDoc: ProjectDoc?
    var camWriter: LayerWriter?, micWriter: LayerWriter?
    static var activeRecordingDir: URL?
    static func isRecording(_ dir: URL) -> Bool { activeRecordingDir == dir }
    var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        view = MetalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        audio.muted = UserDefaults.standard.bool(forKey: "muted")
        // Development: `--export <project folder> [hdr|sdr] [hd|uhd]` renders both canvases and quits (no capture).
        if let i = CommandLine.arguments.firstIndex(of: "--export"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            runHeadlessExport(dir: URL(fileURLWithPath: args[i + 1]), range: args.contains("sdr") ? .sdr : .hdr, res: args.contains("uhd") ? .uhd : .hd)
            return
        }
        view.placement = { [weak self] in
            guard let self = self, self.camera.cameraOn else { return nil }
            return self.livePlacement
        }
        view.onPlacement = { [weak self] p in self?.setPlacement(p) }
        view.contextMenu = { [weak self] in self?.makeCameraMenu(title: "Camera") }
        buildMenu()
        setTitle("connecting…")
        if CommandLine.arguments.contains("--no-capture") { setTitle("capture off (--no-capture)") } else { start() }
        if cameraID != nil { camera.setCamera(uniqueID: cameraID) { [weak self] e in self?.deviceResult(e) } }
        if micID != nil { camera.setMicrophone(uniqueID: micID) { [weak self] e in self?.deviceResult(e) } }
        if CommandLine.arguments.contains("--fullscreen") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.window.toggleFullScreen(nil) } }
        if CommandLine.arguments.contains("--library") { showLibrary() }
        #if DEBUG
        DebugSnapshots.start()
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count, let secs = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.startRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self?.stopRecording() }
            }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Elgato HDR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard Edit menu so text fields (rename, search) get copy/paste/undo.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let modeItem = NSMenuItem(); main.addItem(modeItem)
        let modeMenu = NSMenu(title: "Input")
        for (i, m) in modes.enumerated() {
            let it = NSMenuItem(title: m.name, action: #selector(selectMode(_:)), keyEquivalent: i < 9 ? "\(i+1)" : "")
            it.tag = i; modeMenu.addItem(it); modeItems.append(it)
        }
        modeItem.submenu = modeMenu

        let colorItem = NSMenuItem(); main.addItem(colorItem)
        let colorMenu = NSMenu(title: "Color")
        for (name, mode) in [("HDR10 (PQ, BT.2020)", ColorMode.pq), ("HLG (BT.2020)", .hlg), ("SDR (BT.709)", .sdr)] {
            let it = NSMenuItem(title: name, action: #selector(selectColor(_:)), keyEquivalent: "")
            it.representedObject = mode.rawValue; colorMenu.addItem(it); colorItems.append(it)
        }
        colorItem.submenu = colorMenu

        let audioItem = NSMenuItem(); main.addItem(audioItem)
        let audioMenu = NSMenu(title: "Audio")
        muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        audioMenu.addItem(muteItem)
        audioItem.submenu = audioMenu

        let camItem = NSMenuItem(); main.addItem(camItem)
        cameraMenu.delegate = self   // rebuilt on open so device lists stay current
        camItem.submenu = cameraMenu

        let recItem = NSMenuItem(); main.addItem(recItem)
        let recMenu = NSMenu(title: "Record")
        recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recMenu.addItem(recordItem)
        recMenu.addItem(.separator())
        recMenu.addItem(withTitle: "Recordings Library", action: #selector(showLibraryAction), keyEquivalent: "o")
        recMenu.addItem(withTitle: "Show Recordings in Finder", action: #selector(showRecordings), keyEquivalent: "")
        recItem.submenu = recMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Show Live View", action: #selector(showLiveView), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenu.addItem(.separator())
        for (name, p, key) in [("Smooth", Presentation.smooth, "j"), ("Game (low latency, no tearing)", .game, "g"), ("Lowest Latency (may tear)", .immediate, "l")] {
            let it = NSMenuItem(title: name, action: #selector(selectPresentation(_:)), keyEquivalent: key)
            it.representedObject = p.rawValue; viewMenu.addItem(it); presentationItems.append(it)
        }
        viewMenu.addItem(.separator())
        let rc = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"); rc.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(rc)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
        populateCameraMenu(cameraMenu)
        refreshChecks()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === cameraMenu { populateCameraMenu(menu) } }

    func makeCameraMenu(title: String) -> NSMenu { let m = NSMenu(title: title); populateCameraMenu(m); return m }

    /// Camera menu: devices, then the overlay window's look. Also used as the live view's right-click menu.
    func populateCameraMenu(_ m: NSMenu) {
        m.removeAllItems()
        func item(_ title: String, _ sel: Selector, _ key: String = "", on: Bool = false, obj: Any? = nil, enabled: Bool = true) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self; it.state = on ? .on : .off; it.representedObject = obj; it.isEnabled = enabled
            m.addItem(it); return it
        }
        _ = item(camera.cameraOn ? "Hide Camera" : "Show Camera", #selector(toggleCamera), "k")
        m.addItem(.separator())
        let camHeader = NSMenuItem(title: "Camera", action: nil, keyEquivalent: ""); camHeader.isEnabled = false; m.addItem(camHeader)
        let cams = CameraCapture.cameras()
        if cams.isEmpty { _ = item("No cameras found", #selector(noop), enabled: false) }
        for d in cams { _ = item(d.localizedName, #selector(selectCamera(_:)), on: camera.cameraOn && d.uniqueID == cameraID, obj: d.uniqueID) }
        m.addItem(.separator())
        let micHeader = NSMenuItem(title: "Microphone (recorded as its own layer)", action: nil, keyEquivalent: ""); micHeader.isEnabled = false; m.addItem(micHeader)
        _ = item("None", #selector(selectMic(_:)), on: !camera.micOn, obj: "")
        for d in CameraCapture.microphones() { _ = item(d.localizedName, #selector(selectMic(_:)), on: camera.micOn && d.uniqueID == micID, obj: d.uniqueID) }
        m.addItem(.separator())
        let p = livePlacement
        _ = item("Circle", #selector(setShape(_:)), on: p.isCircle, obj: "circle")
        _ = item("Rounded", #selector(setShape(_:)), on: !p.isCircle && p.roundness > 0, obj: "rounded")
        _ = item("Square Corners", #selector(setShape(_:)), on: p.roundness == 0, obj: "square")
        let aspectItem = NSMenuItem(title: "Window Shape", action: nil, keyEquivalent: ""); m.addItem(aspectItem)
        let am = NSMenu()
        for a in CameraAspect.allCases {
            let it = NSMenuItem(title: a.rawValue, action: #selector(setAspect(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = a.rawValue; it.state = p.aspect == a ? .on : .off; am.addItem(it)
        }
        aspectItem.submenu = am
        let posItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: ""); m.addItem(posItem)
        let pm = NSMenu()
        for (name, x, y) in [("Top Left", 0, 0), ("Top", 1, 0), ("Top Right", 2, 0), ("Left", 0, 1), ("Right", 2, 1), ("Bottom Left", 0, 2), ("Bottom", 1, 2), ("Bottom Right", 2, 2)] {
            let it = NSMenuItem(title: name, action: #selector(setPosition(_:)), keyEquivalent: ""); it.target = self
            it.tag = y * 3 + x; pm.addItem(it)
        }
        posItem.submenu = pm
        _ = item("Bigger", #selector(biggerCamera), "=")
        _ = item("Smaller", #selector(smallerCamera), "-")
        m.addItem(.separator())
        _ = item("Mirror", #selector(toggleMirror), on: cameraMirror)
        _ = item("Border", #selector(toggleBorder), on: p.border)
        _ = item("Shadow", #selector(toggleShadow), on: p.shadow)
        m.addItem(.separator())
        _ = item("Drag the camera to move it, drag a corner or scroll to resize", #selector(noop), enabled: false)
    }

    @objc func noop() {}

    /// Camera/mic changes report failures in an alert: the title is rewritten every second by the stream stats.
    func deviceResult(_ error: String?) {
        applyOverlay()
        log("camera: \(camera.cameraName ?? "off"), microphone: \(camera.micName ?? "off")\(error.map { " — \($0)" } ?? "")")
        guard let error = error else { return }
        let a = NSAlert()
        a.messageText = error.prefix(1).uppercased() + error.dropFirst()
        let privacy = error.contains("access denied")
        a.informativeText = privacy ? "Allow Elgato HDR under System Settings › Privacy & Security, then select the device again." : "Try another device, or reconnect it."
        a.addButton(withTitle: "OK")
        if privacy { a.addButton(withTitle: "Open Privacy Settings") }
        if a.runModal() == .alertSecondButtonReturn {
            let pane = error.hasPrefix("camera") ? "Privacy_Camera" : "Privacy_Microphone"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    func applyOverlay() {
        renderer?.overlay = LiveOverlay(camera: camera.cameraOn ? camera : nil, placement: livePlacement, mirror: cameraMirror)
        view.updateOutline()
        setTitle(lastInfo)
    }
    func setPlacement(_ p: CameraPlacement) {
        livePlacement = p
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "livePlacement") }
        applyOverlay()
    }

    @objc func toggleCamera() {
        if camera.cameraOn { camera.setCamera(uniqueID: nil) { [weak self] _ in self?.applyOverlay() }; return }
        let id = cameraID.flatMap { id in CameraCapture.cameras().first { $0.uniqueID == id }?.uniqueID } ?? CameraCapture.cameras().first?.uniqueID
        guard let id = id else { setTitle("no camera found"); return }
        cameraID = id; UserDefaults.standard.set(id, forKey: "cameraID")
        camera.setCamera(uniqueID: id) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func selectCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if recorder != nil { setTitle("stop recording to switch cameras"); return }
        cameraID = id; UserDefaults.standard.set(id, forKey: "cameraID")
        camera.setCamera(uniqueID: id) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func selectMic(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if recorder != nil { setTitle("stop recording to switch microphones"); return }
        micID = id.isEmpty ? nil : id; UserDefaults.standard.set(micID, forKey: "micID")
        log("microphone: selecting \(micID ?? "none")")
        camera.setMicrophone(uniqueID: micID) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func setShape(_ sender: NSMenuItem) {
        var p = livePlacement
        switch sender.representedObject as? String {
        case "circle": p.aspect = .square; p.roundness = 0.5
        case "square": p.roundness = 0
        default: p.roundness = 0.16
        }
        setPlacement(p)
    }
    @objc func setAspect(_ sender: NSMenuItem) {
        guard let a = CameraAspect(rawValue: sender.representedObject as? String ?? "") else { return }
        var p = livePlacement; p.aspect = a
        if a != .square && p.roundness > 0.3 { p.roundness = 0.16 }   // a circle only makes sense on a square window
        setPlacement(p)
    }
    @objc func setPosition(_ sender: NSMenuItem) {
        var p = livePlacement
        let canvas = view.videoRect.size, r = p.rect(in: canvas)
        let anchors = CameraPlacement.anchors(for: r.size, canvas: canvas)   // 8 anchors in row order, centre omitted
        let idx = sender.tag > 4 ? sender.tag - 1 : sender.tag
        if idx < anchors.count { p.move(to: anchors[idx], canvas: canvas, snap: false) }
        setPlacement(p)
    }
    @objc func biggerCamera() { var p = livePlacement; p.size = min(1, p.size * 1.15); setPlacement(p) }
    @objc func smallerCamera() { var p = livePlacement; p.size = max(0.08, p.size / 1.15); setPlacement(p) }
    @objc func toggleMirror() { cameraMirror.toggle(); UserDefaults.standard.set(cameraMirror, forKey: "cameraMirror"); applyOverlay() }
    @objc func toggleBorder() { var p = livePlacement; p.border.toggle(); setPlacement(p) }
    @objc func toggleShadow() { var p = livePlacement; p.shadow.toggle(); setPlacement(p) }

    func refreshChecks() {
        for it in modeItems { it.state = it.tag == modeIndex ? .on : .off }
        for it in colorItems { it.state = (it.representedObject as? String) == colorMode.rawValue ? .on : .off }
        muteItem?.state = audio.muted ? .on : .off
        for it in presentationItems { it.state = (it.representedObject as? String) == presentation.rawValue ? .on : .off }
    }

    func setTitle(_ s: String) {
        lastInfo = s
        var t = "Elgato HDR  •  \(modes[modeIndex].name)  •  \(s)" + (audio.muted ? "  •  muted" : "")
            + (camera.cameraOn ? "  •  cam" : "") + (camera.micOn ? "  •  mic" : "")
        if recorder != nil {
            let e = Int(Date().timeIntervalSince(recStart))
            let layers = ["game"] + (camWriter != nil ? ["cam"] : []) + (micWriter != nil ? ["mic"] : [])
            t = String(format: "● REC %02d:%02d [%@]  •  ", e / 60, e % 60, layers.joined(separator: "+")) + t
        }
        window.title = t
    }

    @objc func selectMode(_ sender: NSMenuItem) { modeIndex = sender.tag; UserDefaults.standard.set(modeIndex, forKey: "mode"); refreshChecks(); start() }
    @objc func selectColor(_ sender: NSMenuItem) {
        colorMode = ColorMode(rawValue: sender.representedObject as! String)!; UserDefaults.standard.set(colorMode.rawValue, forKey: "color")
        refreshChecks(); renderer?.colorMode = colorMode
    }
    @objc func toggleMute() { audio.muted.toggle(); UserDefaults.standard.set(audio.muted, forKey: "muted"); refreshChecks(); setTitle(lastInfo) }
    @objc func selectPresentation(_ sender: NSMenuItem) {
        presentation = Presentation(rawValue: sender.representedObject as! String)!; UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
        refreshChecks(); renderer?.presentation = presentation
    }
    @objc func reconnect() { start() }

    func start() {
        if recorder != nil { stopRecording() }
        session?.stop(); session = nil
        let mode = modes[modeIndex]
        setTitle("connecting…")
        DispatchQueue.global().async { [weak self] in
            var fd = connectHelper()
            if fd < 0 {
                var spawned = false
                DispatchQueue.main.sync { spawned = spawnHelperWithAdminPrompt() }
                if !spawned { DispatchQueue.main.async { self?.setTitle("helper launch cancelled") }; return }
                for _ in 0..<50 { usleep(200_000); fd = connectHelper(); if fd >= 0 { break } }
            }
            guard fd >= 0 else { DispatchQueue.main.async { self?.setTitle("helper not reachable") }; return }
            guard let self = self else { return }
            if self.shm == nil { self.shm = mapSharedFrames() }
            guard let shm = self.shm else { DispatchQueue.main.async { self.setTitle("shared memory unavailable (old helper?)") }; close(fd); return }
            DispatchQueue.main.sync {
                if self.renderer == nil {
                    self.renderer = Renderer(layer: self.view.metalLayer, shm: shm)
                    self.renderer?.colorMode = self.colorMode; self.renderer?.presentation = self.presentation
                    self.view.updateDrawableSize()
                    self.renderer?.attachDisplayLink(view: self.view)
                    self.applyOverlay()
                }
            }
            guard let renderer = self.renderer else { DispatchQueue.main.async { self.setTitle("Metal unavailable") }; close(fd); return }
            let cmd = "START 7 \(mode.frame) \(mode.fps) SHM\n"
            _ = cmd.withCString { write(fd, $0, strlen($0)) }
            renderer.resetPacing()
            let s = Session(fd: fd, renderer: renderer, shm: shm)
            s.audio = self.audio
            s.onInfo = { [weak self] info in DispatchQueue.main.async {
                if let r = info.range(of: #"([0-9.]+) fps"#, options: .regularExpression), let v = Double(info[r].dropLast(4)) { self?.measuredFps = v }
                if let self = self, s.w > 0 {
                    self.window.contentAspectRatio = NSSize(width: s.w, height: s.h)
                    self.view.videoSize = CGSize(width: s.w, height: s.h)
                }
                self?.setTitle(info) } }
            DispatchQueue.main.async { self.session = s; self.setTitle("starting…") }
            s.run()
        }
    }

    static var recordingsDir: URL {
        let d = UserDefaults.standard.string(forKey: "recordingsDir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Elgato HDR")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    @objc func toggleRecording() { if recorder == nil { startRecording() } else { stopRecording() } }
    @objc func showRecordings() { NSWorkspace.shared.open(AppDelegate.recordingsDir) }
    @objc func showLibraryAction() { showLibrary() }

    func showLibrary() {
        if libraryWindow == nil { libraryWindow = makeLibraryWindow() }
        Library.shared.reload()
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    /// Each recording is a project folder with one file per layer, all starting at the same instant:
    /// game.mov (HDR video + game audio), camera.mov (facecam) and mic.m4a (voice), plus project.json.
    func startRecording() {
        guard let s = session, s.w > 0 else { setTitle("not streaming, cannot record"); return }
        let (dir, name) = Library.shared.newProjectDir(date: Date())
        let nominal = modes[modeIndex].fps
        let fps = abs(measuredFps - nominal) < 2 ? nominal : (measuredFps > 1 ? measuredFps : nominal)
        let startNs = s.lastFrameNs
        do {
            let r = try Recorder(url: dir.appendingPathComponent("game.mov"), width: s.w, height: s.h, fps: fps, colorMode: colorMode, startNs: startNs)
            var proj = Project(name: name, createdAt: Date())
            proj.state = "recording"
            proj.width = s.w; proj.height = s.h; proj.fps = fps; proj.colorMode = colorMode.rawValue
            proj.cameraMirror = cameraMirror
            proj.wide.camera = livePlacement
            if camera.cameraOn, let pb = camera.latest {
                do {
                    camWriter = try LayerWriter(cameraURL: dir.appendingPathComponent("camera.mov"), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), startNs: startNs)
                    proj.camera = LayerInfo(file: "camera.mov")
                } catch { log("camera layer failed: \(error)") }
            }
            if camera.micOn {
                do { micWriter = try LayerWriter(micURL: dir.appendingPathComponent("mic.m4a"), startNs: startNs); proj.mic = LayerInfo(file: "mic.m4a") }
                catch { log("mic layer failed: \(error)") }
            }
            if proj.camera == nil { proj.wide.kind = .screenOnly; proj.vertical.kind = .screenOnly }
            camera.attach(camera: camWriter, mic: micWriter)
            let doc = ProjectDoc(dir: dir, project: proj); doc.save()
            recDoc = doc; AppDelegate.activeRecordingDir = dir
            recorder = r; s.recorder = r; recStart = Date()
            recordItem.title = "Stop Recording"
            recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.setTitle(self?.lastInfo ?? "") }
            setTitle(lastInfo)
        } catch { setTitle("record failed: \(error.localizedDescription)"); log("record failed: \(error)") }
    }

    func stopRecording() { finishRecording { [weak self] msg in log(msg); self?.setTitle(msg) } }

    /// Closes every layer, then completes project.json and its thumbnail.
    func finishRecording(_ done: @escaping (String) -> Void) {
        guard let r = recorder else { return }
        session?.recorder = nil; recorder = nil
        camera.attach(camera: nil, mic: nil)
        recTimer?.invalidate(); recTimer = nil
        recordItem.title = "Start Recording"
        let doc = recDoc, cw = camWriter, mw = micWriter
        recDoc = nil; camWriter = nil; micWriter = nil
        let group = DispatchGroup()
        var msg = ""
        group.enter(); r.finish { m in msg = m; group.leave() }
        var camOK = true, micOK = true
        if let cw = cw { group.enter(); cw.finish { ok in camOK = ok; group.leave() } }
        if let mw = mw { group.enter(); mw.finish { ok in micOK = ok; group.leave() } }
        group.notify(queue: .main) {
            AppDelegate.activeRecordingDir = nil
            guard let doc = doc else { done(msg); return }
            if !camOK { doc.project.camera = nil }
            if !micOK { doc.project.mic = nil }
            let layers = ["game"] + (doc.project.camera != nil ? ["camera"] : []) + (doc.project.mic != nil ? ["mic"] : [])
            doc.finalize {
                Library.shared.reload()
                done("saved \(doc.project.name) [\(layers.joined(separator: " + "))]")
            }
        }
    }

    /// Closing the live view stops capture (and any recording) but keeps the library and editors open.
    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        if recorder != nil { stopRecording() }
        session?.stop(); session = nil
        audio.stop()
    }
    @objc func showLiveView() {
        window.makeKeyAndOrderFront(nil)
        if session == nil { start() }
    }
    var headless = false
    func runHeadlessExport(dir: URL, range: ExportRange, res: ExportResolution) {
        headless = true
        window.orderOut(nil)
        guard let doc = ProjectDoc.load(dir) else { log("export: no project.json in \(dir.path)"); exit(1) }
        Task {
            if doc.project.durationMs == 0 { await withCheckedContinuation { c in doc.finalize { c.resume() } } }
            for canvas in Canvas.allCases {
                let t0 = Date()
                do {
                    let url = try await Exporter(doc: doc, job: ExportJob(canvas: canvas, resolution: res, range: range, fps: .source)).run { _ in }
                    log(String(format: "export: %@ in %.1f s", url.path, Date().timeIntervalSince(t0)))
                } catch { log("export \(canvas.rawValue) failed: \(error)") }
            }
            await doc.writeThumbnail()
            exit(0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !headless }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLiveView() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder != nil else { return .terminateNow }
        finishRecording { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ n: Notification) { session?.stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
