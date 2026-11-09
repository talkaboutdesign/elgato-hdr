import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: MetalView!
    var renderer: Renderer!
    var shm: UnsafeMutableRawPointer?
    var demoSource: DemoSource?
    let demoCamera = CommandLine.arguments.contains("--demo-camera")
    let streamMixer = AudioMixer()
    var streamSession: StreamSession?
    var streamItem: NSMenuItem?
    var session: Session?
    var modeIndex = min(max(UserDefaults.standard.integer(forKey: "mode"), 0), modes.count - 1)   // also accepts `-mode N` on the command line
    var colorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "color") ?? "pq") ?? .pq
    var presentation = Presentation(rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "lowLatency") ? .immediate : .smooth)
    var modeItems: [NSMenuItem] = [], colorItems: [NSMenuItem] = []
    let audio = AudioPlayer()
    var muteItem: NSMenuItem!, recordItem: NSMenuItem!
    var presentationItems: [NSMenuItem] = []
    var recorder: Recorder?
    var recStart = Date()
    var recTimer: Timer?
    var measuredFps: Double = 30
    var lastInfo = ""

    // Facecam + microphone layers
    let camera = CameraCapture()
    var cameraMenu = NSMenu(title: "Camera")
    var cameraID = UserDefaults.standard.string(forKey: "cameraID")
    var micID = UserDefaults.standard.string(forKey: "micID")
    var cameraMirror = UserDefaults.standard.bool(forKey: "cameraMirror")
    var livePlacement: CameraPlacement = {
        if let d = UserDefaults.standard.data(forKey: "livePlacement"), let p = try? JSONDecoder().decode(CameraPlacement.self, from: d) { return p }
        return CameraPlacement()
    }()
    var recDoc: ProjectDoc?
    var camWriter: LayerWriter?, micWriter: LayerWriter?
    static var activeRecordingDir: URL?
    static func isRecording(_ dir: URL) -> Bool { activeRecordingDir == dir }
    var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        view = MetalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        audio.muted = UserDefaults.standard.bool(forKey: "muted")
        // Development: `--export <project folder> [hdr|sdr] [hd|uhd]` renders both canvases and quits (no capture).
        if let i = CommandLine.arguments.firstIndex(of: "--export"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            runHeadlessExport(dir: URL(fileURLWithPath: args[i + 1]), range: args.contains("sdr") ? .sdr : .hdr, res: args.contains("uhd") ? .uhd : .hd)
            return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--make-fixture"), i+1 < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i+1]
            let dir = arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : Self.recordingsDir.appendingPathComponent(arg)
            headless = true
            Task {
                do { let doc = try await FixtureProject.make(at: dir); log("fixture: \(doc.dir.path)"); exit(0) }
                catch { log("fixture failed: \(error)"); exit(1) }
            }
            return
        }
        #endif
        view.placement = { [weak self] in
            guard let self = self, self.camera.cameraOn else { return nil }
            return self.livePlacement
        }
        view.onPlacement = { [weak self] p in self?.setPlacement(p) }
        view.contextMenu = { [weak self] in self?.makeCameraMenu(title: "Camera") }
        buildMenu()
        setTitle("connecting…")
        if CommandLine.arguments.contains("--no-capture") { setTitle("capture off (--no-capture)") } else { start() }
        let micInput = streamMixer.addInput("mic")
        camera.onMicAudio = { buffer, ns in micInput.push(buffer, endHostNs: ns) }
        if demoCamera { camera.injectDemo(); applyOverlay() }
        if !demoCamera && cameraID != nil { camera.setCamera(uniqueID: cameraID) { [weak self] e in self?.deviceResult(e) } }
        if !demoCamera && micID != nil { camera.setMicrophone(uniqueID: micID) { [weak self] e in self?.deviceResult(e) } }
        if CommandLine.arguments.contains("--fullscreen") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.window.toggleFullScreen(nil) } }
        if CommandLine.arguments.contains("--library") { showLibrary() }
        scheduleStreaming()
        #if DEBUG
        DebugSnapshots.start()
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count, let secs = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.startRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self?.stopRecording() }
            }
        }
    }

    var headless = false
    func setTitle(_ s: String) {
        lastInfo = s
        var t = "Elgato HDR  •  \(modes[modeIndex].name)  •  \(s)" + (audio.muted ? "  •  muted" : "")
            + (camera.cameraOn ? "  •  cam" : "") + (camera.micOn ? "  •  mic" : "")
        if recorder != nil {
            let e = Int(Date().timeIntervalSince(recStart))
            let layers = ["game"] + (camWriter != nil ? ["cam"] : []) + (micWriter != nil ? ["mic"] : [])
            t = String(format: "● REC %02d:%02d [%@]  •  ", e / 60, e % 60, layers.joined(separator: "+")) + t
        }
        window.title = t + (demoSource != nil ? "  •  demo source" : "")
    }

    func start() {
        endStream()
        if recorder != nil { stopRecording() }
        if demoSource != nil, session != nil { return }
        session?.stop(); session = nil
        let mode = modes[modeIndex]
        setTitle("connecting…")
        DispatchQueue.global().async { [weak self] in
            let demo: DemoSource?
            if let (w,h,f) = DemoSource.configuration(CommandLine.arguments) { demo = DemoSource(width: w, height: h, fps: f) } else { demo = nil }
            var fd = demo.map { dup($0.readFD) } ?? connectHelper()
            if fd < 0 {
                var spawned = false
                DispatchQueue.main.sync { spawned = spawnHelperWithAdminPrompt() }
                if !spawned { DispatchQueue.main.async { self?.setTitle("helper launch cancelled") }; return }
                for _ in 0..<50 { usleep(200_000); fd = connectHelper(); if fd >= 0 { break } }
            }
            guard fd >= 0 else { DispatchQueue.main.async { self?.setTitle("helper not reachable") }; return }
            guard let self = self else { return }
            if let demo = demo {
                self.demoSource?.stop()
                self.demoSource = demo; self.shm = demo.memory
                DispatchQueue.main.sync { self.renderer?.displayLink?.invalidate(); self.renderer = nil }
            }
            if self.shm == nil { self.shm = mapSharedFrames() }
            guard let shm = self.shm else { DispatchQueue.main.async { self.setTitle("shared memory unavailable (old helper?)") }; close(fd); return }
            DispatchQueue.main.sync {
                if self.renderer == nil {
                    self.renderer = Renderer(layer: self.view.metalLayer, shm: shm, demoSource: demo)
                    self.renderer?.colorMode = self.colorMode; self.renderer?.presentation = self.presentation
                    self.view.updateDrawableSize()
                    self.renderer?.attachDisplayLink(view: self.view)
                    self.applyOverlay()
                }
            }
            guard let renderer = self.renderer else { DispatchQueue.main.async { self.setTitle("Metal unavailable") }; close(fd); return }
            let cmd = "START 7 \(mode.frame) \(mode.fps) SHM\n"
            if let demo = demo { demo.start() } else { _ = cmd.withCString { write(fd, $0, strlen($0)) } }
            renderer.resetPacing()
            let s = Session(fd: fd, renderer: renderer, shm: shm)
            s.audio = self.audio
            let gameInput = self.streamMixer.addInput("game")
            s.onGameAudio = { bytes, count, ns in gameInput.pushInt16Stereo(bytes, byteCount: count, endHostNs: ns) }
            s.onInfo = { [weak self] info in DispatchQueue.main.async {
                if let r = info.range(of: #"([0-9.]+) fps"#, options: .regularExpression), let v = Double(info[r].dropLast(4)) { self?.measuredFps = v }
                if let self = self, s.w > 0 {
                    self.window.contentAspectRatio = NSSize(width: s.w, height: s.h)
                    self.view.videoSize = CGSize(width: s.w, height: s.h)
                }
                self?.setTitle(info) } }
            DispatchQueue.main.async { self.session = s; self.setTitle("starting…") }
            s.run()
        }
    }
    /// Closing the live view stops capture (and any recording) but keeps the library and editors open.
    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        if recorder != nil { stopRecording() }
        endStream()
        session?.stop(); session = nil
        audio.stop()
    }
    @objc func showLiveView() {
        window.makeKeyAndOrderFront(nil)
        if session == nil { start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !headless }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLiveView() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        endStream()
        guard recorder != nil else { return .terminateNow }
        finishRecording { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ n: Notification) { endStream(); session?.stop(); demoSource?.stop() }
}
