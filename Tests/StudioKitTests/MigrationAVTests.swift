import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import StudioKit

// Game baselines recorded through AVFoundation from PR head 5243611 plus prerequisite hard-edge fix (9886099) (SDR, 128x72 / 72x128).
final class MigrationAVTests: XCTestCase {
    func testMigratedProjectFirstFrames() async throws {
        try TimelineExportTests().requireHardware()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Migration-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await FixtureProject.make(at: dir)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for name in ["minimal", "v1", "v1-trim"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            doc.project = try decoder.decode(Project.self, from: Data(contentsOf: url))
            for canvas in Canvas.allCases {
                let size = canvas == .wide ? CGSize(width: 128, height: 72) : CGSize(width: 72, height: 128)
                let built = try await CompositionBuilder.build(doc, canvas: canvas, resolution: .hd, range: .sdr)
                let video = CompositionBuilder.videoComposition(doc.project, canvas: canvas, size: size, built: built)
                let raw = try RawCompositionFrames.frame(built.asset, video: video, ms: 0, hdr: false)
                let codes = RawCompositionFrames.codes(raw)
                let key = "migration-\(name)-\(canvas.rawValue)"
                if let output = ProcessInfo.processInfo.environment["MIGRATION_BASELINE"] {
                    try JSONEncoder().encode(codes).write(to: URL(fileURLWithPath: output).appendingPathComponent(key+".json"))
                    continue
                }
                let golden = try XCTUnwrap(Bundle.module.url(forResource: key, withExtension: "json", subdirectory: "Fixtures/golden"))
                let expected = try JSONDecoder().decode([Double].self, from: Data(contentsOf: golden))
                let instruction = try XCTUnwrap(video.instructions.first as? CompositionInstruction)
                let camera = instruction.plan.layers(atTimelineMs: 0).first { $0.key == .camera }
                var gameError = 0.0
                for y in 0..<Int(size.height) { for x in 0..<Int(size.width) {
                    if camera?.dst.insetBy(dx: -3, dy: -3).contains(CGPoint(x: x, y: y)) == true { continue }
                    let i = (y*Int(size.width)+x)*4
                    for c in 0..<3 { gameError = max(gameError, abs(codes[i+c]-expected[i+c])) }
                } }
                XCTAssertLessThanOrEqual(gameError, 2, key+" stored game baseline")
                if let camera = camera {
                    let source = try RawCompositionFrames.frame(AVURLAsset(url: doc.url("camera.mov")), ms: built.map.source(fromTimeline: 0), hdr: false)
                    let src = RawCompositionFrames.codes(source), sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
                    var checked = 0, error = 0.0
                    for y in 0..<Int(size.height) { for x in 0..<Int(size.width) {
                        let point = CGPoint(x: Double(x)+0.5, y: Double(y)+0.5)
                        guard camera.dst.insetBy(dx: 4, dy: 4).contains(point) else { continue }
                        let u = (point.x-camera.dst.minX)/camera.dst.width
                        let v = (point.y-camera.dst.minY)/camera.dst.height
                        let sx = (camera.src.minX+u*camera.src.width)*Double(sw)-0.5
                        let sy = Int((camera.src.minY+v*camera.src.height)*Double(sh))
                        let left = max(0,min(sw-2,Int(floor(sx)))), row = max(0,min(sh-1,sy))
                        let a = (row*sw+left)*4, b = a+4, weight = sx-floor(sx)
                        guard abs(src[a]-src[b]) < 4 else { continue }
                        for c in 0..<3 {
                            let value = src[a+c]*(1-weight)+src[b+c]*weight
                            error = max(error, abs(codes[(y*Int(size.width)+x)*4+c]-value))
                        }
                        checked += 1
                    } }
                    XCTAssertGreaterThan(checked, 0); XCTAssertLessThanOrEqual(error, 2, key+" native camera colour")
                }
            }
        }
        doc.project.wide.kind = .stacked
        doc.project.camera = LayerInfo(file: "absent-camera.mov")
        doc.project.scenes = [doc.project.defaultScene]; doc.project.timeline.sceneSpans = []
        let missing = try await CompositionBuilder.build(doc, canvas: .wide, resolution: .hd, range: .sdr)
        XCTAssertNil(missing.cameraSize)
        let instruction = try XCTUnwrap(missing.video.instructions.first as? CompositionInstruction)
        XCTAssertEqual(instruction.plan.layers(atTimelineMs: 0).first?.dst, CGRect(origin: .zero, size: Canvas.wide.size(.hd)))
    }
}
