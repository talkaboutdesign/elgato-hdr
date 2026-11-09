import AVFoundation

final class AACEncoder {
    let audioSpecificConfig = Data([0x11, 0x90])
    private let converter: AVAudioConverter
    private let pcm: AVAudioPCMBuffer
    private let compressed: AVAudioCompressedBuffer
    private var timestamps: [(frame: Int64, ns: UInt64)] = []
    private var inputFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    private var primingFrames: Int64 = 2112

    init?(bitrate: Int = 160_000) {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true),
              let destination = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]),
              let converter = AVAudioConverter(from: source, to: destination),
              let pcm = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1024) else { return nil }
        self.converter = converter; self.pcm = pcm
        converter.bitRate = bitrate
        compressed = AVAudioCompressedBuffer(format: destination, packetCapacity: 1,
                                             maximumPacketSize: converter.maximumOutputPacketSize)
    }
    /// AAC includes priming packets: their PTS precedes the first supplied PCM sample.
    /// Calls must be serialized. Discontinuities retain the supplied host timeline.
    func encode(_ interleavedStereo: UnsafePointer<Float>, startHostNs: UInt64) -> (data: Data, ptsNs: UInt64)? {

        pcm.frameLength = 1024
        memcpy(pcm.mutableAudioBufferList.pointee.mBuffers.mData!, interleavedStereo, 1024 * 2 * MemoryLayout<Float>.size)
        var supplied = false; var error: NSError?
        let status = converter.convert(to: compressed, error: &error) { [self] _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return pcm
        }
        if supplied { timestamps.append((inputFrames, startHostNs)); inputFrames += 1024 }
        guard error == nil, status != .error, compressed.packetCount > 0 else { return nil }
        let reported = converter.primeInfo.leadingFrames
        if reported > 0 { primingFrames = Int64(reported) }
        let sourceFrame = outputFrames - primingFrames
        while timestamps.count > 1 && timestamps[1].frame <= sourceFrame { timestamps.removeFirst() }
        guard let anchor = timestamps.first else { return nil }
        let pts = max(0, Double(anchor.ns) + Double(sourceFrame - anchor.frame) * 1e9 / 48000)
        outputFrames += 1024
        return (Data(bytes: compressed.data, count: Int(compressed.byteLength)), UInt64(pts))
    }
}
