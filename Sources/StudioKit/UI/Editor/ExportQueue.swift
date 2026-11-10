import AppKit
import Foundation
import Observation

/// What the queue needs from an export; `Exporter` is one, tests use a fake.
protocol ExportRunning: AnyObject {
    func run(progress: @escaping (Double) -> Void) async throws -> URL
    func cancel()
}
extension Exporter: ExportRunning {}

/// The export sheet's cards. Several can be ticked; each becomes one or more jobs in the queue.
enum ExportPreset: String, CaseIterable, Identifiable {
    case youtube, youtube1080, shorts, custom
    var id: String { rawValue }

    var title: String {
        switch self { case .youtube: "YouTube"; case .youtube1080: "YouTube 1080p SDR"; case .shorts: "Shorts, Reels, TikTok"; case .custom: "Custom" }
    }
    var symbol: String {
        switch self { case .youtube: "play.rectangle.fill"; case .youtube1080: "play.rectangle"; case .shorts: "iphone"; case .custom: "slider.horizontal.3" }
    }

    struct Custom: Equatable {
        var canvases: Set<Canvas> = [.wide]
        var resolution: ExportResolution = .hd
        var range: ExportRange = .hdr
        var fps: ExportFPS = .source
    }

    /// Source resolution up to 4K, HDR when the source is HDR.
    func jobs(for p: Project, custom: Custom) -> [ExportJob] {
        let hdr = p.color != .sdr
        switch self {
        case .youtube: return [ExportJob(canvas: .wide, resolution: p.height > 1080 ? .uhd : .hd, range: hdr ? .hdr : .sdr, fps: .source)]
        case .youtube1080: return [ExportJob(canvas: .wide, resolution: .hd, range: .sdr, fps: .source)]
        case .shorts: return [ExportJob(canvas: .vertical, resolution: .hd, range: .sdr, fps: .sixty)]
        case .custom:
            return Canvas.allCases.filter { custom.canvases.contains($0) }
                .map { ExportJob(canvas: $0, resolution: custom.resolution, range: hdr ? custom.range : .sdr, fps: custom.fps) }
        }
    }

    func detail(for p: Project, custom: Custom) -> String {
        jobs(for: p, custom: custom).map(Self.describe).joined(separator: " + ")
    }
    static func describe(_ j: ExportJob) -> String {
        let size = j.canvas == .wide ? (j.resolution == .uhd ? "4K" : "1080p") : (j.resolution == .uhd ? "2160×3840" : "1080×1920")
        let fps = j.fps == .source ? "" : " · \(j.fps.rawValue) fps"
        return "\(j.canvas.label) · \(size) · \(j.range == .hdr ? "HDR" : "SDR")\(fps)"
    }
    /// Exports are named by canvas, resolution and range; two jobs with the same three would write one file.
    static func fileKey(_ j: ExportJob) -> String { "\(j.canvas.rawValue)-\(j.resolution.rawValue)-\(j.range.rawValue)" }
}

/// Runs exports one at a time in the order they were queued (the media engines are shared; sequential keeps each
/// at full speed). Observable for the progress capsule and its popover. Main thread only.
@Observable
final class ExportQueue {
    struct Item: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done(URL), failed(String), cancelled }
        let id = UUID()
        var title: String
        var job: ExportJob
        var state: State = .waiting
        var progress = 0.0
        var started: Date?
        var isActive: Bool { state == .waiting || state == .running }
    }

    var items: [Item] = []
    @ObservationIgnored var onFinished: ((Item) -> Void)?
    @ObservationIgnored var onDrained: (() -> Void)?
    @ObservationIgnored private let makeRunner: (ExportJob) throws -> ExportRunning
    @ObservationIgnored private var current: (id: UUID, runner: ExportRunning)?
    @ObservationIgnored private var cancelRequested = Set<UUID>()

    init(makeRunner: @escaping (ExportJob) throws -> ExportRunning) { self.makeRunner = makeRunner }

    var isRunning: Bool { items.contains { $0.isActive } }
    var activeCount: Int { items.filter(\.isActive).count }
    /// Position of the running job among this batch (finished and active jobs since the queue was last idle).
    var runningIndex: Int { (items.firstIndex { $0.state == .running } ?? items.count) + 1 }
    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { acc, i in
            switch i.state { case .running: acc + i.progress; case .waiting: acc; default: acc + 1 }
        }
        return sum / Double(items.count)
    }

    /// Adds jobs in order, skipping one that would write the same file as a job already waiting or running.
    @discardableResult
    func enqueue(_ jobs: [(title: String, job: ExportJob)]) -> Int {
        if !isRunning { items.removeAll() }
        var added = 0
        for (title, job) in jobs where !items.contains(where: { $0.isActive && ExportPreset.fileKey($0.job) == ExportPreset.fileKey(job) }) {
            items.append(Item(title: title, job: job)); added += 1
        }
        startNext()
        return added
    }

    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isActive else { return }
        if items[i].state == .running, let c = current, c.id == id { cancelRequested.insert(id); c.runner.cancel() }
        else { items[i].state = .cancelled; drainedIfIdle() }
    }
    func cancelAll() { for i in items where i.isActive { cancel(i.id) } }

    /// Seconds left for the running job, from its pace so far.
    func remaining(_ item: Item, now: Date = Date()) -> Double? {
        guard item.state == .running, let s = item.started, item.progress > 0.02 else { return nil }
        let elapsed = now.timeIntervalSince(s)
        return elapsed / item.progress * (1 - item.progress)
    }

    private func startNext() {
        guard current == nil, let i = items.firstIndex(where: { $0.state == .waiting }) else { return }
        let item = items[i]
        let runner: ExportRunning
        do { runner = try makeRunner(item.job) } catch { finish(item.id, .failed(error.localizedDescription)); return }
        current = (item.id, runner)
        items[i].state = .running; items[i].started = Date(); items[i].progress = 0
        let id = item.id
        Task {
            do {
                let url = try await runner.run { p in DispatchQueue.main.async { self.setProgress(id, p) } }
                await MainActor.run { self.finish(id, .done(url)) }
            } catch {
                await MainActor.run { self.finish(id, self.cancelRequested.contains(id) ? .cancelled : .failed(error.localizedDescription)) }
            }
        }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .running else { return }
        if p - items[i].progress >= 0.002 || p >= 1 { items[i].progress = min(1, p) }
    }

    private func finish(_ id: UUID, _ state: Item.State) {
        if current?.id == id { current = nil }
        cancelRequested.remove(id)
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].state = state
            if case .done = state { items[i].progress = 1 }
            onFinished?(items[i])
        }
        startNext()
        drainedIfIdle()
    }

    private func drainedIfIdle() { if current == nil && !isRunning { onDrained?() } }
}
