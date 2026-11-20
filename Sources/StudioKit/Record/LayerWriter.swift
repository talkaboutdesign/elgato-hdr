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
    /// Mic layer: places the counted samples on the host clock. The microphone can deliver nothing for a while (seen
    /// as 0.4–0.6 s holes when the Studio Display that hosts it re-syncs the screen) and AAC packs whatever it gets
    /// back to back, so without this every hole pulled the rest of the voice earlier.
    var clock = AudioClock()

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

    /// `ns` is the host time of the buffer's first sample. Mono 48 kHz float (what `CameraCapture` asks the capture
    /// output for) goes through `clock`; anything else keeps its own timestamp.
    func appendAudio(_ sb: CMSampleBuffer, ns: UInt64) {
        guard let samples = Self.monoFloat48k(sb) else { return appendTimed(sb, ns: ns) }
        let n = samples.count
        guard n > 0 else { return }
        let end = Double(Int64(bitPattern: ns &- startNs)) / 1e9 + Double(n) / 48000
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            guard input.isReadyForMoreMediaData else { dropped += 1; clock.lost(frames: n); return }
            let first = clock.start == nil, at = clock.next
            let step = clock.place(frames: n, end: end)
            guard let start = clock.start else { return }
            let out = step.isEmpty ? samples : samples.withUnsafeBufferPointer { step.apply(to: $0, channels: 1, zero: 0) { ($0 + $1) / 2 } }
            let pts = CMTime(value: CMTimeValue(((first ? start : at) * 48000).rounded()), timescale: 48000)
            guard let s = Self.sampleBuffer(out, pts: pts) else { dropped += 1; return }
            if input.append(s) { count += 1; lastPts = pts } else { dropped += 1 }
        }
    }

    private func appendTimed(_ sb: CMSampleBuffer, ns: UInt64) {
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

    static let monoFormat: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format
    }()

    /// The samples of a mono 48 kHz float buffer, copied out; nil for any other format.
    static func monoFloat48k(_ sb: CMSampleBuffer) -> [Float]? {
        guard let f = CMSampleBufferGetFormatDescription(sb), let a = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee,
              a.mFormatID == kAudioFormatLinearPCM, a.mSampleRate == 48000, a.mChannelsPerFrame == 1, a.mBitsPerChannel == 32,
              a.mFormatFlags & kAudioFormatFlagIsFloat != 0, a.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, CMBlockBufferGetDataLength(block) >= n * 4 else { return nil }
        var out = [Float](repeating: 0, count: n)
        let status = out.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
        return status == noErr ? out : nil
    }

    static func sampleBuffer(_ samples: [Float], pts: CMTime) -> CMSampleBuffer? {
        guard let format = monoFormat, !samples.isEmpty else { return nil }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let bb = block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: samples.count,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    func finish(_ done: @escaping (Bool) -> Void) {
        queue.async { [self] in
            finished = true
            guard writer.status == .writing, count > 0 else { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); done(false); return }
            input.markAsFinished()
            if let start = clock.start {
                log(String(format: "mic sync: audio %.3f–%.3f s, %d dropped, slew %d samples, %d gaps: %d silence / %d cut", start, clock.next,
                           dropped, clock.slewed, clock.gaps, clock.filled, clock.cut))
            }
            writer.finishWriting { done(self.writer.status == .completed) }
        }
    }
}
