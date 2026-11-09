import Foundation
import XCTest
@testable import StudioKit

final class RTMPFFmpegTests: XCTestCase {
    func testFiveSecondRealH264AndAAC() throws {
        guard ProcessInfo.processInfo.environment["RTMP_FFMPEG_TEST"] == "1",
              FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            throw XCTSkip("Set RTMP_FFMPEG_TEST=1 with /opt/homebrew/bin/ffmpeg installed")
        }
        let fixture = RTMPEncodedFixture(); try fixture.make()
        let reservation = try FakeRTMPServer()
        let port = reservation.port; reservation.stop()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stream.flv")
        let server = Process(), errors = Pipe()
        server.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        server.arguments = ["-loglevel", "error", "-listen", "1", "-i", "rtmp://127.0.0.1:\(port)/live/testkey", "-c", "copy", "-f", "flv", output.path]
        server.standardError = errors; server.standardOutput = FileHandle.nullDevice
        let exited = expectation(description: "ffmpeg exits")
        server.terminationHandler = { _ in exited.fulfill() }
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        Thread.sleep(forTimeInterval: 0.4)
        let publisher = RTMPPublisher(endpoint: StreamEndpoint(url: "rtmp://127.0.0.1:\(port)/live")!, streamKey: "testkey", metadata: StreamMetadata(width: fixture.width, height: fixture.height, fps: 30, videoKbps: 600, audioKbps: 128))
        defer { publisher.stop() }
        publisher.setVideoConfig(sps: fixture.sps, pps: fixture.pps)
        publisher.setAudioConfig(audioSpecificConfig: Data([0x11, 0x90]))
        let ready = expectation(description: "ffmpeg accepts publisher")
        publisher.onState = { if $0 == .publishing { ready.fulfill() } }
        publisher.start(); wait(for: [ready], timeout: 10)
        let packets = (fixture.video.map { (true, $0) } + fixture.audio.map { (false, $0) }).sorted {
            $0.1.ns == $1.1.ns ? $0.0 && !$1.0 : $0.1.ns < $1.1.ns
        }
        let start = ProcessInfo.processInfo.systemUptime
        for (video, packet) in packets {
            let delay = start + Double(packet.ns) / 1e9 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let t = 60_000_000_000 + packet.ns
            if video { publisher.sendVideo(packet.data, ptsNs: t, dtsNs: t, keyframe: packet.keyframe) }
            else { publisher.sendAudio(packet.data, ptsNs: t) }
        }
        publisher.stop()
        wait(for: [exited], timeout: 5)
        if !server.isRunning {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(server.terminationStatus, 0, text.replacingOccurrences(of: "testkey", with: "[redacted]"))
        }
        let probe = Process(), pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        probe.arguments = ["-v", "error", "-show_streams", "-show_format", "-show_packets", "-of", "json", output.path]
        probe.standardOutput = pipe
        try probe.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit(); XCTAssertEqual(probe.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        let video = try XCTUnwrap(streams.first { $0["codec_name"] as? String == "h264" })
        let audio = try XCTUnwrap(streams.first { $0["codec_name"] as? String == "aac" })
        XCTAssertEqual(video["width"] as? Int, fixture.width); XCTAssertEqual(video["height"] as? Int, fixture.height)
        XCTAssertEqual(audio["sample_rate"] as? String, "48000"); XCTAssertEqual(audio["channels"] as? Int, 2)
        // FLV has no per-stream duration field; derive each duration from ffprobe's packet timestamps.
        let probedPackets = try XCTUnwrap(json["packets"] as? [[String: Any]])
        var durations: [String: Double] = [:]
        for stream in [video, audio] {
            let index = try XCTUnwrap(stream["index"] as? Int)
            let selected = probedPackets.filter { $0["stream_index"] as? Int == index }
            let starts = selected.compactMap { Double($0["pts_time"] as? String ?? "") }
            let ends = selected.compactMap { p -> Double? in
                guard let t = Double(p["pts_time"] as? String ?? "") else { return nil }
                return t + (Double(p["duration_time"] as? String ?? "") ?? 0)
            }
            let duration = try XCTUnwrap(ends.max()) - XCTUnwrap(starts.min())
            XCTAssertEqual(duration, 5, accuracy: 0.3)
            durations[stream["codec_name"] as! String] = duration
        }
        print("ffprobe summary: h264 \(fixture.width)x\(fixture.height), duration \(durations["h264"]!); aac 48000 Hz stereo, duration \(durations["aac"]!)")
    }
}
