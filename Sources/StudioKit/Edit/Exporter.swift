import AppKit
import AVFoundation
import VideoToolbox
import QuartzCore
import Darwin

// MARK: - Export

struct ExportJob: Hashable {
    var canvas: Canvas
    var resolution: ExportResolution
    var range: ExportRange
    var fps: ExportFPS
}

/// Renders a project to a single MP4 through AVAssetReader (composited) -> AVAssetWriter.
///
/// The reader and writer lifecycle (start, cancel, finish) runs on one serial queue: a cancel can never interleave
/// with `startReading`/`startWriting` (that race crashed inside `AVAssetReaderAudioMixOutput`), and a cancel that
/// arrives first prevents the start. Every wait in `run` (a lifecycle step, each pump, `finishWriting`) is an
/// exactly-once completion that cancel and the stall watchdog resolve directly, without the lifecycle queue: after
/// `cancelWriting` the writer may never ask for data again, and an AVFoundation call can block that queue for a long
/// time when the media engines are busy.
final class Exporter {
    let doc: ProjectDoc
    let job: ExportJob
    let output: URL
    private let partialOutput: URL
    /// No appended sample and no state change for this long fails the export as stalled.
    var stallTimeout: TimeInterval = 20
    /// Starts feeding one writer input. Tests replace it to simulate a pump that never produces.
    var startPump: (Pump) -> Void = Exporter.feed
    var finishWriter: (AVAssetWriter, @escaping () -> Void) -> Void = { $0.finishWriting(completionHandler: $1) }

    private enum Phase: Equatable { case idle, starting, running, finishing, finished, torndown }
    enum Abort: Equatable { case cancelled, stalled, failed }
    private let queue = DispatchQueue(label: "export-lifecycle")
    private let watchQueue = DispatchQueue(label: "export-watchdog")
    // Lifecycle queue only.
    private var phase = Phase.idle
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var pumps: [Pump] = []
    private var ownsOutput = false
    // Thread-safe.
    private let aborted = AbortSignal()
    private let activity = Activity()
    private let gate = WriterGate()
    private let tornDown = Once<Bool>()           // the reader and writer are stopped and the partial file deleted
    private var watchdog: DispatchSourceTimer?   // watchQueue only

    init(doc: ProjectDoc, job: ExportJob, output: URL? = nil) {
        self.doc = doc; self.job = job
        let name = doc.project.name.replacingOccurrences(of: "/", with: "-")
        let res = job.resolution == .uhd ? "4K" : "1080p"
        self.output = output ?? doc.exportsDir.appendingPathComponent("\(name) — \(job.canvas == .wide ? "16x9" : "9x16") \(res) \(job.range == .hdr ? "HDR" : "SDR").mp4")
        partialOutput = self.output.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString + ".mp4")
        // Exports are file names only: the project folder can be renamed or moved freely.
    }

    /// Safe from any thread, at any time: before `run`, while it builds, starts, pumps or finishes, or after it
    /// returned. Every wait resolves at once; the reader and writer are stopped on the lifecycle queue.
    func cancel() { abort(.cancelled, why: "cancel") }

    func run(progress: @escaping (Double) -> Void) async throws -> URL {
        do { return try await export(progress: progress) } catch {
            let reason = aborted.reason ?? .failed
            abort(reason, why: error.localizedDescription)
            // Teardown (and deleting the partial file) is queued behind whatever the lifecycle queue is doing. Wait
            // for it, but never long: a blocked media engine must not keep the caller (and the export queue) waiting.
            watchQueue.asyncAfter(deadline: .now() + 1.2) { self.tornDown.resolve(false) }
            if await !tornDown.wait() { log("export: teardown still waiting on the media engine") }
            // Each run owns a unique partial path; a late teardown cannot delete a restarted export.
            try? FileManager.default.removeItem(at: partialOutput)
            throw abortError(reason) ?? error
        }
    }

    private func abortError(_ r: Abort?) -> Error? {
        switch r {
        case .cancelled?: CompositionBuilder.err("Export cancelled")
        case .stalled?: CompositionBuilder.err(String(format: "Export stalled: no progress for %.0f seconds", stallTimeout))
        default: nil
        }
    }

    /// First abort wins: every pending wait resolves now, from the calling thread. The reader and writer stop on the
    /// lifecycle queue, after any step running there, and the partial file goes with them.
    private func abort(_ reason: Abort, why: String) {
        guard aborted.trigger(reason) else { return }
        queue.async { self.teardown(reason, why: why) }
    }

    private func teardown(_ reason: Abort, why: String) {   // lifecycle queue
        defer { tornDown.resolve(true) }
        guard phase != .finished, phase != .torndown else { return }
        let started = phase != .idle
        phase = .torndown
        stopWatchdog()
        guard started else { return }
        let statusBeforeCancel = reason == .cancelled ? "" : diagnostics()
        gate.close()
        if let r = reader, r.status == .reading { r.cancelReading() }
        if let w = writer, w.status == .writing { w.cancelWriting() }
        if ownsOutput { try? FileManager.default.removeItem(at: partialOutput) }
        pumps.forEach { $0.release() }
        if reason != .cancelled { log("export: aborted (\(why)) before cancel: \(statusBeforeCancel); after cancel: \(diagnostics())") }
    }

    /// Runs a lifecycle step on the queue. An abort before it starts skips it and returns at once. A `blocking` step
    /// (starting the reader and writer can block in the media engine) also returns at once when aborted while it
    /// runs; teardown follows it on the queue. Any other step, once started, is short and reports its own result,
    /// so "finished" and "cancelled" can never both be true.
    private func step<T>(blocking: Bool = false, _ f: @escaping () throws -> T) async throws -> T {
        let done = Once<Result<T, Error>>(), state = StepState()
        let abortResult = { (r: Abort) -> Result<T, Error> in .failure(self.abortError(r) ?? CompositionBuilder.err("Export failed")) }
        aborted.onTrigger { r in if state.abandon() { done.resolve(abortResult(r)) } }
        queue.async {
            if let r = self.aborted.reason { done.resolve(abortResult(r)); return }
            guard blocking || state.claim() else { return }
            done.resolve(Result { try f() })
        }
        return try await done.wait().get()
    }
    /// Waits for a completion that an abort also resolves.
    private func await_(_ once: Once<Bool>) async throws {
        aborted.onTrigger { _ in once.resolve(false) }
        _ = await once.wait()
        if let e = abortError(aborted.reason) { throw e }
    }

    private func export(progress: @escaping (Double) -> Void) async throws -> URL {
        if let e = abortError(aborted.reason) { throw e }
        let built = try await CompositionBuilder.build(doc, canvas: job.canvas, resolution: job.resolution, range: job.range, fps: job.fps)
        #if DEBUG
        if ProcessInfo.processInfo.environment["EHDR_VALIDATE"] != nil {
            let problems = try await CompositionBuilder.validate(built)
            log("composition valid: \(problems.isEmpty) \(problems.joined(separator: "; ")) comp=\(built.asset.duration.seconds) instr=\(built.duration.seconds)")
        }
        #endif
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hdr = built.outTransfer != 2
        let reader = try AVAssetReader(asset: built.asset)
        let videoTracks = built.asset.tracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
        vOut.videoComposition = built.video
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let audioTracks = built.asset.tracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            o.audioMix = built.audioMix
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let size = built.video.renderSize
        let fps = 1 / built.video.frameDuration.seconds
        let writer = try AVAssetWriter(outputURL: partialOutput, fileType: .mp4)
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: Int(fps * 2)]
        let videoSettings: [String: Any]
        if hdr {
            compression[AVVideoAverageBitRateKey] = Int(Double(size.width * size.height) * fps * 0.12)
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            let pq = built.outTransfer == 0
            if pq {
                let (m, c) = Recorder.hdr10Metadata()
                compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = m
                compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = c
            }
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                         AVVideoTransferFunctionKey: pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG,
                                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
                             AVVideoCompressionPropertiesKey: compression]
        } else {
            compression[AVVideoAverageBitRateKey] = Int(Double(size.width * size.height) * fps * 0.14)
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                             AVVideoCompressionPropertiesKey: compression]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writer.add(vIn)
        let total = max(0.001, built.duration.seconds)
        let activity = activity, gate = gate
        var pumps = [Pump(label: "export-video", output: vOut, input: vIn, gate: gate, activity: activity) { t in progress(min(1, t / total)) }]
        if let aOut = aOut {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
            writer.add(i)
            pumps.append(Pump(label: "export-audio", output: aOut, input: i, gate: gate, activity: activity) { _ in })
        }

        // The watchdog covers the start too: starting the writer can block when the media engines are busy.
        activity.touch()
        startWatchdog(reader: reader, writer: writer)
        try await step(blocking: true) {
            self.phase = .starting
            self.ownsOutput = true
            try? FileManager.default.removeItem(at: self.partialOutput)
            self.reader = reader; self.writer = writer; self.pumps = pumps
            pumps.forEach { p in
                p.retain([reader, writer])
                self.aborted.onTrigger { _ in p.done.resolve(false) }
            }
            guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("cannot read layers") }
            if let error = self.abortError(self.aborted.reason) { throw error }
            guard writer.startWriting() else { throw writer.error ?? CompositionBuilder.err("cannot write export") }
            writer.startSession(atSourceTime: .zero)
            // A cancel that arrived while the writer started is torn down right after this step.
            self.phase = .running
            self.activity.touch()
            pumps.forEach(self.startPump)
        }
        for p in pumps { try await await_(p.done) }

        let finished = Once<Bool>()
        try await step(blocking: true) {
            if reader.status == .failed { throw reader.error ?? CompositionBuilder.err("cannot read layers") }
            self.phase = .finishing
            self.activity.touch()
            self.finishWriter(writer) { finished.resolve(true) }
        }
        try await await_(finished)
        try await step {
            guard writer.status == .completed else { throw writer.error ?? CompositionBuilder.err("export failed") }
            guard rename(self.partialOutput.path, self.output.path) == 0 else { throw CompositionBuilder.err("Cannot publish completed export") }
            self.phase = .finished
            self.stopWatchdog()
            self.pumps.forEach { $0.release() }
            self.aborted.clearHandlers()
        }
        return output
    }

    // MARK: Watchdog

    private func startWatchdog(reader: AVAssetReader, writer: AVAssetWriter) {
        watchQueue.async {
            var readerStatus = reader.status, writerStatus = writer.status
            let t = DispatchSource.makeTimerSource(queue: self.watchQueue)
            let interval = max(0.05, min(1, self.stallTimeout / 4))
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in
                guard let self = self, self.aborted.reason == nil else { return }
                let rs = reader.status, ws = writer.status
                if rs != readerStatus || ws != writerStatus {
                    readerStatus = rs; writerStatus = ws; self.activity.touch()
                }
                let idle = self.activity.idle
                guard idle >= self.stallTimeout else { return }
                log(String(format: "export: STALLED, nothing appended and no state change for %.1f s", idle))
                self.abort(.stalled, why: "stall watchdog")
                // The lifecycle queue may be the thing that is stuck: report what can be read without it.
                self.queue.async { log("export: stall diagnostics \(self.diagnostics())") }
            }
            self.watchdog = t
            t.resume()
        }
    }
    private func stopWatchdog() { watchQueue.async { self.watchdog?.cancel(); self.watchdog = nil } }

    private func diagnostics() -> String {
        let names = ["unknown", "active", "completed", "failed", "cancelled"]
        let rs = reader.map { names[min(4, $0.status.rawValue)] } ?? "none", ws = writer.map { names[min(4, $0.status.rawValue)] } ?? "none"
        var parts = ["reader=\(rs)", "writer=\(ws)"]
        if let e = reader?.error as NSError? { parts.append("readerError=\(e.domain) \(e.code) \(e.localizedDescription)") }
        if let e = writer?.error as NSError? { parts.append("writerError=\(e.domain) \(e.code) \(e.localizedDescription)") }
        parts += pumps.map { $0.summary }
        return parts.joined(separator: " ")
    }

    // MARK: Pumps

    /// Feeds the writer input whenever it asks, until the reader runs dry or the pump is resolved by cancel.
    static func feed(_ p: Pump) {
        p.input.requestMediaDataWhenReady(on: DispatchQueue(label: p.label)) {
            p.enter(); defer { p.exit() }
            while !p.done.isResolved && p.input.isReadyForMoreMediaData {
                guard let sb = p.output.copyNextSampleBuffer() else { p.finish(true); return }
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                guard p.append(sb, at: t) else { p.finish(false); return }
            }
        }
    }

    /// One reader output feeding one writer input. `done` resolves exactly once: the reader ran dry, an append
    /// failed, or the export was cancelled or stalled.
    final class Pump {
        let label: String
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let done = Once<Bool>()
        private let gate: WriterGate
        private let activity: Activity
        private let progress: (Double) -> Void
        private let lock = NSLock()
        private var appended = 0, last = -1.0
        // The reader and writer stay alive while a callback is inside them: `run` can return (cancel, stall) while
        // `copyNextSampleBuffer` is still blocked in the media engine, and freeing the reader then crashes.
        private var owners: [AnyObject]?
        private var inside = false, released = false

        init(label: String, output: AVAssetReaderOutput, input: AVAssetWriterInput, gate: WriterGate, activity: Activity, progress: @escaping (Double) -> Void) {
            self.label = label; self.output = output; self.input = input; self.gate = gate; self.activity = activity; self.progress = progress
        }
        func retain(_ objects: [AnyObject]) { lock.lock(); owners = objects; lock.unlock() }
        func enter() { lock.lock(); inside = true; lock.unlock() }
        func exit() { lock.lock(); inside = false; if released { owners = nil }; lock.unlock() }
        /// After teardown or a finished export; takes effect when no callback is running.
        func release() { lock.lock(); released = true; if !inside { owners = nil }; lock.unlock() }

        func append(_ sb: CMSampleBuffer, at t: Double) -> Bool {
            guard gate.run({ input.append(sb) }) == true else { return false }
            lock.lock(); appended += 1; last = t; lock.unlock()
            activity.touch()
            progress(t)
            return true
        }
        func finish(_ ok: Bool) {
            _ = gate.run { input.markAsFinished() }
            done.resolve(ok)
        }
        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return String(format: "%@[appended=%d last=%.3fs done=%@ ready=%@]", label, appended, last, done.isResolved ? "yes" : "no", input.isReadyForMoreMediaData ? "yes" : "no")
        }
    }
}

/// An exactly-once completion. Whoever resolves first wins; a wait that starts after resolution returns at once.
final class Once<T> {
    private let lock = NSLock()
    private var result: T?
    private var waiter: CheckedContinuation<T, Never>?
    func resolve(_ value: T) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(returning: value)
    }
    var isResolved: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func wait() async -> T {
        await withCheckedContinuation { c in
            lock.lock()
            if let r = result { lock.unlock(); c.resume(returning: r) } else { waiter = c; lock.unlock() }
        }
    }
}

/// Set once (cancel, stall or failure); everything registered is called then, or at once if already set.
final class AbortSignal {
    private let lock = NSLock()
    private var value: Exporter.Abort?
    private var handlers: [(Exporter.Abort) -> Void] = []
    var reason: Exporter.Abort? { lock.lock(); defer { lock.unlock() }; return value }
    func trigger(_ r: Exporter.Abort) -> Bool {
        lock.lock()
        guard value == nil else { lock.unlock(); return false }
        value = r
        let hs = handlers; handlers = []
        lock.unlock()
        hs.forEach { $0(r) }
        return true
    }
    func clearHandlers() { lock.lock(); handlers = []; lock.unlock() }
    func onTrigger(_ h: @escaping (Exporter.Abort) -> Void) {
        lock.lock()
        if let r = value { lock.unlock(); h(r); return }
        handlers.append(h)
        lock.unlock()
    }
}

/// A step is either claimed by the queue (it runs and reports) or abandoned by an abort (its wait returns), never both.
final class StepState {
    private let lock = NSLock()
    private var claimed = false, abandoned = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if abandoned { return false }; claimed = true; return true }
    func abandon() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; abandoned = true; return true }
}

/// When anything last moved (a sample appended, a lifecycle step), for the stall watchdog.
final class Activity {
    private let lock = NSLock()
    private var last = CACurrentMediaTime()
    func touch() { lock.lock(); last = CACurrentMediaTime(); lock.unlock() }
    var idle: Double { lock.lock(); defer { lock.unlock() }; return CACurrentMediaTime() - last }
}

/// Never hold a shared lock across append: the writer may wait for the other input to advance.
/// AVFoundation cancellation stops an in-flight append; the flag prevents further work afterwards.
final class WriterGate {
    private let lock = NSLock()
    private var closed = false
    func run<T>(_ f: () -> T) -> T? {
        lock.lock(); let stop = closed; lock.unlock()
        return stop ? nil : f()
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
}
