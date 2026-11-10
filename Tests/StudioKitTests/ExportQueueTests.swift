import XCTest
@testable import StudioKit

/// Completes when its gate opens (or at once), recording the order jobs ran in.
final class FakeRunner: ExportRunning {
    final class Gate { var open = false; var log: [String] = [] }
    let gate: Gate
    let name: String
    let fail: Bool
    private var cancelled = false
    init(gate: Gate, name: String = "", fail: Bool = false) { self.gate = gate; self.name = name; self.fail = fail }
    func run(progress: @escaping (Double) -> Void) async throws -> URL {
        gate.log.append("start \(name)")
        progress(0.5)
        while !gate.open && !cancelled { try await Task.sleep(nanoseconds: 2_000_000) }
        if cancelled { throw CompositionBuilder.err("cancelled") }
        if fail { throw CompositionBuilder.err("disk full") }
        return URL(fileURLWithPath: "/tmp/\(name).mp4")
    }
    func cancel() { cancelled = true }
}

final class ExportQueueTests: XCTestCase {
    let wide4k = ExportJob(canvas: .wide, resolution: .uhd, range: .hdr, fps: .source)
    let wide1080 = ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source)
    let shorts = ExportJob(canvas: .vertical, resolution: .hd, range: .sdr, fps: .sixty)

    func name(_ j: ExportJob) -> String { ExportPreset.fileKey(j) }

    func testRunsInQueueOrderOneAtATimeAndAppends() {
        let gate = FakeRunner.Gate(); gate.open = true
        var finished: [String] = []
        let q = ExportQueue { j in FakeRunner(gate: gate, name: self.name(j), fail: j == self.wide1080) }
        let drained = expectation(description: "drained")
        q.onFinished = { finished.append("\($0.title):\($0.state == .failed("disk full") ? "failed" : "ok")") }
        q.onDrained = { drained.fulfill() }
        XCTAssertEqual(q.enqueue([("YouTube", wide4k), ("Shorts", shorts)]), 2)
        XCTAssertEqual(q.enqueue([("YouTube again", wide4k), ("1080p", wide1080)]), 1, "a job writing the same file is not queued twice")
        XCTAssertEqual(q.items.map(\.title), ["YouTube", "Shorts", "1080p"])
        XCTAssertEqual(q.items.filter { $0.state == .running }.count, 1, "one at a time")
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(gate.log, ["start wide-uhd-hdr", "start vertical-hd-sdr", "start wide-hd-sdr"])
        XCTAssertEqual(finished, ["YouTube:ok", "Shorts:ok", "1080p:failed"], "a failure does not stop the queue; order is kept")
        XCTAssertFalse(q.isRunning)
        XCTAssertEqual(q.overallProgress, 1)
    }

    func testCancelWaitingAndRunning() {
        let gate = FakeRunner.Gate()
        let q = ExportQueue { j in FakeRunner(gate: gate, name: self.name(j)) }
        let drained = expectation(description: "drained")
        q.onDrained = { drained.fulfill() }
        q.enqueue([("A", wide4k), ("B", shorts), ("C", wide1080)])
        q.cancel(q.items[1].id)
        XCTAssertEqual(q.items[1].state, .cancelled)
        q.cancel(q.items[0].id)                // the running one: the runner is told to stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { gate.open = true }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(q.items.map(\.state), [.cancelled, .cancelled, .done(URL(fileURLWithPath: "/tmp/wide-hd-sdr.mp4"))])
        XCTAssertEqual(gate.log, ["start wide-uhd-hdr", "start wide-hd-sdr"], "a cancelled waiting job never starts")
    }

    func testPresetJobsFollowTheSource() {
        var p = Project(name: "P", createdAt: Date())
        p.width = 2560; p.height = 1440; p.colorMode = ColorMode.pq.rawValue
        let custom = ExportPreset.Custom(canvases: [.vertical, .wide], resolution: .hd, range: .hdr, fps: .thirty)
        XCTAssertEqual(ExportPreset.youtube.jobs(for: p, custom: custom), [wide4k])
        XCTAssertEqual(ExportPreset.youtube1080.jobs(for: p, custom: custom), [wide1080])
        XCTAssertEqual(ExportPreset.shorts.jobs(for: p, custom: custom), [shorts])
        XCTAssertEqual(ExportPreset.custom.jobs(for: p, custom: custom).map(\.canvas), [.wide, .vertical], "canvas order is fixed")
        p.height = 1080; p.colorMode = ColorMode.sdr.rawValue
        XCTAssertEqual(ExportPreset.youtube.jobs(for: p, custom: custom), [ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source)],
                       "1080p SDR source: no 4K, no HDR")
        XCTAssertEqual(ExportPreset.custom.jobs(for: p, custom: custom).first?.range, .sdr)
    }

    func testModelQueuesPresetsInSheetOrder() {
        let m = makeEditorModel()
        let gate = FakeRunner.Gate()
        m.exportQueue = ExportQueue { j in FakeRunner(gate: gate, name: self.name(j)) }
        m.startExport([.shorts, .youtube1080, .youtube], custom: ExportPreset.Custom())
        XCTAssertEqual(m.exportQueue.items.map(\.title), ["YouTube", "YouTube 1080p SDR", "Shorts, Reels, TikTok"])
        m.exportQueue.cancelAll()
    }
}
