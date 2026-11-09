import XCTest
import AVFoundation
@testable import StudioKit

final class AudioMixerTests: XCTestCase {
    let origin: UInt64 = 10_000_000_000
    func ns(_ frame: Double) -> UInt64 { origin + UInt64(frame * 1e9 / 48000) }
    func testConversionHelpers() {
        let input = MixerInput(); let out = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { out.deallocate() }; out.initialize(repeating: 0, count: 8)
        let pcm: [Int16] = [-32768, 32767, 0, 16384, -16384, 8192, 0, 0]
        pcm.withUnsafeBytes { input.pushInt16Stereo($0.baseAddress!, byteCount: $0.count, endHostNs: ns(3)) }
        input.mix(into: out, frames: 4, startHostNs: origin)
        for i in 0..<8 { XCTAssertEqual(out[i], Float(pcm[i]) / 32768, accuracy: 0.00001) }
        let mono = MixerInput(); let values: [Float] = [0.1, -0.2, 0.3, 0.4]
        values.withUnsafeBufferPointer { mono.pushFloatMono($0.baseAddress!, frames: 4, endHostNs: ns(3)) }
        out.update(repeating: 0, count: 8); mono.mix(into: out, frames: 4, startHostNs: origin)
        for i in 0..<4 { XCTAssertEqual(out[i * 2], values[i], accuracy: 0.00001); XCTAssertEqual(out[i * 2 + 1], values[i], accuracy: 0.00001) }
    }
    func simulate(ppm: Double, jitter: Bool, seconds: Double) {
        let mixer = AudioMixer(); let input = mixer.addInput("game")
        let rate = 48000 * (1 + ppm / 1e6); let chunk = 480
        var next = 0; var outputFrames = 0; var maxStep: Float = 0; var previous: Float?
        var squaredError = 0.0; var missesAtOne = 0
        var lagSum = 0.0; var lagCount = 0
        mixer.onBlock = { p, frames, start in
            XCTAssertEqual(start, input.startNs! + UInt64(Double(outputFrames) * 1e9 / 48000))
            for i in 0..<frames {
                if let previous, outputFrames > 48000 { maxStep = max(maxStep, abs(p[i * 2] - previous)) }
                previous = p[i * 2]
                let expected = 0.2 * sin(2 * .pi * 440 * Double(outputFrames + i) / 48000)
                squaredError += pow(Double(p[i * 2]) - expected, 2)
            }
            if Double(outputFrames) > min(60, seconds / 2) * 48000, let position = input.readPosition {
                let expected = (Double(start - self.origin) / 1e9 + Double(frames) / 48000) * rate
                lagSum += abs(position - expected) / rate * 1000; lagCount += 1
                XCTAssertEqual(input.driftPPM, ppm, accuracy: 50)
            }
            outputFrames += frames
        }
        var data = [Float](repeating: 0, count: chunk * 2)
        for tick in 0..<Int(seconds * 1000) {
            let time = Double(tick) / 1000
            while true {
                let end = Double(next + chunk - 1) / rate
                // Vary delivery time, never the capture timestamp. Preserve FIFO ordering.
                let arrival = end + (jitter ? 0.008 + 0.008 * sin(Double(next / chunk) * 1.7) : 0)
                if max(end, arrival) > time { break }
                for i in 0..<chunk {
                    let value = Float(0.2 * sin(2 * .pi * 440 * Double(next + i) / rate))
                    data[i * 2] = value; data[i * 2 + 1] = value
                }
                data.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: chunk, endHostNs: origin + UInt64(max(0, end + (jitter ? 0.008 * sin(Double(next / chunk) * 1.7) : 0)) * 1e9)) }
                next += chunk
            }
            mixer.render(upTo: origin + UInt64(time * 1e9))
            if tick == 1000 { missesAtOne = input.underruns }
        }
        let lag = lagSum / Double(max(1, lagCount))
        print("average converged lag: \(lag) ms")
        XCTAssertLessThan(lag, 1)
        let rms = sqrt(squaredError / Double(outputFrames))
        print(String(format: "drift target=%.0f measured=%.3f ppm jitter=%@ underruns=%d jumps=%d maxStep=%.6f errorRMS=%.8f", ppm, input.driftPPM, String(jitter), input.underruns, input.hardCorrections, maxStep, rms))
        XCTAssertEqual(input.underruns, missesAtOne); XCTAssertEqual(input.hardCorrections, 0)
        XCTAssertLessThan(maxStep, 0.012); XCTAssertEqual(input.driftPPM, ppm, accuracy: 50)
        XCTAssertGreaterThan(outputFrames, Int((seconds - 0.1) * 48000))
        if ppm == 0 && !jitter { XCTAssertLessThan(rms, 0.001) }
    }
    func testPerfectTimelineTenSeconds() { simulate(ppm: 0, jitter: false, seconds: 10) }
    func testPositiveDrift120Seconds() { simulate(ppm: 300, jitter: false, seconds: 120) }
    func testNegativeDrift120Seconds() { simulate(ppm: -300, jitter: false, seconds: 120) }
    func testNegativeTimestampJitter120Seconds() { simulate(ppm: -300, jitter: true, seconds: 120) }
    func testJitter120Seconds() { simulate(ppm: 300, jitter: true, seconds: 120) }

    func testGainMuteMetersTwoInputsAndClip() {
        let mixer = AudioMixer(blockFrames: 480, targetLatencyMs: 0)
        let a = mixer.addInput("a"); let b = mixer.addInput("b")
        let values = [Float](repeating: 0.2, count: 4800)
        for input in [a, b] { values.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 2400, endHostNs: ns(2399)) } }
        var expected: Float = 0.3
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[958], expected, accuracy: 0.00001) }
        a.gain = 0.5; mixer.render(upTo: ns(480))
        XCTAssertEqual(a.meter.rms, 0.1, accuracy: 0.00001); XCTAssertEqual(mixer.masterMeter.peak, 0.3, accuracy: 0.00001)
        a.muted = true; expected = 0.2; mixer.render(upTo: ns(960)); XCTAssertEqual(a.meter.peak, 0.1, accuracy: 0.00001)
        mixer.masterGain = 0.5; expected = 0.1; mixer.render(upTo: ns(1440))
        a.muted = false; a.gain = 4; b.gain = 4; mixer.masterGain = 4
        mixer.onBlock = { p, _, _ in XCTAssertGreaterThan(p[958], 0.891); XCTAssertLessThan(p[958], 1) }
        mixer.render(upTo: ns(1920))
    }
    func testDelayUnderrunAndReturn() {
        let mixer = AudioMixer(blockFrames: 480, targetLatencyMs: 0); let input = mixer.addInput("a")
        input.delayMs = 10
        let values = (0..<1440).flatMap { i in [Float(i) / 10000, Float(i) / 10000] }
        values.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 1440, endHostNs: ns(1439)) }
        var blocks = 0
        mixer.onBlock = { p, _, _ in
            if blocks == 0 { XCTAssertEqual(p[200], 0) }
            if blocks == 1 { XCTAssertEqual(p[200], 0.01, accuracy: 0.00001) }
            blocks += 1
        }
        mixer.render(upTo: ns(1440)); XCTAssertEqual(input.underruns, 1)
        for frame in stride(from: 1920, through: 12000, by: 480) { mixer.render(upTo: ns(Double(frame))) }; XCTAssertGreaterThan(input.underruns, 1)
        input.delayMs = 0
        values.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 1440, endHostNs: ns(13439)) }
        input.resetReadState()
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[200], 0.01, accuracy: 0.0001) }
        mixer.render(upTo: ns(12480))
    }
    func testHardCorrectionAndRingWrap() {
        let input = MixerInput(); let values = [Float](repeating: 0.1, count: 200000)
        values.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 100000, endHostNs: ns(99999)) }
        var out = [Float](repeating: 0, count: 2048)
        out.withUnsafeMutableBufferPointer {
            input.mix(into: $0.baseAddress!, frames: 1024, startHostNs: ns(5000))
            input.mix(into: $0.baseAddress!, frames: 1024, startHostNs: ns(20000))
        }
        XCTAssertEqual(input.hardCorrections, 1); XCTAssertEqual(input.underruns, 0)
    }
    func testRenderPerformance() {
        let mixer = AudioMixer(targetLatencyMs: 0); let a = mixer.addInput("a"); let b = mixer.addInput("b")
        let data = [Float](repeating: 0.1, count: 2048); var elapsed = 0.0
        for block in 0..<1000 {
            for input in [a, b] { data.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 1024, endHostNs: ns(Double((block + 1) * 1024 - 1))) } }
            let start = nowNs(); mixer.render(upTo: ns(Double((block + 1) * 1024))); elapsed += Double(nowNs() - start)
        }
        let ms = elapsed / 1000 / 1e6
        print(String(format: "two-input render average: %.6f ms/block", ms))
        #if DEBUG
        XCTAssertLessThan(ms, 1)
        #else
        XCTAssertLessThan(ms, 0.2)
        #endif
    }
    func testDelayChangeCrossfadesWithoutDrift() {
        let input = MixerInput()
        let data = (0..<48000).map { Float(0.2 * sin((2.0 * Double.pi * 437.0 / 48000.0) * Double($0))) }
        data.withUnsafeBufferPointer { input.pushFloatMono($0.baseAddress!, frames: data.count, endHostNs: ns(47999)) }
        var out = [Float](repeating: 0, count: 960)
        var previous: Float = 0; var maxStep: Float = 0
        for block in 0..<10 {
            if block == 2 { input.delayMs = 100 }
            out = [Float](repeating: 0, count: 960)
            out.withUnsafeMutableBufferPointer { input.mix(into: $0.baseAddress!, frames: 480, startHostNs: ns(Double(20000 + block * 480))) }
            for i in 0..<480 {
                if block > 0 { maxStep = max(maxStep, abs(out[i * 2] - previous)) }; previous = out[i * 2]
                if block >= 4 { XCTAssertEqual(out[i * 2], data[20000 + block * 480 + i - 4800], accuracy: 0.0001) }
            }
        }
        XCTAssertLessThan(maxStep, 0.013); XCTAssertEqual(input.driftPPM, 0, accuracy: 1)
        XCTAssertEqual(input.hardCorrections, 0)
    }
    func testLostThirtyMillisecondsInsertsSilence() {
        let input = MixerInput(); let data = [Float](repeating: 0.2, count: 480)
        for block in 0..<100 where !(40..<43).contains(block) {
            data.withUnsafeBufferPointer { input.pushFloatMono($0.baseAddress!, frames: 480, endHostNs: ns(Double(block * 480 + 479))) }
        }
        var out = [Float](repeating: 0, count: 960)
        for block in 39..<45 {
            out = [Float](repeating: 0, count: 960)
            out.withUnsafeMutableBufferPointer { input.mix(into: $0.baseAddress!, frames: 480, startHostNs: ns(Double(block * 480))) }
            XCTAssertEqual(out[400], (40..<43).contains(block) ? 0 : 0.2, accuracy: 0.0001)
        }
        XCTAssertEqual(input.driftPPM, 0, accuracy: 1)
    }
    func testUnderrunsCountTransitionsOnly() {
        let input = MixerInput(); var out = [Float](repeating: 0, count: 960)
        func render(_ frame: Int) { out.withUnsafeMutableBufferPointer { input.mix(into: $0.baseAddress!, frames: 480, startHostNs: ns(Double(frame))) } }
        render(0); render(480); XCTAssertEqual(input.underruns, 0)
        out.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 480, endHostNs: ns(479)) }
        render(0); render(480); render(960); XCTAssertEqual(input.underruns, 1)
    }
    func testCallbackDoesNotHoldParameterLockAndCatchupIsBounded() {
        let mixer = AudioMixer(targetLatencyMs: 0); let input = mixer.addInput("a")
        let data = [Float](repeating: 0.1, count: 192000)
        data.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 96000, endHostNs: ns(95999)) }
        var calls = 0
        mixer.onBlock = { _, _, _ in
            calls += 1
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { mixer.masterGain = 0.5; done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        }
        mixer.render(upTo: ns(96000))
        XCTAssertEqual(calls, 8); XCTAssertGreaterThan(mixer.skippedBlocks, 0)
    }
    func testGainAndMuteRampsAndPreMuteMeter() {
        let mixer = AudioMixer(blockFrames: 480, targetLatencyMs: 0); let input = mixer.addInput("a")
        let data = [Float](repeating: 0.2, count: 4800)
        data.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 2400, endHostNs: ns(2399)) }
        mixer.render(upTo: ns(480)); input.gain = 2
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[0], 0.2 + 0.2 / 480, accuracy: 0.00001); XCTAssertEqual(p[958], 0.4, accuracy: 0.00001) }
        mixer.render(upTo: ns(960)); input.muted = true
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[0], 0.4 - 0.4 / 480, accuracy: 0.00001); XCTAssertEqual(p[958], 0, accuracy: 0.00001) }
        mixer.render(upTo: ns(1440)); XCTAssertEqual(input.meter.peak, 0.4, accuracy: 0.00001)
        input.muted = false; mixer.onBlock = nil; mixer.render(upTo: ns(1920)); mixer.masterGain = 0.5
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[0], 0.4 - 0.2 / 480, accuracy: 0.00001); XCTAssertEqual(p[958], 0.2, accuracy: 0.00001) }
        mixer.render(upTo: ns(2400))
    }
    func testMicrophoneSampleBuffer() throws {
        let input = MixerInput()
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 2, flags: 0, blockBufferOut: &block), noErr)
        for _ in 0..<2 {
            XCTAssertEqual(CMBlockBufferAppendMemoryBlock(block!, memoryBlock: nil, length: 960, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 960, flags: 0), noErr)
        }
        let data = [Float](repeating: 0.25, count: 480)
        data.withUnsafeBytes { XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 1920), noErr) }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: description!, sampleCount: 480, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        input.push(try XCTUnwrap(sample), endHostNs: ns(479))
        var out = [Float](repeating: 0, count: 960)
        out.withUnsafeMutableBufferPointer { input.mix(into: $0.baseAddress!, frames: 480, startHostNs: origin) }
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.25) < 0.00001 }); XCTAssertEqual(input.rejectedBuffers, 0)
        format.mSampleRate = 44100
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: description!, sampleCount: 480, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        input.push(try XCTUnwrap(sample), endHostNs: ns(959)); XCTAssertEqual(input.rejectedBuffers, 1)
    }
    func testInputsSumInInsertionOrder() {
        for _ in 0..<20 {
            let mixer = AudioMixer(blockFrames: 4, targetLatencyMs: 0)
            for (id, value) in [("a", Float(1e8)), ("b", Float(-1e8)), ("c", Float(0.125))] {
                let input = mixer.addInput(id), data = [Float](repeating: value, count: 8)
                data.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 4, endHostNs: ns(3)) }
            }
            mixer.onBlock = { p, _, _ in XCTAssertEqual(p[0], 0.125) }
            mixer.render(upTo: ns(4))
        }
    }
    func testStoppedQueuedHandlerDoesNotRender() {
        let queue = DispatchQueue(label: "blocked.timer")
        let mixer = AudioMixer(blockFrames: 480, targetLatencyMs: 0, queue: queue)
        let calls = expectation(description: "no stopped callback"); calls.isInverted = true
        mixer.onBlock = { _, _, _ in calls.fulfill() }
        queue.suspend(); mixer.start(); Thread.sleep(forTimeInterval: 0.05); mixer.stop(); queue.resume()
        mixer.render(upTo: nowNs(), generation: 1)
        wait(for: [calls], timeout: 0.05)
    }
    func testRestartSkipsStoppedTimeAndStopCancelsQueuedTicks() {
        let mixer = AudioMixer(blockFrames: 480, targetLatencyMs: 0)
        let lock = NSLock(); var starts: [UInt64] = []
        mixer.onBlock = { _, _, start in lock.lock(); starts.append(start); lock.unlock() }
        mixer.start(); Thread.sleep(forTimeInterval: 0.06); mixer.stop()
        Thread.sleep(forTimeInterval: 0.03)
        lock.lock(); let stoppedCount = starts.count; lock.unlock()
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock(); XCTAssertEqual(starts.count, stoppedCount); lock.unlock()
        let restart = nowNs(); mixer.start(); Thread.sleep(forTimeInterval: 0.04); mixer.stop()
        lock.lock(); let resumed = Array(starts.dropFirst(stoppedCount)); lock.unlock()
        XCTAssertFalse(resumed.isEmpty); XCTAssertLessThanOrEqual(resumed.count, 5)
        XCTAssertTrue(resumed.allSatisfy { $0 >= restart })
    }
    func testRealtimeDriver() throws {
        guard ProcessInfo.processInfo.environment["MIXER_REALTIME_TEST"] == "1" else { throw XCTSkip("Opt-in five-second smoke test: MIXER_REALTIME_TEST=1") }
        let mixer = AudioMixer(); let input = mixer.addInput("synthetic")
        let lock = NSLock(); var blocks = 0
        mixer.onBlock = { _, _, _ in lock.lock(); blocks += 1; lock.unlock() }
        let start = nowNs(); mixer.start()
        let queue = DispatchQueue(label: "synthetic.pusher")
        let done = expectation(description: "five seconds")
        queue.async {
            let samples = [Float](repeating: 0.1, count: 960)
            while nowNs() - start < 5_000_000_000 {
                samples.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 480, endHostNs: nowNs()) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 6); mixer.stop()
        lock.lock(); let count = blocks; lock.unlock()
        let expected = Int(5 * 48000 / 1024)
        print("realtime blocks=\(count) expected=\(expected) tolerance=1")
        XCTAssertLessThanOrEqual(abs(count - expected), 1)
    }
}
