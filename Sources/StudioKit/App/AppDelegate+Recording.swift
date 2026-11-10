import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

extension AppDelegate {

    static var recordingsDir: URL {
        let d = UserDefaults.standard.string(forKey: "recordingsDir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Elgato HDR")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Disk guard: refuse to start below 5 GB free, stop cleanly below 2 GB (about ten minutes of 4K HDR).
    static let minFreeToStart: Int64 = 5_000_000_000, minFreeWhileRecording: Int64 = 2_000_000_000

    /// "Important usage" capacity counts purgeable space (caches, local snapshots) that macOS frees on demand.
    static func recordingsFreeBytes() -> Int64? {
        #if DEBUG
        // Exercises the guard without filling a disk: a file holding the byte count, re-read on every check.
        if let f = ProcessInfo.processInfo.environment["EHDR_FREE_BYTES_FILE"],
           let v = (try? String(contentsOfFile: f)).flatMap({ Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { return v }
        #endif
        return (try? recordingsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    func showRecordingAlert(_ message: String, _ info: String) {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = message; a.informativeText = info
        // A sheet, not runModal: the capture and render paths keep running on the main thread while it is up.
        a.beginSheetModal(for: window)
    }

    private func diskGB(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

    /// Runs every 5 s while recording. The volume query can stall on slow disks, so it stays off the main thread.
    func checkDiskWhileRecording() {
        guard let r = recorder else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let free = AppDelegate.recordingsFreeBytes(), free < AppDelegate.minFreeWhileRecording else { return }
            DispatchQueue.main.async {
                guard let self = self, self.recorder === r else { return }
                log("disk guard: \(self.diskGB(free)) free, stopping recording")
                self.finishRecording { log($0.logLine) }
                self.showRecordingAlert("Recording stopped: the disk is almost full",
                    "Only \(self.diskGB(free)) is left on the recordings volume. Everything up to this point was saved. Free up space or choose another recordings folder before recording again.")
            }
        }
    }

    @objc func toggleRecording() { if recorder == nil { startRecording() } else { stopRecording() } }
    @objc func showRecordings() { NSWorkspace.shared.open(AppDelegate.recordingsDir) }
    @objc func showLibraryAction() { showLibrary() }

    func showLibrary() {
        if libraryWindow == nil { libraryWindow = makeLibraryWindow() }
        Library.shared.reload()
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    /// Each recording is a project folder with one file per layer, all starting at the same instant:
    /// game.mov (HDR video + game audio), camera.mov (facecam) and mic.mov (voice), plus project.json.
    /// All three are fragmented movies, so a crash loses only the last couple of seconds.
    func startRecording() {
        guard let s = session, s.w > 0 else { toast("Nothing to record yet", detail: "Recording starts once the picture is live.", style: .warning); return }
        if let free = AppDelegate.recordingsFreeBytes(), free < AppDelegate.minFreeToStart {
            log("disk guard: \(diskGB(free)) free, not starting a recording")
            showRecordingAlert("Not enough disk space to record",
                "Only \(diskGB(free)) is free on the recordings volume; recording needs at least \(diskGB(AppDelegate.minFreeToStart)). Free up space or choose another recordings folder.")
            return
        }
        let (dir, name) = Library.shared.newProjectDir(date: Date())
        let nominal = demoSource?.fps ?? modes[modeIndex].fps
        let fps = abs(measuredFps - nominal) < 2 ? nominal : (measuredFps > 1 ? measuredFps : nominal)
        let startNs = s.lastFrameNs
        do {
            let r = try Recorder(url: dir.appendingPathComponent("game.mov"), width: s.w, height: s.h, fps: fps, colorMode: colorMode, startNs: startNs)
            var proj = Project(name: name, createdAt: Date())
            proj.state = "recording"
            proj.width = s.w; proj.height = s.h; proj.fps = fps; proj.colorMode = colorMode.rawValue
            proj.cameraMirror = cameraMirror
            beginSceneLog(&proj, startNs: startNs)
            bundleOverlayAssets(proj.scenes, into: dir)
            if camera.cameraOn, let pb = camera.latest {
                do {
                    camWriter = try LayerWriter(cameraURL: dir.appendingPathComponent("camera.mov"), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), startNs: startNs)
                    proj.camera = LayerInfo(file: "camera.mov")
                } catch { log("camera layer failed: \(error)") }
            }
            if camera.micOn {
                do { micWriter = try LayerWriter(micURL: dir.appendingPathComponent("mic.mov"), startNs: startNs); proj.mic = LayerInfo(file: "mic.mov") }
                catch { log("mic layer failed: \(error)") }
            }
            if proj.camera == nil { proj.wide.kind = .screenOnly; proj.vertical.kind = .screenOnly }
            camera.attach(camera: camWriter, mic: micWriter)
            let doc = ProjectDoc(dir: dir, project: proj); doc.save()
            recDoc = doc; AppDelegate.activeRecordingDir = dir
            recorder = r; s.recorder = r; recStart = Date()
            state.recording = true; state.recordingElapsed = 0
            state.recordingLayers = ["game"] + (camWriter != nil ? ["camera"] : []) + (micWriter != nil ? ["mic"] : [])
            refreshChecks()
            var ticks = 0
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.state.recordingElapsed = Date().timeIntervalSince(self.recStart).rounded(.down)
                ticks += 1
                if ticks % 5 == 0 { self.checkDiskWhileRecording() }
            }
            RunLoop.main.add(t, forMode: .common)   // the timer keeps counting during window resizes and menu tracking
            recTimer = t
        } catch { toast("Recording failed", detail: error.localizedDescription, style: .error); log("record failed: \(error)") }
    }

    func stopRecording() {
        finishRecording { [weak self] outcome in
            log(outcome.logLine)
            let t = outcome.toast
            self?.toast(t.text, detail: t.detail, style: t.style)
        }
    }

    /// Closes every layer, then completes project.json and its thumbnail.
    func finishRecording(_ done: @escaping (RecordingOutcome) -> Void) {
        guard let r = recorder else { return }
        endSceneLog()
        session?.recorder = nil; recorder = nil
        camera.attach(camera: nil, mic: nil)
        recTimer?.invalidate(); recTimer = nil
        state.recording = false; state.recordingElapsed = 0; state.recordingLayers = []
        refreshChecks()
        let doc = recDoc, cw = camWriter, mw = micWriter
        recDoc = nil; camWriter = nil; micWriter = nil
        let group = DispatchGroup()
        var msg = ""
        group.enter(); r.finish { m in msg = m; group.leave() }
        var camOK = true, micOK = true
        if let cw = cw { group.enter(); cw.finish { ok in camOK = ok; group.leave() } }
        if let mw = mw { group.enter(); mw.finish { ok in micOK = ok; group.leave() } }
        group.notify(queue: .main) {
            log(msg)
            let gameError = RecordingOutcome.writerError(r.writer, message: msg)
            guard let doc = doc else { done(.failed(reason: gameError ?? msg)); return }
            if !camOK { doc.project.camera = nil }
            if !micOK { doc.project.mic = nil }
            doc.finalize {
                // Only this folder: another recording may have started while this one was finishing.
                AppDelegate.recordingFinalized(doc.dir)
                Library.shared.reload()
                done(RecordingOutcome(project: doc.project, gameError: gameError))
            }
        }
    }

    func runHeadlessExport(dir: URL, range: ExportRange, res: ExportResolution) {
        headless = true
        window.orderOut(nil)
        guard let doc = ProjectDoc.load(dir) else { log("export: no project.json in \(dir.path)"); exit(1) }
        Task {
            if doc.project.durationMs == 0 { await withCheckedContinuation { c in doc.finalize { c.resume() } } }
            for canvas in Canvas.allCases {
                let t0 = Date()
                do {
                    let url = try await Exporter(doc: doc, job: ExportJob(canvas: canvas, resolution: res, range: range, fps: .source)).run { _ in }
                    log(String(format: "export: %@ in %.1f s", url.path, Date().timeIntervalSince(t0)))
                } catch { log("export \(canvas.rawValue) failed: \(error)") }
            }
            await doc.writeThumbnail()
            exit(0)
        }
    }

}
