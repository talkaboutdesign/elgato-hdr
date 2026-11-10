import XCTest
@testable import StudioKit

final class ProjectCodingTests: XCTestCase {
    func testFixturesAndRoundTrip() throws {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for name in ["minimal","v1"] {
            let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
            let p = try dec.decode(Project.self, from: Data(contentsOf: url))
            XCTAssertEqual(p.scenes.count,1); XCTAssertEqual(p.timeline.sceneSpans.count,1)
            XCTAssertEqual(p.version,2); XCTAssertEqual(p.fps,60); XCTAssertEqual(p.colorMode,"pq")
            XCTAssertEqual(p.game,LayerInfo(file:"game.mov")); XCTAssertEqual(p.vertical,.verticalDefault)
            XCTAssertEqual(p.trimStartMs,0); XCTAssertEqual(p.trimEndMs,0)
            XCTAssertEqual(p.wide.zoom,1); XCTAssertEqual(p.wide.camera.shadow,true)
            if name == "minimal" { XCTAssertNil(p.camera); XCTAssertEqual(p.wide,.wideDefault); XCTAssertEqual(p.width,0) }
            else { XCTAssertEqual(p.width,1920); XCTAssertTrue(p.wide.camera.border); XCTAssertEqual(p.camera?.volume,1) }
            // Default numeric date encoding retains subsecond precision in the name-only fixture.
            XCTAssertEqual(try JSONDecoder().decode(Project.self,from: JSONEncoder().encode(p)),p)
        }
    }
}
