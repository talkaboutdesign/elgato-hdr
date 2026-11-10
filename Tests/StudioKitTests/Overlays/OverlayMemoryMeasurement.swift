import XCTest
import Darwin
import AVFoundation
@testable import StudioKit

/// Opt-in (EHDR_MEASURE_TIMER_EXPORT=1), under /tmp/ehdr-encoder.lock.d: the overlay cache's memory over a ten-minute
/// export whose scene has a `{timer}` text layer, which leaves one texture per second behind.
final class OverlayMemoryMeasurement: XCTestCase {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testTenMinuteTimerExport() async throws {
        guard ProcessInfo.processInfo.environment["EHDR_MEASURE_TIMER_EXPORT"] == "1" else { throw XCTSkip("Set EHDR_MEASURE_TIMER_EXPORT=1") }
        try TimelineExportTests().requireHardware()
        let minutes = Double(ProcessInfo.processInfo.environment["EHDR_MEASURE_MINUTES"] ?? "") ?? 10
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TimerExport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = Date()
        let doc = try await GeneratedMedia.project(at: dir, fps: 30, seconds: minutes * 60)
        let timer = Layer(name: "Timer", source: LayerSource(type: "text", text: TextSpec(string: "LIVE {timer}", weight: "bold", plate: [0, 0, 0, 0.6])),
                          frame: NRect(x: 0.05, y: 0.8, w: 0.5, h: 0.15))
        let scene = Scene(name: "Timer", wide: Composition(layers: [Layer(source: .game), timer]), vertical: Composition(layers: [Layer(source: .game), timer]))
        doc.project.scenes = [scene]; doc.project.camera = nil
        doc.project.timeline = Timeline(sceneSpans: [SceneSpan(startMs: 0, sceneID: scene.id)])
        doc.save()
        print(String(format: "MEASURE timer export: %.0f s fixture made in %.1f s", minutes * 60, Date().timeIntervalSince(made)))

        let cache = OverlayTextureCache.shared
        let rastersBefore = cache.rasterCount, base = Self.footprint()
        let lock = NSLock()
        var peakFootprint = base, peakCache = 0, samples = 0
        let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        sampler.schedule(deadline: .now(), repeating: 0.25)
        sampler.setEventHandler {
            let f = Self.footprint(), c = cache.residentBytes
            lock.lock(); peakFootprint = max(peakFootprint, f); peakCache = max(peakCache, c); samples += 1; lock.unlock()
        }
        sampler.resume()
        let start = Date()
        let url = try await Exporter(doc: doc, job: ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source)).run { _ in }
        sampler.cancel()
        let seconds = Date().timeIntervalSince(start)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let mb = { (b: UInt64) in Double(b) / 1_048_576 }
        lock.lock()
        print(String(format: "MEASURE timer export: %.0f s of video in %.1f s; %d {timer} textures made; cache peak %.2f MB (budget %.0f MB, cache's own peak %.2f MB); process footprint %.0f MB before, peak %.0f MB (+%.0f MB) over %d samples",
                     duration, seconds, cache.rasterCount - rastersBefore, Double(peakCache) / 1_048_576, Double(cache.byteBudget) / 1_048_576,
                     Double(cache.peakResidentBytes) / 1_048_576, mb(base), mb(peakFootprint), mb(peakFootprint) - mb(base), samples))
        lock.unlock()
        XCTAssertEqual(duration, minutes * 60, accuracy: 0.1)
        XCTAssertLessThanOrEqual(cache.peakResidentBytes, cache.byteBudget)
    }
}
