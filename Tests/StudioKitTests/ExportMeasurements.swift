import XCTest
import Darwin
@testable import StudioKit

/// Opt-in, always run under /tmp/ehdr-encoder.lock.d against a demo recording.
final class ExportMeasurements: XCTestCase {
    func testMatrix() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["EHDR_MEASURE_PROJECT"], let doc = ProjectDoc.load(URL(fileURLWithPath: path)) else { throw XCTSkip("Set EHDR_MEASURE_PROJECT to a demo recording") }
        let software = env["EHDR_MEASURE_SOFTWARE"] == "1"
        for canvas in Canvas.allCases where env["EHDR_MEASURE_CANVAS"] == nil || env["EHDR_MEASURE_CANVAS"] == canvas.rawValue {
            for range in (software ? [ExportRange.sdr] : [.sdr, .hdr]) where env["EHDR_MEASURE_RANGE"] == nil || env["EHDR_MEASURE_RANGE"] == range.rawValue {
                for run in 1...(Int(env["EHDR_MEASURE_RUNS"] ?? "") ?? 3) {
                    let e = Exporter(doc: doc, job: ExportJob(canvas: canvas, resolution: .hd, range: range, fps: .sixty))
                    e.useSoftwareH264 = software
                    e.onEncoderWaiting = { waiting in if waiting { print("MEASURE state: Waiting for the video encoder") } }
                    let start = Date(), cpu = clock()
                    _ = try await e.run { _ in }
                    let seconds = Date().timeIntervalSince(start)
                    let cpuSeconds = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
                    print(String(format: "MEASURE %@ %@ software=%d run=%d wall=%.3fs CPU=%.3fs (%.1f%%)", canvas.rawValue, range.rawValue, software ? 1 : 0, run, seconds, cpuSeconds, 100 * cpuSeconds / seconds))
                }
            }
        }
    }
    func testTenQueuesWithCancelAndRestart() async throws {
        guard let path = ProcessInfo.processInfo.environment["EHDR_MEASURE_PROJECT"], let doc = ProjectDoc.load(URL(fileURLWithPath: path)) else { throw XCTSkip("Set EHDR_MEASURE_PROJECT") }
        for run in 0..<10 {
            let drained = expectation(description: "queue \(run)")
            let start = Date()
            let queue = await MainActor.run { ExportQueue { Exporter(doc: doc, job: $0) } }
            await MainActor.run {
                let jobs = [("YouTube", ExportPreset.youtube.jobs(for: doc.project, custom: .init())[0]),
                            ("Shorts", ExportPreset.shorts.jobs(for: doc.project, custom: .init())[0])]
                queue.onDrained = { drained.fulfill() }
                queue.enqueue(jobs)
                if run % 2 == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        queue.cancelAll()
                        XCTAssertEqual(queue.enqueue(jobs), 2)
                    }
                }
            }
            await fulfillment(of: [drained], timeout: 900)
            let items = await MainActor.run { queue.items }
            let completed = items.filter { if case .done = $0.state { return true }; return false }.count
            XCTAssertEqual(completed, 2)
            print("MEASURE queue \(run): \(Date().timeIntervalSince(start))s states=\(items.map { String(describing: $0.state) })")
        }
    }

}
