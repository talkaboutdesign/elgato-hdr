import AVFoundation
import VideoToolbox
import XCTest

/// Real codecs stay in the test target; the publisher only accepts already encoded packets.
final class RTMPEncodedFixture {
    struct Packet { var data: Data; var ns: UInt64; var keyframe: Bool = false }
    var video: [Packet] = []
    var audio: [Packet] = []
    var sps = Data(), pps = Data()
    private var encodingError: OSStatus = noErr
    let width = 320, height = 180

    func make() throws { try makeVideo(); try makeAudio() }
    private func makeVideo() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in
            let fixture = Unmanaged<RTMPEncodedFixture>.fromOpaque(ref!).takeUnretainedValue()
            guard status == noErr, let sample else { fixture.encodingError = status; return }
            fixture.collect(sample)
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        defer { VTCompressionSessionInvalidate(session) }
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel as CFTypeRef),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, 600_000 as CFNumber)
        ] { XCTAssertEqual(VTSessionSetProperty(session, key: key, value: value), noErr) }
        for i in 0..<150 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let pointer = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<height { for x in 0..<width {
                let n = y * stride + x * 4
                pointer[n] = UInt8((x + i) % 256); pointer[n + 1] = UInt8(y % 256)
                pointer[n + 2] = UInt8(i % 256); pointer[n + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        XCTAssertEqual(encodingError, noErr); XCTAssertEqual(video.count, 150)
    }
    private func collect(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if sps.isEmpty, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0...1 {
                var pointer: UnsafePointer<UInt8>?, size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    if index == 0 { sps = Data(bytes: pointer, count: size) } else { pps = Data(bytes: pointer, count: size) }
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { encodingError = status; return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        video.append(Packet(data: bytes, ns: UInt64(CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value), keyframe: key))
    }
    private func makeAudio() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let output = try XCTUnwrap(AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
        ]))
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))
        var cursor = 0, packet = 0
        while true {
            let compressed = AVAudioCompressedBuffer(format: output, packetCapacity: 16, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: compressed, error: &error) { requested, state in
                guard cursor < 240000 else { state.pointee = .endOfStream; return nil }
                let count = min(Int(requested), 240000 - cursor)
                let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
                pcm.frameLength = AVAudioFrameCount(count)
                for c in 0..<2 { for i in 0..<count { pcm.floatChannelData![c][i] = Float(sin(Double(cursor + i) * 2 * .pi * 440 / 48000) * 0.1) } }
                cursor += count; state.pointee = .haveData; return pcm
            }
            if let error { throw error }
            for i in 0..<Int(compressed.packetCount) {
                let description = compressed.packetDescriptions![i]
                let data = Data(bytes: compressed.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize))
                audio.append(Packet(data: data, ns: UInt64(packet) * 1024 * 1_000_000_000 / 48000))
                packet += 1
            }
            if status == .endOfStream { break }
            guard status != .error else { throw NSError(domain: "RTMPFixture", code: 1) }
        }
        XCTAssertGreaterThan(audio.count, 230)
    }
}
