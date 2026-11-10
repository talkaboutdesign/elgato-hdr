import XCTest
import QuartzCore
@testable import StudioKit

final class StreamSessionTests: XCTestCase {
    func testRendererSwapKeepsProgramAndNoSignalAlive() throws {
        let demo = DemoSource(width: 64, height: 64, fps: 60)
        let first = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let second = try XCTUnwrap(Renderer(layer: CAMetalLayer(), shm: demo.memory, demoSource: demo))
        let stream = StreamSession(outputs: [.init(canvas: .wide, size: CGSize(width: 64, height: 64), fps: 60,
            videoBitrate: 100_000, publishers: [])], audioBitrate: 160_000, renderer: first, mixer: AudioMixer())
        XCTAssertTrue(stream.start())
        let program = try XCTUnwrap(first.programOutputs.first)
        let gate = DispatchSemaphore(value: 0)
        program.onFrame = { _, _ in gate.signal() }
        stream.replaceRenderer(second)
        XCTAssertTrue(first.programOutputs.isEmpty)
        XCTAssertTrue(second.programOutputs.first === program)
        XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
        stream.stop()
        XCTAssertTrue(second.programOutputs.isEmpty)
    }
}
