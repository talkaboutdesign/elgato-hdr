import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class VideoEncoder {
    struct Settings { var width, height: Int; var fps: Double; var bitrate: Int }
    struct Stats { var frames = 0, dropped = 0; var encodeMs = 0.0, latencyMs = 0.0 }
    var onConfig: ((Data, Data) -> Void)?
    var onFrame: ((Data, UInt64, Bool) -> Void)?
    var onError: ((OSStatus) -> Void)?
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "studio.stream.video")
    private let lock = NSLock()
    private var pending = 0, accepting = true, forceKeyframe = false
    private var counters = Stats()
    private var config: [Data] = []
    private let duration: CMTime

    init?(settings: Settings) {
        guard settings.width > 0, settings.height > 0, settings.fps.isFinite, settings.fps > 0, settings.bitrate > 0 else { return nil }
        duration = CMTime(seconds: 1 / settings.fps, preferredTimescale: 1_000_000_000)
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width), height: Int32(settings.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { log("stream: hardware H.264 encoder unavailable"); return nil }
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
            guard status == noErr else { log("stream: H.264 property failed (\(status))"); VTCompressionSessionInvalidate(session); return nil }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { VTCompressionSessionInvalidate(session); return nil }
    }

    func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }
    func encode(_ pb: CVPixelBuffer, hostNs: UInt64) {
        lock.lock()
        guard accepting, pending < 3 else { if accepting { counters.dropped += 1 }; lock.unlock(); return }
        pending += 1
        queue.async { [self] in
            guard let session else { completed(); return }
            lock.lock(); let force = forceKeyframe; forceKeyframe = false; lock.unlock()
            let begin = nowNs()
            let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pb,
                presentationTimeStamp: CMTime(value: Int64(hostNs), timescale: 1_000_000_000), duration: duration,
                frameProperties: options, infoFlagsOut: nil) { [self] status, _, sample in
                    // VT may invoke this inline or on an internal queue. Preserve callback/config order on our queue.
                    queue.async { [self] in
                        defer { completed() }
                        guard status == noErr, let sample else { onError?(status); return }
                        receive(sample, begin: begin)
                    }
                }
            let elapsed = Double(nowNs() - begin) / 1e6
            lock.lock(); counters.encodeMs += elapsed; lock.unlock()
            if status != noErr { onError?(status); completed() }
        }
        lock.unlock()
    }
    private func completed() { lock.lock(); pending -= 1; lock.unlock() }
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
