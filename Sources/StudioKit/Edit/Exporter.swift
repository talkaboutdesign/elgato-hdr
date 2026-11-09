import AppKit
import AVFoundation

// MARK: - Export

struct ExportJob: Hashable {
    var canvas: Canvas
    var resolution: ExportResolution
    var range: ExportRange
    var fps: ExportFPS
}

/// Renders a project to a single MP4 through AVAssetReader (composited) -> AVAssetWriter.
final class Exporter {
    let doc: ProjectDoc
    let job: ExportJob
    let output: URL
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private(set) var cancelled = false

    init(doc: ProjectDoc, job: ExportJob) {
        self.doc = doc; self.job = job
        let name = doc.project.name.replacingOccurrences(of: "/", with: "-")
        let res = job.resolution == .uhd ? "4K" : "1080p"
        output = doc.exportsDir.appendingPathComponent("\(name) — \(job.canvas == .wide ? "16x9" : "9x16") \(res) \(job.range == .hdr ? "HDR" : "SDR").mp4")
        // Exports are file names only: the project folder can be renamed or moved freely.
    }

    func cancel() { cancelled = true; reader?.cancelReading(); writer?.cancelWriting() }

    func run(progress: @escaping (Double) -> Void) async throws -> URL {
        let built = try await CompositionBuilder.build(doc, canvas: job.canvas, resolution: job.resolution, range: job.range, fps: job.fps)
        #if DEBUG
        if ProcessInfo.processInfo.environment["EHDR_VALIDATE"] != nil {
            final class V: NSObject, AVVideoCompositionValidationHandling {
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool { log("invalid key \(key)"); return true }
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange r: CMTimeRange) -> Bool { log("empty range \(r.start.seconds)+\(r.duration.seconds)"); return true }
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn i: any AVVideoCompositionInstructionProtocol) -> Bool { log("invalid instr range \(i.timeRange.start.seconds)+\(i.timeRange.duration.seconds)"); return true }
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn i: any AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool { log("invalid track id"); return true }
            }
            let ok = try await built.video.isValid(for: built.asset, timeRange: CMTimeRange(start: .zero, duration: built.asset.duration), validationDelegate: V())
            log("composition valid: \(ok) comp=\(built.asset.duration.seconds) instr=\(built.duration.seconds) tracks=\(built.asset.tracks.map { "\($0.trackID):\($0.mediaType.rawValue):\($0.timeRange.duration.seconds)" })")
        }
        #endif
        try FileManager.default.createDirectory(at: doc.exportsDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let hdr = built.outTransfer != 2
        let reader = try AVAssetReader(asset: built.asset)
        let videoTracks = built.asset.tracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
        vOut.videoComposition = built.video
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let audioTracks = built.asset.tracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            o.audioMix = built.audioMix
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let size = built.video.renderSize
        let fps = 1 / built.video.frameDuration.seconds
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: Int(fps * 2)]
        let videoSettings: [String: Any]
        if hdr {
            compression[AVVideoAverageBitRateKey] = Int(Double(size.width * size.height) * fps * 0.12)
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            let pq = built.outTransfer == 0
            if pq {
                let (m, c) = Recorder.hdr10Metadata()
                compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = m
                compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = c
            }
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                         AVVideoTransferFunctionKey: pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG,
                                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
                             AVVideoCompressionPropertiesKey: compression]
        } else {
            compression[AVVideoAverageBitRateKey] = Int(Double(size.width * size.height) * fps * 0.14)
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                             AVVideoCompressionPropertiesKey: compression]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
            writer.add(i); aIn = i
        }
        self.reader = reader; self.writer = writer
        guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("cannot read layers") }
        guard writer.startWriting() else { throw writer.error ?? CompositionBuilder.err("cannot write export") }
        writer.startSession(atSourceTime: .zero)

        let total = max(0.001, built.duration.seconds)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(vOut, into: vIn, label: "export-video") { t in progress(min(1, t / total)) } }
            if let aOut = aOut, let aIn = aIn { group.addTask { await Self.pump(aOut, into: aIn, label: "export-audio") { _ in } } }
        }
        if cancelled || reader.status == .failed {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: output)
            throw reader.error ?? CompositionBuilder.err("export cancelled")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompositionBuilder.err("export failed") }
        return output
    }

    private static func pump(_ out: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String, progress: @escaping (Double) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: label)
            var done = false
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData && !done {
                    if let sb = out.copyNextSampleBuffer() {
                        progress(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
                        if !input.append(sb) { done = true }
                    } else { done = true }
                    if done { input.markAsFinished(); cont.resume() }
                }
            }
        }
    }
}

