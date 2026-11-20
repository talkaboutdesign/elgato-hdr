import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

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
    /// Keeps the counted game-audio samples on the host clock (and so on the video's frame grid).
    var audioClock = AudioClock()
    var videoFrames = 0, droppedVideo = 0, dupFrames = 0, gapFrames = 0
    var finished = false
    let fps: Double
    let frameDur: Int64          // in 60000 units
    var firstIndex: Int64 = -1, lastIndex: Int64 = -1

    /// Below one second the per-fragment index writes start to cost the recorder queue real time.
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

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
        self.fps = fps
        frameDur = Int64((60000.0 / fps).rounded())   // 30 -> 2000, 29.97 -> 2002, 60 -> 1000, 120 -> 500
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
        // Fragmented movie: the index is written every 2 s instead of only at finishWriting, so a crash or power cut
        // loses the last fragment, not the whole file. Must be set before startWriting.
        writer.movieFragmentInterval = Recorder.fragmentInterval
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
            // Snap arrival time to the nominal frame grid: removes USB arrival jitter, keeps holes for dropped frames.
            let index = Int64((t * fps).rounded())
            if index <= lastIndex { dupFrames += 1; return }
            if lastIndex >= 0 && index > lastIndex + 1 { gapFrames += Int(index - lastIndex - 1) }
            guard video.isReadyForMoreMediaData else { droppedVideo += 1; return }
            let pts = CMTime(value: index * frameDur, timescale: 60000)
            if adaptor.append(pb, withPresentationTime: pts) { videoFrames += 1; lastIndex = index; if firstIndex < 0 { firstIndex = index } }
            else { log("video append failed: \(writer.error?.localizedDescription ?? "?")"); droppedVideo += 1 }
        }
    }

    /// Interleaved s16 stereo 48 kHz chunk; `ns` is the time the chunk ended.
    func appendAudio(_ data: Data, ns: UInt64) {
        let frames = data.count / 4
        guard frames > 0 else { return }
        let endT = time(ns)
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            guard audio.isReadyForMoreMediaData else { audioClock.lost(frames: frames); return }
            let first = audioClock.start == nil, at = audioClock.next
            let step = audioClock.place(frames: frames, end: endT)
            guard let start = audioClock.start else { return }    // the whole chunk preceded the recording
            let pcm: [Int16] = data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                if step.isEmpty { return Array(src) }
                return step.apply(to: src, channels: 2, zero: 0) { Int16((Int32($0) + Int32($1)) / 2) }
            }
            // Each chunk goes exactly where the previous one ended; its silence, if any, comes first.
            let pts = first ? start : at
            let n = pcm.count / 2
            guard n > 0 else { return }
            let bytes = pcm.count * 2
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let bb = block else { return }
            pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
            var sb: CMSampleBuffer?
            let ptsTime = CMTime(value: CMTimeValue((pts * 48000).rounded()), timescale: 48000)
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: audioFormat, sampleCount: n, presentationTimeStamp: ptsTime, packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let s = sb else { return }
            if !audio.append(s) { log("audio append failed: \(writer.error?.localizedDescription ?? "?")") }
        }
    }

    /// Where the two tracks start and end as written; a difference at the end means the audio clock was not followed.
    var syncReport: String {
        let unit = Double(frameDur) / 60000
        guard firstIndex >= 0, let audioStart = audioClock.start else { return "game sync: \(videoFrames) video frames, \(audioClock.start == nil ? "no" : "some") audio" }
        let v0 = Double(firstIndex) * unit, v1 = Double(lastIndex + 1) * unit, a0 = audioStart, a1 = audioClock.next
        let line = String(format: "game sync: video %.3f–%.3f s (%.3f s), audio %.3f–%.3f s (%.3f s), audio ends %+.0f ms from video",
                          v0, v1, v1 - v0, a0, a1, a1 - a0, (a1 - v1) * 1000)
        return abs(a1 - v1) > 0.050 ? "warning: " + line : line
    }

    func finish(_ completion: @escaping (String) -> Void) {
        queue.async { [self] in
            finished = true
            guard writer.status == .writing else { completion("recording failed: \(writer.error?.localizedDescription ?? "unknown")"); return }
            video.markAsFinished(); audio.markAsFinished()
            let frames = videoFrames, dropped = droppedVideo, url = url, clock = audioClock
            log(syncReport)
            writer.finishWriting {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                completion(String(format: "saved %@ (%d frames, %d dropped, %d gaps, %d dups, audio slew %+d samples, %d audio gaps: %d silence / %d cut, %.1f MB)", url.lastPathComponent, frames, dropped, self.gapFrames, self.dupFrames, clock.slewed, clock.gaps, clock.filled, clock.cut, Double(size) / 1e6))
            }
        }
    }
}


