import XCTest
@testable import StudioKit

/// The audio clock follower on its own: simulated devices, no writer.
final class AudioClockTests: XCTestCase {
    /// A device delivering 768-sample chunks (16 ms, as the capture helper flushes) from a sample clock `ppm` fast
    /// against the host, each stamped on arrival with a latency uniform in 0...2×`jitterMs`.
    struct Device {
        var ppm = 0.0, jitterMs = 0.0, chunk = 768
        var rng = SplitMix(seed: 11)
        var produced = 0
        var rate: Double { 48000 * (1 + ppm / 1e6) }
        /// Host seconds at which the chunk's last sample was really produced, and when it arrived.
        mutating func next() -> (trueEnd: Double, arrival: Double) {
            produced += chunk
            let t = Double(produced) / rate
            return (t, t + rng.uniform() * 2 * jitterMs / 1000)
        }
        /// Samples the device produced that never reach the host.
        mutating func lose(_ samples: Int) { produced += samples }
        var meanLatency: Double { jitterMs / 1000 }
    }

    struct Run { var maxError = 0.0, finalError = 0.0, steps: [AudioClock.Step] = [], errors: [(Double, Double)] = [] }

    /// Feeds `seconds` of chunks; `event(t, &device)` may change the device (loss, stall) as time passes. The error is
    /// where the clock put the end of each chunk minus where it really belongs (true time plus typical latency).
    func simulate(_ device: inout Device, seconds: Double, skipFirst: Double = 0, event: ((Double, inout Device) -> Double)? = nil) -> (AudioClock, Run) {
        var clock = AudioClock(), run = Run()
        while true {
            var (trueEnd, arrival) = device.next()
            if trueEnd > seconds { break }
            if let event { arrival += event(trueEnd, &device) }
            let step = clock.place(frames: device.chunk, end: arrival)
            run.steps.append(step)
            let error = clock.next - (trueEnd + device.meanLatency)
            run.errors.append((trueEnd, error))
            if trueEnd >= skipFirst { run.maxError = max(run.maxError, abs(error)) }
            run.finalError = error
        }
        return (clock, run)
    }

    func testFollowsAFastAndASlowClockForAnHour() {
        for ppm in [100.0, -100.0] {
            var device = Device(ppm: ppm, jitterMs: 4)
            let (clock, run) = simulate(&device, seconds: 3600)
            XCTAssertLessThan(run.maxError, 0.010, "\(ppm) ppm")
            XCTAssertLessThan(abs(run.finalError), 0.005, "\(ppm) ppm")
            // A fast device writes too many samples: the clock must take out about 100 ppm of them, and vice versa.
            let expected = -ppm / 1e6 * 48000 * 3600
            XCTAssertEqual(Double(clock.slewed), expected, accuracy: abs(expected) * 0.05, "\(ppm) ppm")
            XCTAssertEqual(clock.gaps, 0)
            // Never more than one sample per 16 ms chunk: 1300 ppm at most, inaudible.
            XCTAssertLessThanOrEqual(run.steps.map { max($0.insert, $0.remove) }.max() ?? 0, 1)
        }
    }

    func testArrivalJitterAloneCorrectsNothing() {
        var device = Device(jitterMs: 8)
        let (clock, run) = simulate(&device, seconds: 3600)
        XCTAssertEqual(run.steps.dropFirst().filter { !$0.isEmpty }.count, 0)
        XCTAssertEqual(clock.slewed, 0); XCTAssertEqual(clock.gaps, 0)
        XCTAssertLessThan(run.maxError, 0.010)
    }

    /// The bug this type replaces: one sustained 3 ms error (3 ms of samples lost) made the old slew drop 1% of every
    /// chunk for the rest of the recording. The error has to shrink, and never grow past where it started.
    func testASmallErrorShrinksInsteadOfRunningAway() {
        var device = Device(jitterMs: 1)
        var lost = false
        let (clock, run) = simulate(&device, seconds: 600) { t, d in
            if t > 30 && !lost { d.lose(144); lost = true }
            return 0
        }
        let after = run.errors.filter { $0.0 > 30.1 }.map { abs($0.1) }
        XCTAssertGreaterThan(after.first ?? 0, 0.0025)
        XCTAssertLessThan(after.max() ?? 1, 0.0045)
        XCTAssertLessThan(abs(run.errors.first { $0.0 > 90 }?.1 ?? 1), 0.001, "recovered within a minute")
        XCTAssertLessThan(abs(run.finalError), 0.001)
        XCTAssertEqual(clock.slewed, 144, accuracy: 30)
        XCTAssertEqual(clock.gaps, 0)
    }

    func testAHalfSecondGapIsFilledWithSilenceInOneStep() {
        var device = Device(jitterMs: 4)
        var lost = false
        let (clock, run) = simulate(&device, seconds: 120) { t, d in
            if t > 60 && !lost { d.lose(24000); lost = true }
            return 0
        }
        XCTAssertEqual(clock.gaps, 1)
        XCTAssertEqual(Double(clock.filled), 24000, accuracy: 480)
        // The samples after 60 s resume at 60.5 s; a quarter second of chunks that agree confirms the gap, and the clock
        // is inside 10 ms from then on.
        let late = run.errors.filter { $0.0 > 60.5 + AudioClock.gapConfirm + 0.017 }.map { abs($0.1) }
        XCTAssertLessThan(late.max() ?? 1, 0.010)
        XCTAssertEqual(run.steps.filter { $0.silence > 0 }.count, 1)
    }

    /// Audio running ahead (the first chunk arrived late, then the rest on time) is cut, not slewed for a minute.
    func testALateFirstChunkIsCutBackOnce() {
        var device = Device(jitterMs: 2)
        var first = true
        let (clock, run) = simulate(&device, seconds: 30) { _, _ in
            defer { first = false }
            return first ? 0.080 : 0
        }
        XCTAssertEqual(clock.gaps, 1)
        XCTAssertEqual(Double(clock.cut), 0.080 * 48000, accuracy: 480)
        XCTAssertLessThan(run.errors.filter { $0.0 > 0.4 }.map { abs($0.1) }.max() ?? 1, 0.010)
    }

    /// A USB stall holds chunks back and then delivers them in a burst: no data is lost, so nothing may be inserted.
    func testAStallIsNotAGap() {
        var device = Device(jitterMs: 2)
        let (clock, run) = simulate(&device, seconds: 120) { t, _ in
            // Every 20 s, 120 ms of chunks arrive together at the end of the stall.
            let phase = t.truncatingRemainder(dividingBy: 20)
            return phase > 10 && phase < 10.12 ? 10.12 - phase : 0
        }
        XCTAssertEqual(clock.gaps, 0); XCTAssertEqual(clock.filled, 0); XCTAssertEqual(clock.cut, 0)
        XCTAssertLessThan(abs(clock.slewed), 10)
        XCTAssertLessThan(run.errors.filter { $0.0 > 5 }.map { abs($0.1) }.max() ?? 1, 0.010)
    }

    func testWriterBackpressureBecomesSilence() {
        var clock = AudioClock()
        _ = clock.place(frames: 768, end: 0.016)
        clock.lost(frames: 768)
        let step = clock.place(frames: 768, end: 0.048)
        XCTAssertEqual(step.silence, 768)
        XCTAssertEqual(clock.next, 0.048, accuracy: 1e-9)
    }

    func testSamplesBeforeTheRecordingAreTrimmed() {
        var clock = AudioClock()
        let step = clock.place(frames: 768, end: 0.008)
        XCTAssertEqual(step.discard, 384)
        XCTAssertEqual(clock.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(clock.next, 0.008, accuracy: 1e-9)
    }

    func testApplyKeepsTheCountsTheClockPromised() {
        let src: [Float] = (0..<768).map { Float($0) }
        for step in [AudioClock.Step(insert: 3), AudioClock.Step(remove: 3), AudioClock.Step(discard: 100, silence: 50, insert: 1),
                     AudioClock.Step(remove: 192)] {
            let out = src.withUnsafeBufferPointer { step.apply(to: $0, channels: 1, zero: 0) { ($0 + $1) / 2 } }
            XCTAssertEqual(out.count, step.silence + 768 - step.discard + step.insert - step.remove, "\(step)")
            // Still a ramp: every inserted or merged sample sits between its neighbours.
            let body = Array(out.dropFirst(step.silence))
            XCTAssertEqual(body, body.sorted(), "\(step)")
        }
        let stereo: [Int16] = (0..<200).flatMap { [Int16($0), Int16(-$0)] }
        let out = stereo.withUnsafeBufferPointer { AudioClock.Step(insert: 2).apply(to: $0, channels: 2, zero: 0) { Int16((Int32($0) + Int32($1)) / 2) } }
        XCTAssertEqual(out.count, 404)
        for i in stride(from: 0, to: out.count, by: 2) { XCTAssertEqual(out[i], -out[i + 1]) }
    }
}
