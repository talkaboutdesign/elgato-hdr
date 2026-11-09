import Foundation
import CoreGraphics
import CoreVideo
import Metal

final class ProgramOutput {
    let canvas: Canvas, size: CGSize, fps: Double
    var composition: () -> Composition = { Composition() }
    var camera: () -> CVPixelBuffer? = { nil }
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    struct Stats { var frames = 0, dropped = 0; var renderMs = 0.0 }
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "studio.stream.no-signal")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var startNs: UInt64?, lastGameNs: UInt64 = 0, lastPTS: UInt64 = 0
    private var lastIndex: Int64 = -1, generation = 0, inFlight = 0
    private var active = false, counters = Stats()

    init(canvas: Canvas, size: CGSize, fps: Double) {
        precondition(size.width > 0 && size.height > 0 && fps.isFinite && fps > 0)
        self.canvas = canvas; self.size = size; self.fps = fps
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        _ = MetalCore.shared.pipeline("layerFrag", .bgra8Unorm)
        _ = MetalCore.shared.pipeline("layerFrag", .bgra8Unorm, blend: true)
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return }
        active = true; generation += 1; startNs = nil; lastIndex = -1; lastPTS = 0; lastGameNs = nowNs()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .milliseconds(150), repeating: .nanoseconds(33_333_333))
        timer.setEventHandler { [weak self] in self?.noSignal() }
        self.timer = timer; timer.resume()
    }
    func stop() { lock.lock(); active = false; generation += 1; timer?.cancel(); timer = nil; lock.unlock() }
    func gameFrame(y: MTLTexture, c: MTLTexture, size: CGSize, colorMode: ColorMode, camera: CVPixelBuffer?, hostNs: UInt64) {
        // The fallback timer cannot hold up the capture reader. Its pass is short and never waits for GPU completion.
        guard lock.try() else { return }; defer { lock.unlock() }
        guard active else { return }
        lastGameNs = nowNs()
        render(game: (y, c, size, colorMode), camera: camera, hostNs: hostNs)
    }
    private func noSignal() {
        lock.lock(); defer { lock.unlock() }
        let ns = nowNs()
        guard active, ns >= lastGameNs, ns - lastGameNs >= 150_000_000 else { return }
        render(game: nil, camera: camera(), hostNs: ns)
    }
    private func render(game: (MTLTexture, MTLTexture, CGSize, ColorMode)?, camera: CVPixelBuffer?, hostNs: UInt64) {
        if startNs == nil {
            // Put arrivals inside the selection bucket, not on its edge: sub-millisecond capture jitter at
            // 60 Hz must not discard alternating frames. A quarter period still selects exactly half at 120 Hz.
            startNs = hostNs - min(hostNs, UInt64(1e9 / fps / 4))
        }
        guard hostNs >= startNs!, hostNs > lastPTS else { return }
        // The epsilon accounts only for integer nanosecond rounding at exact frame boundaries.
        let index = Int64((Double(hostNs - startNs!) * fps / 1e9 + 0.000001).rounded(.down))
        guard index > lastIndex else { return }
        lastIndex = index
        guard inFlight < 3, let pool else { counters.dropped += 1; return }
        let begin = nowNs(), core = MetalCore.shared
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &buffer)
        guard let pb = buffer, let (target, ref) = core.texture(pb, .bgra8Unorm), let cb = core.queue.makeCommandBuffer() else { counters.dropped += 1; return }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var sources: [SourceKey: SourceInfo] = [:], textures: [SourceKey: LayerTextures.Kind] = [:]
        var keep = [ref]
        if let (y, c, size, mode) = game {
            sources[.game] = SourceInfo(size: size)
            textures[.game] = .biplanar(y: y, c: c, bits: 10, transfer: mode.transfer, bt709: mode == .sdr)
        }
        if let camera, let planes = core.planes(camera) {
            keep += planes.2
            sources[.camera] = SourceInfo(size: CGSize(width: CVPixelBufferGetWidth(camera), height: CVPixelBufferGetHeight(camera)))
            textures[.camera] = .biplanar(y: planes.0, c: planes.1, bits: planes.3, transfer: 2, bt709: true)
        }
        let comp = composition(), token = generation
        core.encodeLayers(cb, target: target, canvas: size, background: comp.backgroundColor, outTransfer: 2,
                          layers: DrawLayer.pair(SceneResolver.resolve(comp, canvas: size, sources: sources), textures))
        inFlight += 1; lastPTS = hostNs
        cb.addCompletedHandler { [self] completed in
            _ = keep; _ = camera
            lock.lock(); inFlight -= 1
            let deliver = active && generation == token && completed.status == .completed
            if deliver { counters.frames += 1; counters.renderMs += Double(nowNs() - begin) / 1e6 }
            else if completed.status != .completed { counters.dropped += 1 }
            lock.unlock()
            if deliver { onFrame?(pb, hostNs) }
        }
        cb.commit()
    }
    func takeStats() -> Stats { lock.lock(); defer { lock.unlock() }; let result = counters; counters = Stats(); return result }
    deinit { timer?.cancel() }
}
