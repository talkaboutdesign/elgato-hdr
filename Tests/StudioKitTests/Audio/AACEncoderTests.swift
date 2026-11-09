import XCTest
import AVFoundation
@testable import StudioKit

final class AACEncoderTests: XCTestCase {
    func testFiveSecondToneRoundTrip() throws {
        let encoder = try XCTUnwrap(AACEncoder())
        XCTAssertEqual(encoder.audioSpecificConfig, Data([0x11, 0x90]))
        let aac = try XCTUnwrap(AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]))
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let decoder = try XCTUnwrap(AVAudioConverter(from: aac, to: pcm))
        decoder.primeMethod = .none
        let input = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: 8192)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024))
        var samples = [Float](repeating: 0, count: 2048)
        var decoded: [Float] = []; var timestamps: [UInt64] = []
        let epoch: UInt64 = 10_000_000_000
        // Pad the five-second tone to whole blocks, then feed silence to drain encoder priming.
        let toneFrames = 240000; let blocks = (toneFrames + 1023) / 1024
        for block in 0..<(blocks + 8) {
            for i in 0..<1024 {
                let frame = block * 1024 + i
                let value = frame < toneFrames ? Float(0.2 * sin(2 * .pi * 1000 * Double(frame) / 48000)) : 0
                samples[i * 2] = value; samples[i * 2 + 1] = value
            }
            let packet = samples.withUnsafeBufferPointer { encoder.encode($0.baseAddress!, startHostNs: epoch + UInt64(Double(block * 1024) / 48000 * 1e9)) }
            guard let packet else { continue }
            timestamps.append(packet.ptsNs)
            XCTAssertLessThanOrEqual(packet.data.count, 8192)
            packet.data.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.data.count)
            input.byteLength = UInt32(packet.data.count); input.packetCount = 1
            input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: UInt32(packet.data.count))
            var supplied = false; var error: NSError?
            let status = decoder.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            XCTAssertNil(error); XCTAssertNotEqual(status, .error)
            let p = output.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(output.frameLength) { decoded.append(p[i * 2]) }
        }
        XCTAssertEqual(decoded.count, timestamps.count * 1024)
        XCTAssertGreaterThanOrEqual(decoded.count, toneFrames + 2112)
        var alignmentError = 0.0
        for i in 48000..<96000 {
            let expected = 0.2 * sin(2 * Double.pi * 1000 * Double(i) / 48000)
            alignmentError += pow(Double(decoded[i + 2112]) - expected, 2)
        }
        XCTAssertLessThan(sqrt(alignmentError / 48000), 0.01)
        XCTAssertLessThanOrEqual(decoded.count, (blocks + 8) * 1024 + 2112)
        XCTAssertEqual(timestamps.first!, epoch - 44_000_000, accuracy: 1)
        for i in 1..<timestamps.count { XCTAssertEqual(Double(timestamps[i] - timestamps[i - 1]), 1024e9 / 48000, accuracy: 1) }
        // Measure the spectrum in a stable interior second, avoiding codec priming and tail padding.
        var bestFrequency = 0; var bestPower = 0.0
        for frequency in stride(from: 900, through: 1100, by: 5) {
            var real = 0.0; var imaginary = 0.0
            for i in 0..<48000 {
                let angle = 2 * Double.pi * Double(frequency * i) / 48000
                real += Double(decoded[48000 + i]) * cos(angle)
                imaginary += Double(decoded[48000 + i]) * sin(angle)
            }
            let power = real * real + imaginary * imaginary
            if power > bestPower { bestPower = power; bestFrequency = frequency }
        }
        XCTAssertEqual(bestFrequency, 1000)
        let active = decoded.filter { abs($0) > 0.01 }.count
        XCTAssertGreaterThan(active, 220000)
        print("AAC roundtrip: input=\(toneFrames) decoded=\(decoded.count) packets=\(timestamps.count) peak=\(bestFrequency) Hz firstPTS=\(timestamps.first!)")
    }
}
