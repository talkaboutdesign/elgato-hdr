import XCTest
import AVFoundation
@testable import StudioKit

final class DemoExportStressTests: XCTestCase {
    func testDemoQueues() async throws {
        guard let path = ProcessInfo.processInfo.environment["EHDR_STRESS_PROJECT"], let doc = ProjectDoc.load(URL(fileURLWithPath: path)) else {
            throw XCTSkip("Opt-in real demo recording: EHDR_STRESS_PROJECT")
        }
        doc.project.timeline.segments = [Segment(startMs: 0, endMs: 1500), Segment(startMs: 2500, endMs: doc.project.durationMs)]
        doc.project.timeline.zooms = [ZoomBlock(startMs: 3000, endMs: 6000, scale: 1.8)]
        let scene = Scene(name: "Game only", wide: Composition(layers: [Layer(source: .game)]), vertical: Composition(layers: [Layer(source: .game)]))
        doc.project.scenes.append(scene)
        doc.project.timeline.sceneSpans.append(SceneSpan(startMs: 7000, sceneID: scene.id))
        let model = await MainActor.run { EditorModel(doc: doc) }
        var rng = SeededRandom(state: 314), completed = 0, cancelled = 0
        for n in 0..<20 {
            let drain = expectation(description: "queue \(n)")
            await MainActor.run {
                model.startExport([.youtube, .shorts], custom: ExportPreset.Custom())
                model.exportQueue.onDrained = { drain.fulfill() }
                if n % 2 == 1 { model.play(rate: 1) } else { model.pause() }
            }
            if n % 2 == 0 {
                let delay = Double.random(in: 0...2, using: &rng)
                try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                await MainActor.run { model.exportQueue.cancelAll() }
                cancelled += 1
            }
            await fulfillment(of: [drain], timeout: 60)
            if n % 2 == 0 {
                let retry = expectation(description: "restart \(n)")
                await MainActor.run {
                    model.startExport([.youtube, .shorts], custom: ExportPreset.Custom())
                    model.exportQueue.onDrained = { retry.fulfill() }
                }
                await fulfillment(of: [retry], timeout: 60)
            }
            let last = await MainActor.run { Array(model.exportQueue.items.suffix(2)) }
            for item in last { if case .done = item.state { completed += 1 } else { XCTFail("\(item.state)") } }
        }
        await MainActor.run { model.close() }
        print("Demo stress: 20 queues, \(cancelled) cancelled and restarted, \(completed)/40 final exports finished")
    }
}
