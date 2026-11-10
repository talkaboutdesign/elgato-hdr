import Foundation
import CoreGraphics
import CoreVideo
import Metal

struct FramePhase {
    var nextDue: Double?
    var last: UInt64?
    mutating func accept(_ ns: UInt64, fps: Double) -> Bool {
        if let last, ns <= last { return false }
        let period = 1e9 / fps, time = Double(ns)
        let due = nextDue ?? time
        // Under half a period rejects alternate 120 Hz arrivals; 0.45 also tolerates a
        // first frame 4 ms late followed by a 3 ms early frame at 60 Hz.
        guard time + 1 >= due - 0.45 * period else { return false }
        nextDue = max(due + period, time + 0.5 * period)
        last = ns
        return true
    }
}

final class ProgramOutput {
    let canvas: Canvas, size: CGSize, fps: Double
    /// The picture at a host time for this output's size, given the sources that have frames. The stream session
    /// supplies `Renderer.livePicture`, so window and stream show the same scene and transition frame. Called on the
    /// reader thread (game frames) and the no-signal queue; it must not block.
    var picture: (_ size: CGSize, _ sources: [SourceKey: SourceInfo], _ hostNs: UInt64) -> LivePicture = { _, _, _ in LivePicture() }
    var camera: () -> CVPixelBuffer? = { nil }
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onLeasedFrame: ((CVPixelBuffer, UInt64, @escaping () -> Void) -> Void)?
    private struct Slot {
        let buffer: CVPixelBuffer
        let target: MTLTexture
        let chroma: MTLTexture?
        let refs: [CVMetalTexture]
    }
    private var slots: [Slot] = [], freeSlots: [Int] = []
    private var intermediate: MTLTexture?
    private var conversion: MTLComputePipelineState?
    private let nv12: Bool
    struct Stats { var frames = 0, dropped = 0; var renderMs = 0.0; var rateSkipped = 0, contention = 0, capacity = 0, stale = 0, gpu = 0, inactive = 0 }
    private let lock = NSLock(), statsLock = NSLock()
    private let timerQueue = DispatchQueue(label: "studio.stream.no-signal")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var phase = FramePhase(), lastGameNs: UInt64 = 0
    private var generation = 0, inFlight = 0
    private var active = false, counters = Stats()
    private var totalDropped = 0

    init(canvas: Canvas, size: CGSize, fps: Double, nv12: Bool = true) {
        self.nv12 = nv12
        precondition(size.width > 0 && size.height > 0 && fps.isFinite && fps > 0)
        self.canvas = canvas; self.size = size; self.fps = fps
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        _ = MetalCore.shared.pipeline("layerFrag", .bgra8Unorm)
        _ = MetalCore.shared.pipeline("layerFrag", .bgra8Unorm, blend: true)
        let core = MetalCore.shared
        if nv12 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            intermediate = core.device.makeTexture(descriptor: d)
            conversion = core.library.makeFunction(name: "streamNV12").flatMap { try? core.device.makeComputePipelineState(function: $0) }
        }
        // Lease slots through the encoder callback, not just GPU completion. Wrappers and planes are made once,
        // before capture uses this output; serial GPU submissions safely share the intermediate texture.
        if let pool {
            for _ in 0..<(EncodeAdmission.inFlightLimit + 2) {
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pb = buffer,
                      let y = core.texture(pb, nv12 ? .r8Unorm : .bgra8Unorm, plane: 0) else { break }
                let c = nv12 ? core.texture(pb, .rg8Unorm, plane: 1) : nil
                if nv12 && c == nil { break }
                CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                if nv12 {
                    CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
                }
                slots.append(Slot(buffer: pb, target: y.0, chroma: c?.0, refs: [y.1] + (c.map { [$0.1] } ?? [])))
            }
        }
        freeSlots = Array(slots.indices)

    }
    var isReady: Bool { slots.count == EncodeAdmission.inFlightLimit + 2 && (!nv12 || (intermediate != nil && conversion != nil)) }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return }
        statsLock.lock(); active = true; generation += 1; statsLock.unlock(); phase = FramePhase(); lastGameNs = nowNs()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .milliseconds(150), repeating: .nanoseconds(33_333_333))
        timer.setEventHandler { [weak self] in self?.noSignal() }
        self.timer = timer; timer.resume()
    }
    func stop() { lock.lock(); statsLock.lock(); active = false; generation += 1; let dropped = totalDropped; statsLock.unlock(); timer?.cancel(); timer = nil; lock.unlock(); log("program \(canvas.rawValue) summary: dropped render=\(dropped) encoder=0") }
    func gameFrame(y: MTLTexture, c: MTLTexture, size: CGSize, colorMode: ColorMode, camera: CVPixelBuffer?, hostNs: UInt64, isCurrent: @escaping () -> Bool = { true }) {
        // The fallback timer cannot hold up the capture reader. Its pass is short and never waits for GPU completion.
        guard lock.try() else { statsLock.lock(); counters.contention += 1; counters.dropped += 1; totalDropped += 1; statsLock.unlock(); return }; defer { lock.unlock() }
        guard active else { return }
        lastGameNs = nowNs()
        render(game: (y, c, size, colorMode), camera: camera, hostNs: hostNs, isCurrent: isCurrent)
    }
    private func noSignal() {
        lock.lock(); defer { lock.unlock() }
        let ns = nowNs()
        guard active, ns >= lastGameNs, ns - lastGameNs >= 150_000_000 else { return }
        render(game: nil, camera: camera(), hostNs: ns)
    }
    private func render(game: (MTLTexture, MTLTexture, CGSize, ColorMode)?, camera: CVPixelBuffer?, hostNs: UInt64, isCurrent: @escaping () -> Bool = { true }) {
        guard phase.accept(hostNs, fps: fps) else { statsLock.lock(); counters.rateSkipped += 1; statsLock.unlock(); return }
        statsLock.lock()
        guard inFlight < 2, let index = freeSlots.popLast() else { counters.capacity += 1; counters.dropped += 1; totalDropped += 1; statsLock.unlock(); return }
        statsLock.unlock()
        let begin = nowNs(), core = MetalCore.shared, slot = slots[index]
        let pb = slot.buffer, target = intermediate ?? slot.target
        guard let cb = core.queue.makeCommandBuffer() else { release(index); statsLock.lock(); counters.dropped += 1; totalDropped += 1; counters.gpu += 1; statsLock.unlock(); return }
        var sources: [SourceKey: SourceInfo] = [:], textures: [SourceKey: LayerTextures.Kind] = [:]
        var keep = slot.refs
        if let (y, c, size, mode) = game {
            sources[.game] = SourceInfo(size: size)
            textures[.game] = .biplanar(y: y, c: c, bits: 10, transfer: mode.transfer, bt709: mode == .sdr)
        }
        if let camera, let planes = core.planes(camera) {
            keep += planes.2
            sources[.camera] = SourceInfo(size: CGSize(width: CVPixelBufferGetWidth(camera), height: CVPixelBufferGetHeight(camera)))
            textures[.camera] = .biplanar(y: planes.0, c: planes.1, bits: planes.3, transfer: 2, bt709: true)
        }
        // Without a game frame (no signal) the scene renders without its game layers: the background shows.
        let pic = picture(size, sources, hostNs), token = generation
        textures.merge(pic.textures) { own, _ in own }
        core.encodeLayers(cb, target: target, canvas: size, background: pic.frame.background, outTransfer: 2,
                          layers: DrawLayer.pair(pic.frame.layers, textures))
        if let chroma = slot.chroma, let conversion, let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(conversion)
            enc.setTexture(target, index: 0); enc.setTexture(slot.target, index: 1); enc.setTexture(chroma, index: 2)
            enc.dispatchThreads(MTLSize(width: chroma.width, height: chroma.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            enc.endEncoding()
        }
        statsLock.lock(); inFlight += 1; statsLock.unlock()
        cb.addCompletedHandler { [self] completed in
            _ = keep; _ = camera
            statsLock.lock(); inFlight -= 1
            let current = isCurrent()
            let deliver = active && generation == token && completed.status == .completed && current
            if deliver { counters.frames += 1; counters.renderMs += Double(nowNs() - begin) / 1e6 }
            else {
                counters.dropped += 1; totalDropped += 1
                if !current { counters.stale += 1 }
                else if completed.status != .completed { counters.gpu += 1 }
                else { counters.inactive += 1 }
            }
            statsLock.unlock()
            if deliver, let onLeasedFrame { onLeasedFrame(pb, hostNs) { [self] in release(index) } }
            else { if deliver { onFrame?(pb, hostNs) }; release(index) }
        }
        cb.commit()
    }
    private func release(_ index: Int) { statsLock.lock(); freeSlots.append(index); statsLock.unlock() }
    func takeStats() -> Stats { statsLock.lock(); defer { statsLock.unlock() }; let result = counters; counters = Stats(); return result }
    deinit { timer?.cancel() }
}
