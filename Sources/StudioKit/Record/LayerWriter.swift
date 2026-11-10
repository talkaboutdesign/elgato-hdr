import AppKit
import AVFoundation
import CoreMedia

/// Records one layer (camera video or microphone audio) to its own file, timed from the shared recording zero.
final class LayerWriter {
    let url: URL
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    let startNs: UInt64
    let queue: DispatchQueue
    var finished = false
    var count = 0, dropped = 0
    var lastPts = CMTime.negativeInfinity
    var size: CGSize = .zero

    /// Camera layer: H.264 High at the camera's native size.
    init(cameraURL url: URL, width: Int, height: Int, startNs: UInt64) throws {
        self.url = url; self.startNs = startNs; queue = DispatchQueue(label: "layer-camera")
        size = CGSize(width: width, height: height)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(6_000_000, width * height * 6),
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoAllowFrameReorderingKey: false],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        try start()
    }

    /// Microphone layer: mono AAC in an audio-only QuickTime movie, because .m4a cannot take movie fragments.
    init(micURL url: URL, startNs: UInt64) throws {
        self.url = url; self.startNs = startNs; queue = DispatchQueue(label: "layer-mic")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 160_000])
        input.expectsMediaDataInRealTime = true
        adaptor = nil
        try start()
    }

    private func start() throws {
        guard writer.canAdd(input) else { throw NSError(domain: "LayerWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot add input"]) }
        writer.add(input)
        writer.movieFragmentInterval = Recorder.fragmentInterval   // crash safety, see Recorder.init
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "LayerWriter", code: 2) }
        writer.startSession(atSourceTime: .zero)
    }

    private func pts(_ ns: UInt64) -> CMTime? { ns > startNs ? CMTime(value: CMTimeValue(ns - startNs), timescale: 1_000_000_000) : nil }

    func appendVideo(_ pb: CVPixelBuffer, ns: UInt64) {
        guard let t = pts(ns) else { return }
        queue.async { [self] in
            guard !finished, writer.status == .writing, let adaptor = adaptor, t > lastPts else { return }
            guard input.isReadyForMoreMediaData else { dropped += 1; return }
            if adaptor.append(pb, withPresentationTime: t) { count += 1; lastPts = t } else { dropped += 1 }
        }
    }

    func appendAudio(_ sb: CMSampleBuffer, ns: UInt64) {
        guard let t = pts(ns) else { return }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out) == noErr, let s = out else { return }
        queue.async { [self] in
            guard !finished, writer.status == .writing, t > lastPts else { return }
            guard input.isReadyForMoreMediaData else { dropped += 1; return }
            if input.append(s) { count += 1; lastPts = t } else { dropped += 1 }
        }
    }

    func finish(_ done: @escaping (Bool) -> Void) {
        queue.async { [self] in
            finished = true
            guard writer.status == .writing, count > 0 else { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); done(false); return }
            input.markAsFinished()
            writer.finishWriting { done(self.writer.status == .completed) }
        }
    }
}
