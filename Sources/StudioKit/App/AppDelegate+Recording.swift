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
    @objc func toggleRecording() { if recorder == nil { startRecording() } else { stopRecording() } }
    @objc func showRecordings() { NSWorkspace.shared.open(AppDelegate.recordingsDir) }
    @objc func showLibraryAction() { showLibrary() }

    func showLibrary() {
        if libraryWindow == nil { libraryWindow = makeLibraryWindow() }
        Library.shared.reload()
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    /// Each recording is a project folder with one file per layer, all starting at the same instant:
    /// game.mov (HDR video + game audio), camera.mov (facecam) and mic.m4a (voice), plus project.json.
    func startRecording() {
        guard let s = session, s.w > 0 else { setTitle("not streaming, cannot record"); return }
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
            proj.wide.camera = livePlacement
            if camera.cameraOn, let pb = camera.latest {
                do {
                    camWriter = try LayerWriter(cameraURL: dir.appendingPathComponent("camera.mov"), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), startNs: startNs)
                    proj.camera = LayerInfo(file: "camera.mov")
                } catch { log("camera layer failed: \(error)") }
            }
            if camera.micOn {
                do { micWriter = try LayerWriter(micURL: dir.appendingPathComponent("mic.m4a"), startNs: startNs); proj.mic = LayerInfo(file: "mic.m4a") }
                catch { log("mic layer failed: \(error)") }
            }
            if proj.camera == nil { proj.wide.kind = .screenOnly; proj.vertical.kind = .screenOnly }
            camera.attach(camera: camWriter, mic: micWriter)
            let doc = ProjectDoc(dir: dir, project: proj); doc.save()
            recDoc = doc; AppDelegate.activeRecordingDir = dir
            recorder = r; s.recorder = r; recStart = Date()
            recordItem.title = "Stop Recording"
            recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.setTitle(self?.lastInfo ?? "") }
            setTitle(lastInfo)
        } catch { setTitle("record failed: \(error.localizedDescription)"); log("record failed: \(error)") }
    }

    func stopRecording() { finishRecording { [weak self] msg in log(msg); self?.setTitle(msg) } }

    /// Closes every layer, then completes project.json and its thumbnail.
    func finishRecording(_ done: @escaping (String) -> Void) {
        guard let r = recorder else { return }
        session?.recorder = nil; recorder = nil
        camera.attach(camera: nil, mic: nil)
        recTimer?.invalidate(); recTimer = nil
        recordItem.title = "Start Recording"
        let doc = recDoc, cw = camWriter, mw = micWriter
        recDoc = nil; camWriter = nil; micWriter = nil
        let group = DispatchGroup()
        var msg = ""
        group.enter(); r.finish { m in msg = m; group.leave() }
        var camOK = true, micOK = true
        if let cw = cw { group.enter(); cw.finish { ok in camOK = ok; group.leave() } }
        if let mw = mw { group.enter(); mw.finish { ok in micOK = ok; group.leave() } }
        group.notify(queue: .main) {
            AppDelegate.activeRecordingDir = nil
            guard let doc = doc else { done(msg); return }
            if !camOK { doc.project.camera = nil }
            if !micOK { doc.project.mic = nil }
            let layers = ["game"] + (doc.project.camera != nil ? ["camera"] : []) + (doc.project.mic != nil ? ["mic"] : [])
            doc.finalize {
                Library.shared.reload()
                done("saved \(doc.project.name) [\(layers.joined(separator: " + "))]")
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
