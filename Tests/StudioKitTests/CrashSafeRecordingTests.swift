import XCTest
import AVFoundation
import VideoToolbox
@testable import StudioKit

/// Writers that never reach `finish` (crash, kill -9, power cut) must still leave a readable file.
final class CrashSafeRecordingTests: XCTestCase {
    let zero: UInt64 = 1_000_000_000
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CrashSafe-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func requireHEVC() throws {
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard status == noErr, let encoder = encoder else { throw XCTSkip("No hardware HEVC encoder (\(status))") }
        VTCompressionSessionInvalidate(encoder)
    }

    func duration(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    /// Feeds `seconds` of demo video and audio at real-time cadence (real-time writers drop on backpressure).
    func writeGame(_ url: URL, seconds: Double) async throws -> Recorder {
        let r = try Recorder(url: url, width: 640, height: 360, fps: 30, colorMode: .pq, startNs: zero)
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
            let ns = zero + UInt64(Double(frame) * 1e9 / 30)
            r.appendVideo(try XCTUnwrap(out), ns: ns)
            r.appendAudio(Data(count: 1600 * 4), ns: ns + 33_333_333)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        r.queue.sync {}
        return r
    }

    func testGameRecorderSurvivesWithoutFinish() async throws {
        try requireHEVC()
        let url = dir.appendingPathComponent("game.mov")
        var r: Recorder? = try await writeGame(url, seconds: 3)
        XCTAssertEqual(r?.writer.status, .writing)
        r = nil   // released without finishWriting, as after a crash
        XCTAssertNil(r)
        let d = try await duration(url)
        XCTAssertGreaterThanOrEqual(d, 2, "unfinished game.mov reads as \(d) s")
    }

    func testCameraLayerSurvivesWithoutFinish() async throws {
        let url = dir.appendingPathComponent("camera.mov")
        var w: LayerWriter? = try LayerWriter(cameraURL: url, width: 640, height: 360, startNs: zero)
        for frame in 0..<90 {
            w?.appendVideo(CameraCapture.demoPixelBuffer(frame: frame), ns: zero + 1 + UInt64(Double(frame) * 1e9 / 30))
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        w?.queue.sync {}
        XCTAssertGreaterThan(w?.count ?? 0, 60)
        w = nil
        let d = try await duration(url)
        XCTAssertGreaterThanOrEqual(d, 2, "unfinished camera.mov reads as \(d) s")
    }

    func testMicLayerSurvivesWithoutFinish() async throws {
        let url = dir.appendingPathComponent("mic.mov")
        var w: LayerWriter? = try LayerWriter(micURL: url, startNs: zero)
        for chunk in 0..<150 {   // 20 ms chunks
            if let sb = CameraCapture.demoAudio(sample: chunk * 960, count: 960) { w?.appendAudio(sb, ns: zero + 1 + UInt64(chunk) * 20_000_000) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        w?.queue.sync {}
        w = nil
        let d = try await duration(url)
        // AAC fragments end on a 1024-sample packet boundary, so the first fragment can stop a packet or two short of 2 s.
        XCTAssertGreaterThanOrEqual(d, 2 - 2048.0 / 48000, "unfinished mic.mov reads as \(d) s")
    }

    func project(camera: Bool) -> ProjectDoc {
        var p = Project(name: "Interrupted", createdAt: Date())
        p.state = "recording"
        if camera { p.camera = LayerInfo(file: "camera.mov") }
        let doc = ProjectDoc(dir: dir, project: p); doc.save()
        return doc
    }

    func testFinalizeDropsMissingCamera() async throws {
        try requireHEVC()
        let r = try await writeGame(dir.appendingPathComponent("game.mov"), seconds: 1)
        _ = await withCheckedContinuation { c in r.finish { c.resume(returning: $0) } }
        let doc = project(camera: true)   // camera.mov was never written
        await withCheckedContinuation { c in doc.finalize { c.resume() } }
        XCTAssertNil(doc.project.camera)
        XCTAssertEqual(doc.project.state, "complete")
        XCTAssertGreaterThan(doc.project.durationMs, 500)
        XCTAssertNil(ProjectDoc.load(dir)?.project.camera, "the cleared layer is saved")
    }

    func testFinalizeMarksGarbageGameDamaged() async throws {
        try Data((0..<4096).map { UInt8($0 & 0xff) }).write(to: dir.appendingPathComponent("game.mov"))
        let doc = project(camera: false)
        await withCheckedContinuation { c in doc.finalize { c.resume() } }
        XCTAssertEqual(doc.project.state, "damaged")
        XCTAssertEqual(ProjectDoc.load(dir)?.project.state, "damaged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "a damaged project keeps its folder")
    }
}
