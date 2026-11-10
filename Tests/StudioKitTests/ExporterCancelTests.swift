import XCTest
import AVFoundation
@testable import StudioKit

/// The real exporter on the fixture recording: a cancel at any moment returns promptly and leaves no file, a cancel
/// before the start prevents it, and an export that stops producing fails as stalled instead of hanging the queue.
final class ExporterCancelTests: XCTestCase {
    private static var shared: (dir: URL, doc: ProjectDoc)?

    /// One fixture for the class (it records in real time): cuts, a zoom and a scene change, as the editor makes them.
    private func fixture() async throws -> ProjectDoc {
        try TimelineExportTests().requireHardware()
        if let s = Self.shared { return s.doc }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Cancel-" + UUID().uuidString)
        let doc = try await FixtureProject.make(at: dir, frameCount: 150)
        let game = Composition(layers: [Layer(source: .game, fit: true)])
        let pip = Composition(layers: [Layer(source: .game, fit: true), Layer(source: .camera, frame: NRect(x: 0.65, y: 0.1, w: 0.3, h: 0.3))])
        let a = Scene(name: "Game", wide: game, vertical: game), b = Scene(name: "Camera", wide: pip, vertical: pip)
        doc.project.scenes = [a, b]
        doc.project.timeline = Timeline(segments: [Segment(startMs: 0, endMs: 500), Segment(startMs: 750, endMs: 2500)],
            sceneSpans: [SceneSpan(startMs: 0, sceneID: a.id), SceneSpan(startMs: 1900, sceneID: b.id, transition: SceneTransition(style: .fade, durationMs: 100))],
            zooms: [ZoomBlock(startMs: 1000, endMs: 1700, scale: 1.8)])
        Self.shared = (dir, doc)
        return doc
    }
    override class func tearDown() {
        if let s = shared { try? FileManager.default.removeItem(at: s.dir) }
        shared = nil
        super.tearDown()
    }

    /// The task's result, or nil if it has not finished within `seconds`: the test then fails instead of hanging on
    /// an export that never returns (a task group would wait for it).
    private func result(of task: Task<URL, Error>, within seconds: Double) async -> Result<URL, Error>? {
        final class First: @unchecked Sendable {
            private let lock = NSLock(); private var c: CheckedContinuation<Result<URL, Error>?, Never>?
            init(_ c: CheckedContinuation<Result<URL, Error>?, Never>) { self.c = c }
            func resume(_ r: Result<URL, Error>?) { lock.lock(); let k = c; c = nil; lock.unlock(); k?.resume(returning: r) }
        }
        return await withCheckedContinuation { c in
            let first = First(c)
            Task { first.resume(await task.result) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); first.resume(nil) }
        }
    }

    func testThirtyCancelsAtRandomTimesReturnPromptlyAndLeaveNoFile() async throws {
        let doc = try await fixture()
        let jobs = [ExportJob(canvas: .wide, resolution: .uhd, range: .hdr, fps: .source),
                    ExportJob(canvas: .vertical, resolution: .hd, range: .sdr, fps: .sixty),
                    ExportJob(canvas: .wide, resolution: .hd, range: .hdr, fps: .source)]
        var rng = SeededRandom(state: 2026)
        let delays = (0..<30).map { _ in Double.random(in: 0...2, using: &rng) }
        let dir = doc.exportsDir.appendingPathComponent("cancels")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        struct Outcome { var delay: Double; var returnedAfter: Double?; var cancelled: Bool; var fileLeft: Bool; var error: String? }
        var outcomes: [Outcome] = []
        // Five at a time keeps the run short and the exports slow enough that late cancels still land mid-export.
        for batch in stride(from: 0, to: delays.count, by: 5) {
            let results = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
                for i in batch..<min(delays.count, batch + 5) {
                    let out = dir.appendingPathComponent("cancel-\(i).mp4")
                    let e = Exporter(doc: doc, job: jobs[i % jobs.count], output: out)
                    group.addTask {
                        let task = Task { try await e.run { _ in } }
                        try? await Task.sleep(nanoseconds: UInt64(delays[i] * 1e9))
                        let t0 = Date()
                        e.cancel()
                        let r = await self.result(of: task, within: 10)
                        let after = r == nil ? nil : Date().timeIntervalSince(t0)
                        let exists = FileManager.default.fileExists(atPath: out.path)
                        switch r {
                        case .success?: return Outcome(delay: delays[i], returnedAfter: after, cancelled: false, fileLeft: exists, error: nil)
                        case .failure(let e)?: return Outcome(delay: delays[i], returnedAfter: after, cancelled: true, fileLeft: exists, error: e.localizedDescription)
                        case nil: return Outcome(delay: delays[i], returnedAfter: nil, cancelled: true, fileLeft: exists, error: "did not return")
                        }
                    }
                }
                var all: [Outcome] = []
                for await o in group { all.append(o) }
                return all
            }
            outcomes += results
        }
        for o in outcomes {
            let label = String(format: "cancel at %.3f s", o.delay)
            let after = try XCTUnwrap(o.returnedAfter, "\(label): run never returned")
            XCTAssertLessThan(after, 2, "\(label): returned \(after) s after cancel")
            if o.cancelled {
                XCTAssertEqual(o.error, "Export cancelled", label)
                XCTAssertFalse(o.fileLeft, "\(label): a cancelled export leaves no file")
            } else {
                XCTAssertTrue(o.fileLeft, "\(label): finished before the cancel arrived, so its file stays")
            }
        }
        // A cancel that landed while the writer was still starting finishes its teardown just after `run` returned.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).count
        XCTAssertEqual(left, outcomes.filter { !$0.cancelled }.count, "only exports that finished before their cancel left a file")
        let cancelled = outcomes.filter(\.cancelled).count, worst = outcomes.compactMap(\.returnedAfter).max() ?? 0
        XCTAssertGreaterThanOrEqual(cancelled, 20, "most cancels land while exporting")
        print(String(format: "Exporter cancels: %d runs, %d cancelled mid-export, %d finished before the cancel, slowest return %.3f s after cancel",
                     outcomes.count, cancelled, outcomes.count - cancelled, worst))
    }

    func testCancelBeforeStartPreventsTheStart() async throws {
        let doc = try await fixture()
        let out = doc.exportsDir.appendingPathComponent("before-start.mp4")
        try FileManager.default.createDirectory(at: doc.exportsDir, withIntermediateDirectories: true)
        try Data("an earlier export".utf8).write(to: out)
        let e = Exporter(doc: doc, job: ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source), output: out)
        e.cancel()
        let t0 = Date()
        do { _ = try await e.run { _ in XCTFail("no progress after a cancel") }; XCTFail("a cancelled export must not run") }
        catch { XCTAssertEqual(error.localizedDescription, "Export cancelled") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        XCTAssertEqual(try Data(contentsOf: out), Data("an earlier export".utf8), "nothing was started, so the file there is untouched")
    }

    func testStalledPumpTripsTheWatchdog() async throws {
        let doc = try await fixture()
        let out = doc.exportsDir.appendingPathComponent("stalled.mp4")
        let e = Exporter(doc: doc, job: ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source), output: out)
        e.stallTimeout = 1
        e.startPump = { _ in }    // never produces
        let t0 = Date()
        let task = Task { try await e.run { _ in } }
        let r = await result(of: task, within: 10)
        let elapsed = Date().timeIntervalSince(t0)
        guard case .failure(let error)? = r else { return XCTFail("a stalled export must fail, got \(String(describing: r))") }
        XCTAssertEqual(error.localizedDescription, "Export stalled: no progress for 1 seconds")
        XCTAssertGreaterThanOrEqual(elapsed, 1)
        XCTAssertLessThan(elapsed, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the partial file is deleted")
    }

    /// The queue resolves every item, whatever its exporter does, and the editor's lock follows it.
    func testQueueResolvesCancelledStalledAndFinishedJobs() async throws {
        let doc = try await fixture()
        let jobs = [ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source),
                    ExportJob(canvas: .vertical, resolution: .hd, range: .sdr, fps: .sixty),
                    ExportJob(canvas: .wide, resolution: .hd, range: .hdr, fps: .source)]
        let queue = await MainActor.run {
            ExportQueue { job in
                let e = Exporter(doc: doc, job: job)
                if job.canvas == .vertical { e.stallTimeout = 1; e.startPump = { _ in } }
                return e
            }
        }
        final class Box: @unchecked Sendable { var items: [ExportQueue.Item] = [] }
        let box = Box(), drained = expectation(description: "every item resolved")
        await MainActor.run {
            queue.onFinished = { box.items.append($0) }
            queue.onDrained = { drained.fulfill() }
            queue.enqueue([("A", jobs[0]), ("B", jobs[1]), ("C", jobs[2])])
            let first = queue.items[0].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { queue.cancel(first) }
        }
        await fulfillment(of: [drained], timeout: 30)
        let finished = await MainActor.run { box.items }
        let states = finished.map { "\($0.title): \($0.state)" }
        XCTAssertEqual(finished.count, 3, "\(states)")
        guard finished.count == 3 else { return }
        XCTAssertEqual(finished[0].state, .cancelled)
        XCTAssertEqual(finished[1].state, .failed("Export stalled: no progress for 1 seconds"))
        if case .done = finished[2].state {} else { XCTFail("C: \(finished[2].state)") }
        let running = await MainActor.run { queue.isRunning }
        XCTAssertFalse(running, "edits unlock once every item is resolved")
    }
}

/// A runner that ignores cancel entirely: the queue still resolves the job after its grace period.
final class ExportQueueGraceTests: XCTestCase {
    final class Deaf: ExportRunning {
        func run(progress: @escaping (Double) -> Void) async throws -> URL {
            try await Task.sleep(nanoseconds: 30_000_000_000); return URL(fileURLWithPath: "/tmp/late.mp4")
        }
        func cancel() {}
    }
    func testCancelledJobThatNeverReturnsIsResolved() {
        let q = ExportQueue { _ in Deaf() }
        q.cancelGrace = 0.3
        let drained = expectation(description: "drained")
        q.onDrained = { drained.fulfill() }
        q.enqueue([("Stuck", ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source))])
        q.cancel(q.items[0].id)
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(q.items.map(\.state), [.cancelled])
        XCTAssertFalse(q.isRunning)
    }
}

/// A seeded generator, so a failing cut set can be reproduced.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
