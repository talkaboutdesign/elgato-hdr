import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

struct EncodeAdmission {
    var queued = 0, pending = 0
    mutating func admit() -> Bool {
        guard queued < 2, pending < 8 else { return false }
        queued += 1; pending += 1; return true
    }
}

final class VideoEncoder {
    struct Settings { var width, height: Int; var fps: Double; var bitrate: Int }
    struct Stats { var frames = 0, dropped = 0; var encodeMs = 0.0, latencyMs = 0.0 }
    var onConfig: ((Data, Data) -> Void)?
    var onFrame: ((Data, UInt64, Bool) -> Void)?
    var onError: ((OSStatus) -> Void)?
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "studio.stream.video")
    private let lock = NSLock()
    private var admission = EncodeAdmission()
    private var accepting = true, forceKeyframe = false
    private var counters = Stats()
    private var config: [Data] = []
    private let duration: CMTime
    private let settings: Settings
    private var failures = 0, epoch = 0
    private var lastErrorNs: UInt64 = 0

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
    func encode(_ pb: CVPixelBuffer, hostNs: UInt64) {
        lock.lock()
        guard accepting, admission.admit() else { if accepting { counters.dropped += 1 }; lock.unlock(); return }
        queue.async { [self] in
            guard let session else { lock.lock(); admission.queued -= 1; lock.unlock(); completed(); return }
            lock.lock(); let force = forceKeyframe; forceKeyframe = false; lock.unlock()
            let begin = nowNs(), token = epoch
            let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pb,
                presentationTimeStamp: CMTime(value: Int64(hostNs), timescale: 1_000_000_000), duration: duration,
                frameProperties: options, infoFlagsOut: nil) { [self] status, _, sample in
                    // VT may invoke this inline or on an internal queue. Preserve callback/config order on our queue.
                    queue.async { [self] in
                        defer { completed(token: token) }
                        guard token == epoch else { return }
                        guard status == noErr, let sample else { failed(status); return }
                        failures = 0
                        receive(sample, begin: begin)
                    }
                }
            let elapsed = Double(nowNs() - begin) / 1e6
            lock.lock(); admission.queued -= 1; counters.encodeMs += elapsed; lock.unlock()
            if status != noErr { completed(token: token); failed(status) }
        }
        lock.unlock()
    }
    // Test hook runs on the same serial queue as encode and recovery.
    func invalidateForTesting() { queue.sync { if let session { VTCompressionSessionInvalidate(session) } } }
    func drainForTesting() { queue.sync {} }
    private func failed(_ status: OSStatus) {
        lock.lock(); counters.dropped += 1; lock.unlock()
        failures += 1
        let ns = nowNs()
        if ns - lastErrorNs >= 1_000_000_000 { log("stream: H.264 failure (\(status)); recovering"); lastErrorNs = ns }
        guard status == kVTInvalidSessionErr || failures >= 3 else { return }
        epoch += 1
        lock.lock(); admission.pending = admission.queued; lock.unlock()
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; config = []
        if createSession() { failures = 0; requestKeyframe() }
        else {
            session = nil
            lock.lock(); accepting = false; lock.unlock()
            onError?(status)
        }
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
        lock.lock(); counters.frames += 1; counters.latencyMs += Double(nowNs() - begin) / 1e6; lock.unlock()
        onFrame?(data, UInt64(max(0, pts)), keyframe)
    }
    func takeStats() -> Stats { lock.lock(); defer { lock.unlock() }; let result = counters; counters = Stats(); return result }
    func finish() {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
        // CompleteFrames schedules the last callbacks; drain them before invalidating.
        queue.sync { if let session { VTCompressionSessionInvalidate(session) }; session = nil }
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
