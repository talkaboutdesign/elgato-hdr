import Foundation
import Metal

/// The game frame the scene thumbnails draw: a private copy taken right after a live frame is drawn, at most twice a
/// second. The live frame itself is a shared-memory slot the capture helper refills, or a Smooth-mode ring texture
/// that a later frame overwrites, so a thumbnail reading it could show a newer or half-written frame. The copy is
/// encoded on the live command queue just after the frame's own commands, so it reads exactly what was drawn.
///
/// Writer (reader thread or display link) and reader (thumbnail queue) exclude each other: a copy is not started while
/// a thumbnail pass reads, and a pass skips while a copy is in flight. Nothing waits; the next due frame retries.
final class GameSnapshot {
    static let intervalNs: UInt64 = 500_000_000
    private let lock = NSLock()
    private var y: MTLTexture?, c: MTLTexture?
    private var frameSize = CGSize.zero, transfer: Int32 = 0
    private var ready = false, writing = false, allocating = false, readers = 0
    private var lastNs: UInt64 = 0
    private let device: MTLDevice
    private let allocQueue = DispatchQueue(label: "game-snapshot", qos: .utility)

    init(device: MTLDevice = MetalCore.shared.device) { self.device = device }

    /// After a live frame is committed. When no copy is due this is one lock and a compare. Textures of a new size are
    /// allocated on a utility queue, never on the caller's thread; the next due frame then takes the copy.
    func capture(y sy: MTLTexture, c sc: MTLTexture, transfer t: Int32, on queue: MTLCommandQueue, atNs now: UInt64) {
        lock.lock()
        guard !writing, !allocating, readers == 0, lastNs == 0 || now &- lastNs >= Self.intervalNs else { lock.unlock(); return }
        guard let ty = y, let tc = c, ty.width == sy.width, ty.height == sy.height, ty.pixelFormat == sy.pixelFormat,
              tc.width == sc.width, tc.height == sc.height, tc.pixelFormat == sc.pixelFormat else {
            allocating = true; lock.unlock()
            allocate(like: sy, sc)
            return
        }
        writing = true; ready = false; lastNs = now
        lock.unlock()
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            lock.lock(); writing = false; lock.unlock(); return
        }
        blit.copy(from: sy, to: ty); blit.copy(from: sc, to: tc)
        blit.endEncoding()
        let size = CGSize(width: sy.width, height: sy.height)
        cb.addCompletedHandler { [weak self] b in
            guard let self = self else { return }
            self.lock.lock()
            self.writing = false
            if b.status == .completed { self.ready = true; self.frameSize = size; self.transfer = t }
            self.lock.unlock()
        }
        cb.commit()
    }

    private func allocate(like sy: MTLTexture, _ sc: MTLTexture) {
        let (yw, yh, yf, cw, ch, cf) = (sy.width, sy.height, sy.pixelFormat, sc.width, sc.height, sc.pixelFormat)
        allocQueue.async { [weak self] in
            guard let self = self else { return }
            func make(_ f: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
                d.usage = .shaderRead; d.storageMode = .private
                return self.device.makeTexture(descriptor: d)
            }
            let ny = make(yf, yw, yh), nc = make(cf, cw, ch)
            self.lock.lock()
            if self.readers == 0 { self.y = ny; self.c = nc; self.ready = false; self.lastNs = 0 }
            self.allocating = false
            self.lock.unlock()
        }
    }

    /// The copy for one thumbnail pass, or nil when none is ready. Pair with `endRead()` once the GPU has read it.
    func beginRead() -> LiveGameFrame? {
        lock.lock(); defer { lock.unlock() }
        guard ready, !writing, let y = y, let c = c else { return nil }
        readers += 1
        return LiveGameFrame(y: y, c: c, size: frameSize, transfer: transfer)
    }
    func endRead() { lock.lock(); readers = max(0, readers - 1); lock.unlock() }
}
