import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import StudioKit

final class ExportTests: XCTestCase {
    func testFourExports() async throws {
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard status == noErr, let encoder = encoder else { throw XCTSkip("No hardware HEVC encoder (\(status))") }
        VTCompressionSessionInvalidate(encoder)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Foundation-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let doc = try await SharedRecording.shared.copy(to: dir, frames: 120)
        XCTAssertEqual(doc.project.durationMs,2000,accuracy:1000/60)
        XCTAssertTrue(doc.hasCamera); XCTAssertTrue(doc.hasMic)
        for canvas in Canvas.allCases {
            for range in [ExportRange.hdr,.sdr] {
                let start = Date()
                let url = try await Exporter(doc:doc,job:ExportJob(canvas:canvas,resolution:.hd,range:range,fps:.source)).run { _ in }
                XCTAssertLessThan(Date().timeIntervalSince(start), max(8, doc.project.durationMs / 1000 * 4), "Export throughput regressed")
                print(String(format: "Fixture export %@ %@: %.3fs",canvas.rawValue,range.rawValue,Date().timeIntervalSince(start)))
                if range == .hdr, FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffprobe") {
                    let process = Process(), pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                    process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=chroma_location", "-of", "default=nw=1", url.path]
                    process.standardOutput = pipe
                    try process.run(); process.waitUntilExit()
                    let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    print("HDR ffprobe: \(result)")
                    XCTAssertEqual(process.terminationStatus, 0)
                    XCTAssertTrue(result.contains("chroma_location=center"), result)
                }
                let asset = AVURLAsset(url:url)
                let duration = try await asset.load(.duration)
                XCTAssertEqual(duration.seconds,2,accuracy:1/60)
                let tracks = try await asset.loadTracks(withMediaType:.video)
                let track = try XCTUnwrap(tracks.first)
                let size = try await track.load(.naturalSize)
                XCTAssertEqual(size,canvas.size(.hd))
                let formats = try await track.load(.formatDescriptions)
                let format = try XCTUnwrap(formats.first)
                XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format),range == .hdr ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264)
                let tf = CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_TransferFunction) as? String
                XCTAssertEqual(tf,range == .hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String : kCVImageBufferTransferFunction_ITU_R_709_2 as String)
                let audio = try await asset.loadTracks(withMediaType:.audio)
                XCTAssertFalse(audio.isEmpty)
            }
        }
    }
}
