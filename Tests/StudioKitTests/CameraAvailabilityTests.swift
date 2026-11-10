import XCTest
import CoreGraphics
@testable import StudioKit

final class CameraAvailabilityTests: XCTestCase {
    func testAbsentCameraExpandsOnlyGameAndPreservesAuthoredScene() {
        for canvas in Canvas.allCases {
            for fit in [false, true] {
                let size = canvas.size(.hd)
                let game = Layer(source: .game, frame: NRect(x: 0, y: 0.4, w: 1, h: 0.6), fit: fit)
                let overlay = Layer(source: LayerSource(type: "color", color: [1, 0, 0, 1]), frame: NRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
                let c = Composition(layers: [game, Layer(source: .camera), overlay])
                let original = c
                let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 2560, height: 1440))]
                let resolved = SceneResolver.resolve(c, canvas: size, sources: sources)
                var full = game; full.frame = NRect(x: 0, y: 0, w: 1, h: 1)
                XCTAssertEqual(resolved, SceneResolver.resolve(Composition(layers: [full, overlay]), canvas: size, sources: sources))
                XCTAssertEqual(c, original)
                let intentional = Composition(layers: [game, overlay])
                XCTAssertNotEqual(SceneResolver.resolve(intentional, canvas: size, sources: sources).first?.dst, resolved.first?.dst)
            }
        }
    }
}
