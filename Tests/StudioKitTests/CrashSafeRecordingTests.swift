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
    func writeGame(_ url: URL, seconds: Double, layers: Bool = false) async throws -> Recorder {
        let folder = url.deletingLastPathComponent()
        let camera = layers ? try LayerWriter(cameraURL: folder.appendingPathComponent("camera.mov"), width: 640, height: 360, startNs: zero) : nil
        let mic = layers ? try LayerWriter(micURL: folder.appendingPathComponent("mic.mov"), startNs: zero) : nil
        let r = try Recorder(url: url, width: 640, height: 360, fps: 30, colorMode: .pq, startNs: zero)
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
            let ns = zero + UInt64(Double(frame) * 1e9 / 30)
            r.appendVideo(try XCTUnwrap(out), ns: ns)
            camera?.appendVideo(CameraCapture.demoPixelBuffer(frame: frame), ns: ns + 1)
            if let mic, let audio = CameraCapture.demoAudio(sample: frame * 1600, count: 1600) { mic.appendAudio(audio, ns: ns + 1) }
            r.appendAudio(Data(count: 1600 * 4), ns: ns + 33_333_333)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        camera?.queue.sync {}; mic?.queue.sync {}
        if layers { XCTAssertGreaterThan(camera?.count ?? 0, 60) }
        r.queue.sync {}
        return r
    }

    private static var interrupted: Task<URL, Error>?
    private static var interruptedDir: URL?
    private func interruptedRecording() async throws -> URL {
        try requireHEVC()
        if let task = Self.interrupted { return try await task.value }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterruptedShared-" + UUID().uuidString)
        Self.interruptedDir = folder
        let task = Task {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var recorder: Recorder? = try await self.writeGame(folder.appendingPathComponent("game.mov"), seconds: 3, layers: true)
            XCTAssertEqual(recorder?.writer.status, .writing)
            recorder = nil
            return folder
        }
        Self.interrupted = task
        return try await task.value
    }
    override class func tearDown() {
        if let folder = interruptedDir { try? FileManager.default.removeItem(at: folder) }
        interrupted = nil; interruptedDir = nil
        super.tearDown()
    }
    func testGameRecorderSurvivesWithoutFinish() async throws {
        let folder = try await interruptedRecording()
        let d = try await duration(folder.appendingPathComponent("game.mov"))
        XCTAssertGreaterThanOrEqual(d, 2)
    }
    func testCameraLayerSurvivesWithoutFinish() async throws {
        let folder = try await interruptedRecording()
        let d = try await duration(folder.appendingPathComponent("camera.mov"))
        XCTAssertGreaterThanOrEqual(d, 2)
    }
    func testMicLayerSurvivesWithoutFinish() async throws {
        let folder = try await interruptedRecording()
        let d = try await duration(folder.appendingPathComponent("mic.mov"))
        XCTAssertGreaterThanOrEqual(d, 2 - 2048.0 / 48000)
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
