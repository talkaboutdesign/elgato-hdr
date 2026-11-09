import XCTest
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
        mixer.onBlock = { p, frames, start in
            XCTAssertEqual(start, input.startNs! + UInt64(Double(outputFrames) * 1e9 / 48000))
            for i in 0..<frames {
                if let previous, outputFrames > 48000 { maxStep = max(maxStep, abs(p[i * 2] - previous)) }
                previous = p[i * 2]
                let expected = 0.2 * sin(2 * .pi * 440 * Double(outputFrames + i) / 48000)
                squaredError += pow(Double(p[i * 2]) - expected, 2)
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
                data.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: chunk, endHostNs: origin + UInt64(end * 1e9)) }
                next += chunk
            }
            mixer.render(upTo: origin + UInt64(time * 1e9))
            if tick == 1000 { missesAtOne = input.underruns }
        }
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
    func testJitter120Seconds() { simulate(ppm: 300, jitter: true, seconds: 120) }

    func testGainMuteMetersTwoInputsAndClip() {
        let mixer = AudioMixer(blockFrames: 480, targetLatencyMs: 0)
        let a = mixer.addInput("a"); let b = mixer.addInput("b")
        let values = [Float](repeating: 0.2, count: 4800)
        for input in [a, b] { values.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 2400, endHostNs: ns(2399)) } }
        var expected: Float = 0.3
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[0], expected, accuracy: 0.00001) }
        a.gain = 0.5; mixer.render(upTo: ns(480))
        XCTAssertEqual(a.meter.rms, 0.1, accuracy: 0.00001); XCTAssertEqual(mixer.masterMeter.peak, 0.3, accuracy: 0.00001)
        a.muted = true; expected = 0.2; mixer.render(upTo: ns(960)); XCTAssertEqual(a.meter.peak, 0)
        mixer.masterGain = 0.5; expected = 0.1; mixer.render(upTo: ns(1440))
        a.muted = false; a.gain = 4; b.gain = 4; mixer.masterGain = 4
        mixer.onBlock = { p, _, _ in XCTAssertGreaterThan(p[0], 0.891); XCTAssertLessThan(p[0], 1) }
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
        mixer.render(upTo: ns(12000)); XCTAssertGreaterThan(input.underruns, 1)
        input.delayMs = 0
        values.withUnsafeBufferPointer { input.push($0.baseAddress!, frames: 1440, endHostNs: ns(13439)) }
        mixer.onBlock = { p, _, _ in XCTAssertEqual(p[200], 0.01, accuracy: 0.00001) }
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
        #if !DEBUG
        XCTAssertLessThan(ms, 0.2)
        #endif
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
        let expected = Int((5 - 0.060) * 48000 / 1024)
        print("realtime blocks=\(count) expected=\(expected) tolerance=1")
        XCTAssertLessThanOrEqual(abs(count - expected), 1)
    }
}
