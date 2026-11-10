import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Fixed-memory latency distribution: 0.1 ms buckets up to 2 s, with an exact maximum.
struct EncodeLatency: Equatable {
    private var buckets = [Int](repeating: 0, count: 20001)
    private(set) var count = 0
    private(set) var maxMs = 0.0
    mutating func add(_ ms: Double) {
        buckets[min(20000, max(0, Int(ms * 10)))] += 1
        count += 1; maxMs = max(maxMs, ms)
    }
    func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = max(1, Int(ceil(Double(count) * fraction)))
        var n = 0
        for (i, v) in buckets.enumerated() { n += v; if n >= rank { return i == 20000 ? maxMs : Double(i) / 10 } }
        return maxMs
    }
}

struct EncodeAdmission {
    // Bound encoder latency and leased memory while absorbing measured NV12 callback bursts.
    static let inFlightLimit = 16
    var queued = 0, pending = 0
    mutating func admit() -> Bool {
        guard queued < 2, pending < Self.inFlightLimit else { return false }
        queued += 1; pending += 1; return true
    }
}

final class VideoEncoder {
    struct Settings { var width, height: Int; var fps: Double; var bitrate: Int }
    struct Stats { var frames = 0, dropped = 0, queueRejected = 0, inFlightRejected = 0; var encodeMs = 0.0, latencyMs = 0.0; var latency = EncodeLatency() }
    var onConfig: ((Data, Data) -> Void)?
    var onFrame: ((Data, UInt64, Bool) -> Void)?
    var onError: ((OSStatus) -> Void)?
    var onRecovery: (() -> Void)?
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "studio.stream.video")
    private let lock = NSLock()
    private var admission = EncodeAdmission()
    private var accepting = true, forceKeyframe = false
    private var counters = Stats()
    private var lifetime = EncodeLatency(), totalQueueRejected = 0, totalInFlightRejected = 0, totalDropped = 0
    private var config: [Data] = []
    private let duration: CMTime
    private let settings: Settings
    private var failures = 0, epoch = 0
    private var leases: [Int: () -> Void] = [:], nextLease = 0
    private var lastErrorNs: UInt64 = 0
    private var failRecoveryForTesting = false

    init?(settings: Settings) {
        guard settings.width > 0, settings.height > 0, settings.fps.isFinite, settings.fps > 0, settings.bitrate > 0 else { return nil }
        self.settings = settings
        duration = CMTime(seconds: 1 / settings.fps, preferredTimescale: 1_000_000_000)
        guard createSession() else { return nil }
    }
    private func createSession() -> Bool {
        let settings = self.settings
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width), height: Int32(settings.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { log("stream: hardware H.264 encoder unavailable"); return false }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(settings.fps * 2),
            kVTCompressionPropertyKey_AverageBitRate: settings.bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [Double(settings.bitrate) / 8 * 1.15, 1],
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.fps,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard status == noErr else { log("stream: H.264 property failed (\(status))"); VTCompressionSessionInvalidate(session); return false }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { VTCompressionSessionInvalidate(session); return false }
        return true
    }

    func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }
    func encode(_ pb: CVPixelBuffer, hostNs: UInt64, onComplete: @escaping () -> Void = {}) {
        lock.lock()
        guard accepting, admission.admit() else { if accepting { counters.dropped += 1; totalDropped += 1; if admission.queued >= 2 { counters.queueRejected += 1; totalQueueRejected += 1 } else { counters.inFlightRejected += 1; totalInFlightRejected += 1 } }; lock.unlock(); onComplete(); return }
        queue.async { [self] in
            guard let session else { lock.lock(); admission.queued -= 1; lock.unlock(); completed(); onComplete(); return }
            lock.lock(); let force = forceKeyframe; forceKeyframe = false; lock.unlock()
            let leaseID = nextLease; nextLease += 1; leases[leaseID] = onComplete
            let begin = nowNs(), token = epoch
            let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pb,
                presentationTimeStamp: CMTime(value: Int64(hostNs), timescale: 1_000_000_000), duration: duration,
                frameProperties: options, infoFlagsOut: nil) { [self] status, _, sample in
                    // VT may invoke this inline or on an internal queue. Preserve callback/config order on our queue.
                    queue.async { [self] in
                        defer { completeLease(leaseID, token: token) }
                        guard token == epoch else { return }
                        guard status == noErr, let sample else { failed(status); return }
                        failures = 0
                        receive(sample, begin: begin)
                    }
                }
            let elapsed = Double(nowNs() - begin) / 1e6
            lock.lock(); admission.queued -= 1; counters.encodeMs += elapsed; lock.unlock()
            if status != noErr { completeLease(leaseID, token: token); failed(status) }
        }
        lock.unlock()
    }
    // Test hook runs on the same serial queue as encode and recovery.
    func invalidateForTesting(fatal: Bool = false) { queue.sync { failRecoveryForTesting = fatal; if let session { VTCompressionSessionInvalidate(session) } } }
    func enqueueForTesting(_ work: @escaping () -> Void) { queue.async(execute: work) }
    func drainForTesting() { queue.sync {} }
    private func failed(_ status: OSStatus) {
        lock.lock(); counters.dropped += 1; totalDropped += 1; lock.unlock()
        failures += 1
        let ns = nowNs()
        if ns - lastErrorNs >= 1_000_000_000 { log("stream: H.264 failure (\(status)); recovering"); lastErrorNs = ns }
        guard status == kVTInvalidSessionErr || failures >= 3 else { return }
        epoch += 1
        lock.lock(); admission.pending = admission.queued; lock.unlock()
        if let session { VTCompressionSessionInvalidate(session) }
        cancelLeases()
        session = nil; config = []
        if !failRecoveryForTesting && createSession() { failures = 0; requestKeyframe(); onRecovery?() }
        else {
            session = nil
            lock.lock(); accepting = false; lock.unlock()
            onError?(status)
        }
    }
    private func completeLease(_ id: Int, token: Int) {
        guard let done = leases.removeValue(forKey: id) else { return }
        completed(token: token); done()
    }
    private func cancelLeases() {
        // Invalidation has returned: VT no longer reads these buffers. A cancelled frame need not get an output
        // callback; late callbacks find no lease, so they cannot recycle the same slot twice.
        let abandoned = Array(leases.values); leases.removeAll()
        abandoned.forEach { $0() }
    }
    private func completed(token: Int? = nil) {
        guard token == nil || token == epoch else { return }
        lock.lock(); admission.pending -= 1; lock.unlock()
    }
    private func receive(_ sample: CMSampleBuffer, begin: UInt64) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var sets: [Data] = []
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?; var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
                sets.append(Data(bytes: pointer, count: size))
            }
            if sets != config { config = sets; onConfig?(sets[0], sets[1]) }
        }
        guard !config.isEmpty, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { onError?(status); return }
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000_000, method: .default).value
        let ms = Double(nowNs() - begin) / 1e6
        lock.lock(); counters.frames += 1; counters.latencyMs += ms; counters.latency.add(ms); lifetime.add(ms); lock.unlock()
        onFrame?(data, UInt64(max(0, pts)), keyframe)
    }
    func takeStats() -> Stats { lock.lock(); defer { lock.unlock() }; let result = counters; counters = Stats(); return result }
    func finish() {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
        // CompleteFrames schedules the last callbacks; drain them before invalidating.
        queue.sync { if let session { VTCompressionSessionInvalidate(session) }; session = nil; epoch += 1; cancelLeases() }
        log("encoder summary \(settings.width)x\(settings.height): frames=\(lifetime.count) dropped render=0 encoder=\(totalDropped) queueRejected=\(totalQueueRejected) inFlightRejected=\(totalInFlightRejected) latency p50=\(lifetime.percentile(0.50)) p95=\(lifetime.percentile(0.95)) p99=\(lifetime.percentile(0.99)) max=\(lifetime.maxMs) ms")
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
