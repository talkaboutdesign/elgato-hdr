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

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

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

// MARK: - Metal renderer (P010 -> PQ/HLG/709 RGB, zero-copy from shared memory)

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
vertex V vtx(uint id [[vertex_id]]) {
    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    V o; o.pos = float4(p[id], 0, 1); o.uv = float2((p[id].x + 1) * 0.5, 1 - (p[id].y + 1) * 0.5); return o;
}
fragment float4 frag(V in [[stage_in]], texture2d<float> yT [[texture(0)]], texture2d<float> cT [[texture(1)]], constant int &mode [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yT.sample(s, in.uv).r * (65535.0 / 64.0);      // 10-bit code, MSB-aligned in 16 bits
    float2 c = cT.sample(s, in.uv).rg * (65535.0 / 64.0);
    float Y = (y - 64.0) / 876.0, Cb = (c.x - 512.0) / 896.0, Cr = (c.y - 512.0) / 896.0;   // video range
    float3 rgb = (mode == 2)
        ? float3(Y + 1.5748 * Cr, Y - 0.1873 * Cb - 0.4681 * Cr, Y + 1.8556 * Cb)       // BT.709
        : float3(Y + 1.4746 * Cr, Y - 0.16455 * Cb - 0.57135 * Cr, Y + 1.8814 * Cb);    // BT.2020
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
"""

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let layer: CAMetalLayer
    var slotBuffers: [MTLBuffer] = []
    var textures: [Int: (MTLTexture, MTLTexture)] = [:]   // key: slot<<32 | w<<16 | h
    var colorMode: ColorMode = .pq { didSet { applyColor() } }
    var lowLatency = false { didSet { layer.displaySyncEnabled = !lowLatency } }
    // latency stats (seconds)
    var latSum = 0.0, latMax = 0.0, latN = 0
    let statLock = NSLock()

    init?(layer: CAMetalLayer, shm: UnsafeMutableRawPointer) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q; self.layer = layer
        do {
            let lib = try dev.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vtx"); d.fragmentFunction = lib.makeFunction(name: "frag")
            d.colorAttachments[0].pixelFormat = .rgb10a2Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
        } catch { log("metal setup failed: \(error)"); return nil }
        for i in 0..<shmSlots {
            guard let b = dev.makeBuffer(bytesNoCopy: shm + i * shmSlotBytes, length: shmSlotBytes, options: .storageModeShared, deallocator: nil) else { log("no-copy buffer failed"); return nil }
            slotBuffers.append(b)
        }
        layer.device = dev
        layer.pixelFormat = .rgb10a2Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = !lowLatency
        layer.backgroundColor = NSColor.black.cgColor
        applyColor()
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

    func textures(slot: Int, w: Int, h: Int) -> (MTLTexture, MTLTexture)? {
        let key = slot << 40 | w << 20 | h
        if let t = textures[key] { return t }
        let yd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
        yd.usage = .shaderRead; yd.storageMode = .shared
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: w / 2, height: h / 2, mipmapped: false)
        cd.usage = .shaderRead; cd.storageMode = .shared
        guard let y = slotBuffers[slot].makeTexture(descriptor: yd, offset: 0, bytesPerRow: w * 2),
              let c = slotBuffers[slot].makeTexture(descriptor: cd, offset: w * h * 2, bytesPerRow: w * 2) else { return nil }
        textures[key] = (y, c); return (y, c)
    }

    /// Render slot `slot` (w x h P010) and present immediately. `arrivalNs` = helper timestamp (CLOCK_UPTIME_RAW).
    func draw(slot: Int, w: Int, h: Int, arrivalNs: UInt64) {
        guard let (yT, cT) = textures(slot: slot, w: w, h: h), let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        // aspect-fit viewport
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let scale = min(dw / Double(w), dh / Double(h))
        let vw = Double(w) * scale, vh = Double(h) * scale
        enc.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2, width: vw, height: vh, znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(yT, index: 0); enc.setFragmentTexture(cT, index: 1)
        var mode: Int32 = colorMode == .sdr ? 2 : 0
        enc.setFragmentBytes(&mode, length: 4, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        drawable.addPresentedHandler { [weak self] d in
            guard let self = self, d.presentedTime > 0 else { return }
            let lat = d.presentedTime - Double(arrivalNs) / 1e9
            self.statLock.lock(); self.latSum += lat; self.latMax = max(self.latMax, lat); self.latN += 1; self.statLock.unlock()
        }
        cb.present(drawable)
        cb.commit()
    }

    func takeStats() -> (avgMs: Double, maxMs: Double, n: Int) {
        statLock.lock(); defer { statLock.unlock() }
        let r = (latN > 0 ? latSum / Double(latN) * 1000 : 0, latMax * 1000, latN)
        latSum = 0; latMax = 0; latN = 0
        return r
    }
}

final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = metalLayer; layerContentsRedrawPolicy = .never }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateDrawableSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    func updateDrawableSize() {
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }
}

// MARK: - Audio playback

final class AudioPlayer {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    var queuedFrames: Int = 0           // frames scheduled but not yet played
    let maxQueuedFrames = 48000 * 80 / 1000    // trim above 80 ms of backlog (delivery jitter is ~10-30 ms)
    let prefillFrames = 48000 * 30 / 1000       // resume playback once 30 ms is queued after an underrun
    var needsPrefill = true
    var underruns = 0
    let lock = NSLock()
    var muted = false { didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 } }
    var started = false
    var pushed = 0, dropped = 0; var lastStat = Date()

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in self?.restart() }
    }
    func start() {
        do {
            try engine.start()
            started = true
            needsPrefill = true
            engine.mainMixerNode.outputVolume = muted ? 0 : 1
            log("audio engine running on \(engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz output")
        } catch { log("audio engine start failed: \(error)"); started = false }
    }
    var restartGeneration = 0
    /// Output device changed (or sample rate changed): tear everything down and rebuild after the device settles.
    func restart() {
        restartGeneration += 1; let gen = restartGeneration
        started = false
        player.stop(); engine.stop(); engine.reset()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        lock.lock(); queuedFrames = 0; lock.unlock()
        func attempt(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (n == 0 ? 0.25 : 0.5)) { [weak self] in
                guard let self = self, gen == self.restartGeneration else { return }
                self.start()
                if !self.started && n < 10 { attempt(n + 1) }
            }
        }
        attempt(0)
    }
    func stop() { player.stop(); engine.stop(); started = false }

    /// Interleaved signed 16-bit stereo, 48 kHz.
    func push(_ bytes: UnsafeRawPointer, _ count: Int) {
        if !started { if restartGeneration == 0 { start() }; if !started { return } }
        let frames = count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        lock.lock(); let backlog = queuedFrames; lock.unlock()
        pushed += 1
        if Date().timeIntervalSince(lastStat) >= 5 { log(String(format: "audio: %d chunks, %d dropped, %d underruns, backlog %.0f ms", pushed, dropped, underruns, Double(backlog) / 48.0)); lastStat = Date() }
        if backlog > maxQueuedFrames { dropped += 1; return }
        buf.frameLength = AVAudioFrameCount(frames)
        let src = bytes.assumingMemoryBound(to: Int16.self)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        let scale: Float = 1.0 / 32768.0
        for i in 0..<frames { l[i] = Float(Int16(littleEndian: src[2*i])) * scale; r[i] = Float(Int16(littleEndian: src[2*i+1])) * scale }
        lock.lock(); queuedFrames += frames; let nowQueued = queuedFrames; lock.unlock()
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self.queuedFrames -= frames; let left = self.queuedFrames; self.lock.unlock()
            if left <= 0 && !self.needsPrefill { self.needsPrefill = true; self.underruns += 1; self.player.pause() }
        }
        if needsPrefill && nowQueued >= prefillFrames { needsPrefill = false; player.play() }
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
    var videoFrames = 0, droppedVideo = 0
    var finished = false

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
            guard video.isReadyForMoreMediaData else { droppedVideo += 1; return }
            if adaptor.append(pb, withPresentationTime: CMTime(seconds: t, preferredTimescale: 1_000_000)) { videoFrames += 1 }
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
            var pts = audioAnchor + Double(audioSamplesWritten) / 48000.0
            let expected = endT - Double(n) / 48000.0
            if abs(pts - expected) > 0.08 { log(String(format: "audio re-anchor: drift %.0f ms", (expected - pts) * 1000)); audioAnchor = max(expected, pts); audioSamplesWritten = 0; pts = audioAnchor }
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
                completion(String(format: "saved %@ (%d frames, %d dropped, %.1f MB)", url.lastPathComponent, frames, dropped, Double(size) / 1e6))
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
                renderer.draw(slot: slot, w: w, h: h, arrivalNs: tNs)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: MetalView!
    var renderer: Renderer!
    var shm: UnsafeMutableRawPointer?
    var session: Session?
    var modeIndex = UserDefaults.standard.object(forKey: "mode") as? Int ?? 0
    var colorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "color") ?? "pq") ?? .pq
    var lowLatency = UserDefaults.standard.object(forKey: "lowLatency") as? Bool ?? false
    var modeItems: [NSMenuItem] = [], colorItems: [NSMenuItem] = []
    let audio = AudioPlayer()
    var muteItem: NSMenuItem!, recordItem: NSMenuItem!, lowLatencyItem: NSMenuItem!
    var recorder: Recorder?
    var recStart = Date()
    var recTimer: Timer?
    var measuredFps: Double = 30
    var lastInfo = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        view = MetalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        audio.muted = UserDefaults.standard.bool(forKey: "muted")
        buildMenu()
        setTitle("connecting…")
        start()
        if CommandLine.arguments.contains("--fullscreen") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.window.toggleFullScreen(nil) } }
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

        let recItem = NSMenuItem(); main.addItem(recItem)
        let recMenu = NSMenu(title: "Record")
        recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recMenu.addItem(recordItem)
        recMenu.addItem(withTitle: "Show Recordings in Finder", action: #selector(showRecordings), keyEquivalent: "")
        recItem.submenu = recMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        lowLatencyItem = NSMenuItem(title: "Low Latency (no vsync)", action: #selector(toggleLowLatency), keyEquivalent: "l")
        viewMenu.addItem(lowLatencyItem)
        let rc = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"); rc.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(rc)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
        refreshChecks()
    }

    func refreshChecks() {
        for it in modeItems { it.state = it.tag == modeIndex ? .on : .off }
        for it in colorItems { it.state = (it.representedObject as? String) == colorMode.rawValue ? .on : .off }
        muteItem?.state = audio.muted ? .on : .off
        lowLatencyItem?.state = lowLatency ? .on : .off
    }

    func setTitle(_ s: String) {
        lastInfo = s
        var t = "Elgato HDR  •  \(modes[modeIndex].name)  •  \(s)" + (audio.muted ? "  •  muted" : "")
        if recorder != nil { let e = Int(Date().timeIntervalSince(recStart)); t = String(format: "● REC %02d:%02d  •  ", e / 60, e % 60) + t }
        window.title = t
    }

    @objc func selectMode(_ sender: NSMenuItem) { modeIndex = sender.tag; UserDefaults.standard.set(modeIndex, forKey: "mode"); refreshChecks(); start() }
    @objc func selectColor(_ sender: NSMenuItem) {
        colorMode = ColorMode(rawValue: sender.representedObject as! String)!; UserDefaults.standard.set(colorMode.rawValue, forKey: "color")
        refreshChecks(); renderer?.colorMode = colorMode
    }
    @objc func toggleMute() { audio.muted.toggle(); UserDefaults.standard.set(audio.muted, forKey: "muted"); refreshChecks(); setTitle(lastInfo) }
    @objc func toggleLowLatency() { lowLatency.toggle(); UserDefaults.standard.set(lowLatency, forKey: "lowLatency"); refreshChecks(); renderer?.lowLatency = lowLatency }
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
                    self.renderer?.colorMode = self.colorMode; self.renderer?.lowLatency = self.lowLatency
                    self.view.updateDrawableSize()
                }
            }
            guard let renderer = self.renderer else { DispatchQueue.main.async { self.setTitle("Metal unavailable") }; close(fd); return }
            let cmd = "START 7 \(mode.frame) \(mode.fps) SHM\n"
            _ = cmd.withCString { write(fd, $0, strlen($0)) }
            let s = Session(fd: fd, renderer: renderer, shm: shm)
            s.audio = self.audio
            s.onInfo = { [weak self] info in DispatchQueue.main.async {
                if let r = info.range(of: #"([0-9.]+) fps"#, options: .regularExpression), let v = Double(info[r].dropLast(4)) { self?.measuredFps = v }
                if let self = self, s.w > 0 { self.window.contentAspectRatio = NSSize(width: s.w, height: s.h) }
                self?.setTitle(info) } }
            DispatchQueue.main.async { self.session = s; self.setTitle("starting…") }
            s.run()
        }
    }

    static var recordingsDir: URL {
        let d = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Elgato HDR")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    @objc func toggleRecording() { if recorder == nil { startRecording() } else { stopRecording() } }
    @objc func showRecordings() { NSWorkspace.shared.open(AppDelegate.recordingsDir) }

    func startRecording() {
        guard let s = session, s.w > 0 else { setTitle("not streaming, cannot record"); return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = AppDelegate.recordingsDir.appendingPathComponent("Capture \(f.string(from: Date())).mov")
        let nominal = modes[modeIndex].fps
        let fps = abs(measuredFps - nominal) < 2 ? nominal : (measuredFps > 1 ? measuredFps : nominal)
        do {
            let r = try Recorder(url: url, width: s.w, height: s.h, fps: fps, colorMode: colorMode, startNs: s.lastFrameNs)
            recorder = r; s.recorder = r; recStart = Date()
            recordItem.title = "Stop Recording"
            recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.setTitle(self?.lastInfo ?? "") }
            setTitle(lastInfo)
        } catch { setTitle("record failed: \(error.localizedDescription)"); log("record failed: \(error)") }
    }
    func stopRecording() {
        guard let r = recorder else { return }
        session?.recorder = nil; recorder = nil
        recTimer?.invalidate(); recTimer = nil
        recordItem.title = "Start Recording"
        r.finish { [weak self] msg in DispatchQueue.main.async { log(msg); self?.setTitle(msg) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let r = recorder else { return .terminateNow }
        session?.recorder = nil; recorder = nil
        r.finish { _ in DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationWillTerminate(_ n: Notification) { session?.stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
