import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
@testable import StudioKit

// Full-HD game baselines: pre-engine 092984d plus the prerequisite hard-edge fix, through AVFoundation.
final class MigrationAVTests: XCTestCase {
    func testMigratedProjectFirstFrames() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Migration-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Golden comparisons need identical encoded inputs, independent of hardware encoder rate-control/load.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["game", "camera"] {
            let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures/migration-media"))
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name+".mov"))
        }
        let doc = ProjectDoc(dir: dir, project: Project(name: "Migration", createdAt: Date()))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for name in ["minimal", "v1", "v1-trim"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            doc.project = try decoder.decode(Project.self, from: Data(contentsOf: url))
            for canvas in Canvas.allCases {
                let size = canvas.size(.hd)
                let built = try await CompositionBuilder.build(doc, canvas: canvas, resolution: .hd, range: .sdr)
                let video = CompositionBuilder.videoComposition(doc.project, canvas: canvas, size: size, built: built)
                let raw = try RawCompositionFrames.frame(built.asset, video: video, ms: 0, hdr: false)
                let codes = RawCompositionFrames.codes(raw)
                let key = "migration-\(name)-\(canvas.rawValue)"
                let golden = try XCTUnwrap(Bundle.module.url(forResource: key, withExtension: "lzfse", subdirectory: "Fixtures/golden"))
                let compressed = try Data(contentsOf: golden)
                let expected = [UInt8](try (compressed as NSData).decompressed(using: .lzfse))
                XCTAssertEqual(codes.count, expected.count)
                let instruction = try XCTUnwrap(video.instructions.first as? CompositionInstruction)
                let camera = instruction.plan.layers(atTimelineMs: 0).first { $0.key == .camera }
                var gameError = 0.0
                for y in 0..<Int(size.height) { for x in 0..<Int(size.width) {
                    if camera?.dst.insetBy(dx: -3, dy: -3).contains(CGPoint(x: x, y: y)) == true { continue }
                    let i = (y*Int(size.width)+x)*4
                    for c in 0..<3 { gameError = max(gameError, abs(codes[i+c]-Double(expected[i+c]))) }
                } }
                XCTAssertLessThanOrEqual(gameError, 2, key+" stored game baseline")
                if let camera = camera {
                    let source = try RawCompositionFrames.frame(AVURLAsset(url: doc.url("camera.mov")), ms: built.map.source(fromTimeline: 0), hdr: false)
                    let src = RawCompositionFrames.codes(source), sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
                    var checked = 0, error = 0.0
                    for y in 0..<Int(size.height) { for x in 0..<Int(size.width) {
                        let point = CGPoint(x: Double(x)+0.5, y: Double(y)+0.5)
                        let margin = max(4, camera.radius + camera.border + 2)
                        guard camera.dst.insetBy(dx: margin, dy: margin).contains(point) else { continue }
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
