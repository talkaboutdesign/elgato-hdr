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
    var audioAnchor: Double = -1     // seconds (recording time) of the first audio sample written
    var audioSamplesWritten: Int64 = 0
    var videoFrames = 0, droppedVideo = 0, dupFrames = 0, gapFrames = 0
    var finished = false
    let fps: Double
    let frameDur: Int64          // in 60000 units
    var lastIndex: Int64 = -1
    var slewSamples = 0

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
            if adaptor.append(pb, withPresentationTime: pts) { videoFrames += 1; lastIndex = index }
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
            let pts = audioAnchor + Double(audioSamplesWritten) / 48000.0
            // Slew instead of jumping: if the sample clock drifts from arrival time, drop or repeat a few samples
            // spread across this chunk (max 1%), keeping audio continuous and locked to the video clock.
            let expected = endT - Double(n) / 48000.0
            let err = expected - pts                       // > 0: audio is behind (need to drop samples)
            if abs(err) > 0.002 {
                let want = Int((err * 48000).rounded())
                let maxAdj = max(1, n / 100)
                let adj = max(-maxAdj, min(maxAdj, want))
                if adj != 0 {
                    var out = Data(capacity: (n + abs(adj)) * 4)
                    let stride = n / abs(adj)
                    var i = 0, k = 0
                    while i < n {
                        let frame = d.subdata(in: i * 4 ..< i * 4 + 4)
                        if (i + 1) % stride == 0 && k < abs(adj) { k += 1; if adj > 0 { i += 1; continue } else { out.append(frame) } }
                        out.append(frame); i += 1
                    }
                    d = out; n = out.count / 4; slewSamples += adj
                }
            }
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
                completion(String(format: "saved %@ (%d frames, %d dropped, %d gaps, %d dups, audio slew %d samples, %.1f MB)", url.lastPathComponent, frames, dropped, self.gapFrames, self.dupFrames, self.slewSamples, Double(size) / 1e6))
            }
        }
    }
}


