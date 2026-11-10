import XCTest
import CoreGraphics
@testable import StudioKit

final class EditorRecheckTests: XCTestCase {
    func testRecordingPreparationPreservesLiveScenesAndOverlays() throws {
        var p = Project(name: "Live", createdAt: Date())
        let overlay = Layer(source: LayerSource(type: "image", file: "overlay.png"), frame: NRect(x: 0.6, y: 0.1, w: 0.3, h: 0.3))
        p.scenes = (0..<4).map { Scene(name: "Scene \($0)", wide: Composition(layers: [Layer(source: .game), overlay]), vertical: Composition(layers: [overlay])) }
        let live = p.scenes
        p.ensureRecordingScene()
        XCTAssertEqual(p.scenes, live)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.scenes, live)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("overlay.png"))
        let assets = root.appendingPathComponent("Assets")
        XCTAssertTrue(AssetStore.bundle(AssetStore.referencedFiles(p.scenes), into: assets, from: [root]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("overlay.png")), Data([1, 2, 3]))
        p.scenes = []; p.ensureRecordingScene()
        XCTAssertEqual(p.scenes.count, 1)
    }

    func testStalePartialsRemoveDeadOwnersAndPreserveLiveOwnersAndPublishedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dead = dir.appendingPathComponent(".export-2147483647-00000000-0000-0000-0000-000000000000.mp4")
        let live = dir.appendingPathComponent(".export-\(ProcessInfo.processInfo.processIdentifier)-00000000-0000-0000-0000-000000000000.mp4")
        let published = dir.appendingPathComponent("published.mp4")
        for url in [dead, live, published] { try Data([1]).write(to: url) }
        Exporter.removeStalePartials(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
    }

    func testCameraBoundaryFadesToGameOnlyAndAvailabilityMorphStartsFromCurrentFrame() {
        let size = CGSize(width: 100, height: 100)
        let c = Composition(layers: [Layer(source: .game, frame: NRect(x: 0, y: 0.3, w: 1, h: 0.7)), Layer(source: .camera, frame: NRect(x: 0, y: 0, w: 1, h: 0.3))])
        let scene = Scene(name: "Split", wide: c, vertical: c)
        let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: size), .camera: SourceInfo(size: size)]
        var plan = RenderPlan(scenes: [scene], timeline: Timeline(), map: TimeMap(segments: [], sourceDurationMs: 2000), canvas: .wide, canvasSize: size, sources: sources, mirrorCamera: false)
        plan.cameraRanges = [Segment(startMs: 0, endMs: 1000)]
        XCTAssertEqual(plan.layers(atTimelineMs: 925).first { $0.key == .camera }?.opacity, 0.5)
        XCTAssertFalse(plan.layers(atTimelineMs: 1000).contains { $0.key == .camera })
        XCTAssertEqual(plan.layers(atTimelineMs: 1000).first?.dst, CGRect(origin: .zero, size: size))
        let old = LiveSceneState(scene: scene)
        let changed = old.changingSources(atNs: 1000, transition: SceneTransition(style: .morph, durationMs: 380), previous: sources)
        let absent: [SourceKey: SourceInfo] = [.game: SourceInfo(size: size)]
        let start = changed.layers(canvas: .wide, size: size, sources: absent, atNs: 1000)
        let end = changed.layers(canvas: .wide, size: size, sources: absent, atNs: 380_001_000)
        XCTAssertEqual(start.first?.dst, c.layers[0].frame.rect(in: size))
        XCTAssertEqual(end.first?.dst, CGRect(origin: .zero, size: size))
    }

    func testScriptFixtureIgnoresOnlyKnownAdditionalDefaults() {
        let base = "{}"
        let defaults = #"{"frameWidth":0,"frameColor":[0.42,0.49,1,1],"sceneTransition":{"style":"morph","durationMs":380}}"#
        XCTAssertEqual(EditorScriptTests.normalize(base), EditorScriptTests.normalize(defaults))
        XCTAssertNotEqual(EditorScriptTests.normalize(base), EditorScriptTests.normalize(#"{"frameWidth":0.1}"#))
    }

    func testHoverLoaderRestartsWithNewestProjectWhenOldLoadCompletes() async {
        let first = Once<Bool>(), started = expectation(description: "first started"), restarted = expectation(description: "new generation")
        let loader = await MainActor.run { ScrubFrameLoader() }
        await MainActor.run {
            var old = Project(name: "Old", createdAt: Date()); old.state = "complete"; old.durationMs = 1000
            var latest = old; latest.durationMs = 2000
            let doc = ProjectDoc(dir: URL(fileURLWithPath: "/tmp/hover-test"), project: latest)
            loader.load = { _, project in
                if project.durationMs == 1000 { started.fulfill(); _ = await first.wait() }
                else { XCTAssertEqual(project.durationMs, 2000); restarted.fulfill() }
                return []
            }
            loader.request(doc: doc, project: old)
            DispatchQueue.main.async { loader.request(doc: doc, project: latest) }
        }
        await fulfillment(of: [started], timeout: 1)
        first.resolve(true)
        await fulfillment(of: [restarted], timeout: 1)
    }

    func testWatchdogExcludesEncoderWaitButEnforcesHardLimit() {
        var w = ExportWatchdog()
        XCTAssertFalse(w.expired(now: 0, idle: 0, waiting: false, stall: 20, hardLimit: 600))
        XCTAssertFalse(w.expired(now: 100, idle: 100, waiting: true, stall: 20, hardLimit: 600))
        XCTAssertFalse(w.expired(now: 110, idle: 110, waiting: false, stall: 20, hardLimit: 600))
        XCTAssertTrue(w.expired(now: 120, idle: 120, waiting: false, stall: 20, hardLimit: 600))
        var hard = ExportWatchdog()
        XCTAssertTrue(hard.expired(now: 600, idle: 600, waiting: true, stall: 20, hardLimit: 600))
    }

    func testClosingGateWaitsForPumpAndRejectsNewWork() {
        let gate = WriterGate()
        XCTAssertTrue(gate.enter())
        let closed = expectation(description: "drained")
        let blocked = expectation(description: "still blocked"); blocked.isInverted = true
        DispatchQueue.global().async { gate.closeAndWait(); blocked.fulfill(); closed.fulfill() }
        wait(for: [blocked], timeout: 0.1)
        XCTAssertFalse(gate.enter())
        gate.leave()
        wait(for: [closed], timeout: 1)
        XCTAssertNil(gate.run { 42 })
    }

    func testCancelAndRequeueWaitsForTeardown() {
        final class Runner: ExportRunning {
            let done = Once<Bool>()
            func run(progress: @escaping (Double) -> Void) async throws -> URL {
                _ = await done.wait(); throw CompositionBuilder.err("cancelled")
            }
            func cancel() {}
        }
        let first = Runner(), second = Runner()
        var starts = 0
        let q = ExportQueue { _ in starts += 1; return starts == 1 ? first : second }
        let job = ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source)
        q.enqueue([("first", job)])
        q.cancel(q.items[0].id)
        XCTAssertEqual(q.enqueue([("restart", job)]), 1)
        XCTAssertEqual(q.items[1].state, .waiting)
        XCTAssertEqual(starts, 1)
        let next = expectation(description: "next after teardown")
        q.onFinished = { _ in DispatchQueue.main.async { next.fulfill() } }
        first.done.resolve(true)
        wait(for: [next], timeout: 2)
        XCTAssertEqual(starts, 2)
        q.onFinished = nil; second.done.resolve(true)
    }

    func testOnlyLargestGameExpandsForVisibleMissingCamera() {
        let main = Layer(source: .game, frame: NRect(x: 0, y: 0.3, w: 1, h: 0.7))
        let mini = Layer(source: .game, frame: NRect(x: 0.7, y: 0.7, w: 0.2, h: 0.2))
        var camera = Layer(source: .camera)
        let size = CGSize(width: 100, height: 100)
        let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: size)]
        func resolve() -> [ResolvedLayer] { SceneResolver.resolve(Composition(layers: [main, mini, camera]), canvas: size, sources: sources) }
        XCTAssertEqual(resolve()[0].dst, CGRect(origin: .zero, size: size))
        XCTAssertEqual(resolve()[1].dst, mini.frame.rect(in: size))
        camera.visible = false
        XCTAssertEqual(resolve()[0].dst, main.frame.rect(in: size))
        camera.visible = true; camera.opacity = 0
        XCTAssertEqual(resolve()[0].dst, main.frame.rect(in: size))
    }

    func testEditorAndLiveTransitionsMatchBothCanvasesAtTenPoints() {
        let a = Scene(name: "A", wide: Composition(layers: [Layer(source: .game)]), vertical: Composition(layers: [Layer(source: .camera)]))
        let b = Scene(name: "B", wide: a.vertical, vertical: a.wide)
        let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 1920, height: 1080)), .camera: SourceInfo(size: CGSize(width: 640, height: 480))]
        for style in [SceneTransition.Style.cut, .fade, .morph] {
            let transition = SceneTransition(style: style, durationMs: 900)
            var live = LiveSceneState(scene: b); live.from = a; live.transition = transition
            for c in Canvas.allCases { for i in 0..<10 {
                let p = Double(i) / 9
                XCTAssertEqual(RenderPlan.transitionLayers(from: a, to: b, transition: transition, progress: p, canvas: c, size: c.size(.hd), sources: sources),
                               live.layers(canvas: c, size: c.size(.hd), sources: sources, atNs: UInt64(i) * 100_000_000))
            } }
        }
    }
}
